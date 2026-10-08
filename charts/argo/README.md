# Teknoir Argo CD Chart

This chart deploys Argo CD and integrates it with the Teknoir infrastructure.

## Architecture

Argo CD is deployed behind the Istio ingress gateway.

* **Traffic Routing**: Istio routes external HTTPS traffic to Argo CD via a `VirtualService`.
* **TLS Termination**: TLS is terminated at the Istio Gateway, and traffic is forwarded to Argo CD via HTTP (on port 80). The `--insecure` flag is provided to the Argo CD server to prevent redirect loops.
* **Authentication**: Argo CD is configured to use its native OpenID Connect (OIDC) integration to authenticate against the Keycloak instance provided by the `auth` chart. It handles its own callback flow, bypassing `oauth2-proxy`.
  The bypass must be **complete**: the gateway `EnvoyFilter` shipped by the `auth`
  chart disables *both* its `ext_authz` filter and its `lua` response filter for
  the `argocd.<domain>:443` vhost (`auth` chart ≥ `0.0.7`). With the lua filter
  still active, Argo CD's own `401`/`403` API responses are rewritten into a
  cross-origin `302` to `https://<domain>/oauth2/start`, which the browser
  aborts — the UI then reports `Unable to execute resource action: Request has
  been terminated …`. See
  [AIRGAP-BOOTSTRAP.md §11](../../docs/AIRGAP-BOOTSTRAP.md#11-troubleshooting-argocd-ui-cannot-execute-resource-actions).

## Prerequisites

1.  **ArgoCD chart**: deployed by `airgap/bootstrap-airgap.sh` (from the bundle), or with `[deploy-argo.sh](../../scripts/deploy-argo.sh)` from a checkout. Both install the same K3s file, `teknoir-argo.yaml`.
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
4.  **Secret Generation**: The Keycloak client secret can only be generated **after** Keycloak is deployed and the `argocd` client has been created (steps above) — Keycloak issues the client secret on client creation.


## Setup Instructions

1.  **Generate the OIDC Secret** (after the Keycloak client exists):
    Copy the client secret from the `argocd` client's **Credentials** tab in Keycloak, then run the secret generation script from the root of the project to create the Kubernetes manifest:

    ```bash
    ./scripts/gen-argocd-keycloak-secrets.sh
    ```

    *Note: The script will prompt you for the OIDC client secret from Keycloak.*

2.  **Deploy the Secret:**
    Apply the generated secret to your cluster:

    ```bash
    kubectl apply -f .secrets/manifest-argocd-keycloak-secret.yaml
    ```

3.  **Deploy Argo CD:**
    Use Helm (or your preferred deployment script) to install the chart:

    ```bash
    ./scripts/deploy-argo.sh
    ```

    If Argo CD was already running before the secret existed (e.g., during the air-gapped bootstrap), restart the server to pick up the new secret instead:

    ```bash
    kubectl -n teknoir-system rollout restart deploy -l app.kubernetes.io/name=argocd-server
    ```

## Configuration

The main configuration overrides are located in `values.yaml`.

Key settings include:
*   `argo-cd.server.extraArgs`: Contains `--insecure` to handle Istio TLS termination.
*   `argo-cd.configs.cm.oidc.config`: The Keycloak integration details. The base
    config lives in `files/oidc.config` and is injected at render time (not in
    `values.yaml`) so the Teknoir Root CA can be embedded as `rootCA`.
*   `argo-cd.configs.rbac`: Maps the `admin` Keycloak group to the Argo CD `role:admin`.

### Keycloak TLS trust (`rootCA`)

`argocd-server` performs OIDC discovery directly against Keycloak
(`https://auth.<domain>/.../.well-known/openid-configuration`) using its **own**
TLS trust — it does **not** consult the node OS trust store nor
`argocd-tls-certs-cm` (that ConfigMap is repo-server-only, for Harbor OCI login).
Without the CA it fails with `x509: certificate signed by unknown authority`.

To fix this, the render (`airgap/lib.sh:helm_template_chart`, used by
`airgap/render-bootstrap.sh` and `[deploy-argo.sh](../../scripts/deploy-argo.sh)`)
embeds `teknoir-root-ca.crt` into
`oidc.config` as the `rootCA` field via `helm template --set-file`. The CA is
generated per-deployment and gitignored, so it is injected at render time rather
than hardcoded here. No cert files need to be mounted into the ArgoCD pod, and no
`oidc.tls.insecure.skip.verify` escape hatch is required.

Note: this only covers the **server-side** OIDC discovery call. The **browser**
must still trust `*.<domain>` for the login redirect leg, which is why
`gen-local-ca-secret.sh` distributes `teknoir-root-ca.crt` to operator laptops.