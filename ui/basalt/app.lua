-- ui/basalt/app.lua
-- Cockpit bootstrap: ensure Basalt is loaded, discover monitors, and build one Basalt frame
-- per monitor (honoring mirroring) plus one for the terminal. Pages/panels are a LATER task --
-- this module only stands up the frames + render-loop foundation.
--
-- Basalt load pattern mirrors easyhover2_suitex.lua:602-636 EXACTLY: loadfile(path, nil, _ENV),
-- never dofile() -- CC:Tweaked's dofile (bios.lua) loads with the BIOS's own bare _G, which has
-- no require/package/shell, and the vendored bundle needs package.path for its internal module
-- loader. loadfile(path, nil, _ENV) loads it with THIS program's own environment instead.
--
-- Basalt 2.0 API verified against release/basalt-full.lua (the pinned, vendored FULL build --
-- NOT the unminified upstream source, and NOT from memory):
--   * basalt.createFrame() -- release/basalt-full.lua:367-369. Takes NO monitor argument in this
--     build; the new frame's "term" property defaults to term.current() (elements/BaseFrame.lua,
--     bundled at release/basalt-full.lua:4706-4708: `self.set("term",term.current())`).
--   * frame:setTerm(mon) -- an AUTO-GENERATED accessor, not a hand-written method. BaseFrame.lua
--     defines a "term" property via defineProperty(da,"term",{...}) (release/basalt-full.lua:
--     4698-4704); propertySystem.lua's defineProperty (release/basalt-full.lua:191-208) builds
--     `cb["set"..Name]` / `cb["get"..Name]` for every defined property, so "term" yields
--     setTerm/getTerm with no separate definition anywhere -- confirmed by :getTerm() call sites
--     at lines 3278/3284/3329/3951. The term setter rebinds the frame's renderer to the new
--     term-like table and re-reads width/height from `bb.getSize()`, but ONLY if
--     `bb.setCursorPos` is non-nil (release/basalt-full.lua:4701) -- a mock MUST implement
--     setCursorPos or setTerm silently no-ops.
--   * basalt.getMainFrame() -- release/basalt-full.lua:371-372. Returns (creating if absent) the
--     frame bound to the actual `term.current()` -- this is "the terminal frame".
--   * basalt.update(...) -- release/basalt-full.lua:407-411 (`function b_a.update(...)`).
--     Dispatches the event args through the same handler basalt.run()'s loop uses, then renders
--     every currently-active frame (`for _,f in pairs(_aa) do f:render() f:postRender() end`).
--     The render-interval throttle variable (`aaa`, declared `local aaa=0` near line 355) is 0
--     and is never reassigned anywhere in the bundle, so basalt.update(...) renders
--     unconditionally on every call -- no hidden min-interval to trip a headless probe.
--     NEVER basalt.run(): that blocks on os.pullEventRaw() in a while loop (lines 412-417).
--
-- NO peripheral/Basalt/fs work happens at module LOAD time -- everything is inside M.* functions
-- so `require("ui.basalt.app")` loads clean headless.
local Monitors = require("ui.monitors")
local fnv1a = require("tools.fnv1a")

local Config    = require("ui.config")
local Engine    = require("ui.engine")
local RelayWriter = require("ui.relaywriter")
local Fuel      = require("ui.fuel")
local CfgServer = require("ui.cfgserver")
local cadence   = require("ui.basalt.cadence")
local Nav       = require("ui.basalt.nav")
local senssource = require("ui.basalt.senssource")
local UILog     = require("ui.basalt.uilog")
local WptClient = require("ui.basalt.wptclient")
local navtarget = require("ui.navtarget")
local navwpt    = require("nav.waypoints")
local routefollow = require("ui.routefollow")

local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")
local fsx       = require("fcs.io.fsx")

local M = {}

-- ===== Page/menu registry =====
--
-- M.PAGES: screen id -> module, covering every screen a per-monitor Nav stack (ui/basalt/nav.lua)
-- can reach: the five top-level pages (emc/fcs/config/ap/nav) plus the BIT/CONFIG hub and its six
-- sub-menus (tuning/mdb/uical/senscal/dtc/fcssync -- ids pinned by
-- ui/basalt/bitconfig/hub.lua's M.ITEMS). Every module here is a PURE load (each one's own header
-- comment states "NO peripheral/Basalt access at module LOAD") -- required at module top so
-- M.run() never pays a mid-flight require cost.
--
-- CIRCULARITY NOTE: ui/basalt/pages/config.lua and ui/basalt/bitconfig/uical.lua both need
-- BasaltApp.CONFIG_PATH -- they require ui.basalt.app LAZILY (inside the functions that use it,
-- not at their own module top) specifically so this list doesn't loop back on itself
-- (require("ui.basalt.app") -> require(pages.config) -> require("ui.basalt.app") again, still
-- mid-load -- CraftOS-PC's require rejects that with "loop or previous error loading module",
-- verified empirically). Every OTHER module below has no such back-reference.
M.PAGES = {
  emc       = require("ui.basalt.pages.emc"),
  fcs       = require("ui.basalt.pages.fcs"),
  flight    = require("ui.basalt.pages.flight"),   -- merged EMC+FCS for the overhead 1x2 monitors
  config    = require("ui.basalt.pages.config"),
  ap        = require("ui.basalt.pages.ap"),
  nav       = require("ui.basalt.pages.nav"),
  pfd       = require("ui.basalt.pages.pfd"),      -- PFD: heading tape + attitude + ALT/SPD
  bitconfig = require("ui.basalt.bitconfig.hub"),
  tuning    = require("ui.basalt.bitconfig.tuning"),
  mdb       = require("ui.basalt.bitconfig.mdb"),
  uical     = require("ui.basalt.bitconfig.uical"),
  senscal   = require("ui.basalt.bitconfig.senscal"),
  senssource = require("ui.basalt.bitconfig.senssource"),
  pfdrate   = require("ui.basalt.bitconfig.pfd"),   -- PFD RATE submenu (id "pfdrate", not the cockpit "pfd")
  dtc       = require("ui.basalt.bitconfig.dtc"),
  fcssync   = require("ui.basalt.bitconfig.fcssync"),
}

