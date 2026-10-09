#!/usr/bin/env bash
# End-to-end test of charts/virtual-devices and the spike kit on a throwaway k3d
# cluster with KVM. HEAVY: about 2 GB of images and 15-30 minutes. Run it under the
# shared lock, e.g.
#   flock /path/to/heavy.lock hack/virtual-device-spike/test/k3d-e2e.sh
#
# It creates cluster vd-s1-e2e (k3s v1.34.5, like r415) with its own kubeconfig (the
# default kubeconfig and current context are not touched), then:
#   1. applies the chart the way Argo CD syncs it (operators first, then the CRs);
#   2. adds stand-ins for the platform (gateway, teamspace services) and the Device CRD
#      with a fixture Device holding a throwaway key;
#   3. checks that the CoreDNS override takes effect and how (reload or restart);
#   4. renders the kit for the fixture Device, applies it, waits for the guest's
#      tnctl bootstrap to finish;
#   5. runs check.sh --phase all over the virtctl transport with --inner-pod and
#      compares the results with what this environment can show.
# The cluster is deleted on exit unless KEEP=1.
#
# Needs: docker, k3d, kubectl, helm, jq, python3 (PyYAML), go, openssl, curl, /dev/kvm.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${KIT}/../.." && pwd)"
# shellcheck source-path=SCRIPTDIR/.. source=lib/pins.sh
. "${KIT}/lib/pins.sh"

CLUSTER=vd-s1-e2e
CTX="k3d-${CLUSTER}"
K3S_IMAGE="docker.io/rancher/k3s:v1.34.5-k3s1@sha256:998f4db28a13143ada759690b554c5d8c1814ac03f77c1bdd78bbd73875a1379"
VIRTCTL_URL="https://github.com/kubevirt/kubevirt/releases/download/${VDS_KUBEVIRT_VERSION}/virtctl-${VDS_KUBEVIRT_VERSION}-linux-amd64"
VIRTCTL_SHA256="7125d69c3b3e9c8185c106d9cdf77a817491e4657ac47f4509fb40d7aea59cca" # GitHub release asset digest
DEVICE=vd-s1-fixture
KEEP=${KEEP:-0}
DISK=${DISK:-containerdisk}

log() { printf '[e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
for t in docker k3d kubectl helm jq python3 go openssl curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[[ -c /dev/kvm ]] || die "/dev/kvm is required"

TMP=$(mktemp -d)
chmod 700 "$TMP"
export KUBECONFIG="${TMP}/kubeconfig"
cleanup() {
  local rc=$?
  if [[ $KEEP == 1 ]]; then
    log "KEEP=1: cluster ${CLUSTER} kept; kubeconfig ${KUBECONFIG}"
  else
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$TMP"
  fi
  exit "$rc"
}
trap cleanup EXIT
k() { kubectl --context "$CTX" "$@"; }

# Poll until a command prints something matching a regex.
wait_for() { # wait_for SECONDS REGEX DESCRIPTION CMD...
  local deadline=$(($(date +%s) + $1)) re=$2 what=$3 out=""
  shift 3
  while (($(date +%s) < deadline)); do
    out=$("$@" 2>/dev/null || true)
    [[ $out =~ $re ]] && { log "$what: $out"; return 0; }
    sleep 10
  done
  log "timed out waiting for $what (last: ${out:-<nothing>})"
  return 1
}

# ------------------------------------------------------------------ virtctl
VIRTCTL_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/teknoir-vd-spike/virtctl-${VDS_KUBEVIRT_VERSION}"
if [[ ! -x ${VIRTCTL_DIR}/virtctl ]]; then
  mkdir -p "$VIRTCTL_DIR"
  curl -fsSL -o "${VIRTCTL_DIR}/virtctl.download" "$VIRTCTL_URL"
  echo "${VIRTCTL_SHA256}  ${VIRTCTL_DIR}/virtctl.download" | sha256sum -c - >/dev/null || die "virtctl checksum mismatch"
  chmod 755 "${VIRTCTL_DIR}/virtctl.download"
  mv "${VIRTCTL_DIR}/virtctl.download" "${VIRTCTL_DIR}/virtctl"
fi
export PATH="${VIRTCTL_DIR}:$PATH"

# ------------------------------------------------------------------ cluster
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE%@*})"
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait --timeout 300s \
  --k3s-arg '--disable=traefik@server:0' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false >/dev/null
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
k get nodes -o wide

