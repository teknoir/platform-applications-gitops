import datetime as dt
import os
import shutil
import subprocess
import sys
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

    def test_shipped_policy_has_no_exceptions_since_the_ui_cutover(self):
        pol = CP.load_policy(os.path.join(H.SCRIPTS, "release-policy.yaml"))
        self.assertEqual(pol["images"], "deny")   # since 2026-10-17: every first-party image is pinned
        # The next.teknoir.cloud preview lane (:nextgen) ended with the UI cut-over (release B, 2026-10-17).
        self.assertEqual(pol["exceptions"], [])
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

    @staticmethod
    def multisource(name, *sources):
        return ("root.yaml", {"kind": "Application", "metadata": {"name": name}, "spec": {"sources": list(sources)}})

    def kargo_app(self, ref_revision):
        """The kargo Application: an OCI chart source plus this repository as the `values` source."""
        return self.multisource(
            "kargo",
            {"repoURL": "ghcr.io/akuity/kargo-charts", "chart": "kargo", "targetRevision": "1.12.6"},
            {"repoURL": "https://github.com/teknoir/platform-applications-gitops", "ref": "values",
             "targetRevision": ref_revision})

    def test_a_multi_source_application_checks_the_source_of_this_repository(self):
        self.assertEqual(CP.check_applications([self.kargo_app(SHA)], SHA, "teknoir-cloud"), [])

    def test_a_multi_source_application_source_off_the_release_is_an_error(self):
        f = CP.check_applications([self.kargo_app("main")], SHA, "teknoir-cloud")
        self.assertEqual(codes(f), ["revision-not-release"])
        self.assertIn("Application/kargo sources[1]", f[0].where)
        # the OCI chart's own version is not this repository's revision and is never flagged
        self.assertNotIn("1.12.6", f[0].message)

    def test_a_multi_source_application_without_this_repository_is_not_checked(self):
        appdoc = self.multisource("kargo", {"repoURL": "ghcr.io/akuity/kargo-charts", "chart": "kargo",
                                            "targetRevision": "1.12.6"})
        self.assertEqual(CP.check_applications([appdoc], SHA, "teknoir-cloud"), [])

    def test_no_release_skips_the_revision_check(self):
        # a PR (a pin, a hand change) is not on a release yet: no Application revision check at all
        self.assertEqual(CP.check_applications([self.appdoc("a", "teknoir-cloud")], None, "teknoir-cloud"), [])

    def test_release_must_be_a_full_sha(self):
        self.assertEqual(codes(CP.check_applications([], "abc1234", "teknoir-cloud")), ["release-invalid"])

    def test_other_projects_without_release_are_not_checked(self):
        self.assertEqual(CP.check_applications([self.appdoc("a", "teknoir-online")], None, "teknoir-online"), [])

    def test_other_projects_are_not_checked_even_with_a_release(self):
        # only staging follows a release; teknoir-online and teknoir-local follow their branch name
        self.assertEqual(CP.check_applications([self.appdoc("a", "teknoir-online")], SHA, "teknoir-online"), [])

    def test_added_and_removed_applications(self):
        self.assertEqual(CP.app_set_changes({"a", "b"}, {"b", "c"}), (["c"], ["a"]))


class ChartDeps(unittest.TestCase):
    def charts(self, *versions, tree="charts"):
        d = H.tmpdir()
        for i, v in enumerate(versions):
            os.makedirs(os.path.join(d, *tree.split("/"), f"c{i}"))
            with open(os.path.join(d, *tree.split("/"), f"c{i}", "Chart.yaml"), "w") as fh:
                fh.write(f"name: c{i}\ndependencies:\n  - name: x\n    version: {v!r}\n    repository: https://x\n")
        return d

    def test_exact_versions_pass(self):
        self.assertEqual(CP.check_chart_deps(self.charts("1.20.1", "7.1.9", "0.7.0")), [])

    def test_ranges_fail(self):
        for v in ("^1.2.3", "~1.2.0", ">=1.0.0", "1.x", "*", "1.2.3 - 2.0.0", "1.2", ""):
            self.assertEqual(codes(CP.check_chart_deps(self.charts(v))), ["chart-dependency-range"], v)

    def test_a_range_in_the_plugin_tree_fails(self):
        # plugins/charts/: the imported profile plugin charts (CI v4 P9.1) are checked like charts/
        f = CP.check_chart_deps(self.charts("~1.2.0", tree="plugins/charts"))
        self.assertEqual(codes(f), ["chart-dependency-range"])
        self.assertEqual(f[0].where, "plugins/charts/c0/Chart.yaml")

    def test_a_repo_without_a_plugin_tree_is_fine(self):
        self.assertEqual(CP.check_chart_deps(H.tmpdir()), [])

    def test_the_real_charts_have_exact_dependencies(self):
        root = os.path.dirname(H.SCRIPTS)
        self.assertEqual(CP.check_chart_deps(root), [])

    def test_the_emqx_dependency_is_exact(self):
        root = os.path.dirname(H.SCRIPTS)
        self.assertTrue(os.path.isfile(os.path.join(root, "plugins/charts/profile-plugin-emqx/Chart.yaml")))
        with open(os.path.join(root, "plugins/charts/profile-plugin-emqx/Chart.yaml")) as fh:
            deps = CP.yaml.safe_load(fh)["dependencies"]
        self.assertEqual([(d["name"], d["version"]) for d in deps], [("emqx", "5.8.9")])


