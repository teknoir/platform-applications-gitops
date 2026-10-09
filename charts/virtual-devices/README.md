# virtual-devices

Runtime for Teknoir virtual devices: [KubeVirt](https://kubevirt.io) and
[CDI](https://github.com/kubevirt/containerized-data-importer), plus two small pieces of
platform configuration. Deployed by `charts/app-of-apps` when `virtualDevices.enabled`
is true (only `teknoir-cloud`, for the S1 spike; see `hack/virtual-device-spike/README.md`).

| Object | Notes |
|---|---|
| KubeVirt operator, `KubeVirt` CR | v1.8.4 (k8s 1.34-1.35). No feature gates; serial console log disabled; 1 infra replica; uninstall blocked while VMs exist. |
| CDI operator, `CDI` CR | v1.65.0. Feature gate `HonorWaitForFirstConsumer` (local-path); explicit worker pod resources for quota budgeting. |
| PriorityClass `teknoir-virtual-device` | `-100`, `preemptionPolicy: Never`: below every platform pod, never preempts. |
| `kube-system/coredns-custom` key `virtual-devices.override` | `(mqtt\|deadend)-<ns>.<domain>` answer with the `istio-ingressgateway-public` ClusterIP, so a VM reaches EMQX and deadend through the public gateway like an external device. This chart owns the ConfigMap. |

## Pinning

The operator manifests are **vendored**, never fetched at deploy time:

- `vendor/upstream.lock.yaml`: release versions, the sha256 of each downloaded release
  asset, and the digest of every image the operators run or deploy.
- `vendor/*.yaml`: upstream files with only the image references changed. Each image is pinned
  to `<tag>@<digest>`, and the KubeVirt operand images are set through `VIRT_*_IMAGE`. The one exception is
  `VIRT_OPERATOR_IMAGE`, which is digest-only because virt-operator parses it into the operand version.
- `vendor/SHA256SUMS`: checksums of the vendored files.

Bump: edit `version`/`source`/`sha256` in the lock, then run
`python3 -I hack/vendor.py resolve && python3 -I hack/vendor.py rebuild`, review the diff,
and run the tests. Before bumping KubeVirt, check the support matrix and the
virt-launcher base: r415's Opteron is x86-64-v2, so a CentOS Stream 10 based launcher
would not run there.

## Tests

```sh
charts/virtual-devices/tests/run.sh                 # offline
VD_ONLINE=1 charts/virtual-devices/tests/run.sh     # + byte-identical rebuild from upstream
```
