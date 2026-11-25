#!/usr/bin/env python3
"""watch.py - the staging watch (P4.2 section 6, plan 7.3).

Three checks, each idempotent: one open issue per alert, edited in place instead of duplicated, closed when the
condition clears.

1. unverified - the newest commit on the default branch that is older than VERIFY_DEADLINE_MINUTES and that no
   verified/* tag contains opens (or updates in place) one staging-alert issue naming the commit and its author;
   that issue is closed when no such commit remains.
2. freight - a verified/* tag whose annotated tag message lacks `freight=` opens a staging-alert issue: the tag must
   record the Kargo freight it verified, or the next release cannot tell what staging actually served.
3. ruleset - every .github/rulesets/<name>.json equals the live ruleset of that name (GitHub REST, looked up by
   name), ignoring the fields GitHub itself generates. A missing or different ruleset opens a ruleset-drift issue,
   closed again when the live ruleset matches.

Only the `git` and `gh` CLIs are used. `--dry-run` prints what it would do instead of calling gh.

Environment: GH_TOKEN (for gh), GITHUB_REPOSITORY (owner/name; default: `gh repo view`), DEFAULT_BRANCH (default: the
repository's default branch), WATCH_NOW (epoch seconds; tests only).
"""

from __future__ import annotations

import argparse
import difflib
import glob
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from urllib.parse import quote, unquote

# --- thresholds, labels and formats -------------------------------------------------------------------------
ALERT_LABEL = "staging-alert"             # unverified commit, missing freight=
DRIFT_LABEL = "ruleset-drift"             # live ruleset missing or different
# The tag prefix Kargo's staging-verified stage cuts once its browser analysis passes.
VERIFIED_TAG_PREFIX = "verified/"
FREIGHT_KEY = "freight"                   # the tag message annotation that records the Kargo freight (plan 7.3)
VERIFY_DEADLINE_MINUTES = 45              # a commit on the default branch older than this, with no verified/ tag
RULESET_DIR = os.path.join(".github", "rulesets")
ISSUE_LIST_LIMIT = 200
MAX_DIFF_LINES = 60
MARKER_RE = re.compile(r"<!--\s*gitops-watch\s+([^>]*?)\s*-->")
FIELD_SEP = "\x1f"
RECORD_SEP = "\x1e"   # git %1e: ends one for-each-ref record (any tag message is text)

# Fields GitHub generates (ids, links, timestamps, provenance) or that the payload sets to the empty default:
# they say nothing about whether the ruleset is the intended one.
IGNORED_RULESET_FIELDS = frozenset({
    "id", "bypass_actors", "node_id", "_links", "created_at", "updated_at",
    "source", "source_type", "current_user_can_bypass",
})


class WatchError(RuntimeError):
    """A gh or git call failed; the run stops rather than guess."""


def now() -> float:
    override = os.environ.get("WATCH_NOW")
    return float(override) if override else time.time()


def _run(cmd, *, cwd=None, check=True):
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and proc.returncode != 0:
        raise WatchError(
            f"{' '.join(cmd)} failed (exit {proc.returncode}): {(proc.stderr or proc.stdout).strip()}"
        )
    return proc


def marker(kind: str, **fields) -> str:
    """The issue's identity: kind plus its subject, in an HTML comment the Markdown never shows. Values are
    URL-encoded, so a subject with spaces still reads back as one field."""
    parts = [f"kind={kind}"] + [f"{k}={quote(str(v))}" for k, v in fields.items()]
    return f"<!-- gitops-watch {' '.join(parts)} -->"


def parse_marker(body: str) -> dict:
    m = MARKER_RE.search(body or "")
    if not m:
        return {}
    fields = {}
    for part in m.group(1).split():
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = unquote(value)
    return fields


# --- rulesets ------------------------------------------------------------------------------------------------

