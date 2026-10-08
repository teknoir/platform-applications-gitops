#!/bin/sh
# oidc-config.sh — converge Harbor's OIDC settings through its API.
#
# Runs as the harbor chart's PostSync Job (templates/oidc-config-job.yaml).
# GETs /api/v2.0/configurations, compares it with the desired settings and PUTs
# only the keys that differ. Harbor never returns the OIDC client secret, so
# its sha256 is kept in ConfigMap $STATE_CONFIGMAP and the secret is sent only
# when that hash changes. Harbor refuses to switch auth_mode once users other
# than admin exist; auth_mode is then left alone with a warning.
#
# Environment:
#   HARBOR_API            e.g. http://harbor-core.teknoir-system.svc.cluster.local/api/v2.0
#   HARBOR_ADMIN_PASSWORD from Secret harbor-secret      (never printed)
#   OIDC_CLIENT_SECRET    from Secret harbor-oidc-secret (never printed)
#   DESIRED               JSON file of Harbor configuration keys -> values
#   STATE_CONFIGMAP       ConfigMap for the client secret hash
#   POD_NAMESPACE         namespace of that ConfigMap
#   WAIT_SECONDS          how long to wait for Harbor's API (default 1200)
#
# Never add `set -x`: the credentials are in variables and in a 0600 file.
set -eu
umask 077

log() { printf 'oidc-config: %s\n' "$*"; }
die() { printf 'oidc-config: ERROR: %s\n' "$*" >&2; exit 1; }

: "${HARBOR_API:?}" "${HARBOR_ADMIN_PASSWORD:?}" "${OIDC_CLIENT_SECRET:?}"
: "${DESIRED:?}" "${STATE_CONFIGMAP:?}" "${POD_NAMESPACE:?}"
WAIT_SECONDS="${WAIT_SECONDS:-1200}"
[ -r "${DESIRED}" ] || die "desired settings ${DESIRED} not readable"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT INT TERM

# curl takes the admin credential from a 0600 config file, never from argv.
# printf is a shell builtin, so the password does not show up in /proc either.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf 'user = "admin:%s"\n' "$(esc "${HARBOR_ADMIN_PASSWORD}")" > "${tmp}/auth"

# api METHOD PATH [BODYFILE]: response body in ${tmp}/body, HTTP status in $code
# (000 when Harbor cannot be reached).
api() {
  if [ -n "${3:-}" ]; then
    code="$(curl -sS -m 30 -K "${tmp}/auth" -o "${tmp}/body" -w '%{http_code}' \
      -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" \
      "${HARBOR_API}$2")" || code=000
  else
    code="$(curl -sS -m 30 -K "${tmp}/auth" -o "${tmp}/body" -w '%{http_code}' \
      -X "$1" "${HARBOR_API}$2")" || code=000
  fi
}
errors() { jq -r '[.errors[]?.message] | join("; ")' "${tmp}/body" 2>/dev/null || true; }

# 1. Wait until Harbor core answers the admin API (it starts after its database).
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while :; do
  api GET /configurations
  case "${code}" in
    200) break ;;
    401|403) die "Harbor rejects the admin credential from Secret harbor-secret (HTTP ${code})" ;;
  esac
  [ "$(date +%s)" -lt "${deadline}" ] \
    || die "Harbor API not ready after ${WAIT_SECONDS}s (last HTTP ${code})"
  log "waiting for the Harbor API (HTTP ${code})"
  sleep 10
done
cp "${tmp}/body" "${tmp}/current.json"

# 2. Keys whose current value differs from the desired one. These settings are
#    not secret, so their names may be logged.
jq -r --slurpfile want "${DESIRED}" '
  . as $cur | $want[0] | to_entries[]
  | select($cur[.key].value != .value) | .key' "${tmp}/current.json" > "${tmp}/changed"

if grep -qx auth_mode "${tmp}/changed"; then
  api GET '/users?page=1&page_size=10'
  [ "${code}" = 200 ] || die "GET /users failed (HTTP ${code}): $(errors)"
  others="$(jq '[.[] | select(.username != "admin")] | length' "${tmp}/body")"
  if [ "${others}" -gt 0 ]; then
    log "WARNING: auth_mode is $(jq -r '.auth_mode.value' "${tmp}/current.json"), not" \
      "the desired value, and users other than admin exist: Harbor refuses to" \
      "switch it, so auth_mode is left alone"
    grep -vx auth_mode "${tmp}/changed" > "${tmp}/changed.new" || true
    mv "${tmp}/changed.new" "${tmp}/changed"
  fi
fi

jq -c --rawfile keys "${tmp}/changed" '
  ($keys | split("\n") | map(select(length > 0))) as $k
  | with_entries(select(.key as $x | $k | index($x)))' "${DESIRED}" > "${tmp}/patch.json"

# 3. The client secret: compare hashes, never values.
want_hash="$(printf '%s' "${OIDC_CLIENT_SECRET}" | sha256sum | cut -d' ' -f1)"
state="$(kubectl -n "${POD_NAMESPACE}" get configmap "${STATE_CONFIGMAP}" \
  --ignore-not-found -o name)" || die "cannot read ConfigMap ${STATE_CONFIGMAP}"
have_hash=""
if [ -n "${state}" ]; then
  have_hash="$(kubectl -n "${POD_NAMESPACE}" get configmap "${STATE_CONFIGMAP}" \
    -o jsonpath='{.data.clientSecretSha256}')" \
    || die "cannot read ConfigMap ${STATE_CONFIGMAP}"
fi
send_secret=false
if [ "${want_hash}" != "${have_hash}" ]; then
  send_secret=true
  printf '%s' "${OIDC_CLIENT_SECRET}" \
    | jq -R -s -c --slurpfile p "${tmp}/patch.json" '$p[0] + {oidc_client_secret: .}' \
    > "${tmp}/patch.new"
  mv "${tmp}/patch.new" "${tmp}/patch.json"
fi

if [ "$(jq 'length' "${tmp}/patch.json")" -eq 0 ]; then
  log "Harbor OIDC configuration is up to date; nothing to change"
  exit 0
fi

# 4. PUT only what differs.
log "updating: $(jq -r 'keys | map(if . == "oidc_client_secret"
  then "oidc_client_secret (value not shown)" else . end) | join(", ")' "${tmp}/patch.json")"
api PUT /configurations "${tmp}/patch.json"
[ "${code}" = 200 ] || die "PUT /configurations failed (HTTP ${code}): $(errors)"

# 5. Record the secret's hash only after Harbor accepted it.
if [ "${send_secret}" = true ]; then
  if [ -n "${state}" ]; then
    kubectl -n "${POD_NAMESPACE}" patch configmap "${STATE_CONFIGMAP}" --type merge \
      -p "{\"data\":{\"clientSecretSha256\":\"${want_hash}\"}}" >/dev/null
  else
    kubectl -n "${POD_NAMESPACE}" create configmap "${STATE_CONFIGMAP}" \
      --from-literal=clientSecretSha256="${want_hash}" >/dev/null
  fi
fi
log "Harbor OIDC configuration updated"
