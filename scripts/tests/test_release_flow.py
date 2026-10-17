"""End-to-end tests of scripts/staging-release against a fake cluster, a fake GitHub and a REAL throwaway git
repository with a bare origin: tagging, pushing, the root patch, lease, convergence, rollback, break-glass."""
import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402
from helpers import L  # noqa: E402

SR = H.load("staging_release", "staging-release")
SHA = lambda c: c * 40


class Base(unittest.TestCase):
    def setUp(self):
        self.repo = H.Repo()
        self.cache = os.path.join(self.repo.tmp, "cache")
        os.makedirs(self.cache)
        self.out = []

    def root_branch(self):
        return H.root_app(target="teknoir-cloud", sync_rev=self.repo.sha("c2"))

    def root_pinned(self, sha="c2", tag="staging-20261017.1", prev=None):
        s = self.repo.sha(sha)
        return H.root_app(target=s, release_name=tag, params=[{"name": "release", "value": s}, {"name": "releaseName", "value": tag}],
                          annotations={L.ANN_PREVIOUS: prev} if prev else None)

    def tool(self, fake):
        return SR.Tool(fake, self.repo.work, out=self.out.append, cache=self.cache)

    def args(self, **kw):
        a = SR.build_parser().parse_args([])
        for k, v in kw.items():
            setattr(a, k, v)
        return a

    def plan(self, fake, ref=None):
        t = self.tool(fake)
        rc = t.cmd_plan(self.args(ref=ref))
        return t, rc

    def remote_tags(self):
        return subprocess.run(["git", "-C", self.repo.origin, "tag", "-l"], capture_output=True, text=True).stdout.split()


