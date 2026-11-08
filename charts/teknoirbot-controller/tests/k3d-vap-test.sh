#!/usr/bin/env bash
# Behavioural test of the ValidatingAdmissionPolicy teknoirbot-device-guard (templates/admission.yaml) on the LOCAL
# THROWAWAY cluster context k3d-teknoir-dev (any other context is refused). Repeatable: it creates the namespaces
# tb-vap-test (the teamspace) and tb-vap-sys (stands in for teknoir-system), the chart's ServiceAccount, ClusterRole,
# ClusterRoleBinding, VAP and binding, the Device CRD (only when the cluster lacks it), tests, and removes all of it again
# on exit.
#
# The bot's identity is impersonated (--as=system:serviceaccount:tb-vap-sys:teknoirbot-controller) and holds the chart's
# own ClusterRole, so a verdict is the policy's, not RBAC's. A second ServiceAccount (tb-other) holds the same ClusterRole
# and must be unaffected. The admin (no --as) must be allowed everything.
#
# The Device CRD must have spec.desktop (the file of charts/device-controller, or the path in $1): a CRD without it prunes
# the field silently and the desktop cases would test nothing, so the test fails then. The TeknoirBot CRD of this chart is
# installed too (a Device is created with a controller ownerReference to a real TeknoirBot, or the garbage collector
# deletes it); both CRDs are removed again only when this run installed them.
#
#   charts/teknoirbot-controller/tests/k3d-vap-test.sh [device-crd-file]
#
# Needs: kubectl, helm, jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
CRD_FILE="${1:-$(cd "${CHART}/../device-controller/crds" && pwd)/devices.yaml}"
TB_CRD="${CHART}/crds/teknoir.org_teknoirbots.yaml"
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
  || "${KC[@]}" get clusterrolebinding teknoirbot-other >/dev/null 2>&1 \
  || "${KC[@]}" get ns "$NS" >/dev/null 2>&1 || "${KC[@]}" get ns "$SYS" >/dev/null 2>&1; then
  echo "refusing: $POLICY, ClusterRole teknoirbot-controller or a test namespace already exists on $CONTEXT" >&2
  exit 2
fi

TMP=$(mktemp -d)
pass=0; failn=0
installed_crd=0; installed_tb=0
ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }

