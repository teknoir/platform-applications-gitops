#!/usr/bin/env python3
"""ci poll: start a pipeline for every new commit on a registered repo's branches/tags.

Runs every few minutes (CronWorkflow ci-poll). For each enabled repo in the registry
(/repos) it lists the branch heads (and tag refs when the repo builds tags) with
conditional requests: an unchanged repo answers 304, which does not count against
GitHub's rate limit. Every ref whose sha changed since the last poll, and that matches
the repo's branch/tag filters, gets a ci-dispatch Workflow (repo, ref, sha, before).

State (last seen sha per ref, ETags) lives in ConfigMap ci-poll-state. A repo seen for
the first time is only recorded, never built, so registering a repo does not rebuild
all of its branches. Polling instead of webhooks keeps the cluster closed to inbound
traffic from the internet.

Env: GITHUB_ORG, NAMESPACE, STATE_CONFIGMAP, REPOS_DIR, MAX_SUBMIT. Files:
/github/token, the pod's ServiceAccount token (ci-poller). Python stdlib only.
"""
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

ORG = os.environ["GITHUB_ORG"]
NS = os.environ["NAMESPACE"]
STATE_CM = os.environ.get("STATE_CONFIGMAP", "ci-poll-state")
REPOS = os.environ.get("REPOS_DIR", "/repos")
MAX_SUBMIT = int(os.environ.get("MAX_SUBMIT", "20"))
TOKEN = open("/github/token").read().strip()
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
ZERO = "0" * 40


def glob_re(pattern):  # same semantics as plan.py
    i, rx = 0, ""
    while i < len(pattern):
        if pattern.startswith("**", i):
            rx += ".*"
            i += 2
            if pattern.startswith("/", i):
                rx = rx[:-2] + "(?:.*/)?"
                i += 1
            continue
        c = pattern[i]
        rx += {"*": "[^/]*", "?": "[^/]"}.get(c, re.escape(c))
        i += 1
    return re.compile("^" + rx + "$")


def matches(name, globs):
    return any(glob_re(g).match(name) for g in globs or [])


def k8s(method, path, body=None, content_type="application/json"):
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")
    req = urllib.request.Request(K8S + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", "Bearer " + open(f"{SA}/token").read().strip())
    req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
        return json.loads(r.read())


def github_refs(repo, kind, etag):
    """(status, etag, {ref: sha}) for refs/heads or refs/tags; status 304 = unchanged."""
    refs, url, first_etag = {}, f"https://api.github.com/repos/{ORG}/{repo}/git/matching-refs/{kind}?per_page=100", None
    while url:
        req = urllib.request.Request(url)
        req.add_header("Authorization", "Bearer " + TOKEN)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if etag and first_etag is None:
            req.add_header("If-None-Match", etag)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                if first_etag is None:
                    first_etag = r.headers.get("ETag", "")
                for item in json.loads(r.read()):
                    # Annotated tags point at a tag object; it is peeled to its commit only
                    # when the ref changed (see peel()).
                    refs[item["ref"]] = item["object"]["sha"] + ("^tag" if item["object"]["type"] == "tag" else "")
                m = re.search(r'<([^>]+)>;\s*rel="next"', r.headers.get("Link", ""))
                url = m.group(1) if m else None
        except urllib.error.HTTPError as e:
            if e.code == 304:
                return 304, etag, None
            raise
    return 200, first_etag, refs


def peel(repo, sha):
    """Commit sha of an annotated tag object ("<sha>^tag"), else sha itself."""
    if not sha.endswith("^tag"):
        return sha
    req = urllib.request.Request(f"https://api.github.com/repos/{ORG}/{repo}/git/tags/{sha[:-4]}")
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())["object"]["sha"]


