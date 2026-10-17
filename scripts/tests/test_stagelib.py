import datetime as dt
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402
from helpers import L  # noqa: E402

SHA1 = "1" * 40
SHA2 = "2" * 40
NOW = dt.datetime(2026, 10, 17, 12, 0, tzinfo=dt.timezone.utc)


class TagNumbering(unittest.TestCase):
    def test_first_of_the_day(self):
        self.assertEqual(L.next_tag([], dt.date(2026, 10, 17)), "staging-20261017.1")

    def test_other_days_do_not_count(self):
        self.assertEqual(L.next_tag(["staging-20261016.7"], dt.date(2026, 10, 17)), "staging-20261017.1")

    def test_increments_numerically_not_lexically(self):
        tags = [f"staging-20261017.{n}" for n in (1, 2, 9, 10)]
        self.assertEqual(L.next_tag(tags, dt.date(2026, 10, 17)), "staging-20261017.11")

    def test_ignores_foreign_tags(self):
        self.assertEqual(L.next_tag(["pre-release-gating/teknoir-cloud", "v1"], dt.date(2026, 10, 17)), "staging-20261017.1")

    def test_ordering_and_floor(self):
        self.assertTrue(L.tag_at_or_after("staging-20261018.1", "staging-20261017.9"))
        self.assertTrue(L.tag_at_or_after("staging-20261017.10", "staging-20261017.2"))
        self.assertFalse(L.tag_at_or_after("staging-20261017.1", "staging-20261017.2"))
        with self.assertRaises(ValueError):
            L.tag_key("v1")


class Guards(unittest.TestCase):
    def test_context_must_be_vpro(self):
        self.assertEqual(L.guard_context("vpro"), "vpro")
        for bad in ("teknoir-poc-eks", "k3d-teknoir-dev", "r415", "", "vpro2", "prod", "teknoir-online", "vpro-prod"):
            with self.assertRaises(L.Refuse, msg=bad):
                L.guard_context(bad)

    def test_kube_refuses_other_contexts_at_construction(self):
        with self.assertRaises(L.Refuse):
            L.Kube(L.Sys(), "teknoir-poc-eks")

    def test_kube_always_sets_context_and_as_only_for_the_releaser(self):
        k = L.Kube(L.Sys(), "vpro")
        self.assertEqual(k.base()[:3], ["kubectl", "--context", "vpro"])
        self.assertNotIn("--as=" + L.RELEASER_SA, k.base())
        self.assertIn("--as=" + L.RELEASER_SA, k.base(as_releaser=True))


class Candidate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = H.Repo()
        cls.g = L.Git(L.Sys(), cls.r.work)
        cls.fp = cls.g.first_parent("origin/teknoir-cloud")

    def validate(self, cand, live):
        return L.validate_candidate(self.fp, self.g.is_ancestor, cand, live)

    def test_first_parent_line_excludes_merged_branch_commits(self):
        self.assertIn(self.r.sha("m3"), self.fp)
        self.assertNotIn(self.r.sha("f3"), self.fp)       # on the branch, but only via the merge

    def test_forward_prefix_release(self):
        self.assertEqual(self.validate(self.r.sha("m3"), self.r.sha("c2")), "forward")
        self.assertEqual(self.validate(self.r.sha("c4"), self.r.sha("c2")), "forward")

    def test_squash_and_merge_commits_both_work(self):
        self.assertEqual(self.validate(self.r.sha("c4"), self.r.sha("m3")), "forward")

    def test_noop_for_the_live_commit(self):
        self.assertEqual(self.validate(self.r.sha("m3"), self.r.sha("m3")), "noop")

    def test_older_than_live_is_refused(self):
        with self.assertRaisesRegex(L.Refuse, "older"):
            self.validate(self.r.sha("c2"), self.r.sha("c4"))

    def test_commit_inside_a_merged_branch_is_refused(self):
        with self.assertRaisesRegex(L.Refuse, "first-parent"):
            self.validate(self.r.sha("f3"), self.r.sha("c2"))

    def test_unknown_or_short_sha_is_refused(self):
        with self.assertRaises(L.Refuse):
            self.validate("abc1234", self.r.sha("c2"))
        with self.assertRaises(L.Refuse):
            self.validate("f" * 40, self.r.sha("c2"))

    def test_pending_lists_first_parent_commits_with_pr_and_branch(self):
        pend = self.g.pending(self.r.sha("c2"), self.r.sha("c4"))
        self.assertEqual([p["sha"] for p in pend], [self.r.sha("m3"), self.r.sha("c4")])
        self.assertEqual((pend[0]["pr"], pend[0]["branch"]), (3, "feature"))
        self.assertEqual((pend[1]["pr"], pend[1]["branch"]), (4, ""))

    def test_parse_pr(self):
        self.assertEqual(L.parse_pr("Merge pull request #63 from teknoir/dc/remove-ssh-pin"), {"pr": 63, "branch": "dc/remove-ssh-pin"})
        self.assertEqual(L.parse_pr("user-controller: x (#64)"), {"pr": 64, "branch": ""})
        self.assertEqual(L.parse_pr("no number"), {"pr": None, "branch": ""})


