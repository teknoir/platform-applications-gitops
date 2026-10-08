#!/usr/bin/env bash
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
#                renders (harbor's chart-internal defaults are WARN, see below)
#   node-ip      no 192.168.x.x address in a render (site config, not GitOps)
#   determinism  two renders differ only in fields the Application ignores
#                (ignoreDifferences), so selfHeal never churns
#   images       Teknoir images on a mutable tag (WARN until G-09)
#   secrets      lists the Secrets with data in the one-shot tiers (INFO)
#
# Usage: tests/render.sh [--out DIR] [--no-determinism] [CHART...]
#   CHART           chart directory names under charts/ (default: all)
#   --out DIR       write each render to DIR/<chart>.yaml
#   --no-determinism  skip the second render
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
# Rendered Secret keys that legitimately hold a chart default credential:
# Harbor chart 1.18.3 cannot take its internal database password or the
# core/jobservice -> registry credential from a Secret. Both are reachable only
# inside teknoir-system (STRICT mTLS). "<secret>/<key>" lines.
CREDENTIAL_ALLOW=(
  harbor-core/POSTGRESQL_PASSWORD
  harbor-database/POSTGRES_PASSWORD
  harbor-core/REGISTRY_CREDENTIAL_PASSWORD
  harbor-jobservice/REGISTRY_CREDENTIAL_PASSWORD
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
charts=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out_dir="$2"; shift 2 ;;
    --no-determinism) determinism=false; shift ;;
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

if [[ ${#charts[@]} -eq 0 ]]; then
  for d in "${ROOT}"/charts/*/; do
    [[ -f "${d}Chart.yaml" ]] && charts+=("$(basename "${d}")")
  done
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

  # --- images --------------------------------------------------------------------
  while IFS= read -r image; do
    tag="${image##*:}"
    if [[ "${image}" == *@sha256:* || ( "${image}" == *:* && "${tag}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.-]+)?$ ) ]]; then
      continue
    fi
    warn images "${chart}: ${image} is on a mutable tag (G-09)"
  done < <(jq -r '[.. | objects | select(has("image") and (.image | type == "string")) | .image]
      | unique | .[] | select(test("(^|/)teknoir/"))' "${docs}")

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
