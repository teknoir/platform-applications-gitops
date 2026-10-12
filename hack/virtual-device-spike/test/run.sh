#!/usr/bin/env bash
# Offline tests for the S1 spike kit. No cluster, no credentials: the Device fixture is
# filled with a throwaway RSA key and password generated here.
#
#   hack/virtual-device-spike/test/run.sh
#
# Needs: bash, shellcheck, go, git, jq, openssl, helm, python3 (PyYAML), kubeconform
# (fetches Kubernetes 1.34 and pinned CRDs-catalog schemas into its cache).
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "${HERE}/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/.. source=lib/pins.sh
. "${KIT}/lib/pins.sh"
CRDS_CATALOG="https://raw.githubusercontent.com/datreeio/CRDs-catalog/63669a570e231d4f1f8396d229a1de512bcf0a34"

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
mkdir -p "$CACHE"

fail=0
step() { printf '\n--- %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

step "shellcheck"
if shellcheck -x "${KIT}"/*.sh "${KIT}"/lib/*.sh "${KIT}"/test/*.sh "${KIT}"/test/fakebin/*; then ok "shellcheck clean"; else bad "shellcheck"; fi

step "gofmt"
[[ -z $(gofmt -l "${KIT}/renderer/main.go") ]] && ok "renderer/main.go is gofmt-clean" || bad "gofmt renderer/main.go"

step "throwaway credentials and fixture"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=teknoir.ai" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASSWORD="test-$(openssl rand -hex 12)"
fixture() { # fixture OUT [jq-filter]
  jq --arg k "$(base64 -w0 <"$TMP/key.pem")" --arg c "$(base64 -w0 <"$TMP/cert.pem")" --arg p "$(printf '%s' "$PASSWORD" | base64 -w0)" \
    ".spec.keys.data.rsa_private=\$k | .spec.keys.data.rsa_public=\$c | .spec.keys.data.userpassword=\$p | ${2:-.}" \
    "${HERE}/fixtures/device.json" >"$1"
}
fixture "$TMP/device.json"
ok "generated a throwaway key and password"
KEY_MARKER=$(grep -v -- '-----' "$TMP/key.pem" | tr -d '\n' | cut -c41-100)
no_secrets_in() { # no_secrets_in FILE LABEL
  if grep -qF -- "$KEY_MARKER" "$1" || grep -qF -- "$PASSWORD" "$1" || grep -q 'PRIVATE KEY' "$1"; then
    bad "$2 contains a credential"
  else
    ok "$2 contains no credential"
  fi
}

step "dry render (containerdisk, defaults)"
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/out" >"$TMP/stdout" 2>"$TMP/stderr" &&
  ok "render.sh exited 0" || { bad "render.sh failed"; cat "$TMP/stderr"; }
[[ $(cat "$TMP/stdout") == "$TMP/out" ]] && ok "stdout is only the output directory" || bad "unexpected stdout: $(head -c 200 "$TMP/stdout")"
no_secrets_in "$TMP/stdout" "render stdout"
no_secrets_in "$TMP/stderr" "render stderr"
python3 -I "${HERE}/inspect_render.py" "$TMP/out" "$TMP/key.pem" "$PASSWORD" containerdisk || fail=1

step "the bootstrap is the cli template at ${VDS_CLI_REF:0:12}, not a fork"
CLI_SRC="${TEKNOIR_CLI_SRC:-$HOME/git/ai/cli}"
if git -C "$CLI_SRC" cat-file -e "${VDS_CLI_REF}^{commit}" 2>/dev/null; then
  want=$(git -C "$CLI_SRC" show "${VDS_CLI_REF}:pkg/templates/server.sh.tmpl" | sha256sum | awk '{print $1}')
  grep -q "server.sh.tmpl (sha256 ${want})" "$TMP/out/summary.txt" && ok "summary records the template sha256 of cli ${VDS_CLI_REF:0:12}" ||
    bad "template sha256 differs from cli ${VDS_CLI_REF:0:12}"
else
  printf 'skip cli clone not found at %s (set TEKNOIR_CLI_SRC)\n' "$CLI_SRC"
fi
extract_script() { python3 -I -c '
import base64,sys,yaml
s=yaml.safe_load(open(sys.argv[1]))
ud=yaml.safe_load(base64.b64decode(s["data"]["userdata"]))
sys.stdout.write(base64.b64decode(ud["write_files"][0]["content"]).decode())' "$1"; }
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/out2" >/dev/null 2>&1
extract_script "$TMP/out/10-cloudinit-secret.yaml" >"$TMP/s1.sh"
extract_script "$TMP/out2/10-cloudinit-secret.yaml" >"$TMP/s2.sh"
d=$(diff "$TMP/s1.sh" "$TMP/s2.sh" | grep -E '^[<>]' || true)
[[ $(wc -l <<<"$d") == 2 && $d == *'_K3S_TOKEN='* ]] && ok "two renders differ only in the random k3s token" || bad "renders differ beyond the k3s token: $d"
sh -n "$TMP/s1.sh" && ok "rendered bootstrap parses with sh -n" || bad "rendered bootstrap has a syntax error"

step "kubeconform -strict (Kubernetes 1.34 + KubeVirt/CDI CRDs-catalog @63669a5)"
if kubeconform -strict -summary -kubernetes-version 1.34.0 -cache "$CACHE" \
  -schema-location default -schema-location "${CRDS_CATALOG}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$TMP/out/00-namespace.yaml" "$TMP/out/10-cloudinit-secret.yaml" "$TMP/out/20-vm.yaml"; then
  ok "kubeconform"
else
  bad "kubeconform"
fi

step "committed manifests/teknoir-demo-vdev.yaml is current"
"${KIT}/render.sh" --namespace-only --out "$TMP/nsonly" >/dev/null 2>&1
diff -u "${KIT}/manifests/teknoir-demo-vdev.yaml" "$TMP/nsonly/00-namespace.yaml" && ok "manifests/teknoir-demo-vdev.yaml matches render.sh --namespace-only" ||
  bad "manifests/teknoir-demo-vdev.yaml is stale (re-run render.sh --namespace-only)"

step "variants"
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/generic" --disk generic >/dev/null 2>&1 &&
  python3 -I "${HERE}/inspect_render.py" "$TMP/generic" "$TMP/key.pem" "$PASSWORD" generic >"$TMP/generic.log" &&
  ok "--disk generic renders an HTTPS import with SHA512 verification" || { bad "--disk generic"; cat "$TMP/generic.log"; }
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/airgap" --egress platform-only --allow-harbor --cpu-model Opteron_G5 >/dev/null 2>&1
python3 -I - "$TMP/airgap" <<'PY' && ok "--egress platform-only drops internet egress; --allow-harbor adds 443 to istio=ingressgateway; --cpu-model sets the model" || bad "airgap/cpu-model variant"
import sys, yaml, os
d = sys.argv[1]
ns = [x for x in yaml.safe_load_all(open(os.path.join(d, "00-namespace.yaml"))) if x]
names = {x["metadata"]["name"] for x in ns}
assert "vdev-egress-internet" not in names, names
h = next(x for x in ns if x["metadata"]["name"] == "vdev-egress-harbor")
assert h["spec"]["egress"][0]["to"][0]["podSelector"]["matchLabels"] == {"istio": "ingressgateway"}
assert h["spec"]["egress"][0]["ports"] == [{"protocol": "TCP", "port": 443}]
vm = next(yaml.safe_load_all(open(os.path.join(d, "20-vm.yaml"))))
assert vm["spec"]["template"]["spec"]["domain"]["cpu"]["model"] == "Opteron_G5"
PY
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/debug" --debug-user --allow-virtctl-ssh >"$TMP/debug.out" 2>&1
no_secrets_in "$TMP/debug.out" "--debug-user render output"
python3 -I - "$TMP/debug" "$(ssh-keygen -y -f "$TMP/key.pem")" <<'PY' && ok "--debug-user adds vdspike with the device's SSH public key; --allow-virtctl-ssh opens only 22 from virt-api" || bad "debug variant"
import base64, os, sys, yaml
d, pub = sys.argv[1], sys.argv[2]
sec = next(yaml.safe_load_all(open(os.path.join(d, "10-cloudinit-secret.yaml"))))
ud = yaml.safe_load(base64.b64decode(sec["data"]["userdata"]))
assert [u["name"] for u in ud["users"]] == ["vdspike"], ud["users"]
assert ud["users"][0]["ssh_authorized_keys"] == [pub]
assert ud["users"][0]["lock_passwd"] is True
np = next(x for x in yaml.safe_load_all(open(os.path.join(d, "00-namespace.yaml"))) if x and x["metadata"]["name"] == "vdev-ingress-virtctl-ssh")
rule = np["spec"]["ingress"][0]
assert rule["ports"] == [{"protocol": "TCP", "port": 22}]
assert rule["from"][0]["podSelector"]["matchLabels"] == {"kubevirt.io": "virt-api"}
assert rule["from"][0]["namespaceSelector"]["matchLabels"] == {"kubernetes.io/metadata.name": "kubevirt"}
PY
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/medium" --cpu 4 --memory-gi 8 --disk-gi 40 >/dev/null 2>&1
python3 -I - "$TMP/medium" <<'PY' && ok "--cpu 4 --memory-gi 8 --disk-gi 40 sizes the VM and the quota" || bad "sizing variant"
import sys, yaml, os
d = sys.argv[1]
vm = next(yaml.safe_load_all(open(os.path.join(d, "20-vm.yaml"))))
dom = vm["spec"]["template"]["spec"]["domain"]
assert dom["cpu"]["cores"] == 4 and dom["resources"]["requests"]["cpu"] == "2000m" and dom["resources"]["limits"]["memory"] == "8Gi"
assert vm["spec"]["dataVolumeTemplates"][0]["spec"]["storage"]["resources"]["requests"]["storage"] == "40Gi"
q = next(x for x in yaml.safe_load_all(open(os.path.join(d, "00-namespace.yaml"))) if x and x["kind"] == "ResourceQuota")["spec"]["hard"]
assert q["requests.cpu"] == "5000m" and q["limits.cpu"] == "9" and q["requests.memory"] == "18Gi" and q["requests.storage"] == "176Gi", q
PY

step "refusals"
expect_fail() { # expect_fail LABEL ARGS...
  local label=$1
  shift
  if "${KIT}/render.sh" "$@" >"$TMP/refusal.out" 2>&1; then bad "accepted: $label"; else ok "refused: $label"; fi
  no_secrets_in "$TMP/refusal.out" "refusal output ($label)"
}
expect_fail "device name not matching the fixture" --device other-device --fixture "$TMP/device.json" --out "$TMP/r1"
expect_fail "invalid device name" --device "Bad_Name" --fixture "$TMP/device.json" --out "$TMP/r2"
expect_fail "non-empty output directory" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/out"
expect_fail "k3s version that is not a release tag" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/r3" --k3s-version latest
fixture "$TMP/nokey.json" 'del(.spec.keys.data.rsa_private)'
expect_fail "Device without rsa_private" --device vd-s1-fixture --fixture "$TMP/nokey.json" --out "$TMP/r4"
fixture "$TMP/badkey.json" ".spec.keys.data.rsa_private=\"$(printf 'not a key' | base64)\""
expect_fail "rsa_private that is not a PEM key" --device vd-s1-fixture --fixture "$TMP/badkey.json" --out "$TMP/r5"
expect_fail "k3s >= v1.34.12 with a device certificate without keyCertSign" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/r6" --k3s-version v1.34.12+k3s1
expect_fail "k3s v1.36.5 with a device certificate without keyCertSign" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/r7" --k3s-version v1.36.5+k3s1
openssl req -x509 -key "$TMP/key.pem" -days 1 -subj "/CN=teknoir.ai" -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" -out "$TMP/cert-certsign.pem" 2>/dev/null
jq --arg c "$(base64 -w0 <"$TMP/cert-certsign.pem")" '.spec.keys.data.rsa_public=$c' "$TMP/device.json" >"$TMP/device-certsign.json"
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device-certsign.json" --out "$TMP/certsign" --k3s-version v1.36.5+k3s1 >/dev/null 2>&1 &&
  ok "k3s v1.36.5 is accepted when the device certificate has keyCertSign" || bad "k3s v1.36.5 refused despite keyCertSign"
"${KIT}/render.sh" --device vd-s1-fixture --fixture "$TMP/device.json" --out "$TMP/old135" --k3s-version v1.35.8+k3s1 >/dev/null 2>&1 &&
  ok "k3s v1.35.8 (before the CA change) is accepted" || bad "k3s v1.35.8 refused"
for r in r1 r2 r3 r4 r5 r6 r7; do
  if [[ -d $TMP/$r ]] && find "$TMP/$r" -name '10-cloudinit-secret.yaml' | grep -q .; then bad "refused render $r left a Secret behind"; fi
done
find "$TMP" -maxdepth 2 -name '.work.*' | grep -q . && bad "a .work directory was left behind" || ok "no .work directories left behind"

step "renderer -in-cluster against a fake API server"
# shellcheck source-path=SCRIPTDIR/.. source=lib/common.sh
RENDERER=$(. "${KIT}/lib/common.sh"; build_renderer 2>/dev/null)
CHART="$(cd "${KIT}/../.." && pwd)/charts/virtual-device-spike"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" \
  -keyout "$TMP/srv-key.pem" -out "$TMP/srv-cert.pem" 2>/dev/null
SA_TOKEN="test-token-$(openssl rand -hex 8)"
printf '%s' "$SA_TOKEN" >"$TMP/sa-token"
# in_cluster NAME [fake-api flags] -- [renderer flags]: runs the renderer against a fresh fake API.
in_cluster() {
  local name=$1 dev=$TMP/device.json
  shift
  local fake=() extra=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    case "$1" in
      --device-json) dev=$2; shift 2 ;;
      *) fake+=("$1"); shift ;;
    esac
  done
  [[ ${1:-} == -- ]] && shift
  extra=("$@")
  rm -f "$TMP/ic-$name.port" "$TMP/ic-$name.rec" "$TMP/ic-$name.rec.post"
  python3 -I "${HERE}/fake_api.py" "$TMP/srv-cert.pem" "$TMP/srv-key.pem" "$TMP/ic-$name.port" "$TMP/ic-$name.rec" "$dev" "$SA_TOKEN" "${fake[@]}" &
  local pid=$! i
  for i in $(seq 50); do [[ -s $TMP/ic-$name.port ]] && break; sleep 0.1; done
  set +e
  "$RENDERER" -in-cluster -api-url "https://127.0.0.1:$(cat "$TMP/ic-$name.port")" \
    -token-file "$TMP/sa-token" -ca-file "$TMP/srv-cert.pem" \
    -device vd-s1-fixture -namespace teknoir-demo -vdev-namespace teknoir-demo-vdev -domain teknoir.cloud \
    -k3s-version "${K3S_V:-${VDS_K3S_VERSION}}" -cluster-cidr "$VDS_CLUSTER_CIDR" -service-cidr "$VDS_SERVICE_CIDR" \
    -cluster-dns "$VDS_CLUSTER_DNS" -cli-ref "$VDS_CLI_REF" "${extra[@]}" >"$TMP/ic-$name.out" 2>&1
  IC_RC=$?
  set -e
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  no_secrets_in "$TMP/ic-$name.out" "in-cluster output ($name)"
}
in_cluster fresh
[[ $IC_RC == 0 ]] && ok "fresh: exit 0" || { bad "fresh: exit $IC_RC"; cat "$TMP/ic-fresh.out"; }
[[ $(cut -d' ' -f1,3 "$TMP/ic-fresh.rec" | tr '\n' ',') == "GET 404,GET 200,POST 201," ]] && ok "fresh: GET secret (404), GET device, POST secret (201), nothing else" ||
  bad "fresh: requests were $(tr '\n' ',' <"$TMP/ic-fresh.rec")"
python3 -I - "$TMP/ic-fresh.rec.post" "$TMP/key.pem" "$PASSWORD" <<'PY' && ok "fresh: the Secret is cloud-init user data with the rendered bootstrap, 0 other keys" || bad "fresh: Secret content"
import base64, json, sys, yaml
s = json.load(open(sys.argv[1]))
assert s["kind"] == "Secret" and s["metadata"]["name"] == "vd-s1-fixture-cloudinit" and s["metadata"]["namespace"] == "teknoir-demo-vdev", s["metadata"]
assert s["metadata"]["labels"]["teknoir.org/device"] == "vd-s1-fixture" and s["metadata"]["labels"]["teknoir.org/teamspace"] == "teknoir-demo"
assert list(s["data"]) == ["userdata"] and s["type"] == "Opaque"
ud = yaml.safe_load(base64.b64decode(s["data"]["userdata"]))
assert ud["hostname"] == "vd-s1-fixture"
script = base64.b64decode(ud["write_files"][0]["content"]).decode()
assert script.startswith("#!/bin/sh\n") and '_DEVICE_ID="vd-s1-fixture"' in script and '_NAMESPACE="teknoir-demo"' in script
assert "'v1.34.11+k3s1'" in ud["write_files"][1]["content"]
assert sys.argv[3] in script, "device user password missing from the bootstrap"
PY
in_cluster exists --secret-exists
[[ $IC_RC == 0 && $(cut -d' ' -f1,3 "$TMP/ic-exists.rec" | tr '\n' ',') == "GET 200," ]] && ok "existing Secret: exit 0 after one GET, no Device read, no POST (k3s token stays stable)" || bad "existing Secret: rc=$IC_RC requests $(tr '\n' ',' <"$TMP/ic-exists.rec")"
in_cluster nodevice --no-device
[[ $IC_RC != 0 && ! -e $TMP/ic-nodevice.rec.post ]] && grep -q 'create it in Backstage first' "$TMP/ic-nodevice.out" && ok "missing Device: fails and creates nothing" || bad "missing Device: rc=$IC_RC"
K3S_V=v1.34.12+k3s1 in_cluster newk3s
[[ $IC_RC != 0 && ! -e $TMP/ic-newk3s.rec.post ]] && grep -q keyCertSign "$TMP/ic-newk3s.out" && ok "k3s v1.34.12 with a certificate without keyCertSign: refused, nothing created" || bad "k3s v1.34.12: rc=$IC_RC"
K3S_V=v1.36.5+k3s1 in_cluster newk3s-ok --device-json "$TMP/device-certsign.json"
[[ $IC_RC == 0 && -e $TMP/ic-newk3s-ok.rec.post ]] && ok "k3s v1.36.5 with a keyCertSign certificate: accepted" || bad "k3s v1.36.5 with keyCertSign: rc=$IC_RC"
fixture "$TMP/nokey-ic.json" 'del(.spec.keys.data.rsa_private)'
in_cluster nokey --device-json "$TMP/nokey-ic.json"
[[ $IC_RC != 0 && ! -e $TMP/ic-nokey.rec.post ]] && ok "Device without rsa_private: fails and creates nothing" || bad "Device without rsa_private: rc=$IC_RC"
if "$RENDERER" -in-cluster -api-url https://127.0.0.1:1 -token-file "$TMP/sa-token" -ca-file "$TMP/srv-cert.pem" -device 'Bad_Name' \
  -namespace teknoir-demo -vdev-namespace teknoir-demo-vdev -domain teknoir.cloud -k3s-version "$VDS_K3S_VERSION" -cluster-cidr "$VDS_CLUSTER_CIDR" \
  -service-cidr "$VDS_SERVICE_CIDR" -cluster-dns "$VDS_CLUSTER_DNS" -cli-ref "$VDS_CLI_REF" >/dev/null 2>&1; then bad "invalid device name accepted"; else ok "invalid device name refused before any request"; fi

step "charts/virtual-device-spike"
if helm template s "$CHART" --set renderer.digest= >/dev/null 2>"$TMP/helm-nodigest.err"; then bad "chart rendered without renderer.digest"; else
  grep -q 'renderer.digest must be pinned' "$TMP/helm-nodigest.err" && ok "an empty renderer.digest fails the render" || bad "unexpected error without digest"; fi
helm template s "$CHART" --set renderer.digest="sha256:$(printf 'a%.0s' $(seq 64))" --set device.name=vd-s1-fixture >"$TMP/chart.yaml" && ok "helm template" || bad "helm template"
if kubeconform -strict -summary -kubernetes-version 1.34.0 -cache "$CACHE" \
  -schema-location default -schema-location "${CRDS_CATALOG}/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "$TMP/chart.yaml"; then ok "kubeconform -strict on the rendered chart"; else bad "kubeconform on the chart"; fi
python3 -I - "$TMP/chart.yaml" "$TMP/out/20-vm.yaml" <<'PY' && ok "chart = render.sh VM; Job, RBAC and render namespace as designed; no vdev namespace objects" || bad "chart assertions"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
key = lambda d: (d["kind"], d["metadata"]["name"])
by = {key(d): d for d in docs}
want = [d for f in sys.argv[2:3] for d in yaml.safe_load_all(open(f)) if d]
for w in want:
    c = yaml.safe_load(yaml.dump(by[key(w)]))
    ann = c["metadata"].get("annotations", {})
    ann.pop("argocd.argoproj.io/sync-wave", None)
    if w["kind"] == "VirtualMachine":
        ann.pop("teknoir.org/bootstrap"); w["metadata"]["annotations"].pop("teknoir.org/bootstrap")
    if not ann:
        c["metadata"].pop("annotations", None)
    assert c == w, f"{key(w)} differs from render.sh output"
assert by[("VirtualMachine", "vd-s1-fixture")]["metadata"]["annotations"]["argocd.argoproj.io/sync-wave"] == "2"
job = by[("Job", "vd-spike-render")]
a = job["metadata"]["annotations"]
assert a["argocd.argoproj.io/hook"] == "Sync" and a["argocd.argoproj.io/hook-delete-policy"] == "BeforeHookCreation" and a["argocd.argoproj.io/sync-wave"] == "1"
assert job["metadata"]["namespace"] == "teknoir-vdev-spike"
assert job["spec"]["backoffLimit"] == 3 and job["spec"]["activeDeadlineSeconds"] == 300
pod = job["spec"]["template"]["spec"]
c = pod["containers"][0]
assert c["securityContext"] == {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}}
assert pod["securityContext"]["runAsNonRoot"] is True and pod["securityContext"]["seccompProfile"] == {"type": "RuntimeDefault"}
assert c["image"].startswith("ghcr.io/teknoir/vdev-spike-render@sha256:") and c["resources"]["requests"] == {"cpu": "50m", "memory": "64Mi"}
assert "-in-cluster" in c["args"] and "-device=vd-s1-fixture" in c["args"]
ns = by[("Namespace", "teknoir-vdev-spike")]
assert ns["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "restricted" and ns["metadata"]["labels"]["istio-injection"] == "disabled"
assert not [d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"].get("namespace") == "teknoir-vdev-spike"]
# The vdev namespace, NetworkPolicies, ResourceQuota and LimitRange are owned by the
# device-controller Application (charts/device-controller virtual-devices-runtime.yaml),
# never by this chart: two owners made both Applications flap.
assert not [d for d in docs if d["kind"] in ("NetworkPolicy", "ResourceQuota", "LimitRange")], "vdev runtime objects must not be in this chart"
assert ("Namespace", "teknoir-demo-vdev") not in by, "vdev Namespace must not be in this chart"
rules = {(d["metadata"]["namespace"], d["metadata"]["name"]): d["rules"] for d in docs if d["kind"] == "Role"}
assert rules == {
    ("teknoir-demo", "vd-spike-render-device"): [{"apiGroups": ["teknoir.org"], "resources": ["devices"], "resourceNames": ["vd-s1-fixture"], "verbs": ["get"]}],
    ("teknoir-demo-vdev", "vd-spike-render-secret"): [
        {"apiGroups": [""], "resources": ["secrets"], "verbs": ["create"]},
        {"apiGroups": [""], "resources": ["secrets"], "resourceNames": ["vd-s1-fixture-cloudinit"], "verbs": ["get"]}],
}, rules
assert not [d for d in docs if d["kind"] in ("ClusterRole", "ClusterRoleBinding")]
PY

step "kc wrapper allows only read-only kubectl verbs"
FAKE_LOG="$TMP/kc.log"
export FAKE_LOG
(
  # shellcheck source-path=SCRIPTDIR/.. source=lib/common.sh
  . "${KIT}/lib/common.sh"
  # shellcheck disable=SC2030  # PATH is meant to change only in this subshell
  PATH="${HERE}/fakebin:$PATH"
  export KUBE_CONTEXT=fake-ctx
  for v in apply create delete patch edit replace label annotate scale exec cp port-forward run rollout drain cordon "auth reconcile"; do
    # shellcheck disable=SC2086
    if (kc $v x >/dev/null 2>&1); then echo "ALLOWED $v"; fi
  done
  for v in get describe logs version "auth can-i"; do
    # shellcheck disable=SC2086
    (kc $v x >/dev/null 2>&1) || true
  done
) >"$TMP/kc.out"
[[ ! -s $TMP/kc.out ]] && ok "write verbs refused (apply, create, delete, patch, exec, port-forward, ...)" || bad "kc allowed: $(cat "$TMP/kc.out")"
grep -qv -- '--context fake-ctx' "$TMP/kc.log" && bad "kc ran kubectl without --context" || ok "every kc call passes --context"

step "check.sh against a fake cluster: read-only and credential-free"
fixture "$TMP/device-ra.json" '.subresources.status.remote_access={"active":true,"port":"40123"}'
: >"$FAKE_LOG"
set +e
# shellcheck disable=SC2031  # PATH as of this shell, not the subshell above
PATH="${HERE}/fakebin:$PATH" FAKE_DEVICE="$TMP/device-ra.json" \
  "${KIT}/check.sh" --context fake-ctx --device vd-s1-fixture --phase all >"$TMP/check.out" 2>&1
rc=$?
set -e
[[ $rc == 1 ]] && ok "check.sh exits 1 when checks fail" || bad "check.sh exit status $rc (want 1)"
grep -q '^Summary: ' "$TMP/check.out" && ok "check.sh ran every phase to its summary" || { bad "check.sh did not finish"; tail -20 "$TMP/check.out"; }
for id in P1 P3 P6 P9 P14 P15 N1 V0 V1 D1 D2 G1 I0 T0; do
  grep -qE "^[A-Z]{4} +${id} " "$TMP/check.out" || bad "check.sh printed no result for $id"
done
verbs=$(grep -- '^--context fake-ctx' "$FAKE_LOG" | sed -E 's/^--context fake-ctx (-n [^ ]+ )?//' | awk '{print $1}' | sort -u)
bad_verbs=$(grep -vxE 'get|describe|logs|version|auth|api-resources' <<<"$verbs" || true)
read_verbs=$(tr '\n' ' ' <<<"$verbs")
[[ -z $bad_verbs ]] && grep -q -- '--context fake-ctx' "$FAKE_LOG" && ok "check.sh used only read verbs: ${read_verbs}" || bad "check.sh used other verbs: $bad_verbs"
grep '^--context' "$FAKE_LOG" | grep -q 'auth can-i' && ! grep '^--context' "$FAKE_LOG" | grep ' auth ' | grep -vq ' auth can-i ' &&
  ok "auth is only 'auth can-i'" || bad "check.sh used 'auth' other than 'auth can-i', or never ran 'auth can-i'"
# Every line of the log is a kubectl call with --context, or the fake ssh's ARGS/STDIN.
others=$(grep -vE '^(--context fake-ctx |ARGS |STDIN )' "$FAKE_LOG" || true)
[[ -z $others ]] && ok "every kubectl call passed --context fake-ctx" || bad "calls without --context: $(head -3 <<<"$others")"
grep -q '^ARGS ' "$FAKE_LOG" && ok "check.sh tried the guest transport (ssh)" || bad "check.sh never called ssh"
no_secrets_in "$TMP/check.out" "check.sh output"
if grep '^ARGS ' "$FAKE_LOG" | grep -qF -- "$PASSWORD" || grep '^ARGS ' "$FAKE_LOG" | grep -qF -- "$KEY_MARKER"; then
  bad "a credential appeared in ssh arguments"
else
  ok "ssh got the key as a file and the password only on stdin"
fi
grep '^ARGS ' "$FAKE_LOG" | grep -q 'deadend-teknoir-demo.teknoir.cloud' && grep '^ARGS ' "$FAKE_LOG" | grep -q -- '-p 40123' &&
  ok "tunnel transport goes through deadend-<ns>.<domain>:2222 to the device's tunnel port" || bad "tunnel transport arguments unexpected"

step "check.sh --phase removed: passes on a clean cluster, catches a wrong-order removal"
# shellcheck disable=SC2031  # PATH as of this shell, not the subshell above
fake_path="${HERE}/fakebin:$PATH"
: >"$FAKE_LOG"
set +e
PATH="$fake_path" "${KIT}/check.sh" --context fake-ctx --argocd-namespace argocd --phase removed >"$TMP/removed-clean.out" 2>&1
rc=$?
set -e
[[ $rc == 0 ]] && ok "clean cluster: exit 0" || { bad "clean cluster: exit $rc"; cat "$TMP/removed-clean.out"; }
grep -q '^FAIL' "$TMP/removed-clean.out" && bad "clean cluster reported a FAIL" || ok "clean cluster: no FAIL"
for id in R1 R2 R3 R3b R4 R5 R6 R7 R8 R8b R9; do
  grep -qE "^PASS +${id} " "$TMP/removed-clean.out" || bad "clean cluster: no PASS for ${id}"
done
grep -qE '^INFO +R10 .*1 labels' "$TMP/removed-clean.out" && ok "R10 reports the node labels virt-handler leaves behind" || bad "R10 did not report node labels"
grep -q -- '-n argocd get applications.argoproj.io virtual-devices' "$FAKE_LOG" && ok "--argocd-namespace is used for the Application" || bad "--argocd-namespace ignored"
verbs=$(grep -- '^--context fake-ctx' "$FAKE_LOG" | sed -E 's/^--context fake-ctx (-n [^ ]+ )?//' | awk '{print $1}' | sort -u)
[[ -z $(grep -vxE 'get|version|api-resources' <<<"$verbs" || true) ]] && ok "removed phase used only read verbs: $(tr '\n' ' ' <<<"$verbs")" || bad "removed phase used other verbs: $verbs"
set +e
PATH="$fake_path" FAKE_SCENARIO=leftover "${KIT}/check.sh" --context fake-ctx --phase removed >"$TMP/removed-left.out" 2>&1
rc=$?
set -e
[[ $rc == 1 ]] && ok "leftover cluster: exit 1" || bad "leftover cluster: exit $rc (want 1)"
for id in R2 R3 R3b R4 R5 R6 R7 R8 R8b R9; do
  grep -qE "^FAIL +${id} " "$TMP/removed-left.out" || { bad "leftover cluster: no FAIL for ${id}"; }
done
grep -qE '^FAIL +R3 .*v1\.subresources\.kubevirt\.io' "$TMP/removed-left.out" && grep -qE '^FAIL +R9 .*stale GroupVersion' "$TMP/removed-left.out" &&
  ok "leftover cluster: the stale APIService and the incomplete discovery are named" || bad "leftover cluster: stale APIService not named"
grep -qE '^FAIL +R3 .*v1\.kubevirt\.io' "$TMP/removed-left.out" && bad "R3 flagged a Local (CRD-backed) APIService" ||
  ok "R3 names only service-backed APIServices (a Local one goes with its CRD, R2)"
grep -qE '^FAIL +R4 .*cert-manager|^FAIL +R4 .*istio|^FAIL +R2 .*cert-manager|^FAIL +R8 .*(left: |,)(admin|cluster-admin)(,| |$)' "$TMP/removed-left.out" &&
  bad "leftover cluster: an unrelated object was flagged" || ok "leftover cluster: unrelated objects (cert-manager, istio, admin) are not flagged"
grep -qE '^PASS +R1 ' "$TMP/removed-left.out" && grep -qE '^PASS +R5 +namespace cdi' "$TMP/removed-left.out" &&
  ok "leftover cluster: objects that are gone still PASS" || bad "leftover cluster: R1/R5 cdi"
if PATH="$fake_path" "${KIT}/check.sh" --context fake-ctx --phase removed,platform >/dev/null 2>&1; then
  bad "--phase removed,platform was accepted"
else
  ok "--phase removed cannot be combined with other phases"
fi

step "k3d e2e: Argo CD timelines and the forced re-sync patch (jq/argo.jq)"
python3 -I "${HERE}/argo_jq_test.py" || bad "argo_jq_test.py"

printf '\n'
if ((fail)); then
  echo "kit tests FAILED"
  exit 1
fi
echo "kit tests passed"
