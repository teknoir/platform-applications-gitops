#!/usr/bin/env bash
# Tests for the ZTNA (WireGuard over STUNner) GitOps changes: charts/app-of-apps (templates/ztna.yaml,
# _helpers.tpl), charts/gateway-api-crds, charts/stunner, charts/ztna, and the ztna parts of
# charts/device-controller and charts/virtual-devices. No cluster needed.
#
#   charts/ztna/tests/run.sh                 offline (kubeconform fetches the Kubernetes 1.34
#                                            JSON schemas once into its cache; the STUNner helm
#                                            dependency is pulled from https://l7mp.io/stunner)
#   ZTNA_ONLINE=1 charts/ztna/tests/run.sh   also validates Istio and Prometheus Operator objects
#                                            against the datreeio CRDs-catalog schemas
#
# The admission policies are tested against a throwaway local kube-apiserver by vap-test.sh (run
# from here when the envtest binaries exist).
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${CHART}/../.." && pwd)"
CHARTS="${REPO}/charts"
AOA="${CHARTS}/app-of-apps"
K8S_VERSION="1.34.0"
IMG_TAG="sha-0123abcd@sha256:3333333333333333333333333333333333333333333333333333333333333333"

for t in helm kubeconform python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
mkdir -p "$CACHE"

fail=0
step() { printf '\n--- %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

# ---------------------------------------------------------------- app-of-apps
step "app-of-apps: gate (values flag AND project allowlist)"
apps() { # apps FILE: sorted Application names
  python3 -I -c 'import sys, yaml; print(" ".join(sorted(d["metadata"]["name"] for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "Application")))' "$1"
}
helm template aoa "$AOA" --set project=teknoir-cloud --set ztna.enabled=false >"$TMP/aoa-off.yaml"
helm template aoa "$AOA" --set project=teknoir-cloud --set ztna.enabled=true >"$TMP/aoa-on.yaml"
cp -r "$AOA" "$TMP/aoa-nokey"
python3 -I - "$TMP/aoa-nokey/values.yaml" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s = re.sub(r"(?m)^ztna:\n  enabled: \w+\n", "", s)
assert "ztna:" not in re.sub(r"(?m)^#.*$", "", s)
open(sys.argv[1], "w").write(s)
PY
helm template aoa "$TMP/aoa-nokey" >"$TMP/aoa-nokey.yaml"
for n in gateway-api-crds stunner ztna; do
  grep -q "^  name: $n\$" "$TMP/aoa-off.yaml" && bad "ztna.enabled=false renders Application $n" || ok "ztna.enabled=false: no Application $n"
  [[ " $(apps "$TMP/aoa-on.yaml") " == *" $n "* ]] && ok "ztna.enabled=true on teknoir-cloud: Application $n" || bad "Application $n missing"
done
diff -q <(grep -v '^#' "$TMP/aoa-nokey.yaml") <(grep -v '^#' "$TMP/aoa-off.yaml") >/dev/null &&
  ok "a values file without the ztna key renders the same as ztna.enabled=false" || bad "a missing ztna key renders differently from the flag off"
grep -q 'ztna' "$TMP/aoa-off.yaml" && bad "ztna.enabled=false leaves a trace of ztna in the output" || ok "ztna.enabled=false: output has no 'ztna' at all"
for env in teknoir-online teknoir-local airgap-redesign teknoir-dev teknoir-online-godaddy default; do
  helm template aoa "$AOA" --set project="$env" --set ztna.enabled=true >"$TMP/aoa-$env-on.yaml"
  helm template aoa "$AOA" --set project="$env" --set ztna.enabled=false >"$TMP/aoa-$env-off.yaml"
  diff -q "$TMP/aoa-$env-on.yaml" "$TMP/aoa-$env-off.yaml" >/dev/null &&
    ok "project=$env with ztna.enabled=true: output identical to flag off" || bad "project=$env with ztna.enabled=true changes the output"
done
# The cherry-pick case: a teknoir-online values file that took the flag.
cp -r "$AOA" "$TMP/aoa-online"
printf '# GitOps values\nproject: teknoir-online\n\nztna:\n  enabled: true\n' >"$TMP/aoa-online/values.yaml"
helm template aoa "$TMP/aoa-online" >"$TMP/aoa-online.yaml"
grep -q 'ztna' "$TMP/aoa-online.yaml" && bad "teknoir-online values with ztna.enabled render ztna" || ok "teknoir-online values with ztna.enabled: true render nothing of ztna"

step "app-of-apps: Applications (teknoir-cloud, enabled)"
python3 -I - "$TMP/aoa-on.yaml" "$TMP/aoa-off.yaml" <<'PY' || fail=1
import sys, yaml
load = lambda p: {d["metadata"]["name"]: d for d in yaml.safe_load_all(open(p)) if d and d["kind"] == "Application"}
on, off = load(sys.argv[1]), load(sys.argv[2])
assert set(on) - set(off) == {"gateway-api-crds", "stunner", "ztna"}, set(on) ^ set(off)
repo = "https://github.com/teknoir/platform-applications-gitops"
for name, path, ns in (("gateway-api-crds", "charts/gateway-api-crds", "kube-system"),
                       ("stunner", "charts/stunner", "stunner-system"),
                       ("ztna", "charts/ztna", "teknoir-ztna")):
    a = on[name]
    assert a["spec"]["source"] == {"path": path, "repoURL": repo, "targetRevision": "teknoir-cloud"}, a["spec"]["source"]
    assert a["spec"]["destination"] == {"namespace": ns, "server": "https://kubernetes.default.svc"}
    assert a["spec"]["project"] == "teknoir-cloud"
    assert "sync-wave" not in str(a["metadata"]), "no sync waves: a failing ZTNA Application must not stall the root app-of-apps"
    assert "finalizers" not in a["metadata"], "no cascading delete when the flag is turned off"
    sp = a["spec"]["syncPolicy"]
    assert "ServerSideApply=true" in sp["syncOptions"], sp
    assert sp["automated"]["selfHeal"] is True
    assert sp["retry"]["limit"] == 10
assert on["gateway-api-crds"]["spec"]["syncPolicy"]["automated"]["prune"] is False, "CRDs are never pruned"
st = on["stunner"]["spec"]["syncPolicy"]
assert "CreateNamespace=true" in st["syncOptions"] and "SkipDryRunOnMissingResource=true" in st["syncOptions"], st
assert st["managedNamespaceMetadata"]["labels"] == {"istio-injection": "disabled"}, st
# the switch reaches the two charts that need it, and only them
SWITCHED = ("device-controller", "virtual-devices", "auth", "backstage")
for n in SWITCHED:
    assert on[n]["spec"]["source"]["helm"] == {"parameters": [{"name": "ztna.enabled", "value": "true"}]}, (n, on[n]["spec"]["source"])
    assert "helm" not in off[n]["spec"]["source"], n
assert "sync-wave" not in str(on["device-controller"]["metadata"]), "device-controller has no wave (retry covers the missing namespace)"
assert on["device-controller"]["spec"]["syncPolicy"]["retry"]["limit"] == 10
for n in on:
    if n not in ("gateway-api-crds", "stunner", "ztna") + SWITCHED:
        assert on[n] == off[n], n
print("ok   no sync waves, server-side apply, no finalizers, CRDs not pruned, namespace labels, switch passed to device-controller, virtual-devices, auth and backstage only")
PY

# ---------------------------------------------------------------- charts
step "helm lint"
for c in gateway-api-crds stunner; do
  helm lint "${CHARTS}/$c" >"$TMP/lint.txt" 2>&1 && ok "helm lint $c" || { cat "$TMP/lint.txt"; bad "helm lint $c"; }
done
helm lint "${CHARTS}/ztna" --set hub.image.tag="$IMG_TAG" >"$TMP/lint.txt" 2>&1 && ok "helm lint ztna" || { cat "$TMP/lint.txt"; bad "helm lint ztna"; }

step "helm dependency build (stunner 1.2.1 from https://l7mp.io/stunner)"
( cd "${CHARTS}/stunner" && helm dependency build >"$TMP/dep.txt" 2>&1 ) && ok "helm dependency build" || { cat "$TMP/dep.txt"; bad "helm dependency build"; }

step "render (ztna disabled and enabled)"
DC_ON=(--set ztna.enabled=true --set ztna.agentImage=ghcr.io/teknoir/wg-agent:sha-0a0a0a0a@sha256:1111111111111111111111111111111111111111111111111111111111111111 --set ztna.terminalImage=ghcr.io/teknoir/web-terminal:sha-0b0b0b0b@sha256:2222222222222222222222222222222222222222222222222222222222222222)
helm template gateway-api-crds "${CHARTS}/gateway-api-crds" --namespace kube-system --include-crds >"$TMP/crds.yaml"
helm template stunner "${CHARTS}/stunner" --namespace stunner-system --include-crds >"$TMP/stunner.yaml"
helm template ztna "${CHARTS}/ztna" --namespace teknoir-ztna --set hub.image.tag="$IMG_TAG" >"$TMP/ztna.yaml"
helm template device-controller "${CHARTS}/device-controller" --namespace teknoir-system >"$TMP/dc-off.yaml"
helm template device-controller "${CHARTS}/device-controller" --namespace teknoir-system "${DC_ON[@]}" >"$TMP/dc-on.yaml"
helm template virtual-devices "${CHARTS}/virtual-devices" --namespace kubevirt >"$TMP/vd-off.yaml"
helm template virtual-devices "${CHARTS}/virtual-devices" --namespace kubevirt --set ztna.enabled=true >"$TMP/vd-on.yaml"
ok "rendered"
printf 'rendered resources:\n'
for f in crds stunner ztna; do
  printf '  %s:\n' "$f"
  python3 -I -c 'import sys, yaml, collections
c = collections.Counter()
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d: c[(d["kind"], d["metadata"].get("namespace", "-"), d["metadata"]["name"])] += 1
for (k, ns, n), _ in sorted(c.items()): print(f"    {k:34} {ns:16} {n}")' "$TMP/$f.yaml" | grep -v -E "CustomResourceDefinition" || true
  printf '    CustomResourceDefinition x %s\n' "$(grep -c '^kind: CustomResourceDefinition$' "$TMP/$f.yaml" || true)"
done

step "ztna.enabled=false renders byte-identical to the base branch for every chart"
BASE_REF="${ZTNA_BASE_REF:-origin/teknoir-cloud}"
if git -C "$REPO" rev-parse --verify -q "$BASE_REF" >/dev/null; then
  mkdir -p "$TMP/base" "$TMP/head"
  git -C "$REPO" archive "$BASE_REF" charts | tar -x -C "$TMP/base"
  cp -r "$CHARTS" "$TMP/head/charts"
  for c in "$TMP"/head/charts/*/; do
    n=$(basename "$c")
    [[ -d $TMP/base/charts/$n ]] || continue   # charts that do not exist on the base (ztna, stunner, gateway-api-crds)
    for root in base head; do
      if grep -q '^dependencies:' "$TMP/$root/charts/$n/Chart.yaml"; then
        # stunner is not on the base; the others are rendered without their lock file (it is not in Git)
        ( cd "$TMP/$root/charts/$n" && helm dependency build >/dev/null 2>&1 ) || echo "WARN: helm dependency build failed for $root/$n"
      fi
    done
    for proj in teknoir-cloud teknoir-online teknoir-local; do
      args=()
      [[ $n == app-of-apps ]] && args=(--set project="$proj")
      helm template "$n" "$TMP/base/charts/$n" --namespace x "${args[@]}" >"$TMP/base-$n.yaml" 2>"$TMP/base-$n.err" || { echo "skip $n (base render failed: $(head -c 150 "$TMP/base-$n.err"))"; continue 2; }
      # Force the switch off on the head render (the branch may ship it on), so this compares
      # only what the off state would change.
      hargs=("${args[@]}")
      [[ $n == app-of-apps ]] && hargs+=(--set ztna.enabled=false)
      helm template "$n" "$TMP/head/charts/$n" --namespace x "${hargs[@]}" >"$TMP/head-$n.yaml" 2>"$TMP/head-$n.err" || { cat "$TMP/head-$n.err"; bad "$n does not render"; continue 2; }
      # charts that generate random values (harbor passwords) cannot be compared byte for byte
      helm template "$n" "$TMP/base/charts/$n" --namespace x "${args[@]}" 2>/dev/null | cmp -s - "$TMP/base-$n.yaml" || { echo "skip $n (the base render is not deterministic)"; continue 2; }
      # An image promotion (a changed '<repo>:<tag>' or 'tag:' line) is an expected difference
      # with the flag off; everything else must be byte-identical.
      grep -v -E '^\s*image: |^\s*tag: ' "$TMP/base-$n.yaml" >"$TMP/base-$n.cmp"
      grep -v -E '^\s*image: |^\s*tag: ' "$TMP/head-$n.yaml" >"$TMP/head-$n.cmp"
      cmp -s "$TMP/base-$n.cmp" "$TMP/head-$n.cmp" || { diff "$TMP/base-$n.yaml" "$TMP/head-$n.yaml" | head -10 || true; bad "$n ($proj): render with the flag off differs from $BASE_REF"; continue 2; }
      [[ $n == app-of-apps ]] || break   # only app-of-apps depends on the project
    done
    ok "$n: byte-identical to $BASE_REF with ztna off"
  done
else
  echo "SKIP: $BASE_REF not available"
fi

step "each CRD set exactly once (gateway-api-crds vs stunner)"
crd_names() { python3 -I -c 'import sys, yaml; print("\n".join(sorted(d["metadata"]["name"] for d in yaml.safe_load_all(open(sys.argv[1])) if d and d["kind"] == "CustomResourceDefinition")))' "$1"; }
crd_names "$TMP/crds.yaml" >"$TMP/crds.names"
crd_names "$TMP/stunner.yaml" >"$TMP/stunner.names"
[[ -z $(comm -12 "$TMP/crds.names" "$TMP/stunner.names") ]] && ok "no CRD is rendered by both charts" || bad "duplicated CRDs: $(comm -12 "$TMP/crds.names" "$TMP/stunner.names" | tr '\n' ' ')"
grep -q '\.gateway\.networking\.k8s\.io$' "$TMP/stunner.names" && bad "stunner renders Gateway API CRDs" || ok "stunner renders no Gateway API CRDs (standardCrds/experimentalCrds disabled)"
[[ $(grep -c 'stunner.l7mp.io$' "$TMP/stunner.names") == 4 ]] && ok "stunner renders the 4 STUNner CRDs" || bad "STUNner CRDs missing"
( cd "${CHARTS}/gateway-api-crds/crds" && sha256sum --check --quiet ../SHA256SUMS ) && ok "vendored Gateway API CRDs match SHA256SUMS" || bad "gateway-api-crds checksum"
S=$(helm pull stunner/stunner --version 1.2.1 --untar --untardir "$TMP/pull" 2>&1 && cmp "$TMP/pull/stunner/charts/gateway-api-standard-crds/crds/gateway-api-crds.yaml" "${CHARTS}/gateway-api-crds/crds/gateway-api-standard-v1.4.1.yaml" && echo same) || S=err
[[ $S == *same ]] && ok "vendored CRDs are byte-identical to the stunner 1.2.1 chart's standard-channel subchart" || bad "vendored CRDs differ from stunner 1.2.1 ($S)"

step "kubeconform -strict (Kubernetes ${K8S_VERSION}; CRs against schemas generated from their CRDs)"
python3 -I "${CHARTS}/virtual-devices/tests/crd2schema.py" "$TMP/schemas" "$TMP/crds.yaml" "$TMP/stunner.yaml" "${CHARTS}/device-controller/crds/devices.yaml" >/dev/null
LOC=(-schema-location default -schema-location "$TMP/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
if [[ ${ZTNA_ONLINE:-0} == 1 ]]; then
  LOC+=(-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json')
  IGN=()
else
  # Istio and Prometheus Operator objects have no schema offline.
  IGN=(-ignore-missing-schemas)
fi
for f in crds stunner ztna dc-off dc-on vd-off vd-on; do
  if kubeconform -strict -summary "${IGN[@]}" -kubernetes-version "$K8S_VERSION" -cache "$CACHE" -skip CustomResourceDefinition "${LOC[@]}" "$TMP/$f.yaml" >"$TMP/kc-$f.txt" 2>&1; then
    ok "kubeconform $f: $(tail -1 "$TMP/kc-$f.txt")"
  else
    cat "$TMP/kc-$f.txt"; bad "kubeconform $f"
  fi
done
step "kubeconform rejects a misspelled field in a STUNner custom resource (the generated schemas are strict)"
sed 's/gatewayClassName: stunner-gatewayclass/gatewayClassNam: stunner-gatewayclass/' "$TMP/stunner.yaml" >"$TMP/typo.yaml"
kubeconform -strict "${IGN[@]}" -kubernetes-version "$K8S_VERSION" -cache "$CACHE" -skip CustomResourceDefinition "${LOC[@]}" "$TMP/typo.yaml" >/dev/null 2>&1 &&
  bad "a misspelled Gateway field passed validation" || ok "misspelled field rejected"

step "structural assertions"
python3 -I - "$TMP" <<'PY' || fail=1
import sys, yaml
t = sys.argv[1]
load = lambda n: [d for d in yaml.safe_load_all(open(f"{t}/{n}.yaml")) if d]
by = lambda docs, kind, name=None: [d for d in docs if d["kind"] == kind and (name is None or d["metadata"]["name"] == name)]

# --- STUNner objects
st = load("stunner")
gc, = by(st, "GatewayClass")
assert gc["spec"]["controllerName"] == "stunner.l7mp.io/gateway-operator"
assert gc["spec"]["parametersRef"] == {"group": "stunner.l7mp.io", "kind": "GatewayConfig", "name": "stunner-gatewayconfig", "namespace": "stunner-system"}
cfg, = by(st, "GatewayConfig")
assert cfg["spec"]["realm"] == "stunner.l7mp.io"
assert cfg["spec"]["authRef"] == {"name": "stunner-auth-secret", "namespace": "stunner-system"}
assert "sharedSecret" not in cfg["spec"] and "password" not in cfg["spec"], "no secret in Git"
gw, = by(st, "Gateway")
assert gw["metadata"]["name"] == "teknoir-turn" and gw["metadata"]["namespace"] == "stunner-system"
assert gw["metadata"]["annotations"]["stunner.l7mp.io/disable-health-check-expose"] == "true"
assert gw["spec"]["gatewayClassName"] == "stunner-gatewayclass"
assert [(l["protocol"], l["port"]) for l in gw["spec"]["listeners"]] == [("TURN-UDP", 3478)]
rt, = by(st, "UDPRoute")
assert rt["apiVersion"] == "stunner.l7mp.io/v1" and rt["metadata"] == {"name": "wg-hub", "namespace": "stunner-system", "annotations": rt["metadata"]["annotations"]}
assert rt["spec"]["parentRefs"] == [{"name": "teknoir-turn"}]
assert rt["spec"]["rules"] == [{"backendRefs": [{"name": "wg-hub", "namespace": "teknoir-ztna", "port": 51820}]}], rt["spec"]
for d in (gc, cfg, gw, rt):
    a = d["metadata"]["annotations"]
    assert a["argocd.argoproj.io/sync-wave"] == "1" and a["argocd.argoproj.io/sync-options"] == "SkipDryRunOnMissingResource=true", d["kind"]
op, = by(st, "Deployment")
img = op["spec"]["template"]["spec"]["containers"][0]["image"]
assert "@sha256:" in img, img
dp, = by(st, "Dataplane")
assert "@sha256:" in dp["spec"]["image"] and dp["spec"]["replicas"] == 1
assert not by(st, "Secret"), "the TURN secret is not in Git"
assert not [d for d in st if d["metadata"].get("name") == "stunner-auth"], "REST auth service not deployed"
for d in st:  # every namespaced object lands in stunner-system
    if d["kind"] in ("Gateway", "GatewayConfig", "UDPRoute", "Deployment", "Service", "ServiceAccount", "Role", "RoleBinding"):
        assert d["metadata"]["namespace"] == "stunner-system", (d["kind"], d["metadata"])

# --- ztna objects
z = load("ztna")
assert not by(z, "Secret") and not by(z, "ConfigMap"), "no Secrets or ConfigMaps in Git (policy and identity ConfigMaps are written at runtime)"
deps = {d["metadata"]["name"]: d for d in by(z, "Deployment")}
assert set(deps) == {"wg-hub", "wg-flags"}, set(deps)
dep = deps["wg-hub"]
spec = dep["spec"]["template"]["spec"]
c, = spec["containers"]
assert c["image"].startswith("ghcr.io/teknoir/wg-hub:") and "@sha256:" in c["image"]
assert dep["spec"]["replicas"] == 1 and dep["spec"]["strategy"]["type"] == "Recreate"
assert spec["securityContext"]["runAsNonRoot"] is True and c["securityContext"]["readOnlyRootFilesystem"] is True
assert c["securityContext"]["capabilities"] == {"drop": ["ALL"]} and c["securityContext"]["allowPrivilegeEscalation"] is False
assert "hostNetwork" not in spec and not spec.get("hostPID")
assert [(p["name"], p["containerPort"]) for p in c["ports"]] == [("http", 8080), ("http-internal", 8081), ("metrics", 9090), ("wg", 51820)], c["ports"]
# k3s servicelb SNATs client addresses: no client address header may be trusted until real client IPs are verified
assert "CLIENT_IP_HEADER" not in [e["name"] for e in c.get("env", [])], "CLIENT_IP_HEADER must not be set on the hub (see charts/ztna/README.md, Client IP)"
# --- flags watcher: same image, own SA, no ports, hardened
fdep = deps["wg-flags"]
fs = fdep["spec"]["template"]["spec"]
fc, = fs["containers"]
assert fc["image"] == c["image"] and fc["args"] == ["flags-watcher"] and "command" not in fc, fc
assert fs["serviceAccountName"] == "wg-flags" and "ports" not in fc
assert fc["securityContext"]["readOnlyRootFilesystem"] is True and fc["securityContext"]["capabilities"] == {"drop": ["ALL"]}
assert not [s_ for s_ in by(z, "Service") if s_["metadata"]["name"] == "wg-flags"], "no Service for the flags watcher"
svc, = by(z, "Service", "wg-hub")
assert [(p["name"], p["port"]) for p in svc["spec"]["ports"]] == [("http", 8080), ("http-internal", 8081), ("http-metrics", 9090), ("wg", 51820)]
# --- VirtualServices route to 8080 only (8081 is internal)
for v in by(z, "VirtualService"):
    for h in v["spec"]["http"]:
        for r in h["route"]:
            assert r["destination"]["port"]["number"] == 8080, v["metadata"]["name"]
# --- AuthorizationPolicy: 8080 from the two ingress gateways, 8081 from the namespace, 9090 from prometheus
ap, = by(z, "AuthorizationPolicy", "wg-hub")
rules = [(r["from"][0]["source"], r["to"][0]["operation"]["ports"]) for r in ap["spec"]["rules"]]
assert rules[0] == ({"principals": ["cluster.local/ns/istio-system/sa/istio-ingressgateway", "cluster.local/ns/istio-system/sa/istio-ingressgateway-public"]}, ["8080"]), rules
assert rules[1] == ({"namespaces": ["teknoir-ztna"]}, ["8081"]), rules
assert rules[2][1] == ["9090"] and len(rules) == 3, rules
# --- RBAC: only the flags watcher reads Devices; the hub never can
for d in by(z, "ClusterRole") + by(z, "Role"):
    reads_devices = any("devices" in rule["resources"] for rule in d["rules"])
    assert reads_devices == (d["metadata"]["name"] == "wg-flags" and d["kind"] == "ClusterRole"), d["metadata"]["name"]
fl, = by(z, "Role", "wg-flags")
assert fl["rules"] == [{"apiGroups": [""], "resources": ["configmaps"], "verbs": ["get", "list", "watch", "create", "update", "patch", "delete"]}]
fcr, = by(z, "ClusterRole", "wg-flags")
assert fcr["rules"] == [{"apiGroups": ["teknoir.org"], "resources": ["devices"], "verbs": ["get", "list", "watch"]}]
for b in by(z, "ClusterRoleBinding", "wg-flags") + by(z, "RoleBinding", "wg-flags"):
    assert b["subjects"] == [{"kind": "ServiceAccount", "name": "wg-flags", "namespace": "teknoir-ztna"}]
vs = by(z, "VirtualService")
assert {v["metadata"]["name"]: (v["spec"]["hosts"], v["spec"]["gateways"]) for v in vs} == {
    "wg": (["wg.teknoir.cloud"], ["istio-system/teknoir-gateway"]),
    "wg-device": (["wg-device.teknoir.cloud"], ["istio-system/teknoir-gateway-public"])}
ns, = by(z, "Namespace")
assert ns["metadata"]["labels"]["istio-injection"] == "enabled"
# every object of the hub lands in the release namespace, except the Roles on the TURN secret and the pull secret source
for d in z:
    n = d["metadata"].get("namespace")
    if d["kind"] in ("ClusterRole", "ClusterRoleBinding", "Namespace", "ValidatingAdmissionPolicy", "ValidatingAdmissionPolicyBinding"):
        assert n is None, d["kind"]
    else:
        assert n in ("teknoir-ztna", "stunner-system", "teknoir-system"), (d["kind"], n)
# --- the Role the hub gets in stunner-system reads only the one Secret
r, = [d for d in by(z, "Role") if d["metadata"]["namespace"] == "stunner-system"]
assert r["rules"] == [{"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["stunner-auth-secret"], "verbs": ["get"]}]
# --- the hub never gets Secret rights anywhere else, nor delete anywhere
for d in by(z, "Role") + by(z, "ClusterRole"):
    for rule in d["rules"]:
        if d["metadata"]["name"] in ("ztna-pull-secret-source", "ztna-pull-secret-target", "wg-flags"):
            continue
        assert "delete" not in rule["verbs"], d["metadata"]["name"]
        if "secrets" in rule["resources"]:
            assert d["metadata"]["name"] == "wg-hub-turn-secret"

# --- device-controller
off, on = load("dc-off"), load("dc-on")
cm_off, = by(off, "ConfigMap"); cm_on, = by(on, "ConfigMap")
assert "ZTNA" not in cm_off["data"] and "ZTNA" in cm_on["data"]
import json
z = json.loads(cm_on["data"]["ZTNA"])
assert z["enabled"] is True and z["hubNamespace"] == "teknoir-ztna" and z["allowedPorts"] == [22]
assert not [d for d in off if d["metadata"].get("namespace") == "teknoir-ztna"], "nothing in teknoir-ztna while disabled"
roles = [d for d in on if d["kind"] in ("Role", "RoleBinding") and d["metadata"].get("namespace") == "teknoir-ztna"]
assert sorted(d["kind"] for d in roles) == ["Role", "RoleBinding"]
# the enabled render adds only the Role, its binding and the vdev TURN policy (and the ZTNA key)
names = lambda docs: {(d["kind"], d["metadata"]["name"]) for d in docs}
assert names(on) - names(off) == {("Role", "device-controller-ztna"), ("RoleBinding", "device-controller-ztna-rolebinding"), ("NetworkPolicy", "vdev-egress-turn")}, names(on) ^ names(off)
assert not names(off) - names(on)
print("ok   STUNner Gateway/GatewayClass/GatewayConfig/UDPRoute (port 51820, no endPort, cross-namespace backend), hub Deployment hardening, Roles, no Secrets in Git, device-controller ZTNA key and Role")
PY
python3 -I - "${CHARTS}/device-controller/crds/devices.yaml" <<'PY' && ok "Device CRD: status.wireguard next to status.virtual_device with the 18 fields" || bad "Device CRD status.wireguard"
import sys, yaml
crd = yaml.safe_load(open(sys.argv[1]))
st = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["status"]["properties"]
assert "virtual_device" in st and "wireguard" in st
w = st["wireguard"]["properties"]
want = {"enabled": "boolean", "state": "string", "reasons": "array", "note": "string", "enrollmentGeneration": "integer",
        "enrollUntil": "string", "lastReenrollRequest": "string", "lastFlagsSet": "boolean", "identityFingerprint": "string",
        "enrolledAt": "string", "enrollmentConflicts": "integer", "webTerminalURL": "string", "policyUpdatedAt": "string", "message": "string",
        "approvedFingerprint": "string", "approvedEpoch": "string", "identityApproved": "boolean", "identityVoided": "boolean"}
assert {k: v["type"] for k, v in w.items()} == want, {k: v["type"] for k, v in w.items()}
assert w["enrollmentGeneration"]["format"] == "int64" and w["reasons"]["items"]["type"] == "string"
assert "required" not in st["wireguard"], "all fields optional"
assert crd["spec"]["versions"][0]["subresources"] == {"status": {}}
PY

step "virtual devices: CoreDNS rewrites and TURN egress policy"
python3 -I - "$TMP" <<'PY' || fail=1
import sys, yaml
t = sys.argv[1]
load = lambda n: [d for d in yaml.safe_load_all(open(f"{t}/{n}.yaml")) if d]
cm_off, = [d for d in load("vd-off") if d["kind"] == "ConfigMap"]
cm_on, = [d for d in load("vd-on") if d["kind"] == "ConfigMap"]
off, on = cm_off["data"]["virtual-devices.override"], cm_on["data"]["virtual-devices.override"]
assert "wg-device" not in off and "turn" not in off.replace("return", "")
assert on.startswith(off.rstrip("\n")[:200])
assert "rewrite stop name exact wg-device.teknoir.cloud. istio-ingressgateway-public.istio-system.svc.cluster.local. answer auto" in on
assert "rewrite stop name exact turn.teknoir.cloud. teknoir-turn.stunner-system.svc.cluster.local. answer auto" in on
assert [l for l in off.splitlines() if l.startswith("    rewrite")] == [l for l in on.splitlines() if l.startswith("    rewrite")][:1], "existing rewrite untouched"
dc_off = [d for d in load("dc-off") if d["kind"] == "NetworkPolicy"]
dc_on = [d for d in load("dc-on") if d["kind"] == "NetworkPolicy"]
assert {d["metadata"]["name"] for d in dc_on} - {d["metadata"]["name"] for d in dc_off} == {"vdev-egress-turn"}
p, = [d for d in dc_on if d["metadata"]["name"] == "vdev-egress-turn"]
assert p["spec"]["egress"] == [{"to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "stunner-system"}}, "podSelector": {"matchLabels": {"app": "stunner"}}}], "ports": [{"protocol": "UDP", "port": 3478}]}]
print("ok   wg-device -> istio-ingressgateway-public, turn -> teknoir-turn.stunner-system; vdev-egress-turn UDP 3478 -> app=stunner in stunner-system; nothing else changes")
PY

step "helm unittest"
if helm plugin list 2>/dev/null | grep -q '^unittest'; then
  for c in ztna device-controller; do
    helm unittest "${CHARTS}/$c" >"$TMP/ut-$c.txt" 2>&1 && ok "helm unittest $c: $(grep '^Tests:' "$TMP/ut-$c.txt")" || { cat "$TMP/ut-$c.txt"; bad "helm unittest $c"; }
  done
else
  echo "SKIP: helm unittest plugin not installed"
fi

step "yamllint (the rendered ZTNA manifests)"
if command -v yamllint >/dev/null; then
  printf 'extends: relaxed\nrules:\n  line-length: disable\n  trailing-spaces: {}\n' >"$TMP/yamllint.yaml"
  yamllint -c "$TMP/yamllint.yaml" "$TMP/ztna.yaml" "$TMP/stunner.yaml" "$TMP/dc-on.yaml" >"$TMP/yl.txt" 2>&1 && ok "yamllint" || { cat "$TMP/yl.txt"; bad "yamllint"; }
else
  echo "SKIP: yamllint not installed"
fi

step "admission policies against a throwaway kube-apiserver"
"${HERE}/vap-test.sh" || fail=1

printf '\n'
if ((fail)); then
  echo "ztna tests FAILED"
  exit 1
fi
echo "ztna tests passed"
