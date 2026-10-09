# Virtual-device S1 spike kit (r415)

The S1 spike answers one question before any controller code is written: does a
virtual device on KubeVirt, bootstrapped by the **real tnctl server script**, come
online on staging (r415) like a physical device, inside the isolation the design
promises? (Design section 8 "S1"; critique "S1 spike on r415".)

The kit has three parts. None of them changes the cluster:

| Part | What it does |
|---|---|
| `render.sh` | Renders the manifests for one test Device: the `<teamspace>-vdev` namespace with its policies, a cloud-init Secret holding the tnctl bootstrap, and a KubeVirt VirtualMachine. They go into a private `0700` directory. It never applies anything and never prints a secret. |
| `manifests/teknoir-demo-vdev.yaml` | The runtime namespace for `teknoir-demo` as `render.sh --namespace-only` renders it, committed for review. It sets PSA `baseline`, turns off Istio injection, adds a default-deny NetworkPolicy with minimal egress, and a ResourceQuota and LimitRange sized with the KubeVirt/CDI overhead. |
| `check.sh` | Runs the S1 checks. Toward the cluster it only uses `kubectl get/describe/logs/version/auth can-i`, which the `kc` wrapper enforces. In the guest it reads state and makes TCP connection attempts over SSH through the device's own reverse tunnel. |

The cluster side is deployed by `charts/virtual-devices`, which the same PR adds. The
PR's last commit enables it for `teknoir-cloud`, and the app-of-apps template renders it
on no other environment (see the chart README). It contains KubeVirt v1.8.4 and CDI
v1.65.0 (vendored and pinned), PriorityClass `teknoir-virtual-device`, and the CoreDNS
override for `mqtt-`/`deadend-<ns>.teknoir.cloud`.

