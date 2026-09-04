-- tests/test_pilot_modes.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")
local FEEL = { headingRate=2.2, leadCapHeading=0.7, climbRate=4.5, leadCapVert=8,
  surgeSpeed=10, surgeLead=20, swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.4,
  cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 }
local function meas() return { altitude=0, heading=0, swayPos=0, surgePos=0 } end

t.test("MAN tilt ramps while held and auto-levels on release", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  local a = p:update(0.1, { pitchUp = true }, meas())
  t.truthy(a.pitch > 0, "pitch ramps up while held")
  local held = a.pitch
  local b = p:update(0.1, {}, meas())          -- released
  t.truthy(b.pitch < held, "pitch decays toward level on release")
end)

t.test("MAN tilt is clamped to tiltCap", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = true, surge = "position" }, FEEL); p:reset(meas())
  for _ = 1, 50 do p:update(0.1, { rollRight = true }, meas()) end
  t.truthy(p:update(0, {}, meas()).roll <= 0.4 + 1e-9, "roll capped at tiltCap")
end)

t.test("CRUISE throttle ramps up, holds on release, ramps down on back", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "throttle" }, FEEL); p:reset(meas())
  local up = p:update(0.2, { surgeFwd = true }, meas())
  t.truthy(up.surgeThrottle > 0, "throttle rises")
  local hold = p:update(0.2, {}, meas())
  t.near(hold.surgeThrottle, up.surgeThrottle, 1e-9, "throttle holds on release")
  local down = p:update(0.2, { surgeBack = true }, meas())
  t.truthy(down.surgeThrottle < hold.surgeThrottle, "S ramps throttle down")
end)

t.test("PRECISION policy emits no tilt", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "position" }, FEEL); p:reset(meas())
  local sp = p:update(0.1, { pitchUp = true }, meas())
  t.truthy((sp.pitch or 0) == 0, "no pitch in non-tilt policy")
end)

-- MAN drift-relax: while the pilot actively tilts, the horizontal position hold must not
-- fight the bank-drift. Modelled by resetting the position setpoints to the MEASURED
-- position each tick so the translate loop sees ~zero error; releasing tilt freezes them.
-- Covered by pilot.lua's unified drift rule (any tilt mode relaxes while tilting); the
-- relaxTiltDrift field itself is now inert (kept here to show it is harmless to pass).
local MANPOL = { tilt = true, surge = "position", relaxTiltDrift = true }

t.test("MAN relaxes horizontal hold while tilting (position setpoints track measured)", function()
  local p = Pilot.new(FEEL); p:setMode(MANPOL, FEEL); p:reset(meas())
  -- craft has drifted to swayPos/surgePos = 3 while the pilot holds pitch; the hold must
  -- follow (not command a correction back to 0).
  local m = { altitude = 0, heading = 0, swayPos = 3, surgePos = 3 }
  local sp = p:update(0.1, { pitchUp = true }, m)
  t.near(sp.swayPos, 3, 1e-9, "swayPos tracks measured while tilting (no fight)")
  t.near(sp.surgePos, 3, 1e-9, "surgePos tracks measured while tilting")
end)

t.test("MAN re-holds position after tilt release (freezes, ignores further drift)", function()
  local p = Pilot.new(FEEL); p:setMode(MANPOL, FEEL); p:reset(meas())
  p:update(0.1, { pitchUp = true }, { altitude=0, heading=0, swayPos=3, surgePos=3 })
  -- release tilt; craft coasts to swayPos=5 but the hold must stay where tilt ended (3),
  -- NOT keep tracking the new measured position.
  local sp = p:update(0.1, {}, { altitude=0, heading=0, swayPos=5, surgePos=5 })
  t.near(sp.swayPos, 3, 1e-9, "swayPos frozen at tilt-release position, not re-tracking 5")
  t.near(sp.surgePos, 3, 1e-9, "surgePos frozen at tilt-release position")
end)

-- PRECISION has policy.tilt=false and no held tilt keys, and driftArrest defaults true (CPL-like
-- hands-off), so the unified rule never fires: the hold stays put under drift.
t.test("PRECISION hands-off (driftArrest default true): hold stays put under drift", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "position" }, FEEL); p:reset(meas())
  local sp = p:update(0.1, {}, { altitude=0, heading=0, swayPos=3, surgePos=3 })
  t.near(sp.swayPos, 0, 1e-9, "PRECISION holds its setpoint (0), not the drifted 3")
