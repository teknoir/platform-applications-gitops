#!/usr/bin/env bash
# Istio policy matrix for the EMQX dashboard proxy (templates/dashboard.yaml): who reaches it.
# This is the owners-only evidence (plans/emqx-dashboard-access.md).
#
# Creates the dedicated throwaway k3d cluster "emqx-dash" (context k3d-emqx-dash), installs Istio
# 1.29.2 (minimal) with two injected gateways, then installs from THIS chart: the proxy Deployment
# (nginx + guard), Service, VirtualService, DestinationRule, the DENY policy and emqx-authz/emqx-api,
# in front of a real EMQX 5.8.9. Two user policies stand in for what user-controller compiles from
# the gitops claim presets (owner: core /* with notPorts 18083 + the port-18083 rule; developer: core
# /* with notPorts 18083 + an observatory path rule with notPorts), both bound to the gateway
# principal and the X-Auth-Request-Email header like the mesh-authz design. The k3d gateway has no
# ext_authz, so the test sets X-Auth-Request-Email itself, as oauth2-proxy would. The cluster is
# deleted at the end (KEEP_CLUSTER=1 keeps it).
#
# Never touches any other cluster: every kubectl/istioctl call passes --context k3d-emqx-dash, and
# k3d is told not to switch the current context.
#
#   tests/k3d-dashboard-authz.sh           run the matrix (exit 0 only when every row matches)
#   tests/k3d-dashboard-authz.sh --check   dry run: render the chart, validate the manifests, check tools
#
# Pattern: profile-controller test/mesh-authz/k3d-matrix.sh.
set -uo pipefail

CLUSTER=emqx-dash
CTX=k3d-emqx-dash
ISTIO_VERSION=1.29.2
NS=ts
OTHER_NS=other-ns
DOMAIN=teknoir.cloud
HOST="emqx-dashboard-$NS.$DOMAIN"
OWNER=owner@example.com
DEV=dev@example.com
EMQX_IMAGE="${EMQX_IMAGE:-emqx/emqx:5.8.9}"
CURL_IMAGE=curlimages/curl:8.10.1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
FAILED=0
TOTAL=0
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

k() { kubectl --context "$CTX" "$@"; }
log() { printf '== %s\n' "$*"; }

cleanup() {
  rm -rf "$WORK"
  [ "$CHECK" = 1 ] && return
  if [ "${KEEP_CLUSTER:-0}" = 1 ]; then
    log "KEEP_CLUSTER=1: leaving cluster $CLUSTER (delete: k3d cluster delete $CLUSTER)"
  else
    log "deleting cluster $CLUSTER"
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
for t in k3d kubectl istioctl docker helm python3 curl; do need "$t"; done
ver="$(istioctl version --remote=false 2>/dev/null | head -1)"
case "$ver" in
  *"$ISTIO_VERSION"*) ;;
  *) echo "istioctl $ISTIO_VERSION required, got: $ver" >&2; exit 2 ;;
esac

# --- manifests from the chart ------------------------------------------------------------------
if ! ls "$CHART"/charts/emqx-*.tgz >/dev/null 2>&1; then
  helm dependency build "$CHART" >/dev/null || { echo "helm dependency build failed" >&2; exit 2; }
fi
helm template emqx "$CHART" -n "$NS" --set "domain=$DOMAIN" > "$WORK/chart.yaml" || { echo "helm template failed" >&2; exit 2; }
python3 -I - "$WORK/chart.yaml" "$WORK/chart-selected.yaml" <<'PY' || exit 2
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
keep = []
for d in docs:
    kind, name = d["kind"], d["metadata"]["name"]
    # the dashboard proxy, its routing and the two EMQX policies (not the EMQX subchart: it is stubbed below)
    if name == "emqx-dashboard" or (kind == "AuthorizationPolicy" and name in ("emqx-authz", "emqx-api", "emqx-dashboard-gateway-only")):
        keep.append(d)
names = sorted(f'{d["kind"]}/{d["metadata"]["name"]}' for d in keep)
need = {"ServiceAccount/emqx-dashboard", "ConfigMap/emqx-dashboard", "Service/emqx-dashboard", "Deployment/emqx-dashboard",
       "VirtualService/emqx-dashboard", "DestinationRule/emqx-dashboard", "AuthorizationPolicy/emqx-dashboard-gateway-only",
       "AuthorizationPolicy/emqx-authz", "AuthorizationPolicy/emqx-api"}
missing = need - set(names)
if missing:
    sys.exit("chart does not render: " + ", ".join(sorted(missing)))
