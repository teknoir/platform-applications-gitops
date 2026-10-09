# shellcheck shell=bash
# charts/monitoring/tests/lib.sh — sourced by the monitoring chart tests.
#
# chart_render_setup CHART_DIR DEST: copy a chart to DEST with its
# dependencies from the render cache (same layout as tests/render.sh, pulled
# when missing), so the working tree is never touched.
#
# monitoring_render_setup DIR: chart_render_setup for this chart into
# DIR/monitoring. Defines render [ARGS...] (helm template as ArgoCD runs it:
# release monitoring, namespace teknoir-system).
# Environment: KUBE_VERSION (default 1.33.5), RENDER_CACHE (default
# ~/.cache/teknoir-render), HELM (default helm).

MONITORING_CHART="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.33.5}"
RENDER_CACHE="${RENDER_CACHE:-${HOME}/.cache/teknoir-render}"
HELM="${HELM:-helm}"

chart_render_setup() {
  local chart="$1" dest="$2" name version repo key
  cp -R "${chart}" "${dest}"
  rm -rf "${dest}/charts" "${dest}/Chart.lock" "${dest}/tests"
  mkdir -p "${dest}/charts" "${RENDER_CACHE}"
  while IFS=$'\t' read -r name version repo; do
    [[ -n "${name}" ]] || continue
    key="${RENDER_CACHE}/$(printf '%s' "${repo}" | sed 's#[^A-Za-z0-9._-]#_#g')/${name}-${version}"
    if ! compgen -G "${key}/*.tgz" >/dev/null; then
      rm -rf "${key}.tmp" && mkdir -p "${key}.tmp"
      "${HELM}" pull "${name}" --repo "${repo}" --version "${version}" -d "${key}.tmp" >/dev/null
      rm -rf "${key}" && mv "${key}.tmp" "${key}"
    fi
    cp "${key}"/*.tgz "${dest}/charts/"
  done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' "${dest}/Chart.yaml")
}

monitoring_render_setup() {
  MONITORING_SRC="$1/monitoring"
  chart_render_setup "${MONITORING_CHART}" "${MONITORING_SRC}"
}

render() {
  "${HELM}" template monitoring "${MONITORING_SRC}" --namespace teknoir-system \
    --kube-version "${KUBE_VERSION}" "$@"
}
