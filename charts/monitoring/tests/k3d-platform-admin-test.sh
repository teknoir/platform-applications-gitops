#!/usr/bin/env bash
# Policy matrix for templates/platform-admin-only.yaml on a real Istio (plans/platform-monitoring-access.md).
#
# Runs ONLY against a throwaway k3d cluster you pass in CTX (k3d-*), never vpro or production. It needs Istio
# (istiod, no gateway: `istioctl --context k3d-x install --set profile=minimal -y`) and network access to pull
# docker.io/kennethreitz/httpbin and docker.io/curlimages/curl. Everything is created in the namespace
# pao-test and removed again at the end (KEEP=1 keeps it).
#
#   CTX=k3d-pao charts/monitoring/tests/k3d-platform-admin-test.sh
#
# The chart's own policies are rendered with helm (the three workload labels are put on three httpbin pods) with
# three test-only changes: the gateway principal (also in the existing ALLOW policies) is the ServiceAccount `gw` of the test namespace (the "ingress
# gateway") and the JWKS is inline (a key generated here) instead of https://auth.<domain>. The tokens are signed
# with that key, so the matrix proves the real Istio semantics: the groups claim of a VALIDATED token, a missing
# claim failing closed, and unrelated callers (Prometheus' service account) untouched.
set -euo pipefail
CTX=${CTX:?set CTX to a throwaway k3d context, e.g. k3d-pao}
case "$CTX" in k3d-*) ;; *) echo "refusing: CTX must be a k3d-* context, got $CTX" >&2; exit 2 ;; esac
[[ "$CTX" == "k3d-teknoir-dev" ]] && { echo "refusing: use a dedicated throwaway cluster, not k3d-teknoir-dev" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/.." && pwd)"
NS=pao-test
K=(kubectl --context "$CTX" -n "$NS")
W=$(mktemp -d); trap '[[ -n "${KEEP:-}" ]] || kubectl --context "$CTX" delete ns '"$NS"' --wait=false >/dev/null 2>&1; rm -rf "$W"' EXIT

# --- keys, tokens -------------------------------------------------------------------------------------------
python3 -I - "$W" <<'PY'
import sys, json, time, base64
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
w = sys.argv[1]
def mk():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)
good, other = mk(), mk()
def jwk(k, kid):
    d = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(k.public_key()))
    d.update({"kid": kid, "use": "sig", "alg": "RS256"}); return d
open(f"{w}/jwks.json", "w").write(json.dumps({"keys": [jwk(good, "k1")]}))
iss = "https://auth.pao.test/auth/realms/master"
now = int(time.time())
def tok(claims, key=good, exp=3600, issuer=iss, alg="RS256"):
    c = {"iss": issuer, "sub": "u", "iat": now, "exp": now + exp, "email": "x@example.test"}; c.update(claims)
    return jwt.encode(c, key, algorithm=alg, headers={"kid": "k1"})
tokens = {
    "admin":            tok({"groups": ["admin"]}),
    "admin-and-others": tok({"groups": ["teknoir-demo-devs", "admin", "x"]}),
    "developer":        tok({"groups": ["developer"]}),
    "no-groups":        tok({}),
    "empty-groups":     tok({"groups": []}),
    "admin-prefix":     tok({"groups": ["admin2", "superadmin", "administrators", "/admin"]}),
    "admin-as-string":  tok({"groups": "admin"}),
    "role-not-group":   tok({"realm_access": {"roles": ["admin"]}, "role": "admin"}),
    "badsig":           tok({"groups": ["admin"]}, key=other),
    "expired":          tok({"groups": ["admin"]}, exp=-3600),
    "wrongiss":         tok({"groups": ["admin"]}, issuer="https://evil.example/realms/master"),
}
# alg none (unsigned) token
b = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
tokens["alg-none"] = b({"alg": "none", "typ": "JWT"}) + "." + b({"iss": iss, "groups": ["admin"], "exp": now + 3600}) + "."
for k, v in tokens.items():
    open(f"{w}/tok-{k}", "w").write(v)
PY

# --- render the chart's policies (test-only: gateway principal, inline JWKS) -------------------------------
helm template monitoring "$CHART" --namespace "$NS" --set namespace="$NS" --set domain=pao.test \
  --set platformAdminOnly.gatewayPrincipal="cluster.local/ns/$NS/sa/gw" \
  -s templates/platform-admin-only.yaml -s templates/authorizationpolicy.yaml > "$W/rendered.yaml"
python3 -I - "$W" <<'PY'
import sys, re
w = sys.argv[1]
jwks = open(f"{w}/jwks.json").read()
s = open(f"{w}/rendered.yaml").read()
s, n = re.subn(r'^(\s*)jwksUri: .*$', lambda m: f"{m.group(1)}jwks: '{jwks}'", s, flags=re.M)
assert n == 3, n
# templates/authorizationpolicy.yaml names the real gateway principal: point it at the test gateway too
s = s.replace('cluster.local/ns/istio-system/sa/istio-ingressgateway', f'cluster.local/ns/pao-test/sa/gw')
open(f"{w}/policies.yaml", "w").write(s)
PY

