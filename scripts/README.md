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
| `pin-image` | pins a Teknoir-built image as `tag@sha256:digest` (`images.tsv` lists them all); `--adopt-running`. A changed `wg-hub` tag resets `hub.image.leaderElection` to false (render stops); `--leader-election` confirms an image with leader election |
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

Context exactly `vpro` (names with online|eks|prod are refused); the tag is `staging-YYYYMMDD.N`
(`^staging-[0-9]{8}\.[1-9][0-9]*$`, the same expression as the guard policy); the candidate is a first-parent commit of
`origin/teknoir-cloud` that descends from the live release; `--yes` equals the dry-run SHA and the plan is fresh and
live has not moved; the Lease `teknoir-system/staging-release-lock` is held from apply to converged; an existing tag is
refused (push rejection retries with N+1); children must be converged on live (rollback and a re-run of the live SHA are
exempt); removing Applications needs `--allow-remove`; the lint, `helm unittest charts/app-of-apps`, kubeconform and
`crane manifest` of every `@sha256` image must pass.

- **Which tooling decides.** The lint code (`check-pins.py`) and the image policy (`release-policy.yaml`) are those of
  the CANDIDATE commit (its worktree), the rollback floor is read from `origin/teknoir-cloud`.
- **Tooling identity.** The tooling is the tree `git rev-parse HEAD:scripts` of the checkout that runs. `--yes` and
  `--rollback --yes` refuse unless `scripts/` of the checkout is CLEAN (no uncommitted or staged change and no
  untracked file, `__pycache__` aside; a file `git diff` cannot see is still a difference) and that tree equals
  `git rev-parse <candidate>:scripts`. `--rollback --yes` accepts the head of `origin/teknoir-cloud`, the live release or
  the target instead of the candidate. The dry run records the tree (and any dirty paths) in the plan as `tooling`;
  `--yes` refuses a plan whose tooling is not the one it runs. The message names the worktree to run it from.
- **Who applies.** The releaser identity (`staging-releaser`) is used only when the release-guard chart installed it
  (ServiceAccount, RoleBinding, `auth can-i`). Before that (the cutover and release .2, which switches the guard on)
  the release is applied as the operator's own admin identity and the script says `guard not installed: applying as admin`.
- **Portal bindings (backstage-sa).** A render in which a portal service account (`config.portal.serviceAccounts` of
  `charts/profile-controller`) has no `teknoir-admin` ClusterRoleBinding left depends on profile-controller writing the
  RoleBinding `teknoir-portal` into every teamspace. Two guards: (1) the lint (`check-pins.py`, code
  `portal-controller-unchecked`, also a step of `scripts/tests/run.sh`) fails while the pinned profile-controller tag is not
  in `portal_profile_controller_tags` of `release-policy.yaml` (fail closed; list a tag only after checking that its build
  contains the portal commits); (2) when the release diff removes a `<name>-api-teknoir-admin-rolebinding`, the dry run and
  `--yes` (before and under the Lease) read every `profiles.teknoir.org` and the `teknoir-portal` RoleBindings (read-only)
  and refuse unless each teamspace has one with the ClusterRole and service accounts of the candidate's config.
- **Under the Lease** the live release is read again and the plan, the candidate and the convergence guard are checked
  again. At the cutover the convergence guard runs too (the candidate then equals the synced revision).
- **Watching.** Only pods of workloads in the render, or pods (re)started after the patch, count; Argo Workflow pods do
  not; Pending beyond 3 minutes is a failure. Deviation from the design (watch, step 7): the logs of the changed
  controllers are NOT scanned by the script (five Go controllers share no error format; a regex would roll good
  releases back). The success output prints the `kubectl logs` commands for the controllers whose render changed.
- **Release markers** (contract with `teknoir/infra` `staging-root.sh`, matched EXACTLY, nothing is trimmed): a GitHub
  Release is `[rolled back] <tag>` (title starts with `[rolled back] `) and its body has the line `Rolled-Back: true`
  after a rollback; `[not applied] <tag>` with `Not-Applied: true` when the root patch failed after the tag and Release
  were created (the tag stays; it never went live). Either the title prefix or a body line that equals the trailer
  marks it (` [rolled back] x`, `[rolled back]x`, an indented or trailing-space trailer do not); rollback targets, the
  bootstrap pick and `--verified` skip marked releases.
- **A failed root patch** is not taken at its word: the root is read again. Only when neither its release annotation nor
  its `targetRevision` is the new release is the Release marked `[not applied]`. When both are the new ones the apiserver
  did apply it and the watch continues; when the root cannot be read, or only one of them is new, the script reports the
  ambiguity and marks nothing.
- **`--verified`** needs staging converged on the release and a root exactly as the release writes it.
- **`--skip-registry-check`** on the dry run makes the plan unusable for `--yes` unless it is repeated on `--yes`; the
  tag message then says `registry check: SKIPPED`. The tag message also records `guard warn count at release`, the
  baseline `staging-status` uses to report guard warnings since the release.

## Notes for operators

- The dry run is read-only on the cluster (`kubectl get` only); the only writes are `git fetch`, the worktrees and the
  render cache under `~/.cache/staging-release/`.
- `release-policy.yaml`: `images: warn` until the plugin pins are done (rollout step 8), then `deny`. The backstage-next
  `:nextgen` exceptions expire 2026-11-30 (the planned Nextgen cut-over): extend the date in a reviewed PR or pin the image.
  `rollback_floor` stays empty until the first release with the guard (release 2) exists.
- Images that are not in `images.tsv` because they are not in this repo: the teamspace plugin images
  (profile-plugins-helm chart defaults) and `devstudio-configure-devices` (rendered by the controllers).
- Needs: kubectl, helm (+ the unittest plugin), git, crane, gh, kubeconform, dyff, curl, python3 + PyYAML.
