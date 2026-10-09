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
- Clients: `teknoir` (oauth2-proxy, PKCE S256, redirect
  `https://<domain>/oauth2/callback` and `https://*.<domain>/oauth2/callback`,
  post-logout redirect `https://<domain>/*` for the Backstage logout),
  `argocd` (`https://argocd.<domain>/auth/callback`), `harbor`
  (`https://harbor.<domain>/c/oidc/callback`), `user-controller` (service account
  only, realm-management `manage-users`, `view-users`, `query-users`).
- Client scope `groups` (flat group names in ID/access tokens and userinfo),
  default on teknoir/argocd/harbor; group `admin` (ArgoCD role:admin, Harbor
  admin group). Default scopes include `basic`, which carries `sub` (Backstage
  requires it).
- Required action `VERIFY_PROFILE` is disabled (`realm.verifyProfile: false`).
  Keycloak 26's default user profile requires a last name; users created by
  user-controller before r5 have none and would meet the "Update your account
  information" form at their first login. Only this required action is
  managed; no `userProfile` document is imported (it would replace the whole
  profile, including the unmanaged-attribute policy user-controller's claim
  attributes rely on). Set `realm.verifyProfile: true` once every user has a
  last name.
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
  the user is exactly in group `admin`.
- **Disabled since 0.0.9** (`realm.platformAdmin.enabled: false`, decision D1):
  named admins exist (`teknoir-airgap admin-user`), and anyone who can read
  `keycloak-platform-admin` could otherwise sign in as an admin. A fresh
  install creates the user disabled. Break-glass: the master-realm admin
  (`teknoir-airgap credentials keycloak-admin`) can enable it in the console;
  the next sync of `auth` disables it again (keycloak-config-cli never deletes
  users).

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

### Legacy master-realm clients

Before the redesign, the platform clients lived in realm master. On a migrated
install realm master still holds `teknoir`, `argocd` and `harbor`; the legacy
`teknoir` client has a service account with master-realm `manage-users`
(enough to reset the master admin's password, `tests/realm-docker-test.sh`
R11) and shares its secret with oauth2-proxy. As its last step the init
container deletes the clients listed in `keycloakConfig.masterLegacyClients`
(default `[teknoir, argocd, harbor]`, env `KC_MASTER_LEGACY_CLIENTS`) from
realm master, with Keycloak deleting their service-account users:

- Only when realm `realm.name` (env `KC_REALM`) has a client with the same
  clientId, i.e. the move happened. Before the first realm import (a fresh
  install, or a migrated one whose import has not run yet) nothing is deleted.
- Never a built-in client: `admin-cli`, `security-admin-console`, `broker`,
  `master-realm`, `realm-management`, `account*`, `*-realm`. The chart refuses
  them (and anything that is not a plain clientId) at render time, and the
  script refuses them again.
- Idempotent: a client that is gone is logged and skipped. Logs client names
  only. `[]` turns the step off.
- Fails the Job before deleting anything when a lookup fails or a clientId
  appears more than once in either realm.
- **Irreversible** except from a backup: take the encrypted node backup
  before the first sync of 0.0.9 on an existing install.

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
  the PostSync import has created the realm.
- Client secret and cookie secret from `oauth2-proxy-secret`; the client secret
  is a platform-secrets copy of `keycloak-client-secrets[teknoir]` and
  platform-secrets restarts oauth2-proxy when it changes.

## Gateway: ext_authz and the login redirect

`templates/istio-auth.yaml` adds three HTTP filters to the ingress gateway's
TLS listener (`portNumber: 443`; plain HTTP on :80 stays a bare 301 to https):

1. `envoy.filters.http.lua` (INSERT_BEFORE ext_authz) records the request URL
   (from `:authority` and `:path`; client-supplied `X-Forwarded-*` are not
   trusted at the edge) and whether it is a navigation.
2. `envoy.filters.http.ext_authz` (INSERT_FIRST) asks oauth2-proxy.
3. `envoy.filters.http.lua.authz_ok` (INSERT_AFTER ext_authz) sets dynamic
   metadata `oauth2_proxy.authz=ok`. It runs only when ext_authz let the
   request through (or is disabled for the route). It must stay after
   ext_authz: before it, every denial would pass as a bare 403.

On the way back filter 1 rewrites a 401/403 only when `authz` is not `ok` (an
ext_authz denial; oauth2-proxy answers every denial with 403) and the path is
not `/oauth2*`:

- navigation: 302 to `https://<sharedHost>/oauth2/start?rd=<request URL>`,
  plus two Set-Cookie headers that expire the session cookie (with
  `Domain=<cookie domain>` and host-only), so a cookie that oauth2-proxy can
  no longer use (expired, session gone from Redis, rotated cookie secret)
  cannot cause a login loop;
- fetch/XHR/websocket (`Sec-Fetch-Mode` other than `navigate`, or
  `X-Requested-With: XMLHttpRequest`): a bare 401 with no Location.