yaml.safe_dump_all(keep, open(sys.argv[2], "w"))
print("rendered:", ", ".join(names))
PY

# user policies as user-controller compiles them from the claim presets (see header)
GWP=cluster.local/ns/istio-system/sa/istio-ingressgateway
userpolicy() { # name email rules-yaml
  cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: $1, namespace: $NS}
spec:
  rules:
$3
EOF
}
rule() { # email, operation-yaml (one line, flow style)
  cat <<EOF
  - from: [{source: {principals: [$GWP]}}]
    to: [{operation: $2}]
    when: [{key: "request.headers[X-Auth-Request-Email]", values: ["$1"]}]
EOF
}
{
  userpolicy user-owner-teknoir-authorization-policy "$OWNER" "$(rule "$OWNER" '{paths: ["/*"], notPorts: ["18083"]}'; rule "$OWNER" '{ports: ["18083"]}')"
  echo ---
  userpolicy user-dev-teknoir-authorization-policy "$DEV" "$(rule "$DEV" '{paths: ["/*"], notPorts: ["18083"]}'; rule "$DEV" '{methods: [GET], paths: ["/events*", "/'"$NS"'/observatory*"], notPorts: ["18083"]}')"
  echo ---
  # mesh-authz rule 2: anonymous in-namespace HTTP is allowed (the DENY must still win on the proxy)
  cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: ns-allow-in-namespace, namespace: $NS}
spec:
  rules:
  - from: [{source: {namespaces: [$NS]}}]
EOF
} > "$WORK/policies.yaml"

if [ "$CHECK" = 1 ]; then
  if command -v kubeconform >/dev/null 2>&1; then
    kubeconform -strict -ignore-missing-schemas -summary "$WORK/chart-selected.yaml" "$WORK/policies.yaml" || exit 1
  fi
  log "check: manifests render; would run $EMQX_IMAGE and the proxy image on cluster $CLUSTER"
  exit 0
fi

# --- cluster -----------------------------------------------------------------------------------
if k3d cluster list "$CLUSTER" >/dev/null 2>&1; then
  log "cluster $CLUSTER exists from an earlier run, recreating it"
  k3d cluster delete "$CLUSTER" >/dev/null 2>&1
fi
log "creating k3d cluster $CLUSTER"
k3d cluster create "$CLUSTER" --servers 1 --agents 0 --wait \
  --k3s-arg '--disable=traefik@server:*' \
  --kubeconfig-update-default=true --kubeconfig-switch-context=false \
  >/dev/null || { echo "k3d cluster create failed" >&2; exit 2; }
k get nodes >/dev/null || { echo "context $CTX not usable" >&2; exit 2; }

PROXY_IMAGE="$(python3 -I - "$WORK/chart-selected.yaml" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d["kind"] == "Deployment":
        print(d["spec"]["template"]["spec"]["containers"][0]["image"])
PY
)"
log "importing images"
for img in "$EMQX_IMAGE" "${PROXY_IMAGE%@*}" "$CURL_IMAGE" istio/pilot:$ISTIO_VERSION istio/proxyv2:$ISTIO_VERSION; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null || true
done
k3d image import -c "$CLUSTER" "$EMQX_IMAGE" "${PROXY_IMAGE%@*}" "$CURL_IMAGE" istio/pilot:$ISTIO_VERSION istio/proxyv2:$ISTIO_VERSION >/dev/null 2>&1 || true

log "installing istio $ISTIO_VERSION (minimal)"
istioctl --context "$CTX" install -y --set profile=minimal >/dev/null || { echo "istioctl install failed" >&2; exit 2; }
k -n istio-system rollout status deploy/istiod --timeout=180s >/dev/null || exit 2

# --- gateways, namespaces, EMQX, clients ---------------------------------------------------------
gateway() { # name label gateway-name
  cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: $1, namespace: istio-system}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: istio-system}
spec:
  selector: {matchLabels: {istio: $2}}
  template:
    metadata:
      labels: {istio: $2, sidecar.istio.io/inject: "true"}
      annotations: {inject.istio.io/templates: gateway}
    spec:
      serviceAccountName: $1
      containers:
      - {name: istio-proxy, image: auto}
---
apiVersion: v1
kind: Service
metadata: {name: $1, namespace: istio-system}
spec:
  selector: {istio: $2}
  ports: [{name: http, port: 80, targetPort: 80}]
---
apiVersion: networking.istio.io/v1
kind: Gateway
metadata: {name: $3, namespace: istio-system}
spec:
  selector: {istio: $2}
  servers: [{port: {number: 80, name: http, protocol: HTTP}, hosts: ["*"]}]
EOF
}
{
  gateway istio-ingressgateway ingressgateway teknoir-gateway
  echo ---
  gateway istio-ingressgateway-public ingressgateway-public teknoir-gateway-public
} > "$WORK/gateways.yaml"

API_KEY="e2e$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
API_SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"

cat > "$WORK/workloads.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $NS, labels: {istio-injection: enabled}}
---
apiVersion: v1
kind: Namespace
metadata: {name: $OTHER_NS, labels: {istio-injection: enabled}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: emqx, namespace: $NS}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: emqx, app.kubernetes.io/instance: emqx}}
  template:
    metadata: {labels: {app.kubernetes.io/name: emqx, app.kubernetes.io/instance: emqx}}
    spec:
      containers:
      - name: emqx
        image: $EMQX_IMAGE
        imagePullPolicy: IfNotPresent
        env:
        - {name: EMQX_API_KEY__BOOTSTRAP_FILE, value: /opt/emqx-bootstrap/api-keys.txt}
        - {name: EMQX_DASHBOARD__DEFAULT_USERNAME, value: teknoir}
        - {name: EMQX_DASHBOARD__DEFAULT_PASSWORD, value: teknoir}   # the legacy chart default: the guard must remove it
        ports: [{containerPort: 18083}]
        volumeMounts: [{name: keys, mountPath: /opt/emqx-bootstrap, readOnly: true}]
      volumes: [{name: keys, secret: {secretName: emqx-bootstrap-api-keys}}]
---
apiVersion: v1
kind: Service
metadata: {name: emqx, namespace: $NS}
spec:
  selector: {app.kubernetes.io/name: emqx, app.kubernetes.io/instance: emqx}
  ports: [{name: http-dashboard, port: 18083, targetPort: 18083}]
---
# test only: expose the same host on the public gateway, to prove the DENY (gateway principal) holds
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata: {name: emqx-dashboard-public-probe, namespace: $NS}
spec:
  hosts: ["$HOST"]
  gateways: [istio-system/teknoir-gateway-public]
  http:
  - route: [{destination: {host: emqx-dashboard.$NS.svc.cluster.local, port: {number: 18083}}}]
EOF

client() { # name namespace inject(true|false)
  cat <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $2
  labels: {app: $1}
  annotations: {sidecar.istio.io/inject: "$3"}
spec:
  containers:
  - {name: curl, image: $CURL_IMAGE, imagePullPolicy: IfNotPresent, command: ["sleep", "100000"]}
EOF
}
{
  client sidecar-client "$NS" true
  client plain-client "$NS" false
  client other-sidecar "$OTHER_NS" true
  client other-plain "$OTHER_NS" false
} > "$WORK/clients.yaml"

log "deploying"
k apply -f "$WORK/gateways.yaml" >/dev/null || exit 2
# namespaces first, then the secret the chart's Deployment and EMQX read (random test key, never printed)
k apply -f <(python3 -I -c "
import sys, yaml
docs=[d for d in yaml.safe_load_all(open('$WORK/workloads.yaml')) if d and d['kind']=='Namespace']
yaml.safe_dump_all(docs, sys.stdout)") >/dev/null || exit 2
k -n "$NS" create secret generic emqx-bootstrap-api-keys \
  --from-literal=apiKey="$API_KEY" --from-literal=apiSecret="$API_SECRET" \
  --from-literal=api-keys.txt="$API_KEY:$API_SECRET" >/dev/null || exit 2
k apply -f "$WORK/workloads.yaml" >/dev/null || exit 2
k apply -f "$WORK/clients.yaml" >/dev/null || exit 2
k apply -f "$WORK/chart-selected.yaml" >/dev/null || exit 2
k -n istio-system rollout status deploy/istio-ingressgateway --timeout=180s >/dev/null || exit 2
k -n istio-system rollout status deploy/istio-ingressgateway-public --timeout=180s >/dev/null || exit 2
k -n "$NS" rollout status deploy/emqx --timeout=240s >/dev/null || { echo "emqx not ready" >&2; exit 2; }
if ! k -n "$NS" rollout status deploy/emqx-dashboard --timeout=240s >/dev/null; then
  echo "emqx-dashboard not ready (2/2 containers: read-only root, entrypoint env script, mounts)" >&2
  k -n "$NS" get pods >&2; k -n "$NS" logs deploy/emqx-dashboard -c nginx --tail=20 >&2; exit 2
fi
for p in "$NS/sidecar-client" "$NS/plain-client" "$OTHER_NS/other-sidecar" "$OTHER_NS/other-plain"; do
  k -n "${p%/*}" wait --for=condition=Ready "pod/${p#*/}" --timeout=180s >/dev/null || { echo "pod $p not ready" >&2; exit 2; }
