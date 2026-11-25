"""charts/kargo-config rendered, against the vendored Kargo 1.12.6 step schemas (CI/CD v4 P4.2,
plans/cicd/v4/p42-spec.md section 4).

Every Stage step's `config` is validated against scripts/tests/fixtures/kargo-1.12.6-schemas/<uses>-config.json,
and every Warehouse subscription against the documented key allowlist, so a Kargo field that does not exist in
1.12.6 fails here instead of at the webhook. Kargo expressions are opaque strings to the schemas: a value that is
one `${{ ... }}` expression satisfies any type (Kargo evaluates it into the typed value before it uses it), which
is why the validators below treat expressions as wildcards.

Uses jsonschema when it is importable, else a minimal check (types, required, additionalProperties, enum,
minLength/minItems, oneOf) written here. Needs helm on PATH; without it the class skips.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml

try:
    import jsonschema
except ImportError:  # pragma: no cover - depends on the machine
    jsonschema = None

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CHART = os.path.join(ROOT, "charts", "kargo-config")
SCHEMAS = os.path.join(HERE, "fixtures", "kargo-1.12.6-schemas")
REPO = "https://github.com/teknoir/platform-applications-gitops.git"

# Warehouse subscriptions: the keys Kargo 1.12.6 documents (plans/cicd/v4/ground-kargo.md 2 and 4).
IMAGE_KEYS = {"repoURL", "imageSelectionStrategy", "allowTagsRegexes", "ignoreTagsRegexes", "discoveryLimit",
              "cacheByTag", "constraint", "platform", "strictSemvers"}
GIT_KEYS = {"repoURL", "branch", "commitSelectionStrategy", "discoveryLimit", "includePaths", "excludePaths"}

EXPR = re.compile(r"^\$?\{\{.*\}\}$", re.S)
TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def is_expression(value):
    return isinstance(value, str) and EXPR.match(value.strip()) is not None


# ----------------------------------------------------------------------------- minimal schema check (fallback)
def minimal_check(schema, value, path, root=None):
    """Problems of `value` against `schema`; enough of JSON Schema for the vendored Kargo step schemas."""
    root = root if root is not None else schema
    problems = []
    if "$ref" in schema:
        ref = schema["$ref"]
        if not ref.startswith("#/"):
            return problems  # only external ref (the unused selector) — never reached
        target = root
        for part in ref[2:].split("/"):
            target = target[part]
        return minimal_check(target, value, path, root)
    if "type" in schema and not is_expression(value):
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(TYPES.get(t, lambda v: True)(value) for t in types):
            return [f"{path}: {value!r} is not of type {schema['type']}"]
    if "enum" in schema and not any(value == e for e in schema["enum"]):
        problems.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append(f"{path}: missing required key {key}")
        props = schema.get("properties") or {}
        if schema.get("additionalProperties") is False:
            problems += [f"{path}: unexpected key {k}" for k in value if k not in props]
        for key, child in value.items():
            if key in props:
                problems += minimal_check(props[key], child, f"{path}.{key}", root)
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            problems.append(f"{path}: fewer than {schema['minProperties']} keys")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            problems.append(f"{path}: fewer than {schema['minItems']} items")
        if isinstance(schema.get("items"), dict):
            for i, child in enumerate(value):
                problems += minimal_check(schema["items"], child, f"{path}[{i}]", root)
    if "minLength" in schema and isinstance(value, str) and not is_expression(value) \
            and len(value) < schema["minLength"]:
        problems.append(f"{path}: shorter than {schema['minLength']}")
    if "oneOf" in schema:
        hits = sum(1 for branch in schema["oneOf"] if not minimal_check(branch, value, path, root))
        if hits != 1:
            problems.append(f"{path}: {hits} of the oneOf branches match (want exactly 1)")
    return problems


if jsonschema is not None:
    # A `${{ ... }}` string is a Kargo expression: Kargo evaluates it into the typed value, so one written where
    # the schema asks for an integer or a number (git-merge-pr prNumber is the only one) is not a schema
    # violation. The integer/number predicates and the numeric bounds are widened for exactly that; enum,
    # required, additionalProperties and oneOf still apply.
    _TYPE_CHECKER = jsonschema.Draft202012Validator.TYPE_CHECKER
    _CHECKER = _TYPE_CHECKER.redefine_many({
        name: (lambda name: lambda checker, instance: is_expression(instance)
               or _TYPE_CHECKER.is_type(instance, name))(name)
        for name in ("integer", "number")
    })

    def _minimum(validator, limit, instance, schema):
        if is_expression(instance) or not validator.is_type(instance, "number"):
            return
        if instance < limit:
            yield jsonschema.ValidationError(f"{instance!r} is less than the minimum of {limit}")

    def _maximum(validator, limit, instance, schema):
        if is_expression(instance) or not validator.is_type(instance, "number"):
            return
        if instance > limit:
            yield jsonschema.ValidationError(f"{instance!r} is greater than the maximum of {limit}")

    _VALIDATOR = jsonschema.validators.extend(jsonschema.Draft202012Validator, type_checker=_CHECKER,
                                              validators={"minimum": _minimum, "maximum": _maximum})

    def schema_problems(config, schema):
        return [e.message for e in _VALIDATOR(schema).iter_errors(config)]
else:  # pragma: no cover - depends on the machine
    def schema_problems(config, schema):
        return minimal_check(schema, config, "config")


# ----------------------------------------------------------------------------- render
def enabled_values(path):
    """charts/kargo-config/values.yaml with every group enabled, gitopsMain on and the release parameter set:
    the whole chart renders, so every Stage and Warehouse is validated."""
    with open(os.path.join(CHART, "values.yaml")) as fh:
        values = yaml.safe_load(fh)
    for group in values["groups"]:
        group["enabled"] = True
    values["warehouses"]["gitopsMain"]["enabled"] = True
    values["staging"]["setReleaseParam"] = True
    values["verification"]["browser"]["image"] = "ghcr.io/teknoir/gitops-verify:sha-0000000a@sha256:" + "1" * 64
    values["verification"]["prometheus"]["address"] = "http://prometheus.teknoir-system.svc.cluster.local:9090"
    with open(path, "w") as fh:
        yaml.safe_dump(values, fh, sort_keys=False)
    return path


def render(values=None):
    cmd = ["helm", "template", "kargo-config", CHART, "--namespace", "platform"]
    if values:
        cmd += ["-f", values]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode:
        raise AssertionError("helm template failed: " + p.stderr[:2000])
    return p.stdout


def documents(text):
    return [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]


class KargoConfig(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("helm"):
            raise unittest.SkipTest("helm is not on PATH")
        cls.tmp = tempfile.mkdtemp(prefix="kargo-config-test.")
        cls.default_text = render()
        cls.full_text = render(enabled_values(os.path.join(cls.tmp, "enabled.yaml")))
        cls.default_docs = documents(cls.default_text)
        cls.full_docs = documents(cls.full_text)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    # -- helpers
    @staticmethod
    def of_kind(docs, kind):
        return [d for d in docs if d.get("kind") == kind]

    def stages(self, docs):
        return {d["metadata"]["name"]: d for d in self.of_kind(docs, "Stage")}

    def warehouses(self, docs):
        return {d["metadata"]["name"]: d for d in self.of_kind(docs, "Warehouse")}

    def groups(self):
        with open(os.path.join(CHART, "values.yaml")) as fh:
            return yaml.safe_load(fh)["groups"]

    # -- Stage steps against the vendored schemas
    def test_every_stage_step_config_matches_the_kargo_1_12_6_schema(self):
        checked = 0
        for docs in (self.default_docs, self.full_docs):
            for stage in self.of_kind(docs, "Stage"):
                for step in stage["spec"]["promotionTemplate"]["spec"]["steps"]:
                    uses = step["uses"]
                    path = os.path.join(SCHEMAS, uses + "-config.json")
                    self.assertTrue(os.path.isfile(path), f"{uses}: no vendored schema")
                    with open(path) as fh:
                        schema = json.load(fh)
                    problems = schema_problems(step["config"], schema)
                    self.assertEqual(problems, [], f"{stage['metadata']['name']}/{uses}: {problems}")
                    checked += 1
        self.assertGreater(checked, 0)

    def test_every_step_alias_has_no_hyphen(self):
        for docs in (self.default_docs, self.full_docs):
            for stage in self.of_kind(docs, "Stage"):
                for step in stage["spec"]["promotionTemplate"]["spec"]["steps"]:
                    if "as" in step:
                        self.assertRegex(step["as"], r"^[a-z][a-z0-9]*$", stage["metadata"]["name"])

    def test_the_pin_steps_skip_push_pr_and_merge_without_a_new_commit(self):
        # git-commit is Skipped (output commit = HEAD) when the Freight is already pinned; the `if` guards on the
        # next three steps then skip them too, and the Promotion succeeds (Kargo counts Skipped as Succeeded).
        expected = {
            3: "${{ success() && status('commit') == 'Succeeded' }}",
            4: "${{ success() && status('push') == 'Succeeded' }}",
            5: "${{ success() && status('openpr') == 'Succeeded' }}",
        }
        checked = 0
        for name, stage in self.stages(self.full_docs).items():
            if not name.startswith("pin-"):
                continue
            steps = stage["spec"]["promotionTemplate"]["spec"]["steps"]
            for i in range(3):
                self.assertNotIn("if", steps[i], name)
            for i, expression in expected.items():
                self.assertEqual(steps[i]["if"], expression, name)
            checked += 1
        self.assertEqual(checked, len(self.groups()))

    # -- Warehouses
    def test_every_warehouse_subscription_uses_documented_keys(self):
        for docs in (self.default_docs, self.full_docs):
            for wh in self.of_kind(docs, "Warehouse"):
                self.assertTrue(wh["spec"]["subscriptions"], wh["metadata"]["name"])
                for sub in wh["spec"]["subscriptions"]:
                    kinds = [k for k in ("image", "git") if k in sub]
                    self.assertEqual(len(kinds), 1, wh["metadata"]["name"])
                    keys = set(sub[kinds[0]])
                    allowed = IMAGE_KEYS if kinds[0] == "image" else GIT_KEYS
                    self.assertEqual(keys - allowed, set(), wh["metadata"]["name"])
                    self.assertIn("repoURL", keys)

    def test_the_defaults_poll_the_branch_and_only_the_enabled_groups(self):
        # values.yaml decides which groups are on; this test never hard-codes one.
        enabled = [g["name"] for g in self.groups() if g["enabled"]]
        warehouses = self.warehouses(self.default_docs)
        self.assertEqual(sorted(warehouses), sorted(["gitops-main"] + ["img-" + n for n in enabled]))
        self.assertEqual(sorted(self.stages(self.default_docs)),
                         sorted(["staging", "staging-verified"] + ["pin-" + n for n in enabled]))

    def test_every_enabled_group_gets_a_warehouse_and_a_pin_stage(self):
        warehouses = self.warehouses(self.full_docs)
        stages = self.stages(self.full_docs)
        self.assertIn("gitops-main", warehouses)
        for group in self.groups():
            self.assertIn("img-" + group["name"], warehouses)
            self.assertIn("pin-" + group["name"], stages)
        self.assertEqual(len(stages), len(self.groups()) + 2)

    def test_a_same_commit_group_only_makes_freight_with_one_tag(self):
        groups = {g["name"]: g for g in self.groups()}
        for name, wh in self.warehouses(self.full_docs).items():
            if not name.startswith("img-"):
                continue
            group = groups[name[len("img-"):]]
            if group["sameCommit"] and len(group["images"]) > 1:
                expression = wh["spec"]["freightCreationCriteria"]["expression"]
                for img in group["images"]:
                    self.assertIn('imageFrom("%s").Tag' % img["poll"], expression, name)

    # -- the pins files get the right value for every style
    def test_pin_values_follow_the_style_of_each_image(self):
        groups = {g["name"]: g for g in self.groups()}
        stages = self.stages(self.full_docs)
        for name, group in groups.items():
            updates = {u["key"]: u["value"] for u in
                       stages["pin-" + name]["spec"]["promotionTemplate"]["spec"]["steps"][1]["config"]["updates"]}
            self.assertEqual(sorted(updates), sorted(i["key"] for i in group["images"]), name)
            for img in group["images"]:
                value = updates[img["key"]]
                if img["style"] == "ref":
                    self.assertTrue(value.startswith(img["repository"] + ":"), f"{name}: {value}")
                    self.assertIn('imageFrom("%s").Tag' % img["poll"], value)
                elif img["style"] == "tag":
                    self.assertEqual(value, '${{ imageFrom("%s").Tag }}@${{ imageFrom("%s").Digest }}'
                                     % (img["poll"], img["poll"]))
                else:
                    self.assertEqual(value, '${{ imageFrom("%s").Digest }}' % img["poll"])

    # -- defaults (P5.2: staging auto-promotes; pins follow values.yaml), and the P4.3 (b) fallback
    def test_auto_promotion_follows_values(self):
        # P5.2 cut-over: a merge to main is a release. Each pin group is on only when
        # values.yaml autoPromotion.pins says so (P6.1 enables one group per reviewed PR).
        config = self.of_kind(self.default_docs, "ProjectConfig")[0]
        policies = config["spec"]["promotionPolicies"]
        self.assertEqual(len(policies), len(self.groups()) + 2)
        with open(os.path.join(CHART, "values.yaml")) as fh:
            auto = yaml.safe_load(fh)["autoPromotion"]
        pins_on = {"pin-" + name for name, on in auto["pins"].items() if on}
        on = {p["stageSelector"]["name"] for p in policies if p["autoPromotionEnabled"] is True}
        self.assertEqual(on, {"staging", "staging-verified"} | pins_on, policies)
        # Every pin policy not switched on in values.yaml is off.
        self.assertEqual({p["stageSelector"]["name"] for p in policies
                          if p["stageSelector"]["name"].startswith("pin-")
                          and p["autoPromotionEnabled"] is not False}, pins_on, policies)
        self.assertEqual({p["stageSelector"]["name"] for p in policies
                          if p["stageSelector"]["name"].startswith("pin-")},
                         {"pin-" + g["name"] for g in self.groups()}, policies)

    def test_the_release_parameter_is_only_set_with_setReleaseParam(self):
        staging = self.stages(self.default_docs)["staging"]
        source = staging["spec"]["promotionTemplate"]["spec"]["steps"][0]["config"]["apps"][0]["sources"][0]
        self.assertNotIn("helm", source)
        staging = self.stages(self.full_docs)["staging"]
        source = staging["spec"]["promotionTemplate"]["spec"]["steps"][0]["config"]["apps"][0]["sources"][0]
        self.assertEqual(source["helm"]["images"][0]["key"], "release")

    def test_the_staging_stage_syncs_the_root_application(self):
        staging = self.stages(self.full_docs)["staging"]
        update = staging["spec"]["promotionTemplate"]["spec"]["steps"][0]
        self.assertEqual(update["uses"], "argocd-update")
        self.assertEqual(update["config"]["apps"][0]["name"], "app-of-apps")
        self.assertEqual(update["config"]["apps"][0]["namespace"], "teknoir-system")
        self.assertEqual(update["retry"], {"timeout": "10m"})
        names = [t["name"] for t in staging["spec"]["verification"]["analysisTemplates"]]
        self.assertEqual(names, ["revision-check", "browser", "prometheus-soak"])

    # -- literals
    def test_kargo_expressions_and_rollouts_placeholders_render_literally(self):
        self.assertIn("${{ ctx.promotion }}", self.full_text)
        self.assertIn('${{ imageFrom("ghcr.io/teknoir/wg-hub").Tag }}', self.full_text)
        self.assertIn("{{args.revision}}", self.full_text)
        self.assertIn('${{ now().UTC().Format("20060102T150405Z") }}', self.full_text)
        # Every `{{` is either a Kargo `${{ ... }}` or an Argo Rollouts `{{args....}}`: no Helm action survived
        # rendering (Helm would otherwise have parsed the expression instead of emitting it).
        self.assertNotRegex(self.full_text, r"(?<!\$)\{\{\s*(?!args\.)")


if __name__ == "__main__":
    unittest.main()
