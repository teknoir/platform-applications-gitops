#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# Unit test of the legacy-client step of files/keycloak-admin-check.sh (step
# 5) with a stub curl that plays Keycloak's admin API from fixtures. Needs jq;
# no docker, no helm, no cluster (not packaged: .helmignore tests/). Runs the
# script under dash and busybox sh (the toolbox image's /bin/sh is busybox),
# whichever are installed. tests/realm-docker-test.sh R11 runs the same step
# against a real Keycloak.
#
#   charts/auth/tests/admin-check-test.sh
#   ADMIN_CHECK=<file> charts/auth/tests/admin-check-test.sh   (another script,
#                                                            e.g. a mutant)
#
#   U1  migrated: deletes exactly the master clients whose clientId realm
#       teknoir has (by the master client's id); keeps a listed client realm
#       teknoir lacks ("not migrated"); skips one realm master lacks
#   U2  realm teknoir missing (404): keeps every client, deletes nothing
#   U3  realm teknoir exists without the clients: keeps them ("not migrated")
#   U4  clientId twice in realm teknoir: fails, deletes nothing
#   U5  clientId twice in realm master: fails, deletes nothing
#   U6  realm master answers with similar clientIds only (no exact match):
#       nothing to delete
#   U7  built-in names: refused without a lookup, nothing deleted
#   U8  names that are not plain clientIds (glob, path, quote): refused
#       without a lookup
#   U9  KC_REALM=master, an empty or unset list: no lookup, no delete
#   U10 lookup errors (500 on either realm, a non-list answer): fail before
#       any delete
#   U11 DELETE 404 is "already gone" (exit 0); DELETE 500 fails
#   U12 the admin password and the token never appear in the output
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${ADMIN_CHECK:-$HERE/../files/keycloak-admin-check.sh}
command -v jq >/dev/null || {
	echo "admin-check-test: needs jq" >&2
	exit 2
}

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
PW=dummy-admin-pw-7f3a      # the test's admin password (dummy)
TOKEN=dummy-token-91c2e     # the stub's access token (dummy)

# The stub curl. Fixtures in $FIX: <realm>.json is the realm's client list
# (Keycloak filters by clientId: the stub does the same, unless
# <realm>.unfiltered exists); <realm>.code makes every lookup in that realm
# answer with that status (404: the realm does not exist); <realm>.body
# replaces the answer; delete.code is the DELETE status (default 204). Every
# call is logged to $FIX/calls as "<METHOD> <path> [clientId]" (no headers).
cat >"$W/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out= method=GET w= cid= url=
while [ $# -gt 0 ]; do
	case $1 in
	-o) out=$2; shift ;;
	-w) w=1; shift ;;
	-X) method=$2; shift ;;
	-H | -m) shift ;;
	--data-urlencode)
		case $2 in clientId=*) cid=${2#clientId=} ;; esac
		shift
		;;
	http://* | https://*) url=$1 ;;
	esac
	shift
done
path=${url#http://kc.test/auth}
body= code=200
case $path in
/realms/master)
	[ -z "$w" ] || { echo "stub: unexpected -w" >&2; exit 2; }
	exit 0
	;;
/realms/master/protocol/openid-connect/token)
	body="{\"access_token\":\"$TOKEN\"}"
	;;
