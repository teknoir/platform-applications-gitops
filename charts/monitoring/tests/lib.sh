# shellcheck shell=bash
# charts/monitoring/tests/lib.sh — sourced by the monitoring chart tests.
#
# monitoring_render_setup DIR: copy the chart to DIR/monitoring with its
# dependencies from the render cache (same layout as tests/render.sh, pulled
# when missing), so the working tree is never touched. Defines render [ARGS...]
# (helm template as ArgoCD runs it: release monitoring, namespace
# teknoir-system).
# Environment: KUBE_VERSION (default 1.33.5), RENDER_CACHE (default
# ~/.cache/teknoir-render), HELM (default helm).

MONITORING_CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.33.5}"
RENDER_CACHE="${RENDER_CACHE:-${HOME}/.cache/teknoir-render}"
HELM="${HELM:-helm}"

monitoring_render_setup() {
  local name version repo key
  MONITORING_SRC="$1/monitoring"
  cp -R "${MONITORING_CHART}" "${MONITORING_SRC}"
  rm -rf "${MONITORING_SRC}/charts" "${MONITORING_SRC}/Chart.lock" "${MONITORING_SRC}/tests"
  mkdir -p "${MONITORING_SRC}/charts" "${RENDER_CACHE}"
  while IFS=$'\t' read -r name version repo; do
    [[ -n "${name}" ]] || continue
    key="${RENDER_CACHE}/$(printf '%s' "${repo}" | sed 's#[^A-Za-z0-9._-]#_#g')/${name}-${version}"
    if ! compgen -G "${key}/*.tgz" >/dev/null; then
      rm -rf "${key}.tmp" && mkdir -p "${key}.tmp"
      "${HELM}" pull "${name}" --repo "${repo}" --version "${version}" -d "${key}.tmp" >/dev/null
      rm -rf "${key}" && mv "${key}.tmp" "${key}"
    fi
    cp "${key}"/*.tgz "${MONITORING_SRC}/charts/"
  done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' "${MONITORING_SRC}/Chart.yaml")
}

render() {
  "${HELM}" template monitoring "${MONITORING_SRC}" --namespace teknoir-system \
    --kube-version "${KUBE_VERSION}" "$@"
}
