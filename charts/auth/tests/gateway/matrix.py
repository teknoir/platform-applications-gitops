#!/usr/bin/env python3
"""Curl matrix against the Envoy harness (see run.sh). Usage: matrix.py <gw port> <nomarker port> <deadauthz port>.

Every case is checked against an oracle written from the contract (charts/auth/README.md), not from
the Lua. Exit code 1 if any check fails; a summary table is printed either way.

The authz stub (stubs.py) answers like oauth2-proxy with --force-json-errors: 401 {} for needs-login (no or bad
credentials, a decodable cookie whose session is gone = "stale", an undecodable one = "garbage"), 403 {} for
logged-in-but-not-allowed ("forbidden"); "legacy" cookies and /legacy403, /oauth2x paths get the old 403 sign-in page.
"""
import collections
import hashlib
import itertools
import json
import os
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

GW, NOMARKER, DEADGW = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
HOST = "app.teknoir.test"
SHARED = "teknoir.test"
COOKIE = "_teknoir_oauth2_proxy_v2"
RETRY = "_teknoir_auth_retry"
EPOCH = "Thu, 01 Jan 1970 00:00:00 GMT"
PAYLOAD = '{"error":"unauthorized","message":"Authentication required: run tnctl login or sign in in the browser."}'
BLOCK = bytes(range(256)) * 4  # same as stubs.py
BIG, BIG_403 = 20 * 1024 * 1024, 5 * 1024 * 1024  # both well above the 32 KiB buffer limit of the harness listeners
SHA = {n: hashlib.sha256(BLOCK * (n // len(BLOCK))).hexdigest() for n in (BIG, BIG_403)}
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
        elif method == "OPTIONS":
            cmd += ["-X", method]
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
        # a navigation is a browser only for a top-level document load: not an iframe, not a prefetch/prerender
        return "browser" if (c["sfm"] == "navigate" and c.get("dest", "document") == "document" and not c.get("purpose")) else "api"
    if c["auth"] is not None or c.get("xrw"):
        return "api"
    if c["method"] in ("GET", "HEAD") and c["accept"] is not None and "text/html" in c["accept"].lower():
        return "browser"
    return "api"


def headers_for(c):
    h = []
    if c["sfm"] is not None:
        h.append(f"Sec-Fetch-Mode: {c['sfm']}")
    if c.get("dest"):
        h.append(f"Sec-Fetch-Dest: {c['dest']}")
    if c.get("purpose"):
        h.append(f"Sec-Purpose: {c['purpose']}")
    if c["accept"] is not None:
        h.append(f"Accept: {c['accept']}")
    else:
        h.append("Accept:")  # curl would send */*; strip it to model "no Accept"
    if c["auth"] == "good":
        h.append("Authorization: Bearer good-token")
    elif c["auth"] == "bad":
        h.append("Authorization: Bearer junk")
    jar = []
    if c["cookie"] is not None:
        jar.append(f"{COOKIE}={c['cookie']}")
    if c.get("retry"):
        jar.append(f"{RETRY}=1")
    if jar:
        h.append("Cookie: " + "; ".join(jar))
    if c.get("xrw"):
        h.append("X-Requested-With: XMLHttpRequest")
    h += c.get("extra_headers", [])
    return h


def check_case(c):
    proto, path = c["proto"], c["path"]
    st, ver, h, body, rc, err, _ = curl(proto, path, headers_for(c), c["method"], host=c.get("host", HOST), port=c.get("port", GW))
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
        if "set-cookie" in h:
            probs.append("set-cookie on an allowed request")
        return probs
    session = c["cookie"] is not None  # a session cookie of ours is present (stale, garbage, forbidden, legacy)
    legacy = c["cookie"] == "legacy" or path.startswith(("/legacy403", "/oauth2x"))
    authz = 403 if (c["cookie"] == "forbidden" or legacy) else 401
    cookies = h.get("set-cookie", [])
    if path.startswith("/oauth2"):
        # /oauth2 exemption: the denial is left exactly as ext_authz produced it (plus a content-type)
        want_len = 2 if c["cookie"] == "forbidden" else 8492
        want_st = 403
        if st != want_st:
            probs.append(f"/oauth2 exemption: status {st}, want the untouched {want_st}")
        if not head and len(body) != want_len:
            probs.append(f"/oauth2 exemption: body {len(body)} bytes, want the untouched {want_len}")
        if "www-authenticate" in h or "location" in h:
            probs.append("exempt request was rewritten")
        if one(h, "content-type") is None:
            probs.append("exempt denial without content-type")
        if RETRY in " ".join(cookies):
            probs.append("exempt request got the loop-guard marker")
        return probs
    if session and authz == 403:
        # logged in but not allowed (or the authorizer failed): never a login retry. A browser navigation with the
        # bare {} gets the not-permitted page; an old oauth2-proxy's own HTML (legacy) and non-browsers pass through.
        kind = classify(c)
        if any(x.startswith(RETRY) for x in cookies):
            probs.append("403 got the loop-guard marker")
        if "www-authenticate" in h or "location" in h:
            probs.append("403 was rewritten into a challenge/redirect")
        if st != 403:
            probs.append(f"403 with a session cookie got {st}, want 403")
        if one(h, "content-type") is None:
            probs.append("403 without content-type")
        if kind == "browser" and c["cookie"] == "forbidden":
            if one(h, "content-type") != "text/html; charset=utf-8" or one(h, "cache-control") != "no-store":
                probs.append(f"not-permitted page headers {one(h, 'content-type')!r} {one(h, 'cache-control')!r}")
            if not head and b"<title>Access not permitted</title>" not in body:
                probs.append(f"not-permitted page missing: {body[:40]!r}")
            if len(cookies) != 1:
                probs.append(f"not-permitted page set-cookie count {len(cookies)}, want only the authorizer's 1")
            return probs
        if c["cookie"] == "forbidden" and not head and body != b"{}":
            probs.append(f"forbidden body altered: {body[:20]!r}")
        if c["cookie"] == "legacy" and not head and len(body) != 8492:
            probs.append(f"legacy sign-in page altered ({len(body)} bytes)")
        if len(cookies) != 1:
            probs.append(f"passthrough 403 set-cookie count {len(cookies)}, want only the authorizer's 1")
        return probs
    kind = classify(c)
    start_url = f"https://{SHARED}/oauth2/start?rd={urlenc('https://' + c.get('host', HOST) + path)}"
    page = kind == "browser" and c.get("retry")
    if kind == "browser" and not page:
        if st != 302:
            probs.append(f"browser denial got {st}, want 302")
        if one(h, "location") != start_url:
            probs.append(f"location {one(h, 'location')!r} != {start_url!r}")
        if cl != "0" or body:
            probs.append(f"302 not empty (content-length {cl}, body {len(body)})")
        if one(h, "cache-control") != "no-store":
            probs.append("302 without cache-control: no-store")
        if "www-authenticate" in h:
            probs.append("302 carries www-authenticate")
        probs += check_marker(cookies, want=True)
    elif page:
        if st != 401:
            probs.append(f"loop guard page got {st}, want 401")
        if one(h, "content-type") != "text/html; charset=utf-8":
            probs.append(f"page content-type {one(h, 'content-type')!r}")
        if one(h, "cache-control") != "no-store":
            probs.append("page without cache-control: no-store")
        if "location" in h or "www-authenticate" in h:
            probs.append("page carries location/www-authenticate")
        text = body.decode(errors="replace")
        out = f"https://{SHARED}/oauth2/sign_out?rd={urlenc(start_url)}"
        if not head:
            for needle in ("<title>Sign-in did not complete</title>", f'href="{start_url}"', f'href="{out}"'):
                if needle not in text:
                    probs.append(f"page lacks {needle[:60]}")
        probs += check_marker(cookies, want=False)
    else:
        if st != 401:
            probs.append(f"api denial got {st}, want 401")
        want_ch = 'Bearer realm="teknoir"' + (', error="invalid_token"' if (c["auth"] is not None or session) else "")
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
        probs += check_marker(cookies, want=False)
    # the session cookie is cleared by the gateway (both variants) exactly when one was sent
    probs += check_clears(cookies, want=session)
    if not session and kind != "browser" and cookies:
        probs.append(f"api denial without a session cookie carries set-cookie {cookies}")
    return probs


def check_marker(cookies, want):
    marks = [x for x in cookies if x.startswith(RETRY + "=")]
    if not want:
        return [f"unexpected loop-guard marker {marks}"] if marks else []
    if len(marks) != 1:
        return [f"want exactly one loop-guard marker, got {marks}"]
    m = marks[0]
    attrs = [a.strip() for a in m.split(";")]
    need = [f"{RETRY}=1", "Path=/", "Max-Age=30", "Secure", "SameSite=Lax"]
    miss = [n for n in need if n not in attrs]
    if any(a.lower().startswith("domain=") for a in attrs):
        miss.append("no Domain (host-only)")
    return [f"marker {m!r} lacks {miss}"] if miss else []


def check_clears(cookies, want):
    ours = [x for x in cookies if x.startswith(COOKIE + "=;") and "Max-Age=0" in x]
    domain = [x for x in ours if f"Domain={SHARED}" in x]
    hostonly = [x for x in ours if "Domain=" not in x]
    if not want:
        # oauth2-proxy's own (host-only looking) clearing cookie may pass on the 302 path; the gateway adds none
        return [f"gateway cleared a cookie that was not sent: {ours}"] if domain else []
    probs = []
    if len(domain) != 1:
        probs.append(f"want one Domain={SHARED} clearing cookie, got {ours}")
    # oauth2-proxy's own clearing cookie (stale) stays next to the gateway's host-only one
    if len(hostonly) < 1:
        probs.append(f"want a host-only clearing cookie, got {ours}")
    for x in domain + hostonly:
        attrs = [a.strip() for a in x.split(";")]
        for n in ("Path=/", "Max-Age=0", "Secure", "SameSite=None", f"Expires={EPOCH}"):
            if n not in attrs:
                probs.append(f"clearing cookie {x!r} lacks {n}")
    return probs


# ---------------------------------------------------------------- matrix

def build_matrix():
    cases = []
    for proto, sfm, accept, auth, cookie, path in itertools.product(
        ("h1", "h2"),
        (None, "navigate", "cors", "websocket"),
        ("text/html,application/xhtml+xml", "application/json", None),
        (None, "good", "bad"),
        (None, "good", "stale", "garbage", "forbidden", "legacy"),
        ("/private?a=b&c=d", "/oauth2x/deny", "/ext401/x%20y", "/legacy403/x%20y"),
    ):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=auth, cookie=cookie, path=path, method="GET"))
    # X-Requested-With, HEAD, POST on the denied/unauthenticated path
    for proto, sfm, accept in itertools.product(("h1", "h2"), (None, "navigate", "cors"), ("text/html", "*/*", None)):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="GET", xrw=True))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="HEAD"))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth="bad", cookie=None, path="/private", method="HEAD"))
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=None, path="/private", method="POST"))
    # OPTIONS (CORS preflight) and HEAD, with and without a dead session cookie: never a redirect, never a marker
    for proto, sfm, accept, cookie in itertools.product(("h1", "h2"), (None, "cors"), ("text/html", "*/*", None), (None, "stale", "garbage")):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=cookie, path="/private", method="OPTIONS"))
    for proto, sfm, accept, cookie in itertools.product(("h1", "h2"), (None, "navigate", "cors"), ("text/html", "*/*"), ("stale", "garbage", "forbidden")):
        cases.append(dict(proto=proto, sfm=sfm, accept=accept, auth=None, cookie=cookie, path="/private", method="HEAD"))
    # navigations that are not a user opening a page: iframe/frame/embed/object and prefetch/prerender are api clients
    for proto, dest, purpose, cookie in itertools.product(("h1", "h2"), ("document", "iframe", "frame", "embed", "object"),
                                                          (None, "prefetch", "prefetch;prerender"), (None, "stale", "garbage")):
        cases.append(dict(proto=proto, sfm="navigate", dest=dest, purpose=purpose, accept="text/html", auth=None, cookie=cookie, path="/private", method="GET"))
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


