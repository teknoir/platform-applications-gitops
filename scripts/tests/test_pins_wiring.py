"""The pins wiring of charts/app-of-apps, derived from scripts/images.yaml (CI/CD v4 P4.2, plans/cicd/v4/p42-spec.md
sections 1 and 2): every grouped image row is pinned in pins/<group>.yaml and empty in its chart values, and it makes
its chart's child Application list ../../pins/<group>.yaml for project teknoir-cloud; a grouped row with values_files
(such as ci-runner) is pinned in those chart values files instead, which the scale-set Applications already list as
their `$values` source. No Application lists valueFiles for teknoir-online or teknoir-local (those branches have no
pins/ directory, and their root render must not change).

PinsLiveInTheGroupFiles reads files only and never skips. PinsWiring renders the root with helm: without helm on PATH
that class skips."""
import os
import re
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


def source(app):
    """The single source of a gitops chart Application. Multi-source Applications (kargo: an
    upstream chart plus a $values ref) have none and never carry pins, which test_multi_source_applications_list_no_pins
    checks."""
    return app["spec"].get("source") or {}


def all_sources(app):
    return ([app["spec"]["source"]] if app["spec"].get("source") else []) + (app["spec"].get("sources") or [])


MISSING = object()


def value_at(path, key_path):
    """The value at a dotted key path in a YAML file, or MISSING. A segment of digits indexes a list."""
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}
    for key in key_path.split("."):
        if isinstance(doc, list) and key.isdigit() and int(key) < len(doc):
            doc = doc[int(key)]
        elif isinstance(doc, dict) and key in doc:
            doc = doc[key]
        else:
            return MISSING
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
            if row.get("values_files"):
                # pinned where it is consumed (the ARC scale-set values): set in every listed file
                for f in row["values_files"]:
                    pin = value_at(os.path.join(ROOT, f), row["key_path"])
                    self.assertIsInstance(pin, str, f"{name}: {f} has no {row['key_path']}")
                    self.assertTrue(pin.strip(), f"{name}: {f} {row['key_path']} is empty")
                continue
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
        by_group = {}
        for row in self.images["images"]:
            if row["group"]:
                by_group.setdefault(row["group"], []).append(row)
        for group in self.images["groups"]:
            # a group whose every image is pinned in chart values files (ci-runner) has no pins/<group>.yaml
            if by_group.get(group) and all(r.get("values_files") for r in by_group[group]):
                continue
            self.assertTrue(os.path.isfile(os.path.join(ROOT, "pins", group + ".yaml")), group)

    def test_every_image_with_a_group_points_at_its_group_pins_files(self):
        ci_runners = open(os.path.join(AOA, "templates", "ci-runners.yaml")).read()
        for row in self.images["images"]:
            if not row["group"]:
                continue
            if row.get("values_files"):
                # the scale-set Applications already list these files as their `$values` source: the template
                # renders one scale-set Application per set of its $scaleSets list over this directory
                for f in row["values_files"]:
                    m = re.match(r"^charts/ci-runners/arc/([a-z0-9-]+)\.yaml$", f)
                    self.assertIsNotNone(m, f"{row['component']}: {f}")
                    self.assertIn("$values/charts/ci-runners/arc/", ci_runners, f"{row['component']}: {f}")
                    self.assertRegex(ci_runners, r"\$scaleSets := list[^\n]*\b%s\b" % re.escape(m.group(1)),
                                     f"{row['component']}: {f}")
                continue
            self.assertEqual(row["pins_file"], f"pins/{row['group']}.yaml", row["component"])
            self.assertFalse(row.get("values_file"), row["component"])
            app = self.cloud[APP_NAME.get(row["chart"], row["chart"])]
            files = (source(app).get("helm") or {}).get("valueFiles") or []
            self.assertIn(f"../../pins/{row['group']}.yaml", files, f"{row['component']}: {app['metadata']['name']}")
            self.assertEqual(files[0], "values.yaml", f"{row['component']}: values.yaml first")

    def test_every_application_with_value_files_lists_only_pins_files_after_values(self):
        for name, app in self.cloud.items():
            files = (source(app).get("helm") or {}).get("valueFiles") or []
            if not files:
                continue
            self.assertEqual(files[0], "values.yaml", name)
            pins = files[1:]
            self.assertEqual(pins, sorted(pins), f"{name}: pins files alphabetical")
            chart = source(app).get("path") or ""
            for f in pins:
                self.assertRegex(f, r"^\.\./\.\./pins/[a-z0-9-]+\.yaml$", name)
                # ArgoCD resolves a value file against the chart in the repository
                self.assertTrue(os.path.isfile(os.path.join(ROOT, chart, f)), f"{name}: {f}")

    def test_the_affected_applications_are_exactly_the_ones_with_a_group(self):
        # a values_files row (ci-runner) has no valueFiles Application: the scale sets read it through `$values`
        charts = {row["chart"] for row in self.images["images"] if row["group"] and not row.get("values_files")}
        expected = {APP_NAME.get(c, c) for c in charts}
        got = {n for n, a in self.cloud.items() if (source(a).get("helm") or {}).get("valueFiles")}
        self.assertEqual(got, expected)

    def test_no_application_lists_value_files_for_the_other_projects(self):
        for name, app in self.online.items():
            self.assertNotIn("valueFiles", source(app).get("helm") or {}, name)
        # teknoir-local renders the same children (no allowlisted valueFiles either)
        for name, app in self.local.items():
            self.assertNotIn("valueFiles", source(app).get("helm") or {}, name)

    def test_a_helm_block_is_never_empty(self):
        for project in (CLOUD, ONLINE, LOCAL):
            for name, app in apps_of(project).items():
                for src in all_sources(app):
                    if "helm" in src:
                        self.assertTrue(src["helm"], f"{project}/{name}")

    def test_multi_source_applications_list_no_pins(self):
        for project in (CLOUD, ONLINE, LOCAL):
            for name, app in apps_of(project).items():
                for src in app["spec"].get("sources") or []:
                    for f in (src.get("helm") or {}).get("valueFiles") or []:
                        self.assertNotIn("pins/", f, f"{project}/{name}")

    def test_the_parameters_the_pins_change_left_alone_are_kept(self):
        # backstage and device-controller already emitted helm.parameters conditionally; restructuring the helm block
        # keeps them identical (the byte-identical test_pins_render.py proves it against the base ref)
        cloud = self.cloud
        names = lambda app: [p["name"] for p in (source(app).get("helm") or {}).get("parameters") or []]
        self.assertEqual(names(cloud["backstage"])[0], "fleet.prometheusUrlTemplate")
        self.assertIn("ztna.enabled", names(cloud["backstage"]))
        # retainedConfigRepublish (R0, plans/teknoirbot/root-in-vm.md) comes first and always on teknoir-cloud
        self.assertEqual(names(cloud["device-controller"]),
                         ["retainedConfigRepublish", "ztna.enabled", "ztna.defaultOn", "teknoirbotApi.enabled"])

    def test_no_pins_path_reaches_the_other_projects(self):
        for project in (ONLINE, LOCAL):
            text = subprocess.run(["helm", "template", "app-of-apps", AOA, "--set", f"project={project}"],
                                  check=True, capture_output=True, text=True).stdout
            self.assertNotIn("pins/", text, project)


if __name__ == "__main__":
    unittest.main()
