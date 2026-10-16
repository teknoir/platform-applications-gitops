# ztna

GitOps for **WireGuard over STUNner**, the ZTNA alternative to the SSH reverse tunnels. Design:
`plans/wireguard-ztna-tunnel.md` (rev 3); wire contract: `github.com/teknoir/wg-tunnel` `pkg/api/api.go`.
Staging (`teknoir-cloud`, r415) only. The legacy SSH tunnel (deadend, port 2222) has been removed on staging; WireGuard replaces it.

Three new charts and four touched charts, all behind **one switch**:

| Chart / Application | What |
|---|---|
| `charts/gateway-api-crds` (`gateway-api-crds`) | Gateway API CRDs, standard channel v1.4.1 (the set STUNner 1.2.1 ships), server-side applied, never pruned |
| `charts/stunner` (`stunner`) | STUNner operator 1.2.1 (pinned images), GatewayClass `stunner-gatewayclass`, GatewayConfig, Gateway `teknoir-turn` (TURN-UDP 3478, LoadBalancer via k3s servicelb), `stunner.l7mp.io/v1` UDPRoute `wg-hub` -> `teknoir-ztna/wg-hub:51820` |
| `charts/ztna` (`ztna`) | Namespace `teknoir-ztna` (mesh), wg-hub, wg-flags (flags watcher), headless Service, RBAC, admission policies, VirtualServices `wg` and `wg-device`, AuthorizationPolicy, ServiceMonitor, pull secret copy |
| `charts/device-controller` | `ZTNA` key in the controller ConfigMap, Role in `teknoir-ztna`, CRD `status.wireguard`; plus the `vdev-egress-turn` NetworkPolicy of the virtual devices |
| `charts/virtual-devices` | CoreDNS rewrites `wg-device.<domain>` and `turn.<domain>` |
| `charts/auth` | EnvoyFilter patch: `wg.<domain>:443` bypasses the oauth2-proxy ext_authz and the Lua login redirect (the hub validates the Keycloak token itself; the redirect turned its JSON 401/403 into a 302) |
| `charts/backstage` | `teknoir.ztna.enabled: true` in the app-config ConfigMap and `APP_CONFIG_teknoir_ztna_enabled=true` in the frontend env |

