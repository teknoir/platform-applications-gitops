#!/usr/bin/env bash
# Behavioural test of the bot fence (templates/fence.yaml): the ValidatingAdmissionPolicies teknoirbot-device-fence and
# teknoirbot-created-by, together with teknoirbot-device-guard, on the LOCAL THROWAWAY cluster context k3d-teknoir-dev (any
# other context is refused). Repeatable: it creates the namespace tb-fence-test (the teamspace), a scratch ClusterRole
# tb-fence-test and its binding (full CRUD on Devices and TeknoirBots for every impersonated identity, so only the
# policies decide), the three policies and their bindings, the Device and TeknoirBot CRDs (only when the cluster lacks
# them), runs the cases and removes all of it again on exit.
#
# Identities are impersonated (kubectl --as=<user> [--as-group=<group>]); the admin (no --as) is system:masters.
#
#   charts/teknoirbot-controller/tests/k3d-fence-test.sh [device-crd-file]
#
# Needs: kubectl, helm, jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
CRD_FILE="${1:-$(cd "${CHART}/../device-controller/crds" && pwd)/devices.yaml}"
TB_CRD="${CHART}/crds/teknoir.org_teknoirbots.yaml"
CONTEXT=k3d-teknoir-dev
NS=tb-fence-test
SYS=teknoir-system          # the release namespace the identities below belong to (no such namespace is needed)
ROLE=tb-fence-test
POLICIES=(teknoirbot-device-guard teknoirbot-device-fence teknoirbot-created-by)

U_CTRL="system:serviceaccount:${SYS}:teknoirbot-controller"
U_DC="system:serviceaccount:teknoir-system:device-controller-service-account"
U_BS="system:serviceaccount:teknoir-system:backstage-api"
U_ARGO="system:serviceaccount:teknoir-system:argocd-application-controller"
U_GC="system:serviceaccount:kube-system:generic-garbage-collector"
U_NSC="system:serviceaccount:kube-system:namespace-controller"
U_KCM="system:kube-controller-manager"
U_EDIT="system:serviceaccount:${NS}:default-editor"
U_MASTER="tb-fence-masters"   # any user in the group system:masters

for t in kubectl helm jq; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
KC=(kubectl --context "$CONTEXT")
"${KC[@]}" get ns >/dev/null 2>&1 || { echo "context $CONTEXT is not reachable (k3d cluster start teknoir-dev)" >&2; exit 2; }
for p in "${POLICIES[@]}"; do
  if "${KC[@]}" get validatingadmissionpolicy "$p" >/dev/null 2>&1; then
    echo "refusing: policy $p already exists on $CONTEXT" >&2; exit 2
  fi
done
if "${KC[@]}" get clusterrole "$ROLE" >/dev/null 2>&1 || "${KC[@]}" get ns "$NS" >/dev/null 2>&1; then
  echo "refusing: ClusterRole/namespace $ROLE already exists on $CONTEXT" >&2; exit 2
fi

TMP=$(mktemp -d)
pass=0; failn=0
installed_crd=0; installed_tb=0
ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }

