# Teknoir monitoring chart

kube-prometheus-stack (Prometheus, Alertmanager, Grafana and the
prometheus-operator CRDs) for the platform, behind the Istio ingress gateway at
`https://<domain>/teknoir-system/{grafana,prometheus,alertmanager}/`.

## Access

Only members of the Keycloak groups in `monitoring.access.groups` (default
`[admin]`, realm `teknoir`) can reach the three UIs.

1. The gateway's ext_authz (oauth2-proxy, auth chart) signs the user in and
   puts their Keycloak access token in `X-Auth-Request-Access-Token`,
   replacing any value the client sent.
2. `templates/requestauthentication.yaml` verifies the token on each workload
   against `monitoring.access.issuer`. istiod fetches the JWKS from
   `<issuer>/protocol/openid-connect/certs`. An invalid token gets 401.
   `forwardOriginalToken` keeps the header, so Grafana sees it. It also reads
   `X-Forwarded-Access-Token` (the plan's header list, as in the Backstage
   chart). oauth2-proxy's auth endpoint never sets that header, so only a
   client sends it, and it passes the gateway unchanged. It counts only when
   it is a valid, unexpired token of the realm, so using it needs a token of
   a group-admin user as well as a session at the gateway. Dropping it from
   `jwtRules` would close that path, and Grafana does not need it.
3. `templates/authorizationpolicy.yaml` admits the gateway only when the
   token's `groups` claim holds one of `monitoring.access.groups`. Any other
   realm user signs in at the gateway, then gets 403 (`RBAC: access
   denied`) from the workload's sidecar on all three paths. This is not a
   sign-in failure: add the user to a group in `monitoring.access.groups`
   (the next token carries it, so sign out and in again).
4. Grafana signs the user in from `X-Auth-Request-Access-Token`
   (`grafana.ini` `auth.jwt`). The login is `preferred_username`, the
   Keycloak username: the e-mail address for users that user-controller
   creates, while the realm's platform admin signs in with its own username.
   The e-mail is `email`. Group `admin` maps to the Admin role
   (`role_attribute_path`, strict). Anonymous access and self sign-up are
   off.

The lifecycle endpoints are closed to every source.
`prometheus-deny-lifecycle` and `alertmanager-deny-lifecycle` DENY quit and
reload. The operator runs Prometheus with `--web.enable-lifecycle`, so a POST
to `/teknoir-system/prometheus/-/quit` stops it. Such a POST can be a simple
cross-site request, and the oauth2-proxy cookie is `SameSite=None`. Without
the DENY, a page that an admin visits could stop Prometheus through the
gateway with the admin's token, and any platform pod could do it without one.
The config-reloader sidecars reload through `127.0.0.1`, which does not pass
the inbound sidecar, so they are not affected.

The policies match each endpoint with every spelling of its slashes:
`*-/quit`, `*-%2Fquit`, `*-%2fquit` and the same for `reload`. Istio matches
paths after the mesh's path normalization, which is BASE (the istio chart
sets none). BASE resolves dot segments and decodes encoded unreserved
characters such as `%2D`, but keeps an encoded slash. Prometheus and
Alertmanager decode `%2F` before they route. With a plain `*/-/quit`, a POST
to `/teknoir-system/prometheus/-%2Fquit` or `.../prometheus%2F-/quit` passed
the DENY and stopped Prometheus (`tests/lifecycle-deny-docker-test.sh` L5).
Matching from the `-` covers the slash before it in all three spellings. A
doubled or trailing slash gets a redirect to the clean path, which goes back
through the sidecar. A mesh-wide `pathNormalization: DECODE_AND_MERGE_SLASHES`
would close encoded slashes for every path-based policy at once; that is an
istio chart change.

"Group admin only" holds for the gateway path. Inside the mesh, traffic from
teknoir-system and teknoir-auth needs no token:

