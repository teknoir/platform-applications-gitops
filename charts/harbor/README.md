# Harbor

This stage deploys Harbor, an open-source trusted cloud-native registry that stores, signs, and scans content.

## Overview
The Harbor integration is designed to work with the platform's existing Istio and Keycloak infrastructure.

- **Ingress**: Managed by Istio `VirtualService` pointing to the internal Harbor Nginx proxy.
- **TLS**: Terminated at the Istio `ingressgateway` using the wildcard certificate.
- **Authentication**: Native OIDC integration with Keycloak. `oauth2-proxy` is NOT used for Harbor to avoid breaking Docker and Helm CLI workflows.
- **Persistence**: Currently configured for `hostPath` on `/opt/teknoir/harbor` for local/initial deployments.

## Prerequisites
- Keycloak (Stage 7) must be deployed and accessible.
- Harbor secrets generated using `scripts/gen-harbor-secrets.sh`.
- DNS record for `harbor.<teknoir domain>` pointing to the cluster ingress IP.

## Keycloak Configuration
Before configuring Harbor, you must create a client in Keycloak:

1. **Realm**: Use the `master` realm or your specific platform realm.
2. **Client ID**: `harbor`
3. **Client Protocol**: `openid-connect` (Standard flow)
4. **Access Type**: `confidential` (Client authentication ON)
5. **Valid Redirect URIs**: `https://harbor.<teknoir domain>/*`
6. **Base URL**: `https://harbor.<teknoir domain>`

After creating the client, go to the **Credentials** tab and copy the **Client Secret**.

## Harbor OIDC Configuration (Manual)
Once Harbor is deployed, log in as `admin` (get password from `harbor-secret`) and go to **Configuration > Authentication**:
```bash
kubectl get secret harbor-secret -o yaml | yq .data.HARBOR_ADMIN_PASSWORD | base64 -d -i -
```
1. Go to Configuration > Authentication > **Auth Mode**: `OIDC`
2. **OIDC Provider Name**: `Keycloak`
3. **OIDC Endpoint**: `https://auth.<teknoir domain>/auth/realms/master`
4. **OIDC Client ID**: `harbor`
5. **OIDC Client Secret**: (Paste from Keycloak)
6. **Group Filter**: (Optional, e.g., `member`)
7. **Scope**: `openid,profile,email` (Ensure `groups` is present for group mapping)
8. **Verify Certificate**: (Disable if using self-signed or untrusted internal CA)
9. **OIDC User Claim**: `preferred_username`
10. **OIDC Admin Group**: `admin`

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

Alternatively, use **Robot Accounts** for automated workflows (highly recommended for edge devices).

## Robot Accounts
Robot accounts provide long-lived credentials for automated pushes and pulls.
Create them in the Harbor UI under **Robot Accounts** or at the Project level.

## Storage Backend
The initial implementation uses `hostPath`. For production, it is recommended to override the `harbor.persistence` values to use an S3-compatible backend (e.g., MinIO, GCS, AWS S3).