There are **no Argo sync waves**: a wave makes the whole root app-of-apps wait for the previous wave to be Healthy, so one
failing ZTNA Application would stall every other Application. The order (CRDs, operator, ztna, device-controller's Role) is
covered by retry (10 attempts, 30s to 5m backoff) and `SkipDryRunOnMissingResource`.

## The switch

`charts/app-of-apps/values.yaml`: `ztna.enabled` (default **false**). It renders only when the environment is in
the allowlist in `charts/app-of-apps/templates/_helpers.tpl` (`teknoir-cloud`), so a cherry-pick of the flag onto
`teknoir-online` or `teknoir-local` renders nothing. When on, app-of-apps also passes `ztna.enabled=true` to the
`device-controller`, `virtual-devices`, `auth` and `backstage` Applications (Helm parameters). Flipping it is a values change.

**Before flipping**, once the images exist (these are required; the render of that chart fails without them, so
nothing half-configured is applied):

1. `charts/ztna/values.yaml`: `hub.image.tag` (`<immutable tag>@sha256:<digest>` of `ghcr.io/teknoir/wg-hub`).
2. `charts/device-controller/values.yaml`: `ztna.agentImage` (wg-agent) and `ztna.terminalImage` (WireGuard web terminal).
3. The TURN shared secret exists: `infra/scripts/gen-stunner-auth-secret.sh --context r415` (creates
   `stunner-system/stunner-auth-secret`; not in Git; rotating it resets every tunnel).
4. UDP 3478 is free on the node (`ss -ulpn`) and, for real devices, forwarded on the router.
5. `charts/device-controller` image supports the `ZTNA` config and `status.wireguard` (WP B).

Tests: `charts/ztna/tests/run.sh` (renders everything on and off, kubeconform, structural assertions, helm unittest,
and the admission policies against a throwaway local apiserver).

## What the hub is allowed

- **ClusterRole `wg-hub`**: create `subjectaccessreviews` and `tokenreviews`. **No access to Devices**: RBAC cannot give
  metadata-only access, and a Device carries the legacy RSA private key in `spec.keys`.
- **Role in `teknoir-ztna`**: get/list/watch/create/update/patch ConfigMaps (it reads policy and flags, writes identity
  ConfigMaps only, by admission policy), get ServiceAccounts. No delete, no Secrets.
- **Role in `stunner-system`**: get Secret `stunner-auth-secret` (by name).
- The hub image runs non-root, read-only root file system, all capabilities dropped, RuntimeDefault seccomp,
  no service account token beyond its own, **Recreate** strategy and one replica (STUNner routes to every endpoint
  of the headless Service; two hubs would split the session state).

## The flags watcher (`templates/flags.yaml`)

Deployment `wg-flags` (same image as the hub, args `["flags-watcher"]`, own ServiceAccount, no Service, no ports; an
empty-ALLOW AuthorizationPolicy denies all mesh traffic to it). It is the **only** ZTNA identity that can read Devices
(ClusterRole `wg-flags`: get/list/watch `devices`) and writes the security annotations as
`ztna-flags-<teamspace>.<device>` ConfigMaps (Role `wg-flags` in `teknoir-ztna`: get/list/watch/create/update/patch/delete
ConfigMaps). The hub reads those ConfigMaps, so revocation does not depend on device-controller and a hub compromise does
not expose device keys.

## Admission policies (`templates/admission.yaml`)

Backstage's service account has cluster-wide `teknoir-admin`, so RBAC alone does not protect the policy store.

- `ztna-policy-store`: ConfigMaps labelled `ztna.teknoir.org/policy` or named `ztna-policy-*` are written only by
  `system:serviceaccount:teknoir-system:device-controller-service-account`; `ztna.teknoir.org/identity` or
  `ztna-identity-*` only by `system:serviceaccount:teknoir-ztna:wg-hub`; the hub writes no other ConfigMap.
  A label or name on the old or the new object counts (relabelling does not escape).
  `ztna.teknoir.org/flags` or `ztna-flags-*` only by `system:serviceaccount:teknoir-ztna:wg-flags`, and the hub and the
  watcher write no ConfigMap of the other kinds.
- `ztna-workloads`: CREATE and UPDATE of pods, deployments, replicasets, statefulsets, daemonsets, jobs and cronjobs in
  `teknoir-ztna` and `stunner-system` only by device-controller, ArgoCD's application controller, the stunner operator
  (`admission.workloadCreators` in values) and `system:serviceaccount:kube-system:*` / `system:kube-controller-manager` (the
  replicaset and job controllers create the pods). A compromised UI can neither run its own pod as `wg-hub` nor patch the
  hub image.
- `ztna-no-token-mint`: TokenRequest (`serviceaccounts/token`) for `wg-hub`, `wg-flags` and the terminal accounts `wgt-*`
  only by `system:node:*` (the kubelet's projected tokens) and kube-system identities.
- `ztna-device-annotations` (phase 2): on `devices.teknoir.org` CREATE and UPDATE, any add, change or removal of a
  `ztna.teknoir.org/*` annotation (wireguard enable, approved identity, trusted host key, compromised and health flags,
  reenroll) is denied unless the user is the Backstage backend (`system:serviceaccount:teknoir-system:backstage-api`,
  `backstage.serviceAccount` in values), device-controller, or in the group `system:masters`. Notebook pods run as
  `default-editor`, which can edit Devices and would otherwise bypass the Backstage admin gate. Other annotations and
  DELETE are unaffected, and so is the status subresource. Unlike the other policies, `system:masters` is exempt here.
- `ztna-no-exec`: no `pods/exec`, `pods/attach`, `pods/portforward` CONNECT and no `pods/ephemeralcontainers`
  update in `teknoir-ztna` and `stunner-system`, for anyone (system:masters included; the hub holds session keys in
  memory and stunnerd the TURN secret).
- **ArgoCD is not blocked.** The policy and identity ConfigMaps are written at runtime, not by Git, and the chart
  renders no ConfigMap. **Namespace teardown**: the namespace controller deletes the ConfigMaps as itself, so DELETE is
  allowed while the namespace is `Terminating`. The Namespace itself carries `Prune=false,Delete=false`, so removing the
  Application never deletes the pinned identities.
- **Accepted platform risk**: the policies match `request.userInfo.username`. Backstage's service account holds a
  cluster-wide `teknoir-admin`, which includes impersonating ServiceAccounts, so a compromised Backstage can still stand in
  for an allowed identity (for example to write `ztna-identity-*`). The policies close the direct routes only; scoping that
  binding per teamspace (profile-controller RoleBindings) is a platform follow-up, and the ZTNA path cannot be stronger than
  its control plane.
- <a name="break-glass"></a>**Break-glass**: the `ztna` Application has `selfHeal`, so a deleted binding is restored within
  seconds. Order: (1) `argocd app set ztna --sync-policy none`; (2) delete the ValidatingAdmissionPolicyBinding; (3) act;
  (4) re-apply the binding (or re-sync) and `argocd app set ztna --sync-policy automated --self-heal`. system:masters is
  not exempt from any of these policies. The behaviour is tested by `tests/vap-test.sh` against a real kube-apiserver 1.30 (r415 runs 1.34).

## Networking

- `wg.<domain>` (443, `teknoir-gateway`; bypasses the edge login, see `charts/auth`: the hub validates the Keycloak token) and
  `wg-device.<domain>:8084` (`teknoir-gateway-public`, no edge auth; the hub authenticates) both go to `wg-hub:8080`.
  Both hosts are covered by the gateways' `*.<domain>` wildcard hosts and certificate.
- AuthorizationPolicy `wg-hub` (ALLOW): TCP **8080** (the public API) from the two ingress gateway principals only; TCP
  **8081** (`http-internal`: service account delegation `onBehalfOf` and direct sessions) from workloads in `teknoir-ztna`
  only, and no VirtualService routes to it; TCP **8082** (`http-status`, live status for the Backstage console; env `STATUS_ADDR=:8082`, `BACKSTAGE_SA`) only from the
  mTLS principal `cluster.local/ns/teknoir-system/sa/backstage-api` (the hub also checks the exact TokenReview username; the
  `app=backstage-api` pods carry an `istio-proxy` sidecar in the injected namespace `teknoir-system`, verified on r415); TCP 9090 from the Prometheus service account. Istio does not see UDP: the WireGuard
  socket (51820/UDP) is reachable only through STUNner, whose UDPRoute admits an authenticated TURN client to exactly that port.
- `wg-hub` is the **headless** Service: its endpoints are pod IPs (`POD_IP:51820` is the hub endpoint and the TURN peer),
  so there is no ClusterIP NAT or conntrack on the TURN leg.

## STUN source IP (acceptance probe)

The Gateway `teknoir-turn` carries `stunner.l7mp.io/external-traffic-policy: "local"`, so the LoadBalancer Service keeps the
client source address. Without it kube-proxy SNATs to the node and a STUN binding response would report the node, not the
client's server-reflexive address, which breaks candidate exchange for the direct (P2P) path. Probe after a sync, from a
host that is not on the node network (the response must show your public address, not an address of r415):

    stunner-probe: turnutils_stunclient -p 3478 turn.<domain>      # coturn-utils; or: stunclient turn.<domain> 3478
    # expect: "Mapped address" / "XOR-MAPPED-ADDRESS" == the probing host's public IP
    kubectl --context r415 -n stunner-system get svc teknoir-turn -o jsonpath='{.spec.externalTrafficPolicy}'   # Local

With `Local` only nodes that run a dataplane pod answer on the LoadBalancer address; the replica count of the dataplane
(GatewayConfig) must cover the node that servicelb advertises. On the single-node r415 that is automatic.

## Client IP and rate limits

The hub does **not** set `CLIENT_IP_HEADER`, so it applies no per-IP rate limit; only the global backstop per endpoint and the
per-subject caps limit requests. Reason (k3s servicelb / klipper): on r415 both ingress gateway Services are `LoadBalancer`
with `externalTrafficPolicy: Cluster` behind klipper-lb, which masquerades the traffic, so Envoy sees the svclb/node address
for every client and `X-Envoy-External-Address` would be the same private address for everybody. (The hub also ignores a
header value that is loopback, private, CGNAT, link-local or unspecified, so setting it there would not make things worse,
but it would not help either.) A flood on the public `wg-device.<domain>:8084` can therefore still use up the global
backstop.

To switch per-IP limiting on: make real client addresses reach Envoy (`externalTrafficPolicy: Local` on
`istio-ingressgateway` and `istio-ingressgateway-public`, an infra decision in charts/istio, plus the trusted-proxy setting
if a proxy sits in front), verify in the hub logs that distinct public addresses show up, and only then add
`CLIENT_IP_HEADER=X-Envoy-External-Address` to the hub Deployment. `charts/ztna/tests/run.sh` fails while the variable is
present, so removing that check is part of the change.

## Image pull secret

`ghcr.io/teknoir/wg-hub` needs `ghcr-token`, which exists in `teknoir-system` and the teamspaces but is not copied into a
new namespace by any controller. A Sync hook Job (`templates/pull-secret.yaml`, `pullSecretCopy`) copies it once per
sync and an hourly CronJob (`pullSecretCopy.refreshSchedule`) repeats it (get on that one Secret in `teknoir-system`,
create/patch in `teknoir-ztna`, no sidecar, nothing prints the value), so a rotated token reaches the namespace within the
hour without a Git change; set `pullSecretCopy.enabled=false` if the package is public.

## The STUNner chart dependency

`charts/stunner/Chart.lock` and `charts/stunner/charts/stunner-1.2.1.tgz` are **committed** (`.gitignore` re-includes them
for this chart only; the other wrapper charts, for example cert-manager, ignore both and let ArgoCD build their dependencies).
The lock pins the chart digest and the vendored archive means a render does not depend on l7mp.io being reachable or on the
tarball behind 1.2.1 staying the same. To bump: edit `Chart.yaml`, run `helm dependency update` in `charts/stunner` and commit
both files.

## Removing

Turning the flag off removes the Applications and nothing else: no finalizers, and the CRDs and namespaces are kept (the
CRDs delete every object of their kind; `teknoir-ztna` holds the pinned identities and the web terminals device-controller
created). To remove the feature: disable WireGuard on every device (the controller removes the policy and the terminal),
delete the Gateway/UDPRoute (the operator removes stunnerd and the LoadBalancer Service), then the namespaces. Delete
the Gateway API CRDs only when nothing else uses them.

## Not covered here

Hub and agent code, the controller plugin, web terminal, Backstage and `tnctl` are other work packages. The hub is one replica
with in-memory sessions: a restart drops every tunnel and clients re-establish them.
