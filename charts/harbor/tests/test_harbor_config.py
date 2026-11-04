"""Tests of files/harbor-config.py against an in-process fake Harbor and fake Kubernetes API.

Python stdlib only:  python3 -m unittest discover -s charts/harbor/tests -p 'test_*.py'

harbor-config.py runs as a subprocess, as in the cluster, so every test sees what the Job would
log. Covered: idempotency (a second run changes nothing), the upstream credential and its hash,
the guard against public projects on credentialed upstreams, proxy retention with untagged,
the teamspace robot lifecycle, robot Secrets, and that no secret ever reaches the logs.
"""
import base64
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_harbor  # noqa: E402

SCRIPT = os.path.join(HERE, "..", "files", "harbor-config.py")
PROXIES = ["dockerhub", "ghcr", "quay", "k8s", "gcr", "nvcr"]
PULL = [{"project": p, "access": ["repository:pull"]} for p in PROXIES]
DOCKERHUB_TOKEN = "dckr_pat_Zq81kTESTTOKENdockerhub"
GHCR_PAT = "ghp_TESTpatForGhcr0123456789abcdefghij"
NODES_SEED = "SeedPass1234abcdXYZ"
TEAMSPACE_SEED = "TeamspaceSeed1234Ab"
TEAMSPACE_SECRET = ("teknoir-system", "harbor-teamspace-pull")
SEED_ANNOTATION = "teknoir.org/harbor-robot-seed"


def base_config():
    return {
        "configurations": {"project_creation_restriction": "adminonly"},
        "registries": [
            {"name": "dockerhub", "type": "docker-hub", "url": "https://hub.docker.com",
             "credential": {"secret": "harbor-upstream-dockerhub", "format": "basic", "optional": True}},
            {"name": "ghcr", "type": "github-ghcr", "url": "https://ghcr.io",
             "credential": {"secret": "ghcr-token", "format": "dockerconfigjson", "host": "ghcr.io"}},
            {"name": "quay", "type": "docker-registry", "url": "https://quay.io"},
            {"name": "k8s", "type": "docker-registry", "url": "https://registry.k8s.io"},
            {"name": "gcr", "type": "docker-registry", "url": "https://gcr.io"},
            {"name": "nvcr", "type": "docker-registry", "url": "https://nvcr.io"},
        ],
        "projects": [{"name": "teknoir", "public": False, "quotaGiB": 250, "retention": "ci"}] + [
            {"name": p, "proxyRegistry": p, "public": False, "quotaGiB": 30, "retention": "proxy"} for p in PROXIES],
        "retentionPolicies": {
            # as on staging: an `always` rule (no params) next to value rules
            "ci": {"schedule": "0 0 2 * * *",
                   "rules": [{"template": "always", "tags": "{v[0-9]*,main}"},
                             {"template": "latestPushedK", "value": 15},
                             {"template": "nDaysSinceLastPull", "value": 30}]},
            "proxy": {"schedule": "0 30 2 * * *",
                      "rules": [{"template": "nDaysSinceLastPull", "value": 30, "untagged": True}]},
        },
        "gc": {"schedule": "0 0 4 * * 0", "deleteUntagged": False, "workers": 1},
        "auditPurge": {"schedule": "0 30 4 * * 0", "retentionHours": 720,
                       "eventTypes": ["create_artifact", "delete_artifact", "pull_artifact"]},
        "scanAll": {"schedule": "0 0 5 * * 6"},
        "robots": [
            {"name": "ci", "secret": {"namespace": "teknoir-ci", "name": "harbor-ci-robot"},
             "permissions": [{"project": "teknoir", "access": ["repository:push", "repository:pull"]}]},
            {"name": "nodes", "secret": {"namespace": "teknoir-system", "name": "harbor-nodes-pull"},
             "permissions": PULL},
        ],
        "teamspaceRobots": {"enabled": True, "namePrefix": "ts-", "permissions": PULL,
                            "secret": {"namespace": "teknoir-system", "name": "harbor-teamspace-pull"}},
    }


class Harness:
    """A fake Harbor + k8s, a temp dir for /upstream and the service account, and a runner."""

    def __init__(self, test, config=None):
        self.server = fake_harbor.Server()
        self.fake = self.server.__enter__()
        test.addCleanup(self.server.__exit__)
        self.tmp = tempfile.mkdtemp(prefix="harbor-config-test.")
        test.addCleanup(shutil.rmtree, self.tmp, True)
        self.upstream = os.path.join(self.tmp, "upstream")
        self.sa = os.path.join(self.tmp, "sa")
        os.makedirs(self.upstream)
        os.makedirs(self.sa)
        with open(os.path.join(self.sa, "token"), "w") as f:
            f.write(fake_harbor.K8S_TOKEN)
        self.config = config or base_config()
        self.outputs = []
        # teknoir-system as the chart sets it up: harbor-config has no `create` there, the chart
        # renders every Secret it writes as an empty Opaque Secret.
        self.fake.no_create.add("teknoir-system")
        self.render_chart_secrets()

    def render_chart_secrets(self):
        names = [r["secret"] for r in self.config.get("robots", [])]
        t = self.config.get("teamspaceRobots")
        if t and t.get("enabled") is not False:
            names.append(t["secret"])
        for sec in names:
            if sec["namespace"] in self.fake.no_create and (sec["namespace"], sec["name"]) not in self.fake.secrets:
                self.fake.secrets[(sec["namespace"], sec["name"])] = {
                    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
                    "metadata": {"name": sec["name"], "namespace": sec["namespace"], "resourceVersion": "1"}}

    def mark_seed(self, ns, name):
        """Make the Secret an explicit seed (harbor-config adopts its password on create)."""
        obj = self.fake.secrets[(ns, name)]
        obj["metadata"].setdefault("annotations", {})[SEED_ANNOTATION] = "true"

    def write_secret_files(self, registry, files):
        d = os.path.join(self.upstream, registry)
        shutil.rmtree(d, ignore_errors=True)
        if files is None:
            return
        os.makedirs(d)
        for name, content in files.items():
            with open(os.path.join(d, name), "w") as f:
                f.write(content)

    def dockerhub(self, token=DOCKERHUB_TOKEN, user="tekn0ir"):
        self.write_secret_files("dockerhub", None if token is None else {"username": user + "\n", "password": token + "\n"})

    def ghcr(self, pat=GHCR_PAT, user="tekn0ir", style="plain"):
        entry = {"auth": base64.b64encode(f"{user}:{pat}".encode()).decode()}
        if style == "plain":
            entry.update(username=user, password=pat)
        self.write_secret_files("ghcr", None if pat is None else {
            ".dockerconfigjson": json.dumps({"auths": {"ghcr.io": entry}})})

    def run(self, expect_rc=0):
        cfg = os.path.join(self.tmp, "config.json")
        with open(cfg, "w") as f:
            json.dump(self.config, f)
        env = {"PATH": os.environ["PATH"], "HARBOR_URL": self.fake.url, "HARBOR_HOST": "harbor.test.example",
               "HARBOR_ADMIN_PASSWORD": fake_harbor.ADMIN_PASSWORD, "CONFIG": cfg,
               "UPSTREAM_DIR": self.upstream, "K8S_API": self.fake.url, "SA_DIR": self.sa}
        before = len(self.fake.calls)
        p = subprocess.run([sys.executable, "-I", SCRIPT], env=env, capture_output=True, text=True, timeout=120)
        out = p.stdout + p.stderr
        self.outputs.append(out)
        self.last_calls = self.fake.calls[before:]
        self.last_writes = [c for c in self.last_calls if c[0] != "GET"]
        if p.returncode != expect_rc:
            raise AssertionError(f"rc {p.returncode} (wanted {expect_rc}):\n{out}")
        return out

    def all_secret_values(self):
        """Every secret string the fake holds: robot secrets, k8s Secret data, registry credentials."""
        vals = {r["_secret"] for r in self.fake.robots.values()}
        vals |= {r["_sk"] for r in self.fake.registries.values() if r["_sk"]}
        for obj in self.fake.secrets.values():
            for k, v in (obj.get("data") or {}).items():
                if k in ("password", ".dockerconfigjson") or k.endswith(".password"):
                    vals.add(base64.b64decode(v).decode())
        return {v for v in vals if v}


