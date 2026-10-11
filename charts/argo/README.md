# Teknoir Argo CD Chart

Argo CD (argo-cd chart 10.4.0, Argo CD v3.5.1) behind the Istio ingress
gateway. Argo CD is meant to manage itself through the `argo` Application in
app-of-apps, which renders this chart; the airgap bootstrap applies the same
render (no value overrides) before Argo CD exists.

The `argo` Application is enabled since app-of-apps 0.0.4 (wave -5):

* on a fresh install the bootstrap applies this chart's one-shot render once
  (server-side, as `argocd-controller`), then the `argo` Application adopts
  it;
* on teknoir-local, `teknoir-node migrate` detaches the other K3s files, `up`
  creates the Application while the K3s file `teknoir-argo.yaml` is still in
  place (the bootstrap skips the `argo` tier), and `migrate --argo` detaches
  that file right after, with no k3s restart in between (infra DESIGN
  M3/M4/M7a). Two owners would fight on every k3s restart.

## Architecture

* **Traffic Routing**: Istio routes external HTTPS traffic to Argo CD via a `VirtualService`.
* **TLS Termination**: TLS is terminated at the Istio Gateway, and traffic is
  forwarded to Argo CD over the mesh (port 80). `--insecure` prevents redirect loops.
* **Authentication**: native OIDC against Keycloak realm `teknoir`
  (`configs.cm.oidc.config`, client `argocd`), bypassing `oauth2-proxy`. The
  auth chart's gateway `EnvoyFilter` must disable both its `ext_authz` and its
  `lua` filter for the `argocd.<domain>:443` vhost, otherwise Argo CD's own
  `401`/`403` API responses become a cross-origin redirect to `/oauth2/start`.
  Keycloak group `admin` maps to `role:admin`. There is no default role
  (`policy.default: ""`), so other realm users can sign in but see no
  applications, projects or settings. The local `admin` stays enabled
  (`admin.enabled: "true"`) as break-glass: rotate its password (the airgap
  node's `rotate argocd-admin`) and delete `argocd-initial-admin-secret`
  rather than disabling it.

## Secrets and trust (nothing injected at render time)

| What | Where it comes from |
|---|---|
| OIDC client secret | `$argocd-oidc-secret:oidc.auth.clientSecret`: Secret `argocd-oidc-secret` (label `app.kubernetes.io/part-of: argocd`), kept equal to the realm's `argocd` client secret by the platform-secrets chart |
| Keycloak TLS trust (argocd-server) | Secret `teknoir-root-ca-bundle` (`ca.crt`, public) mounted at `/etc/teknoir/ca` and added through `SSL_CERT_DIR`; the airgap node copies it into `teknoir-system` |
| Harbor TLS trust (repo-server) | `argocd-tls-certs-cm` entry `harbor.<domain>`, reconciled by the airgap node (`configs.tls.create: false`), plus the same CA mount |
| Chart repository | `configs.repositories.harbor-teknoir`: `harbor.<domain>/teknoir`, OCI, no credentials (project `teknoir` is public) |

## CRDs

The `argoproj.io` CRDs carry `argocd.argoproj.io/sync-options:
ServerSideApply=true,Prune=false,Delete=false`, so Argo CD never prunes or
deletes them (and with them every Application), not even on a cascading delete
of the `argo` Application. No Application in app-of-apps has the resources
finalizer.

## Self-management cautions

* A bad render of this chart can break Argo CD itself. Render it
  (`tests/render.sh argo`) before releasing, and keep the local admin.
* Break-glass when Argo CD cannot sync itself: re-apply the bundle render on the
  node (`teknoir-node converge --reapply argo`).
