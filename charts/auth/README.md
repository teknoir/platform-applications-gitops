# auth chart

Keycloak (`keycloakx`), oauth2-proxy and the Istio ingress wiring that puts every Teknoir host behind a login:

- `templates/istio-auth.yaml`: the `oauth2-proxy-ext-authz` EnvoyFilter on the ingress gateway (TLS listener, port 443) plus the
  Istio policies for the `teknoir-auth` namespace.
- `templates/oauth2-proxy.yaml`: oauth2-proxy (the ext_authz backend; Keycloak is the identity provider).
- Per-vhost exemptions (`auth.`, `harbor.`, `argocd.`, `wg.`, `bypassAuth`) and per-route exemptions (`/oauth2*`, keycloak) switch
  ext_authz (and, where noted in the template, the Lua) off because the backend authenticates itself.

## Denied requests

The ingress gateway decides **who gets in** with Envoy ext_authz against oauth2-proxy (`/oauth2/auth<original path>`), exactly as before.
What changed is how a **denied** request is answered. The contract:

> Only a top-level browser navigation that the edge authorizer denied is redirected to login. Every other request the edge
> authorizer denied gets `401` with a `WWW-Authenticate` challenge and a small JSON body. A dead session (the request carries the
> session cookie but oauth2-proxy answers `401`) is handled the same way, and its cookie is cleared. A `403` that oauth2-proxy
> produced for a logged-in user, and a `401`/`403` that the backend produced after the edge let the request through, are passed on unchanged.

oauth2-proxy runs with `--force-json-errors=true`: needs-login is `401` (`{}`), logged-in-but-not-allowed is `403` (`{}`). Without
the flag it answers a stale cookie with a `403` sign-in page (or a `500` for a cookie it cannot decode), which the gateway cannot
tell from "not allowed".

### 1. Who is a "browser"

Decided from request headers only, never from the path:

1. `Sec-Fetch-Mode` present: `navigate` is a browser when it is a top-level document load (`Sec-Fetch-Dest` is `document` or absent, and
   there is no `Sec-Purpose` header). Any other value (`cors`, `no-cors`, `same-origin`, `websocket`), a navigation into an
   `iframe`/`frame`/`embed`/`object`, and a prefetch or prerender (`Sec-Purpose`) are API clients: they get the `401` JSON, never a
   redirect and never the loop-guard marker, so a background load cannot put a later real navigation on the sign-in-failed page.
   Browsers send `Sec-Fetch-*` on every request and page scripts cannot set or forge it.
2. Header absent (old browsers, curl, scripts): `Authorization` or `X-Requested-With` present is an API client; else `GET`/`HEAD` with an
   `Accept` containing `text/html` is a browser; anything else (`*/*`, `application/json`, no `Accept`) is an API client.

The default is "API client". The classifier only chooses between two denials; it never decides who is allowed in.

### 2. What the gateway answers

Applies to a `401` (with or without a session cookie) or a `403` (without one) produced by the edge authorizer (ext_authz), outside
`/oauth2*`. "Cookie" is the session cookie (`oauth2Proxy.cookie.name`), matched by exact name.

| Caller | Status | Headers | Body |
|---|---|---|---|
| Browser navigation | `302` | `Location: https://<shared host>/oauth2/start?rd=<url-encoded https://<host><path>>`, `Content-Length: 0`, `Cache-Control: no-store`, loop-guard marker `Set-Cookie: _teknoir_auth_retry=1; Path=/; Max-Age=30; HttpOnly; Secure; SameSite=Lax` (host-only); with a session cookie also two clearing `Set-Cookie` (below) | empty |
| Browser navigation that already carries the marker | `401` | `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`, a restrictive `Content-Security-Policy`; no `Location`, no new marker; clearing `Set-Cookie` when a session cookie was sent | "Sign-in did not complete" (the sign-in gave this browser no valid session, or the sign-in service is temporarily unavailable) with a retry link (`/oauth2/start?rd=...`) and a sign-out link (`/oauth2/sign_out?rd=<retry link>`) |
| Anything else, no `Authorization` header, no session cookie | `401` | `WWW-Authenticate: Bearer realm="teknoir"`, `Content-Type: application/json`, `Content-Length: <body length>`, `Cache-Control: no-store`; no `Location`, no `Set-Cookie` | the JSON below |
| Anything else, `Authorization` header or session cookie sent | `401` | as above, with `WWW-Authenticate: Bearer realm="teknoir", error="invalid_token"`; with a session cookie also the two clearing `Set-Cookie` | the JSON below |

