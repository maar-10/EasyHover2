local t = require("tests.framework")
local Level = require("fcs.actuate.level")

local function fakeBackend()
  local b = { writes = 0, level = {} }
  function b:setThrusterLevel(id, lvl) self.writes = self.writes + 1; self.level[id] = lvl end
  return b
end

t.test("quantizes duty to 0..steps levels (round half up)", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0, FR = 1, RL = 0.5, RR = 0.2 }, 0)
  t.eq(b.level.FL, 0); t.eq(b.level.FR, 15); t.eq(b.level.RL, 8); t.eq(b.level.RR, 3)
end)
t.test("clamps out-of-range duty", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ H = 1.2, L = -0.1 }, 0)
  t.eq(b.level.H, 15); t.eq(b.level.L, 0)
end)
t.test("writes only when the quantized level changes", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- level 8, write #1
  a:apply({ FL = 0.5 }, 0);  t.eq(b.writes, 1)   -- same -> no write
  a:apply({ FL = 0.52 }, 0); t.eq(b.writes, 1)   -- 7.8 -> round 8 -> still 8 -> no write
  a:apply({ FL = 0.6 }, 0);  t.eq(b.writes, 2)   -- 9.0 -> level 9 -> write #2
end)
t.test("state returns the last written level, 0 if unseen", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 1 }, 0)
  t.eq(a:state("FL"), 15); t.eq(a:state("XX"), 0)
end)
-- The writes must be dispatched CONCURRENTLY so N thruster changes cost ~1 server tick, not N
-- (Flight #6: sequential writes collapsed the loop to ~3Hz mid-maneuver; the in-game probe
-- confirmed concurrent dispatch stays flat at one tick). The dispatcher is injectable so the
-- batching contract can be asserted without real timing.
t.test("dispatches all changed levels as one concurrent batch", function()
  local b = fakeBackend()
  local batches = {}
  local a = Level.new({ backend = b, steps = 15,
    dispatch = function(fns) batches[#batches + 1] = #fns; for i = 1, #fns do fns[i]() end end })
  a:apply({ FL = 1.0, FR = 0.0, RL = 0.5 }, 0.05)
  t.eq(#batches, 1, "exactly one dispatch call")
  t.eq(batches[1], 3, "all three changed writes handed over together")
  t.eq(b.level.FL, 15); t.eq(b.level.RL, 8)
end)
t.test("unchanged levels are excluded from the batch", function()
  local b = fakeBackend()
  local sizes = {}
  local a = Level.new({ backend = b, steps = 15,
    dispatch = function(fns) sizes[#sizes + 1] = #fns; for i = 1, #fns do fns[i]() end end })
  a:apply({ FL = 1.0 }, 0.05)
  a:apply({ FL = 1.0 }, 0.05)
  t.eq(sizes[1], 1, "first apply dispatches the one change")
  t.eq(sizes[2], 0, "second apply dispatches nothing")
end)
t.test("level: fuelScale scales the quantized output", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:setFuelScale(0.3)
  a:apply({ t1 = 0.5 }, 0.05)          -- 0.5*0.3*15 = 2.25 -> quantize 2
  t.eq(b.level.t1, 2, "strong fuel scales down")
  a:setFuelScale(3.0)
  a:apply({ t1 = 0.5 }, 0.05)          -- 0.5*3*15 = 22.5 -> clamps to 15
  t.eq(b.level.t1, 15, "weak fuel clamps at max")
end)
t.test("level: fuelScale 1.0 == baseline behaviour", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ t1 = 0.26 }, 0.05)         -- 0.26*15 = 3.9 -> 4, unchanged from pre-fuelScale behaviour
  t.eq(b.level.t1, 4, "default fuelScale reproduces baseline")
end)
t.test("level: setFuelScale ignores nil/non-positive values", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:setFuelScale(nil)
  a:setFuelScale(0)
  a:setFuelScale(-1)
  a:apply({ t1 = 0.26 }, 0.05)
  t.eq(b.level.t1, 4, "invalid scale calls leave default 1.0 in effect")
end)
t.test("planWrites returns closures for changed levels without dispatching", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  local w = a:planWrites({ FL = 1.0, FR = 0.0 })
  t.eq(#w, 2, "two changed levels planned")
  t.eq(b.writes, 0, "nothing written yet (not dispatched)")
  for i = 1, #w do w[i]() end            -- execute the closures
  t.eq(b.level.FL, 15); t.eq(b.level.FR, 0)
  local w2 = a:planWrites({ FL = 1.0 })  -- unchanged -> no closure
  t.eq(#w2, 0, "unchanged level plans no write")
end)
