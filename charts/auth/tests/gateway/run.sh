#!/usr/bin/env bash
# Offline Envoy harness for the gateway denial contract (charts/auth/README.md, "Denied requests").
#
# Renders templates/istio-auth.yaml, takes the real HTTP_FILTER patches out of it, and runs them in
# istio/proxyv2 (Envoy) with a static bootstrap: Lua -> ext_authz -> marker Lua -> router. ext_authz talks
# to a python stub that mimics oauth2-proxy, the router to a python backend stub. A curl matrix over
# HTTP/1.1 and HTTP/2 then checks every row of the contract. No cluster, no network beyond localhost.
#
#   charts/auth/tests/gateway/run.sh                 # run the full matrix, exit 1 on any failure
#   RENDERED=/path/envoyfilter.yaml run.sh           # use an already rendered EnvoyFilter (e.g. the old template)
#   ENVOY_IMAGE=istio/proxyv2:1.29.2 KEEP=1 run.sh   # KEEP=1 keeps the temp dir and Envoy logs
#
# Needs: docker (image istio/proxyv2:1.29.2 cached), helm, curl >= 7.68 with HTTP/2, python3 with PyYAML, openssl.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
chart=$(cd "$here/../.." && pwd)
image=${ENVOY_IMAGE:-istio/proxyv2:1.29.2}
base=${PORT_BASE:-28440}
ports=$(printf '{"gw":%d,"nomarker":%d,"admin":%d,"authz":%d,"backend":%d}' \
  $((base + 3)) $((base + 4)) $((base + 1)) $((base + 5)) $((base + 6)))

for t in docker helm curl python3 openssl; do
  command -v "$t" >/dev/null || { echo "run.sh: missing $t" >&2; exit 2; }
done

tmp=$(mktemp -d)
name=auth-gw-harness-$$
stub_pid=""
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  [ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

# 1. render. A scratch copy without the keycloakx dependency, so no `helm dependency build` (network) is needed.
if [ -n "${RENDERED:-}" ]; then
  cp "$RENDERED" "$tmp/rendered.yaml"
else
  mkdir -p "$tmp/chart/templates"
  cp "$chart/values.yaml" "$tmp/chart/values.yaml"
  cp "$chart/templates/istio-auth.yaml" "$tmp/chart/templates/"
  printf 'apiVersion: v2\nname: auth\nversion: 0.0.0\n' >"$tmp/chart/Chart.yaml"
  helm template auth "$tmp/chart" --namespace teknoir-auth --set domain=teknoir.test \
    -s templates/istio-auth.yaml >"$tmp/rendered.yaml"
fi

# 2. bootstrap, certificate
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=teknoir.test \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
python3 -I "$here/gen_bootstrap.py" "$tmp/rendered.yaml" /cfg/cert.pem /cfg/key.pem "$ports" >"$tmp/envoy.json"
chmod 644 "$tmp"/*.pem "$tmp/envoy.json"

# 3. stubs + Envoy (host network: the config addresses 127.0.0.1)
gw=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["gw"])' "$ports")
nm=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["nomarker"])' "$ports")
ad=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["admin"])' "$ports")
au=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["authz"])' "$ports")
be=$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["backend"])' "$ports")
python3 -I "$here/stubs.py" "$au" "$be" &
stub_pid=$!

docker run -d --rm --name "$name" --network host --user "$(id -u):$(id -g)" \
  -v "$tmp:/cfg:ro" --entrypoint /usr/local/bin/envoy "$image" \
  -c /cfg/envoy.json --disable-hot-restart --log-level warning --component-log-level lua:info >/dev/null
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:$ad/ready" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! curl -fsS "http://127.0.0.1:$ad/ready" >/dev/null 2>&1; then
  echo "run.sh: Envoy did not become ready" >&2
  docker logs "$name" 2>&1 | grep -v "Deprecated field" | tail -30 >&2
  exit 2
fi
echo "Envoy: $(docker exec "$name" /usr/local/bin/envoy --version | sed -n "s/.*version: //p" | head -1)  image $image"

# 4. matrix
set +e
python3 -I "$here/matrix.py" "$gw" "$nm"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "--- envoy log (tail) ---" >&2
  docker logs "$name" 2>&1 | grep -v "Deprecated field" | tail -20 >&2
fi
exit "$rc"
