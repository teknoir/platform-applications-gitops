#!/usr/bin/env bash
# SC2016: the single-quoted strings are jq programs.
# shellcheck disable=SC2016
# charts/monitoring/tests/render-test.sh — render the monitoring chart the way
# ArgoCD does (release monitoring, namespace teknoir-system) and check who can
# reach Grafana, Prometheus and Alertmanager (not packaged: .helmignore tests/).
# No cluster needed.
#
# Checks (FAIL makes the script exit 1):
#   M1  a RequestAuthentication per workload: issuer = monitoring.access.issuer,
#       jwksUri = <issuer>/protocol/openid-connect/certs, the token from
#       X-Auth-Request-Access-Token and X-Forwarded-Access-Token, kept for the
#       workload (forwardOriginalToken)
#   M2  <workload>-allow-ingress: the ingress gateway principal AND
#       request.auth.claims[groups] in monitoring.access.groups
#   M3  every ALLOW rule of every AuthorizationPolicy has a source, and every
#       rule that admits the gateway also requires the groups claim
#   M4  alert delivery: every Alertmanager endpoint of the Prometheus resource
#       is this release's Alertmanager (<fullnameOverride>-alertmanager in the
#       chart's namespace, under its routePrefix) and is rewritten to the
#       Service's name and http-web port (a pod IP would leave the mesh in
#       plaintext: 503); one Alertmanager replica (the Service address
#       reaches one replica only); alertmanager-allow-prometheus admits the
#       ServiceAccount Prometheus runs as (rendered)
#   M5  prometheus-allow-internal still admits the namespace
#   M6  grafana.ini: no anonymous access; auth.jwt signs users in from the
#       forwarded token with the same issuer and JWKS (https), maps group
#       admin to Admin, strict; no self sign-up; basic auth on (sidecars,
#       break-glass) and the login form off (the break-glass is basic auth on
#       the API, as the runbook says); no update checks or reporting
#   M7  Grafana trusts the Teknoir Root CA (Secret teknoir-root-ca-bundle,
#       optional) through SSL_CERT_DIR, and its pods carry the label the
#       grafana policies select
#   M8  monitoring.access.groups renders into all three ingress policies
#   M9  the render fails on: no groups, an issuer that grafana.ini does not
#       repeat, an http issuer, anonymous access (also the string "on"),
#       auth.jwt off (also the string "false", which Grafana reads as off),
#       an expect_claims of another issuer, an alerting endpoint in another
#       namespace, with another address or without the rewrite, no alerting
#       endpoint, two Alertmanager replicas, a namespaceOverride other than
#       the policies' namespace. It renders with anonymous access the string
#       "false"
#   M10 `istioctl validate` accepts every rendered Istio resource (skipped,
#       not failed, when istioctl is not installed)
#   M11 prometheus- and alertmanager-deny-lifecycle: DENY, for every source,
#       of the lifecycle paths */-/quit and */-/reload (a cross-site POST
#       through the gateway, or any platform pod, could stop or reload
#       Prometheus); no other DENY, and none on Grafana
#
# Usage: charts/monitoring/tests/render-test.sh
# Environment:
#   KUBE_VERSION  Kubernetes version to render for (default 1.33.5, as live)
#   RENDER_CACHE  dependency cache shared with tests/render.sh
#                 (default ~/.cache/teknoir-render)
#   HELM          helm binary (default helm)
# Requires helm, yq (mikefarah v4) and jq; network access for an uncached
# kube-prometheus-stack. Optional: istioctl (M10).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${HERE}/lib.sh"
CHART="${MONITORING_CHART}"
NS=teknoir-system
GATEWAY="cluster.local/ns/istio-system/sa/istio-ingressgateway"
WORKLOADS=(grafana prometheus alertmanager)

for tool in "${HELM}" yq jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fails=0
pass() { printf 'PASS  %-4s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-4s %s\n' "$1" "$2"; fails=$((fails + 1)); }
# check ID DESCRIPTION JQ_PROGRAM [JQ ARGS...]: PASS when the program, run on
# the render (a JSON array of documents), prints true.
check() {
  local id="$1" what="$2" prog="$3"
  shift 3
  if [[ "$(jq -r "$@" "${prog}" "${tmp}/render.json")" == true ]]; then
    pass "${id}" "${what}"
  else
    fail "${id}" "${what}"
  fi
}