cleanup() {
  # the admin may have left finalizers on Devices
  for d in $("${KC[@]}" get devices.teknoir.org -n "$NS" -o name 2>/dev/null); do
    "${KC[@]}" -n "$NS" patch "$d" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  "${KC[@]}" delete devices.teknoir.org --all -n "$NS" --wait=false >/dev/null 2>&1 || true
  "${KC[@]}" delete teknoirbots.teknoir.org --all -n "$NS" --wait=false >/dev/null 2>&1 || true
  "${KC[@]}" delete validatingadmissionpolicybinding "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete validatingadmissionpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete clusterrolebinding teknoirbot-controller teknoirbot-other --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete clusterrole teknoirbot-controller --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete ns "$NS" "$SYS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  [[ $installed_crd == 1 ]] && "${KC[@]}" delete crd devices.teknoir.org --ignore-not-found >/dev/null 2>&1
  [[ $installed_tb == 1 ]] && "${KC[@]}" delete crd teknoirbots.teknoir.org --ignore-not-found >/dev/null 2>&1
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
if ! "${KC[@]}" get crd teknoirbots.teknoir.org >/dev/null 2>&1; then
  "${KC[@]}" apply --server-side -f "$TB_CRD" >/dev/null || { echo "cannot apply the TeknoirBot CRD" >&2; exit 2; }
  installed_tb=1
  "${KC[@]}" wait --for=condition=Established crd/teknoirbots.teknoir.org --timeout=30s >/dev/null
fi
desktop_type=$("${KC[@]}" get crd devices.teknoir.org -o jsonpath='{.spec.versions[?(@.name=="v1")].schema.openAPIV3Schema.properties.spec.properties.desktop.type}')
if [[ $desktop_type != object ]]; then
  echo "Device CRD prunes spec.desktop: refresh charts/device-controller/crds/devices.yaml from device-controller (or pass a desktop-capable CRD file as \$1)" >&2
  exit 2
fi
helm template teknoirbot-controller "$CHART" -n "$SYS" --set image.tag=v0@sha256:0000000000000000000000000000000000000000000000000000000000000000 > "$TMP/all.yaml" \
  || { echo "helm template failed" >&2; exit 2; }
# only the ServiceAccount, ClusterRole, ClusterRoleBinding, VAP and binding: split the documents and keep those kinds
python3 -I - "$TMP/all.yaml" "$TMP/apply.yaml" <<'PY'
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
keep = ("kind: ServiceAccount", "kind: ClusterRole\n", "kind: ClusterRoleBinding", "kind: ValidatingAdmissionPolicy")
# of the policies only teknoirbot-device-guard (the fence has its own test, k3d-fence-test.sh)
out = [d for d in docs if any(("\n" + k) in ("\n" + d + "\n") for k in keep)
       and ("kind: ValidatingAdmissionPolicy" not in d or "\n  name: teknoirbot-device-guard\n" in d or "policyName: teknoirbot-device-guard" in d)]
open(sys.argv[2], "w").write("\n---\n".join(out))
PY
"${KC[@]}" apply -f "$TMP/apply.yaml" >/dev/null || { echo "cannot apply the chart objects" >&2; exit 2; }

# a second identity with the SAME ClusterRole (stands in for any other ServiceAccount that writes Devices)
"${KC[@]}" -n "$SYS" create sa tb-other >/dev/null
"${KC[@]}" create clusterrolebinding teknoirbot-other --clusterrole=teknoirbot-controller --serviceaccount="$SYS:tb-other" >/dev/null

BOT=(--as="system:serviceaccount:${SYS}:${SA}")
OTHER=(--as="system:serviceaccount:${SYS}:tb-other")

# the TeknoirBots the Devices are owned by, created by the admin (real uids: the garbage collector deletes Devices whose
# owner does not resolve)
for b in bot scout a preset own unit; do
  "${KC[@]}" -n "$NS" apply -f - >/dev/null <<EOF || { echo "cannot create TeknoirBot $b" >&2; exit 2; }
apiVersion: teknoir.org/v1alpha1
kind: TeknoirBot
metadata: {name: $b}
spec: {}
EOF
done
BOTUID=$("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org bot -o jsonpath='{.metadata.uid}')
SCOUTUID=$("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org scout -o jsonpath='{.metadata.uid}')
declare -A UIDS
for b in bot scout a preset own unit; do UIDS[$b]=$("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org "$b" -o jsonpath='{.metadata.uid}'); done

# device <name> <labelled 0|1> <device_type> <annotations-json> [owned 0|1 (default: owned when labelled)] -> Device JSON
# A labelled body carries a controller ownerReference to the TeknoirBot it is named after (tb-<bot>, one of UIDS; else "bot").
device() {
  local b=${1#tb-}; [[ -n ${UIDS[$b]:-} ]] || b=bot
  jq -n --arg name "$1" --arg ns "$NS" --argjson lab "$2" --arg dt "$3" --argjson ann "$4" --arg bot "$b" --arg uid "${UIDS[$b]}" --argjson own "${5:-$2}" '
    {apiVersion: "teknoir.org/v1", kind: "Device",
     metadata: ({name: $name, namespace: $ns}
       + (if $lab == 1 then {labels: {"teknoir.org/teknoirbot": $bot, "teknoir.org/part-of": "teknoirbot", hardware: "virtual"}} else {} end)
       + (if $own == 1 then {ownerReferences: [{apiVersion: "teknoir.org/v1alpha1", kind: "TeknoirBot", name: $bot, uid: $uid, controller: true, blockOwnerDeletion: true}]} else {} end)
       + (if ($ann | length) > 0 then {annotations: $ann} else {} end)),
     spec: ({device_type: $dt, keys: {data: {board: "dmlydHVhbA=="}}, manifest: {}}
       + (if $dt == "virtual" then {virtual: {cpu: "2", memory: "4Gi", disk: {size: "20Gi"}}} else {} end))}'
}
# the exact desiredDevice() body of the controller (internal/controller/device.go); the 3rd argument is merged into spec
desired() { # <name> [extra-spec-json]
  local extra=${2:-}; [[ -n $extra ]] || extra='{}'
  jq -n --arg name "$1" --arg ns "$NS" --arg uid "$SCOUTUID" --argjson extra "$extra" '
    {apiVersion: "teknoir.org/v1", kind: "Device",
     metadata: {name: $name, namespace: $ns,
       labels: {"teknoir.org/teknoirbot": "scout", hardware: "virtual", "teknoir.org/device-kind": "virtual", "teknoir.org/part-of": "teknoirbot"},
       annotations: {"teknoir.org/virtual-preset": "teknoirbot"},
       ownerReferences: [{apiVersion: "teknoir.org/v1alpha1", kind: "TeknoirBot", name: "scout", uid: $uid, controller: true, blockOwnerDeletion: true}]},
     spec: ({device_type: "virtual",
       keys: {data: {board: "dmlydHVhbA==", username: "dGVrbm9pcg==", userpassword: "cGFzc3dvcmQ="}},
       manifest: {}, virtual: {cpu: "2", memory: "4Gi", disk: {size: "20Gi"}},
       desktop: {mode: "virtual", geometry: "1280x800"}} + $extra)}'
}

# expect allow|deny <description> <identity: bot|other|admin> [message-substring (deny only)] -- <kubectl args...>
# A deny passes only when the output names this policy AND the substring of the rule that must have fired, and has no
# CEL runtime error ("resulted in error": with failurePolicy Fail a broken rule would otherwise look like a denial).
expect() {
  local want=$1 desc=$2 id=$3 msg=""; shift 3
  if [[ $1 != -- ]]; then msg=$1; shift; fi
  shift
  local who=()
  case $id in bot) who=("${BOT[@]}");; other) who=("${OTHER[@]}");; esac
  local out rc
  out=$("${KC[@]}" "${who[@]}" "$@" 2>&1); rc=$?
  case "$want" in
    allow) [[ $rc -eq 0 ]] && ok "allow $desc" || bad "allow $desc (rc=$rc) ${out:0:400}" ;;
    deny)
      if [[ $rc -ne 0 && "$out" == *"ValidatingAdmissionPolicy '${POLICY}'"* && "$out" == *"$msg"* && "$out" != *"resulted in error"* ]]; then
        ok "deny  $desc"
      else
        bad "deny  $desc (rc=$rc, wanted \"$msg\") ${out:0:400}"
      fi ;;
  esac
}

# geometry <expected> <description>: the Device CRD must store spec.desktop.geometry (read back from tb-a)
geometry() {
  local g; g=$("${KC[@]}" -n "$NS" get devices.teknoir.org "${3:-tb-a}" -o jsonpath='{.spec.desktop.geometry}')
  [[ $g == "$1" ]] && ok "$2 (stored: $g)" || bad "$2 (read back '$g', wanted '$1')"
}

# ---- wait for the policy: a known-denied request, up to 30 s -----------------------------------------------------
active=0
for _ in $(seq 1 30); do
  out=$(device probe 0 virtual '{}' | "${KC[@]}" "${BOT[@]}" create --dry-run=server -f - 2>&1)
  [[ "$out" == *"ValidatingAdmissionPolicy '${POLICY}'"* ]] && { active=1; break; }
  sleep 1
done
[[ $active == 1 ]] && ok "policy is active" || { bad "policy is not active after 30 s: ${out:0:300}"; exit 1; }

P=(-n "$NS" patch devices.teknoir.org)
MERGE=(--type=merge -p)

# ---- the controller's own flows ------------------------------------------------------------------------------------
expect allow "bot creates the exact desiredDevice body (owner ref, 4 labels, preset, desktop)" bot -- create -f <(desired tb-scout)
expect allow "bot ownedPatch: labels + preset + virtual cpu/memory/disabled + desktop mode/geometry" bot -- "${P[@]}" tb-scout "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":"scout","hardware":"virtual","teknoir.org/device-kind":"virtual","teknoir.org/part-of":"teknoirbot"},"annotations":{"teknoir.org/virtual-preset":"teknoirbot"}},"spec":{"virtual":{"cpu":"3","memory":"6Gi","disabled":true},"desktop":{"mode":"virtual","geometry":"1920x1080"}}}'
geometry 1920x1080 "the ownedPatch stored spec.desktop.geometry" tb-scout
expect allow "bot un-suspends (virtual.disabled false)"                  bot   -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"virtual":{"disabled":false}}}'
expect allow "bot patches spec.manifest to the same value (a no-op)"     bot   -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"manifest":{}}}'
expect allow "bot creates a labelled virtual Device"                     bot   -- create -f <(device tb-a 1 virtual '{}')
expect allow "bot creates a Device with the preset annotation"           bot   -- create -f <(device tb-preset 1 virtual '{"teknoir.org/virtual-preset":"teknoirbot"}')
expect allow "bot patches spec.virtual.cpu of its Device"                bot   -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"3"}}}'
expect allow "bot patches spec.desktop.geometry of its Device"           bot   -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"desktop":{"mode":"virtual","geometry":"1920x1080"}}}'
geometry 1920x1080 "spec.desktop.geometry of tb-a"
expect allow "bot patches the preset annotation and a label"             bot   -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"hardware":"virtual"},"annotations":{"teknoir.org/virtual-preset":"teknoirbot"}}}'

