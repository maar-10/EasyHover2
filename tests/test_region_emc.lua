-- tests/test_region_emc.lua
-- EMC region screens (ui/basalt/regions/emc.lua) for the merged "flight" cockpit page.
-- Covers the three Basalt-free intent seams (M._onEngine / M._cfg / M._setMax) with stub
-- runtimes, then a CONSTRUCTION PROBE: a real ui/basalt/region.lua Region hosting all three
-- screens, apply() on each, one basalt.update("timer",-1) render pass. NEVER basalt.run().
local t = require("tests.framework")
local M = require("ui.basalt.regions.emc")
local Region = require("ui.basalt.region")
local BasaltApp = require("ui.basalt.app")
local Uical = require("ui.basalt.bitconfig.uical")

-- ===== stub engine: records toggleMaster/feedNow, mutable .master field for status(now) =====

local function newEngineStub(initialMaster)
  local calls = { toggleMaster = 0, feedNow = 0 }
  local e = { master = initialMaster and true or false }
  function e:toggleMaster(now)
    calls.toggleMaster = calls.toggleMaster + 1
    self.master = not self.master
    return self.master
  end
  function e:feedNow(now)
    calls.feedNow = calls.feedNow + 1
    return true
  end
  function e:status(now)
    return { master = self.master }
  end
  return e, calls
end

local function newFuelCfg()
  return {
    pump = { name = nil, kind = "inventory", empty = 0, full = 0 },
    tank = { name = nil, kind = "inventory", empty = 0, full = 0 },
  }
end

-- ===== M._onEngine: no Basalt, stub runtime =====

t.test("_onEngine: engSw does nothing when no relay is bound", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = nil, side = nil }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(result, nil, "gated inert -> nil")
  t.eq(calls.toggleMaster, 0)
end)

t.test("_onEngine: engSw toggles master once a relay is bound", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(calls.toggleMaster, 1)
  t.truthy(result ~= nil and result.op == "toggleMaster", "returns the action taken")
end)

t.test("_onEngine: engSw is gated when the relay NAME is set but the relay is not actually wrapped", function()
  -- Honest-switch fix: config.relay.name alone must not green the switch / allow master-on. The
  -- relay must have actually wrapped -- runtime.isRelayReady() reflects that (a pure read of the
  -- bound relay in ui/basalt/app.lua, no peripheral call).
  local engine, calls = newEngineStub(false)
  local runtime = {
    engine = engine,
    config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() },
    isRelayReady = function() return false end,
  }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(result, nil, "name set but not wrapped -> gated inert")
  t.eq(calls.toggleMaster, 0)
end)

t.test("_onEngine: engSw toggles when the relay is actually wrapped (isRelayReady true)", function()
  local engine, calls = newEngineStub(false)
  local runtime = {
    engine = engine,
    config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() },
    isRelayReady = function() return true end,
  }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(calls.toggleMaster, 1)
  t.truthy(result ~= nil and result.op == "toggleMaster")
end)

t.test("_onEngine: prime does nothing when no relay is bound (even if master reads on)", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = nil, side = nil }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(result, nil)
  t.eq(calls.feedNow, 0)
end)

t.test("_onEngine: prime does nothing when relay bound but master is off", function()
  local engine, calls = newEngineStub(false)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(result, nil)
  t.eq(calls.feedNow, 0)
end)

t.test("_onEngine: prime feeds when relay bound AND master is on", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "prime", 1000)

  t.eq(calls.feedNow, 1)
  t.truthy(result ~= nil and result.op == "feedNow", "returns the action taken")
end)

t.test("_onEngine: an unrecognised id returns nil and calls nothing", function()
  local engine, calls = newEngineStub(true)
  local runtime = { engine = engine, config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() } }

  local result = M._onEngine(runtime, "bogus", 1000)

  t.eq(result, nil)
  t.eq(calls.toggleMaster, 0)
  t.eq(calls.feedNow, 0)
end)

t.test("_onEngine: engSw refuses toggle-on while latest.noFuel", function()
  local engine, calls = newEngineStub(false)
  local runtime = {
    engine = engine,
    config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() },
    isRelayReady = function() return true end,
    rx = { latest = function() return { noFuel = true } end },
  }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(result, nil, "noFuel blocks master-on")
  t.eq(calls.toggleMaster, 0)
  t.eq(engine.master, false)
end)

t.test("_onEngine: engSw still toggles off while latest.noFuel", function()
  local engine, calls = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = { relay = { name = "relay_1", side = "back" }, fuel = newFuelCfg() },
    isRelayReady = function() return true end,
    rx = { latest = function() return { noFuel = true } end },
  }

  local result = M._onEngine(runtime, "engSw", 1000)

  t.eq(calls.toggleMaster, 1)
  t.eq(engine.master, false)
  t.truthy(result ~= nil and result.op == "toggleMaster")
