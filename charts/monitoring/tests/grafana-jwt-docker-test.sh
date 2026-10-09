#!/usr/bin/env bash
# SC2015: `[[ ... ]] && pass || fail` is intended (pass and fail always succeed).
# SC2016: the single-quoted strings are jq programs and container scripts.
# SC2119: render takes optional helm arguments.
# shellcheck disable=SC2015,SC2016,SC2119
# charts/monitoring/tests/grafana-jwt-docker-test.sh — run the chart's Grafana
# image with the chart's rendered grafana.ini in docker and prove the sign-in
# from the forwarded Keycloak access token (grafana.ini auth.jwt). No
# Kubernetes, no Keycloak: a test CA signs a TLS certificate for the host of
# jwk_set_url (auth.<domain>), a toolbox container serves the JWKS there over
# https, and the test mints RS256 tokens like Keycloak's (iss, groups,
# preferred_username, email). Not packaged (.helmignore tests/).
#
# Checks (FAIL makes the script exit 1):
#   G1  Grafana starts with the rendered grafana.ini, its CA mount and
#       SSL_CERT_DIR (as in the Deployment)
#   G2  no token: 401 (no anonymous access)
#   G3  token with groups [admin]: signed in, login = preferred_username,
#       email set, org role Admin; a second request reuses the same user
#   G4  token without group admin: signed in as Viewer
#   G5  rejected (401): another issuer, another signing key, expired
#   G6  basic auth as the local admin still works (sidecars, break-glass)
#   G7  without the Teknoir CA in SSL_CERT_DIR no token verifies (the JWKS
#       TLS certificate is really checked)
#   G8  an http jwk_set_url (the in-mesh keycloak-http service) is refused
#       by Grafana ("must have https scheme"): why the chart uses
#       https://auth.<domain>
#   G9  no token or password value in the Grafana logs
#   G10 the login form is off (auth.disable_login_form): a form login with the
#       local admin's right password signs no one in, so the break-glass is
#       basic auth against the API (G6), not a browser sign-in
#   G11 a CA that appears after Grafana started is not used until Grafana
#       restarts (Go loads the system roots once per process): why the
#       runbook restarts monitoring-grafana after it creates or rotates
#       Secret teknoir-root-ca-bundle
#
# The CA directory has the layout of a Kubernetes Secret volume
# (ca.crt -> ..data/ca.crt, ..data -> ..<timestamp>/), as Grafana sees it.
#
# Usage: charts/monitoring/tests/grafana-jwt-docker-test.sh
# Environment: TOOLBOX_IMAGE (default docker.io/alpine/k8s:1.34.11, the
# platform's toolbox: python3 for the JWKS server), plus lib.sh's KUBE_VERSION,
# RENDER_CACHE and HELM. Requires docker, helm, yq, jq, openssl, xxd, curl.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "${HERE}/lib.sh"
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-docker.io/alpine/k8s:1.34.11}"
NET=tkmon-jwt-test
JWKS_CT=tkmon-jwt-jwks
GRAFANA_CT=tkmon-jwt-grafana

for tool in docker "${HELM}" yq jq openssl xxd curl; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

tmp="$(mktemp -d)"
cleanup() {
  docker rm -f "${GRAFANA_CT}" "${JWKS_CT}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
  rm -rf "${tmp}"
}
trap cleanup EXIT

fails=0
pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- the chart's Grafana: image, grafana.ini, CA trust -----------------------
monitoring_render_setup "${tmp}"
render > "${tmp}/render.yaml"
yq -o=json -I=0 'select(. != null)' "${tmp}/render.yaml" | jq -s . > "${tmp}/render.json"
jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "monitoring-grafana") | .data["grafana.ini"]' \
  "${tmp}/render.json" > "${tmp}/grafana.ini"