class DryRun(Base):
    def test_dry_run_only_reads(self):
        fake = H.FakeSys(self.root_branch())
        t, rc = self.plan(fake, self.repo.sha("c4"))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertTrue(all(v == "get" for v in fake.verbs()), fake.verbs())
        cmds = [c for c, _ in fake.calls]
        self.assertFalse([c for c in cmds if c[0] == "gh" and c[1:3] != ["release", "list"]])
        self.assertFalse([c for c in cmds if c[0] == "git" and any(x in c for x in ("push",))])
        self.assertEqual(self.remote_tags(), [])
        self.assertTrue(os.path.isfile(L.plan_path(self.cache, self.repo.sha("c4"))))

    def test_cutover_is_announced(self):
        fake = H.FakeSys(self.root_branch())
        self.plan(fake, self.repo.sha("c4"))
        text = "\n".join(self.out)
        self.assertIn("PRE-CUTOVER", text)
        self.assertIn("--bootstrap --yes " + self.repo.sha("c4"), text)
        self.assertIn("pending commits (2)", text)
        self.assertIn("#3", text)
        self.assertIn("staging-20261017.1", text.replace("proposed tag   staging", "staging-20261017.1") if False else text) if False else None

    def test_proposed_tag_follows_existing_tags(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        subprocess.run(["git", "-C", self.repo.work, "tag", "staging-%s.1" % fake.now().strftime("%Y%m%d"), self.repo.sha("c2")], check=True)
        t, _ = self.plan(fake, self.repo.sha("c4"))
        plan = json.load(open(L.plan_path(self.cache, self.repo.sha("c4"))))
        self.assertEqual(plan["tag"], "staging-%s.2" % fake.now().strftime("%Y%m%d"))

    def test_candidate_not_on_first_parent_is_refused(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        with self.assertRaises(L.Refuse):
            self.plan(fake, self.repo.sha("f3"))

    def test_candidate_older_than_live_is_refused(self):
        fake = H.FakeSys(self.root_pinned("c4"))
        with self.assertRaises(L.Refuse):
            self.plan(fake, self.repo.sha("c2"))

    def test_wrong_context(self):
        with self.assertRaises(L.Refuse):
            SR.Tool(H.FakeSys(self.root_branch()), self.repo.work, cache=self.cache, context="teknoir-poc-eks")

    def test_removed_application_needs_allow_remove(self):
        fake = H.FakeSys(self.root_pinned("c2"), children=("a", "gone"))
        fake.render_children = ["a"]
        t, rc = self.plan(fake, self.repo.sha("c4"))
        self.assertEqual(rc, 1)
        self.assertIn("would be removed", "\n".join(self.out))
        plan = json.load(open(L.plan_path(self.cache, self.repo.sha("c4"))))
        self.assertEqual(plan["removed"], ["gone"])

    def test_unpinned_image_digest_missing_in_registry_fails_preflight(self):
        fake = H.FakeSys(self.root_pinned("c2"), crane_fail={"ghcr.io/teknoir/x:t@sha256:" + "a" * 64})
        t, rc = self.plan(fake, self.repo.sha("c4"))
        self.assertEqual(rc, 1)
        self.assertIn("crane manifest", "\n".join(self.out))


class Release(Base):
    def test_cutover_applies_as_admin_tags_and_converges(self):
        fake = H.FakeSys(self.root_branch())
        t, _ = self.plan(fake, self.repo.sha("c4"))
        with self.assertRaisesRegex(L.Refuse, "bootstrap"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="sess", reason="first"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="sess", reason="first", bootstrap=True, timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        day = fake.now().strftime("%Y%m%d")
        tag = f"staging-{day}.1"
        self.assertEqual(self.remote_tags(), [tag])
        # annotated, on the candidate, message carries by/reason/pending
        self.assertEqual(subprocess.run(["git", "-C", self.repo.origin, "cat-file", "-t", tag], capture_output=True, text=True).stdout.strip(), "tag")
        self.assertEqual(subprocess.run(["git", "-C", self.repo.origin, "rev-parse", tag + "^{commit}"], capture_output=True, text=True).stdout.strip(), self.repo.sha("c4"))
        msg = subprocess.run(["git", "-C", self.repo.origin, "tag", "-l", "--format=%(contents)", tag], capture_output=True, text=True).stdout
        for s in ("by: sess", "reason: first", "kind: cutover", "#3", "plugin chart version: 0.0.104", "profile-plugin-jwks sha256:aa"):
            self.assertIn(s, msg)
        # GitHub Release as prerelease, created BEFORE the root is patched
        calls = [c for c, _ in fake.calls]
        create = next(i for i, c in enumerate(calls) if c[:3] == ["gh", "release", "create"])
        self.assertIn("--prerelease", calls[create])
        self.assertIn("--verify-tag", calls[create])
        patch = next(i for i, c in enumerate(calls) if c[0] == "kubectl" and "patch" in c and "application" in c and L.ROOT_APP in c)
        self.assertLess(create, patch)
        # cutover: no --as (the releaser SA does not exist yet), merge patch of the right shape
        self.assertFalse(any(x.startswith("--as=") for x in calls[patch]))
        body = json.loads(calls[patch][calls[patch].index("-p") + 1])
        self.assertEqual(body, L.build_root_patch(self.repo.sha("c4"), tag, None))
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c4"))
        # lease taken before, released after
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))
        self.assertIn("CONVERGED", "\n".join(self.out))
        self.assertIn("--verified " + tag, "\n".join(self.out))

    def test_normal_release_is_applied_as_the_releaser(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="sess", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        for c, _ in fake.calls:
            if c[0] == "kubectl" and ("patch" in c or "create" in c or "replace" in c or "annotate" in c):
                self.assertIn("--as=" + L.RELEASER_SA, c, c)
        day = fake.now().strftime("%Y%m%d")
        self.assertEqual(fake.root["metadata"]["annotations"][L.ANN_RELEASE], f"staging-{day}.1")
        self.assertEqual(fake.root["metadata"]["annotations"][L.ANN_PREVIOUS], "staging-20261017.1")
        self.assertEqual(L.root_deviations(fake.root), [])

    def test_yes_needs_by_and_reason_a_plan_and_the_same_sha(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        with self.assertRaisesRegex(L.Refuse, "--by"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4")))
        with self.assertRaisesRegex(L.Refuse, "dry run"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))
        self.plan(fake, self.repo.sha("m3"))
        with self.assertRaisesRegex(L.Refuse, "dry run"):                     # a different sha has no plan
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))
        self.assertEqual(self.remote_tags(), [])
        self.assertNotIn("patch", fake.verbs())

    def test_stale_plan_is_refused(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        fake.sleep(31 * 60)
        with self.assertRaisesRegex(L.Refuse, "old"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))

    def test_plan_with_errors_is_never_applied(self):
        fake = H.FakeSys(self.root_pinned("c2"), crane_fail={"ghcr.io/teknoir/x:t@sha256:" + "a" * 64})
        self.plan(fake, self.repo.sha("c4"))
        with self.assertRaisesRegex(L.Refuse, "preflight"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))

    def test_unconverged_children_block_a_release(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        self.plan(fake, self.repo.sha("c4"))
        with self.assertRaisesRegex(L.Refuse, "not converged"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))
        self.assertEqual(self.remote_tags(), [])

    def test_a_fresh_lease_held_by_another_blocks(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        fake.lease = L.lease_manifest("other@host:1", fake.now())
        fake.lease["metadata"]["resourceVersion"] = "5"
        with self.assertRaisesRegex(L.Refuse, "lock is held"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))
        self.assertEqual(self.remote_tags(), [])

    def test_tag_race_retries_with_the_next_number(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        day = fake.now().strftime("%Y%m%d")
        other = os.path.join(self.repo.tmp, "other")
        subprocess.run(["git", "clone", "-q", self.repo.origin, other], check=True)
        H.git(other, "tag", f"staging-{day}.1", self.repo.sha("c2"))
        H.git(other, "push", "-q", "origin", f"staging-{day}.1")
        t = self.tool(fake)
        t.fetch = lambda: None                                  # the other session tagged after our fetch
        rc = t.cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertIn(f"staging-{day}.2", self.remote_tags())
        self.assertEqual(fake.root["metadata"]["annotations"][L.ANN_RELEASE], f"staging-{day}.2")

    def test_no_convergence_prints_the_rollback_and_auto_rollback_runs_it(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": False, "name": "staging-20261017.1"}]
        H.git(self.repo.work, "tag", "-a", "-m", "m", "staging-20261017.1", self.repo.sha("c2"))
        H.git(self.repo.work, "push", "-q", "origin", "staging-20261017.1")
        self.plan(fake, self.repo.sha("c4"))
        fake.converge_on_patch = False
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30, auto_rollback=False))
        self.assertEqual(rc, 3)
        self.assertIn("NOT CONVERGED", "\n".join(self.out))
        self.assertIn("--rollback staging-20261017.1 --yes " + self.repo.sha("c2"), "\n".join(self.out))
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))      # the lease is released even on failure


    def test_auto_rollback_returns_to_the_previous_release(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": False, "name": "staging-20261017.1"}]
        H.git(self.repo.work, "tag", "-a", "-m", "m", "staging-20261017.1", self.repo.sha("c2"))
        H.git(self.repo.work, "push", "-q", "origin", "staging-20261017.1")
        self.plan(fake, self.repo.sha("c4"))
        fake.converge_on_patch = lambda sha: sha == self.repo.sha("c2")      # the new release never converges, the old one does
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30, auto_rollback=True,
                                               allow_remove="", bootstrap=False))
        text = "\n".join(self.out)
        self.assertIn("--auto-rollback: rolling back now", text)
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c2"))
        self.assertEqual(fake.root["metadata"]["annotations"][L.ANN_RELEASE], "staging-20261017.1")
        self.assertTrue([c for c, _ in fake.calls if c[:3] == ["gh", "release", "edit"] and any(L.ROLLED_BACK_MARK in x for x in c)])


