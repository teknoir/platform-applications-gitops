#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# Render test of the profile-controller chart (no cluster; not packaged:
# .helmignore tests/).
#
#   charts/profile-controller/tests/render-test.sh
#
# Renders the chart as ArgoCD does (release profile-controller, namespace
# teknoir-system) and checks:
#   P1 the chart renders; no duplicate YAML keys
#   P2 RBAC (SEC-C7): no binding to a built-in admin role, no '*', one
#      ClusterRoleBinding to the chart's ClusterRole with exactly the SEC-C7
#      rules, Role profile-controller-argocd in teknoir-system (argoproj
#      create/update/patch/delete), no leader-election Role
#   P3 ConfigMap K2 keys: PLUGIN_CHART_REPO (= app-of-apps repoURL, no
#      oci://), PLUGIN_CHART_VERSION, OIDC_ISSUER; OIDC_JWKS_URI unset, so
#      the effective jwksUri is the public <issuer>/protocol/openid-connect/
#      certs that istiod can fetch; an explicit https:// value is rendered
#   P4 Profile teknoir-default (K3): owner config.admin, kind User,
#      Prune=false,Delete=false, sync-wave 1, no spec.plugins
#   P5 profiles variations: owner override lower-cased, resourceQuotaSpec
#      passed through, `profiles: []` renders none, owner without
#      config.admin
#   P6 refused: empty owner, non-DNS-1123 names, reserved names, kube-*,
#      duplicates, spec.plugins or unknown keys, non-map entries, oci://,
#      an http:// or cluster-internal jwksUri/issuer
#   P7 empty K2 values render no K2 keys (the other env branches)
#   P8 image: '<immutable tag>@sha256:<64 hex>' (K5) or the WP-PC
#      placeholder (WARN), pullPolicy IfNotPresent
#   P9 kubeconform -strict, with the Profile checked against the chart's
#      CRD (unknown fields rejected; a bad Profile is caught); SKIP without
#      kubeconform
#   P10 admission policies: profile-controller-teamspaces and -argocd, each
#      bound with Deny by exactly one binding of the same name (the name the
#      OPERATE break-glass deletes), failurePolicy Fail, matched only on the controller's
#      ServiceAccount; every kind the RBAC lets it write (except events and
#      its Profiles) is matched by one of them; the AppProject/Application
#      repository is PLUGIN_CHART_REPO (the compiled default when empty);
#      the reserved list is the one the Profile template refuses;
#      admissionPolicies.enabled=false renders none
# Requires helm, yq (mikefarah v4), jq, python3 (PyYAML); kubeconform
# optional.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
AOA_VALUES=${AOA_VALUES:-$CHART/../app-of-apps/values.yaml}
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
RENDER_CACHE=${RENDER_CACHE:-$HOME/.cache/teknoir-render}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0 warn=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
note() { echo "WARN $*"; warn=$((warn + 1)); }

render() { helm template profile-controller "$CHART" --namespace teknoir-system --include-crds --kube-version "$KUBE_VERSION" "$@"; }
json() { yq -o=json -I=0 'select(. != null)' "$1" | jq -s .; }
# values <name>: write stdin to $WORK/<name>.yaml, print the path
values() { cat >"$WORK/$1.yaml"; echo "$WORK/$1.yaml"; }
refused() { # refused <label> <helm args...>
	local label=$1; shift
	if render "$@" >/dev/null 2>"$WORK/err"; then bad "P6 $label: renders"; else ok "P6 $label: refused: $(sed -n 's/^Error: execution error at ([^)]*): //p' "$WORK/err" | head -1 | cut -c1-90)"; fi
}

# --- P1 -----------------------------------------------------------------------
if render >"$WORK/r.yaml" 2>"$WORK/err"; then ok "P1 renders"; else bad "P1 render: $(cat "$WORK/err")"; exit 1; fi
json "$WORK/r.yaml" >"$WORK/r.json"
if dups=$(python3 - "$WORK/r.yaml" <<'EOF'
import sys, yaml
class L(yaml.SafeLoader): pass
def m(loader, node, deep=False):
    keys = [loader.construct_object(k, deep=deep) for k, _ in node.value]
    d = {k for k in keys if keys.count(k) > 1}
    if d: raise SystemExit("duplicate keys %s at line %d" % (sorted(d), node.start_mark.line + 1))
    return loader.construct_mapping(node, deep)
L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, m)
list(yaml.load_all(open(sys.argv[1]), Loader=L))
EOF
); then ok "P1 no duplicate YAML keys"; else bad "P1 $dups"; fi

