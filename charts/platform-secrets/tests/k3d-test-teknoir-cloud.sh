#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# SC2016: the single-quoted strings are go-templates / jsonpaths.
# shellcheck disable=SC2015,SC2016
# k3d test of the platform-secrets chart with the teknoir-cloud (staging)
# values. Not packaged (.helmignore tests/). HEAVY: starts a k3d cluster.
#
#   charts/platform-secrets/tests/k3d-test-teknoir-cloud.sh [--keep]
#
# The fixture mirrors r415 (k3s v1.34.5), with dummy values only:
#   - teknoir-auth/oauth2-proxy-secret {client-secret=A, cookie-secret}
#   - teknoir-system/backstage-keycloak-secrets {KEYCLOAK_REALM=master,
#     KEYCLOAK_CLIENTID=teknoir, KEYCLOAK_CLIENTSECRET=B (stale)}, written as a
#     REAL K3s manifest file (server/manifests/teknoir-backstage-keycloak-
#     secrets.yaml), so it carries the same objectset.rio.cattle.io label and
#     annotations and has an Addon owner, like on r415
#   - Deployments teknoir-system/user-controller and backstage-api and
#     teknoir-auth/oauth2-proxy (pause image, envFrom their Secrets);
#     user-controller has an old kubectl rollout restartedAt, like on r415
#   - a decoy teknoir-auth/keycloak-db-secret
# The render is applied server-side with field manager argocd-controller; the
# CronJob is suspended so only the runs started here touch the Secret (a run
# is `kubectl create job --from=cronjob/platform-secrets-resync`).
#
#   S1 the Job completes: sha256(KEYCLOAK_CLIENTSECRET) == sha256(A), realm and
#      client id unchanged, label teknoir.org/managed-by=platform-secrets,
#      user-controller restarted (new restartedAt, rollout completes), no
#      restart-pending marker; backstage-api and oauth2-proxy not restarted,
#      oauth2-proxy-secret untouched; the log matches the rollout runbook
#   S2 a re-run logs 'unchanged'; Secret resourceVersion and the
#      Deployment's generation do not move
#   S3 a k3s restart re-applies the stale K3s file (the r415 failure mode);
#      the next run logs 'synced keys: KEYCLOAK_CLIENTSECRET' and restarts
#   S4 rotating A to A2 in oauth2-proxy-secret: the copy follows, restart
#   S5 the Secret deleted: the next run re-creates it with all 3 keys
#   S6 RBAC: the ServiceAccount cannot get keycloak-db-secret, list secrets,
#      patch oauth2-proxy-secret or restart other Deployments
#   HC tests/staging-hash-check.sh (the rollout pre-check and STG-C1 step 6)
#      against the real API: DIFFERENT on the stale fixture, EQUAL after S1,
#      S3 and S5, DIFFERENT after the k3s revert, and ERROR (never EQUAL) for
#      a deleted Secret, missing keys on both sides, a wrong context and a
#      Forbidden identity
#   S7 no value (plain or base64) of A, A2, B or the cookie in any Job log or
#      in the hash-check output (stdout and stderr)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
CLUSTER=psecrets-tc
CTX=k3d-$CLUSTER
NODE=k3d-$CLUSTER-server-0
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.34.5-k3s1}
K3S_FILE=/var/lib/rancher/k3s/server/manifests/teknoir-backstage-keycloak-secrets.yaml
KEEP=0
[ "${1:-}" = --keep ] && KEEP=1

WORK=$(mktemp -d)
LOGS=$WORK/logs
mkdir -p "$LOGS"
pass=0
fail=0
k() { kubectl --context "$CTX" "$@"; }
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
cleanup() {
	if [ "$KEEP" -eq 0 ]; then k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true; fi
	rm -rf "$WORK"
}
trap cleanup EXIT

