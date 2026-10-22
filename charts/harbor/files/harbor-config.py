#!/usr/bin/env python3
"""harbor-config: reconcile Harbor's configuration from values (config as code).

Runs as an ArgoCD PostSync hook and as an hourly CronJob (templates/harbor-config.yaml).
Idempotent: every run converges Harbor to /config/config.json and changes nothing
that already matches.

  - system settings (PUT /configurations)
  - upstream registry endpoints for the proxy-cache projects, with an optional upstream
    credential read from a mounted Secret (/upstream/<registry>/). Harbor never returns
    the secret, so the registry description carries "credential sha256:<12 hex>" (a
    truncated hash of the username and token) and the credential is sent again only
    when that hash changes; when the Secret disappears the credential is removed again
  - projects: visibility, proxy upstream, storage quota, tag-retention policy, immutable-tag
    rules (exactly the patterns in `immutableTags`; other rules are removed)
  - garbage collection, audit-log purge and scan-all schedules
  - system robot accounts; each robot's credential is delivered as a
    kubernetes.io/dockerconfigjson Secret (extra keys username/password) in the
    namespace that consumes it. A robot whose Secret is missing or whose
    credential no longer logs in gets a new secret (refresh), so deleting the
    Secret rotates the credential.
  - teamspace robots: one pull-only system robot `robot$ts-<profile>` per Profile
    (profiles.teknoir.org), never expiring, with all credentials in ONE Opaque Secret
    (keys <profile>.username / <profile>.password). A robot that this job created
    (description "managed by harbor-config (teamspace)") is deleted when its Profile is
    gone. Deleting a key rotates that teamspace's credential.
  - a project that is `public: true` on an upstream with a credential is refused (ERROR,
    the project is kept private), so the private cache can never become public.

Never prints a credential. Python stdlib only (python:3.x-alpine).
Environment: HARBOR_URL, HARBOR_ADMIN_PASSWORD, CONFIG (path), HARBOR_HOST (registry
host written into the docker config). Optional, for tests: UPSTREAM_DIR (default /upstream),
K8S_API (default https://kubernetes.default.svc), SA_DIR (service account directory).
"""
import base64
import hashlib
import json
import os
import secrets
import re
import ssl
import string
import sys
import urllib.error
import urllib.request

HARBOR = os.environ["HARBOR_URL"].rstrip("/") + "/api/v2.0"
HOST = os.environ["HARBOR_HOST"]
ADMIN = "Basic " + base64.b64encode(("admin:" + os.environ["HARBOR_ADMIN_PASSWORD"]).encode()).decode()
CFG = json.load(open(os.environ.get("CONFIG", "/config/config.json")))
GIB = 1024 ** 3
UPSTREAM_DIR = os.environ.get("UPSTREAM_DIR", "/upstream")
REGISTRY_DESCRIPTION = "managed by harbor-config (platform-applications-gitops)"
TEAMSPACE_DESCRIPTION = "managed by harbor-config (teamspace)"
failures = []
# Registries that carry (or are declared to carry) an upstream credential: their projects stay private.
CREDENTIALED = {r["name"] for r in CFG.get("registries", []) if r.get("credential")}


def log(msg):
    print("harbor-config: " + msg, flush=True)


class HTTPError(Exception):
    def __init__(self, code, body):
        super().__init__(f"HTTP {code}")
        self.code, self.body = code, body


