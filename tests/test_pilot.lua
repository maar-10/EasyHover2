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

t.test("yaw held commands a yaw RATE (yawCmd = headingRate * dir)", function()
  local p = Pilot.new({ headingRate = 1.2, climbRate = 1, swaySpeed = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas())
  local sp = p:update(0.05, {yawRight=true}, meas{heading=0})
  t.near(sp.yawCmd, 1.2, 1e-9, "right -> +headingRate")
  sp = p:update(0.05, {yawLeft=true}, meas{heading=0})
  t.near(sp.yawCmd, -1.2, 1e-9, "left -> -headingRate")
end)

t.test("yaw release clears yawCmd and captures current heading", function()
  local p = Pilot.new({ headingRate = 1.2, climbRate = 1, swaySpeed = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas())
  p:update(0.05, {yawRight=true}, meas{heading=0.3})
  local sp = p:update(0.05, {}, meas{heading=0.5})
  t.eq(sp.yawCmd, nil, "released -> no rate command")
  t.near(sp.heading, 0.5, 1e-9, "heading captured to current")
end)

t.test("lift held commands a climb RATE (climbCmd), not a leashed setpoint", function()
  local p = Pilot.new({ climbRate = 8, headingRate = 1, swaySpeed = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas{altitude=100})
  local sp = p:update(0.05, {up=true}, meas{altitude=100, vSpeed=3})
  t.near(sp.climbCmd, 8, 1e-9, "up held -> climbCmd = +climbRate")
  sp = p:update(0.05, {down=true}, meas{altitude=100})
  t.near(sp.climbCmd, -8, 1e-9, "down held -> climbCmd = -climbRate")
end)

t.test("lift release clears climbCmd and captures current altitude (bumpless hold)", function()
  local p = Pilot.new({ climbRate = 8, headingRate = 1, swaySpeed = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas{altitude=100})
  p:update(0.05, {up=true}, meas{altitude=100})
  local sp = p:update(0.05, {}, meas{altitude=137})
  t.eq(sp.climbCmd, nil, "released -> no rate command")
  t.near(sp.altitude, 137, 1e-9, "hold setpoint captured to current altitude")
end)

t.test("sway held commands a lateral velocity (strafeCmd)", function()
  local p = Pilot.new({ swaySpeed = 6, headingRate = 1, climbRate = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas())
  local sp = p:update(0.05, {swayRight=true}, meas{swayVel=2})
  t.near(sp.strafeCmd, 6, 1e-9, "right -> +swaySpeed")
  sp = p:update(0.05, {swayLeft=true}, meas())
  t.near(sp.strafeCmd, -6, 1e-9, "left -> -swaySpeed")
end)

t.test("surge forward increases surgePos (fwd = main thrust)", function()
  local p = Pilot.new(CFG); p:reset(meas())
  local sp = p:update(1.0, {surgeFwd=true}, meas())
  t.near(sp.surgePos, 1.0, 1e-9, "surgePos +1")
end)

t.test("sway release clears strafeCmd and holds captured swayPos under CPL", function()
  local p = Pilot.new({ swaySpeed = 6, headingRate = 1, climbRate = 1, cruiseSpeed = 1, maxLead = 3 })
  p:reset(meas())
  p:setMaster(true)                                      -- CPL: arrest drift
  p:update(0.05, {swayRight=true}, meas{swayPos=0})
  local sp = p:update(0.05, {}, meas{swayPos=1.5})
  t.eq(sp.strafeCmd, nil, "released -> no rate command")
  t.near(sp.swayPos, 1.5, 1e-9, "CPL captures current swayPos (arrest)")
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

-- Regression: engaging positionHold WHILE a rate key is still held (no release tick first) must
-- not leave stale climbCmd/yawCmd/strafeCmd on self.sp -- the scheme keeps taking the rate branch
-- forever otherwise (Finding 1). The hold must also be bumpless: since the rate-command path left
-- sp.altitude/heading/swayPos STALE during the maneuver, the captured hold target must be the
-- CURRENT measured pose, not that stale pre-hold value.
t.test("position hold engaged mid-hold clears stale *Cmd and captures the CURRENT pose (bumpless)", function()
  local p = Pilot.new(CFG); p:reset(meas{altitude=10, heading=0, swayPos=0})
  -- Hold climb/yaw/sway for a tick with no release tick before engaging hold: *Cmd fields are set.
  p:update(0.05, {up=true, yawRight=true, swayRight=true}, meas{altitude=10, heading=0, swayPos=0})
  p:setPositionHold(true)
  local sp = p:update(0.05, {up=true, yawRight=true, swayRight=true},
    meas{altitude=50, heading=1.2, swayPos=7})
  t.eq(sp.climbCmd, nil, "hold must clear stale climbCmd")
  t.eq(sp.yawCmd, nil, "hold must clear stale yawCmd")
  t.eq(sp.strafeCmd, nil, "hold must clear stale strafeCmd")
  t.near(sp.altitude, 50, 1e-9, "bumpless: captured to CURRENT altitude, not the stale pre-hold value")
  t.near(sp.heading, 1.2, 1e-9, "bumpless: captured to CURRENT heading")
  t.near(sp.swayPos, 7, 1e-9, "bumpless: captured to CURRENT swayPos")
end)
