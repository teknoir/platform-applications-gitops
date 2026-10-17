"""The REAL scripts/staging-render.sh on a fixture tree, with kubectl absent from PATH: the render never talks to a
cluster (the flow tests replace the script by a fake, so this is the only place that proves the claim)."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

SCRIPT = os.path.join(H.SCRIPTS, "staging-render.sh")
TOOLS = ["bash", "env", "helm", "python3", "git", "sha256sum", "cut", "cp", "mktemp", "rm", "mkdir", "grep", "head", "sed",
         "wc", "ls", "cat", "dirname", "date", "tr", "sort", "uniq", "basename", "readlink", "chmod", "ln", "awk", "find", "printf", "tee"]
SHA = "a" * 40


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


class RenderWithoutKubectl(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = [t for t in ("helm", "python3", "git") if not shutil.which(t)]
        if missing:
            raise unittest.SkipTest(f"missing tools: {missing}")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        for t in TOOLS:
            p = shutil.which(t)
            if p:
                os.symlink(p, os.path.join(self.bin, t))
        self.assertFalse(os.path.exists(os.path.join(self.bin, "kubectl")))
        self.env = {"PATH": self.bin, "HOME": self.tmp, "XDG_CACHE_HOME": os.path.join(self.tmp, "cache"),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
        # the fixture tree: a root chart rendering two gitops children (one with a helm parameter), one foreign Application
        tree = self.tree = os.path.join(self.tmp, "tree")
        write(os.path.join(tree, "charts/app-of-apps/Chart.yaml"), "apiVersion: v2\nname: app-of-apps\nversion: 0.1.0\n")
        write(os.path.join(tree, "charts/app-of-apps/values.yaml"), "release: ''\nreleaseName: ''\n")
        write(os.path.join(tree, "charts/app-of-apps/templates/apps.yaml"), """\
{{- range $n := list "alpha" "beta" }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: {{ $n }}, namespace: teknoir-system}
spec:
  destination: {namespace: ns-{{ $n }}, server: https://kubernetes.default.svc}
  source:
    repoURL: https://github.com/teknoir/platform-applications-gitops
    path: charts/{{ $n }}
    targetRevision: {{ $.Values.release | default "branch" | quote }}
    helm:
      parameters:
        - {name: image.tag, value: v1}
{{- end }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: foreign, namespace: teknoir-system}
spec:
  destination: {namespace: x, server: https://kubernetes.default.svc}
  source: {repoURL: https://example.org/other, chart: other, targetRevision: 1.0.0}
""")
        for n in ("alpha", "beta"):
            write(os.path.join(tree, f"charts/{n}/Chart.yaml"), f"apiVersion: v2\nname: {n}\nversion: 0.1.0\n")
            write(os.path.join(tree, f"charts/{n}/values.yaml"), "image: {tag: x}\n")
            write(os.path.join(tree, f"charts/{n}/templates/d.yaml"), f"""\
apiVersion: apps/v1
kind: Deployment
metadata: {{name: {n}}}
spec:
  template:
    spec:
      containers:
        - {{name: c, image: "ghcr.io/teknoir/{n}:{{{{ .Values.image.tag }}}}"}}
""")
        subprocess.run(["git", "init", "-q", tree], check=True)
        H.git(tree, "add", "-A")
        H.git(tree, "commit", "-q", "-m", "fixture")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def render(self, out, *extra):
        return subprocess.run([os.path.join(self.bin, "bash"), SCRIPT, "--tree", self.tree, "--release", SHA, "--release-name",
                               "staging-20261017.1", "--out", out, "--plugins", "none", *extra],
                              capture_output=True, text=True, env=self.env)

    def test_kubectl_is_really_absent(self):
        r = subprocess.run([os.path.join(self.bin, "bash"), "-c", "command -v kubectl"], capture_output=True, text=True, env=self.env)
        self.assertNotEqual(r.returncode, 0)

    def test_renders_the_root_and_the_children_without_a_cluster(self):
        out = os.path.join(self.tmp, "out")
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(out, "apps"))), ["alpha.yaml", "beta.yaml"])     # the foreign one is not rendered
        self.assertEqual(open(os.path.join(out, "apps.tsv")).read().splitlines(),
                         ["alpha\tcharts/alpha\tns-alpha", "beta\tcharts/beta\tns-beta"])
        self.assertIn(f'targetRevision: "{SHA}"', open(os.path.join(out, "root.yaml")).read())            # --release reached the root chart
        self.assertIn("ghcr.io/teknoir/alpha:v1", open(os.path.join(out, "apps", "alpha.yaml")).read())  # the Application's parameter reached the child
        self.assertFalse(os.path.exists(os.path.join(out, "failed")))

    def test_a_second_render_is_served_from_the_cache(self):
        out = os.path.join(self.tmp, "out")
        self.assertEqual(self.render(out).returncode, 0)
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("cached   alpha", r.stdout)

    def test_the_script_names_no_cluster_tool(self):
        text = open(SCRIPT).read()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for tool in ("kubectl", "argocd", "oc "):
            self.assertNotIn(tool, code)


if __name__ == "__main__":
    unittest.main()
