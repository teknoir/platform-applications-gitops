"""The pins wiring of charts/app-of-apps, derived from scripts/images.yaml (CI/CD v4 P4.2, plans/cicd/v4/p42-spec.md
sections 1 and 2): every grouped image row is pinned in pins/<group>.yaml and empty in its chart values, and it makes
its chart's child Application list ../../pins/<group>.yaml for project teknoir-cloud; no Application lists valueFiles
for teknoir-online or teknoir-local (those branches have no pins/ directory, and their root render must not change).

PinsLiveInTheGroupFiles reads files only and never skips. PinsWiring renders the root with helm: without helm on PATH
that class skips."""
import os
import shutil
import subprocess
import sys
import unittest

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

ROOT = os.path.dirname(H.SCRIPTS)
AOA = os.path.join(ROOT, "charts", "app-of-apps")
IMAGES = os.path.join(H.SCRIPTS, "images.yaml")
CLOUD, ONLINE, LOCAL = "teknoir-cloud", "teknoir-online", "teknoir-local"
# chart directory -> Application name, where they differ
APP_NAME = {"auth": "auth", "ztna": "ztna"}


def load_images():
    with open(IMAGES) as fh:
        return yaml.safe_load(fh)


def render(project):
    return yaml.safe_load_all(subprocess.run(
        ["helm", "template", "app-of-apps", AOA, "--set", f"project={project}"],
        check=True, capture_output=True, text=True).stdout)


def apps_of(project):
    return {d["metadata"]["name"]: d for d in render(project) if isinstance(d, dict) and d.get("kind") == "Application"}


MISSING = object()


def value_at(path, key_path):
    """The value at a dotted key path in a YAML file, or MISSING."""
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for key in key_path.split("."):
        if not isinstance(doc, dict) or key not in doc:
            return MISSING
        doc = doc[key]
    return doc


class PinsLiveInTheGroupFiles(unittest.TestCase):
    """Lasting guard (plans/cicd/v4/p42-spec.md sections 1-2): every grouped image row is pinned in its group's pins
    file and nowhere else. The chart values keep the key empty, so a chart can never render a stale copy of the pin
    (the templates require the value). Pure files, no helm: this never skips."""

    def test_every_grouped_pin_is_set_in_the_pins_file_and_empty_in_the_chart_values(self):
        for row in load_images()["images"]:
            if not row["group"]:
                continue
            name = row["component"]
            pin = value_at(os.path.join(ROOT, row["pins_file"]), row["key_path"])
            self.assertIsInstance(pin, str, f"{name}: {row['pins_file']} has no {row['key_path']}")
            self.assertTrue(pin.strip(), f"{name}: {row['pins_file']} {row['key_path']} is empty")
            chart = value_at(os.path.join(ROOT, "charts", row["chart"], "values.yaml"), row["key_path"])
            self.assertEqual(chart, "",
                             f"{name}: charts/{row['chart']}/values.yaml {row['key_path']} must stay empty "
                             f"(the pin is in {row['pins_file']})")


class PinsWiring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("helm"):
            raise unittest.SkipTest("helm is not on PATH")
        cls.images = load_images()
        cls.cloud = apps_of(CLOUD)
        cls.online = apps_of(ONLINE)
        cls.local = apps_of(LOCAL)

    def test_every_group_has_a_pins_file(self):
        for group in self.images["groups"]:
            self.assertTrue(os.path.isfile(os.path.join(ROOT, "pins", group + ".yaml")), group)

    def test_every_image_with_a_group_points_at_its_group_pins_file(self):
        for row in self.images["images"]:
            if not row["group"]:
                continue
            self.assertEqual(row["pins_file"], f"pins/{row['group']}.yaml", row["component"])
            self.assertFalse(row.get("values_file"), row["component"])
            app = self.cloud[APP_NAME.get(row["chart"], row["chart"])]
            files = (app["spec"]["source"].get("helm") or {}).get("valueFiles") or []
            self.assertIn(f"../../pins/{row['group']}.yaml", files, f"{row['component']}: {app['metadata']['name']}")
            self.assertEqual(files[0], "values.yaml", f"{row['component']}: values.yaml first")

    def test_every_application_with_value_files_lists_only_pins_files_after_values(self):
        for name, app in self.cloud.items():
            files = (app["spec"]["source"].get("helm") or {}).get("valueFiles") or []
            if not files:
                continue
            self.assertEqual(files[0], "values.yaml", name)
            pins = files[1:]
            self.assertEqual(pins, sorted(pins), f"{name}: pins files alphabetical")
            chart = (app["spec"]["source"] or {}).get("path") or ""
            for f in pins:
                self.assertRegex(f, r"^\.\./\.\./pins/[a-z0-9-]+\.yaml$", name)
                # ArgoCD resolves a value file against the chart in the repository
                self.assertTrue(os.path.isfile(os.path.join(ROOT, chart, f)), f"{name}: {f}")

    def test_the_affected_applications_are_exactly_the_ones_with_a_group(self):
        charts = {row["chart"] for row in self.images["images"] if row["group"]}
        expected = {APP_NAME.get(c, c) for c in charts}
        got = {n for n, a in self.cloud.items() if (a["spec"]["source"].get("helm") or {}).get("valueFiles")}
        self.assertEqual(got, expected)

    def test_no_application_lists_value_files_for_the_other_projects(self):
        for name, app in self.online.items():
            self.assertNotIn("valueFiles", app["spec"]["source"].get("helm") or {}, name)
        # teknoir-local renders the same children (no allowlisted valueFiles either)
        for name, app in self.local.items():
            self.assertNotIn("valueFiles", app["spec"]["source"].get("helm") or {}, name)

    def test_a_helm_block_is_never_empty(self):
        for project in (CLOUD, ONLINE, LOCAL):
            for name, app in apps_of(project).items():
                if "helm" in app["spec"]["source"]:
                    self.assertTrue(app["spec"]["source"]["helm"], f"{project}/{name}")

    def test_the_parameters_the_pins_change_left_alone_are_kept(self):
        # backstage and device-controller already emitted helm.parameters conditionally; restructuring the helm block
        # keeps them identical (the byte-identical test_pins_render.py proves it against the base ref)
        cloud = self.cloud
        names = lambda app: [p["name"] for p in (app["spec"]["source"].get("helm") or {}).get("parameters") or []]
        self.assertEqual(names(cloud["backstage"])[0], "fleet.prometheusUrlTemplate")
        self.assertIn("ztna.enabled", names(cloud["backstage"]))
        self.assertEqual(names(cloud["device-controller"]), ["ztna.enabled", "ztna.defaultOn", "teknoirbotApi.enabled"])

    def test_no_pins_path_reaches_the_other_projects(self):
        for project in (ONLINE, LOCAL):
            text = subprocess.run(["helm", "template", "app-of-apps", AOA, "--set", f"project={project}"],
                                  check=True, capture_output=True, text=True).stdout
            self.assertNotIn("pins/", text, project)


if __name__ == "__main__":
    unittest.main()
