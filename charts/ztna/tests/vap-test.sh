#!/usr/bin/env bash
# Behavioural test of the ValidatingAdmissionPolicies of charts/ztna (templates/admission.yaml)
# against a THROWAWAY local kube-apiserver + etcd (the envtest binaries, `setup-envtest use 1.30.0`).
# It never touches a cluster: the apiserver listens on 127.0.0.1 and is deleted on exit; kubectl
# is given an explicit kubeconfig. Needs: helm, kubectl, openssl, and envtest binaries
# (ENVTEST_DIR, default ~/.local/share/kubebuilder-envtest/k8s/1.30.0-linux-amd64).
#
#   charts/ztna/tests/vap-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "${HERE}/.." && pwd)"
ENVTEST_DIR="${ENVTEST_DIR:-$HOME/.local/share/kubebuilder-envtest/k8s/1.30.0-linux-amd64}"
for b in etcd kube-apiserver kubectl; do
  [[ -x "${ENVTEST_DIR}/${b}" ]] || { echo "SKIP: ${ENVTEST_DIR}/${b} not found (setup-envtest use 1.30.0)"; exit 0; }
done
for t in helm openssl; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done

TMP=$(mktemp -d)
PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]:-}"; do wait "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

free_port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
ETCD_PORT=${ETCD_PORT:-$(free_port)}; ETCD_PEER=${ETCD_PEER:-$(free_port)}; API_PORT=${API_PORT:-$(free_port)}
KUBECTL="${ENVTEST_DIR}/kubectl"
fail=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

openssl genrsa -out "${TMP}/sa.key" 2048 2>/dev/null
openssl rsa -in "${TMP}/sa.key" -pubout -out "${TMP}/sa.pub" 2>/dev/null
echo "testtoken,admin,uid-admin,\"system:masters\"" > "${TMP}/tokens.csv"

"${ENVTEST_DIR}/etcd" --data-dir "${TMP}/etcd" --listen-client-urls "http://127.0.0.1:${ETCD_PORT}" \
  --advertise-client-urls "http://127.0.0.1:${ETCD_PORT}" --listen-peer-urls "http://127.0.0.1:${ETCD_PEER}" \
  >"${TMP}/etcd.log" 2>&1 &
PIDS+=($!)
"${ENVTEST_DIR}/kube-apiserver" --etcd-servers "http://127.0.0.1:${ETCD_PORT}" \
  --secure-port "${API_PORT}" --bind-address 127.0.0.1 --cert-dir "${TMP}/certs" \
  --token-auth-file "${TMP}/tokens.csv" --authorization-mode=AlwaysAllow --service-cluster-ip-range 10.0.0.0/24 \
  --service-account-issuer https://localhost --service-account-key-file "${TMP}/sa.pub" \
  --service-account-signing-key-file "${TMP}/sa.key" --disable-admission-plugins ServiceAccount \
  >"${TMP}/apiserver.log" 2>&1 &
PIDS+=($!)

KC=("${KUBECTL}" --server "https://127.0.0.1:${API_PORT}" --token testtoken --insecure-skip-tls-verify)
for _ in $(seq 1 60); do "${KC[@]}" get --raw /readyz >/dev/null 2>&1 && break; sleep 1; done
"${KC[@]}" get --raw /readyz >/dev/null 2>&1 || { echo "apiserver did not come up"; tail -20 "${TMP}/apiserver.log"; exit 1; }

HUB=system:serviceaccount:teknoir-ztna:wg-hub
DC=system:serviceaccount:teknoir-system:device-controller-service-account
FLAGS=system:serviceaccount:teknoir-ztna:wg-flags
BACKSTAGE=system:serviceaccount:teknoir-system:backstage
# Backstage's real service account (cluster-wide teknoir-admin): the one a compromised UI uses.
BACKSTAGE_API=system:serviceaccount:teknoir-system:backstage-api
ARGO=system:serviceaccount:teknoir-system:argocd-application-controller
STUNNER_OP=system:serviceaccount:stunner-system:stunner-gateway-operator-controller-manager
RS_CTRL=system:serviceaccount:kube-system:replicaset-controller
JOB_CTRL=system:serviceaccount:kube-system:job-controller
KUBELET=system:node:node1
as() { local u=$1; shift; "${KC[@]}" --as "$u" --as-group system:authenticated "$@"; }

"${KC[@]}" create namespace teknoir-ztna >/dev/null
"${KC[@]}" create namespace stunner-system >/dev/null
"${KC[@]}" create namespace other >/dev/null

# The chart's admission objects only (no image needed for these templates).
helm template ztna "${CHART}" --namespace teknoir-ztna --set hub.image.tag=sha-test --set hub.image.leaderElection=true -s templates/admission.yaml > "${TMP}/admission.yaml"
"${KC[@]}" apply -f "${TMP}/admission.yaml" >/dev/null
# Admission policies are cached by the apiserver for a moment.
for _ in $(seq 1 30); do
  as "${BACKSTAGE}" create configmap probe-"${RANDOM}" -n teknoir-ztna --dry-run=server -o name >/dev/null 2>&1 && break
  sleep 1
done
sleep 3

cm() { # name label(optional key=value) -> manifest
  local name=$1 label=${2:-}
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n' "$name"
  [[ -n $label ]] && printf '  labels:\n    %s: "true"\n' "$label"
  printf 'data:\n  k: v\n'
}
allowed() { # description user manifest-file verb
  local d=$1 u=$2 f=$3 v=${4:-create}
  if out=$(as "$u" "$v" -n teknoir-ztna -f "$f" 2>&1); then ok "allowed: $d"; else bad "should be allowed: $d: $out"; fi
}
denied() {
  local d=$1 u=$2 f=$3 v=${4:-create}
  if out=$(as "$u" "$v" -n teknoir-ztna -f "$f" 2>&1); then bad "should be denied: $d"; else
    if grep -q "ValidatingAdmissionPolicy" <<<"$out"; then ok "denied: $d"; else bad "denied, but not by the policy: $d: $out"; fi
  fi
}

