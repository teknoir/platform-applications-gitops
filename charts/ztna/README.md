# ztna

GitOps for **WireGuard over STUNner**, the ZTNA alternative to the SSH reverse tunnels. Design:
`plans/wireguard-ztna-tunnel.md` (rev 2); wire contract: `github.com/teknoir/wg-tunnel` `pkg/api/api.go`.
Staging (`teknoir-cloud`, r415) only. The SSH tunnel stack (deadend, reverse-tunnel, web-terminal tunnels)
is not touched.

Four charts and two touched charts, all behind **one switch**:

| Chart / Application | Wave | What |
|---|---|---|
| `charts/gateway-api-crds` (`gateway-api-crds`) | -1 | Gateway API CRDs, standard channel v1.4.1 (the set STUNner 1.2.1 ships), server-side applied, never pruned |
| `charts/stunner` (`stunner`) | 0 | STUNner operator 1.2.1 (pinned images), GatewayClass `stunner-gatewayclass`, GatewayConfig, Gateway `teknoir-turn` (TURN-UDP 3478, LoadBalancer via k3s servicelb), `stunner.l7mp.io/v1` UDPRoute `wg-hub` -> `teknoir-ztna/wg-hub:51820` |
| `charts/ztna` (`ztna`) | 1 | Namespace `teknoir-ztna` (mesh), wg-hub, headless Service, RBAC, admission policies, VirtualServices `wg` and `wg-device`, AuthorizationPolicy, ServiceMonitor, pull secret copy |
| `charts/device-controller` | 2 | `ZTNA` key in the controller ConfigMap, Role in `teknoir-ztna`, CRD `status.wireguard`; plus the `vdev-egress-turn` NetworkPolicy of the virtual devices |
| `charts/virtual-devices` | - | CoreDNS rewrites `wg-device.<domain>` and `turn.<domain>` |

## The switch

`charts/app-of-apps/values.yaml`: `ztna.enabled` (default **false**). It renders only when the environment is in
the allowlist in `charts/app-of-apps/templates/_helpers.tpl` (`teknoir-cloud`), so a cherry-pick of the flag onto
`teknoir-online` or `teknoir-local` renders nothing. When on, app-of-apps also passes `ztna.enabled=true` to the
`device-controller` and `virtual-devices` Applications (Helm parameters). Flipping it is a values change.

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

- **ClusterRole `wg-hub`**: create `subjectaccessreviews` and `tokenreviews`; get/list/watch `devices`.
- **Role in `teknoir-ztna`**: get/list/watch/create/update/patch ConfigMaps, get ServiceAccounts. No delete, no Secrets.
- **Role in `stunner-system`**: get Secret `stunner-auth-secret` (by name).
- The hub image runs non-root, read-only root file system, all capabilities dropped, RuntimeDefault seccomp,
  no service account token beyond its own, **Recreate** strategy and one replica (STUNner routes to every endpoint
  of the headless Service; two hubs would split the session state).

## Admission policies (`templates/admission.yaml`)

Backstage's service account has cluster-wide `teknoir-admin`, so RBAC alone does not protect the policy store.

- `ztna-policy-store`: ConfigMaps labelled `ztna.teknoir.org/policy` or named `ztna-policy-*` are written only by
  `system:serviceaccount:teknoir-system:device-controller-service-account`; `ztna.teknoir.org/identity` or
  `ztna-identity-*` only by `system:serviceaccount:teknoir-ztna:wg-hub`; the hub writes no other ConfigMap.
  A label or name on the old or the new object counts (relabelling does not escape).
- `ztna-no-exec`: no `pods/exec`, `pods/attach`, `pods/portforward` CONNECT and no `pods/ephemeralcontainers`
  update in `teknoir-ztna` and `stunner-system`, for anyone (system:masters included; the hub holds session keys in
  memory and stunnerd the TURN secret).
- **ArgoCD is not blocked.** The policy and identity ConfigMaps are written at runtime, not by Git, and the chart
  renders no ConfigMap. **Namespace teardown**: the namespace controller deletes the ConfigMaps as itself, so DELETE is
  allowed while the namespace is `Terminating`. The Namespace itself carries `Prune=false,Delete=false`, so removing the
  Application never deletes the pinned identities.
- Break-glass: a cluster-admin deletes the ValidatingAdmissionPolicyBinding, acts and re-applies it (ArgoCD selfHeal
  restores it). The behaviour is tested by `tests/vap-test.sh` against a real kube-apiserver 1.30 (r415 runs 1.34).

## Networking

- `wg.<domain>` (443, `teknoir-gateway`, oauth2-proxy ext_authz lets `teknoir-cli` bearer tokens through) and
  `wg-device.<domain>:8084` (`teknoir-gateway-public`, no edge auth; the hub authenticates) both go to `wg-hub:8080`.
  Both hosts are covered by the gateways' `*.<domain>` wildcard hosts and certificate.
- AuthorizationPolicy `wg-hub` (ALLOW): TCP 8080 from the two ingress gateway principals and from any workload in
  `teknoir-ztna` (the web terminals); TCP 9090 from the Prometheus service account. Istio does not see UDP: the WireGuard
  socket (51820/UDP) is reachable only through STUNner, whose UDPRoute admits an authenticated TURN client to exactly that port.
- `wg-hub` is the **headless** Service: its endpoints are pod IPs (`POD_IP:51820` is the hub endpoint and the TURN peer),
  so there is no ClusterIP NAT or conntrack on the TURN leg.

## Image pull secret

`ghcr.io/teknoir/wg-hub` needs `ghcr-token`, which exists in `teknoir-system` and the teamspaces but is not copied into a
new namespace by any controller. A Sync hook Job (`templates/pull-secret.yaml`, `pullSecretCopy`) copies it once per
sync (get on that one Secret in `teknoir-system`, create/patch in `teknoir-ztna`, no sidecar, nothing prints the value). A
rotated token reaches the namespace on the next sync; set `pullSecretCopy.enabled=false` if the package is public.

## Removing

Turning the flag off removes the Applications and nothing else: no finalizers, and the CRDs and namespaces are kept (the
CRDs delete every object of their kind; `teknoir-ztna` holds the pinned identities and the web terminals device-controller
created). To remove the feature: disable WireGuard on every device (the controller removes the policy and the terminal),
delete the Gateway/UDPRoute (the operator removes stunnerd and the LoadBalancer Service), then the namespaces. Delete
the Gateway API CRDs only when nothing else uses them.

## Not covered here

Hub and agent code, the controller plugin, web terminal, Backstage and `tnctl` are other work packages. The hub is one replica
with in-memory sessions: a restart drops every tunnel and clients re-establish them.