class Base(unittest.TestCase):
    def setUp(self):
        self.h = Harness(self)
        self.fake = self.h.fake
        self.h.ghcr()  # the platform's ghcr-token exists, as on staging

    def assertNoSecretsInLogs(self, h=None, values=()):
        h = h or self.h
        secrets = h.all_secret_values() | set(values) | {
            DOCKERHUB_TOKEN, GHCR_PAT, fake_harbor.ADMIN_PASSWORD, fake_harbor.K8S_TOKEN}
        # a robot password also appears inside the dockerconfigjson blob: compare its parts
        for obj in h.fake.secrets.values():
            for k, v in (obj.get("data") or {}).items():
                if k == ".dockerconfigjson":
                    for e in json.loads(base64.b64decode(v))["auths"].values():
                        secrets |= {e["password"], e["auth"]}
        for out in h.outputs:
            for s in secrets:
                self.assertNotIn(s, out, "a secret reached the log")
                self.assertNotIn(base64.b64encode(s.encode()).decode(), out)


class IdempotencyTest(Base):
    def test_second_run_changes_nothing(self):
        self.h.dockerhub()
        self.h.ghcr()
        self.fake.profiles = ["teknoir-demo", "acme"]
        out = self.h.run()
        self.assertIn("in sync", out)
        self.assertGreater(len(self.h.last_writes), 20)
        out2 = self.h.run()
        self.assertIn("in sync", out2)
        self.assertEqual(self.h.last_writes, [], "the second run wrote something")
        self.assertNoSecretsInLogs()

    def test_first_run_creates_the_six_proxies_with_quota_and_private(self):
        self.h.run()
        for name in PROXIES:
            p = self.fake.project(name)
            self.assertEqual(p["metadata"]["public"], "false", name)
            self.assertEqual(self.fake.quotas[p["project_id"]]["hard"]["storage"], 30 * 1024 ** 3)
            self.assertEqual(p["registry_id"], self.fake.registry(name)["id"])
        for name in ("gcr", "nvcr"):
            self.assertEqual(self.fake.registry(name)["type"], "docker-registry")
        self.assertEqual(self.fake.registry("nvcr")["url"], "https://nvcr.io")

    def test_untagged_proxy_retention_is_created_and_updated(self):
        self.h.run()
        pol = self.fake.retentions[int(self.fake.project("nvcr")["metadata"]["retention_id"])]
        extras = json.loads(pol["rules"][0]["tag_selectors"][0]["extras"])
        self.assertTrue(extras["untagged"])
        # An existing policy without untagged is updated in place.
        rid = int(self.fake.project("quay")["metadata"]["retention_id"])
        sel = self.fake.retentions[rid]["rules"][0]["tag_selectors"][0]
        sel["extras"] = json.dumps({"untagged": False})
        out = self.h.run()
        self.assertIn("project quay: retention 'proxy' updated", out)
        self.assertTrue(json.loads(self.fake.retentions[rid]["rules"][0]["tag_selectors"][0]["extras"])["untagged"])