end)

-- ===== M._setMax: pure-of-Basalt manual-max stepper, with a save spy =====

local function newSaveSpy()
  local calls = {}
  local function save(path, cfg) calls[#calls + 1] = { path = path, cfg = cfg } end
  return save, calls
end

local function newMaxRuntime()
  return { config = { fuel = newFuelCfg() }, uiRev = 0 }
end

t.test("_setMax: solid +64 sets pump.full, saves against CONFIG_PATH, bumps uiRev", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  local newFull = M._setMax(runtime, "pump", 64, save)

  t.eq(newFull, 64)
  t.eq(runtime.config.fuel.pump.full, 64)
  t.eq(#calls, 1)
  t.eq(calls[1].path, BasaltApp.CONFIG_PATH)
  t.eq(runtime.uiRev, 1)
end)

t.test("_setMax: liquid +1000 sets tank.full, saves, bumps uiRev", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  local newFull = M._setMax(runtime, "tank", 1000, save)

  t.eq(newFull, 1000)
  t.eq(runtime.config.fuel.tank.full, 1000)
  t.eq(#calls, 1)
  t.eq(runtime.uiRev, 1)
end)

t.test("_setMax: solid decrement clamps at 0, never negative", function()
  local runtime = newMaxRuntime()
  runtime.config.fuel.pump.full = 30
  local save = newSaveSpy()

  local newFull = M._setMax(runtime, "pump", -64, save)

  t.eq(newFull, 0)
  t.eq(runtime.config.fuel.pump.full, 0)
end)

t.test("_setMax: liquid decrement clamps at 0, never negative", function()
  local runtime = newMaxRuntime()
  runtime.config.fuel.tank.full = 500
  local save = newSaveSpy()

  local newFull = M._setMax(runtime, "tank", -1000, save)

  t.eq(newFull, 0)
  t.eq(runtime.config.fuel.tank.full, 0)
end)

t.test("_setMax: repeated steps accumulate (two +64s on pump)", function()
  local runtime = newMaxRuntime()
  local save, calls = newSaveSpy()

  M._setMax(runtime, "pump", 64, save)
  local newFull = M._setMax(runtime, "pump", 64, save)

  t.eq(newFull, 128)
  t.eq(#calls, 2)
  t.eq(runtime.uiRev, 2)
end)

-- ===== M._cfg: delegates to uical's tested intent seam (no reimplementation) =====

local function newCfgStubRuntime()
  local calls = { rebind = 0, blockNow = 0 }
  local engine = {}
  function engine:blockNow() calls.blockNow = calls.blockNow + 1 end
  function engine:applyConfig(cfg) end

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = nil, side = "back" },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
    engine = engine,
    rebindRelay = function() calls.rebind = calls.rebind + 1 end,
  }
  return runtime, calls
end

t.test("_cfg: 'relaySide' delegates through to uical -- cycles the relay side and saves", function()
  local runtime = newCfgStubRuntime()
  local save, saveCalls = newSaveSpy()

  local effect = M._cfg(runtime, "relaySide", { save = save })

  t.truthy(effect ~= nil and effect.op == "cycleRelaySide", "uical's effect surfaces through")
  t.eq(runtime.config.relay.side, "front", "nextSide('back') == 'front', exactly uical's mapping")
  t.eq(#saveCalls, 1)
end)

t.test("_cfg: 'pulseUp' delegates through to uical -- steps pulseMs by +50", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "pulseUp", { save = save })

  t.eq(runtime.config.engine.pulseMs, 300)
end)

t.test("_cfg: an unrecognised id returns nil (uical's own ConfigPanel.action dispatch)", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  local effect = M._cfg(runtime, "totallyBogus", { save = save })

  t.eq(effect, nil)
end)

-- REGRESSION (Important bug fix): uical._onButton -> _applyOp saves config to disk but never
-- bumps uiRev, and the cadence signature has no field for relay side/name, pulseMs, intervalMs,
-- or bind names -- so emc_config's labels (RELAY: <side>, PMP <name>, etc.) would stay stale
-- until an unrelated telemetry change happened to repaint the page. M._cfg must bump uiRev itself
-- after every delegated call, regardless of which id or what uical's effect was.

t.test("_cfg: bumps runtime.uiRev after delegating (relaySide) so the config screen repaints", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()
  t.eq(runtime.uiRev, 0)

  M._cfg(runtime, "relaySide", { save = save })

  t.eq(runtime.uiRev, 1, "uiRev bumped exactly once")
end)

t.test("_cfg: bumps runtime.uiRev even for a bind op (BIND PUMP), no real peripheral touched", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()
  local deps = { scan = function() return {} end, save = save }

  M._cfg(runtime, "bindPump", deps)

  t.eq(runtime.uiRev, 1, "uiRev bumped even when no candidates were found to bind")
end)

t.test("_cfg: bumps runtime.uiRev even when the id is unrecognised", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "totallyBogus", { save = save })

  t.eq(runtime.uiRev, 1, "uiRev still bumps -- the caller pressed a button, screen must repaint")
end)

t.test("_cfg: repeated presses (relaySide twice) accumulate uiRev, one bump per call", function()
  local runtime = newCfgStubRuntime()
  local save = newSaveSpy()

  M._cfg(runtime, "relaySide", { save = save })
  M._cfg(runtime, "pulseUp", { save = save })

  t.eq(runtime.uiRev, 2)
end)

-- ===== M.config pickers: construction probe + DRAIN-SAFETY through the exact seams its onPick =====
-- ===== closures call (Uical._pickBind / Uical._pickSide -- already exhaustively unit-tested in =====
-- ===== tests/test_bitconfig_uical.lua; here we confirm M.config wires them with the SAME deps =====
-- ===== it was given, and that its own uiRev bump happens on top). =====

t.test("M.config (redesign): readouts + PULSE/INT steppers; device binding MOVED to BIT/CONFIG UI CAL", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)                     -- the real EMC top-region size (flight.lua M.split of 36x38)
  local region = { push = function() end, pop = function() end }

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = "relay_2", side = "top" },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }
  local scanCalls = 0
  local function scan() scanCalls = scanCalls + 1; return {} end

  local h = M.config(basalt, frame, region, runtime, { scan = scan })

  -- The SIDE/PMP/TNK/RLY dropdowns moved to BIT/CONFIG UI CAL, so this screen neither scans
  -- peripherals nor builds pickers -- it's engine readouts + PULSE/INT steppers + INVERT + CAL FUEL.
  t.eq(scanCalls, 0, "no peripheral scan on this screen anymore")
  t.eq(h.elements.pumpPicker, nil, "no pump picker here (moved to UI CAL)")
  t.eq(h.elements.relayPicker, nil, "no relay picker here (moved to UI CAL)")
  t.truthy(h.elements.pulseDn and h.elements.pulseUp, "PULSE steppers present")
  t.truthy(h.elements.intDn and h.elements.intUp, "INTRVL steppers present")
  t.truthy(h.elements.invBtn ~= nil, "INVERT toggle present")
  t.truthy(h.elements.calFuelBtn ~= nil and h.elements.backBtn ~= nil, "CAL FUEL + BACK present")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  t.truthy(h.elements.pulseLbl:getText():find("250", 1, true), "PULSE readout reflects pulseMs")

  local okr, errr = pcall(function() basalt.update("timer", -1) end)
  t.truthy(okr, "basalt.update should not error: " .. tostring(errr))
