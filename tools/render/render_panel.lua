-- tools/render/render_panel.lua
-- Runs headless in CraftOS-PC. Mounts REAL EasyHover 2 Basalt panels into a recording terminal
-- (tools/render/rec_term) sized to their monitor surface, applies a representative state, renders,
-- and serialises each captured cell grid to /render_out_<id>.txt for the host-side SVG generator.
-- PANEL = one recipe id, or "all" to render every panel in one boot. See the basalt-render skill.
local Rec = require("tools.render.rec_term")
local Nav = require("ui.basalt.nav")
local basalt = require("ui.basalt.app").ensureBasalt()
local Theme = require("ui.theme")

local PANEL = _G.EH2_RENDER_PANEL or "pfd"
-- Apply the cockpit colour scheme exactly like ui/basalt/app.lua's M.run: a global custom theme
-- (black bg everywhere + font/button colours) + palette overrides per recording term. Override
-- _G.EH2_RENDER_COLORS to preview a specific choice / colourblind mode; defaults otherwise.
local COLORS = _G.EH2_RENDER_COLORS or Theme.DEFAULTS
Theme.applyTheme(basalt, COLORS)

-- ---- permissive mocks (deps the various build()s take; enough to render a default form) ----
local function noop() end
local function readStub() return nil end            -- no saved config -> panel shows its defaults
local function scanStub() return {} end
local function sampler() return { pitch = 0, roll = 0, heading = 0, yaw = 0 } end
local deps = { save = noop, read = readStub, write = noop, delete = noop, scan = scanStub,
               sampler = sampler, sample = sampler }

-- A rich-enough runtime for the pages that read live config/engine state (emc/fcs/config/flight).
local Config = require("ui.config")
local cfg = Config.withDefaults({
  assign = { monitor_0 = "emc", monitor_1 = "fcs" },
  relay  = { name = "redstone_relay_0", side = "back" },
  fuel   = { pump = { name = "pump_0", kind = "inventory", empty = 0, full = 100 },
             tank = { name = "tank_0", kind = "fluid", empty = 0, full = 1000 } },
  engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true },
})
local engineStub = {}
function engineStub:status() return { master = false, feeding = false, pulses = 0, nextFeedInMs = nil } end
function engineStub:setMaster() end
function engineStub:feedNow() end
-- Stub the comms links + command sender so opening a region that drives M.setParamsOpen
-- (fcs_params) does not nil-index runtime.links/sender during a headless render.
local noopSend = { send = function() end }
local runtime = { config = cfg, engine = engineStub, monitors = { "monitor_0", "monitor_1" }, uiRev = 0,
  links = { tel = noopSend, cmd = noopSend }, sender = noopSend }

-- ---- panel registry: id -> { W, H, build(basalt, frame) -> handle, [postBuild(handle)], [state] } ----
-- Resolutions match each panel's PARENT surface: PFD 36x24; overhead FLIGHT + its region drilldowns
-- 36x38; NAV page + ALL BIT/CONFIG drilldowns + WPT entry panels 36x10; CONFIG on the UI-PC shell
-- (advanced-computer terminal) 51x19; A/P 15x10.
local function P(mod) return require(mod) end
local function flightBuild(b, f) return P("ui.basalt.pages.flight").build(b, f, runtime, nil) end
-- Shared demo state so every mock that shows the FCS mode region renders a selected mode (LDG lime
-- + CPL lime) against the dim-green unselected ones, instead of an all-unselected default.
local FLIGHT_STATE = { engaged = true, gndSafety = false, flightMode = "LDG", masterMode = "CPL",
                       fuel = "Biodiesel", fuelPct = 60 }
