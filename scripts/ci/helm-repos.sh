#!/usr/bin/env bash
# Add every Helm repository this repository uses to the local helm config, so a fresh runner can build chart
# dependencies, render and run the chart tests (.github/workflows/ci.yml: the render, helm-unittest and
# scripts-tests jobs call this before their helm steps).
#
#   scripts/ci/helm-repos.sh        from the repository root
#
# Sources (https:// only, de-duplicated):
#   charts/*/Chart.yaml    dependencies[].repository (a commented-out line never counts)
#   charts/*/Chart.lock    dependencies[].repository
#   plugins/charts/*/      the same two, for a profile plugin chart whose dependency is not vendored: a chart whose
#                          Chart.lock archives are all committed under its charts/ directory (the emqx 5.8.9 of
#                          profile-plugin-emqx, plugins/charts/README.md) needs no repository at all, so nothing
#                          is added for it and a render stays offline
#   charts/app-of-apps/templates/*.yaml
#                          the repoURL of a child Application that pulls a Helm chart (a `chart:` field next to
#                          it). The templates are not valid YAML before rendering, so this is a line regex.
#
# Each repository is added once, as repo1, repo2, ... (--force-update makes a re-run harmless), then
# `helm repo update`. Needs helm; no python.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# vendored: Chart.lock exists and every dependency archive it names is committed under charts/. helm dependency
# build reports such a dependency ok and never fetches it, so its repository would only be a network dependency.
vendored() { # chart-dir
  local name version n=0
  [[ -f "$1/Chart.lock" ]] || return 1
  while read -r name version; do
    n=$((n + 1))
    [[ -f "$1/charts/$name-$version.tgz" ]] || return 1
  done < <(awk '/^- name:/ { n = $3 } /^  version:/ { print n, $2 }' "$1/Chart.lock")
  ((n > 0))
}

sources=(charts/*/Chart.yaml charts/*/Chart.lock)
for d in plugins/charts/*/; do
  d=${d%/}
  [[ -f "$d/Chart.yaml" ]] || continue
  grep -q '^dependencies:' "$d/Chart.yaml" || continue
  if vendored "$d"; then
    echo "helm-repos: vendored, no repository added: $d" >&2
  else
    sources+=("$d/Chart.yaml")
    if [[ -f "$d/Chart.lock" ]]; then sources+=("$d/Chart.lock"); fi
  fi
done

repos=$(
  {
    awk '$1 == "repository:" && $2 ~ /^"?https:\/\// { gsub(/"/, "", $2); print $2 }' "${sources[@]}"
    awk '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (line[i] !~ /^[[:space:]]*repoURL:[[:space:]]*"?https:\/\//) continue
          helmchart = 0
          for (j = i - 4; j <= i + 4; j++)
            if (j >= 1 && j <= NR && line[j] ~ /^[[:space:]]*chart:[[:space:]]/) helmchart = 1
          if (!helmchart) continue
          u = line[i]
          sub(/^[[:space:]]*repoURL:[[:space:]]*/, "", u)
          gsub(/"/, "", u)
          sub(/[[:space:]]+$/, "", u)
          print u
        }
      }' charts/app-of-apps/templates/*.yaml
  } | grep -v '^https://github.com/teknoir/platform-applications-gitops$' | sort -u || true
)

if [[ -z "$repos" ]]; then
  echo "helm-repos: no Helm repository found" >&2
  exit 1
fi

n=0
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  n=$((n + 1))
  echo "helm-repos: repo$n = $url"
  helm repo add --force-update "repo$n" "$url"
done <<<"$repos"

helm repo update
