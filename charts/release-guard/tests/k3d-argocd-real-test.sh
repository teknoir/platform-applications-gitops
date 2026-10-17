#!/usr/bin/env bash
# Test of the staging-release-guard ValidatingAdmissionPolicy against a REAL ArgoCD (v3.5.1, the version on
# staging) on the LOCAL THROWAWAY cluster context k3d-teknoir-dev (the script refuses any context that does not
# start with "k3d-" or "kind-"). k3d-guard-test.sh impersonates the identities with `kubectl --as` and emulates
# ArgoCD's request shapes; this script runs the real tools, so the shapes are the ones ArgoCD really writes:
# `argocd app sync`, `argocd app terminate-op`, the UI's REST calls (POST /api/v1/applications/<n>/sync, DELETE
# .../operation) through argocd-server, autosync and selfHeal by the application controller, and then the denied
# cases with the real CLI (`argocd app set --revision` with --core as the kube admin and through the server,
# `argocd app sync --revision`, `--local` manifests), plus hand `kubectl patch` of the root.
#
#   charts/release-guard/tests/k3d-argocd-real-test.sh              # default context k3d-teknoir-dev
#   CONTEXT=k3d-other KEEP=1 charts/release-guard/tests/k3d-argocd-real-test.sh
#
# What it creates on the cluster (and removes again on exit, unless KEEP=1):
#   - ArgoCD v3.5.1 (upstream manifests/install.yaml, with the namespace of the ClusterRoleBindings rewritten) in
#     the namespace $NS (default teknoir-system, the namespace and the service accounts the chart's default
#     `identities` expect; another NS works because the script passes `identities` explicitly). Dex, the
#     notifications controller and the applicationset controller are scaled to 0 (not needed).
#     The CRDs applications/appprojects that existed before are left in place.
#   - namespace rg-real-git: a pod serving a throwaway git repo (git://, `git daemon`; fixed commit dates, so
#     the SHAs are stable) and a Helm repository (busybox httpd). No dependence on GitHub; the images
#     busybox:1.36 and alpine/git (+ apk git-daemon) are pulled by the node.
#   - the test Applications (project default, destination the cluster, namespaces rg-real-*):
#       app-of-apps  the "root" (the guard's rootApplication), pinned to a commit SHA, automated
#       rg-pinned    mirrors our children: single source, pinned SHA, no `sources`, ignoreDifferences with `group`
#                    omitted, ServerSideApply, automated prune + selfHeal
#       rg-manual    manual sync, pinned SHA        rg-slow   manual, a PreSync hook that sleeps (a running op)
#       rg-helm      a Helm repo chart at an exact version (like the profile-plugin apps), manual
#       rg-branch    follows the branch `main`, automated
#       rg-legacy    manual, stored the way the app-of-apps templates used to render children (`sources: []`,
#                    ignoreDifferences `group: ""`): ArgoCD's Go types drop both when argocd-server writes the
#                    Application back, so ANY sync/terminate from the UI or CLI changes spec and is refused.
#                    That is why the templates must not render them (check-pins: app-not-roundtrip-stable).
#   - the guard (helm template of this chart), Deny, then Warn.
# argocd-server is reached by `kubectl port-forward` (127.0.0.1:$PORT) with a real login; the admin password and
# session token are never printed (they live in files below a 0700 temp dir).
#
# Needs: kubectl, helm, jq, git, curl, tar, python3 (PyYAML), argocd (CLI v3.5.x), network access for the node
# to pull images and for this host to download the upstream install manifest.
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$(cd "${HERE}/.." && pwd)}"   # CHART=<dir of another release-guard chart> runs the test against it (a negative control)
CONTEXT="${CONTEXT:-k3d-teknoir-dev}"
NS="${NS:-teknoir-system}"
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.1}"
INSTALL_URL="${INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml}"
PORT="${PORT:-18443}"
KEEP="${KEEP:-0}"
GITNS=rg-real-git
ROOT=app-of-apps
GITURL="git://rg-git.${GITNS}.svc/repo.git"
HELMURL="http://rg-git.${GITNS}.svc/charts"

case "$CONTEXT" in
  k3d-*|kind-*) ;;
  *) echo "refusing context '$CONTEXT': this test only runs on a throwaway k3d/kind cluster" >&2; exit 2 ;;
esac
for t in kubectl helm jq git curl tar python3 argocd; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

