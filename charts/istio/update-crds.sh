#!/usr/bin/env bash
# update-crds.sh — vendor the istio CRDs of the pinned istio-base dependency
# into crds/ (connected side).
#
# The istio base chart renders its CRDs from a template whose annotations
# cannot be set, so they could not carry argocd.argoproj.io/sync-options.
# This renders that template exactly as this chart's Application does (release
# "istio", namespace istio-system, so the labels match the live CRDs), splits it
# into one file per CRD and adds Prune=false,Delete=false to each. ArgoCD then
# never deletes a CRD, and with it every VirtualService, Gateway,
# AuthorizationPolicy, ... in the cluster, on a prune or a cascading delete of
# the Application.
#
# It also regenerates the istio-base.base.excludedCRDs list in values.yaml
# (between the BEGIN/END markers) from the vendored names, so the base
# template renders none of them and no CRD is ever rendered twice.
#
# Run it after every istio bump: templates/crds-version-check.yaml fails the
# render while crds/ or excludedCRDs come from another version. Idempotent: the
# output depends only on the pinned version.
#
# Usage: charts/istio/update-crds.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ANNOTATION="argocd.argoproj.io/sync-options: Prune=false,Delete=false"
# Must equal the Application name (ArgoCD uses it as the Helm release name) and
# its destination namespace in charts/app-of-apps: the CRD labels carry them.
RELEASE="istio"
NAMESPACE="istio-system"

read -r version repo < <(helm dependency list . 2>/dev/null \
  | awk '$1 == "base" {print $2, $3; exit}')
[[ -n "${version:-}" && -n "${repo:-}" ]] \
  || { echo "istio base dependency not found in Chart.yaml" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Render the base subchart's CRD template through a copy of this chart without
# its templates (the version check would fail mid-bump) and without crds/.
mkdir -p "${tmp}/chart"
cp Chart.yaml values.yaml "${tmp}/chart/"
(cd "${tmp}/chart" && helm dependency update >/dev/null)
helm template "${RELEASE}" "${tmp}/chart" --namespace "${NAMESPACE}" \
  --set-json 'istio-base.base.excludedCRDs=[]' \
  --show-only charts/istio-base/templates/crds.yaml > "${tmp}/crds.yaml"

mkdir -p "${tmp}/out"
n="$(awk -v out="${tmp}/out" -v ann="    ${ANNOTATION}" \
  -v hdr1="# Vendored from istio base ${version} (release ${RELEASE}) by update-crds.sh," \
  -v hdr2="# which adds ${ANNOTATION%%:*}. Do not edit." '
  function die(msg) { print msg > "/dev/stderr"; failed = 1; exit 1 }
  function flush(   f, i) {
    if (n == 0) return
    if (!crd) die("rendered a document that is not a CustomResourceDefinition")
    if (name == "") die("CRD without metadata.name")
    if (!annotated) die(name ": no metadata.annotations block to extend")
    f = out "/" name ".yaml"
    print hdr1 > f
    print hdr2 > f
    for (i = 1; i <= n; i++) print buf[i] > f
    close(f)
    count++
    n = 0; name = ""; crd = 0; annotated = 0; inmeta = 0
  }
  /^---$/ { flush(); next }
  n == 0 && (/^#/ || /^[[:space:]]*$/) { next }
  {
    buf[++n] = $0
    if ($0 == "kind: CustomResourceDefinition") crd = 1
    if ($0 == "metadata:") { inmeta = 1; next }
    if (inmeta && $0 !~ /^ /) inmeta = 0
    if (inmeta && $0 == "  annotations:") { buf[++n] = ann; annotated = 1 }
    if (inmeta && name == "" && $0 ~ /^  name: /) {
      name = $0; sub(/^  name: /, "", name); gsub(/"/, "", name)
    }
  }
  END { if (failed) exit 1; flush(); print count + 0 }' "${tmp}/crds.yaml")"
[[ "${n}" -gt 0 ]] || { echo "no CRDs rendered from istio base ${version}" >&2; exit 1; }

# Regenerate excludedCRDs from the vendored names.
{
  for f in "${tmp}"/out/*.yaml; do
    printf '      - %s\n' "$(basename "${f}" .yaml)"
  done
} > "${tmp}/excluded"
awk -v list="${tmp}/excluded" '
  /# BEGIN excludedCRDs/ { print; print "    excludedCRDs:"; while ((getline l < list) > 0) print l; skip = 1; found++; next }
  /# END excludedCRDs/ { skip = 0 }
  !skip { print }
  END { if (found != 1) exit 1 }' values.yaml > "${tmp}/values.yaml" \
  || { echo "values.yaml: expected exactly one '# BEGIN excludedCRDs' marker" >&2; exit 1; }

rm -rf crds
mv "${tmp}/out" crds
cat "${tmp}/values.yaml" > values.yaml
echo "crds/: ${n} CRDs from istio base ${version}; excludedCRDs regenerated in values.yaml"
