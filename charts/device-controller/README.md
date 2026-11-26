# device-controller

Deploys Teknoir's `device-controller` (`harbor.teknoir.cloud/teknoir/device-controller`) into `teknoir-system`, with
every setting in `values.yaml` (each block is documented there) and its CRDs in `crds/` (annotated
`Prune=false,Delete=false`; `DOWNGRADE.md` has the removal and rollback runbook).

Two parts concern virtual devices:

- `templates/virtual-devices-runtime.yaml` renders one runtime namespace `<teamspace>-vdev` per
  `virtualDevices.allowances` entry (default-deny NetworkPolicy, quota, LimitRange), labelled
  `teknoir.org/component: virtual-device-runtime`;
- `templates/virtual-devices-vap.yaml` renders the ValidatingAdmissionPolicy `virtual-device-shape` and its binding
  (`virtualDevices.shapePolicy`, both gated on `virtualDevices.enabled`).

## VM-shape policy `virtual-device-shape`

A teamspace user who may write in a runtime namespace could otherwise create a VM shaped like a privileged pod: a
`hostDisk` volume (a host path written from the guest), host PCI (`hostDevices`, `gpus`, `filesystems`), a `bridge` or
`multus` network (another teamspace's pod network), a `lun` or `cdrom` disk, guest-agent `accessCredentials`, `tpm`,
`launchSecurity`, dedicated CPUs, hugepages, `autoattachVSOCK`, or a `hooks.kubevirt.io/hookSidecars` annotation (a
sidecar container in the virt-launcher pod). The policy allow-lists what the controller's `BuildVM` builds:

| Field | Allowed |
|---|---|
| volumes | `dataVolume`, `cloudInitNoCloud` |
| interfaces | `masquerade` |
| networks | `pod` |
| disks | `disk` |
| absent | `hostDevices`, `gpus`, `filesystems`, `accessCredentials`, `tpm`, `launchSecurity`, `cpu.dedicatedCpuPlacement`, `memory.hugepages`, `autoattachVSOCK`, `hooks.kubevirt.io/hookSidecars` |

Scope: `kubevirt.io/v1` `virtualmachines` (CREATE and UPDATE; a VM is validated on the spec in `spec.template.spec`
only when that spec changed, so virt-controller's label, annotation and finalizer writes and the deletion of a VM
created before the policy are never blocked) and `virtualmachineinstances` (CREATE only: virt-handler and
virt-controller updates are never blocked). Only in namespaces labelled `teknoir.org/component:
virtual-device-runtime`, never on a `*/status` subresource. `failurePolicy: Fail`; every expression is null-safe, so
a missing field cannot turn into a denial. `virtualDevices.shapePolicy.validationActions` is `[Deny]` by default and
can be set to `[Warn, Audit]` without a code change.

Break-glass: pause the Application's auto-sync and delete the ValidatingAdmissionPolicyBinding `virtual-device-shape`
(the policy then does nothing); restore it afterwards. Through GitOps: `virtualDevices.shapePolicy.enabled: false`.

## Tests

- `helm unittest charts/device-controller` (`tests/virtual_devices_vap_test.yaml`: the rules, the namespace selector,
  the UPDATE guard, the actions and the gates). CI runs it through `scripts/ci/helm-unittest.sh`.
- `tests/k3d-vdev-vap-test.sh` (by hand, context `k3d-teknoir-dev` only, like the teknoirbot tests): behaviour against a
  real API server. It installs stub KubeVirt CRDs when the cluster has none, creates a labelled and an unlabelled
  namespace, applies the rendered policy, and checks that the `BuildVM` goldens in `tests/testdata/` (the shape before
  2026-11-26 and today's) and their VMIs are admitted, that every forbidden field is denied on a VM and on a VMI, that
  an unlabelled namespace is not validated, and that UPDATE never blocks a VM whose spec did not change.
  `K3D=1 scripts/tests/run.sh` runs it together with the other cluster tests.
