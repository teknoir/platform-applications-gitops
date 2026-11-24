"""The Kargo robot and the robot Secret options it needs (CI/CD v4 P4.2, plans/cicd/v4/p42-spec.md section 5).

  - `secret.optional: true` (the kargo robot): while the owning chart has not rendered or granted the Secret
    (charts/kargo-config renders platform/harbor-read), a 403 on reading it or a missing Secret skips that
    robot with one log line and creates no `robot$kargo`; the other robots and the run still succeed. A robot
    without `optional` fails the robots step on an unreadable Secret, as it always has;
  - `secret.extraData`: plaintext extra keys written into a robot's Secret on every write. Kargo's credential
    lookup reads repoURL and repoURLIsRegex next to username/password (the image Secret of a Warehouse);
  - `secret.keys`: renames the two credential keys (the docker config always carries the real robot name).

Runs files/harbor-config.py as a subprocess against the in-process fake Harbor and Kubernetes API, like
test_harbor_config.py.
"""
import copy
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_harbor  # noqa: E402
import test_harbor_config as T  # noqa: E402

PULL = [{"project": "teknoir", "access": ["repository:pull"]}]
KARGO_SECRET = ("platform", "harbor-read")
REPO_RE = r"^harbor\.teknoir\.cloud/teknoir/.*"


def kargo_robot(**secret):
    """The `kargo` robot as charts/harbor/values.yaml declares it."""
    sec = {"namespace": "platform", "name": "harbor-read", "optional": True,
           "extraData": {"repoURL": REPO_RE, "repoURLIsRegex": "true"}}
    sec.update(secret)
    return {"name": "kargo", "secret": sec, "permissions": PULL}


def config(robots):
    cfg = T.base_config()
    cfg["robots"] = [r for r in cfg["robots"] if r["name"] != "ci"] + robots
    return cfg


