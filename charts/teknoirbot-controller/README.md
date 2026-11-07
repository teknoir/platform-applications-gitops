# teknoirbot-controller

Deploys the TeknoirBot controller (`ghcr.io/teknoir/teknoirbot-controller`, private repo) into `teknoir-system`:

- the CRD `teknoirbots.teknoir.org` (`crds/`, annotated `Prune=false,Delete=false`: pruning a CRD would delete every bot);
- ServiceAccount, ClusterRole and ClusterRoleBinding `teknoirbot-controller` (the rules of `config/rbac/role.yaml` of the
  controller repo: Devices create/get/list/patch/watch, TeknoirBots read plus status and finalizers, Events);
- a leader-election Role and RoleBinding (when `leaderElection`, default on; create on Leases plus get/update/patch only on
  the controller's own Lease `teknoirbot-controller.teknoir.org`, which must match `LeaderElectionID` in the controller);
- the Deployment (1 replica, metrics on 8080, probes on 8081; the label `kustomize.component` is what the monitoring PodMonitor selects);
- the ValidatingAdmissionPolicy `teknoirbot-device-guard` and its binding (below);
- the bot fence: the policies `teknoirbot-device-fence` and `teknoirbot-created-by` and their bindings ("Bot fence").

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

## Bot fence

`templates/fence.yaml` holds two ValidatingAdmissionPolicies (`failurePolicy: Fail`, binding action `Deny`), the reverse of
`teknoirbot-device-guard`: they narrow what everybody else may do. Test: `tests/k3d-fence-test.sh` (context `k3d-teknoir-dev` only).
The identities are chart values (`fence.deviceControllerServiceAccount`, `fence.backstageServiceAccount`,
`fence.argocdServiceAccount`); the Kubernetes ones are fixed.

| Policy | Applies to | Who may write |
|---|---|---|
| `teknoirbot-device-fence` | Devices (CREATE, UPDATE, DELETE) that carry, or carried, the label `teknoir.org/teknoirbot`, or whose name starts with `tb-` | teknoirbot-controller (narrowed by `teknoirbot-device-guard`), device-controller, the garbage collector, the namespace controller, `system:kube-controller-manager` and `system:masters` are exempt. backstage-api may only UPDATE and only change the `teknoir.org/disabled*` annotations (spec, labels, other annotations, ownerReferences, finalizers and `subresources` stay equal). Nobody else may write them (default-editor included). |
| `teknoirbot-created-by` | TeknoirBots (the main resource; `teknoirbots/status` is not matched), `system:masters` exempt | CREATE and UPDATE only by backstage-api or ArgoCD (the garbage collector and `system:kube-controller-manager` may UPDATE only to drop finalizers: spec, labels and annotations unchanged); backstage-api sets a non-empty `teknoir.org/created-by` at create, and nobody changes it afterwards. DELETE only by backstage-api, ArgoCD, the garbage collector, the namespace controller or `system:kube-controller-manager`. |

All four fence objects carry `argocd.argoproj.io/sync-options: Delete=false`: turning `teknoirbot.enabled` off deletes the controller but not the bots or their Devices, so the fence stays with them; remove it by hand only after the bots are gone.

`fence.backstageServiceAccount` is the only portal identity. A second Backstage release (backstage-next, SA backstage-next-api) cannot create, change or delete TeknoirBots, or Disable/Enable a bot computer. Do not set `teknoirBots.enabled` there.

Break-glass: a cluster-admin (`system:masters` is exempt from both) pauses the Application's auto-sync (or, once the Application is gone, just deletes the binding), deletes the
ValidatingAdmissionPolicyBinding of the policy in the way, acts, and restores it (re-enable auto-sync).

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
    bash charts/teknoirbot-controller/tests/k3d-fence-test.sh
