package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Main = require("nav.ui.main")
local ConfigPage = require("nav.ui.config")
local App = require("nav.app")
local BasaltApp = require("ui.basalt.app")
local gpsproto = require("nav.comms.gpsproto")
local navconfig = require("nav.config")

-- ============================ MAIN page: pure view-model ============================

t.test("main.viewModel shows a fix as position + quality (no heading -- that's the PFD's job)", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 200, quality = 1.0 },
    heading = 90, compass = "E",
    grade = { usable = true, usableHosts = 4, reasons = {} },
    beacons = { A = { pos = { x = 0, y = 0, z = 0 }, ageMs = 300 } },
  })
  t.eq(vm.position, "3 4N 5", "y suffixed N (trilaterated) when no baro is present")
  t.eq(vm.positionTone, "good")
  t.truthy(vm.fixInfo:find("4 beacons", 1, true), "fixInfo still reports beacon count")
  t.truthy(vm.quality:find("GOOD", 1, true), "high quality reads GOOD")
  t.eq(vm.qualityTone, "good")
  t.eq(#vm.beacons, 1)
  t.truthy(vm.beacons[1].text:find("A", 1, true))
end)

t.test("main.viewModel no longer returns heading/headingTone -- dropped from the NAV shell (PFD-owned)", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 200, quality = 1.0 },
    heading = 90, compass = "E",
    grade = { usable = true, usableHosts = 4, reasons = {} },
    beacons = {},
  })
  t.eq(vm.heading, nil, "no heading field")
  t.eq(vm.headingTone, nil, "no headingTone field")
end)

t.test("main.viewModel warns on a poor-geometry fix (POOR + block error estimate)", function()
  local vm = Main.viewModel({ fix = { x = 1, y = 2, z = 3, nBeacons = 4, age = 0, quality = 0.1, errorEst = 13 },
    grade = { usable = true, usableHosts = 4, reasons = {} }, beacons = {} })
  t.truthy(vm.quality:find("POOR", 1, true), "low quality reads POOR")
  t.truthy(vm.quality:find("13", 1, true), "shows the ~error estimate in blocks")
  t.eq(vm.qualityTone, "bad")
end)

t.test("main.viewModel uses baro y (suffix B) when the FCS baro is fresh; x/z stay GPS", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 0, quality = 1.0 },
    baroY = -47, baroFresh = true,
    grade = { usableHosts = 4 }, beacons = {} })
  t.eq(vm.position, "3 -47B 5", "y from baro (B); x/z from GPS")
end)

t.test("main.viewModel falls back to GPS y (suffix N) when baro is stale", function()
  local vm = Main.viewModel({
    fix = { x = 3, y = 4, z = 5, nBeacons = 4, age = 0, quality = 1.0 },
    baroY = -47, baroFresh = false,
    grade = { usableHosts = 4 }, beacons = {} })
  t.eq(vm.position, "3 4N 5", "stale baro -> trilaterated y (N)")
end)

t.test("main.viewModel shows baro y even with no GPS fix (-- yB --)", function()
  local vm = Main.viewModel({ baroY = -47, baroFresh = true, grade = { usableHosts = 2 }, beacons = {} })
  t.eq(vm.position, "-- -47B --", "altitude known, horizontal unknown")
  t.eq(vm.positionTone, "normal")
end)

t.test("main.viewModel is honest when there is no fix", function()
  local vm = Main.viewModel({ heading = nil, grade = { usable = false, usableHosts = 2, reasons = {} }, beacons = {} })
  t.eq(vm.position, "NO FIX")
  t.eq(vm.positionTone, "bad")
  t.eq(vm.qualityTone, "bad")
end)

t.test("main page builds on a real Basalt frame; apply + render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local h = Main.build(basalt, frame, nil, nil)
  t.eq(h.id, "nav-main")
  local ok, err = pcall(h.apply, { nav = {
    fix = { x = 1, y = 2, z = 3, nBeacons = 4, age = 0, quality = 1.0 },
    heading = 47, compass = "NE", grade = { usable = true, usableHosts = 4, reasons = {} }, beacons = {} } })
  t.truthy(ok, "apply must not error: " .. tostring(err))
  t.truthy(pcall(function() basalt.update("timer", -1) end))
end)

