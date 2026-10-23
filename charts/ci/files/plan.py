#!/usr/bin/env python3
"""ci plan: turn one GitHub push (repo, ref, sha, before) into the jobs of a pipeline.

Reads the repo's pipeline config (/repos/<repo>.json, from charts/ci/files/repos/,
merged with the defaults in /repos/_defaults.json) and writes Argo output parameters:

  /out/active   "true" when the push matches the repo's triggers and has work
  /out/tests    JSON list of test steps   {name, image, workdir, script, ...}
  /out/images   JSON list of image builds {name, refs, args, prebuild, builders, ...}
  /out/helm     JSON object for a chart release, or "" for none
  /out/summary  one line for the commit status

A push of an unregistered repo, a deleted ref or a ref that matches no trigger is a
successful no-op (active=false). A broken config fails the step, so the error is
visible in the workflow instead of silently skipping the build.

Python stdlib only. Never prints the token.
"""
import base64
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.request

REPO = os.environ["REPO"]
REF = os.environ["REF"]
SHA = os.environ["SHA"]
BEFORE = os.environ.get("BEFORE", "")
ORG = os.environ["GITHUB_ORG"]
HARBOR = os.environ.get("HARBOR_HOST", "")
HARBOR_PROJECT = os.environ["HARBOR_PROJECT"]
BUILDERS = json.loads(os.environ["BUILDERS"])  # {"vpro": "tcp://buildkitd-vpro...:1234", ...}
OUT = os.environ.get("OUT", "/out")
REPOS = os.environ.get("REPOS_DIR", "/repos")
ZERO = "0" * 40
TOKEN_FILE = os.environ.get("GITHUB_TOKEN_FILE", "/github/token")


def out(name, value):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(value if isinstance(value, str) else json.dumps(value, separators=(",", ":")))


def finish(active, summary, tests=(), images=(), helm=""):
    out("active", "true" if active else "false")
    out("tests", list(tests))
    out("images", list(images))
    out("helm", helm if helm == "" else json.dumps(helm, separators=(",", ":")))
    out("helmenabled", "false" if helm == "" else "true")
    out("summary", summary[:140])
    print(f"plan: {summary}")
    sys.exit(0)


def die(msg):
    # Still report on the commit: the exit handler posts a failure with this summary.
    out("active", "true")
    out("summary", f"CI config error: {msg}"[:140])
    for name in ("tests", "images"):
        out(name, [])
    out("helm", "")
    out("helmenabled", "false")
    print(f"plan: config error: {msg}", file=sys.stderr)
    sys.exit(2)


def glob_re(pattern):
    """GitHub Actions filter globs: * = any but '/', ** = anything, ? = one char."""
    i, rx = 0, ""
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith("**", i):
            rx += ".*"
            i += 2
            if pattern.startswith("/", i):  # "a/**/b" also matches "a/b"
                rx = rx[:-2] + "(?:.*/)?"
                i += 1
            continue
        rx += {"*": "[^/]*", "?": "[^/]"}.get(c, re.escape(c))
        i += 1
    return re.compile("^" + rx + "$")


def matches(name, globs):
    return any(glob_re(g).match(name) for g in globs or [])


def github(path, accept="application/vnd.github+json"):
    req = urllib.request.Request(f"https://api.github.com{path}")
    req.add_header("Authorization", "Bearer " + open(TOKEN_FILE).read().strip())
    req.add_header("Accept", accept)
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


# -- registry: read the revision label of an existing tag (sha-* tags are never re-pushed)
MANIFEST_TYPES = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json"])
GITHUB_USER_FILE = os.environ.get("GITHUB_USER_FILE", "/github/username")
HARBOR_USER_FILE = os.environ.get("HARBOR_USER_FILE", "/harbor/username")
HARBOR_PASSWORD_FILE = os.environ.get("HARBOR_PASSWORD_FILE", "/harbor/password")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # blob redirects are followed by hand, without the registry token


_opener = urllib.request.build_opener(_NoRedirect)


def _registry_get(url, token, accept=None):
    req = urllib.request.Request(url)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if accept:
        req.add_header("Accept", accept)
    try:
        with _opener.open(req, timeout=20) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
            with urllib.request.urlopen(e.headers["Location"], timeout=20) as r:
                return r.read()
        raise


