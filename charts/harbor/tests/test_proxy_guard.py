"""Tests of the ghcr path guard (files/harbor-proxy-guard.lua, templates/harbor-proxy-guard.yaml).

The Lua runs in LuaJIT, the Lua flavour of Envoy: with a `luajit` binary on PATH (the CI step runs
in the digest-pinned nickblah/luajit image; LUAJIT_BIN overrides), otherwise from a container image
that must be present locally (LUAJIT_IMAGE, default the same digest). Without either the tests skip
locally and FAIL when CI=1 (or REQUIRE_LUAJIT=1), so the guard cannot go untested in CI. The rendered EnvoyFilter is checked against the file when helm and the chart's
subchart (helm dependency build) are available.
"""
import json
import os
import shutil
import subprocess
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.join(HERE, "..")
LUA = os.path.join(CHART, "files", "harbor-proxy-guard.lua")
IMAGE = os.environ.get("LUAJIT_IMAGE", "nickblah/luajit@sha256:0c1d93093ea91bdb1b93a0c2ccb3b907f48aca901a27d74db8aa660b587c68c4")

# (path as sent by the client, expected status or "pass")
CASES = [
    ("/v2/", "pass"),
    ("/v2/dockerhub/library/busybox/manifests/1.37.0", "pass"),
    ("/v2/ghcr/teknoir/nvr/manifests/ds8.0-gst1.26.8", "pass"),
    ("/v2/ghcr/teknoir/wg-agent/blobs/sha256:abc", "pass"),
    ("/v2/ghcr/teknoir/x?scope=1", "pass"),
    ("/v2/ghcr/Teknoir/x", "pass"),  # Harbor lowercases project paths; the org check is on the lowercased path
    ("/v2/ghcr/teknoir%2Fx", "pass"),  # encoded slash inside an allowed org stays allowed
    ("/v2/ghcr-other/dexidp/dex/manifests/v1", "pass"),  # a different project
    ("/service/token?scope=repository:ghcr/dexidp/dex:pull", "pass"),  # not /v2/: the guard sits on /v2/
    ("/v2/ghcr/dexidp/dex/manifests/v2.45.1", 403),
    ("/v2/ghcr/tekn0ir/private/manifests/x", 403),
    ("/v2/ghcr/teknoir-evil/x/manifests/x", 403),  # prefix of an allowed org is not the org
    ("/v2/ghcr%2Fdexidp%2Fdex/manifests/v2.45.1", 403),
    ("/v2/ghcr%2fdexidp/dex/manifests/v2.45.1", 403),
    ("/v2/ghcr%252Fdexidp/dex/manifests/v2.45.1", 403),  # double-encoded
    ("/v2/ghcr%25252Fdexidp/dex", 403),
    ("/v2//ghcr/dexidp/dex/manifests/v1", 403),  # merged slashes
    ("/v2/ghcr//dexidp/dex/manifests/v1", 403),
    ("/v2/GHCR/dexidp/dex/manifests/v1", 403),  # case
    ("/v2/Ghcr/DexIdp/dex/manifests/v1", 403),
    ("/v2/ghcr/teknoir/../dexidp/dex/manifests/v1", 403),  # dot segments
    ("/v2/ghcr/teknoir/%2e%2e/dexidp/dex/manifests/v1", 403),
    ("/v2/ghcr/teknoir/%2E%2E%2Fdexidp/dex", 403),
    ("/v2/ghcr/./dexidp/dex", 403),
    ("/v2/x/../ghcr/dexidp/dex", 403),
    ("/v2/ghcr/teknoir/..%2F..%2Fdexidp/dex/manifests/v1", 403),  # encoded dot segments climbing out of /v2/ghcr
    ("/v2/ghcr/teknoir/../../dexidp/dex/manifests/v1", 403),
    ("/v2/ghcr/x/..%2F..%2F..%2Fdexidp", 403),
    ("/v2/ghcr/dexidp/..%2Fteknoir/x/manifests/v1", 403),
    ("/v2/ghcr/dexidp%2F..%2Fteknoir/dex/manifests/v1", 403),
    ("/v2/dockerhub/library/../busybox/manifests/1", 403),  # dot segments are refused on every /v2/ path
    ("/v2/ghcr/teknoir/x/..", 403),
    ("/v2/ghcr/teknoir/..x/y", "pass"),  # only whole "." / ".." segments
    ("/v2/ghcr/teknoir/a.b/c", "pass"),
    ("/api/v2.0/projects/../x", "pass"),  # not /v2/: untouched
    ("/v2/ghcr\\dexidp/dex/manifests/v1", 403),  # backslash
    ("/v2/ghcr%5Cdexidp/dex/manifests/v1", 403),
    ("/v2/ghcr", 403),  # no organisation
    ("/v2/ghcr/", 403),
    ("/v2/ghcr?x=/teknoir/", 403),  # a query string cannot supply the org
    ("/v2/ghcr%00/teknoir/x", "pass"),  # a different (nonsense) project name, not ghcr
    ("/v2/ghcr/dexidp/dex/manifests/v1#/teknoir/", 403),
]