class RealHarborShapesTest(Base):
    """Harbor returns different shapes than harbor-config sends (read live from v2.14.3 on staging):
    an `always` retention rule has no `params`, `disabled: false` is omitted, GC parameters come back
    as a JSON string without `dry_run`. A converged run must not rewrite any of it."""

    def writes(self, *needles):
        return [c for c in self.h.last_writes if any(n in c[1] for n in needles)]

    def test_two_runs_in_a_row_update_neither_retention_nor_schedules(self):
        self.h.run()
        # The fake keeps what Harbor keeps: the shapes the code compares against are the real ones.
        ci = self.fake.retentions[int(self.fake.project("teknoir")["metadata"]["retention_id"])]
        self.assertNotIn("params", ci["rules"][0])
        self.assertNotIn("disabled", ci["rules"][0])
        self.assertEqual(ci["rules"][1]["params"], {"latestPushedK": 15})
        self.assertIsInstance(self.fake.schedules["gc"]["job_parameters"], str)
        self.assertNotIn("dry_run", json.loads(self.fake.schedules["gc"]["job_parameters"]))
        out = self.h.run()
        self.assertEqual(self.writes("retentions", "schedule"), [])
        self.assertNotIn("updated", out)
        self.assertIn("in sync", out)

    def test_changed_gc_value_still_updates_once(self):
        self.h.run()
        self.fake.schedules["gc"]["job_parameters"] = json.dumps({"delete_untagged": True, "workers": 1})
        out = self.h.run()
        self.assertIn("gc: updated to '0 0 4 * * 0'", out)
        self.assertEqual(json.loads(self.fake.schedules["gc"]["job_parameters"]),
                         {"delete_untagged": False, "workers": 1})
        self.h.run()
        self.assertEqual(self.writes("system/gc"), [])

    def test_changed_gc_cron_and_workers_update(self):
        self.h.run()
        self.fake.schedules["gc"]["schedule"]["cron"] = "0 0 1 * * 1"
        self.assertIn("gc: updated", self.h.run())
        self.fake.schedules["gc"]["job_parameters"] = json.dumps({"delete_untagged": False, "workers": 4})
        self.assertIn("gc: updated", self.h.run())
        self.h.run()
        self.assertEqual(self.writes("system/gc"), [])

    def test_changed_audit_purge_parameter_updates(self):
        self.h.run()
        self.fake.schedules["purgeaudit"]["job_parameters"] = json.dumps(
            {"audit_retention_hour": 24, "dry_run": False, "include_event_types": "create_artifact"})
        self.assertIn("audit purge: updated", self.h.run())
        self.h.run()
        self.assertEqual(self.writes("purgeaudit"), [])

    def test_changed_retention_values_still_update_once(self):
        self.h.run()
        rid = int(self.fake.project("teknoir")["metadata"]["retention_id"])
        self.fake.retentions[rid]["rules"][1]["params"] = {"latestPushedK": 5}
        self.assertIn("project teknoir: retention 'ci' updated", self.h.run())
        self.assertEqual(self.fake.retentions[rid]["rules"][1]["params"], {"latestPushedK": 15})
        self.h.run()
        self.assertEqual(self.writes("retentions"), [])

    def test_changed_always_pattern_cron_and_extras_update(self):
        self.h.run()
        rid = int(self.fake.project("teknoir")["metadata"]["retention_id"])
        self.fake.retentions[rid]["rules"][0]["tag_selectors"][0]["pattern"] = "main"
        self.assertIn("retention 'ci' updated", self.h.run())
        self.fake.retentions[rid]["trigger"]["settings"]["cron"] = "0 0 3 * * *"
        self.assertIn("retention 'ci' updated", self.h.run())
        # a rule that Harbor shows as disabled, or an added/removed rule, is drift too
        self.fake.retentions[rid]["rules"][2]["disabled"] = True
        self.assertIn("retention 'ci' updated", self.h.run())
        del self.fake.retentions[rid]["rules"][2]
        self.assertIn("retention 'ci' updated", self.h.run())
        self.h.run()
        self.assertEqual(self.writes("retentions"), [])

    def test_equivalent_spellings_are_not_drift(self):
        # ints as strings, extras re-serialised without a space, selectors in another key order
        self.h.run()
        rid = int(self.fake.project("teknoir")["metadata"]["retention_id"])
        pol = self.fake.retentions[rid]
        pol["rules"][1]["params"] = {"latestPushedK": "15"}
        pol["rules"][2]["tag_selectors"][0]["extras"] = '{"untagged":false}'
        pol["rules"][2]["tag_selectors"][0] = dict(reversed(list(pol["rules"][2]["tag_selectors"][0].items())))
        self.h.run()
        self.assertEqual(self.writes("retentions"), [])


class UpstreamCredentialTest(Base):
    def dockerhub_calls(self):
        return [c for c in self.h.last_writes if c[1].startswith("/api/v2.0/registries")]

    def test_anonymous_when_the_optional_secret_is_absent(self):
        self.h.dockerhub(None)
        self.h.run()
        reg = self.fake.registry("dockerhub")
        self.assertEqual(reg["_ak"], "")
        self.assertNotIn("credential sha256", reg["description"])
        self.h.run()
        self.assertEqual(self.h.last_writes, [])

    def test_credential_is_sent_once_hashed_and_resent_only_on_change(self):
        self.h.dockerhub()
        self.h.run()
        reg = self.fake.registry("dockerhub")
        self.assertEqual((reg["_ak"], reg["_sk"]), ("tekn0ir", DOCKERHUB_TOKEN))
        self.assertRegex(reg["description"], r" credential sha256:[0-9a-f]{12}$")
        self.assertNotIn(DOCKERHUB_TOKEN, reg["description"])
        first_desc = reg["description"]
        # Unchanged: no registry write at all, so the credential is not sent again.
        self.h.run()
        self.assertEqual(self.dockerhub_calls(), [])
        # Rotated: one PUT with the new credential and a new hash.
        self.h.dockerhub(token="dckr_pat_ROTATEDtokenAAAA")
        out = self.h.run()
        puts = [c for c in self.dockerhub_calls() if c[0] == "PUT"]
        self.assertEqual(len(puts), 1)
        self.assertEqual(puts[0][2]["access_secret"], "dckr_pat_ROTATEDtokenAAAA")
        self.assertEqual(puts[0][2]["credential_type"], "basic")
        self.assertNotEqual(self.fake.registry("dockerhub")["description"], first_desc)
        self.assertIn("registry dockerhub: updated (description, credential set)", out)
        self.h.run()
        self.assertEqual(self.dockerhub_calls(), [])
        self.h.outputs.append("")  # logs of rotation checked below with the new token as well
        for out in self.h.outputs:
            self.assertNotIn("dckr_pat_ROTATEDtokenAAAA", out)
        self.assertNoSecretsInLogs()

    def test_username_change_alone_changes_the_hash(self):
        self.h.dockerhub()
        self.h.run()
        d1 = self.fake.registry("dockerhub")["description"]
        self.h.dockerhub(user="other")
        self.h.run()
        self.assertNotEqual(self.fake.registry("dockerhub")["description"], d1)
        self.assertEqual(self.fake.registry("dockerhub")["_ak"], "other")

    def test_credential_is_removed_when_the_secret_disappears(self):
        self.h.dockerhub()
        self.h.run()
        self.h.dockerhub(None)
        out = self.h.run()
        reg = self.fake.registry("dockerhub")
        self.assertEqual((reg["_ak"], reg["_sk"]), ("", ""))
        self.assertNotIn("credential sha256", reg["description"])
        self.assertIn("credential removed", out)
        self.h.run()
        self.assertEqual(self.h.last_writes, [])

    def test_credential_set_outside_harbor_config_is_removed_from_an_anonymous_upstream(self):
        self.h.run()
        quay = self.fake.registry("quay")
        quay["_ak"], quay["_sk"] = "someone", "by-hand"
        self.h.run()
        self.assertEqual(self.fake.registry("quay")["_ak"], "")

    def test_dockerconfigjson_with_only_the_auth_field(self):
        self.h.ghcr(style="auth-only")
        self.h.run()
        reg = self.fake.registry("ghcr")
        self.assertEqual((reg["_ak"], reg["_sk"]), ("tekn0ir", GHCR_PAT))

    def test_missing_required_credential_is_an_error_without_values(self):
        self.h.ghcr(None)  # ghcr-token is not optional
        out = self.h.run(expect_rc=1)
        self.assertIn("ERROR registry ghcr: credential Secret ghcr-token is missing or incomplete", out)
        self.assertIn("ERROR project ghcr: upstream registry ghcr does not exist; skipped", out)
        self.assertIn("FAILED steps: registry ghcr credential, project ghcr upstream", out)
        # Everything else still reconciled, and no anonymous ghcr registry was created.
        self.assertEqual(self.fake.project("quay")["metadata"]["public"], "false")
        self.assertEqual(self.fake.project("nvcr")["metadata"]["public"], "false")
        self.assertIsNotNone(self.fake.robot("robot$nodes"))
        self.assertNotIn("ghcr", [r["name"] for r in self.fake.registries.values()])

    def test_malformed_credential_secret_is_an_error_without_values(self):
        self.h.write_secret_files("ghcr", {".dockerconfigjson": "{not json" + GHCR_PAT})
        out = self.h.run(expect_rc=1)
        self.assertIn("credential Secret ghcr-token is malformed", out)
        self.assertNotIn(GHCR_PAT, out)

    def test_credential_creation_body_carries_the_credential_only_on_create(self):
        self.h.ghcr()
        self.h.run()
        creates = [c for c in self.h.last_writes if c[0] == "POST" and c[1] == "/api/v2.0/registries"]
        with_cred = [c[2]["name"] for c in creates if c[2].get("credential")]
        self.assertEqual(with_cred, ["ghcr"])


