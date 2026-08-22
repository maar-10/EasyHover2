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
    dispatch = cfg.dispatch or defaultDispatch }, Level)
end

function Level:state(id) return self.last[id] or 0 end

local function quantize(v, steps)
  v = math.floor(v + 0.5)
  if v < 0 then return 0 elseif v > steps then return steps else return v end
end

function Level:apply(duties, dt)
  local writes = {}
  for id, duty in pairs(duties) do
    local level = quantize((duty or 0) * self.steps, self.steps)
    if self.last[id] ~= level then
      self.last[id] = level
      writes[#writes + 1] = function() self.backend:setThrusterLevel(id, level) end
    end
  end
  self.dispatch(writes)
end

-- Device read-back reconciliation (design §7: compare against the block's OWN report, never
-- only our record -- a second writer, a lost write, or a relay/peripheral reload can desync
-- us, and write-on-change would then never correct it). getPower costs a mainThread slot on
-- plain thrusters, so the caller polls SLOWLY, one id at a time, OFF the control cycle
-- (tools/flight.lua resyncTask). Accepts either reported scale (0..15 raw or 0..1 normalized).
-- On disagreement >= half a level, immediately re-asserts our last intended level and returns
-- true. A nil/unseen id is treated as intent 0, so this also heals a stuck-on thruster while
-- disarmed.
function Level:reportDeviceLevel(id, v)
  if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return false end
  local scaled = (v >= 0 and v <= 1) and v * self.steps or v
  local dev = quantize(scaled, self.steps)
  local mine = self.last[id] or 0
  if dev ~= mine then
    local lvl = mine          -- capture current intent; a racing apply() may already have moved on
    self.dispatch({ function() self.backend:setThrusterLevel(id, lvl) end })
    return true
  end
  return false
end

return Level
