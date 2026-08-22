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

-- ---- device read-back reconciliation (design §7) ----
t.test("reportDeviceLevel: agreement dispatches nothing", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0)                       -- intent level 8
  t.eq(b.writes, 1)
  t.eq(a:reportDeviceLevel("FL", 8), false)      -- device agrees (raw scale)
  t.eq(b.writes, 1)
  t.eq(a:reportDeviceLevel("FL", 8/15), false)   -- agrees in normalized scale too
  t.eq(b.writes, 1)
end)

t.test("reportDeviceLevel: disagreement re-asserts the intended level", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0)                       -- intent 8; suppose a second writer dropped it to 3
  t.truthy(a:reportDeviceLevel("FL", 3), "reports a heal")
  t.eq(b.level.FL, 8, "intent re-asserted")
  t.eq(a:state("FL"), 8, "internal state unchanged")
end)

t.test("reportDeviceLevel: unseen id treats intent as 0 (heals stuck-on while disarmed)", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  t.truthy(a:reportDeviceLevel("RR", 12))
  t.eq(b.level.RR, 0)
end)

t.test("reportDeviceLevel: NaN/inf readings are ignored", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0.5 }, 0)
  t.eq(a:reportDeviceLevel("FL", 0/0), false)
  t.eq(a:reportDeviceLevel("FL", math.huge), false)
  t.eq(a:reportDeviceLevel("FL", "junk"), false)
  t.eq(b.writes, 1)
end)

t.test("reportDeviceLevel: normalized-scale disagreement quantizes before comparing", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  a:apply({ FL = 0 }, 0)                          -- intent 0
  t.eq(a:reportDeviceLevel("FL", 0.2), true)      -- 0.2*15 = 3 -> disagree
  t.eq(b.level.FL, 0)
end)
