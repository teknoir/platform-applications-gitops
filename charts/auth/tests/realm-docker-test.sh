#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# SC2016: the single-quoted strings are scripts run inside the toolbox.
# shellcheck disable=SC2015,SC2016
# Tests the auth chart's realm-as-code against a real Keycloak in docker (not
# packaged: .helmignore tests/). No Kubernetes needed.
#
#   charts/auth/tests/realm-docker-test.sh
#
# Renders the chart, extracts the realm file and keycloak-admin-check.sh from
# the keycloak-config ConfigMap, and runs them with the chart's pinned images
# (keycloak-config-cli, toolbox; as user 65534 with a read-only root file
# system and a /tmp tmpfs, like the Job) against quay.io/keycloak/keycloak (same
# version as the keycloak-theme image), configured like the chart
# (http-relative-path /auth, KC_HOSTNAME, xforwarded). Checks:
#   R1 admin-check fails clearly when the admin password is unknown
#   R2 admin-check rotates the admin password from previous-password
#   R3 admin-check is a no-op once the password matches
#   R4 keycloak-config-cli imports realm teknoir (exit 0)
#   R5 user-controller: client-credentials token, list/create/delete users
#   R6 every client's secret equals the injected value
#   R7 example token of the teknoir client carries sub, email,
#      email_verified and groups=[admin]
#   R8 second import is a no-op and succeeds; a changed client secret is
#      applied on the next import
#   R9 no secret value in any container log
#   R10 platform-admin: created in group admin with a complete profile; a
#       browser login with the initial password gets exactly one form (Update
#       Password, no profile form) and a code; after re-imports the changed
#       password still logs in with no form, the initial one is rejected
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
KC_IMAGE=${KC_IMAGE:-quay.io/keycloak/keycloak:26.5.3}
NET=tkauth-test
KC=tkauth-kc
pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

WORK=$(mktemp -d)
cleanup() {
	docker rm -f "$KC" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT

rand() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }

