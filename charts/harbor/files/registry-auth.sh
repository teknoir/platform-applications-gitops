#!/bin/sh
# registry-auth.sh — Harbor's internal registry credential, created once.
#
# harbor-core and harbor-jobservice log in to harbor-registry with basic auth
# as REGISTRY_USERNAME. harbor.registry.credentials.existingSecret points all
# three at Secret SECRET_NAME:
#   REGISTRY_PASSWD    random password (core and jobservice, env)
#   REGISTRY_HTPASSWD  "<user>:<bcrypt hash>" (registry, /etc/registry/passwd;
#                      the registry accepts bcrypt only)
#
# - Absent Secret: created with a new random password and its htpasswd line.
# - Present with both keys non-empty: never changed.
# - Present but incomplete: both keys are replaced together.
# - Rotation: delete the Secret and sync the harbor Application; this Job then
#   creates a new one.
# Whenever the Job creates or replaces the Secret while a Deployment in
# RESTART_DEPLOYMENTS already runs with it (ready and referencing it), that
# Deployment is restarted, so core, jobservice and registry agree again. The
# pending restarts are recorded on the Secret (annotation
# teknoir.org/restart-pending, written in the same request as the data), so a
# run that dies before restarting retries them.
#
# bcrypt comes from helm's `htpasswd` template function: the toolbox image
# (docker.io/alpine/k8s) has helm but no other bcrypt tool.
#
# Never prints a value: no `set -x`; values live in shell variables and in
# files under a private directory on the in-memory /tmp (printf is a shell
# builtin, so values never reach any argv); kubectl and helm output that could
# carry a value is captured or discarded. Errors are never read as "absent":
# only an empty `get --ignore-not-found` means absent.
#
# POSIX sh (busybox ash). Needs kubectl, helm, jq, tr, head, sed, date.
# Environment: SECRET_NAME, REGISTRY_USERNAME, POD_NAMESPACE (required);
# RESTART_DEPLOYMENTS (space-separated), PASSWORD_LENGTH (default 32),
# KUBECTL and HELM (commands, for tests).
set -eu
LC_ALL=C
export LC_ALL
umask 077

: "${SECRET_NAME:?}" "${REGISTRY_USERNAME:?}" "${POD_NAMESPACE:?}"
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
RESTART_DEPLOYMENTS=${RESTART_DEPLOYMENTS:-}
PASSWORD_LENGTH=${PASSWORD_LENGTH:-32}
PENDING=teknoir.org/restart-pending
MANAGED_BY=harbor-registry-auth

log() { printf 'registry-auth: %s\n' "$*"; }
die() {
	printf 'registry-auth: ERROR: %s\n' "$*" >&2
	exit 1
}

kc() {
	# shellcheck disable=SC2086 # KUBECTL may carry flags, e.g. "kubectl --context x"
	$KUBECTL -n "$POD_NAMESPACE" "$@"
}

# reason <stderr-file>: the bracketed reason of a kubectl error
# ("AlreadyExists", "Forbidden", ...), never the message, which could quote
# an object.
reason() {
	_r=$(sed -n 's/^Error from server (\([A-Za-z]*\)).*/\1/p' "$1" | head -n 1)
	printf '%s' "${_r:-unknown error}"
}

case $REGISTRY_USERNAME in
*[!A-Za-z0-9_.-]* | '') die "REGISTRY_USERNAME must be [A-Za-z0-9_.-]+" ;;
esac
case $PASSWORD_LENGTH in
*[!0-9]* | '') die "PASSWORD_LENGTH must be a number" ;;
esac
[ "$PASSWORD_LENGTH" -ge 16 ] || die "PASSWORD_LENGTH must be 16 or more"

work=$(mktemp -d) || die "cannot create a private work directory"
trap 'rm -rf "$work"' EXIT

# ------------------------------------------------------------------ state

# secret_state: "absent", or "present[ <key with a value>...][ pending=<list>]"
secret_state() {
	# shellcheck disable=SC2016 # a go-template, not shell
	_s=$(kc get secret "$SECRET_NAME" --ignore-not-found -o go-template='present{{range $k, $v := .data}}{{if $v}} {{$k}}{{end}}{{end}}{{with .metadata.annotations}}{{with index . "teknoir.org/restart-pending"}} pending={{.}}{{end}}{{end}}' 2>"$work/err") ||
		die "cannot read Secret $SECRET_NAME ($(reason "$work/err"))"
	printf '%s' "${_s:-absent}"
}

has_key() {
	case " $state " in
	*" $1 "*) return 0 ;;
	esac
	return 1
}

pending_list() {
	# the comma-separated Deployment list recorded on the Secret
	printf '%s' "$state" | sed -n 's/.* pending=\([^ ]*\).*/\1/p'
}

