#!/usr/bin/env bash
# render.sh: render, never apply, the S1 spike manifests for one test Device.
#
# Output (a private 0700 directory):
#   00-namespace.yaml          <ns>-vdev: PSA labels, NetworkPolicies, ResourceQuota, LimitRange
#   10-cloudinit-secret.yaml   cloud-init user data with the rendered tnctl server bootstrap (SECRET, 0600)
#   20-vm.yaml                 KubeVirt VirtualMachine (Debian 13 root disk imported by CDI)
#   summary.txt                inputs, pins and the commands to apply and to clean up
#
# The bootstrap is the real tnctl server script (cli pkg/templates at a pinned commit),
# rendered from the Device's keys exactly as `tnctl bootstrap` does. The only additions
# are environment variables the script already honours: CREATE_USER=true,
# INSTALL_K3S_VERSION and INSTALL_K3S_EXEC (inner k3s CIDRs). Secrets are written only
# to files with mode 0600 inside the private directory and are never printed.
#
# Cluster access (only with --source kubectl, the default): kubectl get on the Device
# and on Deployments in the teamspace. Nothing is created, changed or deleted.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
umask 077

usage() {
  cat <<EOF
Usage: $(basename "$0") --device NAME [options]

Required:
  --device NAME          the test Device (must already exist in the teamspace)

Device source (one of):
  --source kubectl       read the Device with 'kubectl get' (default; read-only)
  --source tnctl         run 'tnctl bootstrap NAME --skip-upload' (needs 'tnctl login')
  --fixture FILE         read the Device JSON from FILE (offline dry render; no cluster)

Options:
  --namespace NS         teamspace (default: teknoir-demo); runtime namespace is NS-vdev
  --domain DOMAIN        platform domain (default: teknoir.cloud)
  --context CTX          kubectl context (default: r415)
  --out DIR              output directory, created 0700, must be empty (default: mktemp)
  --cpu N                vCPUs (default: 2)
  --memory-gi N          guest memory in GiB (default: 4)
  --disk-gi N            root disk in GiB (default: 20)
  --cpu-overcommit N     cpu request = vCPU / N (default: 2)
  --disk containerdisk|generic
                         root disk source (default: containerdisk = Debian 13 genericcloud
                         containerdisk by digest; generic = Debian 13 generic qcow2 over
                         HTTPS with SHA512 verification)
  --cpu-model MODEL      KubeVirt CPU model (default: cluster default host-model)
  --k3s-version V        inner k3s version (default: ${VDS_K3S_VERSION})
  --egress internet|platform-only
                         NetworkPolicy egress profile (default: internet, as staging)
  --allow-harbor         also allow egress to istio=ingressgateway pods on 443 (airgap Harbor)
  --allow-virtctl-ssh    allow ingress to port 22 from KubeVirt's virt-api pods, so
                         'virtctl ssh/port-forward' works (virt-api dials the VM's pod IP;
                         the default-deny policy blocks it otherwise)
  --debug-user           add a break-glass guest user 'vdspike' (the device's SSH public
                         key, passwordless sudo) to inspect the guest while the bootstrap
                         is still running or hung; the device's own user is unchanged
  --allowance-devices N  devices the ResourceQuota budgets for (default: 2)
  --cli-src DIR          local clone of github.com/teknoir/cli containing ${VDS_CLI_REF:0:12}
                         (default: \$TEKNOIR_CLI_SRC or ~/git/ai/cli if it has the commit,
                         else a fresh clone of ${VDS_CLI_REPO_URL})
  --namespace-only       render only 00-namespace.yaml (no Device needed)
  -h, --help
EOF
}

