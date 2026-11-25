"""The verification Job script charts/kargo-config/files/revision-check.sh on a fake kubectl
(CI/CD v4 P4.2, plans/cicd/v4/p42-spec.md section 4).

The script runs as the Job of the AnalysisTemplate revision-check: it polls the root Application of the
staging release, its children and the plugin Applications and exits 1 with one line per failing Application.
Each test serves JSON fixtures through a fake `kubectl` first on PATH, with the poll window shortened to one
pass (REVISION_CHECK_TIMEOUT=0, REVISION_CHECK_INTERVAL=0). Nothing here talks to a cluster.
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SCRIPT = os.path.join(ROOT, "charts", "kargo-config", "files", "revision-check.sh")
REPO = "https://github.com/teknoir/platform-applications-gitops.git"
SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER = "fedcba9876543210fedcba9876543210fedcba98"
DEVHOST = "https://devhost-ci.example"
PLUGIN_VERSION = "0.0.113"

# Serves the fixtures of $FAKE_KUBECTL: {"<ns>": {"application/<name>": {...}, "applications": {"items": [...]},
# "configmap/<name>": {...}}}. An unknown object exits 1 like kubectl.
FAKE_KUBECTL = '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
ns, verb, kind, name = "default", None, None, None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-n", "--namespace"):
        ns = args[i + 1]
        i += 2
        continue
    if a in ("-o", "--output"):
        i += 2
        continue
    if verb is None:
        verb = a
    elif kind is None:
        kind = a
    elif name is None:
        name = a
    i += 1
data = json.load(open(os.environ["FAKE_KUBECTL"]))
if verb != "get":
    sys.stderr.write("fake kubectl: unsupported verb %r\\n" % verb)
    sys.exit(2)
kind = kind.split(".")[0]          # applications.argoproj.io -> applications
key = kind + ("/" + name if name else "")
obj = (data.get(ns) or {}).get(key)
if obj is None:
    sys.stderr.write("fake kubectl: %s not found in %s\\n" % (key, ns))
    sys.exit(1)
print(json.dumps(obj))
'''


def source(repo=REPO, path="charts/x"):
    return {"repoURL": repo, "targetRevision": "main", "path": path}


def app(name, *, revision=SHA, sync="Synced", health="Healthy", server="https://kubernetes.default.svc",
        repo=REPO, chart=None, target="main"):
    src = {"repoURL": repo, "targetRevision": target}
    if chart:
        src["chart"] = chart
    else:
        src["path"] = "charts/" + name
    return {"metadata": {"name": name},
            "spec": {"source": src, "destination": {"namespace": "ns", "server": server}},
            "status": {"sync": {"status": sync, "revision": revision}, "health": {"status": health}}}


def multi(name, entries, *, sync="Synced", health="Healthy"):
    """entries: [(repoURL, synced revision of that source)] — sources in order, status.sync.revisions aligned."""
    return {"metadata": {"name": name},
            "spec": {"sources": [{"repoURL": r} for r, _ in entries],
                     "destination": {"namespace": "ns", "server": "https://kubernetes.default.svc"}},
            "status": {"sync": {"status": sync, "revisions": [rev for _, rev in entries]},
                       "health": {"status": health}}}


def root(children=(), *, revision=SHA, sync="Synced", health="Healthy"):
    return {"metadata": {"name": "app-of-apps"},
            "spec": {"source": source(), "destination": {"namespace": "teknoir-system",
                                                         "server": "https://kubernetes.default.svc"}},
            "status": {"sync": {"status": sync, "revision": revision}, "health": {"status": health},
                       "resources": [{"kind": "Application", "name": n} for n in children]}}


def configmap(version=PLUGIN_VERSION):
    return {"metadata": {"name": "profile-controller-config"}, "data": {"PLUGIN_CHART_VERSION": version}}


class Scenario:
    """A fake kubectl first on PATH, the fixtures it serves, and the script run with a one-pass poll."""

    def __init__(self, test):
        self.tmp = tempfile.mkdtemp(prefix="revision-check-test.")
        test.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        path = os.path.join(self.bin, "kubectl")
        with open(path, "w") as fh:
            fh.write(FAKE_KUBECTL)
        os.chmod(path, 0o755)
        self.data = {}

    def add(self, ns, key, obj):
        self.data.setdefault(ns, {})[key] = obj
        return self

    def application(self, obj, ns="teknoir-system"):
        return self.add(ns, "application/" + obj["metadata"]["name"], obj)

    def applications(self, items, ns="teknoir-system"):
        return self.add(ns, "applications", {"items": items})

    def configmap(self, cm, ns="teknoir-system"):
        return self.add(ns, "configmap/" + cm["metadata"]["name"], cm)

    def run(self, **env):
        # The Application list is always readable (the kargo-verify Role grants list); a test that wants plugin
        # Applications sets them, otherwise the list is empty.
        self.data.setdefault("teknoir-system", {}).setdefault("applications", {"items": []})
        fixtures = os.path.join(self.tmp, "fixtures.json")
        with open(fixtures, "w") as fh:
            json.dump(self.data, fh)
        e = {"PATH": self.bin + os.pathsep + os.environ["PATH"], "FAKE_KUBECTL": fixtures,
             "REVISION": SHA, "REVISION_CHECK_TIMEOUT": "0", "REVISION_CHECK_INTERVAL": "0"}
        e.update({k: v for k, v in env.items() if v is not None})
        return subprocess.run(["sh", SCRIPT], env=e, capture_output=True, text=True, timeout=120)


class RevisionCheck(unittest.TestCase):
    def scenario(self):
        s = Scenario(self)
        s.application(root(["backstage", "profile-controller"]))
        s.application(app("backstage"))
        s.application(app("profile-controller"))
        return s

    def assertPasses(self, run):
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("is Synced at " + SHA, run.stdout)

    def assertFails(self, run, *lines):
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        for line in lines:
            self.assertIn(line, run.stdout)

    def test_passes_when_every_application_is_synced_healthy_and_current(self):
        self.assertPasses(self.scenario().run())

    def test_fails_when_a_child_is_at_another_revision(self):
        s = self.scenario()
        s.application(app("backstage", revision=OTHER))
        self.assertFails(s.run(), f"backstage: revision {OTHER}")

    def test_fails_when_the_root_is_not_synced(self):
        s = Scenario(self)
        s.application(root(["backstage"], sync="OutOfSync"))
        s.application(app("backstage"))
        self.assertFails(s.run(), "app-of-apps: sync OutOfSync")

    def test_fails_when_the_root_is_at_another_revision(self):
        s = Scenario(self)
        s.application(root(["backstage"], revision=OTHER))
        s.application(app("backstage", revision=OTHER))
        self.assertFails(s.run(), f"app-of-apps: revision {OTHER}")

    def test_fails_when_the_root_does_not_exist(self):
        s = Scenario(self)
        self.assertFails(s.run(), "teknoir-system/app-of-apps: not found")

    def test_multi_source_checks_the_revisions_of_this_repository_only(self):
        kargo = multi("kargo", [("ghcr.io/akuity/kargo-charts", "1.12.6"), (REPO + ".git", SHA)])
        s = Scenario(self)
        s.application(root(["kargo"]))
        s.application(kargo)
        self.assertPasses(s.run())

    def test_multi_source_fails_when_this_repository_is_not_at_the_revision(self):
        kargo = multi("kargo", [("ghcr.io/akuity/kargo-charts", "1.12.6"), (REPO, OTHER)])
        s = Scenario(self)
        s.application(root(["kargo"]))
        s.application(kargo)
        self.assertFails(s.run(), f"kargo: revision {OTHER}")

    def test_multi_source_fails_when_the_revisions_array_is_too_short(self):
        """The values source of this repository has synced nowhere yet: status.sync.revisions[1] is absent, so
        the source is not at the revision (the word-split loop used to skip it)."""
        kargo = multi("kargo", [("ghcr.io/akuity/kargo-charts", "1.12.6"), (REPO, SHA)])
        kargo["status"]["sync"]["revisions"] = ["1.12.6"]
        s = Scenario(self)
        s.application(root(["kargo"]))
        s.application(kargo)
        self.assertFails(s.run(), "kargo: revision <none>")

    def test_an_empty_sources_list_is_a_single_source_application(self):
        """spec.sources: [] is what ArgoCD writes back for a single source: it must be read as single-source
        (status.sync.revision), not as a multi-source Application with no revisions."""
        backstage = app("backstage")
        backstage["spec"]["sources"] = []
        s = Scenario(self)
        s.application(root(["backstage"]))
        s.application(backstage)
        self.assertPasses(s.run())

    def test_a_child_without_a_synced_revision_fails(self):
        """status.sync.revision absent: <none>, never a skipped source."""
        child = app("devhost-ci", server=DEVHOST)
        del child["status"]["sync"]["revision"]
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        s.application(child)
        self.assertFails(s.run(DEVHOST_CI_SERVER=DEVHOST), "devhost-ci: revision <none>")

    def test_a_root_without_status_resources_fails(self):
        r = root([])
        del r["status"]["resources"]
        s = Scenario(self)
        s.application(r)
        self.assertFails(s.run(), "app-of-apps lists no child Applications")

    def test_a_root_with_no_application_child_fails(self):
        r = root([])
        r["status"]["resources"] = [{"kind": "ConfigMap", "name": "not-an-application"}]
        s = Scenario(self)
        s.application(r)
        self.assertFails(s.run(), "app-of-apps lists no child Applications")

    def test_a_child_from_another_repository_is_not_revision_checked(self):
        s = Scenario(self)
        s.application(root(["foreign"]))
        s.application(app("foreign", repo="https://github.com/teknoir/elsewhere"))
        self.assertPasses(s.run())

    def test_repo_urls_match_with_or_without_dot_git_and_trailing_slash(self):
        s = Scenario(self)
        s.application(root(["a", "b"]))
        s.application(app("a", repo=REPO + ".git"))
        s.application(app("b", repo=REPO + "/"))
        self.assertPasses(s.run())

    def test_fails_when_a_child_is_out_of_sync(self):
        s = self.scenario()
        s.application(app("profile-controller", sync="OutOfSync"))
        self.assertFails(s.run(), "profile-controller: sync OutOfSync")

    def test_fails_when_a_child_is_degraded(self):
        s = self.scenario()
        s.application(app("backstage", health="Degraded"))
        self.assertFails(s.run(), "backstage: health Degraded")

    def test_fails_when_a_listed_child_does_not_exist(self):
        s = Scenario(self)
        s.application(root(["backstage", "missing"]))
        s.application(app("backstage"))
        self.assertFails(s.run(), "missing: listed in app-of-apps but not found in teknoir-system")

    def test_skips_an_excluded_application(self):
        s = Scenario(self)
        s.application(root(["backstage", "cliproxyapi"]))
        s.application(app("backstage"))
        self.assertPasses(s.run(EXCLUDE_APPS="cliproxyapi"))

    def test_an_excluded_application_is_still_checked_without_the_exclusion(self):
        s = Scenario(self)
        s.application(root(["backstage", "cliproxyapi"]))
        s.application(app("backstage"))
        s.application(app("cliproxyapi", sync="OutOfSync"))
        self.assertFails(s.run(), "cliproxyapi: sync OutOfSync")

    def test_a_devhost_ci_application_is_revision_checked_only(self):
        s = Scenario(self)
        s.application(root(["backstage", "devhost-ci"]))
        s.application(app("backstage"))
        s.application(app("devhost-ci", server=DEVHOST, sync="OutOfSync", health="Degraded"))
        self.assertPasses(s.run(DEVHOST_CI_SERVER=DEVHOST))

    def test_a_devhost_ci_application_still_needs_the_revision(self):
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        s.application(app("devhost-ci", server=DEVHOST, revision=OTHER))
        self.assertFails(s.run(DEVHOST_CI_SERVER=DEVHOST), f"devhost-ci: revision {OTHER}")

    def test_a_devhost_ci_application_that_cannot_be_compared_warns_and_passes(self):
        """The dev host is down: ArgoCD leaves the sync Unknown (and an unreachable host also sets a
        ComparisonError condition), so a stale revision must not stall a staging promotion."""
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        s.application(app("devhost-ci", server=DEVHOST, revision=OTHER, sync="Unknown"))
        run = s.run(DEVHOST_CI_SERVER=DEVHOST)
        self.assertPasses(run)
        self.assertIn("revision-check: WARN devhost-ci: devhost-ci unreachable or not comparable (sync Unknown);"
                      " not blocking", run.stdout)

    def test_a_devhost_ci_application_with_a_comparison_error_warns_and_passes(self):
        """OutOfSync with a ComparisonError condition: the comparison never ran, so the revision is stale."""
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        child = app("devhost-ci", server=DEVHOST, revision=OTHER, sync="OutOfSync")
        child["status"]["conditions"] = [{"type": "ComparisonError", "message": "connection refused"}]
        s.application(child)
        run = s.run(DEVHOST_CI_SERVER=DEVHOST)
        self.assertPasses(run)
        self.assertIn("WARN devhost-ci: devhost-ci unreachable or not comparable (sync OutOfSync); not blocking",
                      run.stdout)

    def test_a_comparable_devhost_ci_application_at_another_revision_still_fails(self):
        """Synced, no error condition: the dev host was reached and reports another revision, which is a real
        failure."""
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        s.application(app("devhost-ci", server=DEVHOST, revision=OTHER, sync="Synced"))
        self.assertFails(s.run(DEVHOST_CI_SERVER=DEVHOST), f"devhost-ci: revision {OTHER}")

    def test_a_non_devhost_application_that_cannot_be_compared_still_fails(self):
        """The warning is only for a child whose destination.server is DEVHOST_CI_SERVER: an Unknown sync on
        r415 itself is a failure."""
        s = Scenario(self)
        s.application(root(["backstage"]))
        s.application(app("backstage", revision=OTHER, sync="Unknown"))
        self.assertFails(s.run(DEVHOST_CI_SERVER=DEVHOST), "backstage: sync Unknown")

    def test_without_a_devhost_ci_server_that_application_is_health_checked(self):
        s = Scenario(self)
        s.application(root(["devhost-ci"]))
        s.application(app("devhost-ci", server=DEVHOST, sync="OutOfSync"))
        self.assertFails(s.run(), "devhost-ci: sync OutOfSync")

    def test_prints_one_line_per_failing_application(self):
        s = Scenario(self)
        s.application(root(["a", "b", "c"], sync="OutOfSync"))
        s.application(app("a", revision=OTHER))
        s.application(app("b", health="Degraded"))
        s.application(app("c"))
        run = s.run()
        self.assertEqual(run.returncode, 1)
        lines = [ln for ln in run.stdout.splitlines() if ln]
        self.assertEqual(len(lines), 3, run.stdout)
        self.assertTrue(any(ln.startswith("app-of-apps: sync") for ln in lines), lines)
        self.assertTrue(any(ln.startswith("a: revision") for ln in lines), lines)
        self.assertTrue(any(ln.startswith("b: health") for ln in lines), lines)

    # -- rule 4: profile-plugin Applications follow the profile-controller ConfigMap

    def plugin(self, name="profile-plugin-jwks", target=PLUGIN_VERSION):
        return app(name, repo="https://teknoir.github.io/profile-plugins-helm", chart=name, target=target)

    def test_a_plugin_application_follows_the_configmap_version(self):
        s = self.scenario()
        s.applications([self.plugin()])
        s.configmap(configmap())
        self.assertPasses(s.run())

    def test_a_plugin_application_at_another_version_fails(self):
        s = self.scenario()
        s.applications([self.plugin(target="0.0.112")])
        s.configmap(configmap())
        self.assertFails(s.run(), "profile-plugin-jwks: plugin chart 0.0.112 (want 0.0.113")

    def test_a_plugin_application_without_the_configmap_fails(self):
        s = self.scenario()
        s.applications([self.plugin()])
        self.assertFails(s.run(), "teknoir-system/profile-controller-config: not found")

    def test_without_plugin_applications_the_configmap_is_not_needed(self):
        s = self.scenario()
        s.applications([])
        self.assertPasses(s.run())

    def test_a_configmap_without_the_version_fails(self):
        s = self.scenario()
        s.applications([self.plugin()])
        s.configmap({"metadata": {"name": "profile-controller-config"}, "data": {}})
        self.assertFails(s.run(), "no data.PLUGIN_CHART_VERSION")

    def test_the_revision_is_required(self):
        run = self.scenario().run(REVISION="")
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