# the bot's org unit: the two placement keys, copied from the TeknoirBot, at create and afterwards
ORG='{"teknoir.org/org-tree-path":"se/karlstad","teknoir.org/org-tree-node-id":"karlstad"}'
expect allow "bot creates a Device with the two placement annotations"   bot   -- create -f <(device tb-unit 1 virtual "$ORG")
expect allow "bot changes the placement annotations of its Device"       bot   -- "${P[@]}" tb-unit "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/org-tree-path":"se/north/karlstad"}}}'
expect allow "bot removes the placement annotations of its Device"       bot   -- "${P[@]}" tb-unit "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/org-tree-path":null,"teknoir.org/org-tree-node-id":null}}}'
expect allow "bot adds teknoir.org/org-tree-node-id to its Device"       bot   -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/org-tree-node-id":"n"}}}'

# device-controller (stood in for by the admin) writes spec.keys, spec.manifest and finalizers; the bot stays able to patch
expect allow "admin (as device-controller) changes spec.keys"            admin -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"keys":{"data":{"rsa_private":"eHh4"}}}}'
expect allow "admin (as device-controller) writes spec.manifest.apps and a finalizer" admin -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"finalizers":["x.example/y"]},"spec":{"manifest":{"apps":{"k":{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"k"}}}}}}'
expect allow "bot patches cpu after someone else changed spec.keys"      bot   -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"2"}}}'
expect allow "bot patches desktop geometry and cpu next to manifest.apps and a finalizer" bot -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"4"},"desktop":{"mode":"virtual","geometry":"1280x800"}}}'
geometry 1280x800 "spec.desktop.geometry after the device-controller write"
expect allow "admin removes the finalizer again"                         admin -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"finalizers":null}}'

