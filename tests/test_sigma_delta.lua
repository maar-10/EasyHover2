local t = require("tests.framework")
local SigmaDelta = require("fcs.actuate.sigma_delta")
local function recBackend()
  local b = { writes = 0, on = {} }
  function b:setThruster(id, s) self.writes = self.writes + 1; self.on[id] = s end
  return b
end
t.test("duty 1 always on, duty 0 always off", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  for _ = 1, 20 do sd:apply({ a = 1.0, z = 0.0 }, 0.1) end
  t.truthy(sd:state("a") == true); t.truthy(sd:state("z") == false)
end)
t.test("average on-fraction tracks a fractional duty", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 400
  for _ = 1, N do sd:apply({ a = 0.25 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.25, 0.02)              -- density matches duty
end)
t.test("resolves a small duty the coarse PWM would quantise away", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local onCount, N = 0, 1000
  for _ = 1, N do sd:apply({ a = 0.05 }, 0.1); if sd:state("a") then onCount = onCount + 1 end end
  t.near(onCount / N, 0.05, 0.02)              -- ~5% density, not 0 and not 33%
end)
t.test("sigma_delta: fuelScale scales the on-duty rate", function()
  -- duty 0.25 @ dt 0.1 accumulates 0.025/tick -> baseline (scale 1.0) crosses the dt threshold at tick 4.
  local b1 = recBackend(); local sd1 = SigmaDelta.new({ backend = b1 })
  local ticks1 = 0
  for _ = 1, 10 do
    ticks1 = ticks1 + 1
    sd1:apply({ a = 0.25 }, 0.1)
    if sd1:state("a") then break end
  end
  t.eq(ticks1, 4, "baseline (scale 1.0) turns on at tick 4")

  -- scale 2.0 doubles the accumulation rate -> crosses the threshold in half the ticks.
  local b2 = recBackend(); local sd2 = SigmaDelta.new({ backend = b2 })
  sd2:setFuelScale(2.0)
  local ticks2 = 0
  for _ = 1, 10 do
    ticks2 = ticks2 + 1
    sd2:apply({ a = 0.25 }, 0.1)
    if sd2:state("a") then break end
  end
  t.eq(ticks2, 2, "scale 2.0 turns on in half the ticks")
end)
t.test("planWrites returns closures for changed thruster state without dispatching", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  local w = sd:planWrites({ a = 1.0, z = 0.0 }, 0.1)
  t.eq(#w, 2, "two changed states planned")
  t.eq(b.writes, 0, "nothing written yet (not dispatched)")
  for i = 1, #w do w[i]() end
  t.truthy(b.on.a == true); t.truthy(b.on.z == false)
end)
t.test("sigma_delta: setFuelScale ignores nil/non-positive values", function()
  local b = recBackend(); local sd = SigmaDelta.new({ backend = b })
  sd:setFuelScale(nil)
  sd:setFuelScale(0)
  sd:setFuelScale(-1)
  local ticks = 0
  for _ = 1, 10 do
    ticks = ticks + 1
    sd:apply({ a = 0.25 }, 0.1)
    if sd:state("a") then break end
  end
  t.eq(ticks, 4, "invalid scale calls leave default 1.0 in effect")
end)