def run_session_expiry():
    """Dead/garbage session cookies, the loop guard and the other hosts (apex, next., wgt-, wgs-)."""
    hosts = [HOST, SHARED, "next." + SHARED, "wgt-7b00c0ffee." + SHARED, "wgs-7b00c0ffee." + SHARED]
    nav = ["Sec-Fetch-Mode: navigate", "Accept: text/html,application/xhtml+xml"]
    ckies = {"stale": f"{COOKIE}=stale", "garbage": f"{COOKIE}=garbage"}
    g = "expired session"
    for proto in ("h1", "h2"):
        for host in hosts:
            for cname, cval in ckies.items():
                tag = f"{proto} {host.split('.')[0]} {cname}"
                want_rd = urlenc(f"https://{host}/x")
                # top-level navigation: login redirect + the cookie cleared + the loop-guard marker
                st, ver, h, body, rc, err, _ = curl(proto, "/x", nav + [f"Cookie: {cval}"], host=host)
                ck = h.get("set-cookie", [])
                expect(g, f"{tag} navigate -> 302 to /oauth2/start?rd=<url>, empty, no-store",
                       st == 302 and one(h, "location") == f"https://{SHARED}/oauth2/start?rd={want_rd}" and body == b""
                       and one(h, "cache-control") == "no-store", f"{st} {one(h, 'location')}")
                expect(g, f"{tag} navigate -> cookie cleared (Domain + host-only) and marker set",
                       not check_clears(ck, True) and not check_marker(ck, True), f"{check_clears(ck, True)} {check_marker(ck, True)} {ck}")
                # fetch/XHR, websocket upgrade, Accept: application/json, plain curl: JSON 401 + cleared cookie
                for kind, hd in (("fetch", ["Sec-Fetch-Mode: cors", "Accept: */*"]), ("websocket", ["Sec-Fetch-Mode: websocket"]),
                                 ("json-accept", ["Accept: application/json"]), ("xhr", ["X-Requested-With: XMLHttpRequest"]), ("curl", [])):
                    st, ver, h, body, rc, err, _ = curl(proto, "/x", hd + [f"Cookie: {cval}"], host=host)
                    ck = h.get("set-cookie", [])
                    expect(g, f"{tag} {kind} -> 401 JSON, invalid_token challenge, cookie cleared, no marker, no redirect",
                           st == 401 and body.decode(errors="replace") == PAYLOAD and one(h, "content-type") == "application/json"
                           and one(h, "www-authenticate") == 'Bearer realm="teknoir", error="invalid_token"'
                           and "location" not in h and not check_clears(ck, True) and not check_marker(ck, False),
                           f"{st} {body[:40]!r} {h.get('www-authenticate')} {ck}")
            # tnctl: a bearer, no cookie
            st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Authorization: Bearer junk"], host=host)
            expect(g, f"{proto} {host.split('.')[0]} tnctl bad bearer -> 401 invalid_token, no set-cookie",
                   st == 401 and one(h, "www-authenticate") == 'Bearer realm="teknoir", error="invalid_token"' and "set-cookie" not in h, f"{st} {h}")
            st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Authorization: Bearer good-token"], host=host)
            expect(g, f"{proto} {host.split('.')[0]} tnctl good bearer -> 200", st == 200 and body.decode() == OK_BODY, f"{st}")
            # no cookie, no bearer: unchanged (302 for a navigation, 401 for the rest)
            st, ver, h, body, rc, err, _ = curl(proto, "/x", nav, host=host)
            expect(g, f"{proto} {host.split('.')[0]} no cookie navigate -> 302", st == 302 and one(h, "location") == f"https://{SHARED}/oauth2/start?rd={want_rd}"
                   and not check_clears(h.get("set-cookie", []), False), f"{st}")
            st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Sec-Fetch-Mode: cors"], host=host)
            expect(g, f"{proto} {host.split('.')[0]} no cookie fetch -> 401 JSON, no set-cookie",
                   st == 401 and body.decode() == PAYLOAD and one(h, "www-authenticate") == 'Bearer realm="teknoir"' and "set-cookie" not in h, f"{st}")

    g = "loop guard"
    for proto in ("h1", "h2"):
        marker = f"{RETRY}=1"
        # the real sequence: the 302 sets the marker, the browser returns still denied carrying it
        st, ver, h, body, rc, err, _ = curl(proto, "/x", nav + [f"Cookie: {COOKIE}=stale"])
        sent = [x.split(";")[0] for x in h.get("set-cookie", []) if x.startswith(RETRY + "=")]
        st2, ver, h2, body2, rc, err, _ = curl(proto, "/x", nav + ["Cookie: " + "; ".join(sent)])
        expect(g, f"{proto} 302 then a denied return with the marker -> sign-in-failed page, not a second redirect",
               st == 302 and sent == [marker] and st2 == 401 and b"Sign-in did not complete" in body2 and "location" not in h2
               and one(h2, "content-type") == "text/html; charset=utf-8" and one(h2, "cache-control") == "no-store", f"{st} {sent} {st2}")
        for tag, ck, hd, want in (
            ("marker + stale cookie, navigate", f"{COOKIE}=stale; {marker}", nav, "page"),
            ("marker alone (no session cookie), navigate", marker, nav, "page"),
            ("marker + garbage cookie, curl with Accept text/html", f"{COOKIE}=garbage; {marker}", ["Accept: text/html"], "page"),
            ("marker first, then the stale cookie", f"{marker}; {COOKIE}=stale", nav, "page"),
            ("marker + stale cookie, fetch", f"{COOKIE}=stale; {marker}", ["Sec-Fetch-Mode: cors"], "json"),
            ("marker + stale cookie, websocket", f"{COOKIE}=stale; {marker}", ["Sec-Fetch-Mode: websocket"], "json"),
            ("marker + no cookie, fetch", marker, ["Sec-Fetch-Mode: cors"], "json"),
            ("marker + good cookie, navigate", f"{COOKIE}=good; {marker}", nav, "ok"),
            ("marker + forbidden cookie, navigate", f"{COOKIE}=forbidden; {marker}", nav, "pass403"),
            ("marker-lookalike name, navigate", f"x{RETRY}=1; {COOKIE}=stale", nav, "302"),
        ):
            st, ver, h, body, rc, err, _ = curl(proto, "/x", hd + [f"Cookie: {ck}"])
            got = {200: "ok", 302: "302"}.get(st)
            if st == 401:
                got = "page" if b"Sign-in did not complete" in body else ("json" if body.decode(errors="replace") == PAYLOAD else f"401?{body[:20]!r}")
            if st == 403:
                got = "pass403"
            expect(g, f"{proto} {tag} -> {want}", got == want, f"got {got} ({st})")
        # the page links are the way out: they are on /oauth2 (exempt), never behind the guard
        st, ver, h, body, rc, err, _ = curl(proto, "/oauth2x/start", nav + [f"Cookie: {marker}"])
        expect(g, f"{proto} /oauth2 paths are never replaced by the page", st == 403 and len(body) == 8492, f"{st} {len(body)}")
        # a hostile path cannot inject into the page or the links
        st, ver, h, body, rc, err, _ = curl(proto, "/x%22%3E%3Cscript%3Ealert(1)%3C/script%3E", nav + [f"Cookie: {marker}"])
        text = body.decode(errors="replace")
        expect(g, f"{proto} page escapes a hostile path (no raw quote/script from the request)", st == 401 and "<script>" not in text
               and 'rd=https%3A%2F%2Fapp.teknoir.test%2Fx%2522%253E%253Cscript%253E' in text, f"{st} {text[-300:]}")

    g = "authorized but denied"
    for proto in ("h1", "h2"):
        for tag, hd in (("navigate", nav), ("fetch", ["Sec-Fetch-Mode: cors"]), ("websocket", ["Sec-Fetch-Mode: websocket"]), ("curl", [])):
            st, ver, h, body, rc, err, _ = curl(proto, "/x", hd + [f"Cookie: {COOKIE}=forbidden"])
            ck = h.get("set-cookie", [])
            if tag == "navigate":
                expect(g, f"{proto} navigate 403 with a session cookie gets the not-permitted page (403, HTML, no redirect/marker)",
                       st == 403 and b"<title>Access not permitted</title>" in body and one(h, "content-type") == "text/html; charset=utf-8"
                       and "location" not in h and "www-authenticate" not in h and len(ck) == 1 and not check_marker(ck, False),
                       f"{st} {body[:40]!r} {h}")
                continue
            expect(g, f"{proto} {tag} 403 with a session cookie passes through unchanged (403, body, no redirect/challenge/marker)",
                   st == 403 and body == b"{}" and one(h, "content-type") is not None and "location" not in h and "www-authenticate" not in h
                   and len(ck) == 1 and not check_marker(ck, False), f"{st} {body[:20]!r} {h}")

    g = "backend answers"
    for proto in ("h1", "h2"):
        for ck in (f"{COOKIE}=good", f"{COOKIE}=good; {RETRY}=1"):
            for hd in (nav, ["Sec-Fetch-Mode: cors"]):
                st, ver, h, body, rc, err, _ = curl(proto, "/forbidden", hd + [f"Cookie: {ck}"])
                expect(g, f"{proto} backend 403 with a session cookie ({ck[-8:]}) untouched", st == 403 and body == b"backend-forbidden" and "set-cookie" not in h
                       and one(h, "content-type") == "text/plain" and "location" not in h, f"{st} {body[:30]!r} {h}")
                st, ver, h, body, rc, err, _ = curl(proto, "/backend401", hd + [f"Cookie: {ck}"])
                expect(g, f"{proto} backend 401 with a session cookie ({ck[-8:]}) untouched (no redirect, no clearing, no JSON)",
                       st == 401 and body == b"backend-unauthorized" and one(h, "www-authenticate") == 'Basic realm="backend"'
                       and "set-cookie" not in h and "location" not in h, f"{st} {body[:30]!r} {h}")

    g = "marker lost (fallback)"
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/x", nav + [f"Cookie: {COOKIE}=garbage"], port=NOMARKER)
        expect(g, f"{proto} without the marker filter a dead session cookie is still redirected and cleared",
               st == 302 and not check_clears(h.get("set-cookie", []), True), f"{st}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", [f"Cookie: {COOKIE}=forbidden"], port=NOMARKER)
        expect(g, f"{proto} without the marker filter a 403 with a session cookie still passes through", st == 403 and body == b"{}", f"{st}")

    g = "authorizer down"
    # ext_authz cannot reach oauth2-proxy: Envoy answers its own empty 403 (no content-type, no content-length)
    nav = ["Sec-Fetch-Mode: navigate", "Accept: text/html"]
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Sec-Fetch-Mode: cors", f"Cookie: {COOKIE}=stale"], port=DEADGW)
        expect(g, f"{proto} fetch with a session cookie -> 403 passes through with text/plain (not application/json), empty body",
               st == 403 and body == b"" and (one(h, "content-type") or "").startswith("text/plain") and "location" not in h, f"{st} {body[:20]!r} {h}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", nav + [f"Cookie: {COOKIE}=stale"], port=DEADGW)
        expect(g, f"{proto} navigate with a session cookie -> 403 not-permitted page, no redirect, no marker",
               st == 403 and b"<title>Access not permitted</title>" in body and b"temporarily unavailable" in body
               and not check_marker(h.get("set-cookie", []), False) and "location" not in h, f"{st} {body[:40]!r}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", nav, port=DEADGW)
        expect(g, f"{proto} navigate without a cookie -> still 302 to login", st == 302 and not check_marker(h.get("set-cookie", []), True), f"{st}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", nav + [f"Cookie: {RETRY}=1"], port=DEADGW)
        expect(g, f"{proto} second navigate (marker) -> sign-in-failed page that mentions the outage",
               st == 401 and b"Sign-in did not complete" in body and b"temporarily unavailable" in body, f"{st}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Sec-Fetch-Mode: cors"], port=DEADGW)
        expect(g, f"{proto} fetch without a cookie -> 401 JSON", st == 401 and body.decode() == PAYLOAD, f"{st}")

    g = "expired session"
    # cookie position and similar names
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Sec-Fetch-Mode: cors", f"Cookie: a=1; {COOKIE}=garbage; b=2"])
        expect(g, f"{proto} session cookie in the middle of the jar is found (401, cleared)", st == 401 and not check_clears(h.get("set-cookie", []), True), f"{st}")
        st, ver, h, body, rc, err, _ = curl(proto, "/x", ["Sec-Fetch-Mode: cors", f"Cookie: x{COOKIE}=garbage"])
        expect(g, f"{proto} a cookie that only ends in the session cookie's name is not a session (401, no clearing)",
               st == 401 and "set-cookie" not in h and one(h, "www-authenticate") == 'Bearer realm="teknoir"', f"{st} {h}")


