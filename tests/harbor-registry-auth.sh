#!/usr/bin/env bash
# tests/harbor-registry-auth.sh — exercise the harbor chart's registry-auth Job
# (charts/harbor/templates/registry-auth-job.yaml, files/registry-auth.sh) on
# a throwaway cluster, and check its htpasswd against Harbor's own registry.
#
# Usage: tests/harbor-registry-auth.sh --context k3d-<name> [--no-registry]
#
# The cluster must be disposable (the context must start with k3d-): the test
# creates namespace teknoir-system there and leaves it behind. It needs the
# toolbox image (docker.io/alpine/k8s:1.34.11) available to the cluster, e.g.
# `k3d image import -c <name> alpine/k8s:1.34.11`.
#
# Cases:
#   1  absent Secret: created with both keys, labelled, bcrypt line for the user
#   2  re-run: the Secret is unchanged (resourceVersion and data)
#   3  the Job's logs contain neither the password nor the htpasswd line
#   4  RBAC: the Job's ServiceAccount cannot read another Secret
#   5  rotation: the Secret deleted while the consumers run -> re-created, the
#      ready consumers that reference it are restarted, nothing pending
#   6  a Deployment that does not reference the Secret is not restarted
#   7  incomplete Secret (one key emptied) -> both keys replaced
#   8  pending restart left by a dead run -> restarted and cleared
#   9  (docker) goharbor/registry-photon:v2.14.3 accepts the generated
#      htpasswd with the password (200 on /v2/) and rejects a wrong one (401)
# Secret values only ever go to files in a private temp dir (mode 0600) and
# are compared there; nothing prints them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS=teknoir-system
SECRET=harbor-registry-auth
USERNAME=harbor_registry_user
REGISTRY_IMAGE=goharbor/registry-photon:v2.14.3
PAUSE_IMAGE=docker.io/rancher/mirrored-pause:3.6
ctx=""
registry=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) ctx="$2"; shift 2 ;;
    --no-registry) registry=false; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "${ctx}" == k3d-* ]] || { echo "--context k3d-<name> is required (a disposable cluster)" >&2; exit 2; }

kc() { kubectl --context "${ctx}" "$@"; }
umask 077
tmp="$(mktemp -d)"
container=""
cleanup() {
  [[ -z "${container}" ]] || docker rm -f "${container}" >/dev/null 2>&1 || true
  rm -rf "${tmp}"
}
trap cleanup EXIT

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { local what="$1"; shift; if "$@"; then pass "${what}"; else fail "${what}"; fi; }

# --- render the chart's registry-auth objects ----------------------------------
"${ROOT}/tests/render.sh" --no-determinism --out "${tmp}/render" harbor > "${tmp}/render.log" 2>&1 || true
[[ -s "${tmp}/render/harbor.yaml" ]] || { cat "${tmp}/render.log" >&2; echo "harbor does not render" >&2; exit 1; }
yq 'select(.metadata.name == "harbor-registry-auth" and .kind != "Job")' "${tmp}/render/harbor.yaml" > "${tmp}/rbac.yaml"
yq 'select(.metadata.name == "harbor-registry-auth" and .kind == "Job")' "${tmp}/render/harbor.yaml" > "${tmp}/job.yaml"
[[ "$(yq -N '.kind' "${tmp}/rbac.yaml" | sort | tr '\n' ' ')" == "ConfigMap Role RoleBinding ServiceAccount " ]] \
  || { echo "unexpected registry-auth objects in the render" >&2; exit 1; }

kc create namespace "${NS}" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc apply -f "${tmp}/rbac.yaml" >/dev/null

# Stand-ins for the consumers: pause containers that reference the Secret the
# way the Harbor chart does (env for core/jobservice, a volume for registry).
consumer() {
  # consumer <name> <env|volume|none>
  local how="$1"
  case "$2" in
    env) how='env: [{name: REGISTRY_CREDENTIAL_PASSWORD, valueFrom: {secretKeyRef: {name: '"${SECRET}"', key: REGISTRY_PASSWD}}}]' ;;
    volume) how='volumeMounts: [{name: htpasswd, mountPath: /etc/registry/passwd, subPath: passwd}]' ;;
    none) how='env: []' ;;
  esac
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: $1}}
  template:
    metadata: {labels: {app: $1}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: c
          image: ${PAUSE_IMAGE}
          imagePullPolicy: IfNotPresent
          ${how}
$( [[ "$2" == volume ]] && printf '      volumes: [{name: htpasswd, secret: {secretName: %s, items: [{key: REGISTRY_HTPASSWD, path: passwd}]}}]\n' "${SECRET}" )
---
EOF
}

