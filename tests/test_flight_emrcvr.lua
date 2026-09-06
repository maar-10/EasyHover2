-- tests/test_flight_emrcvr.lua
-- Task 2: emrcvr config threading into Flight (defaults fallback + live setter).
-- Task 3: EMRCVR detect/right/restore/exit state machine.
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")
local Pid = require("fcs.control.pid")

local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL" }
  function L:setActive(d) self.scheme = d.scheme end
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:getMode() return self.mode end
  function L:cycle(dt, m) self.cycles = self.cycles + 1
    return { mode = self.mode, m = m, demands = nil, duties = nil } end
  return L
end

t.test("Flight.new with no emrcvr dep falls back to tuningdefaults", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local D = require("fcs.io.tuningdefaults").get().emrcvr
  t.eq(type(f.emr), "table", "flight stores an emr config table")
  t.near(f.emr.tripAngle, D.tripAngle, 1e-9)
  t.near(f.emr.exitAngle, D.exitAngle, 1e-9)
  t.near(f.emr.maxDrift, D.maxDrift, 1e-9)
  t.near(f.emr.dwell, D.dwell, 1e-9)
  t.near(f.emr.levelBand, D.levelBand, 1e-9)
  t.near(f.emr.kpAtt, D.kpAtt, 1e-9)
  t.near(f.emr.capAtt, D.capAtt, 1e-9)
  t.near(f.emr.tripAngle, 1.309, 1e-9)
end)

t.test("Flight.new deep-copies the injected emrcvr dep (mutation doesn't leak back)", function()
  local dep = { tripAngle = 1.0, exitAngle = 0.1, maxDrift = 1.0, dwell = 0.2,
                levelBand = 0.2, kpAtt = 0.5, capAtt = 0.5 }
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG), emrcvr = dep })
  f.emr.tripAngle = 9.9
  t.eq(dep.tripAngle, 1.0, "mutating flight.emr must not mutate the caller's dep table")
end)

t.test("Flight:setEmrcvrCfg merges numeric fields live, leaving others intact", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local before = f.emr.exitAngle
  f:setEmrcvrCfg({ tripAngle = 1.2 })
  t.near(f.emr.tripAngle, 1.2, 1e-9, "tripAngle updated")
  t.near(f.emr.exitAngle, before, 1e-9, "exitAngle untouched")
end)

t.test("Flight:setEmrcvrCfg ignores non-numeric values and non-table input", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local before = f.emr.tripAngle
  f:setEmrcvrCfg({ tripAngle = "nope" })
  t.near(f.emr.tripAngle, before, 1e-9, "non-numeric value ignored")
  f:setEmrcvrCfg("not a table")   -- must not error
  t.near(f.emr.tripAngle, before, 1e-9)
  f:setEmrcvrCfg(nil)             -- must not error
  t.near(f.emr.tripAngle, before, 1e-9)
end)

-- =====================================================================================
-- Task 3: EMRCVR state machine (detect / right / restore / exit)
-- =====================================================================================

