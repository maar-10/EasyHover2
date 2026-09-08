-- Direct 16-level thruster actuator. Writes setPower(0..15) ONLY when a thruster's quantized
-- level changes -> a steady hover holds steady levels -> almost no writes.
--
-- Each setPower is a ~50ms mainThread call. Writing the changed thrusters SEQUENTIALLY costs one
-- server tick EACH, so an active maneuver (all 4 lift levels changing every cycle) collapsed the
-- control loop to ~3Hz (Flight #6). CC:Tweaked drains many mainThread tasks per tick (5ms budget;
-- setPower is trivial), so we dispatch every changed write CONCURRENTLY: all tasks queue before
-- the computer yields and drain in ~1 tick, making N writes cost one tick regardless of N. The
-- in-game probe (tools/probe_batch.lua) confirmed concurrent dispatch stays flat at ~50ms for
-- 1..11 thrusters while sequential climbed to 541ms. Same interface as fcs/actuate/pwm.lua.
local Level = {}
Level.__index = Level

-- Run every write closure concurrently so their mainThread tasks batch into a single tick.
-- Falls back to sequential where the parallel API is absent (non-CC test hosts).
local function defaultDispatch(fns)
  local n = #fns
  if n == 0 then return end
  if n == 1 then fns[1](); return end
  if parallel and parallel.waitForAll then
    parallel.waitForAll(table.unpack(fns, 1, n))
  else
    for i = 1, n do fns[i]() end
  end
end

function Level.new(cfg)
  return setmetatable({ backend = cfg.backend, steps = cfg.steps or 15, last = {},
    dispatch = cfg.dispatch or defaultDispatch, fuelScale = cfg.fuelScale or 1.0 }, Level)
end

function Level:state(id) return self.last[id] or 0 end

-- Compensation-layer multiplier: scales quantized output only, base tuning untouched.
-- Ignores nil/non-positive input so an invalid call leaves the current scale in effect.
function Level:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end

local function quantize(v, steps)
  v = math.floor(v + 0.5)
  if v < 0 then return 0 elseif v > steps then return steps else return v end
end

function Level:planWrites(duties)
  local writes = {}
  for id, duty in pairs(duties) do
    local level = quantize((duty or 0) * self.fuelScale * self.steps, self.steps)
    if self.last[id] ~= level then
      self.last[id] = level
      writes[#writes + 1] = function() self.backend:setThrusterLevel(id, level) end
    end
  end
  return writes
end

function Level:apply(duties, dt)
  self.dispatch(self:planWrites(duties))
end

return Level
