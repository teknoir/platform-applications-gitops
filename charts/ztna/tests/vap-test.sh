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
BACKSTAGE=system:serviceaccount:teknoir-system:backstage
as() { local u=$1; shift; "${KC[@]}" --as "$u" --as-group system:authenticated "$@"; }

"${KC[@]}" create namespace teknoir-ztna >/dev/null
"${KC[@]}" create namespace stunner-system >/dev/null
"${KC[@]}" create namespace other >/dev/null

# The chart's admission objects only (no image needed for these templates).
helm template ztna "${CHART}" --namespace teknoir-ztna --set hub.image.tag=sha-test -s templates/admission.yaml > "${TMP}/admission.yaml"
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

# --- other namespaces are not touched by the policy
cm ztna-policy-ts.dev9 ztna.teknoir.org/policy > "${TMP}/policy-other.yaml"
if as "${BACKSTAGE}" create -n other -f "${TMP}/policy-other.yaml" >/dev/null 2>&1; then ok "allowed: the same ConfigMap in another namespace is not affected"; else bad "policy leaked into namespace 'other'"; fi

# --- exec / attach / port-forward / ephemeral containers
"${KC[@]}" apply -n teknoir-ztna -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  containers: [{name: c, image: example.invalid/x}]
YAML
"${KC[@]}" apply -n stunner-system -f - >/dev/null <<'YAML'
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

# --- namespace teardown: DELETE of a policy ConfigMap by anyone while the namespace is Terminating
as "${DC}" create -n teknoir-ztna -f "${TMP}/policy.yaml" >/dev/null
if as "${BACKSTAGE}" delete configmap ztna-policy-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then bad "pre-teardown delete should be denied"; else ok "denied: delete before teardown"; fi
"${KC[@]}" delete namespace teknoir-ztna --wait=false >/dev/null
sleep 2
phase=$("${KC[@]}" get namespace teknoir-ztna -o jsonpath='{.status.phase}')
if [[ $phase == Terminating ]]; then ok "namespace is Terminating (no namespace controller here, as in a stuck teardown)"; else bad "namespace phase $phase"; fi
if as system:serviceaccount:kube-system:namespace-controller delete configmap ztna-policy-ts.dev1 -n teknoir-ztna >/dev/null 2>&1; then ok "allowed: DELETE of a policy ConfigMap while the namespace is Terminating"; else bad "teardown delete denied"; fi

echo
if [[ $fail -ne 0 ]]; then echo "VAP tests FAILED"; exit 1; fi
echo "VAP tests passed"
