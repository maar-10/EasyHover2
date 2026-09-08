-- tests/test_buildloop_modes.lua
local t = require("tests.framework")
local hover = require("tools.hover_test")

t.test("buildLoop returns a loop plus the mode registry, LDG active", function()
  local backend = { sensors = function() return { onGround = true } end }
  local loop, reg = hover.buildLoop(backend)
  t.truthy(loop and reg, "returns loop and registry")
  t.eq(reg.default, "LDG", "default mode LDG")
  t.truthy(reg.byId.PRECISION and reg.byId.MAN and reg.byId.CRUISE, "all modes present")
  t.truthy(reg.byId.LDG and reg.byId.DRN, "LDG/DRN present")
  t.eq(loop.scheme, reg.byId.LDG.scheme, "loop starts on LDG scheme")
end)

t.test("buildLoop: registry has five flight modes and no CPL/DCPL", function()
  local backend = { sensors = function() return { onGround = false } end }
  local _, reg = hover.buildLoop(backend)
  t.eq(#reg.order, 5, "five flight modes from buildLoop")
  t.eq(reg.byId.CPL, nil, "no CPL")
end)

t.test("buildLoop routes lift to Level and the rest group to a keep-warm actuator", function()
  local hover = require("tools.hover_test")
  local seen = { level = {}, warm = {} }
  local backend = {
    setThrusterLevel = function(_, id, l) seen.level[id] = l end,
    setThrusterNormalized = function(_, id, v) seen.warm[id] = v end,
    sensors = function() return { onGround = false, pitch = 0, roll = 0, heading = 0, yawRate = 0,
      altitude = 0, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 } end,
    liftIds = function() return { "FL","FR","RL","RR" } end,
    lateralIds = function() return { "YFL","YFR","YRL","YRR" } end,
    mainIds = function() return { "MAIN" } end,
    frontalIds = function() return { "FRL","FRR" } end,
  }
  local loop = hover.buildLoop(backend)
  loop:setpoints({ altitude = 0, pitch = 0, roll = 0, heading = 0, swayPos = 0, surgePos = 0 })
  loop:arm(true)
  loop:cycle(0.05, backend:sensors())
  t.truthy(next(seen.level) ~= nil, "lift thrusters written via setThrusterLevel")
  t.truthy(seen.warm.YFL ~= nil or seen.warm.MAIN ~= nil, "rest thrusters written via setPowerNormalized")
end)
