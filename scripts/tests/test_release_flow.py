"""End-to-end tests of scripts/staging-release against a fake cluster, a fake GitHub and a REAL throwaway git
repository with a bare origin: tagging, pushing, the root patch, lease, convergence, rollback, break-glass."""
import datetime
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

    def out_text(self):
        return "\n".join(self.out)

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

    def plan(self, fake, ref=None, **kw):
        t = self.tool(fake)
        rc = t.cmd_plan(self.args(ref=ref, **kw))
        return t, rc

    def add_commit(self, name, fname, content):
        """A new head of origin/teknoir-cloud (the throwaway repo's working tree is on that branch)."""
        sha = self.repo.commit(name, fname, content)
        self.repo.c[name] = sha
        H.git(self.repo.work, "push", "-q", "origin", "teknoir-cloud")
        H.git(self.repo.work, "fetch", "-q", "origin")
        return sha

    def edit_policy_uncommitted(self, text):
        with open(os.path.join(self.repo.work, "scripts", "release-policy.yaml"), "a") as fh:
            fh.write(text)

    def pod(self, name, *, ns="teknoir-system", owner=("ReplicaSet", "a-5d9f7c"), created="2026-10-17T11:00:00Z", phase="Running",
            waiting=None, labels=None):
        st = {"phase": phase, "containerStatuses": [{"name": "c", "state": {"waiting": {"reason": waiting}} if waiting else {"running": {"startedAt": created}}}]}
        md = {"name": name, "namespace": ns, "creationTimestamp": created, "labels": labels or {}}
        if owner:
            md["ownerReferences"] = [{"kind": owner[0], "name": owner[1], "controller": True}]
        return {"metadata": md, "status": st, "spec": {"containers": [{"name": "c", "image": "ghcr.io/teknoir/x:t@sha256:" + "a" * 64}]}}

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
        fake = H.FakeSys(self.root_branch(), releaser_installed=False)
        self.plan(fake, self.repo.sha("c4"))
        text = "\n".join(self.out)
        self.assertIn("PRE-CUTOVER", text)
        self.assertIn("--bootstrap --yes " + self.repo.sha("c4"), text)
        self.assertIn("pending commits (2)", text)
        self.assertIn("#3", text)
        self.assertIn("proposed tag   staging-%s.1   mode cutover" % fake.now().strftime("%Y%m%d"), text)

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
        fake = H.FakeSys(self.root_branch(), releaser_installed=False)
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
        self.assertIn("guard not installed: applying as admin", "\n".join(self.out))
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