# --- policy ConfigMaps
cm ztna-policy-ts.dev1 ztna.teknoir.org/policy > "${TMP}/policy.yaml"
cm ztna-policy-ts.dev2 > "${TMP}/policy-nolabel.yaml"
cm innocent-name ztna.teknoir.org/policy > "${TMP}/policy-labelonly.yaml"
denied "backstage creates a labelled policy ConfigMap" "${BACKSTAGE}" "${TMP}/policy.yaml"
denied "cluster admin creates a labelled policy ConfigMap" admin "${TMP}/policy.yaml"
denied "hub creates a policy ConfigMap" "${HUB}" "${TMP}/policy.yaml"
denied "backstage creates ztna-policy-* without the label" "${BACKSTAGE}" "${TMP}/policy-nolabel.yaml"
denied "backstage creates a policy-labelled ConfigMap with another name" "${BACKSTAGE}" "${TMP}/policy-labelonly.yaml"
allowed "device-controller creates a policy ConfigMap" "${DC}" "${TMP}/policy.yaml"
allowed "device-controller creates ztna-policy-* without the label" "${DC}" "${TMP}/policy-nolabel.yaml"
cm ztna-policy-ts.dev1 ztna.teknoir.org/policy > "${TMP}/policy-update.yaml"
sed -i 's/k: v/k: changed/' "${TMP}/policy-update.yaml"
allowed "device-controller updates its policy ConfigMap" "${DC}" "${TMP}/policy-update.yaml" apply
sed 's/k: changed/k: tampered/' "${TMP}/policy-update.yaml" > "${TMP}/policy-tamper.yaml"
denied "backstage updates a policy ConfigMap" "${BACKSTAGE}" "${TMP}/policy-tamper.yaml" apply
# Relabelling to evade: the old object still carries the label.
cm ztna-policy-ts.dev1 > "${TMP}/policy-stripped.yaml"
denied "backstage strips the label from a policy ConfigMap" "${BACKSTAGE}" "${TMP}/policy-stripped.yaml" replace
if out=$(as "${BACKSTAGE}" delete configmap ztna-policy-ts.dev1 -n teknoir-ztna 2>&1); then bad "should be denied: backstage deletes a policy ConfigMap"; else ok "denied: backstage deletes a policy ConfigMap"; fi
if out=$(as "${DC}" delete configmap ztna-policy-ts.dev1 -n teknoir-ztna 2>&1); then ok "allowed: device-controller deletes its policy ConfigMap"; else bad "device-controller delete: $out"; fi

# --- generateName (no name on CREATE) must not make the CEL fail open or closed incorrectly
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  generateName: gen-\ndata:\n  k: v\n' > "${TMP}/gen.yaml"
allowed "backstage creates an unrelated ConfigMap by generateName" "${BACKSTAGE}" "${TMP}/gen.yaml"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  generateName: ztna-policy-\ndata:\n  k: v\n' > "${TMP}/gen-policy.yaml"
denied "backstage creates ztna-policy-* by generateName without a name" "${BACKSTAGE}" "${TMP}/gen-policy.yaml"

# --- identity ConfigMaps
cm ztna-identity-ts.dev1 ztna.teknoir.org/identity > "${TMP}/identity.yaml"
denied "device-controller creates an identity ConfigMap" "${DC}" "${TMP}/identity.yaml"
denied "backstage creates an identity ConfigMap" "${BACKSTAGE}" "${TMP}/identity.yaml"
allowed "hub creates an identity ConfigMap" "${HUB}" "${TMP}/identity.yaml"
sed -i 's/k: v/k: pinned/' "${TMP}/identity.yaml"
allowed "hub updates its identity ConfigMap" "${HUB}" "${TMP}/identity.yaml" apply
sed 's/k: pinned/k: tampered/' "${TMP}/identity.yaml" > "${TMP}/identity-tamper.yaml"
denied "device-controller updates an identity ConfigMap" "${DC}" "${TMP}/identity-tamper.yaml" apply

# --- the hub writes nothing else
cm other-config > "${TMP}/other.yaml"
denied "hub creates an unrelated ConfigMap" "${HUB}" "${TMP}/other.yaml"
allowed "device-controller creates an unrelated ConfigMap" "${DC}" "${TMP}/other.yaml"
allowed "backstage creates an unrelated ConfigMap" "${BACKSTAGE}" "${TMP}/gen.yaml"

# --- flags ConfigMaps (written by the flags watcher only)
cm ztna-flags-ts.dev1 ztna.teknoir.org/flags > "${TMP}/flags.yaml"
cm ztna-flags-ts.dev2 > "${TMP}/flags-nolabel.yaml"
cm innocent-flags ztna.teknoir.org/flags > "${TMP}/flags-labelonly.yaml"
denied "hub creates a flags ConfigMap" "${HUB}" "${TMP}/flags.yaml"
denied "device-controller creates a flags ConfigMap" "${DC}" "${TMP}/flags.yaml"
denied "backstage creates a flags ConfigMap" "${BACKSTAGE}" "${TMP}/flags.yaml"
denied "backstage-api creates ztna-flags-* without the label" "${BACKSTAGE_API}" "${TMP}/flags-nolabel.yaml"
denied "backstage creates a flags-labelled ConfigMap with another name" "${BACKSTAGE}" "${TMP}/flags-labelonly.yaml"
denied "cluster admin creates a flags ConfigMap" admin "${TMP}/flags.yaml"
allowed "wg-flags creates a flags ConfigMap" "${FLAGS}" "${TMP}/flags.yaml"
sed 's/k: v/k: changed/' "${TMP}/flags.yaml" > "${TMP}/flags-update.yaml"
allowed "wg-flags updates its flags ConfigMap" "${FLAGS}" "${TMP}/flags-update.yaml" apply
sed 's/k: changed/k: tampered/' "${TMP}/flags-update.yaml" > "${TMP}/flags-tamper.yaml"
denied "hub updates a flags ConfigMap" "${HUB}" "${TMP}/flags-tamper.yaml" apply
denied "backstage updates a flags ConfigMap" "${BACKSTAGE}" "${TMP}/flags-tamper.yaml" apply
cm ztna-flags-ts.dev1 > "${TMP}/flags-stripped.yaml"
denied "backstage strips the label from a flags ConfigMap" "${BACKSTAGE}" "${TMP}/flags-stripped.yaml" replace
if as "${BACKSTAGE}" delete configmap ztna-flags-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then bad "should be denied: backstage deletes a flags ConfigMap"; else ok "denied: backstage deletes a flags ConfigMap"; fi
denied "wg-flags creates a policy ConfigMap" "${FLAGS}" "${TMP}/policy.yaml"
denied "wg-flags creates an identity ConfigMap" "${FLAGS}" "${TMP}/identity.yaml"
denied "wg-flags creates an unrelated ConfigMap" "${FLAGS}" "${TMP}/other.yaml"
if as "${FLAGS}" delete configmap ztna-flags-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then ok "allowed: wg-flags deletes its flags ConfigMap"; else bad "wg-flags delete denied"; fi

