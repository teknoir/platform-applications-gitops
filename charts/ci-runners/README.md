# ci-runners

The cluster-side half of CI on the dev-host CI cluster `devhost-ci` (single-node k3s v1.34, pod CIDR
10.52.0.0/16, service CIDR 10.53.0.0/16). It is the design of `plans/cicd/proposal-v4.md` section 5: self-hosted
GitHub Actions runners from Actions Runner Controller (ARC) 0.15.1, a rootless BuildKit daemon, and the policies
that keep CI from reaching the LAN or starving an agent session.

Nothing on staging renders this chart; it is installed by hand on `devhost-ci` until v4 step P6.3 moves it under
ArgoCD on r415.

## What lives where

- This chart (`templates/`): the three namespaces, the low PriorityClass, the memory quotas and LimitRange, the
  NetworkPolicies (deny by exception), the push-guard ConfigMap, the `ci-cache-*` PersistentVolumes and
  PersistentVolumeClaims, and the `buildkitd` Deployment + Service.
- `arc/*.yaml`: plain values files for the two upstream charts. They are **not** dependencies of this chart; each is
  installed as its own Helm release with `-f` (see below).

## Host prerequisites

Created by infra `clusters/devhost-ci/install.sh` on the host, outside Kubernetes:

- `/var/lib/ci-cache/{teknoir-ci,teknoir-land,teknoir-push}` owned by `1001:1001` - mounted at `/cache` by each scale
  set (Go/npm/yarn/tool caches). `arc-runners` enforces baseline PSA, which forbids `hostPath` volumes, so the chart
  backs each dir with a static `ci-cache-<set>` PV (claimRef-bound to a same-name PVC) that the runner pod mounts.
- `/var/lib/buildkit` owned by `1000:1000` - BuildKit state (NVMe).
- QEMU binfmt registered on the host, so ARM64 builds run on x86 images without extra privileges.
- `hostPath` volumes are not covered by `fsGroup`: the ownership above is what lets the runner (UID 1001) and
  buildkitd (UID 1000) write there.

## Bootstrap

All commands take `--kube-context devhost-ci`; the context is `devhost-ci` and is never the default one.

```sh
# 1. namespaces, quota, policies, push guard, cache PV/PVCs, buildkitd
#    The chart creates its own namespaces, so the release record lives in "default"; --take-ownership adopts
#    namespaces that already exist.
helm upgrade --install ci-runners charts/ci-runners -n default --take-ownership --kube-context devhost-ci

# 2. create the hand-made Secrets (see the table below) before the controller and scale sets

# 3. the ARC controller, release name "arc" (the scale sets expect its ServiceAccount)
helm upgrade --install arc -n arc-systems --kube-context devhost-ci \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version 0.15.1 -f charts/ci-runners/arc/controller.yaml

# 4. the three scale sets, each its own release named after the scale set
for s in teknoir-ci teknoir-land teknoir-push; do
  helm upgrade --install "$s" -n arc-runners --kube-context devhost-ci \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --version 0.15.1 -f "charts/ci-runners/arc/$s.yaml"
done
```

### Create the hand-made Secrets

The two Secrets are made by hand and are never committed:

| Secret | Keys |
|---|---|
| `arc-runners/arc-github` | `github_token` (a fine-grained PAT, org runner registration) |
| `arc-runners/harbor-push` | `username`, `password` (Harbor push robot for `harbor.teknoir.cloud`) |

Create them after step 1 (the namespace exists) and before steps 3-4. `arc-github` is referenced by every scale
set; `harbor-push` only by `teknoir-push`, whose pod fails to start (`optional: false`) if it is missing - a
teknoir-push pod without `harbor-push` stays in `CreateContainerConfigError` and holds a runner slot.

## Labels and what each may run

`runs-on:` is the scale-set name.

| Label | min/max | May run |
|---|---|---|
| `teknoir-ci` | 1/3 | PR jobs: `test.yml` (`scripts/test`, `make test`, lint). No secrets. |
| `teknoir-land` | 1/2 | `land.yml` only. No secrets. |
| `teknoir-push` | 0/2 | `image.yml` and chart publish, on `refs/heads/main` only. |

**Push guard.** GitHub Free has one runner group, so any workflow can name any label. The `teknoir-push` runner
sets `ACTIONS_RUNNER_HOOK_JOB_STARTED=/hooks/push-guard.sh`, mounted read-only from the `push-guard` ConfigMap. The
runner runs it as the first step of every job. A failed hook alone does **not** stop later steps with `if: always()`
or action `pre:` steps, and those would see the Harbor credential, so on refusal the hook kills its parent
(`Runner.Worker`), which ends the job before any workflow step runs:

- `push`, `workflow_dispatch` or `schedule` on `refs/heads/main`: allowed (`exit 0`).
- Everything else, including any other branch or a tag: the runner is killed before a step runs.

Tags are refused because a `v*` tag can point at an unmerged commit in a private repo (no tag protection on Free).
Release tags for private repos re-tag a digest that was already built on `main` (done later by a `main` job); they
never build on the tag itself.

The Harbor credential and the Harbor/buildkitd egress exist only on `teknoir-push`; every other runner pod can
reach the internet but not `10/8`, `172.16/12`, `192.168/16`, `169.254/16` or the public IP of the office line
(`values.yaml: deniedCidrs`).

**Release names.** The `ci-runners` NetworkPolicies select `actions.github.com/scale-set-name=<set>`, which ARC sets
to the AutoscalingRunnerSet name, i.e. the Helm release name. Each scale-set release MUST therefore keep its own
name (`teknoir-ci`, `teknoir-land`, `teknoir-push`), or the policy selects no pods.

## Known limits

- **Rootless BuildKit has no process sandbox.** buildkitd runs with `--oci-worker-no-process-sandbox`, so a build
  step shares the daemon's PID namespace and could ptrace it or reach other builds' cache. Only `main`-branch jobs
  reach buildkitd (the push guard), so the exposure is merged code and its dependencies.
- **buildkitd speaks plain TCP.** NetworkPolicy limits pod traffic to `teknoir-push` pods, but processes on the host
  itself can reach it. TLS is a later step.
- **kube-router exempts node-local ports and ICMP.** Pods can reach node-local ports 30000-32767 and send ICMP
  regardless of policy; nothing listens there today. A host iptables `DROP` for 10.52.0.0/16 to local
  30000-32767 is a later step.

## Tests

`helm unittest charts/ci-runners` (tests/ is chart-internal, so it lands with the chart):

```sh
helm unittest charts/ci-runners
```

## Later

From v4 step P6.3, ArgoCD on r415 manages these objects (an app-of-apps Application with destination `devhost-ci`,
ServerSideApply for the ARC CRDs) instead of hand-run `helm upgrade`. This chart and `arc/*.yaml` stay the source.
