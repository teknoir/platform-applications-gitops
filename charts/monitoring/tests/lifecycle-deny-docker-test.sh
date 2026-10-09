#!/usr/bin/env bash
# SC2016: the single-quoted strings are jq programs.
# SC2119: render takes optional helm arguments.
# shellcheck disable=SC2016,SC2119
# charts/monitoring/tests/lifecycle-deny-docker-test.sh — prove in docker that
# the rendered prometheus- and alertmanager-deny-lifecycle policies keep the
# lifecycle endpoints closed, however the path is spelled. No Kubernetes, no
# istiod. Not packaged (.helmignore tests/).
#
# The model of one workload's inbound sidecar: Envoy from the istio chart's
# proxyv2 version, with the HTTP connection manager settings of the mesh's
# path normalization (the istio chart sets none, so BASE: normalize_path on,
# merge_slashes off, escaped slashes kept) and an RBAC filter that DENYs what
# the rendered policy lists. Paths become url_path matchers as istiod
# translates them ("*x" a suffix, "x*" a prefix, otherwise exact; the query is
# not part of the path). Behind each Envoy runs the chart's Prometheus or
# Alertmanager image with the rendered routePrefix, Prometheus with
# --web.enable-lifecycle as the operator runs it.
#
# Checks (FAIL makes the script exit 1):
#   L1  the model: the istio chart sets no pathNormalization (BASE), and each
#       deny-lifecycle policy is one DENY rule of paths only, for every source
#   L2  through each sidecar model the API and the probes stay reachable:
#       Prometheus GET buildinfo, POST /api/v1/query, GET /-/ready; Alertmanager
#       GET /api/v2/status, GET /-/ready
#   L3  every lifecycle request gets 403 from the DENY: POST to quit and
#       reload with each of the two slashes around "-" plain, %2F or %2f, PUT
#       to the plain and encoded forms, and %2D, %71/%72, a dot segment, a
#       ../ segment and a query string. A doubled or trailing slash may pass
#       the DENY, but never gets a 2xx: Go answers with a redirect to the
#       clean path, which sends the client back through the sidecar, or with
#       404 where the endpoint does not exist (Alertmanager has no quit)
#   L4  Prometheus is still running after every quit probe
#   L5  self-test: with the paths of the first 0.0.5 draft ("*/-/quit",
#       "*/-/reload"), POST <prefix>/-%2Fquit reaches Prometheus and stops it.
#       That is the bypass the encoded suffixes close, so L3 and L4 are not
#       vacuous
#
# Usage: charts/monitoring/tests/lifecycle-deny-docker-test.sh
# Environment: PROXY_IMAGE (default docker.io/istio/proxyv2:<the istio chart's
# istiod version>), plus lib.sh's KUBE_VERSION, RENDER_CACHE and HELM.
# Requires docker, helm, yq, jq and curl. Run it under the heavy-job lock.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${HERE}/lib.sh"
ISTIO_CHART="$(cd "${MONITORING_CHART}/../istio" && pwd)"
NET=tkmon-lc-test
PROM_CT=tkmon-lc-prometheus
AM_CT=tkmon-lc-alertmanager
ENVOY_CT=tkmon-lc-envoy
OLD_CT=tkmon-lc-envoy-old

for tool in docker "${HELM}" yq jq curl; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

