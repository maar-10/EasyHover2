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
local Theme     = require("ui.theme")
local Engine    = require("ui.engine")
local RelayWriter = require("ui.relaywriter")
local Fuel      = require("ui.fuel")
local FuelRate  = require("ui.fuelrate")
local FedTrack  = require("ui.fedtrack")
local CfgClient = require("ui.basalt.cfgclient")
local renderpolicy = require("ui.basalt.renderpolicy")
local fcslink   = require("ui.basalt.fcslink")
local Nav       = require("ui.basalt.nav")
local UILog     = require("ui.basalt.uilog")
local WptClient = require("ui.basalt.wptclient")
local navtarget = require("ui.navtarget")
local navwpt    = require("nav.waypoints")
local routefollow = require("ui.routefollow")

local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")

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
  flight    = require("ui.basalt.pages.flight"),   -- merged EMC+FCS for the overhead 3x2 monitor (3 high x 2 wide)
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

-- Same channel convention as ui/main.lua (101-104) and the FCS config responder (105-106):
-- the UI is the CLIENT -- sends req/set on req (105), hears cfg/ack on reply (106).
M.CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
M.CFG_CH = { req = 105, reply = 106 }

-- Which FCS config kinds each BIT/CONFIG menu needs cached before it can render live. tuning's
-- COM/AUTO-COM drilldown also reads devbind/senscal, so all three are prefetched on open.
M.CFG_MENU_KINDS = {
  tuning = { "tuning", "devbind", "senscal" },
  mdb = { "devbind" },
  senscal = { "devbind", "senscal" },
  senssource = { "devbind" },
  dtc = { "tuning", "devbind", "senscal", "fuelcal" },
}

-- cfgMenuStatus(runtime, screenId, requestFn) -> "ok" | "sync" | "fail". PURE given the cache: a
-- non-config screen is always "ok"; "fail" if any needed kind failed; "sync" if any is missing/in
-- flight (requestFn(kind) is invoked once per not-yet-requested kind); else "ok".
function M.cfgMenuStatus(runtime, screenId, requestFn)
  local kinds = M.CFG_MENU_KINDS[screenId]
  if not kinds then return "ok" end
  local agg = "ok"
  for _, kind in ipairs(kinds) do
    local c = runtime.cfgCache[kind]
    if c and c.status == "fail" then return "fail" end
    if not c or c.status == "sync" then
      if not c then requestFn(kind) end
      agg = "sync"
    end
  end
  return agg
end

M.CONFIG_PATH = "/eh2_ui_config.tbl"
M.UI_LOG_PATH = "/eh2_ui_log.txt"   -- rolling UI log; P uploads this to carbide from the cockpit

