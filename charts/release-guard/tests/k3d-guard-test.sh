#!/usr/bin/env bash
# Behavioural test of the staging-release-guard ValidatingAdmissionPolicy (charts/release-guard)
# on the LOCAL THROWAWAY cluster context k3d-teknoir-dev (never vpro, never production: the script
# refuses any context that does not start with "k3d-" or "kind-"). Repeatable: it creates the
# namespace rg-test and the cluster-scoped VAP/binding staging-release-guard*, tests, and removes
# them again on exit.
#
# Every verdict is taken with --dry-run=server, which runs admission, so a wrong expectation can
# never change state. State is changed only in the setup (creating the Applications as the ArgoCD
# controller, annotating the namespace for break-glass) and in the GC / namespace teardown tests.
#
# The identities are impersonated (--as); system:masters is added so RBAC does not get in the way,
# except for the releaser, which runs with the chart's own Role (the real minimum).
#
# Break-glass is the annotation teknoir.org/release-guard=break-glass on the namespace (read by the
# policy as namespaceObject). A paramRef ConfigMap was the first design; on k3s v1.34.5 the param
# lookup stopped working after the first namespace deletion (see charts/release-guard/README.md).
#
#   charts/release-guard/tests/k3d-guard-test.sh            # default context k3d-teknoir-dev
#   CONTEXT=k3d-other charts/release-guard/tests/k3d-guard-test.sh
#
# Needs: kubectl, helm, curl (only to fetch the ArgoCD Application CRD if the cluster lacks it).
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
CONTEXT="${CONTEXT:-k3d-teknoir-dev}"
NS="${NS:-rg-test}"
ARGOCD_CRD_URL="${ARGOCD_CRD_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.1/manifests/crds/application-crd.yaml}"

case "$CONTEXT" in
  k3d-*|kind-*) ;;
  *) echo "refusing context '$CONTEXT': this test only runs on a throwaway k3d/kind cluster" >&2; exit 2 ;;
esac
for t in kubectl helm; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

KC=(kubectl --context "$CONTEXT")
TMP=$(mktemp -d)
pass=0; failn=0
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }

# ---- identities -----------------------------------------------------------------------------
ARGO=system:serviceaccount:teknoir-system:argocd-application-controller
PC=system:serviceaccount:teknoir-system:profile-controller
GC=system:serviceaccount:kube-system:generic-garbage-collector
NSC=system:serviceaccount:kube-system:namespace-controller
RELEASER=system:serviceaccount:${NS}:staging-releaser
ARGO_SERVER=system:serviceaccount:teknoir-system:argocd-server
as_flags() {
  case "$1" in
    releaser) echo "--as=${RELEASER} --as-group=system:serviceaccounts --as-group=system:authenticated" ;;
    admin)    echo "--as=anders --as-group=system:masters --as-group=system:authenticated" ;;
    argo)     echo "--as=${ARGO} --as-group=system:masters --as-group=system:authenticated" ;;
    argosrv)  echo "--as=${ARGO_SERVER} --as-group=system:masters --as-group=system:authenticated" ;;
    pc)       echo "--as=${PC} --as-group=system:masters --as-group=system:authenticated" ;;
    gc)       echo "--as=${GC} --as-group=system:masters --as-group=system:authenticated" ;;
    nsc)      echo "--as=${NSC} --as-group=system:masters --as-group=system:authenticated" ;;
    *) echo "unknown identity $1" >&2; return 1 ;;
  esac
}

# run <identity> <kubectl args...>: server dry run as that identity, prints combined output
run() { local id=$1; shift; local f; f=$(as_flags "$id"); # shellcheck disable=SC2086
  "${KC[@]}" $f "$@" 2>&1; }

