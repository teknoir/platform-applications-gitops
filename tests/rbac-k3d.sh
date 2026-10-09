#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# tests/rbac-k3d.sh — the user-controller and profile-controller under their
# least-privilege RBAC (SEC-C6, SEC-C7) and the GitOps teamspace (TS-C2), in
# a throw-away k3d cluster (k3s v1.33.5, as live).
#
#   tests/rbac-k3d.sh [--keep] [--legacy | --policies-only]
#
# Heavy (k3d, docker): run it under the shared lock where agents share the
# host. Needs docker credentials for ghcr.io/teknoir (private images).
#
# The charts are rendered as ArgoCD does (release = chart, namespace
# teknoir-system) and applied server-side, CRDs first, plus the istio and
# ArgoCD CRDs (from the render cache) and a fake Keycloak/EMQX
# (tests/rbac-k3d/fake-services.go, built here). No ArgoCD, no istiod.
#
# Checks:
#   R1  server-side dry-run of the Profile CRD and the chart's Profile
#       (also against k3d-teknoir-dev when that cluster is up)
#   R2  can-i matrix of the user-controller ServiceAccount
#   R3  can-i matrix of the profile-controller ServiceAccount
#   R4  real RoleBinding creates as each SA outside a teamspace: binding
#       cluster-admin or admin is refused by the RBAC escalation check;
#       binding teknoir-admin passes RBAC and is refused by the admission
#       policy (without the policies: created)
#   R5  both controllers start: lease acquired (user-controller), workers
#       started, no cache-sync timeout
#   R6  Profiles teknoir-default (from the chart) and rbac-test reconcile to
#       completion (finalizer), under the admission policies: namespace with
#       owner, part-of label and Profile ownerReference, 3 RoleBindings, 2
#       ServiceAccounts, 2 AuthorizationPolicies, RequestAuthentication,
#       ConfigMaps, copied TLS and pull Secrets, AppProject, exactly the 9
#       default plugin Applications
#   R7  r5 image: AppProject sourceRepos = [PLUGIN_CHART_REPO] and no
#       cluster whitelist; Applications on PLUGIN_CHART_REPO /
#       PLUGIN_CHART_VERSION with RespectIgnoreDifferences=true;
#       RequestAuthentication issuer/jwksUri = OIDC_ISSUER and OIDC_JWKS_URI
#       (unset: <issuer>/protocol/openid-connect/certs), a public https:// URL
#   R8  a User with claim_set owner@rbac-test: RoleBinding to teknoir-admin
#       and AuthorizationPolicy in rbac-test, Keycloak user created, one
#       temporary password set; r5 image: K1 Secret (labels, expiry,
#       ownerReference) and no status.set_initial_password
#   R9  claim_set removed: RoleBinding and AuthorizationPolicy revoked
#   R10 User deleted: finalizer runs, Keycloak user deleted; r5: K1 Secret gone
#   R11 Profile rbac-test deleted: the controller deletes its Applications
#       (ArgoCD's resources finalizer is then removed by the test, standing
#       in for ArgoCD), Profile, AppProject and namespace go
#   R12 no 'forbidden' and no cache-sync timeout in either controller log;
#       the temporary password appears in no log
#   R13 the admission policies (ValidatingAdmissionPolicy): all type-checked
#       without warnings; server-side dry runs as each SA, where every refusal
#       must come from a policy (so RBAC allowed it):
#       - profile-controller: the platform AppProjects (teknoir-local,
#         default) and Applications cannot be changed, deleted or taken over;
#         no AppProject that is widened, reserved, unowned or aimed outside
#         its teamspace; no Application in another project, namespace or
#         repository, or with several sources; no write outside a teamspace
#         (Secrets, ConfigMaps, RoleBindings, AuthorizationPolicies), no
#         Namespace without its Profile owner, none taken over or released;
#         RoleBindings only to teknoir-* for users or local ServiceAccounts;
#         the teamspace shapes it really writes are allowed
#       - user-controller: no RoleBinding (teknoir-admin to itself) in
#         teknoir-auth, teknoir-system or kube-system; no AuthorizationPolicy
#         in istio-system, no delete in teknoir-auth; the owner's RoleBinding
#         untouchable; only User-owned user-<User>-teknoir-* objects, users as
#         subjects, ALLOW policies; its real shapes are allowed
#       - a cluster admin is not affected
#   R14 the live break-glass of infra docs/airgap/OPERATE.md (r5, "Controller
#       RBAC and admission policies"), with its commands, on stand-ins of the
#       root app-of-apps (as infra's templates/app-of-apps.yaml.tmpl, applied
#       as teknoir-bootstrap) and the controller Applications (as
#       charts/app-of-apps renders them): a denial reads "is forbidden:
#       ValidatingAdmissionPolicy '<p>' with binding '<b>' denied request";
#       the JSON patch removes only spec.syncPolicy.automated; deleting one
#       binding lifts only that policy; the revert (the runbook's merge patch
#       or up's server-side apply of the root, then what ArgoCD's syncs apply)
#       restores the specs as rendered and the refusals. No ArgoCD runs here:
#       its self-heal is not tested, only what it would apply.
#
# Options / environment:
#   --keep      keep the cluster (context k3d-rbac-k3d) and the work dir
#   --legacy    the images predate r5 (WP-UC/WP-PC): checks of r5 behaviour
#               (R7, K1 parts of R8/R10) are SKIPped, not failed, and the
#               admission policies are left out (they refuse what the old
#               profile-controller writes); R13 and R14 are SKIPped
#   --policies-only  no controllers (no images needed): R1-R4, R13 and R14
#               against stand-ins of what the profile-controller creates for
#               teknoir-default (namespace, AppProject, owner RoleBinding)
#   UC_IMAGE, PC_IMAGE  images to run (default: the chart pins). A chart
#               still on the PLACEHOLDER pin needs these. 'repo:tag@sha256:D'
#               is verified (crane: the tag's linux/amd64 digest is D), pulled
#               by tag and imported; the pod runs repo:tag (pinning itself is
#               checked by the VM e2e imageID check). An unpinned reference is
#               used as is, from the local docker images if present (e.g. a
#               local build of an unpublished branch).
#   K3S_IMAGE   default rancher/k3s:v1.33.5-k3s1
#   RENDER_CACHE  chart cache of tests/render.sh (istio base, argo-cd CRDs)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLUSTER=rbac-k3d
CTX=k3d-$CLUSTER
K3S_IMAGE=${K3S_IMAGE:-rancher/k3s:v1.33.5-k3s1}
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
RENDER_CACHE=${RENDER_CACHE:-$HOME/.cache/teknoir-render}
ISTIO_BASE=${ISTIO_BASE:-https://istio-release.storage.googleapis.com/charts base 1.29.2}
ARGO_CD=${ARGO_CD:-https://argoproj.github.io/argo-helm argo-cd 10.4.0}
KEEP=0 LEGACY=0 ONLY_POLICIES=0
for a in "$@"; do
	case $a in
	--keep) KEEP=1 ;;
	--legacy) LEGACY=1 ;;
	--policies-only) ONLY_POLICIES=1 ;;
	-h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
	*) echo "unknown argument: $a" >&2; exit 2 ;;
	esac
done
[ "$LEGACY" -eq 1 ] && [ "$ONLY_POLICIES" -eq 1 ] && { echo "--legacy and --policies-only exclude each other" >&2; exit 2; }
tools="k3d kubectl helm docker yq jq"; [ "$ONLY_POLICIES" -eq 0 ] && tools="$tools go crane"
for t in $tools; do
	command -v "$t" >/dev/null || { echo "missing required tool: $t" >&2; exit 2; }
done

