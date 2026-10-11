# virtual-devices

Runtime for Teknoir virtual devices: [KubeVirt](https://kubevirt.io) and
[CDI](https://github.com/kubevirt/containerized-data-importer), plus two small pieces of
platform configuration. Deployed by `charts/app-of-apps` (Application `virtual-devices`) for the
S1 spike on `teknoir-cloud`; see `hack/virtual-device-spike/README.md`.

| Object | Notes |
|---|---|
| KubeVirt operator, `KubeVirt` CR | v1.8.4 (k8s 1.34-1.35). No feature gates; serial console log disabled; 2 infra replicas; uninstall blocked while VMs exist. |
| CDI operator, `CDI` CR | v1.65.0. Feature gate `HonorWaitForFirstConsumer` (local-path); explicit worker pod resources for quota budgeting; 2 `cdi-apiserver` replicas; uninstall blocked while DataVolumes exist. |
| PriorityClass `teknoir-virtual-device` | `-100`, `preemptionPolicy: Never`: below every platform pod, never preempts. |
| `kube-system/coredns-custom` key `virtual-devices.override` | `(mqtt\|deadend)-<ns>.<domain>` answer with the `istio-ingressgateway-public` ClusterIP, so a VM reaches EMQX and deadend through the public gateway like an external device. This chart owns the ConfigMap. |

## When it is deployed

The Application renders only when **both** gates hold:

1. `virtualDevices.enabled: true` in `charts/app-of-apps/values.yaml` (a missing key is off);
2. the environment (`project`) is in the allowlist in `charts/app-of-apps/templates/virtual-devices.yaml`,
   which is `teknoir-cloud` only.

The environment branches are kept in step by cherry-pick. The allowlist sits in the
template, so it travels with any cherry-pick: on `teknoir-online` (production) or
`teknoir-local` (airgapped) the Application does not render even if the flag comes along.
An environment that is not listed renders nothing rather than failing, because a failed
render of the root app-of-apps would stop every Application of that environment from
syncing. The `teknoir-cloud` opt-in is its own last commit, so the chart commits can be
cherry-picked without enabling anything. `tests/run.sh` checks the guard for every other
environment name.

The Application syncs with server-side apply and server-side diff, prune and selfHeal, and
retries a failed sync 10 times with backoff (30 s to 5 min), the same as `teknoir-local`.
The k3d e2e syncs it with Argo CD v3.5.1, the version r415 runs, and checks that Argo CD
and the operators do not fight (see `hack/virtual-device-spike/README.md`). It found one
fight: cdi-operator rewrites the `spec.versions` of its own CRD `cdis.cdi.kubevirt.io` (it
drops the deprecated `v1alpha1` that the v1.65.0 release manifest still ships), and
selfHeal put it back every few minutes. The Application therefore ignores that one field
(`ignoreDifferences` with `RespectIgnoreDifferences=true`, so a sync keeps the operator's
value). The KubeVirt CR also leaves out `developerConfiguration` while there are no
feature gates: `featureGates` is `omitempty` in the KubeVirt API types, so any typed write
by the operator drops an empty list, which Argo CD would see as drift. `tests/assertions.py`
rejects empty structs and an empty `featureGates`. A single partial selfHeal of the KubeVirt
and CDI CRs in the same second as the first sync is not a fight: Argo CD acts on the
refresh right after its last wave created them, before its cluster cache has the watch
events of the two new objects, so they read as missing; it re-applies them unchanged (the
e2e's timelines and the controller log show it before either operator has written them,
and a server-side dry-run diff of the CRs finds no drifting field).

## Replicas

`virt-api` (two aggregated `subresources.kubevirt.io` APIServices and the KubeVirt
webhooks) and `cdi-apiserver` (`v1beta1.upload.cdi.kubevirt.io` and the CDI webhooks) run
two replicas each, and `virt-controller` does too. While no pod behind an aggregated
APIService is ready, API discovery is incomplete for every client in the cluster, which
stalls namespace deletion and garbage collection. With two replicas, one pod's crash, OOM
kill or eviction no longer causes that. A rolling update was already safe with one replica
(surge first), and a node restart takes both down anyway.

The cost on r415 is about 0.9 GiB of extra memory requests, on a node with 252 GiB.
KubeVirt also adds PDBs (`minAvailable: 1`) for virt-api and virt-controller. They would
block draining the single node, but r415 cannot be drained today anyway: the keycloak,
backstage and oauth2-proxy PDBs allow 0 disruptions.

## Rollback and removal

Turning the flag off removes only the Application, because there is no resources
finalizer. KubeVirt, CDI, their APIServices and webhooks, both PriorityClasses and
`kube-system/coredns-custom` stay in place, so the cluster-wide `mqtt-`/`deadend-` DNS
rewrite stays active too. Removing the runtime is a manual procedure, and its order
matters: delete the CRs while the operators still run. See "Rollback and removing the
runtime" in `hack/virtual-device-spike/README.md`, and check the result with
`check.sh --phase removed`.

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