# expect allow|deny|warn <description> <identity> <kubectl args...>
#   allow  exit 0 and no policy message
#   warn   exit 0 and a "Warning:" naming the policy
#   deny   non-zero and the output names ValidatingAdmissionPolicy 'staging-release-guard'
# The apiserver caches policy and param changes for a moment, so a verdict is retried for ~15 s.
expect() {
  local want=$1 desc=$2 id=$3; shift 3
  local out rc i
  for i in $(seq 1 15); do
    out=$(run "$id" "$@"); rc=$?
    case "$want" in
      allow) [[ $rc -eq 0 && "$out" != *staging-release-guard* ]] && { ok "allow  $desc"; return; } ;;
      warn)  [[ $rc -eq 0 && "$out" == *staging-release-guard* && "$out" == *Warning* ]] && { ok "warn   $desc"; return; } ;;
      deny)  [[ $rc -ne 0 && "$out" == *"ValidatingAdmissionPolicy 'staging-release-guard'"* ]] && { ok "deny   $desc"; return; } ;;
    esac
    sleep 1
  done
  bad "$want $desc  (rc=$rc) ${out:0:300}"
}
# expect_rbac_deny: refused by RBAC (not the policy) - the releaser has no verb for it
expect_rbac_deny() {
  local desc=$1 id=$2; shift 2
  local out rc; out=$(run "$id" "$@"); rc=$?
  [[ $rc -ne 0 && "$out" == *"forbidden"* && "$out" != *staging-release-guard* ]] && ok "rbac   $desc" || bad "rbac $desc (rc=$rc) ${out:0:200}"
}

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
TAG=staging-20261017.1
# shape of a valid root patch from the releaser
ROOT_OK='{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'","teknoir.org/previous-release":"staging-20261016.9"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'","forceString":true},{"name":"releaseName","value":"'$TAG'","forceString":true}]}}}}'

