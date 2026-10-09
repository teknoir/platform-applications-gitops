#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# SC2016: the single-quoted strings are yq programs.
# shellcheck disable=SC2015,SC2016
# RBAC test of backstage-api's ServiceAccount (not packaged: .helmignore tests/).
#
#   charts/backstage/tests/rbac-test.sh [--static] [--keep]
#
# --static runs only the render checks (no cluster). Otherwise a throw-away
# k3d cluster (k3d-bsrbac, its own kubeconfig: the default kubeconfig and
# current context are never touched) gets the real teknoir.org CRDs and the
# chart's ServiceAccount and RBAC, and the ServiceAccount is checked with
# `kubectl auth can-i` and real calls (`kubectl --as`). Checks:
#   S1 no binding to teknoir-admin, cluster-admin, admin or edit; no '*' in
#      any rule's apiGroups, resources or verbs
#   S2 no rule grants pods create, pods/exec|attach|portforward|proxy,
#      Secrets without resourceNames, Secret list/watch, RBAC objects,
#      impersonate, serviceaccounts/token, networkpolicies, namespaces or nodes
#   S3 app-config kubernetes.objectTypes == the object types the plugin
#      ClusterRole grants (pods adds metrics.k8s.io pods); configmaps is not
#      among them
#   S4 externalAccess carries accessRestrictions plugin catalog, permission
#      catalog.entity.read; an empty list fails the render
#   S5 rbac.kubernetesPlugin.enabled=false renders no plugin role or binding
#   S6 an unknown object type fails the render
#   S7 kubeconform -strict on the RBAC and admission objects (when installed)
#   S8 the ValidatingAdmissionPolicy: Fail, matched on the ServiceAccount only,
#      a Deny binding, and its resourceRules cover every namespaced resource
#      the RBAC lets the ServiceAccount create, update, patch or delete;
#      rbac.admissionPolicy.enabled=false renders neither object
#   S9 release gate: when values.yaml pins the WP-BS Backstage build
#      (PIN(WP-BS)), its comment names SEC-C11, i.e. the image is built from
#      r5-backstage with r5-backstage-perm merged (the permission policy and
#      sign-in fixes this chart's RBAC assumes)
#   K0 control: the former binding (ClusterRole teknoir-admin from the
#      user-controller chart) grants get secrets in kube-system and create
#      pods/exec, so the matrix below would catch a regression
#   K1 can-i YES: every call of the audit (README "RBAC")
#   K2 can-i NO: other Secrets, Secret list, pods and exec, workloads,
#      NetworkPolicies, RBAC, impersonation, tokens, namespaces, nodes,
#      other ConfigMaps, Claims outside teknoir-system, '*'
#   K3 real calls as the SA (impersonation, and the SA's own token for the
#      raw users/status PATCH): list every CRD it reads, get the two named
#      teamspace Secrets (value never printed), server-side dry-run creates
#      and patches; Forbidden for Secret list, another Secret, a Pod
#   K4 the admission policy (RBAC alone allows all of these): a control
#      before it, then server-side dry-runs as the SA. Allowed in a teamspace
#      (label app.kubernetes.io/part-of=teknoir-profile, owner annotation):
#      ConfigMap peripheral-config, PVC create/delete, Device create/patch/
#      delete. Denied: any ConfigMap in kube-system (coredns-custom included),
#      another ConfigMap name in a teamspace, and every write in a namespace
#      without the label, without the owner annotation, with a reserved name,
#      a kube- prefix or a -vdev suffix, even when labelled. Other users are
#      not affected.
# Environment: K3S_IMAGE (default rancher/k3s:v1.33.5-k3s1, as live),
# KUBE_VERSION (render, default 1.33.5), HELM (default helm).
# Requires helm, yq (mikefarah v4); for the cluster part k3d, kubectl, curl,
# docker.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
CHARTS=$(cd "$CHART/.." && pwd)
CLUSTER=bsrbac
CTX=k3d-$CLUSTER
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
HELM=${HELM:-helm}
NS=teknoir-system
TS=ts-demo
SA=system:serviceaccount:$NS:backstage-api
STATIC=0
KEEP=0
for a in "$@"; do
	case $a in
	--static) STATIC=1 ;;
	--keep) KEEP=1 ;;
	*)
		echo "usage: $0 [--static] [--keep]" >&2
		exit 2
		;;
	esac
done

