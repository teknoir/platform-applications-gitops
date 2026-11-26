#!/usr/bin/env bash
# End-to-end test of the EMQX dashboard proxy (templates/dashboard.yaml) with docker only:
# the real emqx/emqx image, the rendered nginx config, envsh and guard script, and the
# pinned nginx image, run read-only as the chart runs them.
#
#   tests/dashboard-proxy-e2e.sh            run the matrix, remove everything at the end
#   tests/dashboard-proxy-e2e.sh --check    dry run: render, extract, check tools, no containers
#   tests/dashboard-proxy-e2e.sh --keep     leave the containers up and print the dashboard URL
#                                           (for a browser check); remove with --cleanup
#   tests/dashboard-proxy-e2e.sh --cleanup  remove containers and network of a --keep run
#
# Idempotent: every run uses the fixed names below and removes leftovers first.
# No secrets are printed: the API key is random per run and only used on the docker network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/.." && pwd)"
MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  --keep) MODE=keep ;;
  --cleanup) MODE=cleanup ;;
  "") ;;
  *) echo "usage: $0 [--check|--keep|--cleanup]" >&2; exit 2 ;;
esac

NET=emqx-dash-e2e
EMQX_IMAGE="${EMQX_IMAGE:-emqx/emqx:5.8.9}"
WORK="$(mktemp -d)"
PASS=0; FAIL=0