# --- render ------------------------------------------------------------------
monitoring_render_setup "${tmp}"
render > "${tmp}/render.yaml"
yq -o=json -I=0 'select(. != null)' "${tmp}/render.yaml" | jq -s . > "${tmp}/render.json"

ISSUER="$(yq -r '.monitoring.access.issuer' "${CHART}/values.yaml")"
GROUPS_JSON="$(yq -o=json -I=0 '.monitoring.access.groups' "${CHART}/values.yaml")"
JWKS="${ISSUER}/protocol/openid-connect/certs"
echo "issuer ${ISSUER}  groups ${GROUPS_JSON}"

# grafana.ini as {section: {key: value}} (values as strings).
jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "monitoring-grafana") | .data["grafana.ini"]' \
  "${tmp}/render.json" > "${tmp}/grafana.ini"
awk '
  /^[[:space:]]*[#;]/ || /^[[:space:]]*$/ { next }
  /^\[.*\]$/ { section = substr($0, 2, length($0) - 2); next }
  { i = index($0, "="); key = substr($0, 1, i - 1); val = substr($0, i + 1)
    gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
    printf "%s\t%s\t%s\n", section, key, val }
' "${tmp}/grafana.ini" \
  | jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
      | reduce .[] as $l ({}; .[$l[0]][$l[1]] = $l[2])' > "${tmp}/ini.json"
ini() { jq -r --arg s "$1" --arg k "$2" '.[$s][$k] // "<unset>"' "${tmp}/ini.json"; }
expect_ini() {
  local section="$1" key="$2" want="$3" have
  have="$(ini "${section}" "${key}")"
  if [[ "${have}" == "${want}" ]]; then
    pass M6 "grafana.ini [${section}] ${key} = ${want}"
  else
    fail M6 "grafana.ini [${section}] ${key} is '${have}', want '${want}'"
  fi
}

# --- M1 RequestAuthentication ------------------------------------------------
for w in "${WORKLOADS[@]}"; do
  check M1 "RequestAuthentication ${w}-request-auth: issuer, jwksUri, headers, forwardOriginalToken" '
    [.[] | select(.kind == "RequestAuthentication" and .metadata.name == ($w + "-request-auth"))] as $ra
    | ($ra | length) == 1
      and $ra[0].metadata.namespace == $ns
      and $ra[0].spec.selector.matchLabels == {"app.kubernetes.io/name": $w}
      and ($ra[0].spec.jwtRules | length) == 1
      and $ra[0].spec.jwtRules[0].issuer == $issuer
      and $ra[0].spec.jwtRules[0].jwksUri == $jwks
      and ($ra[0].spec.jwtRules[0].fromHeaders | map(.name))
          == ["X-Auth-Request-Access-Token", "X-Forwarded-Access-Token"]
      and $ra[0].spec.jwtRules[0].forwardOriginalToken == true' \
    --arg w "${w}" --arg ns "${NS}" --arg issuer "${ISSUER}" --arg jwks "${JWKS}"
done
check M1 "exactly three RequestAuthentications" \
  '[.[] | select(.kind == "RequestAuthentication")] | length == 3'

# --- M2 ingress policies -----------------------------------------------------
for w in "${WORKLOADS[@]}"; do
  check M2 "${w}-allow-ingress: gateway principal AND groups ${GROUPS_JSON}" '
    [.[] | select(.kind == "AuthorizationPolicy" and .metadata.name == ($w + "-allow-ingress"))] as $p
    | ($p | length) == 1
      and $p[0].spec.action == "ALLOW"
      and $p[0].spec.selector.matchLabels == {"app.kubernetes.io/name": $w}
      and ($p[0].spec.rules | length) == 1
      and $p[0].spec.rules[0].from == [{"source": {"principals": [$gw]}}]
      and $p[0].spec.rules[0].when == [{"key": "request.auth.claims[groups]", "values": $groups}]' \
    --arg w "${w}" --arg gw "${GATEWAY}" --argjson groups "${GROUPS_JSON}"
done

# --- M3 no ALLOW without a source; gateway always needs the groups claim -----
check M3 "every ALLOW rule has a source; every rule admitting the gateway requires groups" '
  [.[] | select(.kind == "AuthorizationPolicy" and (.spec.action // "ALLOW") == "ALLOW")
   | .spec.rules // [{}] | .[]
   | ((.from // []) | length > 0)
     and (if ([.from[]?.source.principals[]?] | index($gw)) != null
          then ([.when[]? | select(.key == "request.auth.claims[groups]" and ((.values // []) | length) > 0)] | length) > 0
          else true end)]
  | length > 0 and all' --arg gw "${GATEWAY}"

# --- M4 alert delivery ---------------------------------------------------------
sa="$(jq -r '[.[] | select(.kind == "Prometheus")][0].spec.serviceAccountName // ""' "${tmp}/render.json")"
check M4 "alertmanager-allow-prometheus admits ServiceAccount '${sa}' (rendered)" '
  [.[] | select(.kind == "AuthorizationPolicy" and .metadata.name == "alertmanager-allow-prometheus")] as $p
  | $sa != ""
    and ([.[] | select(.kind == "ServiceAccount" and .metadata.name == $sa)] | length) == 1
    and ($p | length) == 1
    and $p[0].spec.selector.matchLabels == {"app.kubernetes.io/name": "alertmanager"}
    and $p[0].spec.rules == [{"from": [{"source": {"principals": ["cluster.local/ns/\($ns)/sa/\($sa)"]}}]}]' \
  --arg sa "${sa}" --arg ns "${NS}"
AM_NAME="$(yq -r '."kube-prometheus-stack".fullnameOverride' "${CHART}/values.yaml")-alertmanager"
check M4 "Prometheus addresses every Alertmanager endpoint to ${AM_NAME}'s Service in ${NS} (<name>.<ns>.svc.cluster.local:<http-web>), under its routePrefix" '
  . as $all
  | [.[] | select(.kind == "Prometheus")][0].spec.alerting.alertmanagers as $am
  | [.[] | select(.kind == "Alertmanager")] as $amr
  | ($am | length) > 0
    and ($amr | length) == 1
    and ($am | all(. as $e
      | ([$all[] | select(.kind == "Service" and .metadata.name == $e.name
                          and (.metadata.namespace // $ns) == $ns)][0].spec.ports // []
         | map(select(.name == $e.port))[0].port) as $port
      | $e.namespace == $ns and $e.name == $name
        and $e.pathPrefix == $amr[0].spec.routePrefix
        and $port != null
        and ([$e.relabelings[]? | select(.targetLabel == "__address__" and (.action // "replace") == "replace")
              | .replacement] == ["\($name).\($ns).svc.cluster.local:\($port)"])))' \
  --arg ns "${NS}" --arg name "${AM_NAME}"
check M4 "one Alertmanager replica (the Service address reaches one replica only)" '
  [.[] | select(.kind == "Alertmanager")] | length == 1 and ((.[0].spec.replicas // 1) == 1)'

# --- M5 internal Prometheus access -----------------------------------------------
check M5 "prometheus-allow-internal admits namespace ${NS}" '
  [.[] | select(.kind == "AuthorizationPolicy" and .metadata.name == "prometheus-allow-internal")]
  | length == 1 and .[0].spec.rules == [{"from": [{"source": {"namespaces": [$ns]}}]}]' --arg ns "${NS}"

# --- M6 grafana.ini --------------------------------------------------------------
expect_ini auth.anonymous enabled false
if [[ "$(ini auth.anonymous org_role)" == "<unset>" ]]; then
  pass M6 "grafana.ini [auth.anonymous] has no org_role"
else
  fail M6 "grafana.ini [auth.anonymous] still sets org_role $(ini auth.anonymous org_role)"
fi
expect_ini auth.basic enabled true
expect_ini auth disable_login_form true
expect_ini auth.jwt enabled true
expect_ini auth.jwt header_name X-Auth-Request-Access-Token
expect_ini auth.jwt username_claim preferred_username
expect_ini auth.jwt email_claim email
expect_ini auth.jwt jwk_set_url "${JWKS}"
expect_ini auth.jwt auto_sign_up true
expect_ini auth.jwt role_attribute_path "contains(groups[*], 'admin') && 'Admin' || 'Viewer'"
expect_ini auth.jwt role_attribute_strict true
expect_ini users allow_sign_up false
expect_ini analytics check_for_updates false
expect_ini analytics check_for_plugin_updates false
expect_ini analytics reporting_enabled false
if [[ "$(ini auth.jwt expect_claims | jq -r '.iss' 2>/dev/null)" == "${ISSUER}" ]]; then
  pass M6 "grafana.ini [auth.jwt] expect_claims iss = ${ISSUER}"
else
  fail M6 "grafana.ini [auth.jwt] expect_claims is '$(ini auth.jwt expect_claims)', want iss ${ISSUER}"
fi
if [[ "$(ini auth.jwt jwk_set_url)" == https://* ]]; then
  pass M6 "grafana.ini [auth.jwt] jwk_set_url is https (Grafana rejects http)"
else
  fail M6 "grafana.ini [auth.jwt] jwk_set_url must be https"
fi

# --- M7 Grafana pod: CA trust and labels ------------------------------------------
check M7 "Grafana: SSL_CERT_DIR has /etc/teknoir/ca, mounted from optional Secret teknoir-root-ca-bundle" '
  [.[] | select(.kind == "Deployment" and .metadata.name == "monitoring-grafana")][0].spec.template.spec as $s
  | ($s.containers[] | select(.name == "grafana")) as $c
  | ([$c.env[] | select(.name == "SSL_CERT_DIR") | .value | split(":") | index("/etc/teknoir/ca")] | .[0] != null)
    and ([$c.volumeMounts[] | select(.mountPath == "/etc/teknoir/ca") | .name] as $m
         | ($m | length) == 1
           and ([$s.volumes[] | select(.name == $m[0] and .secret.secretName == "teknoir-root-ca-bundle"
                 and .secret.optional == true)] | length) == 1)'
check M7 "Grafana pods carry app.kubernetes.io/name=grafana (the policies' selector)" '
  [.[] | select(.kind == "Deployment" and .metadata.name == "monitoring-grafana")][0]
  .spec.template.metadata.labels["app.kubernetes.io/name"] == "grafana"'

# --- M8 custom groups ---------------------------------------------------------------
if render --set 'monitoring.access.groups={admin,ops}' > "${tmp}/groups.yaml" 2> "${tmp}/err"; then
  n="$(yq -o=json -I=0 'select(.kind == "AuthorizationPolicy" and (.metadata.name | test("-allow-ingress$")))
        | .spec.rules[0].when[0].values' "${tmp}/groups.yaml" | jq -s 'map(select(. == ["admin", "ops"])) | length')"
  if [[ "${n}" == 3 ]]; then
    pass M8 "groups {admin,ops} render into all three ingress policies"
  else
    fail M8 "groups {admin,ops} rendered into ${n} of 3 ingress policies"
  fi
else
  fail M8 "render with groups {admin,ops} failed: $(tr '\n' ' ' < "${tmp}/err")"
fi

# --- M9 guards ------------------------------------------------------------------------
expect_render_failure() {
  local what="$1" pattern="$2"
  shift 2
  if render "$@" > /dev/null 2> "${tmp}/err"; then
    fail M9 "${what}: renders, but must fail"
  elif grep -q -- "${pattern}" "${tmp}/err"; then
    pass M9 "${what}: render fails ('${pattern}')"
  else
    fail M9 "${what}: render fails for another reason: $(tr '\n' ' ' < "${tmp}/err")"
  fi
}
expect_render_failure "no groups" "must list at least one Keycloak group" \
  --set 'monitoring.access.groups=null'
expect_render_failure "issuer not repeated in grafana.ini" "jwk_set_url" \
  --set 'monitoring.access.issuer=https://auth.example.org/auth/realms/teknoir'
expect_render_failure "http issuer" "must be an https URL" \
  --set 'monitoring.access.issuer=http://auth.teknoir.airgapped/auth/realms/teknoir'
expect_render_failure "anonymous access" "auth.anonymous.enabled must be false" \
  --set 'kube-prometheus-stack.grafana.grafana\.ini.auth\.anonymous.enabled=true'
expect_render_failure "auth.jwt off" "auth.jwt.enabled must be true" \
  --set 'kube-prometheus-stack.grafana.grafana\.ini.auth\.jwt.enabled=false'
cat > "${tmp}/other-iss.yaml" <<'EOF'
kube-prometheus-stack:
  grafana:
    grafana.ini:
      auth.jwt:
        expect_claims: '{"iss": "https://auth.example.org/auth/realms/teknoir"}'
EOF
expect_render_failure "expect_claims of another issuer" "expect_claims" -f "${tmp}/other-iss.yaml"
expect_render_failure "auth.jwt enabled the string \"false\"" "auth.jwt.enabled must be true" \
  --set-string 'kube-prometheus-stack.grafana.grafana\.ini.auth\.jwt.enabled=false'
expect_render_failure "anonymous access the string \"on\"" "auth.anonymous.enabled must be false" \
  --set-string 'kube-prometheus-stack.grafana.grafana\.ini.auth\.anonymous.enabled=on'
if render --set-string 'kube-prometheus-stack.grafana.grafana\.ini.auth\.anonymous.enabled=false' \
     > /dev/null 2> "${tmp}/err"; then
  pass M9 "anonymous access the string \"false\": renders"
else
  fail M9 "anonymous access the string \"false\" must render: $(tr '\n' ' ' < "${tmp}/err")"
fi
# alertingEndpoints is a list, so a values file replaces it whole.
alerting_values() { # alerting_values FILE NAMESPACE NAME [REPLACEMENT]: no relabeling without REPLACEMENT
  {
    printf 'kube-prometheus-stack:\n  prometheus:\n    prometheusSpec:\n      alertingEndpoints:\n'
    printf '        - namespace: %s\n          name: %s\n          port: http-web\n' "$2" "$3"
    printf '          pathPrefix: /teknoir-system/alertmanager\n          apiVersion: v2\n'
    if [[ -n "${4:-}" ]]; then
      printf '          relabelings:\n            - action: replace\n'
      printf '              targetLabel: __address__\n              replacement: %s\n' "$4"
    fi
  } > "$1"
}
alerting_values "${tmp}/am-ns.yaml" monitoring monitoring-alertmanager \
  monitoring-alertmanager.monitoring.svc.cluster.local:9093
expect_render_failure "alerting endpoint in another namespace" "must be teknoir-system/monitoring-alertmanager" \
  -f "${tmp}/am-ns.yaml"
alerting_values "${tmp}/am-addr.yaml" teknoir-system monitoring-alertmanager 10.42.0.113:9093
expect_render_failure "alerting endpoint rewritten to another address" "relabeling that replaces __address__" \
  -f "${tmp}/am-addr.yaml"
alerting_values "${tmp}/am-norelabel.yaml" teknoir-system monitoring-alertmanager
expect_render_failure "alerting endpoint without the Service rewrite" "relabeling that replaces __address__" \
  -f "${tmp}/am-norelabel.yaml"
expect_render_failure "no alerting endpoint" "alertingEndpoints must address" \
  --set 'kube-prometheus-stack.prometheus.prometheusSpec.alertingEndpoints=null'
expect_render_failure "two Alertmanager replicas" "alertmanagerSpec.replicas is 2" \
  --set 'kube-prometheus-stack.alertmanager.alertmanagerSpec.replicas=2'
expect_render_failure "namespaceOverride other than namespace" "must equal namespace \"teknoir-system\"" \
  --set 'kube-prometheus-stack.namespaceOverride=monitoring'

# --- M10 istioctl validate ----------------------------------------------------------
if command -v istioctl >/dev/null; then
  yq 'select(.apiVersion | test("istio\\.io/"))' "${tmp}/render.yaml" > "${tmp}/istio.yaml"
  if istioctl validate -f "${tmp}/istio.yaml" > "${tmp}/err" 2>&1; then
    pass M10 "istioctl validate: $(grep -c '^kind:' "${tmp}/istio.yaml") Istio resources valid"
  else
    fail M10 "istioctl validate: $(tr '\n' ' ' < "${tmp}/err")"
  fi
else
  echo "SKIP  M10  istioctl not installed"
fi

# --- M11 lifecycle endpoints ----------------------------------------------------------
for w in prometheus alertmanager; do
  check M11 "${w}-deny-lifecycle: DENY */-/quit and */-/reload from every source" '
    [.[] | select(.kind == "AuthorizationPolicy" and .metadata.name == ($w + "-deny-lifecycle"))] as $p
    | ($p | length) == 1
      and $p[0].metadata.namespace == $ns
      and $p[0].spec.action == "DENY"
      and $p[0].spec.selector.matchLabels == {"app.kubernetes.io/name": $w}
      and $p[0].spec.rules == [{"to": [{"operation": {"paths": ["*/-/quit", "*/-/reload"]}}]}]' \
    --arg w "${w}" --arg ns "${NS}"
done
check M11 "no other DENY policy (none on Grafana, none that could cover an API path)" '
  [.[] | select(.kind == "AuthorizationPolicy" and .spec.action == "DENY") | .metadata.name] | sort
  == ["alertmanager-deny-lifecycle", "prometheus-deny-lifecycle"]'

echo
echo "render-test.sh (monitoring): ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
