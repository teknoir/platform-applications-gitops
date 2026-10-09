#!/usr/bin/env bash
# SC2016: the single-quoted strings are jq programs.
# shellcheck disable=SC2016
# charts/monitoring/tests/namespace-authz-test.sh — who reaches Grafana,
# Prometheus and Alertmanager, counting every AuthorizationPolicy that applies
# to them, whatever chart renders it. An ALLOW without a selector applies to
# every workload in its namespace (and, in the root namespace istio-system, to
# the whole mesh). The harbor chart's harbor-allow-internal is one: it admits
# every mTLS source in teknoir-system and teknoir-auth to the monitoring
# workloads too. render-test.sh sees only this chart, so it cannot catch such
# a policy. No cluster needed.
#
# Renders, the way ArgoCD does (no values, the chart's own defaults), every
# chart that charts/app-of-apps/values.yaml installs into teknoir-system or
# istio-system. Pod labels and ServiceAccounts come from the monitoring render
# (Grafana's Deployment; the operator's labels on the Prometheus and
# Alertmanager pods, as on teknoir-local).
#
# Checks (FAIL makes the script exit 1):
#   N1  no ALLOW that applies to a monitoring workload admits the ingress
#       gateway (or might: a rule without a source, a wildcard, istio-system)
#       unless the rule requires request.auth.claims[groups] in
#       monitoring.access.groups
#   N2  without a token, only teknoir-system and teknoir-auth reach them in the
#       mesh (no teamspace, no wildcard, no rule without a source)
#   N3  the in-mesh paths the stack needs are admitted without a token, and the
#       output names the policies that admit each one: Grafana's Prometheus
#       and Alertmanager datasources, and Prometheus' alert delivery
#   N4  self-test: the checks are not vacuous. They must flag an ingress ALLOW
#       without the groups claim (as before 0.0.5), and synthetic
#       namespace-wide ALLOWs that admit istio-system, any source or a
#       teamspace, and a mesh-wide ALLOW for istio-system/* in the root
#       namespace. Each N3 path must be denied once the policies that admit it
#       are removed (today Grafana's Alertmanager datasource is admitted by
#       harbor-allow-internal alone, so it is lost when that policy gets a
#       selector)
# INFO lines list the namespace-wide policies and the effective mTLS mode. A
# WARN line marks an N3 path that only another chart's policy admits.
#
# Usage: charts/monitoring/tests/namespace-authz-test.sh [--renders DIR]
#   --renders DIR  evaluate the renders that `tests/render.sh --out DIR` wrote
#                  (DIR/<chart>.yaml) instead of rendering the charts again,
#                  so tests/render.sh can run this as its monitoring-authz
#                  check. The ALLOWs that admit no gateway (in-namespace
#                  sources such as prometheus-allow-internal,
#                  alertmanager-allow-prometheus and harbor's
#                  harbor-allow-internal) need no groups condition; N1 holds
#                  every rule that may admit the gateway to it.
# Environment: KUBE_VERSION (default 1.33.5), RENDER_CACHE (default
# ~/.cache/teknoir-render, shared with tests/render.sh), HELM (default helm).
# Requires helm, yq (mikefarah v4) and jq; network access for uncached chart
# dependencies.
set -euo pipefail

RENDERS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --renders) [[ -n "${2:-}" && -d "$2" ]] || { echo "--renders needs a directory" >&2; exit 2; }
               RENDERS="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '4,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${HERE}/lib.sh"
CHARTS="$(cd "${MONITORING_CHART}/.." && pwd)"
APPS="${CHARTS}/app-of-apps/values.yaml"
NS=teknoir-system
ROOT_NS=istio-system
GATEWAY="cluster.local/ns/istio-system/sa/istio-ingressgateway"
TOKENLESS_OK='["teknoir-system", "teknoir-auth"]'

for tool in "${HELM}" yq jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fails=0
pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; fails=$((fails + 1)); }
info() { printf 'INFO  %-3s %s\n' "$1" "$2"; }

