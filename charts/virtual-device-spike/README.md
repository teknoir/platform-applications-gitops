# virtual-device-spike

The S1 spike VM of the virtual-device design, delivered by GitOps: one test virtual
Device (a KubeVirt VM that runs the real tnctl server bootstrap) in `<teamspace>-vdev`,
and a one-shot Job that renders its cloud-init Secret inside the cluster, so the device
keys never go into git or onto a workstation. Runbook, order and checks:
`hack/virtual-device-spike/README.md`, "S1 delivered by GitOps".

Deployed by `charts/app-of-apps/templates/virtual-device-spike.yaml` only when
`virtualDevices.enabled` and `virtualDevices.spike.enabled` are both true and the
environment is `teknoir-cloud`. The default is off. It needs the runtime of
`charts/virtual-devices` (KubeVirt, CDI, the PriorityClass and the CoreDNS override).

| Template | Wave | What |
|---|---|---|
| `render-namespace.yaml` | 0 | `teknoir-vdev-spike`: where the Job runs (PSA restricted, no Istio injection). A separate namespace, so the -vdev egress policy needs no API-server rule. |
| `render-rbac.yaml` | 0 | ServiceAccount `vd-spike-render`. Get the one Device; get and create Secrets in the vdev namespace. No list, watch, update, patch or delete. |
| `render-job.yaml` | 1 (Sync hook) | `vdev-spike-render -in-cluster`: if Secret `<device>-cloudinit` exists, do nothing (the k3s token of a running VM stays stable); otherwise render the bootstrap and the cloud-init in memory and create the Secret. Fails, and stops the sync before the VM, when the Device is missing. |
| `vm.yaml` | 2 | The `VirtualMachine` and its DataVolume (same as `render.sh`'s `20-vm.yaml`). |

`renderer.digest` is pinned to a `vdev-spike-render` build; an empty value fails the render
(`.github/workflows/vdev-spike-render.yaml`) before enabling the spike. Rendering
without it fails.
