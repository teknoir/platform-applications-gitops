# release-guard

Admission guard for staging releases (design: `plans/staging-releases.md`, "enforcement" 2 and 4). It keeps
anything but `scripts/staging-release` from changing what ArgoCD deploys on staging (`teknoir-cloud`).

Off by default: `releaseGuard.enabled: false` in `charts/app-of-apps/values.yaml`, and the Application template
renders only on `teknoir-cloud` (allowlist in `templates/_helpers.tpl`, like ZTNA). Turn it on in release step 4
with `mode: Warn`, then `Deny` after a day without unexpected warnings (`scripts/staging-status`).

## What it is

| Object | Purpose |
|---|---|
| `ValidatingAdmissionPolicy staging-release-guard` | CEL rules on ArgoCD `applications` in `teknoir-system` (CREATE, UPDATE, DELETE), `failurePolicy: Fail` |
| `ValidatingAdmissionPolicyBinding staging-release-guard-binding` | `validationActions` `[Warn, Audit]` or `[Deny, Audit]` (values `guard.mode`), limited to the namespace |
| `ServiceAccount staging-releaser` + `Role` + `RoleBinding` | the identity `scripts/staging-release` impersonates (`--as`); nobody runs as it, no token exists |

The policy is keyed on WHO writes (`request.userInfo.username`), following `charts/ztna/templates/admission.yaml`.

### Not evaluated (matchConditions)

- the identities in values `identities`: `system:serviceaccount:teknoir-system:argocd-application-controller`
  (syncs, status, the children of the root; managedFields manager `argocd-controller`/`argocd-application-controller`),
  `system:serviceaccount:teknoir-system:profile-controller` (plugin Applications; manager `manager`),
  `system:serviceaccount:kube-system:generic-garbage-collector` and `namespace-controller` (cascades and namespace
  teardown). The names were confirmed on vpro (`kubectl --context vpro -n teknoir-system get sa`, managedFields of
  the Applications) and the GC and namespace-controller ones on k3d with the real controllers
  (`tests/k3d-guard-test.sh`, section 4 and 7);
- UPDATEs that change none of `spec`, `metadata.finalizers`, a foreign `operation.sync.revision(s)` or an
  `operation.sync.source(s)` override: status writes, refresh annotations, the break-glass annotation, a plain
  `argocd app sync`.

### Rules, for everything else

- (a) the requester is `staging-releaser`, or break-glass is open;
- (b) `operation.sync.revision(s)` may only be the Application's own `spec.source.targetRevision` (blocks
  `argocd app sync --revision <branch>`), and an operation may not carry its own `source` / `sources` (an override
  with another targetRevision, which is what a rollback operation carries), unless break-glass;
- (c) when the releaser writes the root `app-of-apps`: repoURL, path and project fixed, `targetRevision` 40-hex, helm
  parameters exactly `release` (== targetRevision) and `releaseName` (== annotation `teknoir.org/release`,
  `staging-YYYYMMDD.N` with N >= 1 and no leading zero), none of the other helm or source keys, `destination`
  (server and namespace) unchanged, `syncPolicy.automated.selfHeal` and `prune` on, no `ignoreDifferences`. Applies
  even in break-glass;
- (d) DELETE of the root is denied, unless break-glass;
- (e) the releaser changes only the `operation` and status of CHILD Applications (the rollback terminates running
  operations), never their `spec` or finalizers. Applies even in break-glass.

What it blocks: hand `kubectl patch|edit|apply|delete` of the root, children and plugin Applications, `argocd app set`,
`argocd app sync --revision`, hand-created Applications, applying the old branch root. What it does not block: a
session that deliberately runs `kubectl --as=system:serviceaccount:teknoir-system:staging-releaser` (accepted, as in
the ztna policies: it stops accidents, not intent).

## Break-glass

Anders only, scripted: `scripts/staging-release --break-glass-begin --reason <why> --confirm-anders` sets the
annotation `teknoir.org/release-guard=break-glass` on the Namespace `teknoir-system` (and `teknoir.org/break-glass`
on the root); `--break-glass-end` removes both. `scripts/staging-status` flags an open break-glass.

No Application has to be edited to disarm the guard, so selfHeal has nothing to fight: the annotation is on the
Namespace (owned by the profile-controller Application, which applies client-side; an annotation that is not in its
manifest is not drift), and a missing annotation, or any other value, means enforce. There is no state that can be
deleted by accident into a fail-open.

### Why not a ConfigMap (paramRef)

The design named a ConfigMap `release-guard-mode` as `paramRef` with a fail-closed `parameterNotFoundAction: Deny`.
It was built and tested first, and dropped:

- on the k3s v1.34.5 of `k3d-teknoir-dev` (the same version as vpro) the binding's param lookup found the ConfigMap
  for the first requests and then reported "no params found" for every request after the first namespace deletion
  and re-creation, for new bindings and ConfigMaps too, and never recovered (apiserver restart not tried; the
  same policy on an envtest 1.30 apiserver behaved correctly);
- with `Deny`, a missing (or not found) param also denied ArgoCD's and profile-controller's own writes, because the
  param is resolved before `matchConditions` are evaluated. ArgoCD could not even start the sync that would recreate
  the ConfigMap.

`namespaceObject` is served from the apiserver's own namespace informer, worked in every test, and has no such
failure mode.

## Removing

The Application has no resources-finalizer (like ztna): removing the flag leaves the policy and binding in the cluster.
To remove the guard: release with `releaseGuard.mode: Warn` (or open break-glass), delete
`validatingadmissionpolicybinding staging-release-guard-binding` and the policy by hand under break-glass, then
set `releaseGuard.enabled: false` in a release.

## Tests

- `helm unittest charts/release-guard` (render, identities, minimal Role);
- `charts/release-guard/tests/k3d-guard-test.sh`: every rule against `k3d-teknoir-dev` with `--as` impersonation of
  the ArgoCD controller, profile-controller, argocd-server, the releaser (with the chart's own Role), a plain admin
  and the kube-system GC/namespace identities, status-only updates, break-glass on and off, Warn mode, and real GC and
  namespace teardown. Every verdict uses `--dry-run=server`; the script refuses any context that is not `k3d-*` or `kind-*`.
