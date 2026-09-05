local t = require("tests.framework")
local brake = require("fcs.brake")
local CFG = { engageSpeed = 30, satSpeed = 100, minAngle = 0.2618, maxAngle = 0.5236, buttonMax = 0.7854 }

t.test("angle: zero below engage, min at engage, max at/above sat (auto)", function()
  t.near(brake.angle(0, CFG), 0, 1e-9)
  t.near(brake.angle(29.999, CFG), 0, 1e-9)
  t.near(brake.angle(30, CFG), 0.2618, 1e-4, "min at engage")
  t.near(brake.angle(65, CFG), 0.2618 + 0.5*(0.5236-0.2618), 1e-4, "midpoint")
  t.near(brake.angle(100, CFG), 0.5236, 1e-4, "max at sat")
  t.near(brake.angle(500, CFG), 0.5236, 1e-4, "capped above sat")
end)

t.test("angle: button variant reaches buttonMax", function()
  t.near(brake.angle(30, CFG, true), 0.2618, 1e-4, "min at engage")
  t.near(brake.angle(100, CFG, true), 0.7854, 1e-4, "buttonMax at sat")
end)

t.test("angle: degenerate satSpeed<=engageSpeed treated as pure step (no NaN)", function()
  local DEG = { engageSpeed = 30, satSpeed = 30, minAngle = 0.2618, maxAngle = 0.5236, buttonMax = 0.7854 }
  local a
  a = brake.angle(29, DEG); t.eq(a, 0); t.truthy(a == a, "finite, not NaN")
  a = brake.angle(30, DEG); t.near(a, 0.5236, 1e-9, "step to max at engage"); t.truthy(a == a, "finite, not NaN")
  a = brake.angle(50, DEG); t.near(a, 0.5236, 1e-9, "stays at max above engage"); t.truthy(a == a, "finite, not NaN")
  a = brake.angle(30, DEG, true); t.near(a, 0.7854, 1e-9, "button step to buttonMax"); t.truthy(a == a, "finite, not NaN")
end)

t.test("vector: magnitude preserved and opposes drift", function()
  local p, r = brake.vector(0.5, 10, 0)          -- pure forward
  t.truthy(p > 0, "forward -> nose-up (pitch>0)")
  t.near(r, 0, 1e-9)
  t.near(math.sqrt(p*p + r*r), 0.5, 1e-6, "magnitude == theta")
  p, r = brake.vector(0.5, 0, 10)                -- pure right drift
  t.truthy(r < 0, "right drift -> bank left (roll<0)")
  t.near(p, 0, 1e-9)
  local p2, r2 = brake.vector(0.5, 6, 8)         -- diagonal (s=10)
  t.near(math.sqrt(p2*p2 + r2*r2), 0.5, 1e-6, "diagonal magnitude == theta")
end)

t.test("vector: zero theta or zero speed yields zero", function()
  local p, r = brake.vector(0, 10, 10); t.eq(p, 0); t.eq(r, 0)
  p, r = brake.vector(0.5, 0, 0); t.eq(p, 0); t.eq(r, 0)
end)