cleanup_containers() {
  docker rm -f "$NET-emqx" "$NET-proxy" "$NET-guard" "$NET-emqx2" "$NET-guard2" "$NET-badproxy" \
    "$NET-emqx3" "$NET-guard3" "$NET-fake" "$NET-guard4" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
finish() {
  [ "$MODE" = keep ] || cleanup_containers
  rm -rf "$WORK"
}
trap finish EXIT

if [ "$MODE" = cleanup ]; then cleanup_containers; echo "removed"; exit 0; fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
for t in helm docker curl python3; do need "$t"; done

ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
nok()  { FAIL=$((FAIL+1)); echo "FAIL - $1 ($2)"; }
expect() { # expect <description> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "want $2, got $3"; fi
}
code() { curl -s -o /dev/null -m 20 -w '%{http_code}' "$@"; }

# 1. Render the chart and extract the proxy files from the ConfigMap -----------------------
if ! ls "$CHART"/charts/emqx-*.tgz >/dev/null 2>&1; then
  if [ "$MODE" = check ]; then echo "note: charts/emqx is missing, run: helm dependency build $CHART"
  else helm dependency build "$CHART" >/dev/null || { echo "helm dependency build failed" >&2; exit 2; }; fi
fi
if ls "$CHART"/charts/emqx-*.tgz >/dev/null 2>&1; then
  helm template emqx "$CHART" -n teknoir-demo --show-only templates/dashboard.yaml > "$WORK/dashboard.yaml" || exit 2
  FILES="$WORK/files"; mkdir -p "$FILES"
  python3 -I - "$WORK/dashboard.yaml" "$FILES" <<'PY' || exit 2
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = next(d for d in docs if d["kind"] == "ConfigMap")
dep = next(d for d in docs if d["kind"] == "Deployment")
for k, v in cm["data"].items():
    open(f"{sys.argv[2]}/{k}", "w").write(v)
img = dep["spec"]["template"]["spec"]["containers"][0]["image"]
open(f"{sys.argv[2]}/IMAGE", "w").write(img)
PY
  chmod 0555 "$FILES/05-teknoir-auth.envsh"
  chmod 0444 "$FILES/default.conf.template" "$FILES/teknoir-sso.js" "$FILES/default-login-guard.sh"
  IMAGE="$(cat "$FILES/IMAGE")"
fi

if [ "$MODE" = check ]; then
  echo "check: would run $EMQX_IMAGE and ${IMAGE:-<proxy image>} on docker network $NET"
  for t in default.conf.template teknoir-sso.js 05-teknoir-auth.envsh default-login-guard.sh; do
    [ -s "$FILES/$t" ] && echo "check: extracted $t" || { echo "check: MISSING $t"; exit 1; }
  done
  sh -n "$FILES/default-login-guard.sh" && echo "check: guard script parses"
  bash -n "$FILES/05-teknoir-auth.envsh" && echo "check: envsh parses"
  exit 0
fi

cleanup_containers
docker network create "$NET" >/dev/null || exit 2

# 2. Start EMQX (legacy chart default password teknoir/teknoir) and a fresh one (public) ----
KEY="e2e$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
SECRET="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
printf '%s:%s\n' "$KEY" "$SECRET" > "$WORK/api-keys.txt"
chmod 0644 "$WORK/api-keys.txt"
start_emqx() { # start_emqx <name> [extra env...]
  local name="$1"; shift
  docker run -d --name "$name" --network "$NET" --network-alias "${name#$NET-}" -p 127.0.0.1::18083 \
    -v "$WORK/api-keys.txt:/opt/emqx-bootstrap/api-keys.txt:ro" \
    -e EMQX_API_KEY__BOOTSTRAP_FILE=/opt/emqx-bootstrap/api-keys.txt \
    -e EMQX_DASHBOARD__DEFAULT_USERNAME=teknoir "$@" "$EMQX_IMAGE" >/dev/null
}
start_emqx "$NET-emqx" -e EMQX_DASHBOARD__DEFAULT_PASSWORD=teknoir
start_emqx "$NET-emqx2"   # fresh volume: EMQX's built-in default password (public)

run_nginx() { # run_nginx <name> <upstream> <key> <secret>
  docker run -d --name "$1" --network "$NET" -p 127.0.0.1::18083 \
    --read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:uid=101,gid=101,mode=1777 --tmpfs /etc/nginx/conf.d:uid=101,gid=101,mode=0777 \
    -v "$FILES/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
    -v "$FILES/teknoir-sso.js:/teknoir/teknoir-sso.js:ro" \
    -v "$FILES/05-teknoir-auth.envsh:/docker-entrypoint.d/05-teknoir-auth.envsh:ro" \
    -e EMQX_API_KEY="$3" -e EMQX_API_SECRET="$4" \
    -e EMQX_DASHBOARD_UPSTREAM="$2" -e EMQX_VERSION=5.8.9 -e NGINX_ENTRYPOINT_QUIET_LOGS=1 \
    "$IMAGE" >/dev/null
}
run_guard() { # run_guard <name> <upstream> <known passwords>
  docker run -d --name "$1" --network "$NET" \
    --read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:uid=101,gid=101,mode=1777 \
    -v "$FILES/default-login-guard.sh:/teknoir/default-login-guard.sh:ro" \
    -e EMQX_DASHBOARD_UPSTREAM="$2" -e EMQX_DASHBOARD_ADMIN=teknoir \
    -e EMQX_KNOWN_DEFAULT_PASSWORDS="$3" -e GUARD_INTERVAL_SECONDS=3 \
    "$IMAGE" sh /teknoir/default-login-guard.sh >/dev/null
}
hostport() { docker port "$1" 18083/tcp | head -1 | sed 's/.*://'; }

run_nginx "$NET-proxy" "http://$NET-emqx:18083" "$KEY" "$SECRET"
run_nginx "$NET-badproxy" "http://$NET-emqx:18083" "$KEY" "wrong-secret"

echo "waiting for EMQX ..."
for n in emqx emqx2; do
  for i in $(seq 1 90); do
    p="$(hostport "$NET-$n")"
    [ -n "$p" ] && [ "$(code "http://127.0.0.1:$p/status")" = 200 ] && break
    sleep 2
  done
done
EMQX_URL="http://127.0.0.1:$(hostport "$NET-emqx")"
EMQX2_URL="http://127.0.0.1:$(hostport "$NET-emqx2")"
PROXY="http://127.0.0.1:$(hostport "$NET-proxy")"
BADPROXY="http://127.0.0.1:$(hostport "$NET-badproxy")"
expect "EMQX is up" 200 "$(code "$EMQX_URL/status")"
for i in $(seq 1 30); do [ "$(code "$PROXY/teknoir-healthz")" = 200 ] && break; sleep 1; done

login_code() { # login_code <emqx url> <password>
  curl -s -o /dev/null -m 20 -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"username\":\"teknoir\",\"password\":\"$2\"}" "$1/api/v5/login"
}

# 3. Before the guard: the known defaults work (proves the test would notice) ---------------
expect "before the guard: teknoir/teknoir logs in to EMQX" 200 "$(login_code "$EMQX_URL" teknoir)"
expect "before the guard: teknoir/public logs in to the fresh EMQX" 200 "$(login_code "$EMQX2_URL" public)"

# 4. Proxy matrix ---------------------------------------------------------------------------
expect "healthz" 200 "$(code "$PROXY/teknoir-healthz")"
expect "sso script is served" 200 "$(code "$PROXY/teknoir-sso.js")"
expect "index is served" 200 "$(code "$PROXY/")"
curl -s -m 20 "$PROXY/" | grep -q 'teknoir-sso.js' && ok "index references teknoir-sso.js" || nok "index references teknoir-sso.js" "not injected"
# What the dashboard SPA sends on every API call (its axios client uses the placeholder session)
SPA=(-H 'Authorization: Bearer teknoir-istio' -H 'Sec-Fetch-Site: same-origin')
expect "nodes from the SPA (placeholder bearer, same-origin): 200 (proxy adds the API key)" 200 "$(code "${SPA[@]}" "$PROXY/api/v5/nodes")"
expect "nodes without the placeholder bearer: 403 (CSRF guard)" 403 "$(code "$PROXY/api/v5/nodes")"
expect "nodes with a stale stored session (old EMQX JWT as bearer): 200, the proxy replaces it (owner who once used EMQX's login)" 200 "$(code -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.stale.stale' -H 'Sec-Fetch-Site: same-origin' "$PROXY/api/v5/nodes")"
expect "nodes with an empty bearer: 403" 403 "$(code -H 'Authorization: Bearer ' "$PROXY/api/v5/nodes")"
expect "nodes with a client Basic header: 403 (not the SPA)" 403 "$(code -H 'Authorization: Basic Zm9vOmJhcg==' "$PROXY/api/v5/nodes")"
expect "a POST with a stale bearer but Sec-Fetch-Site cross-site is 403" 403 "$(code -X POST -H 'Authorization: Bearer stale' -H 'Sec-Fetch-Site: cross-site' -H 'Content-Type: application/json' -d '{}' "$PROXY/api/v5/nodes")"
grep -q '!== TOKEN' "$FILES/teknoir-sso.js" && ok "sso script replaces any stored token, not only an empty one" || nok "sso script replaces any stored token" "check missing"
expect "clients list from the SPA" 200 "$(code "${SPA[@]}" "$PROXY/api/v5/clients")"
expect "a read with the bearer needs no Sec-Fetch-Site (GET, e.g. old browsers)" 200 "$(code -H 'Authorization: Bearer teknoir-istio' "$PROXY/api/v5/nodes")"
expect "a GET with the bearer passes whatever Sec-Fetch-Site says (a page cannot set the bearer: preflight)" 200 "$(code -H 'Authorization: Bearer teknoir-istio' -H 'Sec-Fetch-Site: cross-site' "$PROXY/api/v5/nodes")"
expect "a CORS preflight gets no credentials and no ACAO" 403 "$(code -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization' "$PROXY/api/v5/nodes")"
curl -s -D - -o /dev/null -m 20 -X OPTIONS -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization' "$PROXY/api/v5/nodes" | grep -qi '^access-control-allow' && nok "a CORS preflight has no Access-Control-Allow-*" "found" || ok "a CORS preflight has no Access-Control-Allow-*"
# CSRF: a cross-site form/multipart POST carries the owner's cookie but no placeholder bearer
printf 'user_id,password,is_superuser\ncsrfdevice,pw-not-used-1,true\n' > "$WORK/u.csv"
# The chart's authenticator 1 is the built-in database; create it so the import has a target
# (without it EMQX answers 404 and the rows below would pass for the wrong reason).
expect "setup: built-in database authenticator created (direct, with the API key)" 200 "$(curl -s -o /dev/null -m 20 -w '%{http_code}' -u "$KEY:$SECRET" -H 'Content-Type: application/json' -d '{"mechanism":"password_based","backend":"built_in_database","user_id_type":"username","password_hash_algorithm":{"name":"sha256","salt_position":"suffix"}}' "$EMQX_URL/api/v5/authentication")"
IMPORT="$PROXY/api/v5/authentication/password_based:built_in_database/import_users?type=plain"
expect "CSRF: cross-origin multipart import_users (Sec-Fetch-Site cross-site, no bearer) is 403" 403 "$(code -X POST -H 'Origin: https://evil.example' -H 'Sec-Fetch-Site: cross-site' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: same-site (*.teknoir.cloud) multipart import_users without bearer is 403" 403 "$(code -X POST -H 'Origin: https://app.example.test' -H 'Sec-Fetch-Site: same-site' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: a POST with the bearer but Sec-Fetch-Site same-site is 403" 403 "$(code -X POST -H 'Authorization: Bearer teknoir-istio' -H 'Sec-Fetch-Site: same-site' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: a POST with the bearer but Sec-Fetch-Site cross-site is 403" 403 "$(code -X POST -H 'Authorization: Bearer teknoir-istio' -H 'Sec-Fetch-Site: cross-site' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: a POST with the bearer but no Sec-Fetch-Site is 403 (writes fail closed)" 403 "$(code -X POST -H 'Authorization: Bearer teknoir-istio' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: a bare POST without any header is 403" 403 "$(code -X POST -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "CSRF: no user was created by the blocked requests" 0 "$(curl -s -m 20 -u "$KEY:$SECRET" "$EMQX_URL/api/v5/authentication/password_based:built_in_database/users" | grep -c csrfdevice)"
expect "SPA upload: the same multipart POST with bearer and same-origin reaches EMQX (200)" 200 "$(code -X POST "${SPA[@]}" -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "SPA upload: the user exists after the legitimate import" 1 "$(curl -s -m 20 -u "$KEY:$SECRET" "$EMQX_URL/api/v5/authentication/password_based:built_in_database/users" | grep -c csrfdevice)"
# Audit line: owner email, method and PATH of every API write and failing API call; never a query
# string, never the API key. The default "main" log must not also log API requests (it has them).
OWNER_HDR=(-H 'X-Auth-Request-Email: owner@example.test' -H 'X-Request-Id: req-audit-1')
expect "audit: a legitimate import with a query string reaches EMQX (200)" 200 "$(code -X POST "${SPA[@]}" "${OWNER_HDR[@]}" -F "filename=@$WORK/u.csv" "$IMPORT&marker=QSECRET1")"
expect "audit: a read with a query string (200)" 200 "$(code "${SPA[@]}" "${OWNER_HDR[@]}" "$PROXY/api/v5/nodes?marker=QSECRET2")"
expect "audit: a failing read with a query string (EMQX 404)" 404 "$(code "${SPA[@]}" "${OWNER_HDR[@]}" "$PROXY/api/v5/no_such_endpoint?marker=QSECRET3")"
expect "audit: a hostile header value (quote) from the gateway side" 200 "$(code -X POST "${SPA[@]}" -H 'X-Auth-Request-Email: a"b@example.test' -F "filename=@$WORK/u.csv" "$IMPORT")"
expect "audit: a page request with a query string (main log)" 200 "$(code "$PROXY/?marker=PAGE1")"
sleep 1
LOG="$(docker logs "$NET-proxy" 2>&1)"
AUD="$(printf '%s\n' "$LOG" | grep '^AUDIT ' || true)"
expect "audit: the write has one line with the owner's email, method, path, status and request id" 1 "$(printf '%s\n' "$AUD" | grep -c '^AUDIT emqx.dashboard user="owner@example.test" method=POST path="/api/v5/authentication/password_based:built_in_database/import_users" status=200 req_id="req-audit-1"$')"
expect "audit: a failing read is logged too (status 404, path only)" 1 "$(printf '%s\n' "$AUD" | grep -c 'user="owner@example.test" method=GET path="/api/v5/no_such_endpoint" status=404')"
[ "$(printf '%s\n' "$AUD" | grep -c 'user="-" method=POST path="/api/v5/authentication/password_based:built_in_database/import_users" status=403 ')" -ge 1 ] && ok "audit: a blocked CSRF write is logged (status 403, no user)" || nok "audit: a blocked CSRF write is logged (status 403, no user)" "no line"
expect "audit: a successful read is not logged" 0 "$(printf '%s\n' "$AUD" | grep -c 'method=GET path="/api/v5/nodes" status=200')"
expect "audit: the quote in a header value is escaped (one line, no raw quote)" 1 "$(printf '%s\n' "$AUD" | grep -c 'user="a\\x22b@example.test"')"
expect "no log line of the proxy contains a query string of an API request" 0 "$(printf '%s\n' "$LOG" | grep -c 'QSECRET\|type=plain')"
expect "the page request is still logged by the default log, with its query" 1 "$(printf '%s\n' "$LOG" | grep -v '^AUDIT ' | grep -c 'GET /?marker=PAGE1 ')"
expect "no AUDIT line for page requests" 0 "$(printf '%s\n' "$AUD" | grep -c 'PAGE1\|path="/"')"
case "$LOG" in *"$SECRET"*|*"$KEY"*) nok "audit/access log never contains the API key or secret" "found" ;; *) ok "audit/access log never contains the API key or secret" ;; esac
# Cache and framing headers of the index page
IDX="$(curl -s -D - -o /dev/null -m 20 "$PROXY/")"
expect "index: Cache-Control no-cache (exactly one header)" 1 "$(printf '%s\n' "$IDX" | grep -ci '^cache-control: no-cache')"
expect "index: no other Cache-Control header from EMQX" 1 "$(printf '%s\n' "$IDX" | grep -ci '^cache-control:')"
expect "index: X-Frame-Options DENY is kept" 1 "$(printf '%s\n' "$IDX" | grep -ci '^x-frame-options: DENY')"
expect "an asset is revalidated too" no-cache "$(curl -s -D - -o /dev/null -m 20 "$PROXY/$(curl -s -m 20 "$PROXY/" | grep -o 'static/[^"]*\.js' | head -1)" | tr -d '\r' | sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' | head -1)"
expect "sso script stays no-store" no-store "$(curl -s -D - -o /dev/null -m 20 "$PROXY/teknoir-sso.js" | tr -d '\r' | sed -n 's/^[Cc]ache-[Cc]ontrol: *//p' | head -1)"
expect "login is answered by the proxy" 200 "$(code -X POST -H 'Content-Type: application/json' -d '{"username":"x","password":"y"}' "$PROXY/api/v5/login")"
curl -s -m 20 -X POST -d '{}' "$PROXY/api/v5/login" | grep -q '"role":"administrator"' && ok "login response has the placeholder session" || nok "login response has the placeholder session" "unexpected body"
expect "logout" 204 "$(code -X POST "$PROXY/api/v5/logout")"
expect "users list is refused" 403 "$(code "$PROXY/api/v5/users")"
expect "users/x/change_pwd is refused" 403 "$(code -X POST -d '{}' "$PROXY/api/v5/users/teknoir/change_pwd")"
expect "users (POST create) is refused" 403 "$(code -X POST -d '{}' "$PROXY/api/v5/users")"
expect "api_key list is refused" 403 "$(code "$PROXY/api/v5/api_key")"
expect "api_key create is refused" 403 "$(code -X POST -d '{}' "$PROXY/api/v5/api_key")"
expect "api_key/x delete is refused" 403 "$(code -X DELETE "$PROXY/api/v5/api_key/foo")"
expect "path confusion /static/..%2Fapi/v5/nodes" 400 "$(code "${SPA[@]}" --path-as-is "$PROXY/static/..%2Fapi/v5/nodes")"
expect "path confusion /events%2F..%2Fapi/v5/nodes" 400 "$(code "${SPA[@]}" --path-as-is "$PROXY/events%2F..%2Fapi/v5/nodes")"
expect "path confusion /x/../api/v5/nodes (dot-normalised by nginx)" 400 "$(code "${SPA[@]}" --path-as-is "$PROXY/x/../api/v5/nodes")"
# Nothing the browser sees contains the credential
hdrs="$(curl -s -D - -o /dev/null -m 20 "${SPA[@]}" "$PROXY/api/v5/nodes"; curl -s -m 20 "$PROXY/"; curl -s -m 20 "${SPA[@]}" "$PROXY/api/v5/nodes")"
case "$hdrs" in *"$SECRET"*|*"$KEY"*) nok "responses never contain the API key or secret" "found" ;; *) ok "responses never contain the API key or secret" ;; esac
# The dashboard's own API paths that do not need credentials stay reachable
expect "status passes through" 200 "$(code "$PROXY/status")"