DEVICE=""
NAMESPACE="teknoir-demo"
DOMAIN="teknoir.cloud"
KUBE_CONTEXT="r415"
SOURCE="kubectl"
FIXTURE=""
OUT=""
CPU=2
MEMORY_GI=4
DISK_GI=20
CPU_OVERCOMMIT=2
DISK="containerdisk"
CPU_MODEL=""
K3S_VERSION="${VDS_K3S_VERSION}"
EGRESS="internet"
ALLOW_HARBOR=false
ALLOW_VIRTCTL_SSH=false
DEBUG_USER=false
ALLOWANCE_DEVICES=2
CLI_SRC="${TEKNOIR_CLI_SRC:-}"
NAMESPACE_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=$2; shift 2 ;;
    --source) SOURCE=$2; shift 2 ;;
    --fixture) SOURCE=fixture; FIXTURE=$2; shift 2 ;;
    --namespace) NAMESPACE=$2; shift 2 ;;
    --domain) DOMAIN=$2; shift 2 ;;
    --context) KUBE_CONTEXT=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    --cpu) CPU=$2; shift 2 ;;
    --memory-gi) MEMORY_GI=$2; shift 2 ;;
    --disk-gi) DISK_GI=$2; shift 2 ;;
    --cpu-overcommit) CPU_OVERCOMMIT=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --cpu-model) CPU_MODEL=$2; shift 2 ;;
    --k3s-version) K3S_VERSION=$2; shift 2 ;;
    --egress) EGRESS=$2; shift 2 ;;
    --allow-harbor) ALLOW_HARBOR=true; shift ;;
    --allow-virtctl-ssh) ALLOW_VIRTCTL_SSH=true; shift ;;
    --debug-user) DEBUG_USER=true; shift ;;
    --allowance-devices) ALLOWANCE_DEVICES=$2; shift 2 ;;
    --cli-src) CLI_SRC=$2; shift 2 ;;
    --namespace-only) NAMESPACE_ONLY=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

# ---------------------------------------------------------------- validation
is_dns_label "$NAMESPACE" || die "--namespace '$NAMESPACE' is not a DNS label"
VDEV_NS="${NAMESPACE}-vdev"
is_dns_label "$VDEV_NS" || die "runtime namespace '$VDEV_NS' is longer than 63 characters"
[[ $DOMAIN =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$ ]] || die "--domain '$DOMAIN' is not a DNS name"
for n in CPU MEMORY_GI DISK_GI CPU_OVERCOMMIT ALLOWANCE_DEVICES; do
  [[ ${!n} =~ ^[1-9][0-9]*$ ]] || die "--$(tr '[:upper:]_' '[:lower:]-' <<<"$n") must be a positive integer"
