-- nav/app.lua
-- NAV role bootstrap. Reuses ui.basalt.app.ensureBasalt to load the vendored Basalt (the nav role
-- ships release/basalt-full.lua, like the ui role), then stands up a terminal frame with a MAIN and
-- a CONFIG tab and runs event-driven scheduled loops: hear GPS -> receiver, relay the GPS fix on a
-- timer, render on a quantized gate. Heading is no longer a NAV-owned relay -- NAV hears the FCS's
-- own telemetry (ch 101) and reads compassHeading straight off that snapshot for its own status. The
-- peripheral + event glue is thin; all the logic lives in nav.runtime / nav.ui.* (unit-tested).
-- buildRuntime/routeModem/buildState are injectable seams so the whole pipeline self-tests headless.
-- NO peripheral/Basalt access at module LOAD; run() is IN-GAME ONLY (it calls basalt.run(), which
-- blocks forever).
local navconfig  = require("nav.config")
local NavRuntime = require("nav.runtime")
local Main       = require("nav.ui.main")
local ConfigPage = require("nav.ui.config")
local protocol   = require("fcs.comms.protocol")
local modemlib   = require("fcs.comms.modem")
local telemetry  = require("fcs.comms.telemetry")
local W          = require("nav.waypoints")
local wptserver  = require("nav.wptserver")
local wptdisk    = require("nav.wptdisk")
local navcfg     = require("nav.navcfg")

local M = {}
M.CONFIG_PATH = navconfig.PATH

-- The NAV PC owns the waypoint/route store + the disk drive; the cockpit NAV menu is a sync client
-- (ui.basalt.wptclient) that requests on 108 and gets replies on 109.
M.WPT_STORE_PATH = "/eh2_nav_wpt.tbl"
M.WPT_REQ_CH = 108
M.WPT_REPLY_CH = 109

