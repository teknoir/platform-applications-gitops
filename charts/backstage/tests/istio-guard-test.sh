#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# Test of the backstage-api API guard (README "API guard"; not packaged:
# .helmignore tests/).
#
#   charts/backstage/tests/istio-guard-test.sh [--static] [--keep]
#
# --static runs only the render checks. Otherwise a throw-away k3d cluster
# (k3d-bsguard, its own kubeconfig; the default kubeconfig and current context
# are never touched) gets Istio (istioctl, ISTIO_VERSION) and the chart's
# Istio resources, Services and ServiceAccount in front of echo stand-ins for
# backstage-api (ports 7007 and 9464) and backstage (80). The stand-in answers
# with the path it got and every verified-jwt header value. The
# RequestAuthentication gets an inline JWKS of a key made here, and the
# tokens are signed with it; through the gateway the test sends the token as
# X-Auth-Request-Access-Token, as oauth2-proxy (ext_authz, not installed here)
# does for every request it lets through.
#
# Static:
#   G1 backstage-api-guard: DENY on app=backstage-api, every rule on port 7007
#   G2 /api/kubernetes: a DENY rule for "no token" and one for "groups claim
#      not in istio.apiGuard.kubernetesGroups"; backstage-api-auth-policy
#      admits the gateway to it only when the groups claim holds one of them
#      (and to every other path without that condition); an empty list fails
#      the render
#   G3 the proxy (also //proxy) is denied for everyone, and the VirtualService
#      answers it 403 in any spelling; denyKubernetesProxy=false drops both
#   G4 /api/auth needs a token (DENY); the in-mesh refresh ALLOW needs a
#      request principal; the in-mesh catalog ALLOW is unchanged
#   G5 VirtualService order: proxy (403) < lowercase /api/kubernetes/ and
#      /api/auth/ < other spellings (404) < /api/ < frontend; both
#      backstage-api routes remove verified-jwt
#   G6 istioctl validate (when installed)
#   G7 in the mesh (every source but the gateway, token or not) only the
#      catalog entity paths and /api/auth/* (which needs a token, G4)
# Live:
#   C  control: the same cluster with the policies as before this change
#      (no guard, refresh without a token, no header removal) lets a user
#      without group admin use /api/kubernetes and the proxy, and lets a
#      tokenless in-mesh caller reach the refresh endpoint, in lowercase and
#      other spellings. INFO line: whether a client-supplied verified-jwt
#      reached backstage-api without a token (Istio 1.29.2's Envoy drops it;
#      the guard does not rely on that)
#   E  through the gateway: /api/kubernetes for group admin only, the proxy
#      for nobody, other spellings never reach backstage-api, /api/auth needs a
#      token, a forged verified-jwt never reaches backstage-api, the catalog
#      and the frontend are unchanged, bad tokens are 401
#   M  in the mesh from a teamspace: catalog without a token, refresh only with
#      one (and then Envoy's verified-jwt replaces a forged one), nothing else
#   S  in the mesh from teknoir-system (admitted to everything by the harbor
#      chart's namespace-wide harbor-allow-internal, copied here): only the
#      catalog, and the auth paths with a token, in any spelling;
#      /api/kubernetes not even for group admin; the metrics port 9464 is not
#      affected
# Environment: K3S_IMAGE (default rancher/k3s:v1.33.5-k3s1), ISTIO_VERSION
# (default 1.29.2, as live), TOOLS_IMAGE (default alpine/k8s:1.34.11: curl and
# python3), KUBE_VERSION (render, default 1.33.5), HELM (default helm).
# Requires helm, yq (mikefarah v4), jq, python3, openssl; live: k3d, kubectl,
# istioctl, docker (pulls the Istio images if missing).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
CLUSTER=bsguard
CTX=k3d-$CLUSTER
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}
ISTIO_VERSION=${ISTIO_VERSION:-1.29.2}
TOOLS_IMAGE=${TOOLS_IMAGE:-alpine/k8s:1.34.11}
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
HELM=${HELM:-helm}
NS=teknoir-system
TS=ts-demo
HOST=teknoir.airgapped
GW_SA=istio-ingressgateway-service-account # istioctl's gateway
STATIC=0
KEEP=0
for a in "$@"; do
	case $a in
	--static) STATIC=1 ;;
	--keep) KEEP=1 ;;
	*)
		echo "usage: $0 [--static] [--keep]" >&2
		exit 2
		;;
	esac