# Render once; pull images and files out of the render.
[ -d "$CHART/charts" ] || helm dependency build "$CHART" >/dev/null
helm template auth "$CHART" --namespace teknoir-auth >"$WORK/render.yaml"
yq() { docker run --rm -i docker.io/alpine/k8s:1.34.11 yq "$@"; }
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-config") | .data["teknoir.yaml"]' <"$WORK/render.yaml" >"$WORK/teknoir.yaml"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-config") | .data["keycloak-admin-check.sh"]' <"$WORK/render.yaml" >"$WORK/keycloak-admin-check.sh"
CLI_IMAGE=$(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].image' <"$WORK/render.yaml")
TOOLBOX=$(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.initContainers[0].image' <"$WORK/render.yaml")
# The Job's env: literal values are used as rendered (except the in-cluster
# URL); every secretKeyRef must have a test value in SECRET_ENV below.
mapfile -t CLI_ENV < <(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].env[] | select(has("value") and .name != "KEYCLOAK_URL") | .name + "=" + .value' <"$WORK/render.yaml")
mapfile -t CLI_SECRET_ENV < <(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].env[] | select(has("valueFrom")) | .name' <"$WORK/render.yaml")
mkdir -p "$WORK/config"
cp "$WORK/teknoir.yaml" "$WORK/config/teknoir.yaml"
chmod -R a+rX "$WORK"
echo "keycloak-config-cli: $CLI_IMAGE  toolbox: $TOOLBOX  keycloak: $KC_IMAGE"

BOOT_PW=$(rand)  # what Keycloak created the admin with ("the old password")
NEW_PW=$(rand)   # keycloak-admin/password
PA_PW=$(rand)    # keycloak-platform-admin/password (initial, temporary)
PA_NEW=$(rand)   # what platform-admin changes it to at first login
declare -A CS=([TEKNOIR_CLIENT_SECRET]=$(rand) [ARGOCD_CLIENT_SECRET]=$(rand) [HARBOR_CLIENT_SECRET]=$(rand) [USER_CONTROLLER_CLIENT_SECRET]=$(rand))
printf '%s\n' "$BOOT_PW" "$NEW_PW" "$PA_PW" "$PA_NEW" "${CS[@]}" >"$WORK/values"

docker network create "$NET" >/dev/null
docker run -d --name "$KC" --network "$NET" -m 1200m \
	-e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD="$BOOT_PW" \
	-e KC_HTTP_RELATIVE_PATH=/auth -e KC_HOSTNAME=auth.teknoir.airgapped -e KC_PROXY_HEADERS=xforwarded \
	-e KC_HEALTH_ENABLED=true -e KC_HTTP_ENABLED=true \
	"$KC_IMAGE" start-dev --hostname-strict=false >/dev/null

# toolbox <env...> -- <sh script>: runs in the test network with $WORK at /w
toolbox() {
	local envs=()
	while [ "$1" != -- ]; do
		envs+=(-e "$1")
		shift
	done
	shift
	docker run --rm --network "$NET" -u 65534:65534 --read-only -v "$WORK:/w:ro" --tmpfs /tmp:mode=1777 "${envs[@]}" \
		--entrypoint /bin/sh "$TOOLBOX" -c "$1"
}
URL=http://$KC:8080/auth

echo "== waiting for Keycloak"
for _ in $(seq 1 90); do
	toolbox -- "curl -fsS -o /dev/null $URL/realms/master" 2>/dev/null && break
	sleep 2
done

echo "== R1-R3 admin-check"
if toolbox KEYCLOAK_URL=$URL KC_ADMIN_USER=admin KC_ADMIN_PASSWORD="$NEW_PW" -- 'sh /w/keycloak-admin-check.sh' >"$WORK/r1.log" 2>&1; then
	bad "R1 admin-check should fail without previous-password"
else
	grep -q 'previous-password' "$WORK/r1.log" && ok "R1 fails and names previous-password" || bad "R1 message"
fi
toolbox KEYCLOAK_URL=$URL KC_ADMIN_USER=admin KC_ADMIN_PASSWORD="$NEW_PW" KC_ADMIN_PREVIOUS_PASSWORD="$BOOT_PW" -- 'sh /w/keycloak-admin-check.sh' >"$WORK/r2.log" 2>&1 &&
	grep -q 'admin password rotated' "$WORK/r2.log" && ok "R2 rotated from previous-password" || { bad "R2 rotation"; cat "$WORK/r2.log"; }
toolbox KEYCLOAK_URL=$URL KC_ADMIN_USER=admin KC_ADMIN_PASSWORD="$NEW_PW" KC_ADMIN_PREVIOUS_PASSWORD="$BOOT_PW" -- 'sh /w/keycloak-admin-check.sh' >"$WORK/r3.log" 2>&1 &&
	grep -q 'logs in with the password from Secret' "$WORK/r3.log" && ok "R3 no-op when the password matches" || bad "R3"

# import: runs keycloak-config-cli like the Job does, with the Job's env
import() {
	local -A secret_env=([KEYCLOAK_USER]=admin [KEYCLOAK_PASSWORD]="$NEW_PW"
		[PLATFORM_ADMIN_USERNAME]=platform-admin [PLATFORM_ADMIN_PASSWORD]="$PA_PW")
	local k args=()
	for k in "${!CS[@]}"; do secret_env[$k]=${CS[$k]}; done
	for k in "${CLI_SECRET_ENV[@]}"; do
		[ -n "${secret_env[$k]:-}" ] || {
			echo "the Job reads $k from a Secret; the test has no value for it" >&2
			return 1
		}
		args+=(-e "$k=${secret_env[$k]}")
	done
	for k in "${CLI_ENV[@]}"; do args+=(-e "$k"); done
	docker run --rm --network "$NET" -u 65534:65534 --read-only -v "$WORK/config:/config:ro" --tmpfs /tmp:mode=1777 \
		-m 512m -e KEYCLOAK_URL=$URL "${args[@]}" "$CLI_IMAGE"
}
echo "== R4 import"
if import >"$WORK/import1.log" 2>&1; then ok "R4 first import succeeded"; else
	bad "R4 first import failed"
	tail -40 "$WORK/import1.log"
fi

# Admin token (master) as a file in the toolbox; checks print only verdicts.
CHECK='set -eu
cd /tmp
tok() { curl -fsS --data-urlencode grant_type=password --data-urlencode client_id=admin-cli --data-urlencode username=admin --data-urlencode "password=$NEW_PW" "$URL/realms/master/protocol/openid-connect/token" | jq -r .access_token; }
H="Authorization: Bearer $(tok)"
api() { curl -fsS -H "$H" "$URL/admin/realms/teknoir$1"; }
'
echo "== R5 user-controller service account"
toolbox URL=$URL NEW_PW="$NEW_PW" UCS="${CS[USER_CONTROLLER_CLIENT_SECRET]}" -- "$CHECK"'
t=$(curl -fsS --data-urlencode grant_type=client_credentials --data-urlencode client_id=user-controller --data-urlencode "client_secret=$UCS" "$URL/realms/teknoir/protocol/openid-connect/token" | jq -r .access_token)
A="Authorization: Bearer $t"
curl -fsS -o /dev/null -H "$A" "$URL/admin/realms/teknoir/users?email=nobody@example.com" && echo "list-users ok"
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "$A" -H "Content-Type: application/json" -d "{\"username\":\"probe@example.com\",\"email\":\"probe@example.com\",\"enabled\":true,\"emailVerified\":true,\"firstName\":\"Probe\"}" "$URL/admin/realms/teknoir/users")
echo "create-user $code"
id=$(curl -fsS -H "$A" "$URL/admin/realms/teknoir/users?email=probe@example.com&exact=true" | jq -r ".[0].id")
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "$A" -H "Content-Type: application/json" -d "{\"type\":\"password\",\"value\":\"Tmp-$(date +%s)-x\",\"temporary\":true}" "$URL/admin/realms/teknoir/users/$id/reset-password")
echo "set-password $code"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE -H "$A" "$URL/admin/realms/teknoir/users/$id")
echo "delete-user $code"
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "$A" "$URL/admin/realms/teknoir/clients")
echo "list-clients $code"
' >"$WORK/r5.log" 2>&1 || true
cat "$WORK/r5.log"
grep -q 'list-users ok' "$WORK/r5.log" && grep -q 'create-user 201' "$WORK/r5.log" && grep -q 'set-password 204' "$WORK/r5.log" &&
	grep -q 'delete-user 204' "$WORK/r5.log" && ok "R5 user-controller can list/create/set-password/delete users" || bad "R5 user-controller permissions"
