# charts/kargo-config

The Kargo objects of the staging pipeline (CI/CD v4 P4.2, `plans/cicd/v4/p42-spec.md` section 4):
the cluster-scoped `Project` `platform` and its `ProjectConfig`, the Warehouses, the Stages
`staging`, `staging-verified` and one `pin-<group>` per enabled image group, and the verification
`AnalysisTemplate`s. The chart is rendered by the Application `kargo-config`
(`charts/app-of-apps/templates/kargo.yaml`), which renders only on `teknoir-cloud` with
`argoRollouts.enabled`, `kargo.enabled` and its own `kargo.config.enabled`, so nothing here is live
until those values are turned on.

## What each template renders

| template | objects |
|---|---|
| `namespace.yaml` | Namespace `platform`, labelled `kargo.akuity.io/project: "true"`, `Prune=false,Delete=false` and `kargo.akuity.io/keep-namespace: "true"` (it holds hand-piped Secrets) |
| `harbor-read.yaml` | Secret `platform/harbor-read` (empty; harbor-config fills it, robot `kargo`), plus the Role and RoleBinding that let `teknoir-system/harbor-config` get/update/patch that one Secret |
| `project.yaml` | `Project` `platform` (with `kargo.akuity.io/keep-namespace: "true"`: deleting it does not delete the namespace); `ProjectConfig` `platform` with one promotion policy per Stage, all auto-promotions off by default |
| `warehouses.yaml` | `gitops-main` (when enabled) and one `img-<group>` Warehouse per enabled group of `scripts/images.yaml`; image subscriptions accept only the CI's immutable `sha-<8>` tags |
| `stage-staging.yaml` | Stage `staging`: `argocd-update` of the root Application to the Freight commit, verification with `revision-check` (plus `browser` / `prometheus-soak` when configured) |
| `stage-staging-verified.yaml` | Stage `staging-verified`: tags the commit the `staging` Stage verified (`verified/<stamp>`), the provenance `scripts/watch.py` reads |
| `stage-pins.yaml`, `_pin-steps.tpl` | One Stage `pin-<group>` per enabled group: rewrite every image's key, commit, push a branch, open a PR and merge it. One `yaml-update` step per target file, in order of first appearance (alias `update`, `update2`, `update3`, ...): an image's `files` when set, else `pins/<group>.yaml`. When the Freight's images are already pinned the commit step is Skipped, and push, PR and merge are skipped too (the Promotion succeeds, no branch, no PR) |
| `analysis-revision-check.yaml` | ServiceAccount, Role and RoleBinding, the script ConfigMap and the `revision-check` AnalysisTemplate |
| `analysis-browser.yaml` | `browser` AnalysisTemplate (only when `verification.browser.image` is set) |
| `analysis-soak.yaml` | `prometheus-soak` AnalysisTemplate (only when `verification.prometheus.address` is set) |

## Values that matter

- `groups` is the image table of `scripts/images.yaml`, in its order; `scripts/tests/test_images_yaml.py`
  asserts the two are equal. Every group has a promotion policy; only an `enabled` group gets a
  Warehouse and a pin Stage. `sameCommit` groups create Freight only when every image carries the
  same tag.
- An image may set `files`: the repository-relative files its pin is written to, each holding the image's
  `key` (the pin Stage then renders one `yaml-update` step per file). Without it the pin goes to
  `pins/<group>.yaml`. Group `ci-runner` uses this: its one image is pinned at `template.spec.containers.0.image`
  in the three ARC scale-set values files (`charts/ci-runners/arc/teknoir-{ci,land,push}.yaml`), so it has no
  `pins/ci-runner.yaml`. A digit key segment indexes a list item (`template.spec.containers.0.image`); Kargo's
  `yaml-update` handles any YAML shape, while `scripts/pin-image` reads only a list indented under its key whose
  pinned key is not on the item's `- ` line. The group is on and auto-promoted since the first `sha-<8>` build
  of `ghcr.io/teknoir/ci-runner` (2026-11-25, P6.4).
- `pinStages.enabled: false` renders the staging Stages only (the drill).
- `staging.setReleaseParam` sets the root Application's Helm parameter `release` besides its
  targetRevision. `argocd-update` has no dedicated Helm-parameter field in Kargo 1.12.6; its
  `sources[].helm.images[]` entries are plain Helm parameters (`key`/`value`), which is what the
  template uses.
- `verifiedTagStamp`: `time` (`verified/<UTC 20060102T150405Z>-<sha8>`) or `none`
  (`verified/<sha8>`).
- `verification.*`: empty `browser.image` and empty `prometheus.address` render no such metric;
  `excludeApps` and `devhostCiServer` are what the revision check skips (see below).
  `verification.pluginConfigMap.name` is the one ConfigMap the revision-check Role may read, and the value the
  script gets as `PLUGIN_CONFIGMAP`. `verification.pluginMinApps` (env `PLUGIN_MIN_APPS`, default 1) is the
  fewest profile-plugin Applications the check must find: fewer fails the promotion (staging runs 8; 0 would let
  a plugin set that vanished pass silently). A cluster that legitimately has no plugin Applications (a rehearsal)
  sets it to 0. A Prometheus address must be reachable without mTLS:
  `teknoir-system` is STRICT mTLS and the Argo Rollouts controller (which runs the soak metric) has no sidecar.

