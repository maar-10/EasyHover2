-- controller/config.lua
-- Config for the GPS beacon controller (basic computer, no Basalt). Persists /eh2_beacon_control.tbl.
-- Mirrors beacon/config.lua / nav/config.lua exactly (load returns the SAVED table pre-merge;
-- withDefaults deep-merges; save is atomic tmp-write + fs.move) so the Suite's configModule contract
-- fits with no special-casing.
local M = {}

M.PATH = "/eh2_beacon_control.tbl"

function M.defaults()
  return {
    channel = 65000,       -- shared GPS channel, same as every beacon + NAV
    updateToken = nil,     -- shared secret for remote update commands; unset = controller can't send
    -- Persisted beacon registry: known beacons + operator annotations + last-known position.
    -- [id] = { name=nil, expectedPos=nil, lastPos=nil }. Runtime-only fields (lastSeen/status/
    -- lastReply/lastQueried/lastAck) are NEVER persisted here -- see controller/runtime.lua.
    roster = {},
  }
end

-- Deep-merge: maps recurse, everything else = saved-if-present-else-default.
local function merge(saved, defaults)
  local out = {}
  for k, v in pairs(defaults) do
    local sv = saved[k]
    if type(v) == "table" and type(sv) == "table" then
      out[k] = merge(sv, v)
    elseif sv ~= nil then
      out[k] = sv
    else
      out[k] = v
    end
  end
  for k, v in pairs(saved) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

--- Additive: saved values over fresh defaults (deep-merged).
function M.withDefaults(cfg)
  return merge(cfg or {}, M.defaults())
end

--- Read + unserialise the SAVED table (pre-merge). Never throws.
--- Returns cfg|nil, existed, err. existed=true with err set means present-but-unparseable.
function M.load(path)
  path = path or M.PATH
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

--- Atomic write: tmp + move.
function M.save(path, cfg)
  path = path or M.PATH
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(cfg)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true, nil
end

return M
