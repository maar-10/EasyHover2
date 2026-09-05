local t = require("tests.framework")
local Pilot = require("fcs.input.pilot")

local CFG = { headingRate = 1.0, climbRate = 0.5, leadCapVert = 2.0,
              cruiseSpeed = 1.0, maxLead = 3.0 }
local function meas(o) o = o or {}
  return { altitude = o.altitude or 10, heading = o.heading or 0,
           swayPos = o.swayPos or 0, surgePos = o.surgePos or 0 }
end

t.test("reset seeds setpoints to current craft state", function()
  local p = Pilot.new(CFG)
  local sp = p:reset(meas{altitude=12, heading=0.3, swayPos=1, surgePos=-2})
  t.eq(sp.altitude, 12); t.eq(sp.heading, 0.3)
  t.eq(sp.swayPos, 1); t.eq(sp.surgePos, -2)
end)

t.test("yaw held ramps heading by headingRate*dt, wrapped", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(0.5, {yawRight=true}, meas())
  t.near(sp.heading, 0.5, 1e-9, "heading +0.5")
  sp = p:update(0.5, {yawLeft=true}, meas())
  t.near(sp.heading, 0.0, 1e-9, "back to 0")
end)

t.test("yaw held is leashed to leadCapHeading ahead of current heading", function()
  local p = Pilot.new({ headingRate = 1.0, leadCapHeading = 0.35,
    climbRate = 0.5, leadCapVert = 2.0, cruiseSpeed = 1.0, maxLead = 3.0 }); p:reset(meas())
  -- would ramp +3 rad, but must clamp to meas.heading(0) + leadCapHeading(0.35)
  local sp = p:update(3.0, {yawRight=true}, meas{heading=0})
  t.near(sp.heading, 0.35, 1e-9, "clamped to +leadCapHeading")
  -- as the craft yaws to catch up, the setpoint may lead again but stays within the cap
  sp = p:update(3.0, {yawRight=true}, meas{heading=0.30})
  t.near(sp.heading, 0.65, 1e-9, "leads current(0.30) by at most the cap")
end)

t.test("lift held ramps altitude, leashed to meas.alt +/- leadCapVert", function()
  local p = Pilot.new(CFG); p:reset(meas{altitude=10})
  -- climbRate 0.5 * dt 10 = +5 requested, but leashed to alt(10)+leadCapVert(2)=12
  local sp = p:update(10, {up=true}, meas{altitude=10})
  t.near(sp.altitude, 12, 1e-9, "clamped to +leadCapVert")
end)

t.test("sway held ramps swayPos at cruiseSpeed, clamped to maxLead", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {swayRight=true}, meas())   -- +1 (cruise 1 * dt 1)
  t.near(sp.swayPos, 1.0, 1e-9, "swayPos +1")
  sp = p:update(10, {swayRight=true}, meas())           -- would be +10, clamped to maxLead 3
  t.near(sp.swayPos, 3.0, 1e-9, "clamped to maxLead")
end)

t.test("surge forward increases surgePos (fwd = main thrust)", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {surgeFwd=true}, meas())
  t.near(sp.surgePos, 1.0, 1e-9, "surgePos +1")
end)

t.test("release holds setpoints where they are", function()
  local p = Pilot.new(CFG); p:reset(meas())
  p:update(1.0, {swayRight=true}, meas())
  -- craft has not moved (meas.swayPos still 0); releasing keeps sp at 1
  local sp = p:update(1.0, {}, meas{swayPos=0.5})
  t.near(sp.swayPos, 1.0, 1e-9, "held at 1")
end)

t.test("yaw release captures current heading + predictive stop, dropping the leashed lead", function()
  local CFG2 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, yawStopLead = 0.1 }
  local p = Pilot.new(CFG2); p:reset(meas())
  -- hold yaw right: setpoint leads meas.heading(0) by leadCapHeading(0.35)
  local held = p:update(3.0, {yawRight=true},
    { altitude=10, heading=0, swayPos=0, surgePos=0, yawRate=0.5 })
  t.near(held.heading, 0.35, 1e-9, "held: leashed 0.35 ahead of current")
  -- release at meas.heading=0.2, yawRate=0.5 -> capture 0.2 + 0.1*0.5 = 0.25 (NOT the 0.35 lead)
  local rel = p:update(0.1, {},
    { altitude=10, heading=0.2, swayPos=0, surgePos=0, yawRate=0.5 })
  t.near(rel.heading, 0.25, 1e-9, "release: current + predictive stop, not the leashed lead")
  t.truthy(rel.heading < held.heading, "setpoint drops behind the held lead -> no oversteer")
end)

t.test("yaw release is edge-triggered: a settled release holds heading and fights drift", function()
  local CFG2 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, yawStopLead = 0.0 }
  local p = Pilot.new(CFG2); p:reset(meas())
  p:update(1.0, {yawRight=true}, { altitude=10, heading=0, swayPos=0, surgePos=0, yawRate=0.3 })
  local r1 = p:update(0.1, {}, { altitude=10, heading=0.3, swayPos=0, surgePos=0, yawRate=0.1 })
  t.near(r1.heading, 0.3, 1e-9, "captured current heading (0.3) on the release edge")
  -- next released tick: heading drifts to 0.5, but the setpoint must STAY 0.3 (PID fights drift),
  -- not re-capture to the drifted heading.
  local r2 = p:update(0.1, {}, { altitude=10, heading=0.5, swayPos=0, surgePos=0, yawRate=0.1 })
  t.near(r2.heading, 0.3, 1e-9, "held at 0.3, not re-tracking the 0.5 drift")
end)

t.test("altitude release captures current alt + predictive stop, dropping the leashed lead (fix #9)", function()
  local CFG3 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, altStopLead = 0.1 }
  local p = Pilot.new(CFG3); p:reset(meas())
  -- hold climb: sp.altitude leads meas.altitude(10) by leadCapVert(2) -> 12
  -- (dt=10 so the requested climb (climbRate*dt=5) overshoots the cap and gets clamped)
  local held = p:update(10.0, {up=true},
    { altitude=10, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(held.altitude, 12, 1e-9, "held: leashed +leadCapVert ahead")
  -- release at meas.altitude=11, vSpeed=1 -> capture 11 + 0.1*1 = 11.1 (NOT the 12 lead)
  local rel = p:update(0.1, {},
    { altitude=11, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(rel.altitude, 11.1, 1e-9, "release: current + predictive stop, not the leashed lead")
  t.truthy(rel.altitude < held.altitude, "setpoint drops behind the held lead -> no bounce")
end)

t.test("altitude release is edge-triggered: settled release holds alt, fights drift (fix #9)", function()
  local CFG3 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, altStopLead = 0.0 }
  local p = Pilot.new(CFG3); p:reset(meas())
  p:update(1.0, {up=true}, { altitude=10, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  local r1 = p:update(0.1, {}, { altitude=11, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(r1.altitude, 11, 1e-9, "captured current alt (11) on the release edge")
  local r2 = p:update(0.1, {}, { altitude=13, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(r2.altitude, 11, 1e-9, "held at 11, not re-tracking the 13 drift")
end)

t.test("position hold freezes setpoints and ignores held", function()
  local p = Pilot.new(CFG); p:reset(meas{heading=0.2, swayPos=1})
  p:setPositionHold(true)
  local sp = p:update(1.0, {yawRight=true, swayRight=true}, meas())
  t.near(sp.heading, 0.2, 1e-9, "heading frozen")
  t.near(sp.swayPos, 1.0, 1e-9, "sway frozen")
end)