def call(method, path, body=None, auth=ADMIN, base=HARBOR, headers=None, ctx=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Authorization", auth)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=30, context=ctx) as r:
            raw = r.read()
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        # The body is Harbor's error message (never a credential).
        raise HTTPError(e.code, e.read()[:300].decode(errors="replace")) from None


def get_all(path):
    out, page = [], 1
    sep = "&" if "?" in path else "?"
    while True:
        items = call("GET", f"{path}{sep}page={page}&page_size=100") or []
        out += items
        if len(items) < 100:
            return out
        page += 1


def step(name):
    """Run one reconcile step; a failure is recorded and the run continues."""
    def deco(fn):
        def run(*a, **kw):
            try:
                return fn(*a, **kw)
            except Exception as e:  # noqa: BLE001
                failures.append(name)
                log(f"ERROR {name}: {e} {getattr(e, 'body', '')}")
        return run
    return deco


# ---------------------------------------------------------------- system

@step("system configurations")
def configurations():
    want = CFG.get("configurations") or {}
    if not want:
        return
    have = call("GET", "/configurations") or {}
    diff = {k: v for k, v in want.items() if (have.get(k) or {}).get("value") != v}
    if diff:
        call("PUT", "/configurations", diff)
        log(f"configurations: set {sorted(diff)}")


def schedule_body(sch, params):
    return {"schedule": {"type": "Custom", "cron": sch}, "parameters": params}


def ensure_schedule(name, path, cron, params):
    have = call("GET", path) or {}
    cur = (have.get("schedule") or {}).get("cron")
    # Harbor returns the parameters as a JSON string in job_parameters.
    cur_params = have.get("parameters") or have.get("job_parameters") or {}
    if isinstance(cur_params, str):
        try:
            cur_params = json.loads(cur_params) if cur_params else {}
        except ValueError:
            cur_params = {}
    body = schedule_body(cron, params)
    if not cur:
        call("POST", path, body)
        log(f"{name}: scheduled '{cron}'")
    elif cur != cron or any(cur_params.get(k) != v for k, v in params.items()):
        call("PUT", path, body)
        log(f"{name}: updated to '{cron}'")


@step("gc schedule")
def gc():
    g = CFG.get("gc")
    if g:
        ensure_schedule("gc", "/system/gc/schedule", g["schedule"],
                        {"delete_untagged": g.get("deleteUntagged", True), "workers": g.get("workers", 1),
                         "dry_run": False})


@step("audit purge schedule")
def purge():
    p = CFG.get("auditPurge")
    if p:
        ensure_schedule("audit purge", "/system/purgeaudit/schedule", p["schedule"],
                        {"audit_retention_hour": p["retentionHours"],
                         "include_event_types": ",".join(p.get("eventTypes", [])),
                         "dry_run": False})


@step("scan-all schedule")
def scan_all():
    s = CFG.get("scanAll")
    if not s:
        return
    have = call("GET", "/system/scanAll/schedule") or {}
    cur = (have.get("schedule") or {}).get("cron")
    body = {"schedule": {"type": "Custom", "cron": s["schedule"]}}
    if not cur:
        call("POST", "/system/scanAll/schedule", body)
        log(f"scan all: scheduled '{s['schedule']}'")
    elif cur != s["schedule"]:
        call("PUT", "/system/scanAll/schedule", body)
        log(f"scan all: updated to '{s['schedule']}'")


# ---------------------------------------------------------------- registries

def read_credential(r):
    """The upstream credential (username, password) of registry config `r`, or None (anonymous).

    The Secret is mounted at UPSTREAM_DIR/<name>/ (optional volume, so a missing Secret is an empty
    directory): format dockerconfigjson reads `.dockerconfigjson` (entry for `host`), format basic
    reads `username` and `password`. A missing credential is fine for an `optional` hook and an
    error otherwise. Error messages never contain a value.
    """
    c = r.get("credential")
    if not c:
        return None
    base = os.path.join(UPSTREAM_DIR, r["name"])
    fmt = c.get("format", "basic")
    user = password = ""
    try:
        if fmt == "dockerconfigjson":
            with open(os.path.join(base, ".dockerconfigjson")) as f:
                auths = (json.load(f).get("auths") or {})
            entry = auths.get(c["host"]) or {}
            user, password = entry.get("username", ""), entry.get("password", "")
            if (not user or not password) and entry.get("auth"):
                user, _, password = base64.b64decode(entry["auth"]).decode().partition(":")
        elif fmt == "basic":
            with open(os.path.join(base, "username")) as f:
                user = f.read().strip()
            with open(os.path.join(base, "password")) as f:
                password = f.read().strip()
        else:
            raise RuntimeError(f"registry {r['name']}: unknown credential format {fmt!r}")
    except FileNotFoundError:
        pass
    except (ValueError, AttributeError, TypeError):
        # Malformed JSON / base64: report which Secret, never its content.
        raise RuntimeError(f"registry {r['name']}: credential Secret {c.get('secret')} is malformed") from None
    if user and password:
        return user, password
    if c.get("optional"):
        return None
    raise RuntimeError(f"registry {r['name']}: credential Secret {c.get('secret')} is missing or incomplete")


def credential_hash(user, password):
    return hashlib.sha256(f"{user}\0{password}".encode()).hexdigest()[:12]


@step("registries")
def registries():
    have = {r["name"]: r for r in get_all("/registries")}
    ids = {}
    # A registry that holds a credential in Harbor now (even one about to be removed) may have cached
    # private content: its projects are not made public in this run.
    CREDENTIALED.update(n for n, r in have.items() if (r.get("credential") or {}).get("access_key"))
    for r in CFG.get("registries", []):
        try:
            cred = read_credential(r)
        except RuntimeError as e:
            failures.append(f"registry {r['name']} credential")
            log(f"ERROR {e}")
            continue
        desc = REGISTRY_DESCRIPTION
        if cred:
            desc += " credential sha256:" + credential_hash(*cred)
        body = {"name": r["name"], "type": r["type"], "url": r["url"], "insecure": False, "description": desc}
        if cred:
            body["credential"] = {"type": "basic", "access_key": cred[0], "access_secret": cred[1]}
        cur = have.get(r["name"])
        if cur is None:
            call("POST", "/registries", body)
            log(f"registry {r['name']}: created" + (" with credential" if cred else ""))
        elif cur.get("type") != r["type"]:
            # The type cannot be changed in place: re-create (only if no project uses it yet).
            call("DELETE", f"/registries/{cur['id']}")
            call("POST", "/registries", body)
            log(f"registry {r['name']}: re-created as {r['type']}")
        else:
            upd = {}
            if cur.get("url") != r["url"]:
                upd["url"] = r["url"]
            if cur.get("description") != desc:
                upd["description"] = desc
                if cred:
                    upd.update(credential_type="basic", access_key=cred[0], access_secret=cred[1])
            if not cred and ((cur.get("credential") or {}).get("access_key") or "credential sha256:" in (cur.get("description") or "")):
                # Anonymous is the wanted state: remove a credential that is no longer configured.
                upd.update(credential_type="basic", access_key="", access_secret="", description=desc)
            if upd:
                call("PUT", f"/registries/{cur['id']}", {"name": r["name"], **upd})
                what = [k for k in ("url", "description") if k in upd]
                if "access_key" in upd:
                    what.append("credential " + ("set" if cred else "removed"))
                log(f"registry {r['name']}: updated ({', '.join(what)})")
    for r in get_all("/registries"):
        ids[r["name"]] = r["id"]
    return ids


# ---------------------------------------------------------------- projects

def retention_body(policy, project_id):
    rules = []
    for rule in policy["rules"]:
        params = {}
        if rule["template"] != "always":
            params = {rule["template"]: rule["value"]}
        rules.append({
            "disabled": False, "action": "retain", "template": rule["template"], "params": params,
            "tag_selectors": [{"kind": "doublestar", "decoration": "matches",
                               "pattern": rule.get("tags", "**"),
                               "extras": json.dumps({"untagged": rule.get("untagged", False)})}],
            "scope_selectors": {"repository": [{"kind": "doublestar", "decoration": "repoMatches",
                                                "pattern": rule.get("repositories", "**")}]},
        })
    return {"algorithm": "or", "rules": rules,
            "trigger": {"kind": "Schedule", "settings": {"cron": policy["schedule"]}},
            "scope": {"level": "project", "ref": project_id}}


def same_retention(have, want):
    def norm(p):
        return json.dumps({"rules": [{k: r.get(k) for k in ("template", "params", "tag_selectors", "scope_selectors")}
                                     for r in p.get("rules", [])],
                           "cron": ((p.get("trigger") or {}).get("settings") or {}).get("cron")}, sort_keys=True)
    return norm(have) == norm(want)


@step("projects")
def projects(registry_ids):
    have = {p["name"]: p for p in get_all("/projects")}
    for p in CFG.get("projects", []):
        name = p["name"]
        quota = int(p["quotaGiB"] * GIB) if p.get("quotaGiB") else -1
        want_public = bool(p.get("public"))
        if want_public and p.get("proxyRegistry") in CREDENTIALED:
            # A public project would serve the cached private images to anyone: refuse, keep it private.
            failures.append(f"project {name} public")
            log(f"ERROR project {name}: refusing public=true, the upstream {p['proxyRegistry']} has a "
                "credential; the project stays private")
            want_public = False
        public = "true" if want_public else "false"
        cur = have.get(name)
        if cur is None:
            body = {"project_name": name, "metadata": {"public": public}, "storage_limit": quota}
            if p.get("proxyRegistry"):
                if p["proxyRegistry"] not in registry_ids:
                    # e.g. a required upstream credential is missing: do not stop the other projects.
                    failures.append(f"project {name} upstream")
                    log(f"ERROR project {name}: upstream registry {p['proxyRegistry']} does not exist; skipped")
                    continue
                body["registry_id"] = registry_ids[p["proxyRegistry"]]
            call("POST", "/projects", body)
            log(f"project {name}: created")
            cur = call("GET", f"/projects/{name}", headers={"X-Is-Resource-Name": "true"})
        pid = cur["project_id"]
        meta = cur.get("metadata") or {}
        want_meta = {"public": public, "auto_scan": "true" if p.get("autoScan") else "false"}
        if any(meta.get(k) != v for k, v in want_meta.items()):
            call("PUT", f"/projects/{pid}", {"metadata": want_meta})
            log(f"project {name}: metadata {want_meta}")
        # Storage quota.
        for q in call("GET", f"/quotas?reference=project&reference_id={pid}") or []:
            if (q.get("hard") or {}).get("storage") != quota:
                call("PUT", f"/quotas/{q['id']}", {"hard": {"storage": quota}})
                log(f"project {name}: quota {p.get('quotaGiB', 'unlimited')} GiB")
        # Tag retention.
        pol_name = p.get("retention")
        if pol_name:
            want = retention_body(CFG["retentionPolicies"][pol_name], pid)
            rid = meta.get("retention_id")
            if not rid:
                call("POST", "/retentions", want)
                log(f"project {name}: retention '{pol_name}' created")
            else:
                cur_pol = call("GET", f"/retentions/{rid}") or {}
                if not same_retention(cur_pol, want):
                    want["id"] = int(rid)
                    call("PUT", f"/retentions/{rid}", want)
                    log(f"project {name}: retention '{pol_name}' updated")
        # Immutable tags: a pushed tag that matches can never be overwritten or deleted.
        if "immutableTags" in p:
            immutable_tags(name, pid, list(p["immutableTags"] or []))


def immutable_rule_body(pattern):
    return {"disabled": False, "action": "immutable", "template": "immutable_template",
            "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": pattern}],
            "scope_selectors": {"repository": [{"kind": "doublestar", "decoration": "repoMatches",
                                                "pattern": "**"}]}}


