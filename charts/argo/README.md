# Teknoir Argo CD Chart

Argo CD (argo-cd chart 10.4.0, Argo CD v3.5.1) behind the Istio ingress
gateway. Argo CD manages itself: the `argo` Application in app-of-apps renders
this chart, and the airgap bootstrap applies the same render (no value
overrides) once, before Argo CD exists.

## Architecture

* **Traffic Routing**: Istio routes external HTTPS traffic to Argo CD via a `VirtualService`.
* **TLS Termination**: TLS is terminated at the Istio Gateway, and traffic is
  forwarded to Argo CD over the mesh (port 80). `--insecure` prevents redirect loops.
* **Authentication**: native OIDC against Keycloak realm `teknoir`
  (`configs.cm.oidc.config`, client `argocd`), bypassing `oauth2-proxy`. The
  auth chart's gateway `EnvoyFilter` must disable both its `ext_authz` and its
  `lua` filter for the `argocd.<domain>:443` vhost, otherwise Argo CD's own
  `401`/`403` API responses become a cross-origin redirect to `/oauth2/start`.
  Keycloak group `admin` (and `argocd-admins`) map to `role:admin`; everyone
  else is read-only. The local `admin` stays enabled as break-glass; delete
  `argocd-initial-admin-secret` once SSO works.

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