local RECIPES = {
  -- PFD (2x2 = 36x24)
  pfd     = { W = 36, H = 24, state = { heading = 45, pitch = 0.14, roll = 0.21, baroAlt = 128.6, sas = 145,
              target = { name = "Pad-2", bearing = 70, relBearing = 25, distanceH = 420, altDelta = 12, color = "green" } },
              build = function(b, f) return P("ui.basalt.pages.pfd").build(b, f, {}, nil) end },

  -- Overhead (2w x 3h = 36x38): merged FLIGHT page + its in-context region drilldowns
  flight        = { W = 36, H = 38, build = flightBuild, state = FLIGHT_STATE },
  flight_engine = { W = 36, H = 38, build = flightBuild, state = FLIGHT_STATE, postBuild = function(h) h.elements.top:push("emc_config") end },
  flight_calfuel= { W = 36, H = 38, build = flightBuild, state = FLIGHT_STATE, postBuild = function(h) h.elements.top:push("emc_calfuel") end },
  flight_params = { W = 36, H = 38, build = flightBuild, state = FLIGHT_STATE, postBuild = function(h) h.elements.bottom:push("fcs_params") end },

  -- NAV surface (2w x 1h = 36x10): NAV page + BIT/CONFIG drilldowns + WPT entry panels
  nav        = { W = 36, H = 10, build = function(b, f)
      local rt = { wptClient = { store = { routes = {}, waypoints = {
        { name = "Home",  type = "base",     x = 0,    y = 64, z = 0 },
        { name = "Pad-2", type = "pad",      x = 120,  y = 70, z = -40 },
        { name = "Ridge", type = "wp",       x = -200, y = 92, z = 310 },
        { name = "North", type = "outpost",  x = 40,   y = 80, z = 500 },
        { name = "Depot", type = "facility", x = 88,   y = 61, z = 12 } } } } }
      return P("ui.basalt.pages.nav").build(b, f, rt, Nav.new("nav")) end },
  hub        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.hub").build(b, f, nil, Nav.new("hub")) end },
  tuning     = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.tuning").build(b, f, nil, Nav.new("tuning"), readStub, noop, noop) end },
  tuning_edit = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.tuning").build(b, f, nil, Nav.new("tuning"), readStub, noop, noop) end,
                  postBuild = function(h) h.elements.region:push("edit_PRECISION_FEEL") end },
  tuning_brake = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.tuning").build(b, f, nil, Nav.new("tuning"), readStub, noop, noop) end,
                  postBuild = function(h) h.elements.region:push("edit_CRUISE_FEEL_extra") end },
  mdb        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.mdb").build(b, f, nil, Nav.new("mdb"), readStub, noop, scanStub) end },
  uical      = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.uical").build(b, f, runtime, Nav.new("uical"), deps) end },
  uical_settings = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.uical").build(b, f, runtime, Nav.new("uical"), deps) end,
                     postBuild = function(h) h.elements.region:push("settings") end },
  senscal    = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.senscal").build(b, f, nil, Nav.new("senscal"), readStub, noop, sampler) end },
  senssource = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.senssource").build(b, f, {}, Nav.new("senssource"), readStub, noop, sampler) end },
  dtc        = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.dtc").build(b, f, nil, Nav.new("dtc"), deps) end },
  pfdrate    = { W = 36, H = 10, build = function(b, f) return P("ui.basalt.bitconfig.pfd").build(b, f, {}, Nav.new("pfdrate"), { save = noop }) end },
  -- WPT / entry panels that open over the NAV surface (overlays fill the 36x10 frame)
  waypointlist = { W = 36, H = 10, build = function(b, f)
      local ctrl = P("ui.basalt.waypointlist").make(f, { rows = 6, selColor = colors.yellow })
      ctrl.setItems({
        { name = "Home",  type = "base" },   { name = "Pad-2", type = "pad" },
        { name = "Ridge", type = "wp" },     { name = "North", type = "outpost" },
        { name = "Depot", type = "facility" } })
      ctrl.selectRow(2); ctrl.refresh(); return {} end },
  keypad_name = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.keypad").make(f).show({ title = "WPT NAME", mode = "name", value = "Home" }); return {} end },
  keypad_num  = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.keypad").make(f).show({ title = "X", mode = "num", value = "128" }); return {} end },
  listpicker  = { W = 36, H = 10, build = function(b, f)
      P("ui.basalt.listpicker").make(f).show({ title = "BIND PUMP", options = {
        { text = "(none)", value = false }, { text = "create:item_vault_7", value = "v7" },
        { text = "pump_0", value = "pump_0" }, { text = "tank_0", value = "tank_0" } } }); return {} end },

  -- CONFIG on the UI-PC shell (advanced computer terminal, native = 51x19, no monitor scaling)
  config  = { W = 51, H = 19, build = function(b, f)
      local rt = { monitors = { "monitor_0", "monitor_1", "monitor_5" },
        config = { assign = { monitor_0 = "flight", monitor_1 = "nav", monitor_5 = "pfd" },
                   monitorOrder = { "monitor_0", "monitor_1", "monitor_3", "monitor_5" } } }
      return P("ui.basalt.pages.config").build(b, f, rt) end },

  -- A/P (1x1 = 15x10)
  ap      = { W = 15, H = 10, build = function(b, f) return P("ui.basalt.pages.ap").build(b, f, {}) end },

  -- Beacon controller ROSTER (advanced-computer terminal, native = 51x19, no monitor scaling).
  -- A fake runtime stub is enough -- controller/app.lua's M.build only ever calls
  -- runtime:sendCommandAll from a button's onClick, never at build time.
  controller_roster = { W = 51, H = 19, build = function(b, f)
      local rt = { sendCommandAll = function() end }
      return P("controller.app").build(b, f, rt) end,
    state = {
      { id = "beacon-67", name = "North Pillar", status = "LIVE",     pos = { x = -7737, y = -54, z = 7579 }, ageMs = 600 },
      { id = "beacon-68", name = "Buddy's Base", status = "SILENT",   pos = { x = 6462,  y = 200, z = 6107 }, ageMs = 183000 },
      { id = "beacon-69", name = nil,            status = "DISABLED", pos = { x = 7144,  y = 65,  z = -7266 }, ageMs = 900 },
      { id = "beacon-70", name = "South Mark",   status = "OFFLINE",  pos = nil, ageMs = nil },
      { id = "beacon-71", name = "East Spire",   status = "LIVE",     pos = { x = 120,   y = 70,  z = -40 }, ageMs = 800 },
    } },

  -- Beacon controller DIAG page (Phase P5b) -- the active-poll status table + "polling..."
  -- indicator (design 3.1). A fake runtime is enough: M.buildDiag never calls runtime itself
  -- (queryAll is entirely controller/diag.lua's job, driven by the app's own timer coroutine).
  controller_diag = { W = 51, H = 19, build = function(b, f)
      return P("controller.app").buildDiag(b, f, {}) end,
    state = {
      { id = "beacon-67", name = "North Pillar", enabled = true,
        health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 1000 },
        lastReplyAgeMs = 420 },
      { id = "beacon-68", name = "Buddy's Base", enabled = false,
        health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 3000 },
        lastReplyAgeMs = 1800 },
      { id = "beacon-69", name = nil, enabled = true,
        health = { selfCheck = { ok = false, mismatches = 2 }, constellation = { hosts = 2, grade = "FAIR" }, intervalMs = 1000 },
        lastReplyAgeMs = 900 },
      { id = "beacon-70", name = "South Mark", enabled = nil, health = nil, lastReplyAgeMs = nil },
    } },

  -- Beacon controller DETAIL page (Phase P5c) -- the per-beacon info block + action grid. A fake
  -- runtime is enough -- every action button's onClick only ever reaches runtime:sendCommand/
  -- setName/setExpectedPos/remove, never called at build time. The harness's own generic
  -- `handle.apply(r.state or {})` call passes only ONE arg (view) -- buildDetail's apply(view, id)
  -- needs a second -- so this recipe wraps `apply` to default a nil id to the demo beacon, letting
  -- the harness's normal single-arg call still land on the right beacon with no postBuild needed.
  controller_detail = { W = 51, H = 19, build = function(b, f)
      local rt = { sendCommandAll = function() end, sendCommand = function() end,
        setName = function() end, setExpectedPos = function() end, remove = function() end }
      local h = P("controller.app").buildDetail(b, f, rt)
      local realApply = h.apply
      h.apply = function(view, id) return realApply(view, id or "beacon-68") end
      return h end,
    state = {
      { id = "beacon-68", name = "Buddy's Base", status = "SILENT", enabled = false,
        pos = { x = 6462, y = 200, z = 6107 }, expectedPos = { x = 6460, y = 200, z = 6105 },
        health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 3000 } },
    } },

  -- Same DETAIL page, but with the SET POS sub-form popped open (postBuild clicks the button after
  -- the demo beacon is applied) -- shows the X/Y/Z field-button + SEND/CANCEL overlay in one shot.
  controller_detail_setpos = (function()
    local demoView = {
      { id = "beacon-68", name = "Buddy's Base", status = "SILENT", enabled = false,
        pos = { x = 6462, y = 200, z = 6107 }, expectedPos = { x = 6460, y = 200, z = 6105 },
        health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 3000 } },
    }
    return { W = 51, H = 19, build = function(b, f)
        local rt = { sendCommandAll = function() end, sendCommand = function() end,
          setName = function() end, setExpectedPos = function() end, remove = function() end }
        local h = P("controller.app").buildDetail(b, f, rt)
        local realApply = h.apply
        h.apply = function(view, id) return realApply(view, id or "beacon-68") end
        return h end,
      state = demoView,
      postBuild = function(h)
        h.apply(demoView, "beacon-68")
        h.elements.grid.buttons.setpos.button:fireEvent("mouse_click", 1, 1, 1)
      end }
  end)(),

  -- DESIGN PROTO: the FLIGHT panel's EMC (top) region redesign -- bordered panel, full-width gauges,
  -- 3-row outlined ENG SW/PRIME, an orange double-border status box + CONFIG. EH2_RENDER_PANEL=proto_flight_emc
  proto_flight_emc = { W = 36, H = 17, build = function(b, f)
    local PG = require("ui.basalt.instruments.panelgfx")
    -- background decoration image (low z: behind the interactive elements)
    local bgimg = f:addImage({ x = 1, y = 1, width = 36, height = 17 }); bgimg:resizeImage(36, 17)
    bgimg.set("z", 1)
    PG.clear(bgimg, 36, 17)
    PG.border(bgimg, 36, 17, colors.green, { top = true, left = true, right = true, bottom = false })
    PG.doubleBox(bgimg, 3, 10, 17, 15, colors.orange)   -- inset from the panel border (black gap)
    -- gauges: label (left) + amount (right) on one row, full-width bar below
    local function lbl(x, y, wd, t, col) local l = f:addLabel({ x = x, y = y, width = wd, height = 1, autoSize = false, text = t }); l:setForeground(col or colors.lime); return l end
    lbl(3, 2, 20, "Solid Pump BZC"); lbl(28, 2, 6, "128x")
    local pb = f:addProgressBar({ x = 3, y = 3, width = 31, height = 1 }); pb:setProgressColor(colors.green); pb:setBackground(colors.gray); pb:setProgress(64)
    lbl(3, 4, 20, "Liquid Main BDSL"); lbl(28, 4, 6, "180B")
    local mb = f:addProgressBar({ x = 3, y = 5, width = 31, height = 1 }); mb:setProgressColor(colors.green); mb:setBackground(colors.gray); mb:setProgress(45)
    -- ENG SW (green/red outline) + PRIME (orange) -- 3-row, centred, spaced
    local function obtn(x, w, text, col) local btn = f:addButton({ x = x, y = 7, width = w, height = 3, text = text }); btn:setBackground(colors.gray); btn:setForeground(colors.lime); btn:addBorder(col); return btn end
    obtn(8, 10, "ENG SW", colors.red)      -- off -> red
    obtn(19, 10, "PRIME", colors.orange)
    -- status text inside the orange box (black interior), spaced from the inner border
    lbl(6, 12, 10, "ENG OFF"); lbl(6, 13, 10, "FEED NO")
    -- CONFIG (blue outline) 3-row, right of the status box
    local cfg = f:addButton({ x = 21, y = 12, width = 13, height = 3, text = "CONFIG" }); cfg:setBackground(colors.gray); cfg:setForeground(colors.lime); cfg:addBorder(colors.blue)
    return {} end },

  -- DESIGN PROTO: the FLIGHT panel's FCS (bottom) region -- 3 sub-regions (controls / master modes /
  -- flight modes) split by orange dividers. EH2_RENDER_PANEL=proto_fcs
  proto_fcs = { W = 36, H = 21, build = function(b, f)
    local PG = require("ui.basalt.instruments.panelgfx")
    local bg = f:addImage({ x = 1, y = 1, width = 36, height = 21 }); bg:resizeImage(36, 21); bg.set("z", 1)
    PG.clear(bg, 36, 21)
    PG.border(bg, 36, 21, colors.green, { top = false, bottom = true, left = true, right = true })
    PG.hline(bg, 6, 4, 33, colors.orange)    -- divider between controls and master modes
    PG.hline(bg, 12, 4, 33, colors.orange)   -- divider between master modes and flight modes
    -- 3-row outlined control button
    local function ctrl(x, y, w, text, col)
      local btn = f:addButton({ x = x, y = y, width = w, height = 3, text = text })
      btn:setBackground(colors.gray); btn:setForeground(colors.lime); btn:addBorder(col); return btn
    end
    -- 2-row mode button: a top CHIP (feedback-coloured bar) over a label button
    local function mode(x, y, w, text, chip)
      local c = f:addButton({ x = x, y = y, width = w, height = 1, text = "" }); c:setBackground(chip)
      local l = f:addButton({ x = x, y = y + 1, width = w, height = 1, text = text }); l:setBackground(colors.gray); l:setForeground(colors.lime)
    end
    -- Sub-region 1: FCS controls (rows 2-4)
    ctrl(4, 2, 8, "FCS", colors.red)          -- disengaged -> red
    ctrl(14, 2, 8, "GND", colors.red)
    ctrl(24, 2, 10, "PARAM", colors.blue)
    -- Sub-region 2: master modes + trim (rows 8-9) -- one active mode = green, others red; trim = orange
    mode(3, 8, 7, "CPL", colors.red); mode(11, 8, 7, "DCPL", colors.green); mode(19, 8, 7, "TRIM UP", colors.orange); mode(27, 8, 7, "TRIM DN", colors.orange)
    -- Sub-region 3: flight modes (rows 14-15, 17-18) -- radio, one green
    mode(3, 14, 10, "PRE", colors.red);  mode(14, 14, 10, "MAN", colors.red); mode(25, 14, 10, "CRU", colors.red)
    mode(3, 17, 10, "DRN", colors.red);  mode(14, 17, 10, "NOL", colors.red); mode(25, 17, 10, "TRK", colors.red)
    return {} end },

  -- DESIGN PROTO: the 4 ADI centre-body options (wings + each body glyph), for picking one.
  proto_bodies = { W = 36, H = 10, build = function(b, f)
    local ADI = require("ui.basalt.instruments.adi")
    local img = f:addImage({ x = 1, y = 1, width = 36, height = 10 }); img:resizeImage(36, 10)
    for y = 1, 10 do for x = 1, 36 do img:setPixel(x, y, " ", "f", "f") end end
    local names = { "circle", "ring", "square", "diamond" }
    for i, name in ipairs(names) do
      local y = i * 2
      for x = 16, 19 do img:setPixel(x, y, " ", "4", "4") end   -- left wing
      for x = 23, 26 do img:setPixel(x, y, " ", "4", "4") end   -- right wing
      ADI.BODIES[name](img, 21, y, 36, 10)                       -- centre body at cx=21
      img:setText(1, y, name); img:setFg(1, y, string.rep("5", #name))  -- lime label
    end
    return {} end },

}

-- DESIGN PROTO: the NAV strip redesign. NO button fills (monitors give only tap + no hover, so a cell
-- is either a glyph or a 2-colour block, never both) -- instead font-on-background buttons wrapped in
-- COLOURED BRACKETS: blue [] for menu buttons (WPT/RT/DTC, BIT/CONFIG), orange [] for functions
-- (UP/DOWN), orange {} for the cycling FILTER. The WPT/RT list sits on a distinct bg colour with a
-- right-triangle bullet per row; a selected row turns to its cue colour (WPT=yellow, RT=blue) with <>
-- brackets and a matching triangle. Rendered against every list-bg slot (except A/P's pink+purple).
local function navProto(basalt, frame, listBg)
  local img = frame:addImage({ x = 1, y = 1, width = 36, height = 10 }); img:resizeImage(36, 10); img.set("z", 1)
  local FG   = colors.toBlit(Theme.role("font"))   -- green font
  local MENU = colors.toBlit(colors.blue)          -- menu-button brackets
  local FUNC = colors.toBlit(colors.orange)        -- function-button brackets + filter braces
  local SELW = colors.toBlit(colors.yellow)        -- selected WPT (cue colour)
  local SELR = colors.toBlit(colors.blue)          -- selected RT  (cue colour)
  local K    = colors.toBlit(colors.black)         -- panel background
  local LB   = colors.toBlit(listBg)               -- list background
  local TRI  = string.char(16)                      -- right-pointing triangle bullet
  local function put(x, y, text, fg, bg) for i = 1, #text do img:setPixel(x + i - 1, y, text:sub(i, i), fg, bg) end end
  local function brk(x, y, open, label, close, br, bg) put(x, y, open, br, bg); put(x + 1, y, label, FG, bg); put(x + 1 + #label, y, close, br, bg) end
  -- fill: black panel, then the coloured list band (rows 2-8)
  for y = 1, 10 do for x = 1, 36 do img:setPixel(x, y, " ", FG, K) end end
  for y = 2, 8 do for x = 1, 36 do img:setPixel(x, y, " ", FG, LB) end end
  -- header: menu tabs (blue) + cycling filter (orange braces)
  brk(1, 1, "[", "WPT", "]", MENU, K); brk(7, 1, "[", "RT", "]", MENU, K); brk(12, 1, "[", "DTC", "]", MENU, K)
  brk(30, 1, "{", "all", "}", FUNC, K)
  -- list rows: triangle bullet + name; a selected row uses its cue colour + <> brackets
  local function item(y, name, sel)
    local col = FG; if sel == "wpt" then col = SELW elseif sel == "rt" then col = SELR end
    put(2, y, TRI, col, LB)
    if sel then put(4, y, "<" .. name .. ">", col, LB) else put(4, y, name, col, LB) end
  end
  item(2, "Home", nil); item(3, "Pad-2", "wpt"); item(4, "Ridge", nil)
  item(5, "Route-1", "rt"); item(6, "North", nil); item(7, "Vault", nil)
  -- footer: UP/DOWN (orange functions) + BIT/CONFIG (blue menu)
  brk(1, 10, "[", "UP", "]", FUNC, K); brk(6, 10, "[", "DOWN", "]", FUNC, K); brk(24, 10, "[", "BIT/CONFIG", "]", MENU, K)
  return {}
end

-- one recipe per list-bg colour slot (A/P's pink + purple excluded)
local NAV_BG = {
  { "white", colors.white }, { "orange", colors.orange }, { "magenta", colors.magenta },
  { "lightBlue", colors.lightBlue }, { "yellow", colors.yellow }, { "lime", colors.lime },
  { "gray", colors.gray }, { "lightGray", colors.lightGray }, { "cyan", colors.cyan },
  { "blue", colors.blue }, { "brown", colors.brown }, { "green", colors.green },
  { "red", colors.red }, { "black", colors.black },
}
for _, e in ipairs(NAV_BG) do
  RECIPES["nav_bg_" .. e[1]] = { W = 36, H = 10, build = function(b, f) return navProto(b, f, e[2]) end }
end

local ORDER = { "pfd", "flight", "flight_engine", "flight_calfuel", "flight_params",
                "nav", "hub", "tuning", "mdb", "uical", "uical_settings", "senscal", "senssource", "dtc", "pfdrate",
                "waypointlist", "keypad_name", "keypad_num", "listpicker", "config", "ap", "controller_roster", "controller_diag", "controller_detail", "controller_detail_setpos" }

-- Render one recipe into a fresh rec-term and serialise it to /render_out_<id>.txt.
local function renderOne(id)
  local r = RECIPES[id]
  if not r then return end
  local rec = Rec.new(r.W, r.H)
  Theme.applyPalette(rec, COLORS)   -- lightRed + colourblind palette overrides into the capture
  local err
  local ok, e = pcall(function()
    -- Mount like the real app (app.lua showScreen): BaseFrame bound via setTerm, page in a child Frame.
    local base = basalt.createFrame()
    base:setTerm(rec)
    local frame = base:addFrame({ x = 1, y = 1, width = r.W, height = r.H })
    local handle = r.build(basalt, frame)
    if r.postBuild then r.postBuild(handle) end          -- drive a region drilldown before applying
    -- Always apply: many pages (e.g. flight) build their regions/content lazily inside apply().
    if handle and handle.apply then handle.apply(r.state or {}) end
    for _ = 1, 6 do basalt.update("timer", -1) end
  end)
  if not ok then err = e end

  local out = { r.W .. " " .. r.H }
  local ov = {}
  for d, hex in pairs(rec.overrides) do ov[#ov + 1] = d .. "=" .. hex end
  if #ov > 0 then out[#out + 1] = "PAL " .. table.concat(ov, " ") end
  for row = 1, r.H do
    local g = rec.grid[row]
    local bytes = {}
    for col = 1, r.W do bytes[col] = g.ch[col] end
    out[#out + 1] = table.concat(g.fg) .. "\t" .. table.concat(g.bg) .. "\t" .. table.concat(bytes, " ")
  end
  local f = fs.open("/render_out_" .. id .. ".txt", "w")
  f.write((err and ("ERR " .. tostring(err) .. "\n") or "") .. table.concat(out, "\n") .. "\n")
  f.close()
end

if PANEL == "all" then
  for _, id in ipairs(ORDER) do renderOne(id) end
else
  renderOne(PANEL)
end

os.shutdown()