HARNESS = """
local cases = {%s}
local failed = 0
for _, c in ipairs(cases) do
  local resp
  local h = {headers = function() return {get = function(_, k) return c[1] end} end,
             respond = function(_, hd, b) resp = hd[":status"] end}
  envoy_on_request(h)
  local got = resp or "pass"
  if got ~= c[2] then failed = failed + 1; print("MISMATCH " .. c[1] .. " got " .. got .. " want " .. c[2]) end
end
print("cases " .. #cases .. " failed " .. failed)
os.exit(failed == 0 and 0 or 1)
"""


def lua_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


LUAJIT_BIN = os.environ.get("LUAJIT_BIN") or shutil.which("luajit")
REQUIRE = os.environ.get("CI") == "1" or os.environ.get("REQUIRE_LUAJIT") == "1"


def luajit_available():
    if LUAJIT_BIN:
        return True
    if not shutil.which("docker"):
        return False
    return subprocess.run(["docker", "image", "inspect", IMAGE], capture_output=True).returncode == 0


def run_lua(code):
    if LUAJIT_BIN:
        cmd = [LUAJIT_BIN, "-"]
    else:
        cmd = ["docker", "run", "--rm", "-i", "--network", "none", IMAGE, "luajit", "-"]
    return subprocess.run(cmd, input=code, capture_output=True, text=True, timeout=120)


class ProxyGuardLuaTest(unittest.TestCase):
    def setUp(self):
        if not luajit_available():
            if REQUIRE:
                self.fail("no luajit binary and no local LuaJIT image, and CI=1 / REQUIRE_LUAJIT=1 forbids skipping")
            self.skipTest("no luajit binary, and docker or the LuaJIT image is not available")

    def chunk(self, orgs, cases):
        allow = "local ALLOW_GHCR_ORGS = { " + ", ".join(f"[{lua_string(o)}] = true" for o in orgs) + " }\n"
        tbl = ", ".join("{%s, %s}" % (lua_string(p), lua_string(str(s))) for p, s in cases)
        return allow + open(LUA).read() + HARNESS % tbl

    def test_cases(self):
        cases = [(p, str(s)) for p, s in CASES]
        r = run_lua(self.chunk(["teknoir"], cases))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"cases {len(CASES)} failed 0", r.stdout)

    def test_allow_list_is_configurable(self):
        cases = [("/v2/ghcr/teknoir/x", "pass"), ("/v2/ghcr/acme/x", "pass"), ("/v2/ghcr/dexidp/x", "403"),
                 ("/v2/ghcr%2Facme/x", "pass")]
        r = run_lua(self.chunk(["teknoir", "acme"], cases))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_empty_allow_list_denies_every_ghcr_path_and_nothing_else(self):
        cases = [("/v2/ghcr/teknoir/x", "403"), ("/v2/quay/x/y/manifests/z", "pass"), ("/v2/", "pass")]
        r = run_lua(self.chunk([], cases))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_deeply_nested_escapes_are_refused(self):
        deep = "/v2/dockerhub/%" + "25" * 12 + "2e/x"  # decodes only after 13 rounds
        r = run_lua(self.chunk(["teknoir"], [(deep, "403")]))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class RenderedFilterTest(unittest.TestCase):
    def render(self, *sets, ok=True):
        if not shutil.which("helm") or not os.path.isdir(os.path.join(CHART, "charts")):
            self.skipTest("helm or the chart's subchart (helm dependency build) is missing")
        cmd = ["helm", "template", "harbor", CHART, "--namespace", "teknoir-system", "-s", "templates/harbor-proxy-guard.yaml"]
        for s in sets:
            cmd += ["--set-json", s]
        p = subprocess.run(cmd, capture_output=True, text=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout if p.returncode == 0 else p.stderr

    def inline_code(self, text):
        start = text.index("inlineCode: |\n") + len("inlineCode: |\n")
        lines = []
        for ln in text[start:].splitlines():
            if ln.startswith(" " * 14) or not ln.strip():
                lines.append(ln[14:])
            else:
                break
        return "\n".join(lines).strip() + "\n"

    def test_rendered_code_is_the_allowlist_plus_the_file(self):
        code = self.inline_code(self.render())
        self.assertTrue(code.startswith('local ALLOW_GHCR_ORGS = { ["teknoir"] = true }\n'))
        self.assertEqual(code.split("\n", 1)[1].strip(), open(LUA).read().strip())

    def test_allow_orgs_values_reach_the_filter(self):
        code = self.inline_code(self.render('harborConfig.proxyGuard.ghcr.allowOrgs=["teknoir","Acme"]'))
        self.assertIn('["teknoir"] = true, ["acme"] = true', code.split("\n")[0])

    def test_disabled_renders_nothing(self):
        # helm refuses `-s` for a template that renders nothing
        out = self.render('harborConfig.proxyGuard.enabled=false', ok=False)
        self.assertIn("could not find template templates/harbor-proxy-guard.yaml", out)


if __name__ == "__main__":
    unittest.main()