```json
{"error":"unauthorized","message":"Authentication required: run tnctl login or sign in in the browser."}
```

The body is fixed: it never says why the request was denied and never echoes the token, the user or `rd`. The only request-derived
text in the sign-in-failed page is `rd`, percent-encoded inside two links.

**Clearing the session cookie.** When a session cookie was sent and the denial is rewritten, the gateway adds
`<cookie name>=; Domain=<cookie domain>; Path=<cookie path>; Max-Age=0; Expires=<epoch>; HttpOnly; Secure; SameSite=<cookie sameSite>`
and the same without `Domain` (a host-only cookie). oauth2-proxy cannot clear a cookie it cannot decode (key rotation, corruption),
and on the API path its own `Set-Cookie` would otherwise be dropped, so without this a browser with a bad cookie stays locked out
until the cookie expires. oauth2-proxy's own clearing `Set-Cookie` is kept next to ours.

**Loop guard.** The login redirect goes to `/oauth2/start` (not behind ext_authz), through Keycloak and back to the original URL. If that
URL is denied again within 30 s (a cookie the browser does not keep, a session the proxy rejects), a second redirect would loop forever.
The `302` therefore sets the short-lived marker; a navigation that is denied and carries it gets the sign-in-failed page. The page's
links are on `/oauth2` (never behind the guard). The marker is host-only (no `Domain`): a tab on another host (a second app, a `wgt-`
tab) is still redirected. A second tab on the *same* host opened within 30 s on a still-unauthenticated browser sees the page once; its
"Try again" link goes straight to login. The same happens during an oauth2-proxy outage (the redirect cannot complete); the page says so.

### 3. What passes through unchanged

- **Backend `401`/`403`.** If ext_authz let the request through (or is switched off for the vhost/route, e.g. `argocd.`), a
  `401`/`403` is the backend's own answer: Backstage's "not allowed", a Grafana login page, Argo CD's challenge. Clients see the
  backend's status, headers and body. `403` means "you are logged in but not allowed"; logging in again does not fix it.
- Requests under `/oauth2*` (the login flow itself).
- **A `403` that carries the session cookie** (oauth2-proxy `force-json-errors`: the session is valid but not authorized; or the
  authorizer itself failed): logging in again does not help, so it is not redirected. A browser navigation whose `403` body is empty
  or the bare `{}` gets a small `403` HTML page ("Access not permitted": not allowed, or the sign-in service is temporarily
  unavailable) with the same retry and sign-out links. Everything else (fetch, XHR, other bodies such as an old oauth2-proxy's own
  HTML) passes through; if it has no `Content-Type` one is added (`text/plain` when there is no body or no `Content-Length`, as in
  an authorizer outage; else `application/json`); nothing else changes.
- Everything that is not a `401`/`403`.

### 4. Client guidance

- `tnctl` and other API clients: `401` means "not logged in, token rejected, or the auth service is unavailable; log in again, and
  retry later if that does not help". The gateway cannot tell these apart: when oauth2-proxy is down, times out or answers `5xx`,
  Envoy ext_authz denies with its default `403` (`status_on_error` is not set, and the ext_authz block is deliberately unchanged),
  and that denial is shaped like any other (`401` JSON for an API client, `302` for a browser; before this change always `302`).
  With a session cookie the `403` passes through (see section 3), so an authorizer outage shows a logged-in browser a `403`, not a redirect.
  Client messages must not claim more than that the token was rejected or authentication is unavailable. Setting ext_authz
  `status_on_error: 503` would let outages pass through as `503`; that touches the golden ext_authz block and is left to a
  separate reviewed change. `403` means "not allowed for this
  account or teamspace" and carries the backend's message. Old gateways (production, airgapped until they get this change) still
  answer a login redirect (`302`) for both; clients must keep handling that.
- Scripts that relied on a `302` from a non-browser request now see `401` (release note).
- WebSocket upgrade requests (`Sec-Fetch-Mode: websocket`) get `401` instead of a redirect.
- SPAs (`fetch`/XHR) get `401` JSON instead of a redirect that fails as a cross-origin error. A full navigation still redirects.
  A `401` with `WWW-Authenticate: Bearer realm="teknoir"` means "the session is gone": a SPA should sign in again
  (`/oauth2/start?rd=<current URL>`). With a live Keycloak SSO session the round trip is silent.
