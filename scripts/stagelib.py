"""Shared logic of the staging release tooling (scripts/staging-release, staging-status, check-pins.py).

Design: plans/staging-releases.md. Python 3 stdlib + PyYAML. The pure functions (tag numbering,
candidate validation, plan validity, root patch, convergence, lease state, rollback target) take plain
data and are unit-tested in scripts/tests/. Everything that touches a cluster, GitHub or git goes
through `Sys` so the tests can replace it.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, field

CONTEXT = "vpro"                      # the only kubectl context these scripts act on
NAMESPACE = "teknoir-system"
ROOT_APP = "app-of-apps"
RELEASER_NAME = "staging-releaser"
RELEASER_SA = f"system:serviceaccount:teknoir-system:{RELEASER_NAME}"
LEASE_NAME = "staging-release-lock"
GITHUB_REPO = "teknoir/platform-applications-gitops"
REPO_URL = "https://github.com/teknoir/platform-applications-gitops"
ROOT_PATH = "charts/app-of-apps"
BRANCH = "origin/teknoir-cloud"
# staging-YYYYMMDD.N: N has no leading zero and is at least 1 (the guard policy uses the same expression).
TAG_RE = re.compile(r"^staging-([0-9]{8})\.([1-9][0-9]*)$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LEASE_SECONDS = 120
STALE_LEASE_SECONDS = 120             # rollback may steal a lease older than this
PLAN_TTL_SECONDS = 30 * 60
# Release markers (contract with infra staging-root.sh / PR teknoir/infra#11, matched EXACTLY, no trimming). A GitHub
# Release is marked by
#   - its TITLE starting with the title mark and a space ("[rolled back] staging-20261017.3"), and
#   - a TRAILER line in its body that equals exactly "Rolled-Back: true" / "Not-Applied: true".
# Either one is enough for a reader; `gh release list` carries only the title, so the title is what the
# selection of rollback targets uses. "rolled back": the release was live and was left by a rollback;
# "not applied": the tag and Release exist but the root patch failed, so it never went live.
ROLLED_BACK_MARK = "[rolled back]"
ROLLED_BACK_TRAILER = "Rolled-Back: true"
NOT_APPLIED_MARK = "[not applied]"
NOT_APPLIED_TRAILER = "Not-Applied: true"
# Tags production pulls too ("Production coupling"): a push to these repos moves production on its next restart.
SHARED_TAGS = ["ghcr.io/teknoir/keycloak-theme:latest", "ghcr.io/teknoir/devstudio-controller:teknoir-cloud",
               "ghcr.io/teknoir/profile-controller:latest"]
ANN_RELEASE = "teknoir.org/release"
ANN_PREVIOUS = "teknoir.org/previous-release"
ANN_BREAK_GLASS = "teknoir.org/break-glass"
NS_GUARD_ANN = "teknoir.org/release-guard"     # on the Namespace; value "break-glass" lifts the guard
NS_GUARD_REASON_ANN = "teknoir.org/release-guard-reason"
NS_GUARD_VALUE = "break-glass"


class Refuse(Exception):
    """A guard refused the action. The message says why and what to do instead."""


# ---------------------------------------------------------------------------------------------
# System access (replaced in tests)
# ---------------------------------------------------------------------------------------------
@dataclass
class Result:
    rc: int
    out: str
    err: str


class Sys:
    """Runs commands. Tests subclass or replace `run`."""

    def run(self, argv: list[str], *, cwd: str | None = None, input: str | None = None,
            check: bool = True, timeout: int | None = None) -> Result:
        p = subprocess.run(argv, cwd=cwd, input=input, capture_output=True, text=True, timeout=timeout)
        if check and p.returncode != 0:
            raise RuntimeError(f"{' '.join(shlex.quote(a) for a in argv)} failed ({p.returncode}): "
                               f"{(p.stderr or p.stdout).strip()[:500]}")
        return Result(p.returncode, p.stdout, p.stderr)

    def now(self) -> dt.datetime:
        return dt.datetime.now(dt.timezone.utc)

    def sleep(self, s: float) -> None:
        time.sleep(s)


# ---------------------------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------------------------
def guard_context(ctx: str) -> str:
    """The kubectl context must be exactly 'vpro' (staging); production names are refused outright."""
    if re.search(r"online|eks|prod", ctx or "", re.I):
        raise Refuse(f"context '{ctx}' looks like production: staging releases never touch it")
    if ctx != CONTEXT:
        raise Refuse(f"context must be exactly '{CONTEXT}', got '{ctx}'")
    return ctx


class Kube:
    """kubectl with --context vpro always set; --as only for the releaser identity."""

    def __init__(self, sys_: Sys, context: str = CONTEXT):
        self.sys = sys_
        self.context = guard_context(context)

    def base(self, as_releaser: bool = False) -> list[str]:
        a = ["kubectl", "--context", self.context]
        if as_releaser:
            a.append(f"--as={RELEASER_SA}")
        return a

    def run(self, args: list[str], *, as_releaser: bool = False, check: bool = True,
            input: str | None = None) -> Result:
        return self.sys.run(self.base(as_releaser) + args, check=check, input=input)

    def get_json(self, args: list[str]) -> dict:
        return json.loads(self.run(["get", *args, "-o", "json"]).out)

    def root(self) -> dict:
        return self.get_json(["-n", NAMESPACE, "application", ROOT_APP])

    def applications(self) -> list[dict]:
        return self.get_json(["-n", NAMESPACE, "applications"]).get("items", [])


# ---------------------------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------------------------
def tag_key(tag: str) -> tuple[str, int]:
    m = TAG_RE.match(tag)
    if not m:
        raise ValueError(f"not a staging tag: {tag}")
    return m.group(1), int(m.group(2))


def next_tag(existing: list[str], today: dt.date) -> str:
    """staging-YYYYMMDD.N: N is the highest existing number of today + 1 (1 if none)."""
    d = today.strftime("%Y%m%d")
    nums = [n for (dd, n) in (tag_key(t) for t in existing if TAG_RE.match(t)) if dd == d]
    return f"staging-{d}.{max(nums, default=0) + 1}"


def tag_at_or_after(tag: str, floor: str) -> bool:
    return tag_key(tag) >= tag_key(floor)


# ---------------------------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------------------------
class Git:
    def __init__(self, sys_: Sys, repo: str):
        self.sys, self.repo = sys_, repo

    def run(self, *args: str, check: bool = True) -> str:
        return self.sys.run(["git", "-C", self.repo, *args], check=check).out.strip()

    def rev(self, ref: str) -> str:
        return self.run("rev-parse", "--verify", f"{ref}^{{commit}}")

    def first_parent(self, ref: str) -> list[str]:
        return self.run("rev-list", "--first-parent", ref).split()

    def is_ancestor(self, a: str, b: str) -> bool:
        return self.sys.run(["git", "-C", self.repo, "merge-base", "--is-ancestor", a, b], check=False).rc == 0

    def tags(self, pattern: str = "staging-*") -> list[str]:
        return [t for t in self.run("tag", "--list", pattern).split() if TAG_RE.match(t)]

    def pending(self, live: str, cand: str) -> list[dict]:
        """First-parent commits live..cand, oldest first, with the PR number and head branch."""
        fmt = "%H%x1f%h%x1f%an%x1f%cI%x1f%s"
        out = self.run("log", "--first-parent", "--reverse", f"--format={fmt}", f"{live}..{cand}")
        res = []
        for line in out.splitlines():
            full, short, author, date, subject = line.split("\x1f", 4)
            res.append({"sha": full, "short": short, "author": author, "date": date,
                        "subject": subject, **parse_pr(subject)})
        return res


def parse_pr(subject: str) -> dict:
    """PR number and head branch from a merge commit ('Merge pull request #63 from org/branch')
    or a squash commit ('title (#64)')."""
    m = re.match(r"Merge pull request #(\d+) from [^/\s]+/(\S+)", subject)
    if m:
        return {"pr": int(m.group(1)), "branch": m.group(2)}
    m = re.search(r"\(#(\d+)\)\s*$", subject)
    if m:
        return {"pr": int(m.group(1)), "branch": ""}
    return {"pr": None, "branch": ""}


def validate_candidate(first_parent_line: list[str], is_ancestor, cand: str, live: str) -> str:
    """A release is a commit on the first-parent history of origin/teknoir-cloud that descends from
    the live release. Returns 'noop' for the live commit itself, 'forward' otherwise."""
    if not SHA_RE.match(cand):
        raise Refuse(f"candidate must be a full 40-hex commit SHA, got '{cand}'")
    if cand not in first_parent_line:
        raise Refuse(f"{cand[:12]} is not on the first-parent history of {BRANCH}. Prefix releases only: "
                     "pick a merge commit of the branch (git log --first-parent), or merge first")
    if cand == live:
        return "noop"
    if not is_ancestor(live, cand):
        raise Refuse(f"{cand[:12]} is older than (or does not descend from) the live release {live[:12]}. "
                     "Use --rollback to go back")
    return "forward"


def validate_rollback_target(target_tag: str, target_sha: str, live_sha: str, is_ancestor, floor: str | None,
                             live_tag: str | None) -> None:
    if not TAG_RE.match(target_tag):
        raise Refuse(f"'{target_tag}' is not a staging-YYYYMMDD.N tag")
    if live_tag and target_tag == live_tag:
        raise Refuse(f"{target_tag} is the live release")
    if not (target_sha == live_sha or is_ancestor(target_sha, live_sha)):
        raise Refuse(f"{target_tag} ({target_sha[:12]}) is not older than the live release; use a normal release")
    if floor and not tag_at_or_after(target_tag, floor):
        raise Refuse(f"{target_tag} is older than the rollback floor {floor} (the first release with the release "
                     "guard and the helper). Going back further is a break-glass action for Anders")


# ---------------------------------------------------------------------------------------------
# Root Application
# ---------------------------------------------------------------------------------------------
def is_cutover_state(root: dict) -> bool:
    """True while the root still follows the branch (before the cutover release)."""
    tr = ((root.get("spec") or {}).get("source") or {}).get("targetRevision", "")
    return not SHA_RE.match(tr or "")


def root_live_sha(root: dict) -> str:
    """The commit the live release is on: targetRevision once pinned, else what the branch-following
    root has synced (status.sync.revision)."""
    tr = ((root.get("spec") or {}).get("source") or {}).get("targetRevision", "")
    if SHA_RE.match(tr or ""):
        return tr
    rev = ((root.get("status") or {}).get("sync") or {}).get("revision", "")
    if not SHA_RE.match(rev or ""):
        raise Refuse("the live root has no synced commit (status.sync.revision); is ArgoCD healthy?")
    return rev


def root_params(root: dict) -> dict:
    ps = (((root.get("spec") or {}).get("source") or {}).get("helm") or {}).get("parameters") or []
    return {p["name"]: p.get("value") for p in ps}


def root_release_name(root: dict) -> str | None:
    return ((root.get("metadata") or {}).get("annotations") or {}).get(ANN_RELEASE) or root_params(root).get("releaseName")


def build_root_patch(sha: str, tag: str, previous: str | None) -> dict:
    """The merge patch only scripts/staging-release applies to the root (rule (c) of the guard)."""
    if not SHA_RE.match(sha):
        raise ValueError("sha must be 40-hex")
    if not TAG_RE.match(tag):
        raise ValueError("tag must be staging-YYYYMMDD.N")
    ann = {ANN_RELEASE: tag}
    if previous:
        ann[ANN_PREVIOUS] = previous
    return {
        "metadata": {"annotations": ann},
        "spec": {"source": {"targetRevision": sha, "helm": {"parameters": [
            {"name": "release", "value": sha, "forceString": True},
            {"name": "releaseName", "value": tag, "forceString": True}]}}},
    }


def expected_root_spec(sha: str, tag: str) -> dict:
    return {
        "project": "default",
        "destination": {"namespace": NAMESPACE, "server": "https://kubernetes.default.svc"},
        "source": {"path": ROOT_PATH, "repoURL": REPO_URL, "targetRevision": sha,
                   "helm": {"parameters": [{"name": "release", "value": sha, "forceString": True},
                                           {"name": "releaseName", "value": tag, "forceString": True}]}},
        "syncPolicy": {"automated": {"prune": True, "selfHeal": True}},
    }


def root_deviations(root: dict) -> list[str]:
    """Differences between the live root and the shape scripts/staging-release writes. Empty = as expected."""
    out = []
    spec = root.get("spec") or {}
    src = spec.get("source") or {}
    tr = src.get("targetRevision", "")
    ann = (root.get("metadata") or {}).get("annotations") or {}
    tag = ann.get(ANN_RELEASE, "")
    if not SHA_RE.match(tr or ""):
        return [f"root targetRevision is '{tr}' (not a commit SHA): the root still follows the branch"]
    if not TAG_RE.match(tag or ""):
        out.append(f"annotation {ANN_RELEASE} is '{tag}', not staging-YYYYMMDD.N")
    exp = expected_root_spec(tr, tag or "?")
    if spec.get("project") != exp["project"]:
        out.append(f"project is {spec.get('project')}")
    if src.get("repoURL") != REPO_URL or src.get("path") != ROOT_PATH:
        out.append("repoURL/path differ")
    ps = root_params(root)
    if set(ps) != {"release", "releaseName"} or ps.get("release") != tr or ps.get("releaseName") != tag:
        out.append(f"helm parameters are {ps}")
    helm = src.get("helm") or {}
    if set(helm) - {"parameters"}:
        out.append(f"extra helm keys {sorted(set(helm) - {'parameters'})}")
    auto = (spec.get("syncPolicy") or {}).get("automated") or {}
    if not auto.get("selfHeal"):
        out.append("syncPolicy.automated.selfHeal is off")
    if auto.get("prune") is not True:
        out.append("syncPolicy.automated.prune is not true")
    dest = spec.get("destination") or {}
    if dest.get("server") != exp["destination"]["server"] or dest.get("namespace") != exp["destination"]["namespace"]:
        out.append(f"destination is {dest.get('server')}/{dest.get('namespace')}")
    if spec.get("ignoreDifferences"):
        out.append("spec.ignoreDifferences is set")
    if spec.get("sources"):
        out.append("spec.sources is not empty")
    if ANN_BREAK_GLASS in ann:
        out.append(f"break-glass is open: {ann[ANN_BREAK_GLASS]}")
    return out


# ---------------------------------------------------------------------------------------------
# Plan file (dry run -> --yes)
# ---------------------------------------------------------------------------------------------
def plan_path(cache_dir: str, sha: str) -> str:
    return os.path.join(cache_dir, f"{sha}.json")


def plan_check(plan: dict, sha: str, now: dt.datetime, live_sha: str | None = None) -> None:
    """--yes <sha> must equal the dry-run candidate, the plan must be fresh, and live must not have moved."""
    if plan.get("candidate") != sha:
        raise Refuse(f"--yes {sha[:12]} does not match the dry-run candidate {str(plan.get('candidate'))[:12]}")
    created = dt.datetime.fromisoformat(plan["created"])
    age = (now - created).total_seconds()
    if age > PLAN_TTL_SECONDS:
        raise Refuse(f"the plan is {int(age // 60)} min old (valid {PLAN_TTL_SECONDS // 60} min): run the dry run again")
    if live_sha and plan.get("live") != live_sha:
        raise Refuse(f"the live release moved since the dry run ({str(plan.get('live'))[:12]} -> {live_sha[:12]}): "
                     "run the dry run again")


# ---------------------------------------------------------------------------------------------
# Lease
# ---------------------------------------------------------------------------------------------
def parse_time(s: str | None) -> dt.datetime | None:
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    return dt.datetime.fromisoformat(s)


def lease_state(lease: dict | None, now: dt.datetime, me: str) -> tuple[str, str]:
    """('free'|'mine'|'held'|'stale', holder). stale = held but not renewed for STALE_LEASE_SECONDS."""
    if not lease:
        return "free", ""
    spec = lease.get("spec") or {}
    holder = spec.get("holderIdentity") or ""
    if not holder:
        return "free", ""
    if holder == me:
        return "mine", holder
    renew = parse_time(spec.get("renewTime")) or parse_time(spec.get("acquireTime"))
    dur = spec.get("leaseDurationSeconds") or LEASE_SECONDS
    if renew is None or (now - renew).total_seconds() > max(dur, STALE_LEASE_SECONDS):
        return "stale", holder
    return "held", holder


def lease_manifest(holder: str, now: dt.datetime, acquired: dt.datetime | None = None) -> dict:
    ts = now.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"
    return {"apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
            "metadata": {"name": LEASE_NAME, "namespace": NAMESPACE},
            "spec": {"holderIdentity": holder, "leaseDurationSeconds": LEASE_SECONDS,
                     "acquireTime": (acquired or now).strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z", "renewTime": ts}}


# ---------------------------------------------------------------------------------------------
# Convergence
# ---------------------------------------------------------------------------------------------
GITOPS_REPO_SUFFIX = "platform-applications-gitops"


def is_gitops_app(app: dict) -> bool:
    src = (app.get("spec") or {}).get("source") or {}
    return str(src.get("repoURL", "")).rstrip("/").endswith(GITOPS_REPO_SUFFIX)


def app_row(app: dict) -> dict:
    st = app.get("status") or {}
    return {"name": app["metadata"]["name"],
            "target": ((app.get("spec") or {}).get("source") or {}).get("targetRevision", ""),
            "revision": (st.get("sync") or {}).get("revision", ""),
            "sync": (st.get("sync") or {}).get("status", "Unknown"),
            "health": (st.get("health") or {}).get("status", "Unknown"),
            "op": (st.get("operationState") or {}).get("phase", "")}


def converged(apps: list[dict], sha: str, *, plugins_changed: bool = False,
              missing_namespaces: set[str] | None = None, expected: set[str] | None = None) -> tuple[bool, list[str]]:
    """The root and every gitops child are on `sha`, Synced and Healthy (plugin apps only when the
    plugin chart version changed, ignoring apps whose destination namespace does not exist)."""
    missing_namespaces = missing_namespaces or set()
    problems: list[str] = []
    seen = set()
    for app in apps:
        name = app["metadata"]["name"]
        row = app_row(app)
        if is_gitops_app(app):
            seen.add(name)
            if row["revision"] != sha or row["target"] != sha:
                problems.append(f"{name}: on {row['revision'][:12] or '-'} (target {row['target'][:12] or '-'}), want {sha[:12]}")
            elif row["sync"] != "Synced" or row["health"] != "Healthy":
                problems.append(f"{name}: {row['sync']}/{row['health']}")
        elif plugins_changed:
            dest = (app.get("spec") or {}).get("destination", {}).get("namespace", "")
            if dest in missing_namespaces:
                continue
            if row["sync"] != "Synced" or row["health"] != "Healthy":
                problems.append(f"{name}: {row['sync']}/{row['health']}")
    for name in sorted((expected or set()) - seen):
        problems.append(f"{name}: Application not found yet")
    return (not problems), problems


# ---------------------------------------------------------------------------------------------
# Releases (GitHub)
# ---------------------------------------------------------------------------------------------
def release_body_lines(body: str | None) -> list[str]:
    """The lines of a Release body, exactly: only carriage returns are removed (gh may return CRLF), nothing is
    trimmed. The same as staging-root.sh (infra#11): `body=${2//$'\\r'/}` and `grep -x`."""
    return (body or "").replace("\r", "").split("\n")


def is_marked(title: str | None, body: str | None = None) -> bool:
    """True when a GitHub Release carries the rolled-back or not-applied marker, EXACTLY like infra's
    staging-root.sh: the title starts with '[rolled back] ' or '[not applied] ' (no trimming, no other position), or
    a body line equals 'Rolled-Back: true' / 'Not-Applied: true' (the whole line, no trimming)."""
    t = title or ""
    if t.startswith(ROLLED_BACK_MARK + " ") or t.startswith(NOT_APPLIED_MARK + " "):
        return True
    lines = release_body_lines(body)
    return ROLLED_BACK_TRAILER in lines or NOT_APPLIED_TRAILER in lines


def marked_title(mark: str, tag: str) -> str:
    return f"{mark} {tag}"


def with_trailer(body: str, trailer: str) -> str:
    """The Release body with the trailer as its own last line (idempotent: an exactly equal line counts)."""
    lines = release_body_lines((body or "").rstrip())
    if trailer in lines:
        return "\n".join(lines) + "\n"
    return "\n".join(lines + ["", trailer]) + "\n"


def pick_rollback_target(releases: list[dict], live_tag: str | None, floor: str | None) -> str | None:
    """Newest release that is verified (not a prerelease), not marked rolled back / not applied, older than live and
    not older than the floor. `releases` are `gh release list --json tagName,isPrerelease,name` rows."""
    cands = []
    for r in releases:
        t = r.get("tagName", "")
        if not TAG_RE.match(t):
            continue
        if r.get("isPrerelease") or is_marked(r.get("name")):
            continue
        if live_tag and tag_key(t) >= tag_key(live_tag):
            continue
        if floor and not tag_at_or_after(t, floor):
            continue
        cands.append(t)
    return max(cands, key=tag_key) if cands else None


def newest_verified_release(releases: list[dict]) -> str | None:
    """For the bootstrap: newest release that is not a prerelease and not marked rolled back / not applied."""
    ok = [r["tagName"] for r in releases
          if TAG_RE.match(r.get("tagName", "")) and not r.get("isPrerelease")
          and not is_marked(r.get("name"))]
    return max(ok, key=tag_key) if ok else None


def tag_message(*, tag: str, sha: str, by: str, reason: str, previous: str | None, live_sha: str,
                pending: list[dict], image_changes: list[str], plugin_digests: dict[str, str],
                plugin_version: str | None, mode: str, shared_digests: dict[str, str] | None = None,
                registry_checked: bool = True, guard_warn_count: int | None = None) -> str:
    lines = [f"{tag}", "",
             f"commit: {sha}", f"previous: {previous or '(none: first release)'} ({live_sha[:12]})",
             f"by: {by}", f"reason: {reason}", f"kind: {mode}",
             "registry check: " + ("every digest-pinned image resolved" if registry_checked else
                                   "SKIPPED (--skip-registry-check on the dry run and on --yes)"),
             f"guard warn count at release: {guard_warn_count if guard_warn_count is not None else '(unknown)'}",
             "", f"pending ({len(pending)}):"]
    for c in pending:
        pr = f"#{c['pr']} " if c.get("pr") else ""
        br = f" [{c['branch']}]" if c.get("branch") else ""
        lines.append(f"  {c['short']} {pr}{c['subject']}{br}")
    lines += ["", f"image changes ({len(image_changes)}):"] + [f"  {c}" for c in image_changes]
    lines += ["", f"plugin chart version: {plugin_version or '(unknown)'}", "plugin chart index digests:"]
    lines += [f"  {k} {v}" for k, v in sorted(plugin_digests.items())]
    lines += ["", "production-shared tag digests:"] + [f"  {k} {v}" for k, v in sorted((shared_digests or {}).items())]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------------------------
# Guard decisions from the apiserver metrics
# ---------------------------------------------------------------------------------------------
GUARD_POLICY = "staging-release-guard"
_METRIC_RE = re.compile(r'^apiserver_validating_admission_policy_check_total\{([^}]*)\}\s+([0-9.eE+-]+)\s*$')


def guard_action_counts(metrics_text: str, policy: str = GUARD_POLICY) -> dict[str, int]:
    """{'warn': n, 'deny': n, 'audit': n}: how often the policy found a violation, per enforcement action,
    since the apiserver started (apiserver_validating_admission_policy_check_total counts failed validations)."""
    out: dict[str, int] = {}
    for line in metrics_text.splitlines():
        m = _METRIC_RE.match(line)
        if not m:
            continue
        labels = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
        if labels.get("policy") != policy:
            continue
        act = labels.get("enforcement_action", "")
        out[act] = out.get(act, 0) + int(float(m.group(2)))
    return out


def warn_delta(now: int | None, baseline: int | None) -> tuple[int | None, bool]:
    """(warnings since the baseline, counter_was_reset). The counter lives in the apiserver process: lower than
    the baseline means the apiserver restarted, then the count since the restart is all that is known."""
    if now is None:
        return None, False
    if baseline is None:
        return now, False
    if now < baseline:
        return now, True
    return now - baseline, False


# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
def repo_root_of(path: str) -> str:
    return subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                          check=True).stdout.strip()


def cache_dir() -> str:
    d = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "staging-release")
    os.makedirs(d, exist_ok=True)
    return d


def eprint(*a) -> None:
    print(*a, file=sys.stderr)