run_job() {
  # run_job <log-file>: one run of the Job to completion
  kc -n "${NS}" delete job harbor-registry-auth --ignore-not-found --wait=true >/dev/null
  kc apply -f "${tmp}/job.yaml" >/dev/null
  if ! kc -n "${NS}" wait --for=condition=complete job/harbor-registry-auth --timeout=180s >/dev/null 2>&1; then
    kc -n "${NS}" logs job/harbor-registry-auth --all-containers > "$1" 2>&1 || true
    echo "the Job did not complete; its log follows (values never appear in it, see case 3)" >&2
    cat "$1" >&2
    return 1
  fi
  kc -n "${NS}" logs job/harbor-registry-auth --all-containers > "$1" 2>&1
}

save_secret() {
  # save_secret <dir>: the keys as files, plus resourceVersion and annotations
  mkdir -p "$1"
  kc -n "${NS}" get secret "${SECRET}" -o json > "$1/secret.json"
  jq -j '.data.REGISTRY_PASSWD // "" | @base64d' "$1/secret.json" > "$1/passwd"
  jq -j '.data.REGISTRY_HTPASSWD // "" | @base64d' "$1/secret.json" > "$1/htpasswd"
  jq -r '.metadata.resourceVersion' "$1/secret.json" > "$1/rv"
  jq -j '.metadata.annotations["teknoir.org/restart-pending"] // ""' "$1/secret.json" > "$1/pending"
  rm -f "$1/secret.json"
}

