-- tests/test_flight.lua
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")

-- Fake loop records arm/setpoints/cycle without needing real control.
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL", cleared = false, armCalls = {} }
  function L:setActive(d) self.scheme = d.scheme end
  function L:arm(b) self.armed = b and true or false; self.armCalls[#self.armCalls+1] = self.armed end
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

t.test("snapshot publishes compassHeading = wrap360(rawHeading * compassSign)", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG), compassSign = -1 })
  local snap = f:snapshot(nil, { rawHeading = 47 })
  t.eq(snap.compassHeading, 313)   -- wrap360(47 * -1) = 313
end)

t.test("snapshot compassHeading is nil when rawHeading is absent", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f:snapshot(nil, {}).compassHeading, nil)
end)

t.test("snapshot publishes pitch/roll/surgeVel from meas (for UI attitude)", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local meas = { pitch = 0.12, roll = -0.05, surgeVel = 3.4, onGround = false }
  local snap = f:snapshot(nil, meas)
  t.eq(snap.pitch, 0.12); t.eq(snap.roll, -0.05); t.eq(snap.surgeVel, 3.4)
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

-- F2: airborne disengage does NOT call setMode/reset, so a CRUISE throttle detent survived on the
-- pilot; re-engage (reset via _needReset) must not put MAIN back at the old detent with no W held.
local CRUISEFEEL = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4,
  cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 }
t.test("CRUISE: disengage then re-engage does not slam MAIN back to the old throttle detent", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  f.pilot:setMode({ tilt = false, surge = "throttle" }, CRUISEFEEL)
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.5, { surgeFwd = true }, meas())         -- ramp a throttle detent while airborne
  t.truthy((L.sp.surgeThrottle or 0) > 0, "MAIN commanded while W held")
  f:handleCommand({ k = "disengage" })
  f:handleCommand({ k = "engage" })
  f:step(0.1, {}, meas())                          -- re-engaged, no W held
  t.near(L.sp.surgeThrottle or 0, 0, 1e-9, "MAIN stays off after re-engage until W")
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

-- §3.3 redesign: parked is now a global LATCH that only a canPark mode (LDG) can SET (Task 8's
-- landed-detector). Ground-rest alone no longer auto-parks a plain engaged flight (no registry =>
-- canPark defaults false) -- this guards the "only LDG can SET" invariant Task 7 establishes.
t.test("on-ground + at rest alone does NOT set the latch without a canPark mode (SET is gated)", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas())
  t.eq(f.parked, false, "no SET path without canPark => latch stays clear")
  t.eq(L.armed, true, "not parked => normal control, loop armed")
end)

t.test("climb un-parks: engaged + on-ground + climb held => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, { up = true }, groundMeas())
  t.eq(L.armed, true, "climb intent arms for liftoff")
end)

t.test("engaged + on-ground + moving => loop armed (a no-canPark flight never latches parked)", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ surgeVel = 2.0 })   -- scraping forward over terrain
  t.eq(L.armed, true, "moving craft treated as in-flight, not parked")
end)

t.test("airborne: engaged + not on-ground => loop armed", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(L.armed, true, "airborne always active")
end)

t.test("snapshot: parked/PARKED mode require the latch to be SET, not just ground+rest", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  local snap = f:step(0.1, {}, groundMeas())
  t.eq(snap.parked, false, "parked flag stays clear absent a SET path")
  t.truthy(snap.mode ~= "PARKED", "mode does not read PARKED absent a SET path")
end)

t.test("step always cycles the loop and returns a snapshot with flags", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  local snap = f:step(0.1, {}, meas())
  t.eq(L.cycles, 1, "cycled once")
  t.eq(snap.engaged, false); t.eq(snap.gndSafety, true)
  t.truthy(snap.altitude ~= nil, "snapshot carries telemetry")
end)

-- ---- §3.3 global parked latch: mode-switch wiring (setGroundSense/canPark) + HONOR/CLEAR ----
-- Small registry fixture carrying groundSense/canPark flags (mirrors the real fcs.modes.registry
-- shape) without pulling in the real scheme/mixer machinery -- matches this file's kiRegistry()
-- pattern below.
local function modeRegistry()
  return { default = "LDG", byId = {
    PRECISION = { id = "PRECISION", policy = { tilt = false, surge = "position" }, feel = nil,
      groundSense = false, canPark = false },
    LDG = { id = "LDG", policy = { tilt = false, surge = "position" }, feel = nil,
      groundSense = true, canPark = true },
    DRN = { id = "DRN", policy = { tilt = true, surge = "position", translate = false }, feel = nil,
      groundSense = false, canPark = false },
  } }
