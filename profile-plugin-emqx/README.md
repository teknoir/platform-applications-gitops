# profile-plugin-emqx

EMQX 5 broker for a teamspace, wrapping the upstream `emqx` chart.

## Config changes roll EMQX

`emqx.recreatePods: true` makes the upstream chart add a `checksum/config`
annotation to the StatefulSet pod template. It is a hash of the generated
ConfigMap, which carries `emqx.emqxConfig` (the `EMQX_*` environment). Changing
any `emqxConfig` value therefore restarts `emqx-0` once, so a chart upgrade
that changes broker config takes effect without a manual restart.

## Certificate renewal needs no restart

The TLS listener on 8883 reads `/certs/tls.crt` and `/certs/tls.key`. They come
from the Secret `domain-wildcard-tls`, mounted as a directory at `/certs` (no
`subPath`), so kubelet updates the files in place when profile-controller copies
a renewed certificate into the teamspace. EMQX picks the new files up by hot
reload (about 2 minutes, no restart, no dropped clients). Do not add a
`subPath` to the mount and do not add a restart-on-secret-change tool: either
would break this or restart EMQX on every renewal.

## MQTT authentication and authorization

Set in `emqx.emqxConfig` (`EMQX_AUTHENTICATION__*`, `EMQX_AUTHORIZATION__*`), with the ACL file
from `templates/acl-configmap.yaml`. Plan: `plans/unified-device-auth/mqtt-hardening.md`.

**Authentication chain** (in order; an authenticator answering "ignore" passes the client on to
the next one, anything else is final):
1. Built-in database: the platform user `teknoir` (fleet-metrics, historian, Observatory,
   device-controller, Backstage). A wrong password for `teknoir` is a hard stop.
2. HTTP, `POST http://jwks:8083/api/v1/mqtt/authn` (profile-plugin-jwks): jwks-server verifies
   the device's RS256 token against the one key stored for that username, checks `aud` and `exp`,
   and requires clientid = username.
   In `observe` mode (profile-plugin-jwks `mqttAuth.authnMode`) a failure answers "ignore" and
   logs `mqtt_authn decision=would_deny`; in `enforce` it answers "deny". A pass is never a
   superuser and carries no ACL.
3. Legacy JWT (`use_jwks`, the union key set at `/api/v1/keys`, `aud` checked): a temporary
   fallback for clients that authenticator 2 answers "ignore" (every observe failure at 0.0.112,
   and a jwks error or timeout at 0.0.113 and 0.0.114). 0.0.115 removes it, after which the chain
   fails closed.

Only the EMQX pod's mTLS principal (`<trustDomain>/ns/<ns>/sa/emqx`) may call
`/api/v1/mqtt/*` on jwks (profile-plugin-jwks `jwks-mqtt-auth` DENY); EMQX is not a key writer.

**Authorization.** Source 1 is a file, `/opt/emqx-acl/acl-<hash>.conf` (helper
`teknoir.emqx.aclConf`), keyed on the username. First match wins:
- `teknoir`: everything under `/devices/#`;
- nobody subscribes `$SYS/#`, `#` or `+/#`;
- a device (username matching `^[a-z0-9][a-z0-9.-]*$`, so it never contains `+`, `#` or `/`):
  subscribe `/devices/<name>/config` and `/devices/<name>/commands/#`; publish
  `/devices/<name>/state/#` and `/devices/<name>/events/#`, never retained.
Everything else falls to `authorization.no_match`. The file has no allow-all line, no `127.0.0.1`
(`ipaddr`) rule and no dashboard rule. EMQX reads it only when the source is created (boot), and
only a change of the env ConfigMap rolls the pod, so the file name carries the first 12 hex
digits of the content's sha256: an ACL change changes `SOURCES__1__PATH` and restarts EMQX.

While observing, source 2 is an HTTP audit sink, `POST http://jwks:8083/api/v1/mqtt/authz-audit`.
It sees only requests the file did not decide, always answers "ignore", and jwks-server logs them
as `mqtt_authz_audit decision=would_deny`. `no_match` is `allow`, so nothing is refused yet.
Do not set `mqtt.use_username_as_clientid`: platform clients share the user `teknoir` with
distinct clientids and would take over each other's sessions.

