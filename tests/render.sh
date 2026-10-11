#!/usr/bin/env bash
# SC2016: the single-quoted strings are jq programs. SC2030/SC2031: the
# self-test runs the checks in subshells on purpose (their counts stay local).
# shellcheck disable=SC2016,SC2030,SC2031
# tests/render.sh — render every GitOps chart the way ArgoCD does and enforce
# the platform policy (G-08).
#
# Each chart is rendered with `helm template <release> <chart> --namespace <ns>
# --include-crds --kube-version $KUBE_VERSION`, where release and namespace are
# the name and destination namespace of the app-of-apps Application that
# deploys it (ArgoCD uses the Application name as the release name), or that
# declares it with enabled: false (checked as if it were enabled). The airgap
# bootstrap must render its one-shot tiers the same way, with no value
# overrides; --out keeps the renders for that comparison.
#
# Checks (FAIL makes the script exit 1, WARN does not):
#   render       every chart renders (dependencies fetched into a scratch copy)
#   pins         every Application pins the chart version in charts/<chart>
#   crds         every CustomResourceDefinition is annotated Prune=false,Delete=false
#   apps         every Application: ServerSideApply=true, retry, no resources
#                finalizer, no helm.skipCrds, RespectIgnoreDifferences when it
#                ignores differences, the platform project
#   project      every rendered resource is allowed by the AppProject
#                (source repo, destination namespace, cluster-scoped kinds)
#   credentials  no known default/literal credential in chart sources or
#                renders (harbor's internal database password is WARN, see below)
#   node-ip      no 192.168.x.x address in a render (site config, not GitOps)
#   determinism  two renders differ only in fields the Application ignores
#                (ignoreDifferences), so selfHeal never churns
#   secrets      lists the Secrets with data in the one-shot tiers (INFO)
# Release policy (r5, app-of-apps 0.0.5; see policy_checks below):
#   ignore-names every named ignoreDifferences rule matches a rendered
#                resource (HYG-C1)
#   images       Teknoir images are K5 pins (<repo>:<immutable tag>@sha256:
#                <digest>, not Always); no digest in the one-shot tiers; WARN on
#                other images on latest, a major-only tag or Always (HYG-C10).
#                Placeholders for images not built yet: PENDING_IMAGE_PINS
#                (WARN), the one allowance, emptied by the pin commit
#   rbac         no binding to cluster-admin; no '*' rule outside
#                RBAC_WILDCARD_ALLOW (SEC-C6)
#   profiles     GitOps Profiles: Prune=false,Delete=false, an owner, no
#                spec.plugins; PLUGIN_CHART_REPO = the app-of-apps repoURL (TS-C2)
#   monitoring-authz  no Grafana anonymous Admin; every ALLOW that may admit
#                the ingress gateway to the monitoring stack requires the groups
#                claim (SEC-C5); plus charts/monitoring/tests/
#                namespace-authz-test.sh --renders on these renders
#   routes       /oauth2 reaches oauth2-proxy on every host it serves (SIGN-C1)
#   auth-filters the ext_authz EnvoyFilter: portNumber 443 on every HTTP_FILTER
#                patch, authz_ok INSERT_AFTER ext_authz (SIGN-C2)
#   self-test    (--self-test) each policy check FAILs (or WARNs) on a mutated
#                copy of the renders, and passes on the renders themselves
#
# Usage: tests/render.sh [--out DIR] [--no-determinism] [--strict-pins]
#                        [--self-test] [CHART...]
#   CHART           chart directory names under charts/ (default: all)
#   --out DIR       write each render to DIR/<chart>.yaml
#   --no-determinism  skip the second render
#   --strict-pins   no PENDING_IMAGE_PINS allowance (for a release build)
#   --self-test     also run the policy checks on bad fixtures (all charts)
# Environment:
#   KUBE_VERSION    Kubernetes version to render for (default 1.33.5, as live)
#   RENDER_CACHE    dependency cache (default ~/.cache/teknoir-render)
#   HELM            helm binary (default helm)
# Requires helm, yq (mikefarah v4) and jq; network access for uncached
# dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.33.5}"
RENDER_CACHE="${RENDER_CACHE:-${HOME}/.cache/teknoir-render}"
HELM="${HELM:-helm}"

# Teknoir one-shot tiers (applied once by the airgap bootstrap, then adopted).
ONESHOT_TIERS=(platform-secrets istio harbor argo)

# Known literal credentials: chart defaults and the published Keycloak admin.
CREDENTIAL_RE='change-me|changeit|harbor12345|harbor_registry_password'
# Rendered Secret keys that hold a chart default credential and are only
# warned about: Harbor chart 1.18.3 cannot take its internal database password
# from a Secret (charts/harbor/values.yaml; changing it awaits the owner's
# decision). "<secret>/<key>" lines; anything else is a failure.
CREDENTIAL_ALLOW=(
  harbor-core/POSTGRESQL_PASSWORD
  harbor-database/POSTGRES_PASSWORD
)
# Cluster-scoped built-in kinds ("group/Kind"); cluster-scoped kinds from
# rendered CRDs are added at run time.
CLUSTER_KINDS=(
  /Namespace /PersistentVolume /Node
  apiextensions.k8s.io/CustomResourceDefinition
  rbac.authorization.k8s.io/ClusterRole rbac.authorization.k8s.io/ClusterRoleBinding
  admissionregistration.k8s.io/MutatingWebhookConfiguration
  admissionregistration.k8s.io/ValidatingWebhookConfiguration
  admissionregistration.k8s.io/ValidatingAdmissionPolicy
  admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding
  apiregistration.k8s.io/APIService storage.k8s.io/StorageClass
  storage.k8s.io/CSIDriver scheduling.k8s.io/PriorityClass
  node.k8s.io/RuntimeClass networking.k8s.io/IngressClass
  certificates.k8s.io/CertificateSigningRequest
)

out_dir=""
determinism=true
strict_pins=false
self_test_run=false
charts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out_dir="$2"; shift 2 ;;
    --no-determinism) determinism=false; shift ;;
    --strict-pins) strict_pins=true; shift ;;
    --self-test) self_test_run=true; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) charts+=("$1"); shift ;;
  esac
done
for tool in "${HELM}" yq jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/src" "${tmp}/out" "${RENDER_CACHE}"
[[ -z "${out_dir}" ]] || mkdir -p "${out_dir}"

fails=0 warns=0
pass() { printf 'PASS  %-12s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-12s %s\n' "$1" "$2"; warns=$((warns + 1)); }
fail() { printf 'FAIL  %-12s %s\n' "$1" "$2"; fails=$((fails + 1)); }
info() { printf 'INFO  %-12s %s\n' "$1" "$2"; }