cleanup() {
  "${KC[@]}" delete validatingadmissionpolicybinding staging-release-guard-binding --ignore-not-found >/dev/null 2>&1
  "${KC[@]}" delete validatingadmissionpolicy staging-release-guard --ignore-not-found >/dev/null 2>&1
  # break-glass is safe for the teardown: nothing is guarded any more once the binding is gone
  "${KC[@]}" delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== context ${CONTEXT}, namespace ${NS}"
"${KC[@]}" version >/dev/null 2>&1 || { echo "cluster ${CONTEXT} is not reachable" >&2; exit 2; }
if ! "${KC[@]}" get crd applications.argoproj.io >/dev/null 2>&1; then
  echo "== installing the ArgoCD Application CRD from ${ARGOCD_CRD_URL}"
  curl -fsSL "$ARGOCD_CRD_URL" -o "${TMP}/crd.yaml" && "${KC[@]}" apply --server-side -f "${TMP}/crd.yaml" >/dev/null \
    || { echo "cannot install the Application CRD (set ARGOCD_CRD_URL)" >&2; exit 2; }
  "${KC[@]}" wait --for=condition=Established crd/applications.argoproj.io --timeout=60s >/dev/null
fi
"${KC[@]}" delete validatingadmissionpolicybinding staging-release-guard-binding --ignore-not-found >/dev/null
"${KC[@]}" delete validatingadmissionpolicy staging-release-guard --ignore-not-found >/dev/null
"${KC[@]}" delete namespace "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
"${KC[@]}" create namespace "$NS" >/dev/null

render() { helm template release-guard "$CHART" --namespace "$NS" --set namespace="$NS" "$@"; }

# ---- helm render sanity ---------------------------------------------------------------------
render --set guard.mode=Bogus >/dev/null 2>&1 && bad "render accepts guard.mode=Bogus" || ok "render rejects guard.mode=Bogus"

# ---- install the guard in Deny mode ----------------------------------------------------------
render --set guard.mode=Deny | "${KC[@]}" apply -f - >/dev/null || { echo "cannot apply the chart" >&2; exit 2; }
sleep 3
TC=$("${KC[@]}" get validatingadmissionpolicy staging-release-guard -o jsonpath='{.status.typeChecking.expressionWarnings}')
[[ -z "$TC" ]] && ok "CEL type check: no warnings" || bad "CEL type check warnings: $TC"

cat > "${TMP}/child.yaml" <<E
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: child, namespace: ${NS}}
spec:
  project: teknoir-cloud
  destination: {namespace: x, server: https://kubernetes.default.svc}
  source: {path: charts/x, repoURL: https://github.com/teknoir/platform-applications-gitops, targetRevision: "${SHA1}"}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
E
sed 's/name: child/name: new-app/' "${TMP}/child.yaml" > "${TMP}/new.yaml"
cat > "${TMP}/root.yaml" <<E
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: ${NS}
  annotations: {teknoir.org/release: staging-20261017.0}
spec:
  project: default
  destination: {namespace: ${NS}, server: https://kubernetes.default.svc}
  source:
    path: charts/app-of-apps
    repoURL: https://github.com/teknoir/platform-applications-gitops
    targetRevision: "${SHA1}"
    helm:
      parameters:
        - {name: release, value: "${SHA1}", forceString: true}
        - {name: releaseName, value: staging-20261017.0, forceString: true}
  sources: []
  syncPolicy: {automated: {prune: true, selfHeal: true}}
E

echo "== setup: the Applications are created by the ArgoCD controller and profile-controller (excluded identities)"
run argo apply -f "${TMP}/child.yaml" >/dev/null && ok "setup: argocd controller created child" || bad "setup: argocd controller cannot create child"
run pc apply -f "${TMP}/root.yaml" >/dev/null && ok "setup: profile-controller created root" || bad "setup: profile-controller cannot create root"
[[ $failn -eq 0 ]] || { echo "setup failed, stopping" >&2; exit 1; }
sed 's/name: child/name: pc-child/' "${TMP}/child.yaml" | run pc apply -f - >/dev/null && ok "setup: profile-controller created pc-child" || bad "setup: profile-controller cannot create pc-child"

echo "== 1. a plain admin (every session is system:admin)"
expect deny  "admin: create a new Application"            admin create -n "$NS" -f "${TMP}/new.yaml" --dry-run=server
expect allow "admin: kubectl apply of the unchanged root (no spec change)" admin apply -f "${TMP}/root.yaml" --dry-run=server -o name
sed -i 's/targetRevision: .*/targetRevision: teknoir-cloud/' "${TMP}/root.yaml"
expect deny  "admin: apply the branch-following root"      admin apply -f "${TMP}/root.yaml" --dry-run=server
sed -i "s/targetRevision: .*/targetRevision: \"${SHA1}\"/" "${TMP}/root.yaml"
expect deny  "admin: patch a child targetRevision"         admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect deny  "admin: patch a child syncPolicy (selfHeal off)" admin patch application child -n "$NS" --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}' --dry-run=server
expect deny  "admin: patch the root helm parameters"       admin patch application app-of-apps -n "$NS" --type merge -p '{"spec":{"source":{"helm":{"parameters":[{"name":"x","value":"y"}]}}}}' --dry-run=server
expect deny  "admin: patch a plugin Application (profile-controller's)" admin patch application pc-child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"0.0.1"}}}' --dry-run=server
expect deny  "admin: delete a child"                       admin delete application child -n "$NS" --dry-run=server
expect deny  "admin: delete the root"                      admin delete application app-of-apps -n "$NS" --dry-run=server
expect deny  "admin: remove the finalizers of a child"     admin patch application child -n "$NS" --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' --dry-run=server
expect deny  "admin: argocd app sync --revision teknoir-cloud (operation, foreign revision)" admin patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"teknoir-cloud"}}}' --dry-run=server
expect deny  "admin: sync with a revisions list that differs" admin patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revisions":["main"]}}}' --dry-run=server
echo "-- not evaluated (status-only and no-spec updates)"
expect allow "admin: annotate a child (refresh)"           admin annotate application child -n "$NS" argocd.argoproj.io/refresh=hard --overwrite --dry-run=server
expect allow "admin: annotate the root teknoir.org/break-glass" admin annotate application app-of-apps -n "$NS" teknoir.org/break-glass=reason --overwrite --dry-run=server
expect allow "admin: write status only"                    admin patch application child -n "$NS" --type merge -p '{"status":{"health":{"status":"Healthy"},"sync":{"status":"Synced","revision":"'$SHA1'"}}}' --dry-run=server
expect allow "admin: plain sync (operation without revision)" admin patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"prune":true}}}' --dry-run=server
expect allow "admin: sync with revision == targetRevision" admin patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"'$SHA1'"}}}' --dry-run=server
expect allow "admin: patch a spec field to the same value (no change)" admin patch application child -n "$NS" --type merge -p '{"spec":{"project":"teknoir-cloud"}}' --dry-run=server
expect allow "admin: unrelated resources are untouched (ConfigMap create)" admin create configmap probe -n "$NS" --dry-run=server

