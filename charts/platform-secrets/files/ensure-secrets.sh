#!/bin/sh
# ensure-secrets.sh SPEC_FILE
#
# Reconciles the platform Secrets described by SPEC_FILE, which the
# platform-secrets chart renders from values.secrets (line format documented
# in templates/_helpers.tpl):
#   - an absent Secret is created with every key;
#   - in a present Secret, random keys and plain values are never changed;
#     missing ones are only added when the Secret sets addMissingKeys;
#   - copyFrom keys and `sync: true` values are re-synced on every run;
#   - when a Secret is created or a key changes, the listed Deployments are
#     restarted. The pending restart is recorded on the Secret itself
#     (annotation teknoir.org/restart-pending, written in the same request as
#     the data), so a run that dies before the restart retries it next time.
#
# Never prints a value: no `set -x`; values live only in shell variables and
# pipes (printf is a shell builtin, so values never reach any argv); kubectl
# output that could echo an object is discarded. Key names are printed.
#
# Errors are never read as "absent": only an empty `get --ignore-not-found`
# means absent. Exit status: 0 when every Secret converged, 1 otherwise.
#
# POSIX sh (busybox ash in docker.io/alpine/k8s). Needs kubectl, tr, head,
# base64, od, awk and date. KUBECTL overrides the kubectl command (tests).
set -eu
LC_ALL=C
export LC_ALL
umask 077

SPEC=${1:?usage: ensure-secrets.sh SPEC_FILE}
KUBECTL=${KUBECTL:-kubectl}
FIELD_MANAGER=platform-secrets
PENDING=teknoir.org/restart-pending
NL='
'

n_created=0
n_updated=0
n_unchanged=0
n_failed=0

log() { printf 'platform-secrets: %s\n' "$*"; }
warn() { printf 'platform-secrets: WARNING: %s\n' "$*" >&2; }
err() { printf 'platform-secrets: ERROR: %s\n' "$*" >&2; }

kc() {
	# shellcheck disable=SC2086 # KUBECTL may carry flags, e.g. "kubectl --context x"
	$KUBECTL "$@"
}

# ---------------------------------------------------------------- generators

# rand_chars <length> <alnum|hex>: alnum values of 8+ characters always hold
# an upper-case letter, a lower-case letter and a digit (password policies).
rand_chars() {
	case $2 in
	hex) _set='0-9a-f' ;;
	*) _set='A-Za-z0-9' ;;
	esac
	while :; do
		_v=$(tr -dc "$_set" </dev/urandom | head -c "$1")
		[ "${#_v}" -eq "$1" ] || continue
		if [ "$2" = alnum ] && [ "$1" -ge 8 ]; then
			case $_v in *[A-Z]*) ;; *) continue ;; esac
			case $_v in *[a-z]*) ;; *) continue ;; esac
			case $_v in *[0-9]*) ;; *) continue ;; esac
		fi
		printf '%s' "$_v"
		return 0
	done
}

# rand_bytes <bytes> <base64|base64url|hex>
rand_bytes() {
	case $2 in
	hex) head -c "$1" /dev/urandom | od -An -tx1 -v | tr -d ' \n' ;;
	base64url) head -c "$1" /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_' ;;
	*) head -c "$1" /dev/urandom | base64 | tr -d '\n' ;;
	esac
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
unb64() { printf '%s' "$1" | base64 -d; }

# gen_random <length> <charset> <bytes> <encoding> <format-b64>: the data
# (base64) of one random key.
gen_random() {
	if [ "$1" -gt 0 ]; then
		_r=$(rand_chars "$1" "$2")
	else
		_r=$(rand_bytes "$3" "$4")
	fi
	_fmt=$(unb64 "$5")
	b64 "${_fmt%%%s*}${_r}${_fmt#*%s}"
}

# ------------------------------------------------------------------ reading

