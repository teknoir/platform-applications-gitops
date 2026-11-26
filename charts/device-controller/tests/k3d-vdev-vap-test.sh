#!/usr/bin/env bash
# Behavioural test of the ValidatingAdmissionPolicy virtual-device-shape (templates/virtual-devices-vap.yaml) on the
# LOCAL THROWAWAY cluster context k3d-teknoir-dev (any other context is refused). Repeatable: it creates the namespace
# vdev-vap-test (labelled teknoir.org/component=virtual-device-runtime, the runtime scope) and vdev-vap-other (not
# labelled), stub CRDs for virtualmachines.kubevirt.io and virtualmachineinstances.kubevirt.io (only when the cluster
# lacks them; removed again only when this run installed them), renders the chart's policy and binding with
# helm template --show-only, tests, and removes all of it again on exit.
#
# The shapes are device-controller's BuildVM goldens (tests/testdata/): vm_small_v1 is what the controller built
# before 2026-11-26, the shape the live VM tb-scout still has; vm_small_v2 is today's shape. Both must be admitted as
# a VirtualMachine and as a VirtualMachineInstance (the VMI is built from the golden's spec.template, as
# virt-controller builds it), every forbidden field of the plan (R10, WP3) must be denied on both, a VM in a
# namespace without the runtime label must be admitted whatever its shape, and UPDATE must never block a VM whose
# spec did not change (virt-controller's label/annotation/finalizer writes, a VM created before the binding, deletion).
#
#   charts/device-controller/tests/k3d-vdev-vap-test.sh
#
# Needs: kubectl, helm, jq, python3 with PyYAML (the goldens are YAML).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${CHART}/../.." && pwd)"
GOLDENS="${HERE}/testdata"
CONTEXT=k3d-teknoir-dev
NS=vdev-vap-test
OTHER=vdev-vap-other
POLICY=virtual-device-shape

for t in kubectl helm jq python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
python3 -I -c 'import yaml' >/dev/null 2>&1 || { echo "missing python3 module: PyYAML (the goldens are YAML)" >&2; exit 2; }
KC=(kubectl --context "$CONTEXT")
"${KC[@]}" get ns >/dev/null 2>&1 || { echo "context $CONTEXT is not reachable (k3d cluster start teknoir-dev)" >&2; exit 2; }
if "${KC[@]}" get validatingadmissionpolicy "$POLICY" >/dev/null 2>&1 \
  || "${KC[@]}" get validatingadmissionpolicybinding "$POLICY" >/dev/null 2>&1 \
  || "${KC[@]}" get ns "$NS" >/dev/null 2>&1 || "${KC[@]}" get ns "$OTHER" >/dev/null 2>&1; then
  echo "refusing: $POLICY, its binding or a test namespace already exists on $CONTEXT" >&2
  exit 2
fi

