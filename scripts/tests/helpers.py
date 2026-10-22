"""Shared test helpers: loading the hyphen-named scripts, a throwaway git repo, a fake Sys."""
import atexit
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SCRIPTS)
for _k, _v in (("GIT_AUTHOR_NAME", "t"), ("GIT_AUTHOR_EMAIL", "t@t"), ("GIT_COMMITTER_NAME", "t"), ("GIT_COMMITTER_EMAIL", "t@t")):
    os.environ.setdefault(_k, _v)
import stagelib as L  # noqa: E402


def load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(SCRIPTS, filename))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    loader.exec_module(mod)
    return mod


def tmpdir() -> str:
    """tempfile.mkdtemp() that is removed when the test process exits."""
    d = tempfile.mkdtemp()
    atexit.register(shutil.rmtree, d, ignore_errors=True)
    return d


def git(repo, *args, env=None):
    e = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
         "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", **(env or {})}
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True, env=e).stdout.strip()


class Repo:
    """A throwaway clone with a bare 'origin' and a branch teknoir-cloud:

        c1 - c2 ---- m3 (merge of PR #3 'feature') - c4 (squash '(#4)')
              \\     /
               f3 --'
    """

    def __init__(self):
        self.tmp = tmpdir()
        self.origin = os.path.join(self.tmp, "origin.git")
        self.work = os.path.join(self.tmp, "work")
        subprocess.run(["git", "init", "-q", "--bare", self.origin], check=True)
        subprocess.run(["git", "init", "-q", "-b", "teknoir-cloud", self.work], check=True)
        git(self.work, "remote", "add", "origin", self.origin)
        self.c = {}
        os.makedirs(os.path.join(self.work, "charts", "app-of-apps", "tests"))
        with open(os.path.join(self.work, "charts", "app-of-apps", "tests", "x_test.yaml"), "w") as fh:
            fh.write("suite: x\n")
        os.makedirs(os.path.join(self.work, "scripts"))
        # The real policy, but with the fixture baseline (no rollback floor, images: warn): tests that need a
        # floor or deny set it themselves (the repo's floor names real releases the fake repo does not have).
        with open(os.path.join(SCRIPTS, "release-policy.yaml")) as src, open(os.path.join(self.work, "scripts", "release-policy.yaml"), "w") as dst:
            text = re.sub(r"(?m)^rollback_floor:.*$", 'rollback_floor: ""', src.read())
            text = re.sub(r"(?m)^cr_revisions:.*$", "cr_revisions: warn", text)
            text = re.sub(r"(?m)^portal_profile_controller_tags:.*$", 'portal_profile_controller_tags: ["sha-1234abcd"]', text)
            dst.write(re.sub(r"(?m)^images:.*$", "images: warn", text))   # the fixture baseline; tests set deny themselves
        self.c["c1"] = self.commit("c1", "README", "1")
        self.c["c2"] = self.commit("c2", "README", "2")
        git(self.work, "checkout", "-q", "-b", "feature")
        self.c["f3"] = self.commit("f3", "feature", "x")
        git(self.work, "checkout", "-q", "teknoir-cloud")
        git(self.work, "merge", "--no-ff", "-q", "-m", "Merge pull request #3 from teknoir/feature", "feature")
        self.c["m3"] = git(self.work, "rev-parse", "HEAD")
        self.c["c4"] = self.commit("squash change (#4)", "README", "4")
        git(self.work, "push", "-q", "origin", "teknoir-cloud", "feature")
        git(self.work, "fetch", "-q", "origin")
        self.sha = lambda name: self.c[name]

    def commit(self, msg, fname, content):
        with open(os.path.join(self.work, fname), "w") as fh:
            fh.write(content)
        git(self.work, "add", "-A")
        git(self.work, "commit", "-q", "-m", msg)
        return git(self.work, "rev-parse", "HEAD")


def app(name, *, target, revision=None, sync="Synced", health="Healthy", repo=L.REPO_URL, chart=None, ns="x", op=None):
    src = {"repoURL": repo, "targetRevision": target}
    if chart:
        src["chart"] = chart
    else:
        src["path"] = f"charts/{name}"
    status = {"sync": {"status": sync, "revision": revision if revision is not None else target},
              "health": {"status": health}}
    if op:
        status["operationState"] = op
    return {"metadata": {"name": name}, "spec": {"source": src, "destination": {"namespace": ns}}, "status": status}