WORK=$(mktemp -d)
FAKE_IMAGE=rbac-k3d-fake:$$
pass=0 fail=0 skip=0
k() { kubectl --context "$CTX" "$@"; }
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
skp() { echo "SKIP $*"; skip=$((skip + 1)); }
r5() { [ "$LEGACY" -eq 0 ]; } # r5 behaviour expected?
policies() { [ "$LEGACY" -eq 0 ]; } # admission policies applied?
controllers() { [ "$ONLY_POLICIES" -eq 0 ]; } # controllers run?
cleanup() {
	if [ "$KEEP" -eq 0 ]; then
		k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
		rm -rf "$WORK"
	else
		echo "kept: cluster $CTX, work dir $WORK"
	fi
	docker rmi "$FAKE_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
# wait_for <seconds> <command...>: poll every 2 s
wait_for() {
	local t=$1; shift
	for _ in $(seq 1 $(((t + 1) / 2))); do
		"$@" >/dev/null 2>&1 && return 0
		sleep 2
	done
	return 1
}

UC_SA=system:serviceaccount:teknoir-system:user-controller
PROBE_TAG=R13 # the check id probe() prints
PC_SA=system:serviceaccount:teknoir-system:profile-controller
PLUGINS="deadend emqx fleet-metrics grafana historian jwks mongodb observatory prometheus"

# --- renders ---------------------------------------------------------------------
echo "== render"
for c in user-controller profile-controller; do
	helm template "$c" "$ROOT/charts/$c" --namespace teknoir-system --include-crds --kube-version "$KUBE_VERSION" >"$WORK/$c.yaml"
done
yq 'select(.kind == "CustomResourceDefinition")' "$WORK/user-controller.yaml" "$WORK/profile-controller.yaml" >"$WORK/crds.yaml"
yq 'select(.kind == "CustomResourceDefinition" and .spec.group == "teknoir.org" and .spec.names.kind == "Profile")' "$WORK/profile-controller.yaml" >"$WORK/profile-crd.yaml"
yq 'select(.kind == "Profile")' "$WORK/profile-controller.yaml" >"$WORK/profiles.yaml"
cmv() { yq -r "select(.kind == \"ConfigMap\" and .metadata.name == \"profile-controller-config\") | .data.$1 // \"\"" "$WORK/profile-controller.yaml"; }
REPO=$(cmv PLUGIN_CHART_REPO) VERSION=$(cmv PLUGIN_CHART_VERSION) ISSUER=$(cmv OIDC_ISSUER) JWKS=$(cmv OIDC_JWKS_URI)
[ -n "$REPO" ] && [ -n "$VERSION" ] && [ -n "$ISSUER" ] || { echo "the profile-controller render lacks PLUGIN_CHART_REPO/VERSION or OIDC_ISSUER" >&2; exit 1; }
# OIDC_JWKS_URI unset: the controller derives it from the issuer.
JWKS=${JWKS:-${ISSUER%/}/protocol/openid-connect/certs}
DEFAULT_OWNER=$(yq -r 'select(.kind == "Profile" and .metadata.name == "teknoir-default") | .spec.owner.name' "$WORK/profile-controller.yaml")
[ -n "$DEFAULT_OWNER" ] || { echo "the profile-controller render has no Profile teknoir-default" >&2; exit 1; }

# --- images ----------------------------------------------------------------------
if controllers; then
chart_image() { yq -r 'select(.kind == "Deployment") | .spec.template.spec.containers[0].image' "$WORK/$1.yaml"; }
UC_REF=${UC_IMAGE:-$(chart_image user-controller)}
PC_REF=${PC_IMAGE:-$(chart_image profile-controller)}
for r in "$UC_REF" "$PC_REF"; do
	case $r in *PLACEHOLDER*)
		echo "the chart still pins a placeholder ($r): set UC_IMAGE/PC_IMAGE (add --legacy for images built before r5)" >&2
		exit 2 ;;
	esac
done
# run_ref <ref>: the reference the pod runs; verifies tag@digest pins
run_ref() {
	local ref=$1 tagref digest have
	case $ref in
	*@sha256:*)
		tagref=${ref%@*} digest=${ref##*@}
		have=$(crane digest --platform linux/amd64 "$tagref")
		[ "$have" = "$digest" ] || { echo "$tagref is $have on linux/amd64, the pin says $digest" >&2; return 1; }
		echo "$tagref" ;;
	*) echo "$ref" ;;
	esac
}
echo "== images"
UC_RUN=$(run_ref "$UC_REF") && ok "image $UC_REF (runs as $UC_RUN)" || { bad "image $UC_REF: tag does not match its pin"; exit 1; }
PC_RUN=$(run_ref "$PC_REF") && ok "image $PC_REF (runs as $PC_RUN)" || { bad "image $PC_REF: tag does not match its pin"; exit 1; }
# a pinned tag is always (re-)pulled; an unpinned reference may be a local build
for ref in "$UC_REF" "$PC_REF"; do
	run=$UC_RUN; [ "$ref" = "$PC_REF" ] && run=$PC_RUN
	case $ref in
	*@sha256:*) docker pull -q "$run" >/dev/null ;;
	*) docker image inspect "$run" >/dev/null 2>&1 || docker pull -q "$run" >/dev/null ;;
	esac
done
mkdir -p "$WORK/fake"
(cd "$ROOT/tests/rbac-k3d" && GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS='' \
	go build -trimpath -ldflags='-s -w' -o "$WORK/fake/fake-services" fake-services.go)
printf 'FROM scratch\nCOPY fake-services /fake-services\nUSER 65534\nENTRYPOINT ["/fake-services"]\n' >"$WORK/fake/Dockerfile"
docker build -q -t "$FAKE_IMAGE" "$WORK/fake" >/dev/null
for c in user-controller profile-controller; do
	run=$UC_RUN; [ "$c" = profile-controller ] && run=$PC_RUN
	yq -i "(select(.kind == \"Deployment\") | .spec.template.spec.containers[0].image) = \"$run\"" "$WORK/$c.yaml"
done
fi

# --- cluster ---------------------------------------------------------------------
echo "== cluster"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait \
	--k3s-arg '--disable=traefik,metrics-server,servicelb@server:0' >/dev/null
if controllers; then k3d image import -c "$CLUSTER" "$UC_RUN" "$PC_RUN" "$FAKE_IMAGE" >/dev/null 2>&1; fi

# istio and ArgoCD CRDs (the controllers watch and write these kinds)
cached_chart() { # cached_chart <repo> <name> <version>: path of the .tgz
	local key
	key="$RENDER_CACHE/$(printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g')/$2-$3"
	if ! compgen -G "$key/*.tgz" >/dev/null; then
		mkdir -p "$key" && helm pull "$2" --repo "$1" --version "$3" -d "$key" >/dev/null
	fi
	compgen -G "$key/*.tgz" | head -1
}
# shellcheck disable=SC2086
tar xzf "$(cached_chart $ISTIO_BASE)" -O base/files/crd-all.gen.yaml >"$WORK/istio-crds.yaml"
# shellcheck disable=SC2086
helm template argo "$(cached_chart $ARGO_CD)" --namespace teknoir-system --kube-version "$KUBE_VERSION" |
	yq 'select(.kind == "CustomResourceDefinition" and (.metadata.name == "applications.argoproj.io" or .metadata.name == "appprojects.argoproj.io"))' >"$WORK/argo-crds.yaml"
k apply --server-side -f "$WORK/istio-crds.yaml" -f "$WORK/argo-crds.yaml" >/dev/null

echo "== R1 server-side dry-run"
k apply --server-side --dry-run=server -f "$WORK/profile-crd.yaml" >/dev/null 2>"$WORK/err" && ok "R1 Profile CRD (dry-run=server, $CTX)" || bad "R1 Profile CRD: $(cat "$WORK/err")"
k apply --server-side --field-manager=argocd-controller -f "$WORK/crds.yaml" >/dev/null
k wait --for condition=Established --timeout=60s crd --all >/dev/null
k apply --dry-run=server -f "$WORK/profiles.yaml" >/dev/null 2>"$WORK/err" && ok "R1 Profile teknoir-default (dry-run=server, $CTX)" || bad "R1 Profile: $(cat "$WORK/err")"
if kubectl --context k3d-teknoir-dev --request-timeout=5s get --raw /readyz >/dev/null 2>&1; then
	kubectl --context k3d-teknoir-dev apply --dry-run=server -f "$WORK/profile-crd.yaml" >/dev/null 2>"$WORK/err" &&
		ok "R1 Profile CRD (dry-run=server, k3d-teknoir-dev)" || bad "R1 Profile CRD on k3d-teknoir-dev: $(cat "$WORK/err")"
	if kubectl --context k3d-teknoir-dev get crd profiles.teknoir.org >/dev/null 2>&1; then
		kubectl --context k3d-teknoir-dev apply --dry-run=server -f "$WORK/profiles.yaml" >/dev/null 2>"$WORK/err" &&
			ok "R1 Profile teknoir-default (dry-run=server, k3d-teknoir-dev)" || bad "R1 Profile on k3d-teknoir-dev: $(cat "$WORK/err")"
	else
		skp "R1 Profile on k3d-teknoir-dev: the CRD is not installed there"
	fi
else
	skp "R1 k3d-teknoir-dev is not running"
fi

# --- fixtures (dummy values only) ------------------------------------------------
echo "== fixtures"
for ns in teknoir-system teknoir-auth istio-system; do k create namespace "$ns" >/dev/null; done
k -n teknoir-system create secret generic backstage-keycloak-secrets \
	--from-literal=KEYCLOAK_REALM=teknoir --from-literal=KEYCLOAK_CLIENTID=user-controller \
	--from-literal=KEYCLOAK_CLIENTSECRET=dummy-client-secret >/dev/null
# copied into every teamspace by the PullSecrets and TLSSecrets plugins
k -n teknoir-system create secret docker-registry ghcr-token --docker-server=ghcr.io \
	--docker-username=dummy --docker-password=dummy >/dev/null
k -n istio-system create secret generic teknoir-airgapped-wildcard-tls --type=kubernetes.io/tls \
	--from-literal=tls.crt=dummy --from-literal=tls.key=dummy >/dev/null 2>&1
