#!/usr/bin/env bash
# charts/argo/tests/render-test.sh — render the argo chart the way ArgoCD and
# the airgap bootstrap do (release argo, namespace teknoir-system) and check
# who gets access to Argo CD. No cluster needed. Not packaged (.helmignore
# tests/).
#
# Checks (FAIL makes the script exit 1):
#   A1  argocd-rbac-cm: no default role, Keycloak group admin is role:admin and
#       nothing else is granted, groups are read from the token
#   A2  argocd-cm: SSO requests the groups scope; the local admin stays
#       enabled (break-glass)
#
# Usage: charts/argo/tests/render-test.sh
# Environment: KUBE_VERSION (default 1.33.5), RENDER_CACHE (default
# ~/.cache/teknoir-render, shared with tests/render.sh), HELM (default helm).
# Requires helm, yq and jq.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.33.5}"
RENDER_CACHE="${RENDER_CACHE:-${HOME}/.cache/teknoir-render}"
HELM="${HELM:-helm}"

for tool in "${HELM}" yq jq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fails=0
pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; fails=$((fails + 1)); }
expect() { # expect ID WHAT HAVE WANT
  if [[ "$3" == "$4" ]]; then pass "$1" "$2"; else fail "$1" "$2: '$3', want '$4'"; fi
}

# --- render (scratch copy, dependencies from the render cache) ----------------
src="${tmp}/argo"
cp -R "${CHART}" "${src}"
rm -rf "${src}/charts" "${src}/Chart.lock" "${src}/tests"
mkdir -p "${src}/charts" "${RENDER_CACHE}"
while IFS=$'\t' read -r name version repo; do
  [[ -n "${name}" ]] || continue
  key="${RENDER_CACHE}/$(printf '%s' "${repo}" | sed 's#[^A-Za-z0-9._-]#_#g')/${name}-${version}"
  if ! compgen -G "${key}/*.tgz" >/dev/null; then
    rm -rf "${key}.tmp" && mkdir -p "${key}.tmp"
    "${HELM}" pull "${name}" --repo "${repo}" --version "${version}" -d "${key}.tmp" >/dev/null
    rm -rf "${key}" && mv "${key}.tmp" "${key}"
  fi
  cp "${key}"/*.tgz "${src}/charts/"
done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' "${src}/Chart.yaml")
"${HELM}" template argo "${src}" --namespace teknoir-system --include-crds \
  --kube-version "${KUBE_VERSION}" > "${tmp}/render.yaml"
cm() { # cm NAME KEY: a ConfigMap value ("<unset>" when missing)
  yq -r "select(.kind == \"ConfigMap\" and .metadata.name == \"$1\") | .data[\"$2\"] // \"<unset>\"" "${tmp}/render.yaml"
}

# --- A1 RBAC --------------------------------------------------------------------
expect A1 "argocd-rbac-cm policy.default (no default role)" "$(cm argocd-rbac-cm policy.default)" ""
expect A1 "argocd-rbac-cm policy.csv (group admin only)" \
  "$(cm argocd-rbac-cm policy.csv | sed '/^[[:space:]]*$/d')" "g, admin, role:admin"
expect A1 "argocd-rbac-cm scopes" "$(cm argocd-rbac-cm scopes)" "[groups]"

# --- A2 SSO and break-glass -------------------------------------------------------
expect A2 "argocd-cm admin.enabled (local admin kept as break-glass)" "$(cm argocd-cm admin.enabled)" "true"
scopes="$(cm argocd-cm oidc.config | yq -o=json -I=0 '.requestedScopes')"
if jq -e 'index("groups") != null' <<<"${scopes}" >/dev/null; then
  pass A2 "oidc.config requests the groups scope"
else
  fail A2 "oidc.config requestedScopes ${scopes} lack groups"
fi

echo
echo "render-test.sh (argo): ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