class Rollback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r = H.Repo()
        cls.g = L.Git(L.Sys(), cls.r.work)

    def v(self, tag, target, live, floor=None, live_tag="staging-20261017.5"):
        L.validate_rollback_target(tag, self.r.sha(target), self.r.sha(live), self.g.is_ancestor, floor, live_tag)

    def test_earlier_release_ok(self):
        self.v("staging-20261017.3", "c2", "c4")

    def test_floor(self):
        self.v("staging-20261017.3", "c2", "c4", floor="staging-20261017.3")
        with self.assertRaisesRegex(L.Refuse, "floor"):
            self.v("staging-20261017.2", "c2", "c4", floor="staging-20261017.3")

    def test_newer_or_same_is_refused(self):
        with self.assertRaisesRegex(L.Refuse, "not older"):
            self.v("staging-20261017.9", "c4", "c2")
        with self.assertRaisesRegex(L.Refuse, "live release"):
            self.v("staging-20261017.5", "c2", "c4")

    def test_not_a_staging_tag(self):
        with self.assertRaises(L.Refuse):
            self.v("v1", "c2", "c4")


class PlanAndLease(unittest.TestCase):
    def plan(self, **kw):
        return {"candidate": SHA1, "live": SHA2, "created": NOW.isoformat(), **kw}

    def test_yes_must_equal_the_dry_run_candidate(self):
        L.plan_check(self.plan(), SHA1, NOW, SHA2)
        with self.assertRaisesRegex(L.Refuse, "does not match"):
            L.plan_check(self.plan(), "3" * 40, NOW, SHA2)

    def test_plan_expires_after_30_minutes(self):
        L.plan_check(self.plan(), SHA1, NOW + dt.timedelta(minutes=29), SHA2)
        with self.assertRaisesRegex(L.Refuse, "old"):
            L.plan_check(self.plan(), SHA1, NOW + dt.timedelta(minutes=31), SHA2)

    def test_live_must_not_have_moved(self):
        with self.assertRaisesRegex(L.Refuse, "moved"):
            L.plan_check(self.plan(), SHA1, NOW, "4" * 40)

    def test_lease_states(self):
        me = "me@h:1"
        self.assertEqual(L.lease_state(None, NOW, me)[0], "free")
        mk = lambda holder, age: {"spec": {"holderIdentity": holder, "leaseDurationSeconds": 120,
                                           "renewTime": (NOW - dt.timedelta(seconds=age)).isoformat().replace("+00:00", "Z")}}
        self.assertEqual(L.lease_state(mk(None, 5), NOW, me)[0], "free")
        self.assertEqual(L.lease_state(mk(me, 5), NOW, me)[0], "mine")
        self.assertEqual(L.lease_state(mk("other", 30), NOW, me)[0], "held")
        self.assertEqual(L.lease_state(mk("other", 300), NOW, me)[0], "stale")

    def test_lease_manifest_shape(self):
        m = L.lease_manifest("me", NOW)
        self.assertEqual(m["metadata"]["name"], L.LEASE_NAME)
        self.assertEqual(m["metadata"]["namespace"], L.NAMESPACE)
        self.assertEqual(m["spec"]["holderIdentity"], "me")