# --- render every chart installed into teknoir-system and the root namespace ----
: > "${tmp}/all.json"
while IFS=$'\t' read -r app chart ns; do
  if [[ -n "${RENDERS}" ]]; then
    [[ -f "${RENDERS}/${chart}.yaml" ]] || { fail N0 "app-of-apps ${app}: no render ${RENDERS}/${chart}.yaml"; continue; }
    cp "${RENDERS}/${chart}.yaml" "${tmp}/${app}.yaml"
  else
    [[ -d "${CHARTS}/${chart}" ]] || { fail N0 "app-of-apps ${app}: no chart ${chart} in charts/"; continue; }
    chart_render_setup "${CHARTS}/${chart}" "${tmp}/src-${app}"
    if ! "${HELM}" template "${app}" "${tmp}/src-${app}" --namespace "${ns}" \
         --kube-version "${KUBE_VERSION}" > "${tmp}/${app}.yaml" 2> "${tmp}/err"; then
      fail N0 "app-of-apps ${app}: helm template failed: $(tr '\n' ' ' < "${tmp}/err")"
      continue
    fi
  fi
  yq -o=json -I=0 'select(. != null)' "${tmp}/${app}.yaml" \
    | jq -c --arg app "${app}" --arg ns "${ns}" '. + {"_app": $app, "_ns": (.metadata.namespace // $ns)}' \
    >> "${tmp}/all.json"
