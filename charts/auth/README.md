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
  the PostSync import has created the realm.
- Client secret and cookie secret from `oauth2-proxy-secret`; the client secret
  is a platform-secrets copy of `keycloak-client-secrets[teknoir]` and
  platform-secrets restarts oauth2-proxy when it changes.

## Dependencies

- Secrets `keycloak-admin`, `keycloak-client-secrets`, `keycloak-platform-admin`,
  `keycloak-db-secret`, `oauth2-proxy-secret`, `oauth2-proxy-redis-secret`
  (platform-secrets, which syncs first).
- Secret `teknoir-root-ca-bundle` in `teknoir-auth` (node secrets phase).
- Images: `ghcr.io/teknoir/keycloak-theme:latest` (IfNotPresent: a restart never
  pulls a newer Keycloak), `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`,
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

## Tests

`tests/realm-docker-test.sh` (not packaged) runs the rendered realm file and
admin check against Keycloak 26.5.3 in docker: admin rotation from
`previous-password`, a full import, user-controller's service-account rights
(and that it cannot read clients), the client secrets, token claims
(`sub`, `email`, `email_verified`, `groups`), a no-op second import, a secret
change on re-import, platform-admin (group admin, complete profile, a scripted
browser login that meets exactly the Update Password form, and a changed
password that survives re-imports with no second forced change), and a scan of
every log for every secret value. The import runs with the Job's rendered env.
