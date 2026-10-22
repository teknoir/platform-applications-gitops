#!/usr/bin/env bash
# Behavioural test of the RBAC of the Backstage API service account on the LOCAL THROWAWAY cluster context
# k3d-teknoir-dev (never vpro, never production: the script refuses any context that does not start with "k3d-" or
# "kind-"). Applies the RENDERED RBAC of charts/backstage and charts/ztna, plus a hand-made RoleBinding
# "teknoir-portal" in one fake teamspace (what profile-controller writes on a real cluster), and asks the API server
# `auth can-i` as system:serviceaccount:teknoir-system:backstage-api. No ArgoCD, no controllers. Everything it creates
# is removed again on exit (the namespaces, the rendered RBAC, and the CRDs only if it installed them).
#
# What it proves (plans/ztna-later.md, "backstage-sa"): the service account can do what the Backstage backend does and
# cannot become another identity (impersonate), run code (pods, exec), read Secrets in bulk, change RBAC, or write
# outside a teamspace that has the RoleBinding.
#
# Run from scripts/tests/run.sh with K3D=1, or alone:
#   charts/backstage/tests/k3d-rbac-test.sh                       # default context k3d-teknoir-dev
#   CONTEXT=k3d-other charts/backstage/tests/k3d-rbac-test.sh
#
# Needs: kubectl, helm.
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHARTS="$(cd "${HERE}/../.." && pwd)"
CONTEXT="${CONTEXT:-k3d-teknoir-dev}"
SYS_NS=teknoir-system
HUB_NS=teknoir-ztna
TS=rbac-ts              # the teamspace that has the RoleBinding
TS_OTHER=rbac-ts-other  # a namespace without it
SA=system:serviceaccount:${SYS_NS}:backstage-api
IMG_TAG="sha-0123abcd@sha256:3333333333333333333333333333333333333333333333333333333333333333"

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

"${KC[@]}" version >/dev/null 2>&1 || { echo "cluster ${CONTEXT} is not reachable" >&2; exit 2; }
if "${KC[@]}" get clusterrole backstage-api-resources-role >/dev/null 2>&1 || "${KC[@]}" get ns "$TS" >/dev/null 2>&1; then
  echo "refusing: ${CONTEXT} already has backstage-api-resources-role or namespace ${TS} (a leftover of an earlier run, or a real install)" >&2
  exit 2
fi

CRDS=()   # CRDs this run installed (removed again)
cleanup() {
  [[ -f "$TMP/rbac.yaml" ]] && "${KC[@]}" delete -f "$TMP/rbac.yaml" --ignore-not-found --timeout=90s >/dev/null 2>&1
  "${KC[@]}" delete namespace "$TS" "$TS_OTHER" "${TS}-vdev" --ignore-not-found --timeout=90s >/dev/null 2>&1
  # the namespaces this run created for the hub and the TURN secret (only if they did not exist before)
  for n in "${CREATED_NS[@]:-}"; do [[ -n $n ]] && "${KC[@]}" delete namespace "$n" --ignore-not-found --timeout=90s >/dev/null 2>&1; done
  for c in "${CRDS[@]:-}"; do [[ -n $c ]] && "${KC[@]}" delete crd "$c" --ignore-not-found --timeout=90s >/dev/null 2>&1; done
  rm -rf "$TMP"
}
CREATED_NS=()
trap cleanup EXIT

