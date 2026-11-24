#!/usr/bin/env bash
# Runs every test of the staging release tooling:
#   - python unittest of scripts/ (pure logic, throwaway git repos, a fake cluster/GitHub/registry; no network), incl. test_ci_lfs.py (charts/ci plan.py lfs modes, clone.sh LFS pull/guard)
#   - helm unittest of charts/app-of-apps (release helper, 19 replacements), charts/istio, charts/release-guard, charts/monitoring (mesh scrape), charts/profile-controller, charts/user-controller, charts/device-controller, charts/backstage and charts/teknoirbot-controller
#   - the root render against a base ref (BASE: origin/HEAD's branch, the gitops branch, `main` since the CI v4 cut-over;
#     fallback origin/main when origin/HEAD is missing): identical except for the removal of the
#     fields ArgoCD's Go types drop (`sources: [ ]` on every child, monitoring's `group: ""`), see EXPECTED below; ROOT_RENDER_EXPECTED="project ..." accepts an intended difference of a project (a mismatch fails the run).
#   - K3D=1: charts/release-guard/tests/k3d-guard-test.sh (impersonated identities) and k3d-argocd-real-test.sh (a real
#     ArgoCD v3.5.1, real CLI and REST calls) and charts/backstage/tests/k3d-rbac-test.sh (can-i matrix and the identity admission policy of the Backstage
#     API service account) and charts/teknoirbot-controller/tests/k3d-vap-test.sh and k3d-fence-test.sh (the device guard and the bot fence) against the throwaway cluster k3d-teknoir-dev
#   Output: verbose for humans and CI. Under a coding agent (CLAUDECODE, AI_AGENT, Codex) it prints only the section
#   totals, plus the end of the log on failure; the full log is always written to .test-logs/ (git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
cd "$REPO"

is_agent() { case "${AI_AGENT:-}" in 0|false|no|off) return 1;; "") ;; *) return 0;; esac
  [ -n "${CLAUDECODE:-}${CODEX_THREAD_ID:-}${CODEX_SANDBOX:-}${GEMINI_CLI:-}${CURSOR_AGENT:-}${OPENCODE:-}" ]; }
if [ -z "${GITOPS_TESTS_INNER:-}" ]; then
  mkdir -p .test-logs; log=".test-logs/run-$(date +%Y%m%d-%H%M%S)-$$.log"; export NO_COLOR=1
  set +e
  if is_agent; then
    GITOPS_TESTS_INNER=1 bash "${BASH_SOURCE[0]}" "$@" >"$log" 2>&1; rc=$?
    grep -E "^(== |Ran [0-9]|OK|FAILED|Charts:|Test Suites:|Tests:|ok: |as expected|differs from|FAIL|WARN)" "$log"
    # on failure: the sections that failed (and the last one), without helm unittest PASS lines and progress dots
    [ "$rc" -eq 0 ] || awk 'function flush() { if (sec != "" && (bad || last)) printf "%s", sec; sec = ""; bad = 0 }
      /^== / { flush() } /^ PASS / || /^\.+$/ { next } /^(FAIL|ERROR:|Traceback|Error:)/ || / FAIL / { bad = 1 }
      { sec = sec $0 "\n" } END { last = 1; flush() }' "$log" | tail -n 200
  else
    GITOPS_TESTS_INNER=1 bash "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
  fi
  echo "exit=$rc full log: $log"; exit "$rc"
fi

# Every temp dir the tests create (throwaway git repos, renders, fake registries) lives in one per-run TMPDIR that is
# removed on exit; the Python tests use tempfile.mkdtemp() and never clean up themselves.
RUN_TMP=$(mktemp -d -t gitops-tests.XXXXXX); trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="$RUN_TMP"

echo "== python unittest (scripts/tests)"
python3 -W ignore -m unittest discover -s scripts/tests -p 'test_*.py' 2>&1