def run_large():
    """Bodies far above the listener buffer limit (32 KiB) must stream through untouched: the Lua may only buffer a denial."""
    g = "large bodies not buffered"
    auth = ["Authorization: Bearer good-token"]
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/big", auth)
        expect(g, f"{proto} allowed 20 MiB download arrives complete", st == 200 and rc == 0 and len(body) == BIG
               and hashlib.sha256(body).hexdigest() == SHA[BIG], f"{st} rc {rc} {len(body)} bytes {err}")
        st, ver, h, body, rc, err, _ = curl(proto, "/big403", auth)
        expect(g, f"{proto} 5 MiB backend 403 (marker set) passes untouched", st == 403 and rc == 0 and len(body) == BIG_403
               and hashlib.sha256(body).hexdigest() == SHA[BIG_403] and "www-authenticate" not in h and "location" not in h,
               f"{st} rc {rc} {len(body)} bytes {err}")
        # without credentials the large path is still a small denial, not the backend body
        st, ver, h, body, rc, err, _ = curl(proto, "/big", [])
        expect(g, f"{proto} denied request for the 20 MiB path gets the 401 JSON", st == 401 and body.decode(errors="replace") == PAYLOAD, f"{st} {len(body)}")
    # Fallback (marker patch lost): a backend 403 body over the buffer limit is buffered by the denial branch. That fails the
    # response (500 on HTTP/1.1, the 401 JSON on HTTP/2) but never exposes the backend body; documented in the README.
    for proto in ("h1", "h2"):
        st, ver, h, body, rc, err, _ = curl(proto, "/big403", auth, port=NOMARKER)
        expect("marker lost (fallback)", f"{proto} 5 MiB backend 403 without the marker is never passed through", st != 200 and len(body) < BIG_403
               and not body.startswith(BLOCK[:64]), f"{st} rc {rc} {len(body)} bytes")


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
    ]
    for name, hdrs, want in cases:
        raw = socket.create_connection(("127.0.0.1", GW), timeout=10)
        s = ctx.wrap_socket(raw, server_hostname=HOST)
        try:
            req1 = f"GET /private HTTP/1.1\r\nHost: {HOST}\r\n" + "".join(h + "\r\n" for h in hdrs) + "\r\n"
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


