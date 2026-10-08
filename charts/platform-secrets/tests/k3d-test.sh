#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# SC2016: the single-quoted strings are go-templates.
# shellcheck disable=SC2015,SC2016
# k3d test of the platform-secrets chart (not packaged: .helmignore tests/).
#
#   charts/platform-secrets/tests/k3d-test.sh [--keep]
#
# Creates a throw-away k3d cluster (context k3d-psecrets), applies the chart
# render exactly like the bootstrap one-shot (server-side, field manager
# argocd-controller), then exercises re-runs via the CronJob. Checks:
#   T1 one-shot Job completes; every Secret exists with its keys
#   T2 adoption: a pre-existing Secret keeps its data, gains the label
#   T3 formats: same-Secret copy, format prefix, 32-byte cookie, 16-char key
#   T4 idempotency: a re-run changes no resourceVersion
#   T5 delete one Secret: only that one is re-created
#   T6 rotation of a copy source: consumer re-synced, Deployment restarted,
#      restart marker cleared
#   T7 a failed restart is retried by the next run (marker survives)
#   T8 errors are not "absent": a Forbidden read fails the run, creates nothing
#   T9 RBAC: unlisted Secrets cannot be read; list is denied
#   T10 two concurrent runs on an empty cluster both succeed
#   T11 never print: no Secret value (plain or base64) in any Job log
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
CLUSTER=psecrets
CTX=k3d-$CLUSTER
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}
TOOLBOX=$(awk '/^image:/{f=1} f&&/repository:/{r=$2} f&&/tag:/{gsub(/"/,"",$2); print r":"$2; exit}' "$CHART/values.yaml")
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

# get_key <ns> <secret> <key>: decoded value (harness only; never echoed)
get_key() { k -n "$1" get secret "$2" -o go-template="{{index .data \"$3\" | base64decode}}"; }
rv() { k -n "$1" get secret "$2" -o jsonpath='{.metadata.resourceVersion}'; }
all_rvs() {
	for s in teknoir-auth/keycloak-client-secrets teknoir-auth/keycloak-admin teknoir-auth/keycloak-db-secret \
		teknoir-auth/oauth2-proxy-secret teknoir-auth/oauth2-proxy-redis-secret teknoir-system/harbor-secret \
		teknoir-system/harbor-oidc-secret teknoir-system/argocd-oidc-secret teknoir-system/backstage-keycloak-secrets \
		teknoir-system/backstage-postgres-secrets teknoir-system/backstage-backend-auth; do
		printf '%s %s\n' "$s" "$(rv "${s%%/*}" "${s#*/}")"
	done
}
# snap_values: record every current secret value (plain and base64) for the
# T11 leak check. Harness-only file, removed on exit. Keys that hold the
# chart's non-secret literals (user names, realm, client id) are reported
# but not counted: their values ("backstage", "user-controller", ...) are
# also object names that the log prints.
LITERAL_KEYS=' username POSTGRES_USER DATA_SOURCE_USER KEYCLOAK_REALM KEYCLOAK_CLIENTID '
snap_values() {
	local ns s key b
	for ns in teknoir-auth teknoir-system; do
		for s in $(k -n "$ns" get secret -o name); do
			for key in $(k -n "$ns" get "$s" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}'); do
				b=$(k -n "$ns" get "$s" -o go-template="{{index .data \"$key\"}}")
				{
					printf '%s %s/%s[%s]\t%s\n' b64 "$ns" "${s#secret/}" "$key" "$b"
					printf '%s %s/%s[%s]\t%s\n' plain "$ns" "${s#secret/}" "$key" "$(printf '%s' "$b" | base64 -d)"
				} >>"$WORK/values"
			done
		done
	done
}
# run_job <name>: one run through the CronJob template; saves the log; rc of the Job
run_job() {
	local st="" p
	k -n teknoir-system create job "$1" --from=cronjob/platform-secrets-resync >/dev/null
	for _ in $(seq 1 90); do
		st=$(k -n teknoir-system get job "$1" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}')
		case $st in *Complete* | *Failed*) break ;; esac
		sleep 2
	done
	# Logs of every attempt (a failed Job has one pod per retry).
	for p in $(k -n teknoir-system get pods -l "job-name=$1" -o name); do
		k -n teknoir-system logs "$p" >>"$LOGS/$1.log" 2>&1 || true
	done
	case $st in *Complete*) return 0 ;; *) return 1 ;; esac
}

echo "== cluster"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait \
	--k3s-arg '--disable=traefik,metrics-server,servicelb@server:0' >/dev/null