def declared_parameters(ruleset: dict) -> dict:
    """{rule type: the parameter keys the repository file declares}. GitHub fills in parameters the file never
    declares (schema defaults, newer schema additions); those say nothing about intent and are not compared."""
    declared = {}
    for rule in ruleset.get("rules") or []:
        params = rule.get("parameters")
        if isinstance(params, dict):
            declared.setdefault(rule.get("type", ""), set()).update(params)
    return declared


def normalise_ruleset(ruleset: dict, declared: dict) -> dict:
    """The comparable shape: generated fields dropped, every rule's parameters limited to the keys the repository
    file declares for that rule type, rules ordered by type and ref globs sorted, so only a real difference
    remains."""
    out = {k: v for k, v in ruleset.items() if k not in IGNORED_RULESET_FIELDS}
    rules = []
    for rule in out.get("rules") or []:
        rule = dict(rule)
        params = rule.get("parameters")
        if isinstance(params, dict):
            keys = declared.get(rule.get("type", ""), set())
            rule["parameters"] = {k: v for k, v in params.items() if k in keys}
        rules.append(rule)
    out["rules"] = sorted(rules, key=lambda r: r.get("type", ""))
    conditions = out.get("conditions")
    if isinstance(conditions, dict) and isinstance(conditions.get("ref_name"), dict):
        ref_name = dict(conditions["ref_name"])
        conditions["ref_name"] = ref_name
        for key in ("include", "exclude"):
            if isinstance(ref_name.get(key), list):
                ref_name[key] = sorted(ref_name[key])
    return out


def ruleset_diff(want: dict, live: dict, declared: dict) -> str:
    a = json.dumps(normalise_ruleset(want, declared), indent=2, sort_keys=True).splitlines()
    b = json.dumps(normalise_ruleset(live, declared), indent=2, sort_keys=True).splitlines()
    lines = list(difflib.unified_diff(a, b, fromfile=".github/rulesets (repository)", tofile="live", lineterm="", n=2))
    if len(lines) > MAX_DIFF_LINES:
        lines = lines[:MAX_DIFF_LINES] + [f"... ({len(lines) - MAX_DIFF_LINES} more diff lines)"]
    return "\n".join(lines)


# --- actions and issues --------------------------------------------------------------------------------------

@dataclass
class Issue:
    number: int
    title: str = ""
    body: str = ""
    label: str = ""
    state: str = "open"
    marker: dict = field(default_factory=dict)


@dataclass
class Action:
    verb: str                    # create | edit | close
    label: str
    subject: str
    title: str = ""
    body: str = ""
    number: int = 0
    comment: str = ""

    def describe(self) -> str:
        if self.verb == "create":
            return f"create {self.label} issue {self.title!r}"
        if self.verb == "edit":
            return f"update {self.label} issue #{self.number} ({self.title!r})"
        return f"close {self.label} issue #{self.number}"


