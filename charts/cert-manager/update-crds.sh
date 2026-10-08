#!/usr/bin/env bash
# update-crds.sh — vendor the cert-manager CRDs of the pinned cert-manager
# dependency into crds/ (connected side).
#
# The cert-manager chart renders its CRDs from templates (crds.enabled) whose
# annotations cannot be set, so they could not carry
# argocd.argoproj.io/sync-options. This renders them exactly as this chart's
# Application would (release cert-manager, namespace cert-manager, so the
# labels match the live CRDs), splits them into one file per CRD and adds
# Prune=false,Delete=false to each. ArgoCD then never deletes a CRD, and with
# it every Certificate and Issuer in the cluster, on a prune or a cascading
# delete of the Application. cert-manager.crds.enabled stays false.
#
# Run it after every cert-manager bump: templates/crds-version-check.yaml fails
# the render while crds/ comes from another version. Idempotent: the output
# depends only on the pinned version.
#
# Usage: charts/cert-manager/update-crds.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ANNOTATION="argocd.argoproj.io/sync-options: Prune=false,Delete=false"
# Must equal the Application name (ArgoCD uses it as the Helm release name) and
# its destination namespace in charts/app-of-apps: the CRD labels carry them.
RELEASE="cert-manager"
NAMESPACE="cert-manager"

read -r version repo < <(helm dependency list . 2>/dev/null \
  | awk '$1 == "cert-manager" {print $2, $3; exit}')
[[ -n "${version:-}" && -n "${repo:-}" ]] \
  || { echo "cert-manager dependency not found in Chart.yaml" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Render through a copy of this chart without its templates (the version check
# would fail mid-bump) and without crds/, keeping only the CRD documents.
mkdir -p "${tmp}/chart"
cp Chart.yaml values.yaml "${tmp}/chart/"
(cd "${tmp}/chart" && helm dependency update >/dev/null)
helm template "${RELEASE}" "${tmp}/chart" --namespace "${NAMESPACE}" \
  --set cert-manager.crds.enabled=true --set cert-manager.crds.keep=true \
  > "${tmp}/render.yaml"

mkdir -p "${tmp}/out"
n="$(awk -v out="${tmp}/out" -v ann="    ${ANNOTATION}" \
  -v hdr1="# Vendored from cert-manager ${version} (release ${RELEASE}) by update-crds.sh," \
  -v hdr2="# which adds ${ANNOTATION%%:*}. Do not edit." '
  function die(msg) { print msg > "/dev/stderr"; failed = 1; exit 1 }
  function flush(   f, i) {
    if (n > 0 && crd) {
      if (name == "") die("CRD without metadata.name")
      if (!annotated) die(name ": no metadata.annotations block to extend")
      f = out "/" name ".yaml"
      print hdr1 > f
      print hdr2 > f
      for (i = 1; i <= n; i++) print buf[i] > f
      close(f)
      count++
    }
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
  END { if (failed) exit 1; flush(); print count + 0 }' "${tmp}/render.yaml")"
[[ "${n}" -gt 0 ]] || { echo "no CRDs rendered from cert-manager ${version}" >&2; exit 1; }

rm -rf crds
mv "${tmp}/out" crds
echo "crds/: ${n} CRDs from cert-manager ${version}"
