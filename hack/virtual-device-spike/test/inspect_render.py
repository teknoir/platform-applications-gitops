#!/usr/bin/env python3
"""Assertions on a render.sh output directory (used by test/run.sh).

Usage: python3 -I inspect_render.py OUT_DIR KEY_PEM PASSWORD MODE

MODE is "containerdisk" or "generic". Prints ok/FAIL lines; exits 1 on failure.
KEY_PEM and PASSWORD are the throwaway test credentials put into the fixture; the
checks confirm they reach the cloud-init Secret and nothing else.
"""
import base64
import os
import re
import stat
import sys

import yaml

out, key_path, password, mode = sys.argv[1:5]
failures = []


def check(cond, msg):
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)


key = open(key_path).read().strip()
key_body = "".join(l for l in key.splitlines() if "-----" not in l)
key_marker = key_body[40:100]  # a slice of the key body, distinctive enough to grep

# ---- files and modes
files = sorted(os.listdir(out))
check(files == ["00-namespace.yaml", "10-cloudinit-secret.yaml", "20-vm.yaml", "summary.txt"], f"output files {files}")
check(stat.S_IMODE(os.stat(out).st_mode) == 0o700, "output directory mode 0700")
for f in files:
    m = stat.S_IMODE(os.stat(os.path.join(out, f)).st_mode)
    check(m & 0o077 == 0, f"{f} mode {oct(m)} has no group/other bits")

# ---- secrets only in the Secret
for f in ("00-namespace.yaml", "20-vm.yaml", "summary.txt"):
    text = open(os.path.join(out, f)).read()
    check(key_marker not in text and password not in text and "PRIVATE KEY" not in text, f"{f} carries no credential")

docs = {}
for f in ("00-namespace.yaml", "10-cloudinit-secret.yaml", "20-vm.yaml"):
    docs[f] = [d for d in yaml.safe_load_all(open(os.path.join(out, f))) if d]

# ---- namespace
ns_docs = {(d["kind"], d["metadata"]["name"]) for d in docs["00-namespace.yaml"]}
for want in [("Namespace", "teknoir-demo-vdev"), ("NetworkPolicy", "vdev-default-deny"), ("NetworkPolicy", "vdev-egress-dns"),
             ("NetworkPolicy", "vdev-egress-gateway"), ("ResourceQuota", "vdev-quota"), ("LimitRange", "vdev-limits")]:
    check(want in ns_docs, f"00-namespace.yaml has {want[0]}/{want[1]}")