remove_containers() {
  docker rm -f "${ENVOY_CT}" "${OLD_CT}" "${PROM_CT}" "${AM_CT}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
remove_containers
tmp="$(mktemp -d)"
cleanup() { remove_containers; rm -rf "${tmp}"; }
trap cleanup EXIT

fails=0
pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- the render: images, route prefixes, the DENY paths -------------------------
monitoring_render_setup "${tmp}"
render > "${tmp}/render.yaml"
yq -o=json -I=0 'select(. != null)' "${tmp}/render.yaml" | jq -s . > "${tmp}/render.json"
spec() { # spec KIND FIELD
  jq -r --arg k "$1" --arg f "$2" '[.[] | select(.kind == $k)][0].spec[$f] // empty' "${tmp}/render.json"
}
PROM_IMAGE="$(spec Prometheus image)"
PROM_PREFIX="$(spec Prometheus routePrefix)"
AM_IMAGE="$(spec Alertmanager image)"
AM_PREFIX="$(spec Alertmanager routePrefix)"
[[ -n "${PROM_IMAGE}" && -n "${PROM_PREFIX}" && -n "${AM_IMAGE}" && -n "${AM_PREFIX}" ]] \
  || { echo "render has no Prometheus/Alertmanager image or routePrefix" >&2; exit 1; }
ISTIO_VERSION="$(yq -r '.dependencies[] | select(.name == "istiod") | .version' "${ISTIO_CHART}/Chart.yaml")"
PROXY_IMAGE="${PROXY_IMAGE:-docker.io/istio/proxyv2:${ISTIO_VERSION}}"
echo "prometheus ${PROM_IMAGE} ${PROM_PREFIX}  alertmanager ${AM_IMAGE} ${AM_PREFIX}  envoy ${PROXY_IMAGE}"

# L1: the mesh's normalization and the policies' shape are what the model covers.
NORMALIZATION="$(yq -r '.istiod.meshConfig.pathNormalization.normalization // "BASE"' "${ISTIO_CHART}/values.yaml")"
if [[ "${NORMALIZATION}" == BASE || "${NORMALIZATION}" == DEFAULT ]]; then
  pass L1 "the istio chart keeps pathNormalization ${NORMALIZATION} (normalize_path on, merge_slashes off, escaped slashes kept)"
else
  fail L1 "the istio chart sets pathNormalization ${NORMALIZATION}; this model covers BASE only, update it"
fi
policy_paths() { # policy_paths NAME: the DENY's paths, one per line; empty if the shape is not paths only
  jq -r --arg n "$1" '[.[] | select(.kind == "AuthorizationPolicy" and .metadata.name == $n)]
    | if length == 1 and .[0].spec.action == "DENY" and (.[0].spec.rules | length) == 1
         and (.[0].spec.rules[0] | keys) == ["to"]
         and all(.[0].spec.rules[0].to[]; (.operation | keys) == ["paths"])
      then .[0].spec.rules[0].to[].operation.paths[] else empty end' "${tmp}/render.json"
}
for w in prometheus alertmanager; do
  policy_paths "${w}-deny-lifecycle" > "${tmp}/${w}.paths"
  if [[ -s "${tmp}/${w}.paths" ]]; then
    pass L1 "${w}-deny-lifecycle is one DENY rule of paths for every source: $(paste -sd' ' "${tmp}/${w}.paths")"
  else
    fail L1 "${w}-deny-lifecycle is missing or not one DENY rule of paths only; the model cannot run it"
  fi
done
printf '%s\n' '*/-/quit' '*/-/reload' > "${tmp}/old.paths"

# --- Envoy configuration, as istiod builds the inbound sidecar -----------------------
matchers() { # matchers PATHS_FILE: the url_path matchers of an Istio `paths` list
  local p
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    if [[ "${p}" == '*' ]]; then echo '{"url_path": {"path": {"safe_regex": {"regex": ".+"}}}}'
    elif [[ "${p}" == \** ]]; then jq -nc --arg v "${p:1}" '{url_path: {path: {suffix: $v}}}'
    elif [[ "${p}" == *\* ]]; then jq -nc --arg v "${p%?}" '{url_path: {path: {prefix: $v}}}'
    else jq -nc --arg v "${p}" '{url_path: {path: {exact: $v}}}'
    fi
  done < "$1" | jq -s .
}
listener() { # listener NAME PORT CLUSTER PATHS_FILE
  jq -n --arg name "$1" --argjson port "$2" --arg cluster "$3" --argjson m "$(matchers "$4")" '
    {name: $name, address: {socket_address: {address: "0.0.0.0", port_value: $port}},
     filter_chains: [{filters: [{name: "envoy.filters.network.http_connection_manager", typed_config: {
       "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
       stat_prefix: $name, normalize_path: true, merge_slashes: false,
       route_config: {virtual_hosts: [{name: "all", domains: ["*"],
         routes: [{match: {prefix: "/"}, route: {cluster: $cluster}}]}]},
       http_filters: [
         {name: "envoy.filters.http.rbac", typed_config: {
           "@type": "type.googleapis.com/envoy.extensions.filters.http.rbac.v3.RBAC",
           rules: {action: "DENY", policies: {"deny-lifecycle": {
             permissions: [{or_rules: {rules: $m}}], principals: [{any: true}]}}}}},
         {name: "envoy.filters.http.router", typed_config: {
           "@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"}}]}}]}]}'
}
cluster() { # cluster NAME HOST PORT
  jq -n --arg name "$1" --arg host "$2" --argjson port "$3" '
    {name: $name, type: "STRICT_DNS", connect_timeout: "2s", load_assignment: {cluster_name: $name,
      endpoints: [{lb_endpoints: [{endpoint: {address: {socket_address: {address: $host, port_value: $port}}}}]}]}}'
}
jq -n --argjson l1 "$(listener prometheus 10001 prometheus "${tmp}/prometheus.paths")" \
      --argjson l2 "$(listener alertmanager 10002 alertmanager "${tmp}/alertmanager.paths")" \
      --argjson c1 "$(cluster prometheus "${PROM_CT}" 9090)" --argjson c2 "$(cluster alertmanager "${AM_CT}" 9093)" \
  '{static_resources: {listeners: [$l1, $l2], clusters: [$c1, $c2]}}' > "${tmp}/envoy.json"
jq -n --argjson l "$(listener prometheus-old 10001 prometheus "${tmp}/old.paths")" \
      --argjson c "$(cluster prometheus "${PROM_CT}" 9090)" \
  '{static_resources: {listeners: [$l], clusters: [$c]}}' > "${tmp}/envoy-old.json"
chmod 0644 "${tmp}"/envoy*.json
chmod 0755 "${tmp}"

# --- containers --------------------------------------------------------------------------
docker network create "${NET}" >/dev/null
start_prometheus() {
  docker rm -f "${PROM_CT}" >/dev/null 2>&1 || true
  docker run -d --name "${PROM_CT}" --network "${NET}" "${PROM_IMAGE}" \
    --config.file=/etc/prometheus/prometheus.yml --web.enable-lifecycle \
    --web.route-prefix="${PROM_PREFIX}" --web.external-url="http://localhost:9090${PROM_PREFIX}" >/dev/null
}
start_prometheus
docker run -d --name "${AM_CT}" --network "${NET}" "${AM_IMAGE}" \
  --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/alertmanager \
  --web.route-prefix="${AM_PREFIX}" --web.external-url="http://localhost:9093${AM_PREFIX}" >/dev/null
envoy_run() { # envoy_run NAME CONFIG PORT...
  local name="$1" config="$2" publish=() port
  shift 2
  for port in "$@"; do publish+=(-p "127.0.0.1::${port}"); done
  docker run -d --name "${name}" --network "${NET}" "${publish[@]}" -v "${config}:/etc/envoy.json:ro" \
    --entrypoint /usr/local/bin/envoy "${PROXY_IMAGE}" -c /etc/envoy.json --log-level warn >/dev/null
}
host_port() { docker port "$1" "$2/tcp" | head -1 | sed 's/.*://'; }
envoy_run "${ENVOY_CT}" "${tmp}/envoy.json" 10001 10002
PROM_URL="http://127.0.0.1:$(host_port "${ENVOY_CT}" 10001)"
AM_URL="http://127.0.0.1:$(host_port "${ENVOY_CT}" 10002)"

code() { # code METHOD URL [CURL ARGS...]: the HTTP status, 000 when there is no answer
  local method="$1" url="$2"
  shift 2
  curl -s -o /dev/null -w '%{http_code}' --path-as-is --max-time 10 -X "${method}" "$@" "${url}" || true
}
wait_ready() { # wait_ready URL: until GET URL is 200 (60 s)
  local _
  for _ in $(seq 60); do [[ "$(code GET "$1")" == 200 ]] && return 0; sleep 1; done
  return 1
}
running() { [[ "$(docker inspect -f '{{.State.Running}}' "${PROM_CT}" 2>/dev/null)" == true ]]; }
if ! wait_ready "${PROM_URL}${PROM_PREFIX}/-/ready" || ! wait_ready "${AM_URL}${AM_PREFIX}/-/ready"; then
  docker logs "${ENVOY_CT}" 2>&1 | tail -20 >&2
  echo "Prometheus or Alertmanager is not ready behind the Envoy model" >&2
  exit 1
fi

# --- L2 the API stays reachable -------------------------------------------------------------
expect() { # expect CHECK WANT METHOD URL [CURL ARGS...]: WANT is an ERE for the status
  local check="$1" want="$2" method="$3" url="$4" got
  shift 4
  got="$(code "${method}" "${url}" "$@")"
  if [[ "${got}" =~ ^(${want})$ ]]; then
    pass "${check}" "${method} ${url#http://127.0.0.1:*/} -> ${got}"
  else
    fail "${check}" "${method} ${url#http://127.0.0.1:*/} -> ${got}, want ${want}"
  fi
}
expect L2 200 GET "${PROM_URL}${PROM_PREFIX}/api/v1/status/buildinfo"
expect L2 200 POST "${PROM_URL}${PROM_PREFIX}/api/v1/query" --data-urlencode 'query=up'
expect L2 200 GET "${PROM_URL}${PROM_PREFIX}/-/ready"
expect L2 200 GET "${AM_URL}${AM_PREFIX}/api/v2/status"
expect L2 200 GET "${AM_URL}${AM_PREFIX}/-/ready"

# --- L3 every spelling of the lifecycle endpoints is denied ---------------------------------
for target in "prometheus ${PROM_URL} ${PROM_PREFIX}" "alertmanager ${AM_URL} ${AM_PREFIX}"; do
  read -r _ url prefix <<< "${target}"
  for x in quit reload; do
    encoded="${x/q/%71}"
    encoded="${encoded/r/%72}"
    for s1 in / %2F %2f; do
      for s2 in / %2F %2f; do
        expect L3 403 POST "${url}${prefix}${s1}-${s2}${x}"
      done
    done
    expect L3 403 PUT "${url}${prefix}/-/${x}"
    expect L3 403 PUT "${url}${prefix}/-%2F${x}"
    expect L3 403 POST "${url}${prefix}/%2D/${x}"
    expect L3 403 POST "${url}${prefix}/-/${encoded}"
    expect L3 403 POST "${url}${prefix}/-/./${x}"
    expect L3 403 POST "${url}${prefix}/api/../-/${x}"
    expect L3 403 POST "${url}${prefix}/-/${x}?x=1"
    expect L3 '[345][0-9][0-9]' POST "${url}${prefix}/-//${x}"
    expect L3 '[345][0-9][0-9]' POST "${url}${prefix}/-/${x}/"
  done
done

# --- L4 Prometheus survived every quit probe -------------------------------------------------
sleep 3
if running && [[ "$(code GET "${PROM_URL}${PROM_PREFIX}/-/ready")" == 200 ]]; then
  pass L4 "Prometheus is still running after every quit probe"
else
  fail L4 "Prometheus stopped: a quit probe reached it"
  start_prometheus
  wait_ready "${PROM_URL}${PROM_PREFIX}/-/ready" || true
fi

# --- L5 self-test: the first draft's paths let an encoded slash through ----------------------
envoy_run "${OLD_CT}" "${tmp}/envoy-old.json" 10001
OLD_URL="http://127.0.0.1:$(host_port "${OLD_CT}" 10001)"
if wait_ready "${OLD_URL}${PROM_PREFIX}/-/ready"; then
  got_plain="$(code POST "${OLD_URL}${PROM_PREFIX}/-/quit")"
  got_enc="$(code POST "${OLD_URL}${PROM_PREFIX}/-%2Fquit")"
  sleep 3
  if [[ "${got_plain}" == 403 && "${got_enc}" == 2* ]] && ! running; then
    pass L5 "with */-/quit and */-/reload: /-/quit -> 403, but /-%2Fquit -> ${got_enc} and Prometheus stopped (the model sees the bypass)"
  else
    fail L5 "with */-/quit and */-/reload: /-/quit -> ${got_plain}, /-%2Fquit -> ${got_enc}, Prometheus $(running && echo running || echo stopped); the model does not show the bypass"
  fi
else
  fail L5 "Prometheus is not ready behind the first draft's Envoy model"
fi

echo
echo "lifecycle-deny-docker-test.sh (monitoring): ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