end)

-- DRN policy.translate=false: the generic sway/surge leash must NOT move the setpoints from
-- held keys; the craft is meant to translate by tilt only, with sway/surge frozen at reset.
t.test("policy.translate=false freezes sway/surge leash (drone: tilt-only translation)", function()
  local p = Pilot.new(FEEL)
  p:setMode({ tilt = true, surge = "position", translate = false }, FEEL)
  p:reset(meas())
  local sp = p:update(0.1, { surgeFwd = true, swayRight = true }, meas())
  t.near(sp.surgePos, 0, 1e-9, "translate=false freezes surgePos")
  t.near(sp.swayPos, 0, 1e-9, "translate=false freezes swayPos")
end)

-- Regression guard: an existing mode (no translate field, e.g. PRECISION) must keep ramping
-- the position leash exactly as before.
t.test("existing mode (no translate field) still ramps sway/surge leash", function()
  local p = Pilot.new(FEEL)
  p:setMode({ tilt = true, surge = "position" }, FEEL)
  p:reset(meas())
  local sp = p:update(0.1, { surgeFwd = true, swayRight = true }, meas())
  t.truthy(sp.surgePos > 0, "surgePos ramps forward without translate flag")
  t.truthy(sp.swayPos > 0, "swayPos ramps right without translate flag")
end)

-- F2: the CRUISE throttle detent is a persistent accumulator (self.throttle). reset() rebuilds sp
-- but must ALSO drop the accumulator, or a disengage/re-engage (which reseeds via reset) re-derives
-- sp.surgeThrottle from the stale detent and slams MAIN back on with no W held.
t.test("reset drops the held CRUISE throttle detent (no MAIN demand returns without W)", function()
  local p = Pilot.new(FEEL); p:setMode({ tilt = false, surge = "throttle" }, FEEL); p:reset(meas())
  p:update(0.5, { surgeFwd = true }, meas())      -- ramp a forward-throttle detent
  t.truthy(p.throttle > 0, "detent accumulated while W held")
  p:reset(meas())                                  -- disengage/re-engage reseed
  t.eq(p.throttle, 0, "reset zeros the throttle accumulator")
  local sp = p:update(0.1, {}, meas())             -- first tick after re-engage, no W
  t.near(sp.surgeThrottle or 0, 0, 1e-9, "MAIN stays off until W is held again")
end)

-- A1: CRUISE drives surge via throttle, not the position leash. Leaving CRUISE under CPL with a
-- leashed-ahead surgePos rails reverse after detent; keep sp.surgePos on measured while throttle.
-- (self.throttle is checked at the START of update(), so the first tick after reset -- where the
-- accumulator is still 0 -- takes the arrest/leash branch, not the pin; a priming tick establishes
-- throttle>0 before we assert the pin, per the one-tick-lag note in fix #3 task 4.)
t.test("CRUISE throttle policy does not advance surgePos off measured", function()
  local p = Pilot.new(FEEL)
  p:setMode({ tilt = false, surge = "throttle" }, FEEL)
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 100 })
  local meas = { altitude = 0, heading = 0, swayPos = 0, surgePos = 50, yawRate = 0 }
  p:update(0.2, { surgeFwd = true }, meas)         -- priming tick: throttle ramps 0 -> >0
  local sp = p:update(0.2, { surgeFwd = true }, meas)
  t.near(sp.surgePos, 50, 1e-9, "surgePos stays on measured, not leashed ahead")
  t.truthy((sp.surgeThrottle or 0) > 0, "throttle still ramps under CRUISE")
end)