def immutable_pattern(rule):
    if rule.get("disabled") or rule.get("action") != "immutable":
        return None
    repos = [s.get("pattern") for s in (rule.get("scope_selectors") or {}).get("repository", [])]
    tags = [s.get("pattern") for s in rule.get("tag_selectors") or []
            if s.get("decoration", "matches") == "matches"]
    return tags[0] if repos == ["**"] and len(tags) == 1 else None


def immutable_tags(name, pid, patterns):
    """Converge the project's immutable-tag rules to `patterns` (all repositories)."""
    path = f"/projects/{pid}/immutabletagrules"
    have = call("GET", path) or []
    keep = set()
    for rule in have:
        pat = immutable_pattern(rule)
        if pat in patterns and pat not in keep:
            keep.add(pat)
            continue
        call("DELETE", f"{path}/{rule['id']}")
        log(f"project {name}: immutable-tag rule {rule.get('id')} removed")
    for pat in patterns:
        if pat not in keep:
            call("POST", path, immutable_rule_body(pat))
            log(f"project {name}: immutable tags '{pat}'")


# ---------------------------------------------------------------- robots + k8s

SA = os.environ.get("SA_DIR", "/var/run/secrets/kubernetes.io/serviceaccount")
K8S = os.environ.get("K8S_API", "https://kubernetes.default.svc")