class Watcher:
    def __init__(self, root: str, *, dry_run: bool = False, out=None):
        self.root = os.path.abspath(root)
        self.dry_run = dry_run
        self.out = out or sys.stdout

    # --- cli ---
    def git(self, *args, check=True):
        return _run(["git", *args], cwd=self.root, check=check)

    def gh(self, *args, check=True):
        return _run(["gh", *args], cwd=self.root, check=check)

    def gh_json(self, *args):
        text = self.gh(*args).stdout.strip()
        return json.loads(text) if text else None

    # --- repository facts ---
    def default_branch(self) -> str:
        branch = os.environ.get("DEFAULT_BRANCH")
        if branch:
            return branch
        return self.gh("repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name").stdout.strip()

    def repo_slug(self) -> str:
        slug = os.environ.get("GITHUB_REPOSITORY")
        if slug:
            return slug
        return self.gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").stdout.strip()

    def revision_ref(self) -> str:
        ref = f"origin/{self.default_branch()}"
        if self.git("rev-parse", "--verify", "--quiet", ref, check=False).returncode == 0:
            return ref
        return "HEAD"

    def newest_commit(self):
        """(sha, committed epoch seconds, author name, subject) of the newest default-branch commit older than
        VERIFY_DEADLINE_MINUTES, or None when the tip is younger than the deadline (a release may still be on
        its way). The cutoff is git's own, so a fresh commit never hides an older unverified one below it."""
        cutoff = int(now() - VERIFY_DEADLINE_MINUTES * 60)
        out = self.git("log", "-1", f"--format=%H{FIELD_SEP}%ct{FIELD_SEP}%an{FIELD_SEP}%s",
                       f"--before=@{cutoff}", self.revision_ref()).stdout.rstrip("\n")
        if not out:
            return None
        sha, committed, author, subject = out.split(FIELD_SEP, 3)
        return sha, int(committed), author, subject

    def tags_containing(self, sha: str):
        """Every tag whose commit history contains sha, or None when git does not know the commit."""
        proc = self.git("tag", "--contains", sha, check=False)
        if proc.returncode != 0:
            return None
        return [t for t in proc.stdout.split() if t]

    def verified_tags(self) -> dict:
        """{tag: (objecttype, message)} for every verified/* tag. A lightweight tag (objecttype != 'tag') has no
        annotated message, so it can never carry freight=."""
        proc = self.git(
            "for-each-ref",
            f"--format=%(refname:strip=2){FIELD_SEP}%(objecttype){FIELD_SEP}%(contents){RECORD_SEP}",
            f"refs/tags/{VERIFIED_TAG_PREFIX}*",
        )
        tags = {}
        for record in proc.stdout.split(RECORD_SEP):
            if not record.strip():
                continue
            fields = (record.split(FIELD_SEP, 2) + ["", ""])[:3]
            name, objtype, message = fields
            tags[name.strip()] = (objtype.strip(), message)
        return tags

    def fetch_rulesets(self) -> dict:
        """{name: live detail} for the ruleset names the repository declares. An entry another source owns (an
        organization ruleset, say) is never the repository's ruleset, even under the same name."""
        wanted = set()
        for path in self.ruleset_files():
            wanted.add(json.load(open(path, encoding="utf-8"))["name"])
        base = f"repos/{self.repo_slug()}/rulesets"
        # --slurp wraps the pages in one array ([page, page]); flatten it, and accept a single flat array too.
        pages = self.gh_json("api", f"{base}?per_page=100", "--paginate", "--slurp") or []
        live = {}
        for page in pages:
            for entry in page if isinstance(page, list) else [page]:
                if entry.get("source_type") != "Repository":
                    continue
                name = entry.get("name")
                if name in wanted:
                    live[name] = self.gh_json("api", f"{base}/{entry['id']}")
        return live

    def ruleset_files(self):
        return sorted(glob.glob(os.path.join(self.root, RULESET_DIR, "*.json")))

    # --- issues ---
    def list_issues(self, label, state="open"):
        """The issues carrying label, in the given state, each with its marker parsed. gh's JSON prints the state
        uppercase (OPEN, CLOSED); it is lowercased here so callers compare one spelling."""
        return [
            Issue(number=item.get("number"), title=item.get("title") or "", body=item.get("body") or "",
                  label=label, state=(item.get("state") or state).lower(),
                  marker=parse_marker(item.get("body") or ""))
            for item in self.gh_json("issue", "list", "--label", label, "--state", state,
                                     "--limit", str(ISSUE_LIST_LIMIT),
                                     "--json", "number,title,body,labels,state") or []
        ]

    def open_issues(self):
        issues = []
        seen = set()
        for label in (ALERT_LABEL, DRIFT_LABEL):
            for issue in self.list_issues(label):
                if issue.number in seen:
                    continue
                seen.add(issue.number)
                issues.append(issue)
        return issues

    @staticmethod
    def matches(issues, kind, subject_key, subject_value):
        return [i for i in issues
                if i.marker.get("kind") == kind and i.marker.get(subject_key) == str(subject_value)]

    def ensure(self, issues, *, kind, label, title, body, subject_key=None, subject_value=None) -> list:
        """Create the issue, or edit the open one in place; a duplicate open issue is closed, not kept. Without
        subject_key there is one issue of the kind (the unverified alert); with it, one per subject value."""
        if subject_key is None:
            found = [i for i in issues if i.marker.get("kind") == kind]
        else:
            found = self.matches(issues, kind, subject_key, subject_value)
        subject = str(subject_value) if subject_key is not None else kind
        if not found:
            return [Action("create", label, subject, title=title, body=body)]
        keep, *duplicates = found
        actions = [Action("close", label, subject, number=dup.number,
                          comment=f"Duplicate of #{keep.number}.") for dup in duplicates]
        if keep.title != title or (keep.body or "").strip() != body.strip():
            actions.append(Action("edit", label, subject, title=title, body=body, number=keep.number))
        return actions

    # --- check 1: an unverified commit ---
    def check_unverified(self, issues) -> list:
        actions = []
        prefix = VERIFIED_TAG_PREFIX
        open_unverified = [i for i in issues if i.marker.get("kind") == "unverified"]

        # The newest commit older than the deadline that no verified/* tag contains, if any. A younger tip is
        # still in flight; a verified tip means its older ancestors are contained by the same tag.
        tip = self.newest_commit()
        unverified = None
        if tip is not None:
            sha, committed, author, subject = tip
            covering = [t for t in (self.tags_containing(sha) or []) if t.startswith(prefix)]
            if not covering:
                unverified = tip

        if unverified is None:
            for issue in open_unverified:
                actions.append(Action("close", ALERT_LABEL, issue.marker.get("commit", ""), number=issue.number,
                                      comment="Resolved: no unverified commit on the default branch remains."))
            return actions

        sha, committed, author, subject = unverified
        # No age in the title or body: a watch that only sees the clock move must not edit the issue.
        title = f"Staging commit {sha[:8]} unverified after {VERIFY_DEADLINE_MINUTES} min"
        body = "\n".join([
            f"The newest commit on `{self.default_branch()}` older than {VERIFY_DEADLINE_MINUTES} min is not "
            f"contained in any `{VERIFIED_TAG_PREFIX}*` tag.",
            "",
            f"- commit: `{sha}`",
            f"- author: {author}",
            f"- subject: {subject}",
            f"- committed: {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(committed))}",
            "",
            "Kargo ships it once its verification passes and cuts the "
            f"`{VERIFIED_TAG_PREFIX}*` tag that closes this issue; if the verification fails, the fix is a revert PR "
            "to the gitops branch, which Kargo ships the same way. Until the tag exists, this issue is the staging "
            "line's only signal that a release was never verified.",
            "",
            marker("unverified", commit=sha),
            "",
        ])
        actions.extend(self.ensure(open_unverified, kind="unverified", label=ALERT_LABEL, title=title, body=body))
        return actions

    # --- check 2: a verified tag without the freight annotation ---
    def check_freight(self) -> list:
        actions = []
        freight_re = re.compile(rf"(?m)^{re.escape(FREIGHT_KEY)}\s*=\s*\S")
        # Closed issues too: a tag whose alert was already resolved by hand is never alerted again.
        history = [i for i in self.list_issues(ALERT_LABEL, state="all") if i.marker.get("kind") == "freight"]
        for tag, (objtype, message) in sorted(self.verified_tags().items()):
            related = [i for i in history if i.marker.get("tag") == tag]
            open_for_tag = [i for i in related if i.state == "open"]
            if objtype == "tag" and freight_re.search(message or ""):
                for issue in open_for_tag:
                    actions.append(Action("close", ALERT_LABEL, tag, number=issue.number,
                                          comment=f"Resolved: `{tag}` now records its `{FREIGHT_KEY}=`."))
                continue
            if not open_for_tag and any(i.state == "closed" for i in related):
                continue                      # resolved by hand: never recreate the alert
            why = ("the tag is lightweight, so it carries no annotated message"
                   if objtype != "tag" else f"the annotated message has no `{FREIGHT_KEY}=` line")
            title = f"Verified tag {tag} has no {FREIGHT_KEY}= annotation"
            body = "\n".join([
                f"`{tag}` marks a staging release as verified, but {why}.",
                "",
                "Plan 7.3: the tag records the Kargo freight it verified (`freight=<freight name>`, the message of "
                "`git-tag` in `stage-staging-verified.yaml`), so the next release can tell what staging served. "
                "A tag without it breaks that comparison.",
                "",
                f"Message: {objtype} / {(message or '').strip()[:500] or '(empty)'}",
                "",
                marker("freight", tag=tag),
                "",
            ])
            actions.extend(self.ensure(open_for_tag, kind="freight", subject_key="tag", subject_value=tag,
                                       label=ALERT_LABEL, title=title, body=body))
        return actions

    # --- check 3: the rulesets ---
    def check_rulesets(self, issues) -> list:
        actions = []
        live = self.fetch_rulesets()
        for path in self.ruleset_files():
            with open(path, encoding="utf-8") as fh:
                want = json.load(fh)
            name = want["name"]
            relative = os.path.relpath(path, self.root)
            declared = declared_parameters(want)
            open_for_name = self.matches(issues, "ruleset", "name", name)
            current = live.get(name)
            if current is not None and normalise_ruleset(want, declared) == normalise_ruleset(current, declared):
                for issue in open_for_name:
                    actions.append(Action("close", DRIFT_LABEL, name, number=issue.number,
                                          comment=f"Resolved: live ruleset `{name}` matches `{relative}` again."))
                continue
            if current is None:
                title = f"Ruleset {name} is missing"
                body_lines = [f"The live repository has no ruleset named `{name}`.", "",
                              f"`{relative}` declares it; P5.1 applies the rulesets. Until then it is missing.", ""]
            else:
                title = f"Ruleset {name} differs from {relative}"
                body_lines = [f"The live ruleset `{name}` differs from `{relative}`.", "",
                              "```diff", ruleset_diff(want, current, declared), "```", ""]
                if current.get("bypass_actors"):
                    body_lines.append("(`bypass_actors` is not compared: break-glass is not drift.)")
                    body_lines.append("")
            body_lines += [marker("ruleset", name=name), ""]
            actions.extend(self.ensure(issues, kind="ruleset", subject_key="name", subject_value=name,
                                       label=DRIFT_LABEL, title=title, body="\n".join(body_lines)))
        return actions

    # --- run ---
    def run(self) -> list:
        issues = self.open_issues()
        actions = []
        actions += self.check_unverified(issues)
        actions += self.check_freight()
        actions += self.check_rulesets(issues)
        for action in actions:
            if self.dry_run:
                print(f"dry-run: would {action.describe()}", file=self.out)
                continue
            self.apply(action)
            print(action.describe(), file=self.out)
        if not actions:
            print("nothing to do", file=self.out)
        return actions

    def apply(self, action: Action) -> None:
        if action.verb == "create":
            self.gh("issue", "create", "--label", action.label, "--title", action.title, "--body", action.body)
        elif action.verb == "edit":
            self.gh("issue", "edit", str(action.number), "--title", action.title, "--body", action.body)
        elif action.verb == "close":
            self.gh("issue", "close", str(action.number), "--comment", action.comment)
        else:  # pragma: no cover - an Action is built by this module only
            raise WatchError(f"unknown action verb {action.verb!r}")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="The staging watch: unverified commits, freight-less verified tags, "
                                                 "ruleset drift.")
    parser.add_argument("--root", default=".", help="repository root (default: the current directory)")
    parser.add_argument("--dry-run", action="store_true", help="print the actions instead of calling gh")
    args = parser.parse_args(argv)
    try:
        Watcher(args.root, dry_run=args.dry_run).run()
    except WatchError as err:
        print(f"watch: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