pass=0
fail=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
WORK=$(mktemp -d)
CLUSTER_UP=0
cleanup() {
	if [ "$CLUSTER_UP" -eq 1 ] && [ "$KEEP" -eq 0 ]; then
		k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
	fi
	if [ "$KEEP" -eq 1 ] && [ "$CLUSTER_UP" -eq 1 ]; then
		echo "kept: KUBECONFIG=$WORK/kubeconfig kubectl --context $CTX ..."
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

render() { "$HELM" template backstage "$CHART" --namespace "$NS" --kube-version "$KUBE_VERSION" "$@"; }
rbac_docs() { yq 'select(.kind == "ClusterRole" or .kind == "Role" or .kind == "ClusterRoleBinding" or .kind == "RoleBinding")' "$1"; }
appconfig() { yq -r 'select(.kind == "ConfigMap" and .metadata.name == "backstage-app-config") | .data["app-config.prod-env.yaml"]' "$1"; }

echo "== static"
render >"$WORK/chart.yaml"
rbac_docs "$WORK/chart.yaml" >"$WORK/rbac.yaml"
appconfig "$WORK/chart.yaml" >"$WORK/appconfig.yaml"

bindings=$(yq -r 'select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding") | .roleRef.name' "$WORK/rbac.yaml" | grep -v '^---$' | sort | tr '\n' ' ')
case " $bindings " in
*" teknoir-admin "* | *" cluster-admin "* | *" admin "* | *" edit "*) bad "S1 a binding references a broad role: $bindings" ;;
*) ok "S1 bindings only to the chart's own roles: $bindings" ;;
esac
stars=$(yq -r 'select(.rules) | .rules[] | ((.apiGroups // []) + (.resources // []) + (.verbs // []))[]' "$WORK/rbac.yaml" | grep -c '^\*$' || true)
[ "$stars" -eq 0 ] && ok "S1 no '*' in any rule" || bad "S1 $stars wildcard(s) in rules"

# rules_for <group> <resource>: verbs of every rule granting exactly that
# (S1 already rejects "*"; yq == would treat it as a glob anyway)
# group and resource, one rule per line; "named:" prefix when the rule has
# resourceNames.
rules_for() {
	G=$1 R=$2 yq -r 'select(.rules) | .rules[] | select((.apiGroups // []) | any_c(. == strenv(G))) | select((.resources // []) | any_c(. == strenv(R))) | (if (.resourceNames // [] | length) > 0 then "named:" else "" end) + (.verbs | join(","))' "$WORK/rbac.yaml" |
		{ grep -v '^---$' || true; }
}
forbidden=""
# <group> <resource> <verb, or * for any verb>
while read -r g r v; do
	[ "$g" = core ] && g=""
	got=$(rules_for "$g" "$r")
	[ -n "$got" ] || continue
	if [ "$v" = '*' ] || grep -qE "(^|,|:)($v|\*)(,|$)" <<<"$got"; then forbidden="$forbidden ${g:-core}/$r:$v"; fi
done <<'EOF2'
core pods create
core pods/exec *
core pods/attach *
core pods/portforward *
core pods/proxy *
core pods/ephemeralcontainers *
core serviceaccounts/token *
core serviceaccounts impersonate
core users impersonate
core groups impersonate
core namespaces *
core nodes *
core nodes/proxy *
core services/proxy *
rbac.authorization.k8s.io roles *
rbac.authorization.k8s.io rolebindings *
rbac.authorization.k8s.io clusterroles *
rbac.authorization.k8s.io clusterrolebindings *
networking.k8s.io networkpolicies *
apps deployments create
apps daemonsets create
batch jobs create
admissionregistration.k8s.io validatingwebhookconfigurations *
admissionregistration.k8s.io mutatingwebhookconfigurations *
apiextensions.k8s.io customresourcedefinitions *
EOF2
secret_rules=$(rules_for "" secrets)
if [ -n "$secret_rules" ] && grep -qv '^named:' <<<"$secret_rules"; then forbidden="$forbidden secrets-without-resourceNames"; fi
if grep -qE 'list|watch|\*' <<<"$secret_rules"; then forbidden="$forbidden secrets-list/watch"; fi
[ -z "$forbidden" ] && ok "S2 no dangerous grant (pods create/exec/attach/portforward, unnamed or listed Secrets, RBAC, impersonate, tokens, NetworkPolicies, namespaces, nodes, workloads, webhooks, CRDs)" ||
	bad "S2 dangerous grants:$forbidden"

