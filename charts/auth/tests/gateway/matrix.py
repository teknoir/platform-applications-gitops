#!/usr/bin/env python3
"""Curl matrix against the Envoy harness (see run.sh). Usage: matrix.py <gw port> <nomarker port>.

Every case is checked against an oracle written from the contract (charts/auth/README.md), not from
the Lua. Exit code 1 if any check fails; a summary table is printed either way.
"""
import collections
import itertools
import os
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

GW, NOMARKER = int(sys.argv[1]), int(sys.argv[2])
HOST = "app.teknoir.test"
SHARED = "teknoir.test"
COOKIE = "_teknoir_oauth2_proxy_v2"
PAYLOAD = '{"error":"unauthorized","message":"Authentication required: run tnctl login or sign in in the browser."}'
OK_BODY = "backend-ok\n"
results = collections.OrderedDict()  # group -> [passed, failed]
failures = []


def record(group, ok, label, detail=""):
    r = results.setdefault(group, [0, 0])
    r[0 if ok else 1] += 1
    if not ok:
        failures.append(f"[{group}] {label}: {detail}")


# ---------------------------------------------------------------- curl

def curl(proto, path, headers=(), method="GET", host=HOST, port=GW, extra=()):
    """Return (status, http_version, headers{lower:[values]}, body bytes, curl rc, stderr)."""
    with tempfile.TemporaryDirectory() as d:
        hf, bf = os.path.join(d, "h"), os.path.join(d, "b")
        cmd = ["curl", "-sS", "-k", "--max-time", "15", "--connect-to", f"{host}:443:127.0.0.1:{port}",
               "-D", hf, "-o", bf, "-w", "%{http_code} %{http_version} %{time_starttransfer} %{time_total}"]
        cmd.append("--http1.1" if proto == "h1" else "--http2")
        if method == "HEAD":
            cmd.append("--head")
        elif method != "GET":
            cmd += ["-X", method, "--data", "{}"]
        for h in headers:
            cmd += ["-H", h]
        cmd += list(extra) + [f"https://{host}{path}"]
        p = subprocess.run(cmd, capture_output=True, text=True)
        out = p.stdout.split()
        status, ver = (int(out[0]), out[1]) if len(out) >= 2 and out[0].isdigit() else (0, "?")
        timing = (float(out[2]), float(out[3])) if len(out) >= 4 else (0.0, 0.0)
        hdrs = {}
        try:
            blocks = open(hf, "rb").read().decode("latin-1").split("\r\n\r\n")
            blocks = [b for b in blocks if b.strip()]
            for line in blocks[-1].split("\r\n")[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    hdrs.setdefault(k.strip().lower(), []).append(v.strip())
        except OSError:
            pass
        # curl --head writes the header block to -o as well; a HEAD response has no body
        body = open(bf, "rb").read() if os.path.exists(bf) and method != "HEAD" else b""
        return status, ver, hdrs, body, p.returncode, p.stderr.strip(), timing


def one(h, k):
    v = h.get(k)
    return v[0] if v else None


def urlenc(s):
    return urllib.parse.quote(s, safe="-_.~")


# ---------------------------------------------------------------- oracle

def classify(c):
    """Independent statement of the rule: browser or api."""
    if c["sfm"] is not None:
        return "browser" if c["sfm"] == "navigate" else "api"
    if c["auth"] is not None or c.get("xrw"):
        return "api"
    if c["method"] in ("GET", "HEAD") and c["accept"] is not None and "text/html" in c["accept"].lower():
        return "browser"
    return "api"


def headers_for(c):
    h = []
    if c["sfm"] is not None:
        h.append(f"Sec-Fetch-Mode: {c['sfm']}")
    if c["accept"] is not None:
        h.append(f"Accept: {c['accept']}")
    else:
        h.append("Accept:")  # curl would send */*; strip it to model "no Accept"
    if c["auth"] == "good":
        h.append("Authorization: Bearer good-token")
    elif c["auth"] == "bad":
        h.append("Authorization: Bearer junk")
    if c["cookie"] is not None:
        h.append(f"Cookie: {COOKIE}={c['cookie']}")
    if c.get("xrw"):
        h.append("X-Requested-With: XMLHttpRequest")
    h += c.get("extra_headers", [])
    return h


def check_case(c):
    proto, path = c["proto"], c["path"]
    st, ver, h, body, rc, err, _ = curl(proto, path, headers_for(c), c["method"], port=c.get("port", GW))
    probs = []
    if rc != 0:
        probs.append(f"curl rc={rc} {err}")
    if "PROTOCOL_ERROR" in err:
        probs.append("PROTOCOL_ERROR")
    if ver != ("2" if proto == "h2" else "1.1"):
        probs.append(f"negotiated HTTP/{ver}")
    allowed = c["auth"] == "good" or c["cookie"] == "good"
    cl = one(h, "content-length")
    head = c["method"] == "HEAD"
    if cl is not None and not head and str(len(body)) != cl:
        probs.append(f"body {len(body)} != content-length {cl}")
    if allowed:
        if st != 200:
            probs.append(f"allowed request got {st}")
        if not head and body.decode(errors="replace") != OK_BODY:
            probs.append("backend body altered")
        if "www-authenticate" in h:
            probs.append("www-authenticate on a 200")
    elif c["cookie"] == "stale" or (path.startswith("/oauth2")):
        # loop guard (a session cookie is present) and /oauth2 exemption: left exactly as ext_authz produced it
        if st == 302:
            probs.append("302 on an exempt request")
        if "www-authenticate" in h or (not head and body.decode(errors="replace") == PAYLOAD):
            probs.append("exempt request was rewritten")
        if not path.startswith("/ext401") and path.startswith("/oauth2") and c["cookie"] != "stale":
            if st != 403:
                probs.append(f"/oauth2 exemption: status {st}, want the untouched 403")
            if not head and len(body) != 8492:
                probs.append(f"/oauth2 exemption: body {len(body)} bytes, want the untouched 8492")
    else:
        kind = classify(c)
        if kind == "browser":
            want = f"https://{SHARED}/oauth2/start?rd={urlenc('https://' + HOST + path)}"
            if st != 302:
                probs.append(f"browser denial got {st}, want 302")
            if one(h, "location") != want:
                probs.append(f"location {one(h, 'location')!r} != {want!r}")
            if cl != "0" or body:
                probs.append(f"302 not empty (content-length {cl}, body {len(body)})")
            if one(h, "cache-control") != "no-store":
                probs.append("302 without cache-control: no-store")
            if "www-authenticate" in h:
                probs.append("302 carries www-authenticate")
        else:
            if st != 401:
                probs.append(f"api denial got {st}, want 401")
            want_ch = 'Bearer realm="teknoir"' + (', error="invalid_token"' if c["auth"] is not None else "")
            if one(h, "www-authenticate") != want_ch:
                probs.append(f"www-authenticate {one(h, 'www-authenticate')!r} != {want_ch!r}")
            if one(h, "content-type") != "application/json":
                probs.append(f"content-type {one(h, 'content-type')!r}")
            if cl != str(len(PAYLOAD)):
                probs.append(f"content-length {cl} != {len(PAYLOAD)}")
            if not head and body.decode(errors="replace") != PAYLOAD:
                probs.append("json body differs")
            if one(h, "cache-control") != "no-store":
                probs.append("401 without cache-control: no-store")
            if "location" in h:
                probs.append("401 carries location")
            if "set-cookie" in h:
                probs.append("401 carries set-cookie")
    return probs


# ---------------------------------------------------------------- matrix

def build_matrix():
    cases = []
    for proto, sfm, accept, auth, cookie, path in itertools.product(
        ("h1", "h2"),
        (None, "navigate", "cors", "websocket"),
        ("text/html,application/xhtml+xml", "application/json", None),
        (None, "good", "bad"),
        (None, "good", "stale"),
        ("/private?a=b&c=d", "/oauth2x/deny", "/ext401/x%20y"),
    ):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=auth, cookie=cookie, path=path, method="GET"))
    # X-Requested-With, HEAD, POST on the denied/unauthenticated path
    for proto, sfm, accept in itertools.product(("h1", "h2"), (None, "navigate", "cors"), ("text/html", "*/*", None)):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="GET", xrw=True))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="HEAD"))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth="bad", cookie=None, path="/private", method="HEAD"))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="POST"))
    return cases


