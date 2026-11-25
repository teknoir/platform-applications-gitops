# GitOps tooling

The gitops branch (`main`) is what staging renders. Kargo ships it: a merge to `main` is picked up by
the `staging` Stage, which sets the root Application `app-of-apps` (`targetRevision`, and the helm
parameter `release=$ARGOCD_APP_REVISION`) to that commit, verifies it, and tags `verified/<stamp>-<sha8>`.
Rollback is a revert PR to `main`, which Kargo ships the same way.

| Script | What |
|---|---|
| `staging-render.sh` | renders a release like ArgoCD (root, children with their `helm.valueFiles` and parameters, profile-plugin charts); cached by chart tree and value-file content under `~/.cache/gitops-render` |
| `check-pins.py` | the lint over the rendered manifests (revision, digest pins, CR revisions, round-trip stability); `release-policy.yaml` holds its rules and the dated exceptions |
| `pin-image` | pins a Teknoir-built image as `tag@sha256:digest` in the group's `pins/<group>.yaml` (or the chart values of a third party image; `scripts/images.yaml` lists them all); `--adopt-running`. A `wg-hub` pin changes only the tag (`hub.image.leaderElection` stays true) |
| `watch.py` | the staging watch (`.github/workflows/watch.yml`, every 15 min once `vars.STAGING_WATCH` is `'true'`): an unverified default-branch commit older than 45 min, a `verified/*` tag without `freight=`, and `.github/rulesets/*.json` drifting from the live rulesets, each as one idempotent issue; `--dry-run` prints instead of calling gh |
| `tests/` | `tests/run.sh` runs everything below |

```
scripts/staging-render.sh --tree . --release <sha> --out /path/to/render
python3 scripts/check-pins.py --release <sha> --repo-root . /path/to/render
scripts/pin-image <component>=<tag> --pr        # a merged pin PR is shipped by Kargo
```

## Pins

An image is pinned as `tag@sha256:<digest>`; `scripts/images.yaml` names every image, its group, key path
and file. A grouped component is written to `pins/<group>.yaml`, a third-party one to its chart values.
Groups that Kargo pins (`charts/kargo-config` pin Stages) get their pins as Kargo PRs; the rest, and the
three third-party images, stay with `scripts/pin-image`.

- `release-policy.yaml`: `images: deny` (first-party images must be digest-pinned); an exception is dated
  and fails the lint once it expires. `cr_revisions: deny` (rendered teknoir.org CRs carry a 40-hex commit).
- Images that are not in `scripts/images.yaml` because they are not in this repo: the teamspace plugin
  images (profile-plugins-helm chart defaults) and `devstudio-configure-devices` (rendered by the
  controllers).
- Needs: kubectl, helm (+ the unittest plugin), git, crane, gh, kubeconform, dyff, curl, python3 + PyYAML.