done
((CPU <= 64)) || die "--cpu must be at most 64"
((MEMORY_GI >= 2)) || die "--memory-gi must be at least 2 (k3s server minimum)"
((DISK_GI >= 10)) || die "--disk-gi must be at least 10"
case "$DISK" in containerdisk | generic) ;; *) die "--disk must be containerdisk or generic" ;; esac
case "$EGRESS" in internet | platform-only) ;; *) die "--egress must be internet or platform-only" ;; esac
case "$SOURCE" in kubectl | tnctl | fixture) ;; *) die "--source must be kubectl or tnctl (or use --fixture FILE)" ;; esac
[[ $K3S_VERSION =~ ^v1\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]] || die "--k3s-version '$K3S_VERSION' is not a k3s release tag (e.g. ${VDS_K3S_VERSION})"
[[ -z $CPU_MODEL || $CPU_MODEL =~ ^[A-Za-z0-9_.-]+$ ]] || die "--cpu-model '$CPU_MODEL' is not a CPU model name"
if [[ $NAMESPACE_ONLY != true ]]; then
  [[ -n $DEVICE ]] || { usage >&2; die "--device is required"; }
  is_dns_label "$DEVICE" || die "--device '$DEVICE' is not a DNS label"
  ((${#DEVICE} <= 58)) || die "--device '$DEVICE' is longer than 58 characters (the root DataVolume is <device>-root)"
fi

need jq base64 awk
OUT=$(make_private_dir "$OUT")
WORK=$(mktemp -d "${OUT}/.work.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# labels INDENT [extra "key: value" ...]: the kit's labels, one per line, indented.
labels() {
  local pad l
  pad=$(printf '%*s' "$1" '')
  shift
  for l in "$@" "teknoir.org/teamspace: ${NAMESPACE}" "teknoir.org/component: virtual-device" \
    "teknoir.org/spike: s1" "app.kubernetes.io/managed-by: vd-spike-kit"; do
    printf '%s%s\n' "$pad" "$l"
  done
}

# ---------------------------------------------------------------- 00-namespace.yaml
render_namespace() {
  local d=$ALLOWANCE_DEVICES
  # ResourceQuota sized for d devices of the rendered size, with the KubeVirt/CDI
  # overhead headroom from the design critique (#10):
  #  - virt-launcher adds ~250-300Mi of memory overhead to the pod request and limit
  #    -> budget +1Gi per device;
  #  - the CDI importer pod (requests 100m/60M, limits 750m/600M) runs while a disk
  #    imports -> +1 CPU and +1Gi of limits for the namespace;
  #  - while a DataVolume imports, CDI's prime PVC is as large as the target PVC, and
  #    filesystem-mode PVCs are inflated by CDI's 5.5% filesystem overhead
  #    -> requests.storage = 2 x 1.1 x disk per device.
  local req_cpu_m=$((d * CPU * 1000 / CPU_OVERCOMMIT + 1000))
  local lim_cpu=$((d * CPU + 1))
  local req_mem=$((d * (MEMORY_GI + 1)))
  local lim_mem=$((d * (MEMORY_GI + 1) + 1))
  local storage=$(((d * DISK_GI * 2 * 11 + 9) / 10))
  cat <<EOF
# Runtime namespace for virtual devices of teamspace ${NAMESPACE} (S1 spike on r415).
# Rendered by hack/virtual-device-spike/render.sh. Teamspace users get no RoleBindings
# here; the device reaches the platform only through the public ingress gateway.
apiVersion: v1
kind: Namespace
metadata:
  name: ${VDEV_NS}
  # istio-injection disabled: no sidecars, the device must use the public gateway
  # like an external device. PSA enforce=baseline is an S1 check (does virt-launcher
  # pass it? fallback: warn, with the violations documented).
  labels:
$(labels 4 "istio-injection: disabled" \
    "pod-security.kubernetes.io/enforce: baseline" "pod-security.kubernetes.io/enforce-version: latest" \
    "pod-security.kubernetes.io/warn: restricted" "pod-security.kubernetes.io/warn-version: latest" \
    "pod-security.kubernetes.io/audit: restricted" "pod-security.kubernetes.io/audit-version: latest")
---
# Default deny in both directions for every pod in the namespace (virt-launcher, CDI
# importer). Nothing needs inbound traffic: operators reach the device only through its
# reverse tunnel to deadend. The policies below add the minimum egress.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-default-deny
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# DNS: the guest's resolver is the outer kube-dns (10.43.0.10, handed out by the
# masquerade DHCP). kube-proxy DNATs it to the CoreDNS pods, which this selects.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-egress-dns
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
# Platform endpoints, exactly as an external device uses them: MQTT over TLS (8883),
# MQTT over WSS (8084) and the deadend reverse tunnel (2222), all on the public
# ingress gateway. mqtt-/deadend-<ns>.<domain> resolve to the gateway's ClusterIP
# (charts/virtual-devices CoreDNS override); kube-proxy DNATs that to the gateway
# pods, so the rule selects pods. The LoadBalancer IP is the node IP on r415, so an
# ipBlock for it would also open node:6443 and node:10250.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-egress-gateway
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              istio: ingressgateway-public
      ports:
        - protocol: TCP
          port: 8883
        - protocol: TCP
          port: 8084
        - protocol: TCP
          port: 2222
EOF
  if [[ $ALLOW_VIRTCTL_SSH == true ]]; then
    cat <<EOF
---
# Optional (--allow-virtctl-ssh): KubeVirt's port-forward (virtctl ssh/port-forward)
# is dialed by the virt-api pods to the VM's pod IP, so default-deny blocks it. This
# opens only port 22 and only to virt-api; using it still needs the
# virtualmachineinstances/portforward subresource, which teamspace users lack here.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-ingress-virtctl-ssh
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector:
    matchLabels:
      kubevirt.io: virt-launcher
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kubevirt
          podSelector:
            matchLabels:
              kubevirt.io: virt-api
      ports:
        - protocol: TCP
          port: 22
EOF
  fi
  if [[ $ALLOW_HARBOR == true ]]; then
    cat <<EOF
---
# Airgap only (critique #4): the inner k3s pulls through Harbor on 443 of the
# istio=ingressgateway pods. Verify first which pod the LoadBalancer VIP is DNATed to.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-egress-harbor
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: istio-system
          podSelector:
            matchLabels:
              istio: ingressgateway
      ports:
        - protocol: TCP
          port: 443
EOF
  fi
  if [[ $EGRESS == internet ]]; then
    cat <<EOF
---
# Internet egress like a real device on staging: everything except private,
# carrier-grade NAT, link-local (cloud metadata), loopback, "this network",
# multicast and reserved ranges. This also keeps the outer pod (10.42/16) and
# service (10.43/16) networks, the node (192.168/16, including kubelet 10250 and the
# API server 6443) and other teamspaces out of reach. Omitted with --egress platform-only.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vdev-egress-internet
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 0.0.0.0/8
              - 10.0.0.0/8
              - 100.64.0.0/10
              - 127.0.0.0/8
              - 169.254.0.0/16
              - 172.16.0.0/12
              - 192.168.0.0/16
              - 224.0.0.0/4
              - 240.0.0.0/4
EOF
  fi
  cat <<EOF
---
# Budget for ${d} device(s) of ${CPU} vCPU / ${MEMORY_GI}Gi / ${DISK_GI}Gi at cpu overcommit ${CPU_OVERCOMMIT},
# including KubeVirt and CDI overhead (see render.sh render_namespace).
apiVersion: v1
kind: ResourceQuota
metadata:
  name: vdev-quota
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  hard:
    requests.cpu: "${req_cpu_m}m"
    limits.cpu: "${lim_cpu}"
    requests.memory: "${req_mem}Gi"
    limits.memory: "${lim_mem}Gi"
    requests.storage: "${storage}Gi"
    persistentvolumeclaims: "$((d * 3))"
    pods: "$((d * 2 + 2))"
    services: "0"
    services.loadbalancers: "0"
    services.nodeports: "0"
    count/secrets: "$((d * 2 + 2))"
    count/virtualmachines.kubevirt.io: "${d}"
    count/virtualmachineinstances.kubevirt.io: "${d}"
    count/datavolumes.cdi.kubevirt.io: "${d}"
    requests.nvidia.com/gpu: "0"
---
# Defaults for containers that set no resources (the quota above requires them) and
# per-object maximums: the largest design preset (4 vCPU / 16Gi / 80Gi) plus KubeVirt
# memory overhead and CDI filesystem overhead.
apiVersion: v1
kind: LimitRange
metadata:
  name: vdev-limits
  namespace: ${VDEV_NS}
  labels:
$(labels 4)
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 50m
        memory: 64Mi
      max:
        cpu: "4"
        memory: 17Gi
    - type: PersistentVolumeClaim
      max:
        storage: 90Gi
EOF
}

render_namespace >"${OUT}/00-namespace.yaml"
if [[ $NAMESPACE_ONLY == true ]]; then
  log "Rendered ${OUT}/00-namespace.yaml"
  printf '%s\n' "$OUT"
  exit 0
fi

# ---------------------------------------------------------------- the Device
DEVICE_JSON="${WORK}/device.json"
case "$SOURCE" in
  fixture)
    [[ -r $FIXTURE ]] || die "--fixture '$FIXTURE' is not readable"
    jq -e . "$FIXTURE" >/dev/null || die "--fixture '$FIXTURE' is not JSON"
    cp "$FIXTURE" "$DEVICE_JSON"
    ;;
  kubectl | tnctl)
    need kubectl
    kc -n "$NAMESPACE" get device "$DEVICE" -o json >"$DEVICE_JSON" ||
      die "Device ${NAMESPACE}/${DEVICE} not found in context ${KUBE_CONTEXT} (create it in Backstage first)"
    ;;
esac
chmod 600 "$DEVICE_JSON"
[[ $(jq -r '.metadata.name' "$DEVICE_JSON") == "$DEVICE" ]] || die "Device JSON is not for '$DEVICE'"
[[ $(jq -r '.metadata.namespace' "$DEVICE_JSON") == "$NAMESPACE" ]] || die "Device '$DEVICE' is not in namespace '$NAMESPACE'"
DEVICE_TYPE=$(jq -r '.spec.device_type // ""' "$DEVICE_JSON")
if [[ $SOURCE != fixture && $DEVICE_TYPE == virtual ]]; then
  # The 2024 VirtualDevice plugin (still in deployed controllers until Phase 0 ships)
  # creates a privileged virtual-device-<name> Deployment for device_type virtual.
  if kc -n "$NAMESPACE" get deployment "virtual-device-${DEVICE}" >/dev/null 2>&1; then
    die "Deployment ${NAMESPACE}/virtual-device-${DEVICE} exists: the deployed device-controller still runs the 2024 VirtualDevice plugin. Use a test Device with a non-virtual board, or deploy the Phase 0 controller first (README, step 3)."
  fi
  log "note: device_type is 'virtual' and no virtual-device-${DEVICE} Deployment exists"
fi

# ---------------------------------------------------------------- the bootstrap
SCRIPT="${WORK}/bootstrap.sh"
RENDER_SUMMARY="${WORK}/render-summary.json"

resolve_cli_src() {
  local c
  for c in "$CLI_SRC" "${HOME}/git/ai/cli"; do
    [[ -n $c && -d $c ]] || continue
    if git -C "$c" cat-file -e "${VDS_CLI_REF}^{commit}" 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
    [[ $c == "$CLI_SRC" ]] && die "--cli-src $c does not contain commit ${VDS_CLI_REF}"
  done
  return 1
}

build_renderer() {
  need go git tar
  local main="${VDS_DIR}/renderer/main.go"
  local key
  key="$(printf '%s %s' "$VDS_CLI_REF" "$(sha256_of "$main")" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-16)"
  local cache="${XDG_CACHE_HOME:-${HOME}/.cache}/teknoir-vd-spike/renderer-${key}"
  if [[ -x ${cache}/vdev-spike-render ]]; then
    printf '%s\n' "${cache}/vdev-spike-render"
    return 0
  fi
  local build src
  build=$(mktemp -d "${TMPDIR:-/tmp}/vd-spike-build.XXXXXX")
  if src=$(resolve_cli_src); then
    log "renderer: using templates from ${src} at ${VDS_CLI_REF:0:12}"
  else
    log "renderer: cloning ${VDS_CLI_REPO_URL} for ${VDS_CLI_REF:0:12}"
    src="${build}/cli.git"
    git clone --quiet --bare --filter=blob:none "$VDS_CLI_REPO_URL" "$src" >&2
    git -C "$src" cat-file -e "${VDS_CLI_REF}^{commit}" || die "commit ${VDS_CLI_REF} not found in ${VDS_CLI_REPO_URL}"
  fi
  mkdir -p "${build}/mod/cmd/vdev-spike-render"
  git -C "$src" archive "$VDS_CLI_REF" go.mod go.sum pkg/templates | tar -x -C "${build}/mod"
  grep -qx 'module teknoir/cli' "${build}/mod/go.mod" || die "unexpected module path in cli go.mod at ${VDS_CLI_REF}"
  cp "$main" "${build}/mod/cmd/vdev-spike-render/main.go"
  mkdir -p "$cache"
  (cd "${build}/mod" && GOWORK=off GOFLAGS=-mod=mod CGO_ENABLED=0 go build -trimpath -o "${cache}/vdev-spike-render" ./cmd/vdev-spike-render) >&2 ||
    die "building the renderer failed"
  rm -rf "$build"
  printf '%s\n' "${cache}/vdev-spike-render"
}

case "$SOURCE" in
  kubectl | fixture)
    RENDERER=$(build_renderer)
    "$RENDERER" -device-json "$DEVICE_JSON" -domain "$DOMAIN" -out "$SCRIPT" >"$RENDER_SUMMARY"
    TEMPLATE_SHA256=$(jq -r .templateSha256 "$RENDER_SUMMARY")
    BOOTSTRAP_SOURCE="cli ${VDS_CLI_REF:0:12} pkg/templates/server.sh.tmpl (sha256 ${TEMPLATE_SHA256})"
    ;;
  tnctl)
    need tnctl
    log "running: tnctl -d ${DOMAIN} -n ${NAMESPACE} bootstrap ${DEVICE} --skip-upload (in the private directory)"
    (cd "$WORK" && umask 077 && tnctl -d "$DOMAIN" -n "$NAMESPACE" bootstrap "$DEVICE" --skip-upload >/dev/null) ||
      die "tnctl bootstrap failed (is 'tnctl login --domain ${DOMAIN}' done?)"
    mv "${WORK}/bootstrap_server_${DEVICE}.sh" "$SCRIPT"
    rm -f "${WORK}/bootstrap_agent_${DEVICE}.sh" "${WORK}/bootstrap_docker_server_${DEVICE}.sh"
    BOOTSTRAP_SOURCE="tnctl $(tnctl --version 2>/dev/null | head -n1 || echo '(version unknown)') bootstrap --skip-upload"
    ;;