-- The NAV hears the FCS telemetry it shares the wired network with -- the SAME channel + decode path
-- ui/basalt/app.lua uses (fcs.comms.telemetry's Rx, for correct seq/session dedup). It caches the
-- true-Y baro (snapshot.altitude) as its accurate vertical source, AND stores the whole snapshot on
-- the nav runtime (R:onFcsSnapshot) so R:heading reads compassHeading -- NAV no longer reads its own
-- navigation_table at all. Same channel as ui/main.lua's telemetry.
M.TELEMETRY_CH = 101
-- Baro is considered fresh within this window of the last telemetry frame (FCS sends ~10Hz); past
-- it the NAV falls back to the trilaterated GPS y.
M.BARO_MAX_AGE_MS = 1000

-- Render cadence for the (c) gate below: this shell is a rarely-watched debug screen (position/
-- fix/quality/beacon status), not a flight display -- 3 s is plenty; heading (which WOULD want a
-- fast cadence) lives on the PFD instead, not here.
M.RENDER_S = 3.0

-- Basalt loader (mirrors ui/basalt/app.lua's ensureBasalt -- deliberately NOT required from there,
-- so the nav role's dependency closure stays lean and never pulls in the whole cockpit page
-- registry). loadfile(path,nil,_ENV), never dofile(): CC:Tweaked's dofile loads with the BIOS's
-- bare _G (no require/package), and the vendored bundle needs package.path for its module loader.
-- The nav role ships release/basalt-full.lua (extraFiles), so a candidate path always exists.
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      local chunk, err = doLoadfile(path, nil, _ENV)
      if not chunk then error("Basalt did not parse: " .. tostring(err)) end
      local ok, basalt = pcall(chunk)
      if not ok or type(basalt) ~= "table" then error("Basalt failed to load: " .. tostring(basalt)) end
      return basalt
    end
  end
  error("Basalt not found -- reinstall the nav role via the Suite")
end

-- M.buildRuntime(deps): loads config and wires the nav runtime. deps (all optional/injectable):
--   gpsModem, wiredModem (raw modems), find (peripheral.find override), now (clock fn), configPath,
--   telemetryRx (fcs.comms.telemetry.Rx override, for tests). No navtable dep -- NAV no longer
--   binds/reads a navigation_table peripheral anywhere; heading comes from the FCS's own telemetry
--   snapshot (see M.routeModem's TELEMETRY_CH branch).
function M.buildRuntime(deps)
  deps = deps or {}
  local find = deps.find or peripheral.find
  local now  = deps.now  or function() return os.epoch("utc") end
  local cfg  = navconfig.withDefaults(select(1, navconfig.load(deps.configPath or M.CONFIG_PATH)) or {})

  local gpsModem = deps.gpsModem
  local wiredModem = deps.wiredModem
  if not gpsModem then gpsModem = find("modem", function(_, m) return m.isWireless and m.isWireless() end) end
  if not wiredModem then wiredModem = find("modem", function(_, m) return not (m.isWireless and m.isWireless()) end) end
  if gpsModem and gpsModem.open then gpsModem.open(cfg.channel) end
  -- Listen for FCS telemetry on the shared wired network -- the true-Y baro (NAV y-source) AND the
  -- compassHeading NAV's own status now reads (no navtable) -- and for cockpit NAV-menu waypoint
  -- sync requests (108, reply on 109).
  if wiredModem and wiredModem.open then pcall(wiredModem.open, M.TELEMETRY_CH) end
  if wiredModem and wiredModem.open then pcall(wiredModem.open, M.WPT_REQ_CH) end

  -- Waypoint/route store (this PC owns it) + the reply link the request handler answers on.
  local wptStorePath = deps.wptStorePath or M.WPT_STORE_PATH
  local store = select(1, W.load(wptStorePath)) or W.defaults()
  local wptLink = deps.wptLink
  if not wptLink and wiredModem then
    wptLink = modemlib.wrap(wiredModem, { txCh = M.WPT_REPLY_CH, rxCh = M.WPT_REQ_CH })
  end

  local rt = NavRuntime.new({ config = cfg, gpsModem = gpsModem, wiredModem = wiredModem, now = now })
  return { nav = rt, config = cfg, gpsModem = gpsModem, wiredModem = wiredModem, uiRev = 0, now = now,
           save = function(c) navconfig.save(M.CONFIG_PATH, c or cfg) end,
           store = store, wptRev = 0, wptLink = wptLink,
           saveStore = function(s) W.save(wptStorePath, s or store) end,
           -- FCS telemetry receiver (ch 101): SAME Rx type + decode path as ui/basalt/app.lua's
           -- `rx`, so seq/session dedup matches exactly -- reused, not reinvented (M.routeModem).
           telemetryRx = deps.telemetryRx or telemetry.Rx.new() }
end

-- M.handleWptRequest(runtime, msg) -> reply. nav_cfg_get/set go through nav.navcfg (persist cfg on
-- successful set). wpt_get/wpt_op go through nav.wptserver (persist store on rev change). Disk ops
-- (wpt_disk) are routed to nav.wptdisk. Testable: inject runtime.config/save + store/saveStore.
function M.handleWptRequest(runtime, msg)
  if type(msg) == "table" and msg.k == "paramsWatch" then
    if runtime.nav and runtime.nav.onParamsWatch then
      runtime.nav:onParamsWatch(msg.on, runtime.diskPresent or function()
        local ok, drive = pcall(peripheral.find, "drive")
        if not ok or not drive or not drive.isDiskPresent then return false end
        local ok2, present = pcall(drive.isDiskPresent)
        return ok2 and present and true or false
      end)
    end
    return nil
  end
  if type(msg) == "table" and msg.k == "wpt_disk" then return M.handleDisk(runtime, msg) end
  if type(msg) == "table" then
    local reply, newCfg = navcfg.apply(runtime.config, msg)
    if reply then
      if msg.k == "nav_cfg_set" and reply.ok then
        runtime.config = newCfg
        if runtime.save then pcall(runtime.save, newCfg) end
      end
      return reply
    end
  end
  local reply, newStore, newRev = wptserver.apply(runtime.store, msg, runtime.wptRev or 0)
  if newRev ~= (runtime.wptRev or 0) then
    runtime.store = newStore
    runtime.wptRev = newRev
    if runtime.saveStore then pcall(runtime.saveStore, runtime.store) end
  end
  return reply
end

-- M.diskDeps() -> { mount, read, write, delete } from the real disk drive on THIS (NAV) PC, or
-- { mount=nil } when no disk is present. In-game only (peripheral/fs); injected in tests.
function M.diskDeps()
  local drive = peripheral.find("drive")
  if not drive or not (drive.isDiskPresent and drive.isDiskPresent()) then return { mount = nil } end
  return {
    mount  = drive.getMountPath and drive.getMountPath() or nil,
    read   = function(p) local f = fs.open(p, "r"); if not f then return nil end local b = f.readAll(); f.close(); return b end,
    write  = function(p, b) local f = fs.open(p, "w"); if not f then return false end f.write(b); f.close(); return true end,
    delete = function(p) if fs.exists(p) then fs.delete(p) end end,
  }
end

-- M.handleDisk(runtime, msg, dd) -> reply. Runs a wpt_disk op (scan/import/export/clean) against the
-- NAV PC's disk (dd = injected disk deps, default M.diskDeps()). IMPORT merges + persists + replies
-- the fresh store (so the cockpit cache refreshes); the rest reply a wpt_disk_res status. Testable
-- via injected dd.
function M.handleDisk(runtime, msg, dd)
  dd = dd or M.diskDeps()
  local mount = dd and dd.mount or nil
  local op = msg.op
  if op == "export" then
    return { k = "wpt_disk_res", op = op, ok = wptdisk.export(runtime.store, mount, dd), mount = mount }
  elseif op == "import" then
    local merged = wptdisk.import(runtime.store, mount, dd)
    if merged then
      runtime.store = merged
      runtime.wptRev = (runtime.wptRev or 0) + 1
      if runtime.saveStore then pcall(runtime.saveStore, runtime.store) end
      return { k = "wpt_store", store = runtime.store, rev = runtime.wptRev }
    end
    return { k = "wpt_disk_res", op = op, ok = false, err = "import failed" }
  elseif op == "scan" then
    return { k = "wpt_disk_res", op = op, result = wptdisk.scan(mount, dd) }
  elseif op == "clean" then
    return { k = "wpt_disk_res", op = op, ok = wptdisk.clean(mount, dd) }
  end
  return { k = "wpt_err", err = "unknown disk op: " .. tostring(op) }
end

-- M.routeModem(runtime, ch, replyCh, msg, dist): GPS-channel messages feed the receiver; FCS
-- telemetry on TELEMETRY_CH decodes through runtime.telemetryRx (fcs.comms.telemetry's Rx -- the
-- SAME seq/session-deduped decode ui/basalt/app.lua uses, reused rather than hand-rolled), then
-- caches the true-Y baro for the NAV y-source AND hands the whole snapshot to the nav runtime
-- (R:onFcsSnapshot) so R:heading reads compassHeading. Everything else ignored.
function M.routeModem(runtime, ch, replyCh, msg, dist)
  if ch == runtime.config.channel then
    return runtime.nav:onModemMessage(ch, replyCh, msg, dist)
  end
  if ch == M.TELEMETRY_CH then
    local f = protocol.decode(msg)
    if type(f) == "table" and runtime.telemetryRx:accept(f) then
      local snap = runtime.telemetryRx:latest()
      runtime.nav:onFcsSnapshot(snap)
      if type(snap) == "table" and type(snap.altitude) == "number" then
        runtime.baroY  = snap.altitude
        runtime.baroAt = runtime.now()
      end
    end
    return false
  end
  if ch == M.WPT_REQ_CH then
    -- A cockpit NAV-menu sync request: apply + persist, reply on 109.
    local ok, f = pcall(protocol.decode, msg)
    if ok and type(f) == "table" and (f.k == "wpt_get" or f.k == "wpt_op" or f.k == "wpt_disk" or f.k == "paramsWatch" or f.k == "nav_cfg_get" or f.k == "nav_cfg_set") then
      local reply = M.handleWptRequest(runtime, f)
      if reply and runtime.wptLink then pcall(function() runtime.wptLink:send(reply) end) end
    end
    return false
  end
  return false
end

-- M.buildState(runtime, now): the flat state the render gate + pages read. Attaches the cached FCS
-- baro + its freshness so nav.ui.main can pick baro (B) vs trilaterated (N) y.
function M.buildState(runtime, now)
  now = now or runtime.now()
  local nav = runtime.nav:status(now)
  nav.baroY = runtime.baroY
  nav.baroFresh = (runtime.baroAt ~= nil) and ((now - runtime.baroAt) <= M.BARO_MAX_AGE_MS) or false
  return { nav = nav, uiRev = runtime.uiRev }
end

-- M.signature(state): quantized render-gate key -- repaint only when the fix/mesh changes. Heading
-- is NOT keyed here: it no longer displays on this shell (moved to the PFD), so a heading-only
-- change must not trigger a repaint.
function M.signature(state)
  local s = state.nav or {}
  local f = s.fix
  local pos = f and ("%d,%d,%d"):format(math.floor(f.x + 0.5), math.floor(f.y + 0.5), math.floor(f.z + 0.5)) or "nofix"
  local n = 0
  for _ in pairs(s.beacons or {}) do n = n + 1 end
  return table.concat({ pos, tostring(n), tostring(f and f.quality or 0), tostring(state.uiRev or 0) }, "|")
end

-- ===== run(): in-game only =====
function M.run(deps)
  deps = deps or {}
  local basalt = M.ensureBasalt(deps.basaltOpts)
  local runtime = M.buildRuntime(deps)

  local root = basalt.getMainFrame()
  local w, h = root:getSize()

  -- Two tab child frames + a top button row.
  local mainFrame = root:addFrame({ x = 1, y = 2, width = w, height = h - 1 })
  local cfgFrame  = root:addFrame({ x = 1, y = 2, width = w, height = h - 1 })
  local mainPage = Main.build(basalt, mainFrame, runtime, nil)
  local cfgPage  = ConfigPage.build(basalt, cfgFrame, runtime, nil)

  local function show(which)
    mainFrame:setVisible(which == "main")
    cfgFrame:setVisible(which == "config")
    runtime.uiRev = runtime.uiRev + 1
  end
  root:addButton({ x = 1, y = 1, width = 8, height = 1, text = "[MAIN]" }):onClick(function() show("main") end)
  root:addButton({ x = 10, y = 1, width = 10, height = 1, text = "[CONFIG]" }):onClick(function() show("config") end)
  show("main")

  -- (a) hear GPS broadcasts.
  basalt.schedule(function()
    while true do
      local _, _, ch, replyCh, msg, dist = os.pullEvent("modem_message")
      M.routeModem(runtime, ch, replyCh, msg, dist)
    end
  end)

  -- (b) SLOW GPS fix relay: trilateration + position/speed, event-driven with a sleep between.
  -- (Heading no longer rides a NAV relay -- the FCS broadcasts its own compassHeading directly on
  -- ch 101, which the modem-message router (a) above already feeds into runtime.nav's snapshot.)
  basalt.schedule(function()
    while true do
      pcall(function() runtime.nav:step(os.epoch("utc")) end)
      sleep((runtime.config.intervalMs or 250) / 1000)
    end
  end)

  -- Disk presence for gated navfix.disk: filtered pulls flip the local boolean always
  -- (not polling); Runtime:frame publishes disk only while paramsWatch is on.
  -- These schedules never send a navfix themselves -- step() is the only publisher.
  basalt.schedule(function()
    while true do
      os.pullEvent("disk")
      if runtime.nav then runtime.nav.disk = true end
    end
  end)
  basalt.schedule(function()
    while true do
      os.pullEvent("disk_eject")
      if runtime.nav then runtime.nav.disk = false end
    end
  end)

  -- (c) render gate: repaint only when the quantized signature changes.
  basalt.schedule(function()
    local lastSig = nil
    while true do
      local state = M.buildState(runtime, os.epoch("utc"))
      local sig = M.signature(state)
      if sig ~= lastSig then
        lastSig = sig
        pcall(mainPage.apply, state)
      end
      sleep(M.RENDER_S)
    end
  end)

  basalt.run()
end

return M