def submit(repo, ref, sha, before):
    wf = {"apiVersion": "argoproj.io/v1alpha1", "kind": "Workflow",
          "metadata": {"generateName": "ci-dispatch-", "namespace": NS,
                       "labels": {"teknoir.org/repo": repo[:63], "teknoir.org/trigger": "poll"}},
          "spec": {"workflowTemplateRef": {"name": "ci-dispatch"},
                   "arguments": {"parameters": [{"name": "repo", "value": repo}, {"name": "ref", "value": ref},
                                                {"name": "sha", "value": sha}, {"name": "before", "value": before}]}}}
    created = k8s("POST", f"/apis/argoproj.io/v1alpha1/namespaces/{NS}/workflows", wf)
    print(f"{repo}: {ref} {before[:8]}..{sha[:8]} -> {created['metadata']['name']}")


def main():
    try:
        cm = k8s("GET", f"/api/v1/namespaces/{NS}/configmaps/{STATE_CM}")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
        # Not in the chart on purpose: ArgoCD would reset the state on every sync.
        cm = k8s("POST", f"/api/v1/namespaces/{NS}/configmaps",
                 {"apiVersion": "v1", "kind": "ConfigMap",
                  "metadata": {"name": STATE_CM, "labels": {"app.kubernetes.io/part-of": "teknoir-ci"}},
                  "data": {"state.json": "{}"}})
    state = json.loads((cm.get("data") or {}).get("state.json") or "{}")
    defaults = json.load(open(os.path.join(REPOS, "_defaults.json")))["repo"]
    submitted, errors = 0, 0
    names = sorted(f[:-5] for f in os.listdir(REPOS) if f.endswith(".json") and not f.startswith("_"))
    for repo in names:
        cfg = dict(defaults, **json.load(open(os.path.join(REPOS, f"{repo}.json"))))
        if not cfg.get("enabled", True):
            state.pop(repo, None)
            continue
        rs = state.setdefault(repo, {"refs": {}, "etags": {}})
        kinds = ["heads"] + (["tags"] if cfg.get("tags") else [])
        for kind in kinds:
            try:
                status, etag, refs = github_refs(repo, kind, rs["etags"].get(kind))
            except urllib.error.HTTPError as e:
                errors += 1
                print(f"{repo}: ERROR listing refs/{kind}: HTTP {e.code}")
                continue
            if status == 304:
                continue
            rs["etags"][kind] = etag
            known = {r: s for r, s in rs["refs"].items() if r.startswith(f"refs/{kind}/")}
            first = f"seen-{kind}" not in rs
            for ref, sha in sorted(refs.items()):
                old = known.get(ref)
                rs["refs"][ref] = sha
                if first or old == sha:
                    continue
                name = ref.split("/", 2)[2]
                wanted = (matches(name, cfg.get("branches")) and not matches(name, cfg.get("branchesIgnore"))) \
                    if kind == "heads" else matches(name, cfg.get("tags"))
                if not wanted:
                    continue
                if submitted >= MAX_SUBMIT:
                    rs["refs"][ref] = old or ZERO  # retried on the next poll
                    continue
                try:
                    submit(repo, ref, peel(repo, sha), peel(repo, old) if old and old != ZERO else ZERO)
                    submitted += 1
                except urllib.error.HTTPError as e:
                    errors += 1
                    rs["refs"][ref] = old or ZERO
                    print(f"{repo}: ERROR submitting {ref}: HTTP {e.code}")
            for ref in set(known) - set(refs):  # deleted branches/tags
                del rs["refs"][ref]
            rs[f"seen-{kind}"] = True
            if first:
                print(f"{repo}: refs/{kind} recorded ({len(refs)} refs, nothing built on first sight)")
    for repo in set(state) - set(names):
        del state[repo]
    k8s("PATCH", f"/api/v1/namespaces/{NS}/configmaps/{STATE_CM}",
        {"data": {"state.json": json.dumps(state, sort_keys=True)}}, "application/merge-patch+json")
    print(f"poll: {len(names)} repos, {submitted} pipelines started, {errors} errors")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
