#!/usr/bin/env bash
# End-to-end test of charts/virtual-devices, its Argo CD Application and the spike kit
# on a throwaway k3d cluster with KVM. HEAVY: about 2.5 GB of images and 30-45
# minutes. Run it under the shared lock, e.g.
#   flock /path/to/heavy.lock hack/virtual-device-spike/test/k3d-e2e.sh
#
# It creates cluster vd-s1-e2e (k3s v1.34.5, like r415) with its own kubeconfig (the
# default kubeconfig and current context are not touched), then:
#   1. installs Argo CD v3.5.1 (the version r415 runs) with r415's argocd-cm settings,
#      and syncs the virtual-devices Application exactly as charts/app-of-apps renders
#      it for teknoir-cloud. Only spec.source differs: the branch is not on GitHub, so
#      Argo CD reads the same chart from an in-cluster Helm repository;
#   2. checks that Argo CD and the operators do not fight: over r415's reconciliation
#      window the Application stays Synced, no sync operation runs (counted from the
#      Application's events, so partial selfHeal syncs count too), and the generations
#      of the CRs, CRDs and operator Deployments do not move; then forces a full re-sync
#      (as the next commit would) and checks the same again over a longer window. It
#      prints timelines of the Application and of the KubeVirt and CDI CRs, recorded by
#      watches from before the first sync, and the application-controller's log about
#      the Application, so every sync operation shows with the state that caused it;
#   3. adds stand-ins for the platform (gateway, teamspace services) and the Device CRD
#      with a fixture Device holding a throwaway key;
#   4. checks that the CoreDNS override takes effect and how (reload or restart);
#   5. renders the kit for the fixture Device, applies it, waits for the guest's
#      tnctl bootstrap to finish;
#   6. runs check.sh --phase all over the virtctl transport with --inner-pod and
#      compares the results with what this environment can show;
#   7. rollback: deletes the Application (what virtualDevices.enabled=false does) and
#      checks that the runtime stays; then removes the runtime in the order the README
#      documents and runs check.sh --phase removed.
# The cluster is deleted on exit unless KEEP=1. ARGO_ONLY=1 stops after step 2 (about
# 12 minutes). ARTIFACTS=<dir> keeps the full timelines and the controller log there.
#
# Needs: docker, k3d, kubectl, helm, jq, python3 (PyYAML), go, openssl, curl, /dev/kvm.
# shellcheck disable=SC2015  # "test && pass || flunk": pass always returns 0
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
# Argo CD as r415 runs it (teknoir-system, checked read-only 2026-10-09): v3.5.1, default
# (annotation) resource tracking. core-install has the controller and repo-server only.
ARGOCD_VERSION=v3.5.1
ARGOCD_MANIFEST_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/core-install.yaml"
ARGOCD_MANIFEST_SHA256="cb6bbcc84e1ab601f43364afd401fb0a7831536d07da74393c9edb1196f80500"
ARGOCD_IMAGE="quay.io/argoproj/argocd:v3.5.1@sha256:0deb1a1c917629b960ead995ae3b6069450a866992676599658687ef9a641ee8"
ARGOCD_REDIS_IMAGE="public.ecr.aws/docker/library/redis:8.2.3-alpine@sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba"
ARGO_NS=argocd
# r415: timeout.reconciliation 120s + jitter 60s; the window covers a full refresh.
STABILITY_SECONDS=${STABILITY_SECONDS:-210}
# After the forced re-sync: longer than selfHeal's retry backoff and a few refreshes, so
# a slow periodic fight (several minutes apart) shows up too.
STABILITY2_SECONDS=${STABILITY2_SECONDS:-330}
DEVICE=vd-s1-fixture
KEEP=${KEEP:-0}
ARGO_ONLY=${ARGO_ONLY:-0}
DISK=${DISK:-containerdisk}
JQ_LIB="${HERE}/jq"

