# Staging release tooling

Design: `plans/staging-releases.md` (workspace). Staging (`vpro`, branch `teknoir-cloud`) runs only the commit of the
live `staging-YYYYMMDD.N` release, held as `targetRevision` of the hand-applied root Application `app-of-apps`.
Merging to `teknoir-cloud` queues a change; it is not live until a release.

| Script | What |
|---|---|
| `staging-release` | dry run (default), `--yes SHA`, `--rollback`, `--verified TAG`, `--break-glass-begin/-end`, `--bootstrap`. `--help` has the details |
| `staging-status` | where staging is and what is pending; read-only. `--devices` adds device-side revisions |
| `staging-render.sh` | renders a release like ArgoCD (root, children, profile-plugin charts); cached |
| `check-pins.py` | the release lint over the rendered manifests; `release-policy.yaml` holds its rules and the dated exceptions |
| `pin-image` | pins a Teknoir-built image as `tag@sha256:digest` (`images.tsv` lists them all); `--adopt-running` |
| `stagelib.py` | shared logic (tag numbering, candidate validation, plan, lease, convergence) |
| `tests/` | `tests/run.sh` runs everything below |

```
scripts/staging-release                       # dry run: pending commits, diff, lint, plan (valid 30 min)
scripts/staging-release --yes <sha> --by <session> --reason "<why>"
# browser check (CLAUDE.md), then
scripts/staging-release --verified staging-YYYYMMDD.N
scripts/staging-release --rollback            # newest verified earlier release; add --yes <target sha> to apply
```

Cutover (once): `scripts/staging-release --bootstrap` (the dry run must show no workload diff), then
`--bootstrap --yes <sha>`.

## Guards

Context exactly `vpro` (names with online|eks|prod are refused); the candidate is a first-parent commit of
`origin/teknoir-cloud` that descends from the live release; `--yes` equals the dry-run SHA and the plan is fresh and
live has not moved; the Lease `teknoir-system/staging-release-lock` is held from apply to converged; an existing tag is
refused (push rejection retries with N+1); children must be converged on live (rollback and a re-run of the live SHA are
exempt); removing Applications needs `--allow-remove`; the lint, `helm unittest charts/app-of-apps`, kubeconform and
`crane manifest` of every `@sha256` image must pass.

## Notes for operators

- The dry run is read-only on the cluster (`kubectl get` only); the only writes are `git fetch`, the worktrees and the
  render cache under `~/.cache/staging-release/`.
- `release-policy.yaml`: `images: warn` until the plugin pins are done (rollout step 8), then `deny`. The backstage-next
  `:nextgen` exceptions expire 2026-11-30 (the planned Nextgen cut-over): extend the date in a reviewed PR or pin the image.
  `rollback_floor` stays empty until the first release with the guard (release 2) exists.
- Images that are not in `images.tsv` because they are not in this repo: the teamspace plugin images
  (profile-plugins-helm chart defaults) and `devstudio-configure-devices` (rendered by the controllers).
- Needs: kubectl, helm (+ the unittest plugin), git, crane, gh, kubeconform, dyff, curl, python3 + PyYAML.
