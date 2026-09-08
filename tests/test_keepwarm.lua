local t = require("tests.framework")
local KeepWarm = require("fcs.actuate.keepwarm")

local function fakeBackend()
  local b = { writes = 0, thr = {} }
  function b:setThrusterNormalized(id, v) self.writes = self.writes + 1; self.thr[id] = v end
  return b
end

t.test("passes continuous throttle straight through (no quantization)", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ YFL = 0.0, YFR = 0.333, MAIN = 0.003 }, 0.05)
  t.near(b.thr.YFL, 0.0, 1e-9); t.near(b.thr.YFR, 0.333, 1e-9); t.near(b.thr.MAIN, 0.003, 1e-9)
end)
t.test("clamps throttle to [0,1]", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ H = 1.4, L = -0.2 }, 0.05)
  t.near(b.thr.H, 1.0, 1e-9); t.near(b.thr.L, 0.0, 1e-9)
end)
t.test("writes only when throttle moves beyond tol", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b, tol = 0.01 })
  a:apply({ YFL = 0.20 }, 0.05); t.eq(b.writes, 1)   -- first write
  a:apply({ YFL = 0.205 }, 0.05); t.eq(b.writes, 1)  -- within tol -> no write
  a:apply({ YFL = 0.22 }, 0.05); t.eq(b.writes, 2)   -- beyond tol -> write
end)
t.test("fuelScale scales the throttle", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:setFuelScale(0.5)
  a:apply({ YFL = 0.4 }, 0.05)
  t.near(b.thr.YFL, 0.2, 1e-9, "0.4 * 0.5")
end)
t.test("setFuelScale ignores nil/non-positive", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:setFuelScale(nil); a:setFuelScale(0); a:setFuelScale(-1)
  a:apply({ YFL = 0.4 }, 0.05)
  t.near(b.thr.YFL, 0.4, 1e-9, "invalid scale leaves 1.0 in effect")
end)
t.test("dispatches changed writes as one concurrent batch", function()
  local b = fakeBackend(); local sizes = {}
  local a = KeepWarm.new({ backend = b,
    dispatch = function(fns) sizes[#sizes+1] = #fns; for i = 1, #fns do fns[i]() end end })
  a:apply({ YFL = 0.5, YFR = 0.0, MAIN = 0.1 }, 0.05)
  t.eq(sizes[1], 3)
  a:apply({ YFL = 0.5, YFR = 0.0, MAIN = 0.1 }, 0.05)  -- all unchanged
  t.eq(sizes[2], 0)
end)
t.test("state returns the last written throttle, 0 if unseen", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ YFL = 0.7 }, 0.05)
  t.near(a:state("YFL"), 0.7, 1e-9); t.eq(a:state("XX"), 0)
end)
t.test("default write tolerance is 0.04 (coarser writes -> fewer mainThread calls)", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })   -- no tol -> default
  a:apply({ YFL = 0.20 }, 0.05); t.eq(b.writes, 1)     -- first write
  a:apply({ YFL = 0.23 }, 0.05); t.eq(b.writes, 1)     -- +0.03 < 0.04 default -> no write
  a:apply({ YFL = 0.25 }, 0.05); t.eq(b.writes, 2)     -- +0.05 from last-written 0.20 -> write
end)
