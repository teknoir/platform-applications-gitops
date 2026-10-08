#!/usr/bin/env bash
# update-crds.sh — vendor the prometheus-operator CRDs of the pinned
# kube-prometheus-stack dependency into crds/ (connected side).
#
# The dependency's own CRDs (crds subchart, kube-prometheus-stack.crds) are
# disabled in values.yaml because their files are static and cannot carry
# argocd.argoproj.io/sync-options. This copies them from the exact chart
# version in Chart.yaml and adds Prune=false,Delete=false to each, so ArgoCD
# never deletes a CRD, and with it every ServiceMonitor, PrometheusRule, ...
# in the cluster, on a prune or a cascading delete of the Application.
#
# Run it after every kube-prometheus-stack bump: templates/crds-version-check.yaml
# fails the render while crds/ comes from another version. Idempotent: the
# output depends only on the pinned version.
#
# Usage: charts/monitoring/update-crds.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ANNOTATION="argocd.argoproj.io/sync-options: Prune=false,Delete=false"

read -r version repo < <(helm dependency list . 2>/dev/null \
  | awk '$1 == "kube-prometheus-stack" {print $2, $3; exit}')
[[ -n "${version:-}" && -n "${repo:-}" ]] \
  || { echo "kube-prometheus-stack dependency not found in Chart.yaml" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

helm pull kube-prometheus-stack --repo "${repo}" --version "${version}" \
  --untar --untardir "${tmp}"
src="${tmp}/kube-prometheus-stack/charts/crds/crds"
compgen -G "${src}/*.yaml" >/dev/null \
  || { echo "no CRDs in kube-prometheus-stack ${version} (${src#"${tmp}/"})" >&2; exit 1; }

mkdir -p "${tmp}/out"
n=0
for f in "${src}"/*.yaml; do
  name="$(basename "${f}")"
  [[ "$(grep -c '^kind: CustomResourceDefinition$' "${f}")" == "1" ]] \
    || { echo "${name}: expected exactly one CustomResourceDefinition" >&2; exit 1; }
  {
    echo "# Vendored from kube-prometheus-stack ${version} (charts/crds/crds/${name})"
    echo "# by update-crds.sh, which adds ${ANNOTATION%%:*}. Do not edit."
    # Insert the annotation as the first key of metadata.annotations.
    awk -v ann="    ${ANNOTATION}" '
      !done && prev == "metadata:" && $0 == "  annotations:" { print; print ann; done = 1; prev = $0; next }
      { print; prev = $0 }
      END { if (!done) exit 1 }' "${f}" \
      || { echo "${name}: no metadata.annotations block to extend" >&2; exit 1; }
  } > "${tmp}/out/${name}"
  n=$((n + 1))
done

rm -rf crds
mv "${tmp}/out" crds
echo "crds/: ${n} CRDs from kube-prometheus-stack ${version}"
