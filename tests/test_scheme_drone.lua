-- tests/test_scheme_drone.lua
local t = require("tests.framework")
local Drone = require("fcs.schemes.drone")

t.test("DRN: attitude/alt pass through AND horizontal loop stabilizes a position error", function()
  local d = Drone.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {},
                        sway = { ks = 0.4, ka = 1.0 }, surge = { ks = 0.4, ka = 1.0 } })
  local sp = { pitch = 0.1, roll = -0.1, heading = 0, altitude = 5, swayPos = 10, surgePos = 10 }
  local m  = { pitch = 0, roll = 0, heading = 0, altitude = 5, swayPos = 0, surgePos = 0,
              swayVel = 0, surgeVel = 0, yawRate = 0 }
  local out = d:update(sp, m, 0.05, false, nil)
  -- horizontal error present -> the FCS commands a correction now (was forced to 0 before)
  t.truthy(out.sway ~= 0, "sway loop stabilizes (not forced 0)")
  t.truthy(out.surge ~= 0, "surge loop stabilizes (not forced 0)")
  t.truthy(out.pitch ~= nil and out.roll ~= nil, "attitude demands present")
  t.truthy(d.pitchPid ~= nil and d.rollPid ~= nil, "inner pids exposed for comAuto")
end)