# --- org ConfigMaps (ztna-org-<teamspace>, the org-gate data): the flags watcher only
cm ztna-org-x ztna.teknoir.org/org > "${TMP}/org.yaml"
cm ztna-org-y > "${TMP}/org-nolabel.yaml"
cm innocent-org ztna.teknoir.org/org > "${TMP}/org-labelonly.yaml"
allowed "wg-flags creates ztna-org-x" "${FLAGS}" "${TMP}/org.yaml"
sed 's/k: v/k: changed/' "${TMP}/org.yaml" > "${TMP}/org-update.yaml"
allowed "wg-flags updates ztna-org-x" "${FLAGS}" "${TMP}/org-update.yaml" apply
allowed "wg-flags creates ztna-org-* without the label" "${FLAGS}" "${TMP}/org-nolabel.yaml"
denied "device-controller creates ztna-org-x" "${DC}" "${TMP}/org.yaml"
denied "backstage-api creates ztna-org-x" "${BACKSTAGE_API}" "${TMP}/org.yaml"
denied "hub creates ztna-org-x" "${HUB}" "${TMP}/org.yaml"
denied "cluster admin creates ztna-org-x" admin "${TMP}/org.yaml"
denied "backstage creates ztna-org-* without the label" "${BACKSTAGE}" "${TMP}/org-nolabel.yaml"
denied "backstage creates an org-labelled ConfigMap with another name" "${BACKSTAGE}" "${TMP}/org-labelonly.yaml"
sed 's/k: changed/k: tampered/' "${TMP}/org-update.yaml" > "${TMP}/org-tamper.yaml"
denied "device-controller updates ztna-org-x" "${DC}" "${TMP}/org-tamper.yaml" apply
denied "backstage-api updates ztna-org-x" "${BACKSTAGE_API}" "${TMP}/org-tamper.yaml" apply
cm ztna-org-x > "${TMP}/org-stripped.yaml"
denied "backstage-api strips the label from ztna-org-x" "${BACKSTAGE_API}" "${TMP}/org-stripped.yaml" replace
if out=$(as "${DC}" delete configmap ztna-org-x -n teknoir-ztna 2>&1); then bad "should be denied: device-controller deletes ztna-org-x"; elif grep -q "ValidatingAdmissionPolicy" <<<"$out"; then ok "denied: device-controller deletes ztna-org-x"; else bad "denied, but not by the policy: device-controller deletes ztna-org-x: $out"; fi
cm other-name ztna.teknoir.org/org > "${TMP}/org-othername.yaml"
allowed "wg-flags (the label owner) creates an org-labelled ConfigMap named other-name" "${FLAGS}" "${TMP}/org-othername.yaml"
denied "device-controller updates an org-labelled ConfigMap named other-name" "${DC}" "${TMP}/org-othername.yaml" apply
if as "${FLAGS}" delete configmap ztna-org-x -n teknoir-ztna >/dev/null 2>&1; then ok "allowed: wg-flags deletes ztna-org-x"; else bad "wg-flags delete of ztna-org-x denied"; fi

# --- pods and workloads (only ArgoCD, device-controller, the stunner operator, kube-system)
wl() { # kind name -> manifest
  case $1 in
    pod) printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: %s}\nspec:\n  containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    deployment) printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: %s}\nspec:\n  selector: {matchLabels: {a: b}}\n  template:\n    metadata: {labels: {a: b}}\n    spec:\n      containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    replicaset) printf 'apiVersion: apps/v1\nkind: ReplicaSet\nmetadata: {name: %s}\nspec:\n  selector: {matchLabels: {a: b}}\n  template:\n    metadata: {labels: {a: b}}\n    spec:\n      containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    statefulset) printf 'apiVersion: apps/v1\nkind: StatefulSet\nmetadata: {name: %s}\nspec:\n  serviceName: x\n  selector: {matchLabels: {a: b}}\n  template:\n    metadata: {labels: {a: b}}\n    spec:\n      containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    daemonset) printf 'apiVersion: apps/v1\nkind: DaemonSet\nmetadata: {name: %s}\nspec:\n  selector: {matchLabels: {a: b}}\n  template:\n    metadata: {labels: {a: b}}\n    spec:\n      containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    job) printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: %s}\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
    cronjob) printf 'apiVersion: batch/v1\nkind: CronJob\nmetadata: {name: %s}\nspec:\n  schedule: "0 0 * * *"\n  jobTemplate:\n    spec:\n      template:\n        spec:\n          restartPolicy: Never\n          containers: [{name: c, image: example.invalid/x}]\n' "$2" ;;
  esac
}
for kind in pod deployment replicaset statefulset daemonset job cronjob; do
  wl $kind rogue > "${TMP}/wl-$kind.yaml"
  for who in "${BACKSTAGE_API}" "${BACKSTAGE}" "${HUB}" "${FLAGS}" admin; do
    denied "$who creates a $kind in teknoir-ztna" "$who" "${TMP}/wl-$kind.yaml"
  done
  if out=$(as "${BACKSTAGE_API}" create -n stunner-system -f "${TMP}/wl-$kind.yaml" 2>&1); then bad "should be denied: backstage-api creates a $kind in stunner-system"; else
    grep -q "ValidatingAdmissionPolicy 'ztna-workloads'" <<<"$out" && ok "denied: backstage-api creates a $kind in stunner-system" || bad "denied, but not by the policy: $kind in stunner-system: $out"; fi
  if as "${BACKSTAGE_API}" create -n other -f "${TMP}/wl-$kind.yaml" >/dev/null 2>&1; then ok "allowed: backstage-api creates a $kind in an unrelated namespace"; else bad "workload policy leaked into namespace 'other' ($kind)"; fi
  allowed "ArgoCD creates a $kind" "${ARGO}" "${TMP}/wl-$kind.yaml"
  wl $kind dc-made > "${TMP}/wl-$kind-dc.yaml"
  allowed "device-controller creates a $kind" "${DC}" "${TMP}/wl-$kind-dc.yaml"
done
wl pod by-rs > "${TMP}/wl-pod-rs.yaml"; allowed "the replicaset controller creates a pod" "${RS_CTRL}" "${TMP}/wl-pod-rs.yaml"
wl pod by-job > "${TMP}/wl-pod-job.yaml"; allowed "the job controller creates a pod" "${JOB_CTRL}" "${TMP}/wl-pod-job.yaml"
wl pod by-kcm > "${TMP}/wl-pod-kcm.yaml"; allowed "kube-controller-manager creates a pod" system:kube-controller-manager "${TMP}/wl-pod-kcm.yaml"
if as "${STUNNER_OP}" create -n stunner-system -f "${TMP}/wl-deployment-dc.yaml" >/dev/null 2>&1; then ok "allowed: the stunner operator creates a Deployment in stunner-system"; else bad "stunner operator denied"; fi
# changing the image of a running pod, or of the hub Deployment, is the other route
sed 's#example.invalid/x#example.invalid/evil#' "${TMP}/wl-pod-rs.yaml" > "${TMP}/wl-pod-rs-evil.yaml"
denied "backstage-api replaces the image of a pod" "${BACKSTAGE_API}" "${TMP}/wl-pod-rs-evil.yaml" replace
sed 's#example.invalid/x#example.invalid/evil#' "${TMP}/wl-deployment-dc.yaml" > "${TMP}/wl-deployment-evil.yaml"
denied "backstage-api patches the image of a Deployment" "${BACKSTAGE_API}" "${TMP}/wl-deployment-evil.yaml" apply
if out=$(as "${BACKSTAGE_API}" patch deployment dc-made -n teknoir-ztna --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"example.invalid/evil"}]' 2>&1); then bad "should be denied: backstage-api json-patches a Deployment"; else grep -q "ValidatingAdmissionPolicy" <<<"$out" && ok "denied: backstage-api json-patches a Deployment" || bad "patch denied, but not by the policy: $out"; fi
allowed "ArgoCD updates the Deployment" "${ARGO}" "${TMP}/wl-deployment-evil.yaml" apply