done

log "applying user policies"
k apply -f "$WORK/policies.yaml" >/dev/null || exit 2
sleep 10 # let istiod push the policies to the sidecars

# --- matrix --------------------------------------------------------------------------------------
http() { # namespace pod url [curl args...] -> prints the status code
  local ns="$1" pod="$2" url="$3"; shift 3
  k -n "$ns" exec "$pod" -c curl -- curl -s -o /dev/null -w '%{http_code}' --max-time 8 --path-as-is "$@" "$url" 2>/dev/null
}
body() { # namespace pod url [curl args...] -> prints the response body
  local ns="$1" pod="$2" url="$3"; shift 3
  k -n "$ns" exec "$pod" -c curl -- curl -s --max-time 8 --path-as-is "$@" "$url" 2>/dev/null
}
expect() { # description want got
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$3"
  else printf 'FAIL  %-78s want %s, got %s\n' "$1" "$2" "$3"; FAILED=$((FAILED + 1)); fi
}
expect_any() { # description "want1 want2" got
  TOTAL=$((TOTAL + 1))
  case " $2 " in *" $3 "*) printf 'PASS  %-78s %s\n' "$1" "$3" ;;
  *) printf 'FAIL  %-78s want one of [%s], got %s\n' "$1" "$2" "$3"; FAILED=$((FAILED + 1)) ;; esac
}
H() { printf '%s: %s' "$1" "$2"; }

