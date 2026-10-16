#!/usr/bin/env python3
"""github-sync: make GitHub Actions match the CI repo registry (charts/ci/files/repos).

For every registered repo whose config says `githubActions: disable`, the GitHub
Actions workflow files listed in `actionsWorkflows` are disabled: the pipeline runs
here now, and the Actions copy would run in parallel (public repos: duplicate pushes
and chart releases) or fail on billing (private repos). `githubActions: enable`
re-enables them (the way back); `keep` leaves them alone. Only the listed files are
touched.

Env: GITHUB_ORG, REPOS_DIR. Files: /github/token. Never prints the token.
"""
import json
import os
import sys
import urllib.error
import urllib.request

ORG = os.environ["GITHUB_ORG"]
REPOS = os.environ.get("REPOS_DIR", "/repos")
TOKEN = open("/github/token").read().strip()
errors = 0


def gh(method, path, body=None):
    req = urllib.request.Request("https://api.github.com" + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw.strip() else None


def sync_repo(repo, cfg):
    mode = cfg.get("githubActions", "keep")
    if mode in ("disable", "enable"):
        workflows = (gh("GET", f"/repos/{ORG}/{repo}/actions/workflows?per_page=100") or {}).get("workflows", [])
        wanted = set(cfg.get("actionsWorkflows") or [])
        for w in workflows:
            file = os.path.basename(w.get("path", ""))
            if file not in wanted:
                continue
            active = w.get("state") == "active"
            if mode == "disable" and active:
                gh("PUT", f"/repos/{ORG}/{repo}/actions/workflows/{w['id']}/disable")
                print(f"{repo}: GitHub Actions workflow {file} disabled")
            elif mode == "enable" and not active:
                gh("PUT", f"/repos/{ORG}/{repo}/actions/workflows/{w['id']}/enable")
                print(f"{repo}: GitHub Actions workflow {file} enabled")


def main():
    global errors
    defaults = json.load(open(os.path.join(REPOS, "_defaults.json")))["repo"]
    names = sorted(f[:-5] for f in os.listdir(REPOS) if f.endswith(".json") and not f.startswith("_"))
    for repo in names:
        cfg = dict(defaults, **json.load(open(os.path.join(REPOS, f"{repo}.json"))))
        try:
            sync_repo(repo, cfg)
        except urllib.error.HTTPError as e:
            errors += 1
            print(f"{repo}: ERROR HTTP {e.code} {e.read()[:200].decode(errors='replace')}")
    print(f"github-sync: {len(names)} repos, {errors} errors")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
