-- Same dispatch shape as fcs/actuate/level.lua: planWrites(duties, dt) returns write closures
-- without dispatching (updating this actuator's state as it collects), apply() dispatches them.
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

local Pwm = {}
Pwm.__index = Pwm
function Pwm.new(cfg)
  return setmetatable({ period = cfg.period or 0.5, backend = cfg.backend, phase = 0, on = {},
    dispatch = cfg.dispatch or defaultDispatch }, Pwm)
end
function Pwm:state(id) return self.on[id] == true end
function Pwm:planWrites(duties, dt)
  if self.period > 0 and (dt or 0) > 0 then
    self.phase = (self.phase + dt / self.period) % 1
  end
  local writes = {}
  for id, duty in pairs(duties) do
    local want = duty > self.phase
    if self.on[id] ~= want then
      self.on[id] = want
      writes[#writes + 1] = function() self.backend:setThruster(id, want) end
    end
  end
  return writes
end
function Pwm:apply(duties, dt)
  self.dispatch(self:planWrites(duties, dt))
end
return Pwm