jq '[.[] | select(.kind == "Deployment" and .metadata.name == "monitoring-grafana")][0].spec.template.spec
    | (.containers[] | select(.name == "grafana")) as $c
    | {image: $c.image,
       ssl_cert_dir: ([$c.env[] | select(.name == "SSL_CERT_DIR") | .value][0] // ""),
       ca_mount: ([$c.volumeMounts[] | select(.mountPath == "/etc/teknoir/ca")][0].mountPath // "")}' \
  "${tmp}/render.json" > "${tmp}/grafana.json"
IMAGE="$(jq -r .image "${tmp}/grafana.json")"
SSL_CERT_DIR_VALUE="$(jq -r .ssl_cert_dir "${tmp}/grafana.json")"
CA_MOUNT="$(jq -r .ca_mount "${tmp}/grafana.json")"
ini() { # ini SECTION KEY
  awk -v s="[$1]" -v k="$2" '
    /^\[/ { in_s = ($0 == s); next }
    in_s { i = index($0, "="); key = substr($0, 1, i - 1); gsub(/[ \t]/, "", key)
           if (key == k) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); print v; exit } }' "${tmp}/grafana.ini"
}
JWKS_URL="$(ini auth.jwt jwk_set_url)"
HEADER="$(ini auth.jwt header_name)"
ISSUER="$(ini auth.jwt expect_claims | jq -r .iss)"
[[ "${JWKS_URL}" == https://* && -n "${HEADER}" && -n "${ISSUER}" && -n "${CA_MOUNT}" ]] \
  || { echo "render has no https jwk_set_url, header_name, issuer or CA mount" >&2; exit 1; }
JWKS_HOST="${JWKS_URL#https://}"
JWKS_HOST="${JWKS_HOST%%/*}"
JWKS_PATH="/${JWKS_URL#https://*/}"
SUBPATH="$(ini server root_url | sed -E 's#^[^/]*//[^/]*##; s#/$##')"
echo "image ${IMAGE}  jwks ${JWKS_URL}  header ${HEADER}  subpath ${SUBPATH}"

# --- test PKI, JWKS, tokens --------------------------------------------------
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# secret_volume DIR CERT: DIR holds CERT as ca.crt the way the kubelet writes
# a Secret volume (atomic writer: ca.crt -> ..data/ca.crt, ..data -> ..<ts>/).
secret_volume() {
  local ts="..2026_10_09_00_00_00.000000001"
  mkdir -p "$1/${ts}"
  cp "$2" "$1/${ts}/ca.crt"
  ln -sfn "${ts}" "$1/..data"
  ln -sfn ..data/ca.crt "$1/ca.crt"
}
mkdir -p "${tmp}/ca" "${tmp}/ca-late" "${tmp}/srv/www$(dirname "${JWKS_PATH}")"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=Test Teknoir Root CA" \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -keyout "${tmp}/ca.key" -out "${tmp}/ca.crt" 2>/dev/null
secret_volume "${tmp}/ca" "${tmp}/ca.crt"
openssl req -newkey rsa:2048 -nodes -subj "/CN=${JWKS_HOST}" \
  -keyout "${tmp}/srv/tls.key" -out "${tmp}/tls.csr" 2>/dev/null
printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "${JWKS_HOST}" > "${tmp}/ext"
openssl x509 -req -in "${tmp}/tls.csr" -CA "${tmp}/ca.crt" -CAkey "${tmp}/ca.key" \
  -CAcreateserial -days 1 -extfile "${tmp}/ext" -out "${tmp}/srv/tls.crt" 2>/dev/null
openssl genrsa -out "${tmp}/sign.key" 2048 2>/dev/null
openssl genrsa -out "${tmp}/other.key" 2048 2>/dev/null
n="$(openssl rsa -in "${tmp}/sign.key" -noout -modulus | cut -d= -f2 | xxd -r -p | b64url)"
jq -n -c --arg n "${n}" '{keys: [{kty: "RSA", kid: "test", use: "sig", alg: "RS256", n: $n, e: "AQAB"}]}' \
  > "${tmp}/srv/www${JWKS_PATH}"
chmod -R a+rX "${tmp}/srv" "${tmp}/ca" "${tmp}/ca-late"

# mint KEY PAYLOAD_JSON: an RS256 token (kid test).
mint() {
  local h p s
  h="$(printf '%s' '{"alg":"RS256","typ":"JWT","kid":"test"}' | b64url)"
  p="$(printf '%s' "$2" | b64url)"
  s="$(printf '%s.%s' "${h}" "${p}" | openssl dgst -sha256 -sign "$1" | b64url)"
  printf '%s.%s.%s' "${h}" "${p}" "${s}"
}
# claims ISSUER GROUPS_JSON USER EXP_OFFSET: access-token claims like Keycloak's.
claims() {
  jq -n -c --arg iss "$1" --argjson groups "$2" --arg user "$3" --argjson off "$4" '
    (now | floor) as $t
    | {iss: $iss, sub: ($user | @base64), aud: "account", typ: "Bearer", azp: "teknoir",
       iat: ($t - 60), exp: ($t + $off), preferred_username: $user, email: $user,
       email_verified: true, groups: $groups}'
}
ADMIN_USER=admin.user@example.org
VIEWER_USER=viewer.user@example.org
T_ADMIN="$(mint "${tmp}/sign.key" "$(claims "${ISSUER}" '["admin"]' "${ADMIN_USER}" 600)")"
T_VIEWER="$(mint "${tmp}/sign.key" "$(claims "${ISSUER}" '["staff"]' "${VIEWER_USER}" 600)")"
T_OTHER_ISS="$(mint "${tmp}/sign.key" "$(claims "https://auth.example.org/auth/realms/teknoir" '["admin"]' "${ADMIN_USER}" 600)")"
T_OTHER_KEY="$(mint "${tmp}/other.key" "$(claims "${ISSUER}" '["admin"]' "${ADMIN_USER}" 600)")"
T_EXPIRED="$(mint "${tmp}/sign.key" "$(claims "${ISSUER}" '["admin"]' "${ADMIN_USER}" -120)")"
ADMIN_PW="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
printf 'user = "admin:%s"\n' "${ADMIN_PW}" > "${tmp}/basic"
chmod 600 "${tmp}/basic"

# --- containers ----------------------------------------------------------------
docker network create "${NET}" >/dev/null
docker run -d --name "${JWKS_CT}" --network "${NET}" --network-alias "${JWKS_HOST}" \
  -v "${tmp}/srv:/srv:ro" --entrypoint python3 "${TOOLBOX_IMAGE}" -c '
import functools, http.server, ssl
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="/srv/www")
srv = http.server.ThreadingHTTPServer(("", 443), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/srv/tls.crt", "/srv/tls.key")
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()' >/dev/null

# start_grafana INI SSL_CERT_DIR [CA_DIR]: (re)start Grafana as the
# Deployment runs it, with CA_DIR (default the test CA) at the CA mount; sets
# BASE. Returns 1 when it does not become healthy within 120 s.
start_grafana() {
  docker rm -f "${GRAFANA_CT}" >/dev/null 2>&1 || true
  docker run -d --name "${GRAFANA_CT}" --network "${NET}" -p 127.0.0.1::3000 \
    -v "$1:/etc/grafana/grafana.ini:ro" -v "${3:-${tmp}/ca}:${CA_MOUNT}:ro" \
    --mount type=tmpfs,destination=/var/lib/grafana-search,tmpfs-mode=1777 \
    -e SSL_CERT_DIR="$2" -e GF_SECURITY_ADMIN_USER=admin -e GF_SECURITY_ADMIN_PASSWORD="${ADMIN_PW}" \
    "${IMAGE}" >/dev/null
  wait_grafana
}
# wait_grafana: wait until Grafana answers /api/health; sets BASE (the host
# port can change on a restart).
wait_grafana() {
  local port
  for _ in $(seq 1 60); do
    port="$(docker port "${GRAFANA_CT}" 3000/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    if [[ -n "${port}" ]]; then
      BASE="http://127.0.0.1:${port}${SUBPATH}"
      [[ "$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/health")" == 200 ]] && return 0
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "${GRAFANA_CT}" 2>/dev/null)" == true ]] || return 1
    sleep 2
  done
  return 1
}
# get PATH [TOKEN]: body in ${tmp}/body, HTTP status in $code. The token goes
# to curl through a 0600 header file, never argv.
get() {
  : > "${tmp}/hdr" && chmod 600 "${tmp}/hdr"
  [[ -z "${2:-}" ]] || printf '%s: %s\n' "${HEADER}" "$2" > "${tmp}/hdr"
  code="$(curl -s -m 20 -H "@${tmp}/hdr" -o "${tmp}/body" -w '%{http_code}' "${BASE}$1")" || code=000
}
role_of() { # role_of TOKEN: the user's role in org 1, or HTTP <code>
  get /api/user/orgs "$1"
  if [[ "${code}" == 200 ]]; then jq -r '[.[] | select(.orgId == 1) | .role][0] // "none"' "${tmp}/body"
  else echo "HTTP ${code}"; fi
}

# G1
if start_grafana "${tmp}/grafana.ini" "${SSL_CERT_DIR_VALUE}"; then
  pass G1 "Grafana ${IMAGE##*:} starts with the rendered grafana.ini (SSL_CERT_DIR=${SSL_CERT_DIR_VALUE})"
else
  fail G1 "Grafana does not become healthy; last log lines:"
  docker logs --tail 20 "${GRAFANA_CT}" 2>&1 | sed 's/^/      /'
  exit 1
fi

# G2
get /api/user
[[ "${code}" == 401 ]] && pass G2 "no token: HTTP 401" || fail G2 "no token: HTTP ${code}, want 401"

# G3
get /api/user "${T_ADMIN}"
if [[ "${code}" == 200 && "$(jq -r .login "${tmp}/body")" == "${ADMIN_USER}" \
      && "$(jq -r .email "${tmp}/body")" == "${ADMIN_USER}" ]]; then
  admin_id="$(jq -r .id "${tmp}/body")"
  pass G3 "group admin: signed in, login and email = preferred_username/email"
else
  admin_id=""
  fail G3 "group admin: HTTP ${code}, login '$(jq -r '.login // ""' "${tmp}/body" 2>/dev/null)'"
fi
r="$(role_of "${T_ADMIN}")"
[[ "${r}" == Admin ]] && pass G3 "group admin: org role Admin" || fail G3 "group admin: org role ${r}, want Admin"
get /api/user "${T_ADMIN}"
[[ "${code}" == 200 && -n "${admin_id}" && "$(jq -r .id "${tmp}/body")" == "${admin_id}" ]] \
  && pass G3 "group admin: the next request is the same user (id ${admin_id})" \
  || fail G3 "group admin: second request HTTP ${code} or another user"

# G4
r="$(role_of "${T_VIEWER}")"
[[ "${r}" == Viewer ]] && pass G4 "no group admin: org role Viewer" || fail G4 "no group admin: org role ${r}, want Viewer"

# G5
for t in other-issuer other-key expired; do
  case "${t}" in
    other-issuer) tok="${T_OTHER_ISS}" ;;
    other-key) tok="${T_OTHER_KEY}" ;;
    expired) tok="${T_EXPIRED}" ;;
  esac
  get /api/user "${tok}"
  [[ "${code}" == 401 ]] && pass G5 "${t} token: HTTP 401" || fail G5 "${t} token: HTTP ${code}, want 401"
done

# G6
code="$(curl -s -m 20 -K "${tmp}/basic" -o "${tmp}/body" -w '%{http_code}' "${BASE}/api/user")" || code=000
[[ "${code}" == 200 && "$(jq -r .login "${tmp}/body")" == admin ]] \
  && pass G6 "basic auth as the local admin: HTTP 200" || fail G6 "basic auth as the local admin: HTTP ${code}"

# G10: a form login (what the browser's login page posts) with the right
# password. The password goes to curl in a 0600 file, never argv.
jq -n -c --rawfile pw <(printf '%s' "${ADMIN_PW}") '{user: "admin", password: $pw}' > "${tmp}/login.json"
chmod 600 "${tmp}/login.json"
code="$(curl -s -m 20 -X POST -H 'Content-Type: application/json' --data-binary "@${tmp}/login.json" \
  -D "${tmp}/login.hdr" -o "${tmp}/body" -w '%{http_code}' "${BASE}/login")" || code=000
if [[ "${code}" != 200 && "${code}" != 000 ]] && ! grep -qi '^set-cookie: grafana_session=[^;]' "${tmp}/login.hdr"; then
  pass G10 "form login with the admin's right password: HTTP ${code}, no session (login form off: break-glass is basic auth on the API)"
else
  fail G10 "form login with the admin's right password: HTTP ${code}, a session cookie may be set"
fi

# G9 (this Grafana's logs, before it is replaced)
docker logs "${GRAFANA_CT}" > "${tmp}/grafana.log" 2>&1
leaked=""
for v in "${ADMIN_PW}" "${T_ADMIN}" "${T_VIEWER}" "${T_ADMIN##*.}"; do
  grep -qF -- "${v}" "${tmp}/grafana.log" && leaked=yes
done
[[ -z "${leaked}" ]] && pass G9 "no token or password value in the Grafana logs" || fail G9 "a token or password value is in the Grafana logs"

# G7
if start_grafana "${tmp}/grafana.ini" /etc/ssl/certs; then
  r="$(role_of "${T_ADMIN}")"
  [[ "${r}" == "HTTP 401" ]] && pass G7 "without the Teknoir CA: the admin token is rejected (TLS verified)" \
    || fail G7 "without the Teknoir CA: ${r}, want HTTP 401"
else
  fail G7 "Grafana without the CA does not start"
fi

# G11: Secret teknoir-root-ca-bundle created after Grafana started. The
# kubelet fills an optional Secret volume once the Secret exists; Grafana does
# not pick the CA up until it restarts.
if start_grafana "${tmp}/grafana.ini" "${SSL_CERT_DIR_VALUE}" "${tmp}/ca-late"; then
  r="$(role_of "${T_ADMIN}")"
  [[ "${r}" == "HTTP 401" ]] && pass G11 "no CA yet in the mount: the admin token is rejected" \
    || fail G11 "no CA yet in the mount: ${r}, want HTTP 401"
  # What an operator sees in the Grafana log (the runbook's symptom).
  line="$(docker logs "${GRAFANA_CT}" 2>&1 | grep -iE 'x509|unknown authority|jwks|jwk' | tail -1 \
    | sed -E 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/<jwt>/g' | cut -c1-300)"
  printf 'INFO  G11 Grafana log without the CA: %s\n' "${line:-<no matching line>}"
  secret_volume "${tmp}/ca-late" "${tmp}/ca.crt"
  chmod -R a+rX "${tmp}/ca-late"
  r="$(role_of "${T_ADMIN}")"
  [[ "${r}" == "HTTP 401" ]] && pass G11 "CA added while Grafana runs: still rejected (roots loaded once per process)" \
    || fail G11 "CA added while Grafana runs: ${r}; the runbook's restart step would be unnecessary, update it"
  docker restart "${GRAFANA_CT}" >/dev/null
  if wait_grafana; then
    r="$(role_of "${T_ADMIN}")"
    [[ "${r}" == Admin ]] && pass G11 "after a restart the CA is used: org role Admin" \
      || fail G11 "after a restart: ${r}, want Admin"
  else
    fail G11 "Grafana does not come back after a restart"
  fi
else
  fail G11 "Grafana with an empty CA mount does not start"
fi

# G8
sed "s#^jwk_set_url = .*#jwk_set_url = http://keycloak-http.teknoir-auth.svc.cluster.local${JWKS_PATH}#" \
  "${tmp}/grafana.ini" > "${tmp}/grafana-http.ini"
if start_grafana "${tmp}/grafana-http.ini" "${SSL_CERT_DIR_VALUE}"; then
  r="$(role_of "${T_ADMIN}")"
  [[ "${r}" == Admin ]] && fail G8 "an http jwk_set_url is accepted; the chart could use the in-mesh URL" \
    || pass G8 "an http jwk_set_url does not sign anyone in (${r})"
else
  if docker logs "${GRAFANA_CT}" 2>&1 | grep -q 'must have https scheme'; then
    pass G8 "an http jwk_set_url stops Grafana: 'must have https scheme'"
  else
    fail G8 "Grafana with an http jwk_set_url does not start, for another reason"
  fi
fi

echo
echo "grafana-jwt-docker-test.sh: ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
