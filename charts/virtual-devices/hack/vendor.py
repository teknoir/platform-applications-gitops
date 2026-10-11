#!/usr/bin/env python3
"""Vendor and pin the KubeVirt and CDI operator manifests for charts/virtual-devices.

Run with `python3 -I` from anywhere; paths are resolved relative to this file.

  verify            Offline. Checks vendor/SHA256SUMS and that every image in the
                    vendored manifests is pinned to the digest in upstream.lock.yaml.
  rebuild [--check] Downloads each upstream release asset into a fresh temporary
                    directory, verifies its sha256 against upstream.lock.yaml, applies
                    the pinning transform and writes vendor/<output> and
                    vendor/SHA256SUMS. With --check nothing is written; the command
                    fails if the result differs from what is committed.
  resolve           Re-resolves every image digest with `crane digest` and rewrites
                    the digests in upstream.lock.yaml (use when bumping a version).

The transform is textual so the vendored files stay diffable against upstream:
the only changes are the image references and, for KubeVirt, the operand image
overrides. Nothing is fetched at deploy time.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.dirname(HERE)
VENDOR = os.path.join(CHART, "vendor")
LOCK = os.path.join(VENDOR, "upstream.lock.yaml")
SUMS = os.path.join(VENDOR, "SHA256SUMS")

# virt-operator reads operand images from these variables (pkg/virt-operator/util/config.go).
# virt-template-* are only deployed behind an opt-in property and are not set.
KUBEVIRT_OPERAND_ENV = [
    ("VIRT_API_IMAGE", "virt-api"),
    ("VIRT_CONTROLLER_IMAGE", "virt-controller"),
    ("VIRT_HANDLER_IMAGE", "virt-handler"),
    ("VIRT_LAUNCHER_IMAGE", "virt-launcher"),
    ("VIRT_EXPORTPROXY_IMAGE", "virt-exportproxy"),
    ("VIRT_EXPORTSERVER_IMAGE", "virt-exportserver"),
    ("VIRT_SYNCHRONIZATIONCONTROLLER_IMAGE", "virt-synchronization-controller"),
    ("GS_IMAGE", "libguestfs-tools"),
    ("PR_HELPER_IMAGE", "pr-helper"),
    ("SIDECAR_SHIM_IMAGE", "sidecar-shim"),
]

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
PINNED_RE = re.compile(r"^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")


def die(msg):
    print(f"vendor.py: {msg}", file=sys.stderr)
    sys.exit(1)


def load_lock():
    with open(LOCK) as f:
        lock = yaml.safe_load(f)
    for key in ("kubevirt", "cdi"):
        entry = lock[key]
        for field in ("version", "source", "sha256", "output", "registry", "images"):
            if field not in entry:
                die(f"{key}.{field} missing in {LOCK}")
        for name, digest in entry["images"].items():
            if not DIGEST_RE.match(digest):
                die(f"{key}.images.{name} is not a sha256 digest: {digest}")
    return lock


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def replace_once(text, old, new, what):
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one occurrence of {what}, found {count}")
    return text.replace(old, new)


def header(entry, changes):
    lines = [
        "# Vendored by charts/virtual-devices/hack/vendor.py. Do not edit by hand.",
        f"# Source: {entry['source']}",
        f"# Upstream sha256: {entry['sha256']}",
        "# Changes from upstream (nothing else differs):",
    ]
    lines += [f"#   - {c}" for c in changes]
    return "\n".join(lines) + "\n"


def transform_kubevirt(text, entry):
    reg, ver, imgs = entry["registry"], entry["version"], entry["images"]

    def pin(name):
        return f"{reg}/{name}:{ver}@{imgs[name]}"

    text = replace_once(
        text,
        f"        image: {reg}/virt-operator:{ver}\n",
        f"        image: {pin('virt-operator')}\n",
        "the virt-operator container image",
    )
    # virt-operator parses VIRT_OPERATOR_IMAGE with ^(.*)/(.*)virt-operator([@:].*)?$ and
    # uses the remainder as the version of every operand. ':<tag>@sha256:...' would
    # become an invalid version label, so this one value is pinned by digest only;
    # KUBEVIRT_VERSION keeps carrying the tag.
    text = replace_once(
        text,
        f"        - name: VIRT_OPERATOR_IMAGE\n          value: {reg}/virt-operator:{ver}\n",
        f"        - name: VIRT_OPERATOR_IMAGE\n          value: {reg}/virt-operator@{imgs['virt-operator']}\n",
        "the VIRT_OPERATOR_IMAGE env var",
    )
    operand_env = "".join(
        f"        - name: {var}\n          value: {pin(name)}\n" for var, name in KUBEVIRT_OPERAND_ENV
    )
    text = replace_once(
        text,
        f"        - name: KUBEVIRT_VERSION\n          value: {ver}\n",
        f"        - name: KUBEVIRT_VERSION\n          value: {ver}\n" + operand_env,
        "the KUBEVIRT_VERSION env var",
    )
    changes = [
        "virt-operator container image pinned to <tag>@<digest>",
        "VIRT_OPERATOR_IMAGE pinned to <digest> (the operator parses it; KUBEVIRT_VERSION keeps the tag)",
        "VIRT_*/GS/PR_HELPER/SIDECAR_SHIM_IMAGE operand overrides added, pinned to <tag>@<digest>",
    ]
    return header(entry, changes) + text


def transform_cdi(text, entry):
    reg, ver, imgs = entry["registry"], entry["version"], entry["images"]
    total = 0
    for name, digest in imgs.items():
        pattern = re.compile(re.escape(f"{reg}/{name}:{ver}") + r"(?=\n)")
        text, n = pattern.subn(f"{reg}/{name}:{ver}@{digest}", text)
        if n == 0:
            die(f"cdi image {name}:{ver} not referenced upstream")
        total += n
    if re.search(re.escape(reg) + r"/[a-z0-9-]+:" + re.escape(ver) + r"\n", text):
        die("cdi manifest still has an unpinned image reference")
    changes = [f"{total} image references (operator image and *_IMAGE env vars) pinned to <tag>@<digest>"]
    return header(entry, changes) + text


TRANSFORMS = {"kubevirt": transform_kubevirt, "cdi": transform_cdi}


def download(url, dest_dir):
    path = os.path.join(dest_dir, os.path.basename(url))
    with urllib.request.urlopen(url, timeout=120) as resp, open(path, "wb") as out:
        out.write(resp.read())
    return path


def iter_images(docs):
    """Yield (where, value) for every container image and *_IMAGE env value."""
    for doc in docs:
        if not doc or doc.get("kind") not in ("Deployment", "DaemonSet", "StatefulSet", "Job"):
            continue
        spec = doc["spec"]["template"]["spec"]
        for c in spec.get("initContainers", []) + spec.get("containers", []):
            yield f"{doc['kind']}/{doc['metadata']['name']} container {c['name']} image", c["image"]
            for env in c.get("env", []):
                if env["name"].endswith("_IMAGE") and "value" in env:
                    yield f"{doc['kind']}/{doc['metadata']['name']} env {env['name']}", env["value"]


def verify_pins(key, entry, text):
    reg, ver, imgs = entry["registry"], entry["version"], entry["images"]
    docs = list(yaml.safe_load_all(text))
    errors = []
    seen = 0
    for where, value in iter_images(docs):
        seen += 1
        if where.endswith("env VIRT_OPERATOR_IMAGE"):
            expected = f"{reg}/virt-operator@{imgs['virt-operator']}"
            if value != expected:
                errors.append(f"{where}: {value} != {expected}")
            continue
        if not PINNED_RE.match(value):
            errors.append(f"{where}: not pinned by tag+digest: {value}")
            continue
        name_tag, digest = value.split("@")
        name = name_tag[len(reg) + 1:].rsplit(":", 1)[0]
        if not name_tag.startswith(reg + "/") or name not in imgs:
            errors.append(f"{where}: image not in lock: {value}")
        elif name_tag != f"{reg}/{name}:{ver}" or digest != imgs[name]:
            errors.append(f"{where}: {value} does not match lock {reg}/{name}:{ver}@{imgs[name]}")
    if key == "kubevirt":
        envs = {}
        for doc in docs:
            if doc and doc.get("kind") == "Deployment" and doc["metadata"]["name"] == "virt-operator":
                for e in doc["spec"]["template"]["spec"]["containers"][0].get("env", []):
                    envs[e["name"]] = e.get("value")
        for var, _ in KUBEVIRT_OPERAND_ENV:
            if var not in envs:
                errors.append(f"virt-operator env {var} missing")
        if envs.get("KUBEVIRT_VERSION") != ver:
            errors.append(f"KUBEVIRT_VERSION is {envs.get('KUBEVIRT_VERSION')}, want {ver}")
    if seen == 0:
        errors.append("no images found")
    return errors


def cmd_verify(_args):
    lock = load_lock()
    ok = True
    sums = {}
    with open(SUMS) as f:
        for line in f:
            digest, name = line.split()
            sums[name] = digest
    for key, entry in (("kubevirt", lock["kubevirt"]), ("cdi", lock["cdi"])):
        path = os.path.join(VENDOR, entry["output"])
        with open(path, "rb") as f:
            data = f.read()
        if sums.get(entry["output"]) != sha256_bytes(data):
            print(f"FAIL {entry['output']}: sha256 does not match vendor/SHA256SUMS")
            ok = False
        text = data.decode()
        if f"# Upstream sha256: {entry['sha256']}\n" not in text:
            print(f"FAIL {entry['output']}: header does not record the locked upstream sha256")
            ok = False
        errors = verify_pins(key, entry, text)
        for e in errors:
            print(f"FAIL {entry['output']}: {e}")
        ok = ok and not errors
        if not errors:
            print(f"ok   {entry['output']}: {entry['version']}, all images pinned to the locked digests")
    if not ok:
        sys.exit(1)


def cmd_rebuild(args):
    lock = load_lock()
    outputs = {}
    with tempfile.TemporaryDirectory(prefix="vd-vendor-") as tmp:
        for key in ("kubevirt", "cdi"):
            entry = lock[key]
            dl_dir = tempfile.mkdtemp(prefix=f"{key}-", dir=tmp)
            path = download(entry["source"], dl_dir)
            with open(path, "rb") as f:
                data = f.read()
            got = sha256_bytes(data)
            if got != entry["sha256"]:
                die(f"{key}: upstream sha256 {got} != locked {entry['sha256']} ({entry['source']})")
            out = TRANSFORMS[key](data.decode(), entry)
            errors = verify_pins(key, entry, out)
            if errors:
                die(f"{key}: transform produced unpinned output: {errors}")
            outputs[entry["output"]] = out.encode()
            print(f"ok   {key} {entry['version']}: upstream sha256 verified ({got})")
    sums = "".join(f"{sha256_bytes(data)}  {name}\n" for name, data in sorted(outputs.items()))
    if args.check:
        differs = False
        for name, data in outputs.items():
            with open(os.path.join(VENDOR, name), "rb") as f:
                if f.read() != data:
                    print(f"FAIL vendor/{name} differs from a fresh rebuild")
                    differs = True
        with open(SUMS) as f:
            if f.read() != sums:
                print("FAIL vendor/SHA256SUMS differs from a fresh rebuild")
                differs = True
        if differs:
            sys.exit(1)
        print("ok   vendored files are byte-identical to a fresh rebuild")
        return
    for name, data in outputs.items():
        with open(os.path.join(VENDOR, name), "wb") as f:
            f.write(data)
    with open(SUMS, "w") as f:
        f.write(sums)
    print("wrote", ", ".join(f"vendor/{n}" for n in sorted(outputs)), "and vendor/SHA256SUMS")


def cmd_resolve(_args):
    lock = load_lock()
    with open(LOCK) as f:
        text = f.read()
    for key in ("kubevirt", "cdi"):
        entry = lock[key]
        for name, old in entry["images"].items():
            ref = f"{entry['registry']}/{name}:{entry['version']}"
            new = subprocess.run(["crane", "digest", ref], check=True, capture_output=True, text=True).stdout.strip()
            if not DIGEST_RE.match(new):
                die(f"crane digest {ref} returned {new!r}")
            if new != old:
                text = text.replace(f"    {name}: {old}\n", f"    {name}: {new}\n", 1)
                print(f"updated {ref} -> {new}")
    with open(LOCK, "w") as f:
        f.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("verify")
    rebuild = sub.add_parser("rebuild")
    rebuild.add_argument("--check", action="store_true")
    sub.add_parser("resolve")
    args = parser.parse_args()
    {"verify": cmd_verify, "rebuild": cmd_rebuild, "resolve": cmd_resolve}[args.cmd](args)


if __name__ == "__main__":
    main()
