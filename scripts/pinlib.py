"""Shared logic of the pin tooling (scripts/pin-image).

Python 3 stdlib. Everything that touches a cluster or git goes through `Sys` so the tests can replace it.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
from dataclasses import dataclass

STAGING_CONTEXTS = ("r415",)   # staging is r415 since the move (plans/staging-on-r415.md); vpro is the CI cluster now
CONTEXT = os.environ.get("STAGING_CONTEXT") or "r415"   # default context; --context overrides it
NAMESPACE = "teknoir-system"
ROOT_APP = "app-of-apps"
RELEASER_NAME = "staging-releaser"
RELEASER_SA = f"system:serviceaccount:teknoir-system:{RELEASER_NAME}"
GITHUB_REPO = "teknoir/platform-applications-gitops"
# The gitops working branch is read from origin/HEAD (the rename to main at the CI v4 cut-over),
# never hard-coded; this is the fallback when origin/HEAD is missing (e.g. a bare remote without
# a HEAD, or a checkout that never fetched it).
GITOPS_BRANCH_FALLBACK = "main"


class Refuse(Exception):
    """A guard refused the action. The message says why and what to do instead."""


# ---------------------------------------------------------------------------------------------
# System access (replaced in tests)
# ---------------------------------------------------------------------------------------------
@dataclass
class Result:
    rc: int
    out: str
    err: str


class Sys:
    """Runs commands. Tests subclass or replace `run`."""

    def run(self, argv: list[str], *, cwd: str | None = None, input: str | None = None,
            check: bool = True, timeout: int | None = None) -> Result:
        p = subprocess.run(argv, cwd=cwd, input=input, capture_output=True, text=True, timeout=timeout)
        if check and p.returncode != 0:
            raise RuntimeError(f"{' '.join(shlex.quote(a) for a in argv)} failed ({p.returncode}): "
                               f"{(p.stderr or p.stdout).strip()[:500]}")
        return Result(p.returncode, p.stdout, p.stderr)


def gitops_branch(sys_: Sys | None = None, repo: str | None = None) -> str:
    """The gitops working branch, short name (the `--base`, the fetch ref, targetRevision).

    Read from the remote's HEAD (`git symbolic-ref --short refs/remotes/origin/HEAD` -> "origin/main"),
    so the rename `teknoir-cloud` -> `main` at the CI v4 cut-over needs no change here. Falls back to
    GITOPS_BRANCH_FALLBACK when origin/HEAD is missing or points nowhere."""
    s = sys_ or Sys()
    git = ["git", *(["-C", repo] if repo else [])]
    r = s.run([*git, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], check=False)
    ref = (r.out or "").strip() if r.rc == 0 else ""
    if ref.startswith("origin/"):
        ref = ref[len("origin/"):]
    # a dangling origin/HEAD (it names a branch the last fetch did not bring) counts as missing
    if ref and s.run([*git, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{ref}"], check=False).rc == 0:
        return ref
    return GITOPS_BRANCH_FALLBACK


# ---------------------------------------------------------------------------------------------
# Guards
# ---------------------------------------------------------------------------------------------
def guard_context(ctx: str) -> str:
    """The kubectl context must be one of STAGING_CONTEXTS (r415); production names are refused outright."""
    if re.search(r"online|eks|prod", ctx or "", re.I):
        raise Refuse(f"context '{ctx}' looks like production: the pin tooling never touches it")
    if ctx not in STAGING_CONTEXTS:
        raise Refuse(f"context must be one of {', '.join(STAGING_CONTEXTS)}, got '{ctx}'")
    return ctx


class Kube:
    """kubectl with --context <staging context> always set; --as only for the releaser identity."""

    def __init__(self, sys_: Sys, context: str = CONTEXT):
        self.sys = sys_
        self.context = guard_context(context)

    def base(self, as_releaser: bool = False) -> list[str]:
        a = ["kubectl", "--context", self.context]
        if as_releaser:
            a.append(f"--as={RELEASER_SA}")
        return a

    def run(self, args: list[str], *, as_releaser: bool = False, check: bool = True,
            input: str | None = None) -> Result:
        return self.sys.run(self.base(as_releaser) + args, check=check, input=input)

    def get_json(self, args: list[str]) -> dict:
        return json.loads(self.run(["get", *args, "-o", "json"]).out)

    def root(self) -> dict:
        return self.get_json(["-n", NAMESPACE, "application", ROOT_APP])

    def applications(self) -> list[dict]:
        return self.get_json(["-n", NAMESPACE, "applications"]).get("items", [])


# ---------------------------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------------------------
class Git:
    def __init__(self, sys_: Sys, repo: str):
        self.sys, self.repo = sys_, repo

    def run(self, *args: str, check: bool = True) -> str:
        return self.sys.run(["git", "-C", self.repo, *args], check=check).out.strip()

    def rev(self, ref: str) -> str:
        return self.run("rev-parse", "--verify", f"{ref}^{{commit}}")

    def first_parent(self, ref: str) -> list[str]:
        return self.run("rev-list", "--first-parent", ref).split()

    def is_ancestor(self, a: str, b: str) -> bool:
        return self.sys.run(["git", "-C", self.repo, "merge-base", "--is-ancestor", a, b], check=False).rc == 0


# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
def repo_root_of(path: str) -> str:
    return subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                          check=True).stdout.strip()
