-- tests/test_basalt_app.lua
-- Headless probe (REAL CraftOS-PC): Basalt loads from the staged /release/basalt-full.lua,
-- and M.buildFrames constructs a frame per (mocked) monitor + one terminal frame, mirroring
-- honored, and a single basalt.update(...) render pass does not error.
--
-- Task 14 additions: M.buildRuntime/M.routeModem/M.buildState/M.startScheduled -- the reused
-- comms/engine/fuel machinery ported from ui/main.lua onto Basalt's scheduler, with a mock modem
-- + mock file reader so it runs with zero real peripherals.
local t = require("tests.framework")
local M = require("ui.basalt.app")
local protocol  = require("fcs.comms.protocol")
local telemetry = require("fcs.comms.telemetry")
local S         = require("fcs.comms.cfgsync")
local RelayWriter = require("ui.relaywriter")
local renderpolicy = require("ui.basalt.renderpolicy")

-- Minimal mock monitor/term: covers every term method release/basalt-full.lua's render path
-- (render.lua: setCursorPos/blit/setTextColor/setCursorBlink; BaseFrame's "term" setter:
-- setCursorPos presence gate + getSize) invokes, plus the rest of the CC:T monitor surface
-- listed in the task brief so any incidental call is a harmless no-op rather than a crash.
local function newMockMonitor()
  return {
    setCursorPos = function() end,
    write = function() end,
    blit = function() end,
    setTextColor = function() end,
    setTextColour = function() end,
    setBackgroundColor = function() end,
    setBackgroundColour = function() end,
    getSize = function() return 30, 12 end,
    clear = function() end,
    clearLine = function() end,
    setCursorBlink = function() end,
    isColor = function() return true end,
    isColour = function() return true end,
    getTextScale = function() return 1 end,
    setTextScale = function() end,
    scroll = function() end,
    getCursorPos = function() return 1, 1 end,
  }
end

t.test("ensureBasalt loads the vendored release build headless", function()
  local basalt = M.ensureBasalt()
  t.truthy(type(basalt) == "table", "basalt module should be a table")
  t.truthy(type(basalt.createFrame) == "function", "basalt.createFrame should exist")
  t.truthy(type(basalt.getMainFrame) == "function", "basalt.getMainFrame should exist")
  t.truthy(type(basalt.update) == "function", "basalt.update should exist")
end)

t.test("buildFrames creates a frame per assigned monitor (mirrored) plus a terminal frame", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mB = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1, mB = 1 }, { "mA", "mB" }, wrap)

  t.truthy(built.terminal ~= nil, "terminal frame should exist")
  t.truthy(built.monitors.mA ~= nil, "mA frame entry should exist")
  t.truthy(built.monitors.mB ~= nil, "mB frame entry should exist")
  t.truthy(built.monitors.mA.frame ~= nil, "mA should have a frame")
  t.truthy(built.monitors.mB.frame ~= nil, "mB should have a frame")
  t.eq(built.monitors.mA.panelId, 1)
  t.eq(built.monitors.mB.panelId, 1)   -- mirrored onto the same panel id
  t.eq(#built.resolved.unassigned, 0)

  -- ONE render pass across every active frame (terminal + both mocked monitors). NEVER
  -- basalt.run() here -- that blocks on os.pullEventRaw() in a loop.
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("buildFrames leaves unassigned present monitors out of the assigned set", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor(), mC = newMockMonitor() }
  local wrap = function(name) return mocks[name] end

  local built = M.buildFrames(basalt, { mA = 1 }, { "mA", "mC" }, wrap)

  t.truthy(built.monitors.mA ~= nil, "mA should be built")
  t.truthy(built.monitors.mC == nil, "mC has no assignment, should not get a frame")
  t.eq(#built.resolved.unassigned, 1)
  t.eq(built.resolved.unassigned[1], "mC")
end)

-- ===== Task 14: buildRuntime / routeModem / buildState / startScheduled =====

local CH, CFG_CH = M.CH, M.CFG_CH

-- Mock modem: covers everything modemlib.wrap needs (open, transmit) and records every transmit
-- so a test can assert a cfgsync reply actually went out, not just that routeModem returned one.
local function newMockModem()
  local sent = {}
  local dev = {
    open = function() end,
    isWireless = function() return false end,
  }
  dev.transmit = function(tx, rx, msg) sent[#sent + 1] = { tx = tx, rx = rx, msg = msg } end
  dev._sent = sent
  return dev
end

local function newRuntime(files)
  local modem = newMockModem()
  local runtime = M.buildRuntime({
    modem = modem,
    wrap = function() return {} end,          -- no relay/fuel peripherals present in this probe
    read = function(p) return (files or {})[p] end,
  })
  return runtime, modem
end

t.test("buildRuntime wires comms/engine/fuel/cfgsync with injected deps, no real peripherals", function()
  local runtime = newRuntime()
  t.truthy(runtime.links ~= nil and runtime.links.tel ~= nil, "tel link present")
  t.truthy(runtime.links.ack ~= nil, "ack link present")
  t.truthy(runtime.links.hb ~= nil, "hb link present")
  t.truthy(runtime.cfgLink ~= nil, "cfgLink present")
  t.truthy(runtime.rx ~= nil, "rx present")
  t.truthy(runtime.sender ~= nil, "sender present")
  t.truthy(runtime.hbRx ~= nil, "hbRx present")
  t.truthy(runtime.engine ~= nil, "engine present")
  t.truthy(runtime.fuelReaders ~= nil and runtime.fuelReaders.pump and runtime.fuelReaders.tank, "fuelReaders present")
  t.truthy(runtime.cfgClient ~= nil, "cfgClient present")
  t.truthy(type(runtime.cfgCache) == "table", "cfgCache present")
  t.eq(runtime.uiRev, 0)
  -- UI logger present + a no-op setLogStatus (real overlay wired only in M.run, in-game).
  t.truthy(runtime.uilog ~= nil, "uilog present")
  t.eq(runtime.uilog.enabled, false, "logging off by default (no _G.EH2_UILOG / deps.uilog)")
  t.eq(type(runtime.setLogStatus), "function", "setLogStatus stub present")
end)

t.test("buildRuntime arms the UI logger when deps.uilog is true", function()
  local modem = newMockModem()
  local runtime = M.buildRuntime({ modem = modem, wrap = function() return {} end,
    read = function() return nil end, uilog = true })
  t.eq(runtime.uilog.enabled, true, "deps.uilog=true arms logging")
  runtime.uilog:event("TEST", "hello", 1000)
  t.eq(#runtime.uilog:rows(), 1, "events record when armed")
end)

t.test("routeModem accepts a telemetry frame into rx", function()
  local runtime = newRuntime()
  local tx = telemetry.Tx.new()
  local frame = tx:frame({ engaged = true, altitude = 42, mode = "HOVER" })
  M.routeModem(runtime, CH.telemetry, protocol.encode(frame))
  local latest = runtime.rx:latest()
  t.truthy(latest ~= nil, "rx has a snapshot")
  t.eq(latest.altitude, 42)
  t.eq(latest.mode, "HOVER")
end)

t.test("routeModem acks the pending sender frame", function()
  local runtime = newRuntime()
  local cmdFrame = runtime.sender:send({ k = "engage" })
  t.truthy(runtime.sender.pending[cmdFrame.id] ~= nil, "pending before ack")
  M.routeModem(runtime, CH.ack, protocol.encode({ k = "ack", sid = cmdFrame.sid, id = cmdFrame.id }))
  t.eq(runtime.sender.pending[cmdFrame.id], nil, "ack clears pending")
end)

t.test("routeModem marks health rx up", function()
  local runtime = newRuntime()
  t.eq(runtime.hbRx:up(os.epoch("utc") / 1000), false, "no heartbeat yet -> down")
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = os.epoch("utc") / 1000 }))
  t.eq(runtime.hbRx:up(os.epoch("utc") / 1000), true, "heartbeat -> up")
end)