# ---- denials: the intended rule fires, not a CEL error ---------------------------------------------------------------
expect deny  "bot creates a Device without the label"                    bot   "non-empty label" -- create -f <(device tb-nolabel 0 virtual '{}')
expect deny  "bot creates a non-virtual Device"                          bot   "virtual Devices" -- create -f <(device tb-jetson 1 jetson '{}')
expect deny  "bot creates a Device with a ztna annotation"               bot   "platform annotations" -- create -f <(device tb-ztna 1 virtual '{"ztna.teknoir.org/wireguard":"enabled"}')
expect deny  "bot creates a Device with teknoir.org/disabled"            bot   "platform annotations" -- create -f <(device tb-dis 1 virtual '{"teknoir.org/disabled":"true"}')
expect deny  "bot creates a Device with an org-tree annotation"          bot   "platform annotations" -- create -f <(device tb-org 1 virtual '{"teknoir.org/org-tree-x":"y"}')
expect deny  "bot creates with an empty teknoirbot label"                bot   "non-empty label" -- create -f <(device tb-empty 0 virtual '{}' | jq '.metadata.labels={"teknoir.org/teknoirbot":"","teknoir.org/part-of":"teknoirbot"}')
expect deny  "bot patches spec.keys"                                     bot   "spec.keys" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"keys":{"data":{"userpassword":"eHh4"}}}}'
expect deny  "bot patches spec.keys.stringData"                          bot   "spec.keys" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"keys":{"stringData":{"a":"b"}}}}'
expect deny  "bot removes a key from spec.keys.data"                     bot   "spec.keys" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"keys":{"data":{"board":null}}}}'
expect deny  "bot adds teknoir.org/disabled"                             bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled":"true"}}}'
expect deny  "bot adds a ztna annotation"                                bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"enabled"}}}'
expect deny  "bot adds teknoir.org/disabled-by"                          bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled-by":"me"}}}'
expect deny  "bot adds another org-tree annotation (teknoir.org/org-tree-x)" bot "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/org-tree-x":"n"}}}'
expect deny  "bot adds the bot key's verifier annotation"                 bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/teknoirbot-key-sha256":"00"}}}'
expect deny  "bot creates a Device with the bot key's verifier annotation" bot "platform annotations" -- create -f <(device tb-key 1 virtual '{"teknoir.org/teknoirbot-key-sha256":"00"}')
expect allow "bot writes the creator and access annotations of its Device" bot  -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/teknoirbot-created-by":"a@example.com","teknoir.org/teknoirbot-access":"read"}}}'
expect deny  "bot creates with the placement keys and teknoir.org/org-tree-x" bot "platform annotations" -- create -f <(device tb-org2 1 virtual '{"teknoir.org/org-tree-path":"a","teknoir.org/org-tree-x":"y"}')
expect deny  "bot removes the teknoir.org/part-of label"                 bot   "non-empty label" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/part-of":null}}}'
expect deny  "bot removes the teknoirbot label"                          bot   "non-empty label" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":null}}}'