# Harness-only helpers. Values are compared as hashes and never echoed.
# Every Secret read is captured, never shown, with stderr discarded: when a
# template fails, kubectl prints the whole object, .data included (go-template
# on stdout, jsonpath on stderr). A failed or empty read returns 1 with no
# output, so it can never equal h(<dummy>); never compare two reads with each
# other without checking their rc. For r415, use tests/staging-hash-check.sh.
rnd32() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
h() { printf '%s' "$1" | sha256sum | cut -c1-64; }
# key_b64 <ns> <secret> <key>: the base64 value (key without '.')
key_b64() {
	local v
	v=$(k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null) || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v"
}
key_hash() {
	local v
	v=$(key_b64 "$@") || return 1
	printf '%s' "$v" | base64 -d | sha256sum | cut -c1-64
}
get_plain() { # only for the non-secret keys (realm, client id)
	local v
	v=$(key_b64 "$@") || return 1
	printf '%s' "$v" | base64 -d
}
data_hash() {
	local v
	v=$(k -n "$1" get secret "$2" -o jsonpath='{.data}' 2>/dev/null) || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v" | sha256sum | cut -c1-64
}
data_keys() { # sorted key names as a JSON list
	local v
	v=$(k -n "$1" get secret "$2" -o jsonpath='{.data}' 2>/dev/null) || return 1
	[ -n "$v" ] || return 1
	printf '%s' "$v" | yq -p json -o json -I0 'keys | sort'
}
rv() { k -n "$1" get secret "$2" -o jsonpath='{.metadata.resourceVersion}'; }
restarted_at() { k -n "$1" get deploy "$2" -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'; }
generation() { k -n "$1" get deploy "$2" -o jsonpath='{.metadata.generation}'; }
pending() { k -n teknoir-system get secret backstage-keycloak-secrets -o jsonpath='{.metadata.annotations.teknoir\.org/restart-pending}'; }
managed_by() { k -n "$1" get secret "$2" -o jsonpath='{.metadata.labels.teknoir\.org/managed-by}'; }
secret_ns_names() { k get secret -A --no-headers -o custom-columns=N:.metadata.namespace,S:.metadata.name | sort; }

# run_job <name>: one run through the CronJob template; saves the log; rc of the Job
run_job() {
	local st="" p
	k -n teknoir-system create job "$1" --from=cronjob/platform-secrets-resync >/dev/null
	for _ in $(seq 1 90); do
		st=$(k -n teknoir-system get job "$1" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}')
		case $st in *Complete* | *Failed*) break ;; esac
		sleep 2
	done
	for p in $(k -n teknoir-system get pods -l "job-name=$1" -o name); do
		k -n teknoir-system logs "$p" >>"$LOGS/$1.log" 2>&1 || true
	done
	case $st in *Complete*) return 0 ;; *) return 1 ;; esac
}
# has_log <file> <fixed string>
has_log() { grep -qF -- "$2" "$LOGS/$1.log"; }
# hc <label> [args...]: tests/staging-hash-check.sh against this cluster (a
# later --context overrides). Sets hc_res to "<stdout>:<rc>"; stdout and
# stderr go to the hash-check log, which S7 scans; the last stderr stays in
# $WORK/hc.err.
HC=$HERE/staging-hash-check.sh
hc() {
	local label=$1 out rc=0
	shift
	out=$("$HC" --context "$CTX" "$@" 2>"$WORK/hc.err") || rc=$?
	hc_res="$out:$rc"
	{
		echo "## $label: $hc_res"
		cat "$WORK/hc.err"
	} >>"$LOGS/hashcheck.log"
}

# Dummy values (never printed).
A=$(rnd32)
A2=$(rnd32)
B=$(rnd32)
COOKIE=$(rnd32)
DECOY=$(rnd32)
b64() { printf '%s' "$1" | base64 -w0; }

TOOLBOX=$(helm template platform-secrets "$CHART" | yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].image')
echo "== cluster ($K3S_IMAGE, toolbox $TOOLBOX)"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait \
	--k3s-arg '--disable=traefik,metrics-server,servicelb@server:0' >/dev/null
# Preload the toolbox layers by tag; the digest-pinned ref then needs only the
# manifest from the registry (or pulls fully if the import is not possible).
if docker image inspect "${TOOLBOX%@*}" >/dev/null 2>&1; then
	k3d image import -c "$CLUSTER" "${TOOLBOX%@*}" >/dev/null 2>&1 || echo "  (toolbox import failed; k3s pulls it)"
fi
# Pause image for the consumer Deployments: the sandbox image k3s already has.
PAUSE_IMAGE=${PAUSE_IMAGE:-}
for _ in $(seq 1 60); do
	[ -n "$PAUSE_IMAGE" ] && break
	PAUSE_IMAGE=$(docker exec "$NODE" crictl images 2>/dev/null | awk '$1 ~ /pause/ { print $1 ":" $2; exit }')
	sleep 2
