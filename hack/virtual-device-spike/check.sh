#!/usr/bin/env bash
# shellcheck disable=SC2015  # "test && result PASS || result FAIL": result always returns 0
# check.sh: read-only S1 checks for the virtual-device spike (design section 8 "S1"
# plus the additions of the design critique).
#
# Against the cluster it only runs `kubectl get|describe|logs|version|auth can-i`
# (enforced by the kc wrapper in lib/common.sh). Checks inside the guest run over SSH
# through the device's own reverse tunnel and deadend (the path tnctl ssh uses), or
# optionally through `virtctl port-forward`. Inside the guest they read state and make
# TCP connection attempts; with --inner-pod they also start one throwaway pod in the
# guest's inner k3s (never in the platform cluster).
#
# Secrets: the Device's key and the device user's password are read with kubectl get,
# kept in a private 0700 directory removed on exit, and never printed. The password
# reaches the guest only on ssh's stdin, for sudo.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
umask 077

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  --device NAME        test Device (required for every phase except platform and removed)
  --namespace NS       teamspace (default: teknoir-demo); runtime namespace NS-vdev
  --domain DOMAIN      platform domain (default: teknoir.cloud)
  --context CTX        kubectl context (default: r415)
  --argocd-namespace NS
                       namespace of the Argo CD Applications (default: teknoir-system)
  --phase P[,P...]     platform | namespace | vm | device | guest | isolation | timing | all
                       (default: all). guest, isolation and timing need guest access.
                       removed: after the runtime was removed (README "Removing the
                       runtime"), check that nothing of it is left; not part of all.
  --transport T        tunnel (default: SSH via deadend and the device's reverse tunnel;
                       needs remote access enabled for the device) | virtctl (SSH over
                       'virtctl port-forward'; needs virtctl and portforward rights)
  --inner-pod          also run the isolation probes from a pod in the inner k3s
  --guest-user USER    log in as USER instead of the device user (e.g. vdspike from
                       render.sh --debug-user, while the bootstrap has not created the
                       device user yet); the device key is used either way
  --prom-url URL       optional teamspace Prometheus base URL (e.g. after
                       'kubectl port-forward -n NS svc/prometheus 9090:80':
                       http://127.0.0.1:9090/NS/prometheus) for Last Seen and the
                       device's reported CPU/memory
  --wait-online MIN    poll up to MIN minutes for TOE to come online before the device
                       checks (default: 0)
  -h, --help

Exit status: 0 when no check FAILed, 1 otherwise.
EOF
}

DEVICE=""
NAMESPACE="teknoir-demo"
DOMAIN="teknoir.cloud"
KUBE_CONTEXT="r415"
ARGOCD_NS="teknoir-system"
PHASES="all"
TRANSPORT="tunnel"
INNER_POD=false
GUEST_USER_OVERRIDE=""
PROM_URL=""
WAIT_ONLINE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE=$2; shift 2 ;;
    --namespace) NAMESPACE=$2; shift 2 ;;
    --domain) DOMAIN=$2; shift 2 ;;
    --context) KUBE_CONTEXT=$2; shift 2 ;;
    --argocd-namespace) ARGOCD_NS=$2; shift 2 ;;
    --phase) PHASES=$2; shift 2 ;;
    --transport) TRANSPORT=$2; shift 2 ;;
    --inner-pod) INNER_POD=true; shift ;;
    --guest-user) GUEST_USER_OVERRIDE=$2; shift 2 ;;
    --prom-url) PROM_URL=${2%/}; shift 2 ;;
    --wait-online) WAIT_ONLINE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

is_dns_label "$NAMESPACE" || die "--namespace is not a DNS label"
is_dns_label "$ARGOCD_NS" || die "--argocd-namespace is not a DNS label"
VDEV_NS="${NAMESPACE}-vdev"
[[ -z $DEVICE ]] || is_dns_label "$DEVICE" || die "--device is not a DNS label"
[[ $WAIT_ONLINE =~ ^[0-9]+$ ]] || die "--wait-online must be a number of minutes"
case "$TRANSPORT" in tunnel | virtctl) ;; *) die "--transport must be tunnel or virtctl" ;; esac
[[ $PHASES == all ]] && PHASES="platform,namespace,vm,device,guest,isolation,timing"
want() { [[ ",${PHASES}," == *",$1,"* ]]; }
for p in ${PHASES//,/ }; do
  case "$p" in platform | namespace | vm | device | guest | isolation | timing | removed) ;; *) die "unknown phase: $p" ;; esac
done
if want removed && [[ $PHASES != removed ]]; then die "--phase removed cannot be combined with other phases"; fi
if [[ -z $DEVICE ]] && [[ $PHASES != platform && $PHASES != removed ]]; then die "--device is required for phases other than platform and removed"; fi
need kubectl jq awk

PRIV=$(make_private_dir "")
trap 'rm -rf "$PRIV"' EXIT

section() { printf '\n== %s\n' "$*"; }
jget() { jq -r "$@" 2>/dev/null || true; }
# ts_to_epoch RFC3339 -> seconds (empty on failure)
ts_to_epoch() { [[ -n ${1:-} && $1 != null ]] && date -u -d "$1" +%s 2>/dev/null || true; }