# --- workloads ----------------------------------------------------------------------------------------------
kubectl --context "$CTX" create ns "$NS" >/dev/null 2>&1 || true
kubectl --context "$CTX" label ns "$NS" istio-injection=enabled --overwrite >/dev/null
{
for sa in gw monitoring-prometheus other; do echo "---
apiVersion: v1
kind: ServiceAccount
metadata: {name: $sa}"; done
for w in grafana prometheus alertmanager; do echo "---
apiVersion: v1
kind: Service
metadata: {name: $w}
spec: {selector: {app.kubernetes.io/name: $w}, ports: [{port: 80, targetPort: 80}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: $w}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: $w}}
  template:
    metadata: {labels: {app.kubernetes.io/name: $w}}
    spec:
      containers:
      - {name: httpbin, image: 'docker.io/kennethreitz/httpbin:latest', ports: [{containerPort: 80}]}"; done
for sa in gw monitoring-prometheus other; do echo "---
apiVersion: apps/v1
kind: Deployment
metadata: {name: client-$sa}
spec:
  replicas: 1
  selector: {matchLabels: {app: client-$sa}}
  template:
    metadata: {labels: {app: client-$sa}}
    spec:
      serviceAccountName: $sa
      containers:
      - {name: curl, image: 'docker.io/curlimages/curl:8.11.1', command: [sleep, '86400']}"; done
} > "$W/workloads.yaml"
"${K[@]}" apply -f "$W/workloads.yaml" >/dev/null
"${K[@]}" apply -f "$W/policies.yaml" >/dev/null
for d in grafana prometheus alertmanager client-gw client-monitoring-prometheus client-other; do
  "${K[@]}" rollout status deploy/$d --timeout=240s >/dev/null
done

# --- matrix -------------------------------------------------------------------------------------------------
fail=0
call() { # client target [token-name header-name]
  local client=$1 target=$2 tok=${3:-} hdr=${4:-x-auth-request-access-token} args=()
  [[ -n "$tok" ]] && args=(-H "$hdr: $(cat "$W/tok-$tok")")
  "${K[@]}" exec deploy/client-$client -c curl -- curl -s -m 10 -o /dev/null -w '%{http_code}' "${args[@]}" "http://$target/get" 2>/dev/null || true
}
# Wait until every sidecar enforces the policies: a valid admin token must pass (a stale or not yet pushed JWKS
# answers 401), and a request without a token must be refused.
wait_ready() {
  local t i
  for t in grafana prometheus alertmanager; do
    for i in $(seq 1 45); do
      [[ "$(call gw $t admin)" == 200 && "$(call gw $t)" == 403 ]] && continue 2
      sleep 4
    done
    echo "FAIL  policies of $t not enforced after 180 s" >&2; exit 1
  done
}
wait_ready
expect() { # description want client target [token header]
  local desc=$1 want=$2; shift 2
  local got; got=$(call "$@")
  if [[ "$got" == "$want" ]]; then printf 'ok    %s -> %s\n' "$desc" "$got"; else printf 'FAIL  %s -> %s (want %s)\n' "$desc" "$got" "$want"; fail=1; fi
}
for t in grafana prometheus alertmanager; do
  echo "== gateway principal -> $t"
  expect "no token"                                   403 gw $t
  expect "admin"                                      200 gw $t admin
  expect "admin among other groups"                   200 gw $t admin-and-others
  expect "developer"                                  403 gw $t developer
  expect "token without a groups claim"               403 gw $t no-groups
  expect "empty groups"                               403 gw $t empty-groups
  expect "admin2/superadmin/administrators//admin"    403 gw $t admin-prefix
  expect "groups as the string admin (not a list)"    200 gw $t admin-as-string
  expect "realm role admin, no group"                 403 gw $t role-not-group
  expect "bad signature, claims admin"                401 gw $t badsig
  expect "expired, claims admin"                      401 gw $t expired
  expect "wrong issuer, claims admin"                 401 gw $t wrongiss
  expect "alg none, claims admin"                     401 gw $t alg-none
  expect "valid admin token in Authorization header"  403 gw $t admin Authorization
  expect "valid admin token in x-forwarded-access-token" 403 gw $t admin x-forwarded-access-token
done
echo "== Prometheus' own identity (scrape, alert delivery, self-scrape) and in-namespace callers: no token, untouched"
expect "monitoring-prometheus -> grafana"      200 monitoring-prometheus grafana
expect "monitoring-prometheus -> alertmanager" 200 monitoring-prometheus alertmanager
expect "monitoring-prometheus -> prometheus"   200 monitoring-prometheus prometheus
expect "other pod, same namespace -> prometheus (prometheus-allow-internal, as before)" 200 other prometheus
expect "other pod -> grafana (not in its ALLOW, as before)"      403 other grafana
expect "other pod -> alertmanager (not in its ALLOW, as before)" 403 other alertmanager
exit $fail