def k8s(method, path, body=None):
    ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt") if K8S.startswith("https") else None
    token = open(f"{SA}/token").read().strip()
    return call(method, path, body, auth="Bearer " + token, base=K8S, ctx=ctx)


def write_secret(ns, name, ksec, obj):
    """Create the Secret (only where harbor-config may: teknoir-ci) or update the existing one.

    The Role in teknoir-system has no `create` (a Role that can create Secrets there can mint a
    service-account-token Secret for a cluster-admin ServiceAccount), so the chart renders the
    Secrets and this only fills them in. An existing Secret keeps its type (immutable)."""
    path = f"/api/v1/namespaces/{ns}/secrets/{name}"
    if ksec is None:
        try:
            k8s("POST", f"/api/v1/namespaces/{ns}/secrets", obj)
        except HTTPError as e:
            if e.code == 403:
                log(f"Secret {ns}/{name} does not exist and harbor-config may not create it; "
                    "ArgoCD renders it from the harbor chart (sync the app), then run the job again")
            raise
        return
    obj["metadata"]["resourceVersion"] = ksec["metadata"]["resourceVersion"]
    if ksec.get("type"):
        obj["type"] = ksec["type"]
    k8s("PUT", path, obj)


def new_secret():
    alphabet = string.ascii_letters + string.digits
    while True:
        s = "".join(secrets.choice(alphabet) for _ in range(40))
        if any(c.islower() for c in s) and any(c.isupper() for c in s) and any(c.isdigit() for c in s):
            return s