class PublicGuardTest(Base):
    def test_public_project_on_a_credentialed_upstream_is_refused_and_stays_private(self):
        self.h.ghcr()
        for p in self.h.config["projects"]:
            if p["name"] == "ghcr":
                p["public"] = True
        out = self.h.run(expect_rc=1)
        self.assertIn("ERROR project ghcr: refusing public=true", out)
        self.assertEqual(self.fake.project("ghcr")["metadata"]["public"], "false")

    def test_an_already_public_project_is_made_private_again(self):
        self.h.ghcr()
        self.h.run()
        self.fake.project("ghcr")["metadata"]["public"] = "true"  # someone clicked it in the UI
        for p in self.h.config["projects"]:
            if p["name"] == "ghcr":
                p["public"] = True
        self.h.run(expect_rc=1)
        self.assertEqual(self.fake.project("ghcr")["metadata"]["public"], "false")

    def test_declared_but_absent_optional_credential_still_blocks_public(self):
        self.h.dockerhub(None)
        for p in self.h.config["projects"]:
            if p["name"] == "dockerhub":
                p["public"] = True
        self.h.run(expect_rc=1)
        self.assertEqual(self.fake.project("dockerhub")["metadata"]["public"], "false")

    def test_a_credential_found_in_harbor_blocks_public_until_it_is_gone(self):
        self.h.run()
        self.fake.registry("quay")["_ak"] = "by-hand"  # not in the config: removed by this run ...
        for p in self.h.config["projects"]:
            if p["name"] == "quay":
                p["public"] = True
        # ... but the cache may hold private content, so the project is not made public in the same run.
        self.h.run(expect_rc=1)
        self.assertEqual(self.fake.registry("quay")["_ak"], "")
        self.assertEqual(self.fake.project("quay")["metadata"]["public"], "false")
        self.h.run()  # the credential is gone now
        self.assertEqual(self.fake.project("quay")["metadata"]["public"], "true")

    def test_public_project_on_an_anonymous_upstream_is_allowed(self):
        for p in self.h.config["projects"]:
            if p["name"] == "quay":
                p["public"] = True
        self.h.run()
        self.assertEqual(self.fake.project("quay")["metadata"]["public"], "true")