# 5. A wrong API key never produces a 401 (the gateway hangs on backend 401s) ----------------
expect "wrong key: nodes gives 403, never 401" 403 "$(code "${SPA[@]}" "$BADPROXY/api/v5/nodes")"
curl -s -m 20 "${SPA[@]}" "$BADPROXY/api/v5/nodes" | grep -q EMQX_CREDENTIAL_REJECTED && ok "wrong key: body is EMQX_CREDENTIAL_REJECTED" || nok "wrong key: body is EMQX_CREDENTIAL_REJECTED" "unexpected body"

# 6. The guard rotates the known defaults, once, and then does nothing ----------------------
run_guard "$NET-guard" "http://$NET-emqx:18083" "teknoir public"
run_guard "$NET-guard2" "http://$NET-emqx2:18083" "teknoir public"
for i in $(seq 1 30); do
  [ "$(login_code "$EMQX_URL" teknoir)" = 401 ] && [ "$(login_code "$EMQX2_URL" public)" = 401 ] && break
  sleep 2
done
expect "after the guard: EMQX rejects teknoir/teknoir" 401 "$(login_code "$EMQX_URL" teknoir)"
expect "after the guard: EMQX rejects teknoir/public" 401 "$(login_code "$EMQX_URL" public)"
expect "after the guard: fresh EMQX rejects teknoir/public" 401 "$(login_code "$EMQX2_URL" public)"
expect "after the guard: fresh EMQX rejects teknoir/teknoir" 401 "$(login_code "$EMQX2_URL" teknoir)"
sleep 8   # two more guard cycles
expect "guard logs exactly one rotation per EMQX (idempotent)" "1 1" "$(docker logs "$NET-guard" 2>&1 | grep -c 'rotated a known default dashboard password for teknoir') $(docker logs "$NET-guard2" 2>&1 | grep -c 'rotated a known default dashboard password for teknoir')"
expect "guard never reports a failed rotation" "0" "$(docker logs "$NET-guard" "$NET-guard2" 2>&1 | grep -c 'could not rotate')"
case "$(docker logs "$NET-guard" 2>&1)" in *"$SECRET"*) nok "guard log has no secrets" "api secret found" ;; *) ok "guard log has no secrets" ;; esac
expect "guard stays silent about the failing login attempts (no wget 401 noise)" 0 "$(docker logs "$NET-guard" "$NET-guard2" 2>&1 | grep -c 'wget:\|Unauthorized')"
expect "the proxy keeps working after the rotation" 200 "$(code "${SPA[@]}" "$PROXY/api/v5/nodes")"
expect "API key still works directly against EMQX" 200 "$(curl -s -o /dev/null -m 20 -w '%{http_code}' -u "$KEY:$SECRET" "$EMQX_URL/api/v5/nodes")"
# The guard leaves a custom (non-default) password alone
docker exec "$NET-emqx" emqx ctl admins passwd teknoir 'Custom-e2e-pw-1' >/dev/null 2>&1
sleep 8
expect "guard leaves a custom admin password alone" 200 "$(login_code "$EMQX_URL" 'Custom-e2e-pw-1')"