GW="http://istio-ingressgateway.istio-system.svc.cluster.local"
GWPUB="http://istio-ingressgateway-public.istio-system.svc.cluster.local"
PX="http://emqx-dashboard.$NS.svc.cluster.local:18083"
HOSTH="$(H Host "$HOST")"
# What the dashboard SPA sends on every API call (placeholder session + browser fetch metadata).
# Rows that expect 403 from Istio send these too, so a 403 cannot come from the proxy's CSRF guard.
BEARER="$(H Authorization 'Bearer teknoir-istio')"
SAMEORIGIN="$(H Sec-Fetch-Site same-origin)"

log "matrix: through the user ingress gateway"
expect "gateway, owner: /"                                    200 "$(http $OTHER_NS other-plain "$GW/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "gateway, owner: /api/v5/nodes (proxy adds the API key through the mesh)" 200 "$(http $OTHER_NS other-plain "$GW/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "gateway, owner: /api/v5/nodes without the placeholder bearer (CSRF guard)" 403 "$(http $OTHER_NS other-plain "$GW/api/v5/nodes" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "gateway, owner: cross-site multipart POST import_users, no bearer (CSRF guard)" 403 "$(http $OTHER_NS other-plain "$GW/api/v5/authentication/password_based:built_in_database/import_users?type=plain" -X POST -F 'filename=@/etc/hostname' -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)" -H "$(H Origin https://evil.example)" -H "$(H Sec-Fetch-Site cross-site)")"
expect "gateway, owner: same-site POST even with the bearer (CSRF guard)" 403 "$(http $OTHER_NS other-plain "$GW/api/v5/clients/x/kickout" -X POST -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)" -H "$BEARER" -H "$(H Sec-Fetch-Site same-site)")"
expect "gateway, owner: /api/v5/login is answered by the proxy" 200 "$(http $OTHER_NS other-plain "$GW/api/v5/login" -X POST -d '{}' -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "gateway, owner: /api/v5/users is refused by the proxy" 403 "$(http $OTHER_NS other-plain "$GW/api/v5/users" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "gateway, owner: /events%2F..%2Fapi/v5/nodes (nginx raw-path guard)" 400 "$(http $OTHER_NS other-plain "$GW/events%2F..%2Fapi/v5/nodes" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
body $OTHER_NS other-plain "$GW/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)" | grep -q teknoir-sso.js && r=yes || r=no
expect "gateway, owner: the dashboard page carries teknoir-sso.js" yes "$r"
case "$(body $OTHER_NS other-plain "$GW/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")$(body $OTHER_NS other-plain "$GW/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")" in
  *"$API_SECRET"*|*"$API_KEY"*) r=leaked ;; *) r=clean ;; esac
