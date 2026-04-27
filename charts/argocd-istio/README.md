# Teknoir Argo CD Istio Chart

This chart integrates Argo CD with the Teknoir infrastructure.

## Architecture

Argo CD is deployed behind the Istio ingress gateway.

* **Traffic Routing**: Istio routes external HTTPS traffic to Argo CD via a `VirtualService`.
* **TLS Termination**: TLS is terminated at the Istio Gateway, and traffic is forwarded to Argo CD via HTTP (on port 80). The `--insecure` flag is provided to the Argo CD server to prevent redirect loops.
* **Authentication**: Argo CD is configured to use its native OpenID Connect (OIDC) integration to authenticate against the Keycloak instance provided by the `auth` chart. It handles its own callback flow, bypassing `oauth2-proxy`.

## Prerequisites

1.  **ArgoCD chart**: The `argocd` chart must be deployed with `[deploy-argo.sh](../../scripts/deploy-argo.sh)`.
2.  **App-of-apps**: The `[app-of-apps](https://github.com/teknoir/platform-applications-gitops/tree/teknoir-cloud/charts/app-of-apps)` application must be deployed (providing Keycloak).
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
4.  **Secret Generation**: You must generate the Keycloak client secret before deploying.


## Setup Instructions

1.  **Generate the OIDC Secret:**
    Run the secret generation script from the root of the project to create the Kubernetes manifest for the Keycloak client secret:

    ```bash
    ./scripts/gen-argocd-keycloak-secrets.sh
    ```

    *Note: The script will prompt you for the OIDC client secret from Keycloak.*

2.  **Deploy the Secret:**
    Apply the generated secret to your cluster:

    ```bash
    kubectl apply -f manifest-argocd-keycloak-secret.yaml
    ```

3.  **Deploy Argo CD:**
    Use Helm (or your preferred deployment script) to install the chart:

    ```bash
    ./scripts/deploy-argo.sh
    ```

## Configuration

The main configuration overrides are located in `values.yaml`.

Key settings include:
*   `argo-cd.server.extraArgs`: Contains `--insecure` to handle Istio TLS termination.
*   `argo-cd.server.config.oidc.config`: Contains the Keycloak integration details.
*   `argo-cd.server.rbacConfig`: Maps the `admin` Keycloak group to the Argo CD `role:admin`.