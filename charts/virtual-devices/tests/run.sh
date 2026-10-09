#!/usr/bin/env bash
# Tests for charts/virtual-devices and its app-of-apps wiring. No cluster needed.
#
#   charts/virtual-devices/tests/run.sh            offline checks (kubeconform fetches
#                                                  the Kubernetes 1.34 JSON schemas once
#                                                  into its cache)
#   VD_ONLINE=1 charts/virtual-devices/tests/run.sh
#                                                  also re-downloads the upstream manifests
#                                                  and proves the vendored files are a
#                                                  byte-identical rebuild
# shellcheck disable=SC2015  # "test && ok || bad": ok and bad always return 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${CHART}/../.." && pwd)"
AOA="${REPO}/charts/app-of-apps"
K8S_VERSION="1.34.0"

for t in helm kubeconform python3; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/kubeconform"
mkdir -p "$CACHE"

fail=0
step() { printf '\n--- %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

step "vendored manifests: checksums and image pins (offline)"
python3 -I "${CHART}/hack/vendor.py" verify || fail=1

if [[ ${VD_ONLINE:-0} == 1 ]]; then
  step "vendored manifests: byte-identical rebuild from upstream (online)"
  python3 -I "${CHART}/hack/vendor.py" rebuild --check || fail=1
fi

step "helm lint"
helm lint "$CHART" >"$TMP/lint.txt" 2>&1 && ok "helm lint" || { cat "$TMP/lint.txt"; bad "helm lint"; }

step "render with the teknoir-cloud values"
helm template virtual-devices "$CHART" --namespace kubevirt >"$TMP/render.yaml"
ok "rendered $(grep -c '^kind:' "$TMP/render.yaml") objects"

step "kubeconform -strict (Kubernetes ${K8S_VERSION} + schemas generated from the vendored CRDs)"
# The upstream Kubernetes JSON schemas have no CustomResourceDefinition schema; the two
# vendored CRDs are covered by their upstream sha256 and by the k3d e2e (server-side apply).
python3 -I "${HERE}/crd2schema.py" "$TMP/schemas" "${CHART}/vendor/kubevirt-operator.yaml" "${CHART}/vendor/cdi-operator.yaml"
if kubeconform -strict -summary -kubernetes-version "$K8S_VERSION" -cache "$CACHE" -skip CustomResourceDefinition \
  -schema-location default \
  -schema-location "$TMP/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$TMP/render.yaml"; then
  ok "kubeconform"
else
  bad "kubeconform"
fi

step "kubeconform rejects a misspelled KubeVirt field (the CRD schemas are strict)"
sed 's/disableSerialConsoleLog: {}/disableSerialConsolLog: {}/' "$TMP/render.yaml" >"$TMP/typo.yaml"
if kubeconform -strict -kubernetes-version "$K8S_VERSION" -cache "$CACHE" -skip CustomResourceDefinition -schema-location default \
  -schema-location "$TMP/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "$TMP/typo.yaml" >/dev/null 2>&1; then
  bad "a misspelled field passed validation"
else
  ok "misspelled field rejected"
fi

step "structural assertions"
python3 -I "${HERE}/assertions.py" "${CHART}/vendor/upstream.lock.yaml" "$TMP/render.yaml" || fail=1

step "feature toggles"
count_kind() { grep -c "^kind: $1\$" "$2" || true; }
helm template virtual-devices "$CHART" --set kubevirt.enabled=false >"$TMP/no-kv.yaml"
[[ $(count_kind KubeVirt "$TMP/no-kv.yaml") == 0 && $(grep -c 'name: virt-operator$' "$TMP/no-kv.yaml" || true) == 0 ]] &&
  ok "kubevirt.enabled=false renders no KubeVirt" || bad "kubevirt.enabled=false still renders KubeVirt"
helm template virtual-devices "$CHART" --set cdi.enabled=false >"$TMP/no-cdi.yaml"
[[ $(count_kind CDI "$TMP/no-cdi.yaml") == 0 && $(grep -c 'name: cdi-operator$' "$TMP/no-cdi.yaml" || true) == 0 ]] &&
  ok "cdi.enabled=false renders no CDI" || bad "cdi.enabled=false still renders CDI"
helm template virtual-devices "$CHART" --set coreDNS.enabled=false --set priorityClass.enabled=false >"$TMP/no-extras.yaml"
[[ $(grep -c 'name: coredns-custom' "$TMP/no-extras.yaml" || true) == 0 && $(grep -c 'name: teknoir-virtual-device' "$TMP/no-extras.yaml" || true) == 0 ]] &&
  ok "coreDNS/priorityClass toggles" || bad "coreDNS/priorityClass toggles"
if helm template virtual-devices "$CHART" --set priorityClass.value=0 >/dev/null 2>&1; then
  bad "priorityClass.value=0 was accepted"
else
  ok "priorityClass.value >= 0 is rejected"
fi
helm template virtual-devices "$CHART" --set coreDNS.domain=teknoir.airgapped >"$TMP/airgapped.yaml"
grep -q 'teknoir\\.airgapped\\.\$ ' "$TMP/airgapped.yaml" && ok "coreDNS.domain is escaped into the regex" || bad "coreDNS.domain not applied"

step "app-of-apps wiring (teknoir-cloud values)"
helm template app-of-apps "$AOA" >"$TMP/aoa.yaml"
python3 -I - "$TMP/aoa.yaml" <<'PY' || fail=1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
apps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Application"}
app = apps.get("virtual-devices")
assert app, "Application virtual-devices missing"
src = app["spec"]["source"]
assert src["path"] == "charts/virtual-devices", src
assert src["targetRevision"] == "teknoir-cloud", src
assert app["spec"]["project"] == "teknoir-cloud"
assert "ServerSideApply=true" in app["spec"]["syncPolicy"]["syncOptions"]
assert app["spec"]["syncPolicy"]["automated"]["prune"] is True
assert "finalizers" not in app["metadata"], "no cascading delete when the flag is turned off"
others = sorted(n for n in apps if n != "virtual-devices")
print("ok   Application virtual-devices -> charts/virtual-devices @ teknoir-cloud, ServerSideApply; other apps:", ", ".join(others))
PY
helm template app-of-apps "$AOA" --set virtualDevices.enabled=false >"$TMP/aoa-off.yaml"
grep -q 'name: virtual-devices' "$TMP/aoa-off.yaml" && bad "virtualDevices.enabled=false still renders the Application" || ok "virtualDevices.enabled=false renders no Application"
printf 'project: teknoir-cloud\n' >"$TMP/no-key.yaml"
cp -r "$AOA" "$TMP/aoa-nokey"
cp "$TMP/no-key.yaml" "$TMP/aoa-nokey/values.yaml"
helm template app-of-apps "$TMP/aoa-nokey" >"$TMP/aoa-nokey.yaml"
grep -q 'name: virtual-devices' "$TMP/aoa-nokey.yaml" && bad "a values file without virtualDevices renders the Application" || ok "default (no virtualDevices key) is off"
diff <(helm template app-of-apps "$TMP/aoa-nokey" | grep -v '^#') <(grep -v '^#' "$TMP/aoa-off.yaml") >/dev/null &&
  ok "with the flag off the app-of-apps output is unchanged" || bad "flag off changes other Applications"

printf '\n'
if ((fail)); then
  echo "chart tests FAILED"
  exit 1
fi
echo "chart tests passed"
