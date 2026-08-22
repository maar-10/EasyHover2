-- tests/test_flight.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")

-- Fake loop records arm/setpoints/cycle without needing real control.
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL", cleared = false }
  function L:setActive(d) self.scheme = d.scheme end
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:clearDamped() self.cleared = true; self.mode = "NORMAL" end
  function L:getMode() return self.mode end
  function L:cycle(dt, m) self.cycles = self.cycles + 1
    return { mode = self.mode, m = m, demands = nil, duties = nil } end
  return L
end
local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function meas() return { altitude=10, heading=0, swayPos=0, surgePos=0,
  vSpeed=0, yawRate=0, swayVel=0, surgeVel=0, pitch=0, roll=0, onGround=false } end

t.test("snapshot publishes true-Y baro (baroMsl) as the DISPLAY altitude, not the AGL control value", function()
  -- The control loop cycles on meas.altitude (AGL); the telemetry snapshot the UI reads must carry
  -- true Y (baroMsl) so the PFD/FCS ALT matches F3. baroMsl absent -> falls back to altitude.
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local snap = f:snapshot(nil, { altitude = 17, baroMsl = 10 })
  t.eq(snap.altitude, 10, "display altitude is true-Y baro, not AGL")
  local snap2 = f:snapshot(nil, { altitude = 12 })  -- no baroMsl
  t.eq(snap2.altitude, 12, "falls back to altitude when baroMsl absent")
end)

t.test("boot state is safe: disengaged, gndSafety on", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f.engaged, false); t.eq(f.gndSafety, true)
end)

t.test("engage is gated by gndSafety", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  t.eq(f:handleCommand({ k = "engage" }), false, "blocked while gndSafety on")
  t.eq(L.armed, false, "loop not armed")
  t.truthy(f:handleCommand({ k = "gndSafety", on = false }), "safety off")
  t.truthy(f:handleCommand({ k = "engage" }), "engage honored")
  t.eq(f.engaged, true, "engaged")
  f:step(0.1, {}, meas())                    -- meas() is airborne (onGround=false) => arms in step
  t.eq(L.armed, true, "loop armed once stepped airborne")
end)

t.test("engage resets pilot setpoints to current state on next step", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, {}, meas())
  t.near(L.sp.altitude, 10, 1e-9, "seeded to current altitude")
end)

t.test("disengage disarms and clears position hold", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:handleCommand({ k = "positionHold", on = true })
  f:handleCommand({ k = "disengage" })
  t.eq(L.armed, false); t.eq(f.positionHold, false)
end)

t.test("clearDamped forwards to the loop", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "clearDamped" })
  t.truthy(L.cleared, "loop cleared")
end)

-- ---- ground-idle (engaged-but-parked) ----
local function groundMeas(o) o = o or {}
  return { altitude=10, heading=0, swayPos=0, surgePos=0, pitch=0, roll=0, yawRate=0,
           vSpeed=o.vSpeed or 0, swayVel=o.swayVel or 0, surgeVel=o.surgeVel or 0,
           onGround=(o.onGround==nil) and true or o.onGround } end
local function engagedFlight(L)
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  return f
end

t.test("parked: engaged + on-ground + at rest + no climb => loop disarmed (zero thrust)", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas())
  t.eq(L.armed, false, "parked craft => loop disarmed")
end)

t.test("climb un-parks: engaged + on-ground + climb held => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, { up = true }, groundMeas())
  t.eq(L.armed, true, "climb intent arms for liftoff")
end)

t.test("motion un-parks: engaged + on-ground but moving > moveEps => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ surgeVel = 2.0 })   -- scraping forward over terrain
  t.eq(L.armed, true, "moving craft treated as in-flight, not parked")
end)

t.test("airborne: engaged + not on-ground => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(L.armed, true, "airborne always active")
end)

t.test("snapshot reports parked + PARKED mode while parked", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  local snap = f:step(0.1, {}, groundMeas())
  t.eq(snap.parked, true, "parked flag set")
  t.eq(snap.mode, "PARKED", "mode reads PARKED")
end)

t.test("step always cycles the loop and returns a snapshot with flags", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  local snap = f:step(0.1, {}, meas())
  t.eq(L.cycles, 1, "cycled once")
  t.eq(snap.engaged, false); t.eq(snap.gndSafety, true)
  t.truthy(snap.altitude ~= nil, "snapshot carries telemetry")
end)