class KargoRobot(unittest.TestCase):
    def assertNoSecrets(self, h):
        """No credential of the fake (robot secrets, Secret data, registry credentials) in any log line."""
        secrets = h.all_secret_values() | {fake_harbor.ADMIN_PASSWORD, fake_harbor.K8S_TOKEN, T.GHCR_PAT}
        for out in h.outputs:
            for s in secrets:
                self.assertNotIn(s, out, "a secret reached the log")

    def harness(self, robots=None):
        h = T.Harness(self, config(robots if robots is not None else [kargo_robot()]))
        h.ghcr()
        # The platform namespace exists and kargo-config (charts/kargo-config) renders the Secret there: the
        # chart owns `create`, harbor-config only get/update/patch.
        h.fake.namespaces.add("platform")
        h.fake.no_create.add("platform")
        # As charts/kargo-config/templates/harbor-read.yaml renders it: labelled as a Kargo image credential,
        # empty until harbor-config fills it in.
        h.fake.secrets[KARGO_SECRET] = {
            "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": "harbor-read", "namespace": "platform", "resourceVersion": "1",
                         "labels": {"kargo.akuity.io/cred-type": "image"}}}
        return h

    def test_writes_the_kargo_robot_secret_with_username_password_and_the_extra_keys(self):
        h = self.harness()
        out = h.run()
        robot = h.fake.robot("robot$kargo")
        self.assertIsNotNone(robot)
        data = h.fake.secret_data(*KARGO_SECRET)
        self.assertEqual(data["username"], "robot$kargo")
        self.assertEqual(data["password"], robot["_secret"])
        self.assertEqual(data["repoURL"], REPO_RE)
        self.assertEqual(data["repoURLIsRegex"], "true")
        # The docker config still names the real robot (Kargo's image Secret does not need it, docker does).
        import json
        auths = json.loads(data[".dockerconfigjson"])["auths"]
        self.assertEqual(auths["harbor.test.example"]["username"], "robot$kargo")
        self.assertIn("Secret platform/harbor-read written", out)
        self.assertNoSecrets(h)

    def test_pull_only_on_the_teknoir_project(self):
        h = self.harness()
        h.run()
        self.assertEqual(h.fake.robot("robot$kargo")["permissions"],
                         [{"kind": "project", "namespace": "teknoir",
                           "access": [{"resource": "repository", "action": "pull"}]}])
        self.assertEqual(h.fake.robot("robot$kargo")["duration"], -1)

    def test_keeps_the_extra_keys_and_writes_nothing_on_a_second_run(self):
        h = self.harness()
        h.run()
        out = h.run()
        self.assertIn("in sync", out)
        self.assertEqual(h.last_writes, [], "the second run wrote something")
        self.assertEqual(h.fake.secret_data(*KARGO_SECRET)["repoURL"], REPO_RE)

    def test_adds_an_extra_key_to_an_existing_working_robot_secret(self):
        """A new key in secret.extraData is written even while the credential still works (the write replaces
        .data, so it must include every wanted key)."""
        h = self.harness([kargo_robot(extraData={"repoURL": REPO_RE})])
        h.run()
        self.assertNotIn("repoURLIsRegex", h.fake.secret_data(*KARGO_SECRET))
        h2 = self.harness([kargo_robot()])
        h2.fake.secrets[KARGO_SECRET] = copy.deepcopy(h.fake.secrets[KARGO_SECRET])
        h2.fake.robots = copy.deepcopy(h.fake.robots)
        h2.run()
        data = h2.fake.secret_data(*KARGO_SECRET)
        self.assertEqual(data["repoURLIsRegex"], "true")
        self.assertEqual(data["password"], h2.fake.robot("robot$kargo")["_secret"])

    def test_a_changed_extra_value_is_written_once(self):
        h = self.harness()
        h.run()
        h2 = self.harness([kargo_robot(extraData={"repoURL": r"^harbor\.teknoir\.cloud/teknoir/wg-.*",
                                                  "repoURLIsRegex": "true"})])
        h2.fake.secrets[KARGO_SECRET] = copy.deepcopy(h.fake.secrets[KARGO_SECRET])
        h2.fake.robots = copy.deepcopy(h.fake.robots)
        h2.run()
        self.assertTrue(h2.fake.secret_data(*KARGO_SECRET)["repoURL"].endswith("wg-.*"))
        h2.run()
        self.assertEqual(h2.last_writes, [])

    def test_a_403_on_the_secret_skips_the_robot_and_the_run(self):
        h = self.harness()
        h.fake.no_access.add("platform")          # RBAC that does not include this Secret
        out = h.run()
        self.assertIn("robot kargo: Secret platform/harbor-read not granted yet (403); skipped", out)
        self.assertNotIn("ERROR", out)
        self.assertIn("in sync", out)
        self.assertIsNone(h.fake.robot("robot$kargo"))
        # and the robots of the other namespaces are still written
        self.assertIsNotNone(h.fake.robot("robot$nodes"))
        self.assertIsNotNone(h.fake.secret_data("teknoir-system", "harbor-nodes-pull"))
        self.assertNoSecrets(h)

    def test_a_404_on_the_secret_skips_the_robot_before_it_is_created(self):
        h = self.harness()
        del h.fake.secrets[KARGO_SECRET]           # kargo-config has not rendered it yet; no `create` here
        out = h.run()
        self.assertIn("robot kargo: Secret platform/harbor-read missing (kargo-config renders it); skipped", out)
        self.assertNotIn("ERROR", out)
        self.assertIn("in sync", out)
        # Skipped before Harbor: no robot (and so no credential to rotate once the Secret shows up), and
        # nothing written to the API server in platform.
        self.assertIsNone(h.fake.robot("robot$kargo"))
        self.assertEqual([c[0] for c in h.last_writes if c[1].startswith("/api/v1/namespaces/platform")], [])
        self.assertIsNotNone(h.fake.robot("robot$nodes"))
        self.assertIsNotNone(h.fake.secret_data("teknoir-system", "harbor-nodes-pull"))
        self.assertNoSecrets(h)

    def test_a_required_robot_secret_that_is_not_granted_fails_the_robots_step(self):
        """A robot without `secret.optional` (here a robots-step robot in teknoir-system) keeps failing the
        step on an unreadable Secret: the skip is opt-in, never a blanket one."""
        nodes = next(r for r in T.base_config()["robots"] if r["name"] == "nodes")
        h = T.Harness(self, config([kargo_robot(), nodes]))
        h.ghcr()
        h.fake.namespaces.add("platform")
        h.fake.no_access.add("teknoir-system")
        out = h.run(expect_rc=1)
        self.assertIn("ERROR robots", out)
        self.assertNoSecrets(h)

    def test_keys_rename_the_credential_keys(self):
        h = self.harness([kargo_robot(keys={"username": "u", "password": "p"})])
        h.run()
        data = h.fake.secret_data(*KARGO_SECRET)
        self.assertEqual(set(data), {".dockerconfigjson", "u", "p", "repoURL", "repoURLIsRegex"})
        self.assertEqual(data["u"], "robot$kargo")
        self.assertEqual(data["p"], h.fake.robot("robot$kargo")["_secret"])

    def test_a_seeded_secret_with_renamed_keys_is_adopted(self):
        h = self.harness([kargo_robot(keys={"username": "u", "password": "p"})])
        h.fake.set_secret_data(*KARGO_SECRET, {"p": T.NODES_SEED})
        h.mark_seed(*KARGO_SECRET)
        out = h.run()
        self.assertIn("password adopted from the seeded Secret", out)
        self.assertEqual(h.fake.robot("robot$kargo")["_secret"], T.NODES_SEED)
        self.assertEqual(h.fake.secret_data(*KARGO_SECRET)["p"], T.NODES_SEED)
        self.assertNotIn(T.NODES_SEED, out)


if __name__ == "__main__":
    unittest.main()
