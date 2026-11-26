"""scripts/ci/helm-unittest.sh: the charts/* suites plus the imported plugins/charts suites (CI v4 P9.1), a
dependency built only when helm dependency list is not ok, and the emqx ACL check after the loop. A fake helm and a
fake python3 record the calls, so the test needs no helm and no network."""
import os
import shlex
import stat
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

SCRIPT = os.path.join(H.SCRIPTS, "ci", "helm-unittest.sh")
REPO = os.path.dirname(H.SCRIPTS)

# A fake helm: `dependency list` is ok for the charts named in $FAKE_HELM_OK, missing for every other chart (exit 1,
# as helm does); `dependency build` and `unittest` succeed. Everything is logged, one command per line.
FAKE_HELM = r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_HELM_LOG"
case "$1 $2" in
  "dependency list")
    while IFS= read -r c; do
      [[ -n "$c" && "${3%/}" == "${c%/}" ]] && { printf 'NAME\tVERSION\tREPOSITORY\tSTATUS\nx\t1.0.0\thttps://x\tok\n'; exit 0; }
    done < "$FAKE_HELM_OK"
    printf 'NAME\tVERSION\tREPOSITORY\tSTATUS\nx\t1.0.0\thttps://x\tmissing\n'
    exit 1
  ;;
esac
exit 0
"""

# A fake python3: fails `-c 'import yaml'` when $FAKE_PY_NO_YAML is set (the skip path), and creates the last
# argument (an absolute path) so the caller's next step finds its output file.
FAKE_PYTHON = r"""#!/usr/bin/env bash
[[ "$1" == "-c" && -n "${FAKE_PY_NO_YAML:-}" ]] && exit 1
last="${!#}"
[[ "$last" == /* && ! -e "$last" ]] && : > "$last"
exit 0
"""


class HelmUnittest(unittest.TestCase):
    def setUp(self):
        d = self.bin = H.tmpdir()
        self.log = os.path.join(d, "helm.log")
        self.ok = os.path.join(d, "ok")
        with open(self.ok, "w") as fh:
            fh.write("plugins/charts/profile-plugin-emqx\n")     # the vendored dependency: ok on a fresh checkout
        for name, body in (("helm", FAKE_HELM), ("python3", FAKE_PYTHON)):
            p = os.path.join(d, name)
            with open(p, "w") as fh:
                fh.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)

    def run_script(self, **env):
        e = {**os.environ, "PATH": self.bin + os.pathsep + os.environ["PATH"], "FAKE_HELM_LOG": self.log,
             "FAKE_HELM_OK": self.ok, **env}
        return subprocess.run(["bash", SCRIPT], cwd=REPO, env=e, capture_output=True, text=True)

    def calls(self):
        with open(self.log) as fh:
            return fh.read().splitlines()

    def test_every_plugin_suite_runs(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        for chart in ("emqx", "jwks", "observatory"):
            self.assertIn(f"unittest plugins/charts/profile-plugin-{chart}", calls)
        self.assertNotIn("unittest plugins/charts/profile-plugin-claims", calls)   # no tests/*_test.yaml
        self.assertIn("unittest charts/app-of-apps", calls)                        # charts/* unchanged

    def test_a_vendored_dependency_is_not_built_and_another_is(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        self.assertFalse([c for c in calls if c.startswith("dependency build plugins/charts/profile-plugin-emqx")],
                         "the vendored emqx dependency was built: it needs no repository")
        self.assertIn("dependency build charts/auth", calls)          # its subchart is not in a fresh checkout
        self.assertIn("dependencies ok, not built", r.stdout)

    def test_the_emqx_acl_check_runs_after_the_loop(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("acl-check --check", r.stdout)
        self.assertTrue([c for c in self.calls() if c.startswith("template emqx ")], "acl-check.sh did not render")

    def test_the_acl_check_is_skipped_without_pyyaml(self):
        r = self.run_script(FAKE_PY_NO_YAML="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("skipped: python3 has no PyYAML", r.stdout)
        self.assertFalse([c for c in self.calls() if c.startswith("template emqx ")])

    def test_no_cluster_script_is_named(self):
        text = open(SCRIPT).read()
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for name in ("k3d-", "-e2e.sh", "docker"):
            self.assertNotIn(name, code)


if __name__ == "__main__":
    unittest.main()
