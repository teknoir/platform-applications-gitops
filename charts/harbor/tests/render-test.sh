#!/usr/bin/env bash
# SC2016: the single-quoted strings are jq programs.
# shellcheck disable=SC2016
# charts/harbor/tests/render-test.sh — render the harbor chart the way ArgoCD
# does (release harbor, namespace teknoir-system), check its access settings
# and images, and run the OIDC config Job's script (files/oidc-config.sh, as
# rendered) against a stub Harbor API. No cluster, no docker. Not packaged
# (.helmignore tests/).
#
# Checks (FAIL makes the script exit 1):
#   H1  the OIDC Job's desired settings: project creation for admins only
#       (project_creation_restriction adminonly), OIDC login with admin group
#       admin
#   H2  every fix-permissions init container runs busybox:1.36.1, by tag only
#       (harbor is a one-shot tier: no @sha256), and no image is on :latest
#   O1  a Harbor with the OIDC settings but project creation for everyone (as
#       teknoir-local before 0.0.10): exactly one PUT, of
#       project_creation_restriction only
#   O2  the second run changes nothing
#   O3  no admin password or client secret in the script's output
#
# Usage: charts/harbor/tests/render-test.sh
# Environment: KUBE_VERSION (default 1.33.5), RENDER_CACHE (default
# ~/.cache/teknoir-render, shared with tests/render.sh), HELM (default helm).
# Requires helm, yq, jq, python3, curl, sha256sum.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.33.5}"
RENDER_CACHE="${RENDER_CACHE:-${HOME}/.cache/teknoir-render}"
HELM="${HELM:-helm}"
BUSYBOX=busybox:1.36.1

for tool in "${HELM}" yq jq python3 curl sha256sum; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 2; }
done

umask 077
tmp="$(mktemp -d)"
stub_pid=""
cleanup() {
  [[ -z "${stub_pid}" ]] || kill "${stub_pid}" 2>/dev/null || true
  rm -rf "${tmp}"
}
trap cleanup EXIT

fails=0
pass() { printf 'PASS  %-3s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-3s %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --- render (scratch copy, dependencies from the render cache) ----------------
src="${tmp}/harbor"
cp -R "${CHART}" "${src}"
rm -rf "${src}/charts" "${src}/Chart.lock" "${src}/tests"
mkdir -p "${src}/charts" "${RENDER_CACHE}"
while IFS=$'\t' read -r name version repo; do
  [[ -n "${name}" ]] || continue
  key="${RENDER_CACHE}/$(printf '%s' "${repo}" | sed 's#[^A-Za-z0-9._-]#_#g')/${name}-${version}"
  if ! compgen -G "${key}/*.tgz" >/dev/null; then
    rm -rf "${key}.tmp" && mkdir -p "${key}.tmp"
    "${HELM}" pull "${name}" --repo "${repo}" --version "${version}" -d "${key}.tmp" >/dev/null
    rm -rf "${key}" && mv "${key}.tmp" "${key}"
  fi
  cp "${key}"/*.tgz "${src}/charts/"
done < <(yq -r '.dependencies // [] | .[] | [.name, .version, .repository] | @tsv' "${src}/Chart.yaml")
"${HELM}" template harbor "${src}" --namespace teknoir-system --kube-version "${KUBE_VERSION}" > "${tmp}/render.yaml"
yq -o=json -I=0 'select(. != null)' "${tmp}/render.yaml" | jq -s . > "${tmp}/render.json"
jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "harbor-oidc-config") | .data["desired.json"]' \
  "${tmp}/render.json" > "${tmp}/desired.json"
jq -r '.[] | select(.kind == "ConfigMap" and .metadata.name == "harbor-oidc-config") | .data["oidc-config.sh"]' \
  "${tmp}/render.json" > "${tmp}/oidc-config.sh"

# --- H1 desired settings --------------------------------------------------------
if jq -e '.project_creation_restriction == "adminonly" and .auth_mode == "oidc_auth"
          and .oidc_admin_group == "admin" and .oidc_groups_claim == "groups"' "${tmp}/desired.json" >/dev/null; then
  pass H1 "desired settings: project_creation_restriction adminonly, OIDC with admin group admin"
else
  fail H1 "desired settings: $(jq -c '{project_creation_restriction, auth_mode, oidc_admin_group}' "${tmp}/desired.json")"
fi

# --- H2 images ------------------------------------------------------------------
jq -r '[.. | objects | select(has("image") and (.image | type == "string")) | .image] | .[]' \
  "${tmp}/render.json" > "${tmp}/images"
fixers="$(jq -r '[.. | objects | select(.name? == "fix-permissions") | .image] | .[]' "${tmp}/render.json")"
if [[ -n "${fixers}" ]] && ! grep -vqxF "${BUSYBOX}" <<<"${fixers}"; then
  pass H2 "$(wc -l <<<"${fixers}") fix-permissions init containers run ${BUSYBOX}"
else
  fail H2 "fix-permissions images: $(sort -u <<<"${fixers}" | paste -sd' ' -)"
fi
if grep -qE '@sha256:|:latest$' "${tmp}/images" || grep -vqE ':[^/]+$' "${tmp}/images"; then
  fail H2 "an image is digest-pinned, on :latest or untagged: $(grep -E '@sha256:|:latest$' "${tmp}/images" | sort -u | paste -sd' ' -)"
else
  pass H2 "no image on :latest, untagged or digest-pinned (one-shot tier)"
fi

# --- O1-O3 oidc-config.sh against a stub Harbor ----------------------------------
ADMIN_PW="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
CLIENT_SECRET="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
mkdir -p "${tmp}/bin" "${tmp}/state"
# Harbor as on teknoir-local before 0.0.10: the OIDC settings applied, the
# client secret recorded, project creation open to everyone.
jq 'with_entries(.value = {value: .value, editable: true})
    + {project_creation_restriction: {value: "everyone", editable: true}}' "${tmp}/desired.json" \
  > "${tmp}/state/config.json"
printf '%s' "${CLIENT_SECRET}" | sha256sum | cut -d' ' -f1 > "${tmp}/state/cm-hash"
: > "${tmp}/state/puts"

cat > "${tmp}/harbor-stub.py" <<'EOF'
import base64, http.server, json, os, sys
state, pw = sys.argv[1], os.environ["STUB_ADMIN_PW"]
want = "Basic " + base64.b64encode(("admin:" + pw).encode()).decode()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def authed(self):
        if self.headers.get("Authorization") == want: return True
        self.reply(401, {"errors": [{"message": "unauthorized"}]}); return False
    def do_GET(self):
        if not self.authed(): return
        if self.path == "/api/v2.0/configurations":
            self.reply(200, json.load(open(state + "/config.json")))
        elif self.path.startswith("/api/v2.0/users"):
            self.reply(200, [{"username": "admin"}])
        else: self.reply(404, {})
    def do_PUT(self):
        if not self.authed(): return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        cfg = json.load(open(state + "/config.json"))
        for k, v in body.items():
            if k != "oidc_client_secret": cfg[k] = {"value": v, "editable": True}
        json.dump(cfg, open(state + "/config.json", "w"))
        with open(state + "/puts", "a") as f: f.write(json.dumps(sorted(body)) + "\n")
        self.reply(200, {})
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(state + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF
# kubectl stand-in for the state ConfigMap (get -o name / -o jsonpath, patch).
cat > "${tmp}/bin/kubectl" <<'EOF'
#!/bin/sh
case "$*" in
  *"get configmap"*"-o name"*) [ -s "${STUB_STATE}/cm-hash" ] && echo "configmap/harbor-oidc-config-state" ;;
  *"get configmap"*"jsonpath"*) cat "${STUB_STATE}/cm-hash" ;;
  *"patch configmap"*|*"create configmap"*) echo "$*" | sed -n 's/.*clientSecretSha256[^0-9a-f]*\([0-9a-f]\{64\}\).*/\1/p' > "${STUB_STATE}/cm-hash" ;;
  *) echo "kubectl stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${tmp}/bin/kubectl"