class TeamspaceRobotsTest(Base):
    SEC = ("teknoir-system", "harbor-teamspace-pull")

    def robot_names(self):
        return sorted(r["name"] for r in self.fake.robots.values())

    def test_one_pull_only_never_expiring_robot_per_profile(self):
        self.fake.profiles = ["teknoir-demo", "acme"]
        self.h.run()
        for ns in self.fake.profiles:
            r = self.fake.robot("robot$ts-" + ns)
            self.assertIsNotNone(r)
            self.assertEqual(r["duration"], -1)
            self.assertEqual(r["description"], "managed by harbor-config (teamspace)")
            self.assertEqual({p["namespace"] for p in r["permissions"]}, set(PROXIES))
            for perm in r["permissions"]:
                self.assertEqual(perm["access"], [{"resource": "repository", "action": "pull"}])
            self.assertNotIn("teknoir", {p["namespace"] for p in r["permissions"]})
        data = self.fake.secret_data(*self.SEC)
        self.assertEqual(sorted(data), ["acme.password", "acme.username", "teknoir-demo.password",
                                        "teknoir-demo.username"])
        self.assertEqual(data["acme.username"], "robot$ts-acme")
        self.assertEqual(self.fake.secrets[self.SEC]["type"], "Opaque")
        # the stored credential logs in
        self.assertEqual(self.fake.robot("robot$ts-acme")["_secret"], data["acme.password"])
        self.assertNoSecretsInLogs()

    def test_nodes_robot_and_its_secret(self):
        self.h.run()
        r = self.fake.robot("robot$nodes")
        self.assertEqual({p["namespace"] for p in r["permissions"]}, set(PROXIES))
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.assertEqual(data["username"], "robot$nodes")
        self.assertEqual(data["password"], r["_secret"])
        cfg = json.loads(data[".dockerconfigjson"])
        self.assertEqual(list(cfg["auths"]), ["harbor.test.example"])
        # ci keeps its push right on project teknoir only
        ci = self.fake.robot("robot$ci")
        self.assertEqual([p["namespace"] for p in ci["permissions"]], ["teknoir"])

    def test_new_profile_adds_a_robot_and_leaves_the_others_alone(self):
        self.fake.profiles = ["a"]
        self.h.run()
        pw_a = self.fake.secret_data(*self.SEC)["a.password"]
        self.fake.profiles = ["a", "b"]
        out = self.h.run()
        self.assertIn("robot robot$ts-b: created", out)
        self.assertNotIn("robot$ts-a", out.replace("teamspace robots", ""))
        data = self.fake.secret_data(*self.SEC)
        self.assertEqual(data["a.password"], pw_a)
        self.assertEqual(len([w for w in self.h.last_writes if w[1] == "/api/v2.0/robots"]), 1)

    def test_robot_of_a_deleted_profile_is_deleted_with_its_keys(self):
        self.fake.profiles = ["a", "b"]
        self.h.run()
        self.fake.profiles = ["a"]
        out = self.h.run()
        self.assertIn("robot robot$ts-b: deleted (Profile b is gone)", out)
        self.assertNotIn("robot$ts-b", self.robot_names())
        self.assertEqual(sorted(self.fake.secret_data(*self.SEC)), ["a.password", "a.username"])
        self.h.run()
        self.assertEqual(self.h.last_writes, [])

    def test_a_failed_write_keeps_the_gone_profiles_robot_and_keys(self):
        """The robot is deleted only after the keys left the Secret, so a failed write cannot orphan them."""
        self.fake.profiles = ["a"]
        self.h.run()
        old = self.fake.secret_data(*self.SEC)["a.password"]
        self.fake.profiles = []
        self.fake.fail_secret_put_once.add(self.SEC)
        out = self.h.run(expect_rc=1)
        self.assertIn("ERROR teamspace robots", out)
        # the write failed: keys and robot are still there, and the next run retries both
        self.assertIsNotNone(self.fake.robot("robot$ts-a"))
        self.assertEqual(self.fake.secret_data(*self.SEC)["a.password"], old)
        out2 = self.h.run()
        self.assertIn("robot robot$ts-a: deleted (Profile a is gone)", out2)
        self.assertIsNone(self.fake.robot("robot$ts-a"))
        self.assertEqual(self.fake.secret_data(*self.SEC), {})
        # a Profile re-created under the same name gets a NEW password, not the orphaned one
        self.fake.profiles = ["a"]
        self.h.run()
        data = self.fake.secret_data(*self.SEC)
        self.assertNotEqual(data["a.password"], old)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], data["a.password"])
        # `old` was overwritten above, so name it explicitly
        self.assertNoSecretsInLogs(values=(old,))

    def test_last_profile_gone_removes_its_robot(self):
        self.fake.profiles = ["a"]
        self.h.run()
        self.fake.profiles = []
        self.h.run()
        self.assertNotIn("robot$ts-a", self.robot_names())
        self.assertEqual(self.fake.secret_data(*self.SEC), {})

    def test_keys_without_a_profile_are_kept_until_a_robot_is_deleted(self):
        """harbor-config can run before the Profile exists (fresh cluster, pre-seeded Secret): a
        credential with no Profile and no managed robot must survive."""
        seeded = {"teknoir-demo.username": "robot$ts-teknoir-demo", "teknoir-demo.password": TEAMSPACE_SEED}
        self.fake.set_secret_data(*self.SEC, seeded)
        self.h.mark_seed(*self.SEC)
        out = self.h.run()
        self.assertIsNone(self.fake.robot("robot$ts-teknoir-demo"))
        self.assertEqual(self.fake.secret_data(*self.SEC), seeded)
        self.assertEqual(out.count("teamspace teknoir-demo: no Profile and no managed robot; "
                                   "credential keys kept"), 1)
        # Nothing was written, so the seed annotation is still there (the next write removes it).
        self.assertEqual(self.fake.secrets[self.SEC]["metadata"]["annotations"][SEED_ANNOTATION], "true")
        # The Profile appears: the robot adopts the seeded password.
        self.fake.profiles = ["teknoir-demo"]
        out2 = self.h.run()
        self.assertIn("robot robot$ts-teknoir-demo: created (password adopted from the seeded Secret)", out2)
        self.assertEqual(self.fake.robot("robot$ts-teknoir-demo")["_secret"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.secret_data(*self.SEC), seeded)
        self.assertNoSecretsInLogs()

    def test_robots_not_created_by_harbor_config_are_never_deleted_or_touched(self):
        self.fake.profiles = ["a"]
        self.h.run()
        rid = self.fake.new_id()
        self.fake.robots[rid] = {"id": rid, "name": "robot$ts-by-hand", "level": "system", "duration": -1,
                                 "description": "made in the UI", "permissions": [], "disable": False, "_secret": "x"}
        rid2 = self.fake.new_id()
        self.fake.robots[rid2] = {"id": rid2, "name": "robot$other", "level": "system", "duration": -1,
                                  "description": "managed by harbor-config (teamspace)", "permissions": [],
                                  "disable": False, "_secret": "y"}
        self.h.run()
        self.assertIn("robot$ts-by-hand", self.robot_names())
        self.assertIn("robot$other", self.robot_names())  # not ts- prefixed, so not ours to delete

    def test_profile_list_failure_deletes_nothing_and_fails_the_step(self):
        self.fake.profiles = ["a", "b"]
        self.h.run()
        self.fake.profiles_status = 403
        out = self.h.run(expect_rc=1)
        self.assertIn("ERROR teamspace robots", out)
        self.assertEqual(sorted(self.robot_names()), ["robot$ci", "robot$nodes", "robot$ts-a", "robot$ts-b"])
        self.assertEqual(len(self.fake.secret_data(*self.SEC)), 4)

    def test_deleting_a_key_rotates_that_teamspaces_credential(self):
        self.fake.profiles = ["a", "b"]
        self.h.run()
        data = self.fake.secret_data(*self.SEC)
        old_a, old_b = data["a.password"], data["b.password"]
        del data["a.password"]
        self.fake.set_secret_data(*self.SEC, data)
        out = self.h.run()
        self.assertIn("robot robot$ts-a: secret refreshed (no Secret)", out)
        new = self.fake.secret_data(*self.SEC)
        self.assertNotEqual(new["a.password"], old_a)
        self.assertEqual(new["b.password"], old_b)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], new["a.password"])
        self.assertNoSecretsInLogs()

    def test_a_stale_credential_is_refreshed(self):
        self.fake.profiles = ["a"]
        self.h.run()
        self.fake.robot("robot$ts-a")["_secret"] = "changed-in-harbor-ui"
        out = self.h.run()
        self.assertIn("secret refreshed (stale Secret)", out)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], self.fake.secret_data(*self.SEC)["a.password"])

    def test_emptying_the_secret_rotates_everyone(self):
        self.fake.profiles = ["a", "b"]
        self.h.run()
        self.fake.set_secret_data(*self.SEC, {})
        self.h.run()
        self.assertEqual(self.fake.secrets[self.SEC]["type"], "Opaque")
        data = self.fake.secret_data(*self.SEC)
        self.assertEqual(sorted(data), ["a.password", "a.username", "b.password", "b.username"])
        for ns in "ab":
            self.assertEqual(self.fake.robot(f"robot$ts-{ns}")["_secret"], data[f"{ns}.password"])

    def test_never_creates_a_secret_in_teknoir_system(self):
        """The Role has no `create` there: a missing Secret is an error, never a POST."""
        self.fake.profiles = ["a"]
        del self.fake.secrets[self.SEC]
        out = self.h.run(expect_rc=1)
        self.assertIn("may not create it", out)
        self.assertNotIn(self.SEC, self.fake.secrets)
        # ArgoCD renders it again; the next run fills it
        self.h.render_chart_secrets()
        self.h.run()
        self.assertEqual(sorted(self.fake.secret_data(*self.SEC)), ["a.password", "a.username"])

    def test_writes_keep_argocd_metadata_of_the_rendered_secret(self):
        """A PUT replaces metadata: tracking-id, sync-options and the label must survive every write
        (and rotation), or the harbor app turns OutOfSync."""
        self.fake.profiles = ["a"]
        meta = self.fake.secrets[self.SEC]["metadata"]
        meta["annotations"] = {"argocd.argoproj.io/tracking-id": "harbor:/Secret:teknoir-system/harbor-teamspace-pull",
                               "argocd.argoproj.io/sync-options": "Prune=false,Delete=false",
                               "argocd.argoproj.io/compare-options": "IgnoreExtraneous"}
        meta["labels"] = {"app.kubernetes.io/instance": "harbor", "teknoir.org/managed-by": "harbor-config"}
        self.h.run()
        self.fake.set_secret_data(*self.SEC, {})  # rotate everyone
        self.h.run()
        meta = self.fake.secrets[self.SEC]["metadata"]
        self.assertEqual(meta["annotations"]["argocd.argoproj.io/tracking-id"],
                         "harbor:/Secret:teknoir-system/harbor-teamspace-pull")
        self.assertEqual(meta["annotations"]["argocd.argoproj.io/sync-options"], "Prune=false,Delete=false")
        self.assertEqual(meta["annotations"]["argocd.argoproj.io/compare-options"], "IgnoreExtraneous")
        self.assertEqual(meta["labels"]["app.kubernetes.io/instance"], "harbor")
        self.assertEqual(meta["labels"]["teknoir.org/managed-by"], "harbor-config")
        self.assertEqual(sorted(self.fake.secret_data(*self.SEC)), ["a.password", "a.username"])

    def test_permissions_drift_is_repaired(self):
        self.fake.profiles = ["a"]
        self.h.run()
        r = self.fake.robot("robot$ts-a")
        r["permissions"] = copy.deepcopy(r["permissions"])
        r["permissions"][0]["access"].append({"resource": "repository", "action": "push"})
        out = self.h.run()
        self.assertIn("robot robot$ts-a: permissions updated", out)
        for perm in self.fake.robot("robot$ts-a")["permissions"]:
            self.assertEqual(perm["access"], [{"resource": "repository", "action": "pull"}])

    def test_invalid_profile_name_is_skipped(self):
        self.fake.profiles = ["Bad_Name", "ok"]
        out = self.h.run()
        self.assertIn("teamspace Bad_Name: not a valid robot name; skipped", out)
        self.assertIn("robot$ts-ok", self.robot_names())

    def test_disabled_teamspace_robots_touch_nothing(self):
        self.h.config["teamspaceRobots"]["enabled"] = False
        self.fake.profiles = ["a"]
        self.h.run()
        self.assertNotIn("robot$ts-a", self.robot_names())
        self.assertEqual(self.fake.secret_data(*self.SEC), {})
        self.assertNotIn("/apis/teknoir.org/v1/profiles", [c[1] for c in self.fake.calls])