grep -q 'list-clients 403' "$WORK/r5.log" && ok "R5 user-controller cannot read clients (least privilege)" || bad "R5 user-controller sees clients"

echo "== R6 client secrets"
toolbox URL=$URL NEW_PW="$NEW_PW" S_teknoir="${CS[TEKNOIR_CLIENT_SECRET]}" S_argocd="${CS[ARGOCD_CLIENT_SECRET]}" \
	S_harbor="${CS[HARBOR_CLIENT_SECRET]}" S_user_controller="${CS[USER_CONTROLLER_CLIENT_SECRET]}" -- "$CHECK"'
for c in teknoir argocd harbor user-controller; do
  id=$(api "/clients?clientId=$c" | jq -r ".[0].id")
  have=$(api "/clients/$id/client-secret" | jq -r .value)
  want=$(eval "printf %s \"\$S_$(echo $c | tr - _)\"")
  [ "$have" = "$want" ] && echo "secret-match $c" || echo "secret-MISMATCH $c"
done
api "/client-scopes" | jq -r ".[].name" | grep -qx groups && echo "scope groups present"
api "/groups" | jq -r ".[].name" | grep -qx admin && echo "group admin present"
' >"$WORK/r6.log" 2>&1 || true
cat "$WORK/r6.log"
[ "$(grep -c '^secret-match' "$WORK/r6.log")" -eq 4 ] && ok "R6 all 4 client secrets equal the injected values" || bad "R6 client secrets"
grep -q 'scope groups present' "$WORK/r6.log" && grep -q 'group admin present' "$WORK/r6.log" && ok "R6 groups scope and admin group exist" || bad "R6 scope/group"

