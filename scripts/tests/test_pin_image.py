import json
import os
import shutil
import sys
import unittest

import yaml

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


LIST_VALUES = '''# top comment
template:
  spec:
    containers:
      # ARC requires the runner container to be named "runner"
      - name: runner
        # pinned below
        image: ghcr.io/teknoir/ci-runner:2.338.2-3@sha256:''' + "e" * 64 + '''
        imagePullPolicy: IfNotPresent
      - name: sidecar
        image: docker.io/library/postgres:16-alpine
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

    def test_the_real_arc_scale_set_values_keep_the_indexed_shape(self):
        # Kargo's pin-ci-runner and scripts/pin-image rewrite these three files at an indexed key. _find_path only
        # reads a list indented under its key whose pinned key is not on the item's `- ` line, so a reformat into
        # any other shape fails here as well as in pin-image; the values must also match PyYAML's own reading.
        root = os.path.dirname(H.SCRIPTS)
        for name in ("teknoir-ci", "teknoir-land", "teknoir-push"):
            rel = os.path.join("charts", "ci-runners", "arc", name + ".yaml")
            with open(os.path.join(root, rel)) as fh:
                text = fh.read()
            doc = yaml.safe_load(text)
            self.assertEqual(PI.get_leaf(text, "template.spec.containers.0.image"),
                             doc["template"]["spec"]["containers"][0]["image"], rel)

    def test_a_digit_segment_indexes_a_list(self):
        key = "template.spec.containers.0.image"
        self.assertEqual(PI.get_leaf(LIST_VALUES, key), "ghcr.io/teknoir/ci-runner:2.338.2-3@sha256:" + "e" * 64)
        out = PI.set_leaf(LIST_VALUES, key, "ghcr.io/teknoir/ci-runner:sha-abcdef12@" + D)
        self.assertIn('image: "ghcr.io/teknoir/ci-runner:sha-abcdef12@' + D + '"', out)
        self.assertIn("        # pinned below", out)
        self.assertEqual(PI.get_leaf(out, "template.spec.containers.1.image"), "docker.io/library/postgres:16-alpine")
        self.assertEqual(len(out.split("\n")), len(LIST_VALUES.split("\n")))

    def test_a_missing_list_item_is_never_created(self):
        with self.assertRaises(ValueError):
            PI.set_leaf(LIST_VALUES, "template.spec.containers.2.image", "x")
        self.assertIsNone(PI.get_leaf(LIST_VALUES, "template.spec.containers.2.image"))

    def test_real_values_files_round_trip_for_every_component(self):
        root = os.path.dirname(H.SCRIPTS)
        images = PI.parse_images_yaml(open(os.path.join(H.SCRIPTS, "images.yaml")).read())
        for name, c in images.items():
            text = open(os.path.join(root, PI.image_path(c))).read()
            old = PI.get_leaf(text, c["key_path"])
            self.assertIsNotNone(old, f"{name}: {PI.image_path(c)} has no value at {c['key_path']}")
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

    def test_images_yaml(self):
        imgs = PI.parse_images_yaml(open(os.path.join(H.SCRIPTS, "images.yaml")).read())
        for must in ("backstage-app", "backstage-api", "devstudio-controller", "user-controller",
                     "notebook-controller", "keycloak-theme", "device-controller", "profile-controller", "postgres"):
            self.assertIn(must, imgs)
        for c in imgs.values():
            self.assertTrue(c["key_path"] and c["repository"] and c["chart"])
            if c["group"]:
                if c.get("values_files"):                                       # a grouped row pinned in chart values
                    self.assertIsNone(c["pins_file"], c)
                    for f in PI.image_paths(c):
                        self.assertTrue(f.startswith("charts/"), c)
                else:
                    self.assertTrue(PI.image_path(c).startswith("pins/"), c)    # a grouped row pins in pins/<group>.yaml
                self.assertFalse(c.get("values_file"), c)
            else:
                self.assertTrue(PI.image_path(c).startswith("charts/"), c)      # a third party row pins in its chart values
                self.assertIsNone(c["pins_file"])


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
        # Self-contained fixtures (unpinned on purpose): the real pins files get pinned by releases. A grouped
        # component is pinned in the group's pins file, a third party one in its chart values file.
        fixtures = {
            "pins/devstudio-controller.yaml":
                "# fixture\nimage:\n  tag: \"teknoir-cloud\"\n",
            "charts/ztna/values.yaml":
                "# fixture\nhub:\n  image:\n    repository: ghcr.io/teknoir/wg-hub\n    leaderElection: true\n    pullPolicy: IfNotPresent\n",
            "pins/wg-tunnel.yaml":
                "# fixture\nhub:\n  image:\n    tag: \"sha-9c9bdae@sha256:" + "c" * 64 + "\"\n"
                "    # confirmation\n",
            "pins/backstage.yaml":
                "# fixture\nbackstage:\n  image: harbor.teknoir.cloud/teknoir/backstage-app:robot\nbackstageApi:\n  image: harbor.teknoir.cloud/teknoir/backstage:robot\n",
            "pins/teknoir-desktop.yaml":
                "# fixture\ndesktop:\n  agent:\n    image: \"ghcr.io/teknoir/teknoir-desktop:sha-ca46a99c-council@" + D + "\"\n",
            # digest style: the pin holds only the digest; its sibling tag stays in the chart values
            "pins/keycloak-theme.yaml":
                "# fixture\nkeycloak:\n  image:\n    digest: \"\"\n",
            "charts/auth/values.yaml":
                "# fixture\nkeycloak:\n  image:\n    repository: ghcr.io/teknoir/keycloak-theme\n    tag: \"latest\"\n    digest: \"\"\n",
        }
        for f, text in fixtures.items():
            os.makedirs(os.path.dirname(os.path.join(self.root, f)), exist_ok=True)
            with open(os.path.join(self.root, f), "w") as fh:
                fh.write(text)
        # ci-runner is pinned in the three ARC scale-set values files (values_files in scripts/images.yaml): the
        # copies carry the real shape (a list item under template.spec.containers) with its comment line.
        arc = os.path.join(os.path.dirname(H.SCRIPTS), "charts", "ci-runners", "arc")
        self.arc_files = [f"charts/ci-runners/arc/{name}.yaml" for name in ("teknoir-ci", "teknoir-land", "teknoir-push")]
        for rel in self.arc_files:
            with open(os.path.join(arc, os.path.basename(rel))) as fh:
                self.write(rel, fh.read())
        self.out = []

    def write(self, rel, text):
        os.makedirs(os.path.dirname(os.path.join(self.root, rel)), exist_ok=True)
        with open(os.path.join(self.root, rel), "w") as fh:
            fh.write(text)

    def read(self, rel):
        with open(os.path.join(self.root, rel)) as fh:
            return fh.read()

    ARC_KEY = "template.spec.containers.0.image"

    def pin(self, sys_):
        return PI.Pin(sys_, self.root, out=self.out.append)

    def test_pin_dry_run_prints_and_does_not_write(self):
        before = open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read()
        res = self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud", write=False)
        self.assertEqual(res["new"], "teknoir-cloud@" + D)
        self.assertEqual(open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read(), before)
        self.assertEqual(res["file"], "pins/devstudio-controller.yaml")
        self.assertTrue(any("source commit " + "f" * 40 in l for l in self.out))

    def test_pin_write(self):
        self.pin(FakeSys()).pin("devstudio-controller", "teknoir-cloud", write=True)
        text = open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read()
        self.assertEqual(PI.get_leaf(text, "image.tag"), "teknoir-cloud@" + D)

    def test_ref_style_keeps_the_repository_in_the_value(self):
        res = self.pin(FakeSys()).pin("backstage-app", "harbor.teknoir.cloud/teknoir/backstage-app:robot", write=True)
        self.assertEqual(res["new"], "harbor.teknoir.cloud/teknoir/backstage-app:robot@" + D)

    def _device_controller(self):
        return open(os.path.join(self.root, "pins/teknoir-desktop.yaml")).read()

    def test_a_values_files_row_pins_every_file(self):
        res = self.pin(FakeSys()).pin("ci-runner", "sha-abcdef12", write=True)
        want = "ghcr.io/teknoir/ci-runner:sha-abcdef12@" + D
        self.assertEqual(res["new"], want)
        self.assertEqual(res["files"], self.arc_files)
        for rel in self.arc_files:
            text = self.read(rel)
            self.assertEqual(PI.get_leaf(text, self.ARC_KEY), want, rel)
            # the comment block above the pinned line and the neighbouring keys stay as written
            self.assertIn("Pinned by Kargo Stage pin-ci-runner", text)
            self.assertIn("imagePullPolicy: IfNotPresent", text)

    def test_a_values_files_row_keeps_the_index_paths_comments_and_line_count(self):
        before = {rel: self.read(rel) for rel in self.arc_files}
        self.pin(FakeSys()).pin("ci-runner", "sha-abcdef12", write=True)
        for rel in self.arc_files:
            self.assertEqual(len(self.read(rel).split("\n")), len(before[rel].split("\n")), rel)
            # the files are copies of the real ones, whose pin Kargo rewrites: take the old line from the copy
            old = [l for l in before[rel].split("\n") if l.lstrip().startswith("image: ghcr.io/teknoir/ci-runner:")]
            self.assertEqual(len(old), 1, rel)
            self.assertEqual(self.read(rel).replace(
                '        image: "ghcr.io/teknoir/ci-runner:sha-abcdef12@' + D + '"', old[0]), before[rel], rel)

    def test_a_missing_key_is_an_error_naming_the_file_and_writes_nothing(self):
        broken = self.arc_files[1]
        text = self.read(broken).replace("        image: ghcr.io/teknoir/ci-runner",
                                         "        notimage: ghcr.io/teknoir/ci-runner", 1)
        self.write(broken, text)
        before = {rel: self.read(rel) for rel in self.arc_files}
        with self.assertRaises(SystemExit) as cm:
            self.pin(FakeSys()).pin("ci-runner", "sha-abcdef12", write=True)
        self.assertIn(broken, str(cm.exception))
        self.assertIn(self.ARC_KEY, str(cm.exception))
        for rel in self.arc_files:
            self.assertEqual(self.read(rel), before[rel], rel)

    def test_a_grouped_row_without_the_key_adds_it_under_the_existing_parent(self):
        # Only a values_files row requires the key. A grouped pins file (and a third party chart values file) keeps
        # set_leaf's behaviour: the missing leaf is added under its existing parent.
        rel = "pins/devstudio-controller.yaml"
        self.write(rel, "# fixture\nimage:\n  pullPolicy: Always\n")
        res = self.pin(FakeSys()).pin("devstudio-controller", "sha-abcdef12", write=True)
        self.assertEqual(res["new"], "sha-abcdef12@" + D)
        text = self.read(rel)
        self.assertIn('  tag: "sha-abcdef12@' + D + '"', text)
        self.assertEqual(PI.get_leaf(text, "image.tag"), "sha-abcdef12@" + D)
        self.assertEqual(PI.get_leaf(text, "image.pullPolicy"), "Always")

    RUNNER_REF = "ghcr.io/teknoir/ci-runner:2.338.2-3"

    def _write_arc(self, rel, ref):
        self.write(rel, "template:\n  spec:\n    containers:\n      - name: runner\n        image: " + ref + "\n")

    def test_adopt_running_writes_every_values_file_that_agrees(self):
        for rel in self.arc_files:
            self._write_arc(rel, self.RUNNER_REF)
        want = self.RUNNER_REF + "@sha256:" + "c" * 64
        running = {self.RUNNER_REF: want}
        res = {r["name"]: r for r in self.pin(FakeSys(running=running)).adopt_running(write=True, context="r415")}
        self.assertEqual(res["ci-runner"]["value"], want)
        for rel in self.arc_files:
            self.assertEqual(PI.get_leaf(self.read(rel), self.ARC_KEY), want, rel)

    def test_adopt_running_skips_values_files_that_disagree(self):
        # file 0 differs from files 1 and 2: nothing is written for the row, one line per file prints its value
        other = "ghcr.io/teknoir/ci-runner:sha-aaaaaaaa"
        self._write_arc(self.arc_files[0], other)
        for rel in self.arc_files[1:]:
            self._write_arc(rel, self.RUNNER_REF)
        before = {rel: self.read(rel) for rel in self.arc_files}
        running = {other: "ghcr.io/teknoir/ci-runner@sha256:" + "c" * 64}
        pin = self.pin(FakeSys(running=running))
        res = {r["name"]: r for r in pin.adopt_running(write=True, context="r415")}
        self.assertEqual(res["ci-runner"]["status"], "disagree")
        self.assertIn("ci-runner: values_files disagree; pin by hand", self.out)
        for rel in self.arc_files:
            self.assertIn(f"ci-runner: {self.ARC_KEY} is {PI.get_leaf(before[rel], self.ARC_KEY)} in {rel}", self.out)
            self.assertEqual(self.read(rel), before[rel], rel)

    def test_council_sub_image_pins_by_tag(self):
        # the council image is the sub-image ghcr.io/teknoir/teknoir-desktop/council: a bare tag resolves to it
        res = self.pin(FakeSys()).pin("teknoir-desktop-agent", "sha-9df98cbf", write=True)
        want = "ghcr.io/teknoir/teknoir-desktop/council:sha-9df98cbf@" + D
        self.assertEqual(res["new"], want)
        self.assertEqual(PI.get_leaf(self._device_controller(), "desktop.agent.image"), want)

    def test_council_sub_image_pins_by_full_ref(self):
        res = self.pin(FakeSys()).pin("teknoir-desktop-agent", "ghcr.io/teknoir/teknoir-desktop/council:sha-9df98cbf", write=True)
        want = "ghcr.io/teknoir/teknoir-desktop/council:sha-9df98cbf@" + D
        self.assertEqual(res["new"], want)
        self.assertEqual(PI.get_leaf(self._device_controller(), "desktop.agent.image"), want)

    def test_council_refuses_the_old_repository(self):
        # the local-ci tag ghcr.io/teknoir/teknoir-desktop:sha-<8>-council is retired
        with self.assertRaises(SystemExit):
            self.pin(FakeSys()).pin("teknoir-desktop-agent", "ghcr.io/teknoir/teknoir-desktop:sha-9df98cbf-council", write=True)

    def _ztna_pins(self):
        return open(os.path.join(self.root, "pins/wg-tunnel.yaml")).read()

    def test_wg_hub_repin_leaves_the_leader_election_flag_unchanged(self):
        # every wg-tunnel main build has leader election: a re-pin only changes the tag in the pins file, and
        # hub.image.leaderElection stays in charts/ztna/values.yaml untouched
        self.pin(FakeSys()).pin("wg-hub", "sha-1234567", write=True)
        text = self._ztna_pins()
        self.assertEqual(PI.get_leaf(text, "hub.image.tag"), "sha-1234567@" + D)
        self.assertIn("    # confirmation", text)
        values = open(os.path.join(self.root, "charts/ztna/values.yaml")).read()
        self.assertEqual(PI.get_leaf(values, "hub.image.leaderElection"), "true")
        self.assertEqual(PI.get_leaf(values, "hub.image.pullPolicy"), "IfNotPresent")

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
        running = {"harbor.teknoir.cloud/teknoir/devstudio-controller:teknoir-cloud": "harbor.teknoir.cloud/teknoir/devstudio-controller@sha256:" + "c" * 64,
                   "harbor.teknoir.cloud/teknoir/backstage-app:robot": "harbor.teknoir.cloud/teknoir/backstage-app@sha256:" + "d" * 64}
        sys_ = FakeSys(digest="sha256:" + "e" * 64, running=running)         # the tag moved: crane says e..., the pod runs c...
        res = {r["name"]: r for r in self.pin(sys_).adopt_running(write=True, context="r415")}
        self.assertEqual(res["devstudio-controller"]["value"], "teknoir-cloud@sha256:" + "c" * 64)
        self.assertTrue(res["devstudio-controller"]["moved"])
        self.assertEqual(res["backstage-app"]["value"], "harbor.teknoir.cloud/teknoir/backstage-app:robot@sha256:" + "d" * 64)
        text = open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read()
        self.assertEqual(PI.get_leaf(text, "image.tag"), "teknoir-cloud@sha256:" + "c" * 64)

    def test_adopt_running_never_writes_without_the_flag_and_never_retags(self):
        before = open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read()
        sys_ = FakeSys(running={"harbor.teknoir.cloud/teknoir/devstudio-controller:teknoir-cloud": "harbor.teknoir.cloud/teknoir/devstudio-controller@sha256:" + "c" * 64})
        self.pin(sys_).adopt_running(write=False, context="r415")
        self.assertEqual(open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read(), before)
        for call in sys_.calls:
            self.assertNotIn(call[1] if call[0] == "crane" else "", ("copy", "tag", "push", "delete", "cp"))
            if call[0] == "kubectl":
                self.assertIn("get", call)

    def test_adopt_running_accepts_r415_and_sets_its_context(self):
        sys_ = FakeSys(running={"harbor.teknoir.cloud/teknoir/devstudio-controller:teknoir-cloud": "harbor.teknoir.cloud/teknoir/devstudio-controller@sha256:" + "c" * 64})
        res = {r["name"]: r for r in self.pin(sys_).adopt_running(write=False, context="r415")}
        self.assertEqual(res["devstudio-controller"]["value"], "teknoir-cloud@sha256:" + "c" * 64)
        kube = [c for c in sys_.calls if c[0] == "kubectl"]
        self.assertTrue(kube)
        for c in kube:
            self.assertEqual(c[1:3], ["--context", "r415"], c)

    def test_adopt_running_refuses_other_contexts(self):
        with self.assertRaises(L.Refuse):
            self.pin(FakeSys()).adopt_running(write=False, context="teknoir-poc-eks")

    def test_digest_style_writes_only_the_digest_and_keeps_the_tag(self):
        self.assertEqual(PI.build_value("digest", "ghcr.io/teknoir/keycloak-theme", "latest", D), D)
        self.assertEqual(PI.sibling_tag_path("keycloak.image.digest"), "keycloak.image.tag")
        self.assertEqual(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", None, "latest"), "ghcr.io/teknoir/keycloak-theme:latest")
        self.assertEqual(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", D, "latest"), "ghcr.io/teknoir/keycloak-theme:latest@" + D)
        self.assertIsNone(PI.current_ref("digest", "ghcr.io/teknoir/keycloak-theme", D, None))

    def test_adopt_running_digest_style_reads_the_sibling_tag_from_the_chart_values(self):
        # keycloak.image.tag does not live in pins/keycloak-theme.yaml: without reading it from the chart values
        # the row has no ref and is skipped as "not set"
        running = {"ghcr.io/teknoir/keycloak-theme:latest": "ghcr.io/teknoir/keycloak-theme@sha256:" + "c" * 64}
        sys_ = FakeSys(digest="sha256:" + "e" * 64, running=running)          # the tag moved: the running digest is kept
        res = {r["name"]: r for r in self.pin(sys_).adopt_running(write=True, context="r415")}
        self.assertEqual(res["keycloak-theme"]["value"], "sha256:" + "c" * 64)
        self.assertTrue(res["keycloak-theme"]["moved"])
        pins = open(os.path.join(self.root, "pins/keycloak-theme.yaml")).read()
        self.assertEqual(PI.get_leaf(pins, "keycloak.image.digest"), "sha256:" + "c" * 64)
        self.assertIsNone(PI.get_leaf(pins, "keycloak.image.tag"))            # the sibling tag is not written to the pins file
        values = open(os.path.join(self.root, "charts/auth/values.yaml")).read()
        self.assertEqual(PI.get_leaf(values, "keycloak.image.tag"), "latest")  # ... and the chart values are untouched

    def pr_base(self, sys_, **kw):
        """The --base of the gh pr create open_pr runs."""
        self.pin(sys_).open_pr({"name": "devstudio-controller", "old": "x", "new": "y@" + D, "revision": "r",
                                "tag": "sha-abc", "file": "pins/devstudio-controller.yaml"}, **kw)
        call = next(c for c in sys_.calls if c[:3] == ["gh", "pr", "create"])
        return call[call.index("--base") + 1]

    def test_open_pr_bases_on_the_gitops_branch_not_a_hard_coded_one(self):
        sys_ = FakeSys()                                   # its git answers "no origin/HEAD": falls back to main
        self.assertEqual(self.pr_base(sys_), "main")

    def test_open_pr_follows_origin_head(self):
        class HeadSys(FakeSys):
            def run(self, argv, **kw):
                if argv[:3] == ["git", "-C", self.root] and argv[3] == "symbolic-ref":
                    return L.Result(0, "origin/teknoir-cloud\n", "")
                if argv[:3] == ["git", "-C", self.root] and argv[3] == "rev-parse":
                    return L.Result(0, "", "")
                return super().run(argv, **kw)

        sys_ = HeadSys()
        sys_.root = self.root
        self.assertEqual(self.pr_base(sys_), "teknoir-cloud")

    def test_open_pr_base_can_be_given(self):
        self.assertEqual(self.pr_base(FakeSys(), base="release/x"), "release/x")

    def test_adopt_skips_what_is_already_pinned(self):
        res = {r["name"]: r for r in self.pin(FakeSys()).adopt_running(write=False, context="r415")}
        self.assertNotIn("device-controller", res)        # file not copied into the fixture
        text = open(os.path.join(self.root, "pins/devstudio-controller.yaml")).read()
        self.assertNotIn("@sha256", text)


if __name__ == "__main__":
    unittest.main()