done

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
WORK=$(mktemp -d)
CLUSTER_UP=0
cleanup() {
	if [ "$CLUSTER_UP" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
		k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
	fi
	if [ "$KEEP" -eq 1 ] && [ "$CLUSTER_UP" -eq 1 ]; then
		echo "kept: KUBECONFIG=$WORK/kubeconfig kubectl --context $CTX ..."
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

render() { "$HELM" template backstage "$CHART" --namespace "$NS" --kube-version "$KUBE_VERSION" "$@"; }
doc() { yq "select(.kind == \"$1\" and .metadata.name == \"$2\")" "$3"; }

echo "== static"
render >"$WORK/chart.yaml"
doc AuthorizationPolicy backstage-api-guard "$WORK/chart.yaml" >"$WORK/guard.yaml"
doc AuthorizationPolicy backstage-api-auth-policy "$WORK/chart.yaml" >"$WORK/allow.yaml"
doc VirtualService backstage "$WORK/chart.yaml" >"$WORK/vs.yaml"

[ "$(yq -r '.spec.action' "$WORK/guard.yaml")" = DENY ] &&
	[ "$(yq -r '.spec.selector.matchLabels.app' "$WORK/guard.yaml")" = backstage-api ] &&
	[ "$(yq -r '[.spec.rules[] | select(([.to[].operation.ports] | flatten | join(",")) == "7007")] | length' "$WORK/guard.yaml")" = "$(yq -r '.spec.rules | length' "$WORK/guard.yaml")" ] &&
	ok "G1 backstage-api-guard: DENY on app=backstage-api, every rule on port 7007" || bad "G1 guard shape: $(cat "$WORK/guard.yaml")"

k8s_rules=$(yq -o=json -I=0 '[.spec.rules[] | select((.to[0].operation.paths // [] | join(",")) == "/api/kubernetes,/api/kubernetes/*")]' "$WORK/guard.yaml")
[ "$(jq -r '[.[] | select(.from[0].source.notRequestPrincipals == ["*"])] | length' <<<"$k8s_rules")" = 1 ] &&
	[ "$(jq -c '[.[] | select(.when[0].key == "request.auth.claims[groups]") | .when[0].notValues]' <<<"$k8s_rules")" = '[["admin"]]' ] &&
	ok "G2 /api/kubernetes: denied without a token and for groups other than admin" || bad "G2 kubernetes rules: $k8s_rules"
gw_rules=$(yq -o=json -I=0 '[.spec.rules[] | select(.from[0].source.principals[0] == "cluster.local/ns/istio-system/sa/istio-ingressgateway") | {"to": .to[0].operation, "when": .when}]' "$WORK/allow.yaml")
[ "$gw_rules" = '[{"to":{"notPaths":["/api/kubernetes","/api/kubernetes/*"]},"when":null},{"to":{"paths":["/api/kubernetes","/api/kubernetes/*"]},"when":[{"key":"request.auth.claims[groups]","values":["admin"]}]}]' ] &&
	ok "G2 the gateway reaches /api/kubernetes only with groups claim admin (ALLOW values: a token without the claim matches nothing)" || bad "G2 gateway ALLOW rules: $gw_rules"
if render --set 'istio.apiGuard.kubernetesGroups=null' >/dev/null 2>"$WORK/err"; then
	bad "G2 an empty istio.apiGuard.kubernetesGroups rendered"
else
	grep -q 'kubernetesGroups must list at least one' "$WORK/err" && ok "G2 empty kubernetesGroups fails the render" || bad "G2 wrong error: $(cat "$WORK/err")"
fi

proxy_paths=$(yq -o=json -I=0 '[.spec.rules[] | select(.from == null and .when == null) | .to[0].operation.paths] | flatten | sort' "$WORK/guard.yaml")
proxy_route=$(yq -o=json -I=0 '.spec.http[0] | {"name": .name, "re": .match[0].uri.regex, "status": .directResponse.status}' "$WORK/vs.yaml")
[ "$proxy_paths" = '["/api/kubernetes//proxy","/api/kubernetes//proxy/*","/api/kubernetes/proxy","/api/kubernetes/proxy/*"]' ] &&
	[ "$proxy_route" = '{"name":"backstage-api-kubernetes-proxy-denied","re":"(?i)/api/kubernetes/+proxy(/.*)?","status":403}' ] &&
	ok "G3 the proxy is denied for everyone (guard) and answered 403 in any spelling (VirtualService)" || bad "G3 proxy: $proxy_paths $proxy_route"
render --set istio.apiGuard.denyKubernetesProxy=false >"$WORK/noproxy.yaml"
if grep -q 'kubernetes/proxy\|+proxy' "$WORK/noproxy.yaml"; then bad "G3 denyKubernetesProxy=false still renders a proxy rule"; else ok "G3 denyKubernetesProxy=false drops the proxy rule and route"; fi

auth_rule=$(yq -o=json -I=0 '[.spec.rules[] | select((.to[0].operation.paths // [] | join(",")) == "/api/auth,/api/auth/*") | .from[0].source]' "$WORK/guard.yaml")
refresh=$(yq -o=json -I=0 '[.spec.rules[] | select((.to[0].operation.paths // [] | join(",")) == "/api/auth/teknoir/refresh") | .from[0].source.requestPrincipals]' "$WORK/allow.yaml")
catalog=$(yq -o=json -I=0 '[.spec.rules[] | select((.to[0].operation.paths // [] | join(",")) == "/api/catalog/entities/*") | .from[0].source.namespaces]' "$WORK/allow.yaml")
[ "$auth_rule" = '[{"notRequestPrincipals":["*"]}]' ] && [ "$refresh" = '[["*"]]' ] && [ "$catalog" = '[["*"]]' ] &&
	ok "G4 /api/auth needs a token; in-mesh refresh needs a request principal; in-mesh catalog unchanged" || bad "G4 auth $auth_rule refresh $refresh catalog $catalog"

order=$(yq -r '[.spec.http[].name] | join(" ")' "$WORK/vs.yaml")
removes=$(yq -r '[.spec.http[] | select(.route[0].destination.host | test("^backstage-api")) | .headers.request.remove[0]] | join(" ")' "$WORK/vs.yaml")
[ "$order" = "backstage-api-kubernetes-proxy-denied backstage-api-guarded backstage-api-guarded-other-spellings backstage-api backstage" ] &&
	[ "$removes" = "verified-jwt verified-jwt" ] &&
	ok "G5 VirtualService order ($order), verified-jwt removed on both backstage-api routes" || bad "G5 order '$order' removes '$removes'"

mesh=$(yq -o=json -I=0 '[.spec.rules[] | select(.from[0].source.notPrincipals != null) | {"src": .from[0].source, "not": .to[0].operation.notPaths}]' "$WORK/guard.yaml")
[ "$mesh" = '[{"src":{"notPrincipals":["cluster.local/ns/istio-system/sa/istio-ingressgateway"]},"not":["/api/catalog/entities","/api/catalog/entities/*","/api/auth/*"]}]' ] &&
	ok "G7 in the mesh only the catalog entity paths and /api/auth/*, with or without a token" || bad "G7 in-mesh rule: $mesh"

if command -v istioctl >/dev/null; then
	yq 'select(.apiVersion | test("istio.io"))' "$WORK/chart.yaml" >"$WORK/istio.yaml"
	istioctl validate -f "$WORK/istio.yaml" >"$WORK/iv.log" 2>&1 && ! grep -qi 'warn\|\*' "$WORK/iv.log" &&
		ok "G6 istioctl validate: $(tail -1 "$WORK/iv.log")" || bad "G6 istioctl validate: $(cat "$WORK/iv.log")"
else
	echo "SKIP G6 istioctl not installed"
fi

if [ "$STATIC" -eq 1 ]; then
	echo "== $pass passed, $fail failed (static only)"
	[ "$fail" -eq 0 ]
	exit
fi

echo "== keys and tokens"
cat >"$WORK/jwt.py" <<'PY'
import base64, json, subprocess, sys, time
def b64u(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
cmd, key = sys.argv[1], sys.argv[2]
if cmd == "jwks":
    mod = subprocess.run(["openssl", "rsa", "-in", key, "-noout", "-modulus"], check=True, capture_output=True, text=True).stdout.strip().split("=", 1)[1]
    print(json.dumps({"keys": [{"kty": "RSA", "alg": "RS256", "use": "sig", "kid": "guard-test", "n": b64u(bytes.fromhex(mod)), "e": "AQAB"}]}))
elif cmd == "sign":
    claims = json.loads(sys.argv[3])
    claims.setdefault("exp", int(time.time()) + 3600)
    claims.setdefault("iat", int(time.time()) - 10)
    head = b64u(json.dumps({"alg": "RS256", "typ": "JWT", "kid": "guard-test"}).encode())
    body = b64u(json.dumps(claims).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=f"{head}.{body}".encode(), check=True, capture_output=True).stdout
    print(f"{head}.{body}.{b64u(sig)}")
elif cmd == "payload":
    # A bare base64url payload, the form Envoy writes into verified-jwt.
    print(b64u(json.dumps(json.loads(sys.argv[3])).encode()))
PY
openssl genrsa -out "$WORK/key.pem" 2048 2>/dev/null
openssl genrsa -out "$WORK/other.pem" 2048 2>/dev/null
ISSUER=$(yq -r 'select(.kind == "RequestAuthentication" and .metadata.name == "backstage-api-request-auth") | .spec.jwtRules[0].issuer' "$WORK/chart.yaml")
JWKS=$(python3 -I "$WORK/jwt.py" jwks "$WORK/key.pem")
sign() { python3 -I "$WORK/jwt.py" sign "${2:-$WORK/key.pem}" "{\"iss\":\"$ISSUER\",\"sub\":\"$1\",\"email\":\"$1@example.com\",\"email_verified\":true${3:-}}"; }
T_ADMIN=$(sign admin "" ',"groups":["viewers","admin"]')
T_USER=$(sign user "" ',"groups":["viewer"]')
T_NOGROUPS=$(sign nogroups)
T_SIMILAR=$(sign similar "" ',"groups":["administrators","superadmin","Admin"]')
T_EXPIRED=$(sign expired "" ',"groups":["admin"],"exp":1000')
T_BADSIG=$(sign badsig "$WORK/other.pem" ',"groups":["admin"]')
FORGED=$(python3 -I "$WORK/jwt.py" payload x '{"sub":"root","email":"root@example.com","email_verified":true,"exp":4102444800}')
payload_of() { cut -d. -f2 <<<"$1"; }

echo "== cluster ($K3S_IMAGE, Istio $ISTIO_VERSION)"
export KUBECONFIG=$WORK/kubeconfig
k() { kubectl --context "$CTX" "$@"; }
for img in "docker.io/istio/pilot:$ISTIO_VERSION" "docker.io/istio/proxyv2:$ISTIO_VERSION" "$TOOLS_IMAGE"; do
	docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null
done
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait \
	--kubeconfig-update-default=false --kubeconfig-switch-context=false \
	--k3s-arg '--disable=traefik,metrics-server,servicelb@server:0' >/dev/null
CLUSTER_UP=1
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
k3d image import -c "$CLUSTER" "docker.io/istio/pilot:$ISTIO_VERSION" "docker.io/istio/proxyv2:$ISTIO_VERSION" "$TOOLS_IMAGE" >/dev/null 2>&1
cat >"$WORK/iop.yaml" <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: default
  hub: docker.io/istio
  tag: $ISTIO_VERSION
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service: {type: ClusterIP}
          resources: {requests: {cpu: 10m, memory: 64Mi}}
    pilot:
      k8s:
        resources: {requests: {cpu: 10m, memory: 128Mi}}
  values:
    global:
      imagePullPolicy: IfNotPresent
      proxy: {resources: {requests: {cpu: 10m, memory: 32Mi}}}
EOF
istioctl install -y --kubeconfig "$KUBECONFIG" --context "$CTX" -f "$WORK/iop.yaml" >"$WORK/istioctl.log" 2>&1 || {
	cat "$WORK/istioctl.log"
	exit 1
}
for n in "$NS" "$TS"; do
	k create namespace "$n" >/dev/null
	k label namespace "$n" istio-injection=enabled >/dev/null
done
k create namespace outside >/dev/null

# Stand-ins: echo every request (path, verified-jwt values) as JSON.
cat >"$WORK/echo.py" <<'PY'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
NAME = sys.argv[1]
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle_any(self):
        n = int(self.headers.get("content-length") or 0)
        if n:
            self.rfile.read(n)
        body = json.dumps({"who": NAME, "port": self.server.server_port, "path": self.path,
                           "verified_jwt": self.headers.get_all("verified-jwt") or []}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any
    def log_message(self, *a):
        pass
for port in map(int, sys.argv[2:]):
    s = ThreadingHTTPServer(("0.0.0.0", port), H)
    threading.Thread(target=s.serve_forever, daemon=True).start()
threading.Event().wait()
PY
k -n "$NS" create configmap echo --from-file=echo.py="$WORK/echo.py" >/dev/null
render -s templates/serviceaccount.yaml -s templates/service.yaml | k apply -f - >/dev/null
standin() { # <app> <serviceaccount> <ports...>
	local app=$1 sa=$2 ports
	shift 2
	# Quoted: a bare 7007 would be a YAML number, which command rejects.
	ports=$(printf ', "%s"' "$@")
	k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $app, namespace: $NS}
spec:
  selector: {matchLabels: {app: $app}}
  template:
    metadata: {labels: {app: $app}}
    spec:
      serviceAccountName: $sa
      containers:
        - name: echo
          image: $TOOLS_IMAGE
          imagePullPolicy: IfNotPresent
          command: [python3, -u, /echo/echo.py, "$app"$ports]
          volumeMounts: [{name: echo, mountPath: /echo}]
      volumes: [{name: echo, configMap: {name: echo}}]
EOF
}
standin backstage-api backstage-api 7007 9464
standin backstage default 80
client() { # <namespace> <name>
	k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $2, namespace: $1, labels: {app: $2}}
spec:
  containers:
    - name: client
      image: $TOOLS_IMAGE
      imagePullPolicy: IfNotPresent
      command: [sleep, infinity]
EOF
}
client outside edge
client "$TS" mesh-ts
client "$NS" mesh-sys
k apply -f - >/dev/null <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: teknoir-gateway, namespace: istio-system}
spec:
  selector: {istio: ingressgateway}
  servers:
    - port: {number: 80, name: http, protocol: HTTP}
      hosts: ["$HOST", "*.$HOST"]
---
# A copy of the harbor chart's harbor-allow-internal: no selector, so it
# admits every mTLS source in teknoir-system and teknoir-auth to every
# workload in the namespace, backstage-api included.
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: harbor-allow-internal, namespace: $NS}
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["$NS", teknoir-auth]
EOF
for d in backstage-api backstage; do k -n "$NS" rollout status "deploy/$d" --timeout=240s >/dev/null; done
k -n "$TS" wait --for=condition=Ready pod/mesh-ts --timeout=240s >/dev/null
k -n "$NS" wait --for=condition=Ready pod/mesh-sys --timeout=240s >/dev/null
k -n outside wait --for=condition=Ready pod/edge --timeout=240s >/dev/null