def label(c):
    return " ".join(f"{k}={v}" for k, v in c.items() if v not in (None, False, []))


def run_matrix():
    cases = build_matrix()
    with ThreadPoolExecutor(8) as ex:
        outs = list(ex.map(check_case, cases))
    for c, probs in zip(cases, outs):
        grp = f"matrix {c['proto']}"
        record(grp, not probs, label(c), "; ".join(probs))


# ---------------------------------------------------------------- targeted cases

def expect(group, name, cond, detail=""):
    record(group, bool(cond), name, detail)


def run_targeted():
    g = "backend answers"
    for proto in ("h1", "h2"):
        for hdrs, tag in (([], "api"), (["Sec-Fetch-Mode: navigate", "Accept: text/html"], "navigate")):
            auth = ["Authorization: Bearer good-token"] + hdrs
            st, ver, h, body, rc, err, _ = curl(proto, "/forbidden", auth)
            expect(g, f"{proto} {tag} backend 403 untouched", st == 403 and body == b"backend-forbidden" and rc == 0
                   and "www-authenticate" not in h and "location" not in h, f"{st} {body[:40]!r} {h}")
            st, ver, h, body, rc, err, _ = curl(proto, "/backend401", auth)
            expect(g, f"{proto} {tag} backend 401 untouched", st == 401 and body == b"backend-unauthorized" and rc == 0
                   and one(h, "www-authenticate") == 'Basic realm="backend"', f"{st} {body[:40]!r} {h}")
        # cookie-authenticated browser: backend 403 stays too
        st, ver, h, body, rc, err, _ = curl(proto, "/forbidden", [f"Cookie: {COOKIE}=good", "Sec-Fetch-Mode: navigate"])
        expect(g, f"{proto} cookie session backend 403 untouched", st == 403 and body == b"backend-forbidden", f"{st}")
        # vhost with ext_authz disabled (argocd): backend 401/403 pass, even for a browser with no credentials
        for p, code, want in (("/backend401", 401, b"backend-unauthorized"), ("/forbidden", 403, b"backend-forbidden")):
            st, ver, h, body, rc, err, _ = curl(proto, p, ["Sec-Fetch-Mode: navigate", "Accept: text/html"], host="argocd.teknoir.test")
            expect(g, f"{proto} ext_authz-off vhost {p} untouched", st == code and body == want and "location" not in h, f"{st} {body[:40]!r}")
        # /oauth2/ route with ext_authz off: oauth2-proxy's own 401 (13 bytes) stays
        st, ver, h, body, rc, err, _ = curl(proto, "/oauth2/unauth", ["Sec-Fetch-Mode: navigate"])
        expect(g, f"{proto} /oauth2/ route 401 untouched", st == 401 and body == b"Unauthorized", f"{st} {body!r}")

    g = "spoofed forwarding headers"
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/private", ["Sec-Fetch-Mode: navigate", "X-Forwarded-Uri: /oauth2x", "X-Forwarded-Host: evil.example"])
        want = f"https://{SHARED}/oauth2/start?rd={urlenc('https://' + HOST + '/private')}"
        expect(g, f"{proto} X-Forwarded-Uri/-Host do not change rd or the exemption", st == 302 and one(h, "location") == want,
               f"{st} {one(h, 'location')}")
        st, ver, h, body, rc, err, _ = curl(proto, "/private", ["Sec-Fetch-Mode: navigate", "X-Forwarded-Proto: gopher"])
        expect(g, f"{proto} unknown X-Forwarded-Proto falls back to https", st == 302 and "rd=https%3A%2F%2F" in (one(h, "location") or ""), f"{one(h, 'location')}")
        st, ver, h, body, rc, err, _ = curl(proto, "/private", ["X-Forwarded-Uri: /oauth2x", "X-Forwarded-Host: evil.example", "Authorization: Bearer junk"])
        expect(g, f"{proto} spoofed headers on an api call still 401", st == 401 and one(h, "www-authenticate", ) == 'Bearer realm="teknoir", error="invalid_token"', f"{st}")
        # a spoofed header must not disable the rewrite on a real /oauth2 exempt path either way
        st, ver, h, body, rc, err, _ = curl(proto, "/oauth2x/deny", ["Sec-Fetch-Mode: navigate", "X-Forwarded-Uri: /private"])
        expect(g, f"{proto} real /oauth2 prefix stays exempt whatever X-Forwarded-Uri says", st == 403 and len(body) == 8492, f"{st} {len(body)}")

    g = "marker lost (fallback)"
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/forbidden", ["Authorization: Bearer good-token"], port=NOMARKER)
        expect(g, f"{proto} without the marker filter a backend 403 is rewritten (today's behaviour), never exposed",
               st == 401 and rc == 0 and body.decode() == PAYLOAD, f"{st} {body[:50]!r}")
        st, ver, h, body, rc, err, _ = curl(proto, "/private", ["Sec-Fetch-Mode: navigate"], port=NOMARKER)
        expect(g, f"{proto} without the marker filter a denial still redirects", st == 302 and not body, f"{st}")
        st, ver, h, body, rc, err, _ = curl(proto, "/private", [], port=NOMARKER)
        expect(g, f"{proto} without the marker filter an anonymous request is still denied", st in (401, 302, 403), f"{st}")

    g = "streaming not buffered"
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, (ttfb, total) = curl(proto, "/stream", ["Authorization: Bearer good-token"])
        expect(g, f"{proto} 200 event stream arrives incrementally", st == 200 and body.count(b"event") == 3 and ttfb < total / 2,
               f"status {st} events {body.count(b'event')} ttfb {ttfb:.2f}s total {total:.2f}s")