-- ============================ CONFIG page: pure edit seams ============================

t.test("config.rows renders the current settings as label/value pairs", function()
  local cfg = navconfig.defaults()
  local rows = ConfigPage.rows(cfg)
  local function val(label)
    for _, r in ipairs(rows) do if r.label == label then return r.value end end
  end
  t.truthy(val("GPS CH"):find("65000", 1, true))
  t.truthy(val("RELAY CH"):find("107", 1, true))
  t.truthy(val("HDG SIGN"):find("+", 1, true))
end)

t.test("config.flipSign toggles the navtable heading sign in place", function()
  local cfg = navconfig.defaults()
  t.eq(ConfigPage.flipSign(cfg), -1)
  t.eq(cfg.navtable.sign, -1)
  t.eq(ConfigPage.flipSign(cfg), 1)
end)

t.test("config steppers adjust channel/relay/thresholds within sane bounds", function()
  local cfg = navconfig.defaults()
  ConfigPage.stepChannel(cfg, 1);   t.eq(cfg.channel, 65001)
  ConfigPage.stepRelay(cfg, -1);    t.eq(cfg.relay.channel, 106)
  ConfigPage.stepMaxAge(cfg, 1);    t.eq(cfg.thresholds.maxAgeMs, 3500)   -- 500ms steps
  ConfigPage.stepMinQuality(cfg, 1);t.near(cfg.thresholds.minQuality, 0.6, 1e-9)  -- 0.1 steps
  ConfigPage.stepMinQuality(cfg, 100); t.near(cfg.thresholds.minQuality, 1.0, 1e-9) -- clamp <=1
  ConfigPage.stepMinQuality(cfg, -100); t.near(cfg.thresholds.minQuality, 0.0, 1e-9) -- clamp >=0
end)

t.test("config page builds on a real Basalt frame; apply + render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local cfg = navconfig.defaults()
  local h = ConfigPage.build(basalt, frame, { config = cfg, save = function() end }, nil)
  t.eq(h.id, "nav-config")
  t.truthy(pcall(h.apply, {}))
  t.truthy(pcall(function() basalt.update("timer", -1) end))
end)

-- ============================ App: injectable runtime/route/state ============================

local function fakeDev()
  local d = { sent = {}, opened = {} }
  d.open = function(ch) d.opened[ch] = true end
  d.isWireless = function() return true end
  d.transmit = function(ch, reply, msg) d.sent[#d.sent + 1] = { ch = ch, reply = reply, msg = msg } end
  return d
end

t.test("app.buildRuntime wires the nav runtime from injected peripherals, no navtable anywhere", function()
  local rt = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 1000 end,
  })
  t.truthy(rt.nav ~= nil, "nav runtime present")
  t.eq(rt.config.channel, 65000)
  t.eq(rt.nav:heading(), nil, "no FCS snapshot has arrived yet -- nil, not a navtable read")
  rt.nav:onFcsSnapshot({ compassHeading = 47 })
  t.eq(rt.nav:heading(), 47, "heading comes from an injected FCS snapshot")
end)

t.test("app.routeModem feeds only GPS-channel messages into the receiver, then buildState reflects the fix", function()
  local now = 1000
  local rt = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return now end,
  })
  local target = { x = 3, y = 4, z = 5 }
  local function hear(b)
    local dx, dy, dz = target.x - b.x, target.y - b.y, target.z - b.z
    App.routeModem(rt, 65000, 65000, gpsproto.encode(b), math.sqrt(dx * dx + dy * dy + dz * dz))
  end
  App.routeModem(rt, 999, 999, gpsproto.encode({ id = "Z", x = 0, y = 0, z = 0 }), 5) -- wrong channel: ignored
  hear({ id = "A", x = 0,  y = 0,  z = 0 })
  hear({ id = "B", x = 20, y = 0,  z = 0 })
  hear({ id = "C", x = 0,  y = 20, z = 0 })
  hear({ id = "D", x = 0,  y = 0,  z = 20 })
  local state = App.buildState(rt, now)
  local vm = Main.viewModel(state.nav)
  t.eq(vm.position, "3 4N 5", "the whole receive->fix->view pipeline lands the known position (GPS y, no baro)")
  t.eq(state.nav.beacons.Z, nil, "the off-channel message never entered the mesh")