TMP=$(mktemp -d)
pass=0; failn=0
installed_vm=0; installed_vmi=0
ok()  { printf 'PASS %s\n' "$*"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$*"; failn=$((failn+1)); }

cleanup() {
  local ns vm
  for ns in "$NS" "$OTHER"; do
    # a VM with a finalizer never goes away; the admin may have left one (the update cases add and remove one)
    for vm in $("${KC[@]}" -n "$ns" get virtualmachines.kubevirt.io -o name 2>/dev/null); do
      "${KC[@]}" -n "$ns" patch "$vm" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    done
    "${KC[@]}" delete virtualmachines.kubevirt.io --all -n "$ns" --wait=false >/dev/null 2>&1 || true
    "${KC[@]}" delete virtualmachineinstances.kubevirt.io --all -n "$ns" --wait=false >/dev/null 2>&1 || true
  done
  "${KC[@]}" delete validatingadmissionpolicybinding "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete validatingadmissionpolicy "$POLICY" --ignore-not-found >/dev/null 2>&1 || true
  "${KC[@]}" delete ns "$NS" "$OTHER" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
  [[ $installed_vm == 1 ]] && "${KC[@]}" delete crd virtualmachines.kubevirt.io --ignore-not-found >/dev/null 2>&1
  [[ $installed_vmi == 1 ]] && "${KC[@]}" delete crd virtualmachineinstances.kubevirt.io --ignore-not-found >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- setup ----------------------------------------------------------------------------------------------------
"${KC[@]}" apply -f - >/dev/null <<EOF || { echo "cannot create the test namespaces" >&2; exit 2; }
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    # the label virtual-devices-runtime.yaml puts on <teamspace>-vdev: what the policy's namespaceSelector matches
    teknoir.org/component: virtual-device-runtime
---
apiVersion: v1
kind: Namespace
metadata:
  name: $OTHER
EOF

# Stub CRDs: the policy is evaluated by the API server, so the resources must exist; their schema preserves every
# field (the KubeVirt CRDs are large and the shape, not the schema, is what is tested).
if ! "${KC[@]}" get crd virtualmachines.kubevirt.io >/dev/null 2>&1; then
  "${KC[@]}" apply --server-side -f - >/dev/null <<'EOF' || { echo "cannot apply the VM CRD" >&2; exit 2; }
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: virtualmachines.kubevirt.io
spec:
  group: kubevirt.io
  names: {kind: VirtualMachine, listKind: VirtualMachineList, plural: virtualmachines, singular: virtualmachine}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
  installed_vm=1
  "${KC[@]}" wait --for=condition=Established crd/virtualmachines.kubevirt.io --timeout=30s >/dev/null
fi
if ! "${KC[@]}" get crd virtualmachineinstances.kubevirt.io >/dev/null 2>&1; then
  "${KC[@]}" apply --server-side -f - >/dev/null <<'EOF' || { echo "cannot apply the VMI CRD" >&2; exit 2; }
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: virtualmachineinstances.kubevirt.io
spec:
  group: kubevirt.io
  names: {kind: VirtualMachineInstance, listKind: VirtualMachineInstanceList, plural: virtualmachineinstances, singular: virtualmachineinstance}
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema: {type: object, x-kubernetes-preserve-unknown-fields: true}
EOF
  installed_vmi=1
  "${KC[@]}" wait --for=condition=Established crd/virtualmachineinstances.kubevirt.io --timeout=30s >/dev/null
fi

# the chart's policy and binding only, with the values the device-controller Application passes (the image pins and
# the fleet pointers: helm renders every template, even with --show-only)
helm template device-controller "$CHART" -n teknoir-system \
  --show-only templates/virtual-devices-vap.yaml \
  -f "${REPO}/pins/device-controller.yaml" \
  -f "${REPO}/pins/teknoir-desktop.yaml" \
  -f "${REPO}/pins/web-terminal.yaml" \
  -f "${REPO}/pins/wg-tunnel.yaml" \
  -f "${REPO}/fleet/jetson-orin.yaml" \
  -f "${REPO}/fleet/nvidia-rtx.yaml" \
  -f "${REPO}/fleet/raspberry-pi.yaml" > "$TMP/vap.yaml" \
  || { echo "helm template failed" >&2; exit 2; }
grep -qx 'kind: ValidatingAdmissionPolicy' "$TMP/vap.yaml" && grep -qx 'kind: ValidatingAdmissionPolicyBinding' "$TMP/vap.yaml" \
  || { echo "the rendered template does not hold the policy and its binding" >&2; exit 2; }

# ---- the objects under test -----------------------------------------------------------------------------------
# The goldens as JSON; a VMI is what virt-controller makes of a VM: the template's metadata and spec.
yaml2json() { python3 -I -c 'import json,sys,yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$1"; }
yaml2json "$GOLDENS/vm_small_v1.golden.yaml" > "$TMP/vm-v1.json" || { echo "cannot read the v1 golden" >&2; exit 2; }
yaml2json "$GOLDENS/vm_small_v2.golden.yaml" > "$TMP/vm-v2.json" || { echo "cannot read the v2 golden" >&2; exit 2; }
for v in v1 v2; do
  jq '{apiVersion: "kubevirt.io/v1", kind: "VirtualMachineInstance", metadata: (.spec.template.metadata // {}), spec: .spec.template.spec}' \
    "$TMP/vm-$v.json" > "$TMP/vmi-$v.json"
done

# obj <vm|vmi> <v1|v2> <name> <namespace> <jq program>: the golden with a new name and namespace, then the program,
# which may use $pod: the path of the pod spec (VM: .spec.template.spec, VMI: .spec, the root of the object's spec).
obj() {
  local kind=$1 pod
  [[ $kind == vm ]] && pod='["spec","template","spec"]' || pod='["spec"]'
  jq --arg name "$3" --arg ns "$4" '.metadata.name = $name | .metadata.namespace = $ns' "$TMP/$1-$2.json" \
    | jq --argjson pod "$pod" ". | $5"
}

# expect allow|deny <description> <json> [message-substring (deny only)]: a server-side dry-run create. A deny passes
# only when the output names this policy AND the message of the rule that must have fired, and has no CEL runtime
# error ("resulted in error": with failurePolicy Fail a broken rule would otherwise look like a denial).
expect() {
  local want=$1 desc=$2 json=$3 msg=${4:-} out rc
  out=$(printf '%s' "$json" | "${KC[@]}" create --dry-run=server -f - 2>&1); rc=$?
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

# expectk allow|deny <description> [message-substring] -- <kubectl args...>: the same for a real call (the update cases)
expectk() {
  local want=$1 desc=$2 msg=""; shift 2
  if [[ $1 != -- ]]; then msg=$1; shift; fi
  shift
  local out rc
  out=$("${KC[@]}" "$@" 2>&1); rc=$?
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

# wait_active: a known-denied request until the policy answers, up to 30 s
wait_active() {
  local out
  for _ in $(seq 1 30); do
    out=$(printf '%s' "$(obj vm v2 vd-probe "$NS" 'setpath($pod + ["domain","devices","hostDevices"]; [{"name":"hd","deviceName":"pci_0000_00_1f_2"}])')" \
      | "${KC[@]}" create --dry-run=server -f - 2>&1)
    [[ "$out" == *"ValidatingAdmissionPolicy '${POLICY}'"* ]] && return 0
    sleep 1
  done
  printf '%s' "${out:0:300}"
  return 1
}

"${KC[@]}" apply -f "$TMP/vap.yaml" >/dev/null || { echo "cannot apply the rendered policy" >&2; exit 2; }
out=$(wait_active) && ok "policy is active" || { bad "policy is not active after 30 s: $out"; exit 1; }

HD='setpath($pod + ["domain","devices","hostDevices"]; [{"name":"hd","deviceName":"pci_0000_00_1f_2"}])'

# ---- the shapes the controller builds: admitted ---------------------------------------------------------------
expect allow "the v1 BuildVM golden (the live VM tb-scout's shape) as a VirtualMachine" "$(obj vm v1 vd-v1 "$NS" '.')"
expect allow "the v2 BuildVM golden (today's shape) as a VirtualMachine" "$(obj vm v2 vd-v2 "$NS" '.')"
expect allow "the v1 golden's spec.template as a VirtualMachineInstance" "$(obj vmi v1 vmi-v1 "$NS" '.')"
expect allow "the v2 golden's spec.template as a VirtualMachineInstance" "$(obj vmi v2 vmi-v2 "$NS" '.')"
# KubeVirt's own mutating webhook adds these to a VMI: only the fields the plan lists are restricted, so they pass
expect allow "a VMI with the defaults KubeVirt's mutating webhook adds (machine, firmware, features, cpu.model, rng, multiqueue)" \
  "$(obj vmi v2 vmi-defaults "$NS" '
    setpath($pod + ["domain","machine"]; {"type":"pc-q35-rhel9.6.0"})
    | setpath($pod + ["domain","firmware"]; {"uuid":"5d3f2a1e-0000-4000-8000-000000000000","serial":"0a1b2c3d"})
    | setpath($pod + ["domain","features"]; {"acpi":{"enabled":true},"smm":{"enabled":true}})
    | setpath($pod + ["domain","cpu","model"]; "host-model")
    | setpath($pod + ["domain","devices","autoattachGraphicsDevice"]; false)
    | setpath($pod + ["domain","devices","networkInterfaceMultiqueue"]; true)
    | setpath($pod + ["domain","devices","rng"]; {})')"
# the scope is the label, not the shape: nothing is validated in another namespace
expect allow "a VM with hostDevices in the namespace without the runtime label" "$(obj vm v2 vd-plain "$OTHER" "$HD")"

# ---- every forbidden field: denied on a VM (spec.template.spec) and on a VMI (spec) ---------------------------
n=0
both() { # <description> <message-substring> <jq program using $pod>
  n=$((n+1))
  expect deny "VM $1"  "$(obj vm  v2 "vd-bad-$n" "$NS" "$3")" "$2"
  expect deny "VMI $1" "$(obj vmi v2 "vd-bad-$n" "$NS" "$3")" "$2"
}
both "with hostDevices" "devices.hostDevices is not allowed" "$HD"
both "with gpus" "devices.gpus is not allowed" \
  'setpath($pod + ["domain","devices","gpus"]; [{"name":"gpu","deviceName":"pci_0000_01_00_0"}])'
both "with filesystems" "devices.filesystems is not allowed" \
  'setpath($pod + ["domain","devices","filesystems"]; [{"name":"fs","virtiofs":{"pciAddress":"0000:00:1f.1"}}])'
both "with accessCredentials" "accessCredentials is not allowed" \
  'setpath($pod + ["accessCredentials"]; [{"sshPublicKey":{"source":{"secret":{"secretName":"authkey"}}}}])'
both "with tpm" "devices.tpm is not allowed" \
  'setpath($pod + ["domain","devices","tpm"]; {})'
both "with launchSecurity" "launchSecurity is not allowed" \
  'setpath($pod + ["launchSecurity"]; {"sev":{}})'
both "with dedicatedCpuPlacement" "dedicatedCpuPlacement is not allowed" \
  'setpath($pod + ["domain","cpu","dedicatedCpuPlacement"]; true)'
both "with hugepages" "hugepages is not allowed" \
  'setpath($pod + ["domain","memory","hugepages"]; {"pageSize":"2Mi"})'
both "with autoattachVSOCK" "autoattachVSOCK is not allowed" \
  'setpath($pod + ["domain","devices","autoattachVSOCK"]; true)'
both "with a hostDisk volume" "may only be dataVolume or cloudInitNoCloud" \
  'setpath($pod + ["volumes"]; (getpath($pod + ["volumes"]) // []) + [{"name":"extra","hostDisk":{"path":"/var/lib/extra","type":"Disk"}}])'
both "with a persistentVolumeClaim volume" "may only be dataVolume or cloudInitNoCloud" \
  'setpath($pod + ["volumes"]; (getpath($pod + ["volumes"]) // []) + [{"name":"extra","persistentVolumeClaim":{"claimName":"other"}}])'
both "with a containerDisk volume" "may only be dataVolume or cloudInitNoCloud" \
  'setpath($pod + ["volumes"]; (getpath($pod + ["volumes"]) // []) + [{"name":"extra","containerDisk":{"image":"nginx:latest"}}])'
both "with a secret volume" "may only be dataVolume or cloudInitNoCloud" \
  'setpath($pod + ["volumes"]; (getpath($pod + ["volumes"]) // []) + [{"name":"extra","secret":{"secretName":"vd-1-cloudinit"}}])'
both "with a serviceAccount volume" "may only be dataVolume or cloudInitNoCloud" \
  'setpath($pod + ["volumes"]; (getpath($pod + ["volumes"]) // []) + [{"name":"extra","serviceAccount":{"secretName":"default-token"}}])'
both "with a bridge interface" "interface may only be masquerade" \
  'setpath($pod + ["domain","devices","interfaces"]; [{"name":"default","bridge":{}}])'
both "with a multus network" "network may only be pod" \
  'setpath($pod + ["networks"]; [{"name":"default","multus":{"networkName":"other-teamspace-net"}}])'
both "with a lun disk" "disk may only be disk" \
  'setpath($pod + ["domain","devices","disks"]; (getpath($pod + ["domain","devices","disks"]) // []) + [{"name":"lun","lun":{"bus":"scsi"}}])'
both "with a cdrom disk" "disk may only be disk" \
  'setpath($pod + ["domain","devices","disks"]; (getpath($pod + ["domain","devices","disks"]) // []) + [{"name":"cd","cdrom":{"bus":"sata"}}])'

# hooks.kubevirt.io/hookSidecars: on the VM, in the VM's template (what the VMI inherits) and on the VMI
HOOKMSG="hookSidecars is not allowed on a virtual device's VirtualMachine or VirtualMachineInstance"
expect deny "VM with the hookSidecars annotation" \
  "$(obj vm v2 vd-hook "$NS" 'setpath(["metadata","annotations","hooks.kubevirt.io/hookSidecars"]; "[{\"type\":\"sh\",\"command\":[\"true\"]}]")')" \
  "$HOOKMSG"
expect deny "VM with the hookSidecars annotation in spec.template.metadata.annotations" \
  "$(obj vm v2 vd-hook2 "$NS" 'setpath(["spec","template","metadata","annotations","hooks.kubevirt.io/hookSidecars"]; "[]")')" \
  "spec.template.metadata.annotations of a virtual device's VirtualMachine"
expect deny "VMI with the hookSidecars annotation" \
  "$(obj vmi v2 vmi-hook "$NS" 'setpath(["metadata","annotations","hooks.kubevirt.io/hookSidecars"]; "[]")')" \
  "$HOOKMSG"

# ---- UPDATE: never blocked without a spec change ---------------------------------------------------------------
P=(-n "$NS" patch virtualmachines.kubevirt.io)
MERGE=(--type=merge -p)
# a real VM in the v1 (live) shape, as tb-scout has it
obj vm v1 vd-up "$NS" '.' | "${KC[@]}" create -f - >/dev/null || { echo "cannot create the test VM vd-up" >&2; exit 2; }
expectk allow "a label-only patch of a VM (spec unchanged)" -- "${P[@]}" vd-up "${MERGE[@]}" '{"metadata":{"labels":{"vap-test":"label-only"}}}'
expectk allow "an annotation-only patch of a VM (spec unchanged)" -- "${P[@]}" vd-up "${MERGE[@]}" '{"metadata":{"annotations":{"kubevirt.io/foo":"bar"}}}'
expectk allow "adding a finalizer to a VM (spec unchanged)" -- "${P[@]}" vd-up "${MERGE[@]}" '{"metadata":{"finalizers":["example.com/vap-test"]}}'
expectk allow "removing the finalizer again (spec unchanged)" -- "${P[@]}" vd-up "${MERGE[@]}" '{"metadata":{"finalizers":[]}}'
expectk allow "a spec change that keeps the allowed shape" -- "${P[@]}" vd-up "${MERGE[@]}" '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":60}}}}'
# what the controller's ensureVM syncs on an existing VM (runStrategy, cpu, memory)
expectk allow "changing cpu, memory and runStrategy (what ensureVM syncs)" -- \
  "${P[@]}" vd-up "${MERGE[@]}" '{"spec":{"runStrategy":"Halted","template":{"spec":{"domain":{"cpu":{"cores":3},"resources":{"limits":{"cpu":"3","memory":"6Gi"},"requests":{"cpu":"1500m","memory":"6Gi"}}}}}}}'
expectk deny "adding hostDevices to a VM (spec changed)" "devices.hostDevices is not allowed" -- \
  "${P[@]}" vd-up "${MERGE[@]}" '{"spec":{"template":{"spec":{"domain":{"devices":{"hostDevices":[{"name":"hd","deviceName":"pci_0000_00_1f_2"}]}}}}}}'

# a VM created while the binding is absent (a floor VM, as tb-scout is when the policy ships) stays patchable and
# deletable once the binding exists: its spec never changed, and DELETE is not matched at all
"${KC[@]}" delete validatingadmissionpolicybinding "$POLICY" >/dev/null 2>&1 || { echo "cannot delete the binding" >&2; exit 2; }
# the API server drops the binding from its policy cache a little later: retry for up to 30 s
pre_ok=0
for _ in $(seq 1 30); do
  if obj vm v2 vd-pre "$NS" "$HD" | "${KC[@]}" create -f - >/dev/null 2>&1; then pre_ok=1; break; fi
  sleep 1
done
if [[ $pre_ok == 1 ]]; then
  ok "allow a forbidden VM to be created while the binding is absent"
else
  bad "a forbidden VM could not be created with the binding deleted"
fi
"${KC[@]}" apply -f "$TMP/vap.yaml" >/dev/null || { echo "cannot re-apply the rendered policy" >&2; exit 2; }
out=$(wait_active) && ok "policy is active again" || { bad "policy is not active again after 30 s: $out"; exit 1; }
expectk allow "a label patch of the VM that predates the binding (spec unchanged)" -- "${P[@]}" vd-pre "${MERGE[@]}" '{"metadata":{"labels":{"vap-test":"pre"}}}'
expectk allow "deleting the VM that predates the binding" -- -n "$NS" delete virtualmachines.kubevirt.io vd-pre

# VMI UPDATE is not matched at all (virt-handler and virt-controller write the VMI): a VMI update that would be
# denied at create is allowed, which is the deliberate scope of the policy
obj vmi v2 vmi-up "$NS" '.' | "${KC[@]}" create -f - >/dev/null || { echo "cannot create the test VMI vmi-up" >&2; exit 2; }
expectk allow "a VMI spec update (VMI UPDATE is out of scope by design)" -- \
  -n "$NS" patch virtualmachineinstances.kubevirt.io vmi-up "${MERGE[@]}" '{"spec":{"domain":{"devices":{"hostDevices":[{"name":"hd","deviceName":"pci_0000_00_1f_2"}]}}}}'

echo "----"
echo "$pass passed, $failn failed"
[[ $failn -eq 0 ]]
