-- tests/test_scheme_manual.lua
local t = require("tests.framework")
local Manual = require("fcs.schemes.manual")
local Level  = require("fcs.schemes.level_flight")
local cfg = { hoverDuty = 0.26, alt = {kp=0.02,ki=0.01,kd=0.15,tauD=0.35},
  pitch = {kp=0.1,kd=0.22}, roll = {kp=0.1,kd=0.22}, yaw = {kp=0.95,kd=1.0},
  sway = { ks = 0.4, ka = 1.0 }, surge = { ks = 0.4, ka = 1.0 }, heaveMin = 0.05, heaveMax = 0.85 }

t.test("MAN now passes lateral through (full Level loop) while keeping heave/pitch/roll/yaw", function()
  local man, lvl = Manual.new(cfg), Level.new(cfg)
  local sp = { altitude = 5, pitch = 0.3, roll = -0.2, heading = 0.5,
    swayPos = 6, surgePos = 6 }
  local m = { altitude = 2, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    swayPos = 3, swayVel = 1, surgePos = 3, surgeVel = 1 }
  local dm = man:update(sp, m, 0.05, false)
  local dl = lvl:update(sp, m, 0.05, false)
  t.truthy(dl.sway ~= 0, "sanity: Level produces nonzero sway for this error")
  t.near(dm.sway,  dl.sway,  1e-9, "sway now matches Level (position loop lives)")
  t.near(dm.surge, dl.surge, 1e-9, "surge now matches Level")
  t.near(dm.heave, dl.heave, 1e-9, "heave matches level")
  t.near(dm.pitch, dl.pitch, 1e-9, "pitch passes through (tilt setpoint honored)")
  t.near(dm.roll, dl.roll, 1e-9, "roll passes through")
  t.near(dm.yaw, dl.yaw, 1e-9, "yaw matches level")
end)