end

t.test("mode switch calls setGroundSense with the descriptor's flag and updates canPark", function()
  local calls = {}
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), registry = modeRegistry(),
    setGroundSense = function(b) calls[#calls+1] = b end })
  f:handleCommand({ k = "flightMode", id = "DRN" })
  t.eq(calls[#calls], false, "DRN disables ground-sense")
  t.eq(f.canPark, false, "DRN sets canPark false")
  f:handleCommand({ k = "flightMode", id = "LDG" })
  t.eq(calls[#calls], true, "LDG enables ground-sense")
  t.eq(f.canPark, true, "LDG sets canPark true")
end)

t.test("parked latch is HONORED in a non-LDG mode: loop stays disarmed, ascend clears it", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), registry = modeRegistry() })
  f.engaged = true
  f.parked = true               -- pretend LDG latched it earlier
  f.flightMode = "PRECISION"    -- then switched away
  f:step(0.05, {}, groundMeas())
  t.eq(L.armCalls[#L.armCalls], false, "parked honored: loop disarmed in non-LDG")
  t.eq(f.parked, true, "latch still set (honored, not cleared by a non-climb step)")
  f:step(0.05, { up = true }, groundMeas())
  t.eq(f.parked, false, "ascend clears parked in any mode")
  t.eq(L.armCalls[#L.armCalls], true, "cleared => normal control resumes, loop armed")
end)

t.test("parked latch PERSISTS across a mode switch away from LDG (handleCommand never clears it)", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), registry = modeRegistry() })
  f.flightMode = "LDG"
  f.parked = true               -- latched while in LDG
  f:handleCommand({ k = "flightMode", id = "PRECISION" })
  t.eq(f.parked, true, "latch persists across the switch")
  t.eq(f.canPark, false, "canPark still mirrors the new (non-LDG) descriptor")
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

t.test("setCom command applies a manual CoM offset to the mixer LIVE (fly a hand-set trim, no reboot)", function()
  local L = fakeLoop()
  L.mixer = { com = {}, setCom = function(self, c) self.com = c end }
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })
  t.truthy(f:handleCommand({ k = "setCom", fwd = -0.6, right = -0.1, spanFwd = 7, spanRight = 3.5 }))
  t.eq(L.mixer.com.fwd, -0.6); t.eq(L.mixer.com.right, -0.1)
  t.eq(L.mixer.com.spanFwd, 7); t.eq(L.mixer.com.spanRight, 3.5)
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

-- ---- Task 8: LDG landed-detector (_ldgLanded) SETs the parked latch ----
local function landedMeas(o) o = o or {}
  return { groundDist = o.groundDist or 0.8, vSpeed = o.vSpeed or 0.05, swayVel = o.swayVel or 0.05,
           surgeVel = o.surgeVel or 0.05, pitch = o.pitch or 0.05, roll = o.roll or -0.05,
           altitude = 1, heading = 0, onGround = (o.onGround == nil) and true or o.onGround,
           swayPos = 0, surgePos = 0, yawRate = 0 } end
local function parkFlight(L)
  local f = engagedFlight(L)
  f.canPark = true
  f.flightMode = "LDG"
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  return f
end

t.test("LDG parks at a valid landed measurement: grounded, stable, within tilt band, hands-off", function()
  local L = fakeLoop(); local f = parkFlight(L)
  f:step(0.05, {}, landedMeas())
  t.eq(f.parked, true, "LDG parks at valid parking position")
  t.eq(L.armCalls[#L.armCalls], false, "SET disarms the loop")
end)

-- The parked detector must use the CALIBRATED on-ground flag (backend's onGroundThreshold), not the
-- separate, uncalibrated park.groundClear. On a real pad the optical ground distance (e.g. 2.2) can
-- exceed the stock groundClear (1.0) while the craft is squarely on the ground (onGround=true) --
-- that must still park, or the FCS keeps stabilizing on the pad.
t.test("LDG parks on calibrated ground contact even when groundDist exceeds the stock groundClear", function()
  local L = fakeLoop(); local f = parkFlight(L)
  f:step(0.05, {}, landedMeas{ onGround = true, groundDist = 2.2 })
  t.eq(f.parked, true, "parks on the calibrated onGround flag, ignoring the orphan groundClear")
  t.eq(L.armCalls[#L.armCalls], false, "SET disarms the loop on the ground")
end)

t.test("LDG refuses to park when tilt exceeds parkTiltBand", function()
  local L = fakeLoop(); local f = parkFlight(L)
  f:step(0.05, {}, landedMeas{ pitch = 0.3 })
  t.eq(f.parked, false, "excess tilt refuses park")
end)

t.test("LDG refuses to park while a tilt input is held", function()
  local L = fakeLoop(); local f = parkFlight(L)
  f:step(0.05, { pitchUp = true }, landedMeas())
  t.eq(f.parked, false, "tilt input refuses park")
end)

t.test("LDG refuses to park without calibrated ground contact (onGround false)", function()
  local L = fakeLoop(); local f = parkFlight(L)
  f:step(0.05, {}, landedMeas{ onGround = false })
  t.eq(f.parked, false, "no calibrated ground contact -> no park")
end)

t.test("non-LDG (canPark=false) never sets the parked latch even when grounded+still", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  f.canPark = false
  f.flightMode = "PRECISION"
  f.park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 }
  f:step(0.05, {}, landedMeas())
  t.eq(f.parked, false, "non-LDG cannot set parked")
end)

-- ---- Task 7 carried finding: comAuto must be able to clear a latched-parked craft ----
-- HONOR/CLEAR previously cleared ONLY on held.up. But comAuto forces held={} every step (see the
-- top of step()), so held.up can never fire while comAuto is active -- a latched-parked craft could
-- never be un-parked by autopilot, and Auto-CoM-trim (meant to climb off a landed state) got stuck.
t.test("parked latch is CLEARED when comAuto is active, so comAuto can take over from landed", function()
  local L = fakeLoop()
  L.mixer = { com = {}, setCom = function(self, c) self.com = c end }
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), registry = modeRegistry() })
  f.engaged = true
  f.parked = true                -- pretend LDG latched it earlier
  f.flightMode = "LDG"
  f.comAuto = { active = function() return true end,
    tick = function() return { setpoints = { altitude = 5 } } end, spanFwd = 1, spanRight = 1 }
  f:step(0.05, {}, groundMeas())
  t.eq(f.parked, false, "comAuto active clears the parked latch")
  t.eq(L.armCalls[#L.armCalls], true, "cleared => comAuto branch runs this same tick, loop armed")
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

t.test("comAuto capture hands off to the mixer: pitch/roll integrators are ZEROED (no double-compensation)", function()
  -- During HOLD the captureKi integral builds the level-hold differential; at capture that SAME
  -- compensation is measured (offsetFromDuties reads the duties) and applied to the MIXER as the CoM
  -- offset. If the integrator is left in place it STACKS with the mixer offset (double-compensation)
  -- -> the craft over-corrects, rolls/pitches off attitude, and the angled lift converts that into a
  -- lateral drift. The integrators must be zeroed at the hand-off so the mixer alone carries it.
  local f, L, sA, _, setR = autoFlight({ captureKi = 0.5 })
  L.mixer = { setCom = function(self, c) self.com = c end }
  sA.pitchPid.i = 0.37; sA.rollPid.i = -0.12                 -- integral built up over the HOLD
  setR({ captured = { fwd = -0.7, right = -0.1 }, captureKi = 0 })
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(sA.pitchPid.i, 0, "pitch integrator zeroed at the capture hand-off")
  t.eq(sA.rollPid.i, 0, "roll integrator zeroed at the capture hand-off")
  t.truthy(L.mixer.com and L.mixer.com.fwd == -0.7, "CoM offset applied to the mixer")
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
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.near(sA.pitchPid.ki, 0.10, 1e-9)
end)

-- ---- §11.8 no-fuel interlock (FCS-side; reads the already-polled fuel snapshot, no extra I/O) ----
local function fuelFlight(L, frac0)
  local level = frac0
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG),
    fuel = function() return level end })
  return f, function(v) level = v end
end

t.test("no-fuel: engage is refused while the tank reads below minFuel", function()
  local L = fakeLoop(); local f = fuelFlight(L, 0.01)
  f:handleCommand({ k = "gndSafety", on = false })
  t.eq(f:handleCommand({ k = "engage" }), false, "engage blocked on empty tank")
  t.eq(f.engaged, false)
end)

t.test("no-fuel: running dry mid-flight disarms, resets loops, and latches noFuel", function()
  local L = fakeLoop(); local f, setFuel = fuelFlight(L, 1.0)
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, { up = true }, groundMeas{ onGround = false })   -- airborne + armed
  t.eq(L.armed, true, "sane before the trip")
  setFuel(0.02)                                                -- tank runs dry in flight
  local snap = f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(snap.noFuel, true, "snapshot annunciate noFuel")
  t.eq(f.engaged, false, "disengaged")
  t.eq(L.armed, false, "loop disarmed (zero thrust via the unarmed cycle path)")
  t.eq(snap.engaged, false)
end)

t.test("no-fuel: latched until refuelled past the hysteresis band, then engage works", function()
  local L = fakeLoop(); local f, setFuel = fuelFlight(L, 1.0)
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, { up = true }, groundMeas{ onGround = false })
  setFuel(0.01); f:step(0.1, {}, groundMeas{ onGround = false })   -- trip
  setFuel(0.06)                                                    -- above minFuel, below 2x
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(f.noFuel, true, "still latched inside hysteresis band")
  t.eq(f:handleCommand({ k = "engage" }), false, "engage still refused")
  setFuel(0.5)                                                     -- well past 2x minFuel
  f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(f.noFuel, false, "cleared past hysteresis")
  t.truthy(f:handleCommand({ k = "engage" }), "re-engage honored after refuel")
end)

t.test("no-fuel: an unreadable gauge (nil reading) never trips the gate", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), fuel = function() return nil end })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  local snap = f:step(0.1, { up = true }, groundMeas{ onGround = false })
  t.eq(snap.noFuel, false, "nil gauge never trips")
  t.eq(L.armed, true, "flight unaffected")