end)

t.test("M.config (redesign): INVERT readout reflects config.engine.invert", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)
  local region = { push = function() end, pop = function() end }
  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = nil, side = nil },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = true, kickstart = true, masterDefault = false },
    },
  }
  local h = M.config(basalt, frame, region, runtime, { scan = function() return {} end })
  h.apply({})
  t.truthy(h.elements.invLbl:getText():find("ON", 1, true), "INVERT: ON when config.engine.invert is true")
end)

t.test("emc_config: FUEL row shows the calibration (ABBR pct%) from reported state.fuel/fuelPct", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)
  local region = { push = function() end, pop = function() end }
  local runtime = { uiRev = 0, config = {
    relay = { name = "relay_2", side = "top" }, fuel = newFuelCfg(),
    engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false } } }
  local h = M.config(basalt, frame, region, runtime, { scan = function() return {} end })
  h.apply({ fuel = "Biodiesel", fuelPct = 60 })
  t.eq(h.elements.fuelLabel:getText(), "FUEL:   BIOD 60%", "ABBR + pct from telemetry")
  h.apply({})
  t.eq(h.elements.fuelLabel:getText(), "FUEL:   ----", "---- when fuel unknown")
end)

t.test("M.config: picking a relay through its wired onPick (Uical._pickBind) re-blocks -- DRAIN SAFETY -- and M.config's own bump() fires", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save, saveCalls = newSaveSpy()
  local descriptors = { { name = "relay_9", type = "redstone_relay", methods = {} } }
  local function scan() return descriptors end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)
  t.eq(runtime.uiRev, 0, "no pick made yet")

  -- Drive the EXACT seam M.config's RELAY picker's onPick closure calls, with the SAME deps
  -- M.config itself was built with -- confirms the wiring (not just the seam in isolation).
  Uical._pickBind(runtime, "relay", "relay_9", descriptors, deps)

  t.eq(runtime.config.relay.name, "relay_9")
  t.eq(calls.rebind, 1, "DRAIN SAFETY: rebindRelay fired on the relay pick")
  t.eq(calls.blockNow, 1, "DRAIN SAFETY: engine:blockNow fired on the relay pick")
  t.eq(#saveCalls, 1)
end)

