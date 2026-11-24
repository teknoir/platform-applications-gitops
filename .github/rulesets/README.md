# .github/rulesets — the repository rulesets, as code

Two GitHub rulesets, in the GitHub REST create-payload format (`name`, `target`, `enforcement`, `conditions`,
`rules`, `bypass_actors`):

| file | ruleset | what it protects |
|---|---|---|
| `main.json` | `main` | the default branch: every change arrives as a pull request (squash only), the five required checks of `.github/workflows/ci.yml` (`render`, `helm-unittest`, `check-pins`, `kubeconform`, `scripts-tests`) pass, no force-push, no deletion |
| `verified-tags.json` | `verified-tags` | `refs/tags/verified/*` (the tags Kargo's `staging-verified` stage creates): no deletion, no update, no force-push |

`bypass_actors` is empty in both: break-glass is a deliberate, separate decision, never a standing bypass.

## Who applies them

**P5.1 applies them** (plan P5.1 step 5), by `PUT`/`POST` against the REST API in the payload form above — nothing in
P4.2 creates or changes a live ruleset. Until then the files are only the intended state, and `watch.py` reports a
missing live ruleset as drift.

## Who compares them

`scripts/watch.py` (check 3, run by `.github/workflows/watch.yml` every 15 minutes once `vars.STAGING_WATCH` is
`'true'`) looks every live ruleset up by `name` (`gh api repos/{owner}/{repo}/rulesets`, then
`…/rulesets/{id}`) and compares it with these files. A ruleset that is missing live, or differs, opens one
`ruleset-drift` issue naming it; the issue closes again when the live ruleset matches.

The comparison ignores what GitHub generates or fills with defaults, none of which says anything about intent:

- `id`, `node_id`, `_links`, `created_at`, `updated_at`, `source`, `source_type`, `current_user_can_bypass`;
- `bypass_actors` (identical to the payload's empty list, and break-glass is not drift);
- every rule parameter the repository file does not declare for that rule type (GitHub fills in schema defaults
  such as `dismissal_restriction` or `do_not_enforce_on_create`); a parameter the file declares is compared.

Everything else — `enforcement`, `target`, the ref globs, every rule and its parameters — must match exactly. To
change a live ruleset, change the file here first and let P5.1's apply step (or its documented manual procedure)
carry it over; the watch then closes the drift issue.

`rulesets/*.json` is also where the check names live: the `required_status_checks` contexts must be exactly the
job `name:`s of `.github/workflows/ci.yml`, all from GitHub Actions (`integration_id: 15368`). Rename a job there and
the drift issue is the reminder to change it here.