end)

t.test("no-fuel: without an injected getter the interlock is inert (backwards compatible)", function()
  local L = fakeLoop(); local f = engagedFlight(L)
  local snap = f:step(0.1, {}, groundMeas{ onGround = false })
  t.eq(snap.noFuel, false); t.eq(L.armed, true)
end)

t.test("no-fuel trip restores comAuto-captured ki (same contract as disengage)", function()
  local f, L, sA = autoFlight({ captureKi = 0.5 })
  f:step(0.1, {}, groundMeas{ onGround = false })            -- capture applied (gauge still unset)
  t.near(sA.pitchPid.ki, 0.5, 1e-9)
  f.fuel = function() return 0.01 end
  f.minFuel = 0.05
  f:step(0.1, {}, groundMeas{ onGround = false })            -- trip
  t.eq(f.noFuel, true)
  t.eq(f.engaged, false)
  t.near(sA.pitchPid.ki, 0.10, 1e-9, "ki restored on the fuel trip")
end)

-- ---- Task 6: fuel command + telemetry ----
-- newFlight(extra): Flight.new with the file's standard fakeLoop/Pilot pair, extended with
-- whatever extra deps (setFuelScale/saveFuel/fuelName spies, etc.) the test needs to inject.
local function newFlight(extra)
  local o = { loop = fakeLoop(), pilot = Pilot.new(CFG) }
  for k, v in pairs(extra or {}) do o[k] = v end
  return Flight.new(o)