- The harbor chart's `harbor-allow-internal` has no selector. It therefore
  applies to every workload in teknoir-system, Grafana, Prometheus and
  Alertmanager included, and admits any mTLS source in teknoir-system and
  teknoir-auth. Every platform pod in those namespaces (Backstage, Argo CD,
  Keycloak, oauth2-proxy, the controllers) can use the Prometheus and
  Alertmanager APIs, silences included, without a token. Teamspaces and
  other namespaces cannot.
- Grafana's Alertmanager datasource
  (`http://monitoring-alertmanager.teknoir-system:9093`, a Service, so mTLS
  as `monitoring-grafana`) is admitted only by `harbor-allow-internal`.
- This chart's own in-namespace ALLOWs cover the paths it needs, so those keep
  working without `harbor-allow-internal`:
  - `prometheus-allow-internal` admits teknoir-system, which covers Grafana's
    Prometheus datasource and the operator.
  - `alertmanager-allow-prometheus` admits Prometheus' ServiceAccount, so
    alerts are delivered.
- STRICT mTLS also comes from the harbor chart: `harbor-strict-mtls` is a
  namespace-wide PeerAuthentication.

`tests/namespace-authz-test.sh` renders every chart that app-of-apps installs
into teknoir-system and the root namespace (or, with `--renders DIR`, reads
the renders of `tests/render.sh --out DIR`, so render.sh can run it as its
monitoring-authz check). It checks every policy that
applies to the three workloads, whichever chart renders it: none may admit
the gateway without the groups claim, and only teknoir-system and teknoir-auth
get in without a token. It also lists which policies admit each in-mesh path.

Planned for the next release, with VM tests: give `harbor-allow-internal` a
selector (`app.kubernetes.io/name: harbor`), and add explicit in-namespace
ALLOWs for the workloads that depend on it today: the Argo CD components,
Grafana to Alertmanager, and Prometheus as a client of the other workloads.

Alert delivery goes to the Service. Prometheus addresses Alertmanager by its
Service (`prometheusSpec.alertingEndpoints` rewrites `__address__`). The
upstream chart's default discovers pod IPs instead, and the Prometheus sidecar
sends a request for a pod IP to its PassthroughCluster in plaintext.
Alertmanager's sidecar (STRICT mTLS) resets that request, so every
notification failed with 503. The cause was the transport, not authorization:
`harbor-allow-internal` would have admitted the request had it arrived over
mTLS. Because every replica gets the same Service address, each batch reaches
one Alertmanager replica only, and replicas do not share alerts. So
Alertmanager runs one replica, and HA needs per-pod addresses over mTLS
first.

Grafana's `jwk_set_url` must be https: Grafana 12 refuses to start with an
http one ("must have https scheme"). So it is the issuer's own URL, not the
in-mesh `keycloak-http` service. Grafana trusts the Teknoir Root CA from Secret
`teknoir-root-ca-bundle`, which the airgap node copies into teknoir-system,
mounted at `/etc/teknoir/ca` and added through `SSL_CERT_DIR`. The mount is
optional, so Grafana starts without the Secret, but no token verifies. Go
loads the trusted roots once per process: after the Secret is created or
rotated, restart Grafana, or it keeps rejecting every token
(`tests/grafana-jwt-docker-test.sh` G11):

```sh
kubectl --context teknoir-local -n teknoir-system rollout restart deployment/monitoring-grafana
```

`grafana.ini` sits in the grafana subchart's values and cannot read
`monitoring.access`, so it repeats the issuer. `templates/access-check.yaml`
fails the render in these cases:

- The two issuers differ.
- `auth.jwt` is off or anonymous access is on. These are read as Grafana reads
  booleans, so the string `"false"` counts as off and `"on"` as on.
- `kube-prometheus-stack.namespaceOverride` is not the namespace the policies
  are rendered into.
- An alerting endpoint is not this release's Alertmanager Service (namespace,
  name, routePrefix and the `__address__` rewrite).
- `alertmanagerSpec.replicas` is more than 1.

### Changing who has access

- Add a group to `monitoring.access.groups`.
- To give that group a Grafana role other than Viewer, extend
  `role_attribute_path` as well.
