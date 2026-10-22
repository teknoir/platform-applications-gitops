"""Tests of scripts/set-upstream-credential.sh with a stub kubectl (no cluster)."""
import base64
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "set-upstream-credential.sh")
TOKEN = "dckr_pat_STUBtokenValue123"

# The stub logs its arguments, and for `create secret` prints a manifest holding the --from-file
# contents (as real kubectl does); for `apply` it records what arrives on stdin.
STUB = r'''#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case " $* " in
  *" create secret "*)
    u=""; p=""
    for a in "$@"; do
      case "$a" in
        --from-file=username=*) u="$(cat "${a#--from-file=username=}")" ;;
        --from-file=password=*) p="$(cat "${a#--from-file=password=}")" ;;
      esac
    done
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: x\ndata:\n  username: %s\n  password: %s\n' \
      "$(printf %s "$u" | base64 -w0)" "$(printf %s "$p" | base64 -w0)" ;;
  *" apply "*) cat > "$STUB_APPLIED"; echo "secret/x serverside-applied" ;;
esac
'''


class SetUpstreamCredentialTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="suc-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        k = os.path.join(bindir, "kubectl")
        with open(k, "w") as f:
            f.write(STUB)
        os.chmod(k, os.stat(k).st_mode | stat.S_IXUSR)
        self.log = os.path.join(self.tmp, "log")
        self.applied = os.path.join(self.tmp, "applied")
        self.env = {"PATH": bindir + ":" + os.environ["PATH"], "STUB_LOG": self.log, "STUB_APPLIED": self.applied}

    def run_script(self, args, stdin):
        return subprocess.run(["bash", SCRIPT] + args, input=stdin, env=self.env, capture_output=True, text=True)

    def calls(self):
        return open(self.log).read().splitlines() if os.path.exists(self.log) else []

    def test_stores_the_secret_without_printing_or_passing_values(self):
        r = self.run_script(["dockerhub", "--context", "vpro"], f"tekn0ir\n{TOKEN}\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Secret teknoir-system/harbor-upstream-dockerhub stored", r.stdout)
        for text in (r.stdout, r.stderr, "\n".join(self.calls())):
            self.assertNotIn(TOKEN, text)
            self.assertNotIn(base64.b64encode(TOKEN.encode()).decode(), text)
        # explicit context and namespace on every kubectl call, server-side apply
        for c in self.calls():
            self.assertIn("--context vpro", c)
            self.assertIn("-n teknoir-system", c)
        self.assertTrue(any("apply --server-side" in c for c in self.calls()))
        self.assertFalse(any("last-applied" in c for c in self.calls()))
        applied = open(self.applied).read()
        self.assertIn(base64.b64encode(TOKEN.encode()).decode(), applied)  # the Secret got the value
        self.assertIn(base64.b64encode(b"tekn0ir").decode(), applied)
        self.assertIn("create secret generic harbor-upstream-dockerhub", "\n".join(self.calls()))

    def test_context_is_required(self):
        r = self.run_script(["dockerhub"], f"u\n{TOKEN}\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("missing --context", r.stderr)
        self.assertEqual(self.calls(), [])

    def test_dry_run_changes_nothing(self):
        r = self.run_script(["dockerhub", "--context", "vpro", "--dry-run"], f"u\n{TOKEN}\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dry run: would create or replace Secret teknoir-system/harbor-upstream-dockerhub", r.stdout)
        self.assertEqual(self.calls(), [])
        self.assertNotIn(TOKEN, r.stdout + r.stderr)

    def test_empty_or_missing_input_is_refused(self):
        for stdin in ("", "user\n", "user\n\n", "\n" + TOKEN + "\n"):
            r = self.run_script(["dockerhub", "--context", "vpro"], stdin)
            self.assertEqual(r.returncode, 2, stdin)
            self.assertIn("need a username (line 1) and a token (line 2)", r.stderr)
            self.assertNotIn(TOKEN, r.stdout + r.stderr)
        self.assertEqual(self.calls(), [])

    def test_whitespace_in_the_token_is_refused_without_echo(self):
        r = self.run_script(["dockerhub", "--context", "vpro"], "u\nab cd\n")
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("ab cd", r.stdout + r.stderr)

    def test_invalid_name_and_extra_arguments(self):
        self.assertEqual(self.run_script(["Docker_Hub", "--context", "vpro"], "u\nt\n").returncode, 2)
        self.assertEqual(self.run_script(["a", "b", "--context", "vpro"], "u\nt\n").returncode, 2)
        self.assertEqual(self.run_script(["--bogus", "a", "--context", "vpro"], "u\nt\n").returncode, 2)
        self.assertEqual(self.calls(), [])

    def test_crlf_input_and_namespace_option(self):
        r = self.run_script(["quay", "--context", "vpro", "--namespace", "other"], f"u\r\n{TOKEN}\r\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("-n other", self.calls()[0])
        applied = open(self.applied).read()
        self.assertIn(base64.b64encode(TOKEN.encode()).decode(), applied)

    def test_a_failing_kubectl_fails_the_script(self):
        with open(os.path.join(self.tmp, "bin", "kubectl"), "w") as f:
            f.write("#!/usr/bin/env bash\necho boom >&2\nexit 1\n")
        r = self.run_script(["dockerhub", "--context", "vpro"], f"u\n{TOKEN}\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn("stored", r.stdout)
        self.assertNotIn(TOKEN, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