echo "== R7 token claims (teknoir client, user in group admin)"
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK"'
curl -fsS -o /dev/null -H "$H" -H "Content-Type: application/json" -d "{\"username\":\"claims@example.com\",\"email\":\"claims@example.com\",\"enabled\":true,\"emailVerified\":true,\"firstName\":\"C\",\"lastName\":\"L\"}" "$URL/admin/realms/teknoir/users"
uid=$(api "/users?email=claims@example.com&exact=true" | jq -r ".[0].id")
gid=$(api "/groups?search=admin" | jq -r ".[] | select(.name==\"admin\") | .id")
curl -fsS -o /dev/null -X PUT -H "$H" "$URL/admin/realms/teknoir/users/$uid/groups/$gid"
cid=$(api "/clients?clientId=teknoir" | jq -r ".[0].id")
api "/clients/$cid/evaluate-scopes/generate-example-access-token?scope=openid&userId=$uid" | jq -c "{sub: (.sub != null), email, email_verified, groups, iss, aud}"
cid=$(api "/clients?clientId=argocd" | jq -r ".[0].id")
api "/clients/$cid/evaluate-scopes/generate-example-id-token?scope=openid%20profile%20email%20groups&userId=$uid" | jq -c "{argocd_id_token_groups: .groups}"
' >"$WORK/r7.log" 2>&1 || true
cat "$WORK/r7.log"
grep -q '"sub":true' "$WORK/r7.log" && grep -q '"email":"claims@example.com"' "$WORK/r7.log" && grep -q '"email_verified":true' "$WORK/r7.log" &&
	grep -q '"groups":\["admin"\]' "$WORK/r7.log" && ok "R7 access token has sub, email, email_verified, groups" || bad "R7 claims"
grep -q '"argocd_id_token_groups":\["admin"\]' "$WORK/r7.log" && ok "R7 argocd ID token carries groups" || bad "R7 argocd groups"

# Browser login (authorization code flow of client argocd, no PKCE) as a
# script for the toolbox: Keycloak is addressed by its KC_HOSTNAME, routed to
# the container with --connect-to; redirects are followed only within
# Keycloak. Prints the forms it meets and the outcome, never a password.
cat >"$WORK/kc-browser.sh" <<'SH'
set -eu
cd /tmp
J=/tmp/jar P=/tmp/page H=/tmp/hdr CODE='' LOC=''
req() {
	_u=$1
	shift
	CODE=$(curl -sS --connect-to "$CONNECT" -c "$J" -b "$J" -D "$H" -o "$P" -w '%{http_code}' "$@" "$_u") || CODE=000
	LOC=$(awk 'tolower($1) == "location:" { print $2 }' "$H" | tr -d '\r')
}
follow() {
	while [ "${CODE#3}" != "$CODE" ]; do
		case $LOC in "$BASE"*) req "$LOC" ;; *) return 0 ;; esac
	done
}
action() {
	tr '\n' ' ' <"$P" | grep -oE "<form[^>]*id=\"$1\"[^>]*>" | head -1 |
		grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g'
}
req "$BASE/realms/teknoir/protocol/openid-connect/auth?client_id=argocd&response_type=code&scope=openid&state=st&redirect_uri=https%3A%2F%2Fargocd.teknoir.airgapped%2Fauth%2Fcallback"
follow
a=$(action kc-form-login) || a=''
[ -n "$a" ] || { echo "no-login-form $CODE"; exit 1; }
req "$a" --data-urlencode "username=$LOGIN" --data-urlencode "password=$PW" --data-urlencode credentialId=
follow
for _ in 1 2 3; do
	if a=$(action kc-passwd-update-form) && [ -n "$a" ]; then
		echo "form update-password"
		[ -n "${NEWPW:-}" ] || { echo "no-new-password"; exit 1; }
		req "$a" --data-urlencode "password-new=$NEWPW" --data-urlencode "password-confirm=$NEWPW"
		follow
	elif a=$(action kc-update-profile-form) && [ -n "$a" ]; then
		echo "form update-profile"
		exit 1
	else
		break
	fi
done
case $LOC in
https://argocd.teknoir.airgapped/auth/callback*code=*) echo "login-ok code-issued" ;;
*)
	if grep -q 'kc-form-login' "$P"; then echo "login-rejected"; else echo "login-failed $CODE"; fi
	exit 1
	;;