# ---------------------------------------------------------------- raw HTTP/1.1 sockets

def raw_exchange(sock, request, head=False):
    sock.sendall(request.encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
    head_b, _, rest = buf.partition(b"\r\n\r\n")
    lines = head_b.decode("latin-1").split("\r\n")
    hdrs = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        hdrs.setdefault(k.strip().lower(), []).append(v.strip())
    n = 0 if head else int(one(hdrs, "content-length") or 0)
    while len(rest) < n:
        chunk = sock.recv(65536)
        if not chunk:
            break
        rest += chunk
    body, extra = rest[:n], rest[n:]
    # anything still arriving after content-length bytes is stray data (the old 8492-byte desync)
    r, _, _ = select.select([sock], [], [], 0.3)
    if r:
        extra += sock.recv(65536)
    return int(lines[0].split()[1]), hdrs, body, extra


def run_raw():
    g = "http/1.1 keep-alive framing"
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["http/1.1"])
    cases = [
        ("browser denial", ["Sec-Fetch-Mode: navigate", "Accept: text/html"], 302),
        ("api denial", ["Accept: application/json"], 401),
        ("api denial, bad bearer", ["Authorization: Bearer junk"], 401),
        ("websocket upgrade denial", ["Sec-Fetch-Mode: websocket", "Connection: Upgrade", "Upgrade: websocket"], 401),
    ]
    for name, hdrs, want in cases:
        raw = socket.create_connection(("127.0.0.1", GW), timeout=10)
        s = ctx.wrap_socket(raw, server_hostname=HOST)
        try:
            req1 = f"GET /private HTTP/1.1\r\nHost: {HOST}\r\n" + "".join(h + "\r\n" for h in hdrs) + "\r\n"
            if "Upgrade" in " ".join(hdrs):
                req1 = req1.replace("Connection: Upgrade\r\n", "").replace("Upgrade: websocket\r\n", "")
            st, h, body, extra = raw_exchange(s, req1)
            ok = st == want and not extra and len(body) == int(one(h, "content-length") or -1)
            expect(g, f"{name}: {st}, body {len(body)} == content-length {one(h, 'content-length')}, no stray bytes", ok,
                   f"status {st} cl {one(h, 'content-length')} body {len(body)} extra {len(extra)}")
            req2 = f"GET /ok HTTP/1.1\r\nHost: {HOST}\r\nAuthorization: Bearer good-token\r\n\r\n"
            st2, h2, body2, extra2 = raw_exchange(s, req2)
            expect(g, f"{name}: next request on the same connection is clean", st2 == 200 and body2.decode() == OK_BODY and not extra2,
                   f"status {st2} body {body2[:30]!r} extra {len(extra2)}")
        except Exception as e:  # noqa: BLE001
            expect(g, name, False, repr(e))
        finally:
            s.close()


def main():
    run_matrix()
    run_targeted()
    run_raw()
    w = max(len(k) for k in results)
    print()
    print(f"{'group':<{w}}  {'checks':>6}  {'pass':>5}  {'fail':>5}")
    print(f"{'-' * w}  {'-' * 6}  {'-' * 5}  {'-' * 5}")
    tp = tf = 0
    for k, (p, f) in results.items():
        print(f"{k:<{w}}  {p + f:>6}  {p:>5}  {f:>5}")
        tp, tf = tp + p, tf + f
    print(f"{'-' * w}  {'-' * 6}  {'-' * 5}  {'-' * 5}")
    print(f"{'TOTAL':<{w}}  {tp + tf:>6}  {tp:>5}  {tf:>5}")
    if failures:
        print(f"\n{len(failures)} failure(s), first 25:")
        for f in failures[:25]:
            print("  FAIL", f)
    print("\nRESULT:", "FAIL" if tf else "PASS")
    sys.exit(1 if tf else 0)


main()
