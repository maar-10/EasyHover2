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

t.test("scheme falls back to position-hold PIDs when no rate cmd present", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0, kv = 0.06 }, pitch = {}, roll = {},
    yaw = { kp = 0.95, kd = 0 }, sway = { kp = 0.2, kd = 0 }, surge = {} })
  local d = sc:update({ altitude = 105, heading = 0.2, swayPos = 1 },
    { altitude = 100, vSpeed = 0, heading = 0, swayPos = 0, yawRate = 0, swayVel = 0,
      pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 5, 1e-9, "alt hold = hover + kp*err (position PID)")
  t.near(d.yaw, 0.95 * 0.2, 1e-9, "yaw hold = kp*err (heading PID)")
  t.near(d.sway, 0.2 * 1, 1e-9, "sway hold = kp*err (translate PID)")
end)