# --- the hub's role marker: wg-hub may UPDATE a hub pod's role label and deletion cost, nothing else
hubpod() { # namespace name component -> manifest (a hub pod as the Deployment makes it, plus an extra label and annotation)
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/name: wg-hub\n    app.kubernetes.io/component: %s\n    ztna.teknoir.org/hub-role: standby\n    extra: x\n  annotations:\n    controller.kubernetes.io/pod-deletion-cost: "0"\n    sidecar.istio.io/status: "{}"\nspec:\n  containers: [{name: c, image: example.invalid/x}]\n' "$2" "$1" "$3"
}
hubpod teknoir-ztna hubpod hub > "${TMP}/hubpod.yaml"
hubpod teknoir-ztna pullpod pull-secret > "${TMP}/pullpod.yaml"
hubpod stunner-system lookalike hub > "${TMP}/lookalike.yaml"
for f in hubpod pullpod lookalike; do as "${ARGO}" apply -f "${TMP}/$f.yaml" >/dev/null; done
as "${ARGO}" apply -n teknoir-ztna -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: plainpod}
spec:
  containers: [{name: c, image: example.invalid/x}]
YAML
RESET='{"metadata":{"labels":{"ztna.teknoir.org/hub-role":"standby"},"annotations":{"controller.kubernetes.io/pod-deletion-cost":"0"}}}'
pverdict() { # description want(allow|deny) user namespace pod patch [type]
  local d=$1 want=$2 u=$3 ns=$4 pod=$5 patch=$6 ty=${7:-merge} out got
  out=$(as "$u" patch pod "$pod" -n "$ns" --type "$ty" -p "$patch" 2>&1) && got=allow || {
    grep -q "ValidatingAdmissionPolicy 'ztna-workloads'" <<<"$out" && got=deny || got="other: $out"; }
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got ${out:0:300}"; fi
  as "${ARGO}" patch pod "$pod" -n "$ns" --type merge -p "$RESET" >/dev/null 2>&1 || true
}
ROLE='ztna.teknoir.org/hub-role'; COST='controller.kubernetes.io/pod-deletion-cost'
pverdict "the hub labels its pod leader and sets the deletion cost 100" allow "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"},\"annotations\":{\"$COST\":\"100\"}}}"
pverdict "the hub labels its pod standby (the exact body of its patch)" allow "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"standby\"},\"annotations\":{\"$COST\":\"0\"}}}"
pverdict "the hub changes only the role label" allow "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}}}"
pverdict "the hub changes only the deletion cost" allow "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"annotations\":{\"$COST\":\"100\"}}}"
pverdict "the hub sets another role value" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"admin\"}}}"
pverdict "the hub sets another deletion cost" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"annotations\":{\"$COST\":\"-1000\"}}}"
pverdict "the hub removes the role label" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":null}}}"
pverdict "the hub adds a label" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\",\"added\":\"y\"}}}"
pverdict "the hub changes another label" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"labels":{"extra":"changed"}}}'
pverdict "the hub removes another label" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"labels":{"extra":null}}}'
pverdict "the hub moves its pod out of the hub selector (component)" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"labels":{"app.kubernetes.io/component":"other"}}}'
pverdict "the hub adds an annotation" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"annotations\":{\"$COST\":\"100\",\"added\":\"y\"}}}"
pverdict "the hub changes another annotation" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"annotations":{"sidecar.istio.io/status":"changed"}}}'
pverdict "the hub removes another annotation" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"annotations":{"sidecar.istio.io/status":null}}}'
pverdict "the hub changes the image of its pod" deny "${HUB}" teknoir-ztna hubpod '{"spec":{"containers":[{"name":"c","image":"example.invalid/evil"}]}}' strategic
pverdict "the hub changes the image together with its role" deny "${HUB}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}},\"spec\":{\"containers\":[{\"name\":\"c\",\"image\":\"example.invalid/evil\"}]}}" strategic
pverdict "the hub adds an owner reference" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"ownerReferences":[{"apiVersion":"apps/v1","kind":"ReplicaSet","name":"x","uid":"11111111-1111-1111-1111-111111111111"}]}}'
pverdict "the hub adds a finalizer" deny "${HUB}" teknoir-ztna hubpod '{"metadata":{"finalizers":["example.com/hold"]}}'
pverdict "the hub labels a pull secret pod (component pull-secret)" deny "${HUB}" teknoir-ztna pullpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}}}"
pverdict "the hub labels a pod without the hub labels" deny "${HUB}" teknoir-ztna plainpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}}}"
pverdict "the hub labels a lookalike hub pod in stunner-system" deny "${HUB}" stunner-system lookalike "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}}}"
for who in "${BACKSTAGE_API}" "${BACKSTAGE}" "${FLAGS}" admin; do
  pverdict "$who labels a hub pod leader" deny "$who" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"$ROLE\":\"leader\"}}}"
  pverdict "$who sets the deletion cost of a hub pod" deny "$who" teknoir-ztna hubpod "{\"metadata\":{\"annotations\":{\"$COST\":\"100\"}}}"
done
pverdict "device-controller keeps its right to patch a pod" allow "${DC}" teknoir-ztna hubpod "{\"metadata\":{\"labels\":{\"extra\":\"dc\"}}}"
as "${ARGO}" patch pod hubpod -n teknoir-ztna --type merge -p '{"metadata":{"labels":{"extra":"x"}}}' >/dev/null
# the hub still creates no pod and no workload (the carve-out is UPDATE of a hub pod)
hubpod teknoir-ztna hubpod-new hub > "${TMP}/hubpod-new.yaml"
denied "the hub creates a hub-labelled pod" "${HUB}" "${TMP}/hubpod-new.yaml"
as "${ARGO}" patch pod hubpod -n teknoir-ztna --type merge -p "{\"metadata\":{\"labels\":{\"$ROLE\":\"standby\"}}}" >/dev/null

