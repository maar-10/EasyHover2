-- nav/config.lua
-- Config for the NAV role (advanced pc, Basalt UI). Persists /eh2_nav.tbl. Mirrors ui/config.lua
-- (defaults/withDefaults deep-merge/atomic load+save) so the Suite configModule contract fits
-- unchanged.
local M = {}

M.PATH = "/eh2_nav.tbl"

function M.defaults()
  return {
    channel = 65000,          -- GPS broadcast channel to listen on (shared with the beacons)
    beacons = {},             -- expected beacon ids, for an "N of M heard" readout (optional)
    navtable = { name = nil, sign = 1 },  -- this NAV pc's navigation_table + heading sign cal
    relay = { channel = 107 },-- wired channel we relay fix+heading on; the FCS does NOT open this
    thresholds = { maxAgeMs = 3000, minQuality = 0.5 },  -- how a consumer judges the fix (Phase 2)
    modemSide = nil,          -- ender modem for GPS reception
    wiredSide = nil,          -- wired modem to the craft network
    intervalMs = 250,         -- GPS fix relay cadence (trilateration; slow -- GPS moves slowly)
    headingMs  = 80,          -- FAST heading relay cadence (~12Hz): the magnet-table bearing, split
                              -- off the GPS fix so the PFD tape isn't limited by the GPS rate. Each
                              -- tick = 1 getRelativeAngle + 1 transmit (both main-thread tasks) --
                              -- a deliberately conservative shared-server-budget choice.
  }
end

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

function M.withDefaults(cfg)
  return merge(cfg or {}, M.defaults())
end

local SESSION_PATH = "/eh2_nav.session.tbl"

local function loadAt(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

-- Loading current prefers a parseable session overlay (DEFAULT-for-this-boot).
function M.load(path)
  path = path or M.PATH
  if path == M.PATH then
    local cfg = select(1, loadAt(SESSION_PATH))
    if cfg then return cfg, true, nil end
  end
  return loadAt(path)
end

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