k3d image import -c "$CLUSTER" "$TOOLBOX" >/dev/null
k create namespace teknoir-system >/dev/null
k create namespace teknoir-auth >/dev/null
# Consumers whose restart is checked (sleepers on the toolbox image).
for d in teknoir-auth/oauth2-proxy teknoir-system/user-controller; do
	k -n "${d%%/*}" create deployment "${d#*/}" --image="$TOOLBOX" -- sleep 86400 >/dev/null
	k -n "${d%%/*}" patch deployment "${d#*/}" --type json \
		-p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null
done
# T2 fixture: an existing, adopted Secret with dummy values and a foreign label.
k -n teknoir-auth create secret generic keycloak-db-secret \
	--from-literal=username=keycloak --from-literal=password=pre-existing-dummy >/dev/null
k -n teknoir-auth label secret keycloak-db-secret objectset.rio.cattle.io/hash=dummy >/dev/null
db_rv0=$(rv teknoir-auth keycloak-db-secret)

echo "== T1 bootstrap one-shot (server-side apply as argocd-controller)"
helm template platform-secrets "$CHART" >"$WORK/render.yaml"
k apply --server-side --field-manager=argocd-controller --force-conflicts -f "$WORK/render.yaml" >/dev/null
if k -n teknoir-system wait --for=condition=complete job/platform-secrets-ensure --timeout=180s >/dev/null; then
	ok "T1 one-shot Job completed"
else
	bad "T1 one-shot Job did not complete"
fi
for p in $(k -n teknoir-system get pods -l job-name=platform-secrets-ensure -o name); do
	k -n teknoir-system logs "$p" >>"$LOGS/oneshot.log" 2>&1 || true