# --- TokenRequest for the ZTNA service accounts
for sa in wg-hub wg-flags wgt-0123456789 plain-sa; do "${KC[@]}" create serviceaccount "$sa" -n teknoir-ztna >/dev/null 2>&1 || true; done
tok() { # description user sa want(deny|pass)
  local d=$1 u=$2 sa=$3 want=$4 out got
  out=$(as "$u" create token "$sa" -n teknoir-ztna 2>&1 || true)
  if grep -q "ValidatingAdmissionPolicy 'ztna-no-token-mint'" <<<"$out"; then got=deny; elif grep -qi "forbidden\|denied" <<<"$out"; then got="other: $out"; else got=pass; fi
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got"; fi
}
for sa in wg-hub wg-flags wgt-0123456789; do
  tok "backstage-api mints a token for $sa" "${BACKSTAGE_API}" $sa deny
  tok "cluster admin mints a token for $sa" admin $sa deny
  tok "device-controller mints a token for $sa" "${DC}" $sa deny
  tok "the hub mints a token for $sa" "${HUB}" $sa deny
  tok "the kubelet mints a token for $sa" "${KUBELET}" $sa pass
  tok "a kube-system controller mints a token for $sa" "${RS_CTRL}" $sa pass
done
tok "backstage-api mints a token for an unrelated service account" "${BACKSTAGE_API}" plain-sa pass

# --- the leader Lease of the hub (hub.leaderElection.lease, wg-hub): written by the hub only
lease() { # name holder -> manifest
  printf 'apiVersion: coordination.k8s.io/v1\nkind: Lease\nmetadata: {name: %s}\nspec:\n  holderIdentity: %s\n  leaseDurationSeconds: 60\n' "$1" "$2"
}
lease wg-hub intruder > "${TMP}/lease-intruder.yaml"
lease wg-hub hub-0 > "${TMP}/lease-hub.yaml"
lease wg-hub hub-1 > "${TMP}/lease-hub1.yaml"
lease other-lease x > "${TMP}/lease-other.yaml"
for who in "${BACKSTAGE_API}" "${BACKSTAGE}" "${DC}" "${FLAGS}" admin; do
  denied "$who creates the leader Lease" "$who" "${TMP}/lease-intruder.yaml"
done
allowed "the hub creates the leader Lease" "${HUB}" "${TMP}/lease-hub.yaml"
allowed "the hub takes the leader Lease over (update)" "${HUB}" "${TMP}/lease-hub1.yaml" apply
for who in "${BACKSTAGE_API}" "${BACKSTAGE}" "${DC}" "${FLAGS}" admin; do
  denied "$who steals the leader Lease (update)" "$who" "${TMP}/lease-intruder.yaml" apply
  denied "$who deletes the leader Lease" "$who" "${TMP}/lease-hub1.yaml" delete
done
out=$(as "${BACKSTAGE_API}" patch lease wg-hub -n teknoir-ztna --type merge -p '{"spec":{"holderIdentity":"intruder"}}' 2>&1 || true)
if grep -q "ValidatingAdmissionPolicy 'ztna-hub-lease'" <<<"$out"; then ok "denied: backstage-api patches the leader Lease"; else bad "backstage-api patched the leader Lease: $out"; fi
denied "the hub creates another Lease" "${HUB}" "${TMP}/lease-other.yaml"
allowed "backstage-api creates an unrelated Lease (not matched)" "${BACKSTAGE_API}" "${TMP}/lease-other.yaml"
denied "the hub updates a Lease that is not its own" "${HUB}" "${TMP}/lease-other.yaml" apply
if as "${BACKSTAGE_API}" create -n other -f "${TMP}/lease-intruder.yaml" >/dev/null 2>&1; then ok "allowed: a Lease of the same name in another namespace is not affected"; else bad "lease policy leaked into namespace 'other'"; fi

# --- other namespaces are not touched by the policy
cm ztna-policy-ts.dev9 ztna.teknoir.org/policy > "${TMP}/policy-other.yaml"
if as "${BACKSTAGE}" create -n other -f "${TMP}/policy-other.yaml" >/dev/null 2>&1; then ok "allowed: the same ConfigMap in another namespace is not affected"; else bad "policy leaked into namespace 'other'"; fi

# --- exec / attach / port-forward / ephemeral containers
as "${ARGO}" apply -n teknoir-ztna -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  containers: [{name: c, image: example.invalid/x}]
YAML
as "${ARGO}" apply -n stunner-system -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  containers: [{name: c, image: example.invalid/x}]
YAML
"${KC[@]}" apply -n other -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  containers: [{name: c, image: example.invalid/x}]
YAML
# Pods cannot run without a kubelet: the CONNECT request is admitted (or refused) before the
# apiserver looks for a node, so a refusal by the policy is distinguishable from "pod not scheduled".
check_connect() { # description namespace resource expect(deny|pass)
  local d=$1 ns=$2 sub=$3 want=$4 out
  out=$("${KC[@]}" get --raw "/api/v1/namespaces/${ns}/pods/victim/${sub}?command=id&stdout=true&container=c" 2>&1 || true)
  if grep -q "ValidatingAdmissionPolicy 'ztna-no-exec'" <<<"$out"; then got=deny; else got=pass; fi
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got: $out"; fi
}
check_connect "exec in teknoir-ztna, even for cluster admin" teknoir-ztna exec deny
check_connect "exec in stunner-system" stunner-system exec deny
check_connect "attach in teknoir-ztna" teknoir-ztna attach deny
check_connect "portforward in teknoir-ztna" teknoir-ztna portforward deny
check_connect "exec in an unrelated namespace" other exec pass