# The chart's Istio resources, the RequestAuthentication with the test JWKS.
policies() { # <chart render> -> applied
	JWKS=$JWKS yq '(select(.kind == "RequestAuthentication") | .spec.jwtRules[0].jwks) = strenv(JWKS) |
		del(select(.kind == "RequestAuthentication") | .spec.jwtRules[0].jwksUri)' "$1" >"$WORK/applied.yaml"
	k apply -f "$WORK/applied.yaml" >/dev/null
}
render --set "istio.ingressServiceAccount=$GW_SA" \
	-s templates/istio-authpolicy.yaml -s templates/istio-requestauth.yaml \
	-s templates/istio-virtualservice.yaml -s templates/istio-api-guard.yaml >"$WORK/new.yaml"
# The control: the policies before this change. The old ALLOW admitted the
# gateway to every path, and any namespace to catalog and refresh in one
# rule without a request principal; the old VirtualService was /api/ ->
# backstage-api, the rest -> backstage.
GWP="cluster.local/ns/istio-system/sa/$GW_SA" yq 'select(.metadata.name != "backstage-api-guard") |
	(select(.metadata.name == "backstage-api-auth-policy") | .spec.rules) = [
		{"from": [{"source": {"principals": [strenv(GWP)]}}]},
		{"from": [{"source": {"namespaces": ["*"]}}],
		 "to": [{"operation": {"methods": ["GET", "POST"], "paths": ["/api/catalog/entities/*", "/api/auth/teknoir/refresh"]}}],
		 "when": [{"key": "request.auth.principal", "notValues": [strenv(GWP)]}]}] |
	(select(.kind == "VirtualService") | .spec.http) |= [.[] | select(.name == "backstage-api" or .name == "backstage") | del(.headers)]' \
	"$WORK/new.yaml" >"$WORK/old.yaml"