def _registry_token(registry, repo):
    """A pull token for registry/repo: ghcr with the CI GitHub credentials, Harbor with the robot
    robot$ci (its projects are private), anything else anonymously."""
    try:
        _opener.open(urllib.request.Request(f"https://{registry}/v2/"), timeout=20)
        return ""
    except urllib.error.HTTPError as e:
        challenge = e.headers.get("WWW-Authenticate", "")
    params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    if not challenge.lower().startswith("bearer") or "realm" not in params:
        raise RuntimeError(f"{registry}: unexpected auth challenge")
    url = f"{params['realm']}?service={params.get('service', registry)}&scope=repository:{repo}:pull"
    req = urllib.request.Request(url)
    user = password = ""
    if registry == "ghcr.io" and os.path.exists(TOKEN_FILE):
        user = open(GITHUB_USER_FILE).read().strip() if os.path.exists(GITHUB_USER_FILE) else "ci"
        password = open(TOKEN_FILE).read().strip()
    elif registry == HARBOR and os.path.exists(HARBOR_PASSWORD_FILE) and os.path.exists(HARBOR_USER_FILE):
        user, password = open(HARBOR_USER_FILE).read().strip(), open(HARBOR_PASSWORD_FILE).read().strip()
    if password:
        cred = base64.b64encode(f"{user}:{password}".encode()).decode()
        req.add_header("Authorization", "Basic " + cred)
    with urllib.request.urlopen(req, timeout=20) as r:
        body = json.load(r)
    return body.get("token") or body.get("access_token") or ""


def existing_revision(ref):
    """The org.opencontainers.image.revision label of an existing image ref, "" if the tag does
    not exist. Raises on any other problem (the caller then pushes, as before)."""
    name, tag = ref.rsplit(":", 1)
    registry, repo = name.split("/", 1)
    token = _registry_token(registry, repo)
    try:
        manifest = json.loads(_registry_get(f"https://{registry}/v2/{repo}/manifests/{tag}", token, MANIFEST_TYPES))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return ""
        raise
    if "manifests" in manifest:  # an index: the first image manifest (attestations are "unknown")
        digest = next(m["digest"] for m in manifest["manifests"]
                      if (m.get("platform") or {}).get("os", "linux") != "unknown")
        manifest = json.loads(_registry_get(f"https://{registry}/v2/{repo}/manifests/{digest}", token, MANIFEST_TYPES))
    config = json.loads(_registry_get(f"https://{registry}/v2/{repo}/blobs/{manifest['config']['digest']}", token))
    labels = (config.get("config") or {}).get("Labels") or {}
    return labels.get("org.opencontainers.image.revision", "")


def keep_ref(ref):
    """False for a sha-* ref that already exists with this commit's revision label: a sha-* tag is
    pushed once and never changes (plans/staging-releases.md WP9). Anything else is pushed."""
    if not ref.rsplit(":", 1)[1].startswith("sha-"):
        return True
    try:
        rev = existing_revision(ref)
    except Exception as e:  # registry unreachable or unexpected: push, as before this check
        print(f"plan: {ref}: could not read the existing tag ({e}); pushing it")
        return True
    if rev == SHA:
        print(f"plan: {ref} exists with revision {SHA[:8]}; not pushed again")
        return False
    if rev:
        print(f"plan: {ref} exists with another revision ({rev[:8]}); pushing over it")
    return True


def changed_files():
    """Files changed by this push, or None for 'treat everything as changed'."""
    if not BEFORE or BEFORE == ZERO:
        return None
    try:
        data = json.loads(github(f"/repos/{ORG}/{REPO}/compare/{BEFORE}...{SHA}"))
    except urllib.error.HTTPError as e:
        print(f"plan: compare {BEFORE[:8]}...{SHA[:8]} failed (HTTP {e.code}); building everything")
        return None
    files = [f["filename"] for f in data.get("files", [])]
    if len(files) >= 300:  # the compare API truncates at 300 files
        return None
    return files


def read_file(path):
    return github(f"/repos/{ORG}/{REPO}/contents/{path}?ref={SHA}", "application/vnd.github.raw").decode().strip()


def safe_tag(s):
    s = re.sub(r"[^A-Za-z0-9_.-]", "-", s)
    return s[:128]