-- Task 4 (fix #3): at throttle 0 the pilot LEASHES surgePos (holds current, no forward lead) instead
-- of continuing to pin it to measured, so the CRUISE arrest (cruise.lua) has a station to hold rather
-- than chasing a coasting measured position. Drift is introduced AFTER throttle reaches 0 (simulating
-- momentum: the craft keeps sliding forward under the old measured position while the setpoint should
-- NOT re-track it) so the leash and pin branches provably diverge -- if the throttle-0 branch were
-- reverted to the old unconditional `sp.surgePos = meas.surgePos`, sp.surgePos would snap to the new
-- meas (100) and this test would fail.
t.test("CRUISE throttle policy leashes surgePos (holds station, doesn't re-pin) once throttle returns to 0", function()
  local p = Pilot.new(FEEL)
  p:setMode({ tilt = false, surge = "throttle" }, FEEL)
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 0 })
  local meas = { altitude = 0, heading = 0, swayPos = 0, surgePos = 0, yawRate = 0 }
  p:update(0.2, { surgeFwd = true }, meas)          -- ramp throttle up (pin branch: sp tracks meas=0)
  p:update(0.5, { surgeBack = true }, meas)         -- ramp throttle back down to 0 (still pins while >0)
  -- Throttle is now 0. Momentum carries the craft on: meas jumps far ahead of the held setpoint.
  meas.surgePos = 100
  local sp = p:update(0.1, {}, meas)                -- throttle 0 at entry: leash branch, not pin
  t.truthy(sp.surgePos < 90, "leash does not snap to the new measured position (pin would give 100)")
  t.near(sp.surgePos, meas.surgePos - FEEL.surgeLead, 1e-9,
    "leash clamps to at most surgeLead behind the new measured position, holding station")
end)

-- Task 5 (fix #3): non-tilt-mode auto tilt-brake. CRU arrests (throttle<=0) under CPL, above
-- engageSpeed, in a tiltBrake-enabled mode -> pitch/roll setpoint opposing horizontal drift.
local function measv(o) o = o or {}
  return { altitude=o.altitude or 10, heading=o.heading or 0, swayPos=o.swayPos or 0,
           surgePos=o.surgePos or 0, surgeVel=o.surgeVel or 0, swayVel=o.swayVel or 0,
           pitch=o.pitch or 0, roll=o.roll or 0, yawRate=o.yawRate or 0 }
end
local TB = { enabled=true, engageSpeed=30, satSpeed=100, minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 }
local CRU_FEEL = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                   swaySpeed=5, swayLead=10, cruiseThrottleRate=1, cruiseThrottleMax=1, tiltBrake=TB }

t.test("CRU auto tilt-brake: throttle 0, fast forward drift, CPL -> nose-up pitch setpoint", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })   -- throttle 0, 80 blk/s forward
  t.truthy(sp.pitch > 0.2, "aerobrake nose-up engaged")
  t.near(sp.roll, 0, 1e-9, "no lateral drift -> no roll brake")
end)

t.test("CRU: forward throttle (throttle>0) does NOT auto tilt-brake", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  p:update(1.0, { surgeFwd=true }, measv{ surgeVel=80 })  -- ramp throttle up
  local sp = p:update(0.05, { surgeFwd=true }, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "cruising forward stays level")
end)

-- Discriminates the `btn` half of `engaged = btn or (autoArrest and self.driftArrest)`
-- (fcs/input/pilot.lua _brakeSetpoint): throttle>0 makes autoArrest FALSE (see the
-- "does NOT auto tilt-brake" case above), so this can only pass via the button override.
-- Would fail if `btn or (...)` regressed to `btn and (...)` or dropped btn entirely.
-- (Task 7 wires the throttle-cut on held.brake; this asserts _brakeSetpoint's tilt output
-- alone, which is independent of that.)
t.test("CRU: held.brake button forces tilt-brake even while throttle>0 (autoArrest false)", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  p:update(1.0, { surgeFwd=true }, measv{ surgeVel=80 })  -- ramp throttle up (autoArrest false)
  local sp = p:update(0.05, { brake=true }, measv{ surgeVel=80 })
  t.truthy(sp.pitch > 0.2, "button overrides autoArrest gate")
end)

t.test("CRU auto tilt-brake suppressed under DCPL (drift allowed)", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(false); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "DCPL coasts, no auto brake")
end)

t.test("CRU below engage speed -> no tilt (thrusters only)", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=20 })
  t.near(sp.pitch, 0, 1e-9, "20 blk/s < 30 engage")
end)

t.test("PRE (tiltBrake disabled) never auto tilt-brakes even fast", function()
  local Pilot = require("fcs.input.pilot")
  local feel = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                 swaySpeed=5, swayLead=10, tiltBrake={ enabled=false, engageSpeed=30, satSpeed=100,
                 minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 } }
  local p = Pilot.new(feel)
  p:setMode({ tilt=false, surge="position" }, feel); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "PRE stays level")
end)