STUB_ADMIN_PW="${ADMIN_PW}" python3 "${tmp}/harbor-stub.py" "${tmp}/state" &
stub_pid=$!
for _ in $(seq 1 50); do [[ -s "${tmp}/state/port" ]] && break; sleep 0.1; done
port="$(cat "${tmp}/state/port")"

run_job() { # run_job N: one run of the Job's script; output in ${tmp}/run<N>.log
  PATH="${tmp}/bin:${PATH}" STUB_STATE="${tmp}/state" \
    HARBOR_API="http://127.0.0.1:${port}/api/v2.0" HARBOR_ADMIN_PASSWORD="${ADMIN_PW}" \
    OIDC_CLIENT_SECRET="${CLIENT_SECRET}" DESIRED="${tmp}/desired.json" \
    STATE_CONFIGMAP=harbor-oidc-config-state POD_NAMESPACE=teknoir-system WAIT_SECONDS=10 \
    sh "${tmp}/oidc-config.sh" > "${tmp}/run$1.log" 2>&1
}
if run_job 1 && [[ "$(cat "${tmp}/state/puts")" == '["project_creation_restriction"]' ]] \
    && [[ "$(jq -r .project_creation_restriction.value "${tmp}/state/config.json")" == adminonly ]]; then
  pass O1 "one PUT, of project_creation_restriction only ($(tail -1 "${tmp}/run1.log"))"
else
  fail O1 "PUTs: $(paste -sd' ' "${tmp}/state/puts"); log: $(tr '\n' ' ' < "${tmp}/run1.log")"
fi
if run_job 2 && [[ "$(wc -l < "${tmp}/state/puts")" -eq 1 ]] && grep -q 'nothing to change' "${tmp}/run2.log"; then
  pass O2 "second run: nothing to change"
else
  fail O2 "second run: $(tr '\n' ' ' < "${tmp}/run2.log")"
fi
if grep -qF -e "${ADMIN_PW}" -e "${CLIENT_SECRET}" "${tmp}/run1.log" "${tmp}/run2.log"; then
  fail O3 "a secret value is in the script's output"
else
  pass O3 "no admin password or client secret in the output"
fi

echo
echo "render-test.sh (harbor): ${fails} failed checks"
[[ "${fails}" -eq 0 ]]
