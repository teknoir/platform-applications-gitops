"""scripts/ci/helm-repos.sh adds every Helm repository the charts and the app-of-apps Applications use, each
exactly once (the render, helm-unittest and scripts-tests jobs of .github/workflows/ci.yml run it first). A fake
helm first on PATH records the calls, so the test needs no network."""
import os
import shlex
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers as H  # noqa: E402

SCRIPT = os.path.join(H.SCRIPTS, "ci", "helm-repos.sh")
REPO = os.path.dirname(H.SCRIPTS)

# One per source kind: a Chart.yaml dependency, a Chart.lock entry, a Chart.yaml dependency of another chart.
WANT = [
    "https://codecentric.github.io/helm-charts",             # charts/auth/Chart.yaml and Chart.lock
    "https://istio-release.storage.googleapis.com/charts",   # charts/istio/Chart.lock
    "https://prometheus-community.github.io/helm-charts",    # charts/monitoring/Chart.yaml and Chart.lock
    "https://l7mp.io/stunner",                               # charts/stunner/Chart.yaml and Chart.lock
]


class HelmRepos(unittest.TestCase):
    def test_every_repository_is_added_exactly_once(self):
        d = H.tmpdir()
        log = os.path.join(d, "helm.log")
        with open(os.path.join(d, "helm"), "w") as fh:
            fh.write(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> {shlex.quote(log)}\n')
        os.chmod(os.path.join(d, "helm"), 0o755)
        env = {**os.environ, "PATH": d + os.pathsep + os.environ["PATH"]}
        r = subprocess.run(["bash", SCRIPT], cwd=REPO, env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

        lines = open(log).read().splitlines()
        added = [ln.split()[-1] for ln in lines if ln.startswith("repo add ")]
        for url in WANT:
            self.assertEqual(added.count(url), 1, f"{url} added {added.count(url)} times: {added}")
        self.assertEqual(len(added), len(set(added)), f"a repository is added twice: {added}")
        self.assertNotIn("https://github.com/teknoir/platform-applications-gitops", added)
        # profile-plugin-emqx depends on emqx 5.8.9, vendored as Chart.lock + charts/emqx-5.8.9.tgz: its repository is
        # not added, so the render and the helm tests need no egress for it (plugins/charts/README.md).
        self.assertNotIn("https://repos.emqx.io/charts", added)
        self.assertIn("repo update", lines[-1])


if __name__ == "__main__":
    unittest.main()