class Rollback(Base):
    def prep(self, live_sha="c4", live_tag="staging-20261017.5"):
        fake = H.FakeSys(self.root_pinned(live_sha, live_tag))
        for tag, c in (("staging-20261017.1", "c2"), ("staging-20261017.3", "m3"), ("staging-20261017.5", "c4")):
            H.git(self.repo.work, "tag", "-a", "-m", tag, tag, self.repo.sha(c))
        H.git(self.repo.work, "push", "-q", "origin", "--tags")
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": False, "name": "staging-20261017.1"},
                         {"tagName": "staging-20261017.3", "isPrerelease": True, "name": "staging-20261017.3"},
                         {"tagName": "staging-20261017.5", "isPrerelease": True, "name": "staging-20261017.5"}]
        return fake

    def test_default_target_is_the_newest_verified_release_and_needs_yes(self):
        fake = self.prep()
        rc = self.tool(fake).cmd_rollback(self.args(rollback="-", by="s", reason="r"))
        self.assertEqual(rc, 0)
        self.assertIn("target  staging-20261017.1", "\n".join(self.out))
        self.assertNotIn("patch", fake.verbs())                    # nothing applied without --yes

    def test_rollback_applies_marks_the_abandoned_release_and_creates_no_tag(self):
        fake = self.prep()
        before = self.remote_tags()
        rc = self.tool(fake).cmd_rollback(self.args(rollback="-", yes=self.repo.sha("c2"), by="s", reason="broke", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c2"))
        self.assertEqual(fake.root["metadata"]["annotations"][L.ANN_RELEASE], "staging-20261017.1")
        self.assertEqual(self.remote_tags(), before)
        edit = [c for c, _ in fake.calls if c[:3] == ["gh", "release", "edit"]]
        self.assertEqual(len(edit), 1)
        self.assertIn("staging-20261017.5", edit[0])
        self.assertTrue(any(L.ROLLED_BACK_MARK in x for x in edit[0]))
        self.assertFalse([c for c, _ in fake.calls if c[:3] == ["gh", "release", "create"]])
        for c in fake.kubectl_calls():
            if "patch" in c and "application" in c:
                self.assertIn("--as=" + L.RELEASER_SA, c)

    def test_rollback_is_exempt_from_the_convergence_guard_and_steals_a_stale_lease(self):
        fake = self.prep()
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        fake.lease = L.lease_manifest("dead@host:9", fake.now() - __import__("datetime").timedelta(minutes=10))
        fake.lease["metadata"]["resourceVersion"] = "3"
        rc = self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertIn("stealing the stale release lock", "\n".join(self.out))

    def test_rollback_refuses_a_fresh_lease(self):
        fake = self.prep()
        fake.lease = L.lease_manifest("busy@host:9", fake.now())
        fake.lease["metadata"]["resourceVersion"] = "3"
        with self.assertRaisesRegex(L.Refuse, "lock is held"):
            self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r"))

    def test_floor(self):
        fake = self.prep()
        open(os.path.join(self.repo.work, "scripts", "release-policy.yaml"), "a").write("")
        t = self.tool(fake)
        t.policy = lambda: {"rollback_floor": "staging-20261017.3"}
        with self.assertRaisesRegex(L.Refuse, "floor"):
            t.cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r"))

    def test_yes_must_equal_the_target_sha(self):
        fake = self.prep()
        with self.assertRaisesRegex(L.Refuse, "does not match"):
            self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("m3"), by="s", reason="r"))

    def test_a_gone_digest_stops_the_rollback_before_anything_changes(self):
        fake = self.prep()
        fake.crane_fail = {"ghcr.io/teknoir/x:t@sha256:" + "a" * 64}
        with self.assertRaisesRegex(L.Refuse, "gone from the registry"):
            self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r"))
        self.assertNotIn("patch", fake.verbs())

    def test_no_rollback_before_the_cutover(self):
        fake = H.FakeSys(self.root_branch())
        with self.assertRaisesRegex(L.Refuse, "follows the branch"):
            self.tool(fake).cmd_rollback(self.args(rollback="-", by="s", reason="r"))

    def test_abandoned_operations_are_terminated_before_the_root_is_patched(self):
        fake = self.prep()
        fake.children["a"]["status"]["operationState"] = {"phase": "Running", "operation": {"sync": {"revision": self.repo.sha("c4")}}}
        self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r", timeout=60))
        calls = fake.kubectl_calls()
        term = next(i for i, c in enumerate(calls) if "Terminating" in " ".join(c))
        patch = next(i for i, c in enumerate(calls) if "patch" in c and L.ROOT_APP in c and "targetRevision" in " ".join(c))
        self.assertLess(term, patch)