echo "== 2. ArgoCD's controller, profile-controller, and the argocd-server (not excluded)"
expect allow "argocd controller: change a child spec"      argo patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect allow "argocd controller: create an Application"    argo create -f "${TMP}/new.yaml" -n "$NS" --dry-run=server
expect allow "argocd controller: sync with a foreign revision" argo patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"teknoir-cloud"}}}' --dry-run=server
expect allow "argocd controller: delete a child"            argo delete application child -n "$NS" --dry-run=server
expect allow "argocd controller: write the root status"     argo patch application app-of-apps -n "$NS" --type merge -p '{"status":{"sync":{"status":"Synced"}}}' --dry-run=server
expect allow "profile-controller: change a plugin Application" pc patch application pc-child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"0.0.105"}}}' --dry-run=server
expect allow "profile-controller: delete a plugin Application" pc delete application pc-child -n "$NS" --dry-run=server
expect allow "profile-controller: create a plugin Application" pc create -f "${TMP}/new.yaml" -n "$NS" --dry-run=server
expect allow "argocd-server: plain sync / hard refresh (no spec change)" argosrv annotate application child -n "$NS" argocd.argoproj.io/refresh=hard --overwrite --dry-run=server
expect deny  "argocd-server: app set --revision (spec change)" argosrv patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"main"}}}' --dry-run=server
expect deny  "argocd-server: app sync --revision main"      argosrv patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"main"}}}' --dry-run=server
expect deny  "argocd-server: app delete"                    argosrv delete application child -n "$NS" --dry-run=server