KC=(kubectl --context "$CONTEXT")
KN=(kubectl --context "$CONTEXT" -n "$NS")
TMP=$(mktemp -d); chmod 700 "$TMP"
ACFG="${TMP}/argocd-config"
AC=(argocd --config "$ACFG")
pass=0; failn=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }
note() { printf -- '-- %s\n' "$*"; }
trim() { tr '\n' ' ' | cut -c1-"${1:-300}"; }

PF_PID=""; INSTALLED_BY_US=0; PRE_CRDS=""
cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1
  if [[ "$KEEP" == "1" ]]; then
    echo "== KEEP=1: leaving ArgoCD, the test Applications and the guard installed in ${NS} on ${CONTEXT}"
  else
    echo "== teardown"
    "${KC[@]}" delete validatingadmissionpolicybinding staging-release-guard-binding --ignore-not-found >/dev/null 2>&1
    "${KC[@]}" delete validatingadmissionpolicy staging-release-guard --ignore-not-found >/dev/null 2>&1
    for a in "$ROOT" rg-pinned rg-manual rg-slow rg-helm rg-branch rg-legacy rg-new; do
      "${KN[@]}" delete application "$a" --ignore-not-found --wait=false >/dev/null 2>&1
    done
    sleep 3
    "${KC[@]}" delete namespace "$GITNS" rg-real-apps rg-real-root rg-real-manual rg-real-branch rg-real-helm rg-real-legacy --ignore-not-found --wait=false >/dev/null 2>&1
    "${KN[@]}" delete rolebinding,role,serviceaccount -l app.kubernetes.io/name=release-guard --ignore-not-found >/dev/null 2>&1
    if [[ $INSTALLED_BY_US -eq 1 && -f "${TMP}/install-ns.yaml" ]]; then
      # everything of the install except the CRDs that existed before (the Application and AppProject CRDs are shared
      # with k3d-guard-test.sh, which installs the Application CRD itself when it is missing)
      python3 - "${TMP}/install-ns.yaml" "${PRE_CRDS}" > "${TMP}/install-teardown.yaml" <<'PY'
