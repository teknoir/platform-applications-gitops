import datetime as dt
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

CP = H.load("check_pins", "check-pins.py")
TODAY = dt.date(2026, 10, 17)
D = "@sha256:" + "a" * 64
SHA = "0123456789abcdef0123456789abcdef01234567"


def deploy(*images, kind="Deployment", policy=""):
    cs = [{"name": f"c{i}", "image": im, **({"imagePullPolicy": policy} if policy else {})} for i, im in enumerate(images)]
    return ("f.yaml", {"kind": kind, "apiVersion": "apps/v1", "metadata": {"name": "x", "namespace": "n"},
                       "spec": {"template": {"spec": {"containers": cs}}}})


def policy(**kw):
    p = CP.load_policy(None)
    p.update(kw)
    return p


def codes(findings, level=None):
    return [f.code for f in findings if level is None or f.level == level]


class Images(unittest.TestCase):
    def check(self, docs, **kw):
        return CP.check_images(CP.collect_images(docs), policy(**kw), TODAY)

    def test_pinned_first_party_is_fine(self):
        self.assertEqual(self.check([deploy("ghcr.io/teknoir/device-controller:sha-abc" + D)]), [])

    def test_digest_without_tag_is_pinned(self):
        # charts with a separate digest value (keycloakx) render repo@sha256:<digest> with no tag
        self.assertEqual(self.check([deploy("ghcr.io/teknoir/keycloak-theme" + D)]), [])

    def test_first_party_tag_without_digest_warns_by_default(self):
        f = self.check([deploy("ghcr.io/teknoir/user-controller:teknoir-cloud-20260413-054338")])
        self.assertIn("first-party-unpinned", codes(f, "warn"))
        self.assertEqual(codes(f, "error"), [])

    def test_latest_and_untagged_are_flagged_as_latest(self):
        f = self.check([deploy("ghcr.io/teknoir/keycloak-theme:latest", "harbor.teknoir.cloud/teknoir/x")])
        self.assertEqual(codes(f, "warn").count("first-party-latest"), 2)

    def test_deny_mode_makes_them_errors(self):
        f = self.check([deploy("ghcr.io/teknoir/keycloak-theme:latest", "ghcr.io/teknoir/u:t1")], images="deny")
        self.assertEqual(sorted(codes(f, "error")), ["first-party-latest", "first-party-unpinned"])

    def test_the_three_first_party_registries(self):
        f = self.check([deploy("docker.io/tekn0ir/a:t", "harbor.teknoir.cloud/teknoir/b:t", "ghcr.io/teknoir/c:t")], images="deny")
        self.assertEqual(len(codes(f, "error")), 3)

    # A digest without a tag IS a valid pin (2026-10-17): the keycloakx chart takes a separate image.digest and
    # renders repo@sha256:<digest>, because its image.tag also feeds the app.kubernetes.io/version label, where
    # tag@digest is invalid. The tag stays a human label in the values file (scripts/pin-image style "digest").
    def test_digest_without_a_tag_is_a_valid_pin_even_in_deny(self):
        self.assertEqual(self.check([deploy("ghcr.io/teknoir/a" + D)], images="deny"), [])

    def test_malformed_digest_is_not_a_pin(self):
        f = self.check([deploy("ghcr.io/teknoir/a:t@sha256:abc")], images="deny")
        self.assertEqual(len(codes(f, "error")), 1)

    def test_third_party_exact_tag_is_one_summary_warning_never_an_error(self):
        f = self.check([deploy("quay.io/jetstack/cert-manager:v1.20.1", "postgres:17-alpine")], images="deny")
        self.assertEqual(codes(f, "error"), [])
        self.assertEqual(codes(f, "warn"), ["third-party-no-digest"])

    def test_third_party_latest_is_listed_and_floating(self):
        f = self.check([deploy("docker.io/kennethreitz/httpbin:latest")])
        self.assertIn("third-party-no-digest", codes(f))
        self.assertIn("floating", codes(f))

    def test_istio_auto_placeholder_is_ignored(self):
        self.assertEqual(self.check([deploy("auto")]), [])

    def test_all_pod_kinds_and_init_containers(self):
        docs = [deploy("ghcr.io/teknoir/a:t", kind=k) for k in ("StatefulSet", "DaemonSet", "Job")]
        cron = ("f", {"kind": "CronJob", "metadata": {"name": "c"}, "spec": {"jobTemplate": {"spec": {"template": {"spec": {
            "initContainers": [{"name": "i", "image": "ghcr.io/teknoir/init:t"}], "containers": []}}}}}})
        self.assertEqual(len(CP.collect_images(docs + [cron])), 4)