esac
chmod 600 "$SCRIPT"

# The tnctl template installs the device certificate (rsa_public) as the k3s root CA.
# k3s >= v1.34.12/v1.35.9/v1.36.5 ignores a root without keyCertSign when it validates
# its own /cacerts and never becomes ready (README "Finding"). Refuse that combination.
if k3s_prunes_noncertsign_roots "$K3S_VERSION"; then
  need openssl
  if ! jq -r '.spec.keys.data.rsa_public // ""' "$DEVICE_JSON" | base64 -d 2>/dev/null |
    openssl x509 -noout -ext keyUsage 2>/dev/null | grep -q 'Certificate Sign'; then
    rm -f "$DEVICE_JSON"
    die "k3s ${K3S_VERSION} cannot start with this device's certificate as root CA: it has no keyCertSign key usage (Backstage-generated device certificates never do). Use a k3s release before v1.34.12/v1.35.9/v1.36.5 (default ${VDS_K3S_VERSION}); see README 'Finding'."
  fi
fi
DEBUG_PUBKEY=""
if [[ $DEBUG_USER == true ]]; then
  need ssh-keygen
  jq -r '.spec.keys.data.rsa_private' "$DEVICE_JSON" | base64 -d >"${WORK}/device_key"
  chmod 600 "${WORK}/device_key"
  DEBUG_PUBKEY=$(ssh-keygen -y -f "${WORK}/device_key") || die "cannot derive the SSH public key from the device key"
  rm -f "${WORK}/device_key"
