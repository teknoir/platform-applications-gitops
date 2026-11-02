# Teknoir Argo CD Chart

This chart deploys Argo CD and integrates it with the Teknoir infrastructure.

## Architecture

Argo CD is deployed behind the Istio ingress gateway.

* **Traffic Routing**: Istio routes external HTTPS traffic to Argo CD via a `VirtualService`.
* **TLS Termination**: TLS is terminated at the Istio Gateway, and traffic is forwarded to Argo CD via HTTP (on port 80). The `--insecure` flag is provided to the Argo CD server to prevent redirect loops.
* **Authentication**: Argo CD is configured to use its native OpenID Connect (OIDC) integration to authenticate against the Keycloak instance provided by the `auth` chart. It handles its own callback flow, bypassing `oauth2-proxy`.

## Prerequisites

1.  **First install**: on a new cluster, `scripts/deploy-argo.sh` in [teknoir/infra](https://github.com/teknoir/infra) installs this chart once (Helm release `argo`). From then on the Application `argo` (`charts/app-of-apps/templates/argo.yaml`) manages Argo CD from this directory, and this repository is the source of truth.
2.  **App-of-apps**: The [app-of-apps](https://github.com/teknoir/platform-applications-gitops/tree/teknoir-cloud/charts/app-of-apps) application must be deployed (providing Keycloak).
3.  **Setup in Keycloak**
* Client setup in master realm - Client ID: `argocd`
* OpenID Connect
* Client authentication: ON (this is “confidential”)
* Standard flow: ON
* Service account roles: ON
* Valid redirect URI: `https://argocd.<your-domain>/auth/callback`
*   Ensure the `groups` scope is provided to map Keycloak groups (e.g., `admin`) to Argo CD RBAC roles.
    *   **How to add the groups scope in Keycloak**:
        1. In Keycloak, go to **Client Scopes** and click **Create client scope**. Name it `groups`, set Type to `Default`, Protocol to `OpenID Connect`, and enable **Include in token scope**.
        2. Save, then go to the **Mappers** tab for the new `groups` scope and click **Configure a new mapper** -> **Group Membership**.
        3. Name the mapper `groups`, set **Token Claim Name** to `groups`, turn OFF **Full group path**, and turn ON **Add to ID token**, **Add to access token**, and **Add to userinfo**.
        4. Go to your `argocd` client, navigate to **Client Scopes**, and ensure the `groups` scope is assigned (add it as `Default` or `Optional` if missing).
4.  **OIDC Secret**: `teknoir-system/argocd-oidc-secret` (key `clientSecret`) comes from the `platform-secrets` Application (`charts/platform-secrets/values.yaml`).

## Self-management

- The Application `argo` starts without automated sync: review the first sync's diff (it shows any runtime edit of
  `argocd-cm`, `argocd-rbac-cm` or `argocd-cmd-params-cm` that the chart would revert), sync by hand, then enable
  automated sync in a follow-up commit.
- Deleting the Application `argo` from the UI or CLI is denied by RBAC (a cascade delete would remove Argo CD); the CRDs
  and `argocd-secret` also carry `Delete=false`. Remove it from app-of-apps instead: it has no finalizer.
- A staging rollback to a release from before this chart existed prunes the Application `argo` (orphaning, not
  deleting, Argo CD); Argo CD is then unmanaged until a release with it is rolled out again.

## Configuration

The main configuration overrides are located in `values.yaml`.

Key settings include:
*   `argo-cd.server.extraArgs`: Contains `--insecure` to handle Istio TLS termination.
*   `argo-cd.configs.cm."oidc.config"`: Contains the Keycloak integration details.
*   `argo-cd.configs.rbac`: Maps the `admin` Keycloak group to the Argo CD `role:admin`, and denies deleting the
    Application `argo`.