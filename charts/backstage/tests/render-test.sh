#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# Render tests for the backstage chart (not packaged: .helmignore tests/).
# No cluster, no network (kubeconform needs its schemas; skipped if absent).
#
#   charts/backstage/tests/render-test.sh
#
# Renders the chart like ArgoCD does (release backstage, namespace
# teknoir-system) with this branch's values (teknoir-local), and with the
# new values cleared the way other environments have them. Checks:
#   L1 backstage-api startupProbe on /.backstage/health/v1/readiness:7007,
#      period 10 s, timeout 5 s, failureThreshold 60
#   L2 readinessProbe (same path, 10/5/3) and livenessProbe
#      (/.backstage/health/v1/liveness, 20/5/6); no initialDelaySeconds
#   L3 app-config.prod-env.yaml: catalog.providers.k8s users and profiles
#      every minute, roles and orgtree every 5 minutes, one schedule-only
#      entry each; peripherals not overridden
#   L4 frontend env APP_CONFIG_teknoir_auth_issuer equals the
#      RequestAuthentication issuer, APP_CONFIG_teknoir_auth_clientId teknoir;
#      not on backstage-api
#   L5 backstage-app and backstage images are K5 pins
#      (<repo>:<immutable tag>@sha256:<digest>), IfNotPresent. A
#      sha-PENDING-WP-BS placeholder fails unless ALLOW_PLACEHOLDER_PINS=1
#   L6 backstage-postgres postgres:17.11-alpine@sha256:aa90e97e...; no
#      container pulls Always
#   L8 backstage-api has initContainer wait-for-postgres (the postgres pin,
#      pg_isready against backstage-postgres:5432, bounded loop, exit 0 after
#      it); waitForDb.enabled=false removes it
#   L9 the frontend mounts a chart script as /docker-entrypoint.d/45-inject-index-config.sh
#      (the image's own APP_CONFIG_* injection never reaches the loader: index.html's
#      config script tag wins); run against a fixture it adds only teknoir.* to <head>
#      as window.__APP_CONFIG__, idempotent, no-op without APP_CONFIG_teknoir_*; off
#      with indexRuntimeConfig.enabled=false or without config.oidc.realm
#   L7 helm lint; kubeconform -strict (when installed)
#   D1 schedules {} and no config.oidc.realm (chart defaults): no catalog
#      override, no APP_CONFIG_teknoir_auth_*
#   D2 no catalog key and no config.oidc.realm/clientId: renders, neither
#   D3 no config.oidc at all (staging's values; only the Deployments, as the
#      unchanged RequestAuthentications and externalAccess need it): renders,
#      no APP_CONFIG_teknoir_auth_*
#   C1 config.oidc.clientId is passed through; unset it defaults to teknoir
#   F1 overriding peripherals fails the render, naming the allowed providers
#   F2 an unknown provider fails the render
#   F3 a schedule without timeout fails the render
#   F4 a schedule that is not a map fails the render
# Environment: KUBE_VERSION (default 1.33.5, as live), HELM (default helm),
# ALLOW_PLACEHOLDER_PINS=1. Requires helm and yq (mikefarah v4).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
HELM=${HELM:-helm}
NS=teknoir-system
pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# render <chart dir> <out file> [helm args...]
render() {
	local dir=$1 out=$2
	shift 2
	"$HELM" template backstage "$dir" --namespace "$NS" --kube-version "$KUBE_VERSION" "$@" >"$out"
}
# variant <name> <yq expression>: a copy of the chart whose values.yaml is
# edited by the expression (helm --set cannot reset a map to {}).
variant() {
	local dir="$WORK/$1/backstage"
	mkdir -p "$WORK/$1"
	cp -r "$CHART" "$dir"
	rm -rf "$dir/tests"
	yq -i "$2" "$dir/values.yaml"
	echo "$dir"
}
# q <file> <yq expression>: one value from a multi-document render.
q() { yq -r "$2" "$1" | { grep -v '^---$' || true; } | sed '/^$/d'; }
appconfig() { q "$1" 'select(.kind == "ConfigMap" and .metadata.name == "backstage-app-config") | .data["app-config.prod-env.yaml"]' >"$1.appconfig"; }
container() { echo "select(.kind == \"Deployment\" and .metadata.name == \"$1\") | .spec.template.spec.containers[] | select(.name == \"$1\")"; }