t.test("routeModem delivers a cfg reply to the cfg client's read callback", function()
  local runtime = newRuntime()
  local got
  local sid = runtime.cfgClient:readKind("tuning", function(body) got = body end)
  M.routeModem(runtime, CFG_CH.reply, protocol.encode(S.cfg(sid, "tuning", { gains = 3 })))
  t.truthy(got ~= nil and got.gains == 3, "cfg reply reached the read callback")
end)

t.test("routeModem delivers an ack to the cfg client's write callback", function()
  local runtime = newRuntime()
  local okSeen
  local sid = runtime.cfgClient:writeKind("tuning", { gains = {}, caps = {}, feel = {} },
    function(ok) okSeen = ok end)
  M.routeModem(runtime, CFG_CH.reply, protocol.encode(S.ack(sid, "tuning", true, nil)))
  t.eq(okSeen, true, "ack reached the write callback")
end)

t.test("cfgMenuStatus reports sync until cached, then ok, and requests missing kinds once", function()
  local runtime = { cfgCache = {} }
  local requested = {}
  local requestFn = function(kind) requested[#requested + 1] = kind end
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "sync", "missing kind -> sync")
  t.eq(requested[1], "devbind", "the missing kind was requested")
  runtime.cfgCache.devbind = { body = {}, status = "ok" }
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "ok")
  runtime.cfgCache.devbind = { body = nil, status = "fail" }
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "fail")
  t.eq(M.cfgMenuStatus(runtime, "emc", requestFn), "ok", "a non-config screen is always ok")
end)

t.test("cfgMenuStatus dtc is ok even when FCS cache is empty or failed", function()
  local runtime = { cfgCache = {} }
  local requested = {}
  t.eq(M.cfgMenuStatus(runtime, "dtc", function(kind) requested[#requested + 1] = kind end), "ok")
  t.eq(#requested, 0, "DTC must not prefetch FCS kinds or block the page")
  runtime.cfgCache.tuning = { body = nil, status = "fail" }
  t.eq(M.cfgMenuStatus(runtime, "dtc", function() end), "ok", "FCS silent must not gate DTC")
end)

t.test("buildState assembles the flat cadence keys from telemetry + engine + fuel + uiRev", function()
  local runtime = newRuntime()
  local tx = telemetry.Tx.new()
  local frame = tx:frame({
    engaged = true, gndSafety = false, positionHold = false, mode = "HOVER",
    altitude = 12.3, vSpeed = 0.5, heading = 90, compassHeading = 271, loopHz = 20,
  })
  M.routeModem(runtime, CH.telemetry, protocol.encode(frame))
  runtime.state.pumpFrac = 0.5
  runtime.state.tankFrac = 0.75
  runtime.uiRev = 3

  local state = M.buildState(runtime, os.epoch("utc"))
  t.eq(state.engaged, true)
  t.eq(state.gndSafety, false)
  t.eq(state.mode, "HOVER")
  t.eq(state.altitude, 12.3)
  t.eq(state.vSpeed, 0.5)
  t.eq(state.heading, nil, "no heartbeat received -> heading blanks too (spec decision #2), even though compassHeading is present")
  t.eq(state.loopHz, 20)
  t.eq(state.linkUp, false, "no heartbeat received -> linkUp false")
  t.eq(state.engineMaster, false, "masterDefault is false")
  t.eq(state.feeding, false)
  t.eq(state.pumpFrac, 0.5)
  t.eq(state.tankFrac, 0.75)
  t.eq(state.uiRev, 3)
end)

t.test("buildState sources pitch/roll/sas from the FCS snapshot (rx), not a local poll", function()
  local runtime = {
    rx = { latest = function() return { pitch = 0.1, roll = -0.2, surgeVel = 5 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pitch = 99, roll = 99, sas = 99, pumpFrac = 0, tankFrac = 0 },  -- must be IGNORED now
    nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, 1000)
  t.eq(s.pitch, 0.1); t.eq(s.roll, -0.2); t.eq(s.sas, 5)
end)

t.test("buildState threads fuel/fuelPct/badFuel from the FCS snapshot (rx) into the flat state", function()
  local runtime = {
    rx = { latest = function() return { fuel = "Ethanol", fuelPct = 200, badFuel = false } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 },
    nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, 1000)
  t.eq(s.fuel, "Ethanol")
  t.eq(s.fuelPct, 200)
  t.eq(s.badFuel, false)
end)

t.test("buildState threads badFuel=true from the FCS snapshot (rx) into the flat state", function()
  local runtime = {
    rx = { latest = function() return { fuel = "Kerosene", fuelPct = 40, badFuel = true } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 },
    nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, 1000)
  t.eq(s.fuel, "Kerosene")
  t.eq(s.fuelPct, 40)
  t.eq(s.badFuel, true)
end)

t.test("buildState: masterMode passes through from telemetry", function()
  local runtime = {
    rx = { latest = function() return { flightMode = "MAN", masterMode = "DCPL" } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 },
    nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, 1000)
  t.eq(s.masterMode, "DCPL", "masterMode carried to cadence state")
end)

t.test("buildState threads fuelEst from runtime.state", function()
  local est = { state = "drain", mbPerMin = 450, secondsLeft = 1080 }
  local runtime = {
    rx = { latest = function() return {} end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0, fuelEst = est },
    nav = {}, uiRev = 1,
  }
  local s = M.buildState(runtime, 1000)
  t.eq(s.fuelEst, est, "fuelEst propagated into state")
end)

t.test("routeModem stores a navfix relay (fix present) into runtime.nav", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = { x = 10, y = 82, z = -20, age = 0, source = "gps", nBeacons = 4, quality = 1.0 },
    gs = 12.5, at = 1000 }
  local reply = M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(reply, nil, "navfix is a fire-and-forget relay, no reply frame")
  t.eq(runtime.nav.gpsAlt, 82)
  t.eq(runtime.nav.tas, 12.5)
  t.eq(runtime.nav.fixOk, true)
  t.eq(runtime.nav.at, nil, "navfix does NOT touch the heading-freshness clock (that's navhdg's job)")
end)

t.test("routeModem stores a navfix relay (no fix) into runtime.nav", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = nil, heading = nil, compass = nil, gs = nil, at = 1000 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.gpsAlt, nil)
  t.eq(runtime.nav.tas, nil)
  t.eq(runtime.nav.fixOk, false)
end)

t.test("routeModem no longer has a navhdg branch -- NAV stopped relaying it (Task 6)", function()
  local runtime = newRuntime()
  local frame = { k = "navhdg", heading = 123, compass = "SE", at = 1000 }
  local reply = M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(reply, nil, "an unrecognised relay frame is silently ignored, not an error")
  t.eq(runtime.nav.heading, nil, "no navhdg handling left -- nothing stores it")
  t.eq(runtime.nav.at, nil)
end)

t.test("routeModem stores craft x/z from a navfix relay (for waypoint targeting)", function()
  local runtime = newRuntime()
  local frame = { k = "navfix", fix = { x = 100, y = 64, z = -200 }, gs = 5, at = 1 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.fixX, 100); t.eq(runtime.nav.fixZ, -200); t.eq(runtime.nav.gpsAlt, 64)
end)

t.test("buildState solves the PFD target cue from a selected waypoint + fresh fix", function()
  local runtime = newRuntime()
  local now = os.epoch("utc")
  runtime.nav.fixX = 0; runtime.nav.fixZ = 0
  runtime.nav.target = { name = "E", x = 10, y = 5, z = 0, color = "green" }
  -- Craft heading for the bearing math now comes from the FCS snapshot (compassHeading), gated on
  -- linkUp -- NOT a nav-relay freshness clock (navhdg is gone).
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ altitude = 0, compassHeading = 0 })))
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = now / 1000 }))  -- linkUp -> true
  local s = M.buildState(runtime, now)
  t.truthy(s.target ~= nil, "a target cue is produced")
  t.truthy(math.abs(s.target.bearing - 90) < 1e-6, "east target -> bearing 90")
  t.eq(s.target.name, "E"); t.eq(s.target.color, "green")
  t.truthy(math.abs(s.target.relBearing - 90) < 1e-6, "steer +90 (right) facing north")