cleanup() {
  for b in $("${KC[@]}" get teknoirbots.teknoir.org -n "$NS" -o name 2>/dev/null); do
    "${KC[@]}" -n "$NS" patch "$b" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  for d in $("${KC[@]}" get devices.teknoir.org -n "$NS" -o name 2>/dev/null); do
    "${KC[@]}" -n "$NS" patch "$d" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  "${KC[@]}" delete devices.teknoir.org --all -n "$NS" --wait=false >/dev/null 2>&1 || true
  "${KC[@]}" delete teknoirbots.teknoir.org --all -n "$NS" --wait=false >/dev/null 2>&1 || true
  for p in "${POLICIES[@]}"; do
    "${KC[@]}" delete validatingadmissionpolicybinding "$p" --ignore-not-found >/dev/null 2>&1 || true
    "${KC[@]}" delete validatingadmissionpolicy "$p" --ignore-not-found >/dev/null 2>&1 || true
  done
  "${KC[@]}" delete clusterrolebinding "$ROLE" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete clusterrole "$ROLE" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete ns "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  [[ $installed_crd == 1 ]] && "${KC[@]}" delete crd devices.teknoir.org --ignore-not-found >/dev/null 2>&1
  [[ $installed_tb == 1 ]] && "${KC[@]}" delete crd teknoirbots.teknoir.org --ignore-not-found >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- setup ----------------------------------------------------------------------------------------------------
"${KC[@]}" create ns "$NS" >/dev/null || { echo "cannot create the namespace" >&2; exit 2; }
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
[[ $desktop_type == object ]] || { echo "Device CRD prunes spec.desktop: refresh charts/device-controller/crds/devices.yaml (or pass a desktop-capable CRD file as \$1)" >&2; exit 2; }

helm template teknoirbot-controller "$CHART" -n "$SYS" --set image.tag=v0@sha256:0000000000000000000000000000000000000000000000000000000000000000 > "$TMP/all.yaml" \
  || { echo "helm template failed" >&2; exit 2; }
# only the ValidatingAdmissionPolicies and their bindings: split the documents and keep those kinds
python3 -I - "$TMP/all.yaml" "$TMP/apply.yaml" <<'PY'
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
out = [d for d in docs if "\nkind: ValidatingAdmissionPolicy" in "\n" + d]
open(sys.argv[2], "w").write("\n---\n".join(out))
PY
"${KC[@]}" apply -f "$TMP/apply.yaml" >/dev/null || { echo "cannot apply the policies" >&2; exit 2; }

# a scratch role with full CRUD on Devices and TeknoirBots (and their status), bound to every impersonated identity
"${KC[@]}" create clusterrole "$ROLE" --verb='*' --resource=devices.teknoir.org,devices.teknoir.org/status,teknoirbots.teknoir.org,teknoirbots.teknoir.org/status >/dev/null \
  || { echo "cannot create the scratch ClusterRole" >&2; exit 2; }
args=(create clusterrolebinding "$ROLE" --clusterrole="$ROLE")
for u in "$U_CTRL" "$U_DC" "$U_BS" "$U_ARGO" "$U_GC" "$U_NSC" "$U_KCM" "$U_EDIT" "$U_MASTER"; do args+=(--user="$u"); done
"${KC[@]}" "${args[@]}" >/dev/null || { echo "cannot bind the scratch ClusterRole" >&2; exit 2; }

# the TeknoirBot "a" owns the Devices (a real uid: the garbage collector deletes Devices whose owner does not resolve)
bot() { # <name> [annotations-json]
  jq -n --arg name "$1" --arg ns "$NS" --argjson ann "${2:-{\}}" \
    '{apiVersion: "teknoir.org/v1alpha1", kind: "TeknoirBot", metadata: ({name: $name, namespace: $ns} + (if ($ann|length) > 0 then {annotations: $ann} else {} end)), spec: {}}'
}
bot a | "${KC[@]}" create -f - >/dev/null || { echo "cannot create TeknoirBot a" >&2; exit 2; }
BOTUID=$("${KC[@]}" -n "$NS" get teknoirbot a -o jsonpath='{.metadata.uid}')

# desired <name>: the desiredDevice() body of the controller (internal/controller/device.go), owned by TeknoirBot a
desired() {
  jq -n --arg name "$1" --arg ns "$NS" --arg uid "$BOTUID" '
    {apiVersion: "teknoir.org/v1", kind: "Device",
     metadata: {name: $name, namespace: $ns,
       labels: {"teknoir.org/teknoirbot": "a", hardware: "virtual", "teknoir.org/device-kind": "virtual", "teknoir.org/part-of": "teknoirbot"},
       annotations: {"teknoir.org/virtual-preset": "teknoirbot"},
       ownerReferences: [{apiVersion: "teknoir.org/v1alpha1", kind: "TeknoirBot", name: "a", uid: $uid, controller: true, blockOwnerDeletion: true}]},
     spec: {device_type: "virtual", keys: {data: {board: "dmlydHVhbA==", username: "dGVrbm9pcg==", userpassword: "cGFzc3dvcmQ="}},
       manifest: {}, virtual: {cpu: "2", memory: "4Gi", disk: {size: "20Gi"}}, desktop: {mode: "virtual", geometry: "1280x800"}}}'
}
# plain <name> [labels-json]: a Device of no bot
plain() {
  jq -n --arg name "$1" --arg ns "$NS" --argjson lab "${2:-{\}}" '
    {apiVersion: "teknoir.org/v1", kind: "Device", metadata: ({name: $name, namespace: $ns} + (if ($lab|length) > 0 then {labels: $lab} else {} end)),
     spec: {device_type: "jetson", keys: {data: {board: "amV0c29u"}}, manifest: {}}}'
}

# expect allow|deny <description> <identity> [message-substring (deny only)] -- <kubectl args...>
# identity: admin | ctrl | dc | bs | argo | gc | nsc | kcm | edit | master
# A deny passes only when the output names one of the three policies AND the substring of the rule that must have fired,
# and has no CEL runtime error ("resulted in error": with failurePolicy Fail a broken rule would look like a denial).
expect() {
  local want=$1 desc=$2 id=$3 msg=""; shift 3
  if [[ $1 != -- ]]; then msg=$1; shift; fi
  shift
  local who=()
  case $id in
    ctrl) who=(--as="$U_CTRL");; dc) who=(--as="$U_DC");; bs) who=(--as="$U_BS");; argo) who=(--as="$U_ARGO");;
    gc) who=(--as="$U_GC");; nsc) who=(--as="$U_NSC");; kcm) who=(--as="$U_KCM");; edit) who=(--as="$U_EDIT");;
    master) who=(--as="$U_MASTER" --as-group=system:masters);;
  esac
  local out rc
  out=$("${KC[@]}" "${who[@]}" "$@" 2>&1); rc=$?
  case "$want" in
    allow) [[ $rc -eq 0 ]] && ok "allow $desc" || bad "allow $desc (rc=$rc) ${out:0:400}" ;;
    deny)
      if [[ $rc -ne 0 && "$out" =~ ValidatingAdmissionPolicy\ \'teknoirbot- && "$out" == *"$msg"* && "$out" != *"resulted in error"* ]]; then
        ok "deny  $desc"
      else
        bad "deny  $desc (rc=$rc, wanted \"$msg\") ${out:0:400}"
      fi ;;
  esac
}

# The garbage collector needs a while to watch a freshly installed CRD; the cascade cases below depend on it.
if [[ $installed_crd == 1 || $installed_tb == 1 ]]; then
  echo "waiting 40 s for the garbage collector to watch the new CRD(s)"; sleep 40
fi

# ---- wait for the policies: a known-denied request, up to 30 s each -----------------------------------------------
for probe in "device:$(plain tb-probe | jq -c .)" "bot:$(bot probe | jq -c .)"; do
  active=0
  for _ in $(seq 1 30); do
    out=$(printf '%s' "${probe#*:}" | "${KC[@]}" --as="$U_EDIT" create --dry-run=server -f - 2>&1)
    [[ "$out" =~ ValidatingAdmissionPolicy\ \'teknoirbot- ]] && { active=1; break; }
    sleep 1
  done
  [[ $active == 1 ]] && ok "${probe%%:*} policy is active" || { bad "${probe%%:*} policy is not active after 30 s: ${out:0:300}"; exit 1; }
done

P=(-n "$NS" patch devices.teknoir.org)
MERGE=(--type=merge -p)
FENCE="are written only by teknoirbot-controller and device-controller"
BSMSG="backstage may only change the teknoir.org/disabled"

# ---- Devices: the allowed writers ---------------------------------------------------------------------------------
expect allow "teknoirbot-controller creates tb-a (desiredDevice body, owner reference)" ctrl -- create -f <(desired tb-a)
expect allow "teknoirbot-controller creates tb-del"                      ctrl  -- create -f <(desired tb-del)
expect allow "teknoirbot-controller creates tb-del2"                     ctrl  -- create -f <(desired tb-del2)
expect allow "teknoirbot-controller creates tb-del3"                     ctrl  -- create -f <(desired tb-del3)
expect allow "device-controller patches subresources.status"             dc    -- "${P[@]}" tb-a "${MERGE[@]}" '{"subresources":{"status":{"state":"ok"}}}'
expect allow "device-controller patches spec.manifest"                   dc    -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"manifest":{"apps":{"k":{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"k"}}}}}}'
expect allow "device-controller adds a finalizer"                        dc    -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"finalizers":["teknoir.org/test"]}}'
expect allow "device-controller removes the finalizer"                   dc    -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"finalizers":null}}'
expect allow "device-controller writes spec.keys and a ztna annotation"  dc    -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"keys":{"data":{"rsa_private":"eHh4"}}},"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"enabled"}}}'
expect allow "backstage adds teknoir.org/disabled"                       bs    -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled":"true"}}}'
expect allow "backstage adds disabled-at, disabled-by and disabled-reason" bs  -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled-at":"2026-11-07T10:00:00Z","teknoir.org/disabled-by":"someone@teknoir.ai","teknoir.org/disabled-reason":"test"}}}'
expect allow "backstage changes teknoir.org/disabled-reason"             bs    -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled-reason":"other"}}}'
expect allow "backstage removes the four teknoir.org/disabled* annotations" bs -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled":null,"teknoir.org/disabled-at":null,"teknoir.org/disabled-by":null,"teknoir.org/disabled-reason":null}}}'
expect allow "backstage updates with no change at all (no-op patch)"     bs    -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"2"}}}'
expect allow "masters patch spec and labels of tb-a"                     master -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"3"}},"metadata":{"labels":{"x":"y"}}}'
expect allow "admin patches spec of tb-a"                                admin -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"2"}}}'
expect allow "admin creates a Device with the bot label"                 admin -- create -f <(plain admin-bot '{"teknoir.org/teknoirbot":"a"}')
expect allow "admin creates a plain Device cam-01"                       admin -- create -f <(plain cam-01)
expect allow "default-editor patches the plain Device cam-01 (not fenced)" edit -- "${P[@]}" cam-01 "${MERGE[@]}" '{"spec":{"manifest":{"apps":{}}},"metadata":{"labels":{"x":"y"},"annotations":{"a":"b"}}}'
expect allow "default-editor creates a plain Device"                     edit  -- create -f <(plain cam-02)
expect allow "default-editor deletes a plain Device"                     edit  -- -n "$NS" delete devices.teknoir.org cam-02
expect allow "garbage collector deletes tb-del"                          gc    -- -n "$NS" delete devices.teknoir.org tb-del
expect allow "namespace controller deletes tb-del2"                      nsc   -- -n "$NS" delete devices.teknoir.org tb-del2
expect allow "kube-controller-manager deletes tb-del3"                   kcm   -- -n "$NS" delete devices.teknoir.org tb-del3

