#!/usr/bin/env bash
# Runs every test of the staging release tooling:
#   - python unittest of scripts/ (pure logic, throwaway git repos, a fake cluster/GitHub/registry; no network)
#   - helm unittest of charts/app-of-apps (release helper, 19 replacements) and charts/release-guard
#   - the byte-identity check of the root render against a base ref (BASE=origin/teknoir-cloud, default)
#   - K3D=1: charts/release-guard/tests/k3d-guard-test.sh against the throwaway cluster k3d-teknoir-dev
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
cd "$REPO"

echo "== python unittest (scripts/tests)"
python3 -W ignore -m unittest discover -s scripts/tests -p 'test_*.py' 2>&1 | grep -E "^(Ran|OK|FAILED|FAIL|ERROR)" 

echo "== helm unittest"
helm unittest charts/app-of-apps charts/release-guard 2>&1 | grep -E "^(Charts|Test Suites|Tests):"

BASE="${BASE:-origin/teknoir-cloud}"
if git rev-parse --verify -q "$BASE" >/dev/null; then
  echo "== root render with release unset is byte-identical to $BASE"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  git worktree add -q --detach "$TMP/base" "$BASE"
  for p in teknoir-cloud teknoir-online teknoir-local; do
    helm template app-of-apps "$TMP/base/charts/app-of-apps" --set project="$p" > "$TMP/base-$p.yaml"
    helm template app-of-apps charts/app-of-apps --set project="$p" > "$TMP/new-$p.yaml"
    cmp "$TMP/base-$p.yaml" "$TMP/new-$p.yaml" && echo "identical: $p"
  done
  git worktree remove --force "$TMP/base"
fi

if [[ "${K3D:-}" == "1" ]]; then
  echo "== release guard on k3d-teknoir-dev"
  charts/release-guard/tests/k3d-guard-test.sh
fi