# req <client> <url> [curl args]: "<status> <body>"; the client's namespace is
# derived from its name.
req() {
	local c=$1 url=$2 ns
	shift 2
	case $c in edge) ns=outside ;; mesh-ts) ns=$TS ;; mesh-sys) ns=$NS ;; esac
	k -n "$ns" exec "$c" -c client -- sh -c 'curl -sS --path-as-is -m 10 -o /tmp/b -w "%{http_code} " "$@"; cat /tmp/b; rm -f /tmp/b' _ "$url" "$@" 2>/dev/null || echo "000 curl-failed"
}
GW=http://istio-ingressgateway.istio-system.svc.cluster.local
API=http://backstage-api.$NS.svc.cluster.local
gw() { local p=$1; shift; req edge "$GW$p" -H "Host: $HOST" "$@"; }
tok() { echo "X-Auth-Request-Access-Token: $1"; }
# expect <id> <description> <want status> <want who|-> <response>
expect() {
	local id=$1 d=$2 st=$3 who=$4 r=$5 got_st got_who
	got_st=${r%% *}
	got_who=$(jq -r '.who // "-"' <<<"${r#* }" 2>/dev/null || echo -)
	[ "$got_st" = "$st" ] && { [ "$who" = - ] || [ "$got_who" = "$who" ]; } &&
		ok "$id $d: $st${who:+ $who}" || bad "$id $d: want $st $who, got $r"
}
# wait_for <want status> <request...>: until the policies have propagated.
wait_for() {
	local want=$1 r
	shift
	for _ in $(seq 1 60); do
		r=$("$@")
		[ "${r%% *}" = "$want" ] && return 0
		sleep 2
	done
	echo "timeout waiting for $want from: $* (last: $r)"
	return 1
}

