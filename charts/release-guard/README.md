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
- UPDATEs that change none of `spec`, `metadata.finalizers`, the root's `teknoir.org/release` /
  `teknoir.org/previous-release` annotation, or the `operation` in a way that is not a plain sync of the Application's
  own spec: status writes (terminate = `status.operationState.phase=Terminating`), refresh and hard-refresh
  annotations, the break-glass annotation, and a plain sync from the UI Sync button or `argocd app sync`
  (argocd-server).

#### Round-trip stability of the Applications (what makes the UI/CLI sync and terminate work)

argocd-server does not merge-patch: `Sync` is `util/argo.SetAppOperation` (Get, set `a.Operation`, a full `Update`) and
`TerminateOperation` is also a full `Update`, so the object goes through ArgoCD's Go types and every `omitempty` field
that is stored empty is dropped. A stored `spec.sources: []` or `ignoreDifferences[].group: ""` therefore makes the very
first UI or CLI sync (or terminate) change `spec`, and the guard would judge it as a spec change (denied in Deny, warned
in Warn). The `charts/app-of-apps` templates must render children that ArgoCD would write back unchanged:

- no `sources: [ ]` (13 templates had it) and no `group: ""` (monitoring's `ignoreDifferences`);
- `helm unittest charts/app-of-apps` (`roundtrip_test.yaml`) pins the two that existed, and the release lint
  `scripts/check-pins.py` (`app-not-roundtrip-stable`, an error) rejects any rendered Application with an empty
  `omitempty` field (an empty list, an empty string except `project` / `repoURL` / `kind`, null, an empty
  labels/annotations map). The faithful check was a one-off round trip of the rendered children through the real
  `v1alpha1.Application` type (ArgoCD v3.5.1): after the removals nothing is dropped.

#### Operations (ArgoCD v3.5.1)

`argocd-server`'s `Sync` (UI button, CLI) and the controller's `autoSync` both write `operation.sync.source` as a COPY
of `spec.source` (`sources` = `spec.sources`), plus a `revision` that is the revision resolved for the request, and the
`operation` stays on the Application until it completes (read in the v3.5.1 source, `server/application/application.go`
`Sync` and `controller/appcontroller.go` `autoSync`). So the policy

- judges an operation only when THIS request sets or changes it (`oldObject` has none, or a different one). An operation
  that merely rides along on another write is not judged: the releaser patching the root while an autosync is Running
  (its `source` is the OLD `spec.source`), a terminate, a refresh, an admin annotating an Application mid-sync;
- treats the operation as a plain sync, not an override, when `source` equals `spec.source` (`sources` equal
  `spec.sources`), there are no `manifests`, and `revision` is empty or equals the Application's `targetRevision`;
  `revisions` are empty or equal the sources' `targetRevision`s. Nothing is read from the old object's `status`: the
  Application CRD has no status subresource, so anyone can write `status.sync.revision`. The consequence is that a
  plain argocd-server sync is accepted only for an Application whose `targetRevision` is what argocd-server writes as
  the revision: a 40-hex SHA (every gitops child after the cutover, the lint enforces it) or an exact chart version
  (every `profile-plugin-*` app). A branch-following Application would get the resolved SHA written and is denied
  (Deny) or warned (Warn) on a UI or CLI sync. The guard is therefore enabled only after the cutover (release step 4);
  the Warn to Deny gate ("no unexpected guard warnings") must not be passed while a child still follows a branch;
- denies anything else: a foreign `revision` (`argocd app sync --revision <branch>`), its own `source` / `sources`
  with another `targetRevision` or path (an override, which is what a rollback operation carries), or any
  `operation.sync.manifests` (the controller deploys them as given; `argocd app sync --local` writes them).

The same expressions are used in the `relevant-change` matchCondition (so an allowed operation never reaches the
binding, in Warn mode too: no warning, the apiserver warn counter does not move) and in the variables `opChanged` /
`opPlain`, rule (b). The identity does not matter for the operation rule: the UI Sync is allowed for whoever clicks it (on a pinned Application).

### Rules, for everything else

- (a) the requester is `staging-releaser`, or break-glass is open;
- (b) an `operation` that this request sets or changes must be a plain sync of the Application's own spec (see
  "Operations" above): no foreign `revision(s)`, no `source` / `sources` of its own, no `manifests`, unless break-glass;
- a change of the root's `teknoir.org/release` or `teknoir.org/previous-release` annotation is evaluated like any
  other write: only the releaser (rule (c) then applies) or break-glass may do it, because `staging-release` and
  `staging-status` read the live tag from them;
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
  namespace teardown. Section 2b runs ArgoCD v3.5.1's operation shapes (server plain sync, multi-source targets, an
  autosync operation Running while the releaser patches the root, terminate and refresh during a running operation,
  foreign revisions, overriding sources, `manifests`, a forged `status.sync.revision`, the root's release annotations)
  in Deny mode, and again in Warn mode, where the allowed cases must leave the apiserver warn counter
  (`apiserver_validating_admission_policy_check_total`) unchanged. Plain syncs and terminates are also sent as a FULL
  `kubectl replace` of the object after ArgoCD's Go round trip (what argocd-server really writes), including an app
  that stores `sources: []` (denied: the round trip changes spec, which is why the templates must not render it).
  Every verdict uses `--dry-run=server`; the script refuses any context that is not `k3d-*` or `kind-*`.
- `charts/release-guard/tests/k3d-argocd-real-test.sh`: the same guard against a REAL ArgoCD v3.5.1 installed from the
  upstream manifest on `k3d-teknoir-dev` (namespace `teknoir-system`, the namespace and service accounts the chart's
  default `identities` name; `NS=` and the `identities` values select another), with test Applications that mirror
  our children (pinned SHA, single source, `group` omitted, automated prune + selfHeal, a Helm chart at an exact
  version) served from an in-cluster git daemon and Helm repo. In Deny it runs the real tools and requires success for
  `argocd app sync`, `argocd app terminate-op`, the UI's REST sync and terminate through argocd-server (login,
  `POST /api/v1/applications/<n>/sync`, `DELETE .../operation`), `argocd --core app sync`, refresh, selfHeal and the
  autosync of a new commit on a branch-following app; and refusal for `argocd app set --revision` (`--core` as the kube
  admin and through the server), `argocd app sync --revision <other|branch>`, `argocd app sync --local` (manifests),
  a hand `kubectl patch` of the root spec and of a manifests override, the release annotation by hand, `argocd app
  create` / `delete`, `kubectl delete` of the root and, as the documented limit, a sync of a branch-following app.
  In Warn it repeats the allowed cases (the apiserver warn counter must not move) and the denied ones (it must move).
  It installs ArgoCD and tears everything down again (`KEEP=1` leaves it running; the CRDs that existed are kept);
  `CHART=<dir>` runs it against another copy of the chart (a negative control: against the chart of the previous
  round, the `--local` manifests sync, the manifests patch, the release annotation change and the branch sync pass
  unchallenged).
- `scripts/tests/run.sh` runs all of the above; `K3D=1` adds the two k3d scripts.
