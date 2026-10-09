#!/usr/bin/env bash
# SC2015: `check && ok || bad` is intended (ok/bad always succeed).
# shellcheck disable=SC2015
# Render test of the user-controller chart (no cluster; not packaged:
# .helmignore tests/).
#
#   charts/user-controller/tests/render-test.sh
#
# Renders the chart as ArgoCD does (release user-controller, namespace
# teknoir-system) and checks:
#   U1 the chart renders; no duplicate YAML keys
#   U2 no binding to cluster-admin/admin/edit/view; no '*' in any rule; the
#      only ClusterRoleBinding binds the chart's own ClusterRole
#   U3 the ClusterRole is exactly the SEC-C6 rule set
#   U4 Role leases in teknoir-system; Secret Role in the credentials
#      namespace only, get/create/update/delete (no list/watch); every
#      binding's subject is the controller's ServiceAccount
#   U5 Namespace teknoir-user-credentials, Prune=false,Delete=false
#   U6 ConfigMap USER_CREDENTIALS_NAMESPACE and INITIAL_PASSWORD_TTL (K1);
#      a credentials.namespace override reaches the Namespace, the Role,
#      its binding and the ConfigMap
#   U7 a shared or invalid credentials.namespace fails the render
#   U8 image: '<immutable tag>@sha256:<64 hex>' (K5) or the WP-UC
#      placeholder (WARN), pullPolicy IfNotPresent
#   U9 kubeconform -strict: built-in kinds (schema cache under
#      RENDER_CACHE) and the chart's CRDs (User, Claim, ClaimSet); SKIP
#      without kubeconform
#   U10 admission policy user-controller-teamspace-access: bound with Deny
#      by exactly one binding of the same name (the name the OPERATE
#      break-glass deletes), failurePolicy Fail, matched only on the controller's ServiceAccount;
#      it matches every kind the ClusterRole lets the controller write
#      (except events and its Users); its reserved namespaces equal the
#      profile-controller chart's (plus an overridden credentials namespace,
#      U6); admissionPolicies.enabled=false renders none
# Requires helm, yq (mikefarah v4), jq; kubeconform optional.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CHART=$(cd "$HERE/.." && pwd)
KUBE_VERSION=${KUBE_VERSION:-1.33.5}
RENDER_CACHE=${RENDER_CACHE:-$HOME/.cache/teknoir-render}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0 fail=0 warn=0
ok() { echo "PASS $*"; pass=$((pass + 1)); }
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
note() { echo "WARN $*"; warn=$((warn + 1)); }

render() { helm template user-controller "$CHART" --namespace teknoir-system --include-crds --kube-version "$KUBE_VERSION" "$@"; }
json() { yq -o=json -I=0 'select(. != null)' "$1" | jq -s .; }

# --- U1 -----------------------------------------------------------------------
if render >"$WORK/r.yaml" 2>"$WORK/err"; then ok "U1 renders"; else bad "U1 render: $(cat "$WORK/err")"; exit 1; fi
json "$WORK/r.yaml" >"$WORK/r.json"
# Duplicate mapping keys: yq keeps the last silently, kubectl strict decoding does not.
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
); then ok "U1 no duplicate YAML keys"; else bad "U1 $dups"; fi

# --- U2 -----------------------------------------------------------------------
b=$(jq -r '[.[] | select(.kind == "ClusterRoleBinding" or .kind == "RoleBinding")
	| select(.roleRef.name as $r | ["cluster-admin", "admin", "edit", "view"] | index($r))
	| "\(.kind)/\(.metadata.name) -> \(.roleRef.name)"] | join(", ")' "$WORK/r.json")