**Modes, one chart version each** (every step is a staging release; production stays on its pin):

| Version | jwks `authnMode` | `NO_MATCH` | Source 2 (audit) | Authenticator 3 (legacy JWT) | Restarts |
|---|---|---|---|---|---|
| 0.0.112 observe | `observe` | `allow` | yes | yes | EMQX, jwks |
| 0.0.113 authn enforce | `enforce` | `allow` | yes | yes | jwks |
| 0.0.114 authz enforce | `enforce` | `deny` | removed | yes | EMQX |
| 0.0.115 fail closed | `enforce` | `deny` | removed | removed | EMQX |

Who would be denied while observing:
`kubectl -n <ns> logs deploy/jwks -c jwks | grep -E 'mqtt_(authn|authz_audit)' | grep -v decision=allow`.

**Rollback.** Pin the previous plugin chart version (profile-controller `pluginChartVersion`
through a staging release); EMQX and jwks get the old env and image back exactly. Do not change
authentication or authorization through the EMQX API or dashboard: the env overrides it on the
next restart, so the chart is the only rollback path. A device locked out by an older TOE build
recovers on its next connect after the rollback (TOE mints a fresh token per connect) or after a
TOE restart.

Tests: `helm unittest` (`tests/mqtt_auth_test.yaml`), and `tests/acl-check.sh` (helm template,
then docker `emqx/emqx:5.8.9`: the file parses, every rule compiles with EMQX's own rule compiler,
and a username/action/topic matrix gives the expected allow, deny or no-match; `--check` skips
docker).

## Dashboard: no EMQX login, owners only

EMQX 5 Open Source cannot run its dashboard without a login, and `teknoir` / `teknoir` was
the well-known password. So the dashboard host (`emqx-dashboard-<ns>.<domain>`) no longer
routes to EMQX. It routes to the `emqx-dashboard` Deployment (`templates/dashboard.yaml`,
`dashboard.enabled`), an nginx proxy with a guard container next to it.

Flow:
1. The user ingress gateway (Keycloak + oauth2-proxy sign-in) sends the request to the proxy
   Service `emqx-dashboard:18083` over mTLS.
2. **Who may reach it is decided by Istio.** The `emqx-dashboard-gateway-only` DENY policy
   admits only `dashboard.gatewayPrincipals` (the user gateway's service account; never the
   `-public` gateway). Notebooks, Devstudios, other teamspaces and plaintext pods get 403,
   whatever the namespace-wide ALLOW policies say. On top of that, the gateway forwards only
   owners: the per-user policy user-controller compiles from the claim presets admits port
   18083 only for the `role-user-management` claim (the `owner` claim set). Every other claim
   rule carries `notPorts: ["18083"]`. The rule lives in platform-applications-gitops
   `charts/user-controller/templates/presets.yaml`; a future Claim with rules must exclude
   18083 too (its unit test lists the claims that have no rules).
3. The proxy adds the teamspace's EMQX API key (Secret `emqx-bootstrap-api-keys`, read by
   reference, never sent to the browser) to `/api/v5/*` calls. It answers the dashboard's
   `/api/v5/login` and `/logout` itself, and injects `teknoir-sso.js` into the page, which
   gives the dashboard a placeholder session so it never shows its login page.
4. The proxy never returns 401 (an upstream 401 becomes 403
   `EMQX_CREDENTIAL_REJECTED`): the gateway hangs on backend 401 responses.