- When the domain changes, change `monitoring.access.issuer`, `domain`,
  `grafana.ini` `server.domain` and the two `auth.jwt` URLs together.

### Break-glass

When no token verifies or no admin can sign in (Secret
`teknoir-root-ca-bundle` missing, Keycloak down, Grafana not restarted after a
CA change), go around the gateway with a port-forward. A port-forward reaches
the pod directly, past the gateway and the Istio policies.

Grafana: the browser sign-in with the local admin does not work. The login
form stays off (`auth.disable_login_form: true`; `tests/render-test.sh` M6
and `tests/grafana-jwt-docker-test.sh` G10 check this), so the break-glass is
basic auth against Grafana's HTTP API only. Basic auth stays on because the
dashboard and datasource sidecars need it too. The user is `admin` (key
`admin-user` of Secret `monitoring-grafana`) and the password is key
`admin-password` (on the airgap LAN host:
`./teknoir-airgap credentials grafana-admin --out FILE`). `curl -u admin`
prompts for the password, so it never lands on the command line:

```sh
kubectl --context teknoir-local -n teknoir-system port-forward svc/monitoring-grafana 3000:80
# in another terminal:
curl -u admin http://127.0.0.1:3000/teknoir-system/grafana/api/user
curl -u admin http://127.0.0.1:3000/teknoir-system/grafana/api/datasources
curl -u admin 'http://127.0.0.1:3000/teknoir-system/grafana/api/search?query='
```

Grafana serves under `/teknoir-system/grafana/` (`serve_from_sub_path`), on
the port-forward too. Changing a user's role through the API does not last:
`auth.jwt` sets the role from the token's groups at every sign-in.

Prometheus and Alertmanager have no login of their own, so a port-forward to
their Service works in a browser:

```sh
kubectl --context teknoir-local -n teknoir-system port-forward svc/monitoring-prometheus 9090:9090
# http://127.0.0.1:9090/teknoir-system/prometheus/
kubectl --context teknoir-local -n teknoir-system port-forward svc/monitoring-alertmanager 9093:9093
# http://127.0.0.1:9093/teknoir-system/alertmanager/
```

## Tests

| Test | What it checks | Needs |
|---|---|---|
| `tests/render-test.sh` | Renders the chart and checks the RequestAuthentications, the groups conditions, alert delivery, the `grafana.ini` keys, the CA mount, the render guards and the lifecycle DENY | helm, yq and jq; no cluster |
| `tests/namespace-authz-test.sh` | Renders every chart app-of-apps installs into teknoir-system and istio-system, and checks every AuthorizationPolicy that applies to Grafana, Prometheus and Alertmanager from any chart: the gateway only with the groups claim, token-less access only from teknoir-system and teknoir-auth, the in-mesh paths the stack needs, plus self-tests | helm, yq and jq; no cluster |
| `tests/lifecycle-deny-docker-test.sh` | Puts Envoy from the istio chart's proxyv2 version, with the mesh's BASE path normalization and the rendered lifecycle DENYs as RBAC, in front of the chart's Prometheus and Alertmanager images. The API and `/-/ready` stay reachable; every spelling of quit and reload (encoded slashes, `%2D`, dot segments, a query, PUT) gets 403, and a doubled or trailing slash never a 2xx; Prometheus survives every quit probe; a self-test shows that a plain `*/-/quit` lets `-%2Fquit` stop Prometheus | docker; run it under the heavy-job lock |
| `tests/grafana-jwt-docker-test.sh` | Runs the chart's Grafana image with the rendered `grafana.ini`, plus a test CA (in a Secret volume's layout) and JWKS. Token sign-in (login and e-mail from different claims), Admin/Viewer mapping, rejected tokens, basic auth on the API, the login form off, TLS verification, a CA that appears later needing a restart, the https requirement and that no secret reaches the logs | docker |

## CRDs

`crds/` holds the prometheus-operator CRDs, vendored by `update-crds.sh` and
annotated `Prune=false,Delete=false`. `templates/crds-version-check.yaml`
fails the render when the kube-prometheus-stack pin and `crds/` disagree.
