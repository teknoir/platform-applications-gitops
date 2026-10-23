"""charts/ci Git LFS handling: plan.py lfs modes (images auto, tests false) and clone.sh (pull, pointer guard, warning,
git-lfs already in the image). clone.sh runs for real against a local git repo with a fake git-lfs/apk on PATH; no network."""
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

CI_FILES = os.path.join(os.path.dirname(H.SCRIPTS), "charts", "ci", "files")
SHA = "a" * 40


def load_plan(tmp, repos):
    """Import charts/ci/files/plan.py with its environment pointed at a fixture."""
    env = {"REPO": "r", "REF": "refs/heads/main", "SHA": SHA, "GITHUB_ORG": "teknoir", "HARBOR_HOST": "",
           "HARBOR_PROJECT": "teknoir", "BUILDERS": json.dumps({"vpro": "tcp://x:1"}),
           "OUT": os.path.join(tmp, "out"), "REPOS_DIR": repos}
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("ci_plan_under_test", os.path.join(CI_FILES, "plan.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.keep_ref = lambda ref: True  # no registry lookups
    return mod


class PlanLfs(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()
        self.repos = os.path.join(self.tmp, "repos")
        os.makedirs(self.repos)
        with open(os.path.join(self.repos, "_defaults.json"), "w") as f:
            json.dump({"repo": {"branches": ["**"], "tags": [], "tests": [], "images": []},
                       "image": {"branchTags": ["sha-{sha8}"], "tagTags": ["{tag}"], "latestBranches": ["main"],
                                 "platforms": ["linux/amd64"]},
                       "test": {"cpu": "500m", "memory": "1Gi"}, "helm": {}, "builder": "vpro"}, f)
        os.makedirs(os.path.join(self.tmp, "out"))
        self.plan = load_plan(self.tmp, self.repos)

    def run_plan(self, cfg):
        with open(os.path.join(self.repos, "r.json"), "w") as f:
            json.dump(cfg, f)
        with self.assertRaises(SystemExit) as cm:
            self.plan.main()
        out = lambda n: open(os.path.join(self.tmp, "out", n)).read()
        return cm.exception.code, json.loads(out("images")), json.loads(out("tests")), out("summary")

    def test_lfs_mode_values(self):
        for given, want in ((True, "true"), (False, "false"), ("auto", "auto"), ("AUTO", "auto"), ("true", "true"),
                            ("False", "false")):
            self.assertEqual(self.plan.lfs_mode(given), want)

    def test_lfs_mode_rejects_other_values(self):
        for bad in ("yes", "", None, 1):
            with self.assertRaises(SystemExit) as cm:
                self.plan.lfs_mode(bad)
            self.assertEqual(cm.exception.code, 2)

    def test_image_default_is_auto(self):
        _, images, _, _ = self.run_plan({"images": [{"name": "a"}]})
        self.assertEqual(images[0]["lfs"], "auto")

    def test_image_explicit_values(self):
        _, images, _, _ = self.run_plan({"images": [{"name": "a", "lfs": True}, {"name": "b", "lfs": False},
                                                    {"name": "c", "lfs": "auto"}]})
        self.assertEqual([i["lfs"] for i in images], ["true", "false", "auto"])

    def test_test_default_is_false_and_explicit_wins(self):
        _, _, tests, _ = self.run_plan({"tests": [{"name": "t1", "image": "i", "run": "x"},
                                                  {"name": "t2", "image": "i", "run": "x", "lfs": True}]})
        self.assertEqual([t["lfs"] for t in tests], ["false", "true"])

    def test_invalid_value_is_a_config_error(self):
        code, _, _, summary = self.run_plan_expect_error({"images": [{"name": "a", "lfs": "maybe"}]})
        self.assertEqual(code, 2)
        self.assertIn("lfs must be", summary)

    def run_plan_expect_error(self, cfg):
        with open(os.path.join(self.repos, "r.json"), "w") as f:
            json.dump(cfg, f)
        with self.assertRaises(SystemExit) as cm:
            self.plan.main()
        return cm.exception.code, None, None, open(os.path.join(self.tmp, "out", "summary")).read()


class RepoFiles(unittest.TestCase):
    def read(self, name):
        with open(os.path.join(CI_FILES, "repos", name)) as f:
            return f.read()

    def test_lfs_repos_set_lfs_true(self):
        for name in ("rtdetr-triton.yaml", "nvidia-tracker-deepstream.yaml"):
            self.assertIn("lfs: true}", self.read(name), name)

    def test_workflow_passes_lfs_to_tests_and_images(self):
        wf = open(os.path.join(CI_FILES, "workflows", "ci-dispatch.yaml")).read()
        self.assertEqual(wf.count('{name: LFS, value: "{{inputs.parameters.lfs}}"}'), 2)  # run-test and build-image clones
        self.assertIn('{name: lfs, value: "{{item.lfs}}"}', wf)


FAKE_LFS = """#!/bin/sh
# fake git-lfs: records calls; ls-files prints $LFS_LS_FILES (a file); FAKE_LFS_MISSING makes `version` fail
echo "lfs $*" >> "$CALLS"
case "$1" in
	version) [ -z "${FAKE_LFS_MISSING:-}" ] || exit 1 ;;
	ls-files) [ -z "${LFS_LS_FILES:-}" ] || cat "$LFS_LS_FILES" ;;
	pull) [ -z "${LFS_PULL_FAILS:-}" ] || { echo "pull failed" >&2; exit 1; } ;;
esac
exit 0
"""
FAKE_APK = """#!/bin/sh
echo "apk $*" >> "$CALLS"
# installing git-lfs makes the fake available
rm -f "$MARK_MISSING"
exit 0
"""


class CloneSource(unittest.TestCase):
    def test_checkout_does_not_smudge_lfs_files(self):
        sh = open(os.path.join(CI_FILES, "clone.sh")).read()
        self.assertIn("\nexport GIT_LFS_SKIP_SMUDGE=1\n", sh)
        self.assertLess(sh.index("export GIT_LFS_SKIP_SMUDGE=1"), sh.index("fetch -q"))


class CloneLfs(unittest.TestCase):
    def setUp(self):
        self.tmp = H.tmpdir()
        t = self.tmp
        self.src, self.bin = os.path.join(t, "src"), os.path.join(t, "bin")
        os.makedirs(self.src)
        os.makedirs(self.bin)
        self.calls = os.path.join(t, "calls")
        open(self.calls, "w").close()
        with open(os.path.join(t, "token"), "w") as f:
            f.write("dummy-token")
        # clone.sh with /src and /github/token pointed into the temp dir
        s = open(os.path.join(CI_FILES, "clone.sh")).read().replace("/github/token", os.path.join(t, "token")).replace("/src", self.src)
        self.script = os.path.join(t, "clone.sh")
        open(self.script, "w").write(s)
        for name, body in (("git-lfs", FAKE_LFS), ("apk", FAKE_APK)):
            p = os.path.join(self.bin, name)
            open(p, "w").write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)
        # symlink the real tools clone.sh needs, so PATH holds only these plus the fakes
        for tool in ("git", "sh", "base64", "tr", "wc", "grep", "chmod", "cat", "rm", "dirname", "sed", "head", "env", "mktemp",
                     "uname", "ln", "cp", "mv", "basename", "date", "touch", "test", "["):
            real = shutil.which(tool)
            if real and not os.path.exists(os.path.join(self.bin, tool)):
                os.symlink(real, os.path.join(self.bin, tool))
        self.origin = os.path.join(t, "origin")

    def make_origin(self, lfs_files):
        os.makedirs(self.origin)
        git = lambda *a: H.git(self.origin, *a)
        subprocess.run(["git", "init", "-q", "-b", "main", self.origin], check=True)
        open(os.path.join(self.origin, "README"), "w").write("x\n")
        if lfs_files:
            open(os.path.join(self.origin, ".gitattributes"), "w").write("*.bin filter=lfs diff=lfs merge=lfs -text\n")
            for n in lfs_files:
                open(os.path.join(self.origin, n), "w").write("version https://git-lfs.github.com/spec/v1\noid sha256:" + "0" * 64 + "\nsize 5\n")
        git("add", "-A")
        git("commit", "-q", "-m", "c")
        return git("rev-parse", "HEAD")

    def run_clone(self, sha, lfs=None, ls_files=None, **env):
        e = {"PATH": self.bin, "HOME": self.tmp, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
             "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"url.{self.origin}.insteadOf",
             "GIT_CONFIG_VALUE_0": "https://github.com/o/r.git", "ORG": "o", "REPO": "r", "SHA": sha, "CALLS": self.calls,
             "MARK_MISSING": os.path.join(self.tmp, "missing-mark"), **env}
        if lfs is not None:
            e["LFS"] = lfs
        if ls_files is not None:
            p = os.path.join(self.tmp, "ls-files")
            open(p, "w").write(ls_files)
            e["LFS_ls_files".upper()] = p
        return subprocess.run(["sh", self.script], env=e, capture_output=True, text=True)

    def called(self):
        return open(self.calls).read()

    def test_auto_without_lfs_files_does_not_touch_lfs(self):
        sha = self.make_origin([])
        r = self.run_clone(sha, lfs="auto")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("lfs", self.called())
        self.assertNotIn("warning", r.stderr)

    def test_auto_with_lfs_files_pulls_and_passes_when_objects_present(self):
        sha = self.make_origin(["m.bin"])
        r = self.run_clone(sha, lfs="auto", ls_files="0123456789 * m.bin\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("lfs pull", self.called())
        self.assertNotIn("apk", self.called())  # git-lfs is in the image: no apk, no egress

    def test_true_fails_when_a_file_is_still_a_pointer(self):
        sha = self.make_origin(["m.bin"])
        r = self.run_clone(sha, lfs="true", ls_files="0123456789 - m.bin\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("LFS objects missing", r.stderr)
        self.assertIn("m.bin", r.stderr)

    def test_guard_matches_the_marker_only_not_a_dash_in_a_file_name(self):
        sha = self.make_origin(["a - b.bin"])
        r = self.run_clone(sha, lfs="true", ls_files="0123456789 * a - b.bin\n")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_pull_failure_fails_the_step(self):
        sha = self.make_origin(["m.bin"])
        r = self.run_clone(sha, lfs="true", LFS_PULL_FAILS="1")
        self.assertNotEqual(r.returncode, 0)

    def test_false_warns_when_the_repo_has_lfs_files(self):
        sha = self.make_origin(["m.bin", "n.bin"])
        r = self.run_clone(sha, lfs="false")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 file(s)", r.stderr)
        self.assertIn("lfs is false", r.stderr)
        self.assertNotIn("lfs pull", self.called())

    def test_unset_defaults_to_false(self):
        sha = self.make_origin(["m.bin"])
        r = self.run_clone(sha)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("lfs pull", self.called())
        self.assertIn("lfs is false", r.stderr)

    def test_apk_installs_git_lfs_only_when_missing(self):
        sha = self.make_origin(["m.bin"])
        r = self.run_clone(sha, lfs="true", ls_files="0123456789 * m.bin\n", FAKE_LFS_MISSING="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("apk add -q --no-cache git-lfs", self.called())


if __name__ == "__main__":
    unittest.main()