def ws_connect(extra_headers):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(["http/1.1"])
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", GW), timeout=10), server_hostname=HOST)
    req = (f"GET /ws HTTP/1.1\r\nHost: {HOST}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
           "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
           + "".join(h + "\r\n" for h in extra_headers) + "\r\n")
    return s, req


def run_websocket():
    """Real upgrades (Connection: Upgrade, Upgrade: websocket kept): allowed ones switch protocols and echo, denied ones get the 401."""
    g = "websocket upgrade"
    # allowed: 101, then bytes flow both ways through the Lua and ext_authz filters
    s, req = ws_connect(["Sec-Fetch-Mode: websocket", "Authorization: Bearer good-token"])
    try:
        s.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        status = int(head.split(b" ")[1]) if head else 0
        expect(g, "allowed upgrade gets 101", status == 101 and b"upgrade: websocket" in head.lower(), head[:80])
        for msg in (b"ping", os.urandom(100000)):  # the second one is above the 32 KiB buffer limit
            s.sendall(msg)
            got = rest
            rest = b""
            while len(got) < len(msg):
                chunk = s.recv(65536)
                if not chunk:
                    break
                got += chunk
            expect(g, f"allowed upgrade echoes {len(msg)} bytes", got == msg, f"got {len(got)} bytes")
    except Exception as e:  # noqa: BLE001
        expect(g, "allowed upgrade", False, repr(e))
    finally:
        s.close()
    # denied: the contract's 401 with a consistent body and no stray bytes, not a half-switched connection
    for name, hdrs, want, want_challenge in (
        ("no credentials", ["Sec-Fetch-Mode: websocket"], 401, 'Bearer realm="teknoir"'),
        ("bad bearer", ["Sec-Fetch-Mode: websocket", "Authorization: Bearer junk"], 401, 'Bearer realm="teknoir", error="invalid_token"'),
        ("undecodable session cookie", ["Sec-Fetch-Mode: websocket", f"Cookie: {COOKIE}=garbage"], 401, 'Bearer realm="teknoir", error="invalid_token"'),
        ("dead session cookie", ["Sec-Fetch-Mode: websocket", f"Cookie: {COOKIE}=stale"], 401, 'Bearer realm="teknoir", error="invalid_token"'),
    ):
        s, req = ws_connect(hdrs)
        try:
            st, h, body, extra = raw_exchange(s, req)
            ok = (st == want and not extra and len(body) == int(one(h, "content-length") or -1) and body.decode(errors="replace") == PAYLOAD
                  and one(h, "www-authenticate") == want_challenge)
            expect(g, f"denied upgrade ({name}): {st}, body {len(body)} == content-length {one(h, 'content-length')}, 401 JSON, no stray bytes", ok,
                   f"status {st} cl {one(h, 'content-length')} body {len(body)} extra {len(extra)} wa {one(h, 'www-authenticate')!r}")
        except Exception as e:  # noqa: BLE001
            expect(g, f"denied upgrade ({name})", False, repr(e))
        finally:
            s.close()