fi
rm -f "$DEVICE_JSON"

# Structural checks on the rendered script; failures name the check, never content.
head -n1 "$SCRIPT" | grep -qx '#!/bin/sh' || die "rendered script does not start with #!/bin/sh"
grep -q "^_DEVICE_ID=\"${DEVICE}\"$" "$SCRIPT" || die "rendered script does not set _DEVICE_ID=${DEVICE}"
grep -q "^_NAMESPACE=\"${NAMESPACE}\"$" "$SCRIPT" || die "rendered script does not set _NAMESPACE=${NAMESPACE}"
grep -q "^_DOMAIN=\"${DOMAIN}\"$" "$SCRIPT" || die "rendered script does not set _DOMAIN=${DOMAIN}"
grep -q 'INSTALL_K3S_EXEC="server --token' "$SCRIPT" || die "rendered script does not pass INSTALL_K3S_EXEC through (template changed?)"
# shellcheck disable=SC2016  # literal text of the template
grep -q 'CREATE_USER=${CREATE_USER:-ask}' "$SCRIPT" || die "rendered script has no CREATE_USER switch (template changed?)"
if grep -q '{{' "$SCRIPT"; then die "rendered script contains unrendered template markers"; fi

# ---------------------------------------------------------------- 10-cloudinit-secret.yaml
K3S_EXEC="--cluster-cidr=${VDS_CLUSTER_CIDR} --service-cidr=${VDS_SERVICE_CIDR} --cluster-dns=${VDS_CLUSTER_DNS}"
RENDERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SCRIPT_B64=$(b64_oneline <"$SCRIPT")
USERDATA="${WORK}/userdata"
cat >"$USERDATA" <<EOF
#cloud-config
# S1 spike: Teknoir virtual device ${DEVICE} (teamspace ${NAMESPACE}).
# Rendered by hack/virtual-device-spike/render.sh at ${RENDERED_AT}.
hostname: ${DEVICE}
preserve_hostname: false
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
$(if [[ $DEBUG_USER == true ]]; then printf '%s\n' \
  "# --debug-user: break-glass access while the bootstrap runs (device SSH key, sudo)." \
  "users:" \
  "  - name: vdspike" \
  "    shell: /bin/bash" \
  "    lock_passwd: true" \
  "    sudo: ALL=(ALL) NOPASSWD:ALL" \
  "    ssh_authorized_keys:" \
  "      - ${DEBUG_PUBKEY}"; fi)
