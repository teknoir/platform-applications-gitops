"""In-process fake of the Harbor API and the Kubernetes API, for files/harbor-config.py.

One HTTP server answers both: /api/v2.0/... is Harbor, /api/v1/... and /apis/... are Kubernetes.
Only what harbor-config.py uses is implemented, with Harbor's observable behaviour that matters
for the tests (a registry credential is never returned, robots log in with their secret,
pagination, 404 messages). Every request is recorded in `calls`.
"""
import base64
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ADMIN_PASSWORD = "admin-pw-for-tests"
K8S_TOKEN = "k8s-token-for-tests"


class Fake:
    def __init__(self):
        self.lock = threading.Lock()
        self.calls = []          # (method, path, body)
        self.next_id = 100
        self.configs = {"robot_name_prefix": {"value": "robot$"}}
        self.registries = {}     # id -> dict (with private _secret)
        self.projects = {}       # id -> dict
        self.quotas = {}         # project id -> {"id", "hard"}
        self.retentions = {}
        self.immutable = {}      # project id -> {rule id: rule}
        self.schedules = {}
        self.robots = {}         # id -> dict (with private _secret)
        self.namespaces = {"teknoir-system", "teknoir-ci"}
        self.secrets = {}        # (ns, name) -> object
        self.profiles = []       # names
        self.profiles_status = 200
        self.rv = 1

    # -- helpers
    def new_id(self):
        self.next_id += 1
        return self.next_id

    def writes(self):
        return [c for c in self.calls if c[0] != "GET"]

    def project(self, name):
        return next(p for p in self.projects.values() if p["name"] == name)

    def registry(self, name):
        return next(r for r in self.registries.values() if r["name"] == name)

    def robot(self, full):
        return next((r for r in self.robots.values() if r["name"] == full), None)

    def secret_data(self, ns, name):
        obj = self.secrets.get((ns, name))
        if obj is None:
            return None
        return {k: base64.b64decode(v).decode() for k, v in (obj.get("data") or {}).items()}

    def set_secret_data(self, ns, name, data):
        obj = self.secrets[(ns, name)]
        obj["data"] = {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}
        self.rv += 1
        obj["metadata"]["resourceVersion"] = str(self.rv)


def public_registry(r):
    cred = {"type": "basic", "access_key": r["_ak"], "access_secret": "*****"} if r["_ak"] else {}
    return {k: v for k, v in r.items() if not k.startswith("_")} | {"credential": cred}


def public_robot(r):
    return {k: v for k, v in r.items() if not k.startswith("_")}


