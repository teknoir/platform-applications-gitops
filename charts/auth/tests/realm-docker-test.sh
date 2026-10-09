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
#       (rendered with realm.platformAdmin.enabled=true; the default is false)
#   R11 legacy master-realm clients (keycloakConfig.masterLegacyClients, the
#       admin-check's last step): seeded like the pre-redesign layout
#       (teknoir with a service account holding master-realm manage-users,
#       argocd, harbor). Before realm teknoir exists they are kept (guard).
#       The legacy teknoir service account can reset the master admin's
#       password (the severity). After the import the step deletes them and
#       their service-account users; their secrets get 401 on realm master;
#       the admin still logs in; built-in clients, an unlisted master client
#       and realm teknoir's clients are kept; a second run is a no-op; built-in
#       names are refused even when realm teknoir has the same clientId
#   R12 platform-admin with the default values (enabled: false): disabled by
#       the import, its login is refused, a console re-enable is reverted by
#       the next import, other users are unaffected
#   R13 realm sign-in/out: client teknoir accepts post_logout_redirect_uri
#       https://<domain>/... (not another host); VERIFY_PROFILE is disabled,
#       so a user without a last name signs in with no profile form; enabling
#       it brings the form back and the next import disables it again
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
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

# Render; pull images and files out of the render. The main render enables
# platform-admin (R10 exercises its first login); R12 imports the default
# render, where it is disabled.
command -v yq >/dev/null || yq() { docker run --rm -i docker.io/alpine/k8s:1.34.11 yq "$@"; }
# shellcheck source-path=SCRIPTDIR source=lib.sh disable=SC1091
. "$HERE/lib.sh"
auth_chart_copy "$WORK/chart"
auth_render "$WORK/chart" "$WORK/render.yaml" --set realm.platformAdmin.enabled=true
auth_render "$WORK/chart" "$WORK/render-default.yaml"
rm -rf "$WORK/chart"
realm_file() { yq -r 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-config") | .data["teknoir.yaml"]' <"$1"; }
realm_file "$WORK/render.yaml" >"$WORK/teknoir.yaml"
realm_file "$WORK/render-default.yaml" >"$WORK/teknoir-default.yaml"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-config") | .data["keycloak-admin-check.sh"]' <"$WORK/render.yaml" >"$WORK/keycloak-admin-check.sh"
CLI_IMAGE=$(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].image' <"$WORK/render.yaml")
TOOLBOX=$(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.initContainers[0].image' <"$WORK/render.yaml")
# The Job's env: literal values are used as rendered (except the in-cluster
# URL); every secretKeyRef must have a test value in SECRET_ENV below.
mapfile -t CLI_ENV < <(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].env[] | select(has("value") and .name != "KEYCLOAK_URL") | .name + "=" + .value' <"$WORK/render.yaml")
mapfile -t CLI_SECRET_ENV < <(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.containers[0].env[] | select(has("valueFrom")) | .name' <"$WORK/render.yaml")
# The admin-check init container's literal env (KC_MASTER_LEGACY_CLIENTS,
# KC_REALM), except the in-cluster URL.
mapfile -t ADMIN_ENV < <(yq -r 'select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.initContainers[0].env[] | select(has("value") and .name != "KEYCLOAK_URL") | .name + "=" + .value' <"$WORK/render.yaml")
mkdir -p "$WORK/config" "$WORK/config-default"
cp "$WORK/teknoir.yaml" "$WORK/config/teknoir.yaml"
cp "$WORK/teknoir-default.yaml" "$WORK/config-default/teknoir.yaml"
chmod -R a+rX "$WORK"
echo "keycloak-config-cli: $CLI_IMAGE  toolbox: $TOOLBOX  keycloak: $KC_IMAGE"
echo "admin-check env: ${ADMIN_ENV[*]}"

BOOT_PW=$(rand)  # what Keycloak created the admin with ("the old password")
NEW_PW=$(rand)   # keycloak-admin/password
PA_PW=$(rand)    # keycloak-platform-admin/password (initial, temporary)
PA_NEW=$(rand)   # what platform-admin changes it to at first login
declare -A CS=([TEKNOIR_CLIENT_SECRET]=$(rand) [ARGOCD_CLIENT_SECRET]=$(rand) [HARBOR_CLIENT_SECRET]=$(rand) [USER_CONTROLLER_CLIENT_SECRET]=$(rand))
MH_SECRET=$(rand) # the legacy master harbor client's own secret (R11)
NL_PW=$(rand)     # password of the user without a last name (R13)
printf '%s\n' "$BOOT_PW" "$NEW_PW" "$PA_PW" "$PA_NEW" "${CS[@]}" "$MH_SECRET" "$NL_PW" >"$WORK/values"

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

# admin_check <env...>: runs the rendered keycloak-admin-check.sh like the
# init container (its rendered literal env first, then the arguments).
admin_check() {
	toolbox KEYCLOAK_URL=$URL KC_ADMIN_USER=admin "${ADMIN_ENV[@]}" "$@" -- 'sh /w/keycloak-admin-check.sh'
}

echo "== R1-R3 admin-check"
if admin_check KC_ADMIN_PASSWORD="$NEW_PW" >"$WORK/r1.log" 2>&1; then
	bad "R1 admin-check should fail without previous-password"
else
	grep -q 'previous-password' "$WORK/r1.log" && ok "R1 fails and names previous-password" || bad "R1 message"
fi
admin_check KC_ADMIN_PASSWORD="$NEW_PW" KC_ADMIN_PREVIOUS_PASSWORD="$BOOT_PW" >"$WORK/r2.log" 2>&1 &&
	grep -q 'admin password rotated' "$WORK/r2.log" && ok "R2 rotated from previous-password" || { bad "R2 rotation"; cat "$WORK/r2.log"; }
admin_check KC_ADMIN_PASSWORD="$NEW_PW" KC_ADMIN_PREVIOUS_PASSWORD="$BOOT_PW" >"$WORK/r3.log" 2>&1 &&
	grep -q 'logs in with the password from Secret' "$WORK/r3.log" && ok "R3 no-op when the password matches" || bad "R3"
[ "$(grep -c "realm master has no legacy client" "$WORK/r3.log")" -eq 3 ] && ok "R3 legacy-client step runs with the rendered list (none present)" ||
	{ bad "R3 legacy-client step"; cat "$WORK/r3.log"; }

# Admin token (master) as a file in the toolbox; checks print only verdicts.
CHECK='set -eu
cd /tmp
tok() { curl -fsS --data-urlencode grant_type=password --data-urlencode client_id=admin-cli --data-urlencode username=admin --data-urlencode "password=$NEW_PW" "$URL/realms/master/protocol/openid-connect/token" | jq -r .access_token; }
H="Authorization: Bearer $(tok)"
api() { curl -fsS -H "$H" "$URL/admin/realms/teknoir$1"; }
mapi() { curl -fsS -H "$H" "$URL/admin/realms/master$1"; }
'

echo "== R11 seed the legacy master-realm clients (pre-redesign layout)"
toolbox URL=$URL NEW_PW="$NEW_PW" S_teknoir="${CS[TEKNOIR_CLIENT_SECRET]}" S_argocd="${CS[ARGOCD_CLIENT_SECRET]}" S_harbor="$MH_SECRET" -- "$CHECK"'
mk() { curl -sS -o /dev/null -w "%{http_code}" -H "$H" -H "Content-Type: application/json" -d "$1" "$URL/admin/realms/master/clients"; }
echo "seed teknoir $(mk "{\"clientId\":\"teknoir\",\"enabled\":true,\"publicClient\":false,\"secret\":\"$S_teknoir\",\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":true,\"redirectUris\":[\"https://teknoir.airgapped/oauth2/callback\"]}")"
echo "seed argocd $(mk "{\"clientId\":\"argocd\",\"enabled\":true,\"publicClient\":false,\"secret\":\"$S_argocd\",\"standardFlowEnabled\":true,\"redirectUris\":[\"https://argocd.teknoir.airgapped/auth/callback\"]}")"
echo "seed harbor $(mk "{\"clientId\":\"harbor\",\"enabled\":true,\"publicClient\":false,\"secret\":\"$S_harbor\",\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,\"redirectUris\":[\"https://harbor.teknoir.airgapped/c/oidc/callback\"]}")"
echo "seed keep-me $(mk "{\"clientId\":\"keep-me\",\"enabled\":true,\"publicClient\":true,\"standardFlowEnabled\":true,\"redirectUris\":[\"https://example.org/*\"]}")"
cid=$(mapi "/clients?clientId=teknoir" | jq -r ".[0].id")
sa=$(mapi "/clients/$cid/service-account-user" | jq -r .id)
mr=$(mapi "/clients?clientId=master-realm" | jq -r ".[0].id")
mapi "/clients/$mr/roles" | jq -c "[.[] | select(.name == \"manage-users\" or .name == \"query-users\" or .name == \"view-users\")]" >/tmp/roles
echo "grant $(curl -sS -o /dev/null -w "%{http_code}" -H "$H" -H "Content-Type: application/json" -d @/tmp/roles "$URL/admin/realms/master/users/$sa/role-mappings/clients/$mr") $(jq length /tmp/roles)"
' >"$WORK/r11-seed.log" 2>&1 || true
cat "$WORK/r11-seed.log"
[ "$(grep -cE '^seed (teknoir|argocd|harbor|keep-me) 201$' "$WORK/r11-seed.log")" -eq 4 ] && grep -q '^grant 204 3$' "$WORK/r11-seed.log" &&
	ok "R11 seeded master clients teknoir (manage-users), argocd, harbor, keep-me" || bad "R11 seeding"
admin_check KC_ADMIN_PASSWORD="$NEW_PW" >"$WORK/r11-guard.log" 2>&1 || bad "R11 admin-check failed before the import"
cat "$WORK/r11-guard.log"
[ "$(grep -c "realm teknoir does not exist yet" "$WORK/r11-guard.log")" -eq 3 ] && ! grep -q 'deleted' "$WORK/r11-guard.log" &&
	ok "R11 before realm teknoir exists the legacy clients are kept (guard)" || bad "R11 guard on an unmigrated install"

# import [<config dir>]: runs keycloak-config-cli like the Job does, with the
# Job's env (default: the main render's realm file)
import() {
	local config=${1:-$WORK/config}
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
	docker run --rm --network "$NET" -u 65534:65534 --read-only -v "$config:/config:ro" --tmpfs /tmp:mode=1777 \
		-m 512m -e KEYCLOAK_URL=$URL "${args[@]}" "$CLI_IMAGE"
}
echo "== R4 import"
if import >"$WORK/import1.log" 2>&1; then ok "R4 first import succeeded"; else
	bad "R4 first import failed"
	tail -40 "$WORK/import1.log"
fi

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
https://argocd.teknoir.airgapped/auth/callback*code=*)
	echo "login-ok code-issued"
	[ -n "${LOGOUT_URI:-}" ] || exit 0
	# RP-initiated logout as Backstage sends it (client_id=teknoir and
	# post_logout_redirect_uri, no id_token_hint): the confirmation page, its
	# POST, the redirect back, and no silent login afterwards.
	req "$BASE/realms/teknoir/protocol/openid-connect/logout?client_id=teknoir&post_logout_redirect_uri=$LOGOUT_URI"
	a=$(tr '\n' ' ' <"$P" | grep -oE '<form[^>]*action="[^"]*logout-confirm[^"]*"' | head -1 |
		grep -oE 'action="[^"]*"' | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g') || a=''
	[ "$CODE" = 200 ] && [ -n "$a" ] || { echo "logout-no-confirm-page $CODE"; exit 1; }
	echo "logout-confirm-page ${a%%\?*}"
	case $a in /*) a=$(printf '%s' "$BASE" | sed -E 's#^(https?://[^/]+).*#\1#')$a ;; esac
	sc=$(tr '\n' ' ' <"$P" | grep -oE '<input[^>]*name="session_code"[^>]*>' | grep -oE 'value="[^"]*"' | sed -e 's/^value="//' -e 's/"$//') || sc=''
	req "$a" --data-urlencode "session_code=$sc" --data-urlencode "confirmLogout=Logout"
	echo "logout-redirect $CODE $LOC"
	req "$BASE/realms/teknoir/protocol/openid-connect/auth?client_id=argocd&response_type=code&scope=openid&state=st2&redirect_uri=https%3A%2F%2Fargocd.teknoir.airgapped%2Fauth%2Fcallback"
	follow
	if a=$(action kc-form-login) && [ -n "$a" ]; then echo "after-logout login-form"; else echo "after-logout no-login-form $CODE"; fi
	;;
*)
	if grep -qi 'account is disabled' "$P"; then
		echo "login-rejected account-disabled"
	elif grep -q 'kc-form-login' "$P"; then
		echo "login-rejected"
	else
		echo "login-failed $CODE"
	fi
	exit 1
	;;
esac
SH
browser() { # browser <login> <password> [<new password>]   (LOGOUT_URI: also log out)
	toolbox BASE=http://auth.teknoir.airgapped:8080/auth CONNECT=auth.teknoir.airgapped:8080:$KC:8080 \
		LOGIN="$1" PW="$2" NEWPW="${3:-}" LOGOUT_URI="${LOGOUT_URI:-}" -- 'sh /w/kc-browser.sh'
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
browser platform-admin "$PA_PW" "$PA_NEW" >"$WORK/r10b.log" 2>&1 || true
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
browser platform-admin "$PA_NEW" >"$WORK/r10c.log" 2>&1 || true
cat "$WORK/r10c.log"
! grep -q '^form ' "$WORK/r10c.log" && grep -q '^login-ok' "$WORK/r10c.log" &&
	ok "R10 changed password survives 2 re-imports, no required action re-added" || bad "R10 after re-import"
browser platform-admin "$PA_PW" >"$WORK/r10d.log" 2>&1 || true
grep -q '^login-rejected' "$WORK/r10d.log" && ok "R10 initial password no longer works" || { bad "R10 initial password"; cat "$WORK/r10d.log"; }

echo "== R11 legacy master-realm clients after the import"
# The severity: the legacy teknoir client's service account (master-realm
# manage-users, secret shared with oauth2-proxy) can reset the master admin's
# password. It is reset to the same value, so nothing changes.
toolbox URL=$URL NEW_PW="$NEW_PW" S="${CS[TEKNOIR_CLIENT_SECRET]}" -- '
set -eu
t=$(curl -fsS --data-urlencode grant_type=client_credentials --data-urlencode client_id=teknoir --data-urlencode "client_secret=$S" "$URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)
A="Authorization: Bearer $t"
uid=$(curl -fsS -H "$A" "$URL/admin/realms/master/users?username=admin&exact=true" | jq -r ".[0].id")
echo "{\"type\":\"password\",\"value\":\"$NEW_PW\",\"temporary\":false}" >/tmp/body
echo "severity reset-master-admin-password $(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "$A" -H "Content-Type: application/json" -d @/tmp/body "$URL/admin/realms/master/users/$uid/reset-password")"
' >"$WORK/r11-severity.log" 2>&1 || true
cat "$WORK/r11-severity.log"
grep -q '^severity reset-master-admin-password 204$' "$WORK/r11-severity.log" &&
	ok "R11 severity: the legacy teknoir service account resets the master admin's password" || bad "R11 severity not shown"
admin_check KC_ADMIN_PASSWORD="$NEW_PW" >"$WORK/r11-delete.log" 2>&1 || bad "R11 admin-check failed"
cat "$WORK/r11-delete.log"
[ "$(grep -c "deleted legacy client '[a-z]*' from realm master" "$WORK/r11-delete.log")" -eq 3 ] &&
	ok "R11 admin-check deletes the 3 legacy master clients" || bad "R11 deletion log"
R11_STATE='
for c in teknoir argocd harbor; do echo "master-$c $(mapi "/clients?clientId=$c" | jq length)"; done
for u in service-account-teknoir service-account-harbor; do echo "master-user-$u $(mapi "/users?username=$u&exact=true" | jq length)"; done
for c in admin-cli security-admin-console broker master-realm account account-console teknoir-realm keep-me; do echo "kept-$c $(mapi "/clients?clientId=$c" | jq length)"; done
for c in teknoir argocd harbor user-controller account-console admin-cli broker realm-management security-admin-console; do echo "teknoir-$c $(api "/clients?clientId=$c" | jq length)"; done
cc() { curl -sS -o /dev/null -w "%{http_code}" --data-urlencode grant_type=client_credentials --data-urlencode "client_id=$1" --data-urlencode "client_secret=$2" "$URL/realms/master/protocol/openid-connect/token"; }
echo "old-secret teknoir $(cc teknoir "$S_teknoir")"
echo "old-secret harbor $(cc harbor "$S_harbor")"
echo "admin-login $(curl -sS -o /dev/null -w "%{http_code}" --data-urlencode grant_type=password --data-urlencode client_id=admin-cli --data-urlencode username=admin --data-urlencode "password=$NEW_PW" "$URL/realms/master/protocol/openid-connect/token")"
'
toolbox URL=$URL NEW_PW="$NEW_PW" S_teknoir="${CS[TEKNOIR_CLIENT_SECRET]}" S_harbor="$MH_SECRET" -- "$CHECK$R11_STATE" >"$WORK/r11-state.log" 2>&1 || true
cat "$WORK/r11-state.log"
[ "$(grep -cE '^master-(teknoir|argocd|harbor) 0$' "$WORK/r11-state.log")" -eq 3 ] &&
	[ "$(grep -cE '^master-user-service-account-(teknoir|harbor) 0$' "$WORK/r11-state.log")" -eq 2 ] &&
	ok "R11 the legacy clients and their service-account users are gone from realm master" || bad "R11 legacy clients remain"
grep -q '^old-secret teknoir 401$' "$WORK/r11-state.log" && grep -q '^old-secret harbor 401$' "$WORK/r11-state.log" &&
	ok "R11 the old client secrets get 401 on realm master" || bad "R11 old secrets still work"
grep -q '^admin-login 200$' "$WORK/r11-state.log" && ok "R11 the master admin still logs in" || bad "R11 admin login"
! grep -qE '^kept-.* [^1]$' "$WORK/r11-state.log" && [ "$(grep -c '^kept-' "$WORK/r11-state.log")" -eq 8 ] &&
	ok "R11 built-in master clients, teknoir-realm and the unlisted keep-me are kept" || bad "R11 a kept client is missing"
! grep -qE '^teknoir-.* [^1]$' "$WORK/r11-state.log" && [ "$(grep -c '^teknoir-' "$WORK/r11-state.log")" -eq 9 ] &&
	ok "R11 realm teknoir's clients are untouched" || bad "R11 realm teknoir clients"
admin_check KC_ADMIN_PASSWORD="$NEW_PW" >"$WORK/r11-again.log" 2>&1 &&
	[ "$(grep -c "realm master has no legacy client" "$WORK/r11-again.log")" -eq 3 ] && ! grep -q deleted "$WORK/r11-again.log" &&
	ok "R11 second run is a no-op" || { bad "R11 second run"; cat "$WORK/r11-again.log"; }
# Built-in names: realm teknoir has its own admin-cli, broker, ... so only the
# name guard protects them (the chart refuses them at render time as well).
admin_check KC_ADMIN_PASSWORD="$NEW_PW" KC_MASTER_LEGACY_CLIENTS=admin-cli,security-admin-console,broker,master-realm,realm-management,account,account-console,teknoir-realm \
	>"$WORK/r11-builtin.log" 2>&1 || bad "R11 admin-check failed with built-in names"
cat "$WORK/r11-builtin.log"
toolbox URL=$URL NEW_PW="$NEW_PW" S_teknoir=x S_harbor=x -- "$CHECK$R11_STATE" >"$WORK/r11-state2.log" 2>&1 || true
[ "$(grep -c 'it is a Keycloak built-in client' "$WORK/r11-builtin.log")" -eq 8 ] && ! grep -q deleted "$WORK/r11-builtin.log" &&
	! grep -qE '^kept-.* [^1]$' "$WORK/r11-state2.log" && [ "$(grep -c '^kept-' "$WORK/r11-state2.log")" -eq 8 ] &&
	ok "R11 built-in client names are refused and the clients kept" || bad "R11 built-in guard"

echo "== R13 realm sign-in/out settings"
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK"'
cid=$(api "/clients?clientId=teknoir" | jq -r ".[0].id")
api "/clients/$cid" | jq -r "\"post-logout \" + .attributes[\"post.logout.redirect.uris\"]"
api "/authentication/required-actions/VERIFY_PROFILE" | jq -r "\"verify-profile enabled=\" + (.enabled | tostring)"
' >"$WORK/r13a.log" 2>&1 || true
cat "$WORK/r13a.log"
grep -qx 'post-logout https://teknoir.airgapped/\*' "$WORK/r13a.log" && ok "R13 client teknoir post.logout.redirect.uris https://teknoir.airgapped/*" || bad "R13 post.logout.redirect.uris"
grep -qx 'verify-profile enabled=false' "$WORK/r13a.log" && ok "R13 VERIFY_PROFILE disabled by the import" || bad "R13 VERIFY_PROFILE"
# RP-initiated logout without a session (client_id + post_logout_redirect_uri,
# no id_token_hint): Keycloak redirects straight back for the platform host
# and rejects any other host. The signed-in flow follows below.
toolbox BASE=http://auth.teknoir.airgapped:8080/auth CONNECT=auth.teknoir.airgapped:8080:$KC:8080 -- '
lo() { curl -sS --connect-to "$CONNECT" -o /dev/null -w "%{http_code} %{redirect_url}" "$BASE/realms/teknoir/protocol/openid-connect/logout?client_id=teknoir&post_logout_redirect_uri=$1"; }
echo "logout-root $(lo https%3A%2F%2Fteknoir.airgapped%2F)"
echo "logout-path $(lo https%3A%2F%2Fteknoir.airgapped%2Fcatalog)"
echo "logout-subdomain $(lo https%3A%2F%2Fgrafana.teknoir.airgapped%2F)"
echo "logout-foreign $(lo https%3A%2F%2Fevil.example%2F)"
' >"$WORK/r13b.log" 2>&1 || true
cat "$WORK/r13b.log"
grep -qx 'logout-root 302 https://teknoir.airgapped/' "$WORK/r13b.log" && grep -qx 'logout-path 302 https://teknoir.airgapped/catalog' "$WORK/r13b.log" &&
	ok "R13 post_logout_redirect_uri https://teknoir.airgapped/... is accepted" || bad "R13 logout redirect accepted"
grep -qE '^logout-subdomain 400 ?$' "$WORK/r13b.log" && grep -qE '^logout-foreign 400 ?$' "$WORK/r13b.log" &&
	ok "R13 logout to another host is rejected (400)" || bad "R13 logout to another host"
toolbox URL=$URL NEW_PW="$NEW_PW" NL_PW="$NL_PW" -- "$CHECK"'
echo "{\"username\":\"nolast@example.com\",\"email\":\"nolast@example.com\",\"enabled\":true,\"emailVerified\":true,\"firstName\":\"Nolast\",\"credentials\":[{\"type\":\"password\",\"value\":\"$NL_PW\",\"temporary\":false}]}" >/tmp/u
echo "create-nolast $(curl -sS -o /dev/null -w "%{http_code}" -H "$H" -H "Content-Type: application/json" -d @/tmp/u "$URL/admin/realms/teknoir/users")"
' >"$WORK/r13c.log" 2>&1 || true
cat "$WORK/r13c.log"
browser nolast@example.com "$NL_PW" >"$WORK/r13d.log" 2>&1 || true
cat "$WORK/r13d.log"
grep -q '^create-nolast 201$' "$WORK/r13c.log" && ! grep -q '^form ' "$WORK/r13d.log" && grep -q '^login-ok' "$WORK/r13d.log" &&
	ok "R13 a user without a last name signs in with no profile form" || bad "R13 no-last-name login"
LOGOUT_URI=https%3A%2F%2Fteknoir.airgapped%2F browser nolast@example.com "$NL_PW" >"$WORK/r13h.log" 2>&1 || true
cat "$WORK/r13h.log"
grep -q '^login-ok' "$WORK/r13h.log" && grep -q '^logout-confirm-page' "$WORK/r13h.log" &&
	grep -qx 'logout-redirect 302 https://teknoir.airgapped/' "$WORK/r13h.log" && grep -q '^after-logout login-form' "$WORK/r13h.log" &&
	ok "R13 signed-in logout: confirmation page, 302 to https://teknoir.airgapped/, then the login form" || bad "R13 signed-in logout"
# Sensitivity: with VERIFY_PROFILE enabled (Keycloak's default) the same login
# meets the profile form; the next import disables it again.
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK"'
api "/authentication/required-actions/VERIFY_PROFILE" | jq -c ".enabled = true" >/tmp/ra
echo "enable $(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "$H" -H "Content-Type: application/json" -d @/tmp/ra "$URL/admin/realms/teknoir/authentication/required-actions/VERIFY_PROFILE")"
' >"$WORK/r13e.log" 2>&1 || true
browser nolast@example.com "$NL_PW" >"$WORK/r13f.log" 2>&1 || true
cat "$WORK/r13e.log" "$WORK/r13f.log"
grep -q '^enable 204$' "$WORK/r13e.log" && grep -q '^form update-profile' "$WORK/r13f.log" &&
	ok "R13 with VERIFY_PROFILE enabled the profile form appears (the test can see it)" || bad "R13 sensitivity"
import >"$WORK/import4.log" 2>&1 || bad "R13 re-import failed"
browser nolast@example.com "$NL_PW" >"$WORK/r13g.log" 2>&1 || true
cat "$WORK/r13g.log"
! grep -q '^form ' "$WORK/r13g.log" && grep -q '^login-ok' "$WORK/r13g.log" &&
	ok "R13 the next import disables VERIFY_PROFILE again" || bad "R13 re-import did not disable VERIFY_PROFILE"

echo "== R12 platform-admin disabled (default values)"
if import "$WORK/config-default" >"$WORK/import5.log" 2>&1; then ok "R12 import of the default render succeeded"; else
	bad "R12 import of the default render failed"
	tail -30 "$WORK/import5.log"
fi
R12_STATE='
echo "platform-admin enabled=$(api "/users?username=platform-admin&exact=true" | jq -r ".[0].enabled")"
echo "claims enabled=$(api "/users?email=claims@example.com&exact=true" | jq -r ".[0].enabled")"
echo "nolast enabled=$(api "/users?email=nolast@example.com&exact=true" | jq -r ".[0].enabled")"
'
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK$R12_STATE" >"$WORK/r12a.log" 2>&1 || true
cat "$WORK/r12a.log"
grep -qx 'platform-admin enabled=false' "$WORK/r12a.log" && grep -qx 'claims enabled=true' "$WORK/r12a.log" && grep -qx 'nolast enabled=true' "$WORK/r12a.log" &&
	ok "R12 platform-admin disabled; other users still enabled" || bad "R12 enabled flags"
browser platform-admin "$PA_NEW" >"$WORK/r12b.log" 2>&1 || true
cat "$WORK/r12b.log"
grep -q '^login-rejected' "$WORK/r12b.log" && ok "R12 platform-admin login is refused ($(grep '^login-' "$WORK/r12b.log"))" || bad "R12 platform-admin can still log in"
browser nolast@example.com "$NL_PW" >"$WORK/r12c.log" 2>&1 || true
grep -q '^login-ok' "$WORK/r12c.log" && ok "R12 another realm user still signs in" || { bad "R12 other user"; cat "$WORK/r12c.log"; }
# Break-glass: the master admin re-enables platform-admin in the console; the
# next sync of auth disables it again.
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK"'
id=$(api "/users?username=platform-admin&exact=true" | jq -r ".[0].id")
echo "re-enable $(curl -sS -o /dev/null -w "%{http_code}" -X PUT -H "$H" -H "Content-Type: application/json" -d "{\"enabled\":true}" "$URL/admin/realms/teknoir/users/$id")"
echo "now enabled=$(api "/users/$id" | jq -r .enabled)"
' >"$WORK/r12d.log" 2>&1 || true
cat "$WORK/r12d.log"
import "$WORK/config-default" >"$WORK/import6.log" 2>&1 || bad "R12 re-import failed"
toolbox URL=$URL NEW_PW="$NEW_PW" -- "$CHECK$R12_STATE" >"$WORK/r12e.log" 2>&1 || true
cat "$WORK/r12e.log"
grep -q '^re-enable 204$' "$WORK/r12d.log" && grep -qx 'now enabled=true' "$WORK/r12d.log" &&
	grep -qx 'platform-admin enabled=false' "$WORK/r12e.log" && grep -qx 'claims enabled=true' "$WORK/r12e.log" &&
	ok "R12 a console re-enable is reverted by the next import" || bad "R12 re-import keeps platform-admin enabled"

echo "== R9 never print"
docker logs "$KC" >"$WORK/kc.log" 2>&1 || true
cat "$WORK"/*.log >"$WORK/all.log"
leaks=$(grep -c -F -f "$WORK/values" "$WORK/all.log" || true)
[ "$leaks" -eq 0 ] && ok "R9 no secret value in $(wc -l <"$WORK/all.log") log lines" || bad "R9 $leaks lines leak a value"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
