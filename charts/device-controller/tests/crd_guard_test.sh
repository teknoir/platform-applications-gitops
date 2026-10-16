#!/usr/bin/env bash
# helm-unittest does not render crds/, so this guards them separately.
# Every CRD in crds/ must carry Prune=false,Delete=false: the Application has prune: true,
# and pruning a CRD deletes all its objects (Robots carry a finalizer only the nextgen
# reconciler removes). Run: charts/device-controller/tests/crd_guard_test.sh
set -euo pipefail
dir="$(cd "$(dirname "$0")/../crds" && pwd)"
fail=0
for f in "$dir"/*.yaml; do
  if ! awk '/^kind: CustomResourceDefinition/{k=1} /argocd.argoproj.io\/sync-options: *Prune=false,Delete=false/{a=1} END{exit !(k&&a)}' "$f"; then
    echo "FAIL: $f lacks argocd.argoproj.io/sync-options: Prune=false,Delete=false" >&2; fail=1
  fi
done
[ "$fail" = 0 ] && echo "ok: all $(ls "$dir"/*.yaml | wc -l) CRDs are protected from prune/delete"
exit "$fail"