done < <(yq -o=json '.applications' "${APPS}" | jq -r --arg ns "${NS}" --arg root "${ROOT_NS}" '
  to_entries[] | select(.value.enabled != false and (.value.namespace == $ns or .value.namespace == $root))
  | [.key, (.value.chart // .key), .value.namespace] | @tsv')
jq -s . "${tmp}/all.json" > "${tmp}/all.array.json"
echo "${RENDERS:+renders from ${RENDERS}: }rendered: $(jq -r '[.[]._app] | unique | join(" ")' "${tmp}/all.array.json")"

# Policies as {app, ns, name, action, selector, targeted, rules}.
jq '[.[] | select(.kind == "AuthorizationPolicy")
     | {app: ._app, ns: ._ns, name: .metadata.name, action: (.spec.action // "ALLOW"),
        selector: (if .spec.selector then (.spec.selector.matchLabels // {}) else null end),
        targeted: ((.spec.targetRef // .spec.targetRefs) != null), rules: (.spec.rules // [])}]' \
  "${tmp}/all.array.json" > "${tmp}/policies.json"

# Monitoring workloads: name, pod labels, ServiceAccount.
jq --arg ns "${NS}" '
  [.[] | select(._app == "monitoring")] as $m
  | ($m | map(select(.kind == "Deployment" and .metadata.name == "monitoring-grafana"))[0]) as $g
  | ($m | map(select(.kind == "Prometheus"))[0]) as $p
  | ($m | map(select(.kind == "Alertmanager"))[0]) as $a
  | [ {name: "grafana", labels: $g.spec.template.metadata.labels,
       sa: ($g.spec.template.spec.serviceAccountName // "default")},
      {name: "prometheus",
       labels: ({"app.kubernetes.io/name": "prometheus", "app.kubernetes.io/instance": $p.metadata.name,
                 "app.kubernetes.io/managed-by": "prometheus-operator",
                 "operator.prometheus.io/name": $p.metadata.name, "operator.prometheus.io/shard": "0",
                 "prometheus": $p.metadata.name}
                + (if $p.spec.version then {"app.kubernetes.io/version": ($p.spec.version | ltrimstr("v"))} else {} end)
                + ($p.spec.podMetadata.labels // {})),
       sa: ($p.spec.serviceAccountName // "default")},
      {name: "alertmanager",
       labels: ({"app.kubernetes.io/name": "alertmanager", "app.kubernetes.io/instance": $a.metadata.name,
                 "app.kubernetes.io/managed-by": "prometheus-operator", "alertmanager": $a.metadata.name}
                + (if $a.spec.version then {"app.kubernetes.io/version": ($a.spec.version | ltrimstr("v"))} else {} end)
                + ($a.spec.podMetadata.labels // {})),
       sa: ($a.spec.serviceAccountName // "default")} ]
  | map(. + {ns: $ns, principal: "cluster.local/ns/\($ns)/sa/\(.sa)"})' \
  "${tmp}/all.array.json" > "${tmp}/workloads.json"
if jq -e 'length == 3 and all(.labels != null and (.labels | length) > 0)' "${tmp}/workloads.json" >/dev/null; then
  info N0 "workloads: $(jq -r 'map("\(.name) (sa \(.sa))") | join(", ")' "${tmp}/workloads.json")"
else
  fail N0 "could not derive the pod labels of grafana, prometheus and alertmanager from the render"
fi

# --- the evaluator --------------------------------------------------------------
# Istio semantics, conservatively: a policy applies to a workload when it is in
# the workload's namespace or the root namespace and its matchLabels are a
# subset of the pod's labels (no selector: all). A rule without `from` admits
# every source. Within a source the fields AND; a source with neither
# principals nor namespaces admits any namespace.
LIB='
def glob($p; $s): if $p == "*" then true
  elif ($p | startswith("*")) then ($s | endswith($p[1:]))
  elif ($p | endswith("*")) then ($s | startswith($p[:-1]))
  else $p == $s end;
def applies($w): (.ns == $w.ns or .ns == $root) and (.targeted | not)
  and ((.selector // {}) | to_entries | all(. as $e | $w.labels[$e.key] == $e.value));
def principal_ns: if test("^cluster\\.local/ns/[^/*]+/") then capture("^cluster\\.local/ns/(?<n>[^/]+)/").n else "*" end;
# Namespaces a source can admit; ["*"] when unrestricted.
def source_ns: [(.namespaces // [])[], ((.principals // [])[] | principal_ns)]
  | if length == 0 then ["*"] else unique end;
def rule_ns: if ((.from // []) | length) == 0 then ["*"] else [.from[].source | source_ns[]] | unique end;
def source_admits($id; $tokenless):
  (if .principals then any(.principals[]; glob(.; $id.principal)) else true end)
  and (if .namespaces then any(.namespaces[]; glob(.; $id.ns)) else true end)
  and (if .notPrincipals then (any(.notPrincipals[]; glob(.; $id.principal)) | not) else true end)
  and (if .notNamespaces then (any(.notNamespaces[]; glob(.; $id.ns)) | not) else true end)
  and (if $tokenless then (.requestPrincipals == null) else true end);
def rule_admits($id; $tokenless):
  (if ((.from // []) | length) == 0 then true else any(.from[]; .source | source_admits($id; $tokenless)) end)
  and (if $tokenless then ([(.when // [])[] | select(.key | startswith("request.auth."))] | length) == 0 else true end);
def requires_token: ([(.when // [])[] | select(.key | startswith("request.auth."))] | length) > 0
  or any((.from // [])[]; .source.requestPrincipals != null);
def requires_groups($groups): any((.when // [])[]; .key == "request.auth.claims[groups]"
  and ((.values // []) | length) > 0 and all(.values[]; . as $v | $groups | index($v) != null));
def gw_id: {ns: "istio-system", principal: $gw};
def plabel: "\(.name) (chart \(.app)\(if .selector == null then ", no selector" else "" end))";
# N1: [workload, policy, rule index] for every rule that may admit the gateway
# without requiring the groups claim.
def n1($ws; $groups): [ $ws[] as $w | .[] | select(.action == "ALLOW" and applies($w)) as $p
  | $p.rules | to_entries[] | select((.value | rule_ns | (index("*") != null or index("istio-system") != null))
      or (.value | rule_admits(gw_id; false)))
  | select(.value | requires_groups($groups) | not)
  | "\($w.name) <- \($p | plabel) rule \(.key)" ];
# N2: token-less rules that admit a namespace outside $ok.
def n2($ws; $ok): [ $ws[] as $w | .[] | select(.action == "ALLOW" and applies($w)) as $p
  | $p.rules | to_entries[] | select(.value | requires_token | not)
  | (.value | rule_ns) as $n | select(($n - $ok) | length > 0)
  | "\($w.name) <- \($p | plabel) rule \(.key) admits \($n - $ok | join(","))" ];
# N3: is $id admitted to workload $w without a token? {ok, by, names, apps}
def admitted($id; $w): [.[] | select(applies($w))] as $ps
  | ([$ps[] | select(.action == "DENY") | select(any(.rules[]; rule_admits($id; false))) | plabel]) as $deny
  | ([$ps[] | select(.action == "ALLOW")]) as $allow
  | [$allow[] | select(any(.rules[]; rule_admits($id; true)))] as $ps
  | if ($deny | length) > 0 then {ok: false, by: ["DENY " + ($deny | join(", "))], names: [], apps: []}
    elif ($allow | length) == 0 then {ok: true, by: ["no ALLOW policy applies"], names: [], apps: []}
    else {ok: (($ps | length) > 0), by: [$ps[] | plabel], names: [$ps[].name], apps: ([$ps[].app] | unique)} end;
'
GROUPS_JSON="$(yq -o=json -I=0 '.monitoring.access.groups' "${MONITORING_CHART}/values.yaml")"
eval_jq() { # eval_jq POLICIES PROGRAM [JQ ARGS...]: run PROGRAM with the evaluator on POLICIES
  local policies="$1" prog="$2"
  shift 2
  jq -r --slurpfile ws "${tmp}/workloads.json" --argjson groups "${GROUPS_JSON}" \
    --argjson ok "${TOKENLESS_OK}" --arg gw "${GATEWAY}" --arg root "${ROOT_NS}" \
    "$@" "${LIB} ${prog}" "${policies}"
}
identity() { # identity WORKLOAD: {ns, principal} of a monitoring workload's ServiceAccount
  jq -c --arg w "$1" '.[] | select(.name == $w) | {ns, principal}' "${tmp}/workloads.json"
}

# --- INFO: namespace-wide policies and mTLS ----------------------------------------
jq -r --arg ns "${NS}" --arg root "${ROOT_NS}" '.[] | select(.selector == null and (.ns == $ns or .ns == $root) and (.targeted | not))
  | "\(.action) \(.name) (chart \(.app), namespace \(.ns)): " + (.rules | map(
      if ((.from // []) | length) == 0 then "any source" else [.from[].source | tostring] | join(" | ") end) | join("; "))' \
  "${tmp}/policies.json" | while IFS= read -r line; do info N0 "applies to every workload: ${line}"; done
for w in grafana prometheus alertmanager; do
  # Effective PeerAuthentication: workload selector, else namespace-wide, else root.
  mode="$(jq -r --slurpfile ws "${tmp}/workloads.json" --arg w "${w}" --arg ns "${NS}" --arg root "${ROOT_NS}" '
    ($ws[0][] | select(.name == $w)) as $wl
    | [.[] | select(.kind == "PeerAuthentication")] as $pa
    | ([$pa[] | select(._ns == $ns and .spec.selector != null
          and ((.spec.selector.matchLabels // {}) | to_entries | all(. as $e | $wl.labels[$e.key] == $e.value)))]
       + [$pa[] | select(._ns == $ns and .spec.selector == null)]
       + [$pa[] | select(._ns == $root and .spec.selector == null)])[0]
    | if . == null then "PERMISSIVE (no PeerAuthentication)"
      else "\(.spec.mtls.mode // "PERMISSIVE") from \(.metadata.name) (chart \(._app))" end' "${tmp}/all.array.json")"
  info N0 "${w}: mTLS ${mode}"
done

# --- N1 the gateway only with the groups claim --------------------------------------
n1="$(eval_jq "${tmp}/policies.json" 'n1($ws[0]; $groups) | .[]')"
if [[ -z "${n1}" ]]; then
  pass N1 "no ALLOW from any chart admits the gateway to grafana, prometheus or alertmanager without groups ${GROUPS_JSON}"
else
  while IFS= read -r l; do fail N1 "gateway admitted without the groups claim: ${l}"; done <<< "${n1}"
fi

# --- N2 token-less in-mesh sources ----------------------------------------------------
n2="$(eval_jq "${tmp}/policies.json" 'n2($ws[0]; $ok) | .[]')"
if [[ -z "${n2}" ]]; then
  pass N2 "without a token only $(jq -r 'join(" and ")' <<< "${TOKENLESS_OK}") reach the monitoring workloads in the mesh"
else
  while IFS= read -r l; do fail N2 "token-less access from outside the platform namespaces: ${l}"; done <<< "${n2}"
fi
for w in grafana prometheus alertmanager; do
  info N2 "${w}: token-less in-mesh sources: $(eval_jq "${tmp}/policies.json" '
    ($ws[0][] | select(.name == $w)) as $wl
    | [.[] | select(.action == "ALLOW" and applies($wl)) | plabel as $l
       | .rules[] | select(requires_token | not) | "\(rule_ns | join(",")) via \($l)"] | unique | join("; ")' \
    --arg w "${w}")"
done

# --- N3 the paths the stack needs --------------------------------------------------------
probe() { # probe CLIENT WORKLOAD [POLICIES]: {ok, by, names, apps}, admitted without a token
  local client="$1" target="$2" policies="${3:-${tmp}/policies.json}"
  eval_jq "${policies}" 'admitted($id; ($ws[0][] | select(.name == $t))) | tojson' \
    --argjson id "$(identity "${client}")" --arg t "${target}"
}
PATHS=("grafana prometheus Grafana's Prometheus datasource"
       "grafana alertmanager Grafana's Alertmanager datasource"
       "prometheus alertmanager Prometheus' alert delivery")
for path in "${PATHS[@]}"; do
  read -r client target what <<< "${path}"
  r="$(probe "${client}" "${target}")"
  if [[ "$(jq -r .ok <<< "${r}")" == true ]]; then
    pass N3 "${what} (${client} -> ${target}) admitted by $(jq -r '.by | join(", ")' <<< "${r}")"
    if jq -e '(.apps | length) > 0 and (.apps | index("monitoring")) == null' <<< "${r}" >/dev/null; then
      printf 'WARN  N3  %s depends only on policies of chart %s: it breaks when they get a selector\n' \
        "${what}" "$(jq -r '.apps | join(", ")' <<< "${r}")"
    fi
  else
    fail N3 "${what} (${client} -> ${target}) is denied: $(jq -r \
      'if (.by | length) == 0 then "no ALLOW that applies admits it" else .by | join(", ") end' <<< "${r}")"
  fi
done

# --- N4 self-test -----------------------------------------------------------------------------
# Synthetic policies, so the self-test stays valid whatever the charts render.
mutate() { # mutate NAME JQ_FILTER: write the policies with JQ_FILTER applied to NAME.json
  jq "$2" "${tmp}/policies.json" > "${tmp}/$1.json"
}
expect_flag() { # expect_flag WHAT POLICIES PROGRAM: the program must print a violation
  if [[ -n "$(eval_jq "$2" "$3 | .[]")" ]]; then
    pass N4 "flags ${1}"
  else
    fail N4 "does not flag ${1}"
  fi
}
nswide() { # nswide NAME NAMESPACE RULES_JSON: a selector-less ALLOW, appended
  mutate "$1" ". + [{app: \"selftest\", ns: \"$2\", name: \"$1\", action: \"ALLOW\", selector: null, targeted: false, rules: $3}]"
}
mutate no-groups 'map(if .name == "grafana-allow-ingress" then .rules[0] |= del(.when) else . end)'
expect_flag "grafana-allow-ingress without the groups claim, as before 0.0.5 (N1)" "${tmp}/no-groups.json" 'n1($ws[0]; $groups)'
nswide gw-ns teknoir-system '[{from: [{source: {namespaces: ["teknoir-system", "teknoir-auth", "istio-system"]}}]}]'
expect_flag "a namespace-wide ALLOW admitting namespace istio-system (N1)" "${tmp}/gw-ns.json" 'n1($ws[0]; $groups)'
nswide any-src teknoir-system '[{}]'
expect_flag "a namespace-wide ALLOW rule without a source (N1)" "${tmp}/any-src.json" 'n1($ws[0]; $groups)'
expect_flag "a namespace-wide ALLOW rule without a source (N2)" "${tmp}/any-src.json" 'n2($ws[0]; $ok)'
nswide teamspace teknoir-system '[{from: [{source: {namespaces: ["teknoir-system", "teknoir-demo"]}}]}]'
expect_flag "a namespace-wide ALLOW admitting a teamspace (N2)" "${tmp}/teamspace.json" 'n2($ws[0]; $ok)'
nswide mesh-gw istio-system '[{from: [{source: {principals: ["cluster.local/ns/istio-system/sa/*"]}}]}]'
expect_flag "a mesh-wide ALLOW for istio-system/* in the root namespace (N1)" "${tmp}/mesh-gw.json" 'n1($ws[0]; $groups)'
for path in "${PATHS[@]}"; do
  read -r client target what <<< "${path}"
  names="$(probe "${client}" "${target}" | jq -c .names)"
  jq --argjson n "${names}" 'map(select(.name as $x | $n | index($x) | not))' "${tmp}/policies.json" > "${tmp}/without.json"
  if [[ "$(probe "${client}" "${target}" "${tmp}/without.json" | jq -r .ok)" == false ]]; then
    pass N4 "flags ${what} as denied without $(jq -r 'join(", ")' <<< "${names}")"
  else
    fail N4 "${what} still admitted without $(jq -r 'join(", ")' <<< "${names}")"
  fi
done

echo
echo "namespace-authz-test.sh (monitoring): ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