echo "== C control: the policies before this change"
policies "$WORK/old.yaml"
wait_for 200 gw /api/kubernetes/clusters -H "$(tok "$T_USER")"
expect C1 "gateway, user without group admin: /api/kubernetes/clusters" 200 backstage-api "$(gw /api/kubernetes/clusters -H "$(tok "$T_USER")")"
expect C2 "gateway, user: /api/kubernetes/proxy/api/v1/secrets" 200 backstage-api "$(gw /api/kubernetes/proxy/api/v1/secrets -H "$(tok "$T_USER")")"
expect C3 "gateway, user: /api/KUBERNETES/clusters" 200 backstage-api "$(gw /api/KUBERNETES/clusters -H "$(tok "$T_USER")")"
r=$(req mesh-ts "$API/api/auth/teknoir/refresh" -X POST -H "verified-jwt: $FORGED")
expect C4 "teamspace pod, no token, forged verified-jwt: POST refresh" 200 backstage-api "$r"
# Not a pass/fail check: what this Istio's Envoy does with a client-supplied
# verified-jwt when the request has no token.
echo "INFO C4 verified-jwt that reached backstage-api without a token (Istio $ISTIO_VERSION): $(jq -c '.verified_jwt' <<<"${r#* }")"
expect C5 "teknoir-system pod, no token: /api/AUTH/teknoir/refresh" 200 backstage-api "$(req mesh-sys "$API/api/AUTH/teknoir/refresh" -H "verified-jwt: $FORGED")"

echo "== the chart's policies"
policies "$WORK/new.yaml"
wait_for 403 gw /api/kubernetes/clusters -H "$(tok "$T_USER")"
# Connections opened under the control policies keep their old filter chain
# until Envoy drains them, and the clients' sidecars pool them: a first run
# saw one tokenless /api/AUTH request from teknoir-system still pass. A new
# backstage-api pod has only connections under the chart's policies.
k -n "$NS" rollout restart deploy/backstage-api >/dev/null
k -n "$NS" rollout status deploy/backstage-api --timeout=240s >/dev/null
wait_for 403 gw /api/kubernetes/clusters -H "$(tok "$T_USER")"
wait_for 403 req mesh-ts "$API/api/auth/teknoir/refresh" -X POST -H "verified-jwt: $FORGED"

echo "== E gateway"
expect E1 "group admin: /api/kubernetes/clusters" 200 backstage-api "$(gw /api/kubernetes/clusters -H "$(tok "$T_ADMIN")")"
expect E1 "group admin: POST /api/kubernetes/resources/custom/query" 200 backstage-api "$(gw /api/kubernetes/resources/custom/query -X POST -H "$(tok "$T_ADMIN")")"
expect E2 "group viewer: /api/kubernetes/clusters" 403 - "$(gw /api/kubernetes/clusters -H "$(tok "$T_USER")")"
expect E2 "group viewer: POST /api/kubernetes/services/x" 403 - "$(gw /api/kubernetes/services/x -X POST -H "$(tok "$T_USER")")"
expect E2 "no groups claim: /api/kubernetes/clusters" 403 - "$(gw /api/kubernetes/clusters -H "$(tok "$T_NOGROUPS")")"
expect E2 "groups administrators, superadmin, Admin: /api/kubernetes/clusters" 403 - "$(gw /api/kubernetes/clusters -H "$(tok "$T_SIMILAR")")"
expect E2 "no token: /api/kubernetes/clusters" 403 - "$(gw /api/kubernetes/clusters)"
expect E2 "group viewer: /api/kubernetes//clusters" 403 - "$(gw /api/kubernetes//clusters -H "$(tok "$T_USER")")"
expect E3 "expired token" 401 - "$(gw /api/kubernetes/clusters -H "$(tok "$T_EXPIRED")")"
expect E3 "token signed by another key" 401 - "$(gw /api/kubernetes/clusters -H "$(tok "$T_BADSIG")")"
for p in /api/kubernetes/proxy/api/v1/secrets /api/kubernetes/proxy /api/kubernetes//proxy/api/v1/secrets \
	/api/kubernetes/PROXY/api/v1/secrets /api/Kubernetes/Proxy/x /api/KUBERNETES//proxy/x \
	/api/kubernetes/./proxy/x /api/kubernetes/clusters/../proxy/x /api/kubernetes/%70roxy/x /api/%6Bubernetes/proxy/x; do
	expect E4 "group admin: $p (the proxy)" 403 - "$(gw "$p" -H "$(tok "$T_ADMIN")")"
done
for p in /api/KUBERNETES/clusters /api/Kubernetes/clusters /API/kubernetes/clusters /api/kubernetes \
	/api/%4Bubernetes/clusters /api/AUTH/teknoir/refresh /api/Auth/teknoir/refresh /api/auth; do
	expect E5 "group admin: $p (another spelling)" 404 - "$(gw "$p" -H "$(tok "$T_ADMIN")")"
done
expect E6 "no token, forged verified-jwt: POST /api/auth/teknoir/refresh" 403 - "$(gw /api/auth/teknoir/refresh -X POST -H "verified-jwt: $FORGED")"
expect E6 "no token: /api/auth//teknoir/refresh" 403 - "$(gw /api/auth//teknoir/refresh -H "verified-jwt: $FORGED")"
expect E6 "no token: /api/auth/TEKNOIR/refresh" 403 - "$(gw /api/auth/TEKNOIR/refresh -H "verified-jwt: $FORGED")"
r=$(gw /api/auth/teknoir/refresh -X POST -H "$(tok "$T_USER")" -H "verified-jwt: $FORGED")
expect E7 "user token and a forged verified-jwt: POST refresh" 200 backstage-api "$r"
[ "$(jq -c '.verified_jwt' <<<"${r#* }")" = "[\"$(payload_of "$T_USER")\"]" ] &&
	ok "E7 backstage-api got exactly the verified payload of the user's token" || bad "E7 verified-jwt: $r"
r=$(gw '/api/catalog/entities?filter=kind=user' -H "verified-jwt: $FORGED")
expect E8 "no token: /api/catalog/entities (unchanged, Backstage's own auth)" 200 backstage-api "$r"
[ "$(jq -c '.verified_jwt' <<<"${r#* }")" = "[]" ] && ok "E8 the gateway removed the forged verified-jwt" || bad "E8 verified-jwt: $r"
expect E8 "user: /api/teknoir-entity/x" 200 backstage-api "$(gw /api/teknoir-entity/x -H "$(tok "$T_USER")")"
expect E9 "/ goes to the frontend" 200 backstage "$(gw /catalog -H "$(tok "$T_USER")")"

echo "== M teamspace pod (mesh)"
expect M1 "no token: /api/catalog/entities/by-name/user/default/x" 200 backstage-api "$(req mesh-ts "$API/api/catalog/entities/by-name/user/default/x")"
expect M2 "no token, forged verified-jwt: POST refresh" 403 - "$(req mesh-ts "$API/api/auth/teknoir/refresh" -X POST -H "verified-jwt: $FORGED")"
expect M2 "no token: /api/AUTH/teknoir/refresh" 403 - "$(req mesh-ts "$API/api/AUTH/teknoir/refresh" -H "verified-jwt: $FORGED")"
r=$(req mesh-ts "$API/api/auth/teknoir/refresh" -X POST -H "X-Forwarded-Access-Token: $T_USER" -H "verified-jwt: $FORGED")
expect M3 "user token and a forged verified-jwt: POST refresh" 200 backstage-api "$r"
[ "$(jq -c '.verified_jwt' <<<"${r#* }")" = "[\"$(payload_of "$T_USER")\"]" ] &&
	ok "M3 Envoy replaced the forged verified-jwt with the verified payload" || bad "M3 verified-jwt: $r"
expect M4 "group admin token: /api/kubernetes/clusters (not an in-mesh path)" 403 - "$(req mesh-ts "$API/api/kubernetes/clusters" -H "X-Forwarded-Access-Token: $T_ADMIN")"
expect M4 "no token: /api/teknoir-entity/x" 403 - "$(req mesh-ts "$API/api/teknoir-entity/x")"

echo "== S teknoir-system pod (mesh, admitted by harbor-allow-internal)"
expect S1 "no token: /api/catalog/entities" 200 backstage-api "$(req mesh-sys "$API/api/catalog/entities")"
for p in /api/auth/teknoir/refresh /api/AUTH/teknoir/refresh /api/auth/TEKNOIR/refresh /api/kubernetes/clusters \
	/api/KUBERNETES/proxy/api/v1/secrets /api/kubernetes//proxy/x /api/teknoir-entity/x; do
	expect S2 "no token: $p" 403 - "$(req mesh-sys "$API$p" -H "verified-jwt: $FORGED")"
done
for p in /api/kubernetes/clusters /api/KUBERNETES/clusters /api/kubernetes/proxy/x /api/AUTH/teknoir/refresh /api/teknoir-entity/x; do
	expect S3 "group admin token: $p" 403 - "$(req mesh-sys "$API$p" -H "X-Forwarded-Access-Token: $T_ADMIN")"
done
r=$(req mesh-sys "$API/api/auth/teknoir/refresh" -X POST -H "X-Forwarded-Access-Token: $T_USER" -H "verified-jwt: $FORGED")
expect S3 "user token and a forged verified-jwt: POST refresh" 200 backstage-api "$r"
[ "$(jq -c '.verified_jwt' <<<"${r#* }")" = "[\"$(payload_of "$T_USER")\"]" ] &&
	ok "S3 Envoy replaced the forged verified-jwt with the verified payload" || bad "S3 verified-jwt: $r"
expect S4 "no token: metrics port 9464 (not guarded)" 200 backstage-api "$(req mesh-sys "http://backstage-api.$NS.svc.cluster.local:9464/metrics")"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
