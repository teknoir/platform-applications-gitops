import json
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402
from helpers import L  # noqa: E402

ST = H.load("staging_status", "staging-status")


class Pure(unittest.TestCase):
    def test_tag_record_round_trip(self):
        m = L.tag_message(tag="staging-20261017.2", sha="1" * 40, by="s", reason="r", previous=None, live_sha="2" * 40, pending=[],
                          image_changes=[], plugin_digests={"profile-plugin-jwks": "sha256:aa", "profile-plugin-emqx": "sha256:bb"},
                          plugin_version="0.0.104", mode="release", shared_digests={"ghcr.io/teknoir/keycloak-theme:latest": "sha256:cc"})
        rec = ST.parse_tag_record(m)
        self.assertEqual(rec["plugin_version"], "0.0.104")
        self.assertEqual(rec["plugin_digests"], {"profile-plugin-jwks": "sha256:aa", "profile-plugin-emqx": "sha256:bb"})
        self.assertEqual(rec["shared"], {"ghcr.io/teknoir/keycloak-theme:latest": "sha256:cc"})

    def test_compare_digests(self):
        self.assertEqual(ST.compare_digests({"a": "sha256:1"}, {"a": "sha256:1"}), [])
        moved = ST.compare_digests({"a": "sha256:1" * 4}, {"a": "sha256:2" * 4})
        self.assertIn("MOVED", moved[0])
        self.assertEqual(len(ST.compare_digests({"a": "x"}, {"b": "y"})), 2)

    def test_running_floating_separates_platform_from_user(self):
        pod = lambda ns, img: {"metadata": {"namespace": ns}, "spec": {"containers": [{"name": "c", "image": img}]}}
        pods = [pod("teknoir-system", "ghcr.io/teknoir/backstage-app:robot"), pod("teknoir-demo", "ghcr.io/teknoir/jwks-server:latest"),
                pod("teknoir-system", "ghcr.io/teknoir/device-controller:sha-1@sha256:" + "a" * 64), pod("x", "postgres:17-alpine")]
        plat, user = ST.running_floating(pods, ["ghcr.io/teknoir/"])
        self.assertEqual(plat, ["ghcr.io/teknoir/backstage-app:robot (teknoir-system)"])
        self.assertEqual(user, ["ghcr.io/teknoir/jwks-server:latest (teknoir-demo)"])

    def test_device_findings(self):
        das = {"metadata": {"name": "d", "namespace": "n"}, "spec": {"applications": [{"revision": "main"}, {"revision": "a" * 40}]}}
        dev = {"metadata": {"name": "dev", "namespace": "n"}, "spec": {"manifest": {"apps": [
            {"kind": "HelmChart", "metadata": {"name": "nb"}, "spec": {"repo": "https://x", "chart": "nb"}},
            {"kind": "HelmChart", "metadata": {"name": "ok"}, "spec": {"repo": "https://x", "chart": "ok", "version": "1.0.0"}}]}}}
        f = ST.device_findings({"DeviceApplicationSet": [das], "Device": [dev]})
        self.assertEqual(len(f), 2)
        self.assertTrue(any("revision 'main'" in x for x in f))
        self.assertTrue(any("HelmChart nb has no version" in x for x in f))


class Main(unittest.TestCase):
    def test_refuses_other_contexts(self):
        self.assertEqual(ST.main(["--context", "teknoir-poc-eks"], sys_=H.FakeSys(H.root_app(target="a" * 40))), 2)

    def test_reads_only(self):
        repo = H.Repo()
        sha = repo.sha("c2")
        root = H.root_app(target="teknoir-cloud", sync_rev=sha)
        fake = H.FakeSys(root)
        real_root = L.repo_root_of
        L.repo_root_of = lambda p: repo.work
        try:
            ST.main(["--no-network", "--branch", "origin/teknoir-cloud"], sys_=fake)
        finally:
            L.repo_root_of = real_root
        self.assertTrue(all(v == "get" for v in fake.verbs()), fake.verbs())


class Scripts(unittest.TestCase):
    def test_every_script_is_executable_and_has_help(self):
        for n in ("staging-release", "staging-status", "pin-image", "check-pins.py", "staging-render.sh"):
            p = os.path.join(H.SCRIPTS, n)
            self.assertTrue(os.access(p, os.X_OK), n)
            r = subprocess.run([p, "--help"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f"{n}: {r.stderr[:200]}")
            self.assertTrue(r.stdout.strip(), n)


if __name__ == "__main__":
    unittest.main()
