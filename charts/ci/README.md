# ci: CI/CD on the cluster (Argo Workflows + BuildKit + Harbor)

Replaces GitHub Actions for the teknoir repos (Actions minutes ran out in 2026-10).
Staging only (teknoir-cloud, r415), gated in `charts/app-of-apps/templates/ci.yaml`.
Plan and decisions: `~/git/ai/plans/ci-argo-workflows.md`.

```
CronWorkflow ci-poll (every 2 min, files/poll.py)
  lists branch/tag heads of every registered repo (conditional requests, 304 = free)
  -> new commit: Workflow from WorkflowTemplate ci-dispatch (repo, ref, sha, before)
       plan   files/plan.py + files/repos/<repo>.yaml -> tests / images / chart release
       tests  any toolchain image, repo cloned at sha, only on the CI node (vpro)
       images buildctl -> buildkitd-vpro (default) or buildkitd-r415 (fallback)
              -> harbor.teknoir.cloud/teknoir/<name> + ghcr.io/teknoir/<name>, same tags
       charts helm/chart-releaser-action's own cr.sh (pinned): GitHub release + gh-pages index
       GitHub commit status "teknoir-ci" (link to the run) + "teknoir-ci/image/<name>" = digest
CronWorkflow ci-github-sync (30 min): disables the Actions workflows a repo's config replaces
```

Nothing listens on the internet: there are no webhooks. The UI is
`https://ci.teknoir.cloud` behind the normal edge login.

## Adding or changing a repo's pipeline

One file per repo in `files/repos/<repo>.yaml` (defaults in `values.yaml` `pipelines`).
Merge to `teknoir-cloud`; the next poll uses it. A newly registered repo is only
recorded on its first poll (nothing is rebuilt); its next push builds.

```yaml
branches: ['**']            # GitHub-style globs (* within a segment, ** across); default all
branchesIgnore: []
tags: ['v*']                # tag pushes to build; default none
builder: vpro               # vpro | r415 (the other one is the fallback)
ghcr: true                  # also push to ghcr.io/teknoir/<name> (prod, devices, airgap bundle)
githubActions: disable      # keep | disable | enable the Actions files in actionsWorkflows
actionsWorkflows: [build.yml]
tests:                      # run before any image or chart job; a failure stops the pipeline
  - name: test
    image: docker.io/library/golang:1.26
    run: go test ./...      # sh -e (shell: bash to change), in workdir (default .)
    memory: 2Gi             # cpu: 500m
    # No Docker daemon (dind): it would give repo code root on the node and every pod
    # credential there. Image smoke tests that need `docker run` are not supported yet.
images:
  - name: deadend           # -> harbor.teknoir.cloud/teknoir/deadend, ghcr.io/teknoir/deadend
    context: .              # dockerfile: <context>/Dockerfile
    platforms: [linux/amd64]  # arm64 / arm/v7 via qemu binfmt on the builder nodes
    target: ""
    buildArgs: {VERSION: "{ref}-{sha7}"}
    tagBuildArgs: {}        # overrides for tag pushes
    preBuild: ""            # shell run in the checkout before the build (e.g. placeholders)
    paths: []               # build only when a changed file matches (new branch: always)
    branches: [main]        # narrower than the repo's branches
    tagTemplates: ["{branch}-{ts}", "{branch}", "sha-{sha8}"]  # default
    tagTagTemplates: ["{tag}"]                                  # default, tag pushes
    latest: [main, master]  # branches that also move :latest ([] = never)
    versionFile: ""         # file whose content is {version}
    lfs: false
    submodules: false
helm:                       # chart-releaser, as helm/chart-releaser-action
  release: [main]           # branches that release
  beta: [beta]              # branches that release X.Y.Z-pre versions
  betaVersionCheck: true
  chartsDir: charts
  crAction: v1.6.0          # chart-releaser-action version whose cr.sh runs (sha256 pinned in values)
```

Template variables: `{branch} {tag} {ref} {sha} {sha8} {sha7} {ts} {repo} {version}`
(`{ref}` is the branch or tag name, sanitized for tags).

## Secrets

| Secret (teknoir-ci) | What | Made by |
|---|---|---|
| `github-ci` | `username`, `token`: classic PAT with `repo` + `write:packages` (clone, commit statuses, chart releases, ghcr push, polling) | by hand, below |
| `harbor-ci-robot` | Harbor robot `robot$ci` (push teknoir, pull proxy caches), dockerconfigjson + username/password | charts/harbor `harbor-config` (hourly; delete it to rotate) |
| `ci-admin.service-account-token` | token for the UI/CLI | Kubernetes |

Create or rotate the GitHub token (never printed):

```sh
gh auth token | kubectl --context r415 -n teknoir-ci create secret generic github-ci \
  --from-literal=username=tekn0ir --from-file=token=/dev/stdin --dry-run=client -o yaml |
  kubectl --context r415 apply --server-side -f -
```

Replace it with a GitHub App (git, statuses) plus a machine user's `write:packages` PAT
(ghcr does not accept App tokens) when there is time.

## UI token

```sh
kubectl --context r415 -n teknoir-ci get secret ci-admin.service-account-token \
  -o jsonpath='{.data.token}' | base64 -d   # paste as "Bearer <token>" at https://ci.teknoir.cloud
```

## Run a pipeline by hand

```sh
argo --context r415 -n teknoir-ci submit --from workflowtemplate/ci-dispatch \
  -p repo=deadend -p ref=refs/heads/master -p sha=$(git -C deadend rev-parse HEAD)
```

or `kubectl create` a Workflow with `workflowTemplateRef: {name: ci-dispatch}`.

## Retention

- Workflows: deleted 3 days after success, 7 days after failure; successful pods after
  1 hour (failed pods, and so their logs, live as long as the workflow). No artifact
  repository: logs live only in pods. Polls: 5 minutes.
- BuildKit cache: per-builder GC (`builders.*`: maxUsedSpace, minFreeSpace, reservedSpace).
- Harbor: tag retention + quotas + weekly GC (charts/harbor `harborConfig`).
- Nodes: kubelet image GC (unused images after 14 days, 75 % / 60 % thresholds), journald
  caps (host config, see the plan).

## Nodes

- `vpro` (192.168.2.19): k3s agent of r415, label `teknoir.org/ci-builder=true`, role
  `ci-builder`, taint `teknoir.org/ci=true:NoSchedule` (only CI pods and DaemonSets run
  there). buildkitd cache `/var/lib/buildkit`. Workflow pods prefer it.
- `r415`: buildkitd cache on the SSD `/srv/buildkit`.
