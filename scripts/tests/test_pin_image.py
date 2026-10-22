import json
import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402
from helpers import L  # noqa: E402

PI = H.load("pin_image", "pin-image")
D = "sha256:" + "a" * 64

VALUES = '''# top comment
image:
  repository: ghcr.io/teknoir/user-controller
  # keep this comment
  tag: teknoir-cloud-20260413-054338   # trailing
  pullPolicy: Always

backstage:
  image: ghcr.io/teknoir/backstage-app:robot
  imagePullPolicy: Always
other:
  image: untouched
backstageNext:
  enabled: true

quoted:
  image:
    tag: "old"
'''


class Yaml(unittest.TestCase):
    def test_get(self):
        self.assertEqual(PI.get_leaf(VALUES, "image.tag"), "teknoir-cloud-20260413-054338")
        self.assertEqual(PI.get_leaf(VALUES, "backstage.image"), "ghcr.io/teknoir/backstage-app:robot")
        self.assertEqual(PI.get_leaf(VALUES, "quoted.image.tag"), "old")
        self.assertIsNone(PI.get_leaf(VALUES, "image.nothing"))
        self.assertIsNone(PI.get_leaf(VALUES, "nothing.image"))

    def test_set_keeps_comments_and_neighbours(self):
        out = PI.set_leaf(VALUES, "image.tag", "teknoir-cloud-20260413-054338@" + D)
        self.assertIn('tag: "teknoir-cloud-20260413-054338@' + D + '"  # trailing', out)
        self.assertIn("  # keep this comment", out)
        self.assertEqual(out.replace(PI.get_leaf(out, "image.tag"), "X").count("\n"), VALUES.count("\n"))
        self.assertEqual(PI.get_leaf(out, "other.image"), "untouched")           # same key name elsewhere is untouched
        self.assertEqual(PI.get_leaf(out, "backstage.image"), "ghcr.io/teknoir/backstage-app:robot")

    def test_set_keeps_quote_style(self):
        out = PI.set_leaf(VALUES, "quoted.image.tag", "t@" + D)
        self.assertIn('tag: "t@' + D + '"', out)

    def test_set_adds_a_missing_key_under_an_existing_parent(self):
        out = PI.set_leaf(VALUES, "backstageNext.appImage", "ghcr.io/teknoir/backstage-app:nextgen@" + D)
        self.assertEqual(PI.get_leaf(out, "backstageNext.appImage"), "ghcr.io/teknoir/backstage-app:nextgen@" + D)
        self.assertEqual(PI.get_leaf(out, "backstageNext.enabled"), "true")
        self.assertIn("quoted:", out)

    def test_set_without_a_parent_fails(self):
        with self.assertRaises(ValueError):
            PI.set_leaf(VALUES, "nope.child.leaf", "x")

    def test_real_values_files_round_trip_for_every_component(self):
        root = os.path.dirname(H.SCRIPTS)
        images = PI.parse_images_tsv(open(os.path.join(H.SCRIPTS, "images.tsv")).read())
        for name, c in images.items():
            text = open(os.path.join(root, c["values_file"])).read()
            old = PI.get_leaf(text, c["key_path"])
            if old is None:
                self.assertIn(name, ("backstage-next-app", "backstage-next-api"))   # keys added by the adoption PR
                continue
            new = PI.set_leaf(text, c["key_path"], old + "-x")
            self.assertEqual(PI.get_leaf(new, c["key_path"]), old + "-x", name)
            self.assertEqual(len(new.split("\n")), len(text.split("\n")), name)
            self.assertEqual(PI.get_leaf(PI.set_leaf(new, c["key_path"], old), c["key_path"]), old, name)


class Refs(unittest.TestCase):
    def test_split(self):
        r = "ghcr.io/teknoir/a"
        self.assertEqual(PI.split_ref("sha-1", r), (r, "sha-1", None))
        self.assertEqual(PI.split_ref(r + ":t", r), (r, "t", None))
        self.assertEqual(PI.split_ref(r + ":t@" + D, r), (r, "t", D))
        self.assertEqual(PI.split_ref("localhost:5000/a:t", "localhost:5000/a"), ("localhost:5000/a", "t", None))
        with self.assertRaises(ValueError):
            PI.split_ref("ghcr.io/teknoir/a", r)

    def test_build(self):
        self.assertEqual(PI.build_value("tag", "r", "t", D), "t@" + D)
        self.assertEqual(PI.build_value("ref", "r", "t", D), "r:t@" + D)

    def test_tsv(self):
        imgs = PI.parse_images_tsv(open(os.path.join(H.SCRIPTS, "images.tsv")).read())
        for must in ("backstage-app", "backstage-api", "devstudio-controller", "user-controller",
                     "notebook-controller", "keycloak-theme", "device-controller", "profile-controller", "postgres"):
            self.assertIn(must, imgs)
        for c in imgs.values():
            self.assertTrue(c["values_file"].startswith("charts/") and c["key_path"] and c["repository"])


