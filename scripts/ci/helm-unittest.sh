#!/usr/bin/env bash
# helm unittest of every chart with tests/*_test.yaml (the chart-unittests test of charts/ci/files/repos/
# platform-applications-gitops.yaml, run by .github/workflows/ci.yml). Dependencies are built first where the
# chart has them: the monitoring tests render kube-prometheus-stack subchart templates.
#
#   scripts/ci/helm-unittest.sh        from the repository root
#
# Needs helm and the helm-unittest plugin on PATH. Exit status 1 if any chart's dependencies or tests fail;
# every chart is still tried.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

rc=0
for t in charts/*/tests; do
  ls "$t"/*_test.yaml >/dev/null 2>&1 || continue
  c=${t%/tests}
  echo "== $c"
  if grep -q '^dependencies:' "$c/Chart.yaml"; then
    helm dependency build "$c" >/dev/null || rc=1
  fi
  helm unittest "$c" || rc=1
done
exit "$rc"
