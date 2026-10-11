# shellcheck shell=bash
# Pinned inputs of the S1 spike kit. Every value here is a fixed version or digest;
# nothing in the kit floats. Resolved 2026-10-09.
# shellcheck disable=SC2034  # sourced by render.sh and check.sh

# tnctl bootstrap templates: github.com/teknoir/cli main at 7bb1bea
# (pkg/templates/server.sh.tmpl and partials, module path "teknoir/cli").
VDS_CLI_REPO_URL="https://github.com/teknoir/cli.git"
VDS_CLI_REF="7bb1beaa53069ef20cf9edfa300c1d9560429f0a"

# Inner k3s of the device. The tnctl template installs whatever get.k3s.io serves
# (the stable channel, v1.36.5 on 2026-10-09) unless INSTALL_K3S_VERSION is set.
# The spike pins v1.34.11, the last 1.34 patch before k3s "Improve CA hash
# validation" (k3s 6c7a974, in v1.34.12, v1.35.9 and v1.36.5, released 2026-09-30).
# Those releases drop CA certificates without the keyCertSign key usage when they
# validate their own /cacerts, and the tnctl template makes the device certificate
# (Backstage's `openssl req -x509`, no keyUsage) the k3s root CA, so the server never
# becomes ready. See README "Finding: k3s >= 1.34.12 and the tnctl custom CA".
VDS_K3S_VERSION="v1.34.11+k3s1"

# Inner k3s CIDRs. They must not overlap the outer cluster's 10.42/16 (pods) and
# 10.43/16 (services): the guest's resolver is the outer kube-dns 10.43.0.10, which
# an inner kube-proxy on 10.43/16 would capture.
VDS_CLUSTER_CIDR="10.52.0.0/16"
VDS_SERVICE_CIDR="10.53.0.0/16"
VDS_CLUSTER_DNS="10.53.0.10"

# Root disk, default source: the KubeVirt containerdisks image of Debian 13.
# quay.io/containerdisks/debian:13-2610020212 is built from
# debian-13-genericcloud-amd64-20261001-2618.qcow2 (its "shasum" label equals that
# file's SHA512 in cloud.debian.org trixie/20261001-2618/SHA512SUMS). Note: this is
# the genericcloud variant (cloud kernel); S1's k3s check-config settles whether it
# is enough. CDI pulls it by digest with pullMethod: node.
VDS_DISK_CONTAINERDISK_TAG="quay.io/containerdisks/debian:13-2610020212"
VDS_DISK_CONTAINERDISK_DIGEST="sha256:6b992c4a8a62ca57858cbbf60110e673928d27b2885ea2a106660bc26b112b5b"

# Root disk, alternative (--disk generic): the Debian 13 *generic* cloud image of the
# same build, imported by CDI over HTTPS and verified against Debian's SHA512SUMS.
VDS_DISK_GENERIC_URL="https://cloud.debian.org/images/cloud/trixie/20261001-2618/debian-13-generic-amd64-20261001-2618.qcow2"
VDS_DISK_GENERIC_CHECKSUM="sha512:6f0f93335bdef4ccf523c4317cc663ea52ca23b862667785f3d6d186ab4674a937385ccff0c55996b4b2e4c19e440cdf211e2a75ffa2f6548037ab43950c841d"

# Probe image for the optional inner-pod isolation probes (pulled inside the guest).
VDS_PROBE_IMAGE="docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"

# Expected KubeVirt / CDI versions (charts/virtual-devices/vendor/upstream.lock.yaml).
VDS_KUBEVIRT_VERSION="v1.8.4"
VDS_CDI_VERSION="v1.65.0"
