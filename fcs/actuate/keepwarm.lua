-- Continuous keep-warm thruster actuator. Drives setPowerNormalized(0..1) so a thruster held
-- at a small idle floor stays SPOOLED (Create Propulsion spools 0->full over 0.5s on every
-- 0->on edge; a warm bank has no spool lag on a reversal). Writes only when the fuel-scaled
-- throttle moves beyond `tol` (default 0.04; a steady hover -> almost no writes), dispatched
-- concurrently so N changes cost ~1 server tick (same reasoning as fcs/actuate/level.lua).
-- Same interface as Level.
local KeepWarm = {}
KeepWarm.__index = KeepWarm

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

function KeepWarm.new(cfg)
  return setmetatable({ backend = cfg.backend, last = {},
    tol = cfg.tol or 0.04, fuelScale = cfg.fuelScale or 1.0,
    dispatch = cfg.dispatch or defaultDispatch }, KeepWarm)
end

function KeepWarm:state(id) return self.last[id] or 0 end

-- Compensation-layer multiplier: scales the throttle only, base tuning untouched.
function KeepWarm:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end

local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end

function KeepWarm:planWrites(duties)
  local writes = {}
  for id, duty in pairs(duties) do
    local throttle = clamp((duty or 0) * self.fuelScale)
    local prev = self.last[id]
    if prev == nil or math.abs(throttle - prev) > self.tol then
      self.last[id] = throttle
      writes[#writes + 1] = function() self.backend:setThrusterNormalized(id, throttle) end
    end
  end
  return writes
end

function KeepWarm:apply(duties, dt)
  self.dispatch(self:planWrites(duties))
end

return KeepWarm