package_update: true
packages:
  - qemu-guest-agent
  - curl
  - openssl
  - ca-certificates
write_files:
  # The tnctl server bootstrap, unmodified (contains the device key, the device
  # user's password and the k3s token).
  - path: /usr/local/lib/teknoir/bootstrap.sh
    owner: root:root
    permissions: "0700"
    encoding: b64
    content: ${SCRIPT_B64}
  # Runs it the way a person runs it on a real device, plus the three inputs a
  # virtual device needs: non-interactive user creation, a pinned k3s version and
  # inner k3s CIDRs that do not overlap the platform cluster.
  - path: /usr/local/lib/teknoir/spike-run.sh
    owner: root:root
    permissions: "0755"
    content: |
      #!/bin/sh
      set -u
      state=/var/lib/teknoir-spike
      mkdir -p "\$state"
      date -u +%Y-%m-%dT%H:%M:%SZ > "\$state/bootstrap-started"
      rc=0
      CREATE_USER=true \\
      INSTALL_K3S_VERSION='${K3S_VERSION}' \\
      INSTALL_K3S_EXEC='${K3S_EXEC}' \\
        /bin/sh /usr/local/lib/teknoir/bootstrap.sh > "\$state/bootstrap.log" 2>&1 || rc=\$?
      echo "\$rc" > "\$state/bootstrap-exit"
      date -u +%Y-%m-%dT%H:%M:%SZ > "\$state/bootstrap-finished"
      exit "\$rc"
  # Non-secret parameters, read by check.sh inside the guest.
  - path: /etc/teknoir-spike/spike.env
    owner: root:root
    permissions: "0644"
    content: |
      DEVICE=${DEVICE}
      NAMESPACE=${NAMESPACE}
      DOMAIN=${DOMAIN}
      K3S_VERSION=${K3S_VERSION}
      CLUSTER_CIDR=${VDS_CLUSTER_CIDR}
      SERVICE_CIDR=${VDS_SERVICE_CIDR}
      CLUSTER_DNS=${VDS_CLUSTER_DNS}
      CLI_REF=${VDS_CLI_REF}
      RENDERED_AT=${RENDERED_AT}
