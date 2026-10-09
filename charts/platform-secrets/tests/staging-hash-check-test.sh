#!/usr/bin/env bash
# shellcheck disable=SC2015 # `check && ok || bad` is intended (ok/bad always succeed)
# Unit test of tests/staging-hash-check.sh with a fake kubectl on PATH. Light:
# no cluster, no Docker. Not packaged (.helmignore tests/).
#
#   charts/platform-secrets/tests/staging-hash-check-test.sh
#
# The fake kubectl answers per Secret name (FAKE_SRC for oauth2-proxy-secret,
# FAKE_DST for every other Secret) and accepts only the context FAKE_CTX:
#   A | B      the base64 of dummy value A or B, rc 0
#   empty      nothing, rc 0 (what jsonpath does for a missing key)
#   stdout     the whole object with both values on STDOUT, rc 1 (what a
#              failing go-template does)
#   stderr     the whole object on STDERR, rc 1 (what a failing jsonpath
#              does: "object given to jsonpath engine was")
#   dump0      the whole object on stdout, rc 0 (not base64: ERROR too)
#   forbidden | notfound   the API error on stderr, rc 1 (also for -o name)
#   badb64     a string that is not base64, rc 0
# Every case checks:
#   - stdout is exactly the expected word, and the exit code matches
#     (0 EQUAL, 1 DIFFERENT, 2 ERROR);
#   - no dummy value, plain or base64, appears on stdout or stderr;
#   - kubectl ran only as `--context <ctx> ... get secret <name> -o
#     jsonpath={.data.<key>} | -o name`.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
HC=$HERE/staging-hash-check.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

rnd32() { head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32; }
FAKE_A=$(rnd32)
FAKE_B=$(rnd32)
export FAKE_A FAKE_B FAKE_ARGV=$WORK/argv.log

mkdir -p "$WORK/bin"
cat >"$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
# Fake kubectl for staging-hash-check-test.sh (dummy values only).
printf '%s\n' "$*" >>"$FAKE_ARGV"
ctx="" ns="" name="" out=""
while [ $# -gt 0 ]; do
	case $1 in
	--context) ctx=$2; shift 2 ;;
	-n) ns=$2; shift 2 ;;
	-o) out=$2; shift 2 ;;
	--request-timeout=*) shift ;;
	get) [ "${2:-}" = secret ] || { echo "fake: only get secret" >&2; exit 9; }; name=$3; shift 3 ;;
	*) echo "fake: unexpected argument $1" >&2; exit 9 ;;
	esac
done
if [ "$ctx" != "$FAKE_CTX" ]; then
	echo "error: context \"$ctx\" does not exist" >&2
	exit 1
fi
b64() { printf '%s' "$1" | base64 -w0; }
dump() { printf 'map[apiVersion:v1 data:map[a:%s b:%s plain:%s] kind:Secret metadata:map[name:%s namespace:%s]]\n' \
	"$(b64 "$FAKE_A")" "$(b64 "$FAKE_B")" "$FAKE_A" "$name" "$ns"; }
if [ "$name" = oauth2-proxy-secret ]; then mode=$FAKE_SRC; else mode=$FAKE_DST; fi
case $mode in
forbidden)
	echo "Error from server (Forbidden): secrets \"$name\" is forbidden: User \"nobody\" cannot get resource \"secrets\" in API group \"\" in the namespace \"$ns\"" >&2
	exit 1 ;;
notfound)
	echo "Error from server (NotFound): secrets \"$name\" not found" >&2
	exit 1 ;;
esac
if [ "$out" = name ]; then
	echo "secret/$name"
	exit 0
fi
case $out in jsonpath=*) ;; *) echo "fake: unexpected output format $out" >&2; exit 9 ;; esac
case $mode in
A) b64 "$FAKE_A" ;;
B) b64 "$FAKE_B" ;;
empty) ;;
stdout) dump; exit 1 ;;
stderr) { echo "error: error executing jsonpath: object given to jsonpath engine was:"; dump; } >&2; exit 1 ;;
dump0) dump ;;
badb64) printf '%s' '!!not*base64!!' ;;
*) echo "fake: unknown mode $mode" >&2; exit 9 ;;
esac
EOF
chmod +x "$WORK/bin/kubectl"