# 7. Guard logging and timing ------------------------------------------------------------------
# 7a. a failing change_pwd stays visible (wget's message and our line); a fake EMQX that accepts
#     the login and fails the password change
cat > "$WORK/fake.conf" <<'FAKE'
server {
    listen 18083;
    location = /status { return 200 "ok"; }
    location = /api/v5/login { default_type application/json; return 200 '{"token":"faketoken"}'; }
    location ~ ^/api/v5/users/[^/]+/change_pwd$ { return 500 "boom"; }
}
FAKE
docker run -d --name "$NET-fake" --network "$NET" --network-alias fake --user 101:101 \
  -v "$WORK/fake.conf:/etc/nginx/conf.d/default.conf:ro" "$IMAGE" >/dev/null
sleep 3
docker run -d --name "$NET-guard4" --network "$NET" \
  --read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:uid=101,gid=101,mode=1777 \
  -v "$FILES/default-login-guard.sh:/teknoir/default-login-guard.sh:ro" \
  -e EMQX_DASHBOARD_UPSTREAM="http://fake:18083" -e EMQX_DASHBOARD_ADMIN=teknoir \
  -e EMQX_KNOWN_DEFAULT_PASSWORDS="teknoir public" -e GUARD_INTERVAL_SECONDS=3600 \
  "$IMAGE" sh /teknoir/default-login-guard.sh >/dev/null