class IdentityAndGuards(Base):
    def test_the_fake_refuses_an_unknown_serviceaccount(self):
        fake = H.FakeSys(self.root_pinned("c2"), releaser_installed=False)
        r = fake.run(["kubectl", "--context", "vpro", "--as=" + L.RELEASER_SA, "-n", L.NAMESPACE, "patch", "application", L.ROOT_APP,
                      "--type", "merge", "-p", "{}"], check=False)
        self.assertEqual(r.rc, 1)
        self.assertIn("Forbidden", r.err)

    def test_release_2_without_the_guard_installed_applies_as_admin_with_a_notice(self):
        # the blocker of the review: the releaser SA/RoleBinding are created by the release-guard chart, which release
        # .2 itself switches on, so release .2 must not impersonate them
        fake = H.FakeSys(self.root_pinned("c2"), releaser_installed=False)
        self.plan(fake, self.repo.sha("c4"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertIn("guard not installed: applying as admin", "\n".join(self.out))
        self.assertFalse([c for c, _ in fake.calls if any(x.startswith("--as=") for x in c) and "auth" not in c])
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c4"))
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))

    def test_releaser_present_but_without_rights_falls_back_to_admin(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.releaser_can_i = False
        self.plan(fake, self.repo.sha("c4"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertIn("cannot patch applications", "\n".join(self.out))

    def test_rollback_without_the_guard_applies_as_admin(self):
        fake = Rollback.prep(self, releaser_installed=False)
        rc = self.tool(fake).cmd_rollback(self.args(rollback="-", yes=self.repo.sha("c2"), by="s", reason="r", timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertIn("guard not installed", "\n".join(self.out))

    def test_cutover_runs_the_convergence_guard_when_the_candidate_is_the_synced_revision(self):
        # at the cutover the candidate (branch head) == the commit the branch-following root has synced == 'live': noop
        c4 = self.repo.sha("c4")
        root = H.root_app(target="teknoir-cloud", sync_rev=c4)
        fake = H.FakeSys(root, releaser_installed=False)
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        self.plan(fake, c4)
        with self.assertRaisesRegex(L.Refuse, "not converged"):
            self.tool(fake).cmd_yes(self.args(yes=c4, by="s", reason="first", bootstrap=True, timeout=30))
        self.assertEqual(self.remote_tags(), [])
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], "teknoir-cloud")
        # healthy: the same cutover goes through
        fake2 = H.FakeSys(root, releaser_installed=False)
        self.plan(fake2, c4)
        rc = self.tool(fake2).cmd_yes(self.args(yes=c4, by="s", reason="first", bootstrap=True, timeout=60))
        self.assertEqual(rc, 0, "\n".join(self.out))

    def test_a_rerun_of_the_live_sha_after_the_cutover_is_still_exempt(self):
        fake = H.FakeSys(self.root_pinned("c4"))
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        self.plan(fake, self.repo.sha("c4"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="re-run", timeout=30))
        self.assertIn(rc, (0, 3))

    def test_the_live_release_is_read_again_under_the_lease(self):
        class Moving(H.FakeSys):
            def _kube(self, argv):
                r = super()._kube(argv)
                if "create" in argv and "-" in argv and self.lease and not getattr(self, "moved", False):
                    self.moved = True          # another release lands right after our lease
                    self.root = H.root_app(target=SHA("e"), release_name="staging-20261017.7",
                                           params=[{"name": "release", "value": SHA("e")}, {"name": "releaseName", "value": "staging-20261017.7"}])
                return r
        fake = Moving(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        with self.assertRaisesRegex(L.Refuse, "live release moved"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(self.remote_tags(), [])
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))          # the lease is released again

    def test_registry_check_skipped_in_the_dry_run_blocks_yes_unless_repeated(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"), skip_registry_check=True)
        plan = json.load(open(L.plan_path(self.cache, self.repo.sha("c4"))))
        self.assertFalse(plan["registry_checked"])
        with self.assertRaisesRegex(L.Refuse, "registry"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r"))
        self.assertEqual(self.remote_tags(), [])
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=60, skip_registry_check=True))
        self.assertEqual(rc, 0, "\n".join(self.out))
        day = fake.now().strftime("%Y%m%d")
        msg = subprocess.run(["git", "-C", self.repo.origin, "tag", "-l", "--format=%(contents)", f"staging-{day}.1"], capture_output=True, text=True).stdout
        self.assertIn("registry check: SKIPPED", msg)

    def test_a_checked_plan_records_it_and_the_tag_records_the_guard_warn_baseline(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.metrics = ('apiserver_validating_admission_policy_check_total{enforcement_action="warn",error_type="invalid_error",'
                        'policy="staging-release-guard",policy_binding="staging-release-guard-binding"} 7\n')
        self.plan(fake, self.repo.sha("c4"))
        self.assertTrue(json.load(open(L.plan_path(self.cache, self.repo.sha("c4"))))["registry_checked"])
        self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=60))
        day = fake.now().strftime("%Y%m%d")
        msg = subprocess.run(["git", "-C", self.repo.origin, "tag", "-l", "--format=%(contents)", f"staging-{day}.1"], capture_output=True, text=True).stdout
        self.assertIn("registry check: every digest-pinned image resolved", msg)
        self.assertIn("guard warn count at release: 7", msg)

    def test_a_failed_root_patch_marks_the_release_not_applied(self):
        fake = H.FakeSys(self.root_pinned("c2", tag="staging-20261016.5"))
        self.plan(fake, self.repo.sha("c4"))
        fake.patch_fails = True
        # the root was read again before the Release was marked
        with self.assertRaisesRegex(L.Refuse, r"root patch FAILED.*the root was read again: annotation staging-20261016.5, targetRevision"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        day = fake.now().strftime("%Y%m%d")
        tag = f"staging-{day}.1"
        self.assertEqual(self.remote_tags(), [tag])                      # tags are immutable: it stays
        rel = next(r for r in fake.releases if r["tagName"] == tag)
        self.assertTrue(rel["name"].startswith(L.NOT_APPLIED_MARK + " "), rel["name"])
        self.assertIn(L.NOT_APPLIED_TRAILER, rel["body"].splitlines())
        self.assertIn("by: s", rel["body"])                              # the original body is kept
        self.assertTrue(L.is_marked(rel["name"], rel["body"]))
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c2"))
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))

    def failed_patch_setup(self, **flags):
        fake = H.FakeSys(self.root_pinned("c2", tag="staging-20261016.5"))
        self.plan(fake, self.repo.sha("c4"))
        for k, v in flags.items():
            setattr(fake, k, v)
        return fake

    def test_a_failed_patch_that_the_apiserver_applied_is_not_marked_and_the_watch_continues(self):
        fake = self.failed_patch_setup(patch_applies_then_fails=True)
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(rc, 0, self.out_text())
        tag = f"staging-{fake.now().strftime('%Y%m%d')}.1"
        rel = next(r for r in fake.releases if r["tagName"] == tag)
        self.assertEqual(rel["name"], tag)                                         # not marked
        self.assertNotIn(L.NOT_APPLIED_TRAILER, rel["body"].splitlines())
        self.assertIn("but the root IS", self.out_text())
        self.assertIn("CONVERGED", self.out_text())
        self.assertEqual(fake.root["spec"]["source"]["targetRevision"], self.repo.sha("c4"))

    def test_a_failed_patch_with_an_unreadable_root_is_reported_as_ambiguous_and_not_marked(self):
        fake = self.failed_patch_setup(patch_fails=True, unreadable_after_patch_fail=True)
        with self.assertRaisesRegex(L.Refuse, "could not be classified"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        tag = f"staging-{fake.now().strftime('%Y%m%d')}.1"
        rel = next(r for r in fake.releases if r["tagName"] == tag)
        self.assertEqual(rel["name"], tag)
        self.assertNotIn(L.NOT_APPLIED_TRAILER, rel["body"].splitlines())
        self.assertFalse([c for c, _ in fake.calls if c[:3] == ["gh", "release", "edit"]])
        self.assertFalse(fake.lease["spec"].get("holderIdentity"))                 # the lease is released either way

    def test_a_failed_patch_that_left_a_mixed_root_is_ambiguous(self):
        fake = self.failed_patch_setup(patch_fails=True)
        t = self.tool(fake)
        sha, tag = self.repo.sha("c4"), "staging-20261017.9"
        fake.root["metadata"]["annotations"][L.ANN_RELEASE] = tag                  # the annotation moved, the revision did not
        self.assertEqual(t.root_after_failed_patch(sha, tag)[0], "unknown")
        fake.root["metadata"]["annotations"][L.ANN_RELEASE] = "staging-20261016.5"
        self.assertEqual(t.root_after_failed_patch(sha, tag)[0], "not-applied")

    def test_policy_and_lint_come_from_the_candidate_not_the_checkout(self):
        c5 = self.add_commit("c5", "scripts/release-policy.yaml", open(os.path.join(self.repo.work, "scripts", "release-policy.yaml")).read() + "\nrollback_floor: staging-20261017.3\n")
        # the checkout (what the operator runs) says something else, uncommitted
        self.edit_policy_uncommitted("\nimages: deny\n")
        t = self.tool(H.FakeSys(self.root_pinned("c2")))
        cp, pol, notes = t.lint_tools(t.worktree(c5), c5)
        self.assertEqual(pol["rollback_floor"], "staging-20261017.3")
        self.assertEqual(pol["images"], "warn")                          # not the checkout's 'deny'
        self.assertTrue(any("check-pins.py" in n for n in notes))        # the throwaway candidate has no lint code: ours, said so

    def test_the_candidates_lint_code_is_the_one_that_runs(self):
        marker = os.path.join(self.repo.tmp, "lint-ran")
        lint = open(os.path.join(H.SCRIPTS, "check-pins.py")).read() + f"\n\n_orig_lint = lint\ndef lint(*a, **k):\n    open({marker!r}, 'w').write('candidate')\n    return _orig_lint(*a, **k)\n"
        c5 = self.add_commit("c5", "scripts/check-pins.py", lint)
        fake = H.FakeSys(self.root_pinned("c2"))
        t, rc = self.plan(fake, c5)
        self.assertEqual(rc, 0, "\n".join(self.out))
        self.assertTrue(os.path.isfile(marker))

    def test_the_rollback_floor_comes_from_origin_not_the_checkout(self):
        fake = Rollback.prep(self)
        self.add_commit("c6", "scripts/release-policy.yaml", open(os.path.join(self.repo.work, "scripts", "release-policy.yaml")).read() + "\nrollback_floor: staging-20261017.3\n")
        # the operator's checkout has an empty floor (uncommitted)
        path = os.path.join(self.repo.work, "scripts", "release-policy.yaml")
        txt = open(path).read().replace("rollback_floor: staging-20261017.3", 'rollback_floor: ""')
        open(path, "w").write(txt)
        self.assertEqual(self.tool(fake).rollback_floor(), "staging-20261017.3")
        with self.assertRaisesRegex(L.Refuse, "floor"):
            self.tool(fake).cmd_rollback(self.args(rollback="staging-20261017.1", yes=self.repo.sha("c2"), by="s", reason="r"))

    def commit_local_scripts_change(self):
        """A commit on the checkout that is NOT on origin/teknoir-cloud: the checkout's scripts/ tree differs."""
        H.git(self.repo.work, "checkout", "-q", "-b", "local-tooling")
        self.repo.commit("local tooling", "scripts/release-policy.yaml",
                         open(os.path.join(self.repo.work, "scripts", "release-policy.yaml")).read() + "\n# local\n")

    def test_yes_is_refused_from_a_checkout_whose_scripts_are_uncommitted(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        self.edit_policy_uncommitted("# stale or edited checkout\n")
        with self.assertRaisesRegex(L.Refuse, "scripts/ of this checkout .* is not clean: scripts/release-policy.yaml"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(self.remote_tags(), [])
        self.assertNotIn("create", fake.verbs())                         # nothing was touched, not even the lease

    def test_yes_is_refused_when_scripts_hold_an_untracked_file(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        with open(os.path.join(self.repo.work, "scripts", "check-pins.py"), "w") as fh:     # untracked: git diff would not see it
            fh.write("# planted\n")
        with self.assertRaisesRegex(L.Refuse, "not clean: scripts/check-pins.py"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(self.remote_tags(), [])
        self.assertNotIn("create", fake.verbs())

    def test_a_pycache_is_not_a_difference(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        os.makedirs(os.path.join(self.repo.work, "scripts", "__pycache__"))
        with open(os.path.join(self.repo.work, "scripts", "__pycache__", "stagelib.cpython-313.pyc"), "w") as fh:
            fh.write("x")
        self.assertEqual(self.tool(fake).tooling()["dirty"], [])
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(rc, 0, self.out_text())

    def test_yes_is_refused_from_a_checkout_whose_committed_scripts_differ_from_the_candidates(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        self.commit_local_scripts_change()
        with self.assertRaisesRegex(L.Refuse, "differs from that of the candidate"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(self.remote_tags(), [])
        self.assertNotIn("create", fake.verbs())

    def test_the_plan_records_the_tooling_and_yes_refuses_a_plan_made_by_other_tooling(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.plan(fake, self.repo.sha("c4"))
        planfile = L.plan_path(self.cache, self.repo.sha("c4"))
        plan = json.load(open(planfile))
        want = H.git(self.repo.work, "rev-parse", f"{self.repo.sha('c4')}:scripts")
        self.assertEqual(plan["tooling"], {"tree": want, "dirty": []})           # == git rev-parse <cand>:scripts
        # a plan written by a dirty or different checkout is refused even though THIS checkout is fine
        plan["tooling"] = {"tree": "0" * 40, "dirty": []}
        json.dump(plan, open(planfile, "w"))
        with self.assertRaisesRegex(L.Refuse, "made by other tooling"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        plan["tooling"] = {"tree": want, "dirty": ["scripts/x.py"]}
        json.dump(plan, open(planfile, "w"))
        with self.assertRaisesRegex(L.Refuse, "made by other tooling.*not clean"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        del plan["tooling"]                                                      # an old plan without the identity
        json.dump(plan, open(planfile, "w"))
        with self.assertRaisesRegex(L.Refuse, "made by other tooling"):
            self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=30))
        self.assertEqual(self.remote_tags(), [])

    def test_a_dry_run_from_a_dirty_scripts_tree_says_so_and_records_it(self):
        fake = H.FakeSys(self.root_pinned("c2"))
        self.edit_policy_uncommitted("# edited\n")
        self.plan(fake, self.repo.sha("c4"))
        self.assertIn("scripts/ of this checkout is not clean", self.out_text())
        plan = json.load(open(L.plan_path(self.cache, self.repo.sha("c4"))))
        self.assertEqual(plan["tooling"]["dirty"], ["scripts/release-policy.yaml"])

    def test_rollback_is_refused_from_a_checkout_with_unrelated_scripts(self):
        fake = Rollback.prep(self)
        self.edit_policy_uncommitted("# edited\n")
        with self.assertRaisesRegex(L.Refuse, "not clean"):
            self.tool(fake).cmd_rollback(self.args(rollback="-", yes=self.repo.sha("c2"), by="s", reason="r", timeout=30))
        self.assertNotIn("patch", fake.verbs())

    def test_rollback_is_refused_from_a_checkout_with_untracked_scripts_or_other_committed_scripts(self):
        fake = Rollback.prep(self)
        with open(os.path.join(self.repo.work, "scripts", "extra.py"), "w") as fh:
            fh.write("x")
        with self.assertRaisesRegex(L.Refuse, "not clean: scripts/extra.py"):
            self.tool(fake).cmd_rollback(self.args(rollback="-", yes=self.repo.sha("c2"), by="s", reason="r", timeout=30))
        os.unlink(os.path.join(self.repo.work, "scripts", "extra.py"))
        self.commit_local_scripts_change()
        with self.assertRaisesRegex(L.Refuse, "differs from that of"):
            self.tool(fake).cmd_rollback(self.args(rollback="-", yes=self.repo.sha("c2"), by="s", reason="r", timeout=30))
        self.assertNotIn("patch", fake.verbs())


class WatchPods(Base):
    def run_release(self, pods, timeout=30):
        fake = H.FakeSys(self.root_pinned("c2"))
        fake.pods = pods
        self.plan(fake, self.repo.sha("c4"))
        rc = self.tool(fake).cmd_yes(self.args(yes=self.repo.sha("c4"), by="s", reason="r", timeout=timeout))
        return rc, fake

    def test_an_old_unrelated_failing_pod_does_not_fail_the_release(self):
        rc, _ = self.run_release([self.pod("old-job-x", owner=("Job", "some-job"), waiting="CrashLoopBackOff")])
        self.assertEqual(rc, 0, "\n".join(self.out))

    def test_argo_workflow_pods_are_ignored_even_when_new(self):
        rc, _ = self.run_release([self.pod("wf-1", ns="teknoir-ci", owner=("Workflow", "wf"), created="2026-10-17T12:30:00Z",
                                            waiting="ImagePullBackOff", labels={"workflows.argoproj.io/workflow": "wf"})])
        self.assertEqual(rc, 0, "\n".join(self.out))

    def test_a_failing_pod_of_a_rendered_workload_fails_it(self):
        rc, _ = self.run_release([self.pod("a-5d9f7c-x", waiting="CrashLoopBackOff")])
        self.assertEqual(rc, 3)
        self.assertIn("a-5d9f7c-x: CrashLoopBackOff", "\n".join(self.out))

    def test_a_pod_started_after_the_patch_counts_even_when_its_workload_is_not_rendered(self):
        rc, _ = self.run_release([self.pod("new-x", owner=("ReplicaSet", "other-7f"), created="2026-10-17T12:30:00Z", waiting="ErrImagePull")])
        self.assertEqual(rc, 3)

    def test_pending_beyond_the_grace_period_fails_it(self):
        rc, _ = self.run_release([self.pod("a-5d9f7c-y", phase="Pending", created="2026-10-17T11:00:00Z")])
        self.assertEqual(rc, 3)
        self.assertIn("Pending for", "\n".join(self.out))

    def test_pod_problems_unit(self):
        P = SR.pod_problems
        now = datetime.datetime(2026, 10, 17, 12, 0, tzinfo=datetime.timezone.utc)
        since = now
        rendered = {"teknoir-system/Deployment/a", "/StatefulSet/db"}
        # Pending but young
        self.assertEqual(P([self.pod("a-1", phase="Pending", created="2026-10-17T11:59:00Z")], now=now, since=since, rendered=rendered), [])
        # a StatefulSet pod matched through a namespace-less render entry
        self.assertEqual(len(P([self.pod("db-0", owner=("StatefulSet", "db"), waiting="CreateContainerConfigError")], now=now, since=since, rendered=rendered)), 1)
        # a CronJob run (Job <cronjob>-<timestamp>) of a rendered CronJob
        self.assertEqual(len(P([self.pod("cj-1", owner=("Job", "backup-29412345"), waiting="ImagePullBackOff")], now=now, since=since,
                               rendered={"teknoir-system/CronJob/backup"})), 1)
        # a restart after the patch of a pod that predates it
        pod = self.pod("o-1", owner=("ReplicaSet", "other-1"), waiting="CrashLoopBackOff")
        pod["status"]["containerStatuses"][0]["lastState"] = {"terminated": {"finishedAt": "2026-10-17T12:00:20Z"}}
        self.assertEqual(len(P([pod], now=now, since=since, rendered=rendered)), 1)
        # other namespaces are not platform namespaces
        self.assertEqual(P([self.pod("a-1", ns="teknoir-demo", waiting="CrashLoopBackOff")], now=now, since=since, rendered=rendered), [])


class Rollback(Base):
    def prep(self, live_sha="c4", live_tag="staging-20261017.5", **kw):
        fake = H.FakeSys(self.root_pinned(live_sha, live_tag), **kw)
        for tag, c in (("staging-20261017.1", "c2"), ("staging-20261017.3", "m3"), ("staging-20261017.5", "c4")):
            H.git(self.repo.work, "tag", "-a", "-m", tag, tag, self.repo.sha(c))
        H.git(self.repo.work, "push", "-q", "origin", "--tags")
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": False, "name": "staging-20261017.1", "body": "first"},
                         {"tagName": "staging-20261017.3", "isPrerelease": True, "name": "staging-20261017.3", "body": "third"},
                         {"tagName": "staging-20261017.5", "isPrerelease": True, "name": "staging-20261017.5", "body": "original body of five"}]
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
        # the marker contract (with infra staging-root.sh): title PREFIX and a body trailer line, original body kept
        rel = next(r for r in fake.releases if r["tagName"] == "staging-20261017.5")
        self.assertEqual(rel["name"], "[rolled back] staging-20261017.5")
        self.assertIn("Rolled-Back: true", rel["body"].splitlines())
        self.assertIn("original body of five", rel["body"])
        self.assertTrue(L.is_marked(rel["name"]))
        self.assertFalse([c for c, _ in fake.calls if c[:3] == ["gh", "release", "create"]])
        for c in fake.kubectl_calls():
            if "patch" in c and "application" in c:
                self.assertIn("--as=" + L.RELEASER_SA, c)

    def test_rollback_is_exempt_from_the_convergence_guard_and_steals_a_stale_lease(self):
        fake = self.prep()
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        fake.lease = L.lease_manifest("dead@host:9", fake.now() - datetime.timedelta(minutes=10))
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
        t = self.tool(fake)
        t.rollback_floor = lambda: "staging-20261017.3"
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
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": True, "name": "staging-20261017.1", "body": ""}]
        self.assertEqual(self.tool(fake).cmd_verified("staging-20261017.1"), 0)
        edit = [c for c, _ in fake.calls if c[:3] == ["gh", "release", "edit"]][0]
        self.assertIn("--prerelease=false", edit)
        self.assertIn("--latest", edit)
        with self.assertRaisesRegex(L.Refuse, "not the live release"):
            self.tool(fake).cmd_verified("staging-20261017.9")
        with self.assertRaises(L.Refuse):
            self.tool(fake).cmd_verified("v1")

    def test_verified_needs_convergence_and_a_root_as_the_release_wrote_it(self):
        fake = H.FakeSys(self.root_pinned("c2", "staging-20261017.1"))
        fake.releases = [{"tagName": "staging-20261017.1", "isPrerelease": True, "name": "staging-20261017.1", "body": ""}]
        fake.children["a"]["status"]["health"]["status"] = "Degraded"
        with self.assertRaisesRegex(L.Refuse, "does not match it"):
            self.tool(fake).cmd_verified("staging-20261017.1")
        fake.children["a"]["status"]["health"]["status"] = "Healthy"
        fake.root["spec"]["syncPolicy"]["automated"]["prune"] = False
        with self.assertRaisesRegex(L.Refuse, "prune"):
            self.tool(fake).cmd_verified("staging-20261017.1")
        fake.root["spec"]["syncPolicy"]["automated"]["prune"] = True
        self.assertEqual(self.tool(fake).cmd_verified("staging-20261017.1"), 0)
        self.assertFalse(fake.releases[0]["isPrerelease"])

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
