#!/usr/bin/env bash
# shellcheck disable=SC2015 # `check && ok || bad` is intended (ok/bad always succeed)
# Render test of the platform-secrets chart on teknoir-cloud (staging). Light:
# no cluster, no Docker. Not packaged (.helmignore tests/).
#
#   charts/platform-secrets/tests/render-test-teknoir-cloud.sh
#
# Needs helm, yq (v4), kubeconform and git; crane is optional (R7).
#   R1 code identity: chart code equals platform-secrets 0.0.1 on
#      airgap-redesign (everything but values.yaml and tests/), so the
#      redesign's k3d-test.sh T1-T13 covers the script and templates
#   R2 `helm template | kubeconform -strict`: exactly the 8 expected objects
#   R3 the rendered secrets.spec is exactly the one staging Secret
#      (no random key: staging generates nothing, it only copies)
#   R4 RBAC: teknoir-auth may only get oauth2-proxy-secret; teknoir-system
#      may get/patch backstage-keycloak-secrets, create secrets and get/patch
#      deployment user-controller; nothing cluster-scoped
#   R5 Job/CronJob: image pinned as <repo>:<semver>@sha256:<digest>,
#      IfNotPresent, no sidecar, hook annotations, CronJob schedule
#   R6 app-of-apps renders Application platform-secrets (path, revision,
#      project, wave -10, destination, automated prune/selfHeal)
#   R7 (online, optional) the pinned digest is the linux/amd64 manifest
#      digest of the tag, not the index digest
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
REPO=$(cd "$CHART/../.." && pwd)
REDESIGN_REF=${REDESIGN_REF:-origin/airgap-redesign}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
skip() { echo "SKIP $*"; }

echo "== R1 code identity with $REDESIGN_REF"
if git -C "$REPO" rev-parse --verify -q "$REDESIGN_REF^{commit}" >/dev/null; then
	# Compares the working tree (committed or not) with the redesign chart.
	if git -C "$REPO" diff --quiet "$REDESIGN_REF" -- charts/platform-secrets \
		':(exclude)charts/platform-secrets/values.yaml' ':(exclude)charts/platform-secrets/tests'; then
		ok "R1 chart code identical to $REDESIGN_REF (values.yaml and tests/ excluded)"
	else
		bad "R1 chart code differs from $REDESIGN_REF:"
		git -C "$REPO" diff --stat "$REDESIGN_REF" -- charts/platform-secrets \
			':(exclude)charts/platform-secrets/values.yaml' ':(exclude)charts/platform-secrets/tests'
	fi
	# Untracked files are invisible to git diff: list what the redesign lacks.
	extra=$(cd "$REPO" && find charts/platform-secrets -type f ! -path 'charts/platform-secrets/tests/*' \
		! -name values.yaml | sort | while read -r f; do
		git cat-file -e "$REDESIGN_REF:$f" 2>/dev/null || echo "$f"
	done)
	[ -z "$extra" ] && ok "R1 no chart file outside the redesign's set" || bad "R1 extra files: $extra"
else
	skip "R1 $REDESIGN_REF not available (git fetch origin airgap-redesign)"
fi

echo "== R2 render + kubeconform"
helm template platform-secrets "$CHART" -n teknoir-system >"$WORK/render.yaml"
if kubeconform -strict -summary "$WORK/render.yaml" >"$WORK/kc.txt" 2>&1; then
	ok "R2 kubeconform -strict: $(tail -1 "$WORK/kc.txt")"
else
	bad "R2 kubeconform:"
	cat "$WORK/kc.txt"
fi
yq -N '.kind + " " + .metadata.namespace + "/" + .metadata.name' "$WORK/render.yaml" | sort >"$WORK/objects"
cat >"$WORK/objects.want" <<'EOF'
ConfigMap teknoir-system/platform-secrets
CronJob teknoir-system/platform-secrets-resync
Job teknoir-system/platform-secrets-ensure
Role teknoir-auth/platform-secrets
Role teknoir-system/platform-secrets
RoleBinding teknoir-auth/platform-secrets
RoleBinding teknoir-system/platform-secrets
ServiceAccount teknoir-system/platform-secrets
EOF
diff -u "$WORK/objects.want" "$WORK/objects" && ok "R2 exactly the 8 expected objects" || bad "R2 object list"

