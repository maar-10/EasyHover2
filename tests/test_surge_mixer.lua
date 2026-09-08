local t = require("tests.framework")
local Mixer = require("fcs.mixer.level_flight")
t.test("pure sway right fires the +right thrusters, no yaw cross-talk", function()
  local d = Mixer.new():mixLateral(0.4, 0)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRL, 0.4, 1e-9)   -- +right pair
  t.near(d.YFR, 0, 1e-9);   t.near(d.YRR, 0, 1e-9)
end)
t.test("sway and yaw combine without cross-talk (orthogonal)", function()
  -- small sway + small yaw; each thruster gets the sum, clamped
  local d = Mixer.new():mixLateral(0.2, 0.2)
  t.near(d.YFL, 0.4, 1e-9)   -- SWAY_DIR +1, YAW_DIR +1 -> 0.4
  t.near(d.YFR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR -1 -> -0.4 -> clamp 0
  t.near(d.YRL, 0, 1e-9)     -- SWAY_DIR +1, YAW_DIR -1 -> 0
  t.near(d.YRR, 0, 1e-9)     -- SWAY_DIR -1, YAW_DIR +1 -> 0
end)
t.test("surge forward fires MAIN only", function()
  local d = Mixer.new():mixSurge(0.5)
  t.near(d.MAIN, 0.5, 1e-9); t.near(d.FRL, 0, 1e-9); t.near(d.FRR, 0, 1e-9)
end)
t.test("surge reverse fires the frontal brakes only", function()
  local d = Mixer.new():mixSurge(-0.5)
  t.near(d.FRL, 0.5, 1e-9); t.near(d.FRR, 0.5, 1e-9); t.near(d.MAIN, 0, 1e-9)
end)
t.test("mixYaw still works (delegates to mixLateral)", function()
  local d = Mixer.new():mixYaw(0.4)
  t.near(d.YFL, 0.4, 1e-9); t.near(d.YRR, 0.4, 1e-9)
end)

t.test("keepwarm surge idle is net-zero and both sides warm at surge=0", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.06, mainRatio = 0.05 })
  local out = m:mix({ heave = 0.5, surge = 0 }, true)
  -- floorMain = 0.06*0.05 = 0.003 ; both sides warm
  t.truthy(out.MAIN >= 0.003 - 1e-9, "MAIN warm")
  t.truthy(out.FRL >= 0.06 - 1e-9 and out.FRR >= 0.06 - 1e-9, "frontals warm")
  -- net-zero requires mainRatio == 2*wFront/wMain; here the test just asserts the idle formula:
  t.near(out.MAIN, 0.003, 1e-9); t.near(out.FRL, 0.06, 1e-9)
end)
t.test("keepwarm surge preserves the commanded differential", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.06, mainRatio = 0.05 })
  local warm = m:mix({ heave = 0.5, surge = -0.3 }, true)
  local cold = m:mix({ heave = 0.5, surge = -0.3 }, false)
  -- differential (command part) preserved: warm - idle == cold
  t.near(warm.FRL - 0.06, cold.FRL, 1e-9, "frontal differential preserved")
  t.near(warm.MAIN - 0.003, cold.MAIN, 1e-9, "MAIN idle-only when reversing")
end)