# ------------------------------------------------------------------ chart, as Argo CD syncs it
log "rendering charts/virtual-devices"
helm template virtual-devices "${REPO}/charts/virtual-devices" --namespace kubevirt >"${TMP}/chart.yaml"
python3 -I - "${TMP}/chart.yaml" "${TMP}/wave0.yaml" "${TMP}/wave1.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
w1 = [d for d in docs if d["metadata"].get("annotations", {}).get("argocd.argoproj.io/sync-wave") == "1"]
w0 = [d for d in docs if d not in w1]
yaml.safe_dump_all(w0, open(sys.argv[2], "w"))
yaml.safe_dump_all(w1, open(sys.argv[3], "w"))
print(f"wave 0: {len(w0)} objects, wave 1: {[d['kind'] for d in w1]}")
PY
k apply --server-side -f "${TMP}/wave0.yaml" >/dev/null
k wait --for=condition=Established crd/kubevirts.kubevirt.io crd/cdis.cdi.kubevirt.io --timeout=120s >/dev/null
k -n kubevirt rollout status deploy/virt-operator --timeout=900s
k -n cdi rollout status deploy/cdi-operator --timeout=900s
k apply --server-side -f "${TMP}/wave1.yaml"
wait_for 1500 '^Deployed$' "KubeVirt phase" k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}' || {
  k -n kubevirt get pods -o wide
  die "KubeVirt did not deploy"
}
wait_for 900 '^Deployed$' "CDI phase" k get cdi cdi -o jsonpath='{.status.phase}' || die "CDI did not deploy"
wait_for 300 '^[1-9]' "devices.kubevirt.io/kvm allocatable" k get nodes -o jsonpath='{.items[0].status.allocatable.devices\.kubevirt\.io/kvm}' ||
  die "no KVM device on the node"

# ------------------------------------------------------------------ platform stand-ins
log "platform stand-ins, Device CRD and fixture Device"
k apply -f "${HERE}/e2e-fake-platform.yaml" >/dev/null
k apply --server-side -f "${REPO}/charts/device-controller/crds/" >/dev/null
k wait --for=condition=Established crd/devices.teknoir.org --timeout=60s >/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=teknoir.ai" -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" 2>/dev/null
PASSWORD="e2e-$(openssl rand -hex 12)"
jq --arg k "$(base64 -w0 <"${TMP}/key.pem")" --arg c "$(base64 -w0 <"${TMP}/cert.pem")" --arg p "$(printf '%s' "$PASSWORD" | base64 -w0)" \
  '.spec.keys.data.rsa_private=$k | .spec.keys.data.rsa_public=$c | .spec.keys.data.userpassword=$p' \
  "${HERE}/fixtures/device.json" >"${TMP}/device.json"
k apply -f "${TMP}/device.json" >/dev/null
k -n istio-system rollout status deploy/istio-ingressgateway-public --timeout=300s >/dev/null
k -n teknoir-demo rollout status deploy/fake-teamspace --timeout=300s >/dev/null
k -n teknoir-system rollout status deploy/platform-pod --timeout=300s >/dev/null

# ------------------------------------------------------------------ CoreDNS override
GW_IP=$(k -n istio-system get svc istio-ingressgateway-public -o jsonpath='{.spec.clusterIP}')
dns_answer() {
  k -n default run "dns-$RANDOM" --rm -i --quiet --restart=Never --image="$VDS_PROBE_IMAGE" -- \
    nslookup -type=a "mqtt-teknoir-demo.${VDS_DOMAIN:-teknoir.cloud}" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1
}
COREDNS_NOTE=""
if wait_for 180 "^${GW_IP//./\\.}$" "CoreDNS answer for mqtt-teknoir-demo.teknoir.cloud (no restart)" dns_answer; then
  COREDNS_NOTE="picked up coredns-custom without a restart"
else
  log "restarting CoreDNS to load coredns-custom"
  k -n kube-system rollout restart deploy/coredns >/dev/null
  k -n kube-system rollout status deploy/coredns --timeout=180s >/dev/null
  wait_for 120 "^${GW_IP//./\\.}$" "CoreDNS answer after restart" dns_answer || die "CoreDNS override has no effect"
  COREDNS_NOTE="needed a restart to load coredns-custom"
