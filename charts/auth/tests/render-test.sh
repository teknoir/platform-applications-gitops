#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# SC2016: the yq programs match the literal $(env:...) placeholder.
# shellcheck disable=SC2015,SC2016
# Render assertions for the auth chart (not packaged: .helmignore tests/).
# Needs helm, yq (mikefarah v4) and, if present, kubeconform; no cluster, no
# docker.
#
#   charts/auth/tests/render-test.sh
#
#   T1 images: keycloak renders <repo>:sha-29d2ed6a@sha256:ab392e6e... with the
#      label app.kubernetes.io/version sha-29d2ed6a; keycloak-db, redis and
#      httpbin are pinned by digest; every container is IfNotPresent, none
#      is :latest or tag-less without a digest
#   T2 EnvoyFilter: all three HTTP_FILTER patches match portNumber 443;
#      ext_authz INSERT_FIRST, the redirect Lua INSERT_BEFORE ext_authz,
#      authz_ok INSERT_AFTER ext_authz; no has_session heuristic; the
#      per-vhost/route disables are kept; istio.bypassAuth renders a vhost
#      patch disabling ext_authz and the Lua redirect (none by default)
#   T3 keycloak-config Job: KC_MASTER_LEGACY_CLIENTS=teknoir,argocd,harbor and
#      KC_REALM=teknoir on the admin-check init container; the render fails
#      for a built-in or malformed clientId; [] renders an empty value
#   T4 realm: client teknoir has post.logout.redirect.uris https://<domain>/*;
#      VERIFY_PROFILE is disabled (enabled with realm.verifyProfile=true); no
#      userProfile document; platform-admin is disabled by default
#   T5 Chart.yaml version 0.0.9; the admin-check script passes sh -n;
#      kubeconform -strict on the core kinds (if installed)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh disable=SC1091
. "$HERE/lib.sh"

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
auth_chart_copy "$WORK/chart"
R=$WORK/render.yaml
auth_render "$WORK/chart" "$R"

# qf <file> <expr>: every match across the documents, no separators.
qf() { yq ea -N -r "$2" "$1"; }
q() { qf "$R" "$1"; }

echo "== T1 images"
KC_REF=ghcr.io/teknoir/keycloak-theme:sha-29d2ed6a@sha256:ab392e6e52789483c63818cbe8919ae0e44b6cf547c17faf8a0f024cc29d35f7
[ "$(q 'select(.kind == "StatefulSet" and .metadata.name == "keycloak") | .spec.template.spec.containers[] | select(.name == "keycloak") | .image')" = "$KC_REF" ] &&
	ok "T1 keycloak image is $KC_REF" || bad "T1 keycloak image: $(q 'select(.kind == "StatefulSet" and .metadata.name == "keycloak") | .spec.template.spec.containers[0].image')"
[ "$(q 'select(.kind == "StatefulSet" and .metadata.name == "keycloak") | .metadata.labels["app.kubernetes.io/version"]')" = sha-29d2ed6a ] &&
	[ "$(q 'select(.kind == "StatefulSet" and .metadata.name == "keycloak") | .spec.template.metadata.labels["app.kubernetes.io/version"] // "sha-29d2ed6a"')" = sha-29d2ed6a ] &&
	ok "T1 keycloak label app.kubernetes.io/version is sha-29d2ed6a" || bad "T1 keycloak version label"
want_image() { # <kind>/<name> <container> <ref>
	local got
	got=$(q "select(.kind == \"${1%%/*}\" and .metadata.name == \"${1#*/}\") | .spec.template.spec.containers[] | select(.name == \"$2\") | .image + \" \" + .imagePullPolicy")
	[ "$got" = "$3 IfNotPresent" ] && ok "T1 $1 $3 IfNotPresent" || bad "T1 $1: got '$got'"
}
want_image StatefulSet/keycloak-db postgres docker.io/library/postgres:16.15@sha256:75adc2a65806c96bc0e59030230bfe3f1c1b0d6d8f8181a8913e2b8b53bdc166
want_image StatefulSet/oauth2-proxy-redis redis docker.io/library/redis:7.2.16-alpine@sha256:84bab713067f5494d94c24e99ae3fa3ae2388c037152edcbcf301f7cfaeb3048
want_image Deployment/httpbin httpbin docker.io/kennethreitz/httpbin@sha256:599fe5e5073102dbb0ee3dbb65f049dab44fa9fc251f6835c9990f8fb196a72b
imgs=$(q '.spec.template.spec | select(. != null) | (.initContainers // []) + .containers | .[] | .image + " " + (.imagePullPolicy // "-")' | sort -u)
while read -r l; do echo "     $l"; done <<<"$imgs"
bad_imgs=$(echo "$imgs" | awk '{ ref = $1; pol = $2
	if (pol == "Always") { print; next }
	if (ref ~ /@sha256:/) next
	n = split(ref, p, "/"); last = p[n]
	if (last !~ /:/ || last ~ /:latest$/) print }')