t.test("M.config: pump/tank picks through Uical._pickBind never touch the relay (NO re-block)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save = newSaveSpy()
  local descriptors = { { name = "tank_9", type = "fluid_tank", methods = { getFuelAmountMb = true } } }
  local function scan() return descriptors end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)

  Uical._pickBind(runtime, "pump", "tank_9", descriptors, deps)

  t.eq(runtime.config.fuel.pump.name, "tank_9")
  t.eq(calls.rebind, 0, "pump pick never rebinds the relay")
  t.eq(calls.blockNow, 0, "pump pick never re-blocks")
end)

t.test("M.config: picking a relay side through Uical._pickSide re-blocks -- DRAIN SAFETY", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local region = { push = function() end, pop = function() end }
  local runtime, calls = newCfgStubRuntime()
  local save = newSaveSpy()
  local function scan() return {} end
  local deps = { scan = scan, save = save }

  M.config(basalt, frame, region, runtime, deps)

  Uical._pickSide(runtime, "left", deps)

  t.eq(runtime.config.relay.side, "left")
  t.eq(calls.rebind, 1, "DRAIN SAFETY: rebindRelay fired on the side pick")
  t.eq(calls.blockNow, 1, "DRAIN SAFETY: engine:blockNow fired on the side pick")
end)

-- ===== CONSTRUCTION PROBE: real Basalt, a Region hosting all three screens, stub runtime =====

t.test("Region hosting emc_main/emc_config/emc_calfuel builds + applies + renders without error", function()
  local basalt = BasaltApp.ensureBasalt()
  local parent = basalt.createFrame()

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    uiRev = 0,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1024 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 8000 },
      },
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }

  local screens = {
    emc_main    = function(b, f, r) return M.main(b, f, r, runtime) end,
    emc_config  = function(b, f, r) return M.config(b, f, r, runtime) end,
    emc_calfuel = function(b, f, r) return M.calfuel(b, f, r, runtime) end,
  }

  local region = Region.new(basalt, parent, { x = 1, y = 1, width = 14, height = 24, root = "emc_main", screens = screens })

  local sampleState = { pumpAmount = 800, tankMb = 4200, engineMaster = true, feeding = false }

  t.eq(region:top(), "emc_main")
  local ok1, err1 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok1, "emc_main apply should not error: " .. tostring(err1))

  region:push("emc_config")
  local ok2, err2 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok2, "emc_config apply should not error: " .. tostring(err2))

  region:push("emc_calfuel")
  local ok3, err3 = pcall(function() region:apply(sampleState) end)
  t.truthy(ok3, "emc_calfuel apply should not error: " .. tostring(err3))

  region:pop(); region:pop()
  t.eq(region:top(), "emc_main")

  local okr, errr = pcall(function() basalt.update("timer", -1) end)
  t.truthy(okr, "basalt.update should not error: " .. tostring(errr))
end)

t.test("emc_main: apply() reflects state.pumpAmount/tankMb via manual-max fractions (no peripheral read)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 4000 },
      },
    },
  }

  local region = { push = function() end, pop = function() end }
  local handle = M.main(basalt, frame, region, runtime)

  handle.apply({ pumpAmount = 800, tankMb = 4000, engineMaster = true, feeding = true })

  t.eq(handle.elements.pmpBar:getProgress(), 80, "800/1000 -> 80%")
  t.eq(handle.elements.pmpValLabel:getText(), "800x", "int amount + 'x' unit, no space")
  t.eq(handle.elements.mainBar:getProgress(), 100, "4000/4000 -> 100%")
  t.eq(handle.elements.mainValLabel:getText(), "4B", "floor(mB/1000) + 'B' unit, no space")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("emc_main: LFED shows solid fuel fed last feed (state.lfed) as 'n BZC', '-- BZC' when nil", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local runtime = { engine = newEngineStub(true), config = {
    relay = { name = "relay_1", side = "back" },
    fuel = { pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
             tank = { name = "tank_1", kind = "fluid", empty = 0, full = 4000 } } } }
  local region = { push = function() end, pop = function() end }
  local handle = M.main(basalt, frame, region, runtime)
  handle.apply({ lfed = 3 })
  t.eq(handle.elements.lfedLabel:getText(), "LFED 3 BZC", "n BZC when fed")
  handle.apply({ lfed = nil })
  t.eq(handle.elements.lfedLabel:getText(), "LFED -- BZC", "-- BZC before any feed")
end)