echo "== 3. the releaser (real Role, no system:masters)"
expect allow "releaser: patch the root to a valid release" releaser patch application app-of-apps -n "$NS" --type merge -p "$ROOT_OK" --dry-run=server
expect allow "releaser: patch a child (rollback terminates operations)" releaser patch application child -n "$NS" --type merge -p '{"operation":null}' --dry-run=server
expect allow "releaser: terminate-style operation revision == target" releaser patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"'$SHA1'"}}}' --dry-run=server
expect deny  "releaser: operation revision != target (argocd app sync --revision)" releaser patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"main"}}}' --dry-run=server
bad_root() { # bad_root <description> <json patch>
  expect deny "releaser: root shape: $1" releaser patch application app-of-apps -n "$NS" --type merge -p "$2" --dry-run=server
}
bad_root "targetRevision is a branch" '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}'
bad_root "targetRevision is a short sha" '{"spec":{"source":{"targetRevision":"abcdef1"}}}'
bad_root "targetRevision is an uppercase sha" '{"spec":{"source":{"targetRevision":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}}'
bad_root "release parameter != targetRevision" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA1'"},{"name":"releaseName","value":"'$TAG'"}]}}}}'
bad_root "releaseName != annotation" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"staging-20261017.9"}]}}}}'
bad_root "annotation is not staging-YYYYMMDD.N" '{"metadata":{"annotations":{"teknoir.org/release":"v1"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"v1"}]}}}}'
bad_root "extra helm parameter" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"'$TAG'"},{"name":"project","value":"x"}]}}}}'
bad_root "only one helm parameter" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'"}]}}}}'
bad_root "helm values" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"values":"x: 1","parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"'$TAG'"}]}}}}'
bad_root "helm valuesObject" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"valuesObject":{"x":1},"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"'$TAG'"}]}}}}'
bad_root "helm valueFiles" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"source":{"targetRevision":"'$SHA2'","helm":{"valueFiles":["x.yaml"],"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"'$TAG'"}]}}}}'
bad_root "selfHeal off" '{"metadata":{"annotations":{"teknoir.org/release":"'$TAG'"}},"spec":{"syncPolicy":{"automated":{"selfHeal":false}},"source":{"targetRevision":"'$SHA2'","helm":{"parameters":[{"name":"release","value":"'$SHA2'"},{"name":"releaseName","value":"'$TAG'"}]}}}}'
bad_root "wrong repoURL" '{"spec":{"source":{"repoURL":"https://github.com/evil/repo"}}}'
bad_root "wrong path" '{"spec":{"source":{"path":"charts/auth"}}}'
bad_root "project changed" '{"spec":{"project":"teknoir-cloud"}}'
expect_rbac_deny "releaser: delete the root (no delete verb; the policy denies it too)" releaser delete application app-of-apps -n "$NS" --dry-run=server
expect allow "releaser: annotation-only change of the root is not evaluated" releaser annotate application app-of-apps -n "$NS" teknoir.org/previous-release=staging-20261016.9 --overwrite --dry-run=server
echo "-- the releaser's Role is minimal"
expect_rbac_deny "releaser: create an Application"   releaser create -f "${TMP}/new.yaml" -n "$NS" --dry-run=server
expect_rbac_deny "releaser: delete a child"          releaser delete application child -n "$NS" --dry-run=server
expect_rbac_deny "releaser: read a Secret"           releaser get secrets -n "$NS"
expect_rbac_deny "releaser: annotate the namespace (break-glass is not the releaser's)" releaser annotate namespace "$NS" teknoir.org/release-guard=break-glass --overwrite --dry-run=server
cat > "${TMP}/lease.yaml" <<E
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: {name: staging-release-lock, namespace: ${NS}}
spec: {holderIdentity: test, leaseDurationSeconds: 60}
E
run releaser create -f "${TMP}/lease.yaml" --dry-run=server >/dev/null && ok "releaser: create the Lease staging-release-lock" || bad "releaser: cannot create the Lease"
sed 's/staging-release-lock/other-lock/' "${TMP}/lease.yaml" | run releaser create -f - --dry-run=server >/dev/null 2>&1 \
  && ok "releaser: may create any Lease (create cannot be limited by name; update/patch can)" || ok "releaser: cannot create other Leases"

echo "== 4. kube-system controllers: garbage collection and namespace teardown"
# GC: a child Application owned by a ConfigMap is deleted by the generic-garbage-collector when the owner goes
"${KC[@]}" create configmap gc-owner -n "$NS" >/dev/null
OWNER_UID=$("${KC[@]}" get configmap gc-owner -n "$NS" -o jsonpath='{.metadata.uid}')
sed -e 's/name: child/name: gc-child/' "${TMP}/child.yaml" | run argo apply -f - >/dev/null
"${KC[@]}" patch application gc-child -n "$NS" --as="$ARGO" --as-group=system:masters --type merge \
  -p '{"metadata":{"ownerReferences":[{"apiVersion":"v1","kind":"ConfigMap","name":"gc-owner","uid":"'"$OWNER_UID"'"}]}}' >/dev/null
"${KC[@]}" delete configmap gc-owner -n "$NS" >/dev/null
gone=0; for _ in $(seq 1 40); do "${KC[@]}" get application gc-child -n "$NS" >/dev/null 2>&1 || { gone=1; break; }; sleep 1; done
[[ $gone -eq 1 ]] && ok "garbage collector deleted the owned Application (identity ${GC})" || bad "garbage collector could not delete the owned Application (guard blocks the real GC identity?)"
expect allow "kube-system GC identity (impersonated): delete" gc delete application child -n "$NS" --dry-run=server
expect allow "kube-system namespace-controller (impersonated): delete" nsc delete application child -n "$NS" --dry-run=server

echo "== 5. break-glass (annotation on the namespace)"
BG=teknoir.org/release-guard
setmode() { # setmode <value>|- (- removes the annotation)
  if [[ "$1" == "-" ]]; then "${KC[@]}" annotate namespace "$NS" "${BG}-" >/dev/null
  else "${KC[@]}" annotate namespace "$NS" "${BG}=$1" --overwrite >/dev/null; fi
  sleep 1
}
setmode break-glass
expect allow "break-glass: admin patches a child"           admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect allow "break-glass: admin creates an Application"    admin create -f "${TMP}/new.yaml" -n "$NS" --dry-run=server
expect allow "break-glass: admin sync --revision other"     admin patch application child -n "$NS" --type merge -p '{"operation":{"sync":{"revision":"main"}}}' --dry-run=server
expect allow "break-glass: admin deletes the root"          admin delete application app-of-apps -n "$NS" --dry-run=server
expect deny  "break-glass: the releaser still cannot write a bad root shape" releaser patch application app-of-apps -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect allow "break-glass: the releaser still writes a valid root" releaser patch application app-of-apps -n "$NS" --type merge -p "$ROOT_OK" --dry-run=server
setmode -
expect deny  "break-glass removed: admin patches a child again" admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect deny  "break-glass removed: admin deletes the root again" admin delete application app-of-apps -n "$NS" --dry-run=server
setmode "true"
expect deny  "annotation with another value (true) is not break-glass" admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
setmode ""
expect deny  "annotation with an empty value is not break-glass" admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
setmode -
expect allow "no state to lose: ArgoCD works with no annotation" argo patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server

echo "== 6. Warn mode"
render --set guard.mode=Warn | "${KC[@]}" apply -f - >/dev/null; sleep 3
expect warn  "Warn: admin patch goes through with a warning" admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect warn  "Warn: admin create goes through with a warning" admin create -f "${TMP}/new.yaml" -n "$NS" --dry-run=server
expect allow "Warn: the releaser sees no warning"           releaser patch application app-of-apps -n "$NS" --type merge -p "$ROOT_OK" --dry-run=server
expect allow "Warn: ArgoCD sees no warning"                 argo patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
expect allow "Warn: annotation-only change, no warning"     admin annotate application child -n "$NS" argocd.argoproj.io/refresh=hard --overwrite --dry-run=server
setmode break-glass
expect allow "Warn + break-glass: no warning"               admin patch application child -n "$NS" --type merge -p '{"spec":{"source":{"targetRevision":"teknoir-cloud"}}}' --dry-run=server
setmode -

echo "== 7. namespace teardown (the namespace controller deletes the Applications)"
render --set guard.mode=Deny | "${KC[@]}" apply -f - >/dev/null; sleep 3
"${KC[@]}" delete namespace "$NS" --wait=false >/dev/null
gone=0; for _ in $(seq 1 90); do "${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || { gone=1; break; }; sleep 1; done
if [[ $gone -eq 1 ]]; then ok "namespace deleted with Applications inside, guard in Deny"
else
  bad "namespace stuck Terminating: $("${KC[@]}" get namespace "$NS" -o jsonpath='{.status.conditions[*].message}' | head -c 300)"
fi

echo
echo "RESULT: ${pass} passed, ${failn} failed (context ${CONTEXT})"
[[ $failn -eq 0 ]]