[ -z "$b" ] && ok "U2 no binding to a built-in admin role" || bad "U2 bindings to built-in roles: $b"
b=$(jq -r '[.[] | select(.kind == "ClusterRole" or .kind == "Role") | .metadata.name as $n
	| .rules[]? | select(((.apiGroups // []) + (.resources // []) + (.verbs // [])) | index("*"))
	| $n] | unique | join(", ")' "$WORK/r.json")
[ -z "$b" ] && ok "U2 no '*' in any rule" || bad "U2 '*' in rules of: $b"
b=$(jq -r '[.[] | select(.kind == "ClusterRoleBinding") | "\(.metadata.name)->\(.roleRef.kind)/\(.roleRef.name)"] | join(" ")' "$WORK/r.json")
[ "$b" = "user-controller->ClusterRole/user-controller" ] && ok "U2 one ClusterRoleBinding, to ClusterRole user-controller" || bad "U2 ClusterRoleBindings: $b"

# --- U3 -----------------------------------------------------------------------
# rules normalised: sorted fields, sorted rule list
norm='map({apiGroups: ((.apiGroups // []) | sort), resources: ((.resources // []) | sort),
	resourceNames: ((.resourceNames // []) | sort), verbs: ((.verbs // []) | sort)}) | sort'
want=$(jq -c "$norm" <<'EOF'
[
 {"apiGroups":["teknoir.org"],"resources":["users"],"verbs":["get","list","watch","update","patch"]},
 {"apiGroups":["teknoir.org"],"resources":["users/status"],"verbs":["get","update","patch"]},
 {"apiGroups":["teknoir.org"],"resources":["users/finalizers"],"verbs":["update"]},
 {"apiGroups":["teknoir.org"],"resources":["claims","claimsets","profiles"],"verbs":["get","list","watch"]},
 {"apiGroups":["rbac.authorization.k8s.io"],"resources":["rolebindings"],"verbs":["get","list","watch","create","update","patch","delete"]},
 {"apiGroups":["rbac.authorization.k8s.io"],"resources":["clusterroles"],"resourceNames":["teknoir-admin","teknoir-edit","teknoir-view"],"verbs":["bind"]},
 {"apiGroups":["security.istio.io"],"resources":["authorizationpolicies"],"verbs":["get","list","watch","create","update","patch","delete"]},
 {"apiGroups":[""],"resources":["events"],"verbs":["create","patch"]}
]
EOF
)
have=$(jq -c ".[] | select(.kind == \"ClusterRole\" and .metadata.name == \"user-controller\") | .rules | $norm" "$WORK/r.json")
[ "$have" = "$want" ] && ok "U3 ClusterRole user-controller = SEC-C6 rules" || bad "U3 ClusterRole rules differ: $have"

# --- U4 -----------------------------------------------------------------------
role_rules() { jq -c --arg ns "$1" --arg n "$2" ".[] | select(.kind == \"Role\" and .metadata.namespace == \$ns and .metadata.name == \$n) | .rules | $norm" "$WORK/r.json"; }
want=$(jq -c "$norm" <<<'[{"apiGroups":["coordination.k8s.io"],"resources":["leases"],"verbs":["get","list","watch","create","update","patch","delete"]}]')
[ "$(role_rules teknoir-system user-controller-leader-election)" = "$want" ] && ok "U4 leader-election Role (leases) in teknoir-system" || bad "U4 leader-election Role: $(role_rules teknoir-system user-controller-leader-election)"
want=$(jq -c "$norm" <<<'[{"apiGroups":[""],"resources":["secrets"],"verbs":["get","create","update","delete"]}]')
[ "$(role_rules teknoir-user-credentials user-controller-credentials)" = "$want" ] && ok "U4 credentials Role: secrets get/create/update/delete only" || bad "U4 credentials Role: $(role_rules teknoir-user-credentials user-controller-credentials)"
# (teknoir-kubernetes-edit, aggregated into the users' teknoir-edit, is not
# the controller's.)
b=$(jq -r '[.[] | select(.kind == "Role" or .kind == "ClusterRole") | select(.metadata.name | startswith("user-controller"))
	| .metadata.name as $n | .rules[]? | select((.resources // []) | index("secrets")) | $n] | unique | join(" ")' "$WORK/r.json")
[ "$b" = "user-controller-credentials" ] && ok "U4 no other controller rule mentions secrets" || bad "U4 controller roles with secrets: $b"
b=$(jq -r '[.[] | select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding")
	| select(.metadata.name | startswith("user-controller"))
	| select(.subjects != [{"kind":"ServiceAccount","name":"user-controller","namespace":"teknoir-system"}]) | .metadata.name] | join(" ")' "$WORK/r.json")
[ -z "$b" ] && ok "U4 every binding's subject is SA teknoir-system/user-controller" || bad "U4 bindings with other subjects: $b"
b=$(jq -r '[.[] | select(.kind == "RoleBinding") | "\(.metadata.namespace)/\(.metadata.name)->\(.roleRef.kind)/\(.roleRef.name)"] | sort | join(" ")' "$WORK/r.json")
[ "$b" = "teknoir-system/user-controller-leader-election->Role/user-controller-leader-election teknoir-user-credentials/user-controller-credentials->Role/user-controller-credentials" ] \
	&& ok "U4 RoleBindings bind the Roles in their namespaces" || bad "U4 RoleBindings: $b"

# --- U5 -----------------------------------------------------------------------
b=$(jq -r '.[] | select(.kind == "Namespace" and .metadata.name == "teknoir-user-credentials") | .metadata.annotations["argocd.argoproj.io/sync-options"] // "none"' "$WORK/r.json")
[ "$b" = "Prune=false,Delete=false" ] && ok "U5 Namespace teknoir-user-credentials with Prune=false,Delete=false" || bad "U5 credentials Namespace: '${b:-missing}'"

# --- U6 -----------------------------------------------------------------------
cm() { jq -r --arg k "$2" '.[] | select(.kind == "ConfigMap" and .metadata.name == "user-controller-config") | .data[$k] // "unset"' "$1"; }
[ "$(cm "$WORK/r.json" USER_CREDENTIALS_NAMESPACE)" = teknoir-user-credentials ] && ok "U6 USER_CREDENTIALS_NAMESPACE=teknoir-user-credentials" || bad "U6 USER_CREDENTIALS_NAMESPACE=$(cm "$WORK/r.json" USER_CREDENTIALS_NAMESPACE)"
[ "$(cm "$WORK/r.json" INITIAL_PASSWORD_TTL)" = 72h ] && ok "U6 INITIAL_PASSWORD_TTL=72h" || bad "U6 INITIAL_PASSWORD_TTL=$(cm "$WORK/r.json" INITIAL_PASSWORD_TTL)"
render --set credentials.namespace=uc-creds --set credentials.initialPasswordTTL=24h >"$WORK/o.yaml"
json "$WORK/o.yaml" >"$WORK/o.json"
b=$(jq -r '[.[] | select(.metadata.namespace == "uc-creds" or (.kind == "Namespace" and .metadata.name == "uc-creds")) | .kind] | sort | join(",")' "$WORK/o.json")
if [ "$b" = "Namespace,Role,RoleBinding" ] && [ "$(cm "$WORK/o.json" USER_CREDENTIALS_NAMESPACE)" = uc-creds ] && [ "$(cm "$WORK/o.json" INITIAL_PASSWORD_TTL)" = 24h ] \
	&& ! yq 'select(.kind != "ValidatingAdmissionPolicy")' "$WORK/o.yaml" | grep -q teknoir-user-credentials \
	&& yq 'select(.kind == "ValidatingAdmissionPolicy") | .spec.variables[] | select(.name == "reserved") | .expression' "$WORK/o.yaml" | grep -q '"uc-creds"'; then
	ok "U6 credentials.namespace/initialPasswordTTL overrides reach Namespace, Role, RoleBinding, ConfigMap and the reserved namespaces"
else
	bad "U6 override: objects in uc-creds: $b"
fi

# --- U7 -----------------------------------------------------------------------
for v in teknoir-system teknoir-auth kube-system default Bad_Name ""; do
	if render --set "credentials.namespace=$v" >/dev/null 2>&1; then bad "U7 credentials.namespace='$v' renders"; else ok "U7 credentials.namespace='$v' refused"; fi
done
if render --set credentials.initialPasswordTTL= >/dev/null 2>&1; then bad "U7 empty initialPasswordTTL renders"; else ok "U7 empty initialPasswordTTL refused"; fi

# --- U8 -----------------------------------------------------------------------
img=$(jq -r '.[] | select(.kind == "Deployment") | .spec.template.spec.containers[0] | "\(.image) \(.imagePullPolicy)"' "$WORK/r.json")
ref=${img% *} policy=${img##* }
tag=${ref##*/}; tag=${tag#*:}; tag=${tag%@*}
if [[ "$ref" == ghcr.io/teknoir/user-controller:*@sha256:* && "${ref##*@sha256:}" =~ ^[0-9a-f]{64}$ ]] \
	&& [[ "$tag" =~ ^sha-[0-9a-f]{7,}$ || "$tag" =~ ^[a-z0-9.-]+-[0-9]{8}-[0-9]{6}$ || "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	ok "U8 image pinned: $ref"
elif [[ "$tag" == sha-PLACEHOLDER-WP-UC ]]; then
	note "U8 image is the WP-UC placeholder ($ref): pin the r5 build before release"
else
	bad "U8 image not '<immutable tag>@sha256:<digest>': $ref"
fi
[ "$policy" = IfNotPresent ] && ok "U8 pullPolicy IfNotPresent" || bad "U8 pullPolicy $policy"

# --- U9 -----------------------------------------------------------------------
if command -v kubeconform >/dev/null; then
	mkdir -p "$WORK/schemas" "$RENDER_CACHE/kubeconform"
	# CRD -> JSON schema per served version, strict (no unknown fields) where the
	# CRD lists properties and does not preserve unknown fields.
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
	if kubeconform -strict -summary -kubernetes-version "$KUBE_VERSION" -cache "$RENDER_CACHE/kubeconform" \
		-schema-location default -schema-location "$WORK/schemas/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json" \
		-skip CustomResourceDefinition "$WORK/r.yaml" >"$WORK/kc" 2>&1; then
		ok "U9 kubeconform -strict: $(tail -1 "$WORK/kc")"
	else
		bad "U9 kubeconform: $(grep -v '^Summary' "$WORK/kc" | head -5 | tr '\n' ' ') $(tail -1 "$WORK/kc")"
	fi
else
	echo "SKIP U9 kubeconform not installed"
fi

# --- U10 ----------------------------------------------------------------------
SA_USER=system:serviceaccount:teknoir-system:user-controller
v=$(jq -c '.[] | select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "user-controller-teamspace-access")' "$WORK/r.json")
if [ -n "$v" ]; then
	b=$(jq -r '"\(.spec.failurePolicy) \(.spec.matchConditions | map(.expression) | join(";"))"' <<<"$v")
	[ "$b" = "Fail request.userInfo.username == \"$SA_USER\"" ] && ok "U10 failurePolicy Fail, only requests by $SA_USER" || bad "U10 policy: $b"
	b=$(jq -r '[.[] | select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "user-controller-teamspace-access") | .spec.validationActions | join(",")] | join(" ")' "$WORK/r.json")
	[ "$b" = Deny ] && ok "U10 bound with validationActions [Deny]" || bad "U10 bindings: '$b'"
	b=$(jq -r '[.[] | select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.policyName == "user-controller-teamspace-access") | .metadata.name] | join(" ")' "$WORK/r.json")
	[ "$b" = user-controller-teamspace-access ] && ok "U10 its one binding is named user-controller-teamspace-access (OPERATE break-glass)" || bad "U10 binding names '$b', the break-glass deletes user-controller-teamspace-access"
	b=$(jq -r '[.spec.validations[] | select(.reason != "Forbidden" or (.message // "") == "")] | length' <<<"$v")
	[ "$b" = 0 ] && ok "U10 every validation has a message and reason Forbidden" || bad "U10 $b validations without message/Forbidden"
	writes=$(jq -r '[.[] | select(.kind == "ClusterRole" and .metadata.name == "user-controller")
		| .rules[] | select(.verbs | any(. == "create" or . == "update" or . == "patch" or . == "delete"))
		| .apiGroups[] as $g | .resources[] | "\($g)/\(.)"]
		| map(select(. != "/events" and (startswith("teknoir.org/users") | not))) | unique | join(" ")' "$WORK/r.json")
	matched=$(jq -r '.spec.matchConstraints.resourceRules | [.[] | select(.operations | (index("CREATE") and index("UPDATE") and index("DELETE")))
		| .apiGroups[] as $g | .resources[] | "\($g)/\(.)"] | unique | join(" ")' <<<"$v")
	[ -n "$writes" ] && [ "$writes" = "$matched" ] && ok "U10 every kind the ClusterRole lets it write is matched: $writes" || bad "U10 ClusterRole writes '$writes' != policy matches '$matched'"
	b=$(jq -r '.spec.variables[] | select(.name == "reserved") | .expression' <<<"$v" | jq -r 'sort | join(" ")')
	# (the credentials namespace is in both: teknoir-user-credentials by default)
	pc=$(helm template profile-controller "$CHART/../profile-controller" --namespace teknoir-system --kube-version "$KUBE_VERSION" |
		yq -r 'select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "profile-controller-teamspaces") | .spec.variables[] | select(.name == "reserved") | .expression' | jq -r 'sort | join(" ")')
	[ -n "$b" ] && [ "$b" = "$pc" ] && ok "U10 reserved namespaces = the profile-controller chart's ($b)" || bad "U10 reserved namespaces '$b', profile-controller '$pc'"
else
	bad "U10 no ValidatingAdmissionPolicy user-controller-teamspace-access"
fi
render --set admissionPolicies.enabled=false >"$WORK/np.yaml"
b=$(yq 'select(.kind == "ValidatingAdmissionPolicy*") | .metadata.name' "$WORK/np.yaml" | grep -vc '^---$' || true)
[ "$b" = 0 ] && ok "U10 admissionPolicies.enabled=false renders no policy" || bad "U10 admissionPolicies.enabled=false renders $b policy objects"

echo
echo "user-controller render-test: $pass passed, $fail failed, $warn warnings"
[ "$fail" -eq 0 ]