class FakeSys(L.Sys):
    def __init__(self, digest=D, platforms=("amd64",), label="f" * 40, running=None):
        self.calls = []
        self.digest, self.platforms, self.label, self.running = digest, platforms, label, running or {}

    def run(self, argv, **kw):
        self.calls.append(argv)
        c = argv[0]
        if c == "crane":
            if argv[1] == "digest":
                return L.Result(0, self.digest + "\n", "")
            if argv[1] == "manifest":
                return L.Result(0, json.dumps({"manifests": [{"platform": {"os": "linux", "architecture": a}} for a in self.platforms]}), "")
            if argv[1] == "config":
                return L.Result(0, json.dumps({"config": {"Labels": {"org.opencontainers.image.revision": self.label}}}), "")
        if c == "kubectl":
            return L.Result(0, json.dumps({"items": [
                {"metadata": {"namespace": "ns", "name": "p"}, "spec": {"containers": [{"name": "c", "image": img}]},
                 "status": {"containerStatuses": [{"name": "c", "imageID": idg}]}} for img, idg in self.running.items()]}), "")
        return L.Result(0, "", "")


class PinFlow(unittest.TestCase):
    def setUp(self):
        self.root = H.tmpdir()
        shutil.copytree(os.path.join(os.path.dirname(H.SCRIPTS), "scripts"), os.path.join(self.root, "scripts"),
                        ignore=shutil.ignore_patterns("tests", "__pycache__"))
        # Self-contained fixtures (unpinned on purpose): the real values files get pinned by releases.
        fixtures = {
            "charts/devstudio-controller/values.yaml":
                "# fixture\nimage:\n  repository: ghcr.io/teknoir/devstudio-controller\n  tag: \"teknoir-cloud\"\n  pullPolicy: Always\n",
            "charts/ztna/values.yaml":
                "# fixture\nhub:\n  image:\n    repository: ghcr.io/teknoir/wg-hub\n    tag: \"sha-9c9bdae@sha256:" + "c" * 64 + "\"\n"
                "    # confirmation\n    leaderElection: true\n    pullPolicy: IfNotPresent\n",
            "charts/backstage/values.yaml":
                "# fixture\nbackstage:\n  image: ghcr.io/teknoir/backstage-app:robot\nbackstageApi:\n  image: ghcr.io/teknoir/backstage:robot\n",
        }
        for f, text in fixtures.items():
            os.makedirs(os.path.dirname(os.path.join(self.root, f)), exist_ok=True)
            with open(os.path.join(self.root, f), "w") as fh:
                fh.write(text)
        self.out = []

    def pin(self, sys_):
        return PI.Pin(sys_, self.root, out=self.out.append)

    def test_pin_dry_run_prints_and_does_not_write(self):
        before = open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read()
        res = self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud", write=False)
        self.assertEqual(res["new"], "teknoir-cloud@" + D)
        self.assertEqual(open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read(), before)
        self.assertTrue(any("source commit " + "f" * 40 in l for l in self.out))

    def test_pin_write(self):
        self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud", write=True)
        text = open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read()
        self.assertEqual(PI.get_leaf(text, "image.tag"), "teknoir-cloud@" + D)

    def test_ref_style_keeps_the_repository_in_the_value(self):
        res = self.pin(FakeSys()).pin("backstage-app", "ghcr.io/teknoir/backstage-app:robot", write=True)
        self.assertEqual(res["new"], "ghcr.io/teknoir/backstage-app:robot@" + D)

    def _ztna(self):
        return open(os.path.join(self.root, "charts/ztna/values.yaml")).read()

    def test_wg_hub_repin_resets_the_leader_election_confirmation(self):
        # a rollback or an unreviewed repin must not leave the flag true: the chart render stops instead
        self.pin(FakeSys()).pin("wg-hub", "sha-1234567", write=True)
        text = self._ztna()
        self.assertEqual(PI.get_leaf(text, "hub.image.tag"), "sha-1234567@" + D)
        self.assertEqual(PI.get_leaf(text, "hub.image.leaderElection"), "false")
        self.assertIn("    # confirmation", text)
        self.assertEqual(PI.get_leaf(text, "hub.image.pullPolicy"), "IfNotPresent")
        self.assertTrue(any("leaderElection: true -> false" in l for l in self.out))

    def test_wg_hub_leader_election_flag_confirms_the_pin(self):
        self.pin(FakeSys()).pin("wg-hub", "sha-1234567", write=True, leader_election=True)
        self.assertEqual(PI.get_leaf(self._ztna(), "hub.image.leaderElection"), "true")

    def test_wg_hub_dry_run_leaves_the_flag_and_says_what_it_would_do(self):
        before = self._ztna()
        self.pin(FakeSys()).pin("wg-hub", "sha-1234567", write=False)
        self.assertEqual(self._ztna(), before)
        self.assertTrue(any("leaderElection: true -> false" in l for l in self.out))

    def test_wg_hub_same_pin_again_keeps_the_confirmation(self):
        self.pin(FakeSys(digest="sha256:" + "c" * 64)).pin("wg-hub", "sha-9c9bdae", write=True)
        self.assertEqual(PI.get_leaf(self._ztna(), "hub.image.leaderElection"), "true")

    def test_leader_election_flag_is_for_wg_hub_only(self):
        with self.assertRaises(SystemExit):
            self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud", write=True, leader_election=True)

    def test_refuses_an_image_without_linux_amd64(self):
        with self.assertRaises(SystemExit):
            self.pin(FakeSys(platforms=("arm64",))).pin("devstudio-controller", "teknoir-cloud", write=True)

    def test_refuses_a_wrong_digest(self):
        with self.assertRaises(SystemExit):
            self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud@sha256:" + "b" * 64, write=True)

    def test_refuses_a_foreign_repository_and_unknown_component(self):
        with self.assertRaises(SystemExit):
            self.pin(FakeSys()).pin("devstudio-controller", "ghcr.io/other/x:t", write=True)
        with self.assertRaises(SystemExit):
            self.pin(FakeSys()).pin("nope", "t", write=True)

    def test_adopt_running_pins_the_running_digest_even_if_the_tag_moved(self):
        running = {"ghcr.io/teknoir/devstudio-controller:teknoir-cloud": "ghcr.io/teknoir/devstudio-controller@sha256:" + "c" * 64,
                   "ghcr.io/teknoir/backstage-app:robot": "ghcr.io/teknoir/backstage-app@sha256:" + "d" * 64}
        sys_ = FakeSys(digest="sha256:" + "e" * 64, running=running)         # the tag moved: crane says e..., the pod runs c...
        res = {r["name"]: r for r in self.pin(sys_).adopt_running(write=True, context="vpro")}
        self.assertEqual(res["devstudio-controller"]["value"], "teknoir-cloud@sha256:" + "c" * 64)
        self.assertTrue(res["devstudio-controller"]["moved"])
        self.assertEqual(res["backstage-app"]["value"], "ghcr.io/teknoir/backstage-app:robot@sha256:" + "d" * 64)
        text = open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read()
        self.assertEqual(PI.get_leaf(text, "image.tag"), "teknoir-cloud@sha256:" + "c" * 64)

    def test_adopt_running_never_writes_without_the_flag_and_never_retags(self):
        before = open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read()
        sys_ = FakeSys(running={"ghcr.io/teknoir/devstudio-controller:teknoir-cloud": "ghcr.io/teknoir/devstudio-controller@sha256:" + "c" * 64})
        self.pin(sys_).adopt_running(write=False, context="vpro")
        self.assertEqual(open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read(), before)
        for call in sys_.calls:
            self.assertNotIn(call[1] if call[0] == "crane" else "", ("copy", "tag", "push", "delete", "cp"))
            if call[0] == "kubectl":
                self.assertIn("get", call)

    def test_adopt_running_refuses_other_contexts(self):
        with self.assertRaises(L.Refuse):
            self.pin(FakeSys()).adopt_running(write=False, context="teknoir-poc-eks")

    def test_digest_style_writes_only_the_digest_and_keeps_the_tag(self):
        self.assertEqual(PI.build_value("digest", "ghcr.io/teknoir/keycloak-theme", "latest", D), D)
        self.assertEqual(PI.sibling_tag_path("keycloak.image.digest"), "keycloak.image.tag")
        self.assertEqual(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", None, "latest"), "ghcr.io/teknoir/keycloak-theme:latest")
        self.assertEqual(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", D, "latest"), "ghcr.io/teknoir/keycloak-theme:latest@" + D)
        self.assertIsNone(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", D, None))

    def test_adopt_skips_what_is_already_pinned(self):
        res = {r["name"]: r for r in self.pin(FakeSys()).adopt_running(write=False, context="vpro")}
        self.assertNotIn("device-controller", res)        # file not copied into the fixture
        text = open(os.path.join(self.root, "charts/devstudio-controller/values.yaml")).read()
        self.assertNotIn("@sha256", text)


if __name__ == "__main__":
    unittest.main()