all_charts=()
for d in "${ROOT}"/charts/*/; do
  [[ -f "${d}Chart.yaml" ]] && all_charts+=("$(basename "${d}")")
done
[[ ${#charts[@]} -gt 0 ]] || charts=("${all_charts[@]}")
if [[ "${self_test_run}" == true && ${#charts[@]} -lt ${#all_charts[@]} ]]; then
  echo "--self-test needs every chart" >&2; exit 2
fi

# --- dependencies ------------------------------------------------------------
# fetch_deps <chart dir>: fill <dir>/charts/ from the cache, pulling what is
# missing. Never touches the working tree.
fetch_deps() {
  local dir="$1" name version repo key
  rm -rf "${dir}/charts" "${dir}/Chart.lock"
  mkdir -p "${dir}/charts"
  while IFS=$'\t' read -r name version repo; do
    [[ -n "${name}" ]] || continue
    key="${RENDER_CACHE}/$(printf '%s' "${repo}" | sed 's#[^A-Za-z0-9._-]#_#g')/${name}-${version}"
    if ! compgen -G "${key}/*.tgz" >/dev/null; then
      rm -rf "${key}.tmp" && mkdir -p "${key}.tmp"
      case "${repo}" in
        oci://*) "${HELM}" pull "${repo%/}/${name}" --version "${version}" -d "${key}.tmp" >/dev/null ;;
        http://*|https://*) "${HELM}" pull "${name}" --repo "${repo}" --version "${version}" -d "${key}.tmp" >/dev/null ;;
        *) echo "unsupported repository '${repo}' for ${name}" >&2; return 1 ;;
      esac
      rm -rf "${key}" && mv "${key}.tmp" "${key}"
    fi
    cp "${key}"/*.tgz "${dir}/charts/"
  done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' "${dir}/Chart.yaml" | sort -u)
}

# --- app-of-apps: who deploys what -------------------------------------------
# apps.json: [{name, chart, version, namespace, enabled, app}]; release name =
# Application name. Rendered a second time with every entry enabled, so an
# Application declared with enabled: false (e.g. argo before DESIGN M7a) is
# still checked as it will be deployed: pin, policy, project, determinism.
aoa_src="${tmp}/src/app-of-apps"
cp -R "${ROOT}/charts/app-of-apps" "${aoa_src}"
yq '{"applications": (.applications // {} | map_values({"enabled": true}))}' \
  "${aoa_src}/values.yaml" > "${tmp}/aoa-all-enabled.yaml"
for variant in deployed all; do
  aoa_values=()
  [[ "${variant}" == deployed ]] || aoa_values=(-f "${tmp}/aoa-all-enabled.yaml")
  if ! "${HELM}" template app-of-apps "${aoa_src}" --namespace teknoir-system "${aoa_values[@]}" \
      --kube-version "${KUBE_VERSION}" > "${tmp}/out/app-of-apps.${variant}.yaml" 2> "${tmp}/err"; then
    fail render "app-of-apps (${variant}): $(tr '\n' ' ' < "${tmp}/err")"
    echo "app-of-apps does not render; nothing else can be checked" >&2
    exit 1
  fi
  yq -o=json -I=0 'select(. != null)' "${tmp}/out/app-of-apps.${variant}.yaml" | jq -s . > "${tmp}/aoa.${variant}.json"
done
mv "${tmp}/out/app-of-apps.deployed.yaml" "${tmp}/out/app-of-apps.yaml"
jq --slurpfile deployed "${tmp}/aoa.deployed.json" '
  ([$deployed[0][] | select(.kind == "Application") | .metadata.name]) as $on
  | [.[] | select(.kind == "Application") | {name: .metadata.name, chart: .spec.source.chart,
     version: .spec.source.targetRevision, namespace: .spec.destination.namespace,
     enabled: (.metadata.name as $n | $on | index($n) != null), app: .}]' \
  "${tmp}/aoa.all.json" > "${tmp}/apps.json"
jq '[.[] | select(.kind == "AppProject")][0] // {}' "${tmp}/aoa.deployed.json" > "${tmp}/project.json"
project_name="$(jq -r '.metadata.name // ""' "${tmp}/project.json")"
while IFS= read -r name; do
  info apps "${name}: declared with enabled: false, so app-of-apps does not deploy it; checked as if enabled"
done < <(jq -r '.[] | select(.enabled | not) | .name' "${tmp}/apps.json")

# --- apps: Application policy --------------------------------------------------
while IFS= read -r line; do
  name="$(jq -r .name <<<"${line}")"
  problems="$(jq -r --arg project "${project_name}" '.app as $a | [
      (if ($a.spec.syncPolicy.syncOptions // []) | index("ServerSideApply=true") then empty else "no ServerSideApply=true" end),
      (if ($a.spec.syncPolicy.retry.limit // 0) > 0 then empty else "no syncPolicy.retry" end),
      (if ($a.metadata.finalizers // []) | map(select(test("resources-finalizer"))) | length > 0 then "has the resources finalizer" else empty end),
      (if $a.spec.source.helm.skipCrds then "sets helm.skipCrds" else empty end),
      (if ($a.spec.ignoreDifferences // [] | length) > 0 and (($a.spec.syncPolicy.syncOptions // []) | index("RespectIgnoreDifferences=true") | not)
        then "ignoreDifferences without RespectIgnoreDifferences=true" else empty end),
      (if $a.spec.project != $project then "project \($a.spec.project), not \($project)" else empty end),
      (if ($a.spec.syncPolicy.automated.prune and $a.spec.syncPolicy.automated.selfHeal) then empty else "not automated with prune and selfHeal" end)
    ] | join("; ")' <<<"${line}")"
  if [[ -n "${problems}" ]]; then fail apps "${name}: ${problems}"; else pass apps "${name}"; fi
done < <(jq -c '.[]' "${tmp}/apps.json")

# --- pins ----------------------------------------------------------------------
while IFS=$'\t' read -r app chart version; do
  if [[ ! -f "${ROOT}/charts/${chart}/Chart.yaml" ]]; then
    fail pins "${app}: pins ${chart} ${version}, but charts/${chart} does not exist"
    continue
  fi
  have="$(yq -r .version "${ROOT}/charts/${chart}/Chart.yaml")"
  if [[ "${have}" == "${version}" ]]; then
    pass pins "${app}: ${chart} ${version}"
  else
    fail pins "${app}: pins ${chart} ${version}, charts/${chart} is ${have}"
  fi
done < <(jq -r '.[] | [.name, .chart, .version] | @tsv' "${tmp}/apps.json")

# --- render ----------------------------------------------------------------------
rendered=()
for chart in "${charts[@]}"; do
  [[ "${chart}" != "app-of-apps" ]] || { rendered+=(app-of-apps); pass render "app-of-apps"; continue; }
  [[ -f "${ROOT}/charts/${chart}/Chart.yaml" ]] || { fail render "${chart}: no charts/${chart}/Chart.yaml"; continue; }
  read -r release ns < <(jq -r --arg c "${chart}" \
    '[.[] | select(.chart == $c)][0] // {} | "\(.name // "") \(.namespace // "")"' "${tmp}/apps.json")
  if [[ -z "${release}" ]]; then
    warn render "${chart}: no Application deploys it; rendering as release ${chart} in teknoir-system"
    release="${chart}" ns="teknoir-system"
  fi
  src="${tmp}/src/${chart}"
  rm -rf "${src}" && cp -R "${ROOT}/charts/${chart}" "${src}"
  if ! fetch_deps "${src}" 2> "${tmp}/err"; then
    fail render "${chart}: dependencies: $(tr '\n' ' ' < "${tmp}/err")"
    continue
  fi
  for i in 1 2; do
    [[ "${i}" == 1 || "${determinism}" == true ]] || break
    if ! "${HELM}" template "${release}" "${src}" --namespace "${ns}" --include-crds \
        --kube-version "${KUBE_VERSION}" > "${tmp}/out/${chart}.${i}.yaml" 2> "${tmp}/err"; then
      fail render "${chart}: $(tr '\n' ' ' < "${tmp}/err")"
      continue 2
    fi
  done
  mv "${tmp}/out/${chart}.1.yaml" "${tmp}/out/${chart}.yaml"
  [[ -z "${out_dir}" ]] || cp "${tmp}/out/${chart}.yaml" "${out_dir}/${chart}.yaml"
  printf '%s\t%s\n' "${release}" "${ns}" > "${tmp}/out/${chart}.release"
  rendered+=("${chart}")
  pass render "${chart} (release ${release}, namespace ${ns})"
done
[[ -z "${out_dir}" ]] || cp "${tmp}/out/app-of-apps.yaml" "${out_dir}/app-of-apps.yaml"

# JSON documents per chart, for the checks below.
for chart in "${rendered[@]}"; do
  yq -o=json -I=0 'select(. != null)' "${tmp}/out/${chart}.yaml" | jq -s . > "${tmp}/out/${chart}.json"
done

# Cluster-scoped kinds: built-ins plus the rendered CRDs with scope Cluster.
{
  printf '%s\n' "${CLUSTER_KINDS[@]}"
  for chart in "${rendered[@]}"; do
    jq -r '.[] | select(.kind == "CustomResourceDefinition" and .spec.scope == "Cluster")
      | "\(.spec.group)/\(.spec.names.kind)"' "${tmp}/out/${chart}.json"
  done
} | sort -u | jq -R . | jq -s . > "${tmp}/cluster-kinds.json"

for chart in "${rendered[@]}"; do
  docs="${tmp}/out/${chart}.json"

  # --- crds --------------------------------------------------------------------
  bad="$(jq -r '[.[] | select(.kind == "CustomResourceDefinition")
      | select((.metadata.annotations["argocd.argoproj.io/sync-options"] // "") as $o
        | ($o | split(",") | index("Prune=false")) and ($o | split(",") | index("Delete=false")) | not)
      | .metadata.name] | join(", ")' "${docs}")"
  n="$(jq '[.[] | select(.kind == "CustomResourceDefinition")] | length' "${docs}")"
  if [[ -n "${bad}" ]]; then fail crds "${chart}: not annotated Prune=false,Delete=false: ${bad}"
  elif [[ "${n}" -gt 0 ]]; then pass crds "${chart}: ${n} CRDs protected"; fi

  # --- credentials (rendered) --------------------------------------------------
  # Secret values equal to a known literal; any other string containing one.
  while IFS=$'\t' read -r where key; do
    if printf '%s\n' "${CREDENTIAL_ALLOW[@]}" | grep -qx "${key}"; then
      warn credentials "${chart}: ${where} is a chart-default credential (not settable from a Secret)"
    else
      fail credentials "${chart}: ${where} holds a known literal credential"
    fi
  done < <(jq -r --arg re "${CREDENTIAL_RE}" '.[] | select(.kind == "Secret") as $s
      | (($s.data // {}) | to_entries | map(.value |= (@base64d? // ""))) + (($s.stringData // {}) | to_entries)
      | .[] | select(.value | type == "string" and test("^(" + $re + ")$"; "i"))
      | ["Secret \($s.metadata.name) key \(.key)", "\($s.metadata.name)/\(.key)"] | @tsv' "${docs}")
  while IFS= read -r where; do
    fail credentials "${chart}: ${where}"
  done < <(jq -r --arg re "${CREDENTIAL_RE}" '.[] | select(.kind != "Secret") as $d
      | [paths(strings) as $p | select($d | getpath($p) | test($re; "i")) | $p | map(tostring) | join(".")]
      | select(length > 0) | "\($d.kind) \($d.metadata.name): known literal credential at \(join(", "))"' "${docs}")

  # --- node-ip -----------------------------------------------------------------
  if grep -nE '(^|[^0-9.])192\.168\.[0-9]{1,3}\.[0-9]{1,3}' "${tmp}/out/${chart}.yaml" > "${tmp}/ip"; then
    fail node-ip "${chart}: renders a 192.168.x.x address (line $(cut -d: -f1 "${tmp}/ip" | head -3 | paste -sd, -))"
  fi

  # --- secrets (one-shot tiers) ---------------------------------------------------
  if printf '%s\n' "${ONESHOT_TIERS[@]}" | grep -qx "${chart}"; then
    s="$(jq -r '[.[] | select(.kind == "Secret" and (((.data // {}) + (.stringData // {})) | length) > 0)
        | "\(.metadata.name)[\((.data // {}) + (.stringData // {}) | keys | join(","))]"] | join(" ")' "${docs}")"
    [[ -z "${s}" ]] || info secrets "${chart} (one-shot tier) renders Secrets with data: ${s}"
  fi
done

# --- credentials (sources) -------------------------------------------------------
while IFS= read -r hit; do
  fail credentials "source ${hit#"${ROOT}/"}"
done < <(grep -rniE --include='*.yaml' --include='*.yml' --include='*.tpl' --include='*.sh' \
           --include='*.json' --include='*.config' --exclude-dir=charts --exclude-dir=crds \
           "${CREDENTIAL_RE}" "${ROOT}"/charts/*/values.yaml "${ROOT}"/charts/*/templates \
           "${ROOT}"/charts/*/files 2>/dev/null | cut -c1-200 || true)