class RobotSecretTest(Base):
    def test_a_working_robot_without_the_docker_config_completes_its_secret(self):
        """A seed (or a write that failed after the robot was created) leaves username/password only:
        the next run writes the missing .dockerconfigjson without rotating the credential."""
        self.h.run()
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                                  {"username": data["username"], "password": data["password"]})
        out = self.h.run()
        self.assertIn("robot robot$nodes: Secret teknoir-system/harbor-nodes-pull written (completed)", out)
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.assertIn(".dockerconfigjson", data)
        self.assertEqual(data["password"], self.fake.robot("robot$nodes")["_secret"])
        out2 = self.h.run()
        self.assertNotIn("written", out2)
        self.assertEqual(self.h.last_writes, [])
        self.assertNoSecretsInLogs()

    def test_a_complete_seeded_robot_secret_is_written_once_to_consume_the_marker(self):
        """A seed on a complete Secret whose robot already works still needs one write: the marker
        must go, or a hand-deleted robot would later come back with the old password."""
        self.h.run()
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.h.mark_seed("teknoir-system", "harbor-nodes-pull")
        out = self.h.run()
        self.assertIn("robot robot$nodes: Secret teknoir-system/harbor-nodes-pull written (completed)", out)
        self.assertNotIn(SEED_ANNOTATION,
                         self.fake.secrets[("teknoir-system", "harbor-nodes-pull")]["metadata"].get("annotations") or {})
        data2 = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.assertEqual(data2["password"], data["password"])
        self.assertEqual(self.fake.robot("robot$nodes")["_secret"], data["password"])
        out2 = self.h.run()
        self.assertNotIn("written", out2)
        self.assertEqual(self.h.last_writes, [])
        self.assertNoSecretsInLogs()

    def test_a_non_utf8_stored_password_fails_without_leaking_the_bytes(self):
        """A stored value that is not UTF-8 must not put a byte of it (or its position) in the log."""
        self.fake.set_secret_data("teknoir-system", "harbor-nodes-pull", {"username": "robot$nodes"})
        obj = self.fake.secrets[("teknoir-system", "harbor-nodes-pull")]
        obj["data"]["password"] = base64.b64encode(b"\xffValidPass1").decode()
        out = self.h.run(expect_rc=1)
        self.assertIn("is not valid base64 UTF-8", out)
        self.assertNotIn("0xff", out.lower())
        self.assertNotIn("position", out)
        self.assertNotIn(obj["data"]["password"], out)
        self.assertNotIn("ValidPass1", out)

    def test_static_robot_secret_is_rotated_by_deleting_it(self):
        self.h.run()
        old = self.fake.robot("robot$ci")["_secret"]
        del self.fake.secrets[("teknoir-ci", "harbor-ci-robot")]
        self.h.run()
        self.assertNotEqual(self.fake.robot("robot$ci")["_secret"], old)
        data = self.fake.secret_data("teknoir-ci", "harbor-ci-robot")
        self.assertEqual(data["password"], self.fake.robot("robot$ci")["_secret"])

    def test_missing_namespace_is_skipped_not_failed(self):
        self.fake.namespaces.discard("teknoir-ci")
        out = self.h.run()
        self.assertIn("robot ci: namespace teknoir-ci does not exist yet; skipped", out)
        self.assertIsNone(self.fake.robot("robot$ci"))


