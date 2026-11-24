#!/usr/bin/env bash
# Install kubeconform v0.7.0 into a bin directory (the kubeconform and scripts-tests jobs of
# .github/workflows/ci.yml; the download is checked against its sha256 before it is extracted).
#
#   scripts/ci/install-kubeconform.sh BIN_DIR
#
# When $GITHUB_PATH is set (GitHub Actions) BIN_DIR is appended to it, so later steps find the binary.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
BIN=$1
URL=https://github.com/yannh/kubeconform/releases/download/v0.7.0/kubeconform-linux-amd64.tar.gz
SHA256=c31518ddd122663b3f3aa874cfe8178cb0988de944f29c74a0b9260920d115d3

mkdir -p "$BIN"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/kubeconform.tar.gz"
echo "$SHA256  $tmp/kubeconform.tar.gz" | sha256sum -c -
tar -xz -f "$tmp/kubeconform.tar.gz" -C "$BIN" kubeconform
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$BIN" >>"$GITHUB_PATH"
fi
