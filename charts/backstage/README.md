# Backstage Helm Chart

Backstage (frontend `backstage`, backend `backstage-api`) with its Postgres.

## Secrets

The chart creates no credentials. They come from the platform-secrets chart:

| Secret | Use |
|---|---|
| `backstage-postgres-secrets` | `POSTGRES_USER`/`POSTGRES_PASSWORD` for Postgres and the backend, `DATA_SOURCE_*` for the exporter. Never delete it while PVC `data-backstage-postgres-0` exists: initdb fixed the password on first start. |
| `backstage-backend-auth` | Mounted at `/app/secrets`; `backend-auth-backstage-secrets.yaml` (`secret: <random>`) is `$include`d as `backend.auth.keys`. |
| `backstage-keycloak-secrets` | user-controller's Keycloak client. Backstage does not use it (the keycloakOrg provider is off), so the envFrom is optional. |

## Auth

- oauth2-proxy forwards the user's access token of realm `teknoir`; the istio
  RequestAuthentications verify it (issuer
  `https://auth.<domain>/auth/realms/teknoir`, `config.oidc`) and pass it on as
  `verified-jwt`. istiod trusts the Teknoir CA for the JWKS through
  `/cacerts/extra.pem` (istio chart).
- `backend.auth.externalAccess` (jwks, audience `teknoir-cli`) uses the same
  realm. Node.js trusts the Teknoir CA through `NODE_EXTRA_CA_CERTS` from the
  optional Secret `teknoir-root-ca-bundle` (`backstageApi.caBundle`).
- Sign-in needs a catalog user `default/<email with @ replaced by -at->`,
  i.e. a User CR with that name (`teknoir-airgap admin-user` creates the first).

## GitHub

`backstageApi.github.enabled` (false here) gates `integrations.github`, whose
`$include` makes the GitHub App credentials file mandatory. Without it
Backstage uses the unauthenticated default github.com integration; offline the
GitHub discovery provider only logs errors.