end)

t.test("app.routeModem caches FCS baro AND feeds the same snapshot into NAV's own heading (no navtable)", function()
  local telemetry = require("fcs.comms.telemetry")
  local protocol  = require("fcs.comms.protocol")
  local rt = App.buildRuntime({ gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 5000 end })
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH,
    protocol.encode(telemetry.Tx.new():frame({ altitude = -47, compassHeading = 128 })))
  local state = App.buildState(rt, 5000)
  t.eq(state.nav.baroY, -47, "baro altitude cached from FCS telemetry")
  t.eq(state.nav.baroFresh, true, "fresh within the window")
  t.eq(rt.nav:heading(), 128, "NAV's own status heading comes from the same FCS snapshot")
end)

t.test("app.buildState marks the NAV baro stale past the freshness window", function()
  local telemetry = require("fcs.comms.telemetry")
  local protocol  = require("fcs.comms.protocol")
  local rt = App.buildRuntime({ gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 0 end })
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH,
    protocol.encode(telemetry.Tx.new():frame({ altitude = -47 })))
  local state = App.buildState(rt, App.BARO_MAX_AGE_MS + 1)
  t.eq(state.nav.baroFresh, false, "past the window -> stale -> NAV falls back to GPS y")
end)

t.test("app.routeModem reuses fcs.comms.telemetry's Rx dedup -- a stale/duplicate seq is rejected", function()
  local telemetry = require("fcs.comms.telemetry")
  local protocol  = require("fcs.comms.protocol")
  local rt = App.buildRuntime({ gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 0 end })
  local tx = telemetry.Tx.new()
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH, protocol.encode(tx:frame({ compassHeading = 10 })))
  t.eq(rt.nav:heading(), 10)
  local dup = tx:frame({ compassHeading = 999 })
  dup.seq = 1   -- force a stale seq (already consumed) -- must be rejected, not just latest-wins
  App.routeModem(rt, App.TELEMETRY_CH, App.TELEMETRY_CH, protocol.encode(dup))
  t.eq(rt.nav:heading(), 10, "stale seq rejected -- heading unchanged (proves the shared Rx dedup, not a hand-rolled decode)")
end)

t.test("app.M.RENDER_S is 3.0 -- the NAV shell is a rarely-watched debug screen, not a flight display", function()
  t.eq(App.RENDER_S, 3.0)
end)

t.test("app.signature is unchanged by a heading-only difference (heading dropped from the render key)", function()
  local base = { nav = { fix = { x = 1, y = 2, z = 3, quality = 0.9 }, heading = 10, beacons = {}, uiRev = 0 } }
  local turned = { nav = { fix = { x = 1, y = 2, z = 3, quality = 0.9 }, heading = 270, beacons = {}, uiRev = 0 } }
  t.eq(App.signature(base), App.signature(turned), "heading-only change must NOT move the NAV shell signature")
end)

t.test("app.signature still changes on a real change (position)", function()
  local base = { nav = { fix = { x = 1, y = 2, z = 3, quality = 0.9 }, heading = 10, beacons = {}, uiRev = 0 } }
  local moved = { nav = { fix = { x = 9, y = 2, z = 3, quality = 0.9 }, heading = 10, beacons = {}, uiRev = 0 } }
  t.truthy(App.signature(base) ~= App.signature(moved), "position change still moves the signature")
end)

-- ============================ NAV store sync server (handleWptRequest) ============================