differs() { ! cmp -s "$1" "$2"; }
restarted_at() { kc -n "${NS}" get deployment "$1" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'; }
no_values_in() {
  # no_values_in <log> <dir>: neither the password nor the htpasswd hash
  ! grep -qF -f "$2/passwd" "$1" && ! grep -qF "$(cut -d: -f2- < "$2/htpasswd")" "$1"
}

# --- 1-4: create, re-run, logs, RBAC ------------------------------------------
kc -n "${NS}" delete secret "${SECRET}" --ignore-not-found >/dev/null
run_job "${tmp}/log1"
save_secret "${tmp}/s1"
check "1 Secret created with a 32-character password" test "$(wc -c < "${tmp}/s1/passwd")" -eq 32
check "1 htpasswd is a bcrypt line for ${USERNAME}" \
  grep -qE "^${USERNAME}:\\\$2[aby]\\\$10\\\$[./A-Za-z0-9]{53}\$" "${tmp}/s1/htpasswd"
check "1 Secret labelled teknoir.org/managed-by=harbor-registry-auth" \
  test "$(kc -n "${NS}" get secret "${SECRET}" -o jsonpath='{.metadata.labels.teknoir\.org/managed-by}')" = harbor-registry-auth
check "1 no restart pending" test ! -s "${tmp}/s1/pending"
run_job "${tmp}/log2"
save_secret "${tmp}/s2"
check "2 re-run leaves the Secret unchanged (resourceVersion)" cmp -s "${tmp}/s1/rv" "${tmp}/s2/rv"
check "2 re-run leaves the Secret unchanged (data)" cmp -s "${tmp}/s1/passwd" "${tmp}/s2/passwd"
check "2 re-run logs 'unchanged'" grep -q "exists with both keys: unchanged" "${tmp}/log2"
check "3 logs hold no value (create run)" no_values_in "${tmp}/log1" "${tmp}/s1"
check "3 logs hold no value (re-run)" no_values_in "${tmp}/log2" "${tmp}/s1"
sa="system:serviceaccount:${NS}:harbor-registry-auth"
kc -n "${NS}" create secret generic unrelated-secret --from-literal=k=v --dry-run=client -o yaml | kc apply -f - >/dev/null
check "4 RBAC: cannot get another Secret" test "$(kc -n "${NS}" auth can-i get secret/unrelated-secret --as "${sa}" || true)" = no
check "4 RBAC: cannot list Secrets" test "$(kc -n "${NS}" auth can-i list secrets --as "${sa}" || true)" = no
check "4 RBAC: can get its own Secret" test "$(kc -n "${NS}" auth can-i get "secret/${SECRET}" --as "${sa}" || true)" = yes

# --- 5-6: rotation restarts the running consumers -------------------------------
# harbor-jobservice stands in for a listed Deployment that does not use the
# Secret (yet): it must never be restarted
{ consumer harbor-core env; consumer harbor-jobservice none; consumer harbor-registry volume; } > "${tmp}/consumers.yaml"
kc apply -f "${tmp}/consumers.yaml" >/dev/null
for d in harbor-core harbor-jobservice harbor-registry; do
  kc -n "${NS}" rollout status "deployment/${d}" --timeout=180s >/dev/null
done
kc -n "${NS}" delete secret "${SECRET}" >/dev/null
run_job "${tmp}/log5"
save_secret "${tmp}/s5"
check "5 Secret re-created with a new password" differs "${tmp}/s1/passwd" "${tmp}/s5/passwd"
check "5 harbor-core restarted" test -n "$(restarted_at harbor-core)"
check "5 harbor-registry restarted" test -n "$(restarted_at harbor-registry)"
check "5 no restart left pending" test ! -s "${tmp}/s5/pending"
check "6 harbor-jobservice (not using the Secret) not restarted" test -z "$(restarted_at harbor-jobservice)"
check "3 logs hold no value (rotation run)" no_values_in "${tmp}/log5" "${tmp}/s5"

# --- 7: incomplete Secret -------------------------------------------------------
kc -n "${NS}" patch secret "${SECRET}" --type merge -p '{"data":{"REGISTRY_HTPASSWD":""}}' >/dev/null
run_job "${tmp}/log7"
save_secret "${tmp}/s7"
check "7 incomplete Secret: password replaced" differs "${tmp}/s5/passwd" "${tmp}/s7/passwd"
check "7 incomplete Secret: htpasswd written" grep -qE "^${USERNAME}:\\\$2" "${tmp}/s7/htpasswd"
check "7 incomplete Secret: logged" grep -q "was incomplete: both keys replaced" "${tmp}/log7"

# --- 8: a pending restart from a dead run ---------------------------------------
before="$(restarted_at harbor-registry)"
sleep 1
kc -n "${NS}" annotate secret "${SECRET}" teknoir.org/restart-pending=harbor-registry --overwrite >/dev/null
run_job "${tmp}/log8"
save_secret "${tmp}/s8"
check "8 pending restart done" test "$(restarted_at harbor-registry)" != "${before}"
check "8 pending annotation cleared" test ! -s "${tmp}/s8/pending"
check "8 data unchanged" cmp -s "${tmp}/s7/passwd" "${tmp}/s8/passwd"

# --- 9: Harbor's registry accepts the htpasswd ----------------------------------
if [[ "${registry}" == true ]]; then
  mkdir -p "${tmp}/reg"
  cp "${tmp}/s8/htpasswd" "${tmp}/reg/passwd"
  cat > "${tmp}/reg/config.yml" <<'EOF'
version: 0.1
storage:
  filesystem:
    rootdirectory: /tmp/registry
http:
  addr: :5000
auth:
  htpasswd:
    realm: harbor-registry-basic-realm
    path: /etc/registry/passwd
EOF
  chmod 0644 "${tmp}/reg/passwd" "${tmp}/reg/config.yml"
  chmod 0755 "${tmp}/reg"
  container="$(docker run -d -p 127.0.0.1::5000 \
    -v "${tmp}/reg/passwd:/etc/registry/passwd:ro" -v "${tmp}/reg/config.yml:/etc/registry/config.yml:ro" \
    "${REGISTRY_IMAGE}")"
  port="$(docker port "${container}" 5000/tcp | head -1 | sed 's/.*://')"
  printf 'machine 127.0.0.1 login %s password %s\n' "${USERNAME}" "$(cat "${tmp}/s8/passwd")" > "${tmp}/netrc"
  printf 'machine 127.0.0.1 login %s password wrong-password\n' "${USERNAME}" > "${tmp}/netrc-wrong"
  code=""
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --netrc-file "${tmp}/netrc" "http://127.0.0.1:${port}/v2/" || true)"
    [[ "${code}" == 000 ]] || break
    sleep 1
  done
  check "9 ${REGISTRY_IMAGE} accepts the generated credential (HTTP ${code})" test "${code}" = 200
  code="$(curl -s -o /dev/null -w '%{http_code}' --netrc-file "${tmp}/netrc-wrong" "http://127.0.0.1:${port}/v2/" || true)"
  check "9 ${REGISTRY_IMAGE} rejects a wrong password (HTTP ${code})" test "${code}" = 401
fi

echo
echo "harbor-registry-auth: ${fails} failed"
[[ "${fails}" -eq 0 ]]