-- Fuller fake loop for state-machine tests: real Pid objects on the scheme so attitude
-- demand math (kp*err) is genuine, a mutable caps table, and setEmrcvr/arm/setpoints spies.
-- wrapInner=true mirrors CRUISE/DRN's scheme.inner wrapping (level_flight.lua exposes
-- pitchPid/rollPid only on the INNER level scheme for those two).
local function schemeLoop(wrapInner)
  local pitchPid, rollPid = Pid.new({ kp = 0.12 }), Pid.new({ kp = 0.11 })
  local level = { pitchPid = pitchPid, rollPid = rollPid }
  local scheme = wrapInner and { inner = level } or level
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL", scheme = scheme,
              caps = { pitch = 1, roll = 1, yaw = 2, sway = 3, surge = 4 },
              emrCalls = {}, armCalls = {} }
  function L:setActive(d) self.scheme = d.scheme end
  function L:arm(b) self.armed = b and true or false; self.armCalls[#self.armCalls+1] = self.armed end
  function L:setpoints(x) self.sp = x end
  function L:getMode() return self.mode end
  function L:setEmrcvr(b) self.emrCalls[#self.emrCalls+1] = b; self._emrcvr = b and true or false end
  function L:cycle(dt, m)
    self.cycles = self.cycles + 1
    local lvl = self.scheme.inner or self.scheme
    local demands = nil
    if self.sp and lvl.pitchPid then
      demands = { pitch = lvl.pitchPid:update(self.sp.pitch or 0, m.pitch or 0, dt, false),
                  roll  = lvl.rollPid:update(self.sp.roll or 0, m.roll or 0, dt, false) }
    end
    -- Mirrors loop.lua's non-sticky recompute (self._emrcvr and "EMRCVR" or ...NORMAL...): once
    -- _emrcvr clears, the reported mode reverts, it does not linger on the last-seen value.
    self.mode = self._emrcvr and "EMRCVR" or "NORMAL"
    return { mode = self.mode, m = m, demands = demands, duties = nil }
  end
  return L, level
end

-- Spy pilot: records update/reset calls without doing any real setpoint math -- used where a
-- test must PROVE the pilot was (or wasn't) touched, not just observe its output.
local function spyPilot()
  return {
    updateCalls = 0, resetCalls = 0, resetMeas = nil, setMasterCalls = {},
    setPositionHold = function() end,
    setMode = function() end,
    setMaster = function(self, d) self.setMasterCalls[#self.setMasterCalls+1] = d end,
    setTrimDir = function() end,
    reset = function(self, m) self.resetCalls = self.resetCalls + 1; self.resetMeas = m end,
    update = function(self, dt, held, meas) self.updateCalls = self.updateCalls + 1; return {} end,
  }
end

local function tiltMeas(o)
  o = o or {}
  return { altitude = o.altitude or 20, heading = o.heading or 0,
    swayPos = o.swayPos or 0, surgePos = o.surgePos or 0,
    pitch = o.pitch or 0, roll = o.roll or 0, yawRate = 0,
    swayVel = o.swayVel or 0, surgeVel = o.surgeVel or 0, vSpeed = o.vSpeed or 0,
    onGround = (o.onGround == nil) and false or o.onGround }
end

local function engagedEmrFlight(L, pil)
  local f = Flight.new({ loop = L, pilot = pil or Pilot.new(CFG) })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  return f
end

t.test("EMRCVR trip at 80 deg airborne+engaged: snapshot.mode=='EMRCVR', pilot input ignored", function()
  local L = schemeLoop(false)
  local pil = spyPilot()
  local f = engagedEmrFlight(L, pil)
  local snap = f:step(0.1, { pitchUp = true, up = true, surgeFwd = true }, tiltMeas{ pitch = math.rad(80) })
  t.eq(snap.mode, "EMRCVR", "snapshot mode is EMRCVR")
  t.eq(snap.emrcvr, true, "snapshot carries emrcvr flag")
  t.eq(f.emrcvr, true, "latch set")
  t.eq(pil.updateCalls, 0, "pilot:update never reached -- EMRCVR overrides pilot control")
end)

t.test("EMRCVR does NOT trip when grounded, even past tripAngle", function()
  local L = fakeLoop()
  local f = engagedEmrFlight(L)
  local snap = f:step(0.1, {}, tiltMeas{ pitch = math.rad(80), onGround = true })
  t.eq(f.emrcvr, false, "grounded: no trip")
  t.truthy(snap.mode ~= "EMRCVR", "mode not EMRCVR")
end)

t.test("EMRCVR does NOT trip while disengaged, even airborne past tripAngle", function()
  local L = fakeLoop()
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG) })   -- never engaged
  local snap = f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, false, "disengaged: no trip")
  t.truthy(snap.mode ~= "EMRCVR", "mode not EMRCVR")
end)

