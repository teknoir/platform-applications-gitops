# Istio Chart

Deploys the r415 edge: Istio base/istiod, the ingress gateways, and the edge
`Gateway` resources.

## Domains fronted by the r415 edge

r415 is the single public entry point (the UDM Pro forwards `:443`/`:80` here),
so every hostname must be demultiplexed on this cluster's ingress gateway.

| Domain | Gateway | TLS termination | Backend |
| --- | --- | --- | --- |
| `teknoir.cloud`, `*.teknoir.cloud` | `teknoir-gateway` | r415 (`teknoir-cloud-wildcard-tls`) | in-cluster services |
| `contoai.site`, `*.contoai.site` | `contoai-gateway` | r415 (`contoai-site-wildcard-tls`) | contoai ingress `192.168.2.204:443` (re-encrypt) |

Both 443 servers are `SIMPLE` on the same `istio: ingressgateway` workload;
Istio selects the certificate by SNI, so the two `Gateway` resources coexist and
neither is an edit to the other. `contoai.backend.*` in `values.yaml` controls
the external endpoint, SNI and verification.

### contoai.site certificate

r415 has no DNS-01 credentials for `contoai.site` (the Loopia webhook lives on
the contoai cluster), so the wildcard secret is **copied out-of-band** and is
**not** managed by this chart:

```sh
infra/scripts/copy-contoai-cert-secret.sh
```

Renewal is manual: re-run the script (or schedule it) when cert-manager rotates
the secret on contoai. If the secret is missing, the contoai 443 listener has no
certificate until it appears.

### Disabling

Set `contoai.enabled: false` in `values.yaml` to drop the contoai Gateway and
routing resources. The copied secret is left in place.