# ---- Devices: everybody else is fenced out -------------------------------------------------------------------------
expect deny  "default-editor patches spec of tb-a"                       edit  "$FENCE" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"4"}}}'
expect deny  "default-editor patches a label of tb-a"                    edit  "$FENCE" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"x":"z"}}}'
expect deny  "default-editor patches an annotation of tb-a"              edit  "$FENCE" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"x":"z"}}}'
expect deny  "default-editor removes the teknoirbot label (the old object matches)" edit "$FENCE" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"teknoir.org/teknoirbot":null}}}'
expect deny  "default-editor creates tb-x (no label)"                    edit  "$FENCE" -- create -f <(plain tb-x)
expect deny  "default-editor creates a Device x with the bot label"      edit  "$FENCE" -- create -f <(plain x '{"teknoir.org/teknoirbot":"a"}')
expect deny  "default-editor deletes tb-a"                               edit  "$FENCE" -- -n "$NS" delete devices.teknoir.org tb-a
expect deny  "argocd patches tb-a"                                       argo  "$FENCE" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"4"}}}'
expect deny  "backstage patches spec.virtual.cpu"                        bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"spec":{"virtual":{"cpu":"4"}}}'
expect deny  "backstage patches a label"                                 bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"x":"z"}}}'
expect deny  "backstage removes a label"                                 bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"labels":{"x":null}}}'
expect deny  "backstage patches another annotation"                      bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"x":"z"}}}'
expect deny  "backstage patches a ztna annotation"                       bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"ztna.teknoir.org/wireguard":"other"}}}'
expect deny  "backstage removes another annotation"                      bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/virtual-preset":null}}}'
expect deny  "backstage adds a disabled* annotation together with a spec change" bs "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/disabled":"true"}},"spec":{"virtual":{"cpu":"4"}}}'
expect deny  "backstage patches metadata.finalizers"                     bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"finalizers":["x.example/y"]}}'
expect deny  "backstage removes metadata.ownerReferences"                bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"metadata":{"ownerReferences":null}}'
expect deny  "backstage patches subresources"                            bs    "$BSMSG" -- "${P[@]}" tb-a "${MERGE[@]}" '{"subresources":{"status":{"state":"forged"}}}'
expect deny  "backstage creates a bot Device"                            bs    "$BSMSG" -- create -f <(desired tb-bs)
expect deny  "backstage creates a Device named tb-y without the label"   bs    "$BSMSG" -- create -f <(plain tb-y)
expect deny  "backstage deletes a bot Device"                            bs    "$BSMSG" -- -n "$NS" delete devices.teknoir.org tb-a
expect allow "backstage patches the plain Device cam-01 (not fenced)"    bs    -- "${P[@]}" cam-01 "${MERGE[@]}" '{"spec":{"manifest":{}}}'
expect allow "default-editor reads tb-a"                                 edit  -- -n "$NS" get devices.teknoir.org tb-a