# What the admission policies protect (R13): the platform AppProjects and an
# Application in them, an ALLOW policy in teknoir-auth.
k apply -f - >/dev/null <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: teknoir-local, namespace: teknoir-system}
spec:
  sourceRepos: [harbor.teknoir.airgapped/teknoir]
  destinations: [{namespace: teknoir-system, server: "https://kubernetes.default.svc"}, {namespace: teknoir-auth, server: "https://kubernetes.default.svc"}]
  clusterResourceWhitelist: [{group: rbac.authorization.k8s.io, kind: ClusterRoleBinding}]
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: default, namespace: teknoir-system}
spec:
  sourceRepos: [harbor.teknoir.airgapped/teknoir]
  destinations: [{namespace: teknoir-system, server: "https://kubernetes.default.svc"}]
  clusterResourceWhitelist: [{group: argoproj.io, kind: Application}, {group: argoproj.io, kind: AppProject}]
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: auth, namespace: teknoir-system}
spec:
  project: teknoir-local
  destination: {namespace: teknoir-auth, server: "https://kubernetes.default.svc"}
  source: {repoURL: harbor.teknoir.airgapped/teknoir, chart: auth, targetRevision: 0.0.9}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: keycloak-allow-ingress, namespace: teknoir-auth}
spec:
  action: ALLOW
  rules: [{from: [{source: {namespaces: [teknoir-system, teknoir-auth]}}]}]
EOF
if controllers; then
k -n teknoir-auth apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: fake-services}
spec:
  selector: {matchLabels: {app: fake-services}}
  template:
    metadata: {labels: {app: fake-services}}
    spec:
      containers:
        - name: fake
          image: $FAKE_IMAGE
          imagePullPolicy: Never
          ports: [{containerPort: 8080}, {containerPort: 18083}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak-http}