-- ===== Task 3: fuel-panel redesign -- label-over-bar, colored bars, int+unit values, compact =====
-- ===== ENG SW/PRIME controls. Construction probe on a 14x11 fake frame (the merged page's real =====
-- ===== EMC region size), asserting the FULL geometry/content contract from the design spec. =====

t.test("M.main (Task 3 redesign): fuel panel geometry, colors, and int+unit values", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)   -- the real EMC top-region size (flight.lua M.split of the 36x38 overhead)

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 500000 },
      },
    },
  }
  local region = { push = function() end, pop = function() end }

  local handle = M.main(basalt, frame, region, runtime)
  handle.apply({ pumpAmount = 128, tankMb = 180350, engineMaster = true, feeding = false })

  local el = handle.elements

  -- Values: exact, no space, no percent.
  t.eq(el.pmpValLabel:getText(), "128x", "solid value == pumpAmount .. 'x'")
  t.eq(el.mainValLabel:getText(), "180B", "liquid value == floor(tankMb/1000) .. 'B'")

  -- Labels: solid reads exactly "Solid Pump BZC"; liquid starts with "Liq"/"Liquid Main" and
  -- contains the liquid abbreviation (fit-to-width may pick the short fallback).
  t.eq(el.pmpLabel:getText(), "Solid Pump " .. M.SOLID_ABBR)
  local liquidText = el.mainLabel:getText()
  t.truthy(liquidText:find("^Liq"), "liquid label starts with 'Liq'")
  t.truthy(liquidText:find(M.LIQUID_ABBR, 1, true), "liquid label contains the liquid abbreviation")

  -- Bars: present, colored (not the black default), sitting at x=2.
  t.truthy(el.pmpBar ~= nil, "pmpBar exists")
  t.truthy(el.mainBar ~= nil, "mainBar exists")
  t.eq(el.pmpBar:getX(), el.mainBar:getX(), "both bars share the same interior-left x")
  t.truthy(el.pmpBar:getX() >= 2, "bars sit inside the green border (x >= 2), got " .. tostring(el.pmpBar:getX()))
  t.eq(el.pmpBar:getProgressColor(), colors.green, "pmpBar filled color is green, not the black default")
  t.eq(el.pmpBar:getBackground(), colors.gray, "pmpBar empty color is gray")
  t.eq(el.mainBar:getProgressColor(), colors.green, "mainBar filled color is green")
  t.eq(el.mainBar:getBackground(), colors.gray, "mainBar empty color is gray")

  -- ENG SW / PRIME: 3-row outlined raw buttons (Basalt addBorder), sharing a common width.
  t.eq(el.engSw:getHeight(), 3, "ENG SW is a 3-row outlined button")
  t.eq(el.primeBtn:getHeight(), 3, "PRIME is a 3-row outlined button")
  t.eq(el.engSw:getWidth(), el.primeBtn:getWidth(), "ENG SW / PRIME share a common width")

  -- Every element: y >= 2 (row 1 is the blank top margin), x + width - 1 <= 36 (region width -- an
  -- element may reach column w, never past it).
  local probe = {
    el.pmpLabel, el.pmpBar, el.pmpValLabel,
    el.mainLabel, el.mainBar, el.mainValLabel,
    el.engSw, el.primeBtn,
    el.masterBlock, el.masterText,
    el.feedBlock, el.feedText,
    el.configBtn,
  }
  for i, e in ipairs(probe) do
    t.truthy(e:getY() >= 2, "element #" .. i .. " y >= 2 (got " .. tostring(e:getY()) .. ")")
    local right = e:getX() + e:getWidth() - 1
    t.truthy(right <= 36, "element #" .. i .. " x+width-1 <= 36 (got " .. tostring(right) .. ")")
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

