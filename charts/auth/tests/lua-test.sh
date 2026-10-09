#!/usr/bin/env bash
# Tests the gateway's two Lua filters from the rendered EnvoyFilter
# oauth2-proxy-ext-authz (not packaged: .helmignore tests/).
#
#   charts/auth/tests/lua-test.sh
#
# Renders the chart, extracts the inlineCode of envoy.filters.http.lua (login
# redirect) and envoy.filters.http.lua.authz_ok, and runs them with
# tests/lua-harness.lua (a stub of Envoy's Lua API that simulates the filter
# chain lua -> ext_authz -> authz_ok) in a pinned LuaJIT container (Envoy
# embeds LuaJIT 2.1; vpro has no Lua). Cases:
#   (a) denied, no cookie, navigation -> 302 /oauth2/start?rd=<encoded URL>
#   (b) denied with a garbage cookie -> 302 plus two expiring Set-Cookie
#   (c) denied fetch/XHR/websocket (Sec-Fetch-Mode, X-Requested-With) -> 401,
#       no Location
#   (d) ext_authz allowed, upstream 401 -> unchanged
#   (e) ext_authz allowed, upstream 403 -> unchanged (also with ext_authz
#       disabled for the route)
#   (f) /oauth2/callback denied -> unchanged
#   (g) 200 (and 302/404/500) -> unchanged
#   plus: rd from :authority/:path (not X-Forwarded-*), one Location, empty
#   body, no has_session heuristic, authz_ok is request-only.
# The filter ORDER (authz_ok INSERT_AFTER ext_authz, port 443) is asserted by
# tests/render-test.sh; on a real gateway by the VM e2e (E14).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# LuaJIT 2.1 (alpine), linux/amd64 manifest digest.
LUAJIT_IMAGE=${LUAJIT_IMAGE:-docker.io/nickblah/luajit:2.1.1787165859-alpine@sha256:0c1d93093ea91bdb1b93a0c2ccb3b907f48aca901a27d74db8aa660b587c68c4}
# shellcheck source-path=SCRIPTDIR source=lib.sh disable=SC1091
. "$HERE/lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

auth_chart_copy "$WORK/chart"
auth_render "$WORK/chart" "$WORK/render.yaml"
ef='select(.kind == "EnvoyFilter" and .metadata.name == "oauth2-proxy-ext-authz") | .spec.configPatches[] | select(.applyTo == "HTTP_FILTER")'
yq -r "$ef | select(.patch.value.name == \"envoy.filters.http.lua\") | .patch.value.typed_config.inlineCode" "$WORK/render.yaml" >"$WORK/redirect.lua"
yq -r "$ef | select(.patch.value.name == \"envoy.filters.http.lua.authz_ok\") | .patch.value.typed_config.inlineCode" "$WORK/render.yaml" >"$WORK/authz_ok.lua"
for f in redirect.lua authz_ok.lua; do
	[ -s "$WORK/$f" ] || {
		echo "FAIL the render has no $f filter" >&2
		exit 1
	}
done
DOMAIN=$(yq -r '.domain' "$WORK/chart/values.yaml")
COOKIE=$(yq -r '.oauth2Proxy.cookie.name' "$WORK/chart/values.yaml")
cp "$HERE/lua-harness.lua" "$WORK/harness.lua"
chmod -R a+rX "$WORK"

echo "luajit: $LUAJIT_IMAGE  domain: $DOMAIN  cookie: $COOKIE"
docker run --rm --network none -u 65534:65534 --read-only -v "$WORK:/w:ro" \
	-e DOMAIN="$DOMAIN" -e COOKIE="$COOKIE" -e LUA_DIR=/w \
	--entrypoint luajit "$LUAJIT_IMAGE" /w/harness.lua