[ -z "$bad_imgs" ] && ok "T1 no Always, no :latest, no tag-less image" || bad "T1 floating or Always: $bad_imgs"

echo "== T2 EnvoyFilter"
EF='select(.kind == "EnvoyFilter" and .metadata.name == "oauth2-proxy-ext-authz") | .spec.configPatches'
order=$(q "$EF | .[] | select(.applyTo == \"HTTP_FILTER\") | [.match.listener.portNumber, .patch.operation, (.match.listener.filterChain.filter.subFilter.name // \"-\"), .patch.value.name] | join(\" \")")
expected="443 INSERT_FIRST - envoy.filters.http.ext_authz
443 INSERT_BEFORE envoy.filters.http.ext_authz envoy.filters.http.lua
443 INSERT_AFTER envoy.filters.http.ext_authz envoy.filters.http.lua.authz_ok"
[ "$order" = "$expected" ] && ok "T2 three HTTP_FILTER patches on :443: ext_authz first, Lua before it, authz_ok after it" ||
	bad "T2 HTTP_FILTER patches: $order"
q "$EF | .[] | select(.patch.value.name == \"envoy.filters.http.lua.authz_ok\") | .patch.value.typed_config.inlineCode" | grep -q 'dynamicMetadata():set("oauth2_proxy", "authz", "ok")' &&
	ok "T2 authz_ok sets oauth2_proxy.authz=ok" || bad "T2 authz_ok code"
lua=$(q "$EF | .[] | select(.patch.value.name == \"envoy.filters.http.lua\") | .patch.value.typed_config.inlineCode")
! grep -q has_session <<<"$lua" && grep -q 'md\["authz"\] == "ok"' <<<"$lua" && grep -q 'https://teknoir.airgapped/oauth2/start?rd=' <<<"$lua" &&
	grep -q '_teknoir_oauth2_proxy=; Domain=teknoir.airgapped; Path=/;' <<<"$lua" && grep -q 'SameSite=None' <<<"$lua" &&
	ok "T2 redirect Lua: authz mark, no has_session, login on the shared host, expiring cookie" || bad "T2 redirect Lua content"
disables=$(q "$EF | .[] | select(.applyTo != \"HTTP_FILTER\") | (.match.routeConfiguration.vhost.name // .match.routeConfiguration.vhost.route.name) + \" \" + (.patch.value.typed_per_filter_config | keys | join(\",\"))")
expected='auth.teknoir.airgapped:443 envoy.filters.http.ext_authz
harbor.teknoir.airgapped:443 envoy.filters.http.ext_authz,envoy.filters.http.lua
argocd.teknoir.airgapped:443 envoy.filters.http.ext_authz
oauth2-proxy-auth envoy.filters.http.ext_authz
keycloak envoy.filters.http.ext_authz,envoy.filters.http.lua'
[ "$disables" = "$expected" ] && ok "T2 per-vhost/route disables unchanged, no bypassAuth by default" || bad "T2 disables: $disables"
auth_render "$WORK/chart" "$WORK/bypass.yaml" --set-json 'istio.bypassAuth=[{"gateway":"istio-system/contoai-gateway","vhost":"contoai.site:443"}]'
by=$(qf "$WORK/bypass.yaml" "$EF | .[] | select(.match.routeConfiguration.vhost.name == \"contoai.site:443\") | .match.routeConfiguration.gateway + \" \" + (.patch.value.typed_per_filter_config | to_entries | map(.key + \"=\" + (.value.disabled | tostring)) | join(\",\"))")
[ "$by" = "istio-system/contoai-gateway envoy.filters.http.ext_authz=true,envoy.filters.http.lua=true" ] &&
	ok "T2 bypassAuth vhost disables ext_authz and the Lua redirect" || bad "T2 bypassAuth: '$by'"

