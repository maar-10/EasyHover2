-- Same dispatch shape as fcs/actuate/level.lua: planWrites(duties, dt) returns write closures
-- without dispatching (updating this actuator's state as it collects), apply() dispatches them.
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

local SD = {}
SD.__index = SD
function SD.new(cfg)
  return setmetatable({ backend = cfg.backend, acc = {}, on = {}, fuelScale = cfg.fuelScale or 1.0,
    dispatch = cfg.dispatch or defaultDispatch }, SD)
end
function SD:state(id) return self.on[id] == true end

-- Compensation-layer multiplier: scales the accumulation rate only, base tuning untouched.
-- Ignores nil/non-positive input so an invalid call leaves the current scale in effect.
function SD:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end

function SD:planWrites(duties, dt)
  dt = dt or 0
  local writes = {}
  for id, duty in pairs(duties) do
    local a = (self.acc[id] or 0) + (duty or 0) * self.fuelScale * dt
    local want
    if dt > 0 and a >= dt then want = true; a = a - dt else want = false end
    self.acc[id] = a
    if self.on[id] ~= want then
      self.on[id] = want
      writes[#writes + 1] = function() self.backend:setThruster(id, want) end
    end
  end
  return writes
end
function SD:apply(duties, dt)
  self.dispatch(self:planWrites(duties, dt))
end
return SD
