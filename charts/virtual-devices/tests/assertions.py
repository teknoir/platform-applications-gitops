#!/usr/bin/env python3
"""Structural assertions on `helm template` output of charts/virtual-devices.

Usage: python3 -I assertions.py LOCK RENDERED.yaml

Checks:
  - every container image (Deployments/DaemonSets/StatefulSets/Jobs) is pinned by
    tag+digest, and every *_IMAGE env var is pinned (VIRT_OPERATOR_IMAGE by digest
    only, see hack/vendor.py) to the digests in vendor/upstream.lock.yaml;
  - KubeVirt CR: no feature gates, serial console log disabled, uninstall blocked
    while workloads exist, one infra replica (single-node vpro), applied after the operator (sync wave 1);
  - CDI CR: only HonorWaitForFirstConsumer, explicit worker resources, one
    cdi-apiserver replica;
  - neither CR carries an empty struct other than disableSerialConsoleLog: {} (empty
    structs the server may default invite Argo CD drift);
  - PriorityClass teknoir-virtual-device: negative value, preemptionPolicy Never,
    not global default;
  - coredns-custom: one key, virtual-devices.override, whose rewrite regex matches
    exactly mqtt-/deadend-<label>.<domain>.
"""
import re
import sys

import yaml

PINNED = re.compile(r"^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")
DIGEST_ONLY = re.compile(r"^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$")

failures = []

# Empty mappings that mean something (an enabled "flag struct").
ALLOWED_EMPTY = {"KubeVirt": {"spec.configuration.virtualMachineOptions.disableSerialConsoleLog"}, "CDI": set()}


def empty_structs(node, path=""):
    """Paths of every empty mapping or list below node."""
    out = []
    if isinstance(node, dict):
        if not node and path:
            out.append(path)
        for k, v in node.items():
            out += empty_structs(v, f"{path}.{k}" if path else k)
    elif isinstance(node, list) and not node and path:
        out.append(path)
    return out


def check(cond, msg):
    if cond:
        print(f"ok   {msg}")
    else:
        print(f"FAIL {msg}")
        failures.append(msg)


