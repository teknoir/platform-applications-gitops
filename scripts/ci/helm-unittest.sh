#!/usr/bin/env bash
# helm unittest of every chart with tests/*_test.yaml (the helm-unittest job of .github/workflows/ci.yml), in
# charts/ and in the profile plugin tree plugins/charts/ (CI v4 P9.1): profile-controller still renders the plugin
# Applications from the published chart repository, but the imported copies must pass their own tests from day one.
# Dependencies are built only when helm dependency list reports one that is not `ok`: a fresh checkout has no
# charts/ directory, so the charts that build subcharts keep building them (the monitoring tests render
# kube-prometheus-stack templates), while a vendored dependency (emqx-5.8.9.tgz of profile-plugin-emqx) is already
# ok and needs no repository and no network.
#
# The emqx chart's MQTT ACL check (tests/acl-check.sh --check: the TeknoirBot fence and the rule order, no docker)
# runs after the loop; it is skipped, not failed, when python3 has no PyYAML.
#
#   scripts/ci/helm-unittest.sh        from the repository root
#
# Needs helm and the helm-unittest plugin on PATH. Exit status 1 if any chart's dependencies or tests fail;
# every chart is still tried. The k3d-* and *-e2e.sh scripts of the plugin tests need a cluster and never run here.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

deps_ok() { # chart: helm dependency list reports every dependency ok (nothing to build, no repository needed)
  local out
  out=$(helm dependency list "$1" 2>&1) || true      # it exits 1 when a dependency is not ok
  awk '
    /^NAME[[:space:]]/ { next }                      # the table header: NAME VERSION REPOSITORY STATUS
    NF >= 4 { rows++; if ($NF != "ok") bad = 1 }     # a dependency row (or an error line) whose last field is not ok
    END { exit (rows && !bad) ? 0 : 1 }
  ' <<<"$out"
}

rc=0
for t in charts/*/tests plugins/charts/*/tests; do
  [[ -d "$t" ]] || continue
  ls "$t"/*_test.yaml >/dev/null 2>&1 || continue
  c=${t%/tests}
  echo "== $c"
  if grep -q '^dependencies:' "$c/Chart.yaml"; then
    if deps_ok "$c"; then
      echo "   dependencies ok, not built"
    else
      helm dependency build "$c" >/dev/null || rc=1
    fi
  fi
  helm unittest "$c" || rc=1
done

echo "== plugins/charts/profile-plugin-emqx acl-check --check"
if python3 -c 'import yaml' >/dev/null 2>&1; then
  bash plugins/charts/profile-plugin-emqx/tests/acl-check.sh --check || rc=1
else
  echo "   skipped: python3 has no PyYAML (the helm-unittest job installs it)"
fi
exit "$rc"