expect "gateway, owner: no response contains the API key or secret" clean "$r"
expect "gateway, developer: /"                                403 "$(http $OTHER_NS other-plain "$GW/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect "gateway, developer: /api/v5/nodes"                    403 "$(http $OTHER_NS other-plain "$GW/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect "gateway, developer: /teknoir-sso.js"                  403 "$(http $OTHER_NS other-plain "$GW/teknoir-sso.js" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect_any "gateway, developer: /events%2F..%2Fapi/v5/nodes (path confusion; never 200)" "403 400" "$(http $OTHER_NS other-plain "$GW/events%2F..%2Fapi/v5/nodes" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect_any "gateway, developer: /events/..%2Fapi/v5/nodes (never 200)" "403 400" "$(http $OTHER_NS other-plain "$GW/events/..%2Fapi/v5/nodes" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect_any "gateway, developer: /$NS/observatory/../../api/v5/nodes (never 200)" "403 400 404" "$(http $OTHER_NS other-plain "$GW/$NS/observatory/../../api/v5/nodes" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"
expect "gateway, no header: /"                                403 "$(http $OTHER_NS other-plain "$GW/" -H "$HOSTH")"
expect "gateway, unknown user header: /"                      403 "$(http $OTHER_NS other-plain "$GW/" -H "$HOSTH" -H "$(H X-Auth-Request-Email stranger@example.com)")"
expect "public gateway, owner header: / (the -public principal is not admitted)" 403 "$(http $OTHER_NS other-plain "$GWPUB/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "public gateway, developer header: /"                  403 "$(http $OTHER_NS other-plain "$GWPUB/" -H "$HOSTH" -H "$(H X-Auth-Request-Email $DEV)")"

log "matrix: inside the mesh (the DENY on the proxy pod beats every ALLOW)"
expect "sidecar same ns, no header -> proxy"                  403 "$(http $NS sidecar-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN")"
expect "sidecar same ns, forged owner header -> proxy"        403 "$(http $NS sidecar-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "sidecar same ns, forged owner header -> proxy /"      403 "$(http $NS sidecar-client "$PX/" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "plaintext same ns, forged owner header -> proxy"      403 "$(http $NS plain-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "plaintext same ns, no header -> proxy"                403 "$(http $NS plain-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN")"
expect "sidecar other ns, forged owner header -> proxy"       403 "$(http $OTHER_NS other-sidecar "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$(H X-Auth-Request-Email $OWNER)")"
expect "plaintext other ns, forged owner header -> proxy"     403 "$(http $OTHER_NS other-plain "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$(H X-Auth-Request-Email $OWNER)")"

log "matrix: the guard and the proxy reach EMQX through the mesh"
EMQX="http://emqx.$NS.svc.cluster.local:18083"
login() { http $NS sidecar-client "$EMQX/api/v5/login" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"teknoir\",\"password\":\"$1\"}"; }
for i in $(seq 1 40); do [ "$(login teknoir)" = 401 ] && break; sleep 3; done
expect "EMQX rejects the legacy default teknoir/teknoir after the guard" 401 "$(login teknoir)"
expect "EMQX rejects the built-in default teknoir/public"     401 "$(login public)"
expect "the guard logged one rotation and no failure" "1 0" "$(k -n $NS logs deploy/emqx-dashboard -c default-login-guard | grep -c 'rotated a known default') $(k -n $NS logs deploy/emqx-dashboard -c default-login-guard | grep -c 'could not rotate')"
expect "owner still gets the dashboard API after the rotation" 200 "$(http $OTHER_NS other-plain "$GW/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN" -H "$HOSTH" -H "$(H X-Auth-Request-Email $OWNER)")"

log "control: without the DENY the in-namespace ALLOW admits a sidecar pod (the matrix above would notice)"
k -n "$NS" delete authorizationpolicy emqx-dashboard-gateway-only >/dev/null || exit 2
for i in $(seq 1 20); do [ "$(http $NS sidecar-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN")" = 200 ] && break; sleep 3; done   # istiod push delay
expect "control (DENY removed): sidecar same ns -> proxy"     200 "$(http $NS sidecar-client "$PX/api/v5/nodes" -H "$BEARER" -H "$SAMEORIGIN")"

echo
if [ "$FAILED" -eq 0 ]; then
  log "all $TOTAL rows match"
else
  log "$FAILED of $TOTAL rows differ"
  k -n "$NS" get authorizationpolicies 2>/dev/null
  k -n "$NS" logs deploy/emqx-dashboard -c nginx --tail=20 2>/dev/null
fi
exit $((FAILED > 0))