class AdoptionTest(Base):
    """A robot created while its Secret already holds a valid password adopts it only when the Secret
    is an explicit seed (annotation); a credential carried over from another Harbor keeps working.
    Without the annotation, a hand-deleted robot gets a new password. An invalid seed falls back to
    a new password."""

    def test_nodes_robot_adopts_a_seeded_password(self):
        self.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                                  {"password": NODES_SEED, "username": "robot$nodes"})
        self.h.mark_seed("teknoir-system", "harbor-nodes-pull")
        out = self.h.run()
        self.assertIn("robot robot$nodes: created (password adopted from the seeded Secret)", out)
        self.assertEqual(self.fake.robot("robot$nodes")["_secret"], NODES_SEED)
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.assertEqual(data["username"], "robot$nodes")
        self.assertEqual(data["password"], NODES_SEED)
        cfg = json.loads(data[".dockerconfigjson"])
        self.assertEqual(cfg["auths"]["harbor.test.example"]["password"], NODES_SEED)
        # the write consumes the seed marker
        self.assertNotIn(SEED_ANNOTATION,
                         self.fake.secrets[("teknoir-system", "harbor-nodes-pull")]["metadata"].get("annotations") or {})
        out2 = self.h.run()
        self.assertNotIn("robot robot$nodes: created", out2)
        self.assertNotIn("robot robot$nodes: secret refreshed", out2)
        self.assertEqual(self.h.last_writes, [], "the second run rewrote the Secret")
        self.assertNoSecretsInLogs()

    def test_a_valid_password_without_the_seed_annotation_is_not_adopted(self):
        """An admin deleted the robot by hand to revoke a leaked credential: a re-created robot must
        not come back with the same password just because the old Secret still holds it."""
        self.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                                  {"password": NODES_SEED, "username": "robot$nodes"})
        out = self.h.run()
        self.assertIn("robot robot$nodes: created (new password)\n", out)
        real = self.fake.robot("robot$nodes")["_secret"]
        self.assertNotEqual(real, NODES_SEED)
        self.assertEqual(self.fake.secret_data("teknoir-system", "harbor-nodes-pull")["password"], real)
        # the seed was overwritten, so name it explicitly: it is no longer in the fake's state
        self.assertNoSecretsInLogs(values=(NODES_SEED,))

    def test_teamspace_robot_adopts_a_seeded_password(self):
        self.fake.profiles = ["a"]
        # both keys are seeded: the run must still write once to consume the marker
        self.fake.set_secret_data(*TEAMSPACE_SECRET, {"a.password": TEAMSPACE_SEED, "a.username": "robot$ts-a"})
        self.h.mark_seed(*TEAMSPACE_SECRET)
        out = self.h.run()
        self.assertIn("robot robot$ts-a: created (password adopted from the seeded Secret)", out)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.secret_data(*TEAMSPACE_SECRET)["a.password"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.secret_data(*TEAMSPACE_SECRET)["a.username"], "robot$ts-a")
        self.assertNotIn(SEED_ANNOTATION, self.fake.secrets[TEAMSPACE_SECRET]["metadata"].get("annotations") or {})
        self.h.run()
        self.assertEqual(self.h.last_writes, [], "the second run rewrote the Secret")
        self.assertNoSecretsInLogs()

    def test_a_used_teamspace_seed_marker_is_removed_and_a_deleted_robot_gets_a_new_password(self):
        """The marker is one-shot: once every seeded teamspace has a Profile, the next write consumes
        it, so a robot deleted by hand later comes back with a new password."""
        self.fake.profiles = ["a"]
        self.fake.set_secret_data(*TEAMSPACE_SECRET, {"a.username": "robot$ts-a", "a.password": TEAMSPACE_SEED})
        self.h.mark_seed(*TEAMSPACE_SECRET)
        out = self.h.run()
        self.assertIn("robot robot$ts-a: created (password adopted from the seeded Secret)", out)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], TEAMSPACE_SEED)
        self.assertNotIn(SEED_ANNOTATION,
                         self.fake.secrets[TEAMSPACE_SECRET]["metadata"].get("annotations") or {})
        out2 = self.h.run()
        self.assertNotIn("harbor-teamspace-pull written", out2)
        self.assertEqual(self.h.last_writes, [], "the second run rewrote the Secret")
        # an admin deletes the robot by hand; the marker is gone, so it comes back with a NEW password
        self.fake.robots = {i: r for i, r in self.fake.robots.items() if r["name"] != "robot$ts-a"}
        out3 = self.h.run()
        self.assertIn("robot robot$ts-a: created (new password)", out3)
        data = self.fake.secret_data(*TEAMSPACE_SECRET)
        self.assertNotEqual(data["a.password"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.robot("robot$ts-a")["_secret"], data["a.password"])
        self.assertNoSecretsInLogs(values=(TEAMSPACE_SEED,))

    def test_a_seeded_teamspace_without_a_profile_keeps_the_marker_while_another_is_created(self):
        """A write for another Profile must not consume the marker of a seeded teamspace that has no
        Profile yet; once it does, that write adopts the password and removes the marker."""
        self.fake.profiles = ["acme"]
        self.fake.set_secret_data(*TEAMSPACE_SECRET, {
            "teknoir-demo.username": "robot$ts-teknoir-demo", "teknoir-demo.password": TEAMSPACE_SEED})
        self.h.mark_seed(*TEAMSPACE_SECRET)
        out = self.h.run()
        self.assertIn("robot robot$ts-acme: created (new password)", out)
        self.assertIsNone(self.fake.robot("robot$ts-teknoir-demo"))
        data = self.fake.secret_data(*TEAMSPACE_SECRET)
        self.assertEqual(data["teknoir-demo.username"], "robot$ts-teknoir-demo")
        self.assertEqual(data["teknoir-demo.password"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.robot("robot$ts-acme")["_secret"], data["acme.password"])
        self.assertEqual(self.fake.secrets[TEAMSPACE_SECRET]["metadata"]["annotations"][SEED_ANNOTATION], "true")
        self.fake.profiles = ["acme", "teknoir-demo"]
        out2 = self.h.run()
        self.assertIn("robot robot$ts-teknoir-demo: created (password adopted from the seeded Secret)", out2)
        self.assertEqual(self.fake.robot("robot$ts-teknoir-demo")["_secret"], TEAMSPACE_SEED)
        self.assertEqual(self.fake.secret_data(*TEAMSPACE_SECRET)["teknoir-demo.password"], TEAMSPACE_SEED)
        self.assertNotIn(SEED_ANNOTATION,
                         self.fake.secrets[TEAMSPACE_SECRET]["metadata"].get("annotations") or {})
        self.assertNoSecretsInLogs()

    def test_a_seeded_password_replaces_a_stale_robot_secret(self):
        """A seed written after the robot exists (or a create whose PATCH failed) sets the stored
        password instead of rotating it away."""
        self.h.run()
        old = self.fake.robot("robot$nodes")["_secret"]
        self.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                                  {"username": "robot$nodes", "password": NODES_SEED})
        self.h.mark_seed("teknoir-system", "harbor-nodes-pull")
        out = self.h.run()
        self.assertIn("robot robot$nodes: secret set to the seeded password", out)
        self.assertEqual(self.fake.robot("robot$nodes")["_secret"], NODES_SEED)
        data = self.fake.secret_data("teknoir-system", "harbor-nodes-pull")
        self.assertEqual(data["password"], NODES_SEED)
        self.assertNotIn(SEED_ANNOTATION,
                         self.fake.secrets[("teknoir-system", "harbor-nodes-pull")]["metadata"].get("annotations") or {})
        self.assertNoSecretsInLogs(values=(old, NODES_SEED))

    def test_a_stale_robot_secret_without_the_seed_annotation_is_refreshed(self):
        h = Harness(self)
        h.ghcr()
        h.run()
        old = h.fake.robot("robot$nodes")["_secret"]
        h.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                               {"username": "robot$nodes", "password": NODES_SEED})
        out = h.run()
        self.assertIn("robot robot$nodes: secret refreshed (stale Secret)", out)
        real = h.fake.robot("robot$nodes")["_secret"]
        self.assertNotEqual(real, NODES_SEED)
        self.assertEqual(h.fake.secret_data("teknoir-system", "harbor-nodes-pull")["password"], real)
        # NODES_SEED was overwritten above, so name it explicitly
        self.assertNoSecretsInLogs(h, values=(old, NODES_SEED))

    def test_invalid_seeds_fall_back_to_a_new_password(self):
        # short, no upper, no digit, and a trailing newline (whitespace is refused)
        seeds = ("short1A", "alllowercase123", "NoDigitsHereAtAll", "ValidPass1234\n")
        for seed in seeds:
            with self.subTest(seed=seed):
                h = Harness(self)
                h.ghcr()
                h.fake.set_secret_data("teknoir-system", "harbor-nodes-pull",
                                       {"password": seed, "username": "robot$nodes"})
                h.mark_seed("teknoir-system", "harbor-nodes-pull")
                out = h.run()
                self.assertIn("the seeded password is not valid for Harbor", out)
                real = h.fake.robot("robot$nodes")["_secret"]
                self.assertNotEqual(real, seed)
                self.assertEqual(h.fake.secret_data("teknoir-system", "harbor-nodes-pull")["password"], real)
                self.assertNoSecretsInLogs(h)
                for s in seeds:
                    for v in (s, s.strip(), base64.b64encode(s.encode()).decode()):
                        for output in h.outputs:
                            self.assertNotIn(v, output, "a seed reached the log")


