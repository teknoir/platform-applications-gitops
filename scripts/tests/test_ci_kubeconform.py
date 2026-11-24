"""scripts/ci/kubeconform.sh over tiny render dirs (the kubeconform job of .github/workflows/ci.yml). Needs
kubeconform on PATH and network for the schemas (the datreeio CRDs catalog); skipped without either."""
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

SCRIPT = os.path.join(H.SCRIPTS, "ci", "kubeconform.sh")

DEPLOYMENT = """\
apiVersion: apps/v1
kind: Deployment
metadata: {name: web, namespace: ns}
spec:
  replicas: 1
  selector: {matchLabels: {app: web}}
  template:
    metadata: {labels: {app: web}}
    spec:
      containers:
        - {name: web, image: "ghcr.io/teknoir/x:sha-1234abcd@sha256:%s"}
""" % ("a" * 64)

APPLICATION = """\
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: a, namespace: teknoir-system}
spec:
  project: default
  destination: {namespace: ns, server: "https://kubernetes.default.svc"}
  source: {repoURL: "https://github.com/teknoir/platform-applications-gitops", path: charts/x, targetRevision: main}
"""

INVALID = DEPLOYMENT.replace("replicas: 1", 'replicas: "two"')

# pass 2 validates the argoproj.io group without -ignore-missing-schemas: an unknown kind of that group has no schema
NOKIND = """\
apiVersion: argoproj.io/v1alpha1
kind: NoSuchKind
metadata: {name: x, namespace: ns}
"""

# the same, hidden in the items of a v1 List
NOKIND_LIST = """\
apiVersion: v1
kind: List
items:
  - apiVersion: argoproj.io/v1alpha1
    kind: NoSuchKind
    metadata: {name: x, namespace: ns}
"""


@unittest.skipUnless(shutil.which("kubeconform"), "kubeconform not installed")
@unittest.skipIf(os.environ.get("CI_OFFLINE") == "1", "needs network for the schemas")
class Kubeconform(unittest.TestCase):
    def render(self, *docs):
        d = H.tmpdir()
        os.makedirs(os.path.join(d, "apps"))
        for i, text in enumerate(docs):
            with open(os.path.join(d, "apps", f"{i}.yaml"), "w") as fh:
                fh.write(text)
        return d

    def run_script(self, render):
        return subprocess.run(["bash", SCRIPT, render], capture_output=True, text=True)

    def test_a_valid_render_passes(self):
        r = self.run_script(self.render(DEPLOYMENT, APPLICATION))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_an_invalid_resource_fails(self):
        r = self.run_script(self.render(INVALID, APPLICATION))
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("pass 1 FAILED", r.stderr)

    def test_an_unknown_kind_of_a_checked_group_fails_pass_2(self):
        r = self.run_script(self.render(DEPLOYMENT, NOKIND))
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("pass 2 FAILED", r.stderr)

    def test_an_unknown_kind_in_a_list_fails_pass_2(self):
        r = self.run_script(self.render(DEPLOYMENT, NOKIND_LIST))
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("pass 2 FAILED", r.stderr)

    def test_an_unusable_argument_is_a_usage_error(self):
        r = subprocess.run(["bash", SCRIPT], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        r = subprocess.run(["bash", SCRIPT, os.path.join(H.tmpdir(), "nope")], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