# ------------------------------------------------------------------ platform
check_platform() {
  section "platform: KubeVirt, CDI, KVM, PriorityClass, CoreDNS ($KUBE_CONTEXT)"
  local v minor
  v=$(kc version -o json | jget '.serverVersion.gitVersion')
  minor=$(sed -E 's/^v1\.([0-9]+)\..*/\1/' <<<"$v")
  if [[ $minor == 34 || $minor == 35 ]]; then
    result PASS P1 "Kubernetes $v is supported by KubeVirt 1.8 (1.34-1.35)"
  else
    result FAIL P1 "Kubernetes $v is outside KubeVirt 1.8's supported 1.34-1.35"
  fi

  local app
  if app=$(kc -n "$ARGOCD_NS" get applications.argoproj.io virtual-devices -o json 2>/dev/null); then
    local sync health
    sync=$(jget '.status.sync.status' <<<"$app")
    health=$(jget '.status.health.status' <<<"$app")
    if [[ $sync == Synced && $health == Healthy ]]; then
      result PASS P2 "Argo CD application virtual-devices is Synced/Healthy (revision $(jget '.status.sync.revision[0:12]' <<<"$app"))"
    else
      result FAIL P2 "Argo CD application virtual-devices is $sync/$health"
    fi
  else
    result FAIL P2 "Argo CD application virtual-devices not found (gitops PR merged? README step 1)"
  fi

  local kv
  if kv=$(kc -n kubevirt get kubevirt kubevirt -o json 2>/dev/null); then
    local phase ver gates scl
    phase=$(jget '.status.phase' <<<"$kv")
    ver=$(jget '.status.observedKubeVirtVersion' <<<"$kv")
    [[ $phase == Deployed ]] && result PASS P3 "KubeVirt phase Deployed (observed version $ver)" ||
      result FAIL P3 "KubeVirt phase is '$phase' (conditions: $(jget '[.status.conditions[]? | select(.status=="True") | .type] | join(",")' <<<"$kv"))"
    [[ $ver == "$VDS_KUBEVIRT_VERSION" ]] || result FAIL P3b "KubeVirt observed version '$ver', expected $VDS_KUBEVIRT_VERSION"
    gates=$(jget '.spec.configuration.developerConfiguration.featureGates // [] | join(",")' <<<"$kv")
    [[ -z $gates ]] && result PASS P4 "KubeVirt runs with no feature gates" || result WARN P4 "KubeVirt feature gates enabled: $gates"
    scl=$(jget '.spec.configuration.virtualMachineOptions.disableSerialConsoleLog != null' <<<"$kv")
    [[ $scl == true ]] && result PASS P5 "serial console logging disabled cluster-wide (critique #17)" ||
      result FAIL P5 "serial console logging is not disabled in the KubeVirt CR"
    [[ $(jget '.spec.configuration.developerConfiguration.useEmulation // false' <<<"$kv") == false ]] ||
      result FAIL P5b "KubeVirt useEmulation is on: VMs would run without KVM"
  else
    result FAIL P3 "KubeVirt CR kubevirt/kubevirt not found"
  fi

  local cdi
  if cdi=$(kc get cdi cdi -o json 2>/dev/null); then
    local phase ver
    phase=$(jget '.status.phase' <<<"$cdi")
    ver=$(jget '.status.observedVersion' <<<"$cdi")
    [[ $phase == Deployed && $ver == "$VDS_CDI_VERSION" ]] && result PASS P6 "CDI phase Deployed ($ver), feature gates: $(jget '.spec.config.featureGates // [] | join(",")' <<<"$cdi")" ||
      result FAIL P6 "CDI phase '$phase', version '$ver' (expected Deployed, $VDS_CDI_VERSION)"
  else
    result FAIL P6 "CDI CR cdi not found"
  fi

  local ns pods notready unpinned
  for ns in kubevirt cdi; do
    pods=$(kc -n "$ns" get pods -o json 2>/dev/null || echo '{"items":[]}')
    notready=$(jget '[.items[] | select(.status.phase!="Succeeded") | select(([.status.containerStatuses[]?.ready] | all) | not) | .metadata.name] | join(",")' <<<"$pods")
    unpinned=$(jget '[.items[] | .spec.containers[], (.spec.initContainers // [])[] | .image | select(test("@sha256:[0-9a-f]{64}$") | not)] | unique | join(",")' <<<"$pods")
    if [[ $(jget '.items|length' <<<"$pods") == 0 ]]; then
      result FAIL "P7${ns:0:1}" "no pods in namespace $ns"
      continue
    fi
    [[ -z $notready ]] && result PASS "P7${ns:0:1}" "all $(jget '.items|length' <<<"$pods") pods in $ns are ready" || result FAIL "P7${ns:0:1}" "pods not ready in $ns: $notready"
    [[ -z $unpinned ]] && result PASS "P8${ns:0:1}" "every image running in $ns is pinned by digest" || result FAIL "P8${ns:0:1}" "images in $ns not pinned by digest: $unpinned"
  done

  local nodes
  nodes=$(kc get nodes -o json)
  local n kvm host_model
  while IFS=$'\t' read -r n kvm host_model; do
    if [[ ${kvm:-0} =~ ^[1-9] ]]; then
      result PASS P9 "node $n: devices.kubevirt.io/kvm allocatable=$kvm (host-model CPU: ${host_model:-unknown})"
    else
      result FAIL P9 "node $n: devices.kubevirt.io/kvm not allocatable (KVM missing or virt-handler not ready)"
    fi
  done < <(jq -r '.items[] | [.metadata.name, (.status.allocatable["devices.kubevirt.io/kvm"] // "0"),
      ((.metadata.labels // {}) | to_entries | map(select(.key|startswith("host-model-cpu.node.kubevirt.io/"))) | map(.key|sub("^host-model-cpu.node.kubevirt.io/";"")) | join(","))] | @tsv' <<<"$nodes")

  local pc
  if pc=$(kc get priorityclass teknoir-virtual-device -o json 2>/dev/null); then
    local val pol
    val=$(jget '.value' <<<"$pc")
    pol=$(jget '.preemptionPolicy' <<<"$pc")
    [[ $val =~ ^-?[0-9]+$ ]] && ((val < 0)) && [[ $pol == Never ]] && result PASS P10 "PriorityClass teknoir-virtual-device: value $val (below platform pods at 0), preemptionPolicy Never" ||
      result FAIL P10 "PriorityClass teknoir-virtual-device: value $val, preemptionPolicy $pol"
  else
    result FAIL P10 "PriorityClass teknoir-virtual-device not found"
  fi

  local cm
  if cm=$(kc -n kube-system get configmap coredns-custom -o json 2>/dev/null); then
    local rule
    rule=$(jget '.data["virtual-devices.override"] // ""' <<<"$cm" | grep -E '^\s*rewrite ' || true)
    if [[ $rule == *"${DOMAIN//./\\\\.}"* || $rule == *"${DOMAIN//./\\.}"* ]]; then
      result PASS P11 "coredns-custom virtual-devices.override rewrites (mqtt|deadend)-*.${DOMAIN} (effect verified from the guest, G14)"
    else
      result FAIL P11 "coredns-custom has no virtual-devices.override rule for ${DOMAIN}"
    fi
    result INFO P11b "other coredns-custom keys: $(jget '[.data | keys[] | select(. != "virtual-devices.override")] | join(",")' <<<"$cm")"
  else
    result FAIL P11 "ConfigMap kube-system/coredns-custom not found"
  fi

  # Aggregated APIServices (virt-api: subresources.kubevirt.io; cdi-apiserver:
  # upload.cdi.kubevirt.io). While one is unavailable, API discovery is incomplete for
  # every client in the cluster: namespace deletion and garbage collection stall.
  local apis kv_apis bad_apis
  if apis=$(kc get apiservices -o json 2>/dev/null); then
    kv_apis=$(jget '[.items[] | select(.spec.service != null and ((.spec.group // "") | test("(^|\\.)kubevirt\\.io$"))) | .metadata.name] | join(",")' <<<"$apis")
    bad_apis=$(jget '[.items[] | select(.spec.service != null and ((.spec.group // "") | test("(^|\\.)kubevirt\\.io$"))) | select(([.status.conditions[]? | select(.type=="Available") | .status][0] // "Unknown") != "True") | .metadata.name] | join(",")' <<<"$apis")
    if [[ -z $kv_apis ]]; then
      result FAIL P14 "no aggregated KubeVirt/CDI APIServices (operands not deployed)"
    elif [[ -z $bad_apis ]]; then
      result PASS P14 "aggregated APIServices Available: ${kv_apis}"
    else
      result FAIL P14 "aggregated APIServices not Available: ${bad_apis}. API discovery is incomplete cluster-wide (namespace deletion and garbage collection stall)"
    fi
  else
    result FAIL P14 "cannot list APIServices"
  fi
  # The pods behind them: with one replica, any restart of that pod makes its
  # APIService unavailable (kubevirt.infraReplicas, cdi.apiServerReplicas).
  local d dep want_r ready_r
  for d in kubevirt/virt-api kubevirt/virt-controller cdi/cdi-apiserver; do
    dep=$(kc -n "${d%/*}" get deployment "${d#*/}" -o json 2>/dev/null || echo '{}')
    want_r=$(jget '.spec.replicas // 0' <<<"$dep")
    ready_r=$(jget '.status.readyReplicas // 0' <<<"$dep")
    if ((ready_r >= 2)); then
      result PASS P15 "${d}: ${ready_r}/${want_r} replicas ready"
    elif ((ready_r == 1)); then
      result WARN P15 "${d}: only ${ready_r}/${want_r} replica ready; a restart of that pod interrupts its APIService or webhooks"
    else
      result FAIL P15 "${d}: no ready replica (${ready_r}/${want_r})"
    fi
  done

  local sp
  if sp=$(kc get storageprofile local-path -o json 2>/dev/null); then
    result INFO P12 "CDI StorageProfile local-path: $(jget '[.status.claimPropertySets[]? | "\(.accessModes|join("/")) \(.volumeMode)"] | join("; ")' <<<"$sp") (the VM sets accessModes and volumeMode explicitly)"
  fi
  result INFO P12b "StorageClass local-path volumeBindingMode: $(kc get storageclass local-path -o jsonpath='{.volumeBindingMode}' 2>/dev/null || echo unknown)"

  # nodefs headroom: virt-launcher and CDI importer emptyDirs and container logs land on /var.
  for n in $(jq -r '.items[].metadata.name' <<<"$nodes"); do
    local s avail gib
    s=$(kc get --raw "/api/v1/nodes/${n}/proxy/stats/summary" 2>/dev/null || true)
    avail=$(jget '.node.fs.availableBytes // empty' <<<"$s")
    [[ -n $avail ]] || { result INFO P13 "node $n: nodefs stats unavailable"; continue; }
    gib=$((avail / 1024 / 1024 / 1024))
    if ((gib < 5)); then
      result WARN P13 "node $n: nodefs (/var) has ${gib} GiB free; launcher/importer emptyDirs and logs land there (design risk #3)"
    else
      result PASS P13 "node $n: nodefs (/var) has ${gib} GiB free"
    fi
    result INFO P13b "node $n: imagefs has $(($(jget '.node.runtime.imageFs.availableBytes // 0' <<<"$s") / 1024 / 1024 / 1024)) GiB free"
  done
}

# ------------------------------------------------------------------ namespace
check_namespace() {
  section "namespace: ${VDEV_NS}"
  local ns
  if ! ns=$(kc get namespace "$VDEV_NS" -o json 2>/dev/null); then
    result FAIL N1 "namespace ${VDEV_NS} not found (README step 5)"
    return
  fi
  local enforce inj
  enforce=$(jget '.metadata.labels["pod-security.kubernetes.io/enforce"] // ""' <<<"$ns")
  inj=$(jget '.metadata.labels["istio-injection"] // ""' <<<"$ns")
  [[ $enforce == baseline ]] && result PASS N1 "PSA enforce=baseline on ${VDEV_NS}" || result FAIL N1 "PSA enforce is '$enforce' on ${VDEV_NS}"
  [[ $inj != enabled ]] && result PASS N2 "no Istio injection in ${VDEV_NS} (istio-injection='${inj}')" || result FAIL N2 "Istio injection is enabled in ${VDEV_NS}"

  local np names p
  np=$(kc -n "$VDEV_NS" get networkpolicies -o json)
  names=$(jget '[.items[].metadata.name] | join(",")' <<<"$np")
  for p in vdev-default-deny vdev-egress-dns vdev-egress-gateway; do
    [[ ",$names," == *",$p,"* ]] || result FAIL N3 "NetworkPolicy $p missing"
  done
  result INFO N3 "NetworkPolicies: $names"
  local q
  if q=$(kc -n "$VDEV_NS" get resourcequota vdev-quota -o json 2>/dev/null); then
    result PASS N4 "ResourceQuota vdev-quota: $(jget '[.status.hard | to_entries[] | select(.key|test("cpu|memory|storage|virtualmachines|pods")) | "\(.key)=\(.value)"] | join(" ")' <<<"$q")"
  else
    result FAIL N4 "ResourceQuota vdev-quota missing"
  fi
  kc -n "$VDEV_NS" get limitrange vdev-limits >/dev/null 2>&1 && result PASS N5 "LimitRange vdev-limits present" || result FAIL N5 "LimitRange vdev-limits missing"

  # Who can read the cloud-init Secret? Teamspace users must not; Backstage's SA still
  # can (critique #1, closed in release r5 / Phase 1b).
  local who ans
  for who in "system:serviceaccount:${NAMESPACE}:default-editor" "system:serviceaccount:${NAMESPACE}:default-viewer"; do
    ans=$(kc auth can-i get secrets -n "$VDEV_NS" --as="$who" 2>/dev/null || true)
    [[ $ans == no* ]] && result PASS N6 "$who cannot get secrets in ${VDEV_NS}" || result FAIL N6 "$who can get secrets in ${VDEV_NS} ($ans)"
  done
  ans=$(kc auth can-i get secrets -n "$VDEV_NS" --as=system:serviceaccount:teknoir-system:backstage-api 2>/dev/null || true)
  [[ $ans == no* ]] && result PASS N7 "backstage-api cannot get secrets in ${VDEV_NS}" ||
    result WARN N7 "backstage-api can get secrets in ${VDEV_NS} (known: critique #1, Backstage kubernetes-proxy fix in release r5); keep the spike to internal teamspaces"

  # The render Job of charts/virtual-device-spike (only when that chart is deployed):
  # it may read exactly one Device and one Secret and create Secrets in the vdev
  # namespace, nothing else.
  if kc get namespace teknoir-vdev-spike -o name >/dev/null 2>&1; then
    local rsa=system:serviceaccount:teknoir-vdev-spike:vd-spike-render
    can() { kc auth can-i "$@" --as="$rsa" 2>/dev/null || true; }
    [[ $(can get "devices.teknoir.org/${DEVICE}" -n "$NAMESPACE") == yes* ]] && result PASS N8 "render SA can get Device ${DEVICE}" ||
      result WARN N8 "render SA cannot get Device ${DEVICE} (chart not synced yet?)"
    [[ $(can get devices.teknoir.org/other-device -n "$NAMESPACE") == no* ]] && result PASS N9 "render SA cannot get other Devices" || result FAIL N9 "render SA can get other Devices"
    [[ $(can list devices.teknoir.org -n "$NAMESPACE") == no* ]] && result PASS N9 "render SA cannot list Devices" || result FAIL N9 "render SA can list Devices"
    [[ $(can list secrets -n "$VDEV_NS") == no* ]] && result PASS N10 "render SA cannot list secrets in ${VDEV_NS}" || result FAIL N10 "render SA can list secrets in ${VDEV_NS}"
    [[ $(can get secrets/other-cloudinit -n "$VDEV_NS") == no* ]] && result PASS N10 "render SA cannot get other secrets in ${VDEV_NS}" || result FAIL N10 "render SA can get other secrets in ${VDEV_NS}"
    [[ $(can get secrets -n "$NAMESPACE") == no* ]] && result PASS N10 "render SA cannot get secrets in ${NAMESPACE}" || result FAIL N10 "render SA can get secrets in ${NAMESPACE}"
    [[ $(can delete "secrets/${DEVICE}-cloudinit" -n "$VDEV_NS") == no* && $(can update "secrets/${DEVICE}-cloudinit" -n "$VDEV_NS") == no* ]] &&
      result PASS N10 "render SA cannot update or delete the cloud-init Secret" || result FAIL N10 "render SA can update or delete the cloud-init Secret"
  fi
}

# ------------------------------------------------------------------ vm
check_vm() {
  section "vm: ${VDEV_NS}/${DEVICE}"
  local old
  if old=$(kc -n "$NAMESPACE" get deployment "virtual-device-${DEVICE}" -o name 2>/dev/null) && [[ -n $old ]]; then
    result FAIL V0 "the 2024 plugin created ${NAMESPACE}/virtual-device-${DEVICE} (privileged); delete the test Device and use a non-virtual board"
  else
    result PASS V0 "no 2024 virtual-device-${DEVICE} Deployment in ${NAMESPACE}"
  fi

  local vm
  if ! vm=$(kc -n "$VDEV_NS" get virtualmachine "$DEVICE" -o json 2>/dev/null); then
    result FAIL V1 "VirtualMachine ${VDEV_NS}/${DEVICE} not found (README step 5)"
    return
  fi
  result INFO V1 "VM printableStatus: $(jget '.status.printableStatus' <<<"$vm"), runStrategy $(jget '.spec.runStrategy' <<<"$vm")"

  local dv pvc
  if dv=$(kc -n "$VDEV_NS" get datavolume "${DEVICE}-root" -o json 2>/dev/null); then
    local phase
    phase=$(jget '.status.phase' <<<"$dv")
    [[ $phase == Succeeded ]] && result PASS V2 "DataVolume ${DEVICE}-root Succeeded (source: $(jget '.spec.source | keys[0]' <<<"$dv"), pullMethod $(jget '.spec.source.registry.pullMethod // "-"' <<<"$dv"))" ||
      result FAIL V2 "DataVolume ${DEVICE}-root phase '$phase' progress $(jget '.status.progress' <<<"$dv"): $(jget '[.status.conditions[]? | select(.message!=null and .message!="") | "\(.type): \(.message)"] | join("; ")' <<<"$dv")"
  else
    result FAIL V2 "DataVolume ${DEVICE}-root not found"
  fi
  if pvc=$(kc -n "$VDEV_NS" get pvc "${DEVICE}-root" -o json 2>/dev/null); then
    local sel sc
    sel=$(jget '.metadata.annotations["volume.kubernetes.io/selected-node"] // ""' <<<"$pvc")
    sc=$(jget '.spec.storageClassName' <<<"$pvc")
    [[ $(jget '.status.phase' <<<"$pvc") == Bound && -n $sel ]] &&
      result PASS V3 "PVC ${DEVICE}-root Bound on $sc, WaitForFirstConsumer honoured (selected node $sel), capacity $(jget '.status.capacity.storage' <<<"$pvc")" ||
      result FAIL V3 "PVC ${DEVICE}-root phase $(jget '.status.phase' <<<"$pvc"), selected node '${sel}'"
  fi

  local vmi
  if ! vmi=$(kc -n "$VDEV_NS" get virtualmachineinstance "$DEVICE" -o json 2>/dev/null); then
    result FAIL V4 "no VirtualMachineInstance ${DEVICE} (VM not started yet, or failing: see V9)"
  else
    local phase node agent
    phase=$(jget '.status.phase' <<<"$vmi")
    node=$(jget '.status.nodeName' <<<"$vmi")
    [[ $phase == Running ]] && result PASS V4 "VMI Running on node $node" || result FAIL V4 "VMI phase '$phase': $(jget '[.status.conditions[]? | select(.status!="True") | "\(.type): \(.message // .reason)"] | join("; ")' <<<"$vmi")"
    agent=$(jget '[.status.conditions[]? | select(.type=="AgentConnected") | .status][0] // "False"' <<<"$vmi")
    [[ $agent == True ]] && result PASS V5 "guest agent connected: $(jget '.status.guestOSInfo | "\(.prettyName // .name) kernel \(.kernelRelease)"' <<<"$vmi")" ||
      result FAIL V5 "guest agent not connected (qemu-guest-agent is installed by cloud-init; wait for cloud-init)"
    result INFO V5b "VMI interfaces: $(jget '[.status.interfaces[]? | select(.name != null) | "\(.name)=\(.ipAddress)"] | join(" ")' <<<"$vmi")"
  fi

  local pods pod
  pods=$(kc -n "$VDEV_NS" get pods -l "kubevirt.io=virt-launcher,kubevirt.io/domain=${DEVICE}" -o json 2>/dev/null || echo '{"items":[]}')
  pod=$(jget '[.items[] | select(.status.phase=="Running")][0] // empty' <<<"$pods")
  if [[ -z $pod ]]; then
    result FAIL V6 "no running virt-launcher pod for ${DEVICE}"
  else
    local name uid nonroot priv caps containers
    name=$(jget '.metadata.name' <<<"$pod")
    result PASS V6 "virt-launcher $name admitted under PSA enforce=baseline and Running"
    uid=$(jget '.spec.securityContext.runAsUser // ([.spec.containers[] | select(.name=="compute") | .securityContext.runAsUser][0]) // "unset"' <<<"$pod")
    nonroot=$(jget '.spec.securityContext.runAsNonRoot // ([.spec.containers[] | select(.name=="compute") | .securityContext.runAsNonRoot][0]) // false' <<<"$pod")
    priv=$(jget '[.spec.containers[], (.spec.initContainers // [])[] | select(.securityContext.privileged == true) | .name] | join(",")' <<<"$pod")
    caps=$(jget '[.spec.containers[] | .securityContext.capabilities.add // [] | .[]] | unique | join(",")' <<<"$pod")
    [[ $nonroot == true && -z $priv ]] && result PASS V7 "virt-launcher runs non-root (uid $uid), no privileged container, added capabilities: ${caps:-none}" ||
      result FAIL V7 "virt-launcher runAsNonRoot=$nonroot uid=$uid privileged=[$priv]"
    if [[ $(jget '.status.phase' <<<"$vmi") == Running ]]; then
      result PASS V8 "non-root QEMU opened /dev/kvm (VMI Running with useEmulation off)"
    fi
    containers=$(jget '[.spec.containers[].name] | join(",")' <<<"$pod")
    [[ $containers != *guest-console-log* ]] && result PASS V9a "no guest-console-log container (serial console not copied to pod logs); containers: $containers" ||
      result FAIL V9a "guest-console-log container present: serial console output reaches pod logs"
    [[ $containers != *istio-proxy* ]] || result FAIL V9b "istio-proxy sidecar injected into virt-launcher"
    result INFO V9c "virt-launcher: priorityClass $(jget '.spec.priorityClassName' <<<"$pod") (priority $(jget '.spec.priority' <<<"$pod")), automountServiceAccountToken=$(jget '.spec | if has("automountServiceAccountToken") then .automountServiceAccountToken else "unset" end' <<<"$pod"), SA token volume: $(jget '[.spec.volumes[]? | select(.projected.sources[]?.serviceAccountToken) | .name] | if length==0 then "none" else join(",") end' <<<"$pod")"
    result INFO V9d "virt-launcher compute resources: $(jget '[.spec.containers[] | select(.name=="compute") | .resources | "requests \(.requests.cpu)/\(.requests.memory), limits \(.limits.cpu)/\(.limits.memory)"][0]' <<<"$pod")"
    local hits
    local logs probe
    logs=$(kc -n "$VDEV_NS" logs "$name" -c compute --tail=5000 2>/dev/null || true)
    # libvirt's early host CPUID probe (virHostCPUGetCPUID) runs before virt-handler has
    # handed /dev/kvm to the qemu user and logs "Permission denied"; seen on k3d with a
    # working KVM guest. G6b is the real KVM check.
    probe=$(grep -c 'virHostCPUGetCPUID' <<<"$logs" || true)
    hits=$(grep -i -E 'apparmor|permission denied|/dev/kvm|could not access kvm' <<<"$logs" | grep -v 'virHostCPUGetCPUID' | cut -c1-200 | head -n 5 || true)
    [[ -z $hits ]] && result PASS V10 "virt-launcher log has no AppArmor / permission / KVM access errors (benign libvirt CPUID probe messages: ${probe})" ||
      result WARN V10 "virt-launcher log mentions: ${hits//$'\n'/ | }"
  fi

  local q
  if q=$(kc -n "$VDEV_NS" get resourcequota vdev-quota -o json 2>/dev/null); then
    # shellcheck disable=SC2016  # jq program
    result INFO V11 "quota used/hard: $(jget '[.status.used as $u | .status.hard | to_entries[] | select(.key|test("^(requests|limits)\\.|pods|persistentvolumeclaims|virtualmachines")) | "\(.key) \($u[.key] // "0")/\(.value)"] | join(", ")' <<<"$q")"
    if [[ -n ${pod:-} ]]; then
      # Headroom for one more device of this size: launcher pod + importer pod + 2 PVCs.
      local need_mem free_mem
      need_mem=$(jq -r '[.spec.containers[] | select(.name=="compute") | .resources.limits.memory // "0"][0]' <<<"$pod")
      free_mem=$(jq -r '.status | "\(.hard["limits.memory"]) - \(.used["limits.memory"])"' <<<"$q")
      result INFO V11b "a second device needs about launcher limits.memory $need_mem + importer 600M; limits.memory hard - used = $free_mem (critique #10 headroom check)"
    fi
  fi

  local ev
  # CDI emits ImportTargetInUse (the WaitForFirstConsumer helper pod) and "Completed"
  # as Warnings during a normal import; they are not counted.
  ev=$(kc -n "$VDEV_NS" get events --field-selector type=Warning -o json 2>/dev/null |
    jq -r '[.items[] | select(.reason != "ImportTargetInUse" and .reason != "Completed") | "\(.involvedObject.kind)/\(.involvedObject.name) \(.reason): \(.message|.[0:160])"] | unique | .[-8:] | .[]' 2>/dev/null || true)
  [[ -z $ev ]] && result PASS V12 "no Warning events in ${VDEV_NS}" || {
    result WARN V12 "Warning events in ${VDEV_NS} (latest):"
    while IFS= read -r line; do printf '           %s\n' "$line"; done <<<"$ev"
  }
}

# ------------------------------------------------------------------ device (platform view)
DEVICE_JSON=""
load_device() {
  [[ -n $DEVICE_JSON ]] && return 0
  DEVICE_JSON="${PRIV}/device.json"
  kc -n "$NAMESPACE" get device "$DEVICE" -o json >"$DEVICE_JSON" 2>/dev/null || {
    DEVICE_JSON=""
    return 1
  }
}

prom_query() { # prom_query 'promql' -> first value or empty
  [[ -n $PROM_URL ]] || return 0
  need curl
  curl -fsS --max-time 10 --get --data-urlencode "query=$1" "${PROM_URL}/api/v1/query" 2>/dev/null |
    jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true
}

check_device() {
  section "device: ${NAMESPACE}/${DEVICE} as the platform sees it"
  if ! load_device; then
    result FAIL D1 "Device ${NAMESPACE}/${DEVICE} not found"
    return
  fi
  local deadline
  deadline=$(($(date +%s) + WAIT_ONLINE * 60))
  while :; do
    local cpu mem
    cpu=$(jq -r '.subresources.status.state.cpu_usage // empty' "$DEVICE_JSON")
    mem=$(jq -r '.subresources.status.state.memory_usage // empty' "$DEVICE_JSON")
    if [[ -n $cpu || -n $mem ]] || (($(date +%s) >= deadline)); then break; fi
    sleep 20
    load_device_refresh
  done
  result INFO D1 "device_type '$(jq -r '.spec.device_type // ""' "$DEVICE_JSON")', hardware label '$(jq -r '.metadata.labels.hardware // ""' "$DEVICE_JSON")'"
  if [[ -n $cpu || -n $mem ]]; then
    result PASS D2 "DeviceState has TOE metrics (cpu_usage=${cpu:-?}, memory_usage=${mem:-?}): TOE is publishing state"
  else
    result FAIL D2 "DeviceState has no cpu/memory usage yet: TOE has not published state (or Prometheus has not scraped it)"
  fi
  local ra_active ra_port
  ra_active=$(jq -r '.subresources.status.remote_access.active // false' "$DEVICE_JSON")
  ra_port=$(jq -r '.subresources.status.remote_access.port // "NA"' "$DEVICE_JSON")
  [[ $ra_active == true && $ra_port =~ ^[0-9]+$ ]] && result PASS D3 "remote access active on tunnel port $ra_port" ||
    result WARN D3 "remote access not active (enable a tunnel for the device in Backstage, README step 6)"
  local deps
  deps=$(kc -n "$NAMESPACE" get deployments -o json 2>/dev/null |
    jq -r --arg d "$DEVICE" '[.items[] | select(.metadata.name|startswith("tunnel-")) | select(.metadata.name|endswith("-"+$d)) | "\(.metadata.name) \(.status.readyReplicas // 0)/\(.spec.replicas)"] | join(", ")' || true)
  result INFO D4 "tunnel deployments for ${DEVICE}: ${deps:-none}"
  local das
  das=$(kc -n "$NAMESPACE" get deviceapplicationsets -o json 2>/dev/null |
    jq -r --slurpfile d "$DEVICE_JSON" '($d[0].metadata.labels // {}) as $l | [.items[] | select(.spec.selector.matchLabels as $m | ($m // {}) | to_entries | length > 0 and all(.[]; $l[.key] == .value)) | .metadata.name] | join(",")' 2>/dev/null || true)
  result INFO D7 "DeviceApplicationSets selecting ${DEVICE} (matchLabels): ${das:-none}"
  if [[ -n $PROM_URL ]]; then
    local seen ncpu nmem
    seen=$(prom_query "min by (device_id) (time()-device_last_seen{device_id=\"${DEVICE}\"})")
    ncpu=$(prom_query "max(node_cpu_allocatable{device_id=\"${DEVICE}\"})")
    nmem=$(prom_query "max(node_memory_allocatable{device_id=\"${DEVICE}\"})")
    if [[ -n $seen ]] && awk -v s="$seen" 'BEGIN{exit !(s < 180)}'; then
      result PASS D5 "Last Seen ${seen%.*}s ago (device_last_seen; Backstage shows 'ok' under 180s)"
    else
      result FAIL D5 "Last Seen '${seen:-no data}' (device_last_seen)"
    fi
    result INFO D6 "device reports node_cpu_allocatable=${ncpu:-?} node_memory_allocatable=${nmem:-?} (should match the VM size, not the host)"
  else
    result SKIP D5 "Last Seen not queried (pass --prom-url, or read the Devices table in Backstage)"
  fi
}
load_device_refresh() {
  kc -n "$NAMESPACE" get device "$DEVICE" -o json >"$DEVICE_JSON" 2>/dev/null || true
}

# ------------------------------------------------------------------ guest access
KEY_FILE=""
GUEST_USER=""
guest_prepare() {
  [[ -n $KEY_FILE ]] && return 0
  load_device || { result FAIL G0 "Device ${NAMESPACE}/${DEVICE} not found"; return 1; }
  need ssh base64
  KEY_FILE="${PRIV}/device_key"
  if ! jq -r '.spec.keys.data.rsa_private // ""' "$DEVICE_JSON" | base64 -d >"$KEY_FILE" 2>/dev/null || ! grep -q 'PRIVATE KEY-----' "$KEY_FILE"; then
    result FAIL G0 "the Device's spec.keys.data.rsa_private does not decode to a PEM key"
    KEY_FILE=""
    return 1
  fi
  chmod 600 "$KEY_FILE"
  GUEST_USER=$(jq -r '.spec.keys.data.username // ""' "$DEVICE_JSON" | base64 -d 2>/dev/null || true)
  [[ -z $GUEST_USER_OVERRIDE ]] || GUEST_USER=$GUEST_USER_OVERRIDE
  if [[ -z $GUEST_USER ]]; then
    result FAIL G0 "the Device has no spec.keys.data.username"
    KEY_FILE=""
    return 1
  fi
  case "$TRANSPORT" in
    tunnel)
      local active port
      active=$(jq -r '.subresources.status.remote_access.active // false' "$DEVICE_JSON")
      port=$(jq -r '.subresources.status.remote_access.port // "NA"' "$DEVICE_JSON")
      if [[ $active != true || ! $port =~ ^[0-9]+$ ]]; then
        result FAIL G0 "remote access is not active for ${DEVICE}: enable a tunnel in Backstage (README step 6) or use --transport virtctl"
        KEY_FILE=""
        return 1
      fi
      local dh="deadend-${NAMESPACE}.${DOMAIN}" tls
      if command -v ncat >/dev/null 2>&1; then
        tls="ncat --ssl ${dh} 2222"
      else
        need openssl
        tls="openssl s_client -quiet -verify_quiet -connect ${dh}:2222 -servername ${dh}"
      fi
      # Same chain as tnctl ssh: TLS to deadend:2222 (SNI), SSH as teknoir@deadend, then
      # -W to the device's reverse-tunnel port on deadend's loopback.
      PROXY="ssh -F /dev/null -i ${KEY_FILE} -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ProxyCommand='${tls}' -W %h:%p -p 2222 teknoir@${dh}"
      GUEST_HOST="127.0.0.1"
      GUEST_PORT="$port"
      ;;
    virtctl)
      command -v virtctl >/dev/null 2>&1 || { result FAIL G0 "virtctl not found"; KEY_FILE=""; return 1; }
      # Needs render.sh --allow-virtctl-ssh: virt-api dials the VM's pod IP on port 22.
      PROXY="virtctl --context ${KUBE_CONTEXT} port-forward --stdio=true vmi/${DEVICE}/${VDEV_NS} 22"
      GUEST_HOST="vmi-${DEVICE}"
      GUEST_PORT=22
      ;;
  esac
}

# guest_run SCRIPT_TEXT [sudo]: run a non-secret bash script in the guest and print its output.
guest_run() {
  local script=$1 mode=${2:-user} b64 remote
  b64=$(printf '%s' "$script" | b64_oneline)
  if [[ $mode == sudo ]]; then
    remote="sudo -S -p '' bash -c \"\$(echo ${b64} | base64 -d)\""
  else
    remote="bash -c \"\$(echo ${b64} | base64 -d)\""
  fi
  local pw=""
  # The device user's sudo needs its password; a --guest-user override has NOPASSWD.
  if [[ $mode == sudo && -z $GUEST_USER_OVERRIDE ]]; then
    pw=$(jq -r '.spec.keys.data.userpassword // ""' "$DEVICE_JSON" | base64 -d 2>/dev/null || true)
  fi
  printf '%s\n' "$pw" | ssh -F /dev/null -i "$KEY_FILE" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=30 \
    -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
    -o ProxyCommand="$PROXY" -p "$GUEST_PORT" "${GUEST_USER}@${GUEST_HOST}" "$remote"
}

# ------------------------------------------------------------------ guest
GUEST_KV=""
kvget() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; exit}' <<<"$GUEST_KV"; }

read -r -d '' GUEST_SCRIPT <<'GS' || true
set -u
kv() { printf '%s=%s\n' "$1" "$2"; }
. /etc/os-release 2>/dev/null || true
. /etc/teknoir-spike/spike.env 2>/dev/null || true
kv os "${PRETTY_NAME:-unknown}"
kv kernel "$(uname -r)"
kv virt "$(systemd-detect-virt 2>/dev/null)"
kv hypervisor "$(journalctl -k -b --no-pager 2>/dev/null | grep -m1 -o 'Hypervisor detected: .*')"
kv nproc "$(nproc)"
kv mem_kib "$(awk '/^MemTotal/{print $2}' /proc/meminfo)"
kv root_bytes "$(df -B1 --output=size / | tail -n1 | tr -d ' ')"
kv boot_time "$(date -u -d "@$(($(date +%s) - $(cut -d. -f1 /proc/uptime)))" +%Y-%m-%dT%H:%M:%SZ)"
for f in runcmd-started bootstrap-started bootstrap-finished bootstrap-exit; do kv "spike_${f}" "$(cat /var/lib/teknoir-spike/$f 2>/dev/null)"; done
kv cloudinit "$(cloud-init status 2>/dev/null | awk '/^status:/{print $2}')"
kv qga "$(systemctl is-active qemu-guest-agent 2>/dev/null)"
kv k3s_active "$(systemctl is-active k3s 2>/dev/null)"
kv k3s_since "$(systemctl show k3s -p ActiveEnterTimestamp --value 2>/dev/null)"
kv k3s_version "$(k3s --version 2>/dev/null | head -n1 | awk '{print $3}')"
kv k3s_ca_errors "$(journalctl -u k3s --no-pager 2>/dev/null | grep -c 'CA cert validation failed')"
kv root_ca_certsign "$(openssl x509 -in /var/lib/rancher/k3s/server/tls/root-ca.pem -noout -ext keyUsage 2>/dev/null | grep -c 'Certificate Sign')"
cc=$(k3s check-config 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
kv checkconfig_status "$(printf '%s\n' "$cc" | grep -E 'STATUS:' | tail -n1 | sed 's/^[^S]*//')"
kv checkconfig_problems "$(printf '%s\n' "$cc" | grep -E ': (missing|fail)' | sed 's/^[- ]*//' | tr '\n' ';' | cut -c1-600)"
for m in overlay br_netfilter vxlan nf_tables ip_tables iptable_nat xt_conntrack nf_conntrack; do
  if grep -qw "^$m" /proc/modules 2>/dev/null; then s=loaded; elif modinfo "$m" >/dev/null 2>&1; then s=available; else s=missing; fi
  kv "mod_$m" "$s"
done
K="k3s kubectl"
kv inner_node "$($K get nodes --no-headers 2>/dev/null | awk '{print $1":"$2":"$5}' | tr '\n' ' ')"
kv inner_svc_kubernetes "$($K -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
kv inner_kubedns "$($K -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
kv inner_podcidr "$($K get nodes -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)"
kv toe_phase "$($K -n kube-system get pods -l app=toe -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
kv toe_started "$($K -n kube-system get pods -l app=toe -o jsonpath='{.items[0].status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)"
kv toe_image "$($K -n kube-system get pods -l app=toe -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null)"
# TOE has two MQTT clients that log the same messages: MQTTCloud (the platform's
# EMQX, what "online" means) and MQTTEdge (the device-local emqx-edge broker).
tl=$($K -n kube-system logs deploy/toe --timestamps --tail=-1 2>/dev/null)
cloud=$(printf '%s\n' "$tl" | grep 'MQTTCloud' | grep -v 'MQTTCloudHandler')
kv toe_first_up "$(printf '%s\n' "$cloud" | grep -m1 'mqtt connection up' | awk '{print $1}')"
kv toe_up_count "$(printf '%s\n' "$cloud" | grep -c 'mqtt connection up')"
kv toe_err_count "$(printf '%s\n' "$cloud" | grep -c 'error whilst attempting connection')"
kv toe_last_err "$(printf '%s\n' "$cloud" | grep 'error whilst attempting connection' | tail -n1 | sed 's/.*error whilst attempting connection//' | tr -d '\t' | cut -c1-200)"
kv toe_edge_up "$(printf '%s\n' "$tl" | grep 'MQTTEdge' | grep -c 'mqtt connection up')"
kv rt_pods "$($K get pods -A --no-headers 2>/dev/null | awk '$2 ~ /reverse-tunnel/ {print $1"/"$2":"$4}' | tr '\n' ' ')"
kv dns_mqtt "$(getent ahostsv4 "mqtt-${NAMESPACE}.${DOMAIN}" | awk 'NR==1{print $1}')"
kv dns_deadend "$(getent ahostsv4 "deadend-${NAMESPACE}.${DOMAIN}" | awk 'NR==1{print $1}')"
kv resolv "$(grep -E '^(nameserver|search)' /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null | tr '\n' ';' | cut -c1-300)"
kv sshd "$(sshd -T 2>/dev/null | grep -E '^(passwordauthentication|permitrootlogin|pubkeyauthentication) ' | tr '\n' ';')"
kv bootstrap_log_tail "$(tail -n 3 /var/lib/teknoir-spike/bootstrap.log 2>/dev/null | tr '\n' ';' | cut -c1-300)"
GS

check_guest() {
  section "guest: inside ${DEVICE} (transport: $TRANSPORT)"
  guest_prepare || return 1
  if ! GUEST_KV=$(guest_run "$GUEST_SCRIPT" sudo 2>"${PRIV}/ssh.err"); then
    result FAIL G1 "cannot run commands in the guest over $TRANSPORT: $(head -c 300 "${PRIV}/ssh.err" | tr '\n' ' ')"
    return 1
  fi
  [[ $TRANSPORT == tunnel ]] && result PASS G1 "SSH into the guest through deadend and the device's reverse tunnel works (the tnctl ssh path)" ||
    result PASS G1 "SSH into the guest over virtctl port-forward works"
  result INFO G2 "$(kvget os), kernel $(kvget kernel)"
  local vm want_cpu want_mem_gi
  vm=$(kc -n "$VDEV_NS" get virtualmachine "$DEVICE" -o json 2>/dev/null || echo '{}')
  want_cpu=$(jget '.spec.template.spec.domain.cpu.cores // 0' <<<"$vm")
  want_mem_gi=$(jget '.spec.template.spec.domain.resources.requests.memory // "0Gi" | sub("Gi$";"")' <<<"$vm")
  local mem_gib
  mem_gib=$(awk -v k="$(kvget mem_kib)" 'BEGIN{printf "%.1f", k/1024/1024}')
  if [[ $(kvget nproc) == "$want_cpu" ]] && awk -v m="$mem_gib" -v w="$want_mem_gi" 'BEGIN{exit !(m > w-0.6 && m <= w)}'; then
    result PASS G3 "guest sees exactly the VM size: nproc=$(kvget nproc), MemTotal=${mem_gib} GiB (spec ${want_cpu} vCPU / ${want_mem_gi}Gi)"
  else
    result FAIL G3 "guest size nproc=$(kvget nproc) MemTotal=${mem_gib} GiB does not match spec ${want_cpu} vCPU / ${want_mem_gi}Gi"
  fi
  [[ $(kvget cloudinit) == "done" ]] && result PASS G4 "cloud-init done" || result FAIL G4 "cloud-init status '$(kvget cloudinit)'"
  [[ $(kvget spike_bootstrap-exit) == 0 ]] && result PASS G5 "tnctl server bootstrap exited 0 ($(kvget spike_bootstrap-started) -> $(kvget spike_bootstrap-finished))" ||
    result FAIL G5 "tnctl server bootstrap exit '$(kvget spike_bootstrap-exit)'; log tail: $(kvget bootstrap_log_tail)"
  [[ $(kvget qga) == active ]] && result PASS G6 "qemu-guest-agent active" || result FAIL G6 "qemu-guest-agent '$(kvget qga)'"
  # systemd-detect-virt says "kvm" for hardware virtualization and "qemu" for TCG.
  [[ $(kvget virt) == kvm ]] && result PASS G6b "hardware virtualization in the guest: systemd-detect-virt=kvm ($(kvget hypervisor))" ||
    result FAIL G6b "guest is not KVM-accelerated: systemd-detect-virt='$(kvget virt)'"

  local ccs
  ccs=$(kvget checkconfig_status)
  if [[ $ccs == "STATUS: pass"* ]]; then
    result PASS G7 "k3s check-config: $ccs"
  else
    result FAIL G7 "k3s check-config: '${ccs:-no output}'; problems: $(kvget checkconfig_problems)"
  fi
  local mods m
  mods=""
  for m in overlay br_netfilter vxlan nf_tables ip_tables iptable_nat xt_conntrack nf_conntrack; do mods+="$m=$(kvget "mod_$m") "; done
  [[ $mods != *missing* ]] && result PASS G8 "kernel modules: $mods(genericcloud question, critique #9)" || result FAIL G8 "kernel modules: $mods"

  local want_k3s
  want_k3s=$(jget '.metadata.annotations["teknoir.org/k3s-version"] // empty' <<<"$vm")
  want_k3s=${want_k3s:-$VDS_K3S_VERSION}
  [[ $(kvget k3s_active) == active && $(kvget k3s_version) == "$want_k3s" ]] &&
    result PASS G9 "k3s $(kvget k3s_version) active since $(kvget k3s_since); node $(kvget inner_node)" ||
    result FAIL G9 "k3s '$(kvget k3s_active)' version '$(kvget k3s_version)' (rendered with ${want_k3s})"
  if [[ $(kvget k3s_ca_errors) =~ ^[1-9] ]]; then
    result FAIL G9b "k3s logged 'CA cert validation failed' $(kvget k3s_ca_errors)x; root CA has keyCertSign: $([[ $(kvget root_ca_certsign) == 0 ]] && echo no || echo yes). k3s >= v1.34.12/v1.35.9/v1.36.5 ignores a root without keyCertSign (README 'Finding')"
  fi
  local svc dns pc
  svc=$(kvget inner_svc_kubernetes)
  dns=$(kvget inner_kubedns)
  pc=$(kvget inner_podcidr)
  [[ $svc == 10.53.* && $dns == "$VDS_CLUSTER_DNS" && $pc == 10.52.* ]] &&
    result PASS G10 "inner k3s CIDRs: services 10.53/16 (kubernetes $svc, kube-dns $dns), pods $pc" ||
    result FAIL G10 "inner k3s CIDRs wrong: kubernetes=$svc kube-dns=$dns podCIDR=$pc"
  [[ $(kvget toe_phase) == Running ]] && result PASS G11 "TOE pod Running (image $(kvget toe_image | sed 's/.*@//' | cut -c1-19)...)" || result FAIL G11 "TOE pod phase '$(kvget toe_phase)'"
  if [[ $(kvget toe_up_count) =~ ^[1-9][0-9]*$ ]]; then
    result PASS G12 "TOE's cloud MQTT client connected to mqtt-<ns>.<domain> $(kvget toe_up_count)x (first $(kvget toe_first_up)); failed attempts: $(kvget toe_err_count)"
  else
    result FAIL G12 "TOE's cloud MQTT client never connected (failed attempts: $(kvget toe_err_count); last: $(kvget toe_last_err))"
  fi
  result INFO G12b "TOE's local edge-broker client connections: $(kvget toe_edge_up)"
  result INFO G13 "reverse-tunnel pods: $(kvget rt_pods)"

  local gw_ip pub
  gw_ip=$(kc -n istio-system get svc istio-ingressgateway-public -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  pub=$(getent ahostsv4 "mqtt-${NAMESPACE}.${DOMAIN}" 2>/dev/null | awk 'NR==1{print $1}' || true)
  if [[ -n $gw_ip && $(kvget dns_mqtt) == "$gw_ip" && $(kvget dns_deadend) == "$gw_ip" ]]; then
    result PASS G14 "DNS in the guest: mqtt-/deadend-${NAMESPACE}.${DOMAIN} -> $gw_ip (istio-ingressgateway-public ClusterIP; CoreDNS override active)"
  else
    result WARN G14 "DNS in the guest: mqtt -> '$(kvget dns_mqtt)', deadend -> '$(kvget dns_deadend)'; gateway ClusterIP $gw_ip; public answer seen from here '$pub' (override inactive: does CoreDNS need a restart to load coredns-custom?)"
  fi
  result INFO G15 "guest resolver: $(kvget resolv)"
  result INFO G16 "guest sshd: $(kvget sshd)"
}

# ------------------------------------------------------------------ isolation
check_isolation() {
  section "isolation: connection attempts from inside ${DEVICE} (critique #16: by IP, not by cluster DNS name)"
  guest_prepare || return 1
  local jwks_pod jwks_svc emqx_svc dead_svc prom_svc other node_ip gw_ip pub kube_api
  jwks_pod=$(kc -n "$NAMESPACE" get pods -l app=jwks -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  [[ -n $jwks_pod ]] || jwks_pod=$(kc -n "$NAMESPACE" get endpointslices -l kubernetes.io/service-name=jwks -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)
  jwks_svc=$(kc -n "$NAMESPACE" get svc jwks -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  emqx_svc=$(kc -n "$NAMESPACE" get svc emqx -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  dead_svc=$(kc -n "$NAMESPACE" get svc deadend -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  prom_svc=$(kc -n "$NAMESPACE" get svc prometheus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  kube_api=$(kc -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  # A pod of another namespace with a declared container port (teknoir-system first).
  other=$(kc -n teknoir-system get pods -o json 2>/dev/null |
    jq -r '[.items[] | select(.status.phase=="Running" and .status.podIP!=null and (.spec.hostNetwork|not)) | {ip:.status.podIP, port:([.spec.containers[].ports[]?.containerPort][0]), n:.metadata.name} | select(.port!=null)][0] | "\(.ip) \(.port) \(.n)"' || true)
  node_ip=$(kc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  gw_ip=$(kc -n istio-system get svc istio-ingressgateway-public -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  pub=$(getent ahostsv4 "mqtt-${NAMESPACE}.${DOMAIN}" 2>/dev/null | awk 'NR==1{print $1}' || true)

  # expect|id|label|host|port  (expect: closed = must be blocked, open = must work, info)
  local targets=""
  add() { [[ -n $4 && -n $5 ]] && targets+="$1|$2|$3|$4|$5"$'\n' || result SKIP "$2" "$3: target not found"; }
  add closed I1 "jwks pod :8083 (device key registration)" "$jwks_pod" 8083
  add closed I2 "jwks Service :8083" "$jwks_svc" 8083
  add closed I3 "emqx Service :1883 (plaintext MQTT)" "$emqx_svc" 1883
  add closed I4 "emqx Service :18083 (dashboard)" "$emqx_svc" 18083
  add closed I5 "deadend Service :22 (in-cluster SSH)" "$dead_svc" 22
  add closed I6 "teamspace Prometheus Service :80" "$prom_svc" 80
  add closed I7 "pod of another namespace (${other##* })" "$(awk '{print $1}' <<<"$other")" "$(awk '{print $2}' <<<"$other")"
  add closed I8 "kube-apiserver Service :443" "$kube_api" 443
  add closed I9 "node :6443 (API server)" "$node_ip" 6443
  add closed I10 "node :10250 (kubelet)" "$node_ip" 10250
  add closed I11 "link-local metadata 169.254.169.254:80" 169.254.169.254 80
  add open I12 "mqtt-${NAMESPACE}.${DOMAIN}:8883 (by name)" "mqtt-${NAMESPACE}.${DOMAIN}" 8883
  add open I13 "deadend-${NAMESPACE}.${DOMAIN}:2222 (by name)" "deadend-${NAMESPACE}.${DOMAIN}" 2222
  add open I14 "public ingress gateway ClusterIP :8883" "$gw_ip" 8883
  add open I15 "internet 1.1.1.1:443 (staging egress like a real device)" 1.1.1.1 443
  add info I16 "node :8883 (LoadBalancer VIP: open = DNATed to the gateway pod, closed = svclb hostPort path)" "$node_ip" 8883
  add info I17 "public IP of mqtt-${NAMESPACE}.${DOMAIN} :8883 (router hairpin)" "$pub" 8883

  local probe_script
  probe_script="set -u
while IFS='|' read -r e id label host port; do
  [ -n \"\$id\" ] || continue
  if timeout 4 bash -c \"exec 3<>/dev/tcp/\$host/\$port\" 2>/dev/null; then r=open; else r=closed; fi
  printf '%s|%s|%s|%s|%s|%s\n' \"\$e\" \"\$id\" \"\$label\" \"\$host\" \"\$port\" \"\$r\"
done <<'EOT'
${targets}EOT"
  local out
  if ! out=$(guest_run "$probe_script" user 2>"${PRIV}/ssh.err"); then
    result FAIL I0 "cannot run probes in the guest: $(head -c 300 "${PRIV}/ssh.err" | tr '\n' ' ')"
    return 1
  fi
  report_probes "guest shell" "$out"

  if [[ $INNER_POD == true ]]; then
    local nc_lines="" e id label host port
    while IFS='|' read -r e id label host port; do
      [[ -n $id ]] || continue
      nc_lines+="if nc -z -w 3 $host $port </dev/null >/dev/null 2>&1; then r=open; else r=closed; fi; echo \"$e|$id|$label|$host|$port|\$r\"; "
    done <<<"$targets"
    local pod_name="vd-s1-probe-$RANDOM"
    # Not 'kubectl run -i': attaching races the first probe results. Run, wait, read logs.
    local inner="K='k3s kubectl -n default'
\$K run ${pod_name} --image=${VDS_PROBE_IMAGE} --restart=Never --command -- sh -c '${nc_lines//\'/}' >/dev/null
\$K wait --for=jsonpath='{.status.phase}'=Succeeded pod/${pod_name} --timeout=240s >/dev/null 2>&1
\$K logs pod/${pod_name}
\$K delete pod ${pod_name} --wait=false >/dev/null 2>&1"
    if out=$(guest_run "$inner" sudo 2>"${PRIV}/ssh.err") && grep -q '|' <<<"$out"; then
      report_probes "inner pod" "$(grep '|' <<<"$out")"
    else
      result FAIL I0p "inner-pod probes failed: $(head -c 300 "${PRIV}/ssh.err" | tr '\n' ' ')"
    fi
  fi
}

report_probes() {
  local where=$1 out=$2 e id label host port r
  while IFS='|' read -r e id label host port r; do
    [[ -n $id ]] || continue
    case "$e:$r" in
      closed:closed) result PASS "$id" "[$where] blocked: $label ($host:$port)" ;;
      closed:open) result FAIL "$id" "[$where] REACHABLE: $label ($host:$port)" ;;
      open:open) result PASS "$id" "[$where] reachable: $label ($host:$port)" ;;
      open:closed) result FAIL "$id" "[$where] NOT reachable: $label ($host:$port)" ;;
      info:*) result INFO "$id" "[$where] $r: $label ($host:$port)" ;;
    esac
  done <<<"$out"
}

# ------------------------------------------------------------------ removed
# absent ARGS...: 0 when the API answers NotFound (or the type no longer exists), 1 when
# the object exists, 2 on any other error (connection, RBAC): never a silent PASS.
absent() {
  local err
  if err=$(kc "$@" -o name 2>&1 >/dev/null); then return 1; fi
  [[ $err == *NotFound* || $err == *"not found"* || $err == *"doesn't have a resource type"* ]] && return 0
  return 2
}
absent_result() { # absent_result ID LABEL HINT ARGS...
  local id=$1 label=$2 hint=$3 rc=0
  shift 3
  absent "$@" || rc=$?
  case $rc in
    0) result PASS "$id" "$label: gone" ;;
    1) result FAIL "$id" "$label: still exists${hint:+ ($hint)}" ;;
    *) result FAIL "$id" "$label: cannot tell (kubectl error)" ;;
  esac
}

check_removed() {
  section "removed: nothing of the virtual-device runtime is left ($KUBE_CONTEXT)"
  kc version -o json >/dev/null 2>&1 || { result FAIL R0 "cluster not reachable"; return; }
  local out names

  absent_result R1 "Argo CD application ${ARGOCD_NS}/virtual-devices" \
    "turn virtualDevices.enabled off first, or Argo CD re-creates what you delete" \
    -n "$ARGOCD_NS" get applications.argoproj.io virtual-devices

  if out=$(kc get crd -o json 2>/dev/null); then
    names=$(jget '[.items[].metadata.name | select(test("(^|\\.)kubevirt\\.io$"))] | join(",")' <<<"$out")
    [[ -z $names ]] && result PASS R2 "no CustomResourceDefinitions in *.kubevirt.io" ||
      result FAIL R2 "CRDs left: ${names} (delete the KubeVirt and CDI CRs while the operators run; they remove their CRDs)"
  else
    result FAIL R2 "cannot list CustomResourceDefinitions"
  fi

  if out=$(kc get apiservices -o json 2>/dev/null); then
    names=$(jget '[.items[] | select(.spec.service != null and ((.spec.group // "") | test("(^|\\.)kubevirt\\.io$"))) | .metadata.name] | join(",")' <<<"$out")
    [[ -z $names ]] && result PASS R3 "no aggregated (service-backed) APIServices for *.kubevirt.io" ||
      result FAIL R3 "stale aggregated APIServices: ${names}. Without their service, API discovery is incomplete cluster-wide (namespace deletion and garbage collection stall); see README 'Removing the runtime'"
    names=$(jget '[.items[] | select(([.status.conditions[]? | select(.type=="Available") | .status][0] // "True") != "True") | .metadata.name] | join(",")' <<<"$out")
    [[ -z $names ]] && result PASS R3b "every APIService in the cluster is Available" ||
      result FAIL R3b "APIServices not Available: ${names}"
  else
    result FAIL R3 "cannot list APIServices"
  fi

  local kind
  for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
    if out=$(kc get "$kind" -o json 2>/dev/null); then
      names=$(jget '[.items[] | select(([.webhooks[]?.clientConfig.service.namespace // empty] | any(. == "kubevirt" or . == "cdi")) or (.metadata.name | test("^(virt-|kubevirt|cdi)"))) | .metadata.name] | join(",")' <<<"$out")
      [[ -z $names ]] && result PASS R4 "no ${kind} of KubeVirt or CDI" ||
        result FAIL R4 "${kind} left: ${names} (a webhook whose service is gone rejects writes to the objects it matches)"
    else
      result FAIL R4 "cannot list ${kind}"
    fi
  done

  local ns
  for ns in kubevirt cdi; do
    absent_result R5 "namespace ${ns}" "" get namespace "$ns"
  done
  local pc
  for pc in kubevirt-cluster-critical teknoir-virtual-device; do
    absent_result R6 "PriorityClass ${pc}" "" get priorityclass "$pc"
  done

  if out=$(kc -n kube-system get configmap coredns-custom -o json 2>/dev/null); then
    if [[ $(jget '.data | has("virtual-devices.override")' <<<"$out") == true ]]; then
      result FAIL R7 "kube-system/coredns-custom still has key virtual-devices.override: (mqtt|deadend)-* names are still rewritten cluster-wide"
    else
      result PASS R7 "kube-system/coredns-custom has no virtual-devices.override key (other keys: $(jget '[.data // {} | keys[]] | join(",")' <<<"$out"))"
    fi
  else
    absent_result R7 "ConfigMap kube-system/coredns-custom (and with it the mqtt-/deadend- rewrite)" "" -n kube-system get configmap coredns-custom
  fi

  for kind in clusterroles clusterrolebindings; do
    if out=$(kc get "$kind" -o json 2>/dev/null); then
      names=$(jget '[.items[].metadata.name | select(test("kubevirt|^cdi([.:-]|$)"))] | join(",")' <<<"$out")
      [[ -z $names ]] && result PASS R8 "no ${kind} of KubeVirt or CDI" || result FAIL R8 "${kind} left: ${names}"
    else
      result FAIL R8 "cannot list ${kind}"
    fi
  done
  # KubeVirt and CDI aggregate their roles into the built-in admin/edit/view; the
  # aggregation controller drops those rules once the source roles are gone.
  local role
  for role in admin edit view; do
    out=$(kc get clusterrole "$role" -o json 2>/dev/null || echo '{}')
    names=$(jget '[.rules[]?.apiGroups[]? | select(test("(^|\\.)kubevirt\\.io$"))] | unique | join(",")' <<<"$out")
    [[ -z $names ]] && result PASS R8b "ClusterRole ${role} aggregates no *.kubevirt.io rules" ||
      result FAIL R8b "ClusterRole ${role} still aggregates rules for: ${names}"
  done

  local err
  if err=$(kc api-resources -o name 2>&1 >/dev/null) && [[ -z $err ]]; then
    result PASS R9 "API discovery is complete (kubectl api-resources reports no error)"
  else
    result FAIL R9 "API discovery is incomplete: $(head -n 2 <<<"$err" | tr '\n' ' ')"
  fi

  # Left on the nodes by virt-handler (labels, annotations, extended resources). Harmless
  # for the platform; README 'Removing the runtime' has the cleanup commands.
  if out=$(kc get nodes -o json 2>/dev/null); then
    local n nl na nr
    while IFS=$'\t' read -r n nl na nr; do
      if ((nl + na + nr == 0)); then
        result PASS R10 "node ${n}: no KubeVirt labels, annotations or extended resources"
      else
        result INFO R10 "node ${n}: left by virt-handler: ${nl} labels, ${na} annotations, ${nr} extended resources (cosmetic; README has the cleanup)"
      fi
    done < <(jq -r '.items[] | [.metadata.name,
        ([(.metadata.labels // {}) | keys[] | select(test("kubevirt\\.io"))] | length),
        ([(.metadata.annotations // {}) | keys[] | select(test("kubevirt\\.io"))] | length),
        ([(.status.capacity // {}) | to_entries[] | select((.key | test("kubevirt\\.io")) and .value != "0")] | length)] | @tsv' <<<"$out")
  else
    result FAIL R10 "cannot list nodes"
  fi
}

# ------------------------------------------------------------------ timing
check_timing() {
  section "timing: time to online"
  local vm dv vmi t0
  vm=$(kc -n "$VDEV_NS" get virtualmachine "$DEVICE" -o json 2>/dev/null || echo '{}')
  dv=$(kc -n "$VDEV_NS" get datavolume "${DEVICE}-root" -o json 2>/dev/null || echo '{}')
  vmi=$(kc -n "$VDEV_NS" get virtualmachineinstance "$DEVICE" -o json 2>/dev/null || echo '{}')
  t0=$(ts_to_epoch "$(jget '.metadata.creationTimestamp' <<<"$vm")")
  [[ -n $t0 ]] || { result FAIL T0 "VM not found"; return; }
  if [[ -z $GUEST_KV ]] && guest_prepare; then
    GUEST_KV=$(guest_run "$GUEST_SCRIPT" sudo 2>/dev/null) || GUEST_KV=""
  fi
  local rows=(
    "VM created|$(jget '.metadata.creationTimestamp' <<<"$vm")"
    "root disk imported (DataVolume Ready)|$(jget '[.status.conditions[]? | select(.type=="Ready" and .status=="True") | .lastTransitionTime][0]' <<<"$dv")"
    "VMI scheduled|$(jget '[.status.phaseTransitionTimestamps[]? | select(.phase=="Scheduled") | .phaseTransitionTimestamp][0]' <<<"$vmi")"
    "VMI running|$(jget '[.status.phaseTransitionTimestamps[]? | select(.phase=="Running") | .phaseTransitionTimestamp][0]' <<<"$vmi")"
    "guest booted|$(kvget boot_time)"
    "cloud-init runcmd started|$(kvget spike_runcmd-started)"
    "guest agent connected|$(jget '[.status.conditions[]? | select(.type=="AgentConnected" and .status=="True") | (.lastTransitionTime // .lastProbeTime)][0]' <<<"$vmi")"
    "bootstrap started|$(kvget spike_bootstrap-started)"
    "bootstrap finished|$(kvget spike_bootstrap-finished)"
    "TOE container started|$(kvget toe_started)"
    "TOE cloud MQTT connection up (online)|$(kvget toe_first_up)"
  )
  local row label ts e
  for row in "${rows[@]}"; do
    label=${row%%|*}
    ts=${row#*|}
    e=$(ts_to_epoch "$ts")
    if [[ -n $e ]]; then
      printf '     %-42s %s  +%ss\n' "$label" "$ts" "$((e - t0))"
    else
      printf '     %-42s %s\n' "$label" "(not observed)"
    fi
  done
  local online
  online=$(ts_to_epoch "$(kvget toe_first_up)")
  if [[ -n $online ]]; then
    result PASS T1 "time to online (VM created -> TOE cloud MQTT connection up): $((online - t0))s"
  else
    result FAIL T1 "time to online not measurable: TOE has not connected"
  fi
}

# ------------------------------------------------------------------ main
printf 'S1 checks: context=%s teamspace=%s runtime=%s device=%s phases=%s\n' "$KUBE_CONTEXT" "$NAMESPACE" "$VDEV_NS" "${DEVICE:-'-'}" "$PHASES"
want platform && check_platform
want namespace && check_namespace
want vm && check_vm
want device && check_device
want guest && { check_guest || true; }
want isolation && { check_isolation || true; }
want timing && { check_timing || true; }
want removed && check_removed

printf '\nSummary: %d PASS, %d FAIL, %d WARN, %d INFO/SKIP\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$INFO_COUNT"
((FAIL_COUNT == 0))