def robot_works(user, password):
    auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
    try:
        call("GET", "/users/current/permissions", auth=auth)
        return True
    except HTTPError as e:
        if e.code in (401, 403):
            return False
        raise


def robot_permissions(r):
    out = []
    for perm in r["permissions"]:
        out.append({"kind": "project", "namespace": perm["project"],
                    "access": [{"resource": a.split(":")[0], "action": a.split(":")[1]} for a in perm["access"]]})
    return out


def ensure_robot(prefix, have, name, r, description, stored):
    """Create or repair system robot `prefix+name` so it has the permissions of config `r`.

    `stored` is the password currently kept in Kubernetes (or None). Returns (full name, password):
    the password is set when the robot was created or its secret refreshed (no usable stored
    credential), else None.
    """
    full = prefix + name
    cur = have.get(full)
    if cur is None:
        password = new_secret()
        body = {"name": name, "level": "system", "duration": -1, "disable": False,
                "description": description, "secret": password,
                "permissions": robot_permissions(r)}
        created = call("POST", "/robots", body)
        # Harbor ignores a requested secret on create in some versions; set it explicitly.
        call("PATCH", f"/robots/{created['id']}", {"secret": password})
        log(f"robot {full}: created")
        return full, password
    want_perm = json.dumps(sorted(robot_permissions(r), key=lambda x: x["namespace"]), sort_keys=True)
    have_perm = json.dumps(sorted([{"kind": p["kind"], "namespace": p["namespace"],
                                    "access": [{"resource": a["resource"], "action": a["action"]}
                                               for a in p["access"]]}
                                   for p in cur.get("permissions") or []],
                                  key=lambda x: x["namespace"]), sort_keys=True)
    if want_perm != have_perm:
        full_robot = call("GET", f"/robots/{cur['id']}")
        full_robot["permissions"] = robot_permissions(r)
        call("PUT", f"/robots/{cur['id']}", full_robot)
        log(f"robot {full}: permissions updated")
    if stored is None or not robot_works(full, stored):
        password = new_secret()
        call("PATCH", f"/robots/{cur['id']}", {"secret": password})
        log(f"robot {full}: secret refreshed ({'no Secret' if stored is None else 'stale Secret'})")
        return full, password
    return full, None


def robot_prefix():
    return (call("GET", "/configurations") or {}).get("robot_name_prefix", {}).get("value", "robot$")