# running_consumers: the RESTART_DEPLOYMENTS that are ready and reference the
# Secret (they hold the current credential in memory), comma-separated
running_consumers() {
	_list=
	for _d in $RESTART_DEPLOYMENTS; do
		_j=$(kc get deployment "$_d" --ignore-not-found -o json 2>"$work/err") ||
			die "cannot read Deployment $_d ($(reason "$work/err"))"
		[ -n "$_j" ] || continue
		if printf '%s' "$_j" | jq -e --arg s "$SECRET_NAME" '
			(.status.readyReplicas // 0) > 0
			and ([.spec.template.spec | .. | strings | select(. == $s)] | length > 0)' >/dev/null; then
			_list=${_list:+$_list,}$_d
		fi
	done
	printf '%s' "$_list"
}

# ------------------------------------------------------------------ generate

# generate: writes $work/passwd and $work/htpasswd (never printed)
generate() {
	_pw=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$PASSWORD_LENGTH") || true
	[ "${#_pw}" -eq "$PASSWORD_LENGTH" ] || die "cannot read random bytes"
	printf '%s' "$_pw" >"$work/passwd"

	_chart=$work/chart
	mkdir -p "$_chart/templates"
	printf 'apiVersion: v2\nname: registry-htpasswd\nversion: 0.0.0\n' >"$_chart/Chart.yaml"
	printf 'username: %s\n' "$REGISTRY_USERNAME" >"$_chart/values.yaml"
	printf '%s' "$_pw" >"$_chart/password"
	cat >"$_chart/templates/htpasswd.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: registry-htpasswd
data:
  htpasswd: {{ htpasswd .Values.username (.Files.Get "password") | quote }}
EOF
	# shellcheck disable=SC2086 # HELM may carry flags
	_out=$(HELM_CACHE_HOME=$work/helm/cache HELM_CONFIG_HOME=$work/helm/config \
		HELM_DATA_HOME=$work/helm/data $HELM template registry-htpasswd "$_chart" 2>"$work/err") || {
		# helm's first error line, unless it contains the password
		_e=$(grep -vF -f "$work/passwd" "$work/err" | head -n 1) || true
		die "helm template failed: ${_e:-no message}"
	}
	rm -rf "$_chart"
	_line=$(printf '%s\n' "$_out" | sed -n 's/^  htpasswd: "\(.*\)"$/\1/p')
	case $_line in
	"$REGISTRY_USERNAME":\$2[aby]\$[0-9][0-9]\$*) ;;
	*) die "helm did not produce a bcrypt htpasswd line" ;;
	esac
	[ "${#_line}" -eq $((${#REGISTRY_USERNAME} + 61)) ] || die "helm produced a malformed bcrypt hash"
	printf '%s' "$_line" >"$work/htpasswd"
}

# ------------------------------------------------------------------ write

# write_secret <create|replace> <pending list>: both keys, the labels and the
# restart-pending annotation (set, or removed when the list is empty) in one
# request. Returns 1 when another run created the Secret first.
write_secret() {
	jq -n --arg mode "$1" --arg name "$SECRET_NAME" --arg ns "$POD_NAMESPACE" \
		--arg mb "$MANAGED_BY" --arg pk "$PENDING" --arg pending "$2" \
		--rawfile p "$work/passwd" --rawfile h "$work/htpasswd" '
		{metadata: {
		   labels: {"teknoir.org/managed-by": $mb, "app.kubernetes.io/part-of": "harbor"},
		   annotations: (if $pending != "" then {($pk): $pending}
		                 elif $mode == "replace" then {($pk): null} else {} end)},
		 data: {REGISTRY_PASSWD: ($p | @base64), REGISTRY_HTPASSWD: ($h | @base64)}}
		| if $mode == "create" then
		    {apiVersion: "v1", kind: "Secret", type: "Opaque"} + .
		    | .metadata += {name: $name, namespace: $ns}
		  else . end' >"$work/secret.json" || die "cannot build the Secret"
	rm -f "$work/passwd" "$work/htpasswd"
	if [ "$1" = create ]; then
		if ! kc create -f "$work/secret.json" -o name >/dev/null 2>"$work/err"; then
			rm -f "$work/secret.json"
			[ "$(reason "$work/err")" = AlreadyExists ] ||
				die "cannot create Secret $SECRET_NAME ($(reason "$work/err"))"
			log "Secret $SECRET_NAME was created concurrently: left as is"
			return 1
		fi
		log "Secret $SECRET_NAME created (keys REGISTRY_PASSWD, REGISTRY_HTPASSWD)"
	else
		kc patch secret "$SECRET_NAME" --type merge --patch-file "$work/secret.json" -o name \
			>/dev/null 2>"$work/err" || {
			rm -f "$work/secret.json"
			die "cannot replace the keys of Secret $SECRET_NAME ($(reason "$work/err"))"
		}
		log "Secret $SECRET_NAME was incomplete: both keys replaced"
	fi
	rm -f "$work/secret.json"
	return 0
}

restart_pending() {
	# restart_pending <comma-separated Deployments>: restart them, then clear
	# the annotation
	_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	for _d in $(printf '%s' "$1" | tr ',' ' '); do
		kc patch deployment "$_d" --type merge -o name \
			-p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$_now\"}}}}}" \
			>/dev/null 2>"$work/err" || die "cannot restart Deployment $_d ($(reason "$work/err"))"
		log "Deployment $_d restarted: it ran with the previous credential"
	done
	kc patch secret "$SECRET_NAME" --type merge -o name \
		-p "{\"metadata\":{\"annotations\":{\"$PENDING\":null}}}" >/dev/null 2>"$work/err" ||
		die "cannot clear $PENDING on Secret $SECRET_NAME ($(reason "$work/err"))"
}

# ------------------------------------------------------------------ main

state=$(secret_state)
if has_key REGISTRY_PASSWD && has_key REGISTRY_HTPASSWD; then
	pending=$(pending_list)
	if [ -n "$pending" ]; then
		log "Secret $SECRET_NAME exists; restarts pending from an earlier run: $pending"
		restart_pending "$pending"
	else
		log "Secret $SECRET_NAME exists with both keys: unchanged"
	fi
	exit 0
fi

consumers=$(running_consumers)
generate
if [ "$state" = absent ]; then
	write_secret create "$consumers" || exit 0
else
	write_secret replace "$consumers"
fi
if [ -n "$consumers" ]; then
	restart_pending "$consumers"
fi
log "done"