plugin_types=$(yq -r '.kubernetes.objectTypes[]' "$WORK/appconfig.yaml" | sort | tr '\n' ' ')
role_types=$(yq -r 'select(.kind == "ClusterRole" and .metadata.name == "backstage-api-kubernetes-plugin") | .rules[] | select(.apiGroups[0] != "metrics.k8s.io") | .resources[]' "$WORK/rbac.yaml" | sort | tr '\n' ' ')
metrics=$(yq -r 'select(.kind == "ClusterRole" and .metadata.name == "backstage-api-kubernetes-plugin") | .rules[] | select(.apiGroups[0] == "metrics.k8s.io") | .resources[]' "$WORK/rbac.yaml")
[ -n "$plugin_types" ] && [ "$plugin_types" = "$role_types" ] && [ "$metrics" = pods ] &&
	ok "S3 kubernetes.objectTypes == plugin role resources ($plugin_types) + metrics pods" || bad "S3 objectTypes '$plugin_types' vs role '$role_types' metrics '$metrics'"
case " $plugin_types " in *" configmaps "*) bad "S3 configmaps among the plugin's object types" ;; *) ok "S3 configmaps not read by the plugin" ;; esac

restr=$(yq -o=json -I=0 '.backend.auth.externalAccess[0].accessRestrictions | sort_keys(..)' "$WORK/appconfig.yaml")
[ "$restr" = '[{"permission":"catalog.entity.read","plugin":"catalog"}]' ] &&
	ok "S4 externalAccess restricted to catalog / catalog.entity.read" || bad "S4 externalAccess restrictions: $restr"
if render --set 'externalAccess.accessRestrictions=null' >"$WORK/empty.yaml" 2>"$WORK/empty.err"; then
	bad "S4 an empty externalAccess.accessRestrictions rendered"
else
	grep -q 'externalAccess.accessRestrictions must not be empty' "$WORK/empty.err" && ok "S4 empty accessRestrictions fails the render" || bad "S4 wrong error: $(cat "$WORK/empty.err")"
fi

render --set rbac.kubernetesPlugin.enabled=false >"$WORK/noplugin.yaml"
[ -z "$(yq -r 'select(.metadata.name == "backstage-api-kubernetes-plugin") | .kind' "$WORK/noplugin.yaml" | grep -v '^---$' || true)" ] &&
	[ -n "$(yq -r 'select(.metadata.name == "backstage-api-resources-role") | .kind' "$WORK/noplugin.yaml")" ] &&
	ok "S5 kubernetesPlugin.enabled=false: no plugin role/binding, resources role kept" || bad "S5 plugin toggle"

if render --set 'rbac.kubernetesPlugin.objectTypes={pods,secrets}' >/dev/null 2>"$WORK/unknown.err"; then
	bad "S6 unknown object type 'secrets' rendered"
else
	grep -q 'unknown object type "secrets"' "$WORK/unknown.err" && ok "S6 unknown object type fails the render" || bad "S6 wrong error: $(cat "$WORK/unknown.err")"
fi

vap() { yq "select(.kind == \"$1\" and .metadata.name == \"backstage-api-teamspace-writes\")" "$WORK/chart.yaml"; }
vap ValidatingAdmissionPolicy >"$WORK/vap.yaml"
vap ValidatingAdmissionPolicyBinding >"$WORK/vapb.yaml"
[ "$(yq -r '.spec.failurePolicy' "$WORK/vap.yaml")" = Fail ] &&
	[ "$(yq -r '.spec.matchConditions[0].expression' "$WORK/vap.yaml")" = "request.userInfo.username == \"$SA\"" ] &&
	[ "$(yq -r '.spec.policyName + " " + (.spec.validationActions | join(","))' "$WORK/vapb.yaml")" = "backstage-api-teamspace-writes Deny" ] &&
	ok "S8 admission policy: failurePolicy Fail, matched on $SA only, binding Deny" || bad "S8 admission policy shape: $(cat "$WORK/vap.yaml" "$WORK/vapb.yaml")"
# Every namespaced resource the RBAC lets the SA write must be matched by the
# policy (users and profiles are cluster-scoped: no namespace to bound).
writes=$(yq -r 'select(.kind == "ClusterRole" or .kind == "Role") | .rules[] | select(.verbs | any_c(. == "create" or . == "update" or . == "patch" or . == "delete" or . == "deletecollection")) | .apiGroups[] as $g | .resources[] | ($g | sub("^$"; "core")) + "/" + .' "$WORK/rbac.yaml" |
	grep -v -E '^---$|^teknoir.org/(users|users/status|profiles)$' | sort -u | tr '\n' ' ')
