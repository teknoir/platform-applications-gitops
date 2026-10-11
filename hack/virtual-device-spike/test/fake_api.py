"""Fake Kubernetes API server for the renderer's -in-cluster mode (test only).

    fake_api.py CERT KEY PORTFILE RECORD DEVICE_JSON TOKEN [--secret-exists] [--no-device]

Serves HTTPS on 127.0.0.1 (port written to PORTFILE) with exactly the three requests
the renderer makes: GET secret, GET device, POST secret. RECORD receives one line per
request ("METHOD PATH STATUS") and, for a POST, the body in RECORD.post. Requests
without "Authorization: Bearer TOKEN" get 401. Throwaway credentials only.
"""
import http.server
import json
import ssl
import sys

cert, key, portfile, record, device_json, token = sys.argv[1:7]
secret_exists = "--secret-exists" in sys.argv
no_device = "--no-device" in sys.argv
DEVICE = open(device_json, "rb").read()
SECRET = "/api/v1/namespaces/teknoir-demo-vdev/secrets"
DEV = "/apis/teknoir.org/v1/namespaces/teknoir-demo/devices/vd-s1-fixture"
state = {"created": False}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body=b"{}"):
        with open(record, "a") as f:
            f.write(f"{self.command} {self.path} {code}\n")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def status(self, code, reason):
        self.reply(code, json.dumps({"kind": "Status", "reason": reason}).encode())

    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {token}":
            return self.status(401, "Unauthorized")
        if self.path == SECRET + "/vd-s1-fixture-cloudinit":
            if secret_exists or state["created"]:
                return self.reply(200, b'{"kind":"Secret"}')
            return self.status(404, "NotFound")
        if self.path == DEV:
            return self.status(404, "NotFound") if no_device else self.reply(200, DEVICE)
        self.status(403, "Forbidden")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        if self.headers.get("Authorization") != f"Bearer {token}":
            return self.status(401, "Unauthorized")
        if self.path.split("?")[0] != SECRET:
            return self.status(403, "Forbidden")
        with open(record + ".post", "wb") as f:
            f.write(body)
        state["created"] = True
        self.reply(201, b'{"kind":"Secret"}')


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(portfile, "w").write(str(srv.server_address[1]))
srv.serve_forever()