class NoCiRobotTest(Base):
    def test_config_without_the_ci_robot_still_creates_nodes(self):
        """The template drops the ci robot; the script needs no flag and never touches teknoir-ci."""
        cfg = copy.deepcopy(base_config())
        cfg["robots"] = [r for r in cfg["robots"] if r["name"] != "ci"]
        h = Harness(self, cfg)
        h.ghcr()
        h.fake.no_access = {"teknoir-ci"}   # no RBAC there: any Secret request answers 403
        out = h.run()
        self.assertIsNotNone(h.fake.robot("robot$nodes"))
        self.assertIsNone(h.fake.robot("robot$ci"))
        self.assertIn("robot robot$nodes: created", out)
        self.assertNoSecretsInLogs(h)

    def test_full_config_without_access_to_teknoir_ci_fails_the_robots_step(self):
        """Control: with the ci robot in the config the same run cannot finish, and says why."""
        h = Harness(self, copy.deepcopy(base_config()))
        h.ghcr()
        h.fake.no_access = {"teknoir-ci"}
        out = h.run(expect_rc=1)
        self.assertIn("ERROR robots", out)
        self.assertNoSecretsInLogs(h)


class NoSecretsInLogsTest(Base):
    def test_full_lifecycle_never_logs_a_secret(self):
        self.h.dockerhub()
        self.h.ghcr()
        self.fake.profiles = ["a", "b"]
        self.h.run()
        self.h.dockerhub(token="dckr_pat_SECONDtokenBBBB")
        self.h.run()
        self.fake.profiles = ["a"]
        self.h.run()
        self.h.ghcr(None)
        self.h.run(expect_rc=1)
        self.h.outputs.append("")
        for out in self.h.outputs:
            self.assertNotIn("dckr_pat_SECONDtokenBBBB", out)
        self.assertNoSecretsInLogs()


class RenderedConfigTest(unittest.TestCase):
    """The real chart config (helm template of the harbor-config ConfigMap) against the fake."""

    def setUp(self):
        chart = os.path.join(HERE, "..")
        if not shutil.which("helm") or not os.path.isdir(os.path.join(chart, "charts")):
            self.skipTest("helm or the chart's subchart (helm dependency build) is missing")
        p = subprocess.run(["helm", "template", "harbor", chart, "--namespace", "teknoir-system",
                            "-s", "templates/harbor-config.yaml"], capture_output=True, text=True)
        if p.returncode:
            self.skipTest("helm template failed: " + p.stderr[:200])
        # config.json is the literal block of the ConfigMap
        text = p.stdout
        start = text.index("  config.json: |\n") + len("  config.json: |\n")
        lines = []
        for ln in text[start:].splitlines():
            if ln.startswith("    ") or not ln.strip():
                lines.append(ln[4:])
            else:
                break
        self.config = json.loads("\n".join(lines))
        self.h = Harness(self, self.config)
        self.fake = self.h.fake

    def test_production_values_converge_and_are_idempotent(self):
        self.h.ghcr()
        self.fake.profiles = ["teknoir-demo"]
        out = self.h.run()
        self.assertIn("in sync", out)
        self.h.run()
        self.assertEqual(self.h.last_writes, [])
        self.assertEqual(sorted(p["name"] for p in self.fake.projects.values()),
                         sorted(["teknoir"] + PROXIES))
        self.assertEqual(self.fake.registry("ghcr")["_ak"], "tekn0ir")
        self.assertEqual(self.fake.registry("dockerhub")["_ak"], "")  # anonymous until its Secret exists
        gib = 1024 ** 3
        quotas = {n: self.fake.quotas[self.fake.project(n)["project_id"]]["hard"]["storage"] // gib
                  for n in ["teknoir"] + PROXIES}
        self.assertEqual(quotas, {"teknoir": 250, "ghcr": 150, "dockerhub": 100, "nvcr": 100, "quay": 40,
                                  "gcr": 30, "k8s": 30})
        self.assertEqual(sum(quotas.values()), 700)
        # GC must not delete untagged artifacts: that would drop the digest-pinned pulls the proxy
        # retention rule keeps (retention handles untagged artifacts itself).
        self.assertIs(json.loads(self.fake.schedules["gc"]["job_parameters"])["delete_untagged"], False)
        for n in PROXIES:
            self.assertEqual(self.fake.project(n)["metadata"]["public"], "false")
        self.assertEqual(sorted(self.fake.secret_data("teknoir-system", "harbor-teamspace-pull")),
                         ["teknoir-demo.password", "teknoir-demo.username"])
        self.assertIsNotNone(self.fake.secret_data("teknoir-system", "harbor-nodes-pull"))
        for out in self.h.outputs:
            self.assertNotIn(GHCR_PAT, out)


if __name__ == "__main__":
    unittest.main()
