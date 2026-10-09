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
# 5. With the admin logged in: deletes the legacy clients of realm master
#    named in KC_MASTER_LEGACY_CLIENTS (comma-separated clientIds), each only
#    when realm KC_REALM has a client with the same clientId (proof that the
#    move to KC_REALM happened). Keycloak deletes the client's service-account
#    user with it. Built-in clients are never deleted. Idempotent: a client
#    that is gone is skipped. Logs client names only.
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

# rotate: the admin password from previous-password to password (step 3).
# Leaves a fresh admin token in $T/token.
rotate() {
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
	rm -f "$T/body" "$T/auth" "$T/token" "$T/prev"
	[ "$code" = 204 ] || die "password reset returned HTTP $code"

	code=$(login "$T/pw")
	[ "$code" = 200 ] || die "admin login still fails after the rotation (HTTP $code)"
	log "admin password rotated; key previous-password of Secret keycloak-admin can now be removed"
}

# builtin_client <clientId>: true for Keycloak's own clients, which are never
# deleted (the chart refuses them at render time as well).
builtin_client() {
	case $1 in
	admin-cli | security-admin-console | broker | master-realm | realm-management | account* | *-realm) return 0 ;;
	esac
	return 1
}

# find_client <realm> <clientId>: writes the client's internal id to $T/cid
# (an empty file when there is none; no newline); prints the HTTP status code.
# An answer that is not a client list, or that has the clientId more than once,
# is not "200": the callers then stop without deleting anything.
find_client() {
	rm -f "$T/clients" "$T/cid"
	_code=$(curl -sS -m 20 -o "$T/clients" -w '%{http_code}' -H @"$T/auth" -G \
		--data-urlencode "clientId=$2" "$KC/admin/realms/$1/clients") || _code=000
	if [ "$_code" = 200 ]; then
		jq -j --arg c "$2" '[.[] | select(.clientId == $c)] | if length > 1 then error("clientId \($c) more than once") else (.[0].id // "") end' \
			<"$T/clients" >"$T/cid" || _code="200 with an unusable answer (not a client list, or clientId '$2' more than once)"
	fi
	rm -f "$T/clients"
	printf '%s' "$_code"
}

# remove_master_legacy_clients: step 5. Needs the admin token in $T/token.
remove_master_legacy_clients() {
	[ -n "${KC_MASTER_LEGACY_CLIENTS:-}" ] || return 0
	realm=${KC_REALM:-teknoir}
	if [ "$realm" = master ]; then
		log "WARNING: KC_REALM is master; not deleting any legacy client"
		return 0
	fi
	printf 'Authorization: Bearer %s\n' "$(cat "$T/token")" >"$T/auth"
	set -f
	for c in $(printf '%s' "$KC_MASTER_LEGACY_CLIENTS" | tr ',' ' '); do
		case $c in
		*[!A-Za-z0-9._-]*)
			log "WARNING: not deleting master client '$c': not a plain clientId"
			continue
			;;
		esac
		if builtin_client "$c"; then
			log "WARNING: not deleting master client '$c': it is a Keycloak built-in client"
			continue
		fi
		code=$(find_client master "$c")
		[ "$code" = 200 ] || die "looking up client '$c' in realm master returned HTTP $code"
		mid=$(cat "$T/cid")
		if [ -z "$mid" ]; then
			log "realm master has no legacy client '$c'"
			continue
		fi
		code=$(find_client "$realm" "$c")
		case $code in
		200) ;;
		404)
			log "keeping master client '$c': realm $realm does not exist yet"
			continue
			;;
		*) die "looking up client '$c' in realm $realm returned HTTP $code" ;;
		esac
		# The guard: delete only what realm $realm already has. (Read into a
		# variable: an id file is never tested by size, a newline is not an id.)
		rid=$(cat "$T/cid")
		if [ -z "$rid" ]; then
			log "keeping master client '$c': realm $realm has no client '$c' (not migrated)"
			continue
		fi
		code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X DELETE -H @"$T/auth" \
			"$KC/admin/realms/master/clients/$mid") || code=000
		case $code in
		204) log "deleted legacy client '$c' from realm master (realm $realm has its own '$c')" ;;
		404) log "legacy client '$c' was already gone from realm master" ;;
		*) die "deleting client '$c' from realm master returned HTTP $code" ;;
		esac
	done
	set +f
	rm -f "$T/auth" "$T/cid"
}

printf '%s' "$KC_ADMIN_PASSWORD" >"$T/pw"
code=$(login "$T/pw")
if [ "$code" = 200 ]; then
	log "admin '$KC_ADMIN_USER' logs in with the password from Secret keycloak-admin"
else
	[ "$code" = 401 ] || [ "$code" = 400 ] || die "admin login returned HTTP $code"
	rotate
fi
remove_master_legacy_clients