echo "== R3 secrets.spec"
yq -N 'select(.kind == "ConfigMap") | .data["secrets.spec"]' "$WORK/render.yaml" | sed '/^$/d' >"$WORK/spec"
# KEYCLOAK_CLIENTID=teknoir, KEYCLOAK_REALM=master (base64), both sync: true.
cat >"$WORK/spec.want" <<'EOF'
S|teknoir-system|backstage-keycloak-secrets|Opaque|0
L|teknoir.org/managed-by|platform-secrets
K|KEYCLOAK_CLIENTID|value|dGVrbm9pcg==|1
K|KEYCLOAK_REALM|value|bWFzdGVy|1
K|KEYCLOAK_CLIENTSECRET|copy|teknoir-auth|oauth2-proxy-secret|client-secret
R|teknoir-system|user-controller
E
EOF
diff -u "$WORK/spec.want" "$WORK/spec" && ok "R3 secrets.spec is exactly the staging entry" || bad "R3 secrets.spec"
grep -q '|random|' "$WORK/spec" && bad "R3 staging spec has a random key" || ok "R3 no random key (nothing is generated)"
[ "$(yq -N 'select(.kind == "ConfigMap") | .data["ensure-secrets.sh"]' "$WORK/render.yaml")" = "$(cat "$CHART/files/ensure-secrets.sh")" ] &&
	ok "R3 ConfigMap carries files/ensure-secrets.sh verbatim" || bad "R3 script in ConfigMap differs"

echo "== R4 RBAC"
rules() { yq -N -o=json -I=0 "select(.kind == \"Role\" and .metadata.namespace == \"$1\") | .rules" "$WORK/render.yaml"; }
[ "$(rules teknoir-auth)" = '[{"apiGroups":[""],"resources":["secrets"],"resourceNames":["oauth2-proxy-secret"],"verbs":["get"]}]' ] &&
	ok "R4 teknoir-auth: only get on oauth2-proxy-secret" || bad "R4 teknoir-auth rules: $(rules teknoir-auth)"
want_sys='[{"apiGroups":[""],"resources":["secrets"],"resourceNames":["backstage-keycloak-secrets"],"verbs":["get"]},'
want_sys+='{"apiGroups":[""],"resources":["secrets"],"resourceNames":["backstage-keycloak-secrets"],"verbs":["patch"]},'
want_sys+='{"apiGroups":[""],"resources":["secrets"],"verbs":["create"]},'
want_sys+='{"apiGroups":["apps"],"resources":["deployments"],"resourceNames":["user-controller"],"verbs":["get","patch"]}]'
[ "$(rules teknoir-system)" = "$want_sys" ] &&
	ok "R4 teknoir-system: get/patch backstage-keycloak-secrets, create secrets, get/patch user-controller" ||
	bad "R4 teknoir-system rules: $(rules teknoir-system)"
yq -N 'select(.kind == "RoleBinding") | .metadata.namespace + " " + .roleRef.kind + "/" + .roleRef.name + " " +
	(.subjects | map(.kind + ":" + .namespace + "/" + .name) | join(","))' "$WORK/render.yaml" | sort >"$WORK/rb"
printf '%s\n' "teknoir-auth Role/platform-secrets ServiceAccount:teknoir-system/platform-secrets" \
	"teknoir-system Role/platform-secrets ServiceAccount:teknoir-system/platform-secrets" >"$WORK/rb.want"
diff -u "$WORK/rb.want" "$WORK/rb" && ok "R4 RoleBindings bind only the platform-secrets ServiceAccount" || bad "R4 RoleBindings"
grep -qE '^kind: Cluster(Role|RoleBinding)' "$WORK/render.yaml" && bad "R4 cluster-scoped RBAC rendered" || ok "R4 no ClusterRole/ClusterRoleBinding"

