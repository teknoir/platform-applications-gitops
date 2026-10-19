#!/usr/bin/env python3
"""Two stubs for the Envoy harness.

authz  (oauth2-proxy lookalike): called by ext_authz as GET /oauth2/auth<original path>.
  Authorization "Bearer good-token" or cookie _teknoir_oauth2_proxy_v2=good -> 200 (allow)
  cookie _teknoir_oauth2_proxy_v2=stale -> 500 (oauth2-proxy answers an undecodable cookie that way)
  otherwise -> 403 + 8492-byte HTML sign-in page + expired Set-Cookie (what oauth2-proxy v7.6.0 sends)
  an original path starting /ext401 is denied with 401 {} instead of 403.
backend: 200 everywhere, except /forbidden (403), /backend401 (401 + own challenge), /oauth2/unauth (401, 13 bytes),
  /stream (chunked, slow).
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

COOKIE = "_teknoir_oauth2_proxy_v2"
SIGNIN = ("<html><head><title>Sign In</title></head><body>" + "x" * 8400).encode()
SIGNIN += b"</body></html>" + b"\n" * (8492 - len(SIGNIN) - len(b"</body></html>"))
assert len(SIGNIN) == 8492


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
            self.wfile.write(body)

    do_HEAD = do_GET = do_POST = do_PUT = do_DELETE = lambda self: self.handle_any()


class Authz(Quiet):
    def handle_any(self):
        head = self.command == "HEAD"
        assert self.path.startswith("/oauth2/auth"), self.path
        orig = self.path[len("/oauth2/auth"):]
        auth = self.headers.get("authorization", "")
        cookie = self.headers.get("cookie", "")
        if auth == "Bearer good-token" or f"{COOKIE}=good" in cookie:
            return self.reply(200, b"", [("x-auth-request-email", "tester@teknoir.test")], head)
        if f"{COOKIE}=stale" in cookie:
            return self.reply(500, b"<html>internal error</html>", [("content-type", "text/html")], head)
        if orig.startswith("/ext401"):
            return self.reply(401, b"{}", [("content-type", "application/json")], head)
        return self.reply(
            403,
            SIGNIN,
            [
                ("content-type", "text/html; charset=utf-8"),
                ("set-cookie", f"{COOKIE}=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; Secure; SameSite=None"),
            ],
            head,
        )


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