end

t.test("flight: fuel command sets scale + persists + telemetry", function()
  local scaleX, saved
  local f = newFlight({ setFuelScale = function(x) scaleX = x end, saveFuel = function(id) saved = id end })
  t.eq(f:handleCommand({ k = "fuel", id = "Ethanol" }), true, "known fuel accepted")
  t.near(scaleX, 0.30, 1e-9, "scale 0.30")
  t.eq(saved, "Ethanol", "persisted")
  local snap = f:snapshot(nil, {})
  t.eq(snap.fuel, "Ethanol", "telemetry fuel"); t.eq(snap.fuelPct, 200, "pct")
  t.eq(snap.badFuel, false, "ethanol not bad")
end)
t.test("flight: bad fuel + unknown id", function()
  local f = newFlight()
  f:handleCommand({ k = "fuel", id = "Plant Oil" })
  t.eq(f:snapshot(nil, {}).badFuel, true, "plant oil bad")
  local before = f.fuelName
  f:handleCommand({ k = "fuel", id = "Nonsense" })
  t.eq(f.fuelName, before, "unknown id no-op")
end)
t.test("flight: default fuel is Biodiesel", function()
  t.eq(newFlight().fuelName, "Biodiesel", "defaults to baseline")
end)

-- ---- PARAMS watch: gated snapshot extras (devWarn / disk) ----
t.test("paramsWatch is off by default; snapshot omits devWarn and disk", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  t.eq(f.paramsWatch, false)
  local snap = f:snapshot(nil, meas())
  t.eq(snap.devWarn, nil)
  t.eq(snap.disk, nil)
end)