@step("robots")
def robots():
    prefix = robot_prefix()
    have = {r["name"]: r for r in get_all("/robots?q=level%3Dsystem")}
    for r in CFG.get("robots", []):
        ns, sname = r["secret"]["namespace"], r["secret"]["name"]
        path = f"/api/v1/namespaces/{ns}/secrets/{sname}"
        try:
            ksec = k8s("GET", path)
        except HTTPError as e:
            if e.code == 404 and "namespaces" in e.body and "not found" in e.body and sname not in e.body:
                log(f"robot {r['name']}: namespace {ns} does not exist yet; skipped")
                continue
            if e.code != 404:
                raise
            ksec = None
        stored = None
        if ksec:
            d = ksec.get("data") or {}
            if "password" in d:
                stored = base64.b64decode(d["password"]).decode()
        full, password = ensure_robot(prefix, have, r["name"], r, "managed by harbor-config", stored)
        if password is None:
            continue
        auth = base64.b64encode(f"{full}:{password}".encode()).decode()
        dockercfg = json.dumps({"auths": {HOST: {"username": full, "password": password, "auth": auth}}})
        data = {".dockerconfigjson": base64.b64encode(dockercfg.encode()).decode(),
                "username": base64.b64encode(full.encode()).decode(),
                "password": base64.b64encode(password.encode()).decode()}
        obj = {"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
               "metadata": {"name": sname, "namespace": ns,
                            "labels": {"teknoir.org/managed-by": "harbor-config"},
                            "annotations": {"teknoir.org/harbor-robot": full}},
               "data": data}
        write_secret(ns, sname, ksec, obj)
        log(f"robot {full}: Secret {ns}/{sname} written")


ROBOT_NAME = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$")


@step("teamspace robots")
def teamspace_robots():
    """One pull-only robot per Profile, all credentials in one Secret; robots of gone Profiles are deleted."""
    t = CFG.get("teamspaceRobots")
    if not t or t.get("enabled") is False:
        return
    prefix = robot_prefix()
    tprefix = t.get("namePrefix", "ts-")
    ns, sname = t["secret"]["namespace"], t["secret"]["name"]
    # Read the Profiles first: when the list fails, nothing is deleted.
    profiles = sorted({i["metadata"]["name"] for i in (k8s("GET", "/apis/teknoir.org/v1/profiles") or {}).get("items", [])})
    have = {r["name"]: r for r in get_all("/robots?q=level%3Dsystem")}
    path = f"/api/v1/namespaces/{ns}/secrets/{sname}"
    try:
        ksec = k8s("GET", path)
    except HTTPError as e:
        if e.code != 404:
            raise
        ksec = None
    data = {k: base64.b64decode(v).decode() for k, v in ((ksec or {}).get("data") or {}).items()}
    before = dict(data)
    for prof in profiles:
        name = tprefix + prof
        if not ROBOT_NAME.match(name):
            log(f"teamspace {prof}: not a valid robot name; skipped")
            continue
        full, password = ensure_robot(prefix, have, name, t, TEAMSPACE_DESCRIPTION, data.get(f"{prof}.password"))
        if password is not None:
            data[f"{prof}.password"] = password
        data[f"{prof}.username"] = full
    # Robots (and keys) of Profiles that are gone.
    for full, rob in have.items():
        short = full[len(prefix):] if full.startswith(prefix) else None
        if short and short.startswith(tprefix) and rob.get("description") == TEAMSPACE_DESCRIPTION \
                and short[len(tprefix):] not in profiles:
            call("DELETE", f"/robots/{rob['id']}")
            log(f"robot {full}: deleted (Profile {short[len(tprefix):]} is gone)")
    for key in list(data):
        owner, _, field = key.rpartition(".")
        if field in ("username", "password") and owner not in profiles:
            del data[key]
    if ksec is not None and data == before:
        return
    obj = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
           "metadata": {"name": sname, "namespace": ns, "labels": {"teknoir.org/managed-by": "harbor-config"}},
           "data": {k: base64.b64encode(v.encode()).decode() for k, v in sorted(data.items())}}
    write_secret(ns, sname, ksec, obj)
    log(f"teamspace robots: Secret {ns}/{sname} written ({len(profiles)} teamspaces)")


def main():
    call("GET", "/users/current")  # fail fast when Harbor is down or the admin password is wrong
    configurations()
    ids = registries() or {}
    projects(ids)
    gc()
    purge()
    scan_all()
    robots()
    teamspace_robots()
    if failures:
        log(f"FAILED steps: {', '.join(failures)}")
        sys.exit(1)
    log("in sync")


if __name__ == "__main__":
    main()
