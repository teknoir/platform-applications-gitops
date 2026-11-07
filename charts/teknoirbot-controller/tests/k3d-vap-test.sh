#!/usr/bin/env bash
# Behavioural test of the ValidatingAdmissionPolicy teknoirbot-device-guard (templates/admission.yaml) on the LOCAL
# THROWAWAY cluster context k3d-teknoir-dev (any other context is refused). Repeatable: it creates the namespaces
# tb-vap-test (the teamspace) and tb-vap-sys (stands in for teknoir-system), the chart's ServiceAccount, ClusterRole,
# ClusterRoleBinding, VAP and binding, the Device CRD (only when the cluster lacks it), tests, and removes all of it again
# on exit.
#
# The bot's identity is impersonated (--as=system:serviceaccount:tb-vap-sys:teknoirbot-controller) and holds the chart's
# own ClusterRole, so a verdict is the policy's, not RBAC's. The admin (no --as) must be allowed everything.
#
#   charts/teknoirbot-controller/tests/k3d-vap-test.sh
#
# Needs: kubectl, helm, jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
CRD_FILE="$(cd "${CHART}/../device-controller/crds" && pwd)/devices.yaml"
CONTEXT=k3d-teknoir-dev
NS=tb-vap-test
SYS=tb-vap-sys
SA=teknoirbot-controller
POLICY=teknoirbot-device-guard

for t in kubectl helm jq; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
KC=(kubectl --context "$CONTEXT")
"${KC[@]}" get ns >/dev/null 2>&1 || { echo "context $CONTEXT is not reachable (k3d cluster start teknoir-dev)" >&2; exit 2; }
if "${KC[@]}" get validatingadmissionpolicy "$POLICY" >/dev/null 2>&1 \
  || "${KC[@]}" get clusterrole teknoirbot-controller >/dev/null 2>&1 \
  || "${KC[@]}" get ns "$NS" >/dev/null 2>&1 || "${KC[@]}" get ns "$SYS" >/dev/null 2>&1; then
  echo "refusing: $POLICY, ClusterRole teknoirbot-controller or a test namespace already exists on $CONTEXT" >&2
  exit 2
fi

TMP=$(mktemp -d)
pass=0; failn=0
installed_crd=0
ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }

cleanup() {
  "${KC[@]}" delete devices.teknoir.org --all -n "$NS" --wait=false >/dev/null 2>&1 || true
  "${KC[@]}" delete validatingadmissionpolicybinding "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete validatingadmissionpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete clusterrolebinding teknoirbot-controller --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete clusterrole teknoirbot-controller --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete ns "$NS" "$SYS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [[ $installed_crd == 1 ]] && "${KC[@]}" delete crd devices.teknoir.org --ignore-not-found >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- setup ----------------------------------------------------------------------------------------------------
"${KC[@]}" create ns "$NS" >/dev/null && "${KC[@]}" create ns "$SYS" >/dev/null || { echo "cannot create namespaces" >&2; exit 2; }
if ! "${KC[@]}" get crd devices.teknoir.org >/dev/null 2>&1; then
  "${KC[@]}" apply --server-side -f "$CRD_FILE" >/dev/null || { echo "cannot apply the Device CRD" >&2; exit 2; }
  installed_crd=1
  "${KC[@]}" wait --for=condition=Established crd/devices.teknoir.org --timeout=30s >/dev/null
fi
helm template teknoirbot-controller "$CHART" -n "$SYS" --set image.tag=v0@sha256:0000000000000000000000000000000000000000000000000000000000000000 > "$TMP/all.yaml" \
  || { echo "helm template failed" >&2; exit 2; }
# only the ServiceAccount, ClusterRole, ClusterRoleBinding, VAP and binding: split the documents and keep those kinds
python3 -I - "$TMP/all.yaml" "$TMP/apply.yaml" <<'PY'
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
keep = ("kind: ServiceAccount", "kind: ClusterRole\n", "kind: ClusterRoleBinding", "kind: ValidatingAdmissionPolicy")
out = [d for d in docs if any(("\n" + k) in ("\n" + d + "\n") for k in keep)]
open(sys.argv[2], "w").write("\n---\n".join(out))
PY
"${KC[@]}" apply -f "$TMP/apply.yaml" >/dev/null || { echo "cannot apply the chart objects" >&2; exit 2; }

BOT=(--as="system:serviceaccount:${SYS}:${SA}")

# device <name> <labelled 0|1> <device_type> <annotations-json> -> Device JSON
device() {
  jq -n --arg name "$1" --arg ns "$NS" --argjson lab "$2" --arg dt "$3" --argjson ann "$4" '
    {apiVersion: "teknoir.org/v1", kind: "Device",
     metadata: ({name: $name, namespace: $ns}
       + (if $lab == 1 then {labels: {"teknoir.org/teknoirbot": "bot", "teknoir.org/part-of": "teknoirbot", hardware: "virtual"}} else {} end)
       + (if ($ann | length) > 0 then {annotations: $ann} else {} end)),
     spec: ({device_type: $dt, keys: {data: {board: "dmlydHVhbA=="}}, manifest: {}}
       + (if $dt == "virtual" then {virtual: {cpu: "2", memory: "4Gi", disk: {size: "20Gi"}}} else {} end))}'
}

# expect allow|deny <description> <identity: bot|admin> <kubectl args...>   (stdin is passed through to kubectl)
expect() {
  local want=$1 desc=$2 id=$3; shift 3
  local who=(); [[ $id == bot ]] && who=("${BOT[@]}")
  local out rc
  out=$("${KC[@]}" "${who[@]}" "$@" 2>&1); rc=$?
  case "$want" in
    allow) [[ $rc -eq 0 ]] && ok "allow $desc" || bad "allow $desc (rc=$rc) ${out:0:300}" ;;
    deny)  [[ $rc -ne 0 && "$out" == *"ValidatingAdmissionPolicy '${POLICY}'"* ]] && ok "deny  $desc" || bad "deny  $desc (rc=$rc) ${out:0:300}" ;;
  esac
}