spec:
  selector: {app: fake-services}
  ports: [{name: http, port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: Service
metadata: {name: fake-emqx}
spec:
  selector: {app: fake-services}
  ports: [{name: api, port: 18083, targetPort: 18083}]
EOF
k -n teknoir-auth rollout status deploy/fake-services --timeout=120s >/dev/null
fi
fake_calls() { k get --raw /api/v1/namespaces/teknoir-auth/services/keycloak-http:80/proxy/__calls; }
# fake_emqx <ns>: what the EMQX chart would provide (bootstrap Secrets, the API)
fake_emqx() {
	k -n "$1" create secret generic emqx-bootstrap-api-keys --from-literal=apiKey=dummy-key --from-literal=apiSecret=dummy-secret >/dev/null
	k -n "$1" create secret generic emqx-bootstrap-user --from-literal=username=dummy-user --from-literal=password=dummy-password >/dev/null
	k -n "$1" create service externalname emqx --external-name "fake-emqx.teknoir-auth.svc.cluster.local" --tcp=18083 >/dev/null
}

# --- the charts ------------------------------------------------------------------
echo "== apply charts (server-side, as ArgoCD)"
# --legacy: no admission policies; --policies-only: no controllers
skip_kinds='"CustomResourceDefinition", "Profile"'
policies || skip_kinds="$skip_kinds, \"ValidatingAdmissionPolicy\", \"ValidatingAdmissionPolicyBinding\""
controllers || skip_kinds="$skip_kinds, \"Deployment\""
for c in user-controller profile-controller; do
	yq "select(.kind as \$k | [$skip_kinds] | contains([\$k]) | not)" "$WORK/$c.yaml" >"$WORK/$c.rest.yaml"
	k apply --server-side --field-manager=argocd-controller -f "$WORK/$c.rest.yaml" >/dev/null
done
if policies; then
	b=$(yq -r 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$WORK/user-controller.rest.yaml" "$WORK/profile-controller.rest.yaml" | grep -v '^---$' | sort | paste -sd' ')
	[ "$b" = "profile-controller-argocd profile-controller-teamspaces user-controller-teamspace-access" ] && ok "admission policies applied: $b" || bad "admission policies applied: '$b'"
fi

# --- R2 / R3 can-i -----------------------------------------------------------------
echo "== R2/R3 can-i"
set -f # the argument lists below are word-split, never globbed ('* *')
# can <yes|no> <sa> <can-i args...>
can() {
	local want=$1 sa=$2 got; shift 2
	if k auth can-i "$@" --as="$sa" >/dev/null 2>&1; then got=yes; else got=no; fi
	[ "$got" = "$want" ] && ok "can-i ${sa##*:}: $* -> $got" || bad "can-i ${sa##*:}: $* -> $got, want $want"
}
for args in "create rolebindings --all-namespaces" "delete rolebindings -n teknoir-default" "list rolebindings --all-namespaces" \
	"bind clusterroles/teknoir-admin" "bind clusterroles/teknoir-edit" "bind clusterroles/teknoir-view" \
	"create authorizationpolicies.security.istio.io -n rbac-test" "delete authorizationpolicies.security.istio.io --all-namespaces" \
	"list profiles.teknoir.org" "get claimsets.teknoir.org -n rbac-test" "list claims.teknoir.org -n teknoir-system" \
	"update users.teknoir.org" "update users.teknoir.org --subresource=status" "update users.teknoir.org --subresource=finalizers" \
	"create leases.coordination.k8s.io -n teknoir-system" "create events -n teknoir-system" \
	"get secrets -n teknoir-user-credentials" "create secrets -n teknoir-user-credentials" \
	"update secrets -n teknoir-user-credentials" "delete secrets -n teknoir-user-credentials"; do
	# shellcheck disable=SC2086
	can yes "$UC_SA" $args
done
for args in "bind clusterroles/cluster-admin" "bind clusterroles/admin" "bind clusterroles/edit" "escalate clusterroles" \
	"create clusterroles" "create clusterrolebindings" "create roles -n rbac-test" \
	"get secrets -n teknoir-auth" "get secrets -n teknoir-system" "list secrets --all-namespaces" \
	"list secrets -n teknoir-user-credentials" "watch secrets -n teknoir-user-credentials" \
	"create pods --subresource=exec -n teknoir-system" "create pods --subresource=exec -n rbac-test" "create pods -n teknoir-system" \
	"create namespaces" "delete namespaces" "create users.teknoir.org" "delete users.teknoir.org" "update profiles.teknoir.org" \
	"create leases.coordination.k8s.io -n kube-system" "impersonate serviceaccounts" "* *"; do
	# shellcheck disable=SC2086
	can no "$UC_SA" $args
done
for args in "create namespaces" "update namespaces" "create rolebindings --all-namespaces" \
	"bind clusterroles/teknoir-admin" "bind clusterroles/teknoir-edit" "bind clusterroles/teknoir-view" \
	"create applications.argoproj.io -n teknoir-system" "update applications.argoproj.io -n teknoir-system" \
	"delete applications.argoproj.io -n teknoir-system" "create appprojects.argoproj.io -n teknoir-system" \
	"list applications.argoproj.io --all-namespaces" "create authorizationpolicies.security.istio.io --all-namespaces" \
	"create requestauthentications.security.istio.io --all-namespaces" "list helmcharts.helm.cattle.io --all-namespaces" \
	"list envoyfilters.networking.istio.io --all-namespaces" "list virtualservices.networking.istio.io --all-namespaces" \
	"update profiles.teknoir.org" "patch profiles.teknoir.org --subresource=status" "update profiles.teknoir.org --subresource=finalizers" \
	"get secrets -n istio-system" "create secrets -n teknoir-default" "create resourcequotas -n teknoir-default" \
	"create serviceaccounts -n teknoir-default" "create configmaps -n teknoir-default" "list deployments.apps --all-namespaces"; do
	# shellcheck disable=SC2086
	can yes "$PC_SA" $args
done
for args in "create clusterrolebindings" "bind clusterroles/cluster-admin" "bind clusterroles/admin" "escalate clusterroles" \
	"create clusterroles" "create roles -n teknoir-default" "create pods --subresource=exec -n teknoir-default" \
	"create pods --subresource=exec -n teknoir-system" "create pods -n teknoir-default" "create deployments.apps -n teknoir-default" \
	"create statefulsets.apps -n teknoir-default" "delete namespaces" "create applications.argoproj.io -n default" \
	"create appprojects.argoproj.io -n teknoir-default" "create helmcharts.helm.cattle.io -n teknoir-default" \
	"create virtualservices.networking.istio.io -n teknoir-default" "create users.teknoir.org" "create profiles.teknoir.org" \
	"create leases.coordination.k8s.io -n teknoir-system" "impersonate users" "* *"; do
	# shellcheck disable=SC2086
	can no "$PC_SA" $args
done

set +f

# --- R4 real binding creates -------------------------------------------------------
echo "== R4 escalation check"
k create namespace rbac-probe >/dev/null
for sa in "$UC_SA" "$PC_SA"; do
	n=${sa##*:}
	# rbac-probe is no teamspace (no Profile owns it)
	if k --as="$sa" -n rbac-probe create rolebinding "$n-teknoir-admin" --clusterrole=teknoir-admin --user=probe@example.com >/dev/null 2>"$WORK/err"; then
		policies && bad "R4 $n created a RoleBinding to teknoir-admin outside a teamspace" || ok "R4 $n creates a RoleBinding to teknoir-admin (no admission policies)"
	elif policies && grep -q 'ValidatingAdmissionPolicy' "$WORK/err"; then
		ok "R4 $n: a RoleBinding to teknoir-admin passes RBAC and is refused by the admission policy outside a teamspace"
	else
		bad "R4 $n RoleBinding to teknoir-admin: $(cat "$WORK/err")"
	fi
	for role in cluster-admin admin; do
		if k --as="$sa" -n rbac-probe create rolebinding "$n-$role" --clusterrole="$role" --user=probe@example.com >/dev/null 2>"$WORK/err"; then
			bad "R4 $n created a RoleBinding to $role"
		elif grep -qi forbidden "$WORK/err" && ! grep -q 'ValidatingAdmissionPolicy' "$WORK/err"; then
			ok "R4 $n refused a RoleBinding to $role by RBAC (escalation check)"
		else
			bad "R4 $n RoleBinding to $role failed otherwise: $(cat "$WORK/err")"
		fi
	done
done
k delete namespace rbac-probe --wait=false >/dev/null

# --- R13 admission policies ----------------------------------------------------------
# probe <allow|deny> <sa> <label> <kubectl args...>: a server-side dry run as
# <sa> (admission runs, nothing is stored). A refusal must come from an
# admission policy, i.e. the RBAC allowed the request. PROBE_POLICY=<name>
# (optional): the refusal must come from that policy.
probe() {
	local want=$1 sa=$2 label=$3 got; shift 3
	if k --as="$sa" "$@" --dry-run=server >/dev/null 2>"$WORK/err"; then got=allow; else got=deny; fi
	case $want/$got in
	allow/allow) ok "$PROBE_TAG ${sa##*:}: $label: allowed" ;;
	deny/deny)
		# "ValidatingAdmissionPolicy '<policy>' with binding '<b>' denied request: <message>";
		# an expression that fails to evaluate denies too (failurePolicy Fail): not a pass
		local policy msg
		policy=$(grep -o "ValidatingAdmissionPolicy '[^']*'" "$WORK/err" | head -1 | cut -d"'" -f2)
		msg=$(sed -n 's/.*denied request: //p' "$WORK/err" | head -1)
		if [ -z "$policy" ] || [ -z "$msg" ]; then
			bad "$PROBE_TAG ${sa##*:}: $label: refused, but not by an admission policy: $(head -c 300 "$WORK/err")"
		elif grep -Eqi 'resulted in error|no such key|no matching overload|compil|evaluat' <<<"$msg"; then
			bad "$PROBE_TAG ${sa##*:}: $label: $policy failed to evaluate: $(head -c 300 <<<"$msg")"
		elif [ -n "${PROBE_POLICY:-}" ] && [ "$policy" != "$PROBE_POLICY" ]; then
			bad "$PROBE_TAG ${sa##*:}: $label: refused by $policy, want $PROBE_POLICY"
		else
			ok "$PROBE_TAG ${sa##*:}: $label: refused by $policy ($(cut -c1-60 <<<"$msg")...)"
		fi ;;
	allow/deny) bad "$PROBE_TAG ${sa##*:}: $label: refused: $(head -c 300 "$WORK/err")" ;;
	deny/allow) bad "$PROBE_TAG ${sa##*:}: $label: allowed" ;;
	esac
}
# owner <kind> <name> [uid]: ownerReferences JSON (a made-up uid is fine for a dry run)
owner() { jq -nc --arg k "$1" --arg n "$2" --arg u "${3:-00000000-0000-0000-0000-000000000000}" '[{apiVersion: "teknoir.org/v1", kind: $k, name: $n, uid: $u, controller: true}]'; }
IN_CLUSTER=https://kubernetes.default.svc NOPATCH='{}'
# appproject <name> <owners> [spec patch]: the teamspace shape the controller writes, patched
appproject() {
	jq -nc --arg n "$1" --argjson o "$2" --arg r "$REPO" --arg s "$IN_CLUSTER" --argjson x "${3:-$NOPATCH}" '{apiVersion: "argoproj.io/v1alpha1", kind: "AppProject",
		metadata: {name: $n, namespace: "teknoir-system", ownerReferences: $o},
		spec: ({sourceRepos: [$r], destinations: [{namespace: $n, server: $s}], clusterResourceWhitelist: []} + $x)}'
}
# application <name> <owners> <project> <destination namespace> [spec patch]
application() {
	jq -nc --arg n "$1" --argjson o "$2" --arg p "$3" --arg d "$4" --arg r "$REPO" --arg v "$VERSION" --arg s "$IN_CLUSTER" --argjson x "${5:-$NOPATCH}" '{apiVersion: "argoproj.io/v1alpha1", kind: "Application",
		metadata: {name: $n, namespace: "teknoir-system", ownerReferences: $o},
		spec: ({project: $p, destination: {namespace: $d, server: $s},
			source: {repoURL: $r, chart: "profile-plugin-jwks", targetRevision: $v, helm: {releaseName: "jwks"}},
			syncPolicy: {syncOptions: ["RespectIgnoreDifferences=true"]}} + $x)}'
}
# rolebinding <namespace> <name> <owners> <clusterrole> <subject JSON>
rolebinding() {
	jq -nc --arg ns "$1" --arg n "$2" --argjson o "$3" --arg r "$4" --argjson s "$5" '{apiVersion: "rbac.authorization.k8s.io/v1", kind: "RoleBinding",
		metadata: {name: $n, namespace: $ns, ownerReferences: $o}, roleRef: {apiGroup: "rbac.authorization.k8s.io", kind: "ClusterRole", name: $r}, subjects: [$s]}'
}
# authpolicy <namespace> <name> <owners> <action>
authpolicy() {
	jq -nc --arg ns "$1" --arg n "$2" --argjson o "$3" --arg a "$4" '{apiVersion: "security.istio.io/v1", kind: "AuthorizationPolicy",
		metadata: {name: $n, namespace: $ns, ownerReferences: $o},
		spec: {action: $a, rules: [{when: [{key: "request.headers[X-Auth-Request-Email]", values: ["probe@example.com"]}]}]}}'
}
r13() {
	local td_uid b ts subject
	ts=teknoir-default
	subject='{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"probe@example.com"}'
	echo "== R13 admission policies"
	if ! policies; then skp "R13 admission policies: --legacy"; return 0; fi
	td_uid=$(k get profile "$ts" -o jsonpath='{.metadata.uid}')
	# type-checked (async) against the matched kinds, without warnings
	wait_for 60 sh -c "kubectl --context $CTX get validatingadmissionpolicies -o json | jq -e '[.items[] | select(.metadata.name | test(\"controller\"))
		| select(.status.observedGeneration != .metadata.generation)] | length == 0'" || true
	b=$(k get validatingadmissionpolicies -o json | jq -c '[.items[] | select(.metadata.name | test("controller"))
		| {n: .metadata.name, gen: (.status.observedGeneration == .metadata.generation), w: (.status.typeChecking.expressionWarnings // [])}
		| select(.gen | not) or (.w | length > 0)]')
	[ "$b" = "[]" ] && ok "R13 every policy type-checked, no warnings" || bad "R13 type checking: $b"

	# profile-controller: Applications and AppProjects
	local P=$PC_SA o_ts o_none='[]'
	o_ts=$(owner Profile "$ts" "$td_uid")
	probe deny "$P" "widen the platform AppProject teknoir-local" patch appproject teknoir-local -n teknoir-system --type=merge -p '{"spec":{"sourceRepos":["*"]}}'
	probe deny "$P" "relabel the platform AppProject default" patch appproject default -n teknoir-system --type=merge -p '{"metadata":{"labels":{"probe":"x"}}}'
	probe deny "$P" "delete the platform AppProject teknoir-local" delete appproject teknoir-local -n teknoir-system
	probe deny "$P" "change the platform Application auth" patch application auth -n teknoir-system --type=merge -p '{"spec":{"source":{"targetRevision":"9.9.9"}}}'
	probe deny "$P" "take over the platform Application auth (add a Profile owner)" patch application auth -n teknoir-system --type=merge -p "{\"metadata\":{\"ownerReferences\":$o_ts}}"
	probe deny "$P" "delete the platform Application auth" delete application auth -n teknoir-system
	probe deny "$P" "AppProject with a cluster-scoped whitelist" create -f - <<<"$(appproject vap-x "$(owner Profile vap-x)" '{"clusterResourceWhitelist":[{"group":"*","kind":"*"}]}')"
	probe deny "$P" "AppProject with sourceRepos *" create -f - <<<"$(appproject vap-x "$(owner Profile vap-x)" '{"sourceRepos":["*"]}')"
	probe deny "$P" "AppProject with source namespaces" create -f - <<<"$(appproject vap-x "$(owner Profile vap-x)" '{"sourceNamespaces":["*"]}')"
	probe deny "$P" "AppProject for reserved teknoir-auth" create -f - <<<"$(appproject teknoir-auth "$(owner Profile teknoir-auth)")"
	probe deny "$P" "AppProject for kube-system" create -f - <<<"$(appproject kube-system "$(owner Profile kube-system)")"
	probe deny "$P" "AppProject aimed at teknoir-auth" create -f - <<<"$(appproject vap-x "$(owner Profile vap-x)" "{\"destinations\":[{\"namespace\":\"teknoir-auth\",\"server\":\"$IN_CLUSTER\"}]}")"
	probe deny "$P" "AppProject aimed at another cluster" create -f - <<<"$(appproject vap-x "$(owner Profile vap-x)" '{"destinations":[{"namespace":"vap-x","server":"https://evil.example.com"}]}')"
	probe deny "$P" "AppProject without a Profile owner" create -f - <<<"$(appproject vap-x "$o_none")"
	probe deny "$P" "AppProject named apart from its owner" create -f - <<<"$(appproject vap-x "$o_ts")"
	probe deny "$P" "widen its own AppProject $ts (sourceRepos *)" patch appproject "$ts" -n teknoir-system --type=merge -p '{"spec":{"sourceRepos":["*"]}}'
	probe deny "$P" "widen its own AppProject $ts (cluster-scoped kinds)" patch appproject "$ts" -n teknoir-system --type=merge -p '{"spec":{"clusterResourceWhitelist":[{"group":"*","kind":"*"}]}}'
	probe deny "$P" "release its own AppProject $ts (drop the owner)" patch appproject "$ts" -n teknoir-system --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
	probe allow "$P" "update its own AppProject $ts (a label)" patch appproject "$ts" -n teknoir-system --type=merge -p '{"metadata":{"labels":{"probe":"x"}}}'
	probe deny "$P" "Application in AppProject teknoir-local" create -f - <<<"$(application "$ts-vap" "$o_ts" teknoir-local "$ts")"
	probe deny "$P" "Application into teknoir-auth" create -f - <<<"$(application "$ts-vap" "$o_ts" "$ts" teknoir-auth)"
	probe deny "$P" "Application from another repository" create -f - <<<"$(application "$ts-vap" "$o_ts" "$ts" "$ts" '{"source":{"repoURL":"https://charts.example.com","chart":"x","targetRevision":"1.0.0"}}')"
	probe deny "$P" "Application with several sources" create -f - <<<"$(application "$ts-vap" "$o_ts" "$ts" "$ts" "{\"sources\":[{\"repoURL\":\"$REPO\",\"chart\":\"x\",\"targetRevision\":\"1\"},{\"repoURL\":\"https://charts.example.com\",\"chart\":\"y\",\"targetRevision\":\"1\"}]}")"
	probe deny "$P" "Application on another cluster" create -f - <<<"$(application "$ts-vap" "$o_ts" "$ts" "$ts" '{"destination":{"namespace":"teknoir-default","server":"https://evil.example.com"}}')"
	probe deny "$P" "Application without a Profile owner" create -f - <<<"$(application "$ts-vap" "$o_none" "$ts" "$ts")"
	probe deny "$P" "Application not named <teamspace>-<plugin>" create -f - <<<"$(application auth2 "$o_ts" "$ts" "$ts")"
	probe allow "$P" "Application $ts-vap in the teamspace shape" create -f - <<<"$(application "$ts-vap" "$o_ts" "$ts" "$ts")"
	# profile-controller: writes outside a teamspace, namespaces
	probe deny "$P" "RoleBinding teknoir-admin to itself in teknoir-auth" create rolebinding vap -n teknoir-auth --clusterrole=teknoir-admin --serviceaccount=teknoir-system:profile-controller
	probe deny "$P" "RoleBinding teknoir-admin to itself in kube-system" create rolebinding vap -n kube-system --clusterrole=teknoir-admin --serviceaccount=teknoir-system:profile-controller
	probe deny "$P" "Secret in teknoir-auth" create secret generic vap -n teknoir-auth --from-literal=k=dummy
	probe deny "$P" "ConfigMap in teknoir-system" create configmap vap -n teknoir-system --from-literal=k=v
	probe deny "$P" "AuthorizationPolicy in istio-system (mesh-wide)" create -f - <<<"$(authpolicy istio-system vap "$o_none" ALLOW)"
	probe deny "$P" "delete AuthorizationPolicy teknoir-auth/keycloak-allow-ingress" delete authorizationpolicies.security.istio.io keycloak-allow-ingress -n teknoir-auth
	probe deny "$P" "relabel Namespace teknoir-auth" patch namespace teknoir-auth --type=merge -p '{"metadata":{"labels":{"probe":"x"}}}'
	probe deny "$P" "make teknoir-auth a teamspace (add a Profile owner)" patch namespace teknoir-auth --type=merge -p "{\"metadata\":{\"ownerReferences\":$(owner Profile teknoir-auth)}}"
	probe deny "$P" "mark teknoir-auth as a teamspace (part-of label, owner annotation)" patch namespace teknoir-auth --type=merge -p '{"metadata":{"labels":{"app.kubernetes.io/part-of":"teknoir-profile"},"annotations":{"owner":"probe@example.com"}}}'
	probe deny "$P" "Namespace without a Profile owner" create namespace vap-x
	probe deny "$P" "Namespace kube-vap (reserved prefix)" create -f - <<<"$(jq -nc --argjson o "$(owner Profile kube-vap)" '{apiVersion: "v1", kind: "Namespace", metadata: {name: "kube-vap", ownerReferences: $o}}')"
	probe deny "$P" "release Namespace $ts (drop its Profile owner)" patch namespace "$ts" --type=json -p '[{"op":"remove","path":"/metadata/ownerReferences"}]'
	probe deny "$P" "RoleBinding in $ts for another namespace's ServiceAccount" create rolebinding vap -n "$ts" --clusterrole=teknoir-admin --serviceaccount=teknoir-system:profile-controller
	probe deny "$P" "RoleBinding in $ts for system:anonymous" create rolebinding vap -n "$ts" --clusterrole=teknoir-view --user=system:anonymous
	probe allow "$P" "Namespace vap-new owned by Profile vap-new" create -f - <<<"$(jq -nc --argjson o "$(owner Profile vap-new)" '{apiVersion: "v1", kind: "Namespace", metadata: {name: "vap-new", ownerReferences: $o}}')"
	probe allow "$P" "relabel its Namespace $ts" patch namespace "$ts" --type=merge -p '{"metadata":{"labels":{"probe":"x"}}}'
	probe allow "$P" "ConfigMap in $ts" create configmap vap -n "$ts" --from-literal=k=v
	probe allow "$P" "Secret in $ts" create secret generic vap -n "$ts" --from-literal=k=dummy
	probe allow "$P" "RoleBinding teknoir-view to $ts/default-viewer" create rolebinding vap -n "$ts" --clusterrole=teknoir-view --serviceaccount="$ts:default-viewer"
	probe allow "$P" "RoleBinding teknoir-admin to the owner (User)" create rolebinding vap -n "$ts" --clusterrole=teknoir-admin --user=owner@example.com
	probe allow "$P" "DENY AuthorizationPolicy in $ts (whitelist-namespaces)" create -f - <<<"$(authpolicy "$ts" vap "$o_ts" DENY)"

	# user-controller
	local U=$UC_SA o_user rb ap
	o_user=$(owner User vap-probe)
	rb=user-vap-probe-teknoir-role-binding ap=user-vap-probe-teknoir-authorization-policy
	for ns in teknoir-auth teknoir-system kube-system; do
		probe deny "$U" "RoleBinding teknoir-admin to itself in $ns" create rolebinding x -n "$ns" --clusterrole=teknoir-admin --serviceaccount=teknoir-system:user-controller
	done
	probe deny "$U" "its own-shaped RoleBinding in teknoir-auth" create -f - <<<"$(rolebinding teknoir-auth "$rb" "$o_user" teknoir-admin "$subject")"
	probe deny "$U" "AuthorizationPolicy in istio-system (mesh-wide)" create -f - <<<"$(authpolicy istio-system "$ap" "$o_user" ALLOW)"
	probe deny "$U" "delete AuthorizationPolicy teknoir-auth/keycloak-allow-ingress" delete authorizationpolicies.security.istio.io keycloak-allow-ingress -n teknoir-auth
	probe deny "$U" "change the owner's RoleBinding $ts/namespaceAdmin" patch rolebinding namespaceAdmin -n "$ts" --type=merge -p '{"subjects":[{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"probe@example.com"}]}'
	probe deny "$U" "delete the owner's RoleBinding $ts/namespaceAdmin" delete rolebinding namespaceAdmin -n "$ts"
	probe deny "$U" "RoleBinding in $ts for a ServiceAccount" create -f - <<<"$(rolebinding "$ts" "$rb" "$o_user" teknoir-admin '{"kind":"ServiceAccount","name":"user-controller","namespace":"teknoir-system"}')"
	probe deny "$U" "RoleBinding in $ts for system:anonymous" create -f - <<<"$(rolebinding "$ts" "$rb" "$o_user" teknoir-view '{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"system:anonymous"}')"
	probe deny "$U" "RoleBinding in $ts without a User owner" create -f - <<<"$(rolebinding "$ts" "$rb" "$o_none" teknoir-view "$subject")"
	probe deny "$U" "RoleBinding in $ts under another name" create -f - <<<"$(rolebinding "$ts" vap "$o_user" teknoir-view "$subject")"
	probe deny "$U" "DENY AuthorizationPolicy in $ts" create -f - <<<"$(authpolicy "$ts" "$ap" "$o_user" DENY)"
	probe allow "$U" "$rb (teknoir-view, User) in $ts" create -f - <<<"$(rolebinding "$ts" "$rb" "$o_user" teknoir-view "$subject")"
	probe allow "$U" "$ap (ALLOW) in $ts" create -f - <<<"$(authpolicy "$ts" "$ap" "$o_user" ALLOW)"

	# anyone else is not matched
	if k patch appproject teknoir-local -n teknoir-system --type=merge -p '{"metadata":{"labels":{"probe":"x"}}}' --dry-run=server >/dev/null 2>"$WORK/err" &&
		k -n teknoir-auth create rolebinding vap --clusterrole=teknoir-admin --serviceaccount=teknoir-system:user-controller --dry-run=server >/dev/null 2>>"$WORK/err"; then
		ok "R13 a cluster admin is not affected (platform AppProject, RoleBinding in teknoir-auth)"
	else
		bad "R13 a cluster admin is refused: $(head -c 300 "$WORK/err")"
	fi
}
# --- R14 break-glass ------------------------------------------------------------------
# The commands of infra docs/airgap/OPERATE.md (r5, "Controller RBAC and
# admission policies"); keep them in step with the runbook.
BG_OFF='[{"op":"remove","path":"/spec/syncPolicy/automated"}]'
BG_ON='{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true,"enabled":true}}}}'
# settle <allow|deny> <sa> <kubectl args...>: wait up to 30 s until a dry run
# as <sa> gets that answer (a binding change reaches admission through an
# informer)
settle() {
	local want=$1 sa=$2 got; shift 2
	for _ in $(seq 1 15); do
		if k --as="$sa" "$@" --dry-run=server >/dev/null 2>&1; then got=allow; else got=deny; fi
		[ "$got" = "$want" ] && return 0
		sleep 2
	done
	return 1
}
spec_of() { k -n teknoir-system get application "$1" -o json | jq -cS '.spec'; }
r14() {
	local PROBE_TAG=R14 P=$PC_SA U=$UC_SA app b
	local -A spec0
	local auth_patch='{"spec":{"source":{"targetRevision":"9.9.9"}}}'
	local self_bind=(create rolebinding x -n teknoir-auth --clusterrole=teknoir-admin --serviceaccount=teknoir-system:user-controller)
	echo "== R14 break-glass (OPERATE r5)"
	if ! policies; then skp "R14 break-glass: --legacy"; return 0; fi
	# stand-ins: the controller Applications as the root syncs them, the root as up applies it
	helm template app-of-apps "$ROOT/charts/app-of-apps" --namespace teknoir-system --kube-version "$KUBE_VERSION" |
		yq 'select(.kind == "Application" and (.metadata.name == "user-controller" or .metadata.name == "profile-controller"))' >"$WORK/children.yaml"
	cat >"$WORK/root.yaml" <<'ROOT_APP'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: teknoir-system
  annotations: {argocd.argoproj.io/compare-options: ServerSideDiff=true}
spec:
  project: default
  destination: {namespace: teknoir-system, server: "https://kubernetes.default.svc"}
  source: {repoURL: harbor.teknoir.airgapped/teknoir, chart: app-of-apps, targetRevision: 0.0.5}
  syncPolicy:
    automated: {prune: true, selfHeal: true, enabled: true}
    retry: {limit: 10, backoff: {duration: 30s, factor: 2, maxDuration: 5m}}
ROOT_APP
	yq 'select(.kind == "ValidatingAdmissionPolicyBinding")' "$WORK/user-controller.yaml" "$WORK/profile-controller.yaml" >"$WORK/bindings.yaml"
	k -n teknoir-system apply --server-side --field-manager=argocd-controller -f "$WORK/children.yaml" >/dev/null
	k apply --server-side --field-manager=teknoir-bootstrap -f "$WORK/root.yaml" >/dev/null
	for app in app-of-apps user-controller profile-controller; do
		spec0[$app]=$(spec_of "$app")
		[ "$(jq -c '.syncPolicy.automated' <<<"${spec0[$app]}")" = '{"enabled":true,"prune":true,"selfHeal":true}' ] &&
			ok "R14 stand-in $app with auto-sync (prune, selfHeal)" || bad "R14 stand-in $app: ${spec0[$app]}"
	done

	PROBE_POLICY=profile-controller-argocd probe deny "$P" "change the platform Application auth" patch application auth -n teknoir-system --type=merge -p "$auth_patch"
	grep -q "is forbidden: ValidatingAdmissionPolicy 'profile-controller-argocd' with binding 'profile-controller-argocd' denied request: " "$WORK/err" &&
		ok "R14 a denial reads \"... is forbidden: ValidatingAdmissionPolicy '<policy>' with binding '<binding>' denied request: ...\" (E13's 'forbidden' check, the runbook's grep)" ||
		bad "R14 denial text: $(head -c 300 "$WORK/err")"

	# break-glass for profile-controller-argocd: the root, then the child, then the binding
	k -n teknoir-system patch application app-of-apps --type json -p "$BG_OFF" >/dev/null 2>"$WORK/err" || bad "R14 step 1 (root): $(cat "$WORK/err")"
	k -n teknoir-system patch application profile-controller --type json -p "$BG_OFF" >/dev/null 2>"$WORK/err" || bad "R14 step 2 (profile-controller): $(cat "$WORK/err")"
	k delete validatingadmissionpolicybinding profile-controller-argocd >/dev/null 2>"$WORK/err" || bad "R14 step 3 (binding): $(cat "$WORK/err")"
	for app in app-of-apps profile-controller; do
		[ "$(spec_of "$app")" = "$(jq -cS 'del(.syncPolicy.automated)' <<<"${spec0[$app]}")" ] &&
			ok "R14 $app: auto-sync off, the rest of its spec unchanged" || bad "R14 $app after the patch: $(spec_of "$app")"
	done
	[ "$(spec_of user-controller)" = "${spec0[user-controller]}" ] && ok "R14 the user-controller Application is untouched" || bad "R14 the user-controller Application changed"
	settle allow "$P" patch application auth -n teknoir-system --type=merge -p "$auth_patch" || true
	probe allow "$P" "change the platform Application auth, binding profile-controller-argocd deleted" patch application auth -n teknoir-system --type=merge -p "$auth_patch"
	PROBE_POLICY=profile-controller-teamspaces probe deny "$P" "ConfigMap in teknoir-system (profile-controller-teamspaces still bound)" create configmap vap -n teknoir-system --from-literal=k=v
	PROBE_POLICY=user-controller-teamspace-access probe deny "$U" "RoleBinding teknoir-admin to itself in teknoir-auth (still bound)" "${self_bind[@]}"
	# the same for the user-controller (the root's auto-sync is already off)
	k -n teknoir-system patch application user-controller --type json -p "$BG_OFF" >/dev/null 2>"$WORK/err" || bad "R14 step 2 (user-controller): $(cat "$WORK/err")"
	k delete validatingadmissionpolicybinding user-controller-teamspace-access >/dev/null 2>"$WORK/err" || bad "R14 step 3 (binding): $(cat "$WORK/err")"
	settle allow "$U" "${self_bind[@]}" || true
	probe allow "$U" "RoleBinding teknoir-admin to itself in teknoir-auth, binding user-controller-teamspace-access deleted" "${self_bind[@]}"
	b=$(k get validatingadmissionpolicies -o name | grep -c controller || true)
	[ "$b" = 3 ] && ok "R14 the three policies stay (only bindings deleted)" || bad "R14 $b controller policies left"

	# revert: the root's auto-sync back, by the runbook's merge patch and by up
	# (server-side apply of the root as teknoir-bootstrap)
	k -n teknoir-system patch application app-of-apps --type merge -p "$BG_ON" >/dev/null 2>"$WORK/err" || bad "R14 revert patch: $(cat "$WORK/err")"
	[ "$(spec_of app-of-apps)" = "${spec0[app-of-apps]}" ] && ok "R14 revert by merge patch: the root's spec is as up applied it" || bad "R14 root after the revert patch: $(spec_of app-of-apps)"
	k -n teknoir-system patch application app-of-apps --type json -p "$BG_OFF" >/dev/null
	k apply --server-side --force-conflicts --field-manager=teknoir-bootstrap -f "$WORK/root.yaml" >/dev/null 2>"$WORK/err" || bad "R14 up's apply of the root: $(cat "$WORK/err")"
	[ "$(spec_of app-of-apps)" = "${spec0[app-of-apps]}" ] && ok "R14 revert by up: the root's auto-sync is back" || bad "R14 root after up's apply: $(spec_of app-of-apps)"
	# what the root's self-heal and the children's syncs then apply
	k -n teknoir-system apply --server-side --field-manager=argocd-controller -f "$WORK/children.yaml" >/dev/null
	k apply --server-side --field-manager=argocd-controller -f "$WORK/bindings.yaml" >/dev/null
	for app in user-controller profile-controller; do
		[ "$(spec_of "$app")" = "${spec0[$app]}" ] && ok "R14 revert: $app has its auto-sync back" || bad "R14 $app after the revert: $(spec_of "$app")"
	done
	settle deny "$P" patch application auth -n teknoir-system --type=merge -p "$auth_patch" || true
	settle deny "$U" "${self_bind[@]}" || true
	PROBE_POLICY=profile-controller-argocd probe deny "$P" "change the platform Application auth, after the revert" patch application auth -n teknoir-system --type=merge -p "$auth_patch"
	PROBE_POLICY=user-controller-teamspace-access probe deny "$U" "RoleBinding teknoir-admin to itself in teknoir-auth, after the revert" "${self_bind[@]}"
	k -n teknoir-system delete application app-of-apps user-controller profile-controller >/dev/null
}
summary() {
	echo
	echo "rbac-k3d: $pass passed, $fail failed, $skip skipped$([ "$LEGACY" -eq 1 ] && echo ' (--legacy)')$([ "$ONLY_POLICIES" -eq 1 ] && echo ' (--policies-only)')"
	[ "$fail" -eq 0 ]
}

if ! controllers; then
	# Stand-ins for what the profile-controller creates for teknoir-default.
	echo "== teknoir-default stand-ins (no controllers)"
	k apply --server-side --field-manager=argocd-controller -f "$WORK/profiles.yaml" >/dev/null
	o=$(owner Profile teknoir-default "$(k get profile teknoir-default -o jsonpath='{.metadata.uid}')")
	jq -nc --argjson o "$o" '{apiVersion: "v1", kind: "Namespace", metadata: {name: "teknoir-default", ownerReferences: $o,
		labels: {"app.kubernetes.io/part-of": "teknoir-profile", "istio-injection": "enabled"}, annotations: {owner: "owner@example.com"}}}' | k apply -f - >/dev/null
	appproject teknoir-default "$o" | k apply -f - >/dev/null
	rolebinding teknoir-default namespaceAdmin "$o" teknoir-admin '{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"owner@example.com"}' | k apply -f - >/dev/null
	r13
	r14
	summary
	exit
