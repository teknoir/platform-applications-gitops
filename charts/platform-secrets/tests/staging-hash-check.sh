#!/usr/bin/env bash
# Read-only check that the platform-secrets copy on staging is in sync with
# its source, without ever printing either value. Light: one or two
# `kubectl get` per Secret, nothing is written. Not packaged (.helmignore tests/).
#
#   charts/platform-secrets/tests/staging-hash-check.sh [--context CTX]
#       [--source NS/SECRET/KEY] [--copy NS/SECRET/KEY]
#
# Defaults: --context r415
#           --source  teknoir-auth/oauth2-proxy-secret/client-secret
#           --copy    teknoir-system/backstage-keycloak-secrets/KEYCLOAK_CLIENTSECRET
#
# stdout is exactly one line:
#   EQUAL      both values read, sha256 of the decoded values match    exit 0
#   DIFFERENT  both values read, the hashes differ                     exit 1
#   ERROR      a read failed, or a value is missing or empty           exit 2
# On ERROR, stderr names the failing read and the reason (names only).
#
# Rollout use (plan S1, STG-C1):
#   pre-check, before the merge     DIFFERENT (the stale K3s copy)
#   step 6, after the Job ran       EQUAL
#   STG-C2, after a k3s restart     EQUAL
#
# Why it is written this way (do not "simplify" it into a one-liner):
#   - The value read is captured in a variable and its stderr is discarded.
#     When a template fails, kubectl prints the whole object, .data included:
#     go-template errors print it on stdout and jsonpath errors on stderr
#     ("object given to jsonpath engine was"), so neither `2>/dev/null` nor a
#     pipe alone keeps it off the terminal.
#   - A non-zero rc or an empty value is ERROR, never a hash. A missing key
#     prints nothing with rc 0, and a wrong context or Forbidden prints
#     nothing on stdout, so two failed reads would otherwise hash the same
#     and print EQUAL.
#   - Diagnostics come from `get -o name`, which cannot print data.
#   - xtrace is switched off first: `bash -x` would trace the variables.
#   - Only `kubectl get` runs, always with an explicit --context.
set +x
set -uo pipefail
export LC_ALL=C

CTX=r415
SRC=teknoir-auth/oauth2-proxy-secret/client-secret
DST=teknoir-system/backstage-keycloak-secrets/KEYCLOAK_CLIENTSECRET

err() { printf 'staging-hash-check: %s\n' "$*" >&2; }
die() {
	err "$@"
	echo ERROR
	exit 2
}
usage() {
	err "usage: $0 [--context CTX] [--source NS/SECRET/KEY] [--copy NS/SECRET/KEY]"
	echo ERROR
	exit 2
}

while [ $# -gt 0 ]; do
	case $1 in
	--context | --source | --copy)
		[ $# -ge 2 ] || die "$1 needs a value"
		case $1 in --context) CTX=$2 ;; --source) SRC=$2 ;; --copy) DST=$2 ;; esac
		shift 2
		;;
	--context=*) CTX=${1#*=} && shift ;;
	--source=*) SRC=${1#*=} && shift ;;
	--copy=*) DST=${1#*=} && shift ;;
	*) usage ;;
	esac
done

[ -n "$CTX" ] || die "empty --context"
# NS/SECRET/KEY. The key goes into a jsonpath, so it is limited to the Secret
# key characters without '.' (a dot would select a nested field).
ref_re='^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-.a-z0-9]*[a-z0-9])?/[-_A-Za-z0-9]+$'
for ref in "$SRC" "$DST"; do
	[[ $ref =~ $ref_re ]] || die "not NS/SECRET/KEY (key without '.'): $ref"
done

sha() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-64
}

# why NS NAME KEY: the reason a read failed, from `get -o name` (no data).
why() {
	local e
	if e=$(kubectl --context "$CTX" --request-timeout=20s -n "$1" get secret "$2" -o name 2>&1 >/dev/null); then
		err "$1/$2: key $3 is missing or empty"
	else
		err "$1/$2: $(printf '%s' "$e" | head -n 1 | cut -c1-300)"
	fi
}

# value_hash NS/SECRET/KEY: sha256 of the decoded value on stdout, or rc 1
# with the reason on stderr.
value_hash() {
	local ns=${1%%/*} rest=${1#*/} name key v d
	name=${rest%%/*}
	key=${rest#*/}
	if ! v=$(kubectl --context "$CTX" --request-timeout=20s -n "$ns" get secret "$name" \
		-o "jsonpath={.data.$key}" 2>/dev/null) || [ -z "$v" ]; then
		v=
		why "$ns" "$name" "$key"
		return 1
	fi
	d=$(printf '%s' "$v" | base64 -d 2>/dev/null | sha) || d=
	v=
	if ! [[ $d =~ ^[0-9a-f]{64}$ ]]; then
		err "$ns/$name: key $key is not valid base64"
		return 1
	fi
	printf '%s\n' "$d"
}

# Both reads always run, so an ERROR names every failing side.
rc=0
a=$(value_hash "$SRC") || rc=2
b=$(value_hash "$DST") || rc=2
if [ "$rc" -ne 0 ]; then
	echo ERROR
	exit 2
fi
if [ "$a" = "$b" ]; then
	echo EQUAL
	exit 0
fi
echo DIFFERENT
exit 1