# ---- wait for the policy: a known-denied request, up to 30 s -----------------------------------------------------
active=0
for _ in $(seq 1 30); do
  out=$(device probe 0 virtual '{}' | "${KC[@]}" "${BOT[@]}" create --dry-run=server -f - 2>&1)
  [[ "$out" == *"ValidatingAdmissionPolicy '${POLICY}'"* ]] && { active=1; break; }
  sleep 1
done
[[ $active == 1 ]] && ok "policy is active" || { bad "policy is not active after 30 s: ${out:0:300}"; exit 1; }

# ---- the bot ---------------------------------------------------------------------------------------------------
expect allow "bot creates a labelled virtual Device"                     bot   create -f <(device tb-a 1 virtual '{}')
expect deny  "bot creates a Device without the label"                    bot   create -f <(device tb-nolabel 0 virtual '{}')
expect deny  "bot creates a non-virtual Device"                          bot   create -f <(device tb-jetson 1 jetson '{}')
expect deny  "bot creates a Device with a ztna annotation"               bot   create -f <(device tb-ztna 1 virtual '{"ztna.teknoir.org/wireguard":"enabled"}')
expect deny  "bot creates a Device with teknoir.org/disabled"            bot   create -f <(device tb-dis 1 virtual '{"teknoir.org/disabled":"true"}')
expect deny  "bot creates a Device with an org-tree annotation"          bot   create -f <(device tb-org 1 virtual '{"teknoir.org/org-tree-x":"y"}')
expect allow "bot creates a Device with the preset annotation"           bot   create -f <(device tb-preset 1 virtual '{"teknoir.org/virtual-preset":"teknoirbot"}')
expect allow "bot patches spec.virtual.cpu of its Device"                bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"virtual":{"cpu":"3"}}}'
# spec.desktop only exists in a Device CRD that has the desktop field; an older CRD prunes it, which still passes
expect allow "bot patches spec.desktop.geometry of its Device"           bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"desktop":{"geometry":"1920x1080"}}}'
expect allow "bot patches the preset annotation and a label"             bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"labels":{"hardware":"virtual"},"annotations":{"teknoir.org/virtual-preset":"teknoirbot"}}}'
expect deny  "bot patches spec.keys"                                     bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"keys":{"data":{"userpassword":"eHh4"}}}}'
expect deny  "bot adds teknoir.org/disabled"                             bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"annotations":{"teknoir.org/disabled":"true"}}}'
expect deny  "bot adds a ztna annotation"                                bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"enabled"}}}'
expect deny  "bot removes the teknoirbot label"                          bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"labels":{"teknoir.org/teknoirbot":null}}}'

# a platform annotation that an admin set stays untouchable (change and removal), while the rest stays patchable
expect allow "admin sets ztna and disabled annotations on tb-a"          admin -n "$NS" annotate devices.teknoir.org tb-a ztna.teknoir.org/wireguard=enabled teknoir.org/disabled=true
expect deny  "bot changes an existing ztna annotation"                   bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"other"}}}'
expect deny  "bot removes an existing platform annotation"               bot   -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"metadata":{"annotations":{"teknoir.org/disabled":null}}}'
expect allow "bot patches cpu while platform annotations stay as they are" bot -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"virtual":{"cpu":"4"}}}'

# a Device an admin created without the label
expect allow "admin creates a Device without the label"                  admin create -f <(device plain 0 virtual '{}')
expect deny  "bot patches a Device that an admin created"                bot   -n "$NS" patch devices.teknoir.org plain --type=merge -p '{"spec":{"virtual":{"cpu":"3"}}}'

# ---- the admin is allowed everything above ----------------------------------------------------------------------
expect allow "admin creates a Device without the label (2)"              admin create -f <(device admin-nolabel 0 virtual '{}')
expect allow "admin creates a non-virtual Device"                        admin create -f <(device admin-jetson 0 jetson '{}')
expect allow "admin creates a Device with a ztna annotation"             admin create -f <(device admin-ztna 0 virtual '{"ztna.teknoir.org/wireguard":"enabled"}')
expect allow "admin patches spec.keys of a bot's Device"                 admin -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"keys":{"data":{"userpassword":"eHh4"}}}}'
expect allow "admin patches spec.desktop.geometry"                       admin -n "$NS" patch devices.teknoir.org tb-a --type=merge -p '{"spec":{"desktop":{"geometry":"1280x800"}}}'
expect allow "admin adds teknoir.org/disabled to a Device"               admin -n "$NS" annotate devices.teknoir.org plain teknoir.org/disabled=true
expect allow "admin patches the Device without the label"                admin -n "$NS" patch devices.teknoir.org plain --type=merge -p '{"spec":{"virtual":{"cpu":"3"}}}'
expect allow "admin removes the teknoirbot label"                        admin -n "$NS" label devices.teknoir.org tb-preset teknoir.org/teknoirbot-

echo "----"
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
