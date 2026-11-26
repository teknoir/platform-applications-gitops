"""Plugin git mode (CI v4 P9.1, plugins/charts/README.md): a new revision must not change the pod template.

charts/profile-controller renders the profile-plugin Applications at config.pluginGit.revision. That revision lives in
templates/plugin-revision-configmap.yaml, not in the ConfigMap the Deployment hashes (annotations checksum/config): a
revision in configmap.yaml would restart profile-controller on every release. This renders the chart the way the
profile-controller Application does (charts/app-of-apps templates/controllers.yaml: values.yaml and
pins/profile-controller.yaml) at two revisions and asserts the Deployment documents are byte-identical while the
revision ConfigMaps differ, and that chart mode (no repoURL) renders no revision ConfigMap at all.

Skip when helm is not on PATH."""
import os
import re
import shutil
import subprocess
import sys
import unittest

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

ROOT = os.path.dirname(H.SCRIPTS)
CHART = os.path.join(ROOT, "charts", "profile-controller")
PINS = os.path.join(ROOT, "pins", "profile-controller.yaml")
REPO = "https://github.com/teknoir/platform-applications-gitops"
A = "0123456789abcdef0123456789abcdef01234567"
B = "fedcba9876543210fedcba9876543210fedcba98"
DOC = re.compile(r"(?m)^---\n")


def render(revision):
    """The chart rendered with the profile-controller Application's valueFiles, in git mode at `revision`
    (chart mode when it is None)."""
    args = ["helm", "template", "profile-controller", CHART, "--namespace", "teknoir-system", "-f", PINS]
    if revision is not None:
        args += ["--set", f"config.pluginGit.repoURL={REPO}", "--set-string", f"config.pluginGit.revision={revision}"]
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def documents(out):
    """{"Kind/name": the document's text as rendered}, for a byte comparison of two renders."""
    docs = {}
    for chunk in DOC.split(out):
        chunk = chunk.strip("\n")
        if not chunk.strip():
            continue
        d = yaml.safe_load(chunk)       # the "# Source: ..." comment line is YAML, so the text stays as rendered
        if not isinstance(d, dict) or "kind" not in d:
            continue
        docs[f"{d['kind']}/{d['metadata']['name']}"] = chunk
    return docs


@unittest.skipUnless(shutil.which("helm"), "helm is not on PATH: the render comparison needs helm template")
class PluginRevisionRender(unittest.TestCase):
    def test_two_revisions_render_the_same_deployment_and_different_revision_configmaps(self):
        a, b = documents(render(A)), documents(render(B))
        self.assertIn("Deployment/profile-controller", a)
        self.assertEqual(a["Deployment/profile-controller"], b["Deployment/profile-controller"])
        key = "ConfigMap/profile-controller-plugin-revision"
        self.assertIn(key, a)
        self.assertEqual(yaml.safe_load(a[key])["data"]["revision"], A)
        self.assertEqual(yaml.safe_load(b[key])["data"]["revision"], B)
        self.assertNotEqual(a[key], b[key])

    def test_the_controller_reads_the_revision_from_that_configmap(self):
        a = documents(render(A))
        data = yaml.safe_load(a["ConfigMap/profile-controller-config"])["data"]
        self.assertEqual(data["PLUGIN_GIT_REPO_URL"], REPO)
        self.assertEqual(data["PLUGIN_GIT_PATH"], "plugins/charts")
        self.assertEqual(data["PLUGIN_REVISION_CONFIGMAP"], "teknoir-system/profile-controller-plugin-revision")

    def test_chart_mode_renders_no_revision_configmap_and_no_git_key(self):
        c = documents(render(None))
        self.assertNotIn("ConfigMap/profile-controller-plugin-revision", c)
        data = yaml.safe_load(c["ConfigMap/profile-controller-config"])["data"]
        self.assertNotIn("PLUGIN_GIT_REPO_URL", data)
        self.assertIn("PLUGIN_CHART_VERSION", data)


if __name__ == "__main__":
    unittest.main()
