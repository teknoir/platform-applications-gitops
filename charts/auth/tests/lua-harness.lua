-- lua-harness.lua: runs the auth chart's two gateway Lua filters (rendered
-- by tests/lua-test.sh into /w/redirect.lua and /w/authz_ok.lua) against a
-- stub of Envoy's Lua API, in the filter order the EnvoyFilter sets up:
--
--   envoy.filters.http.lua (redirect) -> ext_authz -> envoy.filters.http.lua.authz_ok
--
-- A request runs the redirect filter's envoy_on_request, then ext_authz
-- (simulated: "allow", "deny" or "disabled" for the route); authz_ok's
-- envoy_on_request runs only when ext_authz did not deny. The response (the
-- ext_authz denial reply, or the upstream's answer) then runs the redirect
-- filter's envoy_on_response. Each filter is loaded into its own environment,
-- as each Envoy Lua filter has its own Lua state; they share only the
-- stream's dynamic metadata.
--
-- Env: DOMAIN (gateway/shared host), COOKIE (oauth2-proxy cookie name).
-- Prints PASS/FAIL lines and "RESULT: n passed, m failed"; exits 1 on a
-- failure.

local DOMAIN = os.getenv("DOMAIN") or "teknoir.airgapped"
local COOKIE = os.getenv("COOKIE") or "_teknoir_oauth2_proxy"
local DIR = os.getenv("LUA_DIR") or "/w"

local pass, fail = 0, 0
local function ok(name) print("PASS " .. name); pass = pass + 1 end
local function bad(name, why) print("FAIL " .. name .. ": " .. tostring(why)); fail = fail + 1 end
local function check(name, cond, why)
  if cond then ok(name) else bad(name, why) end
end

local function readfile(p)
  local f = assert(io.open(p, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

-- load_filter: a fresh global environment per filter (own Lua state).
local function load_filter(path)
  local env = setmetatable({}, { __index = _G })
  local chunk = assert(loadstring(readfile(path), "@" .. path))
  setfenv(chunk, env)
  chunk()
  return env
end

-- Header map: case-insensitive names, repeated names allowed (set-cookie).
local function new_headers(init)
  local entries = {}
  local hm = {}
  function hm:get(name)
    name = string.lower(name)
    local vals = {}
    for _, e in ipairs(entries) do
      if e[1] == name then table.insert(vals, e[2]) end
    end
    if #vals == 0 then return nil end
    return table.concat(vals, ",")
  end
  function hm:all(name)
    name = string.lower(name)
    local vals = {}
    for _, e in ipairs(entries) do
      if e[1] == name then table.insert(vals, e[2]) end
    end
    return vals
  end
  function hm:add(name, value)
    assert(type(value) == "string", "header value must be a string")
    table.insert(entries, { string.lower(name), value })
  end
  function hm:remove(name)
    name = string.lower(name)
    local kept = {}
    for _, e in ipairs(entries) do
      if e[1] ~= name then table.insert(kept, e) end
    end
    entries = kept
  end
  function hm:replace(name, value)
    assert(type(value) == "string", "header value must be a string")
    self:remove(name)
    self:add(name, value)
  end
  for _, kv in ipairs(init or {}) do hm:add(kv[1], kv[2]) end
  return hm
end

local function new_body(s)
  if s == nil then return nil end
  local b = { data = s }
  function b:length() return #self.data end
  function b:getBytes(i, n) return string.sub(self.data, i + 1, i + n) end
  function b:setBytes(x) self.data = x; return #x end
  return b
end

-- Stream info with dynamic metadata (set merges keys into a namespace; get
-- returns a copy of the namespace's table, or nil).
local function new_stream()
  local store = {}
  local md = {}
  function md:set(ns, k, v)
    assert(type(v) == "string", "metadata value must be a string here")
    store[ns] = store[ns] or {}
    store[ns][k] = v
  end
  function md:get(ns)
    local t = store[ns]
    if t == nil then return nil end
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
  end
  local si = {}
  function si:dynamicMetadata() return md end
  return si, store
end

local function new_handle(si, headers, body)
  local hd = {}
  function hd:headers() return headers end
  function hd:streamInfo() return si end
  function hd:body() return body end
  function hd:logInfo() end
  function hd:logWarn() end
  function hd:logErr() end
  return hd
end

-- run{req=..., authz=..., status=..., resp=..., body=...}
local function run(c)
  local redirect = load_filter(DIR .. "/redirect.lua")
  local authz_ok = load_filter(DIR .. "/authz_ok.lua")
  local si, store = new_stream()
  local reqh = new_headers(c.req)
  redirect.envoy_on_request(new_handle(si, reqh, nil))
  if c.authz ~= "deny" then
    authz_ok.envoy_on_request(new_handle(si, reqh, nil))
  end
  local resph = new_headers(c.resp)
  resph:replace(":status", c.status)
  local body = new_body(c.body)
  redirect.envoy_on_response(new_handle(si, resph, body))
  return resph, body, store
end

local function urldecode(s)
  return (string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function req(authority, path, extra)
  local r = { { ":authority", authority }, { ":path", path }, { ":method", "GET" }, { ":scheme", "https" } }
  for _, kv in ipairs(extra or {}) do table.insert(r, kv) end
  return r
end

local LOGIN = "https://" .. DOMAIN .. "/oauth2/start?rd="
local DENIAL = "<html><body>Sign in</body></html>"
local function denial_resp()
  return { { "content-type", "text/html; charset=utf-8" }, { "content-length", tostring(#DENIAL) } }
end

local function expired_cookies(h)
  local n_domain, n_host = 0, 0
  for _, v in ipairs(h:all("set-cookie")) do
    local is_ours = string.sub(v, 1, #COOKIE + 2) == COOKIE .. "=;"
    local expires = string.find(v, "Max-Age=0", 1, true) ~= nil
    local secure = string.find(v, "; Secure", 1, true) ~= nil
    if is_ours and expires and secure then
      if string.find(v, "Domain=" .. DOMAIN, 1, true) then n_domain = n_domain + 1 else n_host = n_host + 1 end
    end
  end
  return n_domain, n_host
end

-- authz_ok must be request-only, and the redirect filter must not carry the
-- old cookie heuristic.
do
  local a = load_filter(DIR .. "/authz_ok.lua")
  check("authz_ok: envoy_on_request only", a.envoy_on_request ~= nil and a.envoy_on_response == nil, "unexpected functions")
  local src = readfile(DIR .. "/redirect.lua")
  check("redirect: no has_session cookie heuristic", string.find(src, "has_session", 1, true) == nil, "has_session still present")
end

-- (a) denied, no cookie, navigation -> 302 to /oauth2/start?rd=<encoded URL>
do
  local path = "/catalog?filters%5Bkind%5D=system&x=1"
  local h, body = run { req = req(DOMAIN, path, { { "sec-fetch-mode", "navigate" } }), authz = "deny", status = "403", resp = denial_resp(), body = DENIAL }
  local loc = h:get("location") or ""
  check("(a) denied navigation: 302", h:get(":status") == "302", h:get(":status"))
  check("(a) Location is /oauth2/start on the shared host", string.sub(loc, 1, #LOGIN) == LOGIN, loc)
  local rd = string.sub(loc, #LOGIN + 1)
  check("(a) rd is fully encoded", string.find(rd, "[^%w%-_%.~%%]") == nil, rd)
  check("(a) rd decodes to the requested URL", urldecode(rd) == "https://" .. DOMAIN .. path, urldecode(rd))
  check("(a) empty body, content-length 0", body:length() == 0 and h:get("content-length") == "0", h:get("content-length"))
  check("(a) exactly one Location", #h:all("location") == 1, #h:all("location"))
end

-- (b) denied with a garbage session cookie (no Sec-Fetch-Mode, like curl)
--     -> 302 plus two Set-Cookie headers expiring the session cookie
do
  local h = run { req = req(DOMAIN, "/", { { "cookie", COOKIE .. "=garbage; other=1" } }), authz = "deny", status = "403", resp = denial_resp(), body = DENIAL }
  check("(b) garbage cookie: 302 (not a bare 403)", h:get(":status") == "302", h:get(":status"))
  check("(b) garbage cookie: Location /oauth2/start", string.sub(h:get("location") or "", 1, #LOGIN) == LOGIN, h:get("location"))
  local nd, nh = expired_cookies(h)
  check("(b) expiring Set-Cookie with Domain=" .. DOMAIN, nd == 1, nd)
  check("(b) expiring host-only Set-Cookie", nh == 1, nh)
end

-- (c) denied fetch/XHR/websocket -> 401, no Location, no cookie change
for _, v in ipairs({
  { "sec-fetch-mode", "cors" }, { "sec-fetch-mode", "same-origin" }, { "sec-fetch-mode", "no-cors" },
  { "sec-fetch-mode", "websocket" }, { "x-requested-with", "XMLHttpRequest" },
}) do
  local name = "(c) " .. v[1] .. ": " .. v[2]
  local resp = denial_resp()
  table.insert(resp, { "location", "https://" .. DOMAIN .. "/oauth2/sign_in" })
  local h, body = run { req = req(DOMAIN, "/api/catalog/entities", { v }), authz = "deny", status = "403", resp = resp, body = DENIAL }
  check(name .. " -> 401", h:get(":status") == "401", h:get(":status"))
  check(name .. " -> no Location", h:get("location") == nil, h:get("location"))
  check(name .. " -> no Set-Cookie added", #h:all("set-cookie") == 0, #h:all("set-cookie"))
  check(name .. " -> empty body", body:length() == 0 and h:get("content-length") == "0", body:length())
end

-- (d)/(e) ext_authz allowed, the upstream answers 401/403 -> unchanged
for _, st in ipairs({ "401", "403" }) do
  local tag = st == "401" and "(d)" or "(e)"
  local h, body = run {
    req = req(DOMAIN, "/api/catalog/entities", { { "cookie", COOKIE .. "=valid" }, { "sec-fetch-mode", "navigate" } }),
    authz = "allow", status = st, resp = { { "www-authenticate", "Bearer" }, { "content-length", "8" } }, body = "upstream",
  }
  check(tag .. " signed in, upstream " .. st .. " passes through", h:get(":status") == st and h:get("location") == nil, h:get(":status"))
  check(tag .. " upstream body and headers kept", body:length() == 8 and h:get("www-authenticate") == "Bearer" and #h:all("set-cookie") == 0, body:length())
end

-- (e2) ext_authz disabled for the route (argocd vhost): upstream 401 unchanged
do
  local h = run { req = req("argocd." .. DOMAIN, "/api/v1/applications"), authz = "disabled", status = "401", resp = {}, body = "nope" }
  check("(e2) ext_authz disabled, upstream 401 passes through", h:get(":status") == "401" and h:get("location") == nil, h:get(":status"))
end

-- (f) /oauth2/* is never rewritten: a denial there, or oauth2-proxy's own 403
do
  local h = run { req = req(DOMAIN, "/oauth2/callback?code=x&state=y"), authz = "deny", status = "403", resp = denial_resp(), body = DENIAL }
  check("(f) /oauth2/callback denied -> unchanged 403", h:get(":status") == "403" and h:get("location") == nil, h:get(":status"))
  h = run { req = req(DOMAIN, "/oauth2/callback?code=x&state=y"), authz = "disabled", status = "403", resp = denial_resp(), body = DENIAL }
  check("(f) /oauth2/callback upstream 403 -> unchanged", h:get(":status") == "403" and h:get("location") == nil, h:get(":status"))
end

-- (g) 200 and other statuses -> unchanged
for _, st in ipairs({ "200", "302", "404", "500" }) do
  local resp = { { "content-length", "2" } }
  if st == "302" then table.insert(resp, { "location", "https://" .. DOMAIN .. "/elsewhere" }) end
  local h, body = run { req = req(DOMAIN, "/"), authz = "allow", status = st, resp = resp, body = "ok" }
  check("(g) " .. st .. " unchanged", h:get(":status") == st and body:length() == 2 and #h:all("set-cookie") == 0, h:get(":status"))
end

-- (h) rd comes from :authority/:path, not from client-supplied X-Forwarded-*
do
  local h = run {
    req = req("grafana." .. DOMAIN, "/d/abc?orgId=1", { { "x-forwarded-host", "evil.example" }, { "x-forwarded-uri", "/evil" }, { "x-forwarded-proto", "http" } }),
    authz = "deny", status = "403", resp = denial_resp(), body = DENIAL,
  }
  local loc = h:get("location") or ""
  check("(h) login on the shared host for a subdomain", string.sub(loc, 1, #LOGIN) == LOGIN, loc)
  check("(h) rd ignores X-Forwarded-*", urldecode(string.sub(loc, #LOGIN + 1)) == "https://grafana." .. DOMAIN .. "/d/abc?orgId=1", loc)
end

-- (i) a denial reply that is 401 and carries its own Location -> one Location, ours
do
  local resp = denial_resp()
  table.insert(resp, { "location", "https://" .. DOMAIN .. "/oauth2/sign_in" })
  local h = run { req = req(DOMAIN, "/x"), authz = "deny", status = "401", resp = resp, body = DENIAL }
  check("(i) 401 denial -> 302 with a single /oauth2/start Location", h:get(":status") == "302" and #h:all("location") == 1 and string.sub(h:get("location"), 1, #LOGIN) == LOGIN, h:get("location"))
end

-- (j) a denial without a body (headers only) -> 302, content-length 0
do
  local h = run { req = req(DOMAIN, "/"), authz = "deny", status = "403", resp = {}, body = nil }
  check("(j) header-only denial -> 302, content-length 0", h:get(":status") == "302" and h:get("content-length") == "0", h:get(":status"))
end

print(string.format("RESULT: %d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