5. CSRF guard on the credentialed API. The oauth2-proxy cookie (`SameSite=None`,
   `Domain=teknoir.cloud`) is sent by a browser on any site, so Istio alone does not prove an
   owner meant a call, and the proxy adds an admin credential to it. The proxy therefore
   requires an `Authorization: Bearer ...` header (the placeholder session `teknoir-istio`, or any
   other bearer: an owner who used EMQX's own login before keeps that old JWT in localStorage
   until `teknoir-sso.js` replaces it, and the proxy swaps the header for the API key anyway; the
   dashboard's axios client sends it on every call; a foreign page cannot send an
   Authorization header without a CORS preflight, which fails) and, for anything but GET/HEAD, `Sec-Fetch-Site: same-origin`
   (browsers set it, pages cannot; same-site `*.teknoir.cloud` pages send `same-site` and are
   refused; a missing header on a write fails closed). Otherwise 403 `TEKNOIR_CSRF_GUARD`,
   never 401. Covered by `tests/dashboard-proxy-e2e.sh` (cross-origin multipart `import_users`
   creates no user) and `tests/k3d-dashboard-authz.sh`.
6. `/api/v5/users*` and `/api/v5/api_key*` answer 403 `MANAGED_BY_TEKNOIR`, so the dashboard's
   Users and API keys pages and Change password do not work (by design). A request whose
   raw path is not `/api/v5/...` (for example `/events%2F..%2Fapi/v5/nodes`) gets 400, so
   path-prefix rules cannot reach the API.

**Fail-safe.** `teknoir-sso.js` uses internals of the dashboard UI (v1.10.5: `__vue_app__`,
`$store`, `$router`, `UPDATE_USER_INFO`). If an EMQX upgrade renames them, owners see EMQX's
login page and any username and password work (the proxy answers the login); nothing is
exposed either way. Run `tests/dashboard-proxy-e2e.sh` (and look at the dashboard) on every
EMQX image bump.

**Default passwords.** The chart sets no dashboard password. The `default-login-guard`
container logs in with the known defaults (`dashboard.knownDefaultPasswords`: `teknoir`, and
EMQX's built-in `public`) every `dashboard.guardIntervalSeconds` (60) and, whenever one works,
changes the password to a random value that is never stored (nobody needs it: the proxy and
profile-controller use the API key). It covers upgrades of an existing volume, fresh installs
and wiped volumes, logs one line without values, and leaves any other password alone.
While EMQX does not answer `/status` (restart, wiped volume) the guard retries every
`dashboard.guardRetrySeconds` (10), so a re-created EMQX with its built-in default password is
rotated within seconds of coming back. The guard is quiet in normal operation: only the
stderr of the login attempts (they fail with 401 once the defaults are gone) is silenced; a failing
`/status` and a failing `change_pwd` stay visible in the container log.
Break-glass for a cluster admin:
`kubectl -n <ns> exec emqx-0 -- emqx ctl admins passwd teknoir <password>` (the guard rotates
`teknoir`/`public` again, but not another value).

**Audit log.** All dashboard actions reach EMQX as the one teamspace API key, so EMQX's own
audit log cannot name the owner. The proxy writes one `AUDIT` line per API write and per failing
API call to its stdout (`kubectl logs deploy/emqx-dashboard -c nginx | grep ^AUDIT`):

    AUDIT emqx.dashboard user="owner@example.com" method=POST path="/api/v5/clients/x/kickout" status=204 req_id="..."

`user` is the gateway's `X-Auth-Request-Email` (`-` when absent), `path` is `$uri` (no query
string, never `$request`), `req_id` is the gateway's request id for correlation. Successful reads
are not logged. The default `main` access log does not log API requests at all (it would write
their query strings): the API location sets its own `access_log`, and the server-level lines
route API requests to the audit format and everything else (pages, assets) to `main`. Login and
logout, answered by the proxy, are audited like any other POST. A malformed raw path
(`/events%2F..%2Fapi/v5/...`, answered 400) is not an API request and goes to `main`.