# ---- TeknoirBots ---------------------------------------------------------------------------------------------------
CB="only through the Teknoir portal or GitOps"
expect allow "backstage creates a bot with teknoir.org/created-by"       bs    -- create -f <(bot b1 '{"teknoir.org/created-by":"someone@teknoir.ai"}')
expect deny  "backstage creates a bot without teknoir.org/created-by"    bs    "must set teknoir.org/created-by" -- create -f <(bot b2)
expect deny  "backstage creates a bot with an empty created-by"          bs    "must set teknoir.org/created-by" -- create -f <(bot b2 '{"teknoir.org/created-by":""}')
expect allow "backstage patches spec.suspended"                          bs    -- -n "$NS" patch teknoirbots.teknoir.org b1 "${MERGE[@]}" '{"spec":{"suspended":true}}'
expect deny  "backstage changes created-by"                              bs    "created-by cannot be changed" -- -n "$NS" patch teknoirbots.teknoir.org b1 "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/created-by":"other@teknoir.ai"}}}'
expect deny  "backstage removes created-by"                              bs    "created-by cannot be changed" -- -n "$NS" patch teknoirbots.teknoir.org b1 "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/created-by":null}}}'
expect allow "argocd creates a bot without created-by"                   argo  -- create -f <(bot b3)
expect deny  "argocd adds created-by afterwards"                         argo  "created-by cannot be changed" -- -n "$NS" patch teknoirbots.teknoir.org b3 "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/created-by":"x@teknoir.ai"}}}'
expect allow "argocd patches spec.suspended"                             argo  -- -n "$NS" patch teknoirbots.teknoir.org b3 "${MERGE[@]}" '{"spec":{"suspended":true}}'
expect deny  "default-editor creates a bot"                              edit  "$CB" -- create -f <(bot b4)
expect deny  "default-editor patches a bot"                              edit  "$CB" -- -n "$NS" patch teknoirbots.teknoir.org b1 "${MERGE[@]}" '{"spec":{"suspended":false}}'
expect deny  "default-editor deletes a bot"                              edit  "deleted only through the Teknoir portal or GitOps" -- -n "$NS" delete teknoirbots.teknoir.org b1
expect allow "teknoirbot-controller patches teknoirbots/status"          ctrl  -- -n "$NS" patch teknoirbots.teknoir.org b1 --subresource=status "${MERGE[@]}" '{"status":{"phase":"Running"}}'
expect deny  "teknoirbot-controller patches the main resource"           ctrl  "$CB" -- -n "$NS" patch teknoirbots.teknoir.org b1 "${MERGE[@]}" '{"metadata":{"finalizers":["teknoir.org/teknoirbot-access"]}}'
expect deny  "teknoirbot-controller deletes a bot"                       ctrl  "deleted only through the Teknoir portal or GitOps" -- -n "$NS" delete teknoirbots.teknoir.org b3
expect allow "masters create a bot without created-by"                   master -- create -f <(bot b5)
expect allow "admin changes created-by of a bot"                         admin -- -n "$NS" annotate --overwrite teknoirbots.teknoir.org b1 teknoir.org/created-by=admin@teknoir.ai
for b in b6 b7 b8; do "${KC[@]}" create -f <(bot "$b") >/dev/null 2>&1 || bad "admin cannot create bot $b"; done
expect allow "backstage deletes a bot"                                   bs    -- -n "$NS" delete teknoirbots.teknoir.org b1
expect allow "argocd deletes a bot"                                      argo  -- -n "$NS" delete teknoirbots.teknoir.org b3
expect allow "garbage collector deletes a bot"                           gc    -- -n "$NS" delete teknoirbots.teknoir.org b6
expect allow "namespace controller deletes a bot"                        nsc   -- -n "$NS" delete teknoirbots.teknoir.org b7
expect allow "kube-controller-manager deletes a bot"                     kcm   -- -n "$NS" delete teknoirbots.teknoir.org b8