done
PAUSE_IMAGE=${PAUSE_IMAGE:-rancher/mirrored-pause:3.6}
echo "  pause image $PAUSE_IMAGE"

echo "== fixture (r415 layout, dummy values)"
k create namespace teknoir-system >/dev/null
k create namespace teknoir-auth >/dev/null
k -n teknoir-auth create secret generic oauth2-proxy-secret \
	--from-file=client-secret=<(printf '%s' "$A") --from-file=cookie-secret=<(printf '%s' "$COOKIE") >/dev/null
k -n teknoir-auth create secret generic keycloak-db-secret \
	--from-literal=username=keycloak --from-file=password=<(printf '%s' "$DECOY") >/dev/null
# The stale copy, as a K3s manifest file (the hand-made r415 file).
cat >"$WORK/stale.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: backstage-keycloak-secrets
  namespace: teknoir-system
type: Opaque
data:
  KEYCLOAK_REALM: $(b64 master)
  KEYCLOAK_CLIENTID: $(b64 teknoir)
  KEYCLOAK_CLIENTSECRET: $(b64 "$B")
EOF
docker cp "$WORK/stale.yaml" "$NODE:$K3S_FILE" >/dev/null
for _ in $(seq 1 60); do
	k -n teknoir-system get secret backstage-keycloak-secrets >/dev/null 2>&1 && break
	sleep 2
