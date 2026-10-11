#!/usr/bin/env python3
"""Offline tests for test/jq/argo.jq, the Argo CD diagnostics and sync patch of k3d-e2e.sh.

    python3 -I hack/virtual-device-spike/test/argo_jq_test.py

The sync_patch test replays, with RFC 7386 merge patches, what the e2e's patch and the
application-controller of Argo CD v3.5.1 do to the Application: setOperationState writes
{"status": {"operationState": state}} as a JSON merge patch, and SyncOperation.resources
is omitempty. The negative control is the e2e's earlier patch (only .operation): it
leaves the resource list of a previous partial selfHeal in place, which is how the
forced full re-sync ran as a partial sync of KubeVirt and CDI.
"""
import copy
import json
import os
import subprocess
import sys

JQ_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jq")
failed = False


def check(cond, msg):
    global failed
    print(("ok   " if cond else "FAIL ") + msg)
    failed |= not cond


def jq(program, data, *args, slurp_stream=False):
    """Run jq with the argo module; data is a value, or a list of values fed as a stream with -n."""
    text = "".join(json.dumps(d, indent=1) + "\n" for d in data) if slurp_stream else json.dumps(data)
    cmd = ["jq", "-L", JQ_LIB, "-c"] + (["-n"] if slurp_stream else []) + list(args) + [f'include "argo"; {program}']
    out = subprocess.run(cmd, input=text, capture_output=True, text=True, check=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def merge_patch(target, patch):
    """RFC 7386 JSON merge patch, as the API server applies --type merge to a custom resource."""
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    out = copy.deepcopy(target) if isinstance(target, dict) else {}
    for key, value in patch.items():
        if value is None:
            out.pop(key, None)
        else:
            out[key] = merge_patch(out.get(key), value)
    return out


def ev(kind, obj):
    return {"type": kind, "object": obj}


# ------------------------------------------------------------------ app_timeline
res = lambda kind, name, status="Synced", health="Healthy": {"kind": kind, "name": name, "status": status, "health": {"status": health}}
base = {
    "metadata": {"name": "virtual-devices", "resourceVersion": "100"},
    "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}, "reconciledAt": "t1", "history": [{"id": 0}],
               "resources": [res("KubeVirt", "kubevirt"), res("CDI", "cdi")],
               "operationState": {"phase": "Succeeded", "startedAt": "s1", "finishedAt": "f1",
                                  "operation": {"initiatedBy": {"automated": True}, "sync": {"revision": "0.1.0"}}}},
}
refresh = merge_patch(base, {"metadata": {"resourceVersion": "101"}, "status": {"reconciledAt": "t2"}})
outofsync = merge_patch(refresh, {"metadata": {"resourceVersion": "102"}, "status": {"sync": {"status": "OutOfSync"}}})
outofsync["status"]["resources"] = [res("KubeVirt", "kubevirt", "OutOfSync", "Missing"), res("CDI", "cdi")]
healing = merge_patch(outofsync, {"metadata": {"resourceVersion": "103"},
                                  "operation": {"initiatedBy": {"automated": True}, "sync": {"resources": [{"group": "kubevirt.io", "kind": "KubeVirt", "name": "kubevirt"}]}}})
lines = jq("app_timeline", [ev("ADDED", base), ev("MODIFIED", refresh), ev("MODIFIED", outofsync), ev("MODIFIED", healing)], slurp_stream=True)
check(len(lines) == 3, f"app_timeline: a refresh that only moves reconciledAt prints no line (got {len(lines)} lines)")
check(lines[0]["operationState"]["by"] == "auto" and lines[0]["operationState"]["resources"] == "all", "app_timeline: a full automated sync reads by=auto resources=all")
check(lines[1]["notSynced"] == ["KubeVirt/kubevirt=OutOfSync/Missing"], f"app_timeline: not-Synced resources carry their health: {lines[1]['notSynced']}")
check(lines[2]["operation"] == {"by": "auto", "resources": "KubeVirt/kubevirt"}, f"app_timeline: a partial selfHeal names its resources: {lines[2]['operation']}")
check(all(set(l) >= {"t", "event", "rv", "sync", "history"} for l in lines), "app_timeline: every line has t, event, rv, sync and history")

# ------------------------------------------------------------------ cr_timeline
kv = {"kind": "KubeVirt", "metadata": {"name": "kubevirt", "resourceVersion": "1", "generation": 1, "finalizers": ["f"],
                                       "managedFields": [{"manager": "argocd-controller", "operation": "Apply", "time": "a", "fieldsV1": {"f:spec": {"f:configuration": {}}}}]},
      "spec": {"configuration": {"x": 1}}, "status": {"phase": "Deploying"}}