# ---- the end of a cascade: the garbage collector removes foregroundDeletion/orphan from the bot ----------------------
# owned <bot>: the desired() body of tb-<bot>, owned by that bot (its real uid)
owned() {
  local uid; uid=$("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org "$1" -o jsonpath='{.metadata.uid}')
  desired "tb-$1" | jq --arg b "$1" --arg uid "$uid" '.metadata.labels["teknoir.org/teknoirbot"]=$b | .metadata.ownerReferences[0].name=$b | .metadata.ownerReferences[0].uid=$uid'
}
# gone_within <seconds> <kubectl get args...>
gone_within() { local t=$1; shift; for _ in $(seq 1 "$t"); do "${KC[@]}" -n "$NS" get "$@" >/dev/null 2>&1 || return 0; sleep 1; done; return 1; }

"${KC[@]}" create -f <(bot fin) >/dev/null 2>&1 || bad "admin cannot create bot fin"
"${KC[@]}" -n "$NS" patch teknoirbots.teknoir.org fin "${MERGE[@]}" '{"metadata":{"finalizers":["foregroundDeletion"]}}' >/dev/null 2>&1 || bad "admin cannot add a finalizer to bot fin"
expect allow "garbage collector removes the foregroundDeletion finalizer" gc -- -n "$NS" patch teknoirbots.teknoir.org fin --type=json -p '[{"op":"remove","path":"/metadata/finalizers/0"}]'
expect deny  "garbage collector patches spec.suspended"                  gc    "$CB" -- -n "$NS" patch teknoirbots.teknoir.org fin "${MERGE[@]}" '{"spec":{"suspended":true}}'
expect deny  "garbage collector adds a label"                            gc    "$CB" -- -n "$NS" patch teknoirbots.teknoir.org fin "${MERGE[@]}" '{"metadata":{"labels":{"x":"y"}}}'
# validation 1 fails first for the garbage collector, so its message (not "created-by cannot be changed") is the one shown
expect deny  "garbage collector changes created-by"                      gc    "$CB" -- -n "$NS" patch teknoirbots.teknoir.org fin "${MERGE[@]}" '{"metadata":{"annotations":{"teknoir.org/created-by":"evil@teknoir.ai"}}}'
expect deny  "garbage collector creates a bot"                           gc    "$CB" -- create -f <(bot g2)

# ArgoCD deletes a bot that owns its Device with foreground propagation (its prune default): both must go within 60 s
expect allow "argocd creates bot fg"                                     argo  -- create -f <(bot fg)
expect allow "teknoirbot-controller creates tb-fg owned by fg"           ctrl  -- create -f <(owned fg)
expect allow "argocd deletes fg with --cascade=foreground"               argo  -- -n "$NS" delete teknoirbots.teknoir.org fg --cascade=foreground --wait=false
if gone_within 60 devices.teknoir.org/tb-fg && gone_within 60 teknoirbots.teknoir.org/fg; then
  ok "foreground delete of fg completes (Device and bot gone)"
else
  bad "foreground delete of fg hangs: $("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org fg -o jsonpath='{.metadata.finalizers}' 2>&1)"
fi

# --cascade=orphan by backstage-api and by masters: the bot goes, its Device stays without an owner
for who in bs master; do
  b="or-$who"
  expect allow "argocd creates bot $b"                                   argo  -- create -f <(bot "$b")
  expect allow "teknoirbot-controller creates tb-$b owned by $b"         ctrl  -- create -f <(owned "$b")
  expect allow "$who deletes $b with --cascade=orphan"                   "$who" -- -n "$NS" delete teknoirbots.teknoir.org "$b" --cascade=orphan --wait=false
  if gone_within 60 teknoirbots.teknoir.org/"$b" && [[ -z $("${KC[@]}" -n "$NS" get devices.teknoir.org "tb-$b" -o jsonpath='{.metadata.ownerReferences}' 2>&1) ]]; then
    ok "orphan delete of $b completes (bot gone, Device has no owner)"
  else
    bad "orphan delete of $b hangs: $("${KC[@]}" -n "$NS" get teknoirbots.teknoir.org "$b" -o jsonpath='{.metadata.finalizers}' 2>&1)"
  fi
done

echo "----"
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