import sys, yaml
keep = set(sys.argv[2].split())
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
print(yaml.safe_dump_all([d for d in docs if not (d["kind"] == "CustomResourceDefinition" and d["metadata"]["name"] in keep)]))
PY
      "${KC[@]}" delete -n "$NS" -f "${TMP}/install-teardown.yaml" --ignore-not-found --wait=false >/dev/null 2>&1
      echo "ArgoCD ${ARGOCD_VERSION} removed from ${NS} (namespace ${NS} itself is left)"
    fi
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== context ${CONTEXT}, ArgoCD namespace ${NS}, ArgoCD ${ARGOCD_VERSION}"
"${KC[@]}" version >/dev/null 2>&1 || { echo "cluster ${CONTEXT} is not reachable" >&2; exit 2; }
"${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$NS" >/dev/null
PRE_CRDS=$("${KC[@]}" get crd applications.argoproj.io appprojects.argoproj.io -o name 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
# refuse a namespace that holds anything but ArgoCD / this guard
FOREIGN=$("${KN[@]}" get deploy,statefulset,daemonset -o json | jq -r '[.items[] | select((.metadata.labels["app.kubernetes.io/part-of"] // "") != "argocd") | .metadata.name] | join(" ")')
[[ -z "$FOREIGN" ]] || { echo "namespace ${NS} holds workloads that are not ArgoCD (${FOREIGN}); set NS to an empty namespace" >&2; exit 2; }
"${KC[@]}" delete validatingadmissionpolicybinding staging-release-guard-binding --ignore-not-found >/dev/null
"${KC[@]}" delete validatingadmissionpolicy staging-release-guard --ignore-not-found >/dev/null
# leftovers of an earlier run (the teardown does not wait for the namespaces to go)
"${KC[@]}" delete namespace "$GITNS" rg-real-apps rg-real-root rg-real-manual rg-real-branch rg-real-helm rg-real-legacy --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1

# ---- 1. ArgoCD ------------------------------------------------------------------------------------
if "${KN[@]}" get deploy argocd-server >/dev/null 2>&1; then
  IMG=$("${KN[@]}" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')
  [[ "$IMG" == *":${ARGOCD_VERSION}" ]] || { echo "ArgoCD in ${NS} runs ${IMG}, not ${ARGOCD_VERSION}" >&2; exit 2; }
  echo "== ArgoCD ${ARGOCD_VERSION} is already installed in ${NS}, reusing it"
else
  echo "== installing ArgoCD ${ARGOCD_VERSION} in ${NS}"
  curl -fsSL "$INSTALL_URL" -o "${TMP}/install.yaml" || { echo "cannot download ${INSTALL_URL}" >&2; exit 2; }
  # the ClusterRoleBinding subjects name the namespace argocd
  sed "s/^\(\s*namespace:\) argocd\$/\1 ${NS}/" "${TMP}/install.yaml" > "${TMP}/install-ns.yaml"
  INSTALLED_BY_US=1
  "${KC[@]}" apply --server-side --force-conflicts -n "$NS" -f "${TMP}/install-ns.yaml" >/dev/null || { echo "install failed" >&2; exit 2; }
fi
for d in argocd-dex-server argocd-notifications-controller argocd-applicationset-controller; do
  "${KN[@]}" scale deploy "$d" --replicas=0 >/dev/null
done
"${KN[@]}" rollout status deploy/argocd-server deploy/argocd-repo-server deploy/argocd-redis --timeout=300s >/dev/null || { echo "ArgoCD did not come up" >&2; exit 2; }
"${KN[@]}" rollout status sts/argocd-application-controller --timeout=300s >/dev/null || { echo "the application controller did not come up" >&2; exit 2; }
SRV=$("${KN[@]}" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}')
ok "ArgoCD running: ${SRV}"

# ---- 2. a git repository and a Helm repository inside the cluster ----------------------------------
echo "== test repositories in ${GITNS}"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
commit_at() { export GIT_AUTHOR_DATE="2026-10-17T10:0$1:00+00:00" GIT_COMMITTER_DATE="2026-10-17T10:0$1:00+00:00"; }
mkdir -p "${TMP}/src/plain" "${TMP}/src/hook" && git -C "${TMP}/src" init -q -b main
cat > "${TMP}/src/plain/cm.yaml" <<'E'
apiVersion: v1
kind: ConfigMap
metadata: {name: rg-plain}
data: {v: "1"}
E
cat > "${TMP}/src/hook/cm.yaml" <<'E'
apiVersion: v1
kind: ConfigMap
metadata: {name: rg-hook}
data: {v: "1"}
E
# a PreSync hook that sleeps: the sync operation stays Running until it is terminated
cat > "${TMP}/src/hook/job.yaml" <<'E'
apiVersion: batch/v1
kind: Job
metadata:
  name: rg-hook
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - {name: sleep, image: "busybox:1.36", command: ["sleep", "3600"]}
E
commit_at 1; git -C "${TMP}/src" add -A; git -C "${TMP}/src" commit -qm one
SHA1=$(git -C "${TMP}/src" rev-parse HEAD)
sed -i 's/"1"/"2"/' "${TMP}/src/plain/cm.yaml"; commit_at 2; git -C "${TMP}/src" commit -qam two
SHA2=$(git -C "${TMP}/src" rev-parse HEAD)
git clone -q --bare "${TMP}/src" "${TMP}/repo.git"; git -C "${TMP}/repo.git" update-server-info
mkdir -p "${TMP}/chart/rg-chart/templates" "${TMP}/www/charts"
printf 'apiVersion: v2\nname: rg-chart\nversion: 0.1.0\n' > "${TMP}/chart/rg-chart/Chart.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: rg-helm}\ndata: {v: "1"}\n' > "${TMP}/chart/rg-chart/templates/cm.yaml"
helm package "${TMP}/chart/rg-chart" -d "${TMP}/www/charts" >/dev/null && helm repo index "${TMP}/www/charts" --url "$HELMURL" || { echo "cannot package the test chart" >&2; exit 2; }
cat > "${TMP}/git.yaml" <<E
apiVersion: v1
kind: Namespace
metadata: {name: ${GITNS}}
---
apiVersion: v1
kind: Pod
metadata: {name: rg-git, namespace: ${GITNS}, labels: {app: rg-git}}
spec:
  containers:
    - name: httpd
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /www && exec httpd -f -p 80 -h /www"]
      volumeMounts: [{name: www, mountPath: /www}]
      readinessProbe: {tcpSocket: {port: 80}}
    - name: gitd
      image: alpine/git:2.47.2
      command: ["sh", "-c", "apk add --no-cache git-daemon >/dev/null && git config --global --add safe.directory '*' && exec git daemon --reuseaddr --base-path=/www --export-all --listen=0.0.0.0 --port=9418 /www"]
      volumeMounts: [{name: www, mountPath: /www}]
      readinessProbe: {tcpSocket: {port: 9418}}
  volumes: [{name: www, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata: {name: rg-git, namespace: ${GITNS}}
spec: {selector: {app: rg-git}, ports: [{name: http, port: 80}, {name: git, port: 9418}]}
E
"${KC[@]}" apply -f "${TMP}/git.yaml" >/dev/null || { echo "cannot create the git pod" >&2; exit 2; }
"${KC[@]}" -n "$GITNS" wait --for=condition=Ready pod/rg-git --timeout=240s >/dev/null || { echo "the git pod is not Ready" >&2; exit 2; }
push_repo() { tar cf - -C "$TMP" repo.git | "${KC[@]}" -n "$GITNS" exec -i rg-git -c httpd -- tar xf - -C /www; }
push_repo && tar cf - -C "${TMP}/www" charts | "${KC[@]}" -n "$GITNS" exec -i rg-git -c httpd -- tar xf - -C /www || { echo "cannot copy the repositories" >&2; exit 2; }
for _ in $(seq 1 30); do "${KC[@]}" -n "$GITNS" exec rg-git -c gitd -- git ls-remote git://localhost/repo.git >/dev/null 2>&1 && break; sleep 1; done
"${KC[@]}" -n "$GITNS" exec rg-git -c gitd -- git ls-remote git://localhost/repo.git 2>&1 | grep -q "$SHA2" && ok "git repo served: main=${SHA2:0:7}, pinned SHA ${SHA1:0:7}" || { echo "the git daemon does not serve the repo" >&2; exit 2; }
# push_commit <n>: a new commit on main (what a branch-following app autosyncs)
push_commit() {
  sed -i "s/\"[0-9]*\"/\"$1\"/" "${TMP}/src/plain/cm.yaml"; commit_at "$1"
  git -C "${TMP}/src" commit -qam "commit $1" && git -C "${TMP}/repo.git" fetch -q "${TMP}/src" main:main && git -C "${TMP}/repo.git" update-server-info && push_repo
}

# ---- 3. login to argocd-server (real CLI and REST) --------------------------------------------------
"${KN[@]}" port-forward svc/argocd-server "${PORT}:443" >"${TMP}/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do curl -sk -o /dev/null "https://127.0.0.1:${PORT}/api/version" && break; sleep 1; done
PW=$("${KN[@]}" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
"${AC[@]}" login "127.0.0.1:${PORT}" --insecure --username admin --password "$PW" >/dev/null 2>&1 && ok "argocd login (real CLI) to argocd-server" || { echo "argocd login failed" >&2; exit 2; }
curl -sk -X POST "https://127.0.0.1:${PORT}/api/v1/session" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg p "$PW" '{username:"admin",password:$p}')" | jq -r .token > "${TMP}/token"; unset PW
[[ -s "${TMP}/token" && "$(cat "${TMP}/token")" != null ]] && ok "REST session token (the UI's login)" || { echo "cannot get a session token" >&2; exit 2; }
# --core talks to the Kubernetes API with the kube admin, no argocd-server: a copy of the kubeconfig with the namespace set
"${KC[@]}" config view --minify --flatten > "${TMP}/kubeconfig"
kubectl --kubeconfig "${TMP}/kubeconfig" config set-context --current --namespace="$NS" >/dev/null
core() { KUBECONFIG="${TMP}/kubeconfig" argocd --core "$@"; }
# api <METHOD> <path> [json]: sets API_CODE and API_OUT (the response body is kept in a file, never printed whole)
api() {
  API_CODE=$(curl -sk -o "${TMP}/api.out" -w '%{http_code}' -H "Authorization: Bearer $(cat "${TMP}/token")" \
    -H 'Content-Type: application/json' -X "$1" "https://127.0.0.1:${PORT}/api/v1/$2" ${3:+-d "$3"})
  API_OUT=$(head -c 600 "${TMP}/api.out" | tr '\n' ' ')
}

# ---- 4. the test Applications (created before the guard exists) -------------------------------------
cat > "${TMP}/apps.yaml" <<E
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${ROOT}, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-root}
  source: {repoURL: "${GITURL}", path: plain, targetRevision: "${SHA1}"}
  syncPolicy: {automated: {prune: true, selfHeal: true}, syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-pinned, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-apps}
  source: {repoURL: "${GITURL}", path: plain, targetRevision: "${SHA1}"}
  ignoreDifferences:
    - kind: Secret
      name: some-secret
      jsonPointers: [/data, /stringData]
    - group: apps
      kind: Deployment
      jsonPointers: [/spec/replicas]
  syncPolicy:
    syncOptions: [ServerSideApply=true, CreateNamespace=true]
    automated: {prune: true, selfHeal: true, enabled: true}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-manual, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-manual}
  source: {repoURL: "${GITURL}", path: plain, targetRevision: "${SHA1}"}
  syncPolicy: {syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-slow, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-apps}
  source: {repoURL: "${GITURL}", path: hook, targetRevision: "${SHA1}"}
  syncPolicy: {syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-branch, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-branch}
  source: {repoURL: "${GITURL}", path: plain, targetRevision: main}
  syncPolicy: {automated: {prune: true, selfHeal: true}, syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-legacy, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-legacy}
  source: {repoURL: "${GITURL}", path: plain, targetRevision: "${SHA1}"}
  sources: []
  ignoreDifferences:
    - {group: "", kind: Secret, name: some-secret, jsonPointers: [/data]}
  syncPolicy: {syncOptions: [CreateNamespace=true]}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: rg-helm, namespace: ${NS}}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: rg-real-helm}
  source: {repoURL: "${HELMURL}", chart: rg-chart, targetRevision: 0.1.0}
  syncPolicy: {syncOptions: [CreateNamespace=true]}