echo "== T3 keycloak-config Job"
JOBENV='select(.kind == "Job" and .metadata.name == "keycloak-config") | .spec.template.spec.initContainers[] | select(.name == "admin-check") | .env[]'
[ "$(q "$JOBENV | select(.name == \"KC_MASTER_LEGACY_CLIENTS\") | .value")" = teknoir,argocd,harbor ] &&
	[ "$(q "$JOBENV | select(.name == \"KC_REALM\") | .value")" = teknoir ] &&
	ok "T3 admin-check env KC_MASTER_LEGACY_CLIENTS=teknoir,argocd,harbor KC_REALM=teknoir" || bad "T3 admin-check env"
for c in admin-cli security-admin-console broker master-realm realm-management account account-console teknoir-realm 'bad,name' 'a b'; do
	if auth_render "$WORK/chart" "$WORK/x.yaml" --set-json "keycloakConfig.masterLegacyClients=[\"teknoir\",\"$c\"]" 2>"$WORK/err"; then
		bad "T3 masterLegacyClients '$c' renders"
	else
		grep -q 'masterLegacyClients' "$WORK/err" && ok "T3 masterLegacyClients '$c' is refused" || bad "T3 '$c': $(cat "$WORK/err")"
	fi
done
auth_render "$WORK/chart" "$WORK/none.yaml" --set-json 'keycloakConfig.masterLegacyClients=[]'
[ "$(qf "$WORK/none.yaml" "$JOBENV | select(.name == \"KC_MASTER_LEGACY_CLIENTS\") | .value")" = "" ] &&
	ok "T3 masterLegacyClients [] renders an empty list (step off)" || bad "T3 empty list"

echo "== T4 realm"
realm() { qf "$1" 'select(.kind == "ConfigMap" and .metadata.name == "keycloak-config") | .data["teknoir.yaml"]'; }
realm "$R" >"$WORK/realm.yaml"
[ "$(yq -r '.clients[] | select(.clientId == "teknoir") | .attributes["post.logout.redirect.uris"]' "$WORK/realm.yaml")" = 'https://teknoir.airgapped/*' ] &&
	ok "T4 client teknoir post.logout.redirect.uris https://teknoir.airgapped/*" || bad "T4 post.logout.redirect.uris"
[ "$(yq -r '.requiredActions[] | select(.alias == "VERIFY_PROFILE") | [.providerId, .enabled, .defaultAction] | join(" ")' "$WORK/realm.yaml")" = 'VERIFY_PROFILE false false' ] &&
	ok "T4 VERIFY_PROFILE disabled" || bad "T4 VERIFY_PROFILE"
[ "$(yq -r '.requiredActions | length' "$WORK/realm.yaml")" = 1 ] && [ "$(yq -r 'has("userProfile") or has("components")' "$WORK/realm.yaml")" = false ] &&
	ok "T4 only VERIFY_PROFILE is managed; no userProfile document" || bad "T4 extra required actions or a userProfile"
[ "$(yq -r '.users[] | select(.username == "$(env:PLATFORM_ADMIN_USERNAME)") | .enabled' "$WORK/realm.yaml")" = false ] &&
	ok "T4 platform-admin disabled by default" || bad "T4 platform-admin enabled"
auth_render "$WORK/chart" "$WORK/alt.yaml" --set realm.verifyProfile=true --set realm.platformAdmin.enabled=true --set domain=example.org
realm "$WORK/alt.yaml" >"$WORK/realm-alt.yaml"
[ "$(yq -r '.requiredActions[] | select(.alias == "VERIFY_PROFILE") | .enabled' "$WORK/realm-alt.yaml")" = true ] &&
	[ "$(yq -r '.users[] | select(.username == "$(env:PLATFORM_ADMIN_USERNAME)") | .enabled' "$WORK/realm-alt.yaml")" = true ] &&
	[ "$(yq -r '.clients[] | select(.clientId == "teknoir") | .attributes["post.logout.redirect.uris"]' "$WORK/realm-alt.yaml")" = 'https://example.org/*' ] &&
	ok "T4 values switch VERIFY_PROFILE, platform-admin and the logout domain" || bad "T4 value overrides"

echo "== T5 chart"
[ "$(yq -r .version "$WORK/chart/Chart.yaml")" = 0.0.9 ] && ok "T5 Chart version 0.0.9" || bad "T5 Chart version"
sh -n "$WORK/chart/files/keycloak-admin-check.sh" && ok "T5 keycloak-admin-check.sh parses (sh -n)" || bad "T5 sh -n"
if command -v kubeconform >/dev/null; then
	if kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.33.5 "$R" >"$WORK/kc.out" 2>&1; then
		ok "T5 kubeconform -strict: $(tail -1 "$WORK/kc.out")"
	else
		bad "T5 kubeconform: $(cat "$WORK/kc.out")"
	fi
else
	echo "SKIP T5 kubeconform not installed"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