t.test("comAuto start un-parks and ignores stick", function()
  local L = fakeLoop()
  L.mixer = { com = { fwd = 0, right = 0, span = 4 }, setCom = function(self, c) self.com = c end }
  local f = engagedFlight(L)
  t.truthy(f:handleCommand({ k = "comAuto", op = "start", span = 4 }))
  local snap = f:step(0.1, { up = true }, groundMeas())
  t.eq(L.armed, true, "auto-trim unparks")
  t.eq(snap.comAuto.phase, "CLIMB")
  t.eq(L.sp.pitch, 0)
end)

t.test("comAuto abort forces a descent", function()
  local L = fakeLoop()
  L.mixer = { com = {}, setCom = function(self, c) self.com = c end }
  local f = engagedFlight(L)
  f:handleCommand({ k = "comAuto", op = "start", span = 4 })
  f:step(0.1, {}, groundMeas{ onGround = false })
  f:handleCommand({ k = "comAuto", op = "abort" })
  local snap = f:step(0.1, { up = true }, groundMeas{ onGround = false })
  t.eq(snap.comAuto.phase, "DESCEND")
  t.eq(snap.comAuto.abortReason, "ABORT")
end)

-- ---- comAuto ki capture is scoped to the scheme it captured from ----
local function kiRegistry()
  local sA = { pitchPid = { ki = 0.10 }, rollPid = { ki = 0.11 } }
  local sB = { pitchPid = { ki = 0.20 }, rollPid = { ki = 0.22 } }
  local reg = { default = "A", byId = {
    A = { scheme = sA, mixer = {}, policy = { tilt = false, surge = "position" }, feel = nil },
    B = { scheme = sB, mixer = {}, policy = { tilt = false, surge = "position" }, feel = nil },
  } }
  return reg, sA, sB
end
local function autoFlight(tickResult)
  local L = fakeLoop()
  local reg, sA, sB = kiRegistry()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), registry = reg })
  L.scheme = sA   -- the active scheme the comAuto machinery captures against
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  -- inject a controllable comAuto (active + one tick result per step)
  local result = tickResult
  f.comAuto = {
    active = function() return true end,
    tick = function() return result end,
    spanFwd = 1, spanRight = 1,
  }
  return f, L, sA, sB, function(r) result = r end
end

t.test("comAuto HOLD: capture saves and restores THIS scheme's ki", function()
  local f, L, sA, _, setR = autoFlight({ captureKi = 0.5 })
  f:step(0.1, {}, groundMeas{ onGround = false })            -- capture begins
  t.near(sA.pitchPid.ki, 0.5, 1e-9, "capture applied")
  setR({ captureKi = 0 })                                    -- HOLD ends
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.near(sA.pitchPid.ki, 0.10, 1e-9, "original ki restored")
  t.near(sA.rollPid.ki, 0.11, 1e-9)
end)

t.test("comAuto HOLD: a mode switch mid-capture never writes A's ki into B", function()
  local f, L, sA, sB, setR = autoFlight({ captureKi = 0.5 })
  f:step(0.1, {}, groundMeas{ onGround = false })            -- capturing into A
  t.near(sA.pitchPid.ki, 0.5, 1e-9)
  f:handleCommand({ k = "flightMode", id = "B" })            -- switch while holding
  t.near(sA.pitchPid.ki, 0.10, 1e-9, "A's ki restored before the switch")
  t.near(sA.rollPid.ki, 0.11, 1e-9)
  t.near(sB.pitchPid.ki, 0.20, 1e-9, "B untouched")
  t.near(sB.rollPid.ki, 0.22, 1e-9)
  -- continuing HOLD applies capture to B only from a fresh save of B's values
  setR({ captureKi = 0.6 })
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.near(sB.pitchPid.ki, 0.6, 1e-9, "fresh capture targets the new scheme")
  setR({ captureKi = 0 })
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.near(sB.pitchPid.ki, 0.20, 1e-9, "restore returns to B's own saved value")
end)

t.test("comAuto done: ki restored even though the engaged branch never runs again", function()
  local f, L, sA, _, setR = autoFlight({ captureKi = 0.5 })
  f:step(0.1, {}, groundMeas{ onGround = false })
  setR({ captureKi = 0.5, done = true })
  f:step(0.1, {}, groundMeas{ onGround = false })            -- done => disarm inside step
  t.eq(f.engaged, false)
  t.near(sA.pitchPid.ki, 0.10, 1e-9, "ki left exactly as found")
  -- next step takes the disengaged path; nothing re-corrupts
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.near(sA.pitchPid.ki, 0.10, 1e-9)
end)
