# plugins/charts: the profile plugin charts, in git

One chart per teamspace plugin (`profile-plugin-<x>`). profile-controller renders one ArgoCD Application per
teamspace plugin from these charts.

## Where they are rendered from

- **Today (until the CI v4 P9.1 switch):** still from the published chart repository
  `https://teknoir.github.io/profile-plugins-helm` at `pluginChartVersion` (0.0.113-p2, the
  `PLUGIN_CHART_VERSION` key of the `profile-controller-config` ConfigMap). The charts in this directory are not
  deployed from yet, and nothing here has to match what production runs.
- **The published repository stays frozen at 0.0.113-p2.** Production pulls its plugin charts at 0.0.99 from the
  same repository, so it must keep serving every published version: never republish, retag or delete an entry there
  now that this directory exists.
- **After the switch:** profile-controller renders the plugin Application from this path at the release
  (the verified gitops revision Kargo promotes), and `profile-plugins-helm` only serves production's frozen 0.0.99.
- `scripts/staging-render.sh --plugins auto` follows the same switch: the tree mode once the rendered
  `profile-controller-config` ConfigMap carries a non-empty `PLUGIN_GIT_REPO_URL`, the chart repository until then.

## Tests in CI

CI covers these charts from day one even though nothing deploys from them:

- `scripts/ci/helm-unittest.sh` runs `helm unittest` on every `plugins/charts/*/tests` that has a `*_test.yaml`
  (emqx, jwks, observatory), then `plugins/charts/profile-plugin-emqx/tests/acl-check.sh --check` (the MQTT ACL file:
  rule order, the TeknoirBot `tb-` fence, no allow-all; no docker). The `k3d-*.sh` and `*-e2e.sh` scripts there need a
  cluster and a docker image and never run in CI.
- `.github/workflows/ci.yml` renders with `--plugins tree`: every chart of this directory is rendered offline, then
  linted by `scripts/check-pins.py` (including its `chart-dependency-range` check over `plugins/charts/*/Chart.yaml`)
  and validated by `scripts/ci/kubeconform.sh`.
- `scripts/tests/test_plugin_charts.py` holds the invariants below (the version lockstep, the vendored dependency,
  the git-ignore exceptions, the chart set).

## Changing a chart or a plugin image

1. A pull request to this repository, changing the chart here (templates, values, `tests/`). CI renders and lints it.
2. **Never bump `version:` in a `Chart.yaml`.** Every chart stays at `0.0.113-p2`, in lockstep: that is the version
   profile-controller asks the published repository for, so a local version would only make this copy and the
   published one differ in a field nothing reads. A plugin change ships as a new gitops revision, not as a new chart
   version. (`scripts/tests/test_plugin_charts.py` fails on a bump.)
3. Merge to `main`: Kargo promotes the commit and verifies it (staging), so the change reaches a teamspace with the
   same release as the rest of the platform. A rollback is a revert PR.
4. A plugin **image** is a value in the chart (`image.registry`/`image.version` per plugin) or a Kargo pin
   (`pins/<group>.yaml`, written by Kargo, never by hand): a first-party image must be `repo:<tag>@sha256:<digest>`
   because `release-policy.yaml` has `images: deny`, and CI's check-pins fails without it.

The chart's own `README.md` (e.g. `profile-plugin-emqx/README.md`) documents behaviour and rollout order; this file
covers the directory only.

## The emqx dependency is vendored

`profile-plugin-emqx` depends on the upstream `emqx` 5.8.9 chart. Its `Chart.lock` and `charts/emqx-5.8.9.tgz` are
committed (the same pattern as `charts/stunner`; `.gitignore`'s `/*/**/charts/*` ignores every other dependency
archive), so:

- a render, a `helm unittest` and the ACL check need no network and no `repos.emqx.io`;
  `scripts/ci/helm-repos.sh` adds no repository for this chart, and `helm dependency list` reports `ok`, so
  `scripts/ci/helm-unittest.sh` does not build it;
- the subchart content is pinned by the committed archive, not by whatever the upstream repository serves later.

To update it, in the chart directory:

```sh
cd plugins/charts/profile-plugin-emqx
helm dependency update          # rewrites Chart.lock and fetches emqx-<version>.tgz into charts/
git add Chart.lock charts/emqx-*.tgz
```

Commit the lock **and** the archive together: the `Chart.yaml` bump (an exact version, never a range — check-pins
fails on one), the lock and the archive must agree, or the render picks up a different subchart than the lock names.
Remove the old archive in the same commit. Read `profile-plugin-emqx/README.md` (dashboard, ACL, retained messages)
before an EMQX upgrade: the dashboard proxy's `teknoir-sso.js` depends on the dashboard UI internals of the pinned
version, and `tests/dashboard-proxy-e2e.sh` must be run by hand against the new image.

## History

Imported from `teknoir/profile-plugins-helm` with `git subtree` at `edea9a9` (its `charts/` directory → this path,
`git-subtree-dir: plugins/charts`, `git-subtree-split: ff0530c`), then the emqx dependency vendored. History before
that import lives in `profile-plugins-helm`.