fi
log "CoreDNS ${COREDNS_NOTE}"

# ------------------------------------------------------------------ kit
log "rendering the kit for ${DEVICE} (disk: ${DISK})"
OUT=$("${KIT}/render.sh" --device "$DEVICE" --fixture "${TMP}/device.json" --context "$CTX" --disk "$DISK" --out "${TMP}/render" 2>"${TMP}/render.log") ||
  { cat "${TMP}/render.log"; die "render failed"; }
T_APPLY=$(date +%s)
k apply -f "${OUT}/00-namespace.yaml"
k create -f "${OUT}/10-cloudinit-secret.yaml"
k create -f "${OUT}/20-vm.yaml"
wait_for 1800 '^Succeeded$' "DataVolume ${DEVICE}-root" k -n teknoir-demo-vdev get dv "${DEVICE}-root" -o jsonpath='{.status.phase}' || {
  k -n teknoir-demo-vdev get dv,pvc,pods -o wide
  k -n teknoir-demo-vdev get events --sort-by=.lastTimestamp | tail -20
  die "root disk import failed"
}
wait_for 900 '^Running$' "VMI phase" k -n teknoir-demo-vdev get vmi "$DEVICE" -o jsonpath='{.status.phase}' || {
  k -n teknoir-demo-vdev get vmi,pods -o wide
  k -n teknoir-demo-vdev get events --sort-by=.lastTimestamp | tail -20
  die "VMI not running"
}
wait_for 900 '^True$' "guest agent" k -n teknoir-demo-vdev get vmi "$DEVICE" -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' ||
  log "guest agent did not connect (continuing; check.sh reports it)"

# Wait for the bootstrap to finish (read over virtctl port-forward + SSH as the device user).
guest() {
  ssh -F /dev/null -i "${TMP}/key.pem" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -o ProxyCommand="virtctl --context ${CTX} port-forward --stdio=true vmi/${DEVICE}.teknoir-demo-vdev 22" \
    teknoir@vmi "$@"
}
bootstrap_exit() { printf '%s\n' "$PASSWORD" | guest "sudo -S -p '' cat /var/lib/teknoir-spike/bootstrap-exit"; }
wait_for 1800 '^[0-9]+$' "bootstrap exit status" bootstrap_exit || log "bootstrap did not finish (continuing; check.sh reports it)"
log "applied -> bootstrap finished: $(($(date +%s) - T_APPLY))s"
# Let TOE try to connect for a minute so its log has something to report.
sleep 60

# ------------------------------------------------------------------ check.sh
log "running check.sh --phase all --transport virtctl --inner-pod"
set +e
"${KIT}/check.sh" --context "$CTX" --device "$DEVICE" --phase all --transport virtctl --inner-pod | tee "${TMP}/check.out"
set -e

# Expected in this environment: no Argo CD (P2), no device-controller DeviceState
# (D2), the stand-in gateway is not EMQX, so TOE cannot complete a TLS/MQTT
# connection (G12) and never comes online (T1).
EXPECTED_FAIL="P2 D2 G12 T1"
MUST_PASS="P1 P3 P4 P5 P6 P7k P8k P7c P8c P9 P10 P11 N1 N2 N4 N5 V0 V2 V3 V4 V5 V6 V7 V8 V9a G1 G3 G4 G5 G6 G7 G8 G9 G10 G11 G14 I1 I2 I3 I4 I5 I6 I7 I8 I9 I10 I11 I12 I13 I14 I15"
fail=0
for id in $MUST_PASS; do
  grep -qE "^PASS +${id} " "${TMP}/check.out" || { log "expected PASS for ${id}"; fail=1; }
done
while read -r id; do
  [[ " $EXPECTED_FAIL " == *" $id "* ]] || { log "unexpected FAIL ${id}"; fail=1; }
done < <(awk '$1=="FAIL"{print $2}' "${TMP}/check.out" | sort -u)
grep -qF -- "$PASSWORD" "${TMP}/check.out" && { log "the device password appeared in check.sh output"; fail=1; }
grep -q 'PRIVATE KEY' "${TMP}/check.out" && { log "a private key appeared in check.sh output"; fail=1; }

log "CoreDNS: ${COREDNS_NOTE}"
if ((fail)); then
  log "k3d e2e FAILED"
  exit 1
fi
log "k3d e2e passed"