def run_identity_headers():
    """Client-supplied identity headers never reach the backend (teamspace policies trust x-auth-request-email from the gateway)."""
    g = "identity headers"
    forged = ["X-Auth-Request-Email: root@evil.test", "X-Auth-Request-User: root", "X-Auth-Request-Preferred-Username: root",
              "X-Auth-Request-Groups: admin", "X-Auth-Request-Access-Token: forged", "X-Forwarded-Access-Token: forged",
              "X-Forwarded-Email: root@evil.test", "X-Forwarded-User: root"]
    for proto in ("h1", "h2"):
        # authenticated: the forged copy is replaced by oauth2-proxy's value, every other forged header is gone
        for cred, tag in (([f"Cookie: {COOKIE}=good"], "cookie"), (["Authorization: Bearer good-token"], "bearer")):
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", cred + forged)
            try:
                seen = json.loads(body)
            except ValueError:
                seen = None
            expect(g, f"{proto} {tag}: only oauth2-proxy's email reaches the backend",
                   st == 200 and seen == {"x-auth-request-email": "tester@teknoir.test"}, f"{st} {body[:200]!r}")
        # one forged header at a time, authenticated: none survives except the email oauth2-proxy sets
        for one_h in forged:
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", [f"Cookie: {COOKIE}=good", one_h])
            name = one_h.split(":")[0].lower()
            seen = json.loads(body) if st == 200 else None
            want = {"x-auth-request-email": "tester@teknoir.test"}
            expect(g, f"{proto} forged {name} is stripped", seen == want, f"{st} {body[:200]!r}")
        # allowed by oauth2-proxy but without an email (a token with no email claim): ext_authz has nothing to overwrite
        # the client's copy with, so only the Lua strip keeps a forged x-auth-request-email from becoming the identity
        for cred, tag in (([f"Cookie: {COOKIE}=noemail"], "cookie"), (["Authorization: Bearer noemail-token"], "bearer")):
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", cred + forged)
            seen = json.loads(body) if st == 200 else None
            expect(g, f"{proto} {tag} without an email claim: no forged identity header reaches the backend",
                   seen == {}, f"{st} {body[:200]!r}")
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", cred + ["X-Auth-Request-Email: root@evil.test"])
            seen = json.loads(body) if st == 200 else None
            expect(g, f"{proto} {tag} without an email claim: forged x-auth-request-email is stripped",
                   seen == {}, f"{st} {body[:200]!r}")
        # unauthenticated: the forged headers do not get a request through
        for hdrs, tag in (([], "api"), (["Sec-Fetch-Mode: navigate", "Accept: text/html"], "browser")):
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", forged + hdrs)
            expect(g, f"{proto} {tag} without credentials and with forged headers is still denied",
                   st in (302, 401) and b"root@evil.test" not in body, f"{st}")
            st, ver, h, body, rc, err, _ = curl(proto, "/whoami", ["Authorization: Bearer junk"] + forged)
            expect(g, f"{proto} bad bearer with forged headers is still 401", st == 401, f"{st}")


def main():
    run_matrix()
    run_targeted()
    run_identity_headers()
    run_session_expiry()
    run_large()
    run_raw()
    run_websocket()
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
