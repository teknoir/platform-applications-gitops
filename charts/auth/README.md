# auth

Keycloak (codecentric keycloakx), oauth2-proxy (ext_authz for every protected
vhost), the Istio auth plumbing, and realm-as-code for realm `teknoir`.

## Realm `teknoir` (realm-as-code)

All platform clients live in realm `teknoir`; the master realm only holds the
Keycloak admin.

- Issuer: `https://auth.<domain>/auth/realms/teknoir`. Keycloak serves under its
  http-relative-path `/auth` (`keycloak.http.relativePath`), so every URL keeps
  the `/auth` prefix (probes, admin console, user-controller `KEYCLOAK_URL`).
- `files/realm/teknoir.yaml` is rendered by Helm (domain, names) and imported
  by keycloak-config-cli (`docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5`)
  in the PostSync Job `keycloak-config`, after every sync, with
  `$(env:...)` substitution of the client secrets from
  `teknoir-auth/keycloak-client-secrets` (platform-secrets chart). Keycloak and
  every consumer therefore share one value.
- Clients: `teknoir-cli` (tnctl, device flow, below), `teknoir` (oauth2-proxy, PKCE S256, redirect
  `https://<domain>/oauth2/callback` and `https://*.<domain>/oauth2/callback`),
  `argocd` (`https://argocd.<domain>/auth/callback`), `harbor`
  (`https://harbor.<domain>/c/oidc/callback`), `user-controller` (service account
  only, realm-management `manage-users`, `view-users`, `query-users`).
- Client scope `groups` (flat group names in ID/access tokens and userinfo),
  default on teknoir/argocd/harbor; group `admin` (ArgoCD role:admin, Harbor
  admin group). Default scopes include `basic`, which carries `sub` (Backstage
  requires it).
- The import is idempotent and always complete (`IMPORT_CACHE_ENABLED=false`):
  UI drift on managed objects is corrected on the next sync. keycloak-config-cli
  keeps remote state, so it only deletes objects it created, and never users.
  The only users managed here are the user-controller service account and the
  initial human admin `platform-admin` (below); user-controller creates every
  other user from its User CRs.

## Initial admin (platform-admin)

Realm `teknoir` starts with one human user, so ArgoCD and Harbor SSO and every
oauth2-proxy-protected host work right after a fresh install:

- `platform-admin` (`platform-admin@<domain>`, email verified, first/last name
  set so the default user profile needs no form), member of group `admin`
  (ArgoCD `role:admin`, Harbor admin group).
- Username and initial password come from `teknoir-auth/keycloak-platform-admin`
  (platform-secrets, random). Read it with
  `teknoir-airgap credentials platform-admin --out FILE`.
- The password is temporary with required action `UPDATE_PASSWORD`: Keycloak
  forces one change at the first login. Both apply only when the import creates
  the user: the credential is labelled `initial` (keycloak-config-cli never
  re-applies it) and the Job sets
  `IMPORT_BEHAVIORS_USERUPDATEIGNOREDPROPERTIES=attributes,requiredActions`,
  so later syncs neither reset the password nor force a second change.
- Name, email, enabled and membership are managed: a sync re-asserts them, and
  the user is exactly in group `admin`. Once named admins exist, set
  `realm.platformAdmin.enabled: false` to disable it (keycloak-config-cli never
  deletes users).

The Job talks to Keycloak in-cluster over the mesh (STRICT mTLS), so its pod
keeps the Istio sidecar as a native sidecar, which ends with the Job.

## Keycloak admin

`KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` come from `teknoir-auth/keycloak-admin`
(platform-secrets). Keycloak applies them only when it creates the admin. The
Job's init step (`files/keycloak-admin-check.sh`) checks that this password
works; if it does not and the Secret has a key `previous-password` that does,
it sets the admin's password to `password` through the admin REST API. So:

- **Rotate**: put the current password into `previous-password`, the new one
  into `password`, then sync `auth` (or wait for the next sync). Remove
  `previous-password` afterwards.