-- The PFD's DISPLAYED heading, AND the craft heading used in the waypoint/route bearing math
-- (M.buildState's `target` cue), are both sourced from the FCS snapshot's compassHeading, gated on
-- the telemetry heartbeat (linkUp): no snapshot has ever arrived, or the link is stale/dead, ->
-- heading is nil -> the tape shows "---" and the steering cue's relBearing is unavailable, instead
-- of either one freezing on a stale bearing. NAV no longer relays its own heading (navhdg is gone --
-- see nav/runtime.lua's R:heading) so there is no separate nav-relay freshness window to track here.

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
    monitors[name] = { frame = frame, panelId = panelId, term = mon }
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

-- M.reconcileMonitors(basalt, runtime, built, frameRecs, present, wrap)
-- Live-reconciles the per-monitor frames/frameRecs to the CURRENT runtime.config.assign + `present`
-- set, WITHOUT a PC reboot (the CONFIG page's REFRESH, and SET UI's live apply). Mutates `built.monitors`
-- and `frameRecs` in place; the terminal frameRec is never touched. Three cases:
--   * newly assigned+present  -> build its frame (mirrors M.buildFrames) + a frameRec at its page.
--   * assignment changed       -> RE-ROOT the existing frameRec in place (frame + built cache kept, so
--                                 M.showScreen's visibility sweep hides the old page's child -- no ghost).
--   * no longer assigned+present -> hide + forget its frame and frameRec (stop rendering to it).
-- `wrap` defaults to peripheral.wrap; injected in tests. Returns the Monitors.resolve result.
function M.reconcileMonitors(basalt, runtime, built, frameRecs, present, wrap)
  wrap = wrap or peripheral.wrap
  local assign = runtime.config.assign
  local resolved = Monitors.resolve(assign, present)

  for name, panelId in pairs(resolved.assigned) do
    local existing = built.monitors[name]
    if not existing then
      local mon = wrap(name)
      if mon and mon.setTextScale then pcall(mon.setTextScale, 0.5) end
      local frame = basalt.createFrame()
      frame:setTerm(mon)
      built.monitors[name] = { frame = frame, panelId = panelId, term = mon }
      local rec = M.newFrameRec(frame, M.rootForMonitor(assign, name))
      -- Wire instant-render (Task 3): a push/pop on THIS monitor's nav repaints it immediately
      -- instead of waiting for the next periodic gate tick. Only WIRED here, never CALLED --
      -- M.run's own boot pass (or the caller's next M.applyNow, if any) is what actually shows this
      -- newly-reconciled frame's initial top; some reconcileMonitors tests build `runtime` as a bare
      -- `{ config = ... }` stub with no rx/engine/hbRx, so eagerly calling M.applyNow (which needs
      -- M.buildState) here would break them for no in-scope benefit.
      rec.nav.onChange = function() M.applyNow(basalt, runtime, rec) end
      frameRecs[name] = rec
    elseif existing.panelId ~= panelId then
      -- Assignment changed: keep the SAME frame + frameRec (so its built-screen cache is intact and
      -- M.showScreen still owns visibility of every child it made), just re-root its nav stack.
      existing.panelId = panelId
      local fr = frameRecs[name]
      if fr then
        fr.nav = Nav.new(M.rootForMonitor(assign, name))
        fr.nav.onChange = function() M.applyNow(basalt, runtime, fr) end
        fr.lastTop = nil
        -- Rebaseline this frame's per-panel gate window: the reused frameRec still carries the OLD
        -- page's lastSig/lastApplyAt. Without clearing them, re-rooting onto a SAME-sig-group rate
        -- page (emc<->flight<->fcs) can leave the old page showing until the next flight-sig change,
        -- because M.gateFrame would see the stale matching sig and skip the apply. Nil-ing them forces
        -- the next gate tick to re-apply the re-rooted top (mirrors M.applyNow's rebaseline).
        fr.lastSig = nil
        fr.lastApplyAt = nil
      end
    end
  end

  for name, rec in pairs(built.monitors) do
    if not resolved.assigned[name] then
      if rec.frame and rec.frame.setVisible then pcall(rec.frame.setVisible, rec.frame, false) end
      built.monitors[name] = nil
      frameRecs[name] = nil
    end
  end

  return resolved
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

  -- S2: FCS config menus render only once their kinds are cached (fetched live from the FCS).
  -- While syncing / on timeout, show a placeholder instead of the menu -- the menu never sees a
  -- half-fetched cfg. requestFn kicks a client read whose reply flips the cache to "ok" and
  -- repaints (applyNow), rebuilding the real menu here.
  local cfgStatus = M.cfgMenuStatus(runtime, screenId, function(kind)
    runtime.cfgCache[kind] = { body = nil, status = "sync" }
    runtime.cfgClient:readKind(kind, function(body)
      runtime.cfgCache[kind] = { body = body, status = body ~= nil and "ok" or "fail" }
      runtime.uiRev = (runtime.uiRev or 0) + 1
      pcall(function() M.applyNow(basalt, runtime, frameRec) end)
    end)
  end)
  if cfgStatus ~= "ok" then
    return M._cfgPlaceholder(basalt, frameRec, screenId, cfgStatus)
  end

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

-- A minimal SYNC / FCS-NOT-ANSWERING frame shown in place of a config menu until its cfg arrives.
-- Cached under a distinct built key so the real menu rebuilds when the cache flips to "ok".
function M._cfgPlaceholder(basalt, frameRec, screenId, status)
  local key = "__cfggate_" .. screenId
  local rec = frameRec.built[key]
  if not rec then
    local w, h = frameRec.frame:getSize()
    local child = frameRec.frame:addFrame({ x = 1, y = 1, width = w, height = h })
    local msg = child:addLabel({ x = 2, y = 2, width = math.max(1, w - 2), height = 2, autoSize = false, text = "" })
    local back = child:addButton({ x = 2, y = h - 1, width = math.min(6, w - 2), height = 1, text = "<" })
    back:onClick(function() if frameRec.nav then frameRec.nav:pop() end end)
    rec = { childFrame = child, handle = { apply = function() end }, _msg = msg }
    frameRec.built[key] = rec
  end
  rec._msg:setText(status == "fail"
    and "FCS NOT ANSWERING -- seed via a config disk & reboot"
    or "SYNCING FCS...")
  for id, r in pairs(frameRec.built) do r.childFrame:setVisible(id == key) end
  return rec
end

-- M.applyNow(basalt, runtime, frameRec) -> entry|nil
-- Instant (non-gated) render of ONE frameRec's CURRENT top screen -- the counterpart to the
-- periodic per-panel gate (M.gateFrame/M.startScheduled's task (e)), which Task 2 made NEVER touch
-- an event-mode screen and NEVER call M.showScreen proactively. This is what closes that visibility
-- gap: called from a Nav's onChange hook right after push()/pop() mutate the stack (so a nav change
-- repaints IMMEDIATELY, not on the next gate tick, up to `pfdMs`/FLIGHT_MS/PARAMS_MS later), and
-- once per frame at M.run's boot (every frame's initial top must be visible at startup, including
-- an EVENT screen like the terminal's "config" root -- the periodic gate would never reach it).
--
-- ALWAYS calls M.showScreen for the frame's current top (the lazy-build + visibility swap) --
-- covers BOTH event and rate tops, satisfying "every nav-top change swaps visibility" unconditionally.
-- When that top is a RATE panel (renderpolicy.policyFor(...).mode == "rate"), ADDITIONALLY
-- force-applies once: entry.handle.apply(state) is called directly, bypassing M.gateFrame's sig
-- dirty-gate entirely (a plain sig comparison can't tell "same screen, telemetry unchanged" apart
-- from "different screen that just happens to share this policy group's sig function" -- e.g.
-- flight/emc/fcs all share M.sigFlight, so switching between them with no telemetry change would
-- read as "no dirty" and silently fail to repaint without this forced bypass). After the forced
-- apply, `frameRec.lastSig`/`lastApplyAt` are rebaselined to the JUST-applied state/now, so
-- M.gateFrame's next periodic tick doesn't immediately think a fresh window has elapsed and
-- redundantly re-apply the same content again. An EVENT top gets showScreen only -- its lazy
-- page.build(...) call already populates the screen once, and its widgets self-render on
-- interaction (button presses etc.), so there's nothing further to force here, and nothing to
-- rebaseline (M.gateFrame never looks at an event top's lastSig/lastApplyAt at all).
function M.applyNow(basalt, runtime, frameRec)
  local top = frameRec.nav:top()
  local entry = M.showScreen(basalt, runtime, frameRec, top)
  local pfdMs = (runtime.config.pfd and runtime.config.pfd.renderMs) or 100
  local pol = renderpolicy.policyFor(top, pfdMs)
  if pol.mode == "rate" then
    local now = os.epoch("utc")
    local state = M.buildState(runtime, now)
    if entry and entry.handle and entry.handle.apply then
      entry.handle.apply(state)
    end
    frameRec.lastSig = pol.sig(state)
    frameRec.lastApplyAt = now
  end
  return entry
end

-- ===== Runtime: comms/engine/fuel machinery (reused verbatim from ui/main.lua) =====

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
--
-- NO peripheral access happens outside this function -- `require("ui.basalt.app")` stays clean
-- headless; a test supplies deps.modem/deps.wrap so this runs under CraftOS-PC too.
function M.buildRuntime(deps)
  deps = deps or {}
  local wrap = deps.wrap or peripheral.wrap
  local find = deps.find or peripheral.find

  local modem = deps.modem or find("modem")
  assert(modem, "UI-PC needs a modem on the wired network")

  local CH, CFG_CH = M.CH, M.CFG_CH

  -- One link per logical channel (UI listens on telemetry/ack/health, sends on command) --
  -- PLUS the CFG_CH client (S2): the UI now reads/writes the running FCS's config live -- SEND
  -- req/set on req (105), HEAR cfg/ack on reply (106). (Pre-S2 the UI was the config SERVER; that
  -- inversion retired ui/cfgserver.lua and the FCS boot's "ui" source.)
  local telLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.telemetry })
  local ackLink = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.ack })
  local hbLink  = modemlib.wrap(modem, { txCh = CH.command, rxCh = CH.health })
  local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.req, rxCh = CFG_CH.reply })
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
  -- (M.makeEngineWriter picks by config.engine.mode). Engine.mode is snapshotted at Engine.new;
  -- cycleMode must call rebuildEngineWriter after applyConfig so the writer arity matches the
  -- new mode (1-arg basic vs 2-arg latch).
  local writer = M.makeEngineWriter(RelayWriter, function() return relay end, config)

  local engine = Engine.new(config.engine, writer)

  local function rebuildEngineWriter()
    engine.writer = M.makeEngineWriter(RelayWriter, function() return relay end, config)
  end

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
  local fuelRate = FuelRate.new(config.fuel and config.fuel.rate)
  local fedTrack = FedTrack.new()   -- LFED: solid-fuel-fed-per-feed, from the 3s pump poll (no extra reads)

  local cfgClient = CfgClient.new({ link = cfgLink })

  return {
    links = { tel = telLink, ack = ackLink, hb = hbLink },
    cfgLink = cfgLink,
    navLink = navLink,
    rx = rx,
    sender = sender,
    hbRx = hbRx,
    bootAt = os.epoch("utc"),   -- UI boot time (ms) -- fcslink's "quick startup recognition" reference

    engine = engine,
    fuelReaders = fuelReaders,
    fuelRate = fuelRate,
    fedTrack = fedTrack,
    cfgClient = cfgClient,
    cfgCache = {},          -- kind -> { body = table, status = "ok"|"sync"|"fail" }
    cfgSaveStatus = nil,    -- last save result string, shown by the menus + FCS SYNC checker
    config = config,
    rebindRelay = rebindRelay,
    rebuildEngineWriter = rebuildEngineWriter,
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
  }