t.test("EMRCVR recovery setpoints: pitch/roll=0, altitude two-phase, translate frozen to meas", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  local tripAlt = 42
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80), altitude = tripAlt })
  t.eq(f.emrcvrAlt, tripAlt, "captured trip altitude")
  t.near(L.sp.pitch, 0, 1e-9, "pitch setpoint zeroed")
  t.near(L.sp.roll, 0, 1e-9, "roll setpoint zeroed")
  t.near(L.sp.altitude, tripAlt, 1e-9, "alt tracks meas while still well outside levelBand")

  -- still heavily tilted, craft climbed/drifted while righting -> alt tracks NEW meas
  f:step(0.05, {}, tiltMeas{ pitch = math.rad(80), altitude = tripAlt + 5, swayPos = 3, surgePos = -2 })
  t.near(L.sp.altitude, tripAlt + 5, 1e-9, "alt = meas while tiltMag >= levelBand")
  t.near(L.sp.swayPos, 3, 1e-9, "translate setpoint frozen to current meas (no leash)")
  t.near(L.sp.surgePos, -2, 1e-9, "translate setpoint frozen to current meas (no leash)")

  -- level enough now -> alt reverts to the captured trip altitude
  f:step(0.05, {}, tiltMeas{ pitch = 0.05, roll = 0, altitude = tripAlt + 5 })
  t.near(L.sp.altitude, tripAlt, 1e-9, "alt = captured trip altitude once level enough")
end)

t.test("EMRCVR: inverted pitch (170 deg) yields a nonzero leveling pitch demand", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  local snap = f:step(0.1, {}, tiltMeas{ pitch = math.rad(170) })
  t.eq(snap.mode, "EMRCVR")
  t.truthy(f.lastDiag and f.lastDiag.demands and f.lastDiag.demands.pitch ~= 0,
    "nonzero pitch demand computed against the elevated kpAtt gain")
end)

t.test("EMRCVR trip aborts an active comAuto", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  local aborted = {}
  f.comAuto = { abort = function(self, reason) aborted[#aborted+1] = reason end,
                active = function() return true end }
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true)
  t.eq(aborted[1], "EMRCVR", "comAuto aborted with reason EMRCVR")
end)

t.test("EMRCVR entry mutates pitch/roll kp + caps to kpAtt/capAtt; exit restores exact saved values", function()
  local L, level = schemeLoop(false)
  local origKpP, origKpR = level.pitchPid.kp, level.rollPid.kp
  local origCaps = L.caps
  local f = engagedEmrFlight(L)
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "latched")
  t.eq(L.emrCalls[1], true, "loop:setEmrcvr(true) called on entry")
  t.near(level.pitchPid.kp, f.emr.kpAtt, 1e-9, "pitch kp elevated to kpAtt")
  t.near(level.rollPid.kp, f.emr.kpAtt, 1e-9, "roll kp elevated to kpAtt")
  t.near(L.caps.pitch, f.emr.capAtt, 1e-9, "pitch cap elevated to capAtt")
  t.near(L.caps.roll, f.emr.capAtt, 1e-9, "roll cap elevated to capAtt")
  t.near(L.caps.yaw, origCaps.yaw, 1e-9, "yaw cap untouched")
  t.near(L.caps.sway, origCaps.sway, 1e-9, "sway cap untouched")
  t.near(L.caps.surge, origCaps.surge, 1e-9, "surge cap untouched")

  for i = 1, 20 do f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 }) end
  t.eq(f.emrcvr, false, "exited after dwell held level+still")
  t.eq(L.emrCalls[#L.emrCalls], false, "loop:setEmrcvr(false) called on exit")
  t.near(level.pitchPid.kp, origKpP, 1e-9, "pitch kp restored to the EXACT saved value")
  t.near(level.rollPid.kp, origKpR, 1e-9, "roll kp restored to the EXACT saved value")
  t.eq(L.caps, origCaps, "caps restored to the EXACT saved table object")
end)

t.test("EMRCVR entry/exit through a wrapped inner scheme (CRUISE/DRN shape)", function()
  local L, level = schemeLoop(true)
  local origKp = level.pitchPid.kp
  local origCaps = L.caps
  local f = engagedEmrFlight(L)
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.near(level.pitchPid.kp, f.emr.kpAtt, 1e-9, "wrapped-inner pitch kp elevated")
  for i = 1, 20 do f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 }) end
  t.eq(f.emrcvr, false)
  t.near(level.pitchPid.kp, origKp, 1e-9, "wrapped-inner pitch kp restored to the exact saved value")
  t.eq(L.caps, origCaps, "caps restored to the exact saved object")