# run <label> <want word> <want rc> <ctx accepted> <src mode> <dst mode> [bash flags --] [args...]
run() {
	local label=$1 want=$2 want_rc=$3 rc=0 out errout leaks=0 v form
	local -a sh=(bash)
	export FAKE_CTX=$4 FAKE_SRC=$5 FAKE_DST=$6
	shift 6
	if [ "${1:-}" = -x ]; then
		sh+=(-x)
		shift
	fi
	: >"$FAKE_ARGV"
	PATH="$WORK/bin:$PATH" "${sh[@]}" "$HC" "$@" >"$WORK/out" 2>"$WORK/err" || rc=$?
	out=$(cat "$WORK/out")
	errout=$(cat "$WORK/err")
	[ "$out" = "$want" ] && [ "$rc" = "$want_rc" ] && ok "$label: $want (rc $rc)" ||
		bad "$label: got '$out' rc $rc, want $want rc $want_rc; stderr: $errout"
	for v in "$FAKE_A" "$FAKE_B"; do
		for form in "$v" "$(printf '%s' "$v" | base64 -w0)"; do
			grep -qF -- "$form" "$WORK/out" "$WORK/err" && leaks=$((leaks + 1))
		done
	done
	[ "$leaks" -eq 0 ] && ok "$label: no value on stdout or stderr" || bad "$label: $leaks value forms leaked"
	cp "$WORK/err" "$WORK/last.err"
}
# argv_ok <ctx>: every fake call was a read-only get with the expected shape
argv_ok() {
	local re="^--context $1 --request-timeout=20s -n [-a-z0-9]+ get secret [-.a-z0-9]+ -o (jsonpath=\{\.data\.[-_A-Za-z0-9]+\}|name)$"
	[ -s "$FAKE_ARGV" ] && ! grep -qvE "$re" "$FAKE_ARGV"
}
stderr_has() { grep -qF -- "$1" "$WORK/last.err"; }

echo "== verdicts"
run "same value" EQUAL 0 r415 A A
argv_ok r415 && ok "default context r415, read-only get with jsonpath only" || bad "kubectl calls: $(cat "$FAKE_ARGV")"
grep -qxF -- '--context r415 --request-timeout=20s -n teknoir-auth get secret oauth2-proxy-secret -o jsonpath={.data.client-secret}' "$FAKE_ARGV" &&
	grep -qxF -- '--context r415 --request-timeout=20s -n teknoir-system get secret backstage-keycloak-secrets -o jsonpath={.data.KEYCLOAK_CLIENTSECRET}' "$FAKE_ARGV" &&
	[ "$(wc -l <"$FAKE_ARGV")" -eq 2 ] && ok "default pair: oauth2-proxy-secret[client-secret] vs backstage-keycloak-secrets[KEYCLOAK_CLIENTSECRET]" ||
	bad "default pair: $(cat "$FAKE_ARGV")"
run "stale copy" DIFFERENT 1 r415 A B
run "explicit --context" EQUAL 0 k3d-x A A --context k3d-x
argv_ok k3d-x && ok "--context is passed through" || bad "--context: $(cat "$FAKE_ARGV")"
run "--context=" DIFFERENT 1 k3d-x B A --context=k3d-x

echo "== failed or empty reads are ERROR, never EQUAL"
run "both empty (missing keys)" ERROR 2 r415 empty empty
stderr_has 'teknoir-auth/oauth2-proxy-secret: key client-secret is missing or empty' &&
	stderr_has 'teknoir-system/backstage-keycloak-secrets: key KEYCLOAK_CLIENTSECRET is missing or empty' &&
	ok "both empty: stderr names both keys" || bad "both empty: stderr $(cat "$WORK/last.err")"