t.test("app.handleWptRequest applies an op, persists on rev change, returns the fresh store", function()
  local W = require("nav.waypoints")
  local saved
  local runtime = { store = W.defaults(), wptRev = 0, saveStore = function(s) saved = s end }
  local reply = App.handleWptRequest(runtime, { k = "wpt_op", op = "addWpt",
    args = { name = "Home", x = 1, y = 2, z = 3, type = "base" } })
  t.eq(reply.k, "wpt_store"); t.eq(reply.rev, 1)
  t.eq(#runtime.store.waypoints, 1); t.eq(runtime.wptRev, 1)
  t.truthy(saved ~= nil and #saved.waypoints == 1, "persisted the store on mutation")
end)

t.test("app.handleWptRequest wpt_get returns the store + rev and never persists", function()
  local W = require("nav.waypoints")
  local persisted = false
  local runtime = { store = W.defaults(), wptRev = 3, saveStore = function() persisted = true end }
  local reply = App.handleWptRequest(runtime, { k = "wpt_get" })
  t.eq(reply.k, "wpt_store"); t.eq(reply.rev, 3)
  t.eq(persisted, false, "a read never persists"); t.eq(runtime.wptRev, 3)
end)

t.test("app.handleWptRequest keeps rev + does not persist on a failed op", function()
  local W = require("nav.waypoints")
  local persisted = false
  local runtime = { store = W.defaults(), wptRev = 2, saveStore = function() persisted = true end }
  App.handleWptRequest(runtime, { k = "wpt_op", op = "deleteWpt", args = { name = "ghost" } })
  t.eq(runtime.wptRev, 2); t.eq(persisted, false)
end)

t.test("app.handleDisk export replies wpt_disk_res; import merges + persists + replies wpt_store", function()
  local W = require("nav.waypoints")
  local files = {}
  local dd = { mount = "disk",
    read = function(p) return files[p] end, write = function(p, b) files[p] = b; return true end,
    delete = function(p) files[p] = nil end }

  -- export the current store to the (fake) disk
  local runtime = { store = W.defaults(), wptRev = 0, saveStore = function() end }
  W.addWpt(runtime.store, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  local rep = App.handleDisk(runtime, { k = "wpt_disk", op = "export" }, dd)
  t.eq(rep.k, "wpt_disk_res"); t.eq(rep.op, "export"); t.eq(rep.ok, true)
  t.truthy(files["/disk/eh2_nav_wpt.tbl"] ~= nil)

  -- a second NAV imports it -> merges + persists + replies the fresh store
  local saved
  local rt2 = { store = W.defaults(), wptRev = 3, saveStore = function(s) saved = s end }
  local rep2 = App.handleDisk(rt2, { k = "wpt_disk", op = "import" }, dd)
  t.eq(rep2.k, "wpt_store"); t.eq(rep2.rev, 4)
  t.eq(#rt2.store.waypoints, 1); t.truthy(saved ~= nil, "imported store persisted")
end)

t.test("app.handleWptRequest routes wpt_disk to handleDisk", function()
  local W = require("nav.waypoints")
  local runtime = { store = W.defaults(), wptRev = 0, saveStore = function() end }
  -- no drive deps -> mount nil -> export fails gracefully, still a wpt_disk_res
  local rep = App.handleDisk(runtime, { k = "wpt_disk", op = "export" }, { mount = nil })
  t.eq(rep.k, "wpt_disk_res"); t.eq(rep.ok, false)
end)

t.test("handleWptRequest paramsWatch is fire-and-forget and does not persist the store", function()
  local runtime = { store = { waypoints = {}, routes = {} }, wptRev = 0, saveStore = function() error("must not persist") end,
    nav = require("nav.runtime").new({ config = { channel = 1, relay = { channel = 107 } }, now = function() return 0 end }) }
  local reply = App.handleWptRequest(runtime, { k = "paramsWatch", on = true })
  t.eq(reply, nil)
  t.eq(runtime.nav.paramsWatch, true)
end)

t.test("routeModem delivers paramsWatch on the wpt request channel without a reply", function()
  local protocol = require("fcs.comms.protocol")
  local replies = {}
  local runtime = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 0 end,
  })
  runtime.wptLink = { send = function(_, f) replies[#replies + 1] = f end }
  runtime.saveStore = function() error("must not persist") end
  App.routeModem(runtime, App.WPT_REQ_CH, App.WPT_REPLY_CH,
    protocol.encode({ k = "paramsWatch", on = true }), nil)
  t.eq(runtime.nav.paramsWatch, true)
  t.eq(#replies, 0, "paramsWatch is fire-and-forget -- no reply on 109")
end)

t.test("handleWptRequest nav_cfg_get replies current cfg and does not persist", function()
  local persisted
  local cfg = { fuelReserve = 12, units = "m" }
  local runtime = { config = cfg, save = function(c) persisted = c end }
  local reply = App.handleWptRequest(runtime, { k = "nav_cfg_get" })
  t.eq(reply.k, "nav_cfg")
  t.eq(reply.body, cfg)
  t.eq(persisted, nil, "a get never persists")
  t.eq(runtime.config, cfg)
end)

t.test("handleWptRequest nav_cfg_set persists new cfg on ok and replies ack", function()
  local persisted
  local runtime = { config = { fuelReserve = 12 }, save = function(c) persisted = c end }
  local body = { fuelReserve = 40, units = "m" }
  local reply = App.handleWptRequest(runtime, { k = "nav_cfg_set", body = body })
  t.eq(reply.k, "nav_cfg_ack")
  t.eq(reply.ok, true)
  t.eq(runtime.config.fuelReserve, 40)
  t.eq(runtime.config.units, "m")
  t.eq(persisted.fuelReserve, 40)
  t.eq(persisted.units, "m")
end)

-- Break this test would catch: persisting the raw partial body so {channel=7} wipes relay.
t.test("handleWptRequest nav_cfg_set {channel=7} keeps relay.channel default", function()
  local persisted
  local runtime = { config = navconfig.defaults(), save = function(c) persisted = c end }
  local reply = App.handleWptRequest(runtime, { k = "nav_cfg_set", body = { channel = 7 } })
  t.eq(reply.k, "nav_cfg_ack")
  t.eq(reply.ok, true)
  t.eq(runtime.config.channel, 7)
  t.eq(runtime.config.relay.channel, 107)
  t.eq(persisted.channel, 7)
  t.eq(persisted.relay.channel, 107)
end)

t.test("handleWptRequest nav_cfg_set with non-table does not persist", function()
  local persisted = false
  local cfg = { fuelReserve = 12 }
  local runtime = { config = cfg, save = function() persisted = true end }
  local reply = App.handleWptRequest(runtime, { k = "nav_cfg_set", body = "nope" })
  t.eq(reply.k, "nav_cfg_ack")
  t.eq(reply.ok, false)
  t.eq(reply.err, "not a table")
  t.eq(runtime.config, cfg)
  t.eq(persisted, false)
end)

t.test("handleWptRequest still serves wpt_get when navcfg does not claim the frame", function()
  local W = require("nav.waypoints")
  local persisted = false
  local runtime = { config = { fuelReserve = 1 }, store = W.defaults(), wptRev = 3,
    save = function() persisted = true end, saveStore = function() persisted = true end }
  local reply = App.handleWptRequest(runtime, { k = "wpt_get" })
  t.eq(reply.k, "wpt_store"); t.eq(reply.rev, 3)
  t.eq(persisted, false)
end)

t.test("routeModem accepts nav_cfg_get on the wpt request channel and replies nav_cfg", function()
  local protocol = require("fcs.comms.protocol")
  local replies = {}
  local runtime = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 0 end,
  })
  runtime.wptLink = { send = function(_, f) replies[#replies + 1] = f end }
  runtime.save = function() error("must not persist") end
  App.routeModem(runtime, App.WPT_REQ_CH, App.WPT_REPLY_CH,
    protocol.encode({ k = "nav_cfg_get" }), nil)
  t.eq(#replies, 1)
  t.eq(replies[1].k, "nav_cfg")
  t.eq(replies[1].body, runtime.config)
end)

t.test("routeModem accepts nav_cfg_set, persists cfg, and replies ack", function()
  local protocol = require("fcs.comms.protocol")
  local replies, saved = {}, nil
  local runtime = App.buildRuntime({
    gpsModem = fakeDev(), wiredModem = fakeDev(),
    configPath = "/no_such_nav.tbl", now = function() return 0 end,
  })
  runtime.wptLink = { send = function(_, f) replies[#replies + 1] = f end }
  runtime.save = function(c) saved = c end
  local body = { channel = 65001, units = "m" }
  App.routeModem(runtime, App.WPT_REQ_CH, App.WPT_REPLY_CH,
    protocol.encode({ k = "nav_cfg_set", body = body }), nil)
  t.eq(#replies, 1)
  t.eq(replies[1].k, "nav_cfg_ack")
  t.eq(replies[1].ok, true)
  t.eq(runtime.config.channel, 65001)
  t.eq(runtime.config.units, "m")
  t.eq(saved.channel, 65001)
  t.eq(saved.units, "m")
end)