end)

-- =====================================================================================
-- Task 4: handleCommand gating while latched + shared _emrAbort on every disarm path
-- =====================================================================================

t.test("EMRCVR lockout: while latched, flightMode/masterMode/gndSafety are refused; fuelPump and engage act", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "latched")
  local modeBefore = f.flightMode

  t.eq(f:handleCommand({ k = "flightMode", id = "CRUISE" }), false, "flightMode refused while latched")
  t.eq(f.flightMode, modeBefore, "flightMode unchanged")

  t.eq(f:handleCommand({ k = "masterMode", id = "DCPL" }), false, "masterMode refused while latched")
  t.eq(f.masterMode, "CPL", "masterMode unchanged (default)")

  t.eq(f:handleCommand({ k = "gndSafety", on = true }), false, "gndSafety refused while latched")
  t.eq(f.gndSafety, false, "gndSafety unchanged")

  t.eq(f:handleCommand({ k = "fuelPump", on = true }), true, "fuelPump honored while latched")
  t.eq(f.fuelPump, true, "fuelPump actually toggled")

  t.eq(f:handleCommand({ k = "engage" }), true, "engage honored while latched")
end)

t.test("EMRCVR disengage while latched: disengages, clears latch, restores exact saved kp/caps", function()
  local L, level = schemeLoop(false)
  local origKpP, origKpR = level.pitchPid.kp, level.rollPid.kp
  local origCaps = L.caps
  local f = engagedEmrFlight(L)
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "latched")

  local r = f:handleCommand({ k = "disengage" })
  t.eq(r, true, "disengage command itself returns true (not blocked)")
  t.eq(f.engaged, false, "disengaged")
  t.eq(f.emrcvr, false, "latch cleared by disengage")
  t.near(level.pitchPid.kp, origKpP, 1e-9, "pitch kp restored to exact saved value")
  t.near(level.rollPid.kp, origKpR, 1e-9, "roll kp restored to exact saved value")
  t.eq(L.caps, origCaps, "caps restored to exact saved object")
  t.eq(L.emrCalls[#L.emrCalls], false, "loop:setEmrcvr(false) called on disengage-abort")

  -- A real snapshot is always emitted through step() (which cycles the loop every tick) --
  -- disengaged now, so this exercises the disarmed/idle path, not EMRCVR.
  local snap = f:step(0.05, {}, tiltMeas{})
  t.truthy(snap.mode ~= "EMRCVR", "snapshot no longer reports EMRCVR after disengage")
end)

t.test("EMRCVR no-fuel abort: _checkFuel clears latch, restores gains/caps, snapshot no longer EMRCVR", function()
  local L, level = schemeLoop(false)
  local origKpP, origKpR = level.pitchPid.kp, level.rollPid.kp
  local origCaps = L.caps
  local frac = 1.0
  local f = Flight.new({ loop = L, pilot = Pilot.new(CFG), fuel = function() return frac end, minFuel = 0.05 })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "latched")

  frac = 0.01   -- below minFuel: trips the no-fuel interlock
  f:step(0.05, {}, tiltMeas{ pitch = math.rad(80) })

  t.eq(f.noFuel, true, "no-fuel latched")
  t.eq(f.emrcvr, false, "EMRCVR latch cleared by no-fuel abort")
  t.near(level.pitchPid.kp, origKpP, 1e-9, "pitch kp restored to exact saved value")
  t.near(level.rollPid.kp, origKpR, 1e-9, "roll kp restored to exact saved value")
  t.eq(L.caps, origCaps, "caps restored to exact saved object")
  t.eq(L.emrCalls[#L.emrCalls], false, "loop:setEmrcvr(false) called on no-fuel abort")

  local snap = f:snapshot(nil, tiltMeas{})
  t.truthy(snap.mode ~= "EMRCVR", "snapshot no longer reports EMRCVR after no-fuel abort")
end)

t.test("EMRCVR entry clears a stale parked latch (LDG parked craft knocked airborne): no re-park drop after recovery", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  -- Simulate a craft that was parked-latched (e.g. LDG landed-detector) before an external
  -- force threw it airborne past tripAngle.
  f.parked = true

  local snap = f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "EMRCVR trips")
  t.eq(f.parked, false, "_emrEnter clears the stale parked latch -- a craft violently thrown past "
    .. "tripAngle while airborne is definitively not resting")

  -- Drive recovery to exit (level + low drift held for dwell).
  for i = 1, 20 do f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 }) end
  t.eq(f.emrcvr, false, "exited recovery")

  -- The following step is the regression this test guards: without the fix, step()'s
  -- parked-honor branch (self.parked still true) would reset the pilot and arm(false) here,
  -- dropping the just-recovered craft until the pilot presses climb.
  local snap2 = f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 })
  t.eq(f.parked, false, "parked latch stays clear after handback")
  t.truthy(snap2.mode ~= "PARKED", "snapshot is not PARKED after recovery handback")
  t.eq(L.armCalls[#L.armCalls], true, "loop stays armed on the post-recovery step (no drop)")
end)

t.test("EMRCVR entry clears a stale positionHold flag so snapshot.positionHold isn't stale-true after recovery", function()
  local L = schemeLoop(false)
  local f = engagedEmrFlight(L)
  f:handleCommand({ k = "positionHold", on = true })
  t.eq(f.positionHold, true, "positionHold set before trip")

  local snap = f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })
  t.eq(f.emrcvr, true, "EMRCVR trips")
  t.eq(f.positionHold, false, "_emrEnter clears positionHold in sync with pilot:setPositionHold(false)")
  t.eq(snap.positionHold, false, "snapshot.positionHold reflects the cleared flag, not stale-true")