# rules 6-8: the fields that make device-controller run workloads, ownerReferences and finalizers
APPS='{"x":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"x"}}}'
expect deny  "bot creates with spec.manifest.apps"                       bot   "empty spec.manifest" -- create -f <(desired tb-m1 "{\"manifest\":{\"apps\":$APPS}}")
expect deny  "bot creates with spec.applications"                        bot   "empty spec.manifest" -- create -f <(desired tb-m2 '{"applications":[{"repo_url":"https://example.com/evil.git"}]}')
expect deny  "bot creates with spec.plugins"                             bot   "empty spec.manifest" -- create -f <(desired tb-m3 '{"plugins":[{"apiVersion":"x/v1","kind":"Y","spec":{}}]}')
expect deny  "bot creates with spec.overrides"                           bot   "empty spec.manifest" -- create -f <(desired tb-m4 '{"overrides":{"revision":"main"}}')
expect deny  "bot creates a labelled Device without an ownerReference"   bot   "controller reference to the TeknoirBot" -- create -f <(device tb-noowner 1 virtual '{}' 0)
expect deny  "bot creates with an owner reference to another TeknoirBot" bot   "controller reference to the TeknoirBot" -- create -f <(desired tb-wrongowner | jq '.metadata.ownerReferences[0].name="bot"')
expect deny  "bot patches spec.manifest.apps of its Device"              bot   "may not change spec.manifest" -- "${P[@]}" tb-scout "${MERGE[@]}" "{\"spec\":{\"manifest\":{\"apps\":$APPS}}}"
expect deny  "bot patches spec.applications of its Device"               bot   "may not change spec.manifest" -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"applications":[{"repo_url":"https://example.com/evil.git"}]}}'
expect deny  "bot patches spec.plugins of its Device"                    bot   "may not change spec.manifest" -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"plugins":[{"apiVersion":"x/v1","kind":"Y","spec":{}}]}}'
expect deny  "bot removes the ownerReferences"                           bot   "may not change spec.manifest" -- "${P[@]}" tb-scout "${MERGE[@]}" '{"metadata":{"ownerReferences":null}}'
expect deny  "bot adds a finalizer"                                      bot   "may not change spec.manifest" -- "${P[@]}" tb-scout "${MERGE[@]}" '{"metadata":{"finalizers":["x.example/y"]}}'

# a platform annotation that an admin set stays untouchable (change and removal), while the rest stays patchable
expect allow "admin sets ztna and disabled annotations on tb-a"          admin -- -n "$NS" annotate devices.teknoir.org tb-a ztna.teknoir.org/wireguard=enabled teknoir.org/disabled=true
expect deny  "bot changes an existing ztna annotation"                   bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"other"}}}'
expect allow "admin sets the bot key's verifier annotation on tb-a"        admin -- -n "$NS" annotate devices.teknoir.org tb-a teknoir.org/teknoirbot-key-sha256=abc
expect deny  "bot changes the bot key's verifier annotation"              bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/teknoirbot-key-sha256":"def"}}}'
expect deny  "bot removes the bot key's verifier annotation"              bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/teknoirbot-key-sha256":null}}}'
expect deny  "bot removes an existing platform annotation"               bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled":null}}}'
expect deny  "bot drops all annotations (annotations: null)"             bot   "platform annotations" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":null}}'
expect deny  "bot replaces all annotations with only the preset (json patch)" bot "platform annotations" -- "${P[@]}" tb-a --type=json -p '[{"op":"replace","path":"/metadata/annotations","value":{"teknoir.org/virtual-preset":"teknoirbot"}}]'
expect allow "bot patches cpu while platform annotations stay as they are" bot -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"4"}}}'