matched=$(yq -r '.spec.matchConstraints.resourceRules[] | select((.operations | any_c(. == "CREATE")) and (.operations | any_c(. == "UPDATE")) and (.operations | any_c(. == "DELETE"))) | .apiGroups[] as $g | .resources[] | ($g | sub("^$"; "core")) + "/" + .' "$WORK/vap.yaml" | sort -u | tr '\n' ' ')
missing=""
for w in $writes; do case " $matched " in *" $w "*) ;; *) missing="$missing $w" ;; esac; done
[ -n "$writes" ] && [ -z "$missing" ] && ok "S8 the policy covers every namespaced write of the RBAC: $writes" || bad "S8 namespaced writes not bounded by the policy:$missing (writes: $writes; policy: $matched)"
render --set rbac.admissionPolicy.enabled=false >"$WORK/novap.yaml"
[ -z "$(yq -r 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding") | .kind' "$WORK/novap.yaml" | grep -v '^---$' || true)" ] &&
	ok "S8 rbac.admissionPolicy.enabled=false renders no policy or binding" || bad "S8 admissionPolicy toggle"

# S9: the r5 integration branch pins the Backstage images built for WP-BS
# (values.yaml "PIN(WP-BS)"). This chart's RBAC and API guard assume an image
# with r5-backstage-perm (SEC-C11: kubernetes.* for platform admins only,
# sign-in only as a provider-managed User, no User/Group from locations).
if grep -q 'PIN(WP-BS)' "$CHART/values.yaml"; then
	sed -n '/PIN(WP-BS)/,/^$/p' "$CHART/values.yaml" | grep -q 'SEC-C11' &&
		ok "S9 the PIN(WP-BS) comment names SEC-C11 (image built with r5-backstage-perm)" ||
		bad "S9 release gate: values.yaml pins the WP-BS build, but its PIN(WP-BS) comment does not name SEC-C11. Merge backstage r5-backstage-perm into r5-backstage before the WP-BS image build, then add 'SEC-C11 Kubernetes plugin for platform admins only, provider-managed sign-in' next to SIGN-C4/TS-C7"
else
	echo "SKIP S9 no PIN(WP-BS) in values.yaml (the image pins come with the r5 integration branch)"
fi

if command -v kubeconform >/dev/null; then
	{
		printf '\n---\n'
		cat "$WORK/vap.yaml"
		printf '\n---\n'
		cat "$WORK/vapb.yaml"
	} >>"$WORK/rbac.yaml"
	kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" "$WORK/rbac.yaml" >"$WORK/kc.log" 2>&1 &&
		ok "S7 kubeconform -strict: $(tail -1 "$WORK/kc.log")" || bad "S7 kubeconform: $(cat "$WORK/kc.log")"
else
	echo "SKIP S7 kubeconform not installed"
fi

if [ "$STATIC" -eq 1 ]; then
	echo "== $pass passed, $fail failed (static only)"
	[ "$fail" -eq 0 ]
	exit
fi

echo "== cluster ($K3S_IMAGE)"
export KUBECONFIG=$WORK/kubeconfig
k() { kubectl --context "$CTX" "$@"; }
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait \
	--kubeconfig-update-default=false --kubeconfig-switch-context=false \
	--k3s-arg '--disable=traefik,metrics-server,servicelb@server:0' >/dev/null
