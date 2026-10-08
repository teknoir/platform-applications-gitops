# cert-manager Chart

cert-manager, the `teknoir-ca` ClusterIssuer (signing with the Teknoir Root CA
in Secret `cert-manager/teknoir-root-ca`, created once by the airgap node) and
the wildcard `Certificate` for `<domain>` and `*.<domain>` that the istio
ingress gateways serve (Secret `istio-system/<domain with dots as dashes>-wildcard-tls`).

## CRDs

The 6 cert-manager CRDs ship from `crds/`, vendored by `update-crds.sh` and
annotated `argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so
neither a prune nor a cascading delete of the Application can delete them.
The dependency's CRD templates stay off (`cert-manager.crds.enabled: false`).
After a cert-manager bump, run `charts/cert-manager/update-crds.sh` (connected
side); `templates/crds-version-check.yaml` fails the render until then.

## Sync order

Workloads and webhooks (wave 0), then the ClusterIssuer (wave 1), then the
wildcard Certificate (wave 2).