end)

t.test("buildState target cue's relBearing survives NAV dropping navhdg -- sourced from the FCS snapshot", function()
  local runtime = newRuntime()
  local now = os.epoch("utc")
  runtime.nav.fixX = 0; runtime.nav.fixZ = 0
  runtime.nav.target = { name = "E", x = 10, y = 5, z = 0, color = "green" }
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ altitude = 0, compassHeading = 0 })))
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = now / 1000 }))  -- linkUp -> true
  local upState = M.buildState(runtime, now)
  t.truthy(upState.target ~= nil, "a target cue is produced")
  t.truthy(upState.target.relBearing ~= nil, "relBearing populated when the telemetry link is up")
  t.truthy(math.abs(upState.target.relBearing - 90) < 1e-6, "east target, facing north -> steer +90")

  -- A dead/stale telemetry heartbeat blanks the steering-cue heading too (not just the PFD tape) --
  -- this is the regression a deleted navhdg relay must not silently reintroduce.
  local downRuntime = newRuntime()
  downRuntime.nav.fixX = 0; downRuntime.nav.fixZ = 0
  downRuntime.nav.target = { name = "E", x = 10, y = 5, z = 0, color = "green" }
  M.routeModem(downRuntime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ altitude = 0, compassHeading = 0 })))
  -- no heartbeat routed -> linkUp stays false
  local downState = M.buildState(downRuntime, now)
  t.truthy(downState.target ~= nil, "bearing/distance still solve without a heading")
  t.eq(downState.target.relBearing, nil, "linkUp false -> craft.heading nil -> relBearing blanks")
end)

t.test("buildState target is nil with no selection", function()
  local runtime = newRuntime()
  runtime.nav.fixX = 0; runtime.nav.fixZ = 0
  t.eq(M.buildState(runtime, os.epoch("utc")).target, nil)
end)

t.test("buildState follows an active route: BLUE current-leg cue, auto-advances on arrival", function()
  local runtime = newRuntime()
  local W = require("nav.waypoints")
  local store = W.defaults()
  W.addWpt(store, { name = "A", x = 0,   y = 64, z = 0, type = "base" })
  W.addWpt(store, { name = "B", x = 100, y = 70, z = 0, type = "poi" })
  W.addRoute(store, "R"); W.addLeg(store, "R", "A"); W.addLeg(store, "R", "B")
  runtime.wptClient.store = store
  local now = os.epoch("utc")
  runtime.nav.fixX = 10; runtime.nav.fixZ = 0
  runtime.nav.routeActive = { name = "R", i = 1 }
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ altitude = 64, compassHeading = 90 })))
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = now / 1000 }))  -- linkUp -> true
  local s = M.buildState(runtime, now)
  t.eq(runtime.nav.routeActive.i, 2, "craft within 50 of leg A -> advanced to leg B")
  t.truthy(s.target ~= nil); t.eq(s.target.name, "B"); t.eq(s.target.color, "blue")
end)