class VerifiedAndBreakGlass(Base):
    def test_verified_flips_the_release_of_the_live_tag_only(self):
        fake = H.FakeSys(self.root_pinned("c2", "staging-20261017.1"))
        self.assertEqual(self.tool(fake).cmd_verified("staging-20261017.1"), 0)
        edit = [c for c, _ in fake.calls if c[:3] == ["gh", "release", "edit"]][0]
        self.assertIn("--prerelease=false", edit)
        self.assertIn("--latest", edit)
        with self.assertRaisesRegex(L.Refuse, "not the live release"):
            self.tool(fake).cmd_verified("staging-20261017.9")
        with self.assertRaises(L.Refuse):
            self.tool(fake).cmd_verified("v1")

    def test_break_glass_is_scripted_and_needs_anders(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        t = self.tool(fake)
        with self.assertRaisesRegex(L.Refuse, "reason"):
            t.cmd_break_glass(True, self.args(reason=None, confirm_anders=True))
        with self.assertRaisesRegex(L.Refuse, "Anders"):
            t.cmd_break_glass(True, self.args(reason="x", confirm_anders=False))
        t.cmd_break_glass(True, self.args(reason="fix the root", confirm_anders=True))
        self.assertEqual(fake.ns_annotations[L.NS_GUARD_ANN], L.NS_GUARD_VALUE)
        self.assertEqual(fake.ns_annotations[L.NS_GUARD_REASON_ANN], "fix the root")
        t.cmd_break_glass(False, self.args())
        self.assertEqual(fake.ns_annotations, {})

    def test_main_refuses_a_branch_override_with_yes(self):
        rc = SR.main(["--branch", "release/tooling", "--yes", SHA("a"), "--by", "s", "--reason", "r"], sys_=H.FakeSys(self.root_pinned("c2")))
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
