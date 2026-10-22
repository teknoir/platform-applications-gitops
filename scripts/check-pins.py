#!/usr/bin/env python3
"""Release lint for staging releases (plans/staging-releases.md, "enforcement" 1).

Checks the rendered manifests of a release (scripts/staging-render.sh output, or any YAML files):

  errors, from day 1
    revision-not-release   a gitops Application whose targetRevision is not the release SHA
    release-unset          project teknoir-cloud but no release SHA given
    chart-dependency-range a chart dependency that is a range, not an exact version
    exception-expired      an exception of release-policy.yaml past its date
    app-not-roundtrip-stable  a rendered Application with a field that ArgoCD's Go types drop when they write the
                           object back (an empty `sources: []`, an empty-string/null/empty-list omitempty field)
  errors once release-policy.yaml has `images: deny`, otherwise warnings
    first-party-unpinned   a first-party image that is not repo:<tag>@sha256:<digest>
    first-party-latest     the same, with :latest or no tag
    hub-audience-unchecked a wg-hub rendered with KEYCLOAK_AUDIENCE_MODE (transition or enforce) whose image tag is
                           NOT listed in release-policy.yaml `audience_hub_tags` (an allowlist of the tags known to
                           have the audience check; any other hub ignores the env, so enforce would only look
                           enforced and transition would never produce the audience metric the plan gates on)
    portal-controller-unchecked  a render in which a portal service account (profile-controller PORTAL_SERVICE_ACCOUNTS) no
                           longer has the teknoir-admin ClusterRoleBinding, i.e. its teamspace rights come only from the
                           teknoir-portal RoleBindings that profile-controller writes, but the profile-controller image
                           tag is NOT listed in release-policy.yaml `portal_profile_controller_tags` (builds that
                           contain the portal code), or no profile-controller Deployment is rendered at all
  warnings
    third-party-no-digest  a third-party image without a digest (exact version tags are fine)
    cr-revision            a teknoir.org DeviceApplicationSet/Device/Robot/RobotType with a revision that is not 40-hex
    profile-version        a Profile with spec.plugins[].spec.version or *Version/image* values
    floating               images that restarts or hook reruns re-pull (pullPolicy Always or no digest)
  info
    excepted               a first-party image covered by an unexpired exception

Usage: check-pins.py [--policy FILE] [--release SHA] [--project teknoir-cloud] [--repo-root DIR]
                     [--today YYYY-MM-DD] [--json] [--quiet] PATH...
Exit status 1 when there is any error. Python 3 stdlib + PyYAML.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
from dataclasses import dataclass, field, asdict

import yaml

SHA40 = re.compile(r"^[0-9a-f]{40}$")
# repo:<tag>@sha256:<digest>, or repo@sha256:<digest> (charts with a separate digest value render no tag)
PINNED = re.compile(r"(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$")
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")
GITOPS_SUFFIX = "platform-applications-gitops"
CR_KINDS = {"DeviceApplicationSet", "Device", "Robot", "RobotType"}
POD_PATHS = {  # kind -> path to the PodSpec
    "Pod": ("spec",),
    "Deployment": ("spec", "template", "spec"),
    "StatefulSet": ("spec", "template", "spec"),
    "DaemonSet": ("spec", "template", "spec"),
    "ReplicaSet": ("spec", "template", "spec"),
    "Job": ("spec", "template", "spec"),
    "CronJob": ("spec", "jobTemplate", "spec", "template", "spec"),
}
DEFAULT_PREFIXES = ["ghcr.io/teknoir/", "harbor.teknoir.cloud/", "docker.io/tekn0ir/"]


@dataclass
class Finding:
    level: str            # error | warn | info
    code: str
    message: str
    where: str = ""

    def line(self) -> str:
        w = f" [{self.where}]" if self.where else ""
        return f"{self.level.upper():5} {self.code}: {self.message}{w}"


@dataclass
class ImageRef:
    image: str
    pull_policy: str
    where: str            # Kind/name container

    @property
    def digest_pinned(self) -> bool:
        return bool(DIGEST.search(self.image))


# ---------------------------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------------------------
class _Loader(yaml.SafeLoader):
    """SafeLoader that accepts a bare '=' (YAML 1.1 'value' tag), which the prometheus CRDs contain."""


_Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: "=")


def load_docs(paths: list[str]) -> list[tuple[str, dict]]:
    """(file, document) for every YAML document under the paths (files or directories)."""
    files: list[str] = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                files += [os.path.join(root, n) for n in sorted(names) if n.endswith((".yaml", ".yml"))]
        else:
            files.append(p)
    docs = []
    for f in sorted(files):
        with open(f) as fh:
            try:
                for d in yaml.load_all(fh, Loader=_Loader):
                    if isinstance(d, dict):
                        docs.append((f, d))
            except yaml.YAMLError as e:
                raise SystemExit(f"{f}: not valid YAML: {e}")
    return docs


def load_policy(path: str | None) -> dict:
    pol = {"images": "warn", "cr_revisions": "warn", "first_party_prefixes": DEFAULT_PREFIXES, "exceptions": [], "rollback_floor": "",
           "audience_hub_tags": [], "portal_profile_controller_tags": []}
    if path:
        with open(path) as fh:
            pol.update(yaml.safe_load(fh) or {})
    if pol["images"] not in ("warn", "deny"):
        raise SystemExit(f"release-policy: images must be warn or deny, got {pol['images']!r}")
    if pol["cr_revisions"] not in ("warn", "deny"):
        raise SystemExit(f"release-policy: cr_revisions must be warn or deny, got {pol['cr_revisions']!r}")
    return pol


# ---------------------------------------------------------------------------------------------
# Image collection
# ---------------------------------------------------------------------------------------------
def _dig(d: dict, path: tuple[str, ...]):
    for k in path:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def collect_images(docs: list[tuple[str, dict]]) -> list[ImageRef]:
    out: list[ImageRef] = []
    for _, d in docs:
        kind = d.get("kind")
        path = POD_PATHS.get(kind)
        if not path:
            continue
        spec = _dig(d, path)
        if not isinstance(spec, dict):
            continue
        name = (d.get("metadata") or {}).get("name", "?")
        ns = (d.get("metadata") or {}).get("namespace", "")
        for key in ("initContainers", "containers", "ephemeralContainers"):
            for c in spec.get(key) or []:
                img = c.get("image")
                if img:
                    out.append(ImageRef(str(img), str(c.get("imagePullPolicy", "")),
                                        f"{kind}/{ns + '/' if ns else ''}{name} {c.get('name', '')}"))
    return out


def is_first_party(image: str, prefixes: list[str]) -> bool:
    return any(image.startswith(p) for p in prefixes)


def image_tag(image: str) -> str | None:
    """The tag of repo:tag[@digest] ('' when there is none)."""
    ref = image.split("@", 1)[0]
    last = ref.rsplit("/", 1)[-1]
    return last.split(":", 1)[1] if ":" in last else ""


def image_without_digest(image: str) -> str:
    return image.split("@", 1)[0]


# ---------------------------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------------------------
def _date(v) -> dt.date:
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    return dt.date.fromisoformat(str(v))


def exception_matches(exc: dict, image: str) -> bool:
    pat = str(exc.get("image", ""))
    ref = image_without_digest(image)
    return ref.startswith(pat[:-1]) if pat.endswith("*") else ref == pat


def check_exceptions(policy: dict, today: dt.date) -> list[Finding]:
    out = []
    for exc in policy.get("exceptions") or []:
        missing = [k for k in ("image", "reason", "owner", "expires") if not exc.get(k)]
        if missing:
            out.append(Finding("error", "exception-invalid", f"exception {exc.get('image')!r} lacks {missing}"))
            continue
        exp = _date(exc["expires"])
        if exp < today:
            out.append(Finding("error", "exception-expired",
                               f"exception for {exc['image']} expired {exp} (owner {exc['owner']}): "
                               f"{exc['reason']}. Pin the image or extend the date in a reviewed PR"))
    return out


# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------
def check_images(images: list[ImageRef], policy: dict, today: dt.date, verbose: bool = False) -> list[Finding]:
    prefixes = policy.get("first_party_prefixes") or DEFAULT_PREFIXES
    level = "error" if policy.get("images") == "deny" else "warn"
    excs = [e for e in (policy.get("exceptions") or []) if e.get("expires") and _date(e["expires"]) >= today and e.get("image")]
    out: list[Finding] = []
    floating: dict[str, list[str]] = {}
    seen_third: dict[str, list[str]] = {}
    for im in images:
        if im.image == "auto":      # istio's injection placeholder
            continue
        if is_first_party(im.image, prefixes):
            if PINNED.search(im.image):
                continue
            exc = next((e for e in excs if exception_matches(e, im.image)), None)
            tag = image_tag(im.image)
            if exc:
                out.append(Finding("info", "excepted", f"{im.image} floats by exception until {_date(exc['expires'])} "
                                   f"(owner {exc['owner']}: {exc['reason']})", im.where))
                floating.setdefault(im.image, []).append(im.where)
                continue
            code = "first-party-latest" if tag in ("", "latest") else "first-party-unpinned"
            out.append(Finding(level, code, f"{im.image} is not <tag>@sha256:<digest>", im.where))
            floating.setdefault(im.image, []).append(im.where)
        else:
            if not im.digest_pinned:
                seen_third.setdefault(im.image, []).append(im.where)
                if image_tag(im.image) in ("", "latest") or im.pull_policy == "Always":
                    floating.setdefault(im.image, []).append(im.where)
    exact = []
    for img, wheres in sorted(seen_third.items()):
        tag = image_tag(img)
        if tag in ("", "latest"):
            out.append(Finding("warn", "third-party-no-digest", f"{img} (floating tag)", ", ".join(sorted(set(wheres)))))
        elif verbose:
            out.append(Finding("warn", "third-party-no-digest", img, ", ".join(sorted(set(wheres)))))
        else:
            exact.append(img)
    if exact:
        out.append(Finding("warn", "third-party-no-digest",
                           f"{len(exact)} third-party image(s) with an exact version tag but no digest (-v lists them)"))
    if floating:
        out.append(Finding("warn", "floating",
                           f"{len(floating)} image(s) will be re-pulled by restarts or hook reruns: "
                           + ", ".join(sorted(floating))))
    return out


def check_hub_audience(docs: list[tuple[str, dict]], policy: dict) -> list[Finding]:
    """A wg-hub that renders KEYCLOAK_AUDIENCE_MODE must run an image that has the audience check.

    The hub image is pinned by hand (scripts/pin-image). A pin that predates the check ignores KEYCLOAK_AUDIENCE and
    KEYCLOAK_AUDIENCE_MODE, so `enforce` would be reported while the downscoped main token (the one Backstage sees)
    still opens hub sessions. This is an allowlist and fails closed: only the exact tags listed in the policy as
    `audience_hub_tags` are known to have the check, any other tag (an old main build, a branch build, a digest-only
    reference) is an error in both modes. An empty or missing list allows no tag.
    """
    known = {str(t) for t in (policy.get("audience_hub_tags") or [])}
    out: list[Finding] = []
    for _, d in docs:
        path = POD_PATHS.get(d.get("kind"))
        spec = _dig(d, path) if path else None
        if not isinstance(spec, dict):
            continue
        name = (d.get("metadata") or {}).get("name", "?")
        for c in spec.get("containers") or []:
            mode = next((e.get("value") for e in c.get("env") or []
                         if isinstance(e, dict) and e.get("name") == "KEYCLOAK_AUDIENCE_MODE"), None)
            img = str(c.get("image") or "")
            if mode is None or (image_tag(img) or "") in known:
                continue
            where = f"{d.get('kind')}/{name} {c.get('name', '')}"
            hint = ("re-pin wg-hub to the wg-tunnel ztna-audience commit or later with scripts/pin-image and list its "
                    "tag in release-policy.yaml audience_hub_tags")
            out.append(Finding("error", "hub-audience-unchecked",
                               f"KEYCLOAK_AUDIENCE_MODE={mode} but {img} is not listed in release-policy.yaml "
                               f"audience_hub_tags (hubs known to have the audience check): it ignores the setting; "
                               f"{hint}", where))
    return out


def check_portal_binding(docs: list[tuple[str, dict]], policy: dict) -> list[Finding]:
    """The Backstage API service account must not lose teknoir-admin before profile-controller can bind it per teamspace.

    profile-controller writes the RoleBinding teknoir-portal into every teamspace when PORTAL_SERVICE_ACCOUNTS is set
    (charts/profile-controller config.portal); an older image ignores the setting. A render in which a listed service
    account has no ClusterRoleBinding to teknoir-admin any more (backstage-sa R2) depends on that code being live, so
    the profile-controller image tag must be one of `portal_profile_controller_tags` in the policy: exact tags without
    the digest, built from a commit that contains the portal code. Fails closed: an unlisted tag, a missing Deployment
    or an empty list is an error. Renders that still bind the service account to teknoir-admin (backstage-sa R1) are
    not affected. The live check that every Profile namespace HAS the RoleBinding is in scripts/staging-release.
    """
    sas: set[str] = set()
    for _, d in docs:
        if d.get("kind") == "ConfigMap":
            val = ((d.get("data") or {}).get("PORTAL_SERVICE_ACCOUNTS") or "")
            sas |= {x.strip() for x in str(val).split(",") if x.strip()}
    if not sas:
        return []
    admin_bound: set[str] = set()
    for _, d in docs:
        if d.get("kind") == "ClusterRoleBinding" and (d.get("roleRef") or {}).get("name") == "teknoir-admin":
            for sub in d.get("subjects") or []:
                if isinstance(sub, dict) and sub.get("kind") == "ServiceAccount":
                    admin_bound.add(f"{sub.get('namespace', '')}/{sub.get('name', '')}")
    portal_only = sorted(sas - admin_bound)
    if not portal_only:
        return []
    known = {str(t) for t in (policy.get("portal_profile_controller_tags") or [])}
    hint = ("build and pin a profile-controller that contains the portal commit (profile-controller branch "
            "backstage-sa-teamspace-binding: 'Bind the portal service account into each teamspace' and 'Replace a "
            "RoleBinding whose roleRef changed instead of updating it') with scripts/pin-image, and list its tag in "
            "release-policy.yaml portal_profile_controller_tags")
    out: list[Finding] = []
    seen = False
    for _, d in docs:
        path = POD_PATHS.get(d.get("kind"))
        spec = _dig(d, path) if path else None
        if d.get("kind") != "Deployment" or not isinstance(spec, dict):
            continue
        name = (d.get("metadata") or {}).get("name", "?")
        for c in spec.get("containers") or []:
            img = str(c.get("image") or "")
            if image_without_digest(img).rsplit("/", 1)[-1].split(":", 1)[0] != "profile-controller":
                continue
            seen = True
            if (image_tag(img) or "") not in known:
                out.append(Finding("error", "portal-controller-unchecked",
                                   f"{', '.join(portal_only)} lost teknoir-admin, so its teamspace rights come only from the "
                                   f"teknoir-portal RoleBindings, but {img} is not listed in release-policy.yaml "
                                   f"portal_profile_controller_tags (builds with the portal code): {hint}",
                                   f"Deployment/{name} {c.get('name', '')}"))
    if not seen:
        out.append(Finding("error", "portal-controller-unchecked",
                           f"{', '.join(portal_only)} lost teknoir-admin but no profile-controller Deployment is rendered, "
                           "so nothing writes the teknoir-portal RoleBindings"))
    return out


def gitops_apps(docs: list[tuple[str, dict]]) -> list[dict]:
    apps = []
    for _, d in docs:
        if d.get("kind") != "Application":
            continue
        src = (d.get("spec") or {}).get("source") or {}
        if str(src.get("repoURL", "")).rstrip("/").endswith(GITOPS_SUFFIX):
            apps.append(d)
    return apps


def check_applications(docs: list[tuple[str, dict]], release: str | None, project: str) -> list[Finding]:
    out = []
    apps = gitops_apps(docs)
    if project == "teknoir-cloud" and not release:
        out.append(Finding("error", "release-unset", "no release SHA given for project teknoir-cloud (staging must follow a release)"))
        return out
    if release and not SHA40.match(release):
        out.append(Finding("error", "release-unset", f"release '{release}' is not a 40-hex commit SHA"))
        return out
    for a in apps:
        tr = a["spec"]["source"].get("targetRevision", "")
        if release and tr != release:
            out.append(Finding("error", "revision-not-release",
                               f"targetRevision is '{tr}', want the release {release[:12]}", f"Application/{a['metadata']['name']}"))
    return out


# Application fields that ArgoCD's Go types (v3.5.1, pkg/apis/application/v1alpha1) serialize even when empty
# (no `omitempty`); an empty value there survives a round trip. Everything else empty is dropped.
_KEEP_EMPTY_STRING = {"project", "repoURL", "kind"}
# free-form content that is kept as written (map values, raw JSON)
_OPAQUE = {"annotations", "labels", "valuesObject", "info"}


def _roundtrip_unstable(node, path: str, key: str = "") -> list[str]:
    """Paths in an Application whose value ArgoCD would drop when it writes the object back: null, an empty list,
    an empty string (except the few non-omitempty keys), an empty labels/annotations map."""
    bad: list[str] = []
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}" if path else str(k)
            if k == "creationTimestamp":
                continue
            if v is None or v == [] or (isinstance(v, str) and v == "" and k not in _KEEP_EMPTY_STRING) \
                    or (v == {} and k in ("labels", "annotations")):
                bad.append(p)
            elif k not in _OPAQUE:
                bad += _roundtrip_unstable(v, p, str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            p = f"{path}[{i}]"
            if v is None or (isinstance(v, str) and v == "" and key not in _KEEP_EMPTY_STRING):
                bad.append(p)
            else:
                bad += _roundtrip_unstable(v, p, key)
    return bad


def check_roundtrip(docs: list[tuple[str, dict]]) -> list[Finding]:
    """argocd-server writes Sync and Terminate as a full Update of the Application through its Go types, so every
    omitempty field that is stored empty is dropped by the first UI/CLI sync. That changes spec on the wire, and
    the release guard (charts/release-guard) would judge such a sync as a spec change. Hence the rendered
    Applications must already be what ArgoCD would write back."""
    out = []
    for _, d in docs:
        if d.get("kind") != "Application":
            continue
        meta = d.get("metadata") or {}
        for p in _roundtrip_unstable({k: v for k, v in d.items() if k in ("metadata", "spec")}, ""):
            out.append(Finding("error", "app-not-roundtrip-stable",
                               f"{p} is empty; ArgoCD drops it when it writes the Application back, so remove it from the template",
                               f"Application/{meta.get('name', '?')}"))
    return out


_RANGE = re.compile(r"[\^~<>*|,]|\bx\b|\bX\b|\s-\s|^$|^v?\d+(\.\d+)?$")


def check_chart_deps(repo_root: str) -> list[Finding]:
    """Chart dependencies must be exact versions (a range lets a republished chart change a release)."""
    out = []
    charts = os.path.join(repo_root, "charts")
    if not os.path.isdir(charts):
        return out
    for name in sorted(os.listdir(charts)):
        cy = os.path.join(charts, name, "Chart.yaml")
        if not os.path.isfile(cy):
            continue
        with open(cy) as fh:
            try:
                chart = yaml.safe_load(fh) or {}
            except yaml.YAMLError:
                continue
        for dep in chart.get("dependencies") or []:
            v = str(dep.get("version", ""))
            if not v or _RANGE.search(v):
                out.append(Finding("error", "chart-dependency-range",
                                   f"dependency {dep.get('name')} has version '{v}', not an exact version", f"charts/{name}/Chart.yaml"))
    return out


def _walk_revisions(obj, path=""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "revision" and isinstance(v, str):
                yield path + "/revision", v
            else:
                yield from _walk_revisions(v, f"{path}/{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _walk_revisions(v, f"{path}[{i}]")


def check_crs(docs: list[tuple[str, dict]], level: str = "warn") -> list[Finding]:
    """Rendered teknoir.org CRs (DeviceApplicationSet, Device, Robot, RobotType) must name a 40-hex commit.
    level is "warn" or "error" (policy cr_revisions: deny). Hand-applied CRs are not in the render."""
    out = []
    for _, d in docs:
        if d.get("kind") in CR_KINDS and str(d.get("apiVersion", "")).startswith("teknoir.org/"):
            for p, rev in _walk_revisions(d.get("spec") or {}):
                if not SHA40.match(rev):
                    out.append(Finding(level, "cr-revision", f"revision '{rev}' at spec{p} is not a 40-hex commit",
                                       f"{d['kind']}/{d['metadata'].get('name')}"))
    return out


def check_profiles(docs: list[tuple[str, dict]]) -> list[Finding]:
    out = []
    for _, d in docs:
        if d.get("kind") != "Profile" or not str(d.get("apiVersion", "")).startswith("teknoir.org/"):
            continue
        name = d["metadata"].get("name")
        for i, pl in enumerate((d.get("spec") or {}).get("plugins") or []):
            spec = (pl or {}).get("spec") or {}
            if spec.get("version"):
                out.append(Finding("warn", "profile-version", f"plugin {pl.get('name', i)} sets spec.version={spec['version']}", f"Profile/{name}"))
            vals = (pl or {}).get("values") or (pl or {}).get("helm", {}).get("values") or {}
            if isinstance(vals, str):
                try:
                    vals = yaml.safe_load(vals) or {}
                except yaml.YAMLError:
                    vals = {}
            for k in (vals if isinstance(vals, dict) else {}):
                if re.search(r"Version$", k) or k.startswith("image"):
                    out.append(Finding("warn", "profile-version", f"plugin {pl.get('name', i)} values key '{k}' pins an image or version", f"Profile/{name}"))
    return out


def app_set_changes(live: set[str], candidate: set[str]) -> tuple[list[str], list[str]]:
    """(added, removed) Application names; a removal prunes the app and its PVCs, hence --allow-remove."""
    return sorted(candidate - live), sorted(live - candidate)


def lint(docs, *, policy: dict, release: str | None, project: str, repo_root: str | None, today: dt.date,
         verbose: bool = False) -> list[Finding]:
    out: list[Finding] = []
    out += check_applications(docs, release, project)
    out += check_roundtrip(docs)
    out += check_exceptions(policy, today)
    if repo_root:
        out += check_chart_deps(repo_root)
    out += check_images(collect_images(docs), policy, today, verbose)
    out += check_crs(docs, "error" if policy.get("cr_revisions") == "deny" else "warn")
    out += check_profiles(docs)
    out += check_hub_audience(docs, policy)
    out += check_portal_binding(docs, policy)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="rendered YAML files or directories")
    ap.add_argument("--policy", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-policy.yaml"))
    ap.add_argument("--release", help="the release commit SHA every gitops Application must follow")
    ap.add_argument("--project", default="teknoir-cloud")
    ap.add_argument("--repo-root", help="checkout whose charts/*/Chart.yaml dependencies are checked")
    ap.add_argument("--today", help="YYYY-MM-DD (default: today, for the exception expiry)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--quiet", action="store_true", help="only errors")
    ap.add_argument("--only", help="comma list of finding codes: report (and fail on) only those, e.g. portal-controller-unchecked")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every third-party image without a digest")
    a = ap.parse_args(argv)
    today = dt.date.fromisoformat(a.today) if a.today else dt.date.today()
    findings = lint(load_docs(a.paths), policy=load_policy(a.policy), release=a.release, project=a.project,
                    repo_root=a.repo_root, today=today, verbose=a.verbose)
    if a.only:
        only = {c.strip() for c in a.only.split(",") if c.strip()}
        findings = [f for f in findings if f.code in only]
    errors = [f for f in findings if f.level == "error"]
    if a.json:
        print(json.dumps([asdict(f) for f in findings], indent=2))
    else:
        for f in findings:
            if not a.quiet or f.level == "error":
                print(f.line())
        print(f"check-pins: {len(errors)} error(s), {sum(f.level == 'warn' for f in findings)} warning(s), "
              f"{sum(f.level == 'info' for f in findings)} excepted")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