esac
SH
browser() { # browser <password> [<new password>]
	toolbox BASE=http://auth.teknoir.airgapped:8080/auth CONNECT=auth.teknoir.airgapped:8080:$KC:8080 \
		LOGIN=platform-admin PW="$1" NEWPW="${2:-}" -- 'sh /w/kc-browser.sh'
}

echo "== R10 platform-admin (initial login)"
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK"'
u=$(api "/users?username=platform-admin&exact=true")
echo "$u" | jq -c ".[0] | {enabled, emailVerified, email, firstName, lastName, requiredActions}"
id=$(echo "$u" | jq -r ".[0].id")
api "/users/$id/groups" | jq -c "{groups: [.[].path]}"
' >"$WORK/r10a.log" 2>&1 || true
cat "$WORK/r10a.log"
grep -q '"enabled":true,"emailVerified":true,"email":"platform-admin@teknoir.airgapped","firstName":"Platform","lastName":"Admin","requiredActions":\["UPDATE_PASSWORD"\]' "$WORK/r10a.log" &&
	grep -q '"groups":\["/admin"\]' "$WORK/r10a.log" && ok "R10 platform-admin created in group admin, profile complete, UPDATE_PASSWORD" || bad "R10 platform-admin user"
browser "$PA_PW" "$PA_NEW" >"$WORK/r10b.log" 2>&1 || true
cat "$WORK/r10b.log"
[ "$(grep -c '^form ' "$WORK/r10b.log")" -eq 1 ] && grep -q '^form update-password' "$WORK/r10b.log" && grep -q '^login-ok' "$WORK/r10b.log" &&
	ok "R10 first login: exactly one form (Update Password), then a code" || bad "R10 first login"

echo "== R8 idempotency and secret change"
if import >"$WORK/import2.log" 2>&1; then ok "R8 second import succeeded"; else
	bad "R8 second import failed"
	tail -30 "$WORK/import2.log"
fi
CS[ARGOCD_CLIENT_SECRET]=$(rand)
printf '%s\n' "${CS[ARGOCD_CLIENT_SECRET]}" >>"$WORK/values"
import >"$WORK/import3.log" 2>&1 || bad "R8 third import failed"
toolbox URL=$URL NEW_PW="$NEW_PW" S="${CS[ARGOCD_CLIENT_SECRET]}" -- "$CHECK"'
id=$(api "/clients?clientId=argocd" | jq -r ".[0].id")
[ "$(api "/clients/$id/client-secret" | jq -r .value)" = "$S" ] && echo rotated-ok || echo rotated-NOT
n=$(api "/clients" | jq "[.[] | select(.clientId==\"argocd\")] | length")
echo "argocd-clients $n"
' >"$WORK/r8.log" 2>&1 || true
cat "$WORK/r8.log"
grep -q rotated-ok "$WORK/r8.log" && ok "R8 changed client secret applied" || bad "R8 secret change"
grep -q 'argocd-clients 1' "$WORK/r8.log" && ok "R8 no duplicate clients" || bad "R8 duplicates"

echo "== R10 platform-admin after re-imports"
browser "$PA_NEW" >"$WORK/r10c.log" 2>&1 || true
cat "$WORK/r10c.log"
! grep -q '^form ' "$WORK/r10c.log" && grep -q '^login-ok' "$WORK/r10c.log" &&
	ok "R10 changed password survives 2 re-imports, no required action re-added" || bad "R10 after re-import"
browser "$PA_PW" >"$WORK/r10d.log" 2>&1 || true
grep -q '^login-rejected' "$WORK/r10d.log" && ok "R10 initial password no longer works" || { bad "R10 initial password"; cat "$WORK/r10d.log"; }

echo "== R9 never print"
docker logs "$KC" >"$WORK/kc.log" 2>&1 || true
cat "$WORK"/*.log >"$WORK/all.log"
leaks=$(grep -c -F -f "$WORK/values" "$WORK/all.log" || true)
[ "$leaks" -eq 0 ] && ok "R9 no secret value in $(wc -l <"$WORK/all.log") log lines" || bad "R9 $leaks lines leak a value"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