kv_status = merge_patch(kv, {"metadata": {"resourceVersion": "2"}, "status": {"phase": "Deployed"}})
kv_status["metadata"]["managedFields"].append({"manager": "virt-operator", "operation": "Update", "subresource": "status", "time": "b", "fieldsV1": {"f:status": {}}})
kv_gen2 = merge_patch(kv_status, {"metadata": {"resourceVersion": "3", "generation": 2}, "spec": {"customizeComponents": {}, "configuration": {"x": 2}}})
kv_gen2["metadata"]["managedFields"].append({"manager": "virt-operator", "operation": "Update", "time": "c", "fieldsV1": {"f:spec": {"f:customizeComponents": {}}}})
kv_gen3 = merge_patch(kv_gen2, {"metadata": {"resourceVersion": "4", "generation": 3}})
kv_gen3["spec"]["configuration"]["y"] = None
lines = jq("cr_timeline", [ev("ADDED", kv), ev("MODIFIED", kv_status), ev("MODIFIED", kv_gen2), ev("MODIFIED", kv_gen3)], slurp_stream=True)
check(len(lines) == 3, f"cr_timeline: a status-only write prints no line (got {len(lines)} lines)")
check(lines[0]["spec"] == kv["spec"] and lines[0]["obj"] == "KubeVirt/kubevirt", "cr_timeline: the first line of an object carries its full spec")
check(lines[1]["specChanges"] == {".configuration.x": [1, 2], ".customizeComponents": ["<absent>", {}]}, f"cr_timeline: spec changes as path: [before, after]: {lines[1].get('specChanges')}")
check(lines[2]["specChanges"] == {".configuration.y": ["<absent>", None]}, f"cr_timeline: an explicit null differs from an absent field: {lines[2].get('specChanges')}")
check("virt-operator/Update@c: customizeComponents" in lines[1]["owners"], f"cr_timeline: spec owners with manager, operation and time: {lines[1]['owners']}")

# ------------------------------------------------------------------ selfheal_report
def report(first_operator_write):
    app_lines = [
        {"t": "10.300", "operation": {"by": "auto", "resources": "all"}, "operationState": {"finished": None}, "notSynced": ["CDI/cdi=OutOfSync/-"]},
        {"t": "10.410", "operation": None, "operationState": {"finished": "2026-10-09T20:26:10Z"}, "notSynced": ["CDI/cdi=OutOfSync/-"]},
        {"t": "10.451", "operation": {"by": "auto", "resources": "CDI/cdi"}, "operationState": None, "notSynced": ["CDI/cdi=OutOfSync/-"]},
        {"t": "10.459", "operation": {"by": "auto", "resources": "CDI/cdi"}, "operationState": {"finished": None}, "notSynced": []},
    ]
    cr_lines = [{"t": "10.392", "obj": "CDI/cdi", "owners": ["argocd-controller/Apply@x: config"]},
                {"t": first_operator_write, "obj": "CDI/cdi", "owners": ["argocd-controller/Apply@x: config", "cdi-operator/Update@y: customizeComponents"]}]
    return jq("selfheal_report($app; $crs)[]", None, "--argjson", "app", json.dumps(app_lines), "--argjson", "crs", json.dumps(cr_lines))


(stale,) = report("10.726")
check(stale["requested"] == "10.451" and stale["actedOn"] == ["CDI/cdi=OutOfSync/-"] and stale["previousOperationFinished"] == "2026-10-09T20:26:10Z",
      f"selfheal_report: one entry per selfHeal, with the status it acted on: {stale}")
check(stale["objects"] == [{"obj": "CDI/cdi", "created": "10.392", "firstOtherWrite": "10.726"}] and stale["verdict"].startswith("stale comparison"),
      "selfheal_report: requested after creation and before any operator write reads as a stale comparison")
(drift,) = report("10.420")
check(not drift["verdict"].startswith("stale comparison"), "selfheal_report: an operator write before the selfHeal is not called stale")

# ------------------------------------------------------------------ sync_patch
selfheal_state = {"phase": "Succeeded", "startedAt": "s2", "finishedAt": "f2", "message": "successfully synced (all tasks run)",
                  "operation": {"initiatedBy": {"automated": True}, "retry": {"limit": 10},
                                "sync": {"revision": "0.1.0", "prune": True, "autoHealAttemptsCount": 1,
                                         "resources": [{"group": "kubevirt.io", "kind": "KubeVirt", "name": "kubevirt"},
                                                       {"group": "cdi.kubevirt.io", "kind": "CDI", "name": "cdi"}]}},
                  "syncResult": {"revision": "0.1.0", "resources": [{"kind": "KubeVirt", "name": "kubevirt", "status": "Synced"}]}}
