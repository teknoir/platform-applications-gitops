# gateway-api-crds

The [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io) CRDs that the STUNner gateway
operator (`charts/stunner`) needs, as their own Application (`charts/app-of-apps/templates/ztna.yaml`,
sync wave -1, `ServerSideApply=true`). Rendered only for `teknoir-cloud` and only with `ztna.enabled`.

## What and why

`crds/gateway-api-standard-v1.4.1.yaml` is the `crds/gateway-api-crds.yaml` of the subchart
`gateway-api-standard-crds` 1.4.1 inside the `stunner/stunner` 1.2.1 Helm chart, byte for byte
(sha256 in `SHA256SUMS`). It holds `backendtlspolicies`, `gatewayclasses`, `gateways`,
`grpcroutes`, `httproutes` and `referencegrants` (`gateway.networking.k8s.io`, standard channel).

- **Standard channel only.** STUNner 1.2.1 ships its own `stunner.l7mp.io/v1` UDPRoute and watches the
  Gateway API `v1alpha2` UDPRoute only "when the CRD is loaded" (operator `udproute.go`), so the
  experimental channel is not needed, and nothing here uses it.
- **Installed exactly once.** `charts/stunner` sets `standardCrds.enabled=false` and
  `experimentalCrds.enabled=false` on the STUNner chart, so the set is not applied twice.
- **Server-side apply.** The file is about 700 KB; `httproutes` alone is above the 256 KiB limit of the
  `last-applied-configuration` annotation of client-side apply.
- **Never pruned.** `prune: false` on the Application; deleting a CRD deletes every object of its kind.
- The file is in `crds/`, so Helm does not template it.

## Updating

Pull the next `stunner/stunner` chart, compare the subchart's CRD file with this one, and replace it
only together with the STUNner chart pin in `charts/stunner/Chart.yaml`. Gateway API upgrades are
additive within a channel but never downgrade (v1.4 ships a safe-upgrades admission policy upstream; this
file does not include it, because the STUNner chart does not).

Istio (istiod) starts its Gateway API controller when these CRDs exist. Its GatewayClass is `istio`, so
it ignores `stunner-gatewayclass`. Check istiod after the first sync (plan gate 4).