class RootSpec(unittest.TestCase):
    def test_patch_has_exactly_what_the_guard_rule_allows(self):
        p = L.build_root_patch(SHA1, "staging-20261017.1", "staging-20261016.9")
        src = p["spec"]["source"]
        self.assertEqual(src["targetRevision"], SHA1)
        self.assertEqual({x["name"]: x["value"] for x in src["helm"]["parameters"]}, {"release": SHA1, "releaseName": "staging-20261017.1"})
        self.assertTrue(all(x["forceString"] for x in src["helm"]["parameters"]))
        self.assertEqual(set(src), {"targetRevision", "helm"})
        self.assertEqual(p["metadata"]["annotations"], {L.ANN_RELEASE: "staging-20261017.1", L.ANN_PREVIOUS: "staging-20261016.9"})

    def test_patch_rejects_bad_input(self):
        with self.assertRaises(ValueError):
            L.build_root_patch("main", "staging-20261017.1", None)
        with self.assertRaises(ValueError):
            L.build_root_patch(SHA1, "v1", None)

    def test_cutover_state_and_live_sha(self):
        branch = H.root_app(target="teknoir-cloud", sync_rev=SHA1)
        self.assertTrue(L.is_cutover_state(branch))
        self.assertEqual(L.root_live_sha(branch), SHA1)
        pinned = H.root_app(target=SHA2)
        self.assertFalse(L.is_cutover_state(pinned))
        self.assertEqual(L.root_live_sha(pinned), SHA2)

    def test_deviations(self):
        ok = H.root_app(target=SHA1, release_name="staging-20261017.1",
                        params=[{"name": "release", "value": SHA1}, {"name": "releaseName", "value": "staging-20261017.1"}])
        self.assertEqual(L.root_deviations(ok), [])
        self.assertTrue(L.root_deviations(H.root_app(target="teknoir-cloud")))
        bad_params = H.root_app(target=SHA1, release_name="staging-20261017.1", params=[{"name": "release", "value": SHA2}, {"name": "releaseName", "value": "staging-20261017.1"}])
        self.assertTrue(any("helm parameters" in d for d in L.root_deviations(bad_params)))
        noheal = H.root_app(target=SHA1, release_name="staging-20261017.1", selfheal=False,
                            params=[{"name": "release", "value": SHA1}, {"name": "releaseName", "value": "staging-20261017.1"}])
        self.assertTrue(any("selfHeal" in d for d in L.root_deviations(noheal)))
        bg = H.root_app(target=SHA1, release_name="staging-20261017.1", annotations={L.ANN_BREAK_GLASS: "why"},
                        params=[{"name": "release", "value": SHA1}, {"name": "releaseName", "value": "staging-20261017.1"}])
        self.assertTrue(any("break-glass" in d for d in L.root_deviations(bg)))


