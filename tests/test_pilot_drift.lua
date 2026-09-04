-- tests/test_pilot_drift.lua
local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")

local function feel()
  return { headingRate = 2.2, leadCapHeading = 0.45, yawStopLead = 0.15, climbRate = 4.5,
           leadCapVert = 8.0, surgeSpeed = 10.0, surgeLead = 20.0, swaySpeed = 5.0, swayLead = 10.0,
           climbRampTime = 1.0, climbBoost = 2.0, trimGain = 0.35 }
end
local function meas() return { altitude = 0, heading = 0, swayPos = 3, surgePos = 4,
  swayVel = 0, surgeVel = 0, yawRate = 0 } end

t.test("CPL hands-off holds station; DCPL hands-off relaxes to measured (coast)", function()
  -- CPL: driftArrest true. Setpoint frozen away from measured stays put (loop will drive to it).
  local p = Pilot.new(feel()); p:setMode({ tilt = false, surge = "position" }, feel()); p:setMaster(true)
  p.sp.swayPos, p.sp.surgePos = 0, 0     -- a standing hold target != measured (3,4)
  local sp = p:update(0.05, {}, meas())
  t.eq(sp.swayPos, 0, "CPL holds sway setpoint")
  t.eq(sp.surgePos, 0, "CPL holds surge setpoint")
  -- DCPL: driftArrest false. Hands-off snaps setpoint to measured -> zero error -> coast.
  local q = Pilot.new(feel()); q:setMode({ tilt = false, surge = "position" }, feel()); q:setMaster(false)
  q.sp.swayPos, q.sp.surgePos = 0, 0
  local sq = q:update(0.05, {}, meas())
  t.eq(sq.swayPos, 3, "DCPL relaxes sway to measured")
  t.eq(sq.surgePos, 4, "DCPL relaxes surge to measured")
end)

t.test("tilting relaxes horizontal hold under CPL (generalized relaxTiltDrift), any tilt mode", function()
  local p = Pilot.new(feel()); p:setMode({ tilt = true, surge = "position" }, feel()); p:setMaster(true)
  p.sp.swayPos, p.sp.surgePos = 0, 0
  local sp = p:update(0.05, { pitchUp = true }, meas())   -- actively tilting
  t.eq(sp.swayPos, 3, "tilt relaxes sway to measured")
  t.eq(sp.surgePos, 4, "tilt relaxes surge to measured")
end)

t.test("climb ramp is always on: sustained hold exceeds a single-tick nudge", function()
  local p = Pilot.new(feel()); p:setMode({ tilt = false, surge = "position" }, feel()); p:setMaster(true)
  local m = meas()
  local tap = Pilot.new(feel()); tap:setMode({ tilt = false, surge = "position" }, feel()); tap:setMaster(true)
  local a1 = tap:update(0.05, { up = true }, m).altitude       -- first tick (tap)
  -- hold for ~1s of ramp on a fresh pilot
  local held = 0
  for _ = 1, 20 do held = p:update(0.05, { up = true }, m).altitude end
  t.truthy((held - m.altitude) > (a1 - m.altitude), "ramped climb outpaces the first-tick nudge")
end)

t.test("brake button forces surge arrest even under DCPL", function()
  local Pilot = require("fcs.input.pilot")
  local feel = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                 swaySpeed=5, swayLead=10, tiltBrake={ enabled=false, engageSpeed=30, satSpeed=100,
                 minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 } }
  local m = { altitude=10, heading=0, swayPos=0, surgePos=0, surgeVel=5, swayVel=0, pitch=0, roll=0, yawRate=0 }
  local p = Pilot.new(feel)
  p:setMode({ tilt=false, surge="position" }, feel); p:setMaster(false); p:reset(m)  -- DCPL
  -- DCPL normally relaxes uncommanded surge to meas (coast); brake button must hold it instead
  local mDrift = { altitude=10, heading=0, swayPos=0, surgePos=7, surgeVel=5, swayVel=0, pitch=0, roll=0, yawRate=0 }
  local sp = p:update(0.05, { brake=true }, mDrift)
  t.near(sp.surgePos, 0, 0.5, "brake holds reset position under DCPL (no coast to 7)")
end)