runcmd:
  - [sh, -c, "mkdir -p /var/lib/teknoir-spike && chmod 700 /var/lib/teknoir-spike && date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/teknoir-spike/runcmd-started"]
  - [systemctl, enable, --now, qemu-guest-agent]
  - [/usr/local/lib/teknoir/spike-run.sh]
EOF
chmod 600 "$USERDATA"

SECRET_FILE="${OUT}/10-cloudinit-secret.yaml"
(
  umask 077
  cat >"$SECRET_FILE" <<EOF
# SECRET: cloud-init user data for virtual device ${DEVICE}, with the device key,
# the device user's password and the k3s token. Apply with 'kubectl create', not
# 'kubectl apply' (apply would copy the whole Secret into an annotation). Delete this
# file once the Secret exists.
apiVersion: v1
kind: Secret
metadata:
  name: ${DEVICE}-cloudinit
  namespace: ${VDEV_NS}
  labels:
$(labels 4 "teknoir.org/device: ${DEVICE}")
type: Opaque
data:
  userdata: $(b64_oneline <"$USERDATA")
EOF
)
chmod 600 "$SECRET_FILE"

# ---------------------------------------------------------------- 20-vm.yaml
CPU_REQUEST_M=$((CPU * 1000 / CPU_OVERCOMMIT))
if [[ $DISK == containerdisk ]]; then
  OS_IMAGE="${VDS_DISK_CONTAINERDISK_TAG}@${VDS_DISK_CONTAINERDISK_DIGEST}"
  # Digest only in the CDI URL: CDI's registry importer does not accept tag+digest.
  DV_SOURCE="registry:
            # ${VDS_DISK_CONTAINERDISK_TAG} (Debian 13 genericcloud 20261001-2618)
            url: docker://${VDS_DISK_CONTAINERDISK_TAG%%:*}@${VDS_DISK_CONTAINERDISK_DIGEST}
            # The node's containerd pulls the image (no scratch PVC, no pod egress).
            pullMethod: node"
else
  OS_IMAGE="${VDS_DISK_GENERIC_URL}"
  DV_SOURCE="http:
            url: ${VDS_DISK_GENERIC_URL}
            checksum: ${VDS_DISK_GENERIC_CHECKSUM}"
fi
CPU_MODEL_LINE=""
if [[ -n $CPU_MODEL ]]; then
  CPU_MODEL_LINE="
          model: ${CPU_MODEL}"
fi

cat >"${OUT}/20-vm.yaml" <<EOF
# S1 spike: virtual device ${DEVICE} of teamspace ${NAMESPACE}, hand-written VM.
# Rendered by hack/virtual-device-spike/render.sh at ${RENDERED_AT}.
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${DEVICE}
  namespace: ${VDEV_NS}
  labels:
$(labels 4 "teknoir.org/device: ${DEVICE}")
  annotations:
    teknoir.org/os-image: "${OS_IMAGE}"
    teknoir.org/bootstrap: "${BOOTSTRAP_SOURCE}"
    teknoir.org/k3s-version: "${K3S_VERSION}"
spec:
  runStrategy: Always
  dataVolumeTemplates:
    - metadata:
        name: ${DEVICE}-root
        labels:
