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
  keeps remote state, so it only deletes objects it created. Users are not
  managed here (user-controller and `teknoir-airgap admin-user` create them).

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
- **Existing install with a known old admin password** (the teknoir-local
  migration): once platform-secrets has created `keycloak-admin`, add the old
  password as `previous-password` (for example
  `kubectl -n teknoir-auth patch secret keycloak-admin --type merge --patch-file /dev/stdin`
  fed from a file, never on the command line), then sync `auth`.
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

- Secrets `keycloak-admin`, `keycloak-client-secrets`, `keycloak-db-secret`,
  `oauth2-proxy-secret`, `oauth2-proxy-redis-secret` (platform-secrets, which
  syncs first).
- Secret `teknoir-root-ca-bundle` in `teknoir-auth` (node secrets phase).
- Images: `ghcr.io/teknoir/keycloak-theme:latest` (IfNotPresent: a restart never
  pulls a newer Keycloak), `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0`,
  `docker.io/adorsys/keycloak-config-cli:6.5.1-26.5.5`,
  `docker.io/alpine/k8s:1.34.11`.

## Upgrade notes (0.0.3 -> 0.0.8)

- keycloak-0 restarts once (the admin env now comes from a Secret).
- oauth2-proxy moves to realm `teknoir`. Logins fail between the moment
  platform-secrets re-syncs `oauth2-proxy-secret[client-secret]` and the end of
  the first realm import; existing sessions of realm master become invalid.
- Users of realm master are not migrated; the platform admin is re-created in
  realm `teknoir` (`teknoir-airgap admin-user`).

## Tests

`tests/realm-docker-test.sh` (not packaged) runs the rendered realm file and
admin check against Keycloak 26.5.3 in docker: admin rotation from
`previous-password`, a full import, user-controller's service-account rights
(and that it cannot read clients), the client secrets, token claims
(`sub`, `email`, `email_verified`, `groups`), a no-op second import, a secret
change on re-import, and a scan of every log for every secret value.
