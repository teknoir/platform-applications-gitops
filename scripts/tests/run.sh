#!/usr/bin/env bash
# Runs every test of the staging release tooling:
#   - python unittest of scripts/ (pure logic, throwaway git repos, a fake cluster/GitHub/registry; no network)
#   - helm unittest of charts/app-of-apps (release helper, 19 replacements) and charts/release-guard
#   - the root render against a base ref (BASE=origin/teknoir-cloud, default): identical except for the removal of the
#     fields ArgoCD's Go types drop (`sources: [ ]` on every child, monitoring's `group: ""`), see EXPECTED below
#   - K3D=1: charts/release-guard/tests/k3d-guard-test.sh (impersonated identities) and k3d-argocd-real-test.sh (a real
#     ArgoCD v3.5.1, real CLI and REST calls) and charts/backstage/tests/k3d-rbac-test.sh (can-i matrix and the identity admission policy of the Backstage
#     API service account) against the throwaway cluster k3d-teknoir-dev
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
cd "$REPO"

# Every temp dir the tests create (throwaway git repos, renders, fake registries) lives in one per-run TMPDIR that is
# removed on exit; the Python tests use tempfile.mkdtemp() and never clean up themselves.
RUN_TMP=$(mktemp -d -t gitops-tests.XXXXXX); trap 'rm -rf "$RUN_TMP"' EXIT
export TMPDIR="$RUN_TMP"

echo "== python unittest (scripts/tests)"
python3 -W ignore -m unittest discover -s scripts/tests -p 'test_*.py' 2>&1 | grep -E "^(Ran|OK|FAILED|FAIL|ERROR)" 

echo "== helm unittest"
helm unittest charts/app-of-apps charts/release-guard 2>&1 | grep -E "^(Charts|Test Suites|Tests):"

BASE="${BASE:-origin/teknoir-cloud}"
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
    cmp "$TMP/expected-$p.yaml" "$TMP/new-$p.yaml" && echo "as expected (base minus the removals): $p ($(diff "$TMP/base-$p.yaml" "$TMP/new-$p.yaml" | grep -c '^<') lines removed, $(diff "$TMP/base-$p.yaml" "$TMP/new-$p.yaml" | grep -c '^>') added)"
  done
  git worktree remove --force "$TMP/base"
fi

# backstage-sa R2 removes teknoir-admin from the Backstage API service account. That is only safe once the pinned
# profile-controller has the portal code (RoleBinding teknoir-portal per teamspace): this step FAILS the run while the pinned
# tag is not listed in release-policy.yaml portal_profile_controller_tags (scripts/check-pins.py check_portal_binding).
# scripts/staging-release also runs the same check on every dry run and --yes (lint), plus a live check of the Profiles.
echo "== portal guard: the pinned profile-controller has the portal code once the Backstage API service account lost teknoir-admin"
mkdir "$RUN_TMP/portal"
helm template profile-controller charts/profile-controller --namespace teknoir-system > "$RUN_TMP/portal/profile-controller.yaml"
helm template backstage charts/backstage --namespace teknoir-system > "$RUN_TMP/portal/backstage.yaml"
python3 scripts/check-pins.py --only portal-controller-unchecked --project teknoir-online "$RUN_TMP/portal"

if [[ "${K3D:-}" == "1" ]]; then
  echo "== release guard on k3d-teknoir-dev"
  charts/release-guard/tests/k3d-guard-test.sh
  echo "== release guard against a real ArgoCD on k3d-teknoir-dev (installs ArgoCD v3.5.1, removes it again)"
  charts/release-guard/tests/k3d-argocd-real-test.sh
  echo "== Backstage API service account RBAC on k3d-teknoir-dev (rendered RBAC + a teknoir-portal RoleBinding, can-i matrix)"
  charts/backstage/tests/k3d-rbac-test.sh
fi
