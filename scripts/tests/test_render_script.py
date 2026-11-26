"""The REAL scripts/staging-render.sh on a fixture tree, with kubectl absent from PATH: the render never talks to a
cluster (the flow tests replace the script by a fake, so this is the only place that proves the claim)."""
import json
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
         "wc", "ls", "cat", "dirname", "date", "tr", "sort", "uniq", "basename", "readlink", "realpath", "chmod", "ln",
         "awk", "find", "printf", "tee"]
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
        write(os.path.join(tree, "charts/app-of-apps/values.yaml"), "release: ''\n")
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
{{- if eq $n "alpha" }}
      valueFiles: [values.yaml, ../../pins/alpha.yaml]
{{- else }}
      parameters:
        - {name: image.tag, value: v1}
{{- end }}
{{- end }}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: foreign, namespace: teknoir-system}
spec:
  destination: {namespace: x, server: https://kubernetes.default.svc}
  source: {repoURL: https://example.org/other, chart: other, targetRevision: 1.0.0}
""")
        # a value file outside the chart directory, like pins/<group>.yaml: passed with -f after values.yaml
        write(os.path.join(tree, "pins/alpha.yaml"), "image: {tag: pinned}\n")
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
        return subprocess.run([os.path.join(self.bin, "bash"), SCRIPT, "--tree", self.tree, "--release", SHA,
                               "--out", out, "--plugins", "none", *extra],
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
        self.assertIn("ghcr.io/teknoir/alpha:pinned", open(os.path.join(out, "apps", "alpha.yaml")).read())  # the Application's valueFiles reached the child
        self.assertIn("ghcr.io/teknoir/beta:v1", open(os.path.join(out, "apps", "beta.yaml")).read())    # the Application's parameter reached the child
        self.assertFalse(os.path.exists(os.path.join(out, "failed")))

    def test_a_second_render_is_served_from_the_cache(self):
        out = os.path.join(self.tmp, "out")
        self.assertEqual(self.render(out).returncode, 0)
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("cached   alpha", r.stdout)

    def test_a_changed_value_file_content_is_rendered_again(self):
        # the cache key hashes the value files by content: git rev-parse HEAD would not see this change
        out = os.path.join(self.tmp, "out")
        self.assertEqual(self.render(out).returncode, 0)
        self.assertIn("cached   alpha", self.render(out).stdout)
        write(os.path.join(self.tree, "pins/alpha.yaml"), "image: {tag: pinned2}\n")
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("rendered alpha", r.stdout)
        self.assertIn("ghcr.io/teknoir/alpha:pinned2", open(os.path.join(out, "apps", "alpha.yaml")).read())

    def test_a_changed_template_is_rendered_again_without_a_commit(self):
        # the chart part of the cache key hashes the chart's files by content: git rev-parse HEAD would not see this
        out = os.path.join(self.tmp, "out")
        self.assertEqual(self.render(out).returncode, 0)
        self.assertIn("cached   alpha", self.render(out).stdout)
        path = os.path.join(self.tree, "charts/alpha/templates/d.yaml")
        write(path, open(path).read().replace("spec:\n  template:", "spec:\n  revisionHistoryLimit: 3\n  template:", 1))
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("rendered alpha", r.stdout)
        self.assertIn("revisionHistoryLimit: 3", open(os.path.join(out, "apps", "alpha.yaml")).read())
        self.assertIn("cached   beta", r.stdout)        # a chart nobody touched stays cached

    def add_app(self, name, valuefiles):
        write(os.path.join(self.tree, "charts/app-of-apps/templates/extra.yaml"), f"""\
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {{name: {name}, namespace: teknoir-system}}
spec:
  destination: {{namespace: ns-{name}, server: https://kubernetes.default.svc}}
  source:
    repoURL: https://github.com/teknoir/platform-applications-gitops
    path: charts/alpha
    targetRevision: branch
    helm:
      valueFiles: [{", ".join(valuefiles)}]
""")

    def test_an_absolute_value_file_resolves_against_the_repository_root(self):
        # ArgoCD resolves a valueFiles entry starting with / against the repository root, not the chart directory
        self.add_app("gamma", ["/pins/alpha.yaml"])
        out = os.path.join(self.tmp, "out")
        r = self.render(out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ghcr.io/teknoir/alpha:pinned", open(os.path.join(out, "apps", "gamma.yaml")).read())

    def test_a_value_file_outside_the_tree_is_refused(self):
        self.add_app("gamma", ["../../../etc/hosts"])
        out = os.path.join(self.tmp, "out")
        r = self.render(out)
        self.assertEqual(r.returncode, 1)
        self.assertIn("outside the tree", r.stderr)
        self.assertEqual(open(os.path.join(out, "failed")).read().split(), ["gamma"])
        self.assertFalse(os.path.exists(os.path.join(out, "apps", "gamma.yaml")))
        self.assertTrue(os.path.exists(os.path.join(out, "apps", "alpha.yaml")))    # the others still render

    def test_an_absolute_value_file_outside_the_tree_is_refused(self):
        write(os.path.join(self.tmp, "outside.yaml"), "image: {tag: outside}\n")
        self.add_app("gamma", ["/../outside.yaml"])
        out = os.path.join(self.tmp, "out")
        r = self.render(out)
        self.assertEqual(r.returncode, 1)
        self.assertIn("outside the tree", r.stderr)
        self.assertEqual(open(os.path.join(out, "failed")).read().split(), ["gamma"])

    def test_a_missing_value_file_is_refused(self):
        self.add_app("gamma", ["../../pins/nope.yaml"])
        r = self.render(os.path.join(self.tmp, "out"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("does not exist", r.stderr)

    def test_the_script_names_no_cluster_tool(self):
        text = open(SCRIPT).read()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for tool in ("kubectl", "argocd", "oc "):
            self.assertNotIn(tool, code)


PLUGIN = """\
apiVersion: v1
kind: ConfigMap
metadata: {{name: {name}, namespace: {{{{ .Release.Namespace }}}}}}
data:
  chart: {name}
"""


class PluginRender(unittest.TestCase):
    """--plugins tree and auto (CI v4 P9.1): the imported profile plugin charts of plugins/charts/ rendered offline,
    and auto still on the chart repository until profile-controller's config carries PLUGIN_GIT_REPO_URL."""

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
        # no curl: the chart-repository plugin mode must not fetch anything in these tests (tree mode is offline)
        self.assertFalse(os.path.exists(os.path.join(self.bin, "curl")))
        self.env = {"PATH": self.bin, "HOME": self.tmp, "XDG_CACHE_HOME": os.path.join(self.tmp, "cache"),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
        tree = self.tree = os.path.join(self.tmp, "tree")
        write(os.path.join(tree, "charts/app-of-apps/Chart.yaml"), "apiVersion: v2\nname: app-of-apps\nversion: 0.1.0\n")
        write(os.path.join(tree, "charts/app-of-apps/values.yaml"), "release: ''\n")
        write(os.path.join(tree, "charts/app-of-apps/templates/apps.yaml"), """\
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: profile-controller, namespace: teknoir-system}
spec:
  destination: {namespace: teknoir-applications, server: https://kubernetes.default.svc}
  source:
    repoURL: https://github.com/teknoir/platform-applications-gitops
    path: charts/profile-controller
    targetRevision: branch
""")
        write(os.path.join(tree, "charts/profile-controller/Chart.yaml"),
              "apiVersion: v2\nname: profile-controller\nversion: 0.1.0\n")
        self.set_controller("")
        write(os.path.join(tree, "charts/profile-controller/templates/configmap.yaml"), """\
apiVersion: v1
kind: ConfigMap
metadata: {name: profile-controller-config, namespace: {{ .Release.Namespace }}}
data:
  PLUGIN_CHART_VERSION: {{ .Values.pluginChartVersion | quote }}
  {{- with .Values.pluginGitRepoUrl }}
  PLUGIN_GIT_REPO_URL: {{ . | quote }}
  {{- end }}
""")
        self.add_plugin("profile-plugin-alpha")
        subprocess.run(["git", "init", "-q", tree], check=True)
        H.git(tree, "add", "-A")
        H.git(tree, "commit", "-q", "-m", "fixture")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def set_controller(self, git_repo_url):
        write(os.path.join(self.tree, "charts/profile-controller/values.yaml"),
              f'pluginChartVersion: "0.0.113-p2"\npluginGitRepoUrl: {git_repo_url!r}\n')

    def add_plugin(self, chart):
        write(os.path.join(self.tree, "plugins/charts", chart, "Chart.yaml"),
              f"apiVersion: v2\nname: {chart}\nversion: 0.0.113-p2\n")
        write(os.path.join(self.tree, "plugins/charts", chart, "templates/cm.yaml"), PLUGIN.format(name=chart))

    def render(self, out, plugins):
        return subprocess.run([os.path.join(self.bin, "bash"), SCRIPT, "--tree", self.tree, "--release", SHA,
                               "--out", out, "--plugins", plugins],
                              capture_output=True, text=True, env=self.env)

    def plugins_json(self, out):
        with open(os.path.join(out, "plugins.json")) as fh:
            return json.load(fh)

    def test_tree_mode_renders_each_imported_chart_offline(self):
        out = os.path.join(self.tmp, "out")
        r = self.render(out, "tree")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(out, "plugins"))), ["profile-plugin-alpha.yaml"])
        rendered = open(os.path.join(out, "plugins", "profile-plugin-alpha.yaml")).read()
        self.assertIn("name: profile-plugin-alpha", rendered)
        self.assertIn("namespace: teknoir-plugins", rendered)        # helm template ... --namespace teknoir-plugins
        self.assertEqual(self.plugins_json(out),
                         {"mode": "git", "revision": SHA, "charts": ["profile-plugin-alpha"]})

    def test_the_tree_render_is_cached_by_chart_content(self):
        out = os.path.join(self.tmp, "out")
        self.assertIn("plugins  rendered profile-plugin-alpha", self.render(out, "tree").stdout)
        self.assertIn("plugins  cached profile-plugin-alpha", self.render(out, "tree").stdout)
        path = os.path.join(self.tree, "plugins/charts/profile-plugin-alpha/templates/cm.yaml")
        write(path, open(path).read() + "  extra: added\n")
        r = self.render(out, "tree")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("plugins  rendered profile-plugin-alpha", r.stdout)
        self.assertIn("extra: added", open(os.path.join(out, "plugins", "profile-plugin-alpha.yaml")).read())

    def test_a_failing_chart_is_reported_and_the_others_render(self):
        self.add_plugin("profile-plugin-broken")
        write(os.path.join(self.tree, "plugins/charts/profile-plugin-broken/templates/fail.yaml"), '{{ fail "boom" }}\n')
        out = os.path.join(self.tmp, "out")
        r = self.render(out, "tree")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("FAILED   profile-plugin-broken", r.stderr)
        self.assertEqual(open(os.path.join(out, "failed")).read().split(), ["profile-plugin-broken"])
        self.assertTrue(os.path.exists(os.path.join(out, "plugins", "profile-plugin-alpha.yaml")))

    def test_auto_uses_the_tree_when_the_controller_config_carries_the_git_repo_url(self):
        self.set_controller("https://github.com/teknoir/platform-applications-gitops")
        out = os.path.join(self.tmp, "out")
        r = self.render(out, "auto")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.plugins_json(out),
                         {"mode": "git", "revision": SHA, "charts": ["profile-plugin-alpha"]})
        self.assertTrue(os.path.exists(os.path.join(out, "plugins", "profile-plugin-alpha.yaml")))

    def test_auto_stays_on_the_chart_repository_without_the_git_repo_url(self):
        # today: no PLUGIN_GIT_REPO_URL, so auto follows PLUGIN_CHART_VERSION to the published chart repository; the
        # fixture has no curl, which proves the tree (plugins/charts/) was not used as the fallback
        out = os.path.join(self.tmp, "out")
        r = self.render(out, "auto")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("cannot fetch", r.stderr)
        self.assertEqual(open(os.path.join(out, "failed")).read().split(), ["plugin-index"])
        self.assertEqual(os.listdir(os.path.join(out, "plugins")), [])


if __name__ == "__main__":
    unittest.main()