An upstream's own 401/403 for a signed-in user (Backstage, ArgoCD API,
teamspace apps) passes through unchanged. Before 0.0.9 a cookie heuristic
(`has_session`) decided this, so any request with an unusable cookie got a
bare 403. Per-vhost disables: `auth.` and `argocd.` (ext_authz), `harbor.`
(both); per route: `oauth2-proxy-auth` (ext_authz) and `keycloak` (both).
`istio.bypassAuth` (`[{gateway, vhost}]`, default `[]`) disables both filters
for further vhosts whose backend authenticates by itself.

## Dependencies

- Secrets `keycloak-admin`, `keycloak-client-secrets`, `keycloak-platform-admin`,
  `keycloak-db-secret`, `oauth2-proxy-secret`, `oauth2-proxy-redis-secret`
  (platform-secrets, which syncs first).
- Secret `teknoir-root-ca-bundle` in `teknoir-auth` (node secrets phase).
- Images, all `IfNotPresent`. Pinned (G-09) to an immutable tag plus the
  linux/amd64 manifest digest (`crane digest --platform linux/amd64`, never
  the index digest):
  - `ghcr.io/teknoir/keycloak-theme:sha-29d2ed6a@sha256:ab392e6e…`
    (Keycloak 26.5.3). keycloakx renders `<repository>@<digest>` and puts
    `tag` into the label `app.kubernetes.io/version`, so `keycloak.image`
    has `repository: …/keycloak-theme:sha-29d2ed6a`, `digest: sha256:…` and
    `tag: sha-29d2ed6a` (a label cannot hold `@`). A new Keycloak runs a
    one-way DB migration; change the pin deliberately.
  - `docker.io/library/postgres:16.15@sha256:75adc2a6…` (`keycloakDb.image`)
  - `docker.io/library/redis:7.2.16-alpine@sha256:84bab713…`
    (`oauth2Proxy.redis.image`)
  - `docker.io/kennethreitz/httpbin@sha256:599fe5e5…` (`httpbin.image`;
    upstream publishes only `latest`, so digest only)
  - by version tag: `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`,
    `docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5`,
    `docker.io/alpine/k8s:1.34.11`.

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

## Upgrade notes (0.0.8 -> 0.0.9, r5)

- keycloak-0 restarts once (the image reference changes to the pinned one;
  same content, so no DB migration): about 1-2 minutes without login.
  keycloak-db restarts (same PostgreSQL 16.15).
- oauth2-proxy-redis restarts (pinned image), so every session is dropped and
  every user signs in again.
- The EnvoyFilter is hot-reloaded by istiod: no gateway restart.
- The PostSync Job deletes the legacy master-realm clients (see "Legacy
  master-realm clients"): take the encrypted backup first. It disables
  platform-admin and VERIFY_PROFILE and adds the post-logout redirect.
- No k3s restart.

## Tests

Not packaged (`.helmignore tests/`); dependencies come from the cache that
`tests/render.sh` uses (`tests/lib.sh`).

- `tests/render-test.sh` (helm, yq; no docker): the pinned images and the
  keycloak version label, no `Always`/`:latest`; the three gateway filters on
  :443 in the right order (authz_ok INSERT_AFTER ext_authz) and `bypassAuth`;
  the admin-check env and the render-time refusal of built-in client names;
  the realm's post-logout redirect, VERIFY_PROFILE and platform-admin values;
  kubeconform.
- `tests/lua-test.sh` (docker, pinned LuaJIT 2.1): runs both rendered Lua
  filters with `tests/lua-harness.lua`, a stub of Envoy's Lua API in the
  filter order: denied navigation, garbage cookie (302 plus the expiring
  cookies), fetch/XHR/websocket (401, no Location), upstream 401/403 for a
  signed-in user (unchanged), `/oauth2/*`, other statuses, and that the
  redirect URL ignores `X-Forwarded-*`.
- `tests/admin-check-test.sh` (jq; no docker): the legacy-client step under
  dash and busybox sh with a stub curl playing Keycloak's admin API: what is
  deleted (by the master client's id) and what is kept (realm `teknoir`
  missing, or without the clientId), a clientId twice in either realm, exact
  clientId matching, built-in and non-plain names, the off switches, lookup
  and delete errors, and no password or token in the output.
  `ADMIN_CHECK=<file>` runs another script (a mutant) instead.
- `tests/realm-docker-test.sh` runs the rendered realm file and admin check
  against Keycloak 26.5.3 in docker: admin rotation from `previous-password`,
  a full import, user-controller's service-account rights (and that it cannot
  read clients), the client secrets, token claims (`sub`, `email`,
  `email_verified`, `groups`), a no-op second import, a secret change on
  re-import, platform-admin (rendered enabled: group admin, complete profile,
  a scripted browser login that meets exactly the Update Password form, and a
  changed password that survives re-imports), the legacy master-realm clients
  (R11: kept before realm teknoir exists, the severity, deleted with their
  service accounts, old secrets 401, built-ins kept, a listed client realm
  `teknoir` lacks kept, idempotent), platform-admin
  disabled by the default values (R12), the logout redirect and VERIFY_PROFILE
  (R13: a user without a last name gets no profile form; a signed-in logout
  meets the confirmation page and returns to `https://<domain>/`), and a scan
  of every log for every secret value. The import runs with the Job's
  rendered env.
