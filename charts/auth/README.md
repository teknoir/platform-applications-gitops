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

- `tnctl` and other API clients: `401` means "not logged in or token rejected, log in again"; `403` means "not allowed for this
  account or teamspace" and carries the backend's message. Old gateways (production, airgapped until they get this change) still
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
  as a backend answer.
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

## Tests

```sh
helm unittest charts/auth                 # filter order, ext_authz golden copy, templated cookie name / shared host, Lua contract
charts/auth/tests/gateway/run.sh          # offline Envoy harness, needs docker (istio/proxyv2:1.29.2), helm, curl, python3 + PyYAML
```

`tests/gateway/run.sh` renders `templates/istio-auth.yaml`, takes the real filter patches out of it and runs them in Envoy with a
python stub that mimics oauth2-proxy (allow a known bearer or cookie, otherwise `403` + an 8492-byte HTML page) and a backend stub.
It runs a curl matrix over HTTP/1.1 and HTTP/2 (`Sec-Fetch-Mode` x `Accept` x `Authorization` x cookie x path, plus HEAD, POST and
`X-Requested-With`), raw keep-alive sockets for HTTP/1.1 framing, spoofed forwarding headers, backend `401`/`403` pass-through, a
listener without the marker filter and a streaming response, then prints a summary table and exits non-zero on any failure.
`RENDERED=<file>` runs it against any already rendered EnvoyFilter (for example the old template, to see what it catches).