# --- project ----------------------------------------------------------------------
if [[ -n "${project_name}" ]]; then
  for chart in "${rendered[@]}"; do
    [[ "${chart}" != "app-of-apps" && -f "${tmp}/out/${chart}.release" ]] || continue
    read -r release ns < "${tmp}/out/${chart}.release"
    app="$(jq -c --arg n "${release}" '[.[] | select(.name == $n)][0].app' "${tmp}/apps.json")"
    [[ "${app}" != "null" ]] || continue
    problems="$(jq -r --argjson app "${app}" --slurpfile proj "${tmp}/project.json" \
        --slurpfile ck "${tmp}/cluster-kinds.json" '
      $proj[0].spec as $p | $ck[0] as $cluster
      | def gmatch($pat; $v): ($pat == "*") or ($pat == $v);
        def group: (.apiVersion | split("/") | if length > 1 then .[0] else "" end);
      [ (if ($p.sourceRepos // []) | map(. == "*" or . == $app.spec.source.repoURL) | any then empty
          else "source \($app.spec.source.repoURL) not in sourceRepos" end),
        (.[] | (group + "/" + .kind) as $gk
          | if ($cluster | index($gk)) then
              (if ($p.clusterResourceWhitelist // []) | map(gmatch(.group; ($gk | split("/")[0])) and gmatch(.kind; ($gk | split("/")[1]))) | any
               then empty else "cluster-scoped \($gk) \(.metadata.name) not in clusterResourceWhitelist" end)
            else
              ((.metadata.namespace // $app.spec.destination.namespace) as $ns
               | if ($p.destinations // []) | map(gmatch(.namespace; $ns)) | any
                 then empty else "\(.kind) \(.metadata.name) in namespace \($ns) not in destinations" end)
            end)
      ] | unique | join("; ")' "${tmp}/out/${chart}.json")"
    if [[ -n "${problems}" ]]; then fail project "${chart}: ${problems}"; else pass project "${chart}"; fi
  done
fi

# --- release policy checks (r5, app-of-apps 0.0.5) -----------------------------
# policy_checks DIR APPS: the checks below on DIR/<chart>.json (one JSON array
# of documents per rendered chart) and APPS (apps.json). They only read their
# inputs, so --self-test can run them on mutated copies of the renders.

# K5 for Teknoir images: <repo>:<immutable tag>@sha256:<amd64 manifest digest>.
K5_TAG_RE='^(sha-[0-9a-f]{7,}|.+-[0-9]{8}-[0-9]{6}|v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?)$'

# THE placeholder allowance (r5): image refs that render.sh accepts with a WARN
# instead of a FAIL while their images are not built yet. CI builds them from
# r5-user-controller, r5-profile-controller and r5-backstage (with
# r5-backstage-perm: SEC-C11); the pin commit replaces the refs in the charts
# and empties this list. An entry that is no longer rendered FAILs, so the
# list cannot outlive the pins. --strict-pins ignores the list (bundle build).
PENDING_IMAGE_PINS=(
)

# Roles allowed a '*' in apiGroups, resources, verbs or nonResourceURLs
# ("<chart>:<Kind>/<name>"), with the reason. Everything else FAILs (SEC-C6).
RBAC_WILDCARD_ALLOW=(
  "argo:ClusterRole/argo-argocd-application-controller"   # ArgoCD applies every platform resource
  "argo:ClusterRole/argo-argocd-server"                   # upstream argo-cd: get/patch/delete on any resource (UI resource actions)
  "monitoring:ClusterRole/monitoring-operator"            # kube-prometheus-stack operator: '*' on its CRDs, StatefulSets, ConfigMaps, Secrets
  "istio:ClusterRole/istiod-clusterrole-istio-system"     # upstream istiod: read-only on the Istio/Gateway API groups, ingresses/status
  "istio:ClusterRole/istio-reader-clusterrole-istio-system" # upstream istio-reader: read-only on the Istio API groups
  "device-controller:ClusterRole/device-controller-manager-role"   # '*' verbs on its own CRDs and Services only
  "devstudio-controller:ClusterRole/devstudio-controller-role"      # '*' verbs on its own CRDs, StatefulSets, Services, VirtualServices only
  "notebook-controller:ClusterRole/notebook-controller-role"        # '*' verbs on its own CRDs, StatefulSets, Services, VirtualServices only
)

GATEWAY_PRINCIPAL="cluster.local/ns/istio-system/sa/istio-ingressgateway"

policy_checks() {
  local dir="$1" apps="$2" chart docs line

  # --- ignore-names (HYG-C1) ------------------------------------------------------
  # Every named ignoreDifferences rule matches a resource the chart renders;
  # a stale name silently stops ignoring (e.g. monitoring-kube-prome-admission).
  while IFS= read -r line; do
    chart="$(jq -r .chart <<<"${line}")"
    [[ -f "${dir}/${chart}.json" ]] || continue
    if jq -e --argjson r "$(jq -c .rule <<<"${line}")" 'map(select(
          (.apiVersion | split("/") | if length > 1 then .[0] else "" end) == ($r.group // "")
          and .kind == $r.kind and .metadata.name == $r.name
          and (($r.namespace // null) == null or (.metadata.namespace // "") == $r.namespace))) | length > 0' \
        "${dir}/${chart}.json" >/dev/null; then
      pass ignore-names "$(jq -r '"\(.app): \(.rule.kind) \(.rule.name)"' <<<"${line}")"
    else
      fail ignore-names "$(jq -r '"\(.app): ignoreDifferences names \(.rule.group // "")/\(.rule.kind) \(.rule.name), which chart \(.chart) does not render"' <<<"${line}")"
    fi
  done < <(jq -c '.[] | .name as $app | .chart as $chart
      | (.app.spec.ignoreDifferences // [])[] | select(.name != null) | {app: $app, chart: $chart, rule: .}' "${apps}")

  # --- images (HYG-C10, G-09) -----------------------------------------------------
  local pending_json='[]' seen_pending="${dir}/.pending-seen"
  : > "${seen_pending}"
  if [[ "${strict_pins}" != true ]]; then
    pending_json="$(printf '%s\n' "${PENDING_IMAGE_PINS[@]}" | jq -R . | jq -s .)"
  fi
  for chart in "${rendered[@]}"; do
    docs="${dir}/${chart}.json"
    [[ -f "${docs}" ]] || continue
    local oneshot=false
    printf '%s\n' "${ONESHOT_TIERS[@]}" | grep -qx "${chart}" && oneshot=true
    while IFS=$'\t' read -r verdict image detail; do
      case "${verdict}" in
        fail) fail images "${chart}: ${image}: ${detail}" ;;
        warn) warn images "${chart}: ${image}: ${detail}" ;;
        pending) warn images "${chart}: ${image}: placeholder accepted by PENDING_IMAGE_PINS (remove with the pin commit)"
                 printf '%s\n' "${image}" >> "${seen_pending}" ;;
        info) info images "${chart}: ${image}: ${detail}" ;;
        ok) pass images "${chart}: ${image}" ;;
      esac
    done < <(jq -r --arg k5 "${K5_TAG_RE}" --argjson pending "${pending_json}" --argjson oneshot "${oneshot}" '
        [.. | objects | select(has("image") and (.image | type == "string"))
            | {image, policy: (.imagePullPolicy // "")}] | unique | .[]
        | .image as $i | .policy as $pp
        | ($i | split("@")) as $parts | $parts[0] as $ref | ($parts[1] // "") as $digest
        | ($ref | split("/") | last) as $last
        | (if ($last | contains(":")) then ($last | split(":") | last) else "" end) as $tag
        | ($i | test("(^|/)teknoir/")) as $teknoir
        | if $oneshot and $digest != "" then ["fail", $i, "digest in a one-shot tier (the bootstrap applies these tag-only)"]
          elif $teknoir then
            ( [ (if ($digest | test("^sha256:[0-9a-f]{64}$")) and ($digest | test("^sha256:0{64}$") | not) then empty else "no linux/amd64 manifest digest" end),
                (if ($tag | test($k5)) then empty else "tag \"\($tag)\" is not immutable (sha-<hex>, <branch>-YYYYMMDD-HHMMSS or semver)" end),
                (if $pp == "Always" or $pp == "Never" then "imagePullPolicy \($pp), not IfNotPresent" else empty end) ]
              | if length == 0 then ["ok", $i, ""]
                elif ($pending | index($i)) then ["pending", $i, join("; ")]
                else ["fail", $i, "not a K5 pin: " + join("; ")] end )
          elif $i == "auto" then ["info", $i, "istio injection template (the injector sets the image)"]
          elif $digest == "" and ($tag == "" or $tag == "latest") then ["warn", $i, "latest tag"]
          elif $digest == "" and ($tag | test("^v?[0-9]+(-[0-9A-Za-z]+)*$")) then ["warn", $i, "major-only tag"]
          elif $pp == "Always" then ["warn", $i, "imagePullPolicy Always"]
          else empty end
        | @tsv' "${docs}")
  done
  if [[ "${strict_pins}" != true && "${#rendered[@]}" -ge "${#all_charts[@]}" ]]; then
    local p
    for p in "${PENDING_IMAGE_PINS[@]}"; do
      grep -qxF "${p}" "${seen_pending}" ||
        fail images "PENDING_IMAGE_PINS lists ${p}, which no chart renders any more: remove it"
    done
  fi

  # --- rbac (SEC-C6) ------------------------------------------------------------------
  local allow_json
  allow_json="$(printf '%s\n' "${RBAC_WILDCARD_ALLOW[@]}" | jq -R . | jq -s .)"
  for chart in "${rendered[@]}"; do
    docs="${dir}/${chart}.json"
    [[ -f "${docs}" ]] || continue
    local rbac_bad=0
    while IFS=$'\t' read -r verdict msg; do
      case "${verdict}" in
        fail) fail rbac "${chart}: ${msg}"; rbac_bad=1 ;;
        info) info rbac "${chart}: ${msg}" ;;
      esac
    done < <(jq -r --arg chart "${chart}" --argjson allow "${allow_json}" '
        (.[] | select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
          | select(.roleRef.name == "cluster-admin")
          | ["fail", "\(.kind) \(.metadata.name) binds cluster-admin"]),
        (.[] | select(.kind == "ClusterRole" or .kind == "Role") | . as $r
          | ("\($chart):\(.kind)/\(.metadata.name)") as $id
          | [(.rules // [])[] | select([(.apiGroups // []), (.resources // []), (.verbs // []), (.nonResourceURLs // [])]
                                      | map(index("*") != null) | any)] as $wild
          | select($wild | length > 0)
          | if ($allow | index($id)) then ["info", "\($r.kind) \($r.metadata.name): wildcard rules allowed (RBAC_WILDCARD_ALLOW)"]
            else ["fail", "\($r.kind) \($r.metadata.name) has a '"'"'*'"'"' rule outside RBAC_WILDCARD_ALLOW: \($wild | map(tojson) | join(" "))"] end)
        | @tsv' "${docs}")
    [[ "${rbac_bad}" -ne 0 ]] || pass rbac "${chart}: no cluster-admin binding, no wildcard rule outside RBAC_WILDCARD_ALLOW"
  done

  # --- profiles (TS-C2, K3) -------------------------------------------------------------
  for chart in "${rendered[@]}"; do
    docs="${dir}/${chart}.json"
    [[ -f "${docs}" ]] || continue
    local n_prof repo want
    n_prof="$(jq '[.[] | select(.kind == "Profile" and (.apiVersion | startswith("teknoir.org/")))] | length' "${docs}")"
    [[ "${n_prof}" -gt 0 ]] || continue
    while IFS=$'\t' read -r name problems; do
      if [[ -n "${problems}" ]]; then fail profiles "${chart}: Profile ${name}: ${problems}"
      else pass profiles "${chart}: Profile ${name}"; fi
    done < <(jq -r '.[] | select(.kind == "Profile" and (.apiVersion | startswith("teknoir.org/")))
        | ((.metadata.annotations // {})["argocd.argoproj.io/sync-options"] // "" | split(",")) as $o
        | [.metadata.name, ([
            (if ($o | index("Prune=false")) and ($o | index("Delete=false")) then empty else "not annotated Prune=false,Delete=false" end),
            (if ((.spec.owner | if type == "object" then .name else . end) // "") | length > 0 then empty else "empty owner" end),
            (if .spec.plugins != null then "declares spec.plugins (ArgoCD and the controller would fight over it)" else empty end)
          ] | join("; "))] | @tsv' "${docs}")
    repo="$(jq -r '[.[] | select(.kind == "ConfigMap") | .data.PLUGIN_CHART_REPO // empty][0] // ""' "${docs}")"
    want="$(jq -r --arg c "${chart}" '[.[] | select(.chart == $c)][0].app.spec.source.repoURL // ""' "${apps}")"
    if [[ -z "${repo}" ]]; then
      fail profiles "${chart}: renders Profiles but no ConfigMap with PLUGIN_CHART_REPO"
    elif [[ "${repo}" != "${want}" ]]; then
      fail profiles "${chart}: PLUGIN_CHART_REPO ${repo} is not the app-of-apps repoURL ${want}"
    else
      pass profiles "${chart}: PLUGIN_CHART_REPO ${repo} = app-of-apps repoURL"
    fi
  done

  # --- monitoring-authz (SEC-C5) ---------------------------------------------------------
  # Grafana: no anonymous Admin (grafana.ini or GF_ env). AuthorizationPolicies
  # that apply to the monitoring stack (the monitoring chart's own, plus any
  # ALLOW without a selector in teknoir-system or the root namespace
  # istio-system, from any chart): every ALLOW rule that may admit the ingress
  # gateway (its principal, a wildcard, istio-system, a not* source or no source
  # at all) must require request.auth.claims[groups]. Namespace-only ALLOWs
  # (prometheus-allow-internal, alertmanager-allow-prometheus,
  # harbor-allow-internal) admit no gateway and need no groups condition. DENY
  # policies only take access away (the *-deny-lifecycle ones are limited to
  # operations) and are not checked here.
  if [[ -f "${dir}/monitoring.json" ]]; then
    while IFS=$'\t' read -r verdict msg; do
      case "${verdict}" in
        fail) fail monitoring-authz "${msg}" ;;
        warn) warn monitoring-authz "${msg}" ;;
        pass) pass monitoring-authz "${msg}" ;;
      esac
    done < <(jq -r '
        def truthy: (tostring | ascii_downcase) as $v | ($v == "true" or $v == "1" or $v == "t" or $v == "yes" or $v == "on");
        def ini($section; $key): (split("\n") | reduce .[] as $l ({s: "", v: null};
            ($l | gsub("^\\s+|\\s+$"; "")) as $t
            | if ($t | test("^\\[.*\\]$")) then .s = ($t | ltrimstr("[") | rtrimstr("]"))
              elif .s == $section and ($t | test("^" + $key + "\\s*=")) then .v = ($t | sub("^[^=]*=\\s*"; ""))
              else . end) | .v);
        [.[] | select(.kind == "ConfigMap" and (.data["grafana.ini"] // null) != null)] as $cms
        | [.[] | select(.kind == "Deployment") | .spec.template.spec.containers[]? | .env[]?] as $env
        | ($env | map(select(.name == "GF_AUTH_ANONYMOUS_ENABLED"))[0].value) as $env_on
        | ($env | map(select(.name == "GF_AUTH_ANONYMOUS_ORG_ROLE"))[0].value) as $env_role
        | if ($cms | length) == 0 then ["fail", "monitoring renders no grafana.ini"]
          else ($cms[] | .metadata.name as $n | .data["grafana.ini"]
            | ($env_on // ini("auth.anonymous"; "enabled") // "false") as $on
            | ($env_role // ini("auth.anonymous"; "org_role") // "Viewer") as $role
            | if ($on | truthy) and (($role | ascii_downcase) == "admin") then ["fail", "\($n): Grafana anonymous access is Admin"]
              elif ($on | truthy) then ["warn", "\($n): Grafana anonymous access is on (role \($role))"]
              else ["pass", "\($n): Grafana anonymous access is off"] end)
          end | @tsv' "${dir}/monitoring.json")
    local policies="${dir}/.policies.json"
    for chart in "${rendered[@]}"; do
      [[ -f "${dir}/${chart}.json" ]] || continue
      read -r _ ns < <(jq -r --arg c "${chart}" '[.[] | select(.chart == $c)][0] // {} | "x \(.namespace // "teknoir-system")"' "${apps}")
      jq -c --arg chart "${chart}" --arg ns "${ns}" '.[] | select(.kind == "AuthorizationPolicy")
          | {chart: $chart, ns: (.metadata.namespace // $ns), name: .metadata.name,
             action: (.spec.action // "ALLOW"), selector: (.spec.selector != null or .spec.targetRef != null or .spec.targetRefs != null),
             rules: (.spec.rules // [])}' "${dir}/${chart}.json"
    done | jq -s . > "${policies}"
    while IFS=$'\t' read -r verdict msg; do
      case "${verdict}" in
        fail) fail monitoring-authz "${msg}" ;;
        pass) pass monitoring-authz "${msg}" ;;
      esac
    done < <(jq -r --arg gw "${GATEWAY_PRINCIPAL}" '
        def maygw: (.principals // []) as $p | (.namespaces // []) as $n
          | (($p | map(. == $gw or . == "*" or startswith("cluster.local/ns/istio-system/") or (endswith("*") and ($gw | startswith(rtrimstr("*")))) or (startswith("*") and ($gw | endswith(ltrimstr("*"))))) | any)
             or ($n | map(. == "istio-system" or . == "*" or (endswith("*") and ("istio-system" | startswith(rtrimstr("*"))))) | any)
             or ((($p | length) == 0) and (($n | length) == 0)));
        def grouped: [(.when // [])[] | select(.key == "request.auth.claims[groups]" and ((.values // []) | length > 0) and ((.values // []) | index("*") | not))] | length > 0;
        .[] | select(.action == "ALLOW")
        | select(.chart == "monitoring" or ((.selector | not) and (.ns == "teknoir-system" or .ns == "istio-system")))
        | . as $pol
        | if (.rules | length) == 0 then ["pass", "\(.chart) \(.name): ALLOW with no rules admits nothing"]
          else
            ([.rules | to_entries[] | .key as $i | .value
              | select(((.from // []) | length) == 0 or ((.from // []) | map(.source | maygw) | any))
              | select(grouped | not) | $i] ) as $bad
            | ([.rules[] | select(((.from // []) | length) > 0 and ((.from // []) | map(.source | maygw) | any | not))] | length) as $nsonly
            | if ($bad | length) > 0 then ["fail", "\($pol.chart) \($pol.name) (\($pol.ns)): ALLOW rule(s) \($bad | map(tostring) | join(",")) may admit the ingress gateway without a request.auth.claims[groups] condition"]
              elif $nsonly == (.rules | length) then ["pass", "\($pol.chart) \($pol.name): namespace-only ALLOW (admits no gateway)"]
              else ["pass", "\($pol.chart) \($pol.name): gateway ALLOW requires the groups claim"] end
          end | @tsv' "${policies}")
  fi

  # --- routes (SIGN-C1): /oauth2 reaches oauth2-proxy on every authenticated host ------
  # The oauth2-proxy VirtualService routes prefix /oauth2 to oauth2-proxy, and
  # no other VirtualService on the same gateway and an overlapping host has a
  # non-catch-all route that would take /oauth2/start, /oauth2/callback or
  # /oauth2/sign_out first (Istio moves catch-all routes behind the others
  # when it merges a host's VirtualServices).
  local vs="${dir}/.vs.json"
  for chart in "${rendered[@]}"; do
    [[ -f "${dir}/${chart}.json" ]] || continue
    jq -c --arg chart "${chart}" '.[] | select(.kind == "VirtualService") | {chart: $chart, name: .metadata.name,
        gateways: (.spec.gateways // []), hosts: (.spec.hosts // []), http: (.spec.http // [])}' "${dir}/${chart}.json"
  done | jq -s . > "${vs}"
  if [[ -f "${dir}/auth.json" ]]; then
    while IFS=$'\t' read -r verdict msg; do
      case "${verdict}" in
        fail) fail routes "${msg}" ;;
        pass) pass routes "${msg}" ;;
      esac
    done < <(jq -r '
        def isproxy: (.destination.host // "") | startswith("oauth2-proxy.");
        def uri_matches($path): (.uri // {}) as $u
          | if $u.prefix then ($path | startswith($u.prefix))
            elif $u.exact then $path == $u.exact
            elif $u.regex then ($path | test("^(?:" + $u.regex + ")$"))
            else true end;
        def catchall: ((.match // []) | length == 0)
          or ((.match // []) | map(((keys - ["uri", "name"]) | length == 0) and ((.uri // {}) as $u
               | ($u == {} or $u.prefix == "/" or $u.regex == "*" or $u.regex == ".*"))) | any);
        def overlap($a; $b): $a == $b or $a == "*" or $b == "*"
          or ($a | startswith("*.") and ($b | endswith($a[1:])))
          or ($b | startswith("*.") and ($a | endswith($b[1:])));
        ["/oauth2/start", "/oauth2/callback", "/oauth2/sign_out"] as $paths
        | [.[] | select(any(.http[]; ((.match // []) | map((.uri.prefix // "") == "/oauth2") | any) and ((.route // []) | map(isproxy) | any)))] as $proxy
        | if ($proxy | length) == 0 then ["fail", "no VirtualService routes prefix /oauth2 to oauth2-proxy"]
          else
            ($proxy[0]) as $p
            | ["pass", "\($p.chart) \($p.name) routes /oauth2 to oauth2-proxy for \($p.hosts | join(", "))"],
              (.[] | select(.name != $p.name or .chart != $p.chart) | . as $v
               | select(any($v.gateways[]; . as $g | $p.gateways | index($g)))
               | select(any($v.hosts[]; . as $h | any($p.hosts[]; overlap(.; $h))))
               | .http[] | select(catchall | not) | . as $r
               | select(any((.match // [])[]; . as $m | any($paths[]; . as $path | $m | uri_matches($path))))
               | select((((.route // []) | length > 0) and ((.route // []) | map(isproxy) | all)) | not)
               | ["fail", "\($v.chart) \($v.name): route \($r.name // "(unnamed)") takes an /oauth2 path on a host oauth2-proxy serves (\($v.hosts | join(", ")))"])
          end | @tsv' "${vs}")
  fi

  # --- auth-filters (SIGN-C2) -----------------------------------------------------------
  # The ext_authz EnvoyFilter: every HTTP_FILTER patch is limited to the TLS
  # listener (portNumber 443), and authz_ok is INSERT_AFTER ext_authz.
  if [[ -f "${dir}/auth.json" ]]; then
    while IFS=$'\t' read -r verdict msg; do
      case "${verdict}" in
        fail) fail auth-filters "${msg}" ;;
        pass) pass auth-filters "${msg}" ;;
      esac
    done < <(jq -r '
        [.[] | select(.kind == "EnvoyFilter" and any(.spec.configPatches[]?; .patch.value.name == "envoy.filters.http.ext_authz"))] as $f
        | if ($f | length) == 0 then ["fail", "auth renders no ext_authz EnvoyFilter"]
          else $f[] | .metadata.name as $n
            | [.spec.configPatches[] | select(.applyTo == "HTTP_FILTER")] as $hp
            | ([$hp[] | select(.match.listener.portNumber != 443)] | length) as $noport
            | ([$hp[] | select(.patch.value.name == "envoy.filters.http.lua.authz_ok")]) as $ok
            | (if ($hp | length) < 3 then ["fail", "\($n): \($hp | length) HTTP_FILTER patches, expected ext_authz, the redirect Lua and authz_ok"] else empty end),
              (if $noport > 0 then ["fail", "\($n): \($noport) HTTP_FILTER patch(es) without listener portNumber 443"]
               else ["pass", "\($n): all \($hp | length) HTTP_FILTER patches match portNumber 443"] end),
              (if ($ok | length) == 1 and $ok[0].patch.operation == "INSERT_AFTER"
                    and $ok[0].match.listener.filterChain.filter.subFilter.name == "envoy.filters.http.ext_authz"
               then ["pass", "\($n): authz_ok is INSERT_AFTER ext_authz"]
               else ["fail", "\($n): authz_ok is not one INSERT_AFTER envoy.filters.http.ext_authz patch"] end)
          end | @tsv' "${dir}/auth.json")
  fi
}

# --- self-test: every policy check fails on a bad fixture ---------------------------
# self_test DIR APPS: runs policy_checks on mutated copies of the real renders.
# Each case names the file to mutate (a chart's JSON or apps.json), a jq
# program, and the line the checks must then print ("<VERDICT>  <check>" plus
# a fragment of the message). The unmutated renders must give no FAIL.
self_test() {
  local dir="$1" apps="$2" fx="${tmp}/fixture" out="${tmp}/selftest.out" n=0 bad=0
  local z64 a64 b64
  z64="$(printf '0%.0s' {1..64})"; a64="$(printf 'a%.0s' {1..64})"; b64="$(printf 'b%.0s' {1..64})"
  run_case() { # run_case <label> <strict> <file> <jq> <expected verdict> <check> <fragment> [pending pin]
    local label="$1" strict="$2" file="$3" prog="$4" verdict="$5" check="$6" frag="$7" pend="${8:-}"
    rm -rf "${fx}" && mkdir -p "${fx}" && cp "${dir}"/*.json "${fx}/" && cp "${apps}" "${fx}/apps.json"
    if [[ -n "${file}" ]]; then
      jq "${prog}" "${fx}/${file}" > "${fx}/${file}.new" && mv "${fx}/${file}.new" "${fx}/${file}"
    fi
    # PENDING_IMAGE_PINS is empty in a release tree: the cases that test the
    # allowance list their own placeholder (in the subshell only).
    ( fails=0 warns=0 strict_pins="${strict}"
      if [[ -n "${pend}" ]]; then PENDING_IMAGE_PINS=("${pend}"); fi
      policy_checks "${fx}" "${fx}/apps.json" ) > "${out}" 2>&1 || true
    n=$((n + 1))
    if grep -qE 'jq: error|^Error: ' "${out}"; then
      bad=$((bad + 1)); fail self-test "${label}: a check errored: $(grep -E 'jq: error|^Error: ' "${out}" | head -2 | tr '\n' ' ')"
    elif [[ "${verdict}" == NONE ]]; then
      if grep -q '^FAIL' "${out}"; then
        bad=$((bad + 1)); fail self-test "${label}: unexpected FAIL: $(grep '^FAIL' "${out}" | head -3 | tr '\n' ' ')"
      else pass self-test "${label}"; fi
    elif grep -E "^${verdict}  ${check} " "${out}" | grep -qF -- "${frag}"; then
      pass self-test "${label}"
    else
      bad=$((bad + 1)); fail self-test "${label}: expected ${verdict} ${check} '${frag}', got: $(grep -E '^(FAIL|WARN)' "${out}" | head -3 | tr '\n' ' ')"
    fi
  }
  run_case "the integrated renders pass every policy check" false "" "" NONE "" ""
  run_case "ignore-names: the pre-0.0.5 webhook name" false apps.json \
    'map(if .name == "monitoring" then .app.spec.ignoreDifferences |= map(if .name == "monitoring-admission" then .name = "monitoring-kube-prome-admission" else . end) else . end)' \
    FAIL ignore-names "monitoring-kube-prome-admission"
  run_case "images: a Teknoir image on :latest" false device-controller.json \
    'walk(if type == "object" and ((.image? // null) | type) == "string" and (.image | test("teknoir/device-controller")) then .image = "ghcr.io/teknoir/device-controller:latest" else . end)' \
    FAIL images "not a K5 pin"
  run_case "images: a Teknoir tag pin without a digest" false notebook-controller.json \
    'walk(if type == "object" and ((.image? // null) | type) == "string" and (.image | test("teknoir/notebook-controller")) then .image = (.image | split("@")[0]) else . end)' \
    FAIL images "no linux/amd64 manifest digest"
  run_case "images: a digest in a one-shot tier" false argo.json \
    "walk(if type == \"object\" and ((.image? // null) | type) == \"string\" and (.image | startswith(\"quay.io/argoproj/argocd:\")) then .image = (.image + \"@sha256:${a64}\") else . end)" \
    FAIL images "digest in a one-shot tier"
  run_case "images: a non-Teknoir image on :latest warns" false monitoring.json \
    'walk(if type == "object" and ((.image? // null) | type) == "string" and (.image | startswith("docker.io/grafana/grafana:")) then .image = "docker.io/grafana/grafana:latest" else . end)' \
    WARN images "latest tag"
  run_case "images: a non-Teknoir major-only tag warns" false backstage.json \
    'walk(if type == "object" and ((.image? // null) | type) == "string" and (.image | startswith("prometheuscommunity/postgres-exporter:")) then .image = "prometheuscommunity/postgres-exporter:v0" else . end)' \
    WARN images "major-only tag"
  run_case "images: imagePullPolicy Always warns" false monitoring.json \
    'walk(if type == "object" and ((.image? // null) | type) == "string" and (.image | startswith("quay.io/prometheus/node-exporter:")) then .imagePullPolicy = "Always" else . end)' \
    WARN images "imagePullPolicy Always"
  local ph="ghcr.io/teknoir/user-controller:sha-PLACEHOLDER-WP-UC@sha256:${z64}"
  local ph_prog="walk(if type == \"object\" and ((.image? // null) | type) == \"string\" and (.image | test(\"teknoir/user-controller\")) then .image = \"${ph}\" else . end)"
  run_case "images: a pending placeholder that is no longer rendered" false user-controller.json \
    "walk(if type == \"object\" and ((.image? // null) | type) == \"string\" and (.image | test(\"teknoir/user-controller\")) then .image = \"ghcr.io/teknoir/user-controller:sha-0123abcd@sha256:${b64}\" else . end)" \
    FAIL images "no chart renders any more" "${ph}"
  run_case "images: a listed placeholder is accepted with a WARN" false user-controller.json "${ph_prog}" \
    WARN images "placeholder accepted by PENDING_IMAGE_PINS" "${ph}"
  run_case "images: an unlisted placeholder fails" false user-controller.json "${ph_prog}" \
    FAIL images "sha-PLACEHOLDER-WP-UC@sha256:${z64}: not a K5 pin"
  run_case "images: --strict-pins rejects the placeholders" true user-controller.json "${ph_prog}" \
    FAIL images "sha-PLACEHOLDER-WP-UC@sha256:${z64}: not a K5 pin" "${ph}"
  run_case "rbac: a binding to cluster-admin" false user-controller.json \
    'map(if .kind == "ClusterRoleBinding" then .roleRef.name = "cluster-admin" else . end)' \
    FAIL rbac "binds cluster-admin"
  run_case "rbac: a wildcard rule outside the allowlist" false user-controller.json \
    '(map(.kind == "ClusterRole") | index(true)) as $i | .[$i].rules += [{"apiGroups": ["*"], "resources": ["*"], "verbs": ["*"]}]' \
    FAIL rbac "outside RBAC_WILDCARD_ALLOW"
  run_case "profiles: Delete=false missing" false profile-controller.json \
    'map(if .kind == "Profile" then .metadata.annotations["argocd.argoproj.io/sync-options"] = "Prune=false" else . end)' \
    FAIL profiles "not annotated Prune=false,Delete=false"
  run_case "profiles: empty owner" false profile-controller.json \
    'map(if .kind == "Profile" then .spec.owner.name = "" else . end)' \
    FAIL profiles "empty owner"
  run_case "profiles: spec.plugins in a GitOps Profile" false profile-controller.json \
    'map(if .kind == "Profile" then .spec.plugins = [{"name": "emqx"}] else . end)' \
    FAIL profiles "declares spec.plugins"
  run_case "profiles: PLUGIN_CHART_REPO is not the app-of-apps repoURL" false profile-controller.json \
    'map(if .kind == "ConfigMap" and .data.PLUGIN_CHART_REPO then .data.PLUGIN_CHART_REPO = "https://teknoir.github.io/profile-plugins-helm" else . end)' \
    FAIL profiles "is not the app-of-apps repoURL"
  run_case "monitoring-authz: Grafana anonymous Admin" false monitoring.json \
    'map(if .kind == "ConfigMap" and .data["grafana.ini"] then .data["grafana.ini"] |= sub("\\[auth.anonymous\\]\nenabled = false"; "[auth.anonymous]\nenabled = true\norg_role = Admin") else . end)' \
    FAIL monitoring-authz "anonymous access is Admin"
  run_case "monitoring-authz: Grafana anonymous Admin from GF_ env" false monitoring.json \
    'map(if .kind == "Deployment" and .metadata.name == "monitoring-grafana" then .spec.template.spec.containers[0].env += [{"name": "GF_AUTH_ANONYMOUS_ENABLED", "value": "1"}, {"name": "GF_AUTH_ANONYMOUS_ORG_ROLE", "value": "Admin"}] else . end)' \
    FAIL monitoring-authz "anonymous access is Admin"
  run_case "monitoring-authz: the gateway ALLOW without the groups claim (as before 0.0.5)" false monitoring.json \
    'map(if .kind == "AuthorizationPolicy" and .metadata.name == "grafana-allow-ingress" then del(.spec.rules[0].when) else . end)' \
    FAIL monitoring-authz "grafana-allow-ingress"
  run_case "monitoring-authz: another chart's namespace-wide ALLOW for istio-system" false harbor.json \
    '. + [{"apiVersion": "security.istio.io/v1", "kind": "AuthorizationPolicy", "metadata": {"name": "fixture-ns-wide", "namespace": "teknoir-system"}, "spec": {"rules": [{"from": [{"source": {"namespaces": ["istio-system"]}}]}]}}]' \
    FAIL monitoring-authz "fixture-ns-wide"
  run_case "monitoring-authz: a namespace-wide ALLOW rule without a source" false harbor.json \
    '. + [{"apiVersion": "security.istio.io/v1", "kind": "AuthorizationPolicy", "metadata": {"name": "fixture-no-source", "namespace": "teknoir-system"}, "spec": {"rules": [{"to": [{"operation": {"methods": ["GET"]}}]}]}}]' \
    FAIL monitoring-authz "fixture-no-source"
  run_case "monitoring-authz: an operation-limited DENY and a namespace-only ALLOW pass" false monitoring.json \
    '. + [{"apiVersion": "security.istio.io/v1", "kind": "AuthorizationPolicy", "metadata": {"name": "fixture-deny-ops", "namespace": "teknoir-system"}, "spec": {"action": "DENY", "rules": [{"to": [{"operation": {"paths": ["/x"]}}]}]}}, {"apiVersion": "security.istio.io/v1", "kind": "AuthorizationPolicy", "metadata": {"name": "fixture-ns-only", "namespace": "teknoir-system"}, "spec": {"rules": [{"from": [{"source": {"namespaces": ["teknoir-system"]}}]}]}}]' \
    NONE "" ""
  run_case "routes: another VirtualService takes /oauth2 first" false backstage.json \
    'map(if .kind == "VirtualService" and .metadata.name == "backstage" then .spec.http = [{"name": "fixture-steal", "match": [{"uri": {"prefix": "/oauth"}}], "route": [{"destination": {"host": "backstage.teknoir-system.svc.cluster.local"}}]}] + .spec.http else . end)' \
    FAIL routes "fixture-steal"
  run_case "routes: a regex route that matches /oauth2/start" false backstage.json \
    'map(if .kind == "VirtualService" and .metadata.name == "backstage" then .spec.http = [{"name": "fixture-regex", "match": [{"uri": {"regex": "(?i)/(api|oauth2)/.*"}}], "route": [{"destination": {"host": "backstage.teknoir-system.svc.cluster.local"}}]}] + .spec.http else . end)' \
    FAIL routes "fixture-regex"
  run_case "routes: no /oauth2 route to oauth2-proxy" false auth.json \
    'map(if .kind == "VirtualService" then .spec.http |= map(select(((.match // []) | map(.uri.prefix == "/oauth2") | any) | not)) else . end)' \
    FAIL routes "no VirtualService routes prefix /oauth2"
  run_case "auth-filters: a patch without portNumber 443" false auth.json \
    'map(if .kind == "EnvoyFilter" then .spec.configPatches |= (to_entries | map(if .key == 1 then del(.value.match.listener.portNumber) else . end) | map(.value)) else . end)' \
    FAIL auth-filters "without listener portNumber 443"
  run_case "auth-filters: authz_ok before ext_authz" false auth.json \
    'map(if .kind == "EnvoyFilter" then .spec.configPatches |= map(if .patch.value.name == "envoy.filters.http.lua.authz_ok" then .patch.operation = "INSERT_BEFORE" else . end) else . end)' \
    FAIL auth-filters "authz_ok is not one INSERT_AFTER"
  info self-test "${n} cases, ${bad} failed"
}

# A jq error inside a check would otherwise only skip it silently.
policy_checks "${tmp}/out" "${tmp}/apps.json" 2> "${tmp}/policy.err"
if [[ -s "${tmp}/policy.err" ]]; then
  fail policy "a policy check errored: $(head -3 "${tmp}/policy.err" | tr '\n' ' ')"
fi

# The full monitoring evaluation (N1-N4: every policy that applies to the
# monitoring workloads, the in-mesh paths the stack needs, its own self-test)
# on these renders, when every chart it reads was rendered.
if [[ -f "${tmp}/out/monitoring.yaml" ]]; then
  need="$(yq -o=json '.applications' "${ROOT}/charts/app-of-apps/values.yaml" | jq -r '
    to_entries[] | select(.value.enabled != false and (.value.namespace == "teknoir-system" or .value.namespace == "istio-system"))
    | (.value.chart // .key)')"
  missing=""
  for c in ${need}; do [[ -f "${tmp}/out/${c}.yaml" ]] || missing+=" ${c}"; done
  if [[ -n "${missing}" ]]; then
    info monitoring-authz "namespace-authz-test.sh skipped: not rendered:${missing}"
  else
    mkdir -p "${tmp}/yaml"
    for c in ${need}; do cp "${tmp}/out/${c}.yaml" "${tmp}/yaml/${c}.yaml"; done
    if "${ROOT}/charts/monitoring/tests/namespace-authz-test.sh" --renders "${tmp}/yaml" > "${tmp}/nat.out" 2>&1; then
      pass monitoring-authz "namespace-authz-test.sh --renders: $(grep -c '^PASS' "${tmp}/nat.out") PASS, 0 FAIL"
    else
      fail monitoring-authz "namespace-authz-test.sh --renders failed:"
      grep -E '^FAIL' "${tmp}/nat.out" | sed 's/^/      /' || tail -5 "${tmp}/nat.out" | sed 's/^/      /'
    fi
    while IFS= read -r l; do warn monitoring-authz "namespace-authz-test.sh: ${l#WARN  }"; done < <(grep -E '^WARN' "${tmp}/nat.out" || true)
  fi
fi

[[ "${self_test_run}" != true ]] || self_test "${tmp}/out" "${tmp}/apps.json"

# --- determinism -------------------------------------------------------------------
# Differences between two renders must all be covered by the Application's
# ignoreDifferences (hooks are not diffed by ArgoCD).
if [[ "${determinism}" == true ]]; then
  for chart in "${rendered[@]}"; do
    [[ "${chart}" != "app-of-apps" && -f "${tmp}/out/${chart}.2.yaml" ]] || continue
    read -r release ns < "${tmp}/out/${chart}.release"
    yq -o=json -I=0 'select(. != null)' "${tmp}/out/${chart}.2.yaml" | jq -s . > "${tmp}/out/${chart}.2.json"
    jq -c --slurpfile b "${tmp}/out/${chart}.2.json" '
      def key: "\(.apiVersion)|\(.kind)|\(.metadata.namespace // "")|\(.metadata.name)";
      def ishook: (.metadata.annotations // {}) | has("argocd.argoproj.io/hook") or has("helm.sh/hook");
      (map(select(ishook | not) | {key: key, value: .}) | from_entries) as $A
      | ($b[0] | map(select(ishook | not) | {key: key, value: .}) | from_entries) as $B
      | (($A | keys) + ($B | keys) | unique)[] as $k
      | if ($A[$k] == null or $B[$k] == null) then {key: $k, missing: true}
        elif $A[$k] == $B[$k] then empty
        else ($A[$k]) as $x | ($B[$k]) as $y
          | {key: $k, doc: $x,
             paths: ([($x | paths(scalars)), ($y | paths(scalars))] | unique
                     | map(select(. as $p | ($x | getpath($p)) != ($y | getpath($p)))))}
        end' "${tmp}/out/${chart}.json" > "${tmp}/diffs.jsonl"
    if [[ ! -s "${tmp}/diffs.jsonl" ]]; then
      pass determinism "${chart}"
      continue
    fi
    rules="$(jq -c --arg n "${release}" '[.[] | select(.name == $n)][0].app.spec.ignoreDifferences // []' "${tmp}/apps.json")"
    uncovered=()
    while IFS= read -r d; do
      key="$(jq -r .key <<<"${d}")"
      if [[ "$(jq -r '.missing // false' <<<"${d}")" == true ]]; then
        uncovered+=("${key}: only in one render (random name?)")
        continue
      fi
      # Paths covered by the matching rules: jsonPointers directly,
      # jqPathExpressions by evaluating path(<expr>) on the resource.
      covered="$(jq -c --argjson rules "${rules}" '.doc as $d
        | ($d.apiVersion | split("/") | if length > 1 then .[0] else "" end) as $g
        | [$rules[] | select((.group // "") == $g and .kind == $d.kind
              and ((.name // $d.metadata.name) == $d.metadata.name)
              and ((.namespace // ($d.metadata.namespace // "")) == ($d.metadata.namespace // "")))
           | .jsonPointers // [] | .[]
           | ltrimstr("/") | split("/") | map(gsub("~1"; "/") | gsub("~0"; "~")
               | if test("^[0-9]+$") then tonumber else . end)]' <<<"${d}")"
      while IFS= read -r expr; do
        [[ -n "${expr}" ]] || continue
        extra="$(jq -c "[path(.doc | ${expr})] | map(.[1:])" <<<"${d}" 2>/dev/null || echo '[]')"
        covered="$(jq -c --argjson e "${extra}" '. + $e' <<<"${covered}")"
      done < <(jq -r --argjson rules "${rules}" '.doc as $d
        | ($d.apiVersion | split("/") | if length > 1 then .[0] else "" end) as $g
        | $rules[] | select((.group // "") == $g and .kind == $d.kind
              and ((.name // $d.metadata.name) == $d.metadata.name))
        | .jqPathExpressions // [] | .[]' <<<"${d}")
      left="$(jq -r --argjson cov "${covered}" '[.paths[] as $p
          | select([$cov[] as $c | ($p[0:($c | length)] == $c)] | any | not)
          | $p | map(tostring) | join(".")] | join(", ")' <<<"${d}")"
      [[ -z "${left}" ]] || uncovered+=("${key}: ${left}")
    done < "${tmp}/diffs.jsonl"
    if [[ ${#uncovered[@]} -eq 0 ]]; then
      pass determinism "${chart}: per-render differences are all in ignoreDifferences"
    else
      for u in "${uncovered[@]}"; do
        fail determinism "${chart}: differs between renders and is not ignored: ${u}"
      done
    fi
  done
fi

echo
echo "render.sh: ${#rendered[@]} charts rendered (kube ${KUBE_VERSION}); ${fails} failed checks, ${warns} warnings"
[[ "${fails}" -eq 0 ]]