- **Existing install** (the teknoir-local migration, VM e2e E10): the master
  admin still has its old password. `keycloak-admin` must hold it as
  `previous-password` **before `up`**, because one `up` applies platform-secrets
  and pins app-of-apps, and ArgoCD then syncs auth (wave 0) right after
  platform-secrets (wave -10). There is no window to add the key in between.
  - `teknoir-airgap migrate` (infra, I-13) does this: when
    `teknoir-auth/keycloak-admin` is absent, it creates it with only
    `previous-password`, read in memory from the live StatefulSet's
    `KC_BOOTSTRAP_ADMIN_PASSWORD` (never printed, never in Git).
  - platform-secrets has `addMissingKeys: true` on `keycloak-admin`, so it adds
    `username` and a random `password` and keeps `previous-password`. The first
    PostSync then rotates the admin to `password`. If migrate already wrote
    `username` and `password`, they are kept.
  - Manual equivalent, before `up`:
    `kubectl --context teknoir-local -n teknoir-auth create secret generic keycloak-admin --from-file=previous-password=FILE`
    (FILE holds the current admin password with no trailing newline, mode
    0600; the value never goes on the command line).
  - If `up` ran without it, the keycloak-config Job fails, realm `teknoir` is
    not imported, and every login through oauth2-proxy fails, because
    oauth2-proxy already uses realm `teknoir`. Recover by adding
    `previous-password` to the existing Secret
    (`kubectl -n teknoir-auth patch secret keycloak-admin --type merge --patch-file FILE`,
    with a `{"data":{"previous-password":"<base64>"}}` file) and syncing `auth`
    by hand. ArgoCD stops auto-syncing a revision after its retry limit.
- Without a working password the Job fails with that instruction; no credential
  is ever printed.

## oauth2-proxy

- Issuer realm `teknoir`; login/redeem/userinfo over the gateway
  (`https://auth.<domain>/auth/...`), JWKS in-cluster.