ns = next(d for d in docs["00-namespace.yaml"] if d["kind"] == "Namespace")
check(ns["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] == "baseline", "namespace enforces PSA baseline")
check(ns["metadata"]["labels"].get("istio-injection") == "disabled", "namespace has istio-injection=disabled")
deny = next(d for d in docs["00-namespace.yaml"] if d["metadata"]["name"] == "vdev-default-deny")
check(deny["spec"] == {"podSelector": {}, "policyTypes": ["Ingress", "Egress"]}, "default deny selects all pods, both directions, no rules")
for d in docs["00-namespace.yaml"]:
    if d["kind"] == "NetworkPolicy":
        check("ingress" not in d["spec"], f"{d['metadata']['name']} allows no ingress")
gw = next(d for d in docs["00-namespace.yaml"] if d["metadata"]["name"] == "vdev-egress-gateway")
check(gw["spec"]["egress"][0]["to"][0]["podSelector"]["matchLabels"] == {"istio": "ingressgateway-public"}, "gateway egress selects istio=ingressgateway-public pods")
check(sorted(p["port"] for p in gw["spec"]["egress"][0]["ports"]) == [2222, 8084, 8883], "gateway egress ports 2222/8084/8883 only")
inet = [d for d in docs["00-namespace.yaml"] if d["metadata"]["name"] == "vdev-egress-internet"]
if inet:
    exc = set(inet[0]["spec"]["egress"][0]["to"][0]["ipBlock"]["except"])
    for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8"):
        check(cidr in exc, f"internet egress excludes {cidr}")
quota = next(d for d in docs["00-namespace.yaml"] if d["kind"] == "ResourceQuota")["spec"]["hard"]
check(quota["count/virtualmachines.kubevirt.io"] == "2" and quota["services"] == "0", "quota caps VMs and forbids Services")
check(quota["requests.memory"] == "10Gi" and quota["requests.storage"] == "88Gi", "quota has KubeVirt/CDI headroom (2 x (4Gi+1Gi), 2 x 2 x 1.1 x 20Gi)")

# ---- Secret and cloud-init
sec = docs["10-cloudinit-secret.yaml"][0]
check(sec["kind"] == "Secret" and sec["metadata"]["name"] == "vd-s1-fixture-cloudinit" and sec["metadata"]["namespace"] == "teknoir-demo-vdev", "Secret vd-s1-fixture-cloudinit in teknoir-demo-vdev")
check(list(sec["data"]) == ["userdata"], "Secret has only key userdata")
ud_text = base64.b64decode(sec["data"]["userdata"]).decode()
check(ud_text.startswith("#cloud-config\n"), "userdata is a #cloud-config")
ud = yaml.safe_load(ud_text)
check(ud["ssh_pwauth"] is False and ud["disable_root"] is True, "cloud-config: no SSH passwords, no root login")
check("qemu-guest-agent" in ud["packages"], "cloud-config installs qemu-guest-agent")
wf = {w["path"]: w for w in ud["write_files"]}
boot = wf["/usr/local/lib/teknoir/bootstrap.sh"]
check(boot["permissions"] == "0700" and boot["owner"] == "root:root" and boot["encoding"] == "b64", "bootstrap.sh is root-only 0700")
script = base64.b64decode(boot["content"]).decode()
check(script.startswith("#!/bin/sh\n"), "bootstrap is the tnctl server script (#!/bin/sh)")
check('_DEVICE_ID="vd-s1-fixture"' in script and '_NAMESPACE="teknoir-demo"' in script and '_DOMAIN="teknoir.cloud"' in script, "bootstrap carries device id, teamspace and domain")
check(key in script, "bootstrap embeds the device private key from the Device")
check(f'_FIRST_USER_PASS="{password}"' in script, "bootstrap embeds the device user's password from the Device")
check(re.search(r'^_K3S_TOKEN="[0-9a-f]{32}"$', script, re.M) is not None, "bootstrap has a 128-bit hex k3s token")
check('export INSTALL_K3S_EXEC="server --token ${_K3S_TOKEN}' in script, "bootstrap appends the caller's INSTALL_K3S_EXEC")
check("{{" not in script, "no unrendered template markers")
run = wf["/usr/local/lib/teknoir/spike-run.sh"]["content"]
check("CREATE_USER=true" in run, "spike-run sets CREATE_USER=true")
check("INSTALL_K3S_VERSION='v1.34.12+k3s1'" in run, "spike-run pins INSTALL_K3S_VERSION")
check("INSTALL_K3S_EXEC='--cluster-cidr=10.52.0.0/16 --service-cidr=10.53.0.0/16 --cluster-dns=10.53.0.10'" in run, "spike-run sets inner CIDRs 10.52/10.53 and cluster DNS 10.53.0.10")
check(ud["runcmd"][-1] == ["/usr/local/lib/teknoir/spike-run.sh"], "runcmd ends with spike-run.sh")
env = wf["/etc/teknoir-spike/spike.env"]["content"]
check(key_marker not in env and password not in env, "spike.env carries no credential")

# ---- VM
vm = docs["20-vm.yaml"][0]
check(vm["kind"] == "VirtualMachine" and vm["metadata"]["namespace"] == "teknoir-demo-vdev", "VirtualMachine in teknoir-demo-vdev")
t = vm["spec"]["template"]
dvt = vm["spec"]["dataVolumeTemplates"][0]
check(dvt["metadata"]["name"] == "vd-s1-fixture-root", "root DataVolume vd-s1-fixture-root")
st = dvt["spec"]["storage"]
check(st["storageClassName"] == "local-path" and st["accessModes"] == ["ReadWriteOnce"] and st["volumeMode"] == "Filesystem", "root disk on local-path, RWO, Filesystem")
src = dvt["spec"]["source"]
if mode == "containerdisk":
    check(re.fullmatch(r"docker://quay\.io/containerdisks/debian@sha256:[0-9a-f]{64}", src["registry"]["url"]) is not None, "root disk from the Debian 13 containerdisk by digest")
    check(src["registry"]["pullMethod"] == "node", "CDI pullMethod node")
else:
    check(src["http"]["url"].endswith("/debian-13-generic-amd64-20261001-2618.qcow2"), "root disk from the Debian 13 generic qcow2")
    check(re.fullmatch(r"sha512:[0-9a-f]{128}", src["http"]["checksum"]) is not None, "generic qcow2 verified by SHA512")
spec = t["spec"]
check(t["metadata"]["annotations"]["sidecar.istio.io/inject"] == "false", "no Istio sidecar")
check(spec["priorityClassName"] == "teknoir-virtual-device", "priorityClassName teknoir-virtual-device")
check(spec["evictionStrategy"] == "None", "evictionStrategy None")
dom = spec["domain"]
check(dom["cpu"]["cores"] == 2 and dom["resources"]["limits"]["cpu"] == "2" and dom["resources"]["requests"]["cpu"] == "1000m", "2 vCPU, cpu request 1 (overcommit 2), limit 2")
check(dom["resources"]["requests"]["memory"] == dom["resources"]["limits"]["memory"] == "4Gi", "4Gi memory, request = limit")
check(dom["devices"]["logSerialConsole"] is False, "serial console not logged")
check(dom["devices"]["interfaces"] == [{"name": "default", "masquerade": {}}], "masquerade networking")
vols = {v["name"]: v for v in spec["volumes"]}
check(vols["cloudinit"]["cloudInitNoCloud"] == {"secretRef": {"name": "vd-s1-fixture-cloudinit"}}, "cloud-init user data from the Secret (cloudInitNoCloud.secretRef)")
check(vols["root"]["dataVolume"]["name"] == "vd-s1-fixture-root", "root volume is the DataVolume")

if failures:
    print(f"\n{len(failures)} render assertion(s) failed")
    sys.exit(1)
print("\nall render assertions passed")