class Exceptions(unittest.TestCase):
    EXC = {"image": "ghcr.io/teknoir/backstage-app:nextgen", "reason": "preview lane", "owner": "Nextgen", "expires": dt.date(2026, 11, 30)}

    def test_excepted_image_is_info_not_a_warning_or_error(self):
        f = CP.check_images(CP.collect_images([deploy("ghcr.io/teknoir/backstage-app:nextgen")]), policy(images="deny", exceptions=[self.EXC]), TODAY)
        self.assertEqual(codes(f, "error") + codes(f, "warn"), ["floating"] if "floating" in codes(f) else [])
        self.assertIn("excepted", codes(f, "info"))

    def test_exception_matches_the_image_exactly_not_other_tags(self):
        f = CP.check_images(CP.collect_images([deploy("ghcr.io/teknoir/backstage-app:robot")]), policy(images="deny", exceptions=[self.EXC]), TODAY)
        self.assertEqual(codes(f, "error"), ["first-party-unpinned"])

    def test_prefix_exception(self):
        exc = {**self.EXC, "image": "ghcr.io/teknoir/backstage-app:*"}
        f = CP.check_images(CP.collect_images([deploy("ghcr.io/teknoir/backstage-app:robot")]), policy(images="deny", exceptions=[exc]), TODAY)
        self.assertEqual(codes(f, "error"), [])

    def test_the_exception_covers_a_digest_pinned_form_too(self):
        self.assertTrue(CP.exception_matches(self.EXC, "ghcr.io/teknoir/backstage-app:nextgen" + D))

    def test_expiry_is_inclusive_of_the_last_day_and_an_error_after(self):
        pol = policy(exceptions=[self.EXC])
        self.assertEqual(CP.check_exceptions(pol, dt.date(2026, 11, 30)), [])
        f = CP.check_exceptions(pol, dt.date(2026, 12, 1))
        self.assertEqual(codes(f), ["exception-expired"])
        self.assertEqual(f[0].level, "error")

    def test_expired_exception_no_longer_excuses_the_image(self):
        late = dt.date(2026, 12, 1)
        pol = policy(images="deny", exceptions=[self.EXC])
        f = CP.check_images(CP.collect_images([deploy("ghcr.io/teknoir/backstage-app:nextgen")]), pol, late)
        self.assertEqual(codes(f, "error"), ["first-party-unpinned"])
        self.assertEqual(CP.lint([deploy("ghcr.io/teknoir/backstage-app:nextgen")], policy=pol, release=None, project="x",
                                 repo_root=None, today=late)[0].code, "exception-expired")

    def test_incomplete_exception_is_an_error(self):
        f = CP.check_exceptions(policy(exceptions=[{"image": "x", "expires": "2027-01-01"}]), TODAY)
        self.assertEqual(codes(f), ["exception-invalid"])

    def test_shipped_policy_has_the_nextgen_lane_expiring_2026_11_30(self):
        pol = CP.load_policy(os.path.join(H.SCRIPTS, "release-policy.yaml"))
        self.assertEqual(pol["images"], "deny")   # since 2026-10-17: every first-party image is pinned
        exc = {e["image"]: e for e in pol["exceptions"]}
        self.assertEqual(set(exc), {"ghcr.io/teknoir/backstage-app:nextgen", "ghcr.io/teknoir/backstage:nextgen"})
        for e in exc.values():
            self.assertEqual(e["owner"], "Nextgen")
            self.assertEqual(CP._date(e["expires"]), dt.date(2026, 11, 30))
        self.assertEqual(CP.check_exceptions(pol, TODAY), [])