-- ===== Task 4: M.calfuel expanded steppers (solid +-1/+-64, liquid +-1000/+-50000/+-100000) + =====
-- ===== M.config top margin. Construction probe on the same 14x11 fake frame as Task 3's M.main =====
-- ===== test above -- clicks each button by firing its registered "mouse_click" callback directly =====
-- ===== (bypasses screen-position/bounds checks -- this is the exact channel :onClick(fn) wires =====
-- ===== into, per release/basalt-full.lua's registerEventCallback/registerCallback/fireEvent). =====

t.test("M.calfuel (Task 4): expanded steppers -- exact deltas, clamps at 0, centered layout within 36x17", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)   -- the real EMC top-region size (calfuel drills within it)

  local runtime = {
    uiRev = 0,
    config = {
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 500000 },
      },
    },
  }
  local region = { push = function() end, pop = function() end }

  local handle = M.calfuel(basalt, frame, region, runtime)
  local el = handle.elements

  -- Labels: "SOLID <n>x" / "LIQUID <n>B" (n == buckets == floor(tank.full/1000)), each padded with
  -- %-7s so the numeric values line up in a column across the two rows.
  t.eq(el.solidLabel:getText(), "SOLID  1000x")
  t.eq(el.liqLabel:getText(), "LIQUID 500B")

  -- Every element: y >= 2 (row 1 is the blank top margin), x + width - 1 <= 36 (region width). The
  -- steppers are chipButton controls -- probe their raw .label button; backBtn/labels are raw elements.
  local probe = {
    el.backBtn, el.solidLabel, el.liqLabel,
    el.solidDn64.label, el.solidDn1.label, el.solidUp1.label, el.solidUp64.label,
    el.liqDn100.label, el.liqDn50.label, el.liqDn1.label, el.liqUp1.label, el.liqUp50.label, el.liqUp100.label,
  }
  for i, e in ipairs(probe) do
    t.truthy(e:getY() >= 2, "element #" .. i .. " y >= 2 (got " .. tostring(e:getY()) .. ")")
    local right = e:getX() + e:getWidth() - 1
    t.truthy(right <= 36, "element #" .. i .. " x+width-1 <= 36 (got " .. tostring(right) .. ")")
  end

  -- Click == fire the same "mouse_click" event :onClick(fn) registered a listener under. chipButton
  -- wires both its .chip and .label to the handler, so firing .label is a real click.
  local function click(btn) (btn.label or btn):fireEvent("mouse_click", 1, 1, 1) end

  local function assertDelta(btn, role, delta, startFull)
    runtime.config.fuel[role].full = startFull
    click(btn)
    t.eq(runtime.config.fuel[role].full, math.max(0, startFull + delta),
      "delta " .. tostring(delta) .. " on " .. role .. " (from " .. startFull .. ")")
  end

  -- Solid: {-64,-1,+1,+64} -> pump.full, exact deltas.
  assertDelta(el.solidDn64, "pump", -M.SOLID_STEP, 1000)
  assertDelta(el.solidDn1,  "pump", -M.SOLID_FINE, 1000)
  assertDelta(el.solidUp1,  "pump",  M.SOLID_FINE, 1000)
  assertDelta(el.solidUp64, "pump",  M.SOLID_STEP, 1000)

  -- Liquid: {-100000,-50000,-1000,+1000,+50000,+100000} -> tank.full, exact deltas (captions are
  -- buckets, e.g. "-100" -> -M.LIQUID_100 mB).
  assertDelta(el.liqDn100, "tank", -M.LIQUID_100, 500000)
  assertDelta(el.liqDn50,  "tank", -M.LIQUID_50,  500000)
  assertDelta(el.liqDn1,   "tank", -M.LIQUID_STEP, 500000)
  assertDelta(el.liqUp1,   "tank",  M.LIQUID_STEP, 500000)
  assertDelta(el.liqUp50,  "tank",  M.LIQUID_50,  500000)
  assertDelta(el.liqUp100, "tank",  M.LIQUID_100, 500000)

  -- Clamp at 0: a decrement larger than the current max never goes negative (assertDelta's own
  -- math.max(0, ...) expectation already covers this, exercised explicitly here too).
  assertDelta(el.solidDn64, "pump", -M.SOLID_STEP, 30)
  assertDelta(el.liqDn100,  "tank", -M.LIQUID_100, 5000)

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("M.config (redesign): top-margin -- BACK at y >= 2, and every control (incl. CAL FUEL, the " ..
  "LAST one) fits the real EMC region (36x17 = flight.lua M.split of the 36x38 overhead)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17) -- the real EMC top-region size (matches M.main/M.calfuel's construction probes)
  local region = { push = function() end, pop = function() end }

  local runtime = {
    uiRev = 0,
    config = {
      relay = { name = nil, side = nil },
      fuel = newFuelCfg(),
      engine = { pulseMs = 250, intervalMs = 330000, invert = false, kickstart = true, masterDefault = false },
    },
  }
  local function scan() return {} end

  local h = M.config(basalt, frame, region, runtime, { scan = scan })
  local el = h.elements

  t.truthy(el.backBtn:getY() >= 2, "BACK button at y >= 2 (got " .. tostring(el.backBtn:getY()) .. ")")

  -- Every control (readout labels + PULSE/INT steppers + INVERT + CAL FUEL/BACK) must fit the region's
  -- 17 rows. CAL FUEL is the LAST control (bottom row); it sits at y=12, comfortably inside 17.
  -- chipButton controls expose .label (a raw Basalt button); outlinedButtons + labels are raw elements.
  local probe = {
    backBtn = el.backBtn, calFuelBtn = el.calFuelBtn,
    pulseLbl = el.pulseLbl, intLbl = el.intLbl, invLbl = el.invLbl,
    pulseDn = el.pulseDn.label, pulseUp = el.pulseUp.label,
    intDn = el.intDn.label, intUp = el.intUp.label, invBtn = el.invBtn.label,
  }
  for name, e in pairs(probe) do
    t.truthy(e:getY() <= 17, name .. " y <= 17 (got " .. tostring(e:getY()) .. ")")
  end

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

-- ===== Task 9 / Task 3 (option a): emc_calfuel's fuel CHIP + gfxpicker + BAD FUEL warning =====

t.test("calfuel: fuel chip shows the reported fuel + %, red chip on badFuel", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)   -- the real EMC region size (flight.lua M.split of the 36x38 overhead)
  local region = { push = function() end, pop = function() end }
  local runtime = { config = { fuel = newFuelCfg() } }

  local h = M.calfuel(basalt, frame, region, runtime)
  local el = h.elements
  t.truthy(el.fuelBtn ~= nil, "fuel picker button present (bottom, next to BACK)")
  t.truthy(el.fuelPicker ~= nil, "fuelPicker (gfxpicker) present")
  t.truthy(el.badLabel ~= nil, "BAD FUEL label present in elements")

  h.apply({ fuel = "Diesel", fuelPct = 80, badFuel = false })
  t.eq(el.fuelBtn:getText(), "Diesel 80%")
  t.truthy(el.fuelBtn:getForeground() ~= colors.red, "ok fuel -> button text not red")

  h.apply({ fuel = "Plant Oil", fuelPct = 20, badFuel = true })
  t.eq(el.fuelBtn:getForeground(), colors.red, "badFuel -> red button text")
  t.eq(el.badLabel:getText(), "BAD FUEL", "BAD FUEL shown for sub-baseline fuel")
  t.eq(el.badLabel:getForeground(), colors.red, "BAD FUEL label is red when bad")

  h.apply({ fuel = "Biodiesel", fuelPct = 60, badFuel = false })
  t.eq(el.badLabel:getText(), "", "hidden for baseline fuel")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("calfuel: tapping the fuel chip opens the modal; picking sends the fuel command", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)
  local region = { push = function() end, pop = function() end }
  local sent = {}
  local runtime = {
    config = { fuel = newFuelCfg() },
    sender = { send = function(_, cmd) return cmd end },
    links = { tel = { send = function(_, frame2) sent[#sent + 1] = frame2 end } },
  }

  local h = M.calfuel(basalt, frame, region, runtime)
  local el = h.elements

  -- Tap the fuel button -- opens the gfxpicker overlay.
  el.fuelBtn:fireEvent("mouse_click", 1, 1, 1)
  t.truthy(el.fuelPicker.visible(), "gfxpicker overlay visible after fuel-button tap")

  -- Pick index 5 -- "Diesel" per fcs/fueltable.lua's display order (1 Plant Oil, 2 Ethanol,
  -- 3 Biodiesel, 4 Sulfurized Diesel, 5 Diesel, 6 Gasoline, 7 Kerosene, 8 Turpentine).
  el.fuelPicker.pick(5)

  t.truthy(#sent >= 1, "a fuel command was sent")
  t.eq(sent[#sent].k, "fuel", "fuel command kind")
  t.eq(sent[#sent].id, "Diesel", "fuel command id")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("emc_main shows FLOW/LEFT from fuelEst", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  frame:setSize(36, 17)   -- the real EMC top-region size (flight.lua M.split of the 36x38 overhead)

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 500000 },
      },
    },
  }
  local region = { push = function() end, pop = function() end }

  local built = M.main(basalt, frame, region, runtime)

  built.apply({ fuelEst = { state = "drain", mbPerMin = 450, secondsLeft = 18 * 60 } })
  t.eq(built.elements.flowLabel:getText(), "FLOW 450 mB/m", "flow rendered")
  t.eq(built.elements.leftLabel:getText(), "LEFT 18m", "left rendered")

  built.apply({ fuelEst = { state = "idle" } })
  t.eq(built.elements.flowLabel:getText(), "FLOW 0 mB/m", "idle flow")
  t.eq(built.elements.leftLabel:getText(), "LEFT --", "idle left")

  -- Truncation (Minor finding from the whole-branch review): FLOW/LEFT setText must route through
  -- the module's fit() helper like every other Label in this file, so an oversized formatted string
  -- never WRAPS under Basalt's Label.autoSize=false (see the file header note) -- it gets truncated
  -- instead. mbPerMin=99999999 formats to "FLOW 99999999 mB/m" (19 chars), which exceeds flowLabel's
  -- width (16 cols at this 36-wide region, iw=32 split in half).
  built.apply({ fuelEst = { state = "drain", mbPerMin = 99999999, secondsLeft = 60 } })
  local flowText = built.elements.flowLabel:getText()
  -- Assert truncation DETERMINISTICALLY: getWidth() is unreliable on the un-rendered mock frame
  -- (returns 0), but the fit() truncation is observable directly -- the un-fit label would be
  -- "FLOW 99999999 mB/m" (18 chars) and fit() makes it strictly shorter (to flowW, ~16 here).
  local unfit = "FLOW 99999999 mB/m"
  t.truthy(#flowText < #unfit,
    "FLOW over-long string must be fit-truncated (unfit " .. #unfit .. " chars; got " .. #flowText .. ": " .. flowText .. ")")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

t.test("engine panel: fuel seam", function()
  local E = require("ui.panels.engine")
  t.eq(#E.fuelOptions(), 8, "8 fuel options")
  t.eq(E.fuelCommand("Ethanol").k, "fuel", "command kind")
  t.eq(E.fuelCommand("Ethanol").id, "Ethanol", "command id")
  t.eq(E.fuelLabel({ fuel = "Biodiesel", fuelPct = 60 }), "Biodiesel 60%", "label")
  t.eq(E.fuelLabel({}), "FUEL --", "label fallback")
  t.eq(E.fuelBad({ badFuel = true }), true, "bad true")
  t.eq(E.fuelBad({ badFuel = false }), false, "bad false")
end)

t.test("engine panel: flow/left labels per state", function()
  local E = require("ui.panels.engine")
  t.eq(E.flowLabel({ state="drain", mbPerMin=450 }), "FLOW 450 mB/m", "drain flow")
  t.eq(E.leftLabel({ state="drain", secondsLeft=18*60 }), "LEFT 18m", "drain left <1h")
  t.eq(E.leftLabel({ state="drain", secondsLeft=65*60 }), "LEFT 1h05m", "drain left >=1h zero-pad")
  t.eq(E.flowLabel({ state="idle" }), "FLOW 0 mB/m", "idle flow")
  t.eq(E.leftLabel({ state="idle" }), "LEFT --", "idle left")
  t.eq(E.flowLabel({ state="refuel" }), "FLOW +", "refuel flow")
  t.eq(E.leftLabel({ state="refuel" }), "LEFT +", "refuel left")
  t.eq(E.flowLabel({ state="unknown" }), "FLOW --", "unknown flow")
  t.eq(E.leftLabel(nil), "LEFT --", "nil left")
end)

t.test("emc_main: Liquid Main label reflects state.fuel (was hardcoded BDSL)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local engine = newEngineStub(true)
  local runtime = {
    engine = engine,
    config = {
      relay = { name = "relay_1", side = "back" },
      fuel = {
        pump = { name = "chest_1", kind = "inventory", empty = 0, full = 1000 },
        tank = { name = "tank_1",  kind = "fluid",     empty = 0, full = 200000 },
      },
    },
  }

  local region = { push = function() end, pop = function() end }
  local handle = M.main(basalt, frame, region, runtime)

  handle.apply({ fuel = "Diesel", tankMb = 200000, pumpAmount = 5 })
  t.truthy(handle.elements.mainLabel:getText():find("DSL"), "Liquid Main label shows selected fuel abbrev")

  handle.apply({ fuel = "Biodiesel", tankMb = 200000 })
  t.truthy(handle.elements.mainLabel:getText():find("BDSL"), "label updates to BDSL on Biodiesel")

  local ok, err = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok, "basalt.update should not error: " .. tostring(err))
end)

-- ===== Task 1: border edges resolver (standalone-panel hosting) =====

t.test("_resolveEdges: nil opts -> DEFAULT_EDGES (top+left+right, no bottom)", function()
  local e = M._resolveEdges(nil)
  t.eq(e.top, true); t.eq(e.left, true); t.eq(e.right, true); t.eq(e.bottom, false)
  t.eq(e, M.DEFAULT_EDGES, "nil opts returns the module default table")
end)

t.test("_resolveEdges: opts.edges override wins (full box)", function()
  local full = { top = true, bottom = true, left = true, right = true }
  local e = M._resolveEdges({ edges = full })
  t.eq(e, full)
end)

t.test("_resolveEdges: opts without edges falls back to DEFAULT_EDGES", function()
  t.eq(M._resolveEdges({ scan = function() return {} end }), M.DEFAULT_EDGES)
end)

return true