t.test("routeModem feeds a wpt_store reply (ch 109) into the wptClient cache", function()
  local runtime = newRuntime()
  t.truthy(runtime.wptClient ~= nil, "buildRuntime wired the NAV store sync client")
  local frame = { k = "wpt_store",
    store = { waypoints = { { name = "Home", x = 1, y = 2, z = 3, type = "base" } }, routes = {} }, rev = 5 }
  M.routeModem(runtime, 109, protocol.encode(frame))
  t.eq(runtime.wptClient.online, true)
  t.eq(runtime.wptClient.rev, 5)
  t.eq(#runtime.wptClient.store.waypoints, 1)
end)

t.test("routeModem invokes onWptReply so event-mode NAV can apply the new store", function()
  -- After render-policy, NAV is event-mode: a uiRev bump does not paint it. The async store
  -- reply must fire a dedicated hook so the visible nav page can apply().
  local runtime = newRuntime()
  local n = 0
  runtime.onWptReply = function() n = n + 1 end
  M.routeModem(runtime, 109, protocol.encode({ k = "wpt_store", rev = 3,
    store = { waypoints = { { name = "Home", x = 1, y = 2, z = 3 } }, routes = {} } }))
  t.eq(n, 1, "store reply notified")
  M.routeModem(runtime, 109, protocol.encode({ k = "wpt_err", err = "nope" }))
  t.eq(n, 2, "error replies notify too")
end)

t.test("applyEventTop calls apply on every built nav page, even if it is not the current top", function()
  local runtime = newRuntime()
  local applied = 0
  local recs = {
    hiddenNav = { nav = { top = function() return "pfd" end },
      built = { nav = { handle = { apply = function() applied = applied + 1 end } },
                pfd = { handle = { apply = function() applied = applied + 10 end } } } },
    noNav = { nav = { top = function() return "pfd" end },
      built = { pfd = { handle = { apply = function() applied = applied + 10 end } } } },
  }
  local n = M.applyEventTop(runtime, recs, "nav")
  t.eq(n, 1, "one built nav handle")
  t.eq(applied, 1, "only the NAV handle applied (not PFD)")
end)

t.test("tickWptFreshness applies nav only on a true-to-false drop", function()
  local runtime = newRuntime()
  runtime.wptClient.lastReplyAt = 0
  runtime.wptClient.online = true
  local applied = 0
  local recs = { a = { built = { nav = { handle = { apply = function() applied = applied + 1 end } } } } }
  local n = M.tickWptFreshness(runtime, recs, 10000)
  t.eq(runtime.wptClient.online, false)
  t.eq(n, 1)
  t.eq(applied, 1)
  t.eq(M.tickWptFreshness(runtime, recs, 11000), 0, "already false: no second apply")
end)

t.test("buildState clears a stale routeActive when its route was deleted on the NAV PC", function()
  local runtime = newRuntime()
  local now = os.epoch("utc")
  runtime.nav.fixX = 0; runtime.nav.fixZ = 0; runtime.nav.heading = 0; runtime.nav.at = now
  runtime.nav.routeActive = { name = "GONE", i = 1 }   -- no such route in the (empty) store
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ altitude = 64 })))
  local s = M.buildState(runtime, now)
  t.eq(s.target, nil, "no steering cue from a missing route")
  t.eq(runtime.nav.routeActive, nil, "stale activation cleared instead of lingering")
end)

t.test("buildState heading comes from the FCS snapshot compassHeading", function()
  local runtime = {
    rx = { latest = function() return { compassHeading = 128 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0 }, nav = { heading = 999 },  -- nav.heading must be IGNORED
    uiRev = 1,
  }
  t.eq(M.buildState(runtime, 1000).heading, 128)
end)

t.test("buildState heading comes from a FRESH telemetry relay, ignoring the nav magnet-table bearing", function()
  local runtime = newRuntime()
  M.routeModem(runtime, CH.telemetry, protocol.encode(telemetry.Tx.new():frame({ compassHeading = 90 })))
  local now = os.epoch("utc")
  M.routeModem(runtime, CH.health, protocol.encode({ k = "hb", t = now / 1000 }))  -- linkUp -> true
  runtime.nav.heading = 123
  runtime.nav.at = now
  local state = M.buildState(runtime, now)
  t.eq(state.heading, 90, "display heading is the FCS snapshot's compassHeading")
end)

t.test("buildState heading is nil when the telemetry heartbeat is down, even with a fresh compassHeading snapshot (spec decision #2)", function()
  local runtime = {
    rx = { latest = function() return { compassHeading = 128 } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return false end },
    state = { pumpFrac = 0, tankFrac = 0 }, nav = {}, uiRev = 1,
  }
  t.eq(M.buildState(runtime, 1000).heading, nil, "hbRx down -> heading blanks (---) instead of freezing at the last bearing")
end)

t.test("buildState heading ignores nav.heading even when the nav relay is fresh (no telemetry compassHeading yet)", function()
  local runtime = newRuntime()
  runtime.nav.heading = 123
  runtime.nav.at = os.epoch("utc")   -- a FRESH nav relay must not be used as a heading fallback
  local state = M.buildState(runtime, os.epoch("utc"))
  t.eq(state.heading, nil, "no telemetry snapshot yet -> no heading (tape shows ---)")
end)

t.test("buildState heading is nil when no telemetry snapshot has ever arrived", function()
  local runtime = newRuntime()
  local state = M.buildState(runtime, os.epoch("utc"))
  t.eq(state.heading, nil)
end)

t.test("app loads + startScheduled registers scheduled work + one render pass, no error, no basalt.run()", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor() }
  local wrap = function(name) return mocks[name] end
  local built = M.buildFrames(basalt, { mA = "fcs" }, { "mA" }, wrap)
  local frameRecs = {
    terminal = M.newFrameRec(built.terminal, "config"),
    mA = M.newFrameRec(built.monitors.mA.frame, "fcs"),
  }

  local runtime = newRuntime()

  local ok, err = pcall(function()
    M.startScheduled(basalt, runtime, frameRecs)
    basalt.update("timer", -1)
  end)
  t.truthy(ok, "startScheduled + one render pass should not error: " .. tostring(err))
  t.truthy(frameRecs.mA.lastApplyAt ~= nil,
    "the fcs (rate) frame's per-panel gate actually ran and stamped its OWN lastApplyAt")
end)