E
"${KC[@]}" apply -f "${TMP}/apps.yaml" >/dev/null || { echo "cannot create the test Applications" >&2; exit 2; }
app_field() { "${KN[@]}" get application "$1" -o jsonpath="$2" 2>/dev/null; }
wait_for() { # wait_for <seconds> <description> <command...>: poll until the command succeeds
  local secs=$1 desc=$2; shift 2; local i
  for ((i=0; i<secs; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}
synced_healthy() { [[ "$(app_field "$1" '{.status.sync.status}/{.status.health.status}')" == "Synced/Healthy" ]]; }
for a in "$ROOT" rg-pinned rg-branch; do
  wait_for 120 "$a" synced_healthy "$a" && ok "setup: ${a} is Synced/Healthy (automated sync by the real controller)" || bad "setup: ${a} is not Synced/Healthy: $(app_field "$a" '{.status.sync.status}/{.status.health.status} {.status.conditions[*].message}' | trim 200)"
done
[[ $failn -eq 0 ]] || { echo "setup failed, stopping" >&2; exit 1; }

# ---- 5. install the guard (Deny); identities given explicitly so any NS works ----------------------
render() { helm template release-guard "$CHART" --namespace "$NS" --set namespace="$NS" \
  --set identities.argocdController="system:serviceaccount:${NS}:argocd-application-controller" \
  --set identities.profileController="system:serviceaccount:${NS}:profile-controller" "$@"; }
render --set guard.mode=Deny | "${KC[@]}" apply -f - >/dev/null || { echo "cannot apply the chart" >&2; exit 2; }
# the apiserver takes a moment to enforce a new policy: wait until a hand patch of the root is refused
probe_denied() { out=$("${KC[@]}" -n "$NS" patch application "$ROOT" --type merge -p '{"spec":{"source":{"targetRevision":"main"}}}' --dry-run=server 2>&1); [[ "$out" == *staging-release-guard* ]]; }
wait_for 60 probe "probe_denied" || { echo "the guard does not enforce" >&2; exit 2; }
TC=$("${KC[@]}" get validatingadmissionpolicy staging-release-guard -o jsonpath='{.status.typeChecking.expressionWarnings}')
[[ -z "$TC" ]] && ok "CEL type check: no warnings" || bad "CEL type check warnings: $TC"

# ---- expectation helpers ------------------------------------------------------------------------------
GUARD="ValidatingAdmissionPolicy 'staging-release-guard'"
# run <command...> -> OUT, RC
run() { OUT=$("$@" 2>&1); RC=$?; }
warn_count() { "${KC[@]}" get --raw /metrics 2>/dev/null | awk '/^apiserver_validating_admission_policy_check_total\{/ && /enforcement_action="warn"/ && /policy="staging-release-guard"/ {n+=$NF} END {print n+0}'; }
# allowed <desc> <command...>: exit 0, no mention of the guard, and (Warn mode) the warn counter did not move
allowed() {
  local desc=$1; shift; local w0 w1; w0=$(warn_count)
  run "$@"; w1=$(warn_count)
  if [[ $RC -ne 0 ]]; then bad "allowed: ${desc} (rc=${RC}) $(printf '%s' "$OUT" | trim)"
  elif [[ "$OUT" == *staging-release-guard* ]]; then bad "allowed: ${desc} printed a guard message: $(printf '%s' "$OUT" | trim)"
  elif [[ $w1 -ne $w0 ]]; then bad "allowed: ${desc} moved the warn counter (${w0} -> ${w1})"
  else ok "allowed ${MODE}: ${desc}"; fi
}
# Warn lets the "denied" changes through, so the next case would start from a changed state: put the specs back (admin
# apply of the same manifests), drop the hand annotation and the extra Application. Not measured by any counter window.
restore() {
  [[ "$MODE" == Warn ]] || return 0
  "${KC[@]}" apply -f "${TMP}/apps.yaml" >/dev/null 2>&1
  "${KN[@]}" annotate application "$ROOT" teknoir.org/release- >/dev/null 2>&1
  "${KN[@]}" delete application rg-new --ignore-not-found --wait=false >/dev/null 2>&1
  wait_for 60 "rg-manual idle" no_operation rg-manual
}
# denied <desc> <command...>: Deny: non-zero exit and the guard named in the output; Warn: exit 0 and the warn counter moved
denied() {
  local desc=$1; shift; local w0 w1; w0=$(warn_count)
  run "$@"; w1=$(warn_count)
  if [[ "$MODE" == Deny ]]; then
    [[ $RC -ne 0 && "$OUT" == *"$GUARD"* ]] && ok "denied  Deny: ${desc}" || bad "denied: ${desc} (rc=${RC}) $(printf '%s' "$OUT" | trim)"
  else
    [[ $RC -eq 0 && $w1 -gt $w0 ]] && ok "warned  Warn: ${desc} (warn counter ${w0} -> ${w1})" || bad "warned: ${desc} (rc=${RC}, counter ${w0} -> ${w1}) $(printf '%s' "$OUT" | trim)"
    restore
  fi
}
# api_allowed / api_denied <desc> <METHOD> <path> [json]: the UI's REST call through argocd-server
api_allowed() {
  local desc=$1; shift; local w0 w1; w0=$(warn_count); api "$@"; w1=$(warn_count)
  if [[ "$API_CODE" == 200 && "$API_OUT" != *staging-release-guard* && $w1 -eq $w0 ]]; then ok "allowed ${MODE}: ${desc} (HTTP 200)"
  else bad "allowed: ${desc} (HTTP ${API_CODE}, counter ${w0} -> ${w1}) ${API_OUT:0:300}"; fi
}
api_denied() {
  local desc=$1; shift; local w0 w1; w0=$(warn_count); api "$@"; w1=$(warn_count)
  if [[ "$MODE" == Deny ]]; then
    [[ "$API_CODE" != 200 && "$API_OUT" == *"$GUARD"* ]] && ok "denied  Deny: ${desc} (HTTP ${API_CODE})" || bad "denied: ${desc} (HTTP ${API_CODE}) ${API_OUT:0:300}"
  else
    [[ "$API_CODE" == 200 && $w1 -gt $w0 ]] && ok "warned  Warn: ${desc} (HTTP 200, counter ${w0} -> ${w1})" || bad "warned: ${desc} (HTTP ${API_CODE}, counter ${w0} -> ${w1}) ${API_OUT:0:300}"
    restore
  fi
}
phase() { app_field "$1" '{.status.operationState.phase}'; }
no_operation() { [[ -z "$(app_field "$1" '{.operation}')" ]]; }
op_running() { [[ "$(phase "$1")" == Running && -n "$(app_field "$1" '{.operation}')" ]]; }
idle() { wait_for 60 "idle $1" no_operation "$1"; }   # the controller clears .operation when an operation is over

# ---- the allowed cases: run in Deny and again in Warn ---------------------------------------------------
allowed_cases() {
  echo "-- ALLOWED (${MODE}): the real tools, nothing may be refused, warned or counted"
  idle rg-slow; idle rg-pinned
  allowed "argocd app sync rg-pinned (CLI -> argocd-server, mirrors our children)" "${AC[@]}" app sync rg-pinned
  allowed "argocd app sync rg-helm (CLI, chart version 0.1.0 as revision)" "${AC[@]}" app sync rg-helm
  allowed "argocd app sync rg-manual (CLI, manual app)" "${AC[@]}" app sync rg-manual
  allowed "argocd app get rg-pinned --hard-refresh (refresh annotation)" "${AC[@]}" app get rg-pinned --hard-refresh
  api_allowed "UI sync of rg-pinned (POST /api/v1/applications/rg-pinned/sync, the Sync dialog's body)" \
    POST applications/rg-pinned/sync '{"prune":false,"dryRun":false,"strategy":{"hook":{"force":false}},"syncOptions":{"items":["CreateNamespace=true"]}}'
  api_allowed "UI sync of rg-helm (REST)" POST applications/rg-helm/sync '{"prune":false}'
  api_allowed "UI sync of rg-manual with revision == its pinned targetRevision (REST)" POST applications/rg-manual/sync '{"revision":"'$SHA1'"}'
  allowed "argocd --core app sync rg-pinned (kube admin writes a plain sync itself)" core app sync rg-pinned

  idle rg-slow
  allowed "argocd app sync rg-slow --async (starts an operation that stays Running on a sleeping hook)" "${AC[@]}" app sync rg-slow --async
  wait_for 60 "running" op_running rg-slow && ok "rg-slow: operation is Running" || bad "rg-slow: no running operation"
  allowed "argocd app terminate-op rg-slow (CLI)" "${AC[@]}" app terminate-op rg-slow
  wait_for 60 "terminated" idle rg-slow && ok "rg-slow: terminated ($(phase rg-slow))" || bad "rg-slow: still has an operation after terminate ($(phase rg-slow))"
  api_allowed "UI sync of rg-slow (REST)" POST applications/rg-slow/sync '{"prune":false,"dryRun":false,"strategy":{"hook":{}}}'
  wait_for 60 "running" op_running rg-slow && ok "rg-slow: operation is Running again" || bad "rg-slow: no running operation"
  api_allowed "UI terminate of rg-slow (DELETE /api/v1/applications/rg-slow/operation)" DELETE applications/rg-slow/operation
  wait_for 60 "terminated" idle rg-slow && ok "rg-slow: terminated ($(phase rg-slow))" || bad "rg-slow: still has an operation after the UI terminate"

  # autosync and selfHeal run as the application controller (an excluded identity)
  "${KC[@]}" -n rg-real-apps patch configmap rg-plain --type merge -p '{"data":{"v":"drift"}}' >/dev/null 2>&1
  w0=$(warn_count)
  healed() { [[ "$("${KC[@]}" -n rg-real-apps get configmap rg-plain -o jsonpath='{.data.v}' 2>/dev/null)" == 1 ]]; }
  wait_for 60 healed healed && [[ $(warn_count) -eq $w0 ]] && ok "allowed ${MODE}: selfHeal of drift on rg-pinned (controller operation), no warning" || bad "selfHeal of rg-pinned did not heal or warned"
  w0=$(warn_count); N=$((N+1)); push_commit "$((N+2))"
  "${AC[@]}" app get rg-branch --hard-refresh >/dev/null 2>&1
  branch_synced() { [[ "$("${KC[@]}" -n rg-real-branch get configmap rg-plain -o jsonpath='{.data.v}' 2>/dev/null)" == "$((N+2))" ]]; }
  wait_for 90 branch branch_synced && [[ $(warn_count) -eq $w0 ]] && ok "allowed ${MODE}: autosync of a new commit on the branch app rg-branch (controller operation), no warning" || bad "autosync of rg-branch did not run or warned"
}
N=0

# ---- the denied cases: Deny refuses, Warn lets them through with a warning --------------------------------
denied_cases() {
  echo "-- NOT ALLOWED (${MODE}): changing what is deployed, with the real CLI"
  idle rg-manual
  denied "argocd --core app set ${ROOT} --revision <other> (as the kube admin)" core app set "$ROOT" --revision "$SHA2"
  denied "argocd app set rg-manual --revision <other> (through argocd-server)" "${AC[@]}" app set rg-manual --revision "$SHA2"
  denied "argocd app sync rg-manual --revision <other SHA>" "${AC[@]}" app sync rg-manual --revision "$SHA2"
  idle rg-manual
  denied "argocd app sync rg-manual --revision main" "${AC[@]}" app sync rg-manual --revision main
  idle rg-manual
  mkdir -p "${TMP}/loc" && cp -r "${TMP}/src/plain" "${TMP}/loc/" && sed -i 's/"[0-9]*"/"local"/' "${TMP}/loc/plain/cm.yaml"
  denied "argocd app sync rg-manual --local (operation.sync.manifests override)" "${AC[@]}" app sync rg-manual --local "${TMP}/loc/plain" --local-repo-root "${TMP}/loc"
  idle rg-manual
  api_denied "UI-style sync of rg-manual with another revision (REST)" POST applications/rg-manual/sync '{"revision":"'$SHA2'"}'
  idle rg-manual
  denied "kubectl patch of the root spec (hand edit, kube admin)" "${KN[@]}" patch application "$ROOT" --type merge -p '{"spec":{"source":{"targetRevision":"'$SHA2'"}}}'
  denied "kubectl patch of a child spec (selfHeal off)" "${KN[@]}" patch application rg-pinned --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
  denied "kubectl patch: operation.sync.manifests override on rg-manual" "${KN[@]}" patch application rg-manual --type merge \
    -p '{"operation":{"sync":{"source":'"$(app_field rg-manual '{.spec.source}')"',"revision":"'$SHA1'","manifests":["apiVersion: v1\nkind: ConfigMap\nmetadata: {name: x}"]}}}'
  idle rg-manual
  denied "kubectl annotate: the root's teknoir.org/release annotation by hand" "${KN[@]}" annotate application "$ROOT" teknoir.org/release=staging-20261017.9 --overwrite
  denied "argocd app create (a new Application through argocd-server)" "${AC[@]}" app create rg-new --repo "$GITURL" --path plain --dest-server https://kubernetes.default.svc --dest-namespace rg-real-new --revision "$SHA1"
  echo "-- a stored empty 'sources: []' / group '' (the old templates): the Go round trip of argocd-server changes spec"
  denied "argocd app sync rg-legacy (stored 'sources: []' and group '': argocd-server's full Update drops them, so spec changes)" "${AC[@]}" app sync rg-legacy
  echo "-- known limit: a branch-following Application is not plain-syncable by argocd-server (it writes the resolved SHA); the guard is enabled only after the cutover, when every gitops child is pinned"
  denied "argocd app sync rg-branch (symbolic targetRevision 'main': revision written is the resolved SHA)" "${AC[@]}" app sync rg-branch
  if [[ "$MODE" == Deny ]]; then
    denied "argocd app delete rg-manual (through argocd-server)" "${AC[@]}" app delete rg-manual --yes
    denied "kubectl delete the root application" "${KN[@]}" delete application "$ROOT"
  fi
}

MODE=Deny
echo "== A. Deny: the real tools"
allowed_cases
denied_cases

echo "== B. Warn: the same allowed cases must not move the warn counter; the denied ones warn"
# remove what Deny could not stop in Warn mode, and restore the root
render --set guard.mode=Warn | "${KC[@]}" apply -f - >/dev/null; sleep 5
MODE=Warn
for _ in $(seq 1 30); do [[ "$("${KC[@]}" get validatingadmissionpolicybinding staging-release-guard-binding -o jsonpath='{.spec.validationActions[0]}')" == Warn ]] && break; sleep 1; done
W_BEFORE=$(warn_count)
allowed_cases
W_ALLOWED=$(warn_count)
[[ $W_ALLOWED -eq $W_BEFORE ]] && ok "Warn: all allowed cases together left the apiserver warn counter at ${W_BEFORE}" || bad "Warn: the warn counter moved over the allowed cases (${W_BEFORE} -> ${W_ALLOWED})"
denied_cases
[[ $(warn_count) -gt $W_ALLOWED ]] && ok "Warn: the denied cases moved the counter (${W_ALLOWED} -> $(warn_count))" || bad "Warn: the denied cases did not move the counter"

echo
echo "RESULT: ${pass} passed, ${failn} failed (context ${CONTEXT}, ArgoCD ${SRV##*:})"
[[ $failn -eq 0 ]]