# read_secret <ns> <name>: prints nothing when the Secret is absent, else
#   T <type> / D <key>=<data> / L <label>=<value> / P <restart-pending>
# Any kubectl error (Forbidden, connection refused, ...) returns non-zero.
read_secret() {
	# shellcheck disable=SC2016 # a go-template, not a shell expansion
	kc -n "$1" get secret "$2" --ignore-not-found -o go-template='T {{.type}}{{"\n"}}{{range $k, $v := .data}}D {{$k}}={{$v}}{{"\n"}}{{end}}{{range $k, $v := .metadata.labels}}L {{$k}}={{$v}}{{"\n"}}{{end}}{{with .metadata.annotations}}{{with index . "teknoir.org/restart-pending"}}P {{.}}{{"\n"}}{{end}}{{end}}'
}

# field <blob> <prefix>: prints the rest of the first line starting with
# <prefix>; returns 1 when there is none. The blob goes through a pipe.
field() {
	printf '%s\n' "$1" | awk -v p="$2" 'index($0, p) == 1 { print substr($0, length(p) + 1); f = 1; exit } END { exit !f }'
}

# source_data <ns> <name> <key> [<self-ns> <self-name> <self-blob>...]:
# prints the data of a copyFrom source. A key of the Secret being reconciled
# is looked up in the given in-memory blobs (pending values first).
source_data() {
	if [ "$1" = "$4" ] && [ "$2" = "$5" ]; then
		field "$6" "D $3=" && return 0
		field "$7" "D $3=" && return 0
		return 1
	fi
	_src=$(read_secret "$1" "$2") || return 2
	[ -n "$_src" ] || return 1
	field "$_src" "D $3="
}

# ------------------------------------------------------------------ writing

json_labels() {
	_j=''
	while IFS='|' read -r _lk _lv; do
		[ -n "$_lk" ] || continue
		_j="${_j:+$_j,}\"$_lk\":\"$_lv\""
	done <<EOF
$s_labels
EOF
	printf '%s' "$_j"
}

restart_deployments() { # <secret id>: returns non-zero if any restart failed
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	_rc=0
	while IFS='|' read -r _rns _rdep; do
		[ -n "$_rns" ] || continue
		if _out=$(kc -n "$_rns" patch deployment "$_rdep" --field-manager="$FIELD_MANAGER" --type merge \
			-p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$_ts\"}}}}}" 2>&1 >/dev/null); then
			log "$1: restarted deployment $_rns/$_rdep"
		else
			case $_out in
			*NotFound* | *"not found"*) log "$1: deployment $_rns/$_rdep does not exist yet, nothing to restart" ;;
			*)
				err "$1: restart of deployment $_rns/$_rdep failed: $_out"
				_rc=1
				;;
			esac
		fi
	done <<EOF
$s_restarts
EOF
	return "$_rc"
}

finish_restarts() { # <ns> <name>: restart, then clear the pending marker
	restart_deployments "$1/$2" || return 1
	if ! _out=$(printf '{"metadata":{"annotations":{"%s":null}}}' "$PENDING" |
		kc -n "$1" patch secret "$2" --field-manager="$FIELD_MANAGER" --type merge --patch-file=/dev/stdin 2>&1 >/dev/null); then
		err "$1/$2: could not clear $PENDING: $_out"
		return 1
	fi
}

# create_secret: returns 0 created, 1 failed, 3 lost a create race.
create_secret() {
	_id="$s_ns/$s_name"
	_data=''
	_mem=''
	while IFS='|' read -r _k _kind _x1 _x2 _x3 _x4 _x5; do
		[ -n "$_k" ] || continue
		case $_kind in
		random) _v=$(gen_random "$_x1" "$_x2" "$_x3" "$_x4" "$_x5") ;;
		value) _v=$_x1 ;;
		copy)
			_rc=0
			_v=$(source_data "$_x1" "$_x2" "$_x3" "$s_ns" "$s_name" "$_mem" "") || _rc=$?
			if [ "$_rc" -ne 0 ]; then
				if [ "$_rc" -eq 1 ]; then
					err "$_id: not created: copy source $_x1/$_x2 key $_x3 for key $_k does not exist"
				else
					err "$_id: not created: cannot read copy source $_x1/$_x2"
				fi
				return 1
			fi
			;;
		*)
			err "$_id: unknown key kind $_kind"
			return 1
			;;
		esac
		_mem="$_mem${NL}D $_k=$_v"
		_data="${_data:+$_data,}\"$_k\":\"$_v\""
	done <<EOF
