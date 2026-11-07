# teknoirbot-controller

Deploys the TeknoirBot controller (`ghcr.io/teknoir/teknoirbot-controller`, private repo) into `teknoir-system`:

- the CRD `teknoirbots.teknoir.org` (`crds/`, annotated `Prune=false,Delete=false`: pruning a CRD would delete every bot);
- ServiceAccount, ClusterRole and ClusterRoleBinding `teknoirbot-controller` (the rules of `config/rbac/role.yaml` of the
  controller repo: Devices create/get/list/patch/watch, TeknoirBots read plus status and finalizers, Events);
- a leader-election Role and RoleBinding (when `leaderElection`, default on; create on Leases plus get/update/patch only on
  the controller's own Lease `teknoirbot-controller.teknoir.org`, which must match `LeaderElectionID` in the controller);
- the Deployment (1 replica, metrics on 8080, probes on 8081; the label `kustomize.component` is what the monitoring PodMonitor selects);
- the ValidatingAdmissionPolicy `teknoirbot-device-guard` and its binding (below).

A TeknoirBot gets one virtual Device `tb-<name>` in its teamspace; the controller creates it and corrects the fields it owns.

## Gate

The Application is rendered by `charts/app-of-apps/templates/teknoirbot.yaml` only when `teknoirbot.enabled: true` in the
app-of-apps values AND the project is `teknoir-cloud` (staging; the allowlist is in the template). It is off until the
image is pinned.

## Image pin

`image.tag` is required (the render fails without it) and is `<tag>@sha256:<digest>`:

    scripts/pin-image teknoirbot-controller=<tag> --write

## Admission policy `teknoirbot-device-guard`

The ClusterRole may create and patch every Device in the cluster; RBAC cannot narrow by label. The policy narrows what the
controller's service account (`system:serviceaccount:<release namespace>:<serviceAccount.name>`; nobody else is evaluated)
can do to Devices: every write carries the labels `teknoir.org/teknoirbot` (non-empty) and `teknoir.org/part-of=teknoirbot`;
an update needs the old object to be a bot's already (the label, or a controller ownerReference to a TeknoirBot);
a create is `device_type: virtual`; `spec.keys` never changes; platform annotations (`ztna.teknoir.org/*`,
`teknoir.org/disabled*`, `teknoir.org/org-tree-*`) are absent at create and unchanged on update. Rules 6-8 keep it from
running workloads through device-controller: a create carries a controller ownerReference to the TeknoirBot named in the
label (6) and an empty `spec.manifest` with no `spec.applications`, `spec.overrides` or `spec.plugins` (7); an update
leaves `spec.manifest`, `spec.applications`, `spec.overrides`, `spec.plugins`, `metadata.ownerReferences` and
`metadata.finalizers` as they were (8). `failurePolicy: Fail`, action `Deny`. Test: `tests/k3d-vap-test.sh` (context `k3d-teknoir-dev` only).
Break-glass: pause the Application's auto-sync, delete the binding, act, restore.

## Refreshing the CRD

After `make manifests` in the controller repo: `charts/teknoirbot-controller/hack/sync-crd.sh <controller-repo-dir>`
(copies the generated CRD and adds the annotation; a second run changes nothing). `tests/crd_guard_test.sh` checks the annotation.

## Desktop

A bot gets its browser desktop only when device-controller has the `DESKTOP` config: `desktop.enabled` and `desktop.image` in
`charts/device-controller/values.yaml` (and `ztna.enabled`, the desktop is reached through Tunneling), and a Device CRD with
`spec.desktop` in `charts/device-controller/crds/devices.yaml`.

## Tests

    helm unittest charts/teknoirbot-controller
    bash charts/teknoirbot-controller/tests/crd_guard_test.sh
    bash charts/teknoirbot-controller/tests/k3d-vap-test.sh