echo "== teknoir-local values"
render "$CHART" "$WORK/local.yaml"
appconfig "$WORK/local.yaml"
API=$(container backstage-api)
FE=$(container backstage)

probe() { q "$WORK/local.yaml" "$API | .$1 | [.httpGet.path, .httpGet.port, .periodSeconds, .timeoutSeconds, .failureThreshold, (.initialDelaySeconds // \"none\")] | join(\" \")"; }
got=$(probe startupProbe)
[ "$got" = "/.backstage/health/v1/readiness 7007 10 5 60 none" ] &&
	ok "L1 startupProbe ($got)" || bad "L1 startupProbe: '$got'"
got_r=$(probe readinessProbe)
got_l=$(probe livenessProbe)
[ "$got_r" = "/.backstage/health/v1/readiness 7007 10 5 3 none" ] &&
	[ "$got_l" = "/.backstage/health/v1/liveness 7007 20 5 6 none" ] &&
	ok "L2 readinessProbe ($got_r), livenessProbe ($got_l)" ||
	bad "L2 readinessProbe '$got_r', livenessProbe '$got_l'"

sched() { yq -r ".catalog.providers.k8s.$1 | [length, .[0].schedule.frequency.minutes, .[0].schedule.timeout.minutes, (.[0] | keys | join(\",\"))] | join(\" \")" "$WORK/local.yaml.appconfig"; }
got="users=$(sched users) profiles=$(sched profiles) roles=$(sched roles) orgtree=$(sched orgtree)"
want="users=1 1 2 schedule profiles=1 1 2 schedule roles=1 5 3 schedule orgtree=1 5 3 schedule"
peri=$(yq -r '.catalog.providers.k8s | has("peripherals")' "$WORK/local.yaml.appconfig")
[ "$got" = "$want" ] && [ "$peri" = false ] &&
	ok "L3 catalog schedules ($got), peripherals untouched" || bad "L3 catalog schedules: '$got' peripherals=$peri"

issuer=$(q "$WORK/local.yaml" "$FE | .env[] | select(.name == \"APP_CONFIG_teknoir_auth_issuer\") | .value")
client=$(q "$WORK/local.yaml" "$FE | .env[] | select(.name == \"APP_CONFIG_teknoir_auth_clientId\") | .value")
ra=$(q "$WORK/local.yaml" 'select(.kind == "RequestAuthentication" and .metadata.name == "backstage-request-auth") | .spec.jwtRules[0].issuer')
api_auth=$(q "$WORK/local.yaml" "$API | .env[] | select(.name | test(\"^APP_CONFIG_teknoir_auth_\")) | .name")
[ "$issuer" = "https://auth.teknoir.airgapped/auth/realms/teknoir" ] && [ "$issuer" = "$ra" ] &&
	[ "$client" = teknoir ] && [ -z "$api_auth" ] &&
	ok "L4 frontend teknoir.auth issuer=$issuer clientId=$client (= RequestAuthentication issuer)" ||
	bad "L4 frontend issuer='$issuer' (RequestAuthentication '$ra') clientId='$client' api='$api_auth'"

