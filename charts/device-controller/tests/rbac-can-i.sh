#!/usr/bin/env bash
# Read-only RBAC check of the device-controller service account (plans/ssh-tunnel-removal.md, step 11).
#
#   rbac-can-i.sh matrix  --context vpro [--legacy] [--datavolumes]
#       Asks the API server "can the controller do X in namespace N?" (kubectl auth can-i, impersonating
#       the service account) for every permission the chart grants (expected yes) and every permission
#       that step 11 removed (expected no). Prints one line per check and the mismatches; exit 1 if any.
#         --legacy       the cluster runs with legacyTunnelCleanup=true: the cleanup deletes are expected yes
#         --datavolumes  the DataVolume create fallback was added to the vdev Role: expect it yes there
#   rbac-can-i.sh logwatch --context vpro [--rounds 48] [--every 1800] [--out FILE]
#       The 24 h "no RBAC denials" check. The controller log of vpro covers about 70 minutes, so
#       `kubectl logs --since=24h` proves nothing: this greps the last (every + 5 min) of the log
#       every <every> seconds, <rounds> times, appends every hit to FILE and exits 1 if there was any.
#   rbac-can-i.sh denials --context vpro [--since 70m]
#       One-off grep of the current log for denials.
#
# Needs a caller that may impersonate the service account (auth can-i --as). Never writes anything.
# Refuses the production context.
set -uo pipefail

SA="${SA:-system:serviceaccount:teknoir-system:device-controller-service-account}"
NS_SYSTEM="${NS_SYSTEM:-teknoir-system}"
TEAMSPACE="${TEAMSPACE:-teknoir-demo}"
VDEV_NS="${VDEV_NS:-${TEAMSPACE}-vdev}"
ZTNA_NS="${ZTNA_NS:-teknoir-ztna}"
OTHER_NS="${OTHER_NS:-kube-system}"
DENIAL_RE='forbidden|cannot (get|list|watch|create|update|patch|delete) |rejected event|Unauthorized'

cmd="${1:-}"; shift || true
CTX=""; LEGACY=0; DV=0; ROUNDS=48; EVERY=1800; OUT=""; SINCE="70m"
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX="$2"; shift 2;;
    --legacy) LEGACY=1; shift;;
    --datavolumes) DV=1; shift;;
    --rounds) ROUNDS="$2"; shift 2;;
    --every) EVERY="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
[ -n "$CTX" ] || { echo "--context is required (always explicit; vpro is staging)" >&2; exit 2; }
case "$CTX" in *eks*|*prod*) echo "refusing production context $CTX" >&2; exit 2;; esac
K=(kubectl --context "$CTX")

denials() { # $1 = --since value
  "${K[@]}" -n "$NS_SYSTEM" logs deploy/device-controller -c manager --since="$1" 2>&1 | grep -Ei "$DENIAL_RE" || true
}

if [ "$cmd" = denials ]; then
  out="$(denials "$SINCE")"
  lines="$("${K[@]}" -n "$NS_SYSTEM" logs deploy/device-controller -c manager --since="$SINCE" 2>/dev/null | wc -l)"
  echo "log window: last $SINCE, $lines lines"
  if [ -n "$out" ]; then echo "$out"; echo "DENIALS FOUND"; exit 1; fi
  echo "no denials"; exit 0
fi

if [ "$cmd" = logwatch ]; then
  OUT="${OUT:-device-controller-denials-$(date -u +%Y%m%dT%H%MZ).log}"
  window="$(( EVERY / 60 + 5 ))m"
  : >"$OUT"; hits=0
  for i in $(seq 1 "$ROUNDS"); do
    out="$(denials "$window")"
    n="$(printf '%s' "$out" | grep -c . || true)"
    echo "$(date -u +%FT%TZ) round $i/$ROUNDS: $n denial lines (window $window)"
    if [ "$n" -gt 0 ]; then printf '%s\n' "$out" >>"$OUT"; hits=$((hits + n)); fi
    [ "$i" -lt "$ROUNDS" ] && sleep "$EVERY"
  done
  echo "done: $hits denial lines in total, written to $OUT"
  [ "$hits" -eq 0 ]; exit $?
fi

[ "$cmd" = matrix ] || { sed -n '2,20p' "$0" >&2; exit 2; }

