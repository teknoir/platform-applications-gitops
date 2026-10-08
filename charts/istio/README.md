# Istio Chart

Istio (base, istiod and the ingress/egress gateways) plus the Teknoir gateways
`teknoir-gateway` and `teknoir-gateway-public` in `istio-system`.

## CRDs

The 14 istio CRDs ship from `crds/`, vendored from the pinned istio `base`
chart by `update-crds.sh` and annotated
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so neither a prune
nor a cascading delete of the Application can delete them (and with them every
VirtualService, Gateway and AuthorizationPolicy in the cluster). The base
chart's own CRD template cannot carry that annotation, so
`istio-base.base.excludedCRDs` lists every vendored CRD to turn it off.

After an istio bump, run `charts/istio/update-crds.sh` (connected side). It
re-vendors `crds/` and regenerates `excludedCRDs`;
`templates/crds-version-check.yaml` fails the render until both match the
pinned version.

## Certificates and trust

- The wildcard `Certificate` lives in the cert-manager chart (0.0.2 and later).
  This chart only references its Secret, `<domain with dots as dashes>-wildcard-tls`,
  as the gateway `credentialName`.
- istiod mounts that Secret's `ca.crt` (the Teknoir Root CA) as
  `/cacerts/extra.pem`, which istiod adds to its trust for fetching the JWKS of
  RequestAuthentications from `https://auth.<domain>`. istiod reads it once at
  start: restart istiod if the CA ever changes.

## Air gap

The airgap bootstrap applies this chart's render once, with no value overrides,
before ArgoCD exists; ArgoCD then adopts it. Every environment value therefore
lives in `values.yaml` on the environment branch.
