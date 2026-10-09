# Teknoir monitoring chart

kube-prometheus-stack (Prometheus, Alertmanager, Grafana and the
prometheus-operator CRDs) for the platform, behind the Istio ingress gateway at
`https://<domain>/teknoir-system/{grafana,prometheus,alertmanager}/`.

## Access

Only members of the Keycloak groups in `monitoring.access.groups` (default
`[admin]`, realm `teknoir`) can reach the three UIs.

1. The gateway's ext_authz (oauth2-proxy, auth chart) signs the user in and
   forwards their Keycloak access token in `X-Auth-Request-Access-Token` and
   `X-Forwarded-Access-Token`.
2. `templates/requestauthentication.yaml` verifies the token on each workload
   against `monitoring.access.issuer`. istiod fetches the JWKS from
   `<issuer>/protocol/openid-connect/certs`. An invalid token gets 401.
   `forwardOriginalToken` keeps the header, so Grafana sees it.
3. `templates/authorizationpolicy.yaml` admits the gateway only when the
   token's `groups` claim holds one of `monitoring.access.groups`. Other
   realm users get 403.
4. Grafana signs the user in from the same token (`grafana.ini` `auth.jwt`).
   The login is `preferred_username` (the e-mail), and group `admin` maps to
   the Admin role (`role_attribute_path`, strict). Anonymous access and
   self sign-up are off.

In-namespace traffic needs no token:
- `prometheus-allow-internal` admits teknoir-system, which covers Grafana's
  Prometheus datasource and the operator.
- `alertmanager-allow-prometheus` admits Prometheus' ServiceAccount, so alerts
  are delivered.

  Prometheus addresses Alertmanager by its Service
  (`prometheusSpec.alertingEndpoints` rewrites `__address__`). The chart's
  default discovers pod IPs instead, and the Prometheus sidecar sends a request
  for a pod IP to its PassthroughCluster in plaintext. Alertmanager's sidecar
  (STRICT mTLS) resets it, so every notification failed with 503.

Grafana's `jwk_set_url` must be https: Grafana 12 refuses to start with an
http one ("must have https scheme"). So it is the issuer's own URL, not the
in-mesh `keycloak-http` service. Grafana trusts the Teknoir Root CA from Secret
`teknoir-root-ca-bundle`, which the airgap node copies into teknoir-system,
mounted at `/etc/teknoir/ca` and added through `SSL_CERT_DIR`.

`grafana.ini` sits in the grafana subchart's values and cannot read
`monitoring.access`, so it repeats the issuer. `templates/access-check.yaml`
fails the render if the two differ, or if anonymous access is turned on.

### Changing who has access

- Add a group to `monitoring.access.groups`.
- To give that group a Grafana role other than Viewer, extend
  `role_attribute_path` as well.
- When the domain changes, change `monitoring.access.issuer`, `domain`,
  `grafana.ini` `server.domain` and the two `auth.jwt` URLs together.

### Break-glass

When no token verifies, for example because the CA Secret is missing or
Keycloak is down:

- Use the local Grafana admin from Secret `monitoring-grafana`
  (`admin-user`/`admin-password`) with basic auth over
  `kubectl port-forward svc/monitoring-grafana 3000:80`. Basic auth stays on;
  the dashboard and datasource sidecars need it.
- Prometheus and Alertmanager can be reached the same way through their
  Services.

## Tests

| Test | What it checks | Needs |
|---|---|---|
| `tests/render-test.sh` | Renders the chart and checks the RequestAuthentications, the groups conditions, alert delivery, the `grafana.ini` keys, the CA mount and the render guards | helm, yq and jq; no cluster |
| `tests/grafana-jwt-docker-test.sh` | Runs the chart's Grafana image with the rendered `grafana.ini`, plus a test CA and JWKS. Token sign-in, Admin/Viewer mapping, rejected tokens, basic auth, TLS verification, the https requirement and that no secret reaches the logs | docker |

## CRDs

`crds/` holds the prometheus-operator CRDs, vendored by `update-crds.sh` and
annotated `Prune=false,Delete=false`. `templates/crds-version-check.yaml`
fails the render when the kube-prometheus-stack pin and `crds/` disagree.