t.test("paramsWatch on publishes devWarn and disk; off omits them again", function()
  local seeded = 0
  local f = Flight.new({
    loop = fakeLoop(), pilot = Pilot.new(CFG),
    diskPresent = function() seeded = seeded + 1; return true end,
  })
  t.truthy(f:handleCommand({ k = "paramsWatch", on = true }))
  t.eq(f.paramsWatch, true)
  t.eq(seeded, 1)
  t.eq(f.disk, true)
  f.devWarn = true
  local snap = f:snapshot(nil, meas())
  t.eq(snap.devWarn, true)
  t.eq(snap.disk, true)
  f:handleCommand({ k = "paramsWatch", on = false })
  local snap2 = f:snapshot(nil, meas())
  t.eq(snap2.devWarn, nil)
  t.eq(snap2.disk, nil)
end)

t.test("paramsWatch on=true twice does not re-seed the disk", function()
  local seeded = 0
  local f = Flight.new({
    loop = fakeLoop(), pilot = Pilot.new(CFG),
    diskPresent = function() seeded = seeded + 1; return false end,
  })
  f:handleCommand({ k = "paramsWatch", on = true })
  f:handleCommand({ k = "paramsWatch", on = true })
  t.eq(seeded, 1, "second on is a no-op seed")
end)

local function trimFakeLoop()
  local L = fakeLoop()
  function L:setTrim(dir, gain, authority, fadeStart, fade, brakeTrim)
    self.trimArgs = { dir, gain, authority, fadeStart, fade }
    self.brakeTrimArg = brakeTrim
  end
  return L
end
local function trimFakePilot()
  return { setMode = function() end, reset = function() end, setTrimDir = function() end,
    setPositionHold = function() end, setMaster = function() end, update = function() return {} end }
end

t.test("flight seeds + threads trim fade/floor feel into loop:setTrim", function()
  local L = trimFakeLoop()
  local feel = { trimDir = -1, trimGain = 0.35, trimAuthority = 0.4, trimFadeStart = 0.25, trimFade = 0.6 }
  local desc = { feel = feel, policy = {}, canPark = false, groundSense = false,
    scheme = { reset = function() end } }
  local reg = { default = "CRUISE", byId = { CRUISE = desc } }
  local f = Flight.new({ loop = L, pilot = trimFakePilot(), registry = reg })
  t.near(f.trimAuthority, 0.4, 1e-9, "seeded from default descriptor at boot")
  t.near(f.trimFadeStart, 0.25, 1e-9, "fadeStart seeded")
  t.near(f.trimFade, 0.6, 1e-9, "fade seeded")
  f:handleCommand({ k = "flightMode", id = "CRUISE" })
  t.truthy(L.trimArgs, "setTrim was called on mode switch")
  t.eq(L.trimArgs[3], 0.4,  "authority threaded")
  t.eq(L.trimArgs[4], 0.25, "fadeStart threaded")
  t.eq(L.trimArgs[5], 0.6,  "fade threaded")
end)

t.test("flight threads brakeTrim into loop:setTrim (6th arg), boolean-safe", function()
  -- CRUISE descriptor with brakeTrim=true -> threaded true; a descriptor without brakeTrim -> seeded true (legacy).
  local L = trimFakeLoop()
  local feel = { trimDir = -1, trimGain = 0.35, trimAuthority = 0.4, trimFadeStart = 0.25, trimFade = 0.6, brakeTrim = true }
  local desc = { feel = feel, policy = {}, canPark = false, groundSense = false, scheme = { reset = function() end } }
  local reg = { default = "CRUISE", byId = { CRUISE = desc } }
  local f = Flight.new({ loop = L, pilot = trimFakePilot(), registry = reg })
  t.eq(f.brakeTrim, true, "seeded brakeTrim=true from descriptor")
  f:handleCommand({ k = "flightMode", id = "CRUISE" })
  t.eq(L.brakeTrimArg, true, "brakeTrim threaded as 6th setTrim arg")

  -- forward-only mode: brakeTrim=false must thread false (NOT be lost by an `or`-style default)
  local L2 = trimFakeLoop()
  local reg2 = { default = "PRE", byId = { PRE = { feel = { trimDir = -1, trimGain = 0.35, brakeTrim = false },
    policy = {}, scheme = { reset = function() end } } } }
  local f2 = Flight.new({ loop = L2, pilot = trimFakePilot(), registry = reg2 })
  t.eq(f2.brakeTrim, false, "seeded brakeTrim=false (boolean-safe, not defaulted to true)")
  f2:handleCommand({ k = "flightMode", id = "PRE" })
  t.eq(L2.brakeTrimArg, false, "brakeTrim=false threaded")
end)
