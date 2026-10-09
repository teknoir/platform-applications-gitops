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
- Logout: when `config.oidc.realm` is set, the frontend gets
  `teknoir.auth.issuer` (the same issuer) and `teknoir.auth.clientId`
  (`config.oidc.clientId`, default `teknoir`) through
  `APP_CONFIG_teknoir_auth_issuer` / `APP_CONFIG_teknoir_auth_clientId`. Its
  logout goes to `/oauth2/sign_out` with `rd` set to the (URL-encoded)
  `<issuer>/protocol/openid-connect/logout?client_id=<clientId>&post_logout_redirect_uri=https://<domain>/`,
  so it ends both the oauth2-proxy session and the Keycloak SSO session
  (the realm's client must allow that redirect URI: auth chart, client
  `teknoir` `post.logout.redirect.uris`). Without `config.oidc.realm` neither
  variable is rendered and the frontend keeps its legacy logout URL. Needs a
  backstage-app image with `teknoir.auth` support (`buildLogoutUrl`, backstage
  r5, newer than robot 9f15dacf); older images ignore the variables.

## Catalog ingestion

The image's `app-config.yaml` refreshes the k8s entity providers every 30
minutes, and a restart does not pull a scheduled run forward (the next run is
`min(stored, now + cadence)`). `catalog.k8sProviderSchedules` (default `{}`:
no override) maps a provider to a Backstage schedule (`frequency`, `timeout`,
optionally `initialDelay`/`scope`). The chart renders each one as
`catalog.providers.k8s.<provider>: [{schedule: …}]` in
`app-config.prod-env.yaml`, which loads after the image's config and replaces
its array. Only `users`, `profiles`, `roles`, `orgtree`, `services`, `devices`
and `deviceapplicationsets` can be overridden: their entries hold nothing but a
schedule. `peripherals` (its entry also carries `wsUrl`, `mqttUrl` and
`syncOrgConfig`) and unknown names fail the render, as does a schedule without
`frequency` and `timeout`.

teknoir-local: users and profiles every minute (timeout 2 min), roles and
orgtree every 5 minutes, so a new User, owner claim or Profile (e.g. the
GitOps teamspace `teknoir-default`) reaches the catalog within about a minute.

## Probes

`backstageApi.probes` is rendered as is into the backstage-api container.
teknoir-local uses the root health endpoints of
`@backstage/backend-defaults` on port 7007:

| Probe | Path | Period | Timeout | Failures |
|---|---|---|---|---|
| startupProbe | `/.backstage/health/v1/readiness` | 10 s | 5 s | 60 (10 min for first-start migrations) |
| readinessProbe | `/.backstage/health/v1/readiness` | 10 s | 5 s | 3 |
| livenessProbe | `/.backstage/health/v1/liveness` | 20 s | 5 s | 6 |

No `initialDelaySeconds`: liveness starts only after the startup probe has
passed. Readiness answers 503 until every plugin has started.

## Images

Every image is pinned as `<repo>:<immutable tag>@sha256:<digest>` with
`IfNotPresent`, where the digest is the **linux/amd64 manifest** digest
(`crane digest --platform linux/amd64 <repo>:<tag>`), never the index digest:
the airgap bundle pushes only the amd64 manifest to Harbor. The Teknoir
images use their `sha-<8>` CI tag. `postgres` is `17.11-alpine`, the version
the live database runs; the exporter is pinned by its version tag.

`charts/backstage/tests/render-test.sh` (not packaged) renders the chart and
checks the above; see its header.

## GitHub

`backstageApi.github.enabled` (false here) gates `integrations.github`, whose
`$include` makes the GitHub App credentials file mandatory. Without it
Backstage uses the unauthenticated default github.com integration; offline the
GitHub discovery provider only logs errors.