end

-- ===== Modem routing (testable, no sleeping) =====

-- M.routeModem(runtime, ch, msg) -> replyFrame|nil
-- Mirrors ui/main.lua's netLoop routing for tel/ack/health EXACTLY, plus CFG_CH client replies:
-- a cfg/ack frame on CFG_CH.reply is handed to cfgClient:onReply (the UI is the requester).
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
    runtime.cfgClient:onReply(c, os.epoch("utc"))
    return nil
  end

  local n = runtime.navLink:onMessage(ch, msg)
  -- NAV no longer relays a navhdg frame at all (Task 6): the FCS broadcasts its own compassHeading
  -- directly (see M.buildState's `heading` field, sourced from `rx`), so there is no navhdg branch
  -- here to handle any more -- only the slow GPS fix relay (navfix) remains on this link.
  if n and n.k == "navfix" then
    -- Slow GPS fix relay: position/speed only -- heading is no longer part of this relay at all
    -- (navhdg is gone; M.buildState reads compassHeading straight off the FCS snapshot instead).
    -- Store the craft's horizontal position too (fixX/fixZ) for NAV-menu waypoint targeting on the
    -- PFD.
    runtime.nav.gpsAlt = n.fix and n.fix.y or nil
    runtime.nav.fixX   = n.fix and n.fix.x or nil
    runtime.nav.fixZ   = n.fix and n.fix.z or nil
    runtime.nav.tas    = n.gs
    runtime.nav.fixOk  = n.fix ~= nil
    -- PARAMS extras (quality/disk/loopMs): copy only while the watch is open so GPS jitter
    -- cannot dirty the overhead panel when PARAMS is closed.
    if runtime.paramsOpen then
      runtime.nav.gpsQuality = n.fix and n.fix.quality or nil
      runtime.nav.disk = n.disk
      local now = os.epoch("utc")
      runtime.nav.loopMs = now - (runtime.nav._lastFixAt or now)
      runtime.nav._lastFixAt = now
    end
    return nil
  end

  -- NAV waypoint-store sync replies (ch 109) -> the client cache. Async: the client only SENDS;
  -- the reply arrives here and refreshes runtime.wptClient's cached store.
  if runtime.wptClient and runtime.wptClient.link then
    local wf = runtime.wptClient.link:onMessage(ch, msg)
    if wf and (wf.k == "wpt_store" or wf.k == "wpt_err" or wf.k == "wpt_disk_res") then
      runtime.wptClient:onReply(wf, os.epoch("utc"))
      -- Event-mode NAV is never gate-painted: a uiRev bump would only wake the 1 Hz PARAMS
      -- signature. Callers (startScheduled) wire onWptReply to apply() the visible nav page.
      if runtime.onWptReply then runtime.onWptReply() end
      return nil
    end
  end

  return nil
end

-- ===== PARAMS-open watch (edge-only) =====

-- M.setParamsOpen(runtime, open)
-- PARAMS is open when the merged flight page's bottom region top is `fcs_params`. Edge-only:
-- duplicate open/close (flag already equals `open`) sends nothing. Rising edge sends
-- `{ k = "paramsWatch", on = true }` on the FCS command path AND the NAV wpt-request link;
-- falling edge sends `on = false` and clears leftover local stamps so they cannot leak.
function M.setParamsOpen(runtime, open)
  if runtime.paramsOpen == open then return end
  runtime.paramsOpen = open
  runtime.links.tel:send(runtime.sender:send({ k = "paramsWatch", on = open }))
  if runtime.wptClient and runtime.wptClient.link then
    runtime.wptClient.link:send({ k = "paramsWatch", on = open })
  end
  if not open then
    if runtime.state then runtime.state.uiLoopMs, runtime.state._uiLoopAt = nil, nil end
    local nv = runtime.nav
    if nv then
      nv.gpsQuality, nv.loopMs, nv.disk, nv._lastFixAt = nil, nil, nil, nil
    end
  end
end

-- ===== Cadence state assembly (pure) =====

-- M.buildState(runtime, now) -> flat cadence.gate-shaped state table.
-- `now` is the ms epoch (os.epoch("utc")), matching what runtime.engine:tick/:status expect;
-- hbRx:up wants seconds, so it's divided down here exactly like ui/main.lua's snapshot() does.
function M.buildState(runtime, now)
  local latest = runtime.rx:latest() or {}
  local e = runtime.engine:status(now)
  -- Telemetry link health (heartbeat), shared by the `linkUp` field below and by the displayed
  -- heading: Rx:latest() (fcs/comms/telemetry.lua) has no time-based expiry, so `latest` freezes
  -- at the last snapshot forever once the link drops -- fine for fields that are allowed to hold
  -- their last value, but heading must go "---" on a stale/dead link (spec decision #2), so it's
  -- additionally gated on this heartbeat signal, below.
  local linkUp = runtime.hbRx:up(now / 1000)
  -- Missing-FCS blink cue for the FLIGHT feedback buttons: quick recognition when the FCS was never
  -- seen since UI boot, a grace window when a live link drops (ui/basalt/fcslink). hbRx.lastSeen is
  -- SECONDS; convert to ms. Phase folds into cadence.sig only while stale -> free when the link is up.
  local fcsStale, blinkPhase = fcslink.evaluate(now, {
    bootAt = runtime.bootAt,
    lastSeenMs = (runtime.hbRx and runtime.hbRx.lastSeen) and (runtime.hbRx.lastSeen * 1000) or nil,
  })
  -- PFD steering cue: an ACTIVE ROUTE's current leg (blue, auto-advancing) takes precedence, else a
  -- single selected waypoint (green). Needs the craft's horizontal position; heading from the SAME
  -- FCS snapshot the PFD's own displayed heading uses (gated on `linkUp`, spec decision #2 -- a
  -- stale/dead link blanks the bearing math too, not just the tape), altitude from baro. NAV no
  -- longer relays its own heading (navhdg is gone -- see nav/runtime.lua's R:heading), so this reads
  -- `latest.compassHeading` directly instead of a separate nav-relay freshness clock.
  local target = nil
  local nv = runtime.nav
  if nv and type(nv.fixX) == "number" and type(nv.fixZ) == "number" then
    local craft = { x = nv.fixX, z = nv.fixZ, heading = linkUp and latest.compassHeading or nil, baroY = latest.altitude }
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
  -- PARAMS extras: always-on tas/loopHz/flightMode already live on this table. The PARAMS-only
  -- fields (devWarn/diskFcs/uiLoopMs/navLoopMs/gpsQuality/diskNav) copy only while open.
  local paramsOpen = runtime.paramsOpen and true or false
  local devWarn, diskFcs, uiLoopMs, navLoopMs, gpsQuality, diskNav
  if paramsOpen then
    devWarn = latest.devWarn
    diskFcs = latest.disk
    uiLoopMs = runtime.state and runtime.state.uiLoopMs or nil
    navLoopMs = nv and nv.loopMs or nil
    gpsQuality = nv and nv.gpsQuality or nil
    diskNav = nv and nv.disk or nil
  end
  return {
    engaged      = latest.engaged,
    gndSafety    = latest.gndSafety,
    onGround     = latest.onGround,
    comAuto      = latest.comAuto,
    positionHold = latest.positionHold,
    mode         = latest.mode,
    flightMode   = latest.flightMode,
    masterMode   = latest.masterMode,
    trimDir      = latest.trimDir,
    linkUp       = linkUp,
    altitude     = latest.altitude,
    vSpeed       = latest.vSpeed,
    -- PFD: display heading, sourced from the FCS snapshot but gated on linkUp (spec decision #2:
    -- stale/dead telemetry -> "---", not a frozen bearing). Other telemetry fields intentionally
    -- freeze on link loss like they always have; only heading is required to blank.
    heading      = linkUp and latest.compassHeading or nil,
    loopHz       = latest.loopHz,
    fuel         = latest.fuel,
    fuelPct      = latest.fuelPct,
    badFuel      = latest.badFuel,
    engineMaster = e.master,
    feeding      = e.feeding,
    pulses       = e.pulses,
    nextFeedInMs = e.nextFeedInMs,
    pumpFrac     = runtime.state.pumpFrac,
    tankFrac     = runtime.state.tankFrac,
    pumpAmount   = runtime.state.pumpAmount,   -- raw solid count (merged page: % vs manual max)
    lfed         = runtime.state.lfed,          -- solid fuel fed on the last feed (LFED, EMC region)
    tankMb       = runtime.state.tankMb,       -- raw liquid mB (merged page: shown raw, gauge vs manual max)
    fuelEst      = runtime.state.fuelEst,      -- adaptive fuel time-to-empty estimate (ui/fuelrate)
    pitch        = latest.pitch,               -- PFD: attitude, sourced from the FCS snapshot
    roll         = latest.roll,
    sas          = latest.surgeVel,
    gpsAlt       = runtime.nav and runtime.nav.gpsAlt or nil,  -- PFD: nav (Task 7's listener writes runtime.nav)
    tas          = runtime.nav and runtime.nav.tas or nil,
    gpsFixOk     = runtime.nav and runtime.nav.fixOk or nil,
    target       = target,   -- PFD waypoint steering cue (NAV menu selection); nil when none
    fcsStale     = fcsStale,    -- FLIGHT feedback buttons blink the missing-FCS cue when true
    blinkPhase   = blinkPhase,  -- 0/1 outline blink phase (only meaningful while fcsStale)
    uiRev        = runtime.uiRev,
    paramsOpen   = paramsOpen,
    devWarn      = devWarn,
    diskFcs      = diskFcs,
    uiLoopMs     = uiLoopMs,
    navLoopMs    = navLoopMs,
    gpsQuality   = gpsQuality,
    diskNav      = diskNav,
  }
end

-- ===== Scheduled work (in-game only; basalt.schedule per easyhover2_suitex.lua's proven pattern) =====

-- M.gateFrame(rec, pol, state, now) -> shouldApply (bool)
-- PURE per-frameRec render-gate decision (no Basalt/showScreen/apply calls -- those stay in the
-- scheduled task (e) below, so this is directly unit-testable headless with a bare `{}` standing
-- in for a frameRec). `pol` is a ui/basalt/renderpolicy.lua M.policyFor(...) result.
--   * pol.mode ~= "rate" (i.e. "event"): ALWAYS returns false, and never touches `rec` -- an event
--     screen (config/nav/dtc/bitconfig/...) is never gate-applied here. M.applyNow (Task 3) is its
--     only render path: an instant, non-gated M.showScreen fired from the frame's Nav onChange hook
--     on push/pop, plus once per frame at M.run's boot.
--   * pol.mode == "rate" but `now - (rec.lastApplyAt or -inf) < pol.ms`: the panel's own poll
--     window hasn't elapsed yet -- returns false, no mutation (still waiting).
--   * Once elapsed: computes `sig = pol.sig(state)` and stamps `rec.lastApplyAt = now` AND
--     `rec.lastSig = sig` UNCONDITIONALLY (restarting this panel's own window either way), but
--     returns true (shouldApply) ONLY when `sig ~= ` the PREVIOUS `rec.lastSig` -- so an
--     elapsed-but-unchanged tick still resets the timer without re-painting, exactly mirroring
--     ui/basalt/cadence.lua's dirty-gate, just scoped to one frameRec's own cadence + own sig
--     instead of one global signature shared by every screen.
function M.gateFrame(rec, pol, state, now)
  if not pol or pol.mode ~= "rate" then return false end
  if now - (rec.lastApplyAt or -math.huge) < pol.ms then return false end
  local sig = pol.sig(state)
  local shouldApply = sig ~= rec.lastSig
  rec.lastSig = sig
  rec.lastApplyAt = now
  return shouldApply
end

-- M.startScheduled(basalt, runtime, frameRecs)
-- Registers seven basalt.schedule sleep-loop coroutines -- the SAME composition ui/main.lua ran
-- under parallel.waitForAny, ported one-for-one onto Basalt's own coroutine scheduler (verified
-- against release/basalt-full.lua: b_a.schedule creates a coroutine, resumes it once, and stores
-- its yielded filter; b_a's internal event dispatcher (bca) then resumes any scheduled coroutine
-- whose filter is nil or matches the incoming event, on every basalt.update(...)/basalt.run()
-- pump -- so a plain `os.pullEvent("modem_message")` loop inside a scheduled function receives
-- real modem_message events exactly like it would inside parallel.waitForAny, and `sleep(n)`
-- self-pumps the same way via "timer" events).
--
-- CRITICAL non-blocking discipline (same as ui/main.lua): peripheral polls and long ops live in
-- (a)-(d) below, NEVER in (e) the render-gate.
--
-- (e) is a PER-PANEL render gate (ui/basalt/renderpolicy.lua): every visible tick it loops over
-- `frameRecs`, and for each one's CURRENT top screen (frameRec.nav:top()) looks up
-- renderpolicy.policyFor(top, pfdMs) -- a PFD-rooted frame repaints on its own tunable ms + a
-- PFD-only sig, a FLIGHT/EMC/FCS-rooted frame on FLIGHT_MS + its own sig, TUNING on PARAMS_MS + its
-- own sig, and everything else ("event" mode: config/nav/dtc/bitconfig/...) is NEVER applied by
-- this gate at all -- M.applyNow (Task 3) is those screens' only render path. M.gateFrame
-- (above) makes the actual elapsed+dirty decision AND owns each frameRec's OWN lastApplyAt/lastSig
-- -- per-FRAME state, not one shared global signature -- so a PFD-only telemetry change can no
-- longer force-repaint a FLIGHT monitor next door, and vice-versa (TRUE per-panel isolation). The
-- base poll interval is `math.min(pfdMs, renderpolicy.FLIGHT_MS)`, recomputed every tick so a live
-- PFD-rate change (BIT/CONFIG -> PFD RATE) takes effect without a reboot -- but it's only ever the
-- OUTER loop cadence; each frame's own window inside M.gateFrame is what actually governs when it
-- paints.
-- Apply a built EVENT-mode screen (e.g. "nav") on every frame that already constructed it.
-- Used after an async waypoint-store reply: the 250 ms gate never paints event screens, and a
-- uiRev bump only wakes PARAMS. Apply even when the screen is not the current top so a later
-- showScreen visibility-swap (applyNow does not re-apply event tops) still shows the new store.
-- Returns how many handles were applied (for tests).
function M.applyEventTop(runtime, frameRecs, screenId)
  if not frameRecs then return 0 end
  local n = 0
  local now = os.epoch("utc")
  local state = M.buildState(runtime, now)
  for _, rec in pairs(frameRecs) do
    local entry = rec.built and rec.built[screenId]
    if entry and entry.handle and type(entry.handle.apply) == "function" then
      entry.handle.apply(state)
      n = n + 1
    end
  end
  return n
end

-- Drop online when the NAV PC has gone silent, and apply event-mode NAV only on a true->false
-- edge so a parked page paints "NAV offline" / disabled actions without a click. Returns how
-- many handles applyEventTop painted (0 when already offline or still fresh).
function M.tickWptFreshness(runtime, frameRecs, now)
  local c = runtime and runtime.wptClient
  if not c then return 0 end
  local was = c.online
  local live = c:refreshOnline(now)
  if was and not live then
    return M.applyEventTop(runtime, frameRecs, "nav")
  end
  return 0
end

function M.startScheduled(basalt, runtime, frameRecs)
  frameRecs = frameRecs or {}
  runtime.onWptReply = function()
    M.applyEventTop(runtime, frameRecs, "nav")
  end

  -- (a) modem_message router: telemetry -> rx, ack -> sender, health -> hbRx, cfg/ack -> cfgClient.
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
      pcall(function()
        local latest = runtime.rx and runtime.rx.latest and runtime.rx:latest()
        runtime.engine:applyTel(latest, now)
        runtime.engine:tick(now)
      end)
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

  -- (c) fuel poll, 3s.
  basalt.schedule(function()
    while true do
      -- Capture the raw amount too (2nd return): the merged flight page divides by a MANUALLY set
      -- max (config.fuel.<role>.full), not the device capacity, and shows the main tank in raw mB.
      runtime.state.pumpFrac, runtime.state.pumpAmount =
        Fuel.read(runtime.fuelReaders.pump, runtime.config.fuel.pump.kind, runtime.config.fuel.pump)
      runtime.state.tankFrac, runtime.state.tankMb =
        Fuel.read(runtime.fuelReaders.tank, runtime.config.fuel.tank.kind, runtime.config.fuel.tank)
      runtime.state.lfed = runtime.fedTrack:poll(runtime.state.pumpAmount)
      runtime.fuelRate:push(runtime.state.tankMb, os.epoch("utc"))
      runtime.state.fuelEst = runtime.fuelRate:read()
      sleep(3.0)
    end
  end)

  -- (d) sender retry, 0.25s.
  basalt.schedule(function()
    while true do
      for _, f in ipairs(runtime.sender:tick(0.25)) do runtime.links.tel:send(f) end
      sleep(0.25)
    end
  end)

  -- (g) NAV store sync poll, 2s: tick freshness (apply NAV on a true->false drop) then pull the
  -- waypoint/route store so the cache stays fresh + a silent NAV can recover. Cheap (one small
  -- frame); the reply lands via routeModem -> wptClient:onReply. First request fires immediately
  -- so the menu populates as soon as it opens.
  basalt.schedule(function()
    while true do
      if runtime.wptClient then
        pcall(function()
          M.tickWptFreshness(runtime, frameRecs, os.epoch("utc"))
          runtime.wptClient:request()
        end)
      end
      sleep(2.0)
    end
  end)

  -- (h) CFG client tick, 0.25s: retransmit timed-out req/set (2 s x 3) and fail callbacks when
  -- the FCS stays silent. Replies land via routeModem -> cfgClient:onReply.
  basalt.schedule(function()
    while true do
      pcall(function() runtime.cfgClient:tick(os.epoch("utc")) end)
      sleep(0.25)
    end
  end)

  -- (e) render gate, PER-PANEL: see M.gateFrame + the header comment above M.startScheduled.
  basalt.schedule(function()
    while true do
      local now = os.epoch("utc")
      -- UI LOOP stamp: period between successive render-gate iterations, only while PARAMS is
      -- open. Closed: leave previous/nil (setParamsOpen nils uiLoopMs on the falling edge).
      if runtime.paramsOpen and runtime.state then
        runtime.state.uiLoopMs = now - (runtime.state._uiLoopAt or now)
        runtime.state._uiLoopAt = now
      end
      local state = M.buildState(runtime, now)
      local pfdMs = (runtime.config.pfd and runtime.config.pfd.renderMs) or 100
      for _, rec in pairs(frameRecs) do
        local top = rec.nav:top()
        local pol = renderpolicy.policyFor(top, pfdMs)
        if M.gateFrame(rec, pol, state, now) then
          local t0 = os.epoch("utc")
          local entry = M.showScreen(basalt, runtime, rec, top)
          if entry and entry.handle and entry.handle.apply then
            entry.handle.apply(state)
          end
          if runtime.uilog.enabled then
            runtime.uilog:event("RENDER", ("apply %dms (%s)"):format(os.epoch("utc") - t0, tostring(top)), t0)
          end
        end
      end
      -- Base poll interval only -- each frame's OWN cadence is enforced inside M.gateFrame, not
      -- here. Tunable live via BIT/CONFIG -> PFD RATE (ui.config pfd.renderMs); recomputed every
      -- tick so a live change takes effect without a reboot. Protects the server-global render
      -- budget the FCS shares -- faster = smoother, watch the FCS loopHz.
      sleep(math.min(pfdMs, renderpolicy.FLIGHT_MS) / 1000)
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
        elseif e == "monitor_touch" then runtime.uilog:event("INPUT", ("touch %s @%s,%s"):format(tostring(ev[2]), tostring(ev[3]), tostring(ev[4])), now)  -- cockpit MONITORS fire this, not mouse_click
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
-- assigned page id (M.rootForMonitor, default "emc" when unassigned/invalid). Every frameRec's
-- `nav.onChange` is wired to M.applyNow (Task 3) BEFORE anything else can trigger a push/pop, so a
-- nav-stack change (BIT/CONFIG, BACK, any page's own push) repaints that frame IMMEDIATELY --
-- M.showScreen always, plus a forced handle.apply(state) when the new top is a rate panel -- rather
-- than waiting on the next periodic gate tick; an explicit M.applyNow pass over every frameRec right
-- after `runtime.applyColors()` additionally guarantees each frame's INITIAL top is shown at boot,
-- including an event-mode root like the terminal's "config" page that M.gateFrame's periodic gate
-- would otherwise never reach. `frameRecs` is ALSO handed to M.startScheduled, whose (e) render-gate
-- task per-panel decides (M.gateFrame, ui/basalt/renderpolicy.lua) when to periodically
-- handle.apply(state) each frame's OWN current top on its OWN cadence + OWN dirty-gate -- FCS-SAFE:
-- peripheral polls stay in M.startScheduled's (a)-(d), never on this render path; event-mode
-- screens are NEVER touched by that periodic gate at all, by design (M.applyNow is their only
-- render path). deps.* mirrors M.buildRuntime's injectable seams (modem/wrap/find) plus
-- deps.basaltOpts (-> M.ensureBasalt) and deps.getNames/deps.getType (-> M.discoverMonitors).
--
-- The FCS is the config source of truth (S2): the BIT/CONFIG menus read/write it live via
-- runtime.cfgClient over CFG_CH; there is no UI-side config server any more.
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

  -- Instant render on nav switch (Task 3): wire every frame's Nav so a push()/pop() repaints THAT
  -- frame immediately (M.applyNow), instead of waiting for the next periodic gate tick -- closes
  -- the visibility gap Task 2 opened when it stopped M.showScreen-ing proactively from the gate and
  -- removed the old navChanged/extraDirty trigger. See M.applyNow's header comment for the full
  -- rationale (forced apply + rebaseline on a same-policy-group switch, event tops get showScreen
  -- only). Wired for every frameRec built so far (terminal + every currently-present monitor);
  -- M.reconcileMonitors wires the same hook for any frame it builds/re-roots later.
  for _, frameRec in pairs(frameRecs) do
    frameRec.nav.onChange = function() M.applyNow(basalt, runtime, frameRec) end
  end

  -- CONFIG page hooks (guarded no-ops until here). REFRESH / SET UI re-resolve the live monitor
  -- frames to the current assign+present set with no PC reboot (M.reconcileMonitors); BIT/CONFIG
  -- opens the hub on the terminal frame, mirroring the NAV page's push("bitconfig").
  runtime.refreshMonitors = function()
    M.reconcileMonitors(basalt, runtime, built, frameRecs,
      M.discoverMonitors(deps.getNames, deps.getType), deps.wrap)
  end
  runtime.openBitConfig = function() frameRecs.terminal.nav:push("bitconfig") end

  -- Uniform colour scheme (ui/theme): a custom Basalt theme paints black on every element/nesting
  -- depth with the configured font colour, and the palette overrides (lightRed + any colourblind
  -- remap) are written to the terminal and every monitor term. Exposed as runtime.applyColors so the
  -- UI SETTINGS submenu can re-apply live after a colour change; called once now for the first render.
  runtime.applyColors = function()
    Theme.applyTheme(basalt, runtime.config.colors)
    Theme.applyPalette(term, runtime.config.colors)
    for _, rec in pairs(built.monitors) do Theme.applyPalette(rec.term, runtime.config.colors) end
    runtime.uiRev = (runtime.uiRev or 0) + 1
  end
  runtime.applyColors()

  -- Boot visibility (Task 3, acceptance criterion 1): M.applyNow's M.showScreen call is the ONLY
  -- thing that ever shows an EVENT-mode screen (config/nav/dtc/bitconfig/...) -- M.gateFrame's
  -- periodic gate never applies one. Without this explicit initial pass, the terminal's "config"
  -- root (and any monitor rooted at an event page) would render as a blank frame forever, until an
  -- operator happened to navigate away and back on it. Run AFTER runtime.applyColors() so the very
  -- first paint already uses the configured palette, not the Basalt default one.
  for _, frameRec in pairs(frameRecs) do
    M.applyNow(basalt, runtime, frameRec)
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

  M.startScheduled(basalt, runtime, frameRecs)
  basalt.run()
end

return M