fi

# --- R5 start ----------------------------------------------------------------------
echo "== R5 controllers start"
for d in user-controller profile-controller; do
	if k -n teknoir-system rollout status "deploy/$d" --timeout=180s >/dev/null 2>&1; then ok "R5 $d Available"; else bad "R5 $d not Available"; fi
done
logs() { k -n teknoir-system logs "deploy/$1" --tail=-1 2>/dev/null; }
wait_for 120 sh -c "kubectl --context $CTX -n teknoir-system logs deploy/user-controller --tail=-1 | grep -q 'successfully acquired lease'" &&
	ok "R5 user-controller acquired its leader-election Lease" || bad "R5 user-controller never acquired the Lease"
for d in user-controller profile-controller; do
	wait_for 120 sh -c "kubectl --context $CTX -n teknoir-system logs deploy/$d --tail=-1 | grep -q 'Starting workers'" &&
		ok "R5 $d started its workers (caches synced)" || bad "R5 $d did not start its workers"
done

# --- R6 / R7 Profiles ----------------------------------------------------------------
echo "== R6/R7 Profiles"
k apply --server-side --field-manager=argocd-controller -f "$WORK/profiles.yaml" >/dev/null
k apply -f - >/dev/null <<'EOF'
apiVersion: teknoir.org/v1
kind: Profile
metadata: {name: rbac-test}
spec:
  owner: {apiGroup: rbac.authorization.k8s.io, kind: User, name: rbac-owner@example.com}