- `--provider-ca-file` from Secret `teknoir-root-ca-bundle` (`ca.crt`, the
  public Teknoir CA certificate; the node's secrets phase reconciles it). The
  volume is non-optional on purpose: without the CA, oauth2-proxy does not
  start, which is visible, instead of failing every login with a TLS error. If
  oauth2-proxy is down, ext_authz fails closed on every protected vhost.
- `--extra-jwt-issuers` is off by default (`oauth2Proxy.oidc.cliClientId`): it
  makes oauth2-proxy run OIDC discovery at startup, which cannot succeed before
  the PostSync import has created the realm. On a fresh install oauth2-proxy
  would crash-loop, ArgoCD would never reach PostSync, and the realm would
  never be imported (a deadlock). So the first sync leaves it off.
- Client secret and cookie secret from `oauth2-proxy-secret`; the client secret
  is a platform-secrets copy of `keycloak-client-secrets[teknoir]` and
  platform-secrets restarts oauth2-proxy when it changes.

### tnctl (client `teknoir-cli`)

Realm `teknoir` has the public client `teknoir-cli` (OAuth device flow only: no
password grant, no browser code flow; the access token carries the audience
`teknoir-cli`). `tnctl login --domain <domain> --realm teknoir` uses it; install
the install's `teknoir-root-ca.crt` on the client first.

To let tnctl through the gateway, turn the extra issuer on in a **second sync**,
after the first install has converged and `keycloak-config` has run:

1. Check the client exists: log in to the Keycloak admin console (realm
   `teknoir`, Clients, `teknoir-cli`) or look at the `keycloak-config` Job log.
2. Release the auth chart with `oauth2Proxy.oidc.cliClientId: teknoir-cli` as
   its default (bump the chart version, pin it in app-of-apps; the Applications
   take no Helm value overrides) and let ArgoCD sync `auth`. oauth2-proxy rolls
   and then runs OIDC discovery of the realm.
3. Backstage restricts what that token may do (`config.externalAccess.accessRestrictions`
   in the backstage chart: the `device` plugin and read-only catalog). Roll out
   the backstage chart with the restriction **before** step 2.

Turn it off again by setting `cliClientId: ""`.

## Denied requests

The ingress gateway decides **who gets in** with Envoy ext_authz against oauth2-proxy (`/oauth2/auth<original path>`), exactly as before.
What changed is how a **denied** request is answered. The contract:

> Only a top-level browser navigation that the edge authorizer denied is redirected to login. Every other request the edge
> authorizer denied gets `401` with a `WWW-Authenticate` challenge and a small JSON body. A `401`/`403` that the backend produced after
> the edge let the request through is passed on unchanged.

### 1. Who is a "browser"

Decided from request headers only, never from the path:

1. `Sec-Fetch-Mode` present: `navigate` is a browser, any other value (`cors`, `no-cors`, `same-origin`, `websocket`) is an API client.
   Browsers send `Sec-Fetch-*` on every request and page scripts cannot set or forge it.
2. Header absent (old browsers, curl, scripts): `Authorization` or `X-Requested-With` present is an API client; else `GET`/`HEAD` with an
   `Accept` containing `text/html` is a browser; anything else (`*/*`, `application/json`, no `Accept`) is an API client.

The default is "API client". The classifier only chooses between two denials; it never decides who is allowed in.

### 2. What the gateway answers

Applies to a `401`/`403` produced by the edge authorizer (ext_authz) for a request without a session cookie, outside `/oauth2*`.

| Caller | Status | Headers | Body |
|---|---|---|---|
| Browser navigation | `302` | `Location: https://<shared host>/oauth2/start?rd=<url-encoded https://<host><path>>`, `Content-Length: 0`, `Cache-Control: no-store` (oauth2-proxy's expired session `Set-Cookie` is kept) | empty |
| Anything else, no `Authorization` header | `401` | `WWW-Authenticate: Bearer realm="teknoir"`, `Content-Type: application/json`, `Content-Length: <body length>`, `Cache-Control: no-store`; no `Location`, no `Set-Cookie` | the JSON below |
| Anything else, `Authorization` header sent | `401` | as above, with `WWW-Authenticate: Bearer realm="teknoir", error="invalid_token"` | the JSON below |

```json
{"error":"unauthorized","message":"Authentication required: run tnctl login or sign in in the browser."}
```

The body is fixed: it never says why the request was denied and never echoes the token, the user or `rd`.

### 3. What passes through unchanged

- **Backend `401`/`403`.** If ext_authz let the request through (or is switched off for the vhost/route, e.g. `argocd.`), a
  `401`/`403` is the backend's own answer: Backstage's "not allowed", a Grafana login page, Argo CD's challenge. Clients see the
  backend's status, headers and body. `403` means "you are logged in but not allowed"; logging in again does not fix it.
- Requests under `/oauth2*` (the login flow itself).
- Requests that carry the session cookie (`oauth2Proxy.cookie.name`). This is the redirect-loop guard; a stale cookie is answered as
  ext_authz answers it (no redirect).
- Everything that is not a `401`/`403`.

### 4. Client guidance

- `tnctl` and other API clients: `401` means "not logged in, token rejected, or the auth service is unavailable; log in again, and
  retry later if that does not help". The gateway cannot tell these apart: when oauth2-proxy is down, times out or answers `5xx`,
  Envoy ext_authz denies with its default `403` (`status_on_error` is not set, and the ext_authz block is deliberately unchanged),
  and that denial is shaped like any other (`401` JSON for an API client, `302` for a browser; before this change always `302`).
  Client messages must not claim more than that the token was rejected or authentication is unavailable. Setting ext_authz
  `status_on_error: 503` would let outages pass through as `503`; that touches the golden ext_authz block and is left to a
  separate reviewed change. `403` means "not allowed for this
  account or teamspace" and carries the backend's message. Gateways without this change (older releases) still
  answer a login redirect (`302`) for both; clients must keep handling that.
- Scripts that relied on a `302` from a non-browser request now see `401` (release note).
- WebSocket upgrade requests (`Sec-Fetch-Mode: websocket`) get `401` instead of a redirect.
- SPAs (`fetch`/XHR) get `401` JSON instead of a redirect that fails as a cross-origin error. A full navigation still redirects.

### 5. Why this does not weaken authentication

- The ext_authz patch (`INSERT_FIRST`, no `failure_mode_allow`, `allowed_headers`) and every oauth2-proxy flag and per-route `disabled`
  entry are unchanged. The rendered diff of this change contains no line of either.
- The Lua filter only runs its rewrite in the response phase, only for `401`/`403`, and its outputs are `302`, `401` or the
  unchanged response. No branch produces a `2xx` and none sends a request upstream.
- "The backend answered" is known from dynamic metadata (`oauth2_proxy_authz.passed`) set by a second tiny Lua filter placed
  **after** ext_authz (`envoy.filters.http.lua.authz_passed`), which only runs for requests ext_authz let through. Clients cannot
  write dynamic metadata. If that patch is ever lost, the code falls back to rewriting (the old behaviour), never to exposing a denial
  as a backend answer. In that fallback the denial branch cannot tell a backend `401`/`403` from ext_authz's, so it buffers the
  body of every backend `401`/`403` (never of other statuses). A backend `401`/`403` body larger than the connection buffer limit then
  fails (HTTP/1.1: `500`, HTTP/2: the `401` JSON) instead of passing through. Auth is not weakened, but this is not exactly "today's
  behaviour" (the old Lua never called `body()`). The harness covers it (`marker lost (fallback)`).
- `rd` and the `/oauth2` exemption are built from `:authority`/`:path` and `x-forwarded-proto` (scheme, `http`/`https` only), not from
  client-supplied `X-Forwarded-Host`/`X-Forwarded-Uri`.
- The Lua touches the response body only on a denial (the small sign-in page). Normal responses are never buffered, so SSE,
  WebSocket and downloads are unaffected. The old rewrite set `Content-Length: 0` but left the 8.5 KB sign-in page in the body,
  which made HTTP/2 clients fail with `PROTOCOL_ERROR` and left stray bytes on HTTP/1.1 keep-alive connections; body and length are now
  replaced together.

### 6. Filter order on the gateway listeners (no `portNumber` scoping here)

```
lua (denial shaping)  ->  ext_authz  ->  lua.authz_passed (marker)  ->  ... ->  router
```

Requests flow left to right; responses (including ext_authz's local denial) flow right to left, so the denial shaping sees the denial
but never a marker, and sees a backend answer together with the marker.

### Running the gateway tests

`helm unittest charts/auth` covers the filter order, the ext_authz golden copy, the templated cookie name and shared host and the Lua
contract. The offline Envoy harness `tests/gateway/run.sh` (docker with `istio/proxyv2:1.29.2`, helm, curl with HTTP/2, python3 + PyYAML)
runs the real patches in Envoy and a curl matrix over HTTP/1.1 and HTTP/2, and prints a summary table; it exits non-zero on any failure.
Its matrix hard-codes the cookie name `_teknoir_oauth2_proxy_v2` and the domain `teknoir.test`, and this chart needs `_helpers.tpl` and
no keycloakx dependency, so render the EnvoyFilter yourself and pass it in (documented option `RENDERED`):

```sh
d=$(mktemp -d) && mkdir -p $d/chart && cp -r charts/auth/templates charts/auth/files charts/auth/values.yaml $d/chart/ &&
  printf 'apiVersion: v2\nname: auth\nversion: 0.0.0\n' >$d/chart/Chart.yaml &&
  helm template auth $d/chart --namespace teknoir-auth --set domain=teknoir.test \
    --set oauth2Proxy.cookie.name=_teknoir_oauth2_proxy_v2 -s templates/istio-auth.yaml >$d/envoyfilter.yaml
RENDERED=$d/envoyfilter.yaml charts/auth/tests/gateway/run.sh
```

The harness chain is lua, ext_authz, marker, router (there is no license filter on this branch).

## Dependencies

- Secrets `keycloak-admin`, `keycloak-client-secrets`, `keycloak-platform-admin`,
  `keycloak-db-secret`, `oauth2-proxy-secret`, `oauth2-proxy-redis-secret`
  (platform-secrets, which syncs first).
- Secret `teknoir-root-ca-bundle` in `teknoir-auth` (node secrets phase).
- Images: `ghcr.io/teknoir/keycloak-theme:latest` (IfNotPresent: a restart never
  pulls a newer Keycloak), `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`,
  `docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5`,
  `docker.io/alpine/k8s:1.34.11`.

## Upgrade notes (0.0.8 -> 0.0.9)

- Realm `teknoir` gets the client `teknoir-cli` at the next PostSync import. oauth2-proxy is unchanged
  (`cliClientId` stays `""`, see "tnctl").
- The EnvoyFilter changes (applied live, no pod restarts): denied non-browser requests get `401` JSON
  instead of a login redirect (see "Denied requests").
- Release together with backstage 0.0.84, which restricts the tnctl principal and rolls backstage-api once
  (Recreate: about a minute without the portal API).

## Upgrade notes (0.0.3 -> 0.0.8)

- Before `up`: `teknoir-auth/keycloak-admin` must exist with the admin's
  current password in `previous-password` (`teknoir-airgap migrate`, see
  "Keycloak admin").
- keycloak-0 restarts once (the admin env now comes from a Secret).
- oauth2-proxy moves to realm `teknoir`. Logins fail between the moment
  platform-secrets re-syncs `oauth2-proxy-secret[client-secret]` and the end of
  the first realm import; existing sessions of realm master become invalid.
- Users of realm master are not migrated; realm `teknoir` starts with
  `platform-admin` (initial password in `keycloak-platform-admin`, forced change
  at first login).

## Tests

`helm unittest charts/auth` (oauth2-proxy extra issuer, realm client `teknoir-cli`, gateway filters).

`tests/realm-docker-test.sh` (not packaged) runs the rendered realm file and
admin check against Keycloak 26.5.3 in docker: admin rotation from
`previous-password`, a full import, user-controller's service-account rights
(and that it cannot read clients), the client secrets, token claims
(`sub`, `email`, `email_verified`, `groups`), a no-op second import, a secret
change on re-import, platform-admin (group admin, complete profile, a scripted
browser login that meets exactly the Update Password form, and a changed
password that survives re-imports with no second forced change), a real tnctl
device-flow login (client `teknoir-cli`: no password grant, no code flow, token
audience `teknoir-cli`), and a scan of every log for every secret value. The import runs with the Job's rendered env.