sleep 6
G4="$(docker logs "$NET-guard4" 2>&1)"
expect "failing change_pwd: the guard says so (one line per known password)" 2 "$(printf '%s\n' "$G4" | grep -c 'could not rotate a known default dashboard password')"
expect "failing change_pwd: wget's own error stays visible" 2 "$(printf '%s\n' "$G4" | grep -c 'wget: server returned error: HTTP/1.1 500')"
case "$G4" in *faketoken*) nok "guard log has no token" "token found" ;; *) ok "guard log has no token" ;; esac

# 7b. EMQX down, then up: the guard (interval 3600 s) rotates within seconds of EMQX coming back,
#     and while it is down /status failures are visible
docker run -d --name "$NET-guard3" --network "$NET" \
  --read-only --user 101:101 --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:uid=101,gid=101,mode=1777 \
  -v "$FILES/default-login-guard.sh:/teknoir/default-login-guard.sh:ro" \
  -e EMQX_DASHBOARD_UPSTREAM="http://$NET-emqx3:18083" -e EMQX_DASHBOARD_ADMIN=teknoir \
  -e EMQX_KNOWN_DEFAULT_PASSWORDS="teknoir public" -e GUARD_INTERVAL_SECONDS=3600 -e GUARD_RETRY_SECONDS=2 \
  "$IMAGE" sh /teknoir/default-login-guard.sh >/dev/null