- A browser with a dead or undecodable session cookie is no longer shown a blank `403`: the next navigation is redirected to login
  and the cookie is cleared.

### 5. Why this does not weaken authentication

- The ext_authz patch (`INSERT_FIRST`, no `failure_mode_allow`, `allowed_headers`) and every oauth2-proxy flag and per-route `disabled`
  entry are unchanged. The rendered diff of this change contains no line of either.
- The Lua filter only runs its rewrite in the response phase, only for `401`/`403`, and its outputs are `302`, `401` (JSON or the
  sign-in-failed page) or the unchanged response. No branch produces a `2xx` and none sends a request upstream.
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

### 6. Filter order on the 443 listener

```
lua (denial shaping)  ->  ext_authz  ->  lua.authz_passed (marker)  ->  ... ->  router
```

Requests flow left to right; responses (including ext_authz's local denial) flow right to left, so the denial shaping sees the denial
but never a marker, and sees a backend answer together with the marker.

## Session lifetimes

Realm `master` (`files/realm/master.yaml`, imported by keycloak-config-cli after every sync) pins `accessTokenLifespan: 300` (5 min),
`ssoSessionIdleTimeout: 86400` (1 d), `ssoSessionMaxLifespan: 604800` (7 d) and `offlineSessionIdleTimeout: 2592000` (30 d, tnctl's
offline token). oauth2-proxy refreshes the Keycloak token every minute (`cookie.refresh`) while a page sends requests and keeps its own
cookie for `cookie.expire: 168h`, the same length as the SSO maximum. The two clocks differ: the cookie's lifetime slides on every refresh,
the SSO maximum is absolute, so a cookie can outlive its SSO session; that case is a dead session, handled as in "Denied requests". The import
sends only the listed realm fields; everything else in the realm is left alone. Changing lifetimes does not log anyone out: Keycloak
checks the current values on the next use of a session. The values apply to the whole `master` realm (including the admin console).
A dead session (idle over a day, or over 7 d) is answered as described in "Denied requests".

## Tests

```sh
helm unittest charts/auth                 # filter order, ext_authz golden copy, templated cookie name / shared host, Lua contract
charts/auth/tests/gateway/run.sh          # offline Envoy harness, needs docker (istio/proxyv2:1.29.2), helm, curl, python3 + PyYAML
```

`tests/gateway/run.sh` renders `templates/istio-auth.yaml`, takes the real filter patches out of it and runs them in Envoy with a
python stub that mimics oauth2-proxy with `--force-json-errors` (allow a known bearer or cookie; `401 {}` for no or bad credentials, a
dead session cookie `stale` and an undecodable one `garbage`; `403 {}` for a logged-in-but-not-allowed `forbidden` cookie; the old
`403` + 8492-byte HTML page for a `legacy` cookie and the `/legacy403`, `/oauth2x` paths, i.e. new Lua against an old oauth2-proxy
during a rolling deploy) and a backend stub.
It runs a curl matrix over HTTP/1.1 and HTTP/2 (`Sec-Fetch-Mode` x `Accept` x `Authorization` x cookie x path, plus HEAD, POST and
`X-Requested-With`; OPTIONS preflights and HEAD with a dead cookie; iframe/prefetch navigations), every client kind with a dead or garbage session cookie on the apex, `next.`, `wgt-` and `wgs-` hosts, the loop
guard (marker with and without a session cookie, with a good cookie, on API requests, lookalike names, a hostile path), the `403`
pass-through, backend `401`/`403` with a session cookie, raw keep-alive sockets for HTTP/1.1 framing, spoofed forwarding headers, backend `401`/`403` pass-through, a
listener without the marker filter, a listener whose authorizer is down (empty `403`), a streaming response, real WebSocket upgrades (allowed: `101` and echo both ways; denied: the `401`
JSON with consistent framing) and bodies far above the harness's 32 KiB per-connection buffer limit (20 MiB allowed download and a
5 MiB backend `403`, over HTTP/1.1 and HTTP/2), then prints a summary table and exits non-zero on any failure.
`RENDERED=<file>` runs it against any already rendered EnvoyFilter (for example the old template, to see what it catches).
