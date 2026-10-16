# device-controller: downgrade and removal runbook

The CRDs in `crds/` (robots, robottypes, devices, deviceapplicationsets) carry
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so reverting this chart or
deleting the files never removes a CRD (which would delete every Robot and RobotType).
`tests/crd_guard_test.sh` checks the annotation; re-add it after copying regenerated CRDs.

Robots carry the finalizer `teknoir.org/robot-release`, which only the nextgen reconciler
removes. Before rolling the device-controller image back to a version without the Robot
reconciler (for example sha-cff556b5), or before removing the Robot CRD on purpose:

    kubectl --context <ctx> get robots.teknoir.org -A -o name | while read r; do
      kubectl --context <ctx> patch "$r" --type=merge -p '{"metadata":{"finalizers":null}}'
    done

Use `kubectl patch` per Robot only after checking its release state: clearing the finalizer
skips the release of the Robot's devices (labels and annotations stay on the Device).
Without this step Robots stay Terminating and a teamspace namespace deletion hangs.

`robotmodels.teknoir.org` was renamed to `robottypes.teknoir.org` (kind RobotType). The chart no longer ships the old
CRD; `Prune=false` keeps it on the cluster, empty, until someone removes it by hand
(`kubectl --context <ctx> delete crd robotmodels.teknoir.org`, only when `get robotmodels -A` lists nothing).
Robots use `spec.type` and the Device label `teknoir.org/robot-type`; the old `spec.model` and
`teknoir.org/robot-model` are not read.

The device-controller keeps the rendered GitOps sources of every device in a ConfigMap
`teknoir-config-sources-<device>` in the device's teamspace (owned by the Device, deleted with it). After a
rollback the older image ignores it; delete the ConfigMaps by hand if they are unwanted:
`kubectl --context <ctx> delete configmap -A -l teknoir.org/device`.