t.test("logging-armed: status overlay (z=1000) + input logger run clean and record events (real basalt)", function()
  local basalt = M.ensureBasalt()
  local mocks = { mA = newMockMonitor() }
  local built = M.buildFrames(basalt, { mA = "fcs" }, { "mA" }, function(name) return mocks[name] end)
  local frameRecs = {
    terminal = M.newFrameRec(built.terminal, "config"),
    mA = M.newFrameRec(built.monitors.mA.frame, "fcs"),
  }
  local runtime = M.buildRuntime({ modem = newMockModem(), wrap = function() return {} end,
    read = function() return nil end, uilog = true })

  local ok, err = pcall(function()
    -- Mirror M.run's overlay wiring: a high-z status label on the terminal frame + the setter.
    local tw, th = built.terminal:getSize()
    local statusLabel = built.terminal:addLabel({ x = 1, y = th, width = tw, height = 1, autoSize = false,
      z = 1000, background = colors.black, foreground = colors.lime, text = "LOG on  P:upload" })
    runtime.setLogStatus = function(s) statusLabel:setText(tostring(s)) end
    runtime.setLogStatus("LOG .. uploading")               -- exercise the setter path

    M.startScheduled(basalt, runtime, frameRecs)
    basalt.update("timer", -1)                             -- render + resume the sleep loops once
    basalt.update("mouse_click", 1, 2, 3)                  -- raw-input logger should record this
  end)
  t.truthy(ok, "logging-armed startScheduled + z-overlay must not error: " .. tostring(err))

  local joined = table.concat(runtime.uilog:rows(), "\n")
  t.truthy(joined:find("INPUT", 1, true), "raw input was logged while armed:\n" .. joined)
  t.truthy(joined:find("RENDER", 1, true), "a rate panel's apply was timing-probe logged while armed:\n" .. joined)
end)

-- ===== Task 4: M.makeEngineWriter -- select engine relay writer by mode =====

