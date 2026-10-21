#!/usr/bin/env python3
"""Two stubs for the Envoy harness.

authz  (oauth2-proxy lookalike): called by ext_authz as GET /oauth2/auth<original path>.
  Models oauth2-proxy v7.6.0 with --force-json-errors=true (the chart default):
  Authorization "Bearer good-token" or cookie _teknoir_oauth2_proxy_v2=good -> 200 (allow)
  cookie ...=stale (decodable, session gone server-side) -> 401 {} + its clearing Set-Cookie
  cookie ...=garbage (undecodable: it cannot clear it) -> 401 {}, no Set-Cookie
  cookie ...=forbidden (logged in, not authorized) -> 403 {} + clearing Set-Cookie
  cookie ...=legacy, or an original path starting /legacy403 or /oauth2x -> what the old flags sent: 403 + 8492-byte
    HTML sign-in page + expired Set-Cookie (rolling deploy: new Lua, old oauth2-proxy)
  otherwise (no credentials, bad bearer) -> 401 {}, no Set-Cookie
  Any method gets the same answer (Envoy forwards the original method, OPTIONS preflights included).
  Like the real ext_authz client response, the gateway keeps only set-cookie and location of these answers; the
  content-type below is dropped by Envoy.
backend: 200 everywhere, except /forbidden (403), /backend401 (401 + own challenge), /oauth2/unauth (401, 13 bytes),
  /stream (chunked, slow), /ws (WebSocket upgrade, then echo), /big (BIG bytes, 200), /big403 (BIG_403 bytes, 403).
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COOKIE = "_teknoir_oauth2_proxy_v2"
SIGNIN = ("<html><head><title>Sign In</title></head><body>" + "x" * 8400).encode()
SIGNIN += b"</body></html>" + b"\n" * (8492 - len(SIGNIN) - len(b"</body></html>"))
assert len(SIGNIN) == 8492
BLOCK = bytes(range(256)) * 4  # 1 KiB, repeated to make the large bodies (matrix.py recomputes them)
BIG = 20 * 1024 * 1024
BIG_403 = 5 * 1024 * 1024


def big_body(n):
    return BLOCK * (n // len(BLOCK))


class Quiet(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body=b"", headers=(), head=False):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):  # peer gave up (e.g. Envoy failing a buffered response)
                self.close_connection = True

    do_HEAD = do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = lambda self: self.handle_any()


class Authz(Quiet):
    def handle_any(self):
        head = self.command == "HEAD"
        assert self.path.startswith("/oauth2/auth"), self.path
        orig = self.path[len("/oauth2/auth"):]
        auth = self.headers.get("authorization", "")
        cookie = self.headers.get("cookie", "")
        if auth == "Bearer good-token" or f"{COOKIE}=good" in cookie:
            return self.reply(200, b"", [("x-auth-request-email", "tester@teknoir.test")], head)
        clear = ("set-cookie", f"{COOKIE}=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; Secure; SameSite=None")
        if f"{COOKIE}=forbidden" in cookie:
            return self.reply(403, b"{}", [("content-type", "application/json"), clear], head)
        legacy = f"{COOKIE}=legacy" in cookie or orig.startswith(("/legacy403", "/oauth2x"))
        if not legacy:
            hdrs = [("content-type", "application/json")]
            if f"{COOKIE}=stale" in cookie:
                hdrs.append(clear)
            return self.reply(401, b"{}", hdrs, head)
        return self.reply(403, SIGNIN, [("content-type", "text/html; charset=utf-8"), clear], head)


class Backend(Quiet):
    def handle_any(self):
        head = self.command == "HEAD"
        p = self.path.split("?")[0]
        if p == "/forbidden":
            return self.reply(403, b"backend-forbidden", [("content-type", "text/plain")], head)
        if p == "/backend401":
            return self.reply(401, b"backend-unauthorized", [("content-type", "text/plain"), ("www-authenticate", 'Basic realm="backend"')], head)
        if p == "/oauth2/unauth":
            return self.reply(401, b"Unauthorized", [], head)
        if p == "/big":
            return self.reply(200, big_body(BIG), [("content-type", "application/octet-stream")], head)
        if p == "/big403":
            return self.reply(403, big_body(BIG_403), [("content-type", "application/octet-stream")], head)
        if p == "/ws" and self.headers.get("upgrade", "").lower() == "websocket":
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.end_headers()
            self.wfile.flush()
            self.close_connection = True
            while True:  # echo until the peer closes
                data = self.connection.recv(4096)
                if not data:
                    return
                self.connection.sendall(data)
        if p == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                chunk = f"event {i}\n".encode()
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                time.sleep(0.5)
            self.wfile.write(b"0\r\n\r\n")
            return
        return self.reply(200, b"backend-ok\n", [("content-type", "text/plain")], head)


def serve(handler, port):
    s = ThreadingHTTPServer(("127.0.0.1", port), handler)
    s.daemon_threads = True
    threading.Thread(target=s.serve_forever, daemon=True).start()


if __name__ == "__main__":
    serve(Authz, int(sys.argv[1]))
    serve(Backend, int(sys.argv[2]))
    while True:
        time.sleep(3600)