**Index caching.** `/` answers `Cache-Control: no-cache` (EMQX's own header is dropped): a stale
cached `index.html` from before the proxy made owners see EMQX's login form. `X-Frame-Options`
is repeated in that location because a location with its own `add_header` does not inherit the
server's.

**Port 18083 of EMQX (management API).** Without more, any pod in any namespace could call
`emqx:18083` with the API key it can read: `emqx-authz` admits the port from anywhere, the
`whitelist-namespaces` DENY exempts it, and the namespace-wide policies of profile-controller admit
every in-namespace sidecar pod on all ports. The DENY policy `emqx-api-restrict` (`emqxApi.*`
in `values.yaml`) closes that: on port 18083 of the `emqx` pod every mesh caller whose principal is
not listed is denied (DENY beats every ALLOW). Allowed: the `emqx-dashboard` ServiceAccount (the
proxy and the guard share its sidecar), or the gateway principals when `dashboard.enabled=false`,
plus `emqxApi.callers` and `emqxApi.extraPrincipals`. MQTT/WebSocket ports (1883, 8883, 8083, 8084)
are not touched.
Callers found (all repos, plus the live emqx sidecar): profile-controller (`plugin_emqx.go`,
creates the MQTT bootstrap user at `emqx:18083`, no sidecar, plaintext), the proxy and the guard
in the `emqx-dashboard` pod, the kubelet probes (rewritten by Istio to the sidecar's
15020, so they never reach the port from outside) and, since 0.0.111, device-controller
(`internal/controller/emqx`, sidecar, so it is listed in `emqxApi.callers` by default): it closes
the MQTT sessions of a disabled or deleted Device with `GET /api/v5/clients?username=<device>`
and `DELETE /api/v5/clients/<clientid>`, using the API key in `emqx-bootstrap-api-keys`. Nothing
else calls the API.

Because profile-controller has no sidecar it has no principal, so it cannot be named in a policy.
`emqxApi.allowPlaintext: true` (default) therefore leaves callers *without* mTLS alone and denies
only mesh callers; that closes the hole for every Devstudio, Notebook, plugin pod and other
teamspace, but not for a pod someone started with `sidecar.istio.io/inject: "false"`. Closing it
needs profile-controller in the mesh: give its pod a sidecar, then set
`emqxApi.extraPrincipals: ["cluster.local/ns/teknoir-system/sa/profile-controller"]` and
`emqxApi.allowPlaintext: false`. Order: sidecar first, values second (the reverse breaks the MQTT
user creation). `tests/k3d-dashboard-authz.sh` covers both modes.

**Not changed.** Developers (`teknoir-edit`)
can still read the API key Secret and exec into `emqx-0`, so "owners only" guards the browser
path, not what a developer can do with kubectl. The dashboard's built-in WebSocket client does
not work against the dashboard host; use `mqtt-<ns>.<domain>:443/mqtt`.

**`dashboard.enabled=false`.** The VirtualService routes the dashboard host straight to
`emqx:18083` again and the guard no longer runs, while the chart still sets no dashboard
password. On a fresh volume EMQX then keeps its well-known default `public`. Do not disable the
proxy without setting `emqx.emqxConfig.EMQX_DASHBOARD__DEFAULT_PASSWORD` to a real value.

**Rollout order (never C1 alone).** The proxy has no owner check of its own and adds the admin
API key to every call: "owners only" is decided entirely by the claim presets
(platform-applications-gitops `charts/user-controller`, `notPorts: ["18083"]` on the generic
rules). So the presets must be live before chart 0.0.109 is pinned on a cluster, and when
rolling back, pin 0.0.108 first (or together with the presets revert), never revert the presets
while 0.0.109 is live: every developer would then reach the EMQX admin API without a login.
Before pinning 0.0.109, check that every user policy in the namespace has `notPorts: ["18083"]`
or belongs to an owner.

**New cluster.** Set `dashboard.gatewayPrincipals` to that cluster's user-gateway service
account and ship the claim presets with it. The image `nginxinc/nginx-unprivileged` (pinned by
digest in `values.yaml`) must be mirrored for airgapped installs.

Tests (`tests/`): `helm unittest` (`dashboard_test.yaml`), `dashboard-proxy-e2e.sh` (docker:
real EMQX, the rendered proxy and guard, read-only like the pod; includes the audit line, the
cache headers and the guard's logging and timing), `k3d-dashboard-authz.sh`
(throwaway k3d cluster with Istio: owner, developer, path confusion, sidecar, plaintext and
other-namespace matrix, plus direct EMQX 18083 and MQTT 1883 access in both `emqxApi` modes). Both scripts take `--check` for a dry run.