log() { printf '[e2e %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
for t in docker k3d kubectl helm jq python3 go openssl curl; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[[ -c /dev/kvm ]] || die "/dev/kvm is required"

TMP=$(mktemp -d)
chmod 700 "$TMP"
export KUBECONFIG="${TMP}/kubeconfig"
# Argo CD diagnostics (timelines, controller log). They hold no secrets: the
# Application, the KubeVirt and CDI CRs and the controller's log about them.
ART=${ARTIFACTS:-${TMP}/artifacts}
mkdir -p "$ART"
WATCHERS=()
kill_tree() { local c; for c in $(pgrep -P "$1" || true); do kill_tree "$c"; done; kill "$1" 2>/dev/null || true; }
stop_watchers() { local p; for p in "${WATCHERS[@]}"; do kill_tree "$p"; done; WATCHERS=(); }
ARGO_DIAG_DONE=0
cleanup() {
  local rc=$?
  stop_watchers
  if ((rc != 0 && ARGO_DIAG_DONE == 0)) && [[ -s ${ART}/application.jsonl ]]; then
    argo_diagnostics || true
  fi
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

# Results of the e2e's own assertions (check.sh results are evaluated separately).
fail=0
pass() { log "PASS $*"; }
flunk() { log "FAIL $*"; fail=1; }

# ------------------------------------------------------------------ downloads (pinned, cached)
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/teknoir-vd-spike"
fetch() { # fetch URL SHA256 DEST
  [[ -s $3 ]] && return 0
  mkdir -p "$(dirname "$3")"
  curl -fsSL -o "$3.download" "$1"
  echo "$2  $3.download" | sha256sum -c - >/dev/null || die "checksum mismatch for $1"
  mv "$3.download" "$3"
}
VIRTCTL_DIR="${CACHE_DIR}/virtctl-${VDS_KUBEVIRT_VERSION}"
fetch "$VIRTCTL_URL" "$VIRTCTL_SHA256" "${VIRTCTL_DIR}/virtctl"
chmod 755 "${VIRTCTL_DIR}/virtctl"
export PATH="${VIRTCTL_DIR}:$PATH"
ARGOCD_MANIFEST="${CACHE_DIR}/argocd-${ARGOCD_VERSION}/core-install.yaml"
fetch "$ARGOCD_MANIFEST_URL" "$ARGOCD_MANIFEST_SHA256" "$ARGOCD_MANIFEST"

# ------------------------------------------------------------------ cluster
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
log "creating k3d cluster ${CLUSTER} (${K3S_IMAGE%@*})"
k3d cluster create "$CLUSTER" --image "$K3S_IMAGE" --no-lb --wait --timeout 300s \
  --k3s-arg '--disable=traefik@server:0' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false >/dev/null
k3d kubeconfig get "$CLUSTER" >"$KUBECONFIG"
k get nodes -o wide

# ------------------------------------------------------------------ Argo CD
log "installing Argo CD ${ARGOCD_VERSION} (core) with r415's argocd-cm settings"
python3 -I - "$ARGOCD_MANIFEST" "${TMP}/argocd.yaml" "$ARGOCD_IMAGE" "$ARGOCD_REDIS_IMAGE" <<'PY'
import sys, yaml
src, dst, argocd_image, redis_image = sys.argv[1:]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
n = 0
for d in docs:
    if d["kind"] in ("Deployment", "StatefulSet"):
        spec = d["spec"]["template"]["spec"]
        for c in spec.get("initContainers", []) + spec.get("containers", []):
            if c["image"] == "quay.io/argoproj/argocd:v3.5.1":
                c["image"] = argocd_image
            elif c["image"] == redis_image.split("@")[0]:
                c["image"] = redis_image
            else:
                raise SystemExit(f"unexpected image {c['image']}: update the pins")
            n += 1
    if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "argocd-cm":
        # r415's argocd-cm (2026-10-09) is the v3.5.1 default (ignoreResourceUpdates,
        # resource.exclusions) plus these keys; its OIDC, URL and UI keys are left out.
        assert "resource.customizations.ignoreResourceUpdates.all" in d["data"], "defaults changed: compare with r415"
        d["data"].update({
            "application.instanceLabelKey": "argocd.argoproj.io/instance",
            "application.sync.impersonation.enabled": "false",
            "timeout.reconciliation": "120s",
            "timeout.hard.reconciliation": "0s",
            "timeout.reconciliation.jitter": "60s",
        })
yaml.safe_dump_all(docs, open(dst, "w"))
print(f"pinned {n} Argo CD containers by digest", file=sys.stderr)
PY
k create namespace "$ARGO_NS" >/dev/null
k -n "$ARGO_NS" apply --server-side -f "${TMP}/argocd.yaml" >/dev/null
k -n "$ARGO_NS" rollout status statefulset/argocd-application-controller --timeout=600s
k -n "$ARGO_NS" rollout status deploy/argocd-repo-server --timeout=600s
k -n "$ARGO_NS" rollout status deploy/argocd-redis --timeout=600s

# The chart, served by an in-cluster Helm repository (static files).
log "serving charts/virtual-devices from an in-cluster Helm repository"
mkdir -p "${TMP}/chartrepo"
helm package "${REPO}/charts/virtual-devices" -d "${TMP}/chartrepo" >/dev/null
CHART_REPO_URL="http://chart-repo.${ARGO_NS}.svc.cluster.local"
helm repo index "${TMP}/chartrepo" --url "$CHART_REPO_URL"
CHART_VERSION=$(helm show chart "${REPO}/charts/virtual-devices" | awk '/^version:/{print $2}')
k -n "$ARGO_NS" create configmap chart-repo --from-file="${TMP}/chartrepo" >/dev/null
k -n "$ARGO_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chart-repo
spec:
  replicas: 1
  selector: {matchLabels: {app: chart-repo}}
  template:
    metadata: {labels: {app: chart-repo}}
    spec:
      containers:
        - name: httpd
          image: ${VDS_PROBE_IMAGE}
          command: ["httpd", "-f", "-p", "8080", "-h", "/srv"]
          ports: [{containerPort: 8080}]
          volumeMounts: [{name: repo, mountPath: /srv}]
      volumes: [{name: repo, configMap: {name: chart-repo}}]
---
apiVersion: v1
kind: Service
metadata:
  name: chart-repo
spec:
  selector: {app: chart-repo}
  ports: [{port: 80, targetPort: 8080}]
EOF
k -n "$ARGO_NS" rollout status deploy/chart-repo --timeout=300s >/dev/null

# AppProject and Application exactly as charts/app-of-apps renders them for
# teknoir-cloud, except metadata.namespace and spec.source.
helm template app-of-apps "${REPO}/charts/app-of-apps" --set project=teknoir-cloud --set virtualDevices.enabled=true >"${TMP}/aoa.yaml"
python3 -I - "${TMP}/aoa.yaml" "${TMP}/argo-app.yaml" "$ARGO_NS" "$CHART_REPO_URL" "$CHART_VERSION" <<'PY'
import copy, sys, yaml
src, dst, ns, repo, version = sys.argv[1:]
docs = [d for d in yaml.safe_load_all(open(src)) if d]
proj = next(d for d in docs if d["kind"] == "AppProject" and d["metadata"]["name"] == "teknoir-cloud")
app = next(d for d in docs if d["kind"] == "Application" and d["metadata"]["name"] == "virtual-devices")
orig = copy.deepcopy(app)
proj["metadata"]["namespace"] = ns
app["metadata"]["namespace"] = ns
# Rendered the same way as the git path source on r415: release name = Application
# name, namespace = destination namespace, the chart's own values.yaml.
app["spec"]["source"] = {"repoURL": repo, "chart": "virtual-devices", "targetRevision": version}
assert {k: v for k, v in app["spec"].items() if k != "source"} == {k: v for k, v in orig["spec"].items() if k != "source"}
assert {k: v for k, v in app["metadata"].items() if k != "namespace"} == orig["metadata"]
yaml.safe_dump_all([proj, app], open(dst, "w"))
print("syncPolicy:", app["spec"]["syncPolicy"], "annotations:", app["metadata"].get("annotations"), file=sys.stderr)
PY
N_RENDERED=$(helm template virtual-devices "${REPO}/charts/virtual-devices" --namespace kubevirt | grep -c '^kind:')

# Watches from before the first sync: the Application and the KubeVirt and CDI CRs, as
# compact timelines (jq/argo.jq). The CR watches retry until Argo CD has created the CRDs.
watch_into() { # watch_into FILE JQ_FUNCTION KUBECTL_GET_ARGS...
  local out=$1 fn=$2
  shift 2
  (
    while :; do
      kubectl --context "$CTX" get "$@" --watch --output-watch-events -o json 2>>"${out}.err" || true
      sleep 2
    done | jq -L "$JQ_LIB" -n -c --unbuffered "include \"argo\"; ${fn}" >>"$out" 2>>"${out}.err"
  ) 2>/dev/null & # stop_watchers kills it: no "Terminated" notice from the subshell in the log
  WATCHERS+=("$!")
}
watch_into "${ART}/application.jsonl" app_timeline -n "$ARGO_NS" applications.argoproj.io --field-selector metadata.name=virtual-devices
watch_into "${ART}/kubevirt.jsonl" cr_timeline -n kubevirt kubevirts.kubevirt.io
watch_into "${ART}/cdi.jsonl" cr_timeline cdis.cdi.kubevirt.io
# The application-controller's log lines about the Application's operations: how each
# one started (automated or requested), resumed and ended, auto-sync decisions other than
# "Synced" and "operation in progress", and every warning or error. Repeats are counted.
controller_log() {
  k -n "$ARGO_NS" logs statefulset/argocd-application-controller --timestamps >"${ART}/application-controller.log" 2>&1 || true
  jq -R -r 'capture("^(?<ts>[^ ]+) (?<j>[{].*)$")? | (.j | fromjson? // empty) as $j | select($j.application == "virtual-devices")
    | select(($j.level != "info" and $j.level != "debug")
             or ($j.msg | test("Initiated automated sync|Initialized new operation|Resuming in-progress|Skipping auto-sync|operation \\(phase: (Succeeded|Failed|Error)|[Ss]ync operation to|Retrying|[Tt]erminating")
                 and (test("application status is Synced|another operation is in progress") | not)))
    | "\(.ts[11:23]) \($j.level) \($j.msg | gsub("\\s+"; " ") | .[:300])"' "${ART}/application-controller.log" | uniq -c -f2 || true
}
argo_diagnostics() {
  ARGO_DIAG_DONE=1
  log "timeline (A: Application, one line per change of its operation, operationState, sync/health or not-Synced resources;"
  log "          C: KubeVirt/CDI CR, one line per change of generation, spec, finalizers or spec owners."
  log "          The CDI CRD has no status subresource, so cdi-operator's status writes move CDI's generation too):"
  { sed 's/^/A /' "${ART}/application.jsonl"; sed 's/^/C /' "${ART}/kubevirt.jsonl" "${ART}/cdi.jsonl" 2>/dev/null; } |
    sort -s -k2,2 | cut -c1-1500 | sed 's/^/[e2e]   /' >&2
  log "application-controller log about the Application's operations (full log: ${ART}/application-controller.log):"
  controller_log | cut -c1-400 | sed 's/^/[e2e]   /' >&2
}

T_SYNC=$(date +%s)
k apply -f "${TMP}/argo-app.yaml" >/dev/null

app_json() { k -n "$ARGO_NS" get application virtual-devices -o json; }
app_state() { app_json | jq -r '"\(.status.sync.status) \(.status.health.status) \(.status.operationState.phase)"'; }
if ! wait_for 1800 '^Synced Healthy Succeeded$' "Argo CD application virtual-devices (sync/health/operation)" app_state; then
  app_json | jq '{conditions: .status.conditions, operation: .status.operationState | {phase, message, retryCount}, notSynced: [.status.resources[]? | select(.status != "Synced")]}'
  die "Argo CD did not sync the chart"
fi
log "first sync took $(($(date +%s) - T_SYNC))s: $(app_json | jq -c '.status.history[0] | {started: .deployStartedAt, finished: .deployedAt, revision}')"
OP=$(app_json | jq -L "$JQ_LIB" -c 'include "argo"; .status.operationState | {phase, by: (.operation | initiator), resources: (.operation | op_resources),
  retryCount: (.retryCount // 0), message, started: .startedAt, finished: .finishedAt}')
log "latest operation: ${OP}"
not_synced=$(app_json | jq -r '[.status.operationState.syncResult.resources[] | select(.status != "Synced") | "\(.kind)/\(.name): \(.message)"] | join("; ")')
[[ -z $not_synced ]] && pass "every resource of the latest sync applied" || flunk "resources not applied by the latest sync: $not_synced"

wait_for 1500 '^Deployed$' "KubeVirt phase" k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}' || {
  k -n kubevirt get pods -o wide
  die "KubeVirt did not deploy"
}
wait_for 900 '^Deployed$' "CDI phase" k get cdi cdi -o jsonpath='{.status.phase}' || die "CDI did not deploy"
wait_for 300 '^[1-9]' "devices.kubevirt.io/kvm allocatable" k get nodes -o jsonpath='{.items[0].status.allocatable.devices\.kubevirt\.io/kvm}' ||
  die "no KVM device on the node"
k -n kubevirt get pdb -o custom-columns='PDB:.metadata.name,MIN:.spec.minAvailable,ALLOWED:.status.disruptionsAllowed' || true
k get apiservices | grep -E 'kubevirt|NAME' || true

# ------------------------------------------------------------------ Argo CD vs the operators
# A fight between Argo CD (selfHeal, server-side apply) and virt-operator/cdi-operator
# shows as OutOfSync resources, new sync operations, or spec writes that bump the
# generation of the objects both could touch. Operations are counted from the
# Application's events: a selfHeal sync of single resources ("partial sync") adds no
# history entry, so the history alone would miss it.
argo_snapshot() {
  app_json | jq -c '{sync: .status.sync.status, health: .status.health.status, syncs: (.status.history | length),
    started: .status.operationState.startedAt, n: (.status.resources | length),
    lastOp: ([.status.operationState.operation.sync.resources[]? | "\(.kind)/\(.name)"] | if length == 0 then "all" else join(",") end),
    outOfSync: [.status.resources[] | select(.status != "Synced") | "\(.kind)/\(.name)"],
    prune: [.status.resources[] | select(.requiresPruning == true) | "\(.kind)/\(.name)"]}'
}
# argo_ops: the Application's operation events, oldest first, one "time reason: message" per line.
argo_ops() {
  k -n "$ARGO_NS" get events -o json | jq -r '[.items[]
    | select(.involvedObject.kind == "Application" and .involvedObject.name == "virtual-devices"
             and (.reason == "OperationStarted" or .reason == "OperationCompleted"))
    | {t: (.lastTimestamp // .eventTime // .metadata.creationTimestamp), r: .reason, m: .message}]
    | sort_by(.t)[] | "\(.t) \(.r): \(.m)"'
}
n_ops() { argo_ops | grep -c ' OperationStarted: ' || true; }
generations() {
  {
    k -n kubevirt get kubevirt kubevirt -o jsonpath='KubeVirt={.metadata.generation}{"\n"}'
    k get cdi cdi -o jsonpath='CDI={.metadata.generation}{"\n"}'
    k get crd kubevirts.kubevirt.io cdis.cdi.kubevirt.io -o jsonpath='{range .items[*]}crd/{.metadata.name}={.metadata.generation}{"\n"}{end}'
    k -n kubevirt get deploy virt-operator -o jsonpath='virt-operator={.metadata.generation}{"\n"}'
    k -n cdi get deploy cdi-operator -o jsonpath='cdi-operator={.metadata.generation}{"\n"}'
    k -n kube-system get configmap coredns-custom -o jsonpath='coredns-custom(rv)={.metadata.resourceVersion}{"\n"}'
    k get priorityclass teknoir-virtual-device kubevirt-cluster-critical -o jsonpath='{range .items[*]}pc/{.metadata.name}(rv)={.metadata.resourceVersion}{"\n"}{end}'
  } | tr '\n' ' '
}
assert_steady() { # assert_steady LABEL SNAPSHOT_BEFORE GENERATIONS_BEFORE OPS_BEFORE
  local label=$1 s0=$2 g0=$3 o0=$4 s1 g1 o1
  s1=$(argo_snapshot)
  g1=$(generations)
  o1=$(n_ops)
  log "$label: argo ${s1}"
  log "$label: generations ${g1}"
  [[ $(jq -r '"\(.sync) \(.health)"' <<<"$s1") == "Synced Healthy" ]] && pass "$label: Application Synced/Healthy" || flunk "$label: Application $(jq -r '"\(.sync)/\(.health)"' <<<"$s1")"
  [[ $(jq -r '.outOfSync | length' <<<"$s1") == 0 ]] && pass "$label: no OutOfSync resource" || flunk "$label: OutOfSync: $(jq -r '.outOfSync | join(",")' <<<"$s1")"
  [[ $(jq -r '.prune | length' <<<"$s1") == 0 ]] && pass "$label: nothing to prune (no operand adopted by Argo CD)" || flunk "$label: Argo CD would prune: $(jq -r '.prune | join(",")' <<<"$s1")"
  [[ $(jq -r .n <<<"$s1") == "$N_RENDERED" ]] && pass "$label: Argo CD tracks exactly the ${N_RENDERED} rendered objects" ||
    flunk "$label: Argo CD tracks $(jq -r .n <<<"$s1") objects, the chart renders ${N_RENDERED}"
  [[ $o1 == "$o0" && $(jq -c '{syncs, started}' <<<"$s1") == $(jq -c '{syncs, started}' <<<"$s0") ]] &&
    pass "$label: no sync operation ran (no selfHeal, partial or full, and no auto-sync)" ||
    flunk "$label: Argo CD ran $((o1 - o0)) operation(s): before $(jq -c '{syncs, started}' <<<"$s0"), after $(jq -c '{syncs, started, lastOp}' <<<"$s1"); events: $(argo_ops | tail -n 4 | tr '\n' ';')"
  [[ $g1 == "$g0" ]] && pass "$label: no spec writes to the CRs, CRDs, operators, coredns-custom or PriorityClasses" ||
    flunk "$label: generations moved: before ${g0}, after ${g1}"
}
O0=$(n_ops)
((O0 >= 1)) && pass "Argo CD records its operations as events (${O0} so far)" || flunk "no Argo CD operation events: operations cannot be counted"
log "operations until KubeVirt and CDI were Deployed:"
argo_ops | sed 's/^/[e2e]   /' >&2
# A partial selfHeal of the CRs right after the first sync is Argo CD's own race, not a
# fight: the sync ends as soon as its last wave has applied the KubeVirt and CDI CRs,
# while the status still holds the comparison from before they existed; auto-sync reads
# that status within milliseconds and re-applies the two unchanged CRs. The timelines
# show it for each such selfHeal: requested after the CRs were created and before any
# operator had written them, so no operator-owned field can be the cause.
jq -L "$JQ_LIB" -n -c --slurpfile app "${ART}/application.jsonl" --slurpfile crs <(cat "${ART}/kubevirt.jsonl" "${ART}/cdi.jsonl") \
  'include "argo"; selfheal_report($app; $crs)[]' | while read -r line; do log "INFO startup selfHeal: ${line}"; done
S0=$(argo_snapshot)
G0=$(generations)
log "stability window: ${STABILITY_SECONDS}s"
sleep "$STABILITY_SECONDS"
assert_steady "after ${STABILITY_SECONDS}s" "$S0" "$G0" "$O0"
log "cdis.cdi.kubevirt.io versions: $(k get crd cdis.cdi.kubevirt.io -o jsonpath='{.spec.versions[*].name}')"

log "forcing a full re-sync with the same manifests (what the next commit does)"
# Started the way Argo CD's SetAppOperation starts one (argocd app sync, automated sync;
# see sync_patch in jq/argo.jq): one write that sets .operation and clears
# .status.operationState, conditional on the resourceVersion read while no operation
# was in flight. Without the clear, a full sync requested after a partial selfHeal kept
# that selfHeal's resource list and ran as a partial sync of KubeVirt and CDI. A conflict
# means the controller wrote the Application in between: read it again and retry.
op_idle() { app_json | jq -r 'if .operation == null then "idle" else "busy" end'; }
force_sync() {
  local attempt app out
  for attempt in 1 2 3 4 5; do
    wait_for 300 '^idle$' "no Argo CD operation in flight" op_idle || return 1
    app=$(app_json)
    [[ $(jq -r '.operation == null' <<<"$app") == true ]] || continue
    log "before the patch (attempt ${attempt}): $(jq -L "$JQ_LIB" -c 'include "argo"; app_detail' <<<"$app")"
    if out=$(k -n "$ARGO_NS" patch application virtual-devices --type merge \
      -p "$(jq -L "$JQ_LIB" -c --arg rev "$CHART_VERSION" 'include "argo"; sync_patch("vd-e2e"; $rev)' <<<"$app")" 2>&1); then
      log "right after the patch: $(app_json | jq -L "$JQ_LIB" -c 'include "argo"; app_detail')"
      return 0
    fi
    [[ $out == *"has been modified"* || $out == *Conflict* ]] || { log "patch failed: ${out}"; return 1; }
    log "conflict, the controller wrote the Application after it was read: ${out}"
  done
  return 1
}
SYNCS0=$(jq -r .syncs <<<"$(argo_snapshot)")
resync_state() { app_json | jq -r 'if .status.operationState.operation.initiatedBy.username == "vd-e2e" then "\(.status.operationState.phase) \(.status.sync.status)" else "pending" end'; }
if ! force_sync; then
  flunk "could not start the forced re-sync"
elif wait_for 600 '^Succeeded Synced$' "re-sync" resync_state; then
  log "re-sync finished: $(app_json | jq -L "$JQ_LIB" -c 'include "argo"; app_detail')"
  RESYNC=$(app_json | jq -c '(.status.operationState.operation | {by: .initiatedBy.username, automated: (.initiatedBy.automated // false),
    resources: (.sync.resources // [])}) + {syncs: (.status.history | length)}')
  [[ $(jq -c '{by, automated, resources}' <<<"$RESYNC") == '{"by":"vd-e2e","automated":false,"resources":[]}' && $(jq -r .syncs <<<"$RESYNC") == $((SYNCS0 + 1)) ]] &&
    pass "forced full re-sync succeeded (one more history entry)" || flunk "the re-sync was not the forced full sync: ${RESYNC}"
  S1=$(argo_snapshot)
  O1=$(n_ops)
  log "stability window after the re-sync: ${STABILITY2_SECONDS}s"
  sleep "$STABILITY2_SECONDS"
  assert_steady "${STABILITY2_SECONDS}s after the re-sync" "$S1" "$G0" "$O1"
  [[ $(k get crd cdis.cdi.kubevirt.io -o jsonpath='{.spec.versions[*].name}') == v1beta1 ]] &&
    pass "re-sync kept the operator's cdis.cdi.kubevirt.io versions (RespectIgnoreDifferences)" ||
    flunk "re-sync re-applied the deprecated CDI CRD version: $(k get crd cdis.cdi.kubevirt.io -o jsonpath='{.spec.versions[*].name}')"
else
  flunk "re-sync did not succeed: $(app_json | jq -c '.status.operationState | {phase, message}')"
fi
log "all Argo CD operations:"
argo_ops | sed 's/^/[e2e]   /' >&2
argo_diagnostics
stop_watchers
if [[ $ARGO_ONLY == 1 ]]; then
  ((fail)) && { log "k3d e2e (ARGO_ONLY) FAILED"; exit 1; }
  log "k3d e2e (ARGO_ONLY) passed"
  exit 0
fi

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
# --allow-virtctl-ssh: the e2e has no deadend, so guest access is virtctl port-forward.
# --debug-user: lets the test read the guest before the bootstrap has created the device user.
OUT=$("${KIT}/render.sh" --device "$DEVICE" --fixture "${TMP}/device.json" --context "$CTX" --disk "$DISK" \
  --allow-virtctl-ssh --debug-user --out "${TMP}/render" 2>"${TMP}/render.log") ||
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
    -o ProxyCommand="virtctl --context ${CTX} port-forward --stdio=true vmi/${DEVICE}/teknoir-demo-vdev 22" \
    vdspike@vmi "$@" </dev/null
}
bootstrap_exit() { guest "sudo cat /var/lib/teknoir-spike/bootstrap-exit"; }
diagnose() {
  guest 'sudo sh -c "cloud-init status --long; echo; ls -la /var/lib/teknoir-spike; echo --- bootstrap.log; tail -n 40 /var/lib/teknoir-spike/bootstrap.log; echo --- k3s; systemctl status k3s --no-pager -l | tail -n 20; journalctl -u k3s --no-pager -n 30"' 2>&1 | cut -c1-240 || true
}
if ! wait_for 1800 '^[0-9]+$' "bootstrap exit status" bootstrap_exit; then
  log "bootstrap did not finish; guest diagnostics:"
  diagnose
fi
log "applied -> bootstrap finished: $(($(date +%s) - T_APPLY))s"
# Let TOE try to connect for a minute so its log has something to report.
sleep 60

# ------------------------------------------------------------------ check.sh
log "running check.sh --phase all --transport virtctl --inner-pod"
set +e
"${KIT}/check.sh" --context "$CTX" --argocd-namespace "$ARGO_NS" --device "$DEVICE" --phase all --transport virtctl --inner-pod | tee "${TMP}/check.out"
set -e

# Expected in this environment: no device-controller DeviceState (D2), the stand-in
# gateway is not EMQX, so TOE cannot complete a TLS/MQTT connection (G12) and never
# comes online (T1).
EXPECTED_FAIL="D2 G12 T1"
MUST_PASS="P1 P2 P3 P4 P5 P6 P7k P8k P7c P8c P9 P10 P11 P14 P15 N1 N2 N4 N5 V0 V2 V3 V4 V5 V6 V7 V8 V9a V10 V12 G1 G3 G4 G5 G6 G6b G7 G8 G9 G10 G11 G14 I1 I2 I3 I4 I5 I6 I7 I8 I9 I10 I11 I12 I13 I14 I15"
for id in $MUST_PASS; do
  grep -qE "^PASS +${id} " "${TMP}/check.out" || flunk "expected PASS for ${id}"
done
# The expected failures must actually fail: they show the checks discriminate.
for id in $EXPECTED_FAIL; do
  grep -qE "^FAIL +${id} " "${TMP}/check.out" || flunk "expected FAIL for ${id} (stand-ins cannot satisfy it)"
done
n_inner=$(grep -cE '^PASS +I([1-9]|1[0-5]) +\[inner pod\]' "${TMP}/check.out" || true)
[[ $n_inner == 15 ]] || flunk "expected 15 passing inner-pod probes, got ${n_inner}"
while read -r id; do
  [[ " $EXPECTED_FAIL " == *" $id "* ]] || flunk "unexpected FAIL ${id}"
done < <(awk '$1=="FAIL"{print $2}' "${TMP}/check.out" | sort -u)
[[ $(grep -cE '^PASS +P15 ' "${TMP}/check.out" || true) == 3 ]] || flunk "expected P15 PASS for virt-api, virt-controller and cdi-apiserver"
grep -qF -- "$PASSWORD" "${TMP}/check.out" && flunk "the device password appeared in check.sh output"
grep -q 'PRIVATE KEY' "${TMP}/check.out" && flunk "a private key appeared in check.sh output"

# ------------------------------------------------------------------ rollback and removal
# 1. virtualDevices.enabled=false: app-of-apps prunes the Application. It has no
#    resources finalizer, so nothing else may go.
log "rollback: deleting the Application (what virtualDevices.enabled=false does)"
k -n "$ARGO_NS" delete application virtual-devices --wait=true --timeout=120s >/dev/null
sleep 30
[[ $(k -n kubevirt get kubevirt kubevirt -o jsonpath='{.status.phase}' 2>/dev/null) == Deployed ]] &&
  k -n kube-system get configmap coredns-custom >/dev/null 2>&1 && k get cdi cdi >/dev/null 2>&1 &&
  pass "flag off: KubeVirt, CDI and coredns-custom stay in place" || flunk "flag off removed part of the runtime"

# 2. The removal order of README "Removing the runtime", step by step.
log "removal: VMs and runtime namespaces"
k -n teknoir-demo-vdev delete vm "$DEVICE" --wait=true --timeout=300s >/dev/null
k delete namespace teknoir-demo-vdev --wait=true --timeout=300s >/dev/null
[[ $(k get vm,vmi,dv -A -o name 2>/dev/null | wc -l) == 0 ]] && pass "no VMs, VMIs or DataVolumes left" || flunk "virtual machines left: $(k get vm,vmi,dv -A -o name | tr '\n' ' ')"
log "removal: KubeVirt CR, then CDI CR, while the operators run"
T_RM=$(date +%s)
k -n kubevirt delete kubevirt kubevirt --wait=true --timeout=600s >/dev/null
k delete cdi cdi --wait=true --timeout=600s >/dev/null
log "CRs removed in $(($(date +%s) - T_RM))s"
# The aggregated (service-backed) APIServices and the webhooks of KubeVirt and CDI must
# be gone before the operators are removed (README step 2 waits for this). They do not
# all go with the CR: the first run of this e2e still saw CDI's upload APIService and
# its webhooks right after 'kubectl delete cdi' returned. The Local APIServices of the
# two CRDs the chart itself ships (kubevirts.kubevirt.io, cdis.cdi.kubevirt.io) stay
# until step 3 deletes those CRDs.
aggregated_apis() { k get apiservices -o json | jq -r '[.items[] | select(.spec.service != null and ((.spec.group // "") | test("kubevirt\\.io$"))) | .metadata.name] | join(",")'; }
operand_webhooks() { k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json | jq -r '[.items[] | select([.webhooks[]?.clientConfig.service.namespace // empty] | any(. == "kubevirt" or . == "cdi")) | .metadata.name] | join(",")'; }
operand_leftovers() {
  local a w
  a=$(aggregated_apis) && w=$(operand_webhooks) || return 1
  [[ -z $a && -z $w ]] && echo gone || echo "apiservices=[${a}] webhooks=[${w}]"
}
first=$(operand_leftovers)
log "right after the CR deletes: ${first}"
if [[ $first != gone ]]; then
  log "owners of what is left: $(k get apiservices -o json | jq -c '[.items[] | select(.spec.service != null and ((.spec.group // "") | test("kubevirt\\.io$"))) | {name: .metadata.name, owners: [.metadata.ownerReferences[]? | "\(.kind)/\(.name)"], deleting: (.metadata.deletionTimestamp != null)}]')"
fi
if wait_for 300 '^gone$' "aggregated APIServices and webhooks of KubeVirt/CDI" operand_leftovers; then
  pass "the aggregated APIServices and webhooks went away by themselves, $(($(date +%s) - T_RM))s after the CR deletes started"
else
  flunk "aggregated APIServices or webhooks still there 300s after deleting the CRs: $(operand_leftovers)"
fi
log "Local APIServices left until step 3: $(k get apiservices -o json | jq -r '[.items[] | select(.spec.service == null and ((.spec.group // "") | test("kubevirt\\.io$"))) | .metadata.name] | join(",")')"
log "left after deleting the CRs (removed with the operators next): $(k get crd -o name | grep -c kubevirt.io || true) CRDs, webhooks: $(k get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -E 'virt|cdi' | tr '\n' ' ')"
log "removal: the rest of the chart (operators, their CRDs and RBAC, PriorityClasses, coredns-custom)"
helm template virtual-devices "${REPO}/charts/virtual-devices" --namespace kubevirt \
  --show-only templates/kubevirt-operator.yaml --show-only templates/cdi-operator.yaml \
  --show-only templates/priorityclass.yaml --show-only templates/coredns-custom.yaml |
  k delete --ignore-not-found --wait=true --timeout=600s -f - >/dev/null
set +e
"${KIT}/check.sh" --context "$CTX" --argocd-namespace "$ARGO_NS" --phase removed | tee "${TMP}/removed.out"
set -e
for id in R1 R2 R3 R3b R4 R5 R6 R7 R8 R8b R9; do
  grep -qE "^PASS +${id} " "${TMP}/removed.out" || flunk "removal: expected PASS for ${id}"
done
grep -qE '^FAIL ' "${TMP}/removed.out" && flunk "removal: check.sh --phase removed reported FAILs"
grep -E '^(INFO|PASS) +R10 ' "${TMP}/removed.out" | sed 's/^/[e2e] node leftovers: /' >&2 || true
log "node extended resources after removal: $(k get nodes -o json | jq -c '[.items[] | {node: .metadata.name,
  capacity: (.status.capacity | with_entries(select(.key | test("kubevirt\\.io")))),
  allocatable: (.status.allocatable | with_entries(select(.key | test("kubevirt\\.io"))))}]')"
REMOVAL_DNS_NOTE=""
# The name has a public A record, so a working lookup answers with an address; an empty
# answer (lookup pod failed) must not count as "rewrite gone".
dns_not_gateway() { local a; a=$(dns_answer); [[ -n $a && $a != "$GW_IP" ]] && echo "not-gateway:${a}"; }
if wait_for 180 '^not-gateway' "CoreDNS stops rewriting mqtt-teknoir-demo.teknoir.cloud (no restart)" dns_not_gateway; then
  REMOVAL_DNS_NOTE="dropped the rewrite without a restart"
  pass "the CoreDNS rewrite is gone after removal"
else
  flunk "CoreDNS still rewrites to the gateway 180s after coredns-custom was deleted"
  REMOVAL_DNS_NOTE="kept the rewrite (needs a restart)"
fi
k api-resources -o name >/dev/null && pass "API discovery works after removal" || flunk "API discovery fails after removal"

log "CoreDNS: ${COREDNS_NOTE}; after removal it ${REMOVAL_DNS_NOTE}"
if ((fail)); then
  log "k3d e2e FAILED"
  exit 1
fi
log "k3d e2e passed"