class Handler(BaseHTTPRequestHandler):
    fake: Fake

    def log_message(self, *a):  # silence
        pass

    # -- plumbing
    def _send(self, code, obj=None):
        raw = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _err(self, code, msg):
        self._send(code, {"errors": [{"code": str(code), "message": msg}], "message": msg})

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def _basic(self):
        h = self.headers.get("Authorization", "")
        if not h.startswith("Basic "):
            return None
        return base64.b64decode(h[6:]).decode().split(":", 1)

    def _dispatch(self, method):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        body = self._body()
        f = self.fake
        with f.lock:
            f.calls.append((method, u.path + ("?" + u.query if u.query else ""), body))
            if u.path.startswith("/api/v2.0/"):
                return self._harbor(method, u.path[len("/api/v2.0"):], q, body)
            return self._k8s(method, u.path, body)

    do_GET = lambda self: self._dispatch("GET")
    do_POST = lambda self: self._dispatch("POST")
    do_PUT = lambda self: self._dispatch("PUT")
    do_PATCH = lambda self: self._dispatch("PATCH")
    do_DELETE = lambda self: self._dispatch("DELETE")

    # -- Harbor
    def _harbor(self, method, path, q, body):
        f = self.fake
        auth = self._basic()
        if path == "/users/current/permissions":
            robot = f.robot(auth[0]) if auth else None
            if robot and robot["_secret"] == auth[1]:
                return self._send(200, [])
            return self._err(401, "unauthorized")
        if not auth or auth != ["admin", ADMIN_PASSWORD]:
            return self._err(401, "unauthorized")

        def page(items):
            p, n = int(q.get("page", 1)), int(q.get("page_size", 10))
            return items[(p - 1) * n: p * n]

        if path == "/users/current":
            return self._send(200, {"username": "admin"})
        if path == "/configurations":
            if method == "PUT":
                for k, v in body.items():
                    f.configs[k] = {"value": v}
                return self._send(200)
            return self._send(200, f.configs)
        if path == "/registries":
            if method == "POST":
                rid = f.new_id()
                cred = body.get("credential") or {}
                f.registries[rid] = {"id": rid, "name": body["name"], "type": body["type"], "url": body["url"],
                                     "description": body.get("description", ""), "_ak": cred.get("access_key", ""),
                                     "_sk": cred.get("access_secret", "")}
                return self._send(201)
            return self._send(200, page([public_registry(r) for r in f.registries.values()]))
        m = re.fullmatch(r"/registries/(\d+)", path)
        if m:
            r = f.registries.get(int(m[1]))
            if r is None:
                return self._err(404, "registry not found")
            if method == "DELETE":
                del f.registries[r["id"]]
                return self._send(200)
            if method == "PUT":
                for k in ("name", "url", "description"):
                    if k in body:
                        r[k] = body[k]
                if "access_key" in body:
                    r["_ak"], r["_sk"] = body["access_key"], body.get("access_secret", "")
                return self._send(200)
        if path == "/projects":
            if method == "POST":
                pid = f.new_id()
                f.projects[pid] = {"project_id": pid, "name": body["project_name"],
                                   "metadata": dict(body.get("metadata") or {}), "registry_id": body.get("registry_id")}
                f.quotas[pid] = {"id": f.new_id(), "hard": {"storage": body.get("storage_limit", -1)}}
                return self._send(201)
            return self._send(200, page(list(f.projects.values())))
        m = re.fullmatch(r"/projects/([^/]+)", path)
        if m and method == "GET":
            return self._send(200, f.project(m[1]))
        if m and method == "PUT":
            f.projects[int(m[1])]["metadata"].update(body["metadata"])
            return self._send(200)
        if path == "/quotas":
            pid = int(q["reference_id"])
            return self._send(200, [{"id": f.quotas[pid]["id"], "hard": f.quotas[pid]["hard"]}])
        m = re.fullmatch(r"/quotas/(\d+)", path)
        if m and method == "PUT":
            for qt in f.quotas.values():
                if qt["id"] == int(m[1]):
                    qt["hard"] = body["hard"]
            return self._send(200)
        if path == "/retentions" and method == "POST":
            rid = f.new_id()
            f.retentions[rid] = dict(body, id=rid)
            f.projects[body["scope"]["ref"]]["metadata"]["retention_id"] = str(rid)
            return self._send(201)
        m = re.fullmatch(r"/retentions/(\d+)", path)
        if m:
            rid = int(m[1])
            if method == "PUT":
                f.retentions[rid] = dict(body, id=rid)
                return self._send(200)
            return self._send(200, f.retentions[rid])
        m = re.fullmatch(r"/projects/(\d+)/immutabletagrules(?:/(\d+))?", path)
        if m:
            rules = f.immutable.setdefault(int(m[1]), {})
            if method == "POST":
                rid = f.new_id()
                rules[rid] = dict(body, id=rid)
                return self._send(201)
            if method == "DELETE":
                rules.pop(int(m[2]), None)
                return self._send(200)
            return self._send(200, list(rules.values()))
        m = re.fullmatch(r"/system/(gc|purgeaudit|scanAll)/schedule", path)
        if m:
            if method in ("POST", "PUT"):
                f.schedules[m[1]] = body
                return self._send(200)
            return self._send(200, f.schedules.get(m[1], {}))
        if path == "/robots":
            if method == "POST":
                rid = f.new_id()
                full = f.configs["robot_name_prefix"]["value"] + body["name"]
                f.robots[rid] = {"id": rid, "name": full, "level": body["level"], "duration": body["duration"],
                                 "description": body["description"], "permissions": body["permissions"],
                                 "disable": body["disable"], "_secret": body["secret"]}
                return self._send(201, {"id": rid, "name": full, "secret": body["secret"]})
            return self._send(200, page([public_robot(r) for r in f.robots.values()]))
        m = re.fullmatch(r"/robots/(\d+)", path)
        if m:
            r = f.robots.get(int(m[1]))
            if r is None:
                return self._err(404, "robot not found")
            if method == "PATCH":
                r["_secret"] = body["secret"]
                return self._send(200)
            if method == "PUT":
                r["permissions"] = body["permissions"]
                return self._send(200)
            if method == "DELETE":
                del f.robots[r["id"]]
                return self._send(200)
            return self._send(200, public_robot(r))
        return self._err(404, f"fake harbor: no route {method} {path}")

    # -- Kubernetes
    def _k8s(self, method, path, body):
        f = self.fake
        if self.headers.get("Authorization") != "Bearer " + K8S_TOKEN:
            return self._send(401, {"message": "Unauthorized"})
        if path == "/apis/teknoir.org/v1/profiles":
            if f.profiles_status != 200:
                return self._send(f.profiles_status, {"message": "profiles.teknoir.org is forbidden"})
            return self._send(200, {"items": [{"metadata": {"name": n}} for n in f.profiles]})
        m = re.fullmatch(r"/api/v1/namespaces/([^/]+)/secrets(?:/([^/]+))?", path)
        if not m:
            return self._send(404, {"message": "no route"})
        ns, name = m[1], m[2]
        if ns not in f.namespaces:
            return self._send(404, {"message": f'namespaces "{ns}" not found'})
        if method == "POST":
            key = (ns, body["metadata"]["name"])
            if key in f.secrets:
                return self._send(409, {"message": "already exists"})
            f.rv += 1
            body["metadata"]["resourceVersion"] = str(f.rv)
            f.secrets[key] = body
            return self._send(201, body)
        obj = f.secrets.get((ns, name))
        if obj is None:
            return self._send(404, {"message": f'secrets "{name}" not found'})
        if method == "PUT":
            if body["metadata"].get("resourceVersion") != obj["metadata"]["resourceVersion"]:
                return self._send(409, {"message": "conflict"})
            f.rv += 1
            body["metadata"]["resourceVersion"] = str(f.rv)
            f.secrets[(ns, name)] = body
            return self._send(200, body)
        return self._send(200, obj)


class Server:
    """Context manager: `with Server() as fake:`; fake.url is the base URL."""

    def __enter__(self):
        self.fake = Fake()
        handler = type("H", (Handler,), {"fake": self.fake})
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.fake.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        return self.fake

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()