CLUSTER_UP=1
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
for f in "$CHARTS"/device-controller/crds/*.yaml "$CHARTS"/user-controller/crds/crds.yaml \
	"$CHARTS"/devstudio-controller/crds/*.yaml "$CHARTS"/notebook-controller/crds/*.yaml \
	"$CHARTS"/profile-controller/crds/crd.yaml "$CHARTS"/istio/crds/virtualservices.networking.istio.io.yaml; do
	k apply --server-side -f "$f" >/dev/null
done
k wait --for=condition=Established crd --all --timeout=60s >/dev/null
for n in "$NS" "$TS" teknoir-auth teknoir-user-credentials ts-two ts-unlabelled ts-noowner kube-test "$TS-vdev"; do k create namespace "$n" >/dev/null; done
# Teamspaces as profile-controller creates them (label and owner annotation);
# ts-noowner lacks the annotation; teknoir-system (reserved), kube-test
# (kube- prefix) and $TS-vdev (a virtual-device runtime namespace) are marked
# like teamspaces but must not count as one.
for n in "$TS" ts-two ts-noowner "$NS" kube-test "$TS-vdev"; do k label namespace "$n" app.kubernetes.io/part-of=teknoir-profile >/dev/null; done
for n in "$TS" ts-two "$NS" kube-test "$TS-vdev"; do k annotate namespace "$n" owner=rbac-test@example.com >/dev/null; done
# Fixtures (dummy values; the harness never prints a Secret value).
for s in mongodb-credentials emqx-bootstrap-user other-teamspace-secret; do
	k -n "$TS" create secret generic "$s" --from-literal=username=dummy --from-literal=password=dummy-not-a-secret >/dev/null
done
k -n teknoir-auth create secret generic oauth2-proxy-secret --from-literal=client-secret=dummy >/dev/null
k -n teknoir-user-credentials create secret generic user-initial-password-x --from-literal=password=dummy >/dev/null
k -n "$TS" create configmap peripheral-config --from-literal=peripherals.json='{}' >/dev/null
k -n "$TS" create configmap other-config --from-literal=a=b >/dev/null
k -n ts-unlabelled create configmap peripheral-config --from-literal=peripherals.json='{}' >/dev/null
for n in "$TS" ts-unlabelled; do
	k -n "$n" create -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fixture}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
EOF
done
k apply -f - >/dev/null <<EOF
apiVersion: teknoir.org/v1
kind: User
metadata: {name: rbac-test-at-example.com}
spec: {email: rbac-test@example.com}
---
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: $TS}
spec: {}
---
apiVersion: teknoir.org/v1
kind: Device
metadata: {name: dev1, namespace: $TS}
spec: {keys: {}, manifest: {}}
---
apiVersion: teknoir.org/v1
kind: Device
metadata: {name: dev1, namespace: ts-unlabelled}
spec: {keys: {}, manifest: {}}
EOF

echo "== K0 control: the former teknoir-admin binding"
"$HELM" template uc "$CHARTS/user-controller" --namespace "$NS" -s templates/clusterroles.yaml >"$WORK/teknoir-admin.yaml"
k apply -f "$WORK/teknoir-admin.yaml" >/dev/null
k create serviceaccount backstage-api -n "$NS" >/dev/null
k create clusterrolebinding backstage-api-teknoir-admin-rolebinding --clusterrole=teknoir-admin --serviceaccount="$NS:backstage-api" >/dev/null
sleep 2 # aggregation controller fills teknoir-admin
[ "$(k auth can-i get secrets -n kube-system --as="$SA" 2>/dev/null || true)" = yes ] &&
	[ "$(k auth can-i create pods --subresource=exec -n kube-system --as="$SA" 2>/dev/null || true)" = yes ] &&
	ok "K0 former binding: get secrets and create pods/exec in kube-system (what this chart removes)" ||
	bad "K0 control did not reproduce the former access"
k delete clusterrolebinding backstage-api-teknoir-admin-rolebinding >/dev/null
k delete serviceaccount backstage-api -n "$NS" >/dev/null

echo "== chart ServiceAccount and RBAC"
render -s templates/serviceaccount.yaml -s templates/rbac.yaml >"$WORK/apply.yaml"
k apply --server-side --field-manager=argocd-controller -f "$WORK/apply.yaml" >/dev/null

# can <yes|no> <namespace|-|*> <can-i args...>
can() {
	local want=$1 ns=$2 got
	shift 2
	local nsarg=()
	case $ns in -) ;; '*') nsarg=(-A) ;; *) nsarg=(-n "$ns") ;; esac
	got=$(k auth can-i "$@" "${nsarg[@]}" --as="$SA" 2>/dev/null || true)
	[ "$got" = "$want" ] && ok "K can-i $want: $* [$ns]" || bad "K can-i $*  [$ns]: want $want, got '${got}'"
}
matrix() {
	local want ns verb res extra
	while read -r want ns verb res extra; do
		[ -z "$want" ] || [ "${want#\#}" != "$want" ] && continue
		# shellcheck disable=SC2086 # extra is word-split on purpose
		can "$want" "$ns" "$verb" "$res" $extra
	done
}

echo "== K1 can-i YES (the audit)"
matrix <<EOF
# catalog providers and the teknoir-entity / teamspace / email backends
yes - list users.teknoir.org
yes - get users.teknoir.org
yes - create users.teknoir.org
yes - patch users.teknoir.org
yes - delete users.teknoir.org
yes - patch users.teknoir.org --subresource=status
yes - list profiles.teknoir.org
yes - get profiles.teknoir.org
yes - create profiles.teknoir.org
yes - patch profiles.teknoir.org
yes - delete profiles.teknoir.org
yes - get profiles.teknoir.org --subresource=status
yes * list devices.teknoir.org
yes * list deviceapplicationsets.teknoir.org
yes $TS get deviceapplicationsets.teknoir.org
yes $TS get devices.teknoir.org
yes $TS create devices.teknoir.org
yes $TS patch devices.teknoir.org
yes $TS delete devices.teknoir.org
yes $TS list devstudios.teknoir.org
yes $TS create devstudios.teknoir.org
yes $TS patch notebooks.teknoir.org
yes $TS delete notebooks.teknoir.org
yes $TS list claimsets.teknoir.org
yes $NS list claimsets.teknoir.org
yes $TS create claimsets.teknoir.org
yes $NS list claims.teknoir.org
yes $TS list virtualservices.networking.istio.io
yes $TS list persistentvolumeclaims
yes $TS get persistentvolumeclaims
yes $TS create persistentvolumeclaims
yes $TS delete persistentvolumeclaims
yes $TS get secrets/mongodb-credentials
yes $TS get secrets/emqx-bootstrap-user
yes $TS get configmaps/peripheral-config
yes $TS update configmaps/peripheral-config
yes $TS create configmaps
# @backstage/plugin-kubernetes-backend (read-only)
yes * list pods
yes * list services
yes * list limitranges
yes * list resourcequotas
yes * list deployments.apps
yes * list replicasets.apps
yes * list statefulsets.apps
yes * list daemonsets.apps
yes * list horizontalpodautoscalers.autoscaling
yes * list jobs.batch
yes * list cronjobs.batch
yes * list ingresses.networking.k8s.io
EOF

# sar <yes|no> <verb> <group> <resource>: a SubjectAccessReview with an
# explicit group, for APIs this cluster does not serve (metrics-server is
# off, so kubectl cannot resolve pods.metrics.k8s.io).
sar() {
	local got
	got=$(k create -o jsonpath='{.status.allowed}' -f - <<EOS
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: $SA
  groups: [system:serviceaccounts, "system:serviceaccounts:$NS", system:authenticated]
  resourceAttributes: {verb: $2, group: $3, resource: $4}
EOS
	)
	[ "$got" = true ] && got=yes || got=no
	[ "$got" = "$1" ] && ok "K SAR $1: $2 $4.$3 (all namespaces)" || bad "K SAR $2 $4.$3: want $1, got $got"
}
sar yes list metrics.k8s.io pods
sar no list metrics.k8s.io nodes

echo "== K2 can-i NO"
matrix <<EOF
no $TS get secrets
no * list secrets
no $TS watch secrets
no $TS get secrets/other-teamspace-secret
no kube-system get secrets/k3s-serving
no teknoir-auth get secrets/oauth2-proxy-secret
no teknoir-user-credentials get secrets/user-initial-password-x
no $NS get secrets/backstage-k8s-sa-token
no $TS update secrets/mongodb-credentials
no $TS create secrets
no $TS create pods
no $TS delete pods
no $TS create pods --subresource=exec
no $TS get pods --subresource=exec
no $TS create pods --subresource=attach
no $TS create pods --subresource=portforward
no $TS get pods --subresource=log
no $TS create deployments.apps
no $TS patch deployments.apps
no $TS create networkpolicies.networking.k8s.io
no $TS patch networkpolicies.networking.k8s.io
no $TS delete networkpolicies.networking.k8s.io
no $TS create rolebindings.rbac.authorization.k8s.io
no - create clusterrolebindings.rbac.authorization.k8s.io
no - bind clusterroles.rbac.authorization.k8s.io
no - escalate clusterroles.rbac.authorization.k8s.io
no $TS impersonate serviceaccounts
no - impersonate users
no $NS create serviceaccounts --subresource=token
no - create namespaces
no - patch namespaces
no - delete namespaces
no - get nodes
no - get nodes --subresource=proxy
no * list configmaps
no $TS get configmaps/other-config
no kube-system update configmaps/coredns
no $TS delete configmaps/peripheral-config
no $TS list claims.teknoir.org
no $NS create claims.teknoir.org
no $TS deletecollection devices.teknoir.org
no - update users.teknoir.org
no kube-system create helmcharts.helm.cattle.io
no $TS create virtualservices.networking.istio.io
no $TS update persistentvolumeclaims
no * * *
EOF

echo "== K3 real calls as $SA"
as() { k --as="$SA" "$@"; }
for r in users.teknoir.org profiles.teknoir.org; do
	as get "$r" -o name >/dev/null 2>"$WORK/err" && ok "K3 get $r" || bad "K3 get $r: $(cat "$WORK/err")"
done
for r in devices.teknoir.org deviceapplicationsets.teknoir.org; do
	as get "$r" -A -o name >/dev/null 2>"$WORK/err" && ok "K3 get $r -A" || bad "K3 get $r -A: $(cat "$WORK/err")"
done
for r in devstudios.teknoir.org notebooks.teknoir.org claimsets.teknoir.org virtualservices.networking.istio.io persistentvolumeclaims; do
	as -n "$TS" get "$r" -o name >/dev/null 2>"$WORK/err" && ok "K3 get $r -n $TS" || bad "K3 get $r: $(cat "$WORK/err")"
done
as -n "$NS" get claims.teknoir.org -o name >/dev/null 2>"$WORK/err" && ok "K3 get claims -n $NS" || bad "K3 claims: $(cat "$WORK/err")"
for s in mongodb-credentials emqx-bootstrap-user; do
	[ "$(as -n "$TS" get secret "$s" -o jsonpath='{.metadata.name}' 2>"$WORK/err")" = "$s" ] && ok "K3 get secret $s (value not read)" || bad "K3 secret $s: $(cat "$WORK/err")"
done
as -n "$TS" create --dry-run=server -f - >/dev/null 2>"$WORK/err" <<EOF && ok "K3 dry-run create Device" || bad "K3 create Device: $(cat "$WORK/err")"
apiVersion: teknoir.org/v1
kind: Device
metadata: {name: dev2, namespace: $TS}
spec: {keys: {}, manifest: {}}
EOF
as patch users.teknoir.org rbac-test-at-example.com --type=merge -p '{"spec":{"display_name":"RBAC test"}}' --dry-run=server >/dev/null 2>"$WORK/err" &&
	ok "K3 dry-run merge patch User" || bad "K3 patch User: $(cat "$WORK/err")"
# The email-verification backend PATCHes users/status directly
# (patchClusterCustomObjectStatus, no GET first), unlike `kubectl patch
# --subresource=status`. Same request here, with the ServiceAccount's own
# token (kept in a variable, never printed).
server=$(k config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
k config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"$WORK/ca.crt"
token=$(k -n "$NS" create token backstage-api --duration=10m)
code=$(curl -sS -o "$WORK/patch.json" -w '%{http_code}' --cacert "$WORK/ca.crt" -X PATCH \
	-H "Authorization: Bearer $token" -H 'Content-Type: application/merge-patch+json' \
	--data '{"status":{}}' "$server/apis/teknoir.org/v1/users/rbac-test-at-example.com/status?dryRun=All")
[ "$code" = 200 ] && ok "K3 dry-run PATCH users/status with the SA token" || bad "K3 PATCH users/status: HTTP $code $(head -c 300 "$WORK/patch.json")"
code=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$WORK/ca.crt" -H "Authorization: Bearer $token" "$server/api/v1/namespaces/kube-system/secrets")
[ "$code" = 403 ] && ok "K3 SA token: list kube-system Secrets is 403" || bad "K3 SA token list kube-system Secrets: HTTP $code"
unset token
as -n "$TS" create configmap new-peripheral-config --from-literal=a=b --dry-run=server >/dev/null 2>"$WORK/err" &&
	ok "K3 dry-run create ConfigMap" || bad "K3 create ConfigMap: $(cat "$WORK/err")"
as -n "$TS" create -f - --dry-run=server >/dev/null 2>"$WORK/err" <<EOF && ok "K3 dry-run create PVC" || bad "K3 create PVC: $(cat "$WORK/err")"
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: vol1, namespace: $TS}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}
EOF
# forbidden <description> <kubectl args...>: the call must fail with Forbidden.
forbidden() {
	local d=$1
	shift
	if as "$@" >/dev/null 2>"$WORK/err"; then
		bad "K3 $d succeeded"
	else
		grep -q -i forbidden "$WORK/err" && ok "K3 $d: Forbidden" || bad "K3 $d failed without Forbidden: $(cat "$WORK/err")"
	fi
}
forbidden "list Secrets in $TS" -n "$TS" get secrets -o name
forbidden "get another teamspace Secret" -n "$TS" get secret other-teamspace-secret -o name
forbidden "get a kube-system Secret" -n kube-system get secret k3s-serving -o name
forbidden "list Secrets cluster-wide" get secrets -A -o name
forbidden "create a Pod" -n "$TS" run rbac-test --image=busybox --restart=Never --dry-run=server
forbidden "list ConfigMaps" -n "$TS" get configmaps -o name
forbidden "create a RoleBinding" -n "$TS" create rolebinding x --clusterrole=view --serviceaccount="$NS:backstage-api" --dry-run=server

echo "== K4 admission policy"
# admit <allow|deny> <description> <kubectl args...>: a server-side dry-run as
# the SA; deny means refused by this chart's policy, not by RBAC.
admit() {
	local want=$1 d=$2
	shift 2
	if as "$@" --dry-run=server >/dev/null 2>"$WORK/err"; then
		[ "$want" = allow ] && ok "K4 allowed: $d" || bad "K4 $d was allowed"
	elif [ "$want" = deny ] && grep -q "ValidatingAdmissionPolicy 'backstage-api-teamspace-writes'" "$WORK/err"; then
		ok "K4 denied by the policy: $d"
	else
		bad "K4 $d: want $want, got: $(cat "$WORK/err")"
	fi
}
device() { printf 'apiVersion: teknoir.org/v1\nkind: Device\nmetadata: {name: %s, namespace: %s}\nspec: {keys: {}, manifest: {}}\n' "$1" "$2"; }
pvc() { printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata: {name: %s, namespace: %s}\nspec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}}\n' "$1" "$2"; }
as -n kube-system create configmap coredns-custom --from-literal=x.override='rewrite name x y' --dry-run=server >/dev/null 2>"$WORK/err" &&
	ok "K4 control: RBAC alone lets the SA create kube-system/coredns-custom (a CoreDNS import on k3s)" || bad "K4 control failed: $(cat "$WORK/err")"
render -s templates/admission-policy.yaml | k apply -f - >/dev/null
for _ in $(seq 1 30); do
	as -n kube-system create configmap coredns-custom --from-literal=a=b --dry-run=server >/dev/null 2>&1 || break
	sleep 2
done
admit deny "ConfigMap kube-system/coredns-custom" -n kube-system create configmap coredns-custom --from-literal=x.override='rewrite name x y'
admit deny "ConfigMap kube-system/peripheral-config" -n kube-system create configmap peripheral-config --from-literal=a=b
admit allow "ConfigMap peripheral-config in a teamspace" -n ts-two create configmap peripheral-config --from-literal=a=b
admit deny "ConfigMap with another name in a teamspace" -n ts-two create configmap other --from-literal=a=b
for n in ts-unlabelled ts-noowner "$NS" kube-test "$TS-vdev"; do
	admit deny "ConfigMap peripheral-config in $n" -n "$n" create configmap peripheral-config --from-literal=a=b
done
as -n "$TS" get configmap peripheral-config -o json | jq '.data.x = "y"' >"$WORK/pc-ts.json"
as -n ts-unlabelled get configmap peripheral-config -o json | jq '.data.x = "y"' >"$WORK/pc-unl.json"
admit allow "update peripheral-config in a teamspace" replace -f "$WORK/pc-ts.json"
admit deny "update peripheral-config outside a teamspace" replace -f "$WORK/pc-unl.json"
pvc vol2 ts-two >"$WORK/pvc-ok.yaml"
admit allow "create a PVC in a teamspace" create -f "$WORK/pvc-ok.yaml"
admit allow "delete a PVC in a teamspace" -n "$TS" delete pvc fixture
for n in kube-system ts-unlabelled "$NS" "$TS-vdev"; do
	pvc vol2 "$n" >"$WORK/pvc-$n.yaml"
	admit deny "create a PVC in $n" create -f "$WORK/pvc-$n.yaml"
done
admit deny "delete a PVC outside a teamspace" -n ts-unlabelled delete pvc fixture
device dev2 ts-two >"$WORK/dev-ok.yaml"
admit allow "create a Device in a teamspace" create -f "$WORK/dev-ok.yaml"
admit allow "patch a Device in a teamspace" -n "$TS" patch devices.teknoir.org dev1 --type=merge -p '{"metadata":{"labels":{"x":"y"}}}'
admit allow "delete a Device in a teamspace" -n "$TS" delete devices.teknoir.org dev1
for n in "$NS" ts-unlabelled "$TS-vdev"; do
	device dev2 "$n" >"$WORK/dev-$n.yaml"
	admit deny "create a Device in $n" create -f "$WORK/dev-$n.yaml"
done
admit deny "patch a Device outside a teamspace" -n ts-unlabelled patch devices.teknoir.org dev1 --type=merge -p '{"metadata":{"labels":{"x":"y"}}}'
admit deny "delete a Device outside a teamspace" -n ts-unlabelled delete devices.teknoir.org dev1
k -n kube-system create configmap coredns-custom --from-literal=a=b --dry-run=server >/dev/null 2>"$WORK/err" &&
	ok "K4 the policy does not affect other users (cluster-admin creates kube-system/coredns-custom)" || bad "K4 cluster-admin blocked: $(cat "$WORK/err")"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