# --- Device annotations (ztna.teknoir.org/*): Backstage backend, device-controller, system:masters only
"${KC[@]}" apply -f "${CHART}/../device-controller/crds/devices.yaml" >/dev/null
"${KC[@]}" wait --for=condition=Established crd/devices.teknoir.org --timeout=30s >/dev/null
"${KC[@]}" create namespace devns >/dev/null
EDITOR_SA=system:serviceaccount:devns:default-editor
dev() { # name [annotations as key=value ...] -> manifest
  local name=$1; shift
  printf 'apiVersion: teknoir.org/v1\nkind: Device\nmetadata:\n  name: %s\n' "$name"
  if [[ $# -gt 0 ]]; then printf '  annotations:\n'; for kv in "$@"; do printf '    %s: "%s"\n' "${kv%%=*}" "${kv#*=}"; done; fi
  printf 'spec:\n  keys: {}\n  manifest: {}\n'
}
dverdict() { # description want(allow|deny) user verb manifest
  local d=$1 want=$2 u=$3 v=$4 f=$5 out got
  out=$(as "$u" "$v" -n devns -f "$f" 2>&1) && got=allow || { grep -q "ValidatingAdmissionPolicy 'ztna-device-annotations'" <<<"$out" && got=deny || got="other: $out"; }
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got"; fi
}
Z=ztna.teknoir.org
dev dev1 "$Z/wireguard=enabled" other.io/x=1 > "${TMP}/d-base.yaml"
dverdict "editor creates a Device with a ztna annotation" deny "${EDITOR_SA}" create "${TMP}/d-base.yaml"
dev dev0 other.io/x=1 > "${TMP}/d-plain.yaml"
dverdict "editor creates a Device without ztna annotations" allow "${EDITOR_SA}" create "${TMP}/d-plain.yaml"
dverdict "backstage-api creates a Device with a ztna annotation" allow "${BACKSTAGE_API}" create "${TMP}/d-base.yaml"
dev dev2 "$Z/wireguard=enabled" > "${TMP}/d-dc.yaml"
dverdict "device-controller creates a Device with a ztna annotation" allow "${DC}" create "${TMP}/d-dc.yaml"
dev dev3 "$Z/wireguard=enabled" > "${TMP}/d-m.yaml"
if "${KC[@]}" create -n devns -f "${TMP}/d-m.yaml" >/dev/null 2>&1; then ok "allowed: system:masters creates a Device with a ztna annotation"; else bad "system:masters denied"; fi
# UPDATE: modify, add, remove
dev dev1 "$Z/wireguard=enabled" "$Z/compromised=true" other.io/x=1 > "${TMP}/d-add.yaml"
dverdict "editor adds ztna/compromised" deny "${EDITOR_SA}" replace "${TMP}/d-add.yaml"
dev dev1 "$Z/wireguard=disabled" other.io/x=1 > "${TMP}/d-mod.yaml"
dverdict "editor modifies ztna/wireguard" deny "${EDITOR_SA}" replace "${TMP}/d-mod.yaml"
dev dev1 other.io/x=1 > "${TMP}/d-rm.yaml"
dverdict "editor removes ztna/wireguard" deny "${EDITOR_SA}" replace "${TMP}/d-rm.yaml"
dverdict "backstage-api sets ztna/compromised" allow "${BACKSTAGE_API}" replace "${TMP}/d-add.yaml"
dev dev1 "$Z/wireguard=enabled" "$Z/compromised=true" "$Z/trusted-host-key=SHA256:abc" other.io/x=1 > "${TMP}/d-dcset.yaml"
dverdict "device-controller adds a ztna annotation" allow "${DC}" replace "${TMP}/d-dcset.yaml"
dev dev1 "$Z/wireguard=enabled" "$Z/compromised=true" "$Z/trusted-host-key=SHA256:abc" other.io/x=2 other.io/y=3 > "${TMP}/d-other.yaml"
dverdict "editor changes other annotations only (ztna ones kept)" allow "${EDITOR_SA}" replace "${TMP}/d-other.yaml"
dev dev1 "$Z/wireguard=enabled" "$Z/compromised=true" "$Z/trusted-host-key=SHA256:abc" > "${TMP}/d-dropother.yaml"
dverdict "editor removes a non-ztna annotation" allow "${EDITOR_SA}" replace "${TMP}/d-dropother.yaml"
dev dev1 > "${TMP}/d-none.yaml"
dverdict "editor strips every annotation of a Device that has ztna ones" deny "${EDITOR_SA}" replace "${TMP}/d-none.yaml"
if "${KC[@]}" replace -n devns -f "${TMP}/d-none.yaml" >/dev/null 2>&1; then ok "allowed: system:masters removes the ztna annotations"; else bad "system:masters replace denied"; fi
dverdict "editor adds a ztna annotation to a Device with no annotations" deny "${EDITOR_SA}" replace "${TMP}/d-mod.yaml"
# DELETE is not matched
"${KC[@]}" apply -n devns -f "${TMP}/d-base.yaml" >/dev/null 2>&1 || true
if as "${EDITOR_SA}" delete device dev1 -n devns >/dev/null 2>&1; then ok "allowed: editor deletes a Device carrying ztna annotations"; else bad "DELETE of a Device was denied"; fi
# status subresource is not matched (the controller writes status; annotations cannot change there)
"${KC[@]}" apply -n devns -f "${TMP}/d-base.yaml" >/dev/null 2>&1 || true
if as "${EDITOR_SA}" patch device dev1 -n devns --subresource=status --type=merge -p '{"status":{"x":1}}' 2>&1 | grep -q "ztna-device-annotations"; then bad "status update was denied by the annotation policy"; else ok "status subresource is not subject to the annotation policy"; fi

# --- Device org-tree placement (teknoir.org/org-tree-path, org-tree-node-id): same principals
OT=teknoir.org/org-tree-path; ON=teknoir.org/org-tree-node-id
dev odev other.io/x=1 > "${TMP}/o-base.yaml"
"${KC[@]}" create -n devns -f "${TMP}/o-base.yaml" >/dev/null
dev odev "$OT=se/a" "$ON=a" other.io/x=1 > "${TMP}/o-placed.yaml"
dverdict "editor sets org-tree-path/node-id on a Device" deny "${EDITOR_SA}" replace "${TMP}/o-placed.yaml"
dev odev "$OT=se/a" other.io/x=1 > "${TMP}/o-pathonly.yaml"
dverdict "editor sets only org-tree-path" deny "${EDITOR_SA}" replace "${TMP}/o-pathonly.yaml"
dev odev "$ON=a" other.io/x=1 > "${TMP}/o-nodeonly.yaml"
dverdict "editor sets only org-tree-node-id" deny "${EDITOR_SA}" replace "${TMP}/o-nodeonly.yaml"
dev odev-new "$OT=se/a" "$ON=a" > "${TMP}/o-create.yaml"
dverdict "editor creates a Device with org-tree-path/node-id" deny "${EDITOR_SA}" create "${TMP}/o-create.yaml"
dverdict "backstage-api creates a Device with org-tree-path/node-id" allow "${BACKSTAGE_API}" create "${TMP}/o-create.yaml"
dverdict "backstage-api sets org-tree-path/node-id" allow "${BACKSTAGE_API}" replace "${TMP}/o-placed.yaml"
dev odev "$OT=se/b" "$ON=a" other.io/x=1 > "${TMP}/o-moved.yaml"
dverdict "editor changes org-tree-path" deny "${EDITOR_SA}" replace "${TMP}/o-moved.yaml"
dev odev other.io/x=1 > "${TMP}/o-removed.yaml"
dverdict "editor removes org-tree-path/node-id" deny "${EDITOR_SA}" replace "${TMP}/o-removed.yaml"
dverdict "device-controller moves a Device in the org tree" allow "${DC}" replace "${TMP}/o-moved.yaml"
dev odev "$OT=se/b" "$ON=a" other.io/x=2 other.io/y=3 > "${TMP}/o-unrelated.yaml"
dverdict "editor changes unrelated annotations, org-tree kept" allow "${EDITOR_SA}" replace "${TMP}/o-unrelated.yaml"
if "${KC[@]}" replace -n devns -f "${TMP}/o-removed.yaml" >/dev/null 2>&1; then ok "allowed: system:masters removes the org-tree placement"; else bad "system:masters org-tree removal denied"; fi

# --- User org annotations (org-tree-member-*, org-tree-units-*): Backstage backend, ArgoCD, user-controller, system:masters
"${KC[@]}" apply -f "${CHART}/../user-controller/crds/crds.yaml" >/dev/null
"${KC[@]}" wait --for=condition=Established crd/users.teknoir.org --timeout=30s >/dev/null
USER_CTRL=system:serviceaccount:teknoir-system:user-controller
usr() { # name [annotations key=value ...] -> manifest
  local name=$1; shift
  printf 'apiVersion: teknoir.org/v1\nkind: User\nmetadata:\n  name: %s\n' "$name"
  if [[ $# -gt 0 ]]; then printf '  annotations:\n'; for kv in "$@"; do printf '    %s: '"'"'%s'"'"'\n' "${kv%%=*}" "${kv#*=}"; done; fi
  printf 'spec:\n  email: %s@example.com\n' "$name"
}
uverdict() { # description want(allow|deny) user verb manifest
  local d=$1 want=$2 u=$3 v=$4 f=$5 out got
  out=$(as "$u" "$v" -f "$f" 2>&1) && got=allow || { grep -q "ValidatingAdmissionPolicy 'ztna-user-org-annotations'" <<<"$out" && got=deny || got="other: $out"; }
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got"; fi
}
UM=teknoir.org/org-tree-member-ts; UU=teknoir.org/org-tree-units-ts
usr u1 other.io/x=1 > "${TMP}/u-base.yaml"
uverdict "editor creates a User without org annotations" allow "${EDITOR_SA}" create "${TMP}/u-base.yaml"
usr u1 "$UM=true" "$UU=[\"a\"]" other.io/x=1 > "${TMP}/u-org.yaml"
uverdict "editor adds org-tree annotations to a User" deny "${EDITOR_SA}" replace "${TMP}/u-org.yaml"
usr u2 "$UM=true" "$UU=[\"a\"]" > "${TMP}/u-new.yaml"
uverdict "editor creates a User with org-tree annotations" deny "${EDITOR_SA}" create "${TMP}/u-new.yaml"
uverdict "backstage-api creates a User with org-tree annotations" allow "${BACKSTAGE_API}" create "${TMP}/u-new.yaml"
uverdict "backstage-api sets org-tree annotations" allow "${BACKSTAGE_API}" replace "${TMP}/u-org.yaml"
usr u1 "$UM=true" "$UU=[\"a\",\"b\"]" other.io/x=1 > "${TMP}/u-widen.yaml"
uverdict "editor widens org-tree-units" deny "${EDITOR_SA}" replace "${TMP}/u-widen.yaml"
uverdict "device-controller widens org-tree-units" deny "${DC}" replace "${TMP}/u-widen.yaml"
uverdict "ArgoCD widens org-tree-units" allow "${ARGO}" replace "${TMP}/u-widen.yaml"
usr u1 other.io/x=1 > "${TMP}/u-strip.yaml"
uverdict "editor removes org-tree annotations" deny "${EDITOR_SA}" replace "${TMP}/u-strip.yaml"
usr u1 "$UM=true" "$UU=[\"a\",\"b\"]" other.io/x=2 other.io/y=3 > "${TMP}/u-unrelated.yaml"
uverdict "editor changes unrelated User annotations, org-tree kept" allow "${EDITOR_SA}" replace "${TMP}/u-unrelated.yaml"
uverdict "user-controller rewrites a User, org-tree kept" allow "${USER_CTRL}" replace "${TMP}/u-unrelated.yaml"
if "${KC[@]}" replace -f "${TMP}/u-strip.yaml" >/dev/null 2>&1; then ok "allowed: system:masters removes the org-tree annotations"; else bad "system:masters User replace denied"; fi
if as "${EDITOR_SA}" delete user u2 >/dev/null 2>&1; then ok "allowed: DELETE of a User is not matched"; else bad "DELETE of a User was denied"; fi

# --- Backstage identities: the Backstage service account cannot name itself (or a group) as a User or Profile owner,
# which profile-controller / user-controller would turn into teknoir-admin. Everyone else is unaffected.
"${KC[@]}" apply -f "${CHART}/../profile-controller/crds/crd.yaml" >/dev/null
"${KC[@]}" wait --for=condition=Established crd/profiles.teknoir.org --timeout=30s >/dev/null
iverdict() { # description want(allow|deny) user verb manifest
  local d=$1 want=$2 u=$3 v=$4 f=$5 out got
  out=$(as "$u" "$v" -f "$f" 2>&1) && got=allow || { grep -q "ValidatingAdmissionPolicy 'ztna-backstage-identities'" <<<"$out" && got=deny || got="other: $out"; }
  if [[ $got == "$want" ]]; then ok "$d ($want)"; else bad "$d: want $want, got $got"; fi
}
uemail() { printf 'apiVersion: teknoir.org/v1\nkind: User\nmetadata:\n  name: %s\nspec:\n  email: %s\n' "$1" "$2"; }
for bad_email in "system:serviceaccount:teknoir-system:backstage-api" "System:Serviceaccount:x:y" "system:masters" "kubernetes-admin"; do
  uemail ib1 "$bad_email" > "${TMP}/i-user.yaml"
  iverdict "backstage-api creates a User with email '${bad_email}'" deny "${BACKSTAGE_API}" create "${TMP}/i-user.yaml"
done
uemail ib1 "system:serviceaccount:teknoir-system:backstage-api" > "${TMP}/i-user-bad.yaml"
uemail ib2 "someone@example.com" > "${TMP}/i-user-ok.yaml"
iverdict "backstage-api creates a User with an e-mail address" allow "${BACKSTAGE_API}" create "${TMP}/i-user-ok.yaml"
# Control characters and YAML syntax: user-controller renders its RoleBinding from an unescaped text template, so a
# line break in an e-mail could add a second `name:` key (the last wins) and still contain an '@'. Manifests are
# built with JSON quoting (valid YAML) so the odd characters reach the policy intact.
jq_str() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
uemail_q() { printf 'apiVersion: teknoir.org/v1\nkind: User\nmetadata:\n  name: %s\nspec:\n  email: %s\n' "$1" "$(jq_str "$2")"; }
INJ=$'a@example.org\n  name: system:serviceaccount:teknoir-system:backstage-api'
uemail_q ibq1 "${INJ}" > "${TMP}/i-user-inj.yaml"
iverdict "backstage-api creates a User whose e-mail carries a line break and a second name: key" deny "${BACKSTAGE_API}" create "${TMP}/i-user-inj.yaml"
for bad_email in $'a@example.org\n' $'a\r@example.org' 'a b@example.org' 'a"b@example.org' "a'b@example.org" 'a:b@example.org' 'a@example.org #x' 'a@b:c@example.org' '@example.org' 'a@'; do
  uemail_q ibq2 "${bad_email}" > "${TMP}/i-user-q.yaml"
  iverdict "backstage-api creates a User with e-mail $(jq_str "${bad_email}")" deny "${BACKSTAGE_API}" create "${TMP}/i-user-q.yaml"
done
uemail_q ibq3 'First.Last+tag@Example.org' > "${TMP}/i-user-q-ok.yaml"
iverdict "backstage-api creates a User with a mixed-case e-mail with + and ." allow "${BACKSTAGE_API}" create "${TMP}/i-user-q-ok.yaml"
uemail_q ibq4 "${INJ}" > "${TMP}/i-user-inj2.yaml"
iverdict "an editor (not Backstage) is not matched by the identities policy" allow "${EDITOR_SA}" create "${TMP}/i-user-inj2.yaml"
printf 'apiVersion: teknoir.org/v1\nkind: User\nmetadata:\n  name: ib2\nspec:\n  email: system:serviceaccount:teknoir-system:backstage-api\n' > "${TMP}/i-user-change.yaml"
iverdict "backstage-api changes a User's email to a service account name" deny "${BACKSTAGE_API}" replace "${TMP}/i-user-change.yaml"
iverdict "an editor (not Backstage) creates a User without an '@'" allow "${EDITOR_SA}" create "${TMP}/i-user-bad.yaml"
iverdict "ArgoCD (not Backstage) replaces a User without an '@'" allow "${ARGO}" replace "${TMP}/i-user-bad.yaml"
prof() { # name kind owner-name [namespace] -> manifest
  printf 'apiVersion: teknoir.org/v1\nkind: Profile\nmetadata:\n  name: %s\nspec:\n  owner:\n    kind: %s\n    name: %s\n' "$1" "$2" "$3"
  [[ -n ${4:-} ]] && printf '    namespace: %s\n' "$4"
  return 0
}
prof ibp1 User "owner@example.com" > "${TMP}/i-prof-ok.yaml"
iverdict "backstage-api creates a Profile owned by an e-mail User" allow "${BACKSTAGE_API}" create "${TMP}/i-prof-ok.yaml"
prof ibp2 ServiceAccount backstage-api teknoir-system > "${TMP}/i-prof-sa.yaml"
iverdict "backstage-api creates a Profile owned by a ServiceAccount" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-sa.yaml"
prof ibp3 Group "system:serviceaccounts:teknoir-system" > "${TMP}/i-prof-group.yaml"
iverdict "backstage-api creates a Profile owned by a Group" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-group.yaml"
prof ibp4 User "system:serviceaccount:teknoir-system:backstage-api" > "${TMP}/i-prof-user-sa.yaml"
iverdict "backstage-api creates a Profile owned by a User named like the service account" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-user-sa.yaml"
prof ibp5 User "admin" > "${TMP}/i-prof-noat.yaml"
iverdict "backstage-api creates a Profile owned by a User without an '@'" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-noat.yaml"
printf 'apiVersion: teknoir.org/v1\nkind: Profile\nmetadata:\n  name: ibp6\nspec:\n  owner:\n    kind: User\n    name: %s\n' "$(jq_str "${INJ}")" > "${TMP}/i-prof-inj.yaml"
iverdict "backstage-api creates a Profile whose owner carries a line break and a second name: key" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-inj.yaml"
printf 'apiVersion: teknoir.org/v1\nkind: Profile\nmetadata:\n  name: ibp7\nspec:\n  owner:\n    kind: User\n    name: %s\n' "$(jq_str 'a b@example.org')" > "${TMP}/i-prof-space.yaml"
iverdict "backstage-api creates a Profile whose owner has a space" deny "${BACKSTAGE_API}" create "${TMP}/i-prof-space.yaml"
printf 'apiVersion: teknoir.org/v1\nkind: Profile\nmetadata:\n  name: ibp1\nspec:\n  owner:\n    kind: Group\n    name: system:serviceaccounts\n' > "${TMP}/i-prof-change.yaml"
iverdict "backstage-api changes a Profile owner to a Group" deny "${BACKSTAGE_API}" replace "${TMP}/i-prof-change.yaml"
iverdict "an editor (not Backstage) creates a Profile owned by a Group" allow "${EDITOR_SA}" create "${TMP}/i-prof-group.yaml"
if "${KC[@]}" create -f "${TMP}/i-prof-sa.yaml" >/dev/null 2>&1; then ok "allowed: system:masters creates a Profile owned by a ServiceAccount"; else bad "system:masters Profile create denied"; fi

# --- namespace teardown: DELETE of a policy ConfigMap by anyone while the namespace is Terminating
as "${DC}" create -n teknoir-ztna -f "${TMP}/policy.yaml" >/dev/null
if as "${BACKSTAGE}" delete configmap ztna-policy-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then bad "pre-teardown delete should be denied"; else ok "denied: delete before teardown"; fi
if as "${BACKSTAGE_API}" delete lease wg-hub -n teknoir-ztna >/dev/null 2>&1; then bad "pre-teardown lease delete should be denied"; else ok "denied: lease delete before teardown"; fi
"${KC[@]}" delete namespace teknoir-ztna --wait=false >/dev/null
sleep 2
phase=$("${KC[@]}" get namespace teknoir-ztna -o jsonpath='{.status.phase}')
if [[ $phase == Terminating ]]; then ok "namespace is Terminating (no namespace controller here, as in a stuck teardown)"; else bad "namespace phase $phase"; fi
if as system:serviceaccount:kube-system:namespace-controller delete configmap ztna-policy-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then ok "allowed: DELETE of a policy ConfigMap while the namespace is Terminating"; else bad "teardown delete denied"; fi
if as system:serviceaccount:kube-system:namespace-controller delete lease wg-hub -n teknoir-ztna >/dev/null 2>&1; then ok "allowed: DELETE of the leader Lease while the namespace is Terminating"; else bad "teardown lease delete denied"; fi

echo
if [[ $fail -ne 0 ]]; then echo "VAP tests FAILED"; exit 1; fi
echo "VAP tests passed"
