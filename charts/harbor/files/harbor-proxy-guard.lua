-- Path guard for Harbor's ghcr proxy-cache project (templates/harbor-proxy-guard.yaml).
-- The chart prepends `local ALLOW_GHCR_ORGS = { ["teknoir"] = true, ... }`.
--
-- The upstream credential of project ghcr can read every package that its owner can read, but
-- robots only need ghcr.io/<allowed org>/... : /v2/ghcr/<org>/... for any other <org> answers 403
-- before harbor-core fetches anything from upstream. The path is normalised first (query
-- dropped, backslashes and percent-escapes decoded until stable, slashes merged, lowercased), so
-- /v2/ghcr%2Fdexidp/..., /v2//ghcr/..., /v2/GHCR/... and double-encoded forms cannot slip by.
-- Dot segments are refused, not resolved: no valid repository name has a "." or ".." component,
-- and resolving them would let harbor-core see a path other than the one judged here
-- (/v2/ghcr/teknoir/..%2F..%2Fdexidp/dex/... judged as /v2/dexidp/..., but routed to project ghcr).
-- Any /v2/ path with a dot segment answers 403.
local function normalize(path)
  local q = string.find(path, "?", 1, true)
  if q then path = string.sub(path, 1, q - 1) end
  local rounds = 0
  while true do
    local decoded = string.gsub(path, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    decoded = string.gsub(decoded, "\\", "/")
    if decoded == path then break end
    path = decoded
    rounds = rounds + 1
    if rounds > 8 then return nil end -- escapes nested deeper than any client sends: refuse
  end
  path = string.gsub(path, "/+", "/")
  local out = {}
  local dots = false
  for seg in string.gmatch(path, "[^/]+") do
    if seg == "." or seg == ".." then dots = true end
    out[#out + 1] = seg
  end
  return string.lower("/" .. table.concat(out, "/")), dots
end

-- Returns true when the (normalised) path is a ghcr proxy request for an organisation that is
-- not allowed (or has none).
local function denied(path)
  local rest = string.match(path, "^/v2/ghcr(/.*)$") or (path == "/v2/ghcr" and "")
  if not rest then return false end
  local org = string.match(rest, "^/([^/]+)")
  if org == nil then return true end
  return ALLOW_GHCR_ORGS[org] ~= true
end

function envoy_on_request(request_handle)
  local raw = request_handle:headers():get(":path") or ""
  local path, dots = normalize(raw)
  if path == nil then
    request_handle:respond({[":status"] = "403", ["content-type"] = "text/plain"},
      "forbidden: ghcr path not allowed\n")
    return
  end
  if string.sub(path, 1, 4) ~= "/v2/" then return end
  if dots then
    request_handle:respond({[":status"] = "403", ["content-type"] = "text/plain"},
      "forbidden: dot segments not allowed\n")
  elseif denied(path) then
    request_handle:respond({[":status"] = "403", ["content-type"] = "text/plain"},
      "forbidden: ghcr organisation not allowed\n")
  end
end