# --- P2 -----------------------------------------------------------------------
norm='map({apiGroups: ((.apiGroups // []) | sort), resources: ((.resources // []) | sort),
	resourceNames: ((.resourceNames // []) | sort), verbs: ((.verbs // []) | sort)}) | sort'
b=$(jq -r '[.[] | select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
	| select(.roleRef.name as $r | ["cluster-admin", "admin", "edit", "view"] | index($r))
	| "\(.kind)/\(.metadata.name) -> \(.roleRef.name)"] | join(", ")' "$WORK/r.json")
[ -z "$b" ] && ok "P2 no binding to a built-in admin role" || bad "P2 bindings to built-in roles: $b"
b=$(jq -r '[.[] | select(.kind == "ClusterRole" or .kind == "Role") | .metadata.name as $n
	| .rules[]? | select(((.apiGroups // []) + (.resources // []) + (.verbs // [])) | index("*")) | $n] | unique | join(", ")' "$WORK/r.json")
[ -z "$b" ] && ok "P2 no '*' in any rule" || bad "P2 '*' in rules of: $b"
b=$(jq -r '[.[] | select(.kind == "ClusterRoleBinding") | "\(.metadata.name)->\(.roleRef.kind)/\(.roleRef.name)"] | join(" ")' "$WORK/r.json")
[ "$b" = "profile-controller->ClusterRole/profile-controller" ] && ok "P2 one ClusterRoleBinding, to ClusterRole profile-controller" || bad "P2 ClusterRoleBindings: $b"
want=$(jq -c "$norm" <<'EOF'
[
 {"apiGroups":["teknoir.org"],"resources":["profiles"],"verbs":["get","list","watch","update","patch"]},
 {"apiGroups":["teknoir.org"],"resources":["profiles/status"],"verbs":["get","update","patch"]},
 {"apiGroups":["teknoir.org"],"resources":["profiles/finalizers"],"verbs":["update"]},
 {"apiGroups":[""],"resources":["namespaces"],"verbs":["get","list","watch","create","update","patch"]},
 {"apiGroups":[""],"resources":["secrets","configmaps","services","serviceaccounts","resourcequotas"],"verbs":["get","list","watch","create","update","patch","delete"]},
 {"apiGroups":["apps"],"resources":["deployments","statefulsets"],"verbs":["get","list","watch"]},
 {"apiGroups":["rbac.authorization.k8s.io"],"resources":["roles"],"verbs":["get","list","watch"]},
 {"apiGroups":["rbac.authorization.k8s.io"],"resources":["rolebindings"],"verbs":["get","list","watch","create","update","patch","delete"]},
 {"apiGroups":["rbac.authorization.k8s.io"],"resources":["clusterroles"],"resourceNames":["teknoir-admin","teknoir-edit","teknoir-view"],"verbs":["bind"]},
 {"apiGroups":["security.istio.io"],"resources":["authorizationpolicies","requestauthentications"],"verbs":["get","list","watch","create","update","patch","delete"]},
 {"apiGroups":["networking.istio.io"],"resources":["virtualservices","envoyfilters"],"verbs":["get","list","watch"]},
 {"apiGroups":["helm.cattle.io"],"resources":["helmcharts"],"verbs":["get","list","watch"]},
 {"apiGroups":["argoproj.io"],"resources":["applications","appprojects"],"verbs":["get","list","watch"]},
 {"apiGroups":[""],"resources":["events"],"verbs":["create","patch"]}
]
EOF
)
have=$(jq -c ".[] | select(.kind == \"ClusterRole\" and .metadata.name == \"profile-controller\") | .rules | $norm" "$WORK/r.json")
[ "$have" = "$want" ] && ok "P2 ClusterRole profile-controller = SEC-C7 rules" || bad "P2 ClusterRole rules differ: $have"
want=$(jq -c "$norm" <<<'[{"apiGroups":["argoproj.io"],"resources":["applications","appprojects"],"verbs":["create","update","patch","delete"]}]')
have=$(jq -c ".[] | select(.kind == \"Role\" and .metadata.namespace == \"teknoir-system\" and .metadata.name == \"profile-controller-argocd\") | .rules | $norm" "$WORK/r.json")
[ "$have" = "$want" ] && ok "P2 Role teknoir-system/profile-controller-argocd: argoproj create/update/patch/delete" || bad "P2 argocd Role: ${have:-missing}"
b=$(jq -r '[.[] | select(.kind == "Role" or .kind == "RoleBinding") | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)"] | sort | join(" ")' "$WORK/r.json")
[ "$b" = "Role/teknoir-system/profile-controller-argocd RoleBinding/teknoir-system/profile-controller-argocd" ] \
	&& ok "P2 no leader-election Role (the controller runs none)" || bad "P2 Roles/RoleBindings: $b"
b=$(jq -r '[.[] | select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
	| select(.subjects != [{"kind":"ServiceAccount","name":"profile-controller","namespace":"teknoir-system"}]) | .metadata.name] | join(" ")' "$WORK/r.json")
[ -z "$b" ] && ok "P2 every binding's subject is SA teknoir-system/profile-controller" || bad "P2 bindings with other subjects: $b"

# --- P3 -----------------------------------------------------------------------
cm() { jq -r --arg k "$2" '.[] | select(.kind == "ConfigMap" and .metadata.name == "profile-controller-config") | .data[$k] // "<unset>"' "$1"; }
aoa_repo=$(yq -r .repoURL "$AOA_VALUES")
repo=$(cm "$WORK/r.json" PLUGIN_CHART_REPO)
[ "$repo" = "$aoa_repo" ] && ok "P3 PLUGIN_CHART_REPO=$repo (= app-of-apps repoURL)" || bad "P3 PLUGIN_CHART_REPO=$repo, app-of-apps repoURL=$aoa_repo"
for kv in PLUGIN_CHART_VERSION=0.0.101 \
	OIDC_ISSUER=https://auth.teknoir.airgapped/auth/realms/teknoir \
	OIDC_JWKS_URI='<unset>' \
	ADMIN=anders.aslund@teknoir.ai DOMAIN=teknoir.airgapped; do
	v=$(cm "$WORK/r.json" "${kv%%=*}")
	[ "$v" = "${kv#*=}" ] && ok "P3 ${kv%%=*}=$v" || bad "P3 ${kv%%=*}=$v, want ${kv#*=}"
done
# The jwksUri the controller writes (OIDC_JWKS_URI, else <issuer>/protocol/
# openid-connect/certs) is resolved by istiod, from istio-system without a
# sidecar: it must be the public URL the platform RequestAuthentications
# (backstage) already use, never the in-mesh keycloak-http Service.
jwks=$(cm "$WORK/r.json" OIDC_JWKS_URI); [ "$jwks" = '<unset>' ] && jwks="$(cm "$WORK/r.json" OIDC_ISSUER)/protocol/openid-connect/certs"
[ "$jwks" = https://auth.teknoir.airgapped/auth/realms/teknoir/protocol/openid-connect/certs ] \
	&& ok "P3 effective jwksUri $jwks (public, fetchable by istiod)" || bad "P3 effective jwksUri $jwks"
f=$(values jwks <<<'config: {oidcJwksUri: "https://auth.example.com/auth/realms/x/protocol/openid-connect/certs"}')
render -f "$f" >"$WORK/j.yaml" && json "$WORK/j.yaml" >"$WORK/j.json"
[ "$(cm "$WORK/j.json" OIDC_JWKS_URI)" = https://auth.example.com/auth/realms/x/protocol/openid-connect/certs ] \
	&& ok "P3 an explicit https:// oidcJwksUri is rendered" || bad "P3 explicit oidcJwksUri: $(cm "$WORK/j.json" OIDC_JWKS_URI)"
# The args still name only the flags every image knows.
b=$(jq -r '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0].args | map(select(startswith("-"))) | join(" ")' "$WORK/r.json")
[ "$b" = "-userid-header -userid-prefix -domain -domain-prefix -istio-revision" ] && ok "P3 no new args (K2 is env only)" || bad "P3 args: $b"

# --- P4 -----------------------------------------------------------------------
p=$(jq -c '[.[] | select(.kind == "Profile")]' "$WORK/r.json")
if [ "$(jq length <<<"$p")" = 1 ] && [ "$(jq -r '.[0].metadata.name' <<<"$p")" = teknoir-default ]; then ok "P4 one Profile: teknoir-default"; else bad "P4 Profiles: $(jq -r 'map(.metadata.name) | join(",")' <<<"$p")"; fi
b=$(jq -c '.[0].spec.owner' <<<"$p")
[ "$b" = '{"apiGroup":"rbac.authorization.k8s.io","kind":"User","name":"anders.aslund@teknoir.ai"}' ] && ok "P4 owner $b" || bad "P4 owner $b"
b=$(jq -r '.[0].metadata.annotations | "\(.["argocd.argoproj.io/sync-options"]) wave=\(.["argocd.argoproj.io/sync-wave"])"' <<<"$p")
[ "$b" = "Prune=false,Delete=false wave=1" ] && ok "P4 annotations: $b" || bad "P4 annotations: $b"
b=$(jq -r '.[0].spec | keys | join(",")' <<<"$p")
[ "$b" = owner ] && ok "P4 spec has only owner (no plugins)" || bad "P4 spec keys: $b"
b=$(jq -r '.[0].apiVersion' <<<"$p")
[ "$b" = teknoir.org/v1 ] && ok "P4 apiVersion teknoir.org/v1" || bad "P4 apiVersion $b"

# --- P5 -----------------------------------------------------------------------
f=$(values multi <<'EOF'
profiles:
  - name: team-a
    owner: " Some.One@Example.COM "
  - name: team-b
    resourceQuotaSpec:
      hard:
        cpu: "8"
        requests.storage: 200Gi
EOF
)
render -f "$f" >"$WORK/m.yaml" && json "$WORK/m.yaml" >"$WORK/m.json"
b=$(jq -r '[.[] | select(.kind == "Profile") | "\(.metadata.name):\(.spec.owner.name):\(.spec.resourceQuotaSpec.hard.cpu // "-")"] | join(" ")' "$WORK/m.json")
[ "$b" = "team-a:some.one@example.com:- team-b:anders.aslund@teknoir.ai:8" ] && ok "P5 owner override lower-cased and trimmed; default owner; quota passed: $b" || bad "P5 profiles: $b"
f=$(values none <<<'profiles: []')
render -f "$f" >"$WORK/n.yaml"
[ "$(yq 'select(.kind == "Profile") | .metadata.name' "$WORK/n.yaml" | grep -vc '^---$' || true)" = 0 ] && ok "P5 profiles: [] renders no Profile" || bad "P5 profiles: [] renders a Profile"
f=$(values noadmin <<'EOF'
config:
  admin: ""
profiles:
  - name: team-c
    owner: owner@example.com
EOF
)
if render -f "$f" >"$WORK/c.yaml" 2>/dev/null && [ "$(yq 'select(.kind == "Profile") | .spec.owner.name' "$WORK/c.yaml")" = owner@example.com ]; then
	ok "P5 per-entry owner without config.admin"
else
	bad "P5 per-entry owner without config.admin"
fi

# --- P6 -----------------------------------------------------------------------
f=$(values noowner <<'EOF'
config:
  admin: ""
profiles:
  - name: team-x
EOF
)
refused "empty owner" -f "$f"
for n in Team-A team_a -team team- "$(printf 'a%.0s' $(seq 1 64))" "" default teknoir teknoir-local teknoir-cloud teknoir-online \
	teknoir-system teknoir-auth istio-system cert-manager teknoir-user-credentials kube-system kube-foo; do
	f=$(values "name" <<<"profiles: [{name: \"$n\"}]")
	refused "name '${n:0:20}'" -f "$f"
done
f=$(values dup <<<'profiles: [{name: team-a}, {name: team-a}]')
refused "duplicate name" -f "$f"
f=$(values plugins <<<'profiles: [{name: team-a, plugins: [{kind: EMQX, spec: {enabled: false}}]}]')
refused "spec.plugins declared" -f "$f"
f=$(values unknown <<<'profiles: [{name: team-a, ownr: x@example.com}]')
refused "unknown key" -f "$f"
f=$(values notmap <<<'profiles: [team-a]')
refused "non-map entry" -f "$f"
refused "oci:// plugin repo" --set config.pluginChartRepo=oci://harbor.teknoir.airgapped/teknoir
refused "in-mesh http:// jwksUri" --set config.oidcJwksUri=http://keycloak-http.teknoir-auth.svc.cluster.local/auth/realms/teknoir/protocol/openid-connect/certs
refused "https:// jwksUri on a .svc host" --set config.oidcJwksUri=https://keycloak-http.teknoir-auth.svc/auth/realms/teknoir/protocol/openid-connect/certs
refused "https:// jwksUri on a .cluster.local host" --set config.oidcJwksUri=https://keycloak.teknoir-auth.svc.cluster.local:8443/certs
refused "http:// issuer" --set config.oidcIssuer=http://auth.teknoir.airgapped/auth/realms/teknoir

# --- P7 -----------------------------------------------------------------------
f=$(values empty <<'EOF'
config:
  pluginChartRepo: ""
  pluginChartVersion: ""
  oidcIssuer: ""
  oidcJwksUri: ""
EOF
)
render -f "$f" >"$WORK/e.yaml" && json "$WORK/e.yaml" >"$WORK/e.json"
b=$(jq -r '.[] | select(.kind == "ConfigMap") | .data | keys | map(select(test("^(PLUGIN_|OIDC_)"))) | join(",")' "$WORK/e.json")
[ -z "$b" ] && ok "P7 empty K2 values render no K2 keys (compiled defaults)" || bad "P7 K2 keys rendered: $b"

# --- P8 -----------------------------------------------------------------------
img=$(jq -r '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | "\(.image) \(.imagePullPolicy)"' "$WORK/r.json")
ref=${img% *} policy=${img##* }
tag=${ref##*/}; tag=${tag#*:}; tag=${tag%@*}
if [[ "$ref" == ghcr.io/teknoir/profile-controller:*@sha256:* && "${ref##*@sha256:}" =~ ^[0-9a-f]{64}$ ]] \
	&& [[ "$tag" =~ ^sha-[0-9a-f]{7,}$ || "$tag" =~ ^[a-z0-9.-]+-[0-9]{8}-[0-9]{6}$ || "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	ok "P8 image pinned: $ref"
elif [[ "$tag" == sha-PLACEHOLDER-WP-PC ]]; then
	note "P8 image is the WP-PC placeholder ($ref): pin the r5 build before release"
else
	bad "P8 image not '<immutable tag>@sha256:<digest>': $ref"
fi
[ "$policy" = IfNotPresent ] && ok "P8 pullPolicy IfNotPresent" || bad "P8 pullPolicy $policy"

# --- P9 -----------------------------------------------------------------------
if command -v kubeconform >/dev/null; then
	mkdir -p "$WORK/schemas" "$RENDER_CACHE/kubeconform"
	jq -c '.[] | select(.kind == "CustomResourceDefinition") | .spec as $s | $s.versions[]
		| {file: "\($s.group)/\($s.names.kind | ascii_downcase)_\(.name).json",
		   schema: (.schema.openAPIV3Schema | walk(if type == "object" and has("properties")
		     and (has("additionalProperties") | not) and ((.["x-kubernetes-preserve-unknown-fields"] // false) | not)
		     then . + {additionalProperties: false} else . end))}' "$WORK/r.json" |
		while IFS= read -r line; do
			f="$WORK/schemas/$(jq -r .file <<<"$line")"
			mkdir -p "$(dirname "$f")"
			jq .schema <<<"$line" >"$f"
		done
	kc() { kubeconform -strict -summary -verbose -kubernetes-version "$KUBE_VERSION" -cache "$RENDER_CACHE/kubeconform" \
		-schema-location default -schema-location "$WORK/schemas/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
		-skip CustomResourceDefinition "$@"; }
	# every document validated except the CRDs themselves (-skip)
	if kc "$WORK/r.yaml" "$WORK/m.yaml" >"$WORK/kc" 2>&1 && ! grep ' skipped$' "$WORK/kc" | grep -vq ' CustomResourceDefinition ' \
		&& [ "$(grep -c ' - Profile .* is valid$' "$WORK/kc")" = 3 ]; then
		ok "P9 kubeconform -strict (Profiles against the CRD): $(tail -1 "$WORK/kc")"
	else
		bad "P9 kubeconform: $(grep -v '^Summary' "$WORK/kc" | head -5 | tr '\n' ' ') $(tail -1 "$WORK/kc")"
	fi
	# negative control: an unknown field in spec.owner must be rejected
	yq 'select(.kind == "Profile") | .spec.owner.team = "x"' "$WORK/r.yaml" >"$WORK/badprofile.yaml"
	if kc "$WORK/badprofile.yaml" >/dev/null 2>&1; then bad "P9 a Profile with an unknown field passes kubeconform"; else ok "P9 a Profile with an unknown field is rejected"; fi
else
	echo "SKIP P9 kubeconform not installed"
fi

# --- P10 ----------------------------------------------------------------------
vap() { jq -c --arg n "$2" '.[] | select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == $n)' "$1"; }
SA_USER=system:serviceaccount:teknoir-system:profile-controller
for n in profile-controller-teamspaces profile-controller-argocd; do
	v=$(vap "$WORK/r.json" "$n")
	if [ -z "$v" ]; then bad "P10 no ValidatingAdmissionPolicy $n"; continue; fi
	b=$(jq -r '"\(.spec.failurePolicy) \(.spec.matchConditions | map(.expression) | join(";"))"' <<<"$v")
	[ "$b" = "Fail request.userInfo.username == \"$SA_USER\"" ] && ok "P10 $n: failurePolicy Fail, only requests by $SA_USER" || bad "P10 $n: $b"
	b=$(jq -r --arg n "$n" '[.[] | select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == $n) | .spec.validationActions | join(",")] | join(" ")' "$WORK/r.json")
	[ "$b" = Deny ] && ok "P10 $n: bound with validationActions [Deny]" || bad "P10 $n bindings: '$b'"
	b=$(jq -r --arg n "$n" '[.[] | select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == $n) | .metadata.name] | join(" ")' "$WORK/r.json")
	[ "$b" = "$n" ] && ok "P10 $n: its one binding is named $n (OPERATE break-glass)" || bad "P10 $n: binding names '$b', the break-glass deletes '$n'"
	b=$(jq -r '[.spec.validations[] | select(.reason != "Forbidden" or (.message // "") == "")] | length' <<<"$v")
	[ "$b" = 0 ] && ok "P10 $n: every validation has a message and reason Forbidden" || bad "P10 $n: $b validations without message/Forbidden"
done
# RBAC write grants (group/resource) vs the kinds the policies match
writes=$(jq -r '[.[] | select(.kind == "ClusterRole" or .kind == "Role") | select(.metadata.name | startswith("profile-controller"))
	| .rules[] | select(.verbs | any(. == "create" or . == "update" or . == "patch" or . == "delete"))
	| .apiGroups[] as $g | .resources[] | "\($g)/\(.)"]
	| map(select(. != "/events" and (startswith("teknoir.org/profiles") | not))) | unique | join(" ")' "$WORK/r.json")
matched=$(jq -r '[.[] | select(.kind == "ValidatingAdmissionPolicy") | .spec.matchConstraints.resourceRules[]
	| select(.operations | (index("CREATE") and index("UPDATE") and index("DELETE")))
	| .apiGroups[] as $g | .resources[] | "\($g)/\(.)"] | unique | join(" ")' "$WORK/r.json")
[ -n "$writes" ] && [ "$writes" = "$matched" ] && ok "P10 every kind the RBAC lets it write is matched (CREATE/UPDATE/DELETE): $writes" \
	|| bad "P10 RBAC writes '$writes' != policy matches '$matched'"
var() { jq -r --arg n "$2" '.spec.variables[] | select(.name == $n) | .expression' <<<"$1"; }
v=$(vap "$WORK/r.json" profile-controller-argocd)
b=$(var "$v" repo | jq -r .)
[ "$b" = "$(cm "$WORK/r.json" PLUGIN_CHART_REPO)" ] && ok "P10 argocd policy repository = PLUGIN_CHART_REPO ($b)" || bad "P10 argocd policy repository '$b'"
v=$(vap "$WORK/e.json" profile-controller-argocd)
b=$(var "$v" repo | jq -r .)
[ "$b" = https://teknoir.github.io/profile-plugins-helm ] && ok "P10 empty pluginChartRepo: the compiled default ($b)" || bad "P10 empty pluginChartRepo: policy repository '$b'"
for n in profile-controller-teamspaces profile-controller-argocd; do
	b=$(var "$(vap "$WORK/r.json" "$n")" reserved | jq -r 'sort | join(" ")')
	want="cert-manager default istio-system teknoir teknoir-auth teknoir-cloud teknoir-local teknoir-online teknoir-system teknoir-user-credentials"
	[ "$b" = "$want" ] && ok "P10 $n: reserved names = the Profile template's" || bad "P10 $n: reserved '$b'"
done
render --set admissionPolicies.enabled=false >"$WORK/np.yaml"
b=$(yq 'select(.kind == "ValidatingAdmissionPolicy*") | .metadata.name' "$WORK/np.yaml" | grep -vc '^---$' || true)
[ "$b" = 0 ] && ok "P10 admissionPolicies.enabled=false renders no policy" || bad "P10 admissionPolicies.enabled=false renders $b policy objects"

echo
echo "profile-controller render-test: $pass passed, $fail failed, $warn warnings"
[ "$fail" -eq 0 ]