local function mockRelay()
  local calls = {}
  return { calls = calls, setOutput = function(s, v) calls[#calls+1] = { side = s, val = v } end }
end

t.test("makeEngineWriter: basic mode drives config.relay.side with a 1-arg writer", function()
  local relay = mockRelay()
  local cfg = { engine = { mode = "basic" }, relay = { side = "back" } }
  local w = M.makeEngineWriter(RelayWriter, function() return relay end, cfg)
  w(true)
  t.eq(relay.calls[1].side, "back"); t.eq(relay.calls[1].val, true)
end)

t.test("makeEngineWriter: latch mode drives block/feed sides with a 2-arg writer", function()
  local relay = mockRelay()
  local cfg = { engine = { mode = "latch" }, relay = { blockSide = "back", feedSide = "left" } }
  local w = M.makeEngineWriter(RelayWriter, function() return relay end, cfg)
  w("block", true); w("feed", true)
  t.eq(relay.calls[1].side, "back"); t.eq(relay.calls[1].val, true)
  t.eq(relay.calls[2].side, "left"); t.eq(relay.calls[2].val, true)
end)

-- ===== M.reconcileMonitors: live monitor re-resolve (CONFIG REFRESH, no PC reboot) =====
-- Reconciles the live per-monitor frames/frameRecs to the CURRENT config.assign + present set,
-- so an operator can plug in / reassign / forget a monitor at the CONFIG page and press REFRESH
-- to see it take effect without rebooting the PC. REAL basalt + mock monitors, one render pass,
-- NEVER basalt.run().

local function setupReconcile(assign, present)
  local basalt = M.ensureBasalt()
  local mocks = {}
  for _, n in ipairs(present) do mocks[n] = newMockMonitor() end
  local wrap = function(name) return mocks[name] end
  local built = M.buildFrames(basalt, assign, present, wrap)
  local frameRecs = { terminal = M.newFrameRec(built.terminal, "config") }
  for name in pairs(built.monitors) do
    frameRecs[name] = M.newFrameRec(built.monitors[name].frame, M.rootForMonitor(assign, name))
  end
  local runtime = { config = { assign = assign } }
  return basalt, runtime, built, frameRecs, mocks
end

t.test("reconcileMonitors adds a frame + frameRec for a newly-present assigned monitor", function()
  local basalt, runtime, built, frameRecs, mocks = setupReconcile({ mA = "fcs" }, { "mA" })
  runtime.config.assign.mB = "nav"                       -- operator plugged in mB and assigned it
  mocks.mB = newMockMonitor()
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA", "mB" }, function(n) return mocks[n] end)
  t.truthy(built.monitors.mB ~= nil, "mB frame entry created")
  t.truthy(frameRecs.mB ~= nil, "mB frameRec created")
  t.eq(frameRecs.mB.nav:top(), "nav", "mB frameRec rooted at its assigned page")
end)

t.test("reconcileMonitors re-roots an existing monitor when its assignment changes (frame reused)", function()
  local basalt, runtime, built, frameRecs = setupReconcile({ mA = "fcs" }, { "mA" })
  local frameBefore = built.monitors.mA.frame
  t.eq(frameRecs.mA.nav:top(), "fcs")
  runtime.config.assign.mA = "nav"                       -- SET UI changed it
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA" })
  t.eq(frameRecs.mA.nav:top(), "nav", "mA re-rooted to the new page")
  t.eq(built.monitors.mA.frame, frameBefore, "physical frame REUSED, not rebuilt")
  t.eq(built.monitors.mA.panelId, "nav", "panelId updated")
end)

t.test("reconcileMonitors re-root REBASELINES the reused frame's gate window (lastSig/lastApplyAt cleared)", function()
  -- The reused frameRec still carries the OLD page's gate baseline. Without clearing it, re-rooting
  -- onto a same-sig-group rate page would leave the stale page showing until the next sig change.
  local basalt, runtime, built, frameRecs = setupReconcile({ mA = "fcs" }, { "mA" })
  frameRecs.mA.lastSig = "STALE-SIG"           -- pretend the old page had been applied
  frameRecs.mA.lastApplyAt = 12345
  runtime.config.assign.mA = "flight"           -- re-root to a SAME-sig-group page (fcs -> flight)
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA" })
  t.eq(frameRecs.mA.lastSig, nil, "lastSig cleared so the gate re-applies the re-rooted top next tick")
  t.eq(frameRecs.mA.lastApplyAt, nil, "lastApplyAt cleared so the panel's poll window restarts")
end)

t.test("reconcileMonitors ignores present-but-unassigned monitors", function()
  local basalt, runtime, built, frameRecs, mocks = setupReconcile({ mA = "fcs" }, { "mA" })
  mocks.mC = newMockMonitor()
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA", "mC" }, function(n) return mocks[n] end)
  t.truthy(built.monitors.mC == nil, "unassigned present monitor gets no frame")
  t.truthy(frameRecs.mC == nil, "unassigned present monitor gets no frameRec")
end)

t.test("reconcileMonitors drops a monitor gone from present+assign", function()
  local basalt, runtime, built, frameRecs = setupReconcile({ mA = "fcs", mB = "nav" }, { "mA", "mB" })
  t.truthy(built.monitors.mB ~= nil)
  runtime.config.assign.mB = nil                         -- DEL forgot it
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA" })
  t.truthy(built.monitors.mB == nil, "dropped from built.monitors")
  t.truthy(frameRecs.mB == nil, "dropped from frameRecs")
  t.truthy(frameRecs.terminal ~= nil, "terminal frameRec untouched")
end)

t.test("a render pass after reconcileMonitors does not error", function()
  local basalt, runtime, built, frameRecs, mocks = setupReconcile({ mA = "fcs" }, { "mA" })
  runtime.config.assign.mB = "nav"; mocks.mB = newMockMonitor()
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA", "mB" }, function(n) return mocks[n] end)
  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "render pass clean: " .. tostring(err))
end)

-- ===== reconcileMonitors wires nav.onChange (Task 3 fix-round-1: prior review found this branch
-- unguarded by any test -- a future refactor could silently drop either wiring line and the full
-- suite would stay green, reintroducing the boot/nav visibility gap for a monitor REFRESH/SET UI
-- rebuilds or re-roots). Covers BOTH branches: a newly-added monitor (M.newFrameRec branch) and an
-- existing monitor whose assignment changed (re-root branch). Spies on M.applyNow itself (rather
-- than needing a full M.buildState-capable runtime) by temporarily swapping the module-level
-- function -- the wired closure looks up `M.applyNow` dynamically on every call, so the swap is
-- visible to it without touching frameRec/nav/basalt at all.

t.test("reconcileMonitors wires nav.onChange for a NEWLY-ADDED monitor, calling M.applyNow(basalt, runtime, thatFrameRec)", function()
  local basalt, runtime, built, frameRecs, mocks = setupReconcile({ mA = "fcs" }, { "mA" })
  runtime.config.assign.mB = "nav"
  mocks.mB = newMockMonitor()
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA", "mB" }, function(n) return mocks[n] end)

  t.truthy(frameRecs.mB.nav.onChange ~= nil, "mB's nav.onChange must be wired (not left nil)")

  local calls = {}
  local origApplyNow = M.applyNow
  M.applyNow = function(b, r, fr) calls[#calls + 1] = { basalt = b, runtime = r, frameRec = fr } end
  local ok = pcall(function() frameRecs.mB.nav.onChange() end)
  M.applyNow = origApplyNow

  t.truthy(ok, "invoking the wired onChange must not error")
  t.eq(#calls, 1, "invoking mB's onChange must call M.applyNow exactly once")
  t.eq(calls[1].basalt, basalt, "wired with the SAME basalt instance reconcileMonitors was given")
  t.eq(calls[1].runtime, runtime, "wired with the SAME runtime reconcileMonitors was given")
  t.eq(calls[1].frameRec, frameRecs.mB, "wired to render mB's OWN frameRec, not some other frame")
end)

t.test("reconcileMonitors RE-WIRES nav.onChange for a RE-ROOTED monitor (assignment changed, frame reused)", function()
  local basalt, runtime, built, frameRecs = setupReconcile({ mA = "fcs" }, { "mA" })
  runtime.config.assign.mA = "nav"   -- SET UI changed it
  M.reconcileMonitors(basalt, runtime, built, frameRecs, { "mA" })

  t.truthy(frameRecs.mA.nav.onChange ~= nil, "mA's re-rooted nav.onChange must be wired (not left nil)")

  local calls = {}
  local origApplyNow = M.applyNow
  M.applyNow = function(b, r, fr) calls[#calls + 1] = { basalt = b, runtime = r, frameRec = fr } end
  local ok = pcall(function() frameRecs.mA.nav.onChange() end)
  M.applyNow = origApplyNow

  t.truthy(ok, "invoking the re-wired onChange must not error")
  t.eq(#calls, 1, "invoking mA's re-rooted onChange must call M.applyNow exactly once")
  t.eq(calls[1].basalt, basalt)
  t.eq(calls[1].runtime, runtime)
  t.eq(calls[1].frameRec, frameRecs.mA, "wired to render mA's OWN (reused) frameRec")
end)

-- ===== M.gateFrame: per-panel render-gate decision (Task 2, render-policy) =====
-- PURE decision logic extracted from the scheduled render-gate task (e) -- see M.gateFrame's
-- header comment in ui/basalt/app.lua. Tested directly against a bare `{}` frameRec, no Basalt/
-- showScreen/apply involved at all.

local function freshRec() return {} end

t.test("gateFrame: flight-rooted frame applies only after FLIGHT_MS elapsed AND its sig changed", function()
  local rec = freshRec()
  local pol = renderpolicy.policyFor("flight", 100)
  local state1 = { pumpAmount = 10 }
  t.eq(M.gateFrame(rec, pol, state1, 0), true, "first-ever tick applies (no prior sig)")
  t.eq(M.gateFrame(rec, pol, state1, 50), false, "50ms < FLIGHT_MS=250 -- gate holds, no re-apply")
  t.eq(M.gateFrame(rec, pol, state1, 260), false, "elapsed (260ms since last stamp) but sig UNCHANGED -- no re-apply")
  local state2 = { pumpAmount = 20 }
  t.eq(M.gateFrame(rec, pol, state2, 520), true, "elapsed (260ms since last stamp) AND sig changed -- applies")
end)

t.test("gateFrame: pfd-rooted frame applies at its OWN caller-supplied pfdMs cadence (200ms)", function()
  local rec = freshRec()
  local pol = renderpolicy.policyFor("pfd", 200)
  local state1 = { pitch = 1 }
  t.eq(M.gateFrame(rec, pol, state1, 0), true, "first tick applies")
  t.eq(M.gateFrame(rec, pol, state1, 150), false, "150ms < pfdMs=200 -- holds")
  local state2 = { pitch = 2 }
  t.eq(M.gateFrame(rec, pol, state2, 210), true, "210ms >= pfdMs=200 AND sig changed -- applies")
end)

t.test("gateFrame: tuning-rooted frame applies at PARAMS_MS (1000ms)", function()
  local rec = freshRec()
  local pol = renderpolicy.policyFor("tuning", 100)
  local state1 = { tankFrac = 0.1 }
  t.eq(M.gateFrame(rec, pol, state1, 0), true, "first tick applies")
  local state2 = { tankFrac = 0.9 }
  t.eq(M.gateFrame(rec, pol, state2, 900), false, "900ms < PARAMS_MS=1000 -- holds even though sig changed")
  t.eq(M.gateFrame(rec, pol, state2, 1000), true, "1000ms >= PARAMS_MS AND sig changed -- applies")
end)

t.test("gateFrame: event-mode screens (e.g. config) are NEVER gate-applied, ever, no rec mutation", function()
  local rec = freshRec()
  local pol = renderpolicy.policyFor("config", 100)
  t.eq(pol.mode, "event")
  t.eq(M.gateFrame(rec, pol, { anything = 1 }, 0), false, "event mode -- gate never applies")
  t.eq(M.gateFrame(rec, pol, { anything = 2 }, 999999), false, "still never applies, no matter how much time passes")
  t.eq(rec.lastApplyAt, nil, "event mode never touches rec.lastApplyAt")
  t.eq(rec.lastSig, nil, "event mode never touches rec.lastSig")
end)

t.test("gateFrame: per-panel isolation -- a PFD-only sig change applies the pfd frame but NOT a flight frame", function()
  local pfdRec, flightRec = freshRec(), freshRec()
  local pfdPol = renderpolicy.policyFor("pfd", 100)
  local flightPol = renderpolicy.policyFor("flight", 100)
  local state1 = { pitch = 1, pumpAmount = 5 }
  t.truthy(M.gateFrame(pfdRec, pfdPol, state1, 0), "pfd first tick applies")
  t.truthy(M.gateFrame(flightRec, flightPol, state1, 0), "flight first tick applies")

  -- Next window: only pitch (a PFD-only field) changes; pumpAmount (a flight-only field) holds.
  local state2 = { pitch = 2, pumpAmount = 5 }
  t.eq(M.gateFrame(pfdRec, pfdPol, state2, 300), true, "pfd sig changed (pitch) -- applies")
  t.eq(M.gateFrame(flightRec, flightPol, state2, 300), false,
    "flight sig UNCHANGED (pumpAmount held) -- must NOT apply just because the pfd frame did")
end)

-- ===== FCS-missing blink cue: buildState surfaces fcsStale + blinkPhase (ui/basalt/fcslink) =====

t.test("buildState flags fcsStale when the FCS has never signalled since boot (past boot grace)", function()
  local runtime = {
    rx = { latest = function() return {} end }, engine = { status = function() return {} end },
    hbRx = { up = function() return false end, lastSeen = nil },   -- no heartbeat ever
    state = { pumpFrac = 0, tankFrac = 0 }, nav = {}, uiRev = 1, bootAt = 0,
  }
  local s = M.buildState(runtime, 5000)   -- 5000ms since boot > 1500 boot grace
  t.eq(s.fcsStale, true, "never-seen + past boot grace -> stale")
  t.eq(s.blinkPhase, math.floor(5000 / 500) % 2, "phase derived from now")
end)

t.test("buildState: NOT fcsStale while the heartbeat is fresh (lastSeen in seconds)", function()
  local runtime = {
    rx = { latest = function() return {} end }, engine = { status = function() return {} end },
    hbRx = { up = function() return true end, lastSeen = 9.8 },    -- last beat at 9800ms
    state = { pumpFrac = 0, tankFrac = 0 }, nav = {}, uiRev = 1, bootAt = 0,
  }
  t.eq(M.buildState(runtime, 10000).fcsStale, false, "200ms since last beat -> fresh")
end)

-- ===== Task 3: M.applyNow -- instant (non-gated) render on nav switch + boot =====
-- Closes the visibility gap Task 2 introduced: the periodic gate (M.gateFrame) now NEVER shows an
-- event-mode screen (config/nav/dtc/bitconfig/...), and Task 2 removed the old navChanged/
-- extraDirty trigger. M.applyNow is the instant-render path: ALWAYS M.showScreen's the frame's
-- current top (the visibility swap), and additionally FORCE-applies once (bypassing the sig
-- dirty-gate) when that top is a rate panel, re-baselining lastSig/lastApplyAt so the periodic
-- gate doesn't immediately re-fire redundantly on its next tick.

t.test("applyNow: EVENT top -- showScreen only, no rate re-baseline (config, the terminal root)", function()
  local basalt = M.ensureBasalt()
  local frameRec = M.newFrameRec(basalt.getMainFrame(), "config")
  local runtime = newRuntime()

  local pol = renderpolicy.policyFor("config", 100)
  t.eq(pol.mode, "event", "config is event-mode -- the periodic gate would never show it")

  local entry = M.applyNow(basalt, runtime, frameRec)
  t.truthy(entry ~= nil, "config screen got built via showScreen")
  t.eq(entry.childFrame:getVisible(), true, "config is visible immediately, no gate tick needed")
  t.eq(frameRec.lastApplyAt, nil, "event top: the gate's own cadence state is left untouched")
  t.eq(frameRec.lastSig, nil, "event top: no sig baseline either -- gate never looks at this frame")
end)

t.test("applyNow: RATE top -- showScreen AND forces an apply, rebaselining lastSig/lastApplyAt", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "fcs")
  local runtime = newRuntime()

  local entry = M.applyNow(basalt, runtime, frameRec)
  t.truthy(entry ~= nil and entry.handle ~= nil, "fcs screen built")
  t.eq(entry.childFrame:getVisible(), true, "fcs is visible immediately")
  t.truthy(frameRec.lastApplyAt ~= nil, "rate top: lastApplyAt rebaselined so the gate doesn't double-fire")
  t.truthy(frameRec.lastSig ~= nil, "rate top: lastSig rebaselined to the state just force-applied")

  -- Rebaselining actually WORKS: the periodic gate, checked immediately after with unchanged
  -- state, must not think there's still a pending apply.
  local pol = renderpolicy.policyFor("fcs", 100)
  local state = M.buildState(runtime, frameRec.lastApplyAt)
  t.eq(M.gateFrame(frameRec, pol, state, frameRec.lastApplyAt + 10), false,
    "gate holds right after a forced apply: window hasn't elapsed AND sig is already baselined")
end)

t.test("applyNow: pushing to an EVENT screen shows it immediately, but the periodic gate still never applies it", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "emc")
  local runtime = newRuntime()
  frameRec.nav.onChange = function() M.applyNow(basalt, runtime, frameRec) end
  M.applyNow(basalt, runtime, frameRec)   -- boot pass, mirrors M.run's initial applyNow loop

  frameRec.nav:push("nav")   -- "nav" page id is event-mode (not in renderpolicy's RATE_SCREENS)
  local navEntry = frameRec.built.nav
  t.truthy(navEntry ~= nil, "nav screen got built via showScreen on push, no gate tick needed")
  t.eq(navEntry.childFrame:getVisible(), true, "nav is visible immediately")

  local pol = renderpolicy.policyFor(frameRec.nav:top(), 100)
  t.eq(pol.mode, "event")
  local now = os.epoch("utc")
  t.eq(M.gateFrame(frameRec, pol, M.buildState(runtime, now), now + 999999), false,
    "event top: the periodic gate never applies it, no matter how much time passes")
end)

t.test("applyNow: nav onChange forces a repaint on a same-policy-group switch (flight<->emc<->fcs) even with UNCHANGED telemetry", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "emc")
  local runtime = newRuntime()
  frameRec.nav.onChange = function() M.applyNow(basalt, runtime, frameRec) end
  M.applyNow(basalt, runtime, frameRec)   -- boot pass: emc built + force-applied once

  -- Spy on emc's apply AFTER the boot pass so the spy only counts calls from here on.
  local emcEntry = frameRec.built.emc
  local emcCalls = 0
  local origEmcApply = emcEntry.handle.apply
  emcEntry.handle.apply = function(...) emcCalls = emcCalls + 1; return origEmcApply(...) end

  frameRec.nav:push("fcs")   -- a DIFFERENT screen in the SAME renderpolicy group (sigFlight/FLIGHT_MS)
  local fcsEntry = frameRec.built.fcs
  t.eq(fcsEntry.childFrame:getVisible(), true, "fcs now visible")
  t.eq(emcEntry.childFrame:getVisible(), false, "emc hidden")

  frameRec.nav:pop()   -- back to emc; telemetry has NOT changed the whole time (same runtime/state)
  t.eq(emcEntry.childFrame:getVisible(), true, "emc visible again")
  t.eq(emcCalls, 1,
    "switching back to emc forced exactly one apply call -- a plain sig-gated re-check would have " ..
    "seen an unchanged sig and applied ZERO times, since telemetry never changed")
end)

t.test("buildState: a live link that drops is NOT stale until past the drop grace", function()
  local runtime = {
    rx = { latest = function() return {} end }, engine = { status = function() return {} end },
    hbRx = { up = function() return false end, lastSeen = 10.0 },  -- last beat at 10000ms
    state = { pumpFrac = 0, tankFrac = 0 }, nav = {}, uiRev = 1, bootAt = 0,
  }
  t.eq(M.buildState(runtime, 13000).fcsStale, false, "3000ms since last beat < 4000 drop grace")
  t.eq(M.buildState(runtime, 14500).fcsStale, true, "4500ms since last beat > 4000 drop grace")
end)

-- ===== Task 4: PARAMS watch edge + gated extras in buildState / routeModem =====

t.test("setParamsOpen is edge-only and sends paramsWatch on both FCS cmd and NAV link", function()
  local sent, navSent = {}, {}
  local runtime = {
    paramsOpen = false,
    sender = { send = function(_, cmd) return { k = "cmd", cmd = cmd } end },
    links = { tel = { send = function(_, f) sent[#sent+1] = f end } },
    wptClient = { link = { send = function(_, f) navSent[#navSent+1] = f end } },
    state = {},
  }
  M.setParamsOpen(runtime, true)
  t.eq(runtime.paramsOpen, true)
  t.eq(sent[1].cmd.k, "paramsWatch"); t.eq(sent[1].cmd.on, true)
  t.eq(navSent[1].k, "paramsWatch"); t.eq(navSent[1].on, true)
  M.setParamsOpen(runtime, true)
  t.eq(#sent, 1, "second open does not send")
  M.setParamsOpen(runtime, false)
  t.eq(sent[2].cmd.on, false)
  t.eq(navSent[2].on, false)
end)

t.test("setParamsOpen close nils leftover UI loop stamp so reopen is not the closed gap", function()
  local runtime = {
    paramsOpen = false,
    sender = { send = function(_, cmd) return { k = "cmd", cmd = cmd } end },
    links = { tel = { send = function() end } },
    state = { _uiLoopAt = 1000, uiLoopMs = 250 },
  }
  M.setParamsOpen(runtime, true)
  runtime.state._uiLoopAt = 1000
  M.setParamsOpen(runtime, false)
  t.eq(runtime.state._uiLoopAt, nil, "close must drop _uiLoopAt so the next open starts a 0ms first sample")
  t.eq(runtime.state.uiLoopMs, nil)
end)

t.test("buildState copies PARAMS extras only while paramsOpen", function()
  local runtime = {
    rx = { latest = function() return { devWarn = true, disk = true, loopHz = 10, flightMode = "LDG" } end },
    engine = { status = function() return {} end }, hbRx = { up = function() return true end },
    state = { pumpFrac = 0, tankFrac = 0, uiLoopMs = 12 },
    nav = { gpsQuality = 0.9, loopMs = 250, disk = true, tas = 8 },
    uiRev = 1, paramsOpen = false,
  }
  local closed = M.buildState(runtime, 1000)
  t.eq(closed.devWarn, nil); t.eq(closed.diskFcs, nil)
  t.eq(closed.uiLoopMs, nil); t.eq(closed.gpsQuality, nil)
  t.eq(closed.tas, 8, "tas is always-on navfix, still copied")
  runtime.paramsOpen = true
  local open = M.buildState(runtime, 1000)
  t.eq(open.devWarn, true); t.eq(open.diskFcs, true)
  t.eq(open.uiLoopMs, 12); t.eq(open.gpsQuality, 0.9)
  t.eq(open.navLoopMs, 250); t.eq(open.diskNav, true)
  t.eq(open.paramsOpen, true)
end)

t.test("routeModem copies gpsQuality/disk/loopMs from navfix only while paramsOpen", function()
  local runtime = newRuntime()
  runtime.paramsOpen = false
  local frame = { k = "navfix", fix = { x = 1, y = 2, z = 3, quality = 0.9 }, gs = 5, disk = true, at = 1000 }
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.tas, 5)
  t.eq(runtime.nav.gpsQuality, nil, "closed: do not copy quality")
  t.eq(runtime.nav.disk, nil)
  runtime.paramsOpen = true
  M.routeModem(runtime, 107, protocol.encode(frame))
  t.eq(runtime.nav.gpsQuality, 0.9)
  t.eq(runtime.nav.disk, true)
end)