**Why the kit lives here.** It is not part of any deployed chart: Argo CD only reads `charts/*`, so
`hack/` is never synced. It sits next to `charts/virtual-devices` because its namespace
manifest is the prototype of the per-allowance template that chart will render in
Phase 1a (critique #11). The two are reviewed and changed together. This repository is
**public**, so the kit holds no secret, IP plan or credential; every environment value
is read at run time.

## What is pinned

| Input | Pin | Where |
|---|---|---|
| KubeVirt | v1.8.4 (supports k8s 1.34-1.35), every image by digest | `charts/virtual-devices/vendor/upstream.lock.yaml` |
| CDI | v1.65.0 (the HCO release-1.18 pairing for KubeVirt 1.8.4), every image by digest | same |
| Bootstrap | tnctl `pkg/templates/server.sh.tmpl` + partials at cli `7bb1bea` | `lib/pins.sh` (`VDS_CLI_REF`) |
| Inner k3s | `v1.34.11+k3s1` via `INSTALL_K3S_VERSION`: the last 1.34 patch that starts with the tnctl custom CA (see Finding) | `lib/pins.sh` |
| Inner CIDRs | `--cluster-cidr=10.52.0.0/16 --service-cidr=10.53.0.0/16 --cluster-dns=10.53.0.10` via `INSTALL_K3S_EXEC` | `lib/pins.sh` |
| Root disk | `quay.io/containerdisks/debian:13-2610020212` by digest (Debian 13 **genericcloud** 20261001-2618), CDI `pullMethod: node` | `lib/pins.sh` |
| Root disk, alternative | `--disk generic`: Debian 13 **generic** 20261001-2618 qcow2 over HTTPS, SHA512-verified by CDI | `lib/pins.sh` |
| Probe image | `busybox:1.37.0` by digest (only for `--inner-pod`) | `lib/pins.sh` |

The bootstrap is not forked. `render.sh` compiles a short renderer
(`renderer/main.go`) against the cli repo's own `pkg/templates` at the pinned commit
and fills `TemplateData` exactly as `tnctl bootstrap` does: the keys come from the
Device, there is a random k3s token, and `DockerSecret` is empty. The only additions are
environment variables the script already honours. `--source tnctl` runs the literal
`tnctl bootstrap <device> --skip-upload` instead, which needs `tnctl login`.

**genericcloud vs generic** (critique #9). The containerdisks image is built from Debian's
`genericcloud` image (cloud kernel), not `generic`. The k3d e2e found that kernel enough
(see below), and G7/G8 confirm it on r415. If it is not, re-render with `--disk generic`.

## Finding: k3s >= 1.34.12 and the tnctl custom CA (affects real devices too)

Found by the k3d e2e on 2026-10-09:
- **Symptom.** With `INSTALL_K3S_VERSION=v1.34.12+k3s1`, the inner k3s server never became ready. The bootstrap hung in `systemctl restart k3s` (the unit has no start timeout). Every 2 s k3s logged `Failed to validate connection to cluster at https://127.0.0.1:6443: CA cert validation failed: ... x509: certificate signed by unknown authority`. `openssl verify` and `curl --cacert` accept the same chain.
- **Cause.** k3s commit 6c7a974 ("Improve CA hash validation", 2026-09-24) shipped in **v1.34.12, v1.35.9 and v1.36.5** (2026-09-30). Its `appendCertsFromPEM` drops every CA certificate without the `keyCertSign` key usage before choosing roots. The tnctl `server.sh.tmpl` (and bootstrap-device `05_tn_install_k3s.sh`) installs the device certificate `rsa_public` as `server/tls/root-ca.pem`. Backstage creates that certificate with `openssl req -x509` and no `-addext keyUsage`, so it carries no key usage at all. The r415 devices `rpi4-white-se`, `rtx2000-ada-128gb-se` and `orin-agx-32gb-se` all have only `basicConstraints CA:TRUE` (checked read-only on their public certificates). The root is dropped, the pool is empty, and validation fails.
- **Impact beyond the spike.** `get.k3s.io` serves stable = v1.36.5. A **real** device bootstrapped today with `tnctl bootstrap` without `INSTALL_K3S_VERSION` should hang the same way. This was not tested on hardware. Also untested: whether an existing device breaks when its k3s is upgraded to an affected release and restarted.
- **Spike handling.** Pin `v1.34.11+k3s1`. `render.sh` refuses an affected k3s version when the device certificate lacks `keyCertSign`. Check G9b names the condition if it happens anyway.
- **Fix options (outside this kit):**
  1. In the template, before installing the CA, re-issue the root certificate from the device key with `keyUsage=critical,keyCertSign,cRLSign,digitalSignature` (`openssl req -x509 -new -key rsa_private.pem ...`). The key does not change, so it also works for existing devices.
  2. In Backstage and the controller fallback, add `-addext keyUsage=...` when generating device certificates. This covers new devices only.
  3. Pin `INSTALL_K3S_VERSION` in tnctl. This is a stopgap.

## What the k3d e2e already answered (2026-10-09)

`test/k3d-e2e.sh` ran the chart and the kit end to end on a throwaway k3d cluster: k3s
v1.34.5 like r415, KVM from an Ubuntu host with `/dev/kvm` `0660 root:kvm`, and k3s's
default containerd. The results below were measured there. Anything that depends on
r415 itself is still open for the spike: the Opteron CPU and its speed, the
svclb/kube-proxy path, `/var` space, the real EMQX, deadend and device-controller, and
the tunnel.

| Question | k3d result |
|---|---|
| Chart deploys in Argo CD wave order | Synced by Argo CD v3.5.1 (the version on r415) from the Application as app-of-apps renders it: the first sync took 20-30 s with no retry, and KubeVirt and CDI were `Deployed` about 2 minutes later. Every running image was pinned by digest, including the operands the operators create. |
| Argo CD and the operators fight? | Not with this chart. The first Argo CD run found one fight: cdi-operator and selfHeal kept rewriting the `spec.versions` of the CRD `cdis.cdi.kubevirt.io`. The Application now ignores that field, and the KubeVirt CR carries no empty `featureGates` list (it is `omitempty` in the API, so an operator write would drop it). In the final run, counted from the Application's events, Argo CD ran exactly two operations in 11 minutes: the first automated sync and the forced re-sync. Nothing went OutOfSync and no generation moved, over 210 s after the operators were `Deployed` and 330 s after the re-sync. One earlier run saw a single partial selfHeal of the KubeVirt and CDI CRs right after the first sync, while the operators were filling them in. It ended with the same generations as the other runs. |
| Rollback and removal | Deleting the Application (the flag off) leaves the runtime and the DNS rewrite in place. Removal in the order of step 10 leaves no CRD, aggregated APIService, webhook, RBAC, PriorityClass or `coredns-custom`, and API discovery stays complete. CDI's upload APIService and webhooks were still there right after `delete cdi` returned, so step 2 waits for them. |
| Non-root virt-launcher and `/dev/kvm` | Works. The launcher runs as uid 107 with only `NET_BIND_SERVICE`, and the guest reports `systemd-detect-virt=kvm`. libvirt logs one harmless `Unable to open /dev/kvm` from an early CPUID probe; V10 ignores it and G6b is the real check. |
| PSA `baseline` | virt-launcher and the CDI importer are admitted under `enforce=baseline`. |
| CDI with local-path WaitForFirstConsumer | Works with `HonorWaitForFirstConsumer`: a temporary launcher pod triggers binding, then the importer runs with `pullMethod: node`. CDI has no StorageProfile defaults for `rancher.io/local-path`, so the VM's explicit `accessModes`/`volumeMode` are required. |
| Quota headroom | A 4 Gi guest gets a launcher with requests and limits of 4592762881 B, about 283 MiB of overhead on both. A 20 Gi disk becomes a 21.2 Gi PVC because of CDI's 5.5% filesystem overhead. The quota allows +1 Gi and 1.1x per device, which leaves room for a second Small. |
| genericcloud kernel (critique #9) | Enough. `k3s check-config` reports `STATUS: pass`, and overlay, br_netfilter, vxlan, nf_tables and the iptables modules all load (kernel 6.12.111+deb13-cloud-amd64). `--disk generic` stays available as a fallback. |
| Inner CIDRs | Services are on 10.53/16 with kube-dns at 10.53.0.10, and pods on 10.52.0.0/24. The guest's resolver chain is systemd-resolved, then the outer kube-dns. |
| CoreDNS override | Took effect **without** a CoreDNS restart once the ConfigMap existed. The guest and inner pods resolve `mqtt-`/`deadend-teknoir-demo.teknoir.cloud` to the gateway ClusterIP. |
| Isolation (critique #16) | I1-I11 are blocked and I12-I15 are reachable, from the guest shell **and** from an inner pod. |
| Inner k3s and the tnctl custom CA | k3s v1.34.11 works. v1.34.12 does not (see Finding). |
| virtctl access | `virtctl port-forward/ssh` is dialed by virt-api and is blocked by default-deny. Use `--allow-virtctl-ssh`. |
| Time to online | The bootstrap finished 56 s after the VM was created: disk import 36 s, then boot and bootstrap 20 s. TOE started at +75 s. The stand-in gateway is not EMQX, so the TOE cloud connection, `Connected` and Last Seen remain for r415. |

## Who does what

Steps marked **[Anders]** change staging or need his accounts. Everything else is
read-only and can be run by anyone with the `r415` context, including Claude.

| # | Step | Who |
|---|---|---|
| 1 | Merge the gitops PR into `teknoir-cloud`. This deploys KubeVirt and CDI on r415. | **[Anders]** |
| 2 | Platform checks (`--phase platform`) | anyone |
| 3 | Create the test Device in Backstage | **[Anders]** |
| 4 | Render the manifests and review them | anyone with r415 read access (reads the Device's keys) |
| 5 | Apply the namespace, Secret and VM | **[Anders]** (approval to apply) |
| 6 | Enable a tunnel for the test Device in Backstage | **[Anders]** |
| 7 | Run all checks, open the web terminal, and record the results | anyone (the browser step needs a signed-in session) |
| 8 | Go/no-go | **[Anders]** |
| 9 | Clean up the test device | **[Anders]** |
| 10 | Only if the runtime goes away: roll back and remove it in order | **[Anders]** |

Tools on the machine running the kit: `kubectl` (context `r415`), `jq`, `git`, `go`,
`base64`, `ssh` and `ncat` (or `openssl`). `python3` with PyYAML and `kubeconform` are
needed only for the tests.

## Runbook

### 1. [Anders] Merge the gitops PR

When the PR merges into `teknoir-cloud`, Argo CD creates the Application
`virtual-devices`. It applies the operators and RBAC first, then the KubeVirt and CDI CRs in
sync wave 1, plus PriorityClass `teknoir-virtual-device` and `kube-system/coredns-custom`.
That ConfigMap has one key, `virtual-devices.override`; r415 had no `coredns-custom` before.
The images are about 2 GB, pulled to `/opt` (imagefs). The operators need a few minutes.

Turning `virtualDevices.enabled` off later removes only the Application, because it has
no resources finalizer. KubeVirt, CDI, both PriorityClasses and `kube-system/coredns-custom`
stay, and so does the DNS rewrite. Removal is step 10.

### 2. Platform checks

```sh
hack/virtual-device-spike/check.sh --phase platform
```

Expect the following:
- P1: Kubernetes v1.34.
- P2: `virtual-devices` Synced/Healthy.
- P3: KubeVirt `Deployed` v1.8.4.
- P4 and P5: no feature gates, serial console log off.
- P6: CDI `Deployed` v1.65.0.
- P7 and P8: all pods ready, and every running image pinned by digest.
- P9: `devices.kubevirt.io/kvm` allocatable on `r415`. The host-model CPU label shows what KubeVirt detected on the Opteron 4332 HE.
- P10: PriorityClass -100/Never.
- P11: the override is present.
- P13: free space on `/var`. It was 3.6 GiB at design time, so expect a WARN.
- P14: the aggregated KubeVirt and CDI APIServices are Available.
- P15: two ready replicas each of virt-api, virt-controller and cdi-apiserver.

This is the first Argo CD sync on r415; the k3d e2e ran the same Application against the
same Argo CD version. P2 must stay Synced. Repeated syncs after the first one mean Argo CD
and an operator fight over a field. The Application's events list every sync operation,
including partial selfHeal syncs:
`kubectl --context r415 -n teknoir-system get events --field-selector involvedObject.name=virtual-devices`.

The rewrite itself is proven later from inside the guest (G14). CoreDNS's `reload`
plugin may not notice a newly created `coredns-custom`. If G14 fails, run step 5b.

### 3. [Anders] Create the test Device in Backstage

In teamspace **teknoir-demo**, open Devices, then Add Device, and fill in:
- **Name:** for example `vd-s1-spike`, at most 58 characters.
- **Hardware:** **Generic PC(AMD64/X86_64)** (`generic-x86_64`).
- **User:** keep the generated password. Adding your own public SSH key is optional.

Do **not** choose "Virtual" while r415 runs the current device-controller
(`applicationset@9780e40`). Its 2024 VirtualDevice plugin would create a privileged
`virtual-device-<name>` Deployment for `device_type: virtual`. Choose "Virtual" only
once the Phase 0 controller gate is deployed. `render.sh` refuses to render if that
Deployment exists, and check V0 reports it.

Do not add the label `device-group: test`. The `devstudios` and `notebook`
DeviceApplicationSets in `teknoir-demo` select on it; check D7 lists any that match.

The device-controller then registers the key in JWKS and publishes the retained
config, as it does for a real device.

### 4. Render and review

```sh
hack/virtual-device-spike/render.sh --device vd-s1-spike
```

This reads the Device with `kubectl get` and prints a summary. The last line of stdout
is the private output directory, for example `/tmp/vd-spike.Ab12Cd34`. Review
`00-namespace.yaml` and `20-vm.yaml` there. `10-cloudinit-secret.yaml` holds the device key,
the device user's password and the k3s token, with mode `0600`. Do not copy it anywhere.

Useful options:
- `--cpu/--memory-gi/--disk-gi`: defaults to the Small preset, 2/4/20.
- `--disk generic`
- `--cpu-model Opteron_G5`: only if the VM does not schedule with KubeVirt's default `host-model`.
- `--source tnctl`
- `--debug-user`: adds a break-glass guest user `vdspike` with the device's SSH key and passwordless sudo. Without it, nothing can log in until the bootstrap creates the device user at its very end, so a hung bootstrap cannot be inspected; the serial console shows only a login prompt.
- `--allow-virtctl-ssh`: allows ingress to port 22 from the `virt-api` pods. In KubeVirt 1.8, `virtctl port-forward`/`ssh` is dialed by virt-api to the VM's pod IP, and the default-deny policy blocks it (the e2e found this).

### 5. [Anders] Apply

Use the commands from `summary.txt`:

```sh
kubectl --context r415 apply  -f <out>/00-namespace.yaml
kubectl --context r415 create -f <out>/10-cloudinit-secret.yaml   # create, not apply
kubectl --context r415 create -f <out>/20-vm.yaml
rm -rf <out>
```

Use `kubectl create` for the Secret. `kubectl apply` would copy the whole Secret,
including the key, into its `last-applied-configuration` annotation, and `kubectl
describe` would print it.

What happens next:
- CDI waits for the VM's pod to be scheduled (WaitForFirstConsumer).
- r415's containerd then pulls the containerdisk and imports it into a 20 Gi local-path PVC under `/opt`.
- The VM boots and cloud-init installs `qemu-guest-agent`.
- The tnctl bootstrap runs: keys, a k3s CA rooted at the device key, k3s `v1.34.11` with inner CIDRs 10.52/10.53, the TOE manifests, and the device user.

Watch progress with:

```sh
hack/virtual-device-spike/check.sh --device vd-s1-spike --phase namespace,vm
```

**5b. CoreDNS.** If G14 later reports that `mqtt-teknoir-demo.teknoir.cloud` does not
resolve to the gateway ClusterIP, CoreDNS has not loaded the new ConfigMap. To fix it, run
`kubectl --context r415 -n kube-system rollout restart deploy/coredns`. This is an
**[Anders]** action. The k3d e2e (see Tests) records whether a restart was needed.

### 6. [Anders] Enable a tunnel for the test Device

In Backstage, open the device page and enable remote access with a tunnel. The
AuthorizedKeys plugin adds the device key to deadend. DeviceConfig adds the
`reverse-tunnel` Deployment to the device's config, and TOE applies it inside the VM.
`check.sh` uses this path, the one `tnctl ssh` uses, for every guest check. It
therefore proves the tunnel works without `pods/exec` or port-forward rights on r415.
`--transport virtctl` is the fallback. It needs `virtctl`, port-forward rights and a render
with `--allow-virtctl-ssh`, so it is not read-only. Before the device user exists (or if
the bootstrap hangs), add `--guest-user vdspike`, which needs a render with `--debug-user`.

### 7. Run the checks

```sh
hack/virtual-device-spike/check.sh --device vd-s1-spike --phase all --inner-pod
```

Pass `--wait-online 15` to poll the Device for TOE metrics first. For Last Seen and the
size the device reports, pass `--prom-url`. That needs a port-forward, an **[Anders]** action:

```sh
kubectl --context r415 -n teknoir-demo port-forward svc/prometheus 9090:80
# then: --prom-url http://127.0.0.1:9090/teknoir-demo/prometheus
```

Web terminal: in Backstage, open the device page and then the web terminal. A shell on
`vd-s1-spike` must open. Check in the browser per CLAUDE.md: the console and network show
no errors, and take a screenshot.

**Record:**
- the full `check.sh` output;
- the timing table (phase `timing`);
- the CPU model label (P9);
- whether a CoreDNS restart was needed (5b);
- the G7 check-config result for genericcloud, and for `--disk generic` if you re-ran with it;
- I16 and I17 (see below).

#### S1 checks and where they are

| S1 question (design section 8 + critique) | Check |
|---|---|
| The KubeVirt release supports k8s 1.34 | P1 |
| KubeVirt `Deployed`; `/dev/kvm` allocatable | P3, P9 |
| A non-root virt-launcher can open `/dev/kvm` (Debian: `0660 root:kvm`; k3s containerd `device_ownership_from_security_context=false`) | V7 + V8 (VMI Running with emulation off), V10 |
| No AppArmor problems on Debian 13 | V4, V10 (launcher log scan) |
| virt-launcher passes PSA `baseline` | N1 + V6 (pod admitted under `enforce=baseline`) |
| CDI imports with local-path WaitForFirstConsumer | V2, V3 (`selected-node` set, PVC Bound) |
| Serial-console logging off | P5, V9a |
| Quota headroom (KubeVirt and CDI overhead) | N4, V9d, V11, V11b, V12 (any `exceeded quota` events) |
| VMI Running, guest agent connected | V4, V5 |
| The guest sees exactly the VM size | G3 |
| tnctl bootstrap succeeds; `k3s check-config` passes; genericcloud kernel modules | G5, G7, G8 |
| Inner k3s starts with the device-rooted custom CA (the k3s >= 1.34.12 finding) | G9, G9b |
| Inner k3s on 10.52/10.53, version pinned | G9, G10 |
| A virt-api or cdi-apiserver restart does not break API discovery | P14, P15 |
| TOE connects (TOE log) and Last Seen updates (platform) | G12; D2; D5 with `--prom-url` |
| Reverse tunnel works; web terminal works | G1 (SSH through deadend and the device's tunnel), D3, D4; web terminal in the browser |
| DNS rewrite vs hairpin | G14 (guest resolves to the gateway ClusterIP); I17 (public IP of the mqtt name, `open` means the router hairpins) |
| Which pod the LB VIP is DNATed to | I16 (node IP:8883 from the guest: `open` means kube-proxy DNATs the VIP to the gateway pod, which the policy allows; `closed` means the svclb/hostPort path, which the policy blocks) |
| Isolation probes from the guest **and** an inner pod, by IP (critique #16) | I1-I15, repeated with `--inner-pod` |
| Teamspace users cannot read the cloud-init Secret | N6; N7 reports the known Backstage hole (critique #1) |
| Time to online on Piledriver | T1 and the timing table (VM created, disk imported, VMI Running, guest boot, bootstrap, TOE `mqtt connection up`) |

### 8. [Anders] Go/no-go

**Go** for Phase 1a if all of the following hold:
- there are no FAILs other than D5 without `--prom-url`;
- TOE comes online;
- the web terminal works;
- I1-I11 are blocked from both the guest and the inner pod;
- time to online is acceptable on Piledriver. The design expects 5-10 minutes for the first boot.

Each failure has a known fallback:

| Failure | Fallback |
|---|---|
| G7/G8 (genericcloud kernel) | `--disk generic` |
| VM unschedulable on host-model CPU | `--cpu-model Opteron_G5` |
| PSA `baseline` refused | Set `enforce` to `privileged`, keep `warn`/`audit` at `baseline`/`restricted`, and document the violations from the events |
| `/dev/kvm` permission denied | A k3s containerd config template with `device_ownership_from_security_context = true`, or a udev rule on r415. Both are host changes for Anders. |
| G14 | Step 5b |

### 9. [Anders] Clean up

```sh
kubectl --context r415 -n teknoir-demo-vdev delete vm vd-s1-spike        # also removes the VMI and the root DataVolume/PVC
kubectl --context r415 -n teknoir-demo-vdev delete secret vd-s1-spike-cloudinit
kubectl --context r415 delete namespace teknoir-demo-vdev
```

Then delete the test Device in Backstage. The finalizer revokes the JWKS key and the
deadend key. Its key is a real platform credential that also sat in the VM, so do
not keep the Device around. The runtime (KubeVirt, CDI, the PriorityClasses and the
CoreDNS rewrite) stays; step 10 removes it.

### 10. [Anders] Rollback and removing the runtime

There are two levels.

**Rollback.** This stops Argo CD from managing the runtime. Set
`virtualDevices.enabled: false` in `charts/app-of-apps/values.yaml` on `teknoir-cloud`
(or revert the enable commit) and merge. Argo CD prunes the `virtual-devices` Application.
It has no resources finalizer, so **everything else stays**: KubeVirt, CDI, their
APIServices and webhooks, PriorityClasses `kubevirt-cluster-critical` and
`teknoir-virtual-device`, and `kube-system/coredns-custom` with the cluster-wide
`mqtt-`/`deadend-<ns>.teknoir.cloud` rewrite. The k3d e2e confirms this.

**Removal.** It starts with the rollback; otherwise selfHeal re-creates what you delete.
The order matters:
- The operators remove what they created only while they run, and only when their CR is
  deleted. That covers virt-api and cdi-apiserver, the aggregated APIServices
  (`subresources.kubevirt.io`, `upload.cdi.kubevirt.io`), their webhooks, CRDs and
  ClusterRoles. Part of it goes only after the CR itself is gone, so step 2 waits for it.
- If the operators go first, the APIServices stay behind without a backend. API discovery
  then fails for every client, which stalls namespace deletion and garbage collection
  cluster-wide. Stale webhooks also reject writes to the objects they match.

```sh
CTX=r415
# 0. After the rollback: the Application is gone.
kubectl --context $CTX -n teknoir-system get applications.argoproj.io virtual-devices   # NotFound

# 1. No virtual devices: delete the VMs (their VMIs and DataVolumes go with them) and
#    the runtime namespaces. Both CRs refuse to uninstall while workloads exist.
kubectl --context $CTX get vm,vmi,dv -A
kubectl --context $CTX -n teknoir-demo-vdev delete vm --all --wait
kubectl --context $CTX delete namespace teknoir-demo-vdev --wait
kubectl --context $CTX get vm,vmi,dv -A          # must print nothing

# 2. Delete the CRs while the operators still run. Each delete returns once its CR is
#    gone, but not everything goes with it: CDI's aggregated upload APIService and its
#    webhooks were still there right after 'delete cdi' returned in the k3d e2e.
kubectl --context $CTX -n kubevirt delete kubevirt kubevirt --wait --timeout=10m
kubectl --context $CTX delete cdi cdi --wait --timeout=10m
#    Wait until no aggregated APIService and no KubeVirt/CDI webhook is left. "Local"
#    APIServices belong to CRDs and are harmless: those of kubevirts.kubevirt.io and
#    cdis.cdi.kubevirt.io (the chart ships both CRDs) stay until step 3. If this times
#    out, stop (see the notes below).
timeout 5m sh -c "until [ -z \"\$(kubectl --context $CTX get apiservices | grep kubevirt.io | grep -v Local)\" ] &&
  [ -z \"\$(kubectl --context $CTX get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -E 'virt|cdi')\" ];
  do sleep 10; done" && echo "operands gone"

# 3. Remove the rest of what the chart created: the operators with their namespaces,
#    CRDs and RBAC, both PriorityClasses, and kube-system/coredns-custom. Run it from
#    the commit that was deployed.
helm template virtual-devices charts/virtual-devices --namespace kubevirt \
  --show-only templates/kubevirt-operator.yaml --show-only templates/cdi-operator.yaml \
  --show-only templates/priorityclass.yaml --show-only templates/coredns-custom.yaml |
  kubectl --context $CTX delete --ignore-not-found --wait --timeout=10m -f -

# 4. Verify. This step is read-only.
kubectl --context $CTX get apiservices | grep kubevirt   # must print nothing
hack/virtual-device-spike/check.sh --context $CTX --phase removed
```

Notes:
- **`coredns-custom`.** The chart owns the whole ConfigMap, so step 3 deletes any other
  key someone added. Before step 3, look at its keys with
  `kubectl --context r415 -n kube-system get configmap coredns-custom -o jsonpath='{.data}'`.
  Check R7 confirms the key is gone. In the k3d e2e CoreDNS stopped rewriting the
  `mqtt-` name without a restart, as it had picked the ConfigMap up without one.
- **Operators removed while a CR still exists.** Nothing removes the operands then. Apply
  the operator again so it can process the deletion:
  `helm template ... --show-only templates/kubevirt-operator.yaml | kubectl apply --server-side -f -`
  (or `cdi-operator.yaml`), wait for the CR to go, then continue with the wait in step 2.
- **Aggregated APIServices or webhooks still there after the wait in step 2,** or after the
  operators went first. R3 names the stale APIServices and R4 the stale webhooks. Their
  backends are gone, so they only break API discovery and writes. Delete each one with
  `kubectl delete apiservice <name>` or
  `kubectl delete validatingwebhookconfiguration|mutatingwebhookconfiguration <name>`.
- **Node leftovers.** virt-handler labels the node with the CPU models and features
  KubeVirt detected (413 `*.kubevirt.io` labels on the k3d node), adds two `kubevirt.io`
  annotations, and registers the extended resources `devices.kubevirt.io/kvm`, `tun` and
  `vhost-net`. Nothing reads them once KubeVirt is gone, and R10 lists them as INFO.
  In the k3d e2e the extended resources were allocatable 0 as soon as virt-handler was
  gone, so nothing can be scheduled against them; their capacity stays listed in the node
  status until the kubelet drops it or k3s restarts. To remove the labels and annotations:

  ```sh
  NODE=r415
  kubectl --context $CTX label node $NODE $(kubectl --context $CTX get node $NODE -o json |
    jq -r '.metadata.labels | keys[] | select(test("kubevirt\\.io")) | . + "-"')
  kubectl --context $CTX annotate node $NODE $(kubectl --context $CTX get node $NODE -o json |
    jq -r '.metadata.annotations | keys[] | select(test("kubevirt\\.io")) | . + "-"')
  ```

## Security notes for the spike

- **Spike only in `teknoir-demo` (internal).** Backstage's `backstage-api`
  ServiceAccount can still read Secrets in `teknoir-demo-vdev` through the Kubernetes
  proxy (critique #1; fixed in release r5). Teamspace members already have root on the node
  through privileged notebooks (critique #2). The KVM boundary protects the platform from code
  inside the device, not from teamspace members.
- **Same secrets as a real device.** The device key and password sit in the Device CR
  and the Backstage catalog, exactly as for real devices. The k3s token ends up in the
  guest's k3s systemd unit, also as on real devices.
- **The cloud-init Secret** lives only in `teknoir-demo-vdev`. No teamspace user has a
  RoleBinding there (N6). The serial console is not copied into pod logs (P5, V9a).
- **`check.sh` reads the Device's keys** with `kubectl get`. It keeps them in a `0700`
  temporary directory that it removes on exit. The password reaches the guest only on
  ssh's stdin, for `sudo`. Host keys are not verified, the same as `tnctl ssh`.

## Tests

```sh
hack/virtual-device-spike/test/run.sh        # offline: shellcheck, dry render against a fixture, kubeconform, check.sh (all phases and removed) against a fake kubectl
charts/virtual-devices/tests/run.sh          # offline: vendored pins, helm lint/template, kubeconform with CRD schemas, assertions, app-of-apps guard and Application spec
VD_ONLINE=1 charts/virtual-devices/tests/run.sh   # + byte-identical rebuild of the vendored manifests from upstream
flock <heavy.lock> hack/virtual-device-spike/test/k3d-e2e.sh   # HEAVY: throwaway k3d + KVM + Argo CD, chart + kit + check.sh + removal end to end
```

The k3d e2e runs everything except what needs r415 itself: the real device-controller, EMQX and
deadend, and the Opteron CPU. It replaces those with stand-ins, renders with
`--allow-virtctl-ssh --debug-user` and uses `--transport virtctl`. On a Debian/Ubuntu host it
reproduces the `/dev/kvm` `0660 root:kvm` and k3s-containerd conditions the critique asks about.

Argo CD is real: v3.5.1, the version r415 runs, with r415's `argocd-cm` sync settings. It
syncs the `virtual-devices` Application as `charts/app-of-apps` renders it for `teknoir-cloud`.
Only `spec.source` differs, because the branch is not on GitHub: Argo CD reads the same chart
from an in-cluster Helm repository, rendered the same way (release name, namespace, values).
After the sync, the e2e:
- watches for a fight between Argo CD and the operators over r415's reconciliation window
  (210 s): OutOfSync resources, any sync operation (counted from the Application's events,
  so a partial selfHeal counts too), or spec writes to the CRs, CRDs, operator Deployments,
  `coredns-custom` and PriorityClasses;
- forces a full re-sync and watches again for 330 s;
- at the end, deletes the Application (the flag-off rollback), checks the runtime stays, and
  runs the step 10 removal, including its wait for the aggregated APIServices and
  webhooks, followed by `check.sh --phase removed`.

The last run (2026-10-09) passed: the Argo CD checks above, check.sh with only the three
FAILs the stand-ins cannot satisfy (D2, G12, T1), and the removal with all R checks passing.