echo "== R5 Job and CronJob"
img_job=$(yq -N 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$WORK/render.yaml")
img_cron=$(yq -N 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].image' "$WORK/render.yaml")
[[ "$img_job" =~ ^docker\.io/alpine/k8s:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]] && [ "$img_job" = "$img_cron" ] &&
	ok "R5 image pinned as tag@digest in Job and CronJob ($img_job)" || bad "R5 image: job=$img_job cron=$img_cron"
# pod <field path>: "<Job value> <CronJob value>"
pod() {
	printf '%s %s' "$(yq -N "select(.kind == \"Job\") | .spec.template$1" "$WORK/render.yaml")" \
		"$(yq -N "select(.kind == \"CronJob\") | .spec.jobTemplate.spec.template$1" "$WORK/render.yaml")"
}
[ "$(pod '.spec.containers[0].imagePullPolicy')" = "IfNotPresent IfNotPresent" ] &&
	ok "R5 imagePullPolicy IfNotPresent" || bad "R5 imagePullPolicy: $(pod '.spec.containers[0].imagePullPolicy')"
[ "$(pod '.metadata.labels["sidecar.istio.io/inject"]')" = "false false" ] &&
	ok "R5 both pod templates opt out of Istio injection" || bad "R5 sidecar.istio.io/inject"
[ "$(pod '.spec.serviceAccountName')" = "platform-secrets platform-secrets" ] &&
	[ "$(pod '.spec.securityContext.runAsNonRoot')" = "true true" ] &&
	ok "R5 ServiceAccount platform-secrets, runAsNonRoot" || bad "R5 pod identity"
[ "$(yq -N 'select(.kind == "Job") | .metadata.annotations["argocd.argoproj.io/hook"] + " " + .metadata.annotations["argocd.argoproj.io/hook-delete-policy"] + " " + .metadata.annotations["argocd.argoproj.io/sync-wave"]' "$WORK/render.yaml")" = "Sync BeforeHookCreation -10" ] &&
	ok "R5 Job is a Sync hook, BeforeHookCreation, wave -10" || bad "R5 Job hook annotations"
[ "$(yq -N 'select(.kind == "CronJob") | .spec.schedule + " " + .spec.concurrencyPolicy' "$WORK/render.yaml")" = "*/10 * * * * Forbid" ] &&
	ok "R5 CronJob every 10 minutes, concurrencyPolicy Forbid" || bad "R5 CronJob schedule"

echo "== R6 app-of-apps Application"
helm template app-of-apps "$REPO/charts/app-of-apps" >"$WORK/aoa.yaml"
yq -N 'select(.kind == "Application" and .metadata.name == "platform-secrets")' "$WORK/aoa.yaml" >"$WORK/app.yaml"
app=$(yq -N -o=json -I=0 '[.spec.source.path, .spec.source.repoURL, .spec.source.targetRevision, .spec.project, .spec.destination.namespace,
	 .spec.destination.server, .metadata.annotations["argocd.argoproj.io/sync-wave"],
	 .spec.syncPolicy.automated.prune, .spec.syncPolicy.automated.selfHeal, .spec.syncPolicy.automated.enabled]' "$WORK/app.yaml")
want_app='["charts/platform-secrets","https://github.com/teknoir/platform-applications-gitops","teknoir-cloud","teknoir-cloud","teknoir-system","https://kubernetes.default.svc","-10",true,true,true]'
[ "$app" = "$want_app" ] && ok "R6 Application platform-secrets: path, revision, project, destination, wave -10, automated" ||
	bad "R6 Application platform-secrets: ${app:-<missing>}"
[ -s "$WORK/app.yaml" ] && [ "$(yq -N '.metadata.finalizers // [] | length' "$WORK/app.yaml")" = 0 ] &&
	ok "R6 no resources finalizer (like the other Applications)" || bad "R6 finalizer"
[ "$(yq -N 'select(.kind == "Application") | .metadata.name' "$WORK/aoa.yaml" | grep -c .)" = 11 ] &&
	ok "R6 11 Applications (10 existing + platform-secrets)" || bad "R6 Application count"
kubeconform -strict -summary -ignore-missing-schemas "$WORK/aoa.yaml" >/dev/null && ok "R6 app-of-apps render parses" || bad "R6 app-of-apps render"

echo "== R7 digest is the linux/amd64 manifest (online)"
if command -v crane >/dev/null 2>&1 && [ -z "${OFFLINE:-}" ]; then
	ref=${img_job%@*}
	if d=$(crane digest --platform linux/amd64 "$ref" 2>/dev/null); then
		[ "$d" = "${img_job#*@}" ] && ok "R7 pinned digest = crane digest --platform linux/amd64 $ref" ||
			bad "R7 pinned ${img_job#*@}, linux/amd64 manifest is $d"
	else
		skip "R7 registry not reachable"
	fi
else
	skip "R7 crane missing or OFFLINE set"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