def root_app(*, target, release_name=None, params=None, sync_rev=None, selfheal=True, annotations=None):
    ann = dict(annotations or {})
    if release_name:
        ann[L.ANN_RELEASE] = release_name
    r = {"metadata": {"name": L.ROOT_APP, "annotations": ann},
         "spec": {"project": "default", "destination": {"namespace": L.NAMESPACE, "server": "https://kubernetes.default.svc"},
                  "source": {"path": L.ROOT_PATH, "repoURL": L.REPO_URL, "targetRevision": target},
                  "syncPolicy": {"automated": {"prune": True, "selfHeal": selfheal}}},
         "status": {"sync": {"status": "Synced", "revision": sync_rev or target}, "health": {"status": "Healthy"}}}
    if params is not None:
        r["spec"]["source"]["helm"] = {"parameters": params}
    return r


# ---------------------------------------------------------------------------------------------
# A fake cluster + GitHub + registry behind Sys. git is REAL (throwaway repo with a bare origin).
# ---------------------------------------------------------------------------------------------
import copy  # noqa: E402
import datetime as _dt  # noqa: E402


def merge_patch(dst, patch):
    if not isinstance(patch, dict):
        return copy.deepcopy(patch)
    out = dict(dst) if isinstance(dst, dict) else {}
    for k, v in patch.items():
        if v is None:
            out.pop(k, None)
        else:
            out[k] = merge_patch(out.get(k), v)
    return out