def main():
    lock_path, rendered_path = sys.argv[1], sys.argv[2]
    with open(lock_path) as f:
        lock = yaml.safe_load(f)
    with open(rendered_path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    by_kind = {}
    for d in docs:
        by_kind.setdefault(d["kind"], []).append(d)

    locked = {}
    for key in ("kubevirt", "cdi"):
        e = lock[key]
        for name, digest in e["images"].items():
            locked[f"{e['registry']}/{name}"] = (e["version"], digest)

    # ---- images
    images = []
    for kind in ("Deployment", "DaemonSet", "StatefulSet", "Job"):
        for d in by_kind.get(kind, []):
            spec = d["spec"]["template"]["spec"]
            for c in spec.get("initContainers", []) + spec.get("containers", []):
                images.append((f"{kind}/{d['metadata']['name']}/{c['name']}", "image", c["image"]))
                for env in c.get("env", []):
                    if env["name"].endswith("_IMAGE") and "value" in env:
                        images.append((f"{kind}/{d['metadata']['name']}/{c['name']}", env["name"], env["value"]))
    check(len(images) >= 20, f"found {len(images)} image references (2 operators + operand env vars)")
    for where, field, ref in images:
        if field == "VIRT_OPERATOR_IMAGE":
            ok = bool(DIGEST_ONLY.match(ref)) and locked.get(ref.split("@")[0], (None, None))[1] == ref.split("@")[1]
            check(ok, f"{where} {field} pinned by locked digest: {ref}")
            continue
        ok = bool(PINNED.match(ref))
        if ok:
            name_tag, digest = ref.split("@")
            name, tag = name_tag.rsplit(":", 1)
            ok = locked.get(name) == (tag, digest)
        check(ok, f"{where} {field} pinned by tag+digest from the lock: {ref}")

    # ---- KubeVirt CR
    kv = by_kind.get("KubeVirt", [])
    check(len(kv) == 1, "one KubeVirt CR")
    if kv:
        kv = kv[0]
        conf = kv["spec"]["configuration"]
        check(conf.get("developerConfiguration", {}).get("featureGates", []) == [], "KubeVirt: no feature gates")
        # virt-operator writes the CR back with omitempty: an empty list would be dropped
        # and re-applied by Argo CD (k3d e2e, Argo CD v3.5.1).
        check("developerConfiguration" not in conf, "KubeVirt: no empty developerConfiguration/featureGates (operator drops it, Argo CD would re-apply)")
        check(conf.get("virtualMachineOptions", {}).get("disableSerialConsoleLog") == {}, "KubeVirt: serial console log disabled")
        check(not conf.get("developerConfiguration", {}).get("useEmulation"), "KubeVirt: no software emulation")
        check(kv["spec"].get("uninstallStrategy") == "BlockUninstallIfWorkloadsExist", "KubeVirt: uninstall blocked while workloads exist")
        check(kv["metadata"]["annotations"].get("argocd.argoproj.io/sync-wave") == "1", "KubeVirt CR in sync wave 1")
        check("SkipDryRunOnMissingResource=true" in kv["metadata"]["annotations"].get("argocd.argoproj.io/sync-options", ""), "KubeVirt CR skips dry-run until its CRD exists")
        check(kv["metadata"]["namespace"] == "kubevirt", "KubeVirt CR in namespace kubevirt")
        check(kv["spec"].get("infra", {}).get("replicas") == 1, "KubeVirt: one virt-api/virt-controller replica (single 14 GB staging host vpro)")
        empties = [p for p in empty_structs(kv["spec"], "spec") if p not in ALLOWED_EMPTY["KubeVirt"]]
        check(not empties, f"KubeVirt: no empty structs besides disableSerialConsoleLog ({empties or 'none'})")

    # ---- CDI CR
    cdi = by_kind.get("CDI", [])
    check(len(cdi) == 1, "one CDI CR")
    if cdi:
        cdi = cdi[0]
        check(cdi["spec"]["config"]["featureGates"] == ["HonorWaitForFirstConsumer"], "CDI: only HonorWaitForFirstConsumer")
        res = cdi["spec"]["config"]["podResourceRequirements"]
        check(bool(res["requests"]) and bool(res["limits"]), "CDI: explicit worker pod requests and limits (quota budgeting)")
        check(cdi["spec"].get("uninstallStrategy") == "BlockUninstallIfWorkloadsExist", "CDI: uninstall blocked while workloads exist")
        check(cdi["metadata"]["annotations"].get("argocd.argoproj.io/sync-wave") == "1", "CDI CR in sync wave 1")
        check(cdi["spec"].get("infra", {}).get("apiServerReplicas") == 1, "CDI: one cdi-apiserver replica (single 14 GB staging host vpro)")
        empties = [p for p in empty_structs(cdi["spec"], "spec") if p not in ALLOWED_EMPTY["CDI"]]
        check(not empties, f"CDI: no empty structs ({empties or 'none'})")

    # ---- operator deployments match the lock versions
    deps = {d["metadata"]["name"]: d for d in by_kind.get("Deployment", [])}
    for name, key in (("virt-operator", "kubevirt"), ("cdi-operator", "cdi")):
        check(name in deps, f"Deployment {name} rendered")
    if "virt-operator" in deps:
        env = {e["name"]: e.get("value") for e in deps["virt-operator"]["spec"]["template"]["spec"]["containers"][0]["env"]}
        check(env.get("KUBEVIRT_VERSION") == lock["kubevirt"]["version"], f"KUBEVIRT_VERSION={lock['kubevirt']['version']}")
        for var in ("VIRT_API_IMAGE", "VIRT_CONTROLLER_IMAGE", "VIRT_HANDLER_IMAGE", "VIRT_LAUNCHER_IMAGE"):
            check(var in env, f"virt-operator sets {var}")

    # ---- PriorityClass
    pcs = {p["metadata"]["name"]: p for p in by_kind.get("PriorityClass", [])}
    pc = pcs.get("teknoir-virtual-device")
    check(pc is not None, "PriorityClass teknoir-virtual-device rendered")
    if pc:
        check(pc["value"] < 0, f"PriorityClass value {pc['value']} is below platform pods (0)")
        check(pc["preemptionPolicy"] == "Never", "PriorityClass preemptionPolicy Never")
        check(pc["globalDefault"] is False, "PriorityClass is not the global default")

    # ---- CoreDNS override
    cms = [c for c in by_kind.get("ConfigMap", []) if c["metadata"]["name"] == "coredns-custom"]
    check(len(cms) == 1 and cms[0]["metadata"]["namespace"] == "kube-system", "coredns-custom ConfigMap in kube-system")
    if cms:
        data = cms[0]["data"]
        check(list(data) == ["virtual-devices.override"], "coredns-custom has exactly the virtual-devices.override key")
        rules = [l.strip() for l in data["virtual-devices.override"].splitlines() if l.strip() and not l.strip().startswith("#")]
        check(len(rules) == 1, "one CoreDNS directive")
        m = re.match(r"^rewrite stop name regex (\S+) (\S+) answer auto$", rules[0]) if rules else None
        check(m is not None, "directive is 'rewrite stop name regex <re> <target> answer auto'")
        if m:
            regex, target = re.compile(m.group(1)), m.group(2)
            check(target == "istio-ingressgateway-public.istio-system.svc.cluster.local.", f"rewrite target {target}")
            for name, want in (
                ("mqtt-teknoir-demo.teknoir.cloud.", True),
                ("deadend-teknoir-demo.teknoir.cloud.", True),
                ("mqtt-a.teknoir.cloud.", True),
                ("mqtt-teknoir-demo.teknoir.cloud.example.com.", False),
                ("x.mqtt-teknoir-demo.teknoir.cloud.", False),
                ("mqtt-.teknoir.cloud.", False),
                ("mqtt-teknoir-demo-.teknoir.cloud.", False),
                ("historian-teknoir-demo.teknoir.cloud.", False),
                ("teknoir.cloud.", False),
                ("mqtt-teknoir-demo.teknoirxcloud.", False),  # dots are escaped
            ):
                check(bool(regex.search(name)) == want, f"rewrite regex {'matches' if want else 'does not match'} {name}")

    if failures:
        print(f"\n{len(failures)} assertion(s) failed")
        sys.exit(1)
    print("\nall chart assertions passed")


if __name__ == "__main__":
    main()
