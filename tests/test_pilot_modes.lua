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
-- than chasing a coasting measured position.
t.test("CRUISE throttle policy leashes surgePos (holds station) once throttle returns to 0", function()
  local p = Pilot.new(FEEL)
  p:setMode({ tilt = false, surge = "throttle" }, FEEL)
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 0 })
  local meas = { altitude = 0, heading = 0, swayPos = 0, surgePos = 0, yawRate = 0 }
  p:update(0.2, { surgeFwd = true }, meas)          -- ramp throttle up
  meas.surgePos = 10                                -- craft has moved forward while throttling
  p:update(0.2, {}, meas)                           -- release: throttle holds, still >0, pins to meas
  p:update(0.5, { surgeBack = true }, meas)          -- ramp throttle back down to 0
  local sp = p:update(0.1, {}, meas)                -- throttle now 0 at entry: leash branch holds
  t.near(sp.surgePos, meas.surgePos, 1e-9, "surgePos held at current station, not re-pinned each tick")
end)