run "copy empty" ERROR 2 r415 A empty
run "source empty" ERROR 2 r415 empty A
run "wrong context" ERROR 2 r415 A A --context no-such-ctx
stderr_has 'context "no-such-ctx" does not exist' && ok "wrong context: reason on stderr" || bad "wrong context: $(cat "$WORK/last.err")"
argv_ok no-such-ctx && ok "wrong context: still read-only gets" || bad "wrong context calls"
run "both Forbidden" ERROR 2 r415 forbidden forbidden
stderr_has 'Error from server (Forbidden)' && ok "Forbidden: reason on stderr" || bad "Forbidden: $(cat "$WORK/last.err")"
run "copy NotFound" ERROR 2 r415 A notfound
stderr_has 'secrets "backstage-keycloak-secrets" not found' && ok "NotFound: reason on stderr" || bad "NotFound: $(cat "$WORK/last.err")"
run "not base64" ERROR 2 r415 A badb64
stderr_has 'key KEYCLOAK_CLIENTSECRET is not valid base64' && ok "not base64: reason on stderr" || bad "not base64: $(cat "$WORK/last.err")"

echo "== kubectl printing the whole object never reaches the terminal"
run "object on stdout, rc 1 (go-template error)" ERROR 2 r415 stdout stdout
run "object on stderr, rc 1 (jsonpath error)" ERROR 2 r415 stderr stderr
run "object on stdout, rc 0 (not base64)" ERROR 2 r415 dump0 A
run "bash -x" DIFFERENT 1 r415 A B -x
run "bash -x, object on stdout" ERROR 2 r415 stdout A -x

echo "== arguments"
run "--source/--copy override" EQUAL 0 r415 A A --source ns-a/src-secret/client-secret --copy ns-b/dst.secret/OTHER_KEY
grep -qxF -- '--context r415 --request-timeout=20s -n ns-a get secret src-secret -o jsonpath={.data.client-secret}' "$FAKE_ARGV" &&
	grep -qxF -- '--context r415 --request-timeout=20s -n ns-b get secret dst.secret -o jsonpath={.data.OTHER_KEY}' "$FAKE_ARGV" &&
	ok "overrides reach the jsonpath" || bad "overrides: $(cat "$FAKE_ARGV")"
for a in '--copy ns/secret/KEY.WITH.DOT' '--copy ns/secret' '--source NS/secret/key' '--copy ns/secret/key}{.data' '--context' '--context=' '--bogus'; do
	# shellcheck disable=SC2086 # split the argument list on purpose
	run "rejects $a" ERROR 2 r415 A A $a
	[ ! -s "$FAKE_ARGV" ] && ok "rejects $a: kubectl not called" || bad "rejects $a: kubectl called"
done

echo "== the script itself"
bash -n "$HC" && ok "bash -n" || bad "bash -n"
if command -v shellcheck >/dev/null 2>&1; then
	shellcheck "$HC" "$0" && ok "shellcheck" || bad "shellcheck"
else
	echo "SKIP shellcheck missing"
fi
grep -vE '^[[:space:]]*#' "$HC" >"$WORK/code"
! grep -nE 'kubectl[^|]*\b(apply|patch|delete|edit|exec|create|replace|label|annotate|scale|rollout)\b' "$WORK/code" &&
	ok "the script has no mutating kubectl verb" || bad "mutating kubectl verb in the script"
[ "$(grep -c 'kubectl ' "$WORK/code")" -eq 2 ] && ok "the script has exactly 2 kubectl calls (value read, -o name probe)" ||
	bad "kubectl calls in the script: $(grep -c 'kubectl ' "$WORK/code")"
! grep -nE 'go-template|-o *(yaml|json)\b|-o=(yaml|json)\b' "$WORK/code" &&
	ok "the script never reads a Secret as go-template, yaml or json" || bad "unsafe output format in the script"

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
