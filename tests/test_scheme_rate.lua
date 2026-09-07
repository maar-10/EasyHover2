local t = require("tests.framework")
local Level = require("fcs.schemes.level_flight")

t.test("scheme altitude rate: heave = hover + kv*(climbCmd - vSpeed), banded", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0.15, kv = 0.06 }, pitch = {}, roll = {}, yaw = {}, sway = {}, surge = {} })
  local d = sc:update({ climbCmd = 8, altitude = 100 },
    { altitude = 100, vSpeed = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 8, 1e-9, "velocity controller drives heave up from rest")
  local d2 = sc:update({ climbCmd = 8, altitude = 100 },
    { altitude = 120, vSpeed = 8, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d2.heave, 0.26, 1e-9, "at target rate heave settles to hover (no rail)")
end)

t.test("scheme yaw/sway rate paths use the controllers' :rate()", function()
  local sc = Level.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {},
    yaw = { kd = 1.8, kw = 0.8 }, sway = { kp = 0.2, ks = 0.4 }, surge = {} })
  local d = sc:update({ yawCmd = 1.5, strafeCmd = 6, altitude = 0 },
    { yawRate = 0.5, swayVel = 2, heading = 0, swayPos = 0, pitch = 0, roll = 0, altitude = 0 },
    0.05, false, {})
  t.near(d.yaw, 0.8 * (1.5 - 0.5), 1e-9, "yaw uses rate path")
  t.near(d.sway, 0.4 * (6 - 2), 1e-9, "sway uses rate path")
end)

t.test("scheme falls back to velocity-limited hold when no rate cmd present", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0, kv = 0.06 }, pitch = {}, roll = {},
    yaw = { kp = 0.95, kd = 0 }, sway = { ks = 0.4, ka = 1.0 }, surge = { ks = 0.4, ka = 1.0 } })
  local d = sc:update({ altitude = 105, heading = 0.2, swayPos = 1, surgePos = 2, swayVmax = 6, surgeVmax = 6 },
    { altitude = 100, vSpeed = 0, heading = 0, swayPos = 0, surgePos = 0, yawRate = 0,
      swayVel = 0, surgeVel = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 5, 1e-9, "alt hold = hover + kp*err (position PID)")
  t.near(d.yaw, 0.95 * 0.2, 1e-9, "yaw hold = kp*err (heading PID)")
  -- sway: err=1, vel=0 -> velTarget=min(1,6)=1 -> 0.4*(1-0)=0.4
  t.near(d.sway, 0.4 * 1, 1e-9, "sway hold = ks*(clamp(ka*err,vmax) - vel)")
  -- surge: err=2, vel=0 -> velTarget=min(2,6)=2 -> 0.4*(2-0)=0.8
  t.near(d.surge, 0.4 * 2, 1e-9, "surge hold = ks*(clamp(ka*err,vmax) - vel)")
end)

t.test("scheme hold honors sp.swayVmax / sp.surgeVmax speed cap", function()
  local sc = Level.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {},
    sway = { ks = 0.5, ka = 1.0 }, surge = { ks = 0.5, ka = 1.0 } })
  local d = sc:update({ altitude = 0, swayPos = 10, surgePos = 10, swayVmax = 3, surgeVmax = 3 },
    { altitude = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0,
      heading = 0, yawRate = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.sway, 0.5 * 3, 1e-9, "sway clamped to vmax=3")
  t.near(d.surge, 0.5 * 3, 1e-9, "surge clamped to vmax=3")
end)

t.test("scheme falls back to DEFAULT_HOLD_VMAX when sp omits swayVmax/surgeVmax", function()
  -- Non-pilot setpoint sources (comAuto trim, EMRCVR handback) don't publish
  -- swayVmax/surgeVmax. With a large displacement the hold must still clamp to the
  -- scheme's safety-floor DEFAULT_HOLD_VMAX (6.0), NOT go unbounded (0.5*20=10).
  local sc = Level.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {},
    sway = { ks = 0.5, ka = 1.0 }, surge = { ks = 0.5, ka = 1.0 } })
  local d = sc:update({ altitude = 0, swayPos = 20, surgePos = 20 },
    { altitude = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0,
      heading = 0, yawRate = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.sway, 3.0, 1e-9, "sway clamped to the DEFAULT_HOLD_VMAX=6.0 floor (0.5*6.0=3.0), not unbounded 0.5*20=10")
  t.near(d.surge, 3.0, 1e-9, "surge clamped to the DEFAULT_HOLD_VMAX=6.0 floor (0.5*6.0=3.0), not unbounded 0.5*20=10")
end)