echo "== context ${CONTEXT}"
# ---- setup: CRDs (so resource names resolve), namespaces, the rendered RBAC, a hand-made teknoir-portal -----------
for f in "${CHARTS}"/device-controller/crds/*.yaml "${CHARTS}"/devstudio-controller/crds/*.yaml \
         "${CHARTS}"/notebook-controller/crds/*.yaml "${CHARTS}"/profile-controller/crds/*.yaml "${CHARTS}"/user-controller/crds/*.yaml; do
  for name in $(grep -h -E '^  name: [a-z]+\.teknoir\.org$' "$f" | sed 's/^  name: //'); do
    "${KC[@]}" get crd "$name" >/dev/null 2>&1 || CRDS+=("$name")
  done
  "${KC[@]}" apply --server-side -f "$f" >/dev/null 2>&1 || { bad "applying CRDs from $f"; }
done
# Istio's VirtualService CRD, as a stub, so that the resource name resolves (the rule is about the name only)
if ! "${KC[@]}" get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
  "${KC[@]}" apply -f - >/dev/null <<'CRD' && CRDS+=(virtualservices.networking.istio.io)
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: virtualservices.networking.istio.io}
spec:
  group: networking.istio.io
  scope: Namespaced
  names: {kind: VirtualService, plural: virtualservices, singular: virtualservice}
  versions:
    - name: v1
      served: true
      storage: true
      schema: {openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}}
CRD
fi
for n in "$SYS_NS" "$HUB_NS" stunner-system "$TS" "$TS_OTHER" "${TS}-vdev"; do
  "${KC[@]}" get ns "$n" >/dev/null 2>&1 || { "${KC[@]}" create ns "$n" >/dev/null && CREATED_NS+=("$n"); }
done

# the same templates the Applications render: backstage (name backstage, namespace teknoir-system) and ztna
helm template backstage "${CHARTS}/backstage" --namespace "$SYS_NS" -s templates/rbac.yaml > "$TMP/rbac.yaml" || { echo "helm template backstage failed" >&2; exit 2; }
helm template ztna "${CHARTS}/ztna" --namespace "$HUB_NS" --set hub.image.tag="$IMG_TAG" -s templates/rbac.yaml >> "$TMP/rbac.yaml" || { echo "helm template ztna failed" >&2; exit 2; }
"${KC[@]}" apply -f "$TMP/rbac.yaml" >/dev/null || { echo "applying the rendered RBAC failed" >&2; exit 2; }
# what profile-controller writes into a teamspace it owns
"${KC[@]}" -n "$TS" create rolebinding teknoir-portal --clusterrole=backstage-api-teamspace --serviceaccount="${SYS_NS}:backstage-api" >/dev/null \
  || { echo "creating the teknoir-portal RoleBinding failed" >&2; exit 2; }
ok "rendered RBAC applied, teknoir-portal bound in ${TS} only"

# ---- the matrix ----------------------------------------------------------------------------------------------------
# can <yes|no> <verb> <resource> [kubectl args...]: kubectl auth can-i as the API service account
can() {
  local want=$1 verb=$2 res=$3; shift 3
  local out; out=$("${KC[@]}" auth can-i "$verb" "$res" "$@" --as="$SA" 2>/dev/null | tail -1)
  [[ "$out" == "$want" ]] && ok "$want  $verb $res $*" || bad "expected $want, got '${out}': $verb $res $*"
}

echo "== yes: what the Backstage backend calls"
# teamspace (RoleBinding teknoir-portal)
can yes get devices.teknoir.org -n "$TS"
can yes list devices.teknoir.org -n "$TS"
can yes patch devices.teknoir.org -n "$TS"
can yes create robots.teknoir.org -n "$TS"
can yes create robottypes.teknoir.org -n "$TS"
can yes update deviceapplicationsets.teknoir.org -n "$TS"
can yes delete devstudios.teknoir.org -n "$TS"
can yes create notebooks.teknoir.org -n "$TS"
can yes create claimsets.teknoir.org -n "$TS"
can yes get devices.teknoir.org/some-device --subresource=status -n "$TS"
can yes list virtualservices.networking.istio.io -n "$TS"
can no create virtualservices.networking.istio.io -n "$TS"
can yes create persistentvolumeclaims -n "$TS"
can yes delete persistentvolumeclaims -n "$TS"
can yes create configmaps -n "$TS"
can yes get configmaps/peripheral-config -n "$TS"
can yes update configmaps/peripheral-config -n "$TS"
can yes get secrets/mongodb-credentials -n "$TS"
can yes get secrets/emqx-bootstrap-user -n "$TS"
can yes create events -n "$TS"
can yes patch events -n "$TS"
can yes create localsubjectaccessreviews.authorization.k8s.io -n "$TS"
# cluster-wide
can yes list devices.teknoir.org -A
can yes list deviceapplicationsets.teknoir.org -A
can yes list claims.teknoir.org -n "$SYS_NS"
can yes list claimsets.teknoir.org -n "$SYS_NS"
can yes create profiles.teknoir.org
can yes delete profiles.teknoir.org
can yes list profiles.teknoir.org
can yes patch users.teknoir.org
can yes create users.teknoir.org
can yes get resourcequotas -n "${TS}-vdev"
can yes get deployments.apps -n "$HUB_NS"

echo "== no: it cannot become another identity, run code, read Secrets or change RBAC"
for ns in "$SYS_NS" "$HUB_NS" "$TS"; do
  can no impersonate serviceaccounts -n "$ns"
done
can no impersonate users
can no impersonate groups
can no create pods -n "$SYS_NS"
can no create pods -n "$TS"
can no create pods --subresource=exec -n "$TS"
can no create pods --subresource=exec -n "$HUB_NS"
can no get pods --subresource=log -n "$SYS_NS"
can no list pods -A
can no create deployments.apps -n "$SYS_NS"
can no update deployments.apps -n "$HUB_NS"
can no get deployments.apps -n "$SYS_NS"
can no get secrets -n "$HUB_NS"
can no list secrets -n stunner-system
can no list secrets -n "$TS"
can no list secrets -A
can no get secrets/other -n "$TS"
can no get secrets/stunner-auth-secret -n stunner-system
can no create secrets -n "$TS"
can no create rolebindings.rbac.authorization.k8s.io -n "$TS"
can no create roles.rbac.authorization.k8s.io -n "$TS"
can no bind clusterroles.rbac.authorization.k8s.io
can no escalate clusterroles.rbac.authorization.k8s.io
can no create clusterrolebindings.rbac.authorization.k8s.io
can no create serviceaccounts -n "$TS"
can no create serviceaccounts --subresource=token -n "$HUB_NS"
can no list namespaces
can no create namespaces
can no list nodes
can no get configmaps -n "$HUB_NS"
can no create configmaps -n "$HUB_NS"
can no update configmaps -n "$TS"      # other ConfigMap names: update is limited to peripheral-config
can no update configmaps/other -n "$TS"
can no delete configmaps -n "$TS"
can no create devices.teknoir.org -n "$HUB_NS"
can no create devices.teknoir.org -n "$SYS_NS"
can no update devices.teknoir.org -n "$SYS_NS"
can no delete persistentvolumeclaims -n harbor
can no create subjectaccessreviews.authorization.k8s.io
can no create tokenreviews.authentication.k8s.io
can no '*' '*' -n "$TS"
can no '*' '*' -A

echo "== no: outside a teamspace with the RoleBinding the teamspace role gives nothing (no ClusterRoleBinding)"
can no get devices.teknoir.org -n "$TS_OTHER" --subresource=status
can no create devices.teknoir.org -n "$TS_OTHER"
can no create robots.teknoir.org -n "$TS_OTHER"
can no patch devices.teknoir.org -n "$TS_OTHER"
can no create persistentvolumeclaims -n "$TS_OTHER"
can no get secrets/mongodb-credentials -n "$TS_OTHER"
can no create localsubjectaccessreviews.authorization.k8s.io -n "$TS_OTHER"
can no update configmaps/peripheral-config -n "$TS_OTHER"
can no create events -n "$TS_OTHER"
# read-only cluster-wide rights still apply everywhere, as designed
can yes list devices.teknoir.org -n "$TS_OTHER"
can no delete devices.teknoir.org -n "$TS_OTHER"

echo "== the old broad binding is gone, and nothing grants teknoir-admin or cluster-admin to the service account"
if "${KC[@]}" get clusterrolebinding backstage-api-teknoir-admin-rolebinding >/dev/null 2>&1; then
  bad "ClusterRoleBinding backstage-api-teknoir-admin-rolebinding exists"
else
  ok "ClusterRoleBinding backstage-api-teknoir-admin-rolebinding does not exist"
fi
cat > "$TMP/bindings.py" <<'PY'
import json, sys
for o in json.load(sys.stdin)["items"]:
    for s in o.get("subjects") or []:
        if s.get("kind") == "ServiceAccount" and s.get("name") == "backstage-api":
            ns = o["metadata"].get("namespace", "-")
            print(o["kind"], ns + "/" + o["metadata"]["name"], "->", o["roleRef"]["name"])
PY
bound=$("${KC[@]}" get clusterrolebinding,rolebinding -A -o json 2>/dev/null | python3 -I "$TMP/bindings.py" | sort)
expected=$'ClusterRoleBinding -/backstage-api-resources-rolebinding -> backstage-api-resources-role\nRoleBinding rbac-ts/teknoir-portal -> backstage-api-teamspace\nRoleBinding teknoir-ztna/backstage-api-hub-workloads -> backstage-api-hub-workloads'
[[ "$bound" == "$expected" ]] && ok "the service account has exactly three bindings" || bad "bindings of backstage-api: ${bound//$'\n'/ ; }"

echo
echo "${pass} passed, ${failn} failed"
[[ $failn -eq 0 ]]
