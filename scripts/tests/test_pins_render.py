"""The pins move is workload-neutral (CI/CD v4 P4.2, plans/cicd/v4/p42-spec.md section 2): render the same release
with scripts/staging-render.sh from a worktree of the base ref (the chart values files still held the pins there) and
from the working tree (the pins live in pins/<group>.yaml), each with a fresh cache, and assert every rendered child
under apps/ is byte-identical.

Opt-in, because it needs a base ref that predates the pins: run it when a change must not alter renders with

    PINS_RENDER_BASE=origin/teknoir-cloud python3 -m unittest scripts.tests.test_pins_render

(any ref with the pins still in the chart values works, e.g. a commit on this branch's base). Without
PINS_RENDER_BASE the class skips; so does a checkout without helm or without that ref (CI's scripts-tests job has a
shallow checkout)."""
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

ROOT = os.path.dirname(H.SCRIPTS)
SCRIPT = os.path.join(H.SCRIPTS, "staging-render.sh")
BASE = os.environ.get("PINS_RENDER_BASE")
SHA = "0" * 40
# The grafana subchart of kube-prometheus-stack generates its admin password (and the checksum over it) on every
# render: two renders of the SAME tree differ there, so the comparison masks those two lines.
GENERATED = (re.compile(r'^(\s*admin-password: ).*$', re.M), re.compile(r'^(\s*checksum/secret: ).*$', re.M))


def normalize(text):
    for rx in GENERATED:
        text = rx.sub(r"\1<generated>", text)
    return text


def have_base():
    return subprocess.run(["git", "-C", ROOT, "rev-parse", "--verify", "-q", BASE + "^{commit}"],
                          capture_output=True).returncode == 0


class PinsRenderIsIdentical(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BASE:
            raise unittest.SkipTest("PINS_RENDER_BASE is not set: run it with "
                                    "PINS_RENDER_BASE=origin/teknoir-cloud (a ref whose chart values still hold the pins)")
        if not shutil.which("helm"):
            raise unittest.SkipTest("helm is not on PATH")
        if not shutil.which("git") or not have_base():
            raise unittest.SkipTest(f"{BASE} is not in this checkout")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.base_tree = os.path.join(self.tmp, "base")
        subprocess.run(["git", "-C", ROOT, "worktree", "add", "-q", "--detach", self.base_tree, BASE], check=True)
        # The subchart archives (charts/*/charts, git-ignored build output) are not in the base worktree, and a
        # dependency build would need the chart repositories: copy the ones the working tree has, so both renders
        # see the same charts without network.
        for charts in glob.glob(os.path.join(ROOT, "charts", "*", "charts")):
            dest = os.path.join(self.base_tree, os.path.relpath(charts, ROOT))
            if not os.path.isdir(dest):
                shutil.copytree(charts, dest)

    def tearDown(self):
        subprocess.run(["git", "-C", ROOT, "worktree", "remove", "--force", self.base_tree], capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def render(self, tree, tag):
        """(out dir, failed child names, output). A child whose subchart needs a chart repository that is not
        configured (charts/monitoring's kube-prometheus-stack offline) fails in BOTH trees for the same reason."""
        out = os.path.join(self.tmp, f"out-{tag}")
        r = subprocess.run(["bash", SCRIPT, "--tree", tree, "--release", SHA, "--release-name", "staging-20261124.1",
                            "--out", out, "--cache", os.path.join(self.tmp, f"cache-{tag}"), "--plugins", "none"],
                           capture_output=True, text=True)
        failed_file = os.path.join(out, "failed")
        failed = open(failed_file).read().split() if os.path.exists(failed_file) else []
        return out, failed, r.returncode, r.stdout + r.stderr

    def test_every_rendered_application_is_byte_identical(self):
        base_out, _, base_rc, base_log = self.render(self.base_tree, "base")
        new_out, _, new_rc, new_log = self.render(ROOT, "new")
        # A child whose subchart is not in the checkout needs a configured chart repository (charts/monitoring's
        # kube-prometheus-stack; scripts/ci/helm-repos.sh). Without one this is an environment gap, not a pins
        # difference: skip, and say how to run it.
        if "no repository definition" in new_log or "no repository definition" in base_log:
            self.skipTest("chart repositories not configured: run scripts/ci/helm-repos.sh first")
        self.assertEqual(base_rc, 0, base_log[-2000:])
        self.assertEqual(new_rc, 0, new_log[-2000:])
        base_apps = sorted(os.listdir(os.path.join(base_out, "apps")))
        new_apps = sorted(os.listdir(os.path.join(new_out, "apps")))
        self.assertEqual(base_apps, new_apps)
        self.assertTrue(base_apps)
        for name in base_apps:
            with open(os.path.join(base_out, "apps", name)) as fh:
                before = normalize(fh.read())
            with open(os.path.join(new_out, "apps", name)) as fh:
                after = normalize(fh.read())
            self.assertEqual(before, after, f"{name} changed with the pins move")


if __name__ == "__main__":
    unittest.main()