sleep 8
[ "$(docker logs "$NET-guard3" 2>&1 | grep -c 'wget:')" -ge 1 ] && ok "EMQX down: the failing /status check stays visible and is retried" || nok "EMQX down: the failing /status check stays visible and is retried" "$(docker logs "$NET-guard3" 2>&1 | wc -l) log lines"
start_emqx "$NET-emqx3"
for i in $(seq 1 90); do
  p="$(hostport "$NET-emqx3")"
  [ -n "$p" ] && [ "$(code "http://127.0.0.1:$p/status")" = 200 ] && break
  sleep 2
done
EMQX3_URL="http://127.0.0.1:$(hostport "$NET-emqx3")"
expect "EMQX3 is up with the built-in default password" 200 "$(login_code "$EMQX3_URL" public)"
for i in $(seq 1 15); do [ "$(login_code "$EMQX3_URL" public)" = 401 ] && break; sleep 2; done
expect "after EMQX came back the guard rotated it within seconds (interval is 3600 s)" 401 "$(login_code "$EMQX3_URL" public)"
expect "guard logged one rotation after the restart" 1 "$(docker logs "$NET-guard3" 2>&1 | grep -c 'rotated a known default dashboard password')"

echo
echo "passed: $PASS, failed: $FAIL"
if [ "$MODE" = keep ]; then
  echo "dashboard (no login): $PROXY/   (remove with: $0 --cleanup)"
fi
[ "$FAIL" = 0 ]