EOF
has_finalizer() { case " $(k get "$1" "$2" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null) " in *" $3 "*) return 0 ;; *) return 1 ;; esac; }
# The EMQX fixtures go in as soon as each namespace exists, so neither
# Profile's retry backoff grows while the other one is checked.
for ns in teknoir-default rbac-test; do
	if wait_for 120 k get namespace "$ns"; then ok "R6 $ns: namespace created"; fake_emqx "$ns"; else bad "R6 $ns: no namespace"; fi
done
check_profile() { # check_profile <name> <owner>
	local ns=$1 owner=$2 b want
	k get namespace "$ns" >/dev/null 2>&1 || return 0
	if wait_for 240 has_finalizer profile "$ns" profile-finalizer; then ok "R6 $ns: reconciled to completion (profile-finalizer)"; else bad "R6 $ns: never completed a reconcile"; fi
	# (the admission policies recognise a teamspace by the part-of label and
	# the owner annotation)
	b=$(k get namespace "$ns" -o go-template='{{index .metadata.annotations "owner"}} {{index .metadata.labels "istio-injection"}} {{index .metadata.labels "app.kubernetes.io/part-of"}} {{(index .metadata.ownerReferences 0).kind}}/{{(index .metadata.ownerReferences 0).name}}')
	[ "$b" = "$owner enabled teknoir-profile Profile/$ns" ] && ok "R6 $ns: namespace owner, istio-injection, part-of teknoir-profile, ownerReference Profile/$ns" || bad "R6 $ns: namespace '$b'"
	b=$(k -n "$ns" get rolebindings -o go-template='{{range .items}}{{.metadata.name}}={{.roleRef.name}} {{end}}')
	for want in namespaceAdmin=teknoir-admin default-editor=teknoir-edit default-viewer=teknoir-view; do
		case " $b " in *" $want "*) ok "R6 $ns: RoleBinding $want" ;; *) bad "R6 $ns: no RoleBinding $want ($b)" ;; esac
	done
	b=$(k -n "$ns" get rolebinding namespaceAdmin -o jsonpath='{.subjects[0].kind}/{.subjects[0].name}' 2>/dev/null)
	[ "$b" = "User/$owner" ] && ok "R6 $ns: namespaceAdmin subject User/$owner" || bad "R6 $ns: namespaceAdmin subject $b"
	for want in serviceaccount/default-editor serviceaccount/default-viewer authorizationpolicies.security.istio.io/ns-owner-access-istio \
		authorizationpolicies.security.istio.io/whitelist-namespaces requestauthentications.security.istio.io/jwt-policy \
		configmap/org-config configmap/user-alerting-rules secret/domain-wildcard-tls secret/ghcr-token; do
		k -n "$ns" get "$want" >/dev/null 2>&1 && ok "R6 $ns: $want" || bad "R6 $ns: missing $want"
	done
	k -n teknoir-system get appproject "$ns" >/dev/null 2>&1 && ok "R6 $ns: AppProject teknoir-system/$ns" || bad "R6 $ns: no AppProject"
	b=$(k -n teknoir-system get applications -o json | jq -r --arg ns "$ns" '[.items[] | select(.spec.project == $ns) | .metadata.name] | sort | join(" ")')
	want=$(for p in $PLUGINS; do printf '%s-%s\n' "$ns" "$p"; done | sort | paste -sd' ')
	[ "$b" = "$want" ] && ok "R6 $ns: the 9 default plugin Applications" || bad "R6 $ns: Applications '$b'"
	b=$(fake_calls | jq --arg ns "$ns" '[.[] | select(.path | startswith("/api/v5/"))] | length')
	[ "${b:-0}" -gt 0 ] && ok "R6 $ns: the EMQX plugin reached the (fake) EMQX API" || bad "R6 $ns: no EMQX API call"
	if r5; then
		b=$(k -n teknoir-system get appproject "$ns" -o json | jq -c '[.spec.sourceRepos, (.spec.clusterResourceWhitelist // [])]')
		[ "$b" = "$(jq -nc --arg r "$REPO" '[[$r], []]')" ] && ok "R7 $ns: AppProject sourceRepos [$REPO], no cluster whitelist" || bad "R7 $ns: AppProject $b"
		b=$(k -n teknoir-system get applications -o json | jq -r --arg ns "$ns" --arg r "$REPO" --arg v "$VERSION" '[.items[] | select(.spec.project == $ns)
			| select(.spec.source.repoURL != $r or .spec.source.targetRevision != $v
			  or ((.spec.syncPolicy.syncOptions // []) | index("RespectIgnoreDifferences=true") | not)) | .metadata.name] | join(" ")')
		[ -z "$b" ] && ok "R7 $ns: Applications on $REPO $VERSION with RespectIgnoreDifferences=true" || bad "R7 $ns: Applications not on repo/version/syncOption: $b"
		b=$(k -n "$ns" get requestauthentication jwt-policy -o jsonpath='{.spec.jwtRules[0].issuer} {.spec.jwtRules[0].jwksUri}')
		[ "$b" = "$ISSUER $JWKS" ] && ok "R7 $ns: RequestAuthentication issuer/jwksUri from OIDC_ISSUER (and OIDC_JWKS_URI or its default)" || bad "R7 $ns: RequestAuthentication '$b', want '$ISSUER $JWKS'"
		# istiod resolves jwksUri from istio-system without a sidecar: only a
		# public https:// URL works (this cluster has no istiod to prove it).
		case ${b#* } in
		https://*.svc/* | https://*.svc:* | https://*.cluster.local/* | https://*.cluster.local:*) bad "R7 $ns: jwksUri ${b#* } is cluster-internal" ;;
		https://*) ok "R7 $ns: jwksUri ${b#* } is a public https:// URL" ;;
		*) bad "R7 $ns: jwksUri ${b#* } is not https://" ;;
		esac
	else
		skp "R7 $ns: --legacy (AppProject $(k -n teknoir-system get appproject "$ns" -o jsonpath='{.spec.sourceRepos}'), issuer $(k -n "$ns" get requestauthentication jwt-policy -o jsonpath='{.spec.jwtRules[0].issuer}'))"
	fi
}
check_profile teknoir-default "$DEFAULT_OWNER"
check_profile rbac-test rbac-owner@example.com
r13
r14

# --- R8-R10 User ------------------------------------------------------------------------
echo "== R8-R10 User"
k apply -f - >/dev/null <<'EOF'
apiVersion: teknoir.org/v1
kind: User
metadata: {name: rbac-user}
spec:
  email: rbac.user@example.com
  display_name: Rbac User
  enabled: true
  claim_set: [{name: owner, namespace: rbac-test}]
EOF
RB=user-rbac-user-teknoir-role-binding AP=user-rbac-user-teknoir-authorization-policy
wait_for 120 k -n rbac-test get rolebinding "$RB" && ok "R8 RoleBinding rbac-test/$RB" || bad "R8 no RoleBinding $RB"
b=$(k -n rbac-test get rolebinding "$RB" -o jsonpath='{.roleRef.name} {.subjects[0].kind}/{.subjects[0].name}' 2>/dev/null)
[ "$b" = "teknoir-admin User/rbac.user@example.com" ] && ok "R8 $RB: teknoir-admin for User/rbac.user@example.com" || bad "R8 $RB: '$b'"
wait_for 60 k -n rbac-test get authorizationpolicies.security.istio.io "$AP" && ok "R8 AuthorizationPolicy rbac-test/$AP" || bad "R8 no AuthorizationPolicy $AP"
wait_for 120 has_finalizer user rbac-user user-finalizer && ok "R8 User reconciled to completion (user-finalizer)" || bad "R8 User never completed a reconcile"
kc_id=$(fake_calls | jq -r '[.[] | select(.method == "POST" and (.path | test("^/auth/admin/realms/[^/]+/users$")))][0].user // ""')
[ -n "$kc_id" ] && ok "R8 Keycloak user created ($kc_id)" || bad "R8 no Keycloak user created"
b=$(fake_calls | jq -c --arg id "$kc_id" '[.[] | select(.user == $id and (.path | endswith("/reset-password"))) | .temporary]')
[ "$b" = "[true]" ] && ok "R8 one temporary password set in Keycloak" || bad "R8 reset-password calls (temporary flags): $b"
SECRET=user-initial-password-rbac-user
pw_status_len=$(k get user rbac-user -o json | jq -r '.status.set_initial_password // "" | length')
if r5; then
	if k -n teknoir-user-credentials get secret "$SECRET" >/dev/null 2>&1; then
		ok "R8 K1 Secret teknoir-user-credentials/$SECRET"
		b=$(k -n teknoir-user-credentials get secret "$SECRET" -o json | jq -r '[.metadata.labels["teknoir.org/user"], .metadata.labels["teknoir.org/purpose"],
			(.metadata.ownerReferences[0] | "\(.kind)/\(.name)"), ((.data.password // "") | length > 0)] | join(" ")')
		[ "$b" = "rbac-user initial-password User/rbac-user true" ] && ok "R8 K1 Secret labels, ownerReference, key password" || bad "R8 K1 Secret: $b"
		exp=$(k -n teknoir-user-credentials get secret "$SECRET" -o jsonpath='{.metadata.annotations.teknoir\.org/expires-at}')
		exp_s=$(date -d "$exp" +%s 2>/dev/null || echo 0)
		[ "$exp_s" -gt "$(date +%s)" ] && ok "R8 K1 Secret expires-at $exp (future)" || bad "R8 K1 Secret expires-at '$exp'"
	else
		bad "R8 no K1 Secret teknoir-user-credentials/$SECRET"
	fi
	[ "$pw_status_len" = 0 ] && ok "R8 no status.set_initial_password" || bad "R8 status.set_initial_password is set"
else
	skp "R8 K1 Secret: --legacy (status.set_initial_password set: $([ "$pw_status_len" -gt 0 ] && echo yes || echo no))"
fi
# keep the temporary password (harness only, never printed) for the leak check
if r5; then
	PW=$(k -n teknoir-user-credentials get secret "$SECRET" -o go-template='{{index .data "password" | base64decode}}' 2>/dev/null || true)
else
	PW=$(k get user rbac-user -o jsonpath='{.status.set_initial_password}' 2>/dev/null || true)
fi

k patch user rbac-user --type=merge -p '{"spec":{"claim_set":null}}' >/dev/null
wait_for 90 sh -c "! kubectl --context $CTX -n rbac-test get rolebinding $RB" && ok "R9 claim_set removed: RoleBinding revoked" || bad "R9 RoleBinding $RB still there"
wait_for 60 sh -c "! kubectl --context $CTX -n rbac-test get authorizationpolicies.security.istio.io $AP" && ok "R9 claim_set removed: AuthorizationPolicy revoked" || bad "R9 AuthorizationPolicy $AP still there"

k delete user rbac-user --wait=false >/dev/null
wait_for 90 sh -c "! kubectl --context $CTX get user rbac-user" && ok "R10 User deleted (finalizer ran)" || bad "R10 User rbac-user still there"
b=$(fake_calls | jq -r --arg id "$kc_id" '[.[] | select(.method == "DELETE" and .user == $id)] | length')
[ "${b:-0}" -ge 1 ] && ok "R10 Keycloak user deleted" || bad "R10 no Keycloak delete for $kc_id"
if r5; then
	wait_for 60 sh -c "! kubectl --context $CTX -n teknoir-user-credentials get secret $SECRET" && ok "R10 K1 Secret gone" || bad "R10 K1 Secret $SECRET still there"
else
	skp "R10 K1 Secret: --legacy"
fi

# --- R11 Profile deletion ------------------------------------------------------------------
echo "== R11 Profile deletion"
apps() { k -n teknoir-system get applications -o json | jq -r '[.items[] | select(.spec.project == "rbac-test")] | "\(length) \([.[] | select(.metadata.deletionTimestamp == null)] | length)"'; }
k delete profile rbac-test --wait=false >/dev/null
wait_for 120 sh -c "kubectl --context $CTX -n teknoir-system get applications -o json | jq -e '[.items[] | select(.spec.project == \"rbac-test\" and .metadata.deletionTimestamp == null)] | length == 0'" &&
	ok "R11 every rbac-test Application deleted ($(apps | cut -d' ' -f1) waiting on ArgoCD's finalizer)" || bad "R11 rbac-test Applications not deleted (total, live: $(apps))"
logs profile-controller >"$WORK/pc-deletion.log"
if grep -Eq 'Deleting resource.*rbac-test-|rbac-test-.*Deleting resource' "$WORK/pc-deletion.log"; then ok "R11 the controller deleted them itself (RevokePlugins)"; else bad "R11 no 'Deleting resource' for rbac-test in the profile-controller log"; fi
for a in $(k -n teknoir-system get applications -o json | jq -r '.items[] | select(.spec.project == "rbac-test") | .metadata.name'); do
	k -n teknoir-system patch application "$a" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
done
wait_for 60 sh -c "kubectl --context $CTX -n teknoir-system get applications -o json | jq -e '[.items[] | select(.spec.project == \"rbac-test\")] | length == 0'" &&
	ok "R11 Applications gone" || bad "R11 Applications left: $(apps)"
wait_for 90 sh -c "! kubectl --context $CTX get profile rbac-test" && ok "R11 Profile rbac-test gone" || bad "R11 Profile rbac-test still there"
wait_for 60 sh -c "! kubectl --context $CTX -n teknoir-system get appproject rbac-test" && ok "R11 AppProject rbac-test gone" || bad "R11 AppProject rbac-test still there"
wait_for 120 sh -c "! kubectl --context $CTX get namespace rbac-test" && ok "R11 namespace rbac-test gone" || bad "R11 namespace rbac-test: $(k get namespace rbac-test -o jsonpath='{.status.phase}' 2>&1)"

# --- R12 logs ------------------------------------------------------------------------------
echo "== R12 logs"
for d in user-controller profile-controller; do
	logs "$d" >"$WORK/$d.log"
	n=$(grep -ci 'forbidden' "$WORK/$d.log" || true)
	[ "$n" = 0 ] && ok "R12 $d log: no 'forbidden' ($(wc -l <"$WORK/$d.log") lines)" || { bad "R12 $d log: $n 'forbidden' lines"; grep -i forbidden "$WORK/$d.log" | head -5 | cut -c1-300; }
	n=$(grep -ciE 'failed to wait for caches to sync|timed out waiting for cache|Timeout: failed waiting' "$WORK/$d.log" || true)
	[ "$n" = 0 ] && ok "R12 $d log: no cache-sync timeout" || bad "R12 $d log: $n cache-sync timeouts"
done
if [ -n "${PW:-}" ]; then
	if grep -qF -- "$PW" "$WORK/user-controller.log" "$WORK/profile-controller.log"; then bad "R12 the temporary password appears in a controller log"; else ok "R12 the temporary password appears in no log"; fi
else
	bad "R12 no temporary password was captured for the leak check"
fi
unset PW

summary