def b64(s):
    return base64.b64encode(s.encode()).decode()


def lfs_mode(value):
    """Normalize a Git LFS setting to "true", "false" or "auto" (YAML booleans arrive as bool)."""
    mode = str(value).strip().lower()
    if mode not in ("true", "false", "auto"):
        die(f"lfs must be true, false or auto, not {value!r}")
    return mode


def merge(defaults, cfg):
    res = dict(defaults)
    for k, v in cfg.items():
        if isinstance(v, dict) and isinstance(res.get(k), dict):
            res[k] = merge(res[k], v)
        else:
            res[k] = v
    return res


def main():
    os.makedirs(OUT, exist_ok=True)
    cfg_path = os.path.join(REPOS, f"{REPO}.json")
    if not os.path.exists(cfg_path):
        finish(False, f"{REPO} is not registered in charts/ci/files/repos")
    defaults = json.load(open(os.path.join(REPOS, "_defaults.json")))
    cfg = merge(defaults["repo"], json.load(open(cfg_path)))
    if not cfg.get("enabled", True):
        finish(False, f"{REPO} is disabled in its CI config")
    if not re.fullmatch(r"[0-9a-f]{40}", SHA):
        finish(False, f"no commit to build (sha {SHA!r}, ref deleted?)")

    if REF.startswith("refs/heads/"):
        kind, name = "branch", REF[len("refs/heads/"):]
        if not matches(name, cfg.get("branches")) or matches(name, cfg.get("branchesIgnore")):
            finish(False, f"branch {name} does not trigger {REPO}")
    elif REF.startswith("refs/tags/"):
        kind, name = "tag", REF[len("refs/tags/"):]
        if not matches(name, cfg.get("tags")):
            finish(False, f"tag {name} does not trigger {REPO}")
    else:
        finish(False, f"ref {REF} is not a branch or tag")

    now = datetime.datetime.now(datetime.timezone.utc)
    var = {"branch": safe_tag(name) if kind == "branch" else "", "tag": safe_tag(name) if kind == "tag" else "",
           "ref": safe_tag(name), "sha": SHA, "sha8": SHA[:8], "sha7": SHA[:7],
           "ts": now.strftime("%Y%m%d-%H%M%S"), "repo": REPO}
    changed = None
    need_changes = any(i.get("paths") for i in cfg.get("images", [])) or (cfg.get("helm") or {}).get("paths")
    if need_changes:
        changed = changed_files()

    def selected(job):
        """A job runs when its own branch/tag filters (default: the repo's) and paths match."""
        if kind == "branch" and "branches" in job and not matches(name, job["branches"]):
            return False
        if kind == "tag" and not matches(name, job.get("tags", cfg.get("tags"))):
            return False
        if job.get("paths") and changed is not None and not any(matches(f, job["paths"]) for f in changed):
            return False
        return True

    def fmt(template, extra=None):
        v = dict(var, **(extra or {}))
        try:
            return template.format(**v)
        except KeyError as e:
            die(f"unknown variable {e} in {template!r} (known: {', '.join(sorted(v))})")

    # -- tests
    tests = []
    for t in cfg.get("tests", []):
        if not selected(t):
            continue
        for k in ("name", "image", "run"):
            if not t.get(k):
                die(f"test without {k}: {t}")
        if t.get("dind"):
            # A Docker daemon would give repo code root on the build node (and the
            # credentials of every pod there). Not supported; see README.md.
            die(f"test {t['name']}: dind is not supported")
        tests.append({"name": t["name"], "image": t["image"], "workdir": t.get("workdir", "."),
                      "script": b64(t["run"]), "shell": t.get("shell", "sh"),
                      "cpu": str(t.get("cpu", defaults["test"]["cpu"])),
                      "memory": str(t.get("memory", defaults["test"]["memory"])),
                      "depth": str(t.get("depth", 1)), "lfs": lfs_mode(t.get("lfs", False))})

    # -- images
    images = []
    for img in cfg.get("images", []):
        if not selected(img):
            continue
        if not img.get("name"):
            die(f"image without name: {img}")
        extra = {}
        if img.get("versionFile"):
            extra["version"] = safe_tag(read_file(img["versionFile"]))
        if kind == "branch":
            tags = [fmt(t, extra) for t in img.get("tagTemplates", defaults["image"]["branchTags"])]
            if name in img.get("latest", defaults["image"]["latestBranches"]):
                tags.append("latest")
        else:
            tags = [fmt(t, extra) for t in img.get("tagTagTemplates", defaults["image"]["tagTags"])]
        tags = list(dict.fromkeys(t for t in tags if t))
        repos = [f"{HARBOR}/{HARBOR_PROJECT}/{img['name']}"] if HARBOR else []  # HARBOR "" = Harbor off
        if img.get("ghcr", cfg.get("ghcr", True)) or not HARBOR:
            repos.append(f"ghcr.io/{ORG}/{img['name']}")
        refs = [ref for ref in (f"{r}:{t}" for r in repos for t in tags) if keep_ref(ref)]
        if not refs:
            print(f"plan: image {img['name']}: every tag exists for this commit; not built")
            continue
        context = img.get("context", ".").strip("/") or "."
        dockerfile = img.get("dockerfile", f"{context}/Dockerfile" if context != "." else "Dockerfile")
        dfdir, dfname = os.path.split(dockerfile)
        platforms = img.get("platforms", defaults["image"]["platforms"])
        args = ["--frontend=dockerfile.v0",
                f"--local=context=/src/{context}",
                f"--local=dockerfile=/src/{dfdir or '.'}",
                f"--opt=filename={dfname}",
                f"--opt=platform={','.join(platforms)}"]
        if img.get("target"):
            args.append(f"--opt=target={img['target']}")
        build_args = dict(img.get("buildArgs") or {})
        if kind == "tag":
            build_args.update(img.get("tagBuildArgs") or {})
        for k, v in build_args.items():
            args.append(f"--opt=build-arg:{k}={fmt(str(v), extra)}")
        for k, v in {"org.opencontainers.image.source": f"https://github.com/{ORG}/{REPO}",
                     "org.opencontainers.image.revision": SHA,
                     "org.opencontainers.image.created": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                     "org.opencontainers.image.ref.name": name}.items():
            args.append(f"--opt=label:{k}={v}")
        args.append('--output=type=image,"name=' + ",".join(refs) + '",push=true')
        builder = img.get("builder", cfg.get("builder", defaults["builder"]))
        order = [builder] + [b for b in BUILDERS if b != builder]
        images.append({"name": img["name"], "refs": " ".join(refs), "args": b64("\n".join(args)),
                       "prebuild": b64(img.get("preBuild", "")),
                       "builders": " ".join(BUILDERS[b] for b in order if b in BUILDERS),
                       "depth": str(img.get("depth", 1)), "lfs": lfs_mode(img.get("lfs", "auto")),
                       "submodules": str(bool(img.get("submodules", False))).lower(),
                       "platforms": ",".join(platforms)})

    # -- helm chart release (chart-releaser, as helm/chart-releaser-action)
    helm = ""
    h = cfg.get("helm")
    if h and kind == "branch":
        mode = "release" if name in h.get("release", []) else "beta" if name in h.get("beta", []) else ""
        if mode and selected(h):
            action = h.get("crAction", defaults["helm"]["crAction"])
            sums = defaults["helm"]["crShaSums"]
            if action not in sums:
                die(f"helm.crAction {action} has no pinned cr.sh checksum (known: {', '.join(sums)})")
            helm = {"mode": mode, "chartsDir": h.get("chartsDir", "charts"), "crAction": action,
                    "crSha256": sums[action]["crSh"], "cr": sums[action]["cr"], "crTarSha256": sums[action]["crTar"],
                    "betaVersionCheck": str(h.get("betaVersionCheck", True)).lower(),
                    "skipExisting": str(h.get("skipExisting", False)).lower(),
                    "markAsLatest": str(h.get("markAsLatest", True)).lower(),
                    "pagesBranch": h.get("pagesBranch", "")}

    jobs = []
    if tests:
        jobs.append(f"{len(tests)} test")
    if images:
        jobs.append(f"{len(images)} image")
    if helm:
        jobs.append(f"chart {helm['mode']}")
    if not jobs:
        finish(False, f"{kind} {name}: no job matches this push")
    finish(True, f"{kind} {name}: " + ", ".join(jobs), tests, images, helm)


if __name__ == "__main__":
    main()