class Convergence(unittest.TestCase):
    def test_all_on_sha_and_healthy(self):
        apps = [H.app("a", target=SHA1), H.app("b", target=SHA1)]
        self.assertEqual(L.converged(apps, SHA1), (True, []))

    def test_child_on_old_revision(self):
        apps = [H.app("a", target=SHA1), H.app("b", target=SHA1, revision=SHA2)]
        ok, pr = L.converged(apps, SHA1)
        self.assertFalse(ok)
        self.assertIn("b:", pr[0])

    def test_child_still_following_the_branch(self):
        ok, pr = L.converged([H.app("a", target="teknoir-cloud", revision=SHA1)], SHA1)
        self.assertFalse(ok)

    def test_unhealthy(self):
        ok, pr = L.converged([H.app("a", target=SHA1, health="Progressing")], SHA1)
        self.assertEqual((ok, pr), (False, ["a: Synced/Progressing"]))

    def test_plugin_apps_only_count_when_the_chart_version_changed(self):
        plug = H.app("teknoir-demo-jwks", target="0.0.105", chart="profile-plugin-jwks", repo="https://teknoir.github.io/profile-plugins-helm",
                     sync="OutOfSync", ns="teknoir-demo")
        self.assertTrue(L.converged([H.app("a", target=SHA1), plug], SHA1)[0])
        self.assertFalse(L.converged([H.app("a", target=SHA1), plug], SHA1, plugins_changed=True)[0])

    def test_plugin_apps_with_a_missing_namespace_are_ignored(self):
        plug = H.app("teknoir-e2e-emqx", target="0.0.105", chart="profile-plugin-emqx", repo="https://teknoir.github.io/profile-plugins-helm",
                     sync="Unknown", health="Unknown", ns="teknoir-e2e")
        self.assertTrue(L.converged([plug], SHA1, plugins_changed=True, missing_namespaces={"teknoir-e2e"})[0])

    def test_expected_application_not_there_yet(self):
        ok, pr = L.converged([H.app("a", target=SHA1)], SHA1, expected={"a", "new"})
        self.assertEqual(pr, ["new: Application not found yet"])


class Releases(unittest.TestCase):
    R = [{"tagName": "staging-20261017.1", "isPrerelease": False, "name": "staging-20261017.1"},
         {"tagName": "staging-20261017.2", "isPrerelease": True, "name": "staging-20261017.2"},
         {"tagName": "staging-20261017.3", "isPrerelease": False, "name": "staging-20261017.3 [rolled back]"},
         {"tagName": "staging-20261017.4", "isPrerelease": False, "name": "staging-20261017.4"},
         {"tagName": "staging-20261018.1", "isPrerelease": False, "name": "staging-20261018.1"},
         {"tagName": "other", "isPrerelease": False, "name": "other"}]

    def test_rollback_target_is_the_newest_verified_older_one(self):
        self.assertEqual(L.pick_rollback_target(self.R, "staging-20261018.1", None), "staging-20261017.4")

    def test_skips_prereleases_and_rolled_back(self):
        self.assertEqual(L.pick_rollback_target(self.R, "staging-20261017.4", None), "staging-20261017.1")

    def test_floor(self):
        self.assertIsNone(L.pick_rollback_target(self.R, "staging-20261017.4", "staging-20261017.2"))

    def test_bootstrap_takes_the_newest_verified_not_the_newest_tag(self):
        self.assertEqual(L.newest_verified_release(self.R), "staging-20261018.1")
        self.assertEqual(L.newest_verified_release(self.R[:3]), "staging-20261017.1")

    def test_tag_message_contents(self):
        m = L.tag_message(tag="staging-20261017.2", sha=SHA1, by="sess", reason="why", previous="staging-20261017.1", live_sha=SHA2,
                          pending=[{"short": "abc1234", "pr": 7, "branch": "x/y", "subject": "do it"}],
                          image_changes=["Deployment/x c: a -> b"], plugin_digests={"profile-plugin-jwks": "sha256:aa"},
                          plugin_version="0.0.104", mode="release", shared_digests={"ghcr.io/teknoir/keycloak-theme:latest": "sha256:bb"})
        for s in ("by: sess", "reason: why", "previous: staging-20261017.1", f"commit: {SHA1}", "abc1234 #7 do it [x/y]",
                  "Deployment/x c: a -> b", "plugin chart version: 0.0.104", "profile-plugin-jwks sha256:aa",
                  "production-shared tag digests:", "keycloak-theme:latest sha256:bb"):
            self.assertIn(s, m)


if __name__ == "__main__":
    unittest.main()