end)

t.test("EMRCVR exit is gated on BOTH <exitAngle and <maxDrift held for dwell, then applies CPL/PRECISION + pilot:reset", function()
  local L = schemeLoop(false)
  local pil = spyPilot()
  local reg = { default = "PRECISION", byId = {
    PRECISION = { id = "PRECISION", scheme = { reset = function() end }, mixer = {}, caps = {},
                  policy = { tilt = false, surge = "position" }, feel = nil },
  } }
  local f = Flight.new({ loop = L, pilot = pil, registry = reg })
  f:handleCommand({ k = "gndSafety", on = false }); f:handleCommand({ k = "engage" })
  f.flightMode = "CRUISE"
  f.masterMode = "DCPL"

  f:step(0.1, {}, tiltMeas{ pitch = math.rad(80) })   -- trip
  t.eq(f.emrcvr, true)

  -- level, but drift too high: must NOT exit
  f:step(0.1, {}, tiltMeas{ pitch = 0, roll = 0, surgeVel = f.emr.maxDrift + 1 })
  t.eq(f.emrcvr, true, "drift too high: no exit")

  -- level + slow, but a single short tick is not yet a full dwell
  f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 })
  t.eq(f.emrcvr, true, "dwell not yet satisfied")

  -- hold level+slow long enough to clear dwell
  for i = 1, 20 do f:step(0.05, {}, tiltMeas{ pitch = 0, roll = 0 }) end
  t.eq(f.emrcvr, false, "exits once <exitAngle & <maxDrift held for dwell")
  t.eq(f.masterMode, "CPL", "master forced to CPL on exit")
  t.eq(f.flightMode, "PRECISION", "flight mode forced to PRECISION on exit")
  t.truthy(pil.resetCalls >= 1, "pilot:reset called on exit")
end)