app = {"metadata": {"name": "virtual-devices", "resourceVersion": "4242"},
       "spec": {"syncPolicy": {"automated": {"prune": True, "selfHeal": True}, "syncOptions": ["ServerSideApply=true", "RespectIgnoreDifferences=true"],
                               "retry": {"limit": 10, "backoff": {"duration": "30s", "factor": 2, "maxDuration": "5m"}}}},
       "status": {"operationState": selfheal_state}}
(patch,) = jq('sync_patch("vd-e2e"; $rev)', app, "--arg", "rev", "0.1.0")
check(patch["metadata"] == {"resourceVersion": "4242"}, "sync_patch: conditional on the resourceVersion that was read")
check(patch["status"] == {"operationState": None}, "sync_patch: clears status.operationState, as SetAppOperation does")
check(patch["operation"] == {"initiatedBy": {"username": "vd-e2e"}, "retry": app["spec"]["syncPolicy"]["retry"],
                             "sync": {"revision": "0.1.0", "prune": True, "syncOptions": app["spec"]["syncPolicy"]["syncOptions"]}},
      f"sync_patch: a full sync with the Application's prune, syncOptions and retry: {patch['operation']}")


def controller_runs(app_after_patch):
    """processRequestedAppOperation: NewOperationState(*app.Operation), then setOperationState
    writes it as a merge patch; a resumed operation is read back from status.operationState."""
    state = {"operation": app_after_patch["operation"], "phase": "Running", "startedAt": "s3"}
    return merge_patch(app_after_patch, {"status": {"operationState": state}})["status"]["operationState"]["operation"]


resumed = controller_runs(merge_patch(app, patch))
check("resources" not in resumed["sync"] and resumed["initiatedBy"] == {"username": "vd-e2e"},
      f"sync_patch: the resumed operation is the full sync the e2e asked for: {json.dumps(resumed, sort_keys=True)}")
old_patch = {"operation": {"initiatedBy": {"username": "vd-e2e"}, "sync": {"revision": "0.1.0", "prune": True, "syncOptions": app["spec"]["syncPolicy"]["syncOptions"]}}}
resumed_old = controller_runs(merge_patch(app, old_patch))
check(len(resumed_old["sync"].get("resources", [])) == 2 and resumed_old["initiatedBy"].get("automated") is True,
      "negative control: the earlier patch (.operation only) resumes as the selfHeal's partial sync of KubeVirt and CDI")

# ------------------------------------------------------------------ ssa_drift
live_kv = {"metadata": {"name": "kubevirt", "labels": {"a": "1"},
                        "annotations": {"argocd.argoproj.io/tracking-id": "virtual-devices:kubevirt.io/KubeVirt:kubevirt/kubevirt",
                                        "argocd.argoproj.io/sync-wave": "1"}},
           "spec": {"imagePullPolicy": "IfNotPresent", "customizeComponents": {}}, "status": {"phase": "Deployed"}}
rendered = {"metadata": {"name": "kubevirt", "labels": {"a": "1"}, "annotations": {"argocd.argoproj.io/sync-wave": "1"}},
            "spec": {"imagePullPolicy": "IfNotPresent"}}
(applied,) = jq("as_argocd_applies($live)", rendered, "--argjson", "live", json.dumps(live_kv))
check(applied["metadata"]["annotations"] == live_kv["metadata"]["annotations"], f"as_argocd_applies: carries Argo CD's tracking annotation: {applied['metadata']}")
dry_same = merge_patch(live_kv, {"status": None})
(none,) = jq("ssa_drift($live; $dry)", None, "--argjson", "live", json.dumps(live_kv), "--argjson", "dry", json.dumps(dry_same))
check(none == {}, f"ssa_drift: an operator-only field kept by the dry-run and status are no drift: {none}")
dry_diff = merge_patch(dry_same, {"spec": {"imagePullPolicy": "Always"}, "metadata": {"labels": {"b": "2"}}})
(some,) = jq("ssa_drift($live; $dry)", None, "--argjson", "live", json.dumps(live_kv), "--argjson", "dry", json.dumps(dry_diff))
check(some == {".spec.imagePullPolicy": ["IfNotPresent", "Always"], ".labels.b": ["<absent>", "2"]}, f"ssa_drift: spec and label changes as path: [live, dry-run]: {some}")

sys.exit(1 if failed else 0)