class Applications(unittest.TestCase):
    @staticmethod
    def appdoc(name, target, repo="https://github.com/teknoir/platform-applications-gitops"):
        return ("root.yaml", {"kind": "Application", "metadata": {"name": name}, "spec": {"source": {"repoURL": repo, "path": "charts/x", "targetRevision": target}}})

    def test_all_on_the_release(self):
        self.assertEqual(CP.check_applications([self.appdoc("a", SHA), self.appdoc("b", SHA)], SHA, "teknoir-cloud"), [])

    def test_branch_revision_is_an_error(self):
        f = CP.check_applications([self.appdoc("a", SHA), self.appdoc("b", "teknoir-cloud")], SHA, "teknoir-cloud")
        self.assertEqual(codes(f), ["revision-not-release"])
        self.assertIn("Application/b", f[0].where)

    def test_other_repos_are_not_checked(self):
        d = self.appdoc("p", "0.0.104", repo="https://teknoir.github.io/profile-plugins-helm")
        self.assertEqual(CP.check_applications([d], SHA, "teknoir-cloud"), [])

    def test_release_unset_on_staging_is_an_error(self):
        self.assertEqual(codes(CP.check_applications([self.appdoc("a", "teknoir-cloud")], None, "teknoir-cloud")), ["release-unset"])

    def test_release_must_be_a_full_sha(self):
        self.assertEqual(codes(CP.check_applications([], "abc1234", "teknoir-cloud")), ["release-unset"])

    def test_other_projects_without_release_are_not_checked(self):
        self.assertEqual(CP.check_applications([self.appdoc("a", "teknoir-online")], None, "teknoir-online"), [])

    def test_added_and_removed_applications(self):
        self.assertEqual(CP.app_set_changes({"a", "b"}, {"b", "c"}), (["c"], ["a"]))


class ChartDeps(unittest.TestCase):
    def charts(self, *versions):
        d = tempfile.mkdtemp()
        for i, v in enumerate(versions):
            os.makedirs(os.path.join(d, "charts", f"c{i}"))
            with open(os.path.join(d, "charts", f"c{i}", "Chart.yaml"), "w") as fh:
                fh.write(f"name: c{i}\ndependencies:\n  - name: x\n    version: {v!r}\n    repository: https://x\n")
        return d

    def test_exact_versions_pass(self):
        self.assertEqual(CP.check_chart_deps(self.charts("1.20.1", "7.1.9", "0.7.0")), [])

    def test_ranges_fail(self):
        for v in ("^1.2.3", "~1.2.0", ">=1.0.0", "1.x", "*", "1.2.3 - 2.0.0", "1.2", ""):
            self.assertEqual(codes(CP.check_chart_deps(self.charts(v))), ["chart-dependency-range"], v)

    def test_the_real_charts_have_exact_dependencies(self):
        root = os.path.dirname(H.SCRIPTS)
        self.assertEqual(CP.check_chart_deps(root), [])


class Crs(unittest.TestCase):
    def cr(self, kind, rev, api="teknoir.org/v1alpha1"):
        return ("f", {"kind": kind, "apiVersion": api, "metadata": {"name": "n"}, "spec": {"applications": [{"revision": rev}]}})

    def test_non_sha_revision_warns(self):
        self.assertEqual(codes(CP.check_crs([self.cr("DeviceApplicationSet", "main")])), ["cr-revision"])

    def test_sha_revision_is_fine(self):
        self.assertEqual(CP.check_crs([self.cr("Robot", SHA)]), [])

    def test_other_groups_and_kinds_are_ignored(self):
        self.assertEqual(CP.check_crs([self.cr("DeviceApplicationSet", "main", api="other.io/v1"), self.cr("Profile", "main")]), [])

    def test_profile_version_keys(self):
        prof = ("f", {"kind": "Profile", "apiVersion": "teknoir.org/v1", "metadata": {"name": "p"}, "spec": {"plugins": [
            {"name": "jwks", "spec": {"version": "0.0.1"}, "values": {"jwksVersion": "main", "imageTag": "x", "ok": 1}}]}})
        self.assertEqual(codes(CP.check_profiles([prof])), ["profile-version"] * 3)


