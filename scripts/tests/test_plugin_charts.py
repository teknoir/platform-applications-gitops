"""The imported profile plugin charts (plugins/charts/, CI v4 P9.1): committed despite the /*/**/charts/* ignore, at
one frozen lockstep version, with the emqx dependency vendored, and exactly the expected chart set. Needs git in the
checkout (no network): the properties are properties of the repository, not of a render."""
import os
import subprocess
import sys
import unittest

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

REPO = os.path.dirname(H.SCRIPTS)
TREE = os.path.join(REPO, "plugins", "charts")
VERSION = "0.0.113-p2"
CHARTS = ["alertmanager", "claims", "deadend", "emqx", "fleet-metrics", "grafana", "historian", "influxdb2", "jwks",
          "mongodb", "observatory", "postgres", "prometheus", "useralerts"]


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=False)


class PluginCharts(unittest.TestCase):
    def test_no_chart_file_is_ignored(self):
        # .gitignore's /*/**/charts/* would ignore everything under plugins/charts/: the exceptions must cover it
        r = git("ls-files", "-ci", "--exclude-standard", "--", "plugins/")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "", ".gitignore still ignores committed plugin chart files")

    def test_a_new_plugin_template_is_committed(self):
        # check-ignore works on a path that does not exist: a new template of an imported chart must not be ignored
        r = git("check-ignore", "--no-index", "-q", "--", "plugins/charts/profile-plugin-jwks/templates/x.yaml")
        self.assertEqual(r.returncode, 1, "a new template under plugins/charts/ is ignored")

    def test_a_new_dependency_archive_is_ignored(self):
        # only the vendored emqx archive is exempted: a dependency archive built by a local render stays out of git
        r = git("check-ignore", "--no-index", "-q", "--", "plugins/charts/profile-plugin-emqx/charts/other.tgz")
        self.assertEqual(r.returncode, 0, "a dependency archive under plugins/charts/ is not ignored")

    def test_every_chart_is_at_the_frozen_lockstep_version(self):
        # Lockstep and frozen (plugins/charts/README.md): a plugin change ships by gitops revision (Kargo), never by a
        # chart version bump, so profile-controller can keep rendering the published repository at 0.0.113-p2.
        for chart in CHARTS:
            with open(os.path.join(TREE, f"profile-plugin-{chart}", "Chart.yaml")) as fh:
                doc = yaml.safe_load(fh)
            self.assertEqual(str(doc["version"]), VERSION, f"profile-plugin-{chart}")
            self.assertEqual(doc["name"], f"profile-plugin-{chart}")

    def test_the_emqx_dependency_is_vendored(self):
        d = os.path.join(TREE, "profile-plugin-emqx")
        with open(os.path.join(d, "Chart.lock")) as fh:
            lock = yaml.safe_load(fh)
        self.assertEqual([(x["name"], str(x["version"])) for x in lock["dependencies"]], [("emqx", "5.8.9")])
        self.assertTrue(os.path.isfile(os.path.join(d, "charts/emqx-5.8.9.tgz")))
        r = git("ls-files", "--error-unmatch", "--", "plugins/charts/profile-plugin-emqx/charts/emqx-5.8.9.tgz")
        self.assertEqual(r.returncode, 0, "charts/emqx-5.8.9.tgz is not committed: a render would need repos.emqx.io")

    def test_exactly_the_expected_charts_exist(self):
        found = sorted(n[len("profile-plugin-"):] for n in os.listdir(TREE)
                       if os.path.isdir(os.path.join(TREE, n)) and n.startswith("profile-plugin-"))
        self.assertEqual(found, CHARTS)


if __name__ == "__main__":
    unittest.main()