class FleetPointers(unittest.TestCase):
    """fleet/<class>.yaml (fleet/README.md, CI v4 P8.5 flow 3.5): one class named after the file, 40-hex."""

    def repo(self, **files):
        d = H.tmpdir()
        os.makedirs(os.path.join(d, "fleet"))
        for name, text in files.items():
            with open(os.path.join(d, "fleet", name), "w") as fh:
                fh.write(text)
        return d

    @staticmethod
    def pointer(cls, rev=SHA):
        return f"fleets:\n  {cls}:\n    revision: {rev}\n"

    def test_a_good_pointer_passes(self):
        self.assertEqual(CP.check_fleet_pointers(self.repo(**{"jetson-orin.yaml": self.pointer("jetson-orin")})), [])

    def test_a_class_that_does_not_match_the_file_name_fails(self):
        f = CP.check_fleet_pointers(self.repo(**{"jetson-orin.yaml": self.pointer("nvidia-rtx")}))
        self.assertEqual(codes(f), ["fleet-pointer"])
        self.assertEqual(f[0].level, "error")
        self.assertIn("fleet/jetson-orin.yaml", f[0].where)

    def test_a_branch_revision_fails(self):
        self.assertEqual(codes(CP.check_fleet_pointers(self.repo(**{"raspberry-pi.yaml": self.pointer("raspberry-pi", "main")}))),
                         ["fleet-pointer"])

    def test_a_missing_revision_fails(self):
        f = CP.check_fleet_pointers(self.repo(**{"nvidia-rtx.yaml": "fleets:\n  nvidia-rtx: {}\n"}))
        self.assertEqual(codes(f), ["fleet-pointer"])

    def test_two_classes_in_one_file_fail(self):
        text = f"fleets:\n  jetson-orin:\n    revision: {SHA}\n  nvidia-rtx:\n    revision: {SHA}\n"
        f = CP.check_fleet_pointers(self.repo(**{"jetson-orin.yaml": text}))
        self.assertEqual(codes(f), ["fleet-pointer"])
        self.assertIn("exactly one class", f[0].message)

    def test_readme_and_other_files_are_ignored(self):
        d = self.repo(**{"jetson-orin.yaml": self.pointer("jetson-orin")})
        with open(os.path.join(d, "fleet", "README.md"), "w") as fh:
            fh.write("# not a fleet pointer\n")
        self.assertEqual(CP.check_fleet_pointers(d), [])

    def test_a_checkout_without_a_fleet_directory_passes(self):
        self.assertEqual(CP.check_fleet_pointers(H.tmpdir()), [])

    def test_the_real_fleet_pointers_pass(self):
        self.assertEqual(CP.check_fleet_pointers(os.path.dirname(H.SCRIPTS)), [])