done
cat "$LOGS/oneshot.log"
missing=0
while read -r ns name keys; do
	for key in ${keys//,/ }; do
		if ! k -n "$ns" get secret "$name" -o go-template="{{index .data \"$key\"}}" 2>/dev/null | grep -q .; then
			echo "  missing $ns/$name key $key"
			missing=1
		fi
	done
done <<'EOF'
teknoir-auth keycloak-client-secrets teknoir,argocd,harbor,user-controller
teknoir-auth keycloak-admin username,password
teknoir-auth keycloak-db-secret username,password
teknoir-auth oauth2-proxy-secret client-secret,cookie-secret
teknoir-auth oauth2-proxy-redis-secret password
teknoir-system harbor-secret HARBOR_ADMIN_PASSWORD,secretKey,secret,CSRF_KEY,JOBSERVICE_SECRET,REGISTRY_HTTP_SECRET,database-password,redis-password
teknoir-system harbor-oidc-secret client-secret
teknoir-system argocd-oidc-secret oidc.auth.clientSecret
teknoir-system backstage-keycloak-secrets KEYCLOAK_REALM,KEYCLOAK_CLIENTID,KEYCLOAK_CLIENTSECRET
teknoir-system backstage-postgres-secrets POSTGRES_USER,POSTGRES_PASSWORD,DATA_SOURCE_USER,DATA_SOURCE_PASS
teknoir-system backstage-backend-auth backend-auth-backstage-secrets.yaml
EOF
[ "$missing" -eq 0 ] && ok "T1 all Secrets and keys exist" || bad "T1 Secrets/keys missing"
[ "$(k -n teknoir-system get secret argocd-oidc-secret -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}')" = argocd ] &&
	ok "T1 argocd-oidc-secret carries part-of=argocd" || bad "T1 argocd label missing"
[ -z "$(k -n teknoir-auth get secret oauth2-proxy-secret -o jsonpath='{.metadata.annotations.teknoir\.org/restart-pending}')" ] &&
	ok "T1 restart marker cleared after create" || bad "T1 restart marker left behind"

echo "== T2 adoption"
[ "$(get_key teknoir-auth keycloak-db-secret password)" = pre-existing-dummy ] &&
	ok "T2 adopted password unchanged" || bad "T2 adopted password changed"
[ "$(k -n teknoir-auth get secret keycloak-db-secret -o jsonpath='{.metadata.labels.teknoir\.org/managed-by}')" = platform-secrets ] &&
	[ "$(k -n teknoir-auth get secret keycloak-db-secret -o jsonpath='{.metadata.labels.objectset\.rio\.cattle\.io/hash}')" = dummy ] &&
	ok "T2 label added, foreign label kept" || bad "T2 labels wrong"
[ "$(rv teknoir-auth keycloak-db-secret)" != "$db_rv0" ] || bad "T2 expected a label patch"

echo "== T3 formats"
[ "$(get_key teknoir-system backstage-postgres-secrets DATA_SOURCE_PASS)" = "$(get_key teknoir-system backstage-postgres-secrets POSTGRES_PASSWORD)" ] &&
	ok "T3 DATA_SOURCE_PASS equals POSTGRES_PASSWORD" || bad "T3 same-Secret copy"
ba=$(get_key teknoir-system backstage-backend-auth backend-auth-backstage-secrets.yaml)
[[ "$ba" =~ ^secret:\ [A-Za-z0-9]{48}$ ]] && ok "T3 backend-auth format" || bad "T3 backend-auth format"
ck=$(get_key teknoir-auth oauth2-proxy-secret cookie-secret)
[ "$(printf '%s=' "$ck" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c)" -eq 32 ] &&
	ok "T3 cookie-secret is 32 bytes (base64url)" || bad "T3 cookie-secret length"
[ "${#ck}" -eq 43 ] || bad "T3 cookie-secret should be 43 chars"
sk=$(get_key teknoir-system harbor-secret secretKey)
[ "${#sk}" -eq 16 ] && ok "T3 harbor secretKey is 16 chars" || bad "T3 harbor secretKey length"
[ "$(get_key teknoir-system backstage-keycloak-secrets KEYCLOAK_REALM)" = teknoir ] &&
	[ "$(get_key teknoir-system backstage-keycloak-secrets KEYCLOAK_CLIENTSECRET)" = "$(get_key teknoir-auth keycloak-client-secrets user-controller)" ] &&
	ok "T3 backstage-keycloak-secrets realm + copied client secret" || bad "T3 backstage-keycloak-secrets"

snap_values
echo "== T4 idempotency"
all_rvs >"$WORK/rv1"
run_job rerun1 && ok "T4 re-run succeeded" || bad "T4 re-run failed"
run_job rerun2 || bad "T4 second re-run failed"
all_rvs >"$WORK/rv2"
diff -u "$WORK/rv1" "$WORK/rv2" && ok "T4 no resourceVersion changed over 2 re-runs" || bad "T4 resourceVersions changed"
grep -q '0 created, 0 updated, 11 unchanged, 0 failed' "$LOGS/rerun2.log" && ok "T4 summary reports 11 unchanged" || bad "T4 summary"

echo "== T5 delete one Secret"
k -n teknoir-auth delete secret oauth2-proxy-redis-secret >/dev/null
run_job rerun3 || bad "T5 run failed"
all_rvs >"$WORK/rv3"
changed=$(diff "$WORK/rv2" "$WORK/rv3" | grep -c '^>' || true)
[ "$changed" -eq 1 ] && grep -q '^> teknoir-auth/oauth2-proxy-redis-secret' <(diff "$WORK/rv2" "$WORK/rv3") &&
	ok "T5 only oauth2-proxy-redis-secret re-created" || bad "T5 changed: $changed"

echo "== T6 rotate a copy source"
r0=$(k -n teknoir-auth get deploy oauth2-proxy -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
newv=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
printf '{"data":{"teknoir":"%s"}}' "$(printf '%s' "$newv" | base64 -w0)" |
	k -n teknoir-auth patch secret keycloak-client-secrets --type merge --patch-file=/dev/stdin >/dev/null
sleep 1
run_job rerun4 || bad "T6 run failed"
[ "$(get_key teknoir-auth oauth2-proxy-secret client-secret)" = "$newv" ] && ok "T6 client-secret re-synced" || bad "T6 client-secret not re-synced"
r1=$(k -n teknoir-auth get deploy oauth2-proxy -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')
[ -n "$r1" ] && [ "$r1" != "$r0" ] && ok "T6 oauth2-proxy restarted" || bad "T6 oauth2-proxy not restarted"
[ -z "$(k -n teknoir-auth get secret oauth2-proxy-secret -o jsonpath='{.metadata.annotations.teknoir\.org/restart-pending}')" ] &&
	ok "T6 restart marker cleared" || bad "T6 marker left"
grep -q 'teknoir-auth/oauth2-proxy-secret: synced keys: client-secret' "$LOGS/rerun4.log" && ok "T6 log names the key" || bad "T6 log"

echo "== T7 failed restart is retried"
k -n teknoir-system patch role platform-secrets --type json -p '[{"op":"remove","path":"/rules/3"}]' >/dev/null
newv2=$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
printf '{"data":{"user-controller":"%s"}}' "$(printf '%s' "$newv2" | base64 -w0)" |
	k -n teknoir-auth patch secret keycloak-client-secrets --type merge --patch-file=/dev/stdin >/dev/null
if run_job rerun5; then bad "T7 run should fail when the restart is forbidden"; else ok "T7 run failed on forbidden restart"; fi
[ "$(k -n teknoir-system get secret backstage-keycloak-secrets -o jsonpath='{.metadata.annotations.teknoir\.org/restart-pending}')" = updated ] &&
	ok "T7 restart marker kept" || bad "T7 marker missing"
k apply --server-side --field-manager=argocd-controller --force-conflicts -f "$WORK/render.yaml" >/dev/null
sleep 1
run_job rerun6 && ok "T7 retry run succeeded" || bad "T7 retry run failed"
[ -n "$(k -n teknoir-system get deploy user-controller -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}')" ] &&
	[ -z "$(k -n teknoir-system get secret backstage-keycloak-secrets -o jsonpath='{.metadata.annotations.teknoir\.org/restart-pending}')" ] &&
	ok "T7 user-controller restarted on retry, marker cleared" || bad "T7 retry"

snap_values
echo "== T8 errors are not absent"
k -n teknoir-auth delete rolebinding platform-secrets >/dev/null
k -n teknoir-auth delete secret oauth2-proxy-redis-secret >/dev/null
if run_job rerun7; then bad "T8 run should fail"; else ok "T8 run failed on Forbidden"; fi
grep -q 'teknoir-auth/keycloak-admin: cannot read it' "$LOGS/rerun7.log" && ok "T8 Forbidden reported as a read error" || bad "T8 message"
k -n teknoir-auth get secret oauth2-proxy-redis-secret >/dev/null 2>&1 && bad "T8 created despite errors" || ok "T8 nothing created in the forbidden namespace"
k apply --server-side --field-manager=argocd-controller --force-conflicts -f "$WORK/render.yaml" >/dev/null

echo "== T9 RBAC"
sa=system:serviceaccount:teknoir-system:platform-secrets
[ "$(k auth can-i get secret/monitoring-grafana -n teknoir-system --as=$sa)" = no ] && ok "T9 unlisted Secret get denied" || bad "T9 unlisted get allowed"
[ "$(k auth can-i list secrets -n teknoir-system --as=$sa)" = no ] && ok "T9 list denied" || bad "T9 list allowed"
[ "$(k auth can-i get secret/keycloak-admin -n teknoir-auth --as=$sa)" = yes ] && ok "T9 listed Secret get allowed" || bad "T9 listed get denied"
[ "$(k auth can-i patch deployment/keycloak -n teknoir-auth --as=$sa)" = no ] && ok "T9 unlisted Deployment patch denied" || bad "T9 deployment patch"
[ "$(k auth can-i delete secret/keycloak-admin -n teknoir-auth --as=$sa)" = no ] && ok "T9 delete denied" || bad "T9 delete allowed"

echo "== T10 concurrent runs on empty namespaces"
snap_values
for s in $(k -n teknoir-auth get secret -l teknoir.org/managed-by=platform-secrets -o name); do k -n teknoir-auth delete "$s" >/dev/null; done
for s in $(k -n teknoir-system get secret -l teknoir.org/managed-by=platform-secrets -o name); do k -n teknoir-system delete "$s" >/dev/null; done
for j in conc-a conc-b; do k -n teknoir-system create job "$j" --from=cronjob/platform-secrets-resync >/dev/null; done
okc=0
for j in conc-a conc-b; do
	if k -n teknoir-system wait --for=condition=complete "job/$j" --timeout=120s >/dev/null 2>&1; then okc=$((okc + 1)); fi
	for p in $(k -n teknoir-system get pods -l "job-name=$j" -o name); do
		k -n teknoir-system logs "$p" >>"$LOGS/$j.log" 2>&1 || true
	done
done
[ "$okc" -eq 2 ] && ok "T10 both concurrent runs succeeded" || { bad "T10 concurrent runs: $okc/2"; cat "$LOGS"/conc-*.log; }
[ "$(get_key teknoir-auth oauth2-proxy-secret client-secret)" = "$(get_key teknoir-auth keycloak-client-secrets teknoir)" ] &&
	ok "T10 copies consistent after the race" || bad "T10 copies inconsistent"

echo "== T11 never print"
snap_values
printf 'plain rotated-1\t%s\nplain rotated-2\t%s\nplain adopted-dummy\tpre-existing-dummy\n' "$newv" "$newv2" >>"$WORK/values"
cat "$LOGS"/*.log >"$WORK/all.log"
leaks=0
checked=0
while IFS=$'\t' read -r id val; do
	[ "${#val}" -ge 8 ] || continue
	checked=$((checked + 1))
	if grep -qF -- "$val" "$WORK/all.log"; then
		key=${id##*[}
		key=${key%]}
		case $LITERAL_KEYS in
		*" $key "*) echo "  (literal, not secret) value of $id appears in a Job log" ;;
		*)
			echo "  LEAK: value of $id appears in a Job log"
			leaks=$((leaks + 1))
			;;
		esac
	fi
done <"$WORK/values"
[ "$leaks" -eq 0 ] && ok "T11 0 leaks: $checked values vs $(wc -l <"$WORK/all.log") log lines" || bad "T11 $leaks values leak"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