fail=0; total=0
# check <yes|no> <namespace|-> <verb> <resource[.group][/subresource]>
check() {
  local want="$1" ns="$2" verb="$3" res="$4" sub="" args=()
  case "$res" in */*) sub="${res#*/}"; res="${res%%/*}";; esac
  [ -n "$sub" ] && args+=(--subresource="$sub")
  if [ "$ns" = "-" ]; then args+=(--all-namespaces); else args+=(-n "$ns"); fi
  local got
  got="$("${K[@]}" auth can-i "$verb" "$res" "${args[@]}" --as="$SA" 2>/dev/null | head -1)"
  total=$((total + 1))
  if [ "$got" != "$want" ]; then
    fail=$((fail + 1)); echo "MISMATCH  want=$want got=${got:-error}  $verb $res${sub:+/$sub} ns=$ns"
  else
    echo "ok        $want  $verb $res${sub:+/$sub} ns=$ns"
  fi
}
many() { # many <yes|no> <ns> "<verbs>" <resource...>
  local want="$1" ns="$2" verbs="$3" v r; shift 3
  for r in "$@"; do for v in $verbs; do check "$want" "$ns" "$v" "$r"; done; done
}
legacy_want=no; [ "$LEGACY" = 1 ] && legacy_want=yes
dv_want=no; [ "$DV" = 1 ] && dv_want=yes

echo "== service account $SA on $CTX; teamspace=$TEAMSPACE vdev=$VDEV_NS ztna=$ZTNA_NS legacy=$LEGACY datavolumes=$DV"

# ---- kept: cluster-wide (checked in the teamspace; the ClusterRole grants them everywhere)
many yes "$TEAMSPACE" "get list watch" services secrets deployments.apps namespaces resourcequotas \
  deviceapplicationsets.teknoir.org robottypes.teknoir.org virtualmachines.kubevirt.io virtualmachineinstances.kubevirt.io
many yes "-" "get list watch" services secrets deployments.apps namespaces resourcequotas virtualmachines.kubevirt.io
check yes "$TEAMSPACE" create secrets
many yes "$TEAMSPACE" "create patch" events
many yes "$TEAMSPACE" "get create update delete" configmaps
many yes "$TEAMSPACE" "get list watch create update patch" devices.teknoir.org
check yes "$TEAMSPACE" update devices.teknoir.org/finalizers
check yes "$TEAMSPACE" update robots.teknoir.org/finalizers
many yes "$TEAMSPACE" "get list watch update patch" robots.teknoir.org
many yes "$TEAMSPACE" "get update patch" robots.teknoir.org/status robottypes.teknoir.org/status

# ---- removed: cluster-wide
many no "$TEAMSPACE" "create" pods/exec pods/attach pods/portforward
many no "$TEAMSPACE" "get create" pods/proxy services/proxy
many no "$TEAMSPACE" "get list" pods
many no "$TEAMSPACE" "update patch" secrets
many no "$TEAMSPACE" "create update patch" services
many no "$TEAMSPACE" "list watch" configmaps          # uncached on purpose; an informer must never be needed
many no "$TEAMSPACE" "create update patch" deployments.apps daemonsets.apps statefulsets.apps replicasets.apps
many no "$TEAMSPACE" "update" deployments.apps/scale deployments.apps/rollback
many no "$TEAMSPACE" "deletecollection" deployments.apps
many no "$TEAMSPACE" "get create update patch" virtualservices.networking.istio.io authorizationpolicies.security.istio.io
check no "$TEAMSPACE" list authorizationpolicies.security.istio.io
many no "$TEAMSPACE" "get list" persistentvolumeclaims
many no "$TEAMSPACE" "get create delete" datavolumes.cdi.kubevirt.io
many no "$TEAMSPACE" "create update patch delete" virtualmachines.kubevirt.io
many no "$TEAMSPACE" "delete deletecollection" devices.teknoir.org
many no "$TEAMSPACE" "update patch" devices.teknoir.org/status
many no "$TEAMSPACE" "create update patch delete" deviceapplicationsets.teknoir.org robottypes.teknoir.org
many no "$TEAMSPACE" "update" deviceapplicationsets.teknoir.org/status deviceapplicationsets.teknoir.org/finalizers robottypes.teknoir.org/finalizers
many no "$TEAMSPACE" "delete" robots.teknoir.org
many no "$TEAMSPACE" "delete" events

# ---- legacy cleanup (legacyTunnelCleanup): off = no, on = yes
many "$legacy_want" "$TEAMSPACE" "delete" deployments.apps services secrets
check "$legacy_want" "$TEAMSPACE" list virtualservices.networking.istio.io
check "$legacy_want" "$TEAMSPACE" delete virtualservices.networking.istio.io

# ---- virtual-device runtime namespace
many yes "$VDEV_NS" "get create delete" secrets
many yes "$VDEV_NS" "get create update delete" virtualmachines.kubevirt.io
many yes "$VDEV_NS" "get list watch" virtualmachineinstances.kubevirt.io services
many no "$VDEV_NS" "update patch" secrets
many no "$VDEV_NS" "patch" virtualmachines.kubevirt.io
check "$dv_want" "$VDEV_NS" create datavolumes.cdi.kubevirt.io
many no "$VDEV_NS" "delete" datavolumes.cdi.kubevirt.io
many no "$VDEV_NS" "create" pods/exec
many no "$VDEV_NS" "create update" deployments.apps
check "$legacy_want" "$VDEV_NS" delete deployments.apps

# ---- hub namespace (Role device-controller-ztna)
many yes "$ZTNA_NS" "get list create update delete" configmaps serviceaccounts virtualservices.networking.istio.io
many yes "$ZTNA_NS" "get create update delete" secrets services authorizationpolicies.security.istio.io
many yes "$ZTNA_NS" "get list watch create update delete" deployments.apps
many no "$ZTNA_NS" "patch" configmaps serviceaccounts secrets services deployments.apps virtualservices.networking.istio.io authorizationpolicies.security.istio.io
many no "$ZTNA_NS" "watch" configmaps serviceaccounts virtualservices.networking.istio.io authorizationpolicies.security.istio.io
many no "$ZTNA_NS" "list watch" authorizationpolicies.security.istio.io
many no "$ZTNA_NS" "create" pods/exec pods/attach pods/portforward
many no "$ZTNA_NS" "create update delete" daemonsets.apps statefulsets.apps replicasets.apps

# ---- anywhere else: the cluster-wide reads and Secret create only
many yes "$OTHER_NS" "get list watch" services secrets
check yes "$OTHER_NS" create secrets
many no "$OTHER_NS" "update patch" secrets
many "$legacy_want" "$OTHER_NS" "delete" secrets services deployments.apps
many no "$OTHER_NS" "create update" services deployments.apps
many no "$OTHER_NS" "create" pods/exec

echo "== $total checks, $fail mismatches"
[ "$fail" -eq 0 ]