$s_keys
EOF
	_ann=''
	[ -z "$s_restarts" ] || _ann=",\"annotations\":{\"$PENDING\":\"created\"}"
	if _out=$(printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s","labels":{%s}%s},"type":"%s","data":{%s}}' \
		"$s_name" "$s_ns" "$(json_labels)" "$_ann" "$s_type" "$_data" |
		kc create --field-manager="$FIELD_MANAGER" -f - 2>&1 >/dev/null); then
		log "$_id: created (keys: $(key_names))"
		return 0
	fi
	case $_out in
	*AlreadyExists* | *"already exists"*) return 3 ;;
	esac
	err "$_id: create failed: $_out"
	return 1
}

key_names() {
	_n=''
	while IFS='|' read -r _k _rest; do
		[ -n "$_k" ] || continue
		_n="${_n:+$_n, }$_k"
	done <<EOF
$s_keys
EOF
	printf '%s' "$_n"
}

# update_secret <current blob>: returns 0 unchanged, 4 updated, 1 failed.
update_secret() {
	_cur=$1
	_id="$s_ns/$s_name"
	_rc_all=0
	_ctype=$(field "$_cur" "T ") || _ctype=''
	[ "$_ctype" = "$s_type" ] || warn "$_id: has type '$_ctype', spec says '$s_type' (type is immutable; left as is)"

	_patch=''  # JSON members of .data
	_pmem=''   # pending data, for same-Secret copies
	_changed=''
	while IFS='|' read -r _k _kind _x1 _x2 _x3 _x4 _x5; do
		[ -n "$_k" ] || continue
		_has=0
		_c=$(field "$_cur" "D $_k=") && _has=1
		_want=''
		case $_kind in
		random)
			[ "$_has" -eq 1 ] && continue
			if [ "$s_add" != 1 ]; then
				warn "$_id: key $_k is missing; not added (addMissingKeys is off)"
				continue
			fi
			_want=$(gen_random "$_x1" "$_x2" "$_x3" "$_x4" "$_x5")
			;;
		value)
			if [ "$_has" -eq 1 ]; then
				[ "$_x2" = 1 ] || continue
				[ "$_c" = "$_x1" ] && continue
			elif [ "$_x2" != 1 ] && [ "$s_add" != 1 ]; then
				warn "$_id: key $_k is missing; not added (addMissingKeys is off)"
				continue
			fi
			_want=$_x1
			;;
		copy)
			_rc=0
			_want=$(source_data "$_x1" "$_x2" "$_x3" "$s_ns" "$s_name" "$_pmem" "$_cur") || _rc=$?
			if [ "$_rc" -ne 0 ]; then
				if [ "$_rc" -eq 1 ]; then
					err "$_id: key $_k: copy source $_x1/$_x2 key $_x3 does not exist; left as is"
				else
					err "$_id: key $_k: cannot read copy source $_x1/$_x2; left as is"
				fi
				_rc_all=1
				continue
			fi
			[ "$_has" -eq 1 ] && [ "$_c" = "$_want" ] && continue
			;;
		*)
			err "$_id: unknown key kind $_kind"
			_rc_all=1
			continue
			;;
		esac
		_pmem="$_pmem${NL}D $_k=$_want"
		_patch="${_patch:+$_patch,}\"$_k\":\"$_want\""
		_changed="${_changed:+$_changed, }$_k"
	done <<EOF
$s_keys
EOF

	_lpatch=''
	while IFS='|' read -r _lk _lv; do
		[ -n "$_lk" ] || continue
		_cl=$(field "$_cur" "L $_lk=") && [ "$_cl" = "$_lv" ] && continue
		_lpatch="${_lpatch:+$_lpatch,}\"$_lk\":\"$_lv\""
	done <<EOF