$(labels 10 "teknoir.org/device: ${DEVICE}")
      spec:
        source:
          ${DV_SOURCE}
        # local-path (WaitForFirstConsumer): the disk lands under /opt on the node
        # the VM is scheduled to, never on r415's small /var.
        storage:
          storageClassName: local-path
          accessModes:
            - ReadWriteOnce
          volumeMode: Filesystem
          resources:
            requests:
              storage: ${DISK_GI}Gi
  template:
    metadata:
      labels:
$(labels 8 "teknoir.org/device: ${DEVICE}" "kubevirt.io/domain: ${DEVICE}")
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      priorityClassName: teknoir-virtual-device
      # Single node, no live migration: a drain shuts the VM down.
      evictionStrategy: None
      terminationGracePeriodSeconds: 120
      domain:
        cpu:
          sockets: 1
          cores: ${CPU}
          threads: 1${CPU_MODEL_LINE}
        resources:
          # cpu request = vCPU / ${CPU_OVERCOMMIT}; memory is never overcommitted.
          requests:
            cpu: ${CPU_REQUEST_M}m
            memory: ${MEMORY_GI}Gi
          limits:
            cpu: "${CPU}"
            memory: ${MEMORY_GI}Gi
        devices:
          # Keep the serial console out of pod logs (also off cluster-wide).
          logSerialConsole: false
          rng: {}
          disks:
            - name: root
              disk:
                bus: virtio
            - name: cloudinit
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
      networks:
        - name: default
          pod: {}
      volumes:
        - name: root
          dataVolume:
            name: ${DEVICE}-root
        - name: cloudinit
          cloudInitNoCloud:
            # Field "secretRef" (Go name UserDataSecretRef): key "userdata" of the Secret.
            secretRef:
              name: ${DEVICE}-cloudinit
EOF

# ---------------------------------------------------------------- summary.txt
SUMMARY="${OUT}/summary.txt"
cat >"$SUMMARY" <<EOF
S1 spike render for device ${DEVICE} (teamspace ${NAMESPACE}, runtime namespace ${VDEV_NS})
rendered:      ${RENDERED_AT}
source:        ${SOURCE}$([[ $SOURCE == fixture ]] && printf ' (%s)' "$FIXTURE")
bootstrap:     ${BOOTSTRAP_SOURCE}
k3s:           ${K3S_VERSION}  INSTALL_K3S_EXEC='${K3S_EXEC}'
size:          ${CPU} vCPU (request ${CPU_REQUEST_M}m), ${MEMORY_GI}Gi memory, ${DISK_GI}Gi disk
root disk:     ${OS_IMAGE}
egress:        ${EGRESS}$([[ $ALLOW_HARBOR == true ]] && printf ' + harbor 443')$([[ $ALLOW_VIRTCTL_SSH == true ]] && printf '; ingress 22 from virt-api (virtctl ssh)')
debug user:    $([[ $DEBUG_USER == true ]] && printf 'vdspike (device SSH key, passwordless sudo)' || printf 'none')

files:
  00-namespace.yaml         sha256 $(sha256_of "${OUT}/00-namespace.yaml")
  10-cloudinit-secret.yaml  SECRET (mode $(mode_of "$SECRET_FILE")), $(wc -c <"$SECRET_FILE" | tr -d ' ') bytes
  20-vm.yaml                sha256 $(sha256_of "${OUT}/20-vm.yaml")

Apply (Anders, after review; README step 5):
  kubectl --context ${KUBE_CONTEXT} apply  -f ${OUT}/00-namespace.yaml
  kubectl --context ${KUBE_CONTEXT} create -f ${OUT}/10-cloudinit-secret.yaml
  kubectl --context ${KUBE_CONTEXT} create -f ${OUT}/20-vm.yaml
  rm -rf ${OUT}        # the Secret now lives only in the cluster

Check (read-only):
  hack/virtual-device-spike/check.sh --context ${KUBE_CONTEXT} --namespace ${NAMESPACE} --domain ${DOMAIN} --device ${DEVICE} --phase all

Clean up (Anders; README step 9):
  kubectl --context ${KUBE_CONTEXT} -n ${VDEV_NS} delete vm ${DEVICE}            # also deletes the VMI and the ${DEVICE}-root DataVolume/PVC
  kubectl --context ${KUBE_CONTEXT} -n ${VDEV_NS} delete secret ${DEVICE}-cloudinit
  kubectl --context ${KUBE_CONTEXT} delete namespace ${VDEV_NS}
EOF
chmod 600 "$SUMMARY"

log ""
cat "$SUMMARY" >&2
printf '%s\n' "$OUT"