/admin/realms/*/clients)
	realm=${path#/admin/realms/}
	realm=${realm%/clients}
	echo "GET $path $cid" >>"$FIX/calls"
	if [ -f "$FIX/$realm.code" ]; then
		code=$(cat "$FIX/$realm.code")
		body='{"error":"stub"}'
	elif [ -f "$FIX/$realm.body" ]; then
		body=$(cat "$FIX/$realm.body")
	elif [ -f "$FIX/$realm.unfiltered" ]; then
		body=$(cat "$FIX/$realm.json")
	else
		body=$(jq -c --arg c "$cid" '[.[] | select(.clientId == $c)]' "$FIX/$realm.json")
	fi
	;;
/admin/realms/master/clients/*)
	[ "$method" = DELETE ] || { echo "stub: unexpected $method $path" >&2; exit 2; }
	echo "DELETE $path" >>"$FIX/calls"
	code=204
	[ ! -f "$FIX/delete.code" ] || code=$(cat "$FIX/delete.code")
	;;
*)
	echo "UNEXPECTED $method $path" >>"$FIX/calls"
	code=599
	;;
esac
if [ -n "$out" ] && [ "$out" != /dev/null ]; then printf '%s' "$body" >"$out"; fi
[ -z "$w" ] || printf '%s' "$code"
EOF
chmod +x "$W/bin/curl"

SHELLS=()
command -v dash >/dev/null && SHELLS+=(dash)
command -v busybox >/dev/null && SHELLS+=("busybox sh")
[ "${#SHELLS[@]}" -gt 0 ] || SHELLS=(sh)

# fixture <name>: a fresh fixture dir in $FIX; realm master has the three
# legacy clients and the built-ins, realm teknoir the migrated three and its
# own built-ins
fixture() {
	FIX=$W/fix-$1
	rm -rf "$FIX" && mkdir -p "$FIX" && : >"$FIX/calls"
	cat >"$FIX/master.json" <<-'EOF'
		[{"id":"m-teknoir","clientId":"teknoir"},{"id":"m-argocd","clientId":"argocd"},
		 {"id":"m-harbor","clientId":"harbor"},{"id":"m-keep","clientId":"keep-me"},
		 {"id":"m-admin-cli","clientId":"admin-cli"},{"id":"m-sac","clientId":"security-admin-console"},
		 {"id":"m-broker","clientId":"broker"},{"id":"m-mr","clientId":"master-realm"},
		 {"id":"m-account","clientId":"account"},{"id":"m-ac","clientId":"account-console"},
		 {"id":"m-tr","clientId":"teknoir-realm"},{"id":"m-rm","clientId":"realm-management"}]
	EOF
	cat >"$FIX/teknoir.json" <<-'EOF'
		[{"id":"t-teknoir","clientId":"teknoir"},{"id":"t-argocd","clientId":"argocd"},
		 {"id":"t-harbor","clientId":"harbor"},{"id":"t-uc","clientId":"user-controller"},
		 {"id":"t-admin-cli","clientId":"admin-cli"},{"id":"t-sac","clientId":"security-admin-console"},
		 {"id":"t-broker","clientId":"broker"},{"id":"t-rm","clientId":"realm-management"},
		 {"id":"t-account","clientId":"account"},{"id":"t-ac","clientId":"account-console"},
		 {"id":"t-mr","clientId":"master-realm"},{"id":"t-tr","clientId":"teknoir-realm"}]
	EOF
}

# run <shell> <env...>: runs the script with the stub; output in $FIX/out,
# exit status in $FIX/rc
run() {
	local sh=$1
	shift
	# shellcheck disable=SC2086 # "busybox sh" is two words
	if env -i PATH="$W/bin:$PATH" FIX="$FIX" TOKEN="$TOKEN" KEYCLOAK_URL=http://kc.test/auth \
		KC_ADMIN_USER=admin KC_ADMIN_PASSWORD="$PW" KC_WAIT_SECONDS=5 "$@" $sh "$SCRIPT" >"$FIX/out" 2>&1; then
		echo 0 >"$FIX/rc"
	else
		echo $? >"$FIX/rc"
	fi
}
rc() { cat "$FIX/rc"; }
has() { grep -qxF "keycloak-admin-check: $1" "$FIX/out"; }
deletes() { { grep '^DELETE ' "$FIX/calls" || true; } | sed 's#^DELETE /admin/realms/master/clients/##' | sort | tr '\n' ' ' | sed 's/ $//'; }
lookups() { grep -c '^GET ' "$FIX/calls" || true; }
show() {
	sed 's/^/    | /' "$FIX/out"
	sed 's/^/    calls: /' "$FIX/calls"
}

for sh in "${SHELLS[@]}"; do
	s="[$sh]"
	echo "== $sh"

	fixture u1
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd,harbor,keep-me,gone KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ "$(deletes)" = "m-argocd m-harbor m-teknoir" ] &&
		has "deleted legacy client 'teknoir' from realm master (realm teknoir has its own 'teknoir')" &&
		has "keeping master client 'keep-me': realm teknoir has no client 'keep-me' (not migrated)" &&
		has "realm master has no legacy client 'gone'" &&
		[ "$(grep -c "^keycloak-admin-check: deleted legacy client" "$FIX/out")" -eq 3 ] &&
		ok "U1 $s migrated: deletes teknoir/argocd/harbor by their master ids, keeps the unmigrated keep-me" || {
		bad "U1 $s migrated"
		show
	}

	fixture u2
	echo 404 >"$FIX/teknoir.code"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd,harbor KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ -z "$(deletes)" ] &&
		[ "$(grep -c "realm teknoir does not exist yet" "$FIX/out")" -eq 3 ] &&
		ok "U2 $s realm teknoir missing: every client kept" || {
		bad "U2 $s realm missing"
		show
	}

	fixture u3
	echo '[{"id":"t-uc","clientId":"user-controller"}]' >"$FIX/teknoir.json"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd,harbor KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ -z "$(deletes)" ] &&
		has "keeping master client 'teknoir': realm teknoir has no client 'teknoir' (not migrated)" &&
		has "keeping master client 'harbor': realm teknoir has no client 'harbor' (not migrated)" &&
		[ "$(grep -c "(not migrated)" "$FIX/out")" -eq 3 ] &&
		ok "U3 $s realm teknoir without the clients: kept as not migrated" || {
		bad "U3 $s not migrated"
		show
	}

	fixture u4
	echo '[{"id":"t-teknoir","clientId":"teknoir"},{"id":"t-teknoir2","clientId":"teknoir"}]' >"$FIX/teknoir.json"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd KC_REALM=teknoir
	[ "$(rc)" != 0 ] && [ -z "$(deletes)" ] &&
		grep -qF "ERROR: looking up client 'teknoir' in realm teknoir returned HTTP 200 with an unusable answer (not a client list, or clientId 'teknoir' more than once)" "$FIX/out" &&
		ok "U4 $s clientId twice in realm teknoir: fails, nothing deleted" || {
		bad "U4 $s duplicate in realm teknoir"
		show
	}

	fixture u5
	echo '[{"id":"m-teknoir","clientId":"teknoir"},{"id":"m-teknoir2","clientId":"teknoir"}]' >"$FIX/master.json"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir KC_REALM=teknoir
	[ "$(rc)" != 0 ] && [ -z "$(deletes)" ] &&
		grep -qF "ERROR: looking up client 'teknoir' in realm master returned HTTP 200 with an unusable answer" "$FIX/out" &&
		ok "U5 $s clientId twice in realm master: fails, nothing deleted" || {
		bad "U5 $s duplicate in realm master"
		show
	}

	fixture u6
	echo '[{"id":"m-x","clientId":"teknoir-old"},{"id":"m-y","clientId":"argocd2"}]' >"$FIX/master.json"
	touch "$FIX/master.unfiltered"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ -z "$(deletes)" ] &&
		has "realm master has no legacy client 'teknoir'" && has "realm master has no legacy client 'argocd'" &&
		ok "U6 $s only similar clientIds in realm master: exact match required" || {
		bad "U6 $s exact match"
		show
	}

	fixture u7
	run "$sh" KC_MASTER_LEGACY_CLIENTS=admin-cli,security-admin-console,broker,master-realm,realm-management,account,account-console,teknoir-realm KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ -z "$(deletes)" ] && [ "$(lookups)" -eq 0 ] &&
		[ "$(grep -c "it is a Keycloak built-in client" "$FIX/out")" -eq 8 ] &&
		ok "U7 $s built-in names refused without a lookup" || {
		bad "U7 $s built-ins"
		show
	}

	fixture u8
	run "$sh" "KC_MASTER_LEGACY_CLIENTS=te*,../teknoir,x/y,a'b,%2e" KC_REALM=teknoir
	[ "$(rc)" = 0 ] && [ -z "$(deletes)" ] && [ "$(lookups)" -eq 0 ] &&
		[ "$(grep -c "not a plain clientId" "$FIX/out")" -eq 5 ] &&
		ok "U8 $s names that are not plain clientIds refused without a lookup" || {
		bad "U8 $s non-plain names"
		show
	}

	fixture u9
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir KC_REALM=master
	r1=$(rc) l1=$(lookups)
	grep -qF "WARNING: KC_REALM is master; not deleting any legacy client" "$FIX/out" && w1=1 || w1=0
	run "$sh" KC_MASTER_LEGACY_CLIENTS= KC_REALM=teknoir
	r2=$(rc) l2=$(lookups)
	run "$sh" KC_REALM=teknoir
	r3=$(rc) l3=$(lookups)
	[ "$r1$r2$r3" = 000 ] && [ "$l1$l2$l3" = 000 ] && [ "$w1" = 1 ] && [ -z "$(deletes)" ] &&
		ok "U9 $s KC_REALM=master, an empty or unset list: no lookup, no delete" || {
		bad "U9 $s off switches ($r1$r2$r3 $l1$l2$l3 $w1)"
		show
	}

	fixture u10
	echo 500 >"$FIX/teknoir.code"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd KC_REALM=teknoir
	r1=$(rc) d1=$(deletes)
	grep -qF "ERROR: looking up client 'teknoir' in realm teknoir returned HTTP 500" "$FIX/out" && e1=1 || e1=0
	fixture u10b
	echo 500 >"$FIX/master.code"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir KC_REALM=teknoir
	r2=$(rc) d2=$(deletes)
	grep -qF "ERROR: looking up client 'teknoir' in realm master returned HTTP 500" "$FIX/out" && e2=1 || e2=0
	fixture u10c
	echo '{"error":"not a list"}' >"$FIX/teknoir.body"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir KC_REALM=teknoir
	r3=$(rc) d3=$(deletes)
	grep -qF "returned HTTP 200 with an unusable answer" "$FIX/out" && e3=1 || e3=0
	[ "$r1" != 0 ] && [ "$r2" != 0 ] && [ "$r3" != 0 ] && [ -z "$d1$d2$d3" ] && [ "$e1$e2$e3" = 111 ] &&
		ok "U10 $s lookup errors (500 in either realm, a non-list answer) fail before any delete" || {
		bad "U10 $s lookup errors ($r1 $r2 $r3 $e1$e2$e3 '$d1$d2$d3')"
		show
	}

	fixture u11
	echo 404 >"$FIX/delete.code"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir KC_REALM=teknoir
	r1=$(rc)
	has "legacy client 'teknoir' was already gone from realm master" && g=1 || g=0
	fixture u11b
	echo 500 >"$FIX/delete.code"
	run "$sh" KC_MASTER_LEGACY_CLIENTS=teknoir,argocd KC_REALM=teknoir
	r2=$(rc)
	grep -qF "ERROR: deleting client 'teknoir' from realm master returned HTTP 500" "$FIX/out" && e=1 || e=0
	[ "$r1" = 0 ] && [ "$g" = 1 ] && [ "$r2" != 0 ] && [ "$e" = 1 ] && [ "$(deletes)" = m-teknoir ] &&
		ok "U11 $s DELETE 404 is already gone; DELETE 500 fails at the first client" || {
		bad "U11 $s delete status ($r1 $g $r2 $e)"
		show
	}

	cat "$W"/fix-*/out >"$W/all-out"
	! grep -qF -e "$PW" -e "$TOKEN" "$W/all-out" && ! grep -q UNEXPECTED "$W"/fix-*/calls &&
		ok "U12 $s no password or token in $(wc -l <"$W/all-out") output lines; no unexpected API call" ||
		bad "U12 $s a secret in the output, or an unexpected call"
	rm -rf "$W"/fix-*
done

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