$s_labels
EOF

	_pending=0
	field "$_cur" "P " >/dev/null && _pending=1

	if [ -n "$_patch" ] || [ -n "$_lpatch" ]; then
		_meta="\"labels\":{$_lpatch}"
		if [ -n "$_patch" ] && [ -n "$s_restarts" ]; then
			_meta="$_meta,\"annotations\":{\"$PENDING\":\"updated\"}"
			_pending=1
		fi
		if ! _out=$(printf '{"metadata":{%s},"data":{%s}}' "$_meta" "$_patch" |
			kc -n "$s_ns" patch secret "$s_name" --field-manager="$FIELD_MANAGER" --type merge --patch-file=/dev/stdin 2>&1 >/dev/null); then
			err "$_id: patch failed: $_out"
			return 1
		fi
		[ -z "$_changed" ] || log "$_id: synced keys: $_changed"
		[ -z "$_lpatch" ] || log "$_id: synced labels"
	fi

	if [ "$_pending" -eq 1 ]; then
		if [ -z "$s_restarts" ]; then
			# No consumers listed (any more): just drop the marker.
			printf '{"metadata":{"annotations":{"%s":null}}}' "$PENDING" |
				kc -n "$s_ns" patch secret "$s_name" --field-manager="$FIELD_MANAGER" --type merge --patch-file=/dev/stdin >/dev/null 2>&1 || _rc_all=1
		else
			finish_restarts "$s_ns" "$s_name" || _rc_all=1
		fi
	fi

	[ "$_rc_all" -eq 0 ] || return 1
	if [ -n "$_patch" ] || [ -n "$_lpatch" ]; then return 4; fi
	return 0
}

process_secret() {
	_id="$s_ns/$s_name"
	_tries=0
	while :; do
		_tries=$((_tries + 1))
		if ! _blob=$(read_secret "$s_ns" "$s_name"); then
			err "$_id: cannot read it (kubectl failed); skipped"
			n_failed=$((n_failed + 1))
			return 0
		fi
		if [ -z "$_blob" ]; then
			_rc=0
			create_secret || _rc=$?
			case $_rc in
			0)
				n_created=$((n_created + 1))
				if [ -n "$s_restarts" ]; then
					finish_restarts "$s_ns" "$s_name" || n_failed=$((n_failed + 1))
				fi
				return 0
				;;
			3)
				# Another run (hook Job vs CronJob) created it first: reconcile it.
				[ "$_tries" -lt 3 ] && continue
				err "$_id: create keeps racing; giving up"
				n_failed=$((n_failed + 1))
				return 0
				;;
			*)
				n_failed=$((n_failed + 1))
				return 0
				;;
			esac
		fi
		_rc=0
		update_secret "$_blob" || _rc=$?
		case $_rc in
		0)
			log "$_id: unchanged"
			n_unchanged=$((n_unchanged + 1))
			;;
		4) n_updated=$((n_updated + 1)) ;;
		*) n_failed=$((n_failed + 1)) ;;
		esac
		return 0
	done
}

# --------------------------------------------------------------------- main

[ -r "$SPEC" ] || {
	err "cannot read spec $SPEC"
	exit 2
}

s_ns=''
s_name=''
s_type=''
s_add=0
s_keys=''
s_labels=''
s_restarts=''
in_secret=0
while IFS='|' read -r t a b c d e f g h <&3; do
	case $t in
	S)
		s_ns=$a s_name=$b s_type=$c s_add=$d
		s_keys='' s_labels='' s_restarts=''
		in_secret=1
		;;
	L) s_labels="$s_labels$a|$b$NL" ;;
	K) s_keys="$s_keys$a|$b|$c|$d|$e|$f|$g$NL" ;;
	R) s_restarts="$s_restarts$a|$b$NL" ;;
	E)
		[ "$in_secret" -eq 1 ] || {
			err "spec: E without S"
			exit 2
		}
		process_secret
		in_secret=0
		;;
	'') ;;
	*)
		err "spec: unknown line type '$t'"
		exit 2
		;;
	esac
	: "$h" # spare field: a line with too many fields lands here, not in g
done 3<"$SPEC"

log "done: $n_created created, $n_updated updated, $n_unchanged unchanged, $n_failed failed"
[ "$n_failed" -eq 0 ]