class Roundtrip(unittest.TestCase):
    """argocd-server rewrites the Application through its Go types (omitempty), see check_roundtrip."""

    @staticmethod
    def app(**spec):
        base = {"project": "p", "destination": {"server": "https://kubernetes.default.svc", "namespace": "n"},
                "source": {"repoURL": "https://github.com/teknoir/platform-applications-gitops", "path": "charts/x", "targetRevision": SHA}}
        base.update(spec)
        return ("a.yaml", {"kind": "Application", "metadata": {"name": "a", "annotations": {"x": ""}}, "spec": base})

    def bad(self, **spec):
        return [f.message.split(" ")[0] for f in CP.check_roundtrip([self.app(**spec)])]

    def test_a_clean_application_passes(self):
        self.assertEqual(CP.check_roundtrip([self.app(syncPolicy={"automated": {"prune": False, "selfHeal": True}})]), [])

    def test_empty_sources_list(self):
        self.assertEqual(self.bad(sources=[]), ["spec.sources"])

    def test_empty_group_in_ignore_differences(self):
        self.assertEqual(self.bad(ignoreDifferences=[{"group": "", "kind": "Secret"}]), ["spec.ignoreDifferences[0].group"])

    def test_empty_string_null_and_empty_list_are_found_anywhere(self):
        self.assertEqual(sorted(self.bad(syncPolicy={"syncOptions": [], "retry": None},
                                         source={"repoURL": "u", "path": "", "helm": {"parameters": [{"name": "a", "value": ""}]}})),
                         ["spec.source.helm.parameters[0].value", "spec.source.path", "spec.syncPolicy.retry", "spec.syncPolicy.syncOptions"])

    def test_fields_without_omitempty_may_be_empty(self):
        self.assertEqual(self.bad(project="", source={"repoURL": ""}), [])

    def test_annotation_values_and_free_form_values_are_kept(self):
        self.assertEqual(self.bad(source={"repoURL": "u", "helm": {"valuesObject": {"a": "", "b": []}}}), [])

    def test_the_release_lint_reports_it_as_an_error(self):
        f = CP.lint([self.app(sources=[])], policy=policy(), release=SHA, project="teknoir-cloud", repo_root=None, today=TODAY)
        self.assertEqual(codes(f, "error"), ["app-not-roundtrip-stable"])

    @unittest.skipUnless(shutil.which("helm"), "helm not installed")
    def test_the_rendered_root_chart_is_stable_for_every_project(self):
        chart = os.path.join(os.path.dirname(H.SCRIPTS), "charts", "app-of-apps")
        for project in ("teknoir-cloud", "teknoir-online", "teknoir-local"):
            out = subprocess.run(["helm", "template", "app-of-apps", chart, "--set", f"project={project}", "--set-string", f"release={SHA}",
                                  "--set", "releaseGuard.enabled=true", "--set", "virtualDevices.spike.enabled=true"],
                                 capture_output=True, text=True, check=True).stdout
            d = tempfile.mkdtemp()
            with open(os.path.join(d, "root.yaml"), "w") as fh:
                fh.write(out)
            apps = [x for x in CP.load_docs([d]) if x[1].get("kind") == "Application"]
            self.assertGreater(len(apps), 5, project)
            self.assertEqual([f.line() for f in CP.check_roundtrip(apps)], [], project)


class Cli(unittest.TestCase):
    def test_exit_status_and_output(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "r.yaml"), "w") as fh:
            fh.write("apiVersion: v1\nkind: Application\nmetadata: {name: a}\nspec: {source: {repoURL: https://github.com/teknoir/platform-applications-gitops, path: x, targetRevision: main}}\n")
        self.assertEqual(CP.main([d, "--release", SHA, "--policy", os.path.join(H.SCRIPTS, "release-policy.yaml")]), 1)
        self.assertEqual(CP.main([d, "--project", "teknoir-online", "--policy", os.path.join(H.SCRIPTS, "release-policy.yaml")]), 0)

    def test_yaml_bare_equals_loads(self):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, "r.yaml"), "w") as fh:
            fh.write("a:\n  - '!='\n  - =\n  - =~\n")
        self.assertEqual(len(CP.load_docs([d])), 1)


if __name__ == "__main__":
    unittest.main()
