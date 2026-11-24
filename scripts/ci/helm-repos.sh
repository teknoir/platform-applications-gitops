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
#   charts/app-of-apps/templates/*.yaml
#                          the repoURL of a child Application that pulls a Helm chart (a `chart:` field next to
#                          it). The templates are not valid YAML before rendering, so this is a line regex.
#
# Each repository is added once, as repo1, repo2, ... (--force-update makes a re-run harmless), then
# `helm repo update`. Needs helm; no python.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

repos=$(
  {
    awk '$1 == "repository:" && $2 ~ /^"?https:\/\// { gsub(/"/, "", $2); print $2 }' charts/*/Chart.yaml charts/*/Chart.lock
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