# K5: immutable tag (sha-<hex>, <branch>-YYYYMMDD-HHMMSS or semver) plus a
# sha256 digest that is not the placeholder.
K5_TAG='(sha-[0-9a-f]{7,}|[A-Za-z0-9._-]+-[0-9]{8}-[0-9]{6}|v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?)'
for c in backstage:ghcr.io/teknoir/backstage-app backstage-api:ghcr.io/teknoir/backstage; do
	name=${c%%:*}
	repo=${c#*:}
	img=$(q "$WORK/local.yaml" "$(container "$name") | .image")
	pol=$(q "$WORK/local.yaml" "$(container "$name") | .imagePullPolicy")
	if [[ "$img" =~ ^${repo//./\\.}:${K5_TAG}@sha256:[0-9a-f]{64}$ ]] && [[ "$img" != *@sha256:0000000000000000000000000000000000000000000000000000000000000000 ]] && [ "$pol" = IfNotPresent ]; then
		ok "L5 $name image is a K5 pin ($img, $pol)"
	elif [[ "$img" == "$repo:sha-PENDING-WP-BS@sha256:"* ]] && [ "$pol" = IfNotPresent ]; then
		if [ "${ALLOW_PLACEHOLDER_PINS:-0}" = 1 ]; then
			echo "PENDING L5 $name image is the WP-BS placeholder ($img); allowed by ALLOW_PLACEHOLDER_PINS=1"
		else
			bad "L5 $name image is the WP-BS placeholder ($img): pin the r5-backstage build (ALLOW_PLACEHOLDER_PINS=1 to skip)"
		fi
	else
		bad "L5 $name image '$img' pullPolicy '$pol' is not a K5 pin with IfNotPresent"
	fi
done

pg=$(q "$WORK/local.yaml" 'select(.kind == "StatefulSet" and .metadata.name == "backstage-postgres") | .spec.template.spec.containers[] | select(.name == "postgres") | .image + " " + .imagePullPolicy')
always=$(q "$WORK/local.yaml" '.spec.template.spec | select(.) | (.initContainers // []) + .containers | .[] | select(.imagePullPolicy != "IfNotPresent") | .name + "=" + (.imagePullPolicy // "unset")')
[ "$pg" = "postgres:17.11-alpine@sha256:aa90e97ee862e558111d34cfb8b2c4bec768c2b039fb791341686928560263b3 IfNotPresent" ] && [ -z "$always" ] &&
	ok "L6 backstage-postgres pinned ($pg); every container IfNotPresent" ||
	bad "L6 backstage-postgres '$pg'; not IfNotPresent: ${always//$'\n'/ }"

wi=$(q "$WORK/local.yaml" 'select(.kind == "Deployment" and .metadata.name == "backstage-api") | .spec.template.spec.initContainers[] | select(.name == "wait-for-postgres") | .image + " " + .command[2]')
wi_img=${wi%% *}
[ "$wi_img" = "${pg%% *}" ] && [[ "$wi" == *"pg_isready -q -h backstage-postgres -p 5432 -U backstage -d postgres"* ]] && [[ "$wi" == *"exit 0"* ]] &&
	ok "L8 backstage-api waits for postgres with the pinned postgres image" ||
	bad "L8 wait-for-postgres initContainer missing or wrong ('$wi_img')"
render "$CHART" "$WORK/nowait.yaml" --set backstageApi.waitForDb.enabled=false
nw=$(q "$WORK/nowait.yaml" 'select(.kind == "Deployment" and .metadata.name == "backstage-api") | .spec.template.spec.initContainers // [] | length')
[ "$nw" = 0 ] && ok "L8b waitForDb.enabled=false renders no initContainer" || bad "L8b initContainers with waitForDb disabled: $nw"

lint=$(cd "$WORK" && "$HELM" lint "$CHART" --namespace "$NS" --kube-version "$KUBE_VERSION" 2>&1) &&
	ok "L7 helm lint" || { bad "L7 helm lint"; echo "$lint"; }
if command -v kubeconform >/dev/null 2>&1; then
	kc=$(kubeconform -strict -ignore-missing-schemas -kubernetes-version "$KUBE_VERSION" -summary "$WORK/local.yaml" 2>&1) &&
		ok "L7 kubeconform -strict: ${kc##*Summary: }" || { bad "L7 kubeconform"; echo "$kc"; }
else
	echo "SKIP L7 kubeconform (not installed)"
fi

# Assert that a render overrides neither the catalog nor the frontend auth.
no_override() {
	local id=$1 file=$2
	appconfig "$file"
	local cat env
	cat=$(yq -r 'has("catalog")' "$file.appconfig")
	env=$(q "$file" '.spec.template.spec.containers[]? | .env[]? | select(.name | test("^APP_CONFIG_teknoir_auth_")) | .name')
	[ "$cat" = false ] && [ -z "$env" ] &&
		ok "$id no catalog override, no APP_CONFIG_teknoir_auth_*" ||
		bad "$id catalog override=$cat, env: ${env//$'\n'/ }"
}

echo "== chart defaults (schedules {}, no config.oidc.realm)"
dir=$(variant defaults '.catalog.k8sProviderSchedules = {} | del(.config.oidc.realm)')
render "$dir" "$WORK/defaults.yaml" && no_override D1 "$WORK/defaults.yaml" || bad "D1 render failed"

echo "== no catalog key, no realm/clientId"
dir=$(variant absent 'del(.catalog) | del(.config.oidc.realm) | del(.config.oidc.clientId)')
render "$dir" "$WORK/absent.yaml" && no_override D2 "$WORK/absent.yaml" || bad "D2 render failed"

echo "== staging-style values (no config.oidc)"
dir=$(variant staging 'del(.catalog) | del(.config.oidc)')
rm "$dir/templates/istio-requestauth.yaml" "$dir/templates/configmap-app-config.yaml"
if render "$dir" "$WORK/staging.yaml"; then
	env=$(q "$WORK/staging.yaml" '.spec.template.spec.containers[]? | .env[]? | select(.name | test("^APP_CONFIG_teknoir_auth_")) | .name')
	n=$(q "$WORK/staging.yaml" 'select(.kind == "Deployment") | .metadata.name' | wc -l)
	[ "$n" -eq 2 ] && [ -z "$env" ] && ok "D3 Deployments render without config.oidc, no APP_CONFIG_teknoir_auth_*" ||
		bad "D3 deployments=$n env: ${env//$'\n'/ }"
else
	bad "D3 render failed"
fi

echo "== frontend index.html runtime config (the image's own injection never reaches the loader)"
# L9: a chart script adds teknoir.* to index.html (window.__APP_CONFIG__); the
# frontend mounts it where nginx runs it after the image's 40-inject-config.sh
mnt=$(q "$WORK/local.yaml" "$FE | .volumeMounts[] | select(.name == \"frontend-inject\") | [.mountPath, .subPath] | join(\" \")")
vol=$(q "$WORK/local.yaml" 'select(.kind == "Deployment" and .metadata.name == "backstage") | .spec.template.spec.volumes[] | select(.name == "frontend-inject") | [.configMap.name, .configMap.defaultMode] | join(" ")')
q "$WORK/local.yaml" 'select(.kind == "ConfigMap" and .metadata.name == "backstage-frontend-inject") | .data["45-inject-index-config.sh"]' >"$WORK/inject.sh"
[ "$mnt" = "/docker-entrypoint.d/45-inject-index-config.sh 45-inject-index-config.sh" ] && [ "$vol" = "backstage-frontend-inject 493" ] &&
	ok "L9 frontend mounts the inject script as /docker-entrypoint.d/45-inject-index-config.sh, mode 0755 (493)" ||
	bad "L9 mount '$mnt' volume '$vol'"
# run the rendered script against a fixture
printf '<html><head><title>x</title></head><body>a|b&c</body></html>\n' >"$WORK/index.html"
cp "$WORK/index.html" "$WORK/index.orig"
env -i PATH="$PATH" INDEX_HTML="$WORK/index.html" APP_CONFIG_app_baseUrl=https://x \
	APP_CONFIG_teknoir_auth_issuer="$issuer" APP_CONFIG_teknoir_auth_clientId=teknoir sh "$WORK/inject.sh" >/dev/null 2>&1
cfg=$(sed -n 's/.*<script data-teknoir-runtime-config>window.__APP_CONFIG__=\(.*\);<\/script><\/head>.*/\1/p' "$WORK/index.html")
got=$(jq -r '[.teknoir.auth.issuer, .teknoir.auth.clientId, (keys | join(","))] | join(" ")' <<<"$cfg" 2>/dev/null || true)
cp "$WORK/index.html" "$WORK/index.once"
env -i PATH="$PATH" INDEX_HTML="$WORK/index.html" APP_CONFIG_teknoir_auth_issuer=other sh "$WORK/inject.sh" >/dev/null 2>&1
cp "$WORK/index.orig" "$WORK/index2.html"
env -i PATH="$PATH" INDEX_HTML="$WORK/index2.html" APP_CONFIG_app_baseUrl=https://x sh "$WORK/inject.sh" >/dev/null 2>&1
[ "$got" = "$issuer teknoir teknoir" ] && grep -q 'a|b&c' "$WORK/index.html" && cmp -s "$WORK/index.html" "$WORK/index.once" && cmp -s "$WORK/index.orig" "$WORK/index2.html" &&
	ok "L9b script writes only teknoir.* (issuer, clientId) into <head>, is idempotent, no-op without APP_CONFIG_teknoir_*" ||
	bad "L9b script result '$got', idempotent=$(cmp -s "$WORK/index.html" "$WORK/index.once" && echo y || echo n), noop=$(cmp -s "$WORK/index.orig" "$WORK/index2.html" && echo y || echo n)"
render "$CHART" "$WORK/l9off.yaml" --set backstage.indexRuntimeConfig.enabled=false
n_off=$(q "$WORK/l9off.yaml" 'select(.metadata.name == "backstage-frontend-inject") | .metadata.name' | wc -l)
v_off=$(q "$WORK/l9off.yaml" "$FE | .volumeMounts // [] | length")
dir=$(variant norealm 'del(.config.oidc.realm)')
render "$dir" "$WORK/l9nr.yaml"
n_nr=$(q "$WORK/l9nr.yaml" 'select(.metadata.name == "backstage-frontend-inject") | .metadata.name' | wc -l)
v_nr=$(q "$WORK/l9nr.yaml" 'select(.kind == "Deployment" and .metadata.name == "backstage") | .spec.template.spec.volumes // [] | length')
[ "$n_off" = 0 ] && [ "$v_off" = 0 ] && [ "$n_nr" = 0 ] && [ "$v_nr" = 0 ] &&
	ok "L9c indexRuntimeConfig.enabled=false and no config.oidc.realm render no ConfigMap, mount or volume" ||
	bad "L9c off: cm=$n_off mounts=$v_off; no realm: cm=$n_nr volumes=$v_nr"

echo "== clientId"
render "$CHART" "$WORK/c1.yaml" --set config.oidc.clientId=other
dir=$(variant noclient 'del(.config.oidc.clientId)')
render "$dir" "$WORK/c2.yaml"
c1=$(q "$WORK/c1.yaml" "$FE | .env[] | select(.name == \"APP_CONFIG_teknoir_auth_clientId\") | .value")
c2=$(q "$WORK/c2.yaml" "$FE | .env[] | select(.name == \"APP_CONFIG_teknoir_auth_clientId\") | .value")
[ "$c1" = other ] && [ "$c2" = teknoir ] && ok "C1 clientId set=$c1, unset=$c2" || bad "C1 clientId set='$c1' unset='$c2'"

echo "== invalid schedules"
# render_fails <id> <expected message regex> <helm args...>
render_fails() {
	local id=$1 re=$2
	shift 2
	local out
	if out=$(render "$CHART" /dev/null "$@" 2>&1); then
		bad "$id render succeeded"
	elif grep -Eq "$re" <<<"$out"; then
		ok "$id render fails: $(grep -Eo "$re.*" <<<"$out" | head -1 | cut -c1-120)"
	else
		bad "$id unexpected error: $out"
	fi
}
render_fails F1 'k8sProviderSchedules\.peripherals: only these providers' \
	--set 'catalog.k8sProviderSchedules.peripherals.frequency.minutes=1' --set 'catalog.k8sProviderSchedules.peripherals.timeout.minutes=1'
render_fails F2 'k8sProviderSchedules\.nosuch: only these providers' \
	--set 'catalog.k8sProviderSchedules.nosuch.frequency.minutes=1' --set 'catalog.k8sProviderSchedules.nosuch.timeout.minutes=1'
render_fails F3 'k8sProviderSchedules\.services needs both frequency and timeout' \
	--set 'catalog.k8sProviderSchedules.services.frequency.minutes=1'
render_fails F4 'k8sProviderSchedules\.devices must be a map' \
	--set 'catalog.k8sProviderSchedules.devices=PT1M'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
