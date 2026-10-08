# Harbor

This stage deploys Harbor, an open-source trusted cloud-native registry that stores, signs, and scans content.

## Overview
The Harbor integration is designed to work with the platform's existing Istio and Keycloak infrastructure.

- **Ingress**: Managed by Istio `VirtualService` pointing to the internal Harbor Nginx proxy.
- **TLS**: Terminated at the Istio `ingressgateway` using the wildcard certificate.
- **Authentication**: Native OIDC integration with Keycloak, configured by a PostSync Job. `oauth2-proxy` is NOT used for Harbor to avoid breaking Docker and Helm CLI workflows.
- **Persistence**: `hostPath` PersistentVolumes under `/opt/teknoir/harbor`, with optional `pvNodeAffinity`.

## Prerequisites
These Secrets exist before Harbor is first applied (the airgap bootstrap creates
them; none of them is in Git or in a bundle):
- `harbor-secret` (admin password, secretKey, core/jobservice/registry secrets,
  CSRF key) and `harbor-oidc-secret` (`client-secret`, the Keycloak `harbor`
  client secret of realm `teknoir`): the platform-secrets chart.
- `harbor-token-service` (`tls.key`/`tls.crt`, referenced by
  `harbor.core.secretName`) and `teknoir-root-ca-bundle` (`ca.crt`, the public
  Teknoir Root CA, referenced by `harbor.caBundleSecretName`): the airgap node.
- DNS for `harbor.<teknoir domain>` pointing to the cluster ingress IP.

## Deterministic render
`harbor.core.secretName` keeps the token-service key pair out of the render,
so ArgoCD no longer rolls harbor-core on every refresh. The registry htpasswd
Secret is still salted randomly per render: the `harbor` Application in
app-of-apps ignores its `/data` and the registry Deployment's `checksum/secret`
annotation, with `RespectIgnoreDifferences=true`.

## OIDC (Keycloak)
A PostSync Job (`templates/oidc-config-job.yaml`, `files/oidc-config.sh`)
configures Harbor's OIDC login through Harbor's API after every sync, from
`oidcConfig.settings` in `values.yaml`: endpoint
`https://auth.<teknoir domain>/auth/realms/teknoir`, client `harbor`, groups
claim `groups`, admin group `admin`, certificate verification on (Harbor trusts
the Teknoir Root CA through `harbor.caBundleSecretName`). It PUTs only the
settings that differ and sends the client secret only when its sha256 (kept in
ConfigMap `harbor-oidc-config-state`) changes; it never prints a secret. Harbor
refuses to switch `auth_mode` once users other than `admin` exist, and the Job
then leaves it alone with a warning. The local `admin` keeps working in OIDC
mode, as break-glass and for the airgap node's pushes.

The Keycloak client, the `groups` client scope and the `admin` group are
declared in realm `teknoir` by the auth chart, so no UI steps remain.

## CLI Usage (Docker/Helm)
Docker and Helm CLI clients do not support OIDC redirects directly. To use the registry from a CLI:

1. Log in to the Harbor UI via OIDC.
2. Go to your **Profile** (click your username in the top right).
3. Copy your **CLI Secret**.
4. Use this CLI secret as your password when logging in via CLI:
   ```bash
   docker login harbor.<teknoir domain>
   # Username: (your email/username)
   # Password: (paste CLI secret)
   ```
   Harbor checks the CLI secret against the user's OIDC token. Without the
   `offline_access` scope (not requested today; see `oidcConfig.settings`) it
   cannot refresh that token, so the CLI secret stops working when the token
   expires until the user logs in to the UI again.

Alternatively, use **Robot Accounts** for automated workflows (highly recommended for edge devices).

## Robot Accounts
Robot accounts provide long-lived credentials for automated pushes and pulls.
Create them in the Harbor UI under **Robot Accounts** or at the Project level.

## Storage Backend
The initial implementation uses `hostPath`. For production, it is recommended to override the `harbor.persistence` values to use an S3-compatible backend (e.g., MinIO, GCS, AWS S3).
