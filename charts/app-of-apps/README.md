# app-of-apps

The root of the platform: the AppProject `teknoir-local` and one ArgoCD
Application per platform chart, all rendered from `values.yaml`
(`applications.<name>`: chart version, destination namespace, sync wave,
optional `ignoreDifferences`). The airgap bootstrap points the root Application
`app-of-apps` at this chart's version and reads the chart pins from its render.

Every Application:
- syncs automatically with prune and selfHeal, server-side apply, and
  `RespectIgnoreDifferences=true` when it ignores differences;
- retries a failed sync 10 times with backoff (30s, x2, up to 5m);
- has no resources finalizer, so deleting an Application never deletes its
  resources (CRDs are additionally annotated `Prune=false,Delete=false`).

Sync waves: AppProject -20; platform-secrets -10; cert-manager, istio, argo -5;
harbor, auth, monitoring 0; the controllers and backstage 5. ArgoCD reports a
child Application healthy as soon as it exists, so the waves order creation and
pruning; each Application then converges through its own retries.

An entry with `enabled: false` renders no Application but stays declared, so
`tests/render.sh` still checks its pin, policy and project. In 0.0.4 that is
`argo`: ArgoCD's self-management starts with 0.0.5, after the live K3s file
`teknoir-argo.yaml` is detached (DESIGN M7a; see `charts/argo/README.md`).

The AppProject only allows charts from `harbor.<domain>/teknoir`, the
namespaces the charts deploy into, and the cluster-scoped kinds they render.
`tests/render.sh` renders every chart and fails when a resource falls outside
the project, when a pin does not match `charts/<chart>/Chart.yaml`, or when an
Application loses its retry, server-side apply or ignore rules.

Releasing: bump the chart(s), pin the new versions here, bump this chart's
version, and set `APP_OF_APPS_VERSION` in infra `airgap/versions.env`. A
version is released once; Harbor keeps the first push.
