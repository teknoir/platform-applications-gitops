# shellcheck shell=bash source-path=SCRIPTDIR
# Shared helpers for render.sh and check.sh.

VDS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the sourcing scripts
VDS_DIR="$(cd "${VDS_LIB_DIR}/.." && pwd)"
# shellcheck source=pins.sh
. "${VDS_LIB_DIR}/pins.sh"

# Never trace: the scripts handle private keys and passwords in variables and files.
set +x

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"; done
}

# DNS-1123 label check (device and namespace names become object names).
is_dns_label() { [[ $1 =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 63 ]]; }

# kc: kubectl restricted to read-only verbs, always with an explicit --context.
# Every kubectl call against a live cluster in this kit goes through kc.
kc() {
  [[ -n ${KUBE_CONTEXT:-} ]] || die "kc: KUBE_CONTEXT is not set"
  # The verb is the first argument that is not a namespace flag.
  local i=1 verb="" next=""
  while ((i <= $#)); do
    case "${!i}" in
      -n | --namespace) i=$((i + 2)) ;;
      --namespace=* | -A | --all-namespaces) i=$((i + 1)) ;;
      -*) die "kc: unexpected flag '${!i}' before the kubectl verb" ;;
      *)
        verb=${!i}
        i=$((i + 1))
        next=${!i:-}
        break
        ;;
    esac
  done
  case "$verb" in
    get | describe | logs | version | api-resources | api-versions | explain) ;;
    auth) [[ $next == can-i ]] || die "kc: only 'auth can-i' is allowed" ;;
    *) die "kc: kubectl verb '${verb}' is not read-only; refusing" ;;
  esac
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

# make_private_dir [path]: create (or accept an empty) directory with mode 0700.
make_private_dir() {
  local d=${1:-}
  umask 077
  if [[ -z $d ]]; then
    d=$(mktemp -d "${TMPDIR:-/tmp}/vd-spike.XXXXXXXX")
  elif [[ -e $d ]]; then
    [[ -d $d ]] || die "$d exists and is not a directory"
    [[ -z $(ls -A "$d") ]] || die "$d is not empty; refusing to mix secret files with existing content"
    [[ -O $d ]] || die "$d is not owned by you"
  else
    mkdir -p "$d"
  fi
  chmod 700 "$d"
  printf '%s\n' "$d"
}

# mode_of FILE: octal permission bits (GNU stat, falls back to BSD stat).
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# sha256 of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

b64_oneline() { base64 | tr -d '\n'; }

# Device JSON accessors (input on stdin).
device_key_b64() { jq -r --arg k "$1" '.spec.keys.data[$k] // ""'; }

# k3s_prunes_noncertsign_roots VERSION: true for k3s releases that ignore CA certs
# without keyCertSign when validating /cacerts (k3s 6c7a974 "Improve CA hash
# validation": v1.34.12+, v1.35.9+, v1.36.5+ and any later minor).
k3s_prunes_noncertsign_roots() {
  local minor patch
  [[ $1 =~ ^v1\.([0-9]+)\.([0-9]+)\+k3s[0-9]+$ ]] || return 0
  minor=${BASH_REMATCH[1]}
  patch=${BASH_REMATCH[2]}
  ((minor >= 37)) && return 0
  ((minor == 36 && patch >= 5)) && return 0
  ((minor == 35 && patch >= 9)) && return 0
  ((minor == 34 && patch >= 12)) && return 0
  return 1
}

# build_renderer: build renderer/ (vdev-spike-render) inside the pinned cli commit and
# print the path of the binary; cached by commit and source hash. Uses CLI_SRC (a local
# clone containing VDS_CLI_REF) if set, else ~/git/ai/cli, else a fresh clone.
resolve_cli_src() {
  local c
  for c in "${CLI_SRC:-}" "${HOME}/git/ai/cli"; do
    [[ -n $c && -d $c ]] || continue
    if git -C "$c" cat-file -e "${VDS_CLI_REF}^{commit}" 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
    [[ $c == "${CLI_SRC:-}" ]] && die "--cli-src $c does not contain commit ${VDS_CLI_REF}"
  done
  return 1
}

build_renderer() {
  need go git tar
  local main="${VDS_DIR}/renderer/main.go" tmpl="${VDS_DIR}/renderer/userdata.tmpl"
  local key
  key="$(printf '%s %s %s' "$VDS_CLI_REF" "$(sha256_of "$main")" "$(sha256_of "$tmpl")" | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-16)"
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
  cp "$main" "$tmpl" "${build}/mod/cmd/vdev-spike-render/"
  mkdir -p "$cache"
  (cd "${build}/mod" && GOWORK=off GOFLAGS=-mod=mod CGO_ENABLED=0 go build -trimpath -o "${cache}/vdev-spike-render" ./cmd/vdev-spike-render) >&2 ||
    die "building the renderer failed"
  rm -rf "$build"
  printf '%s\n' "${cache}/vdev-spike-render"
}

# Probe result printing for check.sh.
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
INFO_COUNT=0
result() { # result PASS|FAIL|WARN|INFO|SKIP id message
  local status=$1 id=$2
  shift 2
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
    INFO | SKIP) INFO_COUNT=$((INFO_COUNT + 1)) ;;
  esac
  printf '%-4s %-5s %s\n' "$status" "$id" "$*"
}