class FakeSys(L.Sys):
    def __init__(self, root, children=("a",), releases=None, crane_fail=(), releaser_installed=True):
        self.real = L.Sys()
        self.root = root
        self.children = {n: app(n, target=L.root_live_sha(root), revision=L.root_live_sha(root)) for n in children}
        self.lease = None
        self.releases = releases or []
        self.crane_fail = set(crane_fail)
        self.calls = []
        self.t = _dt.datetime(2026, 10, 17, 12, 0, tzinfo=_dt.timezone.utc)
        self.ns_annotations = {}
        self.converge_on_patch = True
        self.removed_children_in_render = ()
        self.render_children = list(children)
        # The release-guard chart creates the staging-releaser ServiceAccount, its RoleBinding and Role. Without it
        # (before release .2) impersonating it fails, exactly like the real apiserver.
        self.releaser_installed = releaser_installed
        self.pods = []
        self.metrics = ""
        self.patch_fails = False
        self.patch_applies_then_fails = False    # the apiserver applied the patch but the call reported an error
        self.root_unreadable = False
        self.unreadable_after_patch_fail = False
        self.releaser_can_i = True
        self.guard_binding = None            # a dict (the binding's spec) when the guard is installed
        self.extra_docs = {}                 # release sha -> {file name: manifest} added to that render (apps/<name>.yaml)
        self.profiles = []                   # Profile names (cluster scoped, namespace = name)
        self.rolebindings = []               # RoleBinding objects (all namespaces)
        self.clusterrolebindings = []        # ClusterRoleBinding objects
        self.profiles_unreadable = False
        self.render_fail = set()             # release shas whose render fails

    # clock
    def now(self):
        return self.t

    def sleep(self, s):
        self.t += _dt.timedelta(seconds=s)

    def _kube(self, argv):
        a = [x for x in argv[1:]]
        assert a[0] == "--context" and a[1] == "vpro", argv
        a = a[2:]
        as_user = None
        if a and a[0].startswith("--as="):
            as_user = a[0][5:]
            a = a[1:]
        self.last_as = as_user
        known_sas = {f"system:serviceaccount:{L.NAMESPACE}:{L.RELEASER_NAME}"} if self.releaser_installed else set()
        if as_user is not None and as_user not in known_sas:
            if a[0] == "auth":                     # impersonating is allowed for the admin; the answer is just "no"
                return L.Result(1, "no\n", "")
            return L.Result(1, "", f'Error from server (Forbidden): User "{as_user}" cannot {a[0]} resource: serviceaccount "{as_user.rsplit(":", 1)[-1]}" not found')
        while "-n" in a:                      # the namespace is always teknoir-system here
            i = a.index("-n")
            del a[i:i + 2]
        verb = a[0]
        rest = a[1:]
        out = lambda o, rc=0, err="": L.Result(rc, o if isinstance(o, str) else json.dumps(o), err)
        j = lambda o: out(o)
        if verb == "get":
            if rest[0] == "application" and rest[1] == L.ROOT_APP:
                if self.root_unreadable:
                    return out("", 1, "Error from server (Timeout): the server was unable to return a response")
                return j(self.root)
            if rest[0] == "applications":
                return j({"items": [self.root, *self.children.values()]})
            if rest[0] == "application":
                return j(self.children[rest[1]])
            if rest[0] == "lease":
                return j(self.lease) if self.lease else out("", 1, "NotFound")
            if rest[0] == "pods":
                return j({"items": self.pods})
            if rest[0] == "validatingadmissionpolicybinding":
                return j({"spec": self.guard_binding}) if self.guard_binding else out("", 1, "NotFound")
            if rest[0] == "--raw":
                return out(self.metrics)
            if rest[0] in ("serviceaccount", "rolebinding"):
                return out({"metadata": {"name": rest[1]}}) if self.releaser_installed else out("", 1, "NotFound")
            if rest[0] == "profiles.teknoir.org":
                if self.profiles_unreadable:
                    return out("", 1, "Error from server (Forbidden): profiles.teknoir.org is forbidden")
                return j({"items": [{"metadata": {"name": n}} for n in self.profiles]})
            if rest[0] == "rolebindings":
                assert "-A" in rest and any(x.startswith("--field-selector=metadata.name=") for x in rest), rest
                return j({"items": self.rolebindings})
            if rest[0] == "clusterrolebindings":
                return j({"items": self.clusterrolebindings})
            if rest[0] == "namespaces":
                return out("namespace/teknoir-system\n")
            if rest[0] == "namespace":
                return j({"metadata": {"annotations": self.ns_annotations}})
            return out("", 1, "NotFound")
        if verb == "auth":
            return out("yes\n") if self.releaser_can_i else out("no\n", 1)
        if verb == "create" and rest[:2] == ["-f", "-"]:
            self.lease = json.loads(kw_input(self)); self.lease["metadata"]["resourceVersion"] = "1"; return out("created")
        if verb == "replace":
            self.lease = json.loads(kw_input(self)); self.lease["metadata"]["resourceVersion"] = "2"; return out("replaced")
        if verb == "patch" and rest[0] == "lease":
            self.lease = merge_patch(self.lease, json.loads(rest[rest.index("-p") + 1])); return out("patched")
        if verb == "patch" and rest[0] == "application":
            name = rest[1]
            patch = json.loads(rest[rest.index("-p") + 1])
            if name == L.ROOT_APP:
                if self.patch_fails:
                    self.root_unreadable = self.unreadable_after_patch_fail
                    return out("", 1, "Error from server (InternalError): webhook timed out")
                self.root = merge_patch(self.root, patch)
                sha = patch.get("spec", {}).get("source", {}).get("targetRevision")
                ok = self.converge_on_patch(sha) if callable(self.converge_on_patch) else self.converge_on_patch
                if ok and sha:
                    self.root["status"]["sync"]["revision"] = sha
                    for n, c in self.children.items():
                        c["spec"]["source"]["targetRevision"] = sha
                        c["status"]["sync"]["revision"] = sha
                        c["status"]["health"]["status"] = "Healthy"
                    for n in self.render_children:
                        if n not in self.children:
                            self.children[n] = app(n, target=sha, revision=sha)
                if self.patch_applies_then_fails:
                    return out("", 1, "Error from server (Timeout): request did not complete within the allowed duration")
                return out("patched")
            self.children[name] = merge_patch(self.children[name], patch)
            return out("patched")
        if verb in ("annotate", "patch", "delete", "apply"):
            if verb == "annotate" and rest[0] == "namespace":
                for kv in rest[2:]:
                    if kv == "--overwrite":
                        continue
                    if kv.endswith("-"):
                        self.ns_annotations.pop(kv[:-1], None)
                    else:
                        k, v = kv.split("=", 1)
                        self.ns_annotations[k] = v
            return out("ok")
        raise AssertionError(f"unexpected kubectl: {argv}")

    def run(self, argv, *, cwd=None, input=None, check=True, timeout=None):
        self.calls.append((list(argv), input))
        self._input = input
        c = os.path.basename(argv[0])
        if c == "git":
            return self.real.run(argv, cwd=cwd, input=input, check=check)
        if c == "kubectl":
            r = self._kube(argv)
        elif c == "gh":
            r = self._gh(argv)
        elif c == "crane":
            ref = argv[2] if len(argv) > 2 else ""
            r = L.Result(1, "", "MANIFEST_UNKNOWN") if ref in self.crane_fail else L.Result(0, "sha256:" + "9" * 64 if argv[1] == "digest" else "{}", "")
        elif c == "staging-render.sh":
            r = self._render(argv)
        elif c in ("helm", "kubeconform", "dyff", "curl"):
            r = L.Result(0, "", "")
        else:
            raise AssertionError(f"unexpected command {argv}")
        if check and r.rc != 0:
            raise RuntimeError(f"{argv} failed: {r.err}")
        return r

    def _gh(self, argv):
        flag = lambda f: argv[argv.index(f) + 1] if f in argv else None
        read = lambda path: open(path).read() if path else ""
        if argv[1:3] == ["release", "list"]:
            return L.Result(0, json.dumps([{k: v for k, v in r.items() if k != "body"} for r in self.releases]), "")
        if argv[1:3] == ["release", "view"]:
            r = next((r for r in self.releases if r["tagName"] == argv[3]), None)
            return L.Result(0, (r or {}).get("body", ""), "") if r else L.Result(1, "", "release not found")
        if argv[1:3] == ["release", "create"]:
            self.releases.append({"tagName": argv[3], "isPrerelease": "--prerelease" in argv, "name": flag("--title") or argv[3],
                                  "body": read(flag("--notes-file"))})
        if argv[1:3] == ["release", "edit"]:
            r = next(r for r in self.releases if r["tagName"] == argv[3])
            if flag("--title"):
                r["name"] = flag("--title")
            if flag("--notes-file"):
                r["body"] = read(flag("--notes-file"))
            if flag("--notes"):
                r["body"] = flag("--notes")
            if "--prerelease" in argv:
                r["isPrerelease"] = True
            if "--prerelease=false" in argv:
                r["isPrerelease"] = False
        return L.Result(0, "", "")

    def _render(self, argv):
        g = lambda flag: argv[argv.index(flag) + 1] if flag in argv else None
        out, sha = g("--out"), g("--release")
        if sha in self.render_fail:
            return L.Result(1, "", "helm template failed")
        os.makedirs(os.path.join(out, "apps"), exist_ok=True)
        os.makedirs(os.path.join(out, "plugins"), exist_ok=True)
        with open(os.path.join(out, "root.yaml"), "w") as fh:
            fh.write(json.dumps({"apiVersion": "argoproj.io/v1alpha1", "kind": "Application", "metadata": {"name": "a"},
                                 "spec": {"source": {"repoURL": L.REPO_URL, "path": "charts/a", "targetRevision": sha}}}))
        names = self.render_children
        for n in names:
            with open(os.path.join(out, "apps", f"{n}.yaml"), "w") as fh:
                fh.write(json.dumps({"kind": "Deployment", "metadata": {"name": n, "namespace": "teknoir-system"},
                                     "spec": {"template": {"spec": {"containers": [{"name": "c", "image": "ghcr.io/teknoir/x:t@sha256:" + "a" * 64}]}}}}))
        for fname, doc in (self.extra_docs.get(sha) or {}).items():
            with open(os.path.join(out, "apps", fname), "w") as fh:
                fh.write(json.dumps(doc))
        with open(os.path.join(out, "apps.tsv"), "w") as fh:
            fh.write("".join(f"{n}\tcharts/{n}\tns\n" for n in names))
        with open(os.path.join(out, "plugins.json"), "w") as fh:
            json.dump({"version": "0.0.104", "digests": {"profile-plugin-jwks": "sha256:aa"}}, fh)
        return L.Result(0, "", "")

    # convenience
    def kubectl_calls(self):
        return [c for c, _ in self.calls if os.path.basename(c[0]) == "kubectl"]

    def verbs(self):
        out = []
        for c in self.kubectl_calls():
            a = c[3:]
            if a and a[0].startswith("--as="):
                a = a[1:]
            out.append(a[0])
        return out


def kw_input(fake):
    return fake._input
