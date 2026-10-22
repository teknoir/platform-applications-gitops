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
            "ci": {"schedule": "0 0 2 * * *", "rules": [{"template": "latestPushedK", "value": 15}]},
            "proxy": {"schedule": "0 30 2 * * *",
                      "rules": [{"template": "nDaysSinceLastPull", "value": 30, "untagged": True}]},
        },
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

    def assertNoSecretsInLogs(self):
        secrets = self.h.all_secret_values() | {DOCKERHUB_TOKEN, GHCR_PAT, fake_harbor.ADMIN_PASSWORD, fake_harbor.K8S_TOKEN}
        # a robot password also appears inside the dockerconfigjson blob: compare its parts
        for obj in self.fake.secrets.values():
            for k, v in (obj.get("data") or {}).items():
                if k == ".dockerconfigjson":
                    for e in json.loads(base64.b64decode(v))["auths"].values():
                        secrets |= {e["password"], e["auth"]}
        for out in self.h.outputs:
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

    def test_last_profile_gone_removes_its_robot(self):
        self.fake.profiles = ["a"]
        self.h.run()
        self.fake.profiles = []
        self.h.run()
        self.assertNotIn("robot$ts-a", self.robot_names())
        self.assertEqual(self.fake.secret_data(*self.SEC), {})

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

    def test_deleting_the_whole_secret_rotates_everyone(self):
        self.fake.profiles = ["a", "b"]
        self.h.run()
        del self.fake.secrets[self.SEC]
        self.h.run()
        data = self.fake.secret_data(*self.SEC)
        self.assertEqual(sorted(data), ["a.password", "a.username", "b.password", "b.username"])
        for ns in "ab":
            self.assertEqual(self.fake.robot(f"robot$ts-{ns}")["_secret"], data[f"{ns}.password"])

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
        self.assertNotIn(self.SEC, self.fake.secrets)
        self.assertNotIn("/apis/teknoir.org/v1/profiles", [c[1] for c in self.fake.calls])


class RobotSecretTest(Base):
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
        for n in PROXIES:
            self.assertEqual(self.fake.project(n)["metadata"]["public"], "false")
        self.assertEqual(sorted(self.fake.secret_data("teknoir-system", "harbor-teamspace-pull")),
                         ["teknoir-demo.password", "teknoir-demo.username"])
        self.assertIsNotNone(self.fake.secret_data("teknoir-system", "harbor-nodes-pull"))
        for out in self.h.outputs:
            self.assertNotIn(GHCR_PAT, out)


if __name__ == "__main__":
    unittest.main()
