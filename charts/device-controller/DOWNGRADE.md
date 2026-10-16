# device-controller: downgrade and removal runbook

The CRDs in `crds/` (robots, robotmodels, devices, deviceapplicationsets) carry
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`, so reverting this chart or
deleting the files never removes a CRD (which would delete every Robot and RobotModel).
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