class Crs(unittest.TestCase):
    def cr(self, kind, rev, api="teknoir.org/v1alpha1"):
        return ("f", {"kind": kind, "apiVersion": api, "metadata": {"name": "n"}, "spec": {"applications": [{"revision": rev}]}})

    def test_non_sha_revision_warns(self):
        self.assertEqual(codes(CP.check_crs([self.cr("DeviceApplicationSet", "main")])), ["cr-revision"])

    def test_sha_revision_is_fine(self):
        self.assertEqual(CP.check_crs([self.cr("Robot", SHA)]), [])

    def test_other_groups_and_kinds_are_ignored(self):
        self.assertEqual(CP.check_crs([self.cr("DeviceApplicationSet", "main", api="other.io/v1"), self.cr("Profile", "main")]), [])

    def app_cr(self, kind, **item):
        return ("f", {"kind": kind, "apiVersion": "teknoir.org/v1alpha1", "metadata": {"name": "n"},
                      "spec": {"applications": [item]}})

    def test_robot_application_with_a_branch_revision_fails(self):
        self.assertEqual(codes(CP.check_crs([self.cr("Robot", "nextgen")])), ["cr-revision"])

    def test_robot_type_with_a_sha_revision_is_fine(self):
        self.assertEqual(CP.check_crs([self.cr("RobotType", SHA)]), [])

    def test_a_robot_type_application_without_a_revision_key_fails(self):
        f = CP.check_crs([self.app_cr("RobotType", repo_url="https://github.com/teknoir/x", path="p")])
        self.assertEqual(codes(f), ["cr-revision"])
        self.assertIn("no revision", f[0].message)

    def test_an_empty_revision_is_reported_once(self):
        self.assertEqual(len(CP.check_crs([self.app_cr("DeviceApplicationSet", revision="")])), 1)

    def test_device_applications_without_a_revision_are_not_checked(self):
        # a Device has its own applications; the missing-revision rule is for the rendered CRs only
        self.assertEqual(CP.check_crs([self.app_cr("Device", repo_url="https://github.com/teknoir/x", path="p")]), [])

    def test_the_missing_revision_finding_takes_the_lint_level(self):
        doc = self.app_cr("Robot", repo_url="https://github.com/teknoir/x", path="p")
        self.assertEqual(codes(CP.check_crs([doc], "error"), "error"), ["cr-revision"])

    def test_profile_version_keys(self):
        prof = ("f", {"kind": "Profile", "apiVersion": "teknoir.org/v1", "metadata": {"name": "p"}, "spec": {"plugins": [
            {"name": "jwks", "spec": {"version": "0.0.1"}, "values": {"jwksVersion": "main", "imageTag": "x", "ok": 1}}]}})
        self.assertEqual(codes(CP.check_profiles([prof])), ["profile-version"] * 3)


class PluginRevisions(unittest.TestCase):
    """The <profile-controller>-plugin-revision ConfigMap of plugin git mode (CI v4 P9.1) must hold the release."""

    @staticmethod
    def cm(name, rev, **data):
        return ("f.yaml", {"kind": "ConfigMap", "metadata": {"name": name}, "data": {"revision": rev, **data}})

    def test_the_release_revision_passes(self):
        self.assertEqual(CP.check_plugin_revisions([self.cm("profile-controller-plugin-revision", SHA)], SHA), [])

    def test_another_revision_is_an_error(self):
        f = CP.check_plugin_revisions([self.cm("profile-controller-plugin-revision", "f" * 40)], SHA)
        self.assertEqual(codes(f), ["plugin-revision-not-release"])
        self.assertEqual(f[0].level, "error")
        self.assertIn("ConfigMap/profile-controller-plugin-revision", f[0].where)

    def test_a_missing_revision_is_an_error(self):
        doc = ("f.yaml", {"kind": "ConfigMap", "metadata": {"name": "profile-controller-plugin-revision"}, "data": {"x": "y"}})
        self.assertEqual(codes(CP.check_plugin_revisions([doc], SHA)), ["plugin-revision-not-release"])

    def test_no_release_skips_the_check(self):
        # a pull request is not on a release yet, and chart mode has no such ConfigMap at all
        self.assertEqual(CP.check_plugin_revisions([self.cm("profile-controller-plugin-revision", "main")], None), [])

    def test_other_configmaps_and_kinds_are_ignored(self):
        docs = [self.cm("profile-controller-config", "x"),
                ("f", {"kind": "Secret", "metadata": {"name": "a-plugin-revision"}, "data": {"revision": "x"}})]
        self.assertEqual(CP.check_plugin_revisions(docs, SHA), [])

    def test_the_lint_reports_it_as_an_error(self):
        f = CP.lint([self.cm("profile-controller-plugin-revision", "f" * 40)], policy=policy(), release=SHA,
                    project="teknoir-cloud", repo_root=None, today=TODAY)
        self.assertEqual(codes(f, "error"), ["plugin-revision-not-release"])


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
                                  "--set", "virtualDevices.spike.enabled=true"],
                                 capture_output=True, text=True, check=True).stdout
            d = H.tmpdir()
            with open(os.path.join(d, "root.yaml"), "w") as fh:
                fh.write(out)
            apps = [x for x in CP.load_docs([d]) if x[1].get("kind") == "Application"]
            self.assertGreater(len(apps), 5, project)
            self.assertEqual([f.line() for f in CP.check_roundtrip(apps)], [], project)


