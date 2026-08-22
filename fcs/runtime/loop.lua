local frame = require("fcs.frame")
local envelope = require("fcs.envelope")
local Osc = require("fcs.safety.oscillation")
local Loop = {}
Loop.__index = Loop
function Loop.new(cfg)
  local self = setmetatable({ scheme = cfg.scheme, mixer = cfg.mixer, pwm = cfg.pwm,
    sd = cfg.sd, backend = cfg.backend, dtMax = cfg.dtMax or 0.5, sp = {}, armed = false,
    caps = cfg.caps or {}, mode = "NORMAL", hoverDuty = cfg.hoverDuty }, Loop)
  if cfg.osc then self.osc = Osc.new(cfg.osc) end
  self.isLift = {}
  for _, id in ipairs(frame.LIFT) do self.isLift[id] = true end
  return self
end
function Loop:setpoints(t) self.sp = t end
function Loop:arm(b) self.armed = b and true or false end
function Loop:setActive(d)
  self.scheme, self.mixer, self.caps = d.scheme, d.mixer, d.caps or self.caps
  self.scheme:reset()
end
function Loop:getMode() return self.mode end
function Loop:clearDamped()
  self.mode = "NORMAL"
  if self.osc then self.osc:reset() end
end
function Loop:apply(duties, dt)
  if not self.sd then
    self.pwm:apply(duties, dt)
    return
  end
  local lift, rest = {}, {}
  for id, duty in pairs(duties) do
    if self.isLift[id] then lift[id] = duty else rest[id] = duty end
  end
  self.pwm:apply(lift, dt)
  self.sd:apply(rest, dt)
end
function Loop:cycle(rawDt, m)
  -- §6 dt discipline: clamp AND skip. A cycle that overran (mainThread stall, lag spike) must
  -- not feed its huge dt into the integrators/derivative as a legitimate step -- that is a kick.
  -- Overrun => this cycle runs with dt = 0: every controller's usable-guard (dt > 0) skips
  -- integration and differentiation for exactly this cycle while the P term still reacts, and
  -- the next sample starts fresh from the new timestamp.
  local over = rawDt > self.dtMax
  local dt = rawDt
  if dt < 0 then dt = 0 elseif dt > self.dtMax then dt = self.dtMax end
  if over then dt = 0 end
  m = m or self.backend:sensors()
  if not self.armed then
    self.scheme:reset()
    local zeros = {}
    for _, id in ipairs(frame.LIFT) do zeros[id] = 0 end
    for _, id in ipairs(frame.LATERAL) do zeros[id] = 0 end
    for _, id in ipairs(frame.MAIN) do zeros[id] = 0 end
    for _, id in ipairs(frame.FRONTAL) do zeros[id] = 0 end
    self:apply(zeros, dt)
    return { mode = self.mode, m = m, demands = nil, duties = nil }
  end
  local grounded = m.onGround == true
  local demands = self.scheme:update(self.sp, m, dt, grounded)
  -- The oscillation detector is per-axis and auto-recovering, so mode tracks it every tick:
  -- a trip latches DAMPED, and it falls back to GROUND/NORMAL on its own once the signal is
  -- calm (no longer sticky; clearDamped() still force-resets the detector).
  local tripped = self.osc and self.osc:update(m.pitch, m.roll, dt) or false
  self.mode = tripped and "DAMPED" or (grounded and "GROUND" or "NORMAL")
  if self.mode == "DAMPED" then
    demands.pitch, demands.roll, demands.yaw, demands.sway, demands.surge = 0, 0, 0, 0, 0
    -- Hold vertical too: a genuine trip must not keep climbing off. Neutral = hoverDuty when
    -- known; otherwise leave the scheme's heave (tests without a hoverDuty configured).
    if self.hoverDuty then demands.heave = self.hoverDuty end
  end
  demands = envelope.clamp(demands, self.caps)
  local duties = self.mixer:mix(demands)
  self:apply(duties, dt)
  return { mode = self.mode, m = m, demands = demands, duties = duties }
end
return Loop