## Turning it off: two releases

Kargo does not delete a Project's namespace while the Project still has finalizers; removing `kargo-config` and
`kargo` in the same release deletes the controller that would clear them, and the namespace (with its Secrets)
stays Terminating. Turn it off in this order, one staging release each:

1. `kargo.config.enabled: false` — the Kargo controller removes its finalizers from `Project` and `Namespace`
   `platform` (and from `ProjectConfig`); `charts/kargo-config`'s objects are pruned while Kargo still runs.
2. `kargo.enabled: false` — the `kargo` Application (and with it Kargo) is removed.
3. `argoRollouts.enabled: false` — last, and only once nothing verifies any more.

`Project` `platform` and `Namespace` `platform` carry `kargo.akuity.io/keep-namespace: "true"`, and the
Namespace also `argocd.argoproj.io/sync-options: Prune=false,Delete=false`: the hand-piped Secrets (the git PAT,
the staging test user) and the `harbor-read` Secret survive all of it.

## Kargo and Argo Rollouts syntax

Kargo expressions (`${{ commitFrom("…").ID }}`, `${{ outputs.stamp.tag }}`) and Argo Rollouts
placeholders (`{{args.revision}}`) must reach the objects literally. Helm would parse `{{`, so no
template writes one directly: every expression comes from a helper in `templates/_helpers.tpl` that
`printf`s it. The helm unittest suites assert both literals in the rendered output.

## Pins file comments

Kargo's `yaml-update` rewrites a pinned line unquoted and drops any trailing comment on it, so
comments in `pins/*.yaml` go on their own lines above the key, never at the end of a value line.

## Verification (`files/revision-check.sh`)

The Job polls every 15 s for up to 8 minutes and exits 0 only when the root Application is Synced at
the promoted revision, every child Application listed in it exists and is Synced and Healthy at that
revision (sources of other repositories and Helm charts are not revision-checked; a child whose
destination server is `devhostCiServer` is revision-checked only, and a wrong or missing revision there is a
`WARN` line instead of a failure while the Application is not comparable - sync `Unknown` or a
`ComparisonError` condition, i.e. the dev host is down - so it never stalls a staging promotion), and the
`profile-plugin-*` Applications in `teknoir-system` are current. Otherwise it prints one line per failing
Application and exits 1; on success it adds one summary line (`rule 4: N profile-plugin Applications at chart
<version>` or `rule 5: N profile-plugin Applications at <revision>`).

The plugin rule is mode-aware, decided by the live `profile-controller-config` ConfigMap:

- **Chart mode** (no `PLUGIN_GIT_REPO_URL`): each selected Application's `spec.source.chart` starts with
  `profile-plugin-`, its `targetRevision` equals `PLUGIN_CHART_VERSION`, and it is Synced and Healthy. A
  selected Application with a git source (`spec.source.path`) is a failure: the plugins have moved on.
- **Git mode** (CI v4 P9.1; non-empty `PLUGIN_GIT_REPO_URL`, which must be this repository): the plugin charts
  live in this repository under `PLUGIN_GIT_PATH` (default `plugins/charts`), so each selected Application is
  one source of this repository (no chart) with `spec.source.path ==
  <PLUGIN_GIT_PATH>/profile-plugin-<x>`, `targetRevision`, `status.sync.revision` (missing counts as
  `<none>`), sync `Synced` and health `Healthy` at the promoted revision.

An Application is selected when `spec.source.chart` or `spec.source.path` (or any `spec.sources[]` entry) is
`profile-plugin-*`; names in `excludeApps` are skipped. The ConfigMap is read only when at least one is
selected, and fewer than `pluginMinApps` selected fails the check.
`scripts/tests/test_revision_check.py` runs it against a fake `kubectl`.

The root Application must carry `kargo.akuity.io/authorized-stage: "platform:staging"`; Kargo refuses
to update an Application without it. On r415 that Application is rendered by infra
`scripts/staging-root.sh`.

## Rehearsal (P4.3)

- `values-rehearsal.yaml`: branch `rehearsal/kargo`, pin prefix `kargo/rehearsal`, tag prefix
  `rehearsal/verified/` — a full rehearsal never touches `main` or the real `kargo/promotion/*` branches.
- `values-drill.yaml`: branch `rehearsal/drill`, tag prefix `rehearsal/verified/`, no pin Stages.
- `rehearsal/root.yaml`: the root Application of the k3d rehearsal cluster (model of the r415 root),
  with the authorized-stage annotation.

## Tests

    helm unittest charts/kargo-config
    python3 -m unittest discover -s scripts/tests -p 'test_kargo_config.py'   # validates step configs
