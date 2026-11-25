"""scripts/images.yaml and the charts/kargo-config groups block are one image table (CI/CD v4 P4.2,
plans/cicd/v4/p42-spec.md sections 1 and 4).

scripts/images.yaml is the source of truth: every Teknoir-built image, its group, the pins file or chart values
file it is pinned in, the key path, the value style and the repository a Warehouse polls.
charts/kargo-config/values.yaml carries the same groups, in the same order, in the shape the chart renders
({name, enabled, sameCommit, images: [{component, poll, repository, key, style}]}); a group added, removed,
reordered, renamed or re-styled on one side only must fail here.
"""
import os
import unittest

import yaml

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(SCRIPTS)
IMAGES = os.path.join(SCRIPTS, "images.yaml")
VALUES = os.path.join(ROOT, "charts", "kargo-config", "values.yaml")
STYLES = {"ref", "tag", "digest"}


def load(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


def expected_groups(images):
    """The charts/kargo-config groups block derived from scripts/images.yaml."""
    out = []
    for name, g in images["groups"].items():
        rows = []
        for r in images["images"]:
            if r.get("group") != name:
                continue
            row = {"component": r["component"], "poll": r["poll"], "repository": r["repository"],
                   "key": r["key_path"], "style": r["style"]}
            if r.get("values_files"):
                row["files"] = r["values_files"]
            rows.append(row)
        out.append({"name": name, "enabled": g["enabled"], "sameCommit": g["same_commit"], "images": rows})
    return out


class ImagesYaml(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.images = load(IMAGES)
        cls.values = load(VALUES)

    def test_groups_of_kargo_config_equal_images_yaml(self):
        self.assertEqual(self.values["groups"], expected_groups(self.images))

    def test_every_group_has_at_least_one_image(self):
        groups = {g["name"]: [] for g in self.values["groups"]}
        self.assertEqual(sorted(groups), sorted(self.images["groups"]))
        for row in self.images["images"]:
            if row.get("group"):
                self.assertIn(row["group"], groups, row["component"])
                groups[row["group"]].append(row["component"])
        for name, components in groups.items():
            self.assertTrue(components, name)

    def test_every_grouped_image_has_its_group_pins_file(self):
        for row in self.images["images"]:
            if not row.get("group"):
                continue
            if row.get("values_files"):
                # a grouped row whose pin lives in chart values files: no pins file, each file holds the key
                self.assertIsNone(row["pins_file"], row["component"])
                self.assertTrue(row["values_files"], row["component"])
                for f in row["values_files"]:
                    path = os.path.join(ROOT, f)
                    self.assertTrue(os.path.isfile(path), f"{row['component']}: {f}")
                    with open(path) as fh:
                        doc = yaml.safe_load(fh)
                    for key in row["key_path"].split("."):
                        doc = doc[int(key)] if isinstance(doc, list) else (doc or {}).get(key)
                    self.assertIsInstance(doc, str, f"{row['component']}: {f} has no {row['key_path']}")
                self.assertIsNone(row.get("values_file"), row["component"])
                continue
            self.assertEqual(row["pins_file"], f"pins/{row['group']}.yaml", row["component"])
            self.assertTrue(os.path.isfile(os.path.join(ROOT, row["pins_file"])), row["component"])
            self.assertIsNone(row.get("values_file"), row["component"])

    def test_every_third_party_row_pins_into_a_chart_values_file(self):
        third = [r for r in self.images["images"] if not r.get("group")]
        self.assertTrue(third)
        for row in third:
            self.assertIsNone(row["pins_file"], row["component"])
            self.assertTrue(row.get("values_file"), row["component"])
            self.assertTrue(os.path.isfile(os.path.join(ROOT, row["values_file"])), row["component"])
            self.assertIsNone(row["poll"], row["component"])

    def test_every_image_has_a_known_style_and_a_repository(self):
        for row in self.images["images"]:
            self.assertIn(row["style"], STYLES, row["component"])
            self.assertTrue(row["repository"], row["component"])
            self.assertTrue(row["key_path"], row["component"])

    def test_every_grouped_image_polls_a_repository(self):
        for row in self.images["images"]:
            if not row.get("group"):
                continue
            self.assertTrue(row["poll"], row["component"])
            self.assertNotIn(":", row["poll"], row["component"])  # no tag in a Warehouse repoURL

    def test_a_group_is_enabled_only_while_its_poll_matches_its_repository(self):
        """An enabled group polls the repository it pins from: a Harbor digest whose ghcr push failed would
        otherwise pin an image ghcr lacks. Since P6.2 the private groups pin from Harbor too."""
        for g in self.values["groups"]:
            if not g["enabled"]:
                continue
            for img in g["images"]:
                self.assertEqual(img["poll"], img["repository"], f"{g['name']}/{img['component']}")

    def test_same_commit_groups_have_more_than_one_image(self):
        for g in self.values["groups"]:
            if g["sameCommit"]:
                self.assertGreater(len(g["images"]), 1, g["name"])


if __name__ == "__main__":
    unittest.main()