echo "== helm unittest"
# charts/monitoring renders its kube-prometheus-stack dependency (git-ignored charts/; ArgoCD builds it itself): build it once
compgen -G "charts/monitoring/charts/kube-prometheus-stack-*.tgz" >/dev/null || helm dependency build charts/monitoring >/dev/null 2>&1 || echo "WARN: helm dependency build charts/monitoring failed (offline?)"
helm unittest charts/app-of-apps charts/istio charts/release-guard charts/monitoring charts/profile-controller charts/user-controller charts/device-controller charts/backstage charts/teknoirbot-controller 2>&1
echo "== CRD guards (Prune=false,Delete=false; spec.desktop when desktop.enabled)"
bash charts/device-controller/tests/crd_guard_test.sh
bash charts/teknoirbot-controller/tests/crd_guard_test.sh

rc=0
BASE="${BASE:-$(git symbolic-ref --short -q refs/remotes/origin/HEAD || echo origin/main)}"
if git rev-parse --verify -q "$BASE" >/dev/null; then
  echo "== root render with release unset equals $BASE, except the round-trip removals"
  TMP=$(mktemp -d)
  git worktree add -q --detach "$TMP/base" "$BASE"
  for p in teknoir-cloud teknoir-online teknoir-local; do
    helm template app-of-apps "$TMP/base/charts/app-of-apps" --set project="$p" > "$TMP/base-$p.yaml"
    helm template app-of-apps charts/app-of-apps --set project="$p" > "$TMP/new-$p.yaml"
    # EXPECTED difference: every `  sources: [ ]` line is gone and monitoring's ignoreDifferences entry
    # `- group: ""` + `kind: Secret` is `- kind: Secret` (an empty omitempty field is dropped by ArgoCD's Go types
    # whenever argocd-server writes the Application back: UI sync, terminate)
    python3 - "$TMP/base-$p.yaml" > "$TMP/expected-$p.yaml" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"^  sources: \[ \]\n", "", s, flags=re.M)
s = s.replace('    - group: ""\n      kind: Secret\n', '    - kind: Secret\n')
sys.stdout.write(s)
PY
    stats="$(diff "$TMP/base-$p.yaml" "$TMP/new-$p.yaml" | grep -c '^<' || true) lines removed, $(diff "$TMP/base-$p.yaml" "$TMP/new-$p.yaml" | grep -c '^>' || true) added"
    if cmp -s "$TMP/expected-$p.yaml" "$TMP/new-$p.yaml"; then
      echo "as expected (base minus the removals): $p ($stats)"
    else
      diff "$TMP/expected-$p.yaml" "$TMP/new-$p.yaml" || true
      # ROOT_RENDER_EXPECTED="project ...": projects whose root render differs from the base on purpose (this branch's
      # harbor Application ignoreDifferences on teknoir-cloud). The difference is printed and accepted; once the branch
      # is merged the base has it and the render is identical again. Any other mismatch fails the run.
      if [[ " ${ROOT_RENDER_EXPECTED:-} " == *" $p "* ]]; then
        echo "differs from $BASE as expected (ROOT_RENDER_EXPECTED): $p ($stats)"
      else
        echo "FAIL: root render of $p differs from $BASE beyond the round-trip removals (set ROOT_RENDER_EXPECTED=\"$p\" for an intended difference)"
        rc=1
      fi
    fi
  done
  git worktree remove --force "$TMP/base"
fi

if [[ "${K3D:-}" == "1" ]]; then
  echo "== release guard on k3d-teknoir-dev"
  charts/release-guard/tests/k3d-guard-test.sh
  echo "== release guard against a real ArgoCD on k3d-teknoir-dev (installs ArgoCD v3.5.1, removes it again)"
  charts/release-guard/tests/k3d-argocd-real-test.sh
  echo "== Backstage API service account RBAC on k3d-teknoir-dev (rendered RBAC + a teknoir-portal RoleBinding, can-i matrix)"
  charts/backstage/tests/k3d-rbac-test.sh
  echo "== TeknoirBot device guard and bot fence on k3d-teknoir-dev (impersonated identities)"
  charts/teknoirbot-controller/tests/k3d-vap-test.sh
  charts/teknoirbot-controller/tests/k3d-fence-test.sh
fi

exit "$rc"
