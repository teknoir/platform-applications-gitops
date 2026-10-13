# stunner

Wrapper chart for the [STUNner](https://github.com/l7mp/stunner) Kubernetes gateway operator 1.2.1 (dependency
`stunner` from https://l7mp.io/stunner, exact version) plus the TURN gateway that WireGuard (ZTNA) tunnels use.
Deployed by `charts/app-of-apps` (Application `stunner`, namespace `stunner-system`, `ServerSideApply`,
`SkipDryRunOnMissingResource`, labels `istio-injection=disabled` through `managedNamespaceMetadata`) on `teknoir-cloud`
only, behind `ztna.enabled`. See `charts/ztna/README.md`.

| Object | Notes |
|---|---|
| Operator Deployment, `Dataplane default` | Images pinned by index digest (`1.2.1@sha256:...`). stunnerd runs non-root with a read-only root file system (the upstream image sets no user; verify on first rollout) |
| `GatewayClass stunner-gatewayclass` | `controllerName: stunner.l7mp.io/gateway-operator`, `parametersRef` -> GatewayConfig |
| `GatewayConfig stunner-gatewayconfig` | realm `stunner.l7mp.io`, `authRef` -> `Secret stunner-system/stunner-auth-secret` (`type: ephemeral`, `secret`). **Not in Git**: `infra/scripts/gen-stunner-auth-secret.sh` |
| `Gateway teknoir-turn` | listener `turn-udp`, protocol `TURN-UDP`, port 3478; annotation `stunner.l7mp.io/disable-health-check-expose: "true"`. The operator creates Deployment `teknoir-turn` (pods `app=stunner`) and a LoadBalancer Service `teknoir-turn` in `stunner-system` (k3s servicelb) |
| `UDPRoute wg-hub` (`stunner.l7mp.io/v1`) | one backend: Service `teknoir-ztna/wg-hub`, `port: 51820`, no `endPort`. Cross-namespace backends need no ReferenceGrant with STUNner's own UDPRoute |

The REST auth service is not deployed (the hub mints TURN-REST credentials itself). The Gateway API CRDs are **not** installed by
this chart (`stunner.standardCrds.enabled=false`, `experimentalCrds.enabled=false`): `charts/gateway-api-crds` installs them
once. The experimental channel is not needed: the operator watches the Gateway API v1alpha2 UDPRoute only when its CRD exists.

`helm dependency build` pulls the pinned chart; `Chart.lock` and `charts/*.tgz` are not committed (ArgoCD builds them, like
`charts/cert-manager`).