class Cli(unittest.TestCase):
    def test_exit_status_and_output(self):
        d = H.tmpdir()
        with open(os.path.join(d, "r.yaml"), "w") as fh:
            fh.write("apiVersion: v1\nkind: Application\nmetadata: {name: a}\nspec: {source: {repoURL: https://github.com/teknoir/platform-applications-gitops, path: x, targetRevision: main}}\n")
        self.assertEqual(CP.main([d, "--release", SHA, "--policy", os.path.join(H.SCRIPTS, "release-policy.yaml")]), 1)
        self.assertEqual(CP.main([d, "--project", "teknoir-online", "--policy", os.path.join(H.SCRIPTS, "release-policy.yaml")]), 0)

    def test_yaml_bare_equals_loads(self):
        d = H.tmpdir()
        with open(os.path.join(d, "r.yaml"), "w") as fh:
            fh.write("a:\n  - '!='\n  - =\n  - =~\n")
        self.assertEqual(len(CP.load_docs([d])), 1)



class CrRevisions(unittest.TestCase):
    def das(self, rev):
        return [("x.yaml", {"apiVersion": "teknoir.org/v1", "kind": "DeviceApplicationSet", "metadata": {"name": "d"},
                            "spec": {"applications": [{"repoUrl": "https://github.com/teknoir/x", "revision": rev}]}})]

    def test_branch_revision_warns_by_default_and_fails_in_deny(self):
        self.assertEqual(codes(CP.check_crs(self.das("main")), "warn"), ["cr-revision"])
        self.assertEqual(codes(CP.check_crs(self.das("main"), "error"), "error"), ["cr-revision"])

    def test_sha_revision_passes(self):
        self.assertEqual(CP.check_crs(self.das("a" * 40), "error"), [])

    def test_shipped_policy_denies_cr_revisions(self):
        self.assertEqual(CP.load_policy(os.path.join(H.SCRIPTS, "release-policy.yaml"))["cr_revisions"], "deny")


class PinPullRequestTest(unittest.TestCase):
    """The pull request cases of the hosted CI: a machine-written pin (no release yet), a hand PR, a bad pin and a
    bad release string. The shipped policy (images: deny) is what the CI runs."""
    SHIPPED = os.path.join(H.SCRIPTS, "release-policy.yaml")
    RELEASE = "0123456789abcdef0123456789abcdef01234567"
    PIN = "ghcr.io/teknoir/x:sha-1234abcd@sha256:" + "b" * 64

    @staticmethod
    def app(target):
        return ("root.yaml", {"kind": "Application", "metadata": {"name": "a"}, "spec": {"source": {
            "repoURL": "https://github.com/teknoir/platform-applications-gitops", "path": "charts/x", "targetRevision": target}}})

    def lint(self, docs, release, project="teknoir-cloud"):
        return CP.lint(docs, policy=CP.load_policy(self.SHIPPED), release=release, project=project,
                       repo_root=None, today=TODAY)

    def test_a_pin_pull_request_passes(self):
        f = self.lint([deploy(self.PIN), self.app(self.RELEASE)], self.RELEASE)
        self.assertEqual(codes(f, "error"), [])

    def test_a_hand_pull_request_without_a_release_passes(self):
        f = self.lint([deploy(self.PIN), self.app("teknoir-cloud")], None)
        self.assertEqual(codes(f, "error"), [])

    def test_a_bad_pin_fails_under_the_shipped_policy(self):
        f = self.lint([deploy("ghcr.io/teknoir/x:sha-1234abcd"), self.app(self.RELEASE)], self.RELEASE)
        self.assertEqual(codes(f, "error"), ["first-party-unpinned"])

    def test_a_bad_release_string_fails(self):
        f = self.lint([deploy(self.PIN)], "abc1234")
        self.assertEqual(codes(f, "error"), ["release-invalid"])


if __name__ == "__main__":
    unittest.main()