# ---- Devices that are not a bot's: no takeover -----------------------------------------------------------------------
expect allow "admin creates a Device without the label (plain)"          admin -- create -f <(device plain 0 virtual '{}')
expect deny  "bot patches a Device that an admin created"                bot   "non-empty label" -- "${P[@]}" plain "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"3"}}}'
expect deny  "bot takes over plain: adds both labels"                    bot   "not a TeknoirBot" -- "${P[@]}" plain "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":"bot","teknoir.org/part-of":"teknoirbot"}}}'
expect deny  "bot takes over plain: labels plus an ownerReference in one patch" bot "not a TeknoirBot" -- "${P[@]}" plain "${MERGE[@]}" "{\"metadata\":{\"labels\":{\"teknoir.org/teknoirbot\":\"bot\",\"teknoir.org/part-of\":\"teknoirbot\"},\"ownerReferences\":[{\"apiVersion\":\"teknoir.org/v1alpha1\",\"kind\":\"TeknoirBot\",\"name\":\"bot\",\"uid\":\"$BOTUID\",\"controller\":true,\"blockOwnerDeletion\":true}]}}"

# the label of a bot's own Device is lost: the controller must be able to restore it (it owns the Device by reference)
expect allow "bot creates tb-own (labelled, owner-referenced)"           bot   -- create -f <(device tb-own 1 virtual '{}')
expect allow "admin removes the teknoirbot label from tb-own"            admin -- -n "$NS" label devices.teknoir.org tb-own teknoir.org/teknoirbot-
expect deny  "bot patches tb-own without restoring the label"            bot   "non-empty label" -- "${P[@]}" tb-own "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"3"}}}'
expect allow "bot restores the label of its owner-referenced Device"     bot   -- "${P[@]}" tb-own "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":"own"}}}'

# the name is tied to the label on every write (rule 9): no Device named after one bot with the label of another
D9="only as tb-<bot>"
expect deny  "bot creates cam-07 labelled and owned for TeknoirBot scout" bot  "$D9" -- create -f <(desired cam-07)
expect deny  "bot relabels tb-scout to another bot"                      bot   "$D9" -- "${P[@]}" tb-scout "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":"bot"}}}'
expect allow "admin removes the teknoirbot label from tb-own again"      admin -- -n "$NS" label devices.teknoir.org tb-own teknoir.org/teknoirbot-
expect deny  "bot restores tb-own's label with another bot's name"       bot   "$D9" -- "${P[@]}" tb-own "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":"scout"}}}'

# ---- a second ServiceAccount with the same ClusterRole is not evaluated ------------------------------------------------
expect allow "other SA creates an unlabelled non-virtual Device with a ztna annotation" other -- create -f <(device o1 0 jetson '{"ztna.teknoir.org/wireguard":"enabled"}')
expect allow "other SA patches spec.keys of a bot's Device"              other -- "${P[@]}" tb-scout "${MERGE[@]}" '{"spec":{"keys":{"data":{"x":"eHh4"}}}}'
expect allow "other SA patches spec.manifest.apps of a bot's Device"     other -- "${P[@]}" tb-scout "${MERGE[@]}" "{\"spec\":{\"manifest\":{\"apps\":$APPS}}}"

# ---- the admin is allowed everything above ----------------------------------------------------------------------
expect allow "admin creates a Device without the label (2)"              admin -- create -f <(device admin-nolabel 0 virtual '{}')
expect allow "admin creates a non-virtual Device"                        admin -- create -f <(device admin-jetson 0 jetson '{}')
expect allow "admin creates a Device with a ztna annotation"             admin -- create -f <(device admin-ztna 0 virtual '{"ztna.teknoir.org/wireguard":"enabled"}')
expect allow "admin patches spec.keys of a bot's Device"                 admin -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"keys":{"data":{"userpassword":"eHh4"}}}}'
expect allow "admin patches spec.desktop.geometry"                       admin -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"desktop":{"mode":"virtual","geometry":"1280x800"}}}'
geometry 1280x800 "admin stored spec.desktop.geometry"
expect allow "admin adds teknoir.org/disabled to a Device"               admin -- -n "$NS" annotate devices.teknoir.org plain teknoir.org/disabled=true
expect allow "admin patches the Device without the label"                admin -- "${P[@]}" plain "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"3"}}}'
expect allow "admin removes the teknoirbot label"                        admin -- -n "$NS" label devices.teknoir.org tb-preset teknoir.org/teknoirbot-

echo "----"
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