-- Same channel convention as ui/main.lua (101-104) and fcs/boot/loaderui.lua's cfgsync client
-- (105-106, mirrored here: the UI is the RESPONDER -- listens on req, sends on reply).
M.CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
M.CFG_CH = { req = 105, reply = 106 }

M.CONFIG_PATH = "/eh2_ui_config.tbl"
M.UI_LOG_PATH = "/eh2_ui_log.txt"   -- rolling UI log; P uploads this to carbide from the cockpit

-- Displayed heading comes ONLY from the shared NAV magnet-table bearing relayed by the nav pc
-- (never the FCS's control-signed heading). If no fresh relay has arrived within this window the
-- heading reads unknown -> the PFD tape shows "---" rather than a stale/wrong bearing. Sized to
-- tolerate a handful of missed ~0.1s relays without flickering.
M.NAV_HEADING_MAX_AGE_MS = 1000

-- Route auto-advance: the active leg advances to the next when the craft comes within this many
-- blocks (horizontal) of it. <30 is too tight for practical flight; 50 is the default.
M.ROUTE_ARRIVAL_RADIUS = 50

-- Installed location first (SuiteX writes /basalt-full.lua there), repo/headless location
-- second (the ui role ships release/basalt-full.lua -- see DECISION note on M.ensureBasalt).
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

-- Same constant as BOOT_BASE in easyhover2_suitex.lua:155. Duplicated (not required) here on
-- purpose: this module must load with zero side effects, and requiring the Suite engine would
-- pull in its own bootstrap chain just to read one URL string.
local REPO = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

-- ===== Basalt load (see header comment for the verified API) =====

local function loadBasaltFrom(path, doLoadfile)
  local chunk, err = doLoadfile(path, nil, _ENV)
  if not chunk then
    error("Basalt did not parse: " .. tostring(err))
  end
  local ok, basalt = pcall(chunk)
  if not ok or type(basalt) ~= "table" then
    error("Basalt failed to load: " .. tostring(basalt))
  end
  return basalt
end

local function readManifest()
  if not fs.exists("/manifest.lua") or fs.isDir("/manifest.lua") then return nil end
  local f = fs.open("/manifest.lua", "r")
  if not f then return nil end
  local body = f.readAll()
  f.close()
  local ok, manifest = pcall(textutils.unserialise, body)
  if ok and type(manifest) == "table" then return manifest end
  return nil
end

-- Minimal in-game HTTP fetch fallback -- ONLY reached when neither BASALT_PATHS candidate exists
-- on disk. In practice this should never run: the DECISION (see task-13-report.md) is to ship
-- release/basalt-full.lua IN the `ui` role so Basalt is always present locally, no fetch needed.
-- The actual tools/gen_manifest.lua ROLES change that adds it to the ui role's closure is
-- DEFERRED to Task 27 (assembly), when the ui launcher switches over to this Basalt cockpit --
-- doing it here would need its own manifest-generator tests and risks destabilising the
-- IN SYNC gate this task doesn't own.
local function fetchBasalt()
  if not http then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local url = REPO .. "/release/basalt-full.lua"
  local ok, handle = pcall(http.get, url, { ["Cache-Control"] = "no-cache" })
  if not ok or not handle then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local body = handle.readAll()
  handle.close()
  if not body or body == "" then
    error("Basalt not found -- reinstall the ui role via the Suite")
  end
  local manifest = readManifest()
  if manifest and manifest.basalt then
    if #body ~= manifest.basalt.size or fnv1a(body) ~= manifest.basalt.sum then
      error("Basalt fetch arrived corrupt; nothing was changed.")
    end
  end
  local f = fs.open("/basalt-full.lua", "w")
  if not f then
    error("could not write /basalt-full.lua (disk full?)")
  end
  f.write(body)
  f.close()
  return loadBasaltFrom("/basalt-full.lua", loadfile)
end

-- M.ensureBasalt(opts) -> basalt module table (the loaded Basalt 2.0 library).
-- opts.paths    -- override M.BASALT_PATHS (injectable for tests)
-- opts.exists   -- override fs.exists       (injectable for tests)
-- opts.loadfile -- override loadfile        (injectable for tests)
function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      return loadBasaltFrom(path, doLoadfile)
    end
  end
  return fetchBasalt()
end

-- ===== Monitor discovery =====

-- M.discoverMonitors(getNames, getType) -> { <monitor peripheral name>, ... }
-- Injectable for tests; defaults to the real peripheral API.
function M.discoverMonitors(getNames, getType)
  getNames = getNames or peripheral.getNames
  getType = getType or peripheral.getType
  local names = {}
  for _, name in ipairs(getNames()) do
    if getType(name) == "monitor" then
      names[#names + 1] = name
    end
  end
  return names
end

-- ===== Frame construction =====

-- M.buildFrames(basalt, assign, present, wrap) -> {
--   terminal = <frame>,                                     -- bound to the real terminal
--   monitors = { [monitorName] = { frame = <frame>, panelId = <panelId> }, ... },
--   resolved = Monitors.resolve(assign, present),
-- }
-- One Basalt frame PER assigned monitor name: mirrored monitors (several names -> the same
-- panelId) each still get their own frame, since each is a distinct physical term that must be
-- rendered to independently, even though they'll later show the same panel content.
function M.buildFrames(basalt, assign, present, wrap)
  wrap = wrap or peripheral.wrap
  local resolved = Monitors.resolve(assign, present)
  local monitors = {}
  for name, panelId in pairs(resolved.assigned) do
    local mon = wrap(name)
    -- All monitor panels render at text scale 0.5 -- the smallest cell = the most rows/cols, so
    -- panels are compact and fit the tight overhead monitors. (The PC terminal frame can't scale;
    -- setTextScale is a monitor-only method, so this is where "all UIs at 0.5" is enforced.)
    if mon and mon.setTextScale then pcall(mon.setTextScale, 0.5) end
    local frame = basalt.createFrame()
    frame:setTerm(mon)
    monitors[name] = { frame = frame, panelId = panelId }
  end
  local terminal = basalt.getMainFrame()
  return { terminal = terminal, monitors = monitors, resolved = resolved }
end

-- ===== Per-frame nav-aware screen management (lazy build + visibility toggle) =====
--
-- One "frameRec" lives per top-level Basalt frame (the terminal, or one per assigned monitor
-- name): { frame, nav = Nav.new(root), built = {}, lastTop = nil }. `built` lazily caches
-- { [screenId] = { childFrame, handle } } as screens are visited, so the BIT/CONFIG hub's six
-- sub-menus are never constructed until an operator actually navigates into one.

-- M.rootForMonitor(assign, name) -> the nav ROOT screen id for a monitor's frame. `assign` is
-- runtime.config.assign ([monitorName]=pageId); an unassigned or unrecognised page id falls back
-- to "emc" (per task-27-brief.md). PURE -- no Basalt/peripherals, testable standalone.
function M.rootForMonitor(assign, name)
  local id = assign and assign[name]
  if id ~= nil and M.PAGES[id] then return id end
  return "emc"
end

-- M.newFrameRec(frame, root) -> a fresh frameRec rooted at `root`. PURE (Nav.new is pure).
function M.newFrameRec(frame, root)
  return { frame = frame, nav = Nav.new(root), built = {}, lastTop = nil }
end

-- M.showScreen(basalt, runtime, frameRec, screenId) -> { childFrame, handle } | nil
-- Lazily builds screenId's child Frame (basalt-full.lua's Container:addFrame, auto-generated per
-- emc.lua's header notes -- sized to fill frameRec.frame exactly, verified against
-- release/basalt-full.lua's VisualElement width/height defaults of 1, which is why an explicit
-- width/height is passed here) + that page's element tree (page.build(basalt, childFrame,
-- runtime, frameRec.nav)) on FIRST visit, caching the result in frameRec.built. On EVERY call
-- (cached or not) it then sets EXACTLY that screen's child Frame visible and every other built
-- child invisible (Container.lua's render skips invisible children -- verified against
-- release/basalt-full.lua's canRender check), so a repeat visit to an already-built screen is
-- cheap: no rebuild, just a handful of setVisible() calls. Unknown screenId (not in M.PAGES) is a
-- no-op that returns nil.
function M.showScreen(basalt, runtime, frameRec, screenId)
  local page = M.PAGES[screenId]
  if not page then return nil end

  local entry = frameRec.built[screenId]
  if not entry then
    local w, h = frameRec.frame:getSize()
    local childFrame = frameRec.frame:addFrame({ x = 1, y = 1, width = w, height = h })
    local handle = page.build(basalt, childFrame, runtime, frameRec.nav)
    entry = { childFrame = childFrame, handle = handle }
    frameRec.built[screenId] = entry
  end

  for id, e in pairs(frameRec.built) do
    e.childFrame:setVisible(id == screenId)
  end
  return entry
end

-- ===== Runtime: comms/engine/fuel machinery (reused verbatim from ui/main.lua) =====

-- Real atomic-tmp-write-free file reader for cfgserver -- mirrors fcs/boot/loaderui.lua's
-- realRead exactly (read-only: cfgserver only ever answers `req` frames with file bodies).
-- Delegates to fcs/io/fsx.lua's shared helper.
local realRead = fsx.read

-- Select the engine's relay writer by mode. basic -> single-side level writer (config.relay.side);
-- latch -> two-line pulse writer (config.relay.blockSide/feedSide). Read fresh via closures so a
-- rebind/side change is picked up without rebuilding. Pure but for the injected getRelay.
function M.makeEngineWriter(RelayWriter, getRelay, config)
  if config.engine.mode == "latch" then
    return RelayWriter.makeLatch(getRelay,
      function() return config.relay.blockSide end,
      function() return config.relay.feedSide end)
  end
  return RelayWriter.make(getRelay, function() return config.relay.side end)
end

-- M.buildRuntime(deps) -> runtime
-- deps.modem   -- a modem peripheral (default peripheral.find("modem"))
-- deps.wrap    -- peripheral.wrap override (default peripheral.wrap)
-- deps.find    -- peripheral.find override, used only when deps.modem is absent
-- deps.read    -- file reader for cfgserver, (path) -> body|nil (default realRead)
--
-- NO peripheral access happens outside this function -- `require("ui.basalt.app")` stays clean
-- headless; a test supplies deps.modem/deps.wrap/deps.read so this runs under CraftOS-PC too.
function M.buildRuntime(deps)
  deps = deps or {}
  local wrap = deps.wrap or peripheral.wrap
  local find = deps.find or peripheral.find
  local read = deps.read or realRead

  local modem = deps.modem or find("modem")
  assert(modem, "UI-PC needs a modem on the wired network")

  local CH, CFG_CH = M.CH, M.CFG_CH

  -- One link per logical channel (UI listens on telemetry/ack/health, sends on command) --
  -- PLUS the cfgsync link, mirrored the opposite way round from fcs/boot/loaderui.lua's client:
  -- the UI listens on req (105) and sends replies on reply (106).
  local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
  local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
  local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
  local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.reply, rxCh = CFG_CH.req })
  -- NAV computer relay (nav/runtime.lua): fire-and-forget navfix frames on wired ch 107, no
  -- reply expected -- txCh is set to the same channel purely so the link shape matches the
  -- others; the UI never sends on it.
  local navLink = modemlib.wrap(modem, { txCh = 107, rxCh = 107 })
  -- NAV waypoint store sync: the cockpit menu is a client -- sends requests on 108, gets replies on
  -- 109 (the NAV PC owns the store). Fire-and-forget send; replies land via routeModem -> onReply.
  local wptClient = WptClient.new({ link = modemlib.wrap(modem, { txCh = 108, rxCh = 109 }) })
  for _, c in pairs(CH) do modem.open(c) end
  for _, c in pairs(CFG_CH) do modem.open(c) end
  modem.open(107)
  modem.open(109)

  local rx = telemetry.Rx.new()
  local sender = command.Sender.new({ timeout = 0.5 })
  local hbRx = health.Rx.new({ timeout = 2.0 })

  local config = Config.withDefaults(select(1, Config.load(M.CONFIG_PATH)) or {})

  -- Engine relay: dumb passthrough writer -- ui/engine.lua owns ALL inversion (see ui/main.lua's
  -- header comment on the same construction; ported verbatim, just using the injected `wrap`).
  local relay = nil
  local function rebindRelay()
    relay = nil
    local haveSides
    if config.engine.mode == "latch" then
      haveSides = (config.relay.blockSide ~= nil and config.relay.feedSide ~= nil)
    else
      haveSides = (config.relay.side ~= nil)
    end
    if config.relay.name and haveSides then
      local ok, p = pcall(wrap, config.relay.name)
      if ok then relay = p end
    end
  end
  rebindRelay()

  -- True only when the relay actually WRAPPED (name + side present and the peripheral resolved) --
  -- a pure read of the already-bound upvalue, NO peripheral call, so the ENG SW indicator can
  -- reflect real writability without polling. rebindRelay() refreshes `relay` on every bind/side/
  -- name change, so this stays current without a render-path cost.
  local function isRelayReady() return relay ~= nil end

  -- Physical write edge (ui/relaywriter.lua): basic mode drives config.relay.side and releases the
  -- previously driven side when the side changes; latch mode drives the block/feed lines instead
  -- (M.makeEngineWriter picks by config.engine.mode).
  local writer = M.makeEngineWriter(RelayWriter, function() return relay end, config)

  local engine = Engine.new(config.engine, writer)

  -- Fuel readers (sink over config.fuel.<role>; pure fraction math lives in ui/fuel.lua).
  local function makeFuelReader(role)
    return function()
      local fc = config.fuel[role]
      if not fc or not fc.name then return 0, nil end
      local ok, p = pcall(wrap, fc.name)
      if not ok or not p then return 0, nil end
      if fc.kind == "fluid" then
        if p.getFuelAmountMb then
          local ok1, amt = pcall(p.getFuelAmountMb)
          local cap = nil
          if p.getFuelCapacityMb then
            local ok2, c = pcall(p.getFuelCapacityMb)
            if ok2 then cap = c end
          end
          return (ok1 and amt) or 0, cap
        elseif p.tanks then
          local ok3, tanks = pcall(p.tanks)
          local t = ok3 and tanks and tanks[1]
          if t then return t.amount or 0, t.capacity end
          return 0, nil
        end
        return 0, nil
      else
        local amount = 0
        if p.list then
          local ok4, items = pcall(p.list)
          if ok4 and items then
            for _, item in pairs(items) do amount = amount + (item.count or 0) end
          end
        end
        local capacity = nil
        if p.size then
          local ok5, sz = pcall(p.size)
          if ok5 and sz then capacity = sz * 64 end
        end
        return amount, capacity
      end
    end
  end

  local fuelReaders = { pump = makeFuelReader("pump"), tank = makeFuelReader("tank") }

  -- Not auto-started: FCS SYNC (a later page task) starts/stops this on demand.
  local cfgserver = CfgServer.new({ read = read, dir = "/" })

  return {
    links = { tel = telLink, ack = ackLink, hb = hbLink },
    cfgLink = cfgLink,
    navLink = navLink,
    rx = rx,
    sender = sender,
    hbRx = hbRx,
    engine = engine,
    fuelReaders = fuelReaders,
    cfgserver = cfgserver,
    config = config,
    rebindRelay = rebindRelay,
    isRelayReady = isRelayReady,
    uiRev = 0,
    -- Session UI logger (no-op unless the launcher set _G.EH2_UILOG). Records raw input, scheduled-
    -- loop timings (incl. the engine tick's feeding/pulseEndsAt -- the engine-bug probe), and
    -- semantic actions; P uploads the rolling window to carbide from inside the cockpit.
    uilog = UILog.new((deps.uilog ~= nil) and deps.uilog or (_G.EH2_UILOG == true)),
    setLogStatus = function() end,   -- no-op until M.run wires the Basalt overlay (in-game only)
    wptClient = wptClient,   -- NAV store sync client (waypoints/routes live on the NAV PC)
    state = { pumpFrac = 0, tankFrac = 0, pumpAmount = 0, tankMb = 0 },
    nav = {},  -- PFD nav fields (gpsAlt/tas/fixOk); Task 7's nav listener populates this later
    CH = CH,
    CFG_CH = CFG_CH,
    readFile = read,  -- exposed so M.startScheduled's attitude poll loop can reach it (senssource.resolve)
    wrap = wrap,      -- exposed so M.startScheduled's attitude poll loop can reach it (senssource.readAttitude)
  }
end

-- ===== Modem routing (testable, no sleeping) =====

-- M.routeModem(runtime, ch, msg) -> replyFrame|nil
-- Mirrors ui/main.lua's netLoop routing for tel/ack/health EXACTLY, plus cfgsync on top: a `req`
-- frame on CFG_CH.req is handed to cfgserver:onMessage, and any reply it produces is sent back on
-- cfgLink (and returned, so a test can assert on it directly without capturing a modem transmit).
function M.routeModem(runtime, ch, msg)
  local f = runtime.links.tel:onMessage(ch, msg)
  if f then
    runtime.rx:accept(f)
    return nil
  end

  local a = runtime.links.ack:onMessage(ch, msg)
  if a and a.k == "ack" then
    runtime.sender:ack(a)
    return nil
  end

  local h = runtime.links.hb:onMessage(ch, msg)
  if h and h.k == "hb" then
    runtime.hbRx:mark(os.epoch("utc") / 1000)
    return nil
  end

  local c = runtime.cfgLink:onMessage(ch, msg)
  if c then
    local reply = runtime.cfgserver:onMessage(c)
    if reply then
      runtime.cfgLink:send(reply)
      return reply
    end
  end

  local n = runtime.navLink:onMessage(ch, msg)
  if n and n.k == "navhdg" then
    -- Fast heading relay (shared magnet-table bearing): THE display heading source. Stamps the
    -- heading-freshness clock so a dead NAV -> stale -> tape "---" (buildState gate keys off this).
    runtime.nav.heading = n.heading
    runtime.nav.compass = n.compass
    runtime.nav.at      = os.epoch("utc")
    return nil
  end
  if n and n.k == "navfix" then
    -- Slow GPS fix relay: position/speed only. Deliberately does NOT touch nav.at -- heading
    -- freshness must track the fast navhdg stream, not this slow one. Store the craft's horizontal
    -- position too (fixX/fixZ) for NAV-menu waypoint targeting on the PFD.
    runtime.nav.gpsAlt = n.fix and n.fix.y or nil
    runtime.nav.fixX   = n.fix and n.fix.x or nil
    runtime.nav.fixZ   = n.fix and n.fix.z or nil
    runtime.nav.tas    = n.gs
    runtime.nav.fixOk  = n.fix ~= nil
    return nil
  end

  -- NAV waypoint-store sync replies (ch 109) -> the client cache. Async: the client only SENDS;
  -- the reply arrives here and refreshes runtime.wptClient's cached store.
  if runtime.wptClient and runtime.wptClient.link then
    local wf = runtime.wptClient.link:onMessage(ch, msg)
    if wf and (wf.k == "wpt_store" or wf.k == "wpt_err" or wf.k == "wpt_disk_res") then
      runtime.wptClient:onReply(wf, os.epoch("utc"))
      return nil
    end
  end

  return nil
end

-- ===== Cadence state assembly (pure) =====

-- M.buildState(runtime, now) -> flat cadence.gate-shaped state table.
-- `now` is the ms epoch (os.epoch("utc")), matching what runtime.engine:tick/:status expect;
-- hbRx:up wants seconds, so it's divided down here exactly like ui/main.lua's snapshot() does.
function M.buildState(runtime, now)
  local latest = runtime.rx:latest() or {}
  local e = runtime.engine:status(now)
  -- Heading is display-sourced from the shared NAV magnet table (relayed by the nav pc), NOT the
  -- FCS's control-signed `latest.heading`. Only a fresh relay counts; stale/absent -> nil so the
  -- tape shows "---" (honest) instead of a wrong bearing. See M.NAV_HEADING_MAX_AGE_MS.
  local navFresh = runtime.nav and runtime.nav.at
    and (now - runtime.nav.at) <= M.NAV_HEADING_MAX_AGE_MS
  -- PFD steering cue: an ACTIVE ROUTE's current leg (blue, auto-advancing) takes precedence, else a
  -- single selected waypoint (green). Needs the craft's horizontal position; heading from the fresh
  -- nav bearing, altitude from baro.
  local target = nil
  local nv = runtime.nav
  if nv and type(nv.fixX) == "number" and type(nv.fixZ) == "number" then
    local craft = { x = nv.fixX, z = nv.fixZ, heading = navFresh and nv.heading or nil, baroY = latest.altitude }
    local tgt, color = nil, "green"
    if nv.routeActive and runtime.wptClient then
      local route = navwpt.findRoute(runtime.wptClient.store, nv.routeActive.name)
      if route then
        local legs = navwpt.resolveLegs(runtime.wptClient.store, route)
        local step = routefollow.step(legs, nv.routeActive.i or 1, craft, M.ROUTE_ARRIVAL_RADIUS)
        nv.routeActive.i = step.i   -- auto-advance the active leg on arrival
        tgt, color = step.target, "blue"
      else
        -- The active route was deleted on the NAV PC: drop the cue AND the stale activation,
        -- otherwise routeActive lingers forever (only re-ACT cleared it) and the cue silently
        -- vanishes while state still claims a route is being followed.
        nv.routeActive = nil
      end
    elseif nv.target then
      tgt, color = nv.target, (nv.target.color or "green")
    end
    if tgt then
      local sol = navtarget.solve(craft, tgt)
      if sol then
        target = { name = tgt.name, bearing = sol.bearing, distanceH = sol.distanceH,
          relBearing = sol.relBearing, altDelta = sol.altDelta, color = color }
      end
    end
  end
  return {
    engaged      = latest.engaged,
    gndSafety    = latest.gndSafety,
    onGround     = latest.onGround,
    comAuto      = latest.comAuto,
    positionHold = latest.positionHold,
    mode         = latest.mode,
    flightMode   = latest.flightMode,
    trimDir      = latest.trimDir,
    linkUp       = runtime.hbRx:up(now / 1000),
    altitude     = latest.altitude,
    vSpeed       = latest.vSpeed,
    heading      = navFresh and runtime.nav.heading or nil,
    loopHz       = latest.loopHz,
    engineMaster = e.master,
    feeding      = e.feeding,
    pulses       = e.pulses,
    nextFeedInMs = e.nextFeedInMs,
    pumpFrac     = runtime.state.pumpFrac,
    tankFrac     = runtime.state.tankFrac,
    pumpAmount   = runtime.state.pumpAmount,   -- raw solid count (merged page: % vs manual max)
    tankMb       = runtime.state.tankMb,       -- raw liquid mB (merged page: shown raw, gauge vs manual max)
    pitch        = runtime.state.pitch,        -- PFD: attitude (Task 5's poll loop writes these)
    roll         = runtime.state.roll,
    sas          = runtime.state.sas,
    gpsAlt       = runtime.nav and runtime.nav.gpsAlt or nil,  -- PFD: nav (Task 7's listener writes runtime.nav)
    tas          = runtime.nav and runtime.nav.tas or nil,
    gpsFixOk     = runtime.nav and runtime.nav.fixOk or nil,
    target       = target,   -- PFD waypoint steering cue (NAV menu selection); nil when none
    uiRev        = runtime.uiRev,
  }
end

-- ===== Scheduled work (in-game only; basalt.schedule per easyhover2_suitex.lua's proven pattern) =====

-- M.startScheduled(basalt, runtime, frames, applyState)
-- Registers five basalt.schedule sleep-loop coroutines -- the SAME composition ui/main.lua ran
-- under parallel.waitForAny, ported one-for-one onto Basalt's own coroutine scheduler (verified
-- against release/basalt-full.lua: b_a.schedule creates a coroutine, resumes it once, and stores
-- its yielded filter; b_a's internal event dispatcher (bca) then resumes any scheduled coroutine
-- whose filter is nil or matches the incoming event, on every basalt.update(...)/basalt.run()
-- pump -- so a plain `os.pullEvent("modem_message")` loop inside a scheduled function receives
-- real modem_message events exactly like it would inside parallel.waitForAny, and `sleep(n)`
-- self-pumps the same way via "timer" events).
--
-- CRITICAL non-blocking discipline (same as ui/main.lua): peripheral polls and long ops live in
-- (a)-(d) below, NEVER in (e) the render-gate -- (e) only builds a quantized signature and calls
-- applyState() when it actually changed, so paint stays off the FCS's shared main-thread budget.
--
-- extraDirty (optional 5th param, added for Task 27's nav-aware M.run()): a zero-arg function,
-- checked every render-gate tick ALONGSIDE cadence.gate -- if it returns true, applyState() fires
-- even when cadence.gate itself reports no telemetry change. This is how a per-monitor nav-stack
-- push/pop (a screen switch with no telemetry change at all) still repaints within one ~0.2s gate
-- tick instead of waiting for the next incidental telemetry change. nil/omitted -- e.g. every
-- existing call site before this task -- behaves EXACTLY as before (cadence.gate is the sole
-- trigger), so this stays fully backward compatible.
function M.startScheduled(basalt, runtime, frames, applyState, extraDirty)
  applyState = applyState or function() end

  -- (a) modem_message router: telemetry -> rx, ack -> sender, health -> hbRx, cfgsync req -> reply.
  basalt.schedule(function()
    while true do
      local _, _, ch, _replyCh, msg = os.pullEvent("modem_message")
      M.routeModem(runtime, ch, msg)
    end
  end)

  -- (b) engine tick, 0.1s. pcall-guarded like ui/main.lua (the writer inside ui/engine.lua is
  -- already pcall-wrapped for a disconnected/broken relay; this outer guard additionally keeps a
  -- scheduled coroutine that hit an unexpected error alive instead of dying silently forever).
  basalt.schedule(function()
    local n, lastFeed, lastBeat = 0, nil, 0
    while true do
      local now = os.epoch("utc")
      pcall(function() runtime.engine:tick(now) end)
      -- UI-log probe (no-op when logging off): log every feed/master transition immediately, plus a
      -- ~1s heartbeat, so a wedged feed shows in the log as either a frozen heartbeat (tick loop
      -- starved) or feed=true heartbeats that never clear (tick runs but pulse never ends).
      if runtime.uilog.enabled then
        n = n + 1
        local st = runtime.engine:status(now)
        if st.feeding ~= lastFeed then
          runtime.uilog:event("ENGINE", ("feed=%s master=%s pEnds=%s"):format(
            tostring(st.feeding), tostring(st.master), tostring(runtime.engine.pulseEndsAt)), now)
          lastFeed = st.feeding
        elseif now - lastBeat >= 1000 then
          runtime.uilog:event("ENGINE", ("tick#%d feed=%s"):format(n, tostring(st.feeding)), now)
          lastBeat = now
        end
      end
      sleep(0.1)
    end
  end)

  -- (c) fuel poll, 0.5s.
  basalt.schedule(function()
    while true do
      -- Capture the raw amount too (2nd return): the merged flight page divides by a MANUALLY set
      -- max (config.fuel.<role>.full), not the device capacity, and shows the main tank in raw mB.
      runtime.state.pumpFrac, runtime.state.pumpAmount =
        Fuel.read(runtime.fuelReaders.pump, runtime.config.fuel.pump.kind, runtime.config.fuel.pump)
      runtime.state.tankFrac, runtime.state.tankMb =
        Fuel.read(runtime.fuelReaders.tank, runtime.config.fuel.tank.kind, runtime.config.fuel.tank)
      sleep(0.5)
    end
  end)

  -- (f) attitude poll, ~0.1s: read the LOCAL gimbal + medial-velocity sensors, apply the active
  -- SENS SOURCE calibration, publish pitch/roll/sas. OFF the render path (non-mainThread reads).
  -- Re-resolves only when config.sens.source changes (file reads are not repeated every tick).
  basalt.schedule(function()
    local lastSource, resolved = nil, nil
    while true do
      pcall(function()
        local src = (runtime.config.sens and runtime.config.sens.source) or "FCS"
        if src ~= lastSource then
          lastSource = src
          resolved = senssource.resolve(runtime.config.sens, runtime.readFile)
        end
        if resolved and resolved.source ~= "OFF" then
          local a = senssource.readAttitude(resolved.cal, resolved.sensors, runtime.wrap)
          if a then runtime.state.pitch, runtime.state.roll, runtime.state.sas = a.pitch, a.roll, a.sas
          else runtime.state.pitch, runtime.state.roll, runtime.state.sas = nil, nil, nil end
        else
          runtime.state.pitch, runtime.state.roll, runtime.state.sas = nil, nil, nil
        end
      end)
      sleep(0.1)   -- 10Hz attitude poll: keeps the PFD horizon reactive (UI-pc local, off the flight loop)
    end
  end)

  -- (d) sender retry, 0.25s.
  basalt.schedule(function()
    while true do
      for _, f in ipairs(runtime.sender:tick(0.25)) do runtime.links.tel:send(f) end
      sleep(0.25)
    end
  end)

  -- (g) NAV store sync poll, 2s: pull the waypoint/route store from the NAV PC so the NAV menu cache
  -- stays fresh + offline is detected. Cheap (one small frame); the reply lands via routeModem ->
  -- wptClient:onReply. First request fires immediately so the menu populates as soon as it opens.
  basalt.schedule(function()
    while true do
      if runtime.wptClient then pcall(function() runtime.wptClient:request() end) end
      sleep(2.0)
    end
  end)

  -- (e) render gate, ~0.1s: build state, gate on the quantized signature, repaint only on change.
  basalt.schedule(function()
    local lastSig = nil
    while true do
      local now = os.epoch("utc")
      local state = M.buildState(runtime, now)
      local changed, sig = cadence.gate(lastSig, state)
      local navDirty = extraDirty and extraDirty() or false
      if changed or navDirty then
        lastSig = sig
        local t0 = os.epoch("utc")
        applyState(state, frames)
        if runtime.uilog.enabled then
          runtime.uilog:event("RENDER", ("apply %dms%s"):format(os.epoch("utc") - t0, navDirty and " nav" or ""), t0)
        end
      end
      -- Tunable render cadence (BIT/CONFIG -> PFD RATE, ui.config pfd.renderMs). The dirty-gate is
      -- kept, so unchanged frames still skip the expensive recompose+monitor-blit -- protecting the
      -- server-global render budget the FCS shares. Faster = smoother, watch the FCS loopHz.
      local ms = (runtime.config.pfd and runtime.config.pfd.renderMs) or 100
      sleep(ms / 1000)
    end
  end)

  -- ===== UI logging: raw-input capture + P-to-carbide upload (only armed when logging is on) =====
  if runtime.uilog.enabled then
    -- Write the rolling log + upload to carbide WITHOUT corrupting the cockpit: Basalt renders to
    -- the term it captured at createFrame, so redirecting term here only diverts carbide's own
    -- stdout into an invisible capture window we then scrape the paste URL from. Status shows in the
    -- Basalt overlay (runtime.setLogStatus), never on the terminal. Runs in its own coroutine so a
    -- P press never blocks input logging; guarded so spamming P can't stack uploads.
    local uploading = false
    local function uploadLog()
      if uploading then return end
      uploading = true
      runtime.setLogStatus("LOG .. uploading")
      pcall(function()
        local f = fs.open(M.UI_LOG_PATH, "w")
        if f then f.write(runtime.uilog:compose()); f.close() end
      end)
      local url = nil
      pcall(function()
        local prev = term.current()
        local cw, ch2 = prev.getSize()
        local cap = window.create(prev, 1, 1, cw, ch2, false)   -- invisible: carbide's stdout only
        term.redirect(cap)
        shell.run("carbide", "put", M.UI_LOG_PATH)
        term.redirect(prev)
        local lines = {}
        for i = 1, ch2 do lines[i] = (cap.getLine and (cap.getLine(i))) or "" end
        url = UILog.scrapeUrl(table.concat(lines, "\n"))
      end)
      runtime.uilog:event("UPLOAD", url and ("-> " .. url) or "(carbide unavailable)", os.epoch("utc"))
      runtime.setLogStatus(url and ("LOG ok " .. url) or "LOG upload FAILED (grab " .. M.UI_LOG_PATH .. ")")
      uploading = false
    end

    -- Raw-input logger: logs every input event (no filter; basalt still delivers them to the UI --
    -- os.pullEvent in a scheduled coroutine observes events, it does not consume them). P/p fires an
    -- upload on its own coroutine.
    basalt.schedule(function()
      while true do
        local ev = { os.pullEvent() }
        local e, now = ev[1], os.epoch("utc")
        if e == "mouse_click" then runtime.uilog:event("INPUT", ("click b%s @%s,%s"):format(tostring(ev[2]), tostring(ev[3]), tostring(ev[4])), now)
        elseif e == "mouse_up" then runtime.uilog:event("INPUT", ("up @%s,%s"):format(tostring(ev[3]), tostring(ev[4])), now)
        elseif e == "mouse_drag" then runtime.uilog:event("INPUT", ("drag @%s,%s"):format(tostring(ev[3]), tostring(ev[4])), now)
        elseif e == "mouse_scroll" then runtime.uilog:event("INPUT", ("scroll %s @%s,%s"):format(tostring(ev[2]), tostring(ev[3]), tostring(ev[4])), now)
        elseif e == "char" then
          runtime.uilog:event("INPUT", "char " .. tostring(ev[2]), now)
          if ev[2] == "p" or ev[2] == "P" then basalt.schedule(uploadLog) end
        elseif e == "key" then runtime.uilog:event("INPUT", "key " .. tostring(ev[2]), now)
        elseif e == "key_up" then runtime.uilog:event("INPUT", "key_up " .. tostring(ev[2]), now)
        end
      end
    end)
  end
end

-- ===== M.run: top-level cockpit entry point =====
--
-- IN-GAME ONLY -- calls basalt.run(), which blocks on os.pullEventRaw() forever. NEVER call this
-- from a test (see every M.build*/M.startScheduled test's own header notes on the same point).
--
-- ensureBasalt -> buildRuntime(deps) -> discoverMonitors -> buildFrames, then one frameRec
-- (M.newFrameRec) per top-level frame: the terminal roots at "config"; each monitor roots at its
-- assigned page id (M.rootForMonitor, default "emc" when unassigned/invalid). applyState (wired
-- into M.startScheduled) lazily shows/builds the current nav top per frame (M.showScreen) and
-- calls its handle.apply(state) -- FCS-SAFE: peripheral polls stay in M.startScheduled's (a)-(d),
-- never on this path. `navChanged` (passed as M.startScheduled's extraDirty) makes the render-gate
-- ALSO fire on a nav-stack change (an operator's BIT/CONFIG or BACK button press), not only on a
-- telemetry change, so pressing a nav button switches the visible screen within one ~0.2s gate
-- tick even while telemetry is holding perfectly still -- without reintroducing an unconditional
-- repaint storm. deps.* mirrors M.buildRuntime's injectable seams (modem/wrap/find/read) plus
-- deps.basaltOpts (-> M.ensureBasalt) and deps.getNames/deps.getType (-> M.discoverMonitors).
--
-- cfgserver is deliberately NOT auto-started here -- the FCS SYNC sub-menu (ui/basalt/bitconfig/
-- fcssync.lua) starts/stops it on demand.
function M.run(deps)
  deps = deps or {}
  local basalt = M.ensureBasalt(deps.basaltOpts)
  local runtime = M.buildRuntime(deps)
  local present = M.discoverMonitors(deps.getNames, deps.getType)
  local built = M.buildFrames(basalt, runtime.config.assign, present, deps.wrap)

  local frameRecs = {}
  frameRecs.terminal = M.newFrameRec(built.terminal, "config")
  for name, rec in pairs(built.monitors) do
    frameRecs[name] = M.newFrameRec(rec.frame, M.rootForMonitor(runtime.config.assign, name))
  end

  local function applyState(state, _frames)
    for _, frameRec in pairs(frameRecs) do
      local top = frameRec.nav:top()
      local entry = M.showScreen(basalt, runtime, frameRec, top)
      if entry and entry.handle and entry.handle.apply then
        entry.handle.apply(state)
      end
      frameRec.lastTop = top
    end
  end

  local function navChanged()
    for _, frameRec in pairs(frameRecs) do
      if frameRec.nav:top() ~= frameRec.lastTop then return true end
    end
    return false
  end

  -- Logging status overlay on the PC terminal frame (only when logging is armed). High z so lazily-
  -- built page child frames never cover it. The P-upload task updates it: idle -> uploading ->
  -- uploaded+url. Bottom row; the operator watches the PC screen for the paste link.
  if runtime.uilog.enabled then
    local tw, th = built.terminal:getSize()
    local statusLabel = built.terminal:addLabel({
      x = 1, y = th, width = tw, height = 1, autoSize = false, z = 1000,
      background = colors.black, foreground = colors.lime, text = "LOG on  P:upload",
    })
    runtime.setLogStatus = function(s) pcall(function() statusLabel:setText(tostring(s)) end) end
    runtime.uilog:event("SESSION", "UI logging armed", os.epoch("utc"))
  end

  M.startScheduled(basalt, runtime, built, applyState, navChanged)
  basalt.run()
end

return M