done
[ "$(k -n teknoir-system get secret backstage-keycloak-secrets -o jsonpath='{.metadata.annotations.objectset\.rio\.cattle\.io/owner-name}')" = teknoir-backstage-keycloak-secrets ] &&
	[ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(h "$B")" ] &&
	ok "S0 fixture: the K3s Addon applied the stale Secret (owner annotations as on r415)" || bad "S0 K3s fixture"
deploy() { # <ns> <name> <secret>: pause container with envFrom <secret>
	k apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $2
  namespace: $1
spec:
  replicas: 1
  selector:
    matchLabels: {app: $2}
  template:
    metadata:
      labels: {app: $2}
      annotations:
        kubectl.kubernetes.io/restartedAt: "2026-06-01T15:32:20+02:00"
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: main
          image: $PAUSE_IMAGE
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: $3
EOF
}
deploy teknoir-system user-controller backstage-keycloak-secrets
deploy teknoir-system backstage-api backstage-keycloak-secrets
deploy teknoir-auth oauth2-proxy oauth2-proxy-secret
for d in teknoir-system/user-controller teknoir-system/backstage-api teknoir-auth/oauth2-proxy; do
	k -n "${d%%/*}" rollout status deploy "${d#*/}" --timeout=180s >/dev/null || bad "fixture deployment $d not ready"
done
uc_r0=$(restarted_at teknoir-system user-controller)
ba_r0=$(restarted_at teknoir-system backstage-api)
op_r0=$(restarted_at teknoir-auth oauth2-proxy)
o2p_hash0=$(data_hash teknoir-auth oauth2-proxy-secret) || {
	bad "fixture: oauth2-proxy-secret unreadable"
	o2p_hash0=unreadable
}
o2p_rv0=$(rv teknoir-auth oauth2-proxy-secret)
db_rv0=$(rv teknoir-auth keycloak-db-secret)
secrets0=$(secret_ns_names)
hc pre
[ "$hc_res" = DIFFERENT:1 ] && ok "HC pre-check on the stale fixture: DIFFERENT" || bad "HC pre-check: $hc_res"

echo "== S1 hook Job (render applied server-side as argocd-controller)"
helm template platform-secrets "$CHART" >"$WORK/render.yaml"
k apply --server-side --field-manager=argocd-controller --force-conflicts -f "$WORK/render.yaml" >/dev/null
k -n teknoir-system patch cronjob platform-secrets-resync --type merge -p '{"spec":{"suspend":true}}' >/dev/null
if k -n teknoir-system wait --for=condition=complete job/platform-secrets-ensure --timeout=300s >/dev/null; then
	ok "S1 Job platform-secrets-ensure completed"
else
	bad "S1 Job did not complete"
	k -n teknoir-system describe job platform-secrets-ensure | tail -20
fi
for p in $(k -n teknoir-system get pods -l job-name=platform-secrets-ensure -o name); do
	k -n teknoir-system logs "$p" >>"$LOGS/ensure.log" 2>&1 || true
done
cat "$LOGS/ensure.log"
[ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(h "$A")" ] &&
	ok "S1 sha256(KEYCLOAK_CLIENTSECRET) = sha256(oauth2-proxy client-secret)" || bad "S1 client secret not copied"
[ "$(get_plain teknoir-system backstage-keycloak-secrets KEYCLOAK_REALM)" = master ] &&
	[ "$(get_plain teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTID)" = teknoir ] &&
	ok "S1 KEYCLOAK_REALM=master, KEYCLOAK_CLIENTID=teknoir unchanged" || bad "S1 realm/client id"
[ "$(managed_by teknoir-system backstage-keycloak-secrets)" = platform-secrets ] &&
	ok "S1 label teknoir.org/managed-by=platform-secrets" || bad "S1 label missing"
uc_r1=$(restarted_at teknoir-system user-controller)
[ -n "$uc_r1" ] && [ "$uc_r1" != "$uc_r0" ] && ok "S1 user-controller restarted (restartedAt $uc_r1)" || bad "S1 user-controller not restarted"
k -n teknoir-system rollout status deploy user-controller --timeout=180s >/dev/null &&
	ok "S1 user-controller rollout completed" || bad "S1 rollout status"
[ -z "$(pending)" ] && ok "S1 no restart-pending marker left" || bad "S1 marker left"
[ "$(restarted_at teknoir-system backstage-api)" = "$ba_r0" ] && [ "$(restarted_at teknoir-auth oauth2-proxy)" = "$op_r0" ] &&
	ok "S1 backstage-api and oauth2-proxy not restarted" || bad "S1 unexpected restart"
[ "$(rv teknoir-auth oauth2-proxy-secret)" = "$o2p_rv0" ] && [ "$(data_hash teknoir-auth oauth2-proxy-secret)" = "$o2p_hash0" ] &&
	[ -z "$(managed_by teknoir-auth oauth2-proxy-secret)" ] && [ "$(rv teknoir-auth keycloak-db-secret)" = "$db_rv0" ] &&
	ok "S1 oauth2-proxy-secret and keycloak-db-secret untouched" || bad "S1 source or decoy touched"
[ "$(secret_ns_names)" = "$secrets0" ] && ok "S1 no Secret created or deleted" || bad "S1 Secret set changed"
for l in 'teknoir-system/backstage-keycloak-secrets: synced keys: KEYCLOAK_CLIENTSECRET' \
	'teknoir-system/backstage-keycloak-secrets: synced labels' \
	'teknoir-system/backstage-keycloak-secrets: restarted deployment teknoir-system/user-controller' \
	'done: 0 created, 1 updated, 0 unchanged, 0 failed'; do
	has_log ensure "$l" && ok "S1 log: $l" || bad "S1 log lacks: $l"
done
hc s1
[ "$hc_res" = EQUAL:0 ] && ok "HC after S1 (STG-C1 step 6): EQUAL, reading the hyphenated key client-secret" || bad "HC after S1: $hc_res"

echo "== S2 re-run is a no-op"
s_rv=$(rv teknoir-system backstage-keycloak-secrets)
uc_gen=$(generation teknoir-system user-controller)
sleep 1
run_job s2 && ok "S2 run succeeded" || bad "S2 run failed"
has_log s2 'teknoir-system/backstage-keycloak-secrets: unchanged' && has_log s2 'done: 0 created, 0 updated, 1 unchanged, 0 failed' &&
	ok "S2 log: unchanged" || bad "S2 log"
[ "$(rv teknoir-system backstage-keycloak-secrets)" = "$s_rv" ] && ok "S2 Secret resourceVersion unchanged" || bad "S2 Secret changed"
[ "$(generation teknoir-system user-controller)" = "$uc_gen" ] && [ "$(restarted_at teknoir-system user-controller)" = "$uc_r1" ] &&
	ok "S2 user-controller generation unchanged (no restart loop)" || bad "S2 user-controller restarted"

echo "== S3 k3s restart re-applies the stale K3s file"
docker restart "$NODE" >/dev/null
for _ in $(seq 1 90); do
	k get --raw /readyz >/dev/null 2>&1 && break
	sleep 2
done
reverted=0
for _ in $(seq 1 90); do
	if [ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET 2>/dev/null)" = "$(h "$B")" ]; then
		reverted=1
		break
	fi
	sleep 2
done
if [ "$reverted" -eq 1 ]; then
	ok "S3 k3s restart reverted KEYCLOAK_CLIENTSECRET to the stale value (r415 failure mode reproduced)"
else
	bad "S3 k3s restart did not revert the Secret; re-applying the stale manifest instead"
	k apply -f "$WORK/stale.yaml" >/dev/null
fi
hc s3-reverted
[ "$hc_res" = DIFFERENT:1 ] && ok "HC after the k3s revert: DIFFERENT" || bad "HC after the revert: $hc_res"
uc_r2=$(restarted_at teknoir-system user-controller)
sleep 1
run_job s3 && ok "S3 run succeeded" || bad "S3 run failed"
has_log s3 'teknoir-system/backstage-keycloak-secrets: synced keys: KEYCLOAK_CLIENTSECRET' &&
	has_log s3 'restarted deployment teknoir-system/user-controller' && ok "S3 log: synced KEYCLOAK_CLIENTSECRET, restarted" || bad "S3 log"
[ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(h "$A")" ] &&
	ok "S3 copy is back to the oauth2-proxy client secret" || bad "S3 copy not restored"
hc s3
[ "$hc_res" = EQUAL:0 ] && ok "HC after the S3 run: EQUAL" || bad "HC after S3: $hc_res"
uc_r3=$(restarted_at teknoir-system user-controller)
[ -n "$uc_r3" ] && [ "$uc_r3" != "$uc_r2" ] && [ -z "$(pending)" ] && ok "S3 user-controller restarted, marker cleared" || bad "S3 restart"

echo "== S4 rotation of the source"
printf '{"data":{"client-secret":"%s"}}' "$(b64 "$A2")" |
	k -n teknoir-auth patch secret oauth2-proxy-secret --type merge --patch-file=/dev/stdin >/dev/null
sleep 1
run_job s4 && ok "S4 run succeeded" || bad "S4 run failed"
[ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(h "$A2")" ] &&
	ok "S4 copy follows the rotated client secret" || bad "S4 copy did not follow"
uc_r4=$(restarted_at teknoir-system user-controller)
[ -n "$uc_r4" ] && [ "$uc_r4" != "$uc_r3" ] && [ -z "$(pending)" ] && ok "S4 user-controller restarted, marker cleared" || bad "S4 restart"
has_log s4 'teknoir-system/backstage-keycloak-secrets: synced keys: KEYCLOAK_CLIENTSECRET' && ok "S4 log names the key" || bad "S4 log"
[ "$(restarted_at teknoir-auth oauth2-proxy)" = "$op_r0" ] && ok "S4 oauth2-proxy not restarted by this chart" || bad "S4 oauth2-proxy restarted"

echo "== S5 deleted Secret is re-created"
k -n teknoir-system delete secret backstage-keycloak-secrets >/dev/null
hc s5-deleted
[ "$hc_res" = ERROR:2 ] && grep -qF 'secrets "backstage-keycloak-secrets" not found' "$WORK/hc.err" &&
	ok "HC deleted copy: ERROR (NotFound on stderr)" || bad "HC deleted copy: $hc_res"
sleep 1
run_job s5 && ok "S5 run succeeded" || bad "S5 run failed"
[ "$(get_plain teknoir-system backstage-keycloak-secrets KEYCLOAK_REALM)" = master ] &&
	[ "$(get_plain teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTID)" = teknoir ] &&
	[ "$(key_hash teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(h "$A2")" ] &&
	[ "$(data_keys teknoir-system backstage-keycloak-secrets)" = '["KEYCLOAK_CLIENTID","KEYCLOAK_CLIENTSECRET","KEYCLOAK_REALM"]' ] &&
	ok "S5 re-created with KEYCLOAK_REALM, KEYCLOAK_CLIENTID and KEYCLOAK_CLIENTSECRET" || bad "S5 keys"
[ "$(managed_by teknoir-system backstage-keycloak-secrets)" = platform-secrets ] && ok "S5 label set" || bad "S5 label"
has_log s5 'teknoir-system/backstage-keycloak-secrets: created (keys: KEYCLOAK_CLIENTID, KEYCLOAK_REALM, KEYCLOAK_CLIENTSECRET)' &&
	ok "S5 log: created" || bad "S5 log"
hc s5
[ "$hc_res" = EQUAL:0 ] && ok "HC after the S5 re-create: EQUAL" || bad "HC after S5: $hc_res"
uc_r5=$(restarted_at teknoir-system user-controller)
[ -n "$uc_r5" ] && [ "$uc_r5" != "$uc_r4" ] && [ -z "$(pending)" ] && ok "S5 user-controller restarted, marker cleared" || bad "S5 restart"

echo "== S6 RBAC"
sa=system:serviceaccount:teknoir-system:platform-secrets
can() { k auth can-i "$@" --as="$sa" 2>/dev/null || true; }
[ "$(can get secret/keycloak-db-secret -n teknoir-auth)" = no ] && ok "S6 get keycloak-db-secret denied" || bad "S6 decoy readable"
[ "$(can list secrets -n teknoir-auth)" = no ] && [ "$(can list secrets -n teknoir-system)" = no ] &&
	ok "S6 list secrets denied in both namespaces" || bad "S6 list allowed"
[ "$(can get secret/oauth2-proxy-secret -n teknoir-auth)" = yes ] && ok "S6 get oauth2-proxy-secret allowed (copy source)" || bad "S6 source not readable"
[ "$(can patch secret/oauth2-proxy-secret -n teknoir-auth)" = no ] && [ "$(can create secrets -n teknoir-auth)" = no ] &&
	ok "S6 source is read-only (no patch, no create in teknoir-auth)" || bad "S6 source writable"
[ "$(can patch deployment/backstage-api -n teknoir-system)" = no ] && [ "$(can patch deployment/oauth2-proxy -n teknoir-auth)" = no ] &&
	ok "S6 only user-controller can be restarted" || bad "S6 other Deployments patchable"
[ "$(can delete secret/backstage-keycloak-secrets -n teknoir-system)" = no ] && [ "$(can get secret/argocd-secret -n teknoir-system)" = no ] &&
	ok "S6 no delete, no other teknoir-system Secret" || bad "S6 delete or other Secret allowed"

echo "== HC staging-hash-check fails closed (never EQUAL on a failed read)"
hc missing-both --source teknoir-auth/oauth2-proxy-secret/NO_SUCH_KEY --copy teknoir-system/backstage-keycloak-secrets/NO_SUCH_KEY
[ "$hc_res" = ERROR:2 ] && [ "$(grep -c 'key NO_SUCH_KEY is missing or empty' "$WORK/hc.err")" = 2 ] &&
	ok "HC missing key on both sides (jsonpath prints nothing, rc 0): ERROR" || bad "HC missing keys: $hc_res"
hc wrong-context --context k3d-no-such-cluster
[ "$hc_res" = ERROR:2 ] && grep -qF 'context "k3d-no-such-cluster" does not exist' "$WORK/hc.err" &&
	ok "HC wrong context: ERROR" || bad "HC wrong context: $hc_res"
# An identity without Secret access: the same cluster, impersonating
# system:serviceaccount:default:default (kubeconfig `as`).
k config view --raw --minify >"$WORK/kc-nobody"
yq -i '.users[0].user.as = "system:serviceaccount:default:default"' "$WORK/kc-nobody"
KUBECONFIG=$WORK/kc-nobody hc forbidden
[ "$hc_res" = ERROR:2 ] && [ "$(grep -c 'Error from server (Forbidden)' "$WORK/hc.err")" = 2 ] &&
	ok "HC Forbidden on both reads: ERROR" || bad "HC Forbidden: $hc_res"
rm -f "$WORK/kc-nobody"
hc final
[ "$hc_res" = EQUAL:0 ] && ok "HC default pair still EQUAL" || bad "HC final: $hc_res"

echo "== S7 never print"
[ "$(grep -c '^## ' "$LOGS/hashcheck.log")" = 10 ] && ok "S7 scans the output of all 10 hash-check runs" ||
	bad "S7 hash-check log has $(grep -c '^## ' "$LOGS/hashcheck.log") runs, want 10"
cat "$LOGS"/*.log >"$WORK/all.log"
leaks=0
checked=0
for name in A A2 B COOKIE DECOY; do
	val=${!name}
	for form in "$val" "$(b64 "$val")"; do
		checked=$((checked + 1))
		if grep -qF -- "$form" "$WORK/all.log"; then
			echo "  LEAK: value $name appears in a Job log or the hash-check output"
			leaks=$((leaks + 1))
		fi
	done
done
[ "$leaks" -eq 0 ] && ok "S7 0 leaks: $checked values (plain and base64) vs $(wc -l <"$WORK/all.log") Job and hash-check log lines" || bad "S7 $leaks leaks"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
