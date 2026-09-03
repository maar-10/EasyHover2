-- UI-role config module for the EasyHover 2 UI Suite.
-- Persists /eh2_ui_config.tbl. Mirrors fcs/io/config.lua's structure
-- (load returns the saved table pre-merge; withDefaults deep-merges;
-- save is atomic tmp-write + fs.move).
local M = {}

-- The full default UI config.
function M.defaults()
  return {
    assign = {},                       -- [monitorName]=panelId ("engine"|"fcs"|"config")
    -- Ordered, never-forget list of every monitor the UI/NAV PC has ever seen (CONFIG page's
    -- MONITOR SELECTION list). A remembered-but-absent monitor stays here with its assign so it
    -- works the instant it is plugged back in. Connection state is derived live, never stored.
    monitorOrder = {},                 -- { <monitor peripheral name>, ... }
    relay  = { name = nil, side = nil, blockSide = nil, feedSide = nil },
    fuel   = {
      pump = { name = nil, kind = "inventory", empty = 0, full = 0 },
      tank = { name = nil, kind = "inventory", empty = 0, full = 0 },
    },
    -- intervalMs = gap between feeds. Must be shorter than the engine's burn time; one blaze
    -- cake in a superheated engine lasts ~5m30s on this server, so feed one every 5m30s.
    -- Adjusted in the UI in +/-15s steps; pulseMs (funnel-open time) stays in ms.
    engine = { mode = "basic", pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    sens = { source = "FCS" },
    -- PFD cockpit-page redraw cadence (ms). Tunable in BIT/CONFIG -> PFD RATE. The dirty-gate is
    -- kept (only unchanged frames are skipped); this sets how often it checks/repaints. Faster =
    -- smoother but more shared-server render budget (watch the FCS loopHz). See ui/basalt/app.lua.
    pfd = { renderMs = 100 },
    -- Cockpit colour scheme (BIT/CONFIG -> UI CAL -> UI SETTINGS). Background is hardcoded black in
    -- ui/theme.lua; these pick the font/button/NAV-cue colours + an optional colourblind palette.
    -- Values are ui/theme.lua colour keys / colourblind mode keys.
    colors = { font = "green", button = "darkGray", wpt = "yellow", rt = "blue", colorblind = "none" },
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

-- Additive: saved values over fresh defaults (deep-merged).
function M.withDefaults(cfg)
  return merge(cfg or {}, M.defaults())
end

-- Read + unserialise the SAVED table (pre-merge). Never throws.
-- Returns cfg|nil, existed, err. existed=true with err set means present-but-unparseable.
-- Loading current prefers a parseable session overlay (DEFAULT-for-this-boot).
local CURRENT_PATH = "/eh2_ui_config.tbl"
local SESSION_PATH = "/eh2_ui_config.session.tbl"

local function loadAt(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false, nil end
  local f = fs.open(path, "r")
  if not f then return nil, true, "could not open" end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true, "not a table" end
  return cfg, true, nil
end

function M.load(path)
  if path == CURRENT_PATH then
    local cfg = select(1, loadAt(SESSION_PATH))
    if cfg then return cfg, true, nil end
  end
  return loadAt(path)
end

-- Atomic write: tmp + move.
function M.save(path, cfg)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(cfg)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true, nil
end

return M
