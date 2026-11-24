"""watch.py: the staging watch, run against fake `gh` and `git` executables first on PATH.

The fakes keep their answers in FAKE_DIR: git.json (refs, the tip commit, tags and what each commit's history
contains) and gh.json (default branch, issues, live rulesets). Both append every call to FAKE_DIR/calls.log, so a
test can assert that nothing was written when nothing should be.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(SCRIPTS)
WATCH = os.path.join(SCRIPTS, "watch.py")
SLUG = "teknoir/platform-applications-gitops"
WRITES = re.compile(r"^gh issue (create|edit|close)")   # the calls that change the repository
SHA_OLD = "a" * 40
SHA_NEW = "b" * 40

FAKE_GIT = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_DIR"]
state = json.load(open(os.path.join(d, "git.json")))
args = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a") as fh:
    fh.write("git " + " ".join(args) + "\n")
def done(text, rc=0):
    sys.stdout.write(text)
    sys.exit(rc)
if args[:2] == ["rev-parse", "--verify"]:
    done("", 0 if args[-1] in state["refs"] else 1)
if args and args[0] == "log":
    # Honour --before=@<epoch> like git does: the newest history entry whose commit date is at or before it.
    before = next((a.split("=", 1)[1] for a in args if a.startswith("--before=")), None)
    cutoff = int(before.lstrip("@")) if before else None
    for sha in state.get("history") or [state["head"]]:
        c = state["commits"][sha]
        if cutoff is None or c["ct"] <= cutoff:
            done("%s\x1f%s\x1f%s\x1f%s\n" % (sha, c["ct"], c["author"], c["subject"]))
    done("")
if args[:2] == ["tag", "--contains"]:
    tags = state["contains"].get(args[2])
    if tags is None:
        done("error: no such commit\n", 128)
    done("".join(t + "\n" for t in tags))
if args and args[0] == "for-each-ref":
    out = ""
    for name, t in state["tags"].items():
        out += "%s\x1f%s\x1f%s\x1e" % (name, t["objecttype"], t["message"])
    done(out)
done("fake git: unsupported " + " ".join(args) + "\n", 2)
'''

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
d = os.environ["FAKE_DIR"]
path = os.path.join(d, "gh.json")
state = json.load(open(path))
args = sys.argv[1:]
with open(os.path.join(d, "calls.log"), "a") as fh:
    fh.write("gh " + " ".join(args) + "\n")
def save():
    with open(path, "w") as fh:
        json.dump(state, fh)
def done(text="", rc=0):
    sys.stdout.write(text)
    sys.exit(rc)
def opt(flag):
    return args[args.index(flag) + 1] if flag in args else None
if args[:2] == ["repo", "view"]:
    done(state.get("slug", "teknoir/platform-applications-gitops") if "nameWithOwner" in args
         else state.get("default_branch", "main"))
if args[:2] == ["issue", "list"]:
    label = opt("--label")
    wanted = opt("--state") or "open"
    items = [i for i in state["issues"]
             if label in i["labels"] and (wanted == "all" or i["state"] == wanted)]
    # gh prints the state uppercase in --json, whatever --state it was asked for.
    done(json.dumps([{**{k: i.get(k, "") for k in ("number", "title", "body")}, "state": i["state"].upper()}
                     for i in items]))
if args[:2] == ["issue", "create"]:
    n = max([i["number"] for i in state["issues"]] or [0]) + 1
    state["issues"].append({"number": n, "title": opt("--title"), "body": opt("--body"),
                            "labels": [opt("--label")], "state": "open"})
    save()
    done("https://example.invalid/issues/%d\n" % n)
if args[:2] == ["issue", "edit"] or args[:2] == ["issue", "close"]:
    n = int(args[2])
    for i in state["issues"]:
        if i["number"] != n:
            continue
        if args[1] == "edit":
            i["title"] = opt("--title") or i["title"]
            i["body"] = opt("--body") or i["body"]
        else:
            i["state"] = "closed"
            i["closed_with"] = opt("--comment")
    save()
    done()
if args and args[0] == "api":
    parts = args[1].split("?")[0].split("/")
    if "rulesets" not in parts:
        done("fake gh: unsupported api path %s\n" % args[1], 2)
    at = parts.index("rulesets")
    if len(parts) == at + 1:
        page = [{"id": r["id"], "name": r["name"], "source_type": r.get("source_type", "Repository")}
                for r in state["rulesets"]]
        done(json.dumps([page] if "--slurp" in args else page))
    for r in state["rulesets"]:
        if str(r["id"]) == parts[at + 1]:
            done(json.dumps(r))
    done("gh: HTTP 404: Not Found\n", 1)
done("fake gh: unsupported " + " ".join(args) + "\n", 2)
'''


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def live_detail(payload, rid=1, **overrides):
    """A GET …/rulesets/{id} answer: the payload plus what GitHub fills in or generates."""
    detail = json.loads(json.dumps(payload))
    detail.update({
        "id": rid,
        "node_id": f"RRS_{rid}",
        "_links": {"self": {"href": "https://api.github.invalid"}, "html": {"href": "https://github.invalid"}},
        "created_at": "2026-11-01T00:00:00Z",
        "updated_at": "2026-11-02T00:00:00Z",
        "source": SLUG,
        "source_type": "Repository",
        "current_user_can_bypass": "never",
        "bypass_actors": [],
    })
    for rule in detail["rules"]:
        # Schema defaults GitHub fills in on read that the repository files do not declare.
        if rule["type"] == "pull_request":
            rule["parameters"].setdefault("dismissal_restriction", {"allowed_actors": [], "enabled": False})
            rule["parameters"].setdefault("require_extra_approval_for_unattributed_changes", True)
        if rule["type"] == "required_status_checks":
            rule["parameters"].setdefault("do_not_enforce_on_create", False)
    detail.update(overrides)
    return detail


class WatchCase(unittest.TestCase):
    def setUp(self):
        self.dir = H.tmpdir()
        self.bin = os.path.join(self.dir, "bin")
        os.makedirs(self.bin)
        for name, text in (("git", FAKE_GIT), ("gh", FAKE_GH)):
            path = os.path.join(self.bin, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.chmod(path, 0o755)
        self.root = os.path.join(self.dir, "repo")
        os.makedirs(os.path.join(self.root, ".github", "rulesets"))
        for name in ("main", "verified-tags"):
            shutil.copy(os.path.join(REPO, ".github", "rulesets", f"{name}.json"),
                        os.path.join(self.root, ".github", "rulesets", f"{name}.json"))
        self.payloads = {p["name"]: p for p in
                         (load(os.path.join(self.root, ".github", "rulesets", f"{n}.json"))
                          for n in ("main", "verified-tags"))}
        self.now = int(time.time())
        self.git = {
            "refs": {"origin/main": SHA_OLD},
            "head": SHA_OLD,
            "history": [SHA_OLD],
            "commits": {SHA_OLD: {"ct": self.now - 90 * 60, "author": "Anders Åslund",
                                  "subject": "ci: a change nobody verified"}},
            "contains": {SHA_OLD: [], SHA_NEW: []},
            "tags": {},
        }
        self.gh = {"slug": SLUG, "default_branch": "main", "issues": [], "rulesets": []}
        self.quiet_rulesets()          # a live repository with both rulesets matching: no drift by default

    # --- fixture helpers ---
    def quiet_rulesets(self):
        self.gh["rulesets"] = [live_detail(self.payloads["main"], 101),
                               live_detail(self.payloads["verified-tags"], 102)]

    def save(self):
        for name, state in (("git.json", self.git), ("gh.json", self.gh)):
            with open(os.path.join(self.dir, name), "w", encoding="utf-8") as fh:
                json.dump(state, fh)

    def seed_issue(self, number, title, marker_text, label, state="open"):
        self.gh["issues"].append({"number": number, "title": title, "body": f"old body\n\n{marker_text}\n",
                                  "labels": [label], "state": state})

    def run_watch(self, *args):
        self.save()
        log = os.path.join(self.dir, "calls.log")
        if os.path.exists(log):
            os.remove(log)              # only this run's calls
        env = {k: v for k, v in os.environ.items() if k not in ("DEFAULT_BRANCH",)}
        env.update({
            "PATH": self.bin + os.pathsep + env.get("PATH", ""),
            "FAKE_DIR": self.dir,
            "WATCH_NOW": str(self.now),
            "GITHUB_REPOSITORY": SLUG,
            "HOME": self.dir,
        })
        proc = subprocess.run([sys.executable, WATCH, "--root", self.root, *args],
                              capture_output=True, text=True, env=env)
        self.gh = load(os.path.join(self.dir, "gh.json"))
        with open(os.path.join(self.dir, "calls.log"), encoding="utf-8") as fh:
            calls = fh.read().splitlines()
        return proc, calls

    def issues(self, label=None):
        if label:
            return [i for i in self.gh["issues"] if label in i["labels"]]
        return self.gh["issues"]

    # --- 1. unverified commit ---
    def test_unverified_old_commit_opens(self):
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        issues = self.issues("staging-alert")
        self.assertEqual(len(issues), 1, issues)
        issue = issues[0]
        self.assertEqual(issue["state"], "open")
        self.assertIn(SHA_OLD[:8], issue["title"])
        self.assertIn("unverified", issue["title"])
        self.assertIn(SHA_OLD, issue["body"])
        self.assertIn("Anders Åslund", issue["body"])
        self.assertIn(f"kind=unverified commit={SHA_OLD}", issue["body"])

    def test_already_open_issue_is_updated_not_duplicated(self):
        self.seed_issue(7, "staging-alert: old wording", f"<!-- gitops-watch kind=unverified commit={SHA_OLD} -->",
                        "staging-alert")
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        issues = self.issues("staging-alert")
        self.assertEqual(len(issues), 1, issues)                       # no duplicate
        self.assertNotIn("staging-alert: old wording", issues[0]["title"])
        self.assertIn(SHA_OLD[:8], issues[0]["title"])
        self.assertTrue(any("gh issue edit 7" in c for c in calls), calls)
        self.assertFalse(any(c.startswith("gh issue create") for c in calls), calls)

    def test_second_run_is_a_no_op(self):
        self.run_watch()
        first = len(self.issues())
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.issues()), first)
        self.assertIn("nothing to do", proc.stdout)
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)

    def test_verified_commit_closes(self):
        self.seed_issue(3, f"Staging commit {SHA_OLD[:8]} unverified for 90 min",
                        f"<!-- gitops-watch kind=unverified commit={SHA_OLD} -->", "staging-alert")
        tag = "verified/20261124T101010Z-aaaaaaaa"
        self.git["contains"][SHA_OLD] = [tag, "staging-20261124.1"]
        self.git["tags"][tag] = {"objecttype": "tag", "message": "verified staging-20261124.1\n\nfreight=abc123\n"}
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues("staging-alert")[0]["state"], "closed")
        self.assertTrue(any("gh issue close 3" in c for c in calls), calls)
        self.assertFalse(any(c.startswith("gh issue create") or c.startswith("gh issue edit") for c in calls), calls)

    def test_commit_younger_than_45_minutes_does_nothing(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 30 * 60
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues(), [])
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)

    def test_a_fresh_tip_does_not_hide_the_unverified_commit_below_it(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 120 * 60
        self.git["commits"][SHA_NEW] = {"ct": self.now - 10 * 60, "author": "Anders Åslund",
                                        "subject": "ci: a fresh change"}
        self.git["head"] = SHA_NEW
        self.git["history"] = [SHA_NEW, SHA_OLD]
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        issues = self.issues("staging-alert")
        self.assertEqual(len(issues), 1, issues)
        self.assertIn(SHA_OLD, issues[0]["body"])
        self.assertIn(SHA_OLD[:8], issues[0]["title"])
        self.assertNotIn(SHA_NEW, issues[0]["body"])

    def test_time_moving_alone_does_not_write(self):
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.issues("staging-alert")), 1)
        self.now += 15 * 60
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("nothing to do", proc.stdout)
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)
        self.assertEqual(len(self.issues("staging-alert")), 1)

    def test_a_newer_unverified_commit_edits_the_same_issue(self):
        self.run_watch()                     # one open issue, naming SHA_OLD
        self.git["commits"][SHA_NEW] = {"ct": self.now - 50 * 60, "author": "Anders Åslund",
                                        "subject": "ci: a newer change"}
        self.git["head"] = SHA_NEW
        self.git["history"] = [SHA_NEW, SHA_OLD]
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        issues = self.issues("staging-alert")
        self.assertEqual(len(issues), 1, issues)                         # never a second issue
        self.assertIn(SHA_NEW[:8], issues[0]["title"])
        self.assertTrue(any(c.startswith("gh issue edit") for c in calls), calls)
        self.assertFalse(any(c.startswith("gh issue create") for c in calls), calls)

    # --- 2. a verified tag without freight= ---
    def test_tag_without_freight_opens(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60          # the tip is not the subject here
        tag = "verified/20261124T101010Z-aaaaaaaa"
        self.git["tags"][tag] = {"objecttype": "tag", "message": "verified staging-20261124.1\n"}
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        issues = self.issues("staging-alert")
        self.assertEqual(len(issues), 1, issues)
        self.assertIn(tag, issues[0]["title"])
        self.assertIn("freight=", issues[0]["body"])
        self.assertIn(f"kind=freight tag={tag}", issues[0]["body"])

    def test_lightweight_verified_tag_counts_as_missing_freight(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        tag = "verified/20261124T101010Z-aaaaaaaa"
        self.git["tags"][tag] = {"objecttype": "commit", "message": "freight=abc123\n"}
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(self.issues("staging-alert")), 1)

    def test_a_closed_freight_alert_is_not_recreated(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        tag = "verified/20261124T101010Z-aaaaaaaa"
        self.git["tags"][tag] = {"objecttype": "tag", "message": "verified staging-20261124.1\n"}
        self.seed_issue(11, f"Verified tag {tag} has no freight= annotation",
                        f"<!-- gitops-watch kind=freight tag={tag} -->", "staging-alert", state="closed")
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(any(c.startswith("gh issue list") and "--state all" in c for c in calls), calls)
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)
        self.assertEqual(len(self.issues("staging-alert")), 1)
        self.assertEqual(self.issues("staging-alert")[0]["state"], "closed")

    # --- 3. rulesets ---
    def test_missing_ruleset_opens_drift(self):
        self.gh["rulesets"] = []
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        drifts = self.issues("ruleset-drift")
        self.assertEqual(sorted(i["title"] for i in drifts),
                         ["Ruleset main is missing", "Ruleset verified-tags is missing"])
        for issue in drifts:
            self.assertIn("is missing", issue["body"])

    def test_ruleset_equal_except_generated_fields(self):
        live = live_detail(self.payloads["main"], 101,
                           bypass_actors=[{"actor_id": 5, "actor_type": "RepositoryRole",
                                           "bypass_mode": "always"}])
        self.gh["rulesets"] = [live, live_detail(self.payloads["verified-tags"], 102)]
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues(), [])
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)

    def test_rule_parameters_the_file_does_not_declare_are_not_drift(self):
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        live_main = next(r for r in self.gh["rulesets"] if r["name"] == "main")
        pr = next(r for r in live_main["rules"] if r["type"] == "pull_request")
        self.assertIn("dismissal_restriction", pr["parameters"])              # the fixture carries them live
        self.assertIn("require_extra_approval_for_unattributed_changes", pr["parameters"])
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues(), [])
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)

    def test_a_declared_parameter_with_a_different_live_value_is_drift(self):
        live = live_detail(self.payloads["main"], 101)
        next(r for r in live["rules"] if r["type"] == "pull_request")["parameters"][
            "dismiss_stale_reviews_on_push"] = True
        self.gh["rulesets"] = [live, live_detail(self.payloads["verified-tags"], 102)]
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        drifts = self.issues("ruleset-drift")
        self.assertEqual(len(drifts), 1, drifts)
        self.assertIn("main", drifts[0]["title"])
        self.assertIn("dismiss_stale_reviews_on_push", drifts[0]["body"])

    def test_ruleset_from_another_source_is_ignored(self):
        # An organization ruleset named main lives beside the repository's own; the list entry says which is which.
        foreign = live_detail(self.payloads["main"], 900, source_type="Organization", enforcement="evaluate")
        self.gh["rulesets"] = [live_detail(self.payloads["main"], 101), foreign,
                               live_detail(self.payloads["verified-tags"], 102)]
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, calls = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues(), [])
        self.assertFalse(any(c.startswith("gh api repos/teknoir/platform-applications-gitops/rulesets/900")
                             for c in calls), calls)

    def test_ruleset_differing_opens_ruleset_drift(self):
        self.gh["rulesets"] = [live_detail(self.payloads["main"], 101, enforcement="evaluate"),
                               live_detail(self.payloads["verified-tags"], 102)]
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        drifts = self.issues("ruleset-drift")
        self.assertEqual(len(drifts), 1, drifts)
        self.assertIn("main", drifts[0]["title"])
        self.assertIn("evaluate", drifts[0]["body"])
        self.assertIn("kind=ruleset name=main", drifts[0]["body"])

    def test_drift_issue_closes_when_the_ruleset_matches_again(self):
        self.seed_issue(9, "Ruleset main differs from .github/rulesets/main.json",
                        "<!-- gitops-watch kind=ruleset name=main -->", "ruleset-drift")
        self.git["commits"][SHA_OLD]["ct"] = self.now - 5 * 60
        proc, _ = self.run_watch()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.issues("ruleset-drift")[0]["state"], "closed")

    # --- dry run ---
    def test_dry_run_writes_nothing(self):
        proc, calls = self.run_watch("--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("dry-run: would create staging-alert issue", proc.stdout)
        self.assertEqual(self.issues(), [])
        self.assertFalse(any(WRITES.search(c) for c in calls), calls)


class MarkerCase(unittest.TestCase):
    def test_a_marker_value_with_spaces_round_trips(self):
        watch = H.load("watch", "watch.py")
        text = watch.marker("ruleset", name="My Ruleset")
        self.assertIn("My%20Ruleset", text)
        self.assertEqual(watch.parse_marker(text), {"kind": "ruleset", "name": "My Ruleset"})

    def test_a_tag_value_keeps_its_slashes(self):
        watch = H.load("watch", "watch.py")
        text = watch.marker("freight", tag="verified/20261124T101010Z-aaaaaaaa")
        self.assertIn("tag=verified/20261124T101010Z-aaaaaaaa", text)
        self.assertEqual(watch.parse_marker(text)["tag"], "verified/20261124T101010Z-aaaaaaaa")


if __name__ == "__main__":
    unittest.main()
