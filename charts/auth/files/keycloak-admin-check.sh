#!/bin/sh
# keycloak-admin-check.sh: init step of the keycloak-config Job.
#
# 1. Waits until Keycloak answers on KEYCLOAK_URL.
# 2. Checks that the master-realm admin (KC_ADMIN_USER / KC_ADMIN_PASSWORD,
#    from Secret keycloak-admin) can log in.
# 3. If not, and KC_ADMIN_PREVIOUS_PASSWORD (optional key previous-password of
#    the same Secret) still works, sets the admin's password to
#    KC_ADMIN_PASSWORD through the admin REST API and checks again. This is how
#    a rotation of keycloak-admin (or the one-time move away from the old
#    published bootstrap password) reaches Keycloak without kcadm by hand:
#    KC_BOOTSTRAP_ADMIN_PASSWORD only applies when Keycloak creates the admin.
# 4. Otherwise fails with what to do.
#
# Never prints a credential or token: they live in variables and in 0600
# files on the pod's memory-backed /tmp, passed to curl as @file arguments.
# POSIX sh; needs curl and jq (docker.io/alpine/k8s toolbox).
set -eu
umask 077

KC=${KEYCLOAK_URL%/}
: "${KC_ADMIN_USER:?}" "${KC_ADMIN_PASSWORD:?}"
PREV=${KC_ADMIN_PREVIOUS_PASSWORD:-}
WAIT=${KC_WAIT_SECONDS:-600}

log() { printf 'keycloak-admin-check: %s\n' "$*"; }
die() {
	printf 'keycloak-admin-check: ERROR: %s\n' "$*" >&2
	exit 1
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT INT TERM
printf '%s' "$KC_ADMIN_USER" >"$T/user"

i=0
until curl -fsS -o /dev/null -m 5 "$KC/realms/master"; do
	i=$((i + 5))
	[ "$i" -lt "$WAIT" ] || die "Keycloak at $KC is not reachable after ${WAIT}s"
	sleep 5
done
log "Keycloak is reachable"

# login <password-file>: writes the access token to $T/token; prints the HTTP
# status code (only the code).
login() {
	rm -f "$T/token" "$T/resp"
	_code=$(curl -sS -m 20 -o "$T/resp" -w '%{http_code}' \
		--data-urlencode grant_type=password --data-urlencode client_id=admin-cli \
		--data-urlencode "username@$T/user" --data-urlencode "password@$1" \
		"$KC/realms/master/protocol/openid-connect/token") || _code=000
	if [ "$_code" = 200 ]; then
		jq -er .access_token <"$T/resp" >"$T/token" || _code=000
	fi
	rm -f "$T/resp"
	printf '%s' "$_code"
}

printf '%s' "$KC_ADMIN_PASSWORD" >"$T/pw"
code=$(login "$T/pw")
if [ "$code" = 200 ]; then
	log "admin '$KC_ADMIN_USER' logs in with the password from Secret keycloak-admin"
	exit 0
fi
[ "$code" = 401 ] || [ "$code" = 400 ] || die "admin login returned HTTP $code"

if [ -z "$PREV" ]; then
	die "admin '$KC_ADMIN_USER' cannot log in with the password from Secret keycloak-admin (HTTP $code). Keycloak only applies KC_BOOTSTRAP_ADMIN_PASSWORD when it creates the admin. Put the admin's current password in key previous-password of Secret teknoir-auth/keycloak-admin; this Job then rotates it (see the auth chart README)."
fi

printf '%s' "$PREV" >"$T/prev"
code=$(login "$T/prev")
[ "$code" = 200 ] || die "admin '$KC_ADMIN_USER' cannot log in with password or previous-password from Secret keycloak-admin (HTTP $code)"
log "previous password accepted; rotating the admin password to the one in Secret keycloak-admin"

printf 'Authorization: Bearer %s\n' "$(cat "$T/token")" >"$T/auth"
code=$(curl -sS -m 20 -o "$T/users" -w '%{http_code}' -H @"$T/auth" -G \
	--data-urlencode "username@$T/user" --data-urlencode exact=true \
	"$KC/admin/realms/master/users") || code=000
[ "$code" = 200 ] || die "looking up admin user returned HTTP $code"
uid=$(jq -er 'if length == 1 then .[0].id else error("expected exactly one user") end' <"$T/users") ||
	die "admin user '$KC_ADMIN_USER' not found exactly once in realm master"

jq -n --rawfile v "$T/pw" '{type: "password", value: $v, temporary: false}' >"$T/body"
code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X PUT -H @"$T/auth" \
	-H 'Content-Type: application/json' --data-binary @"$T/body" \
	"$KC/admin/realms/master/users/$uid/reset-password") || code=000
rm -f "$T/body" "$T/auth" "$T/token"
[ "$code" = 204 ] || die "password reset returned HTTP $code"

code=$(login "$T/pw")
[ "$code" = 200 ] || die "admin login still fails after the rotation (HTTP $code)"
log "admin password rotated; key previous-password of Secret keycloak-admin can now be removed"
