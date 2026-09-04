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
function Loop:setTrim(dir, gain, authority, fadeStart, fade)
  self.trimDir = dir or 0; self.trimGain = gain or 0
  self.trimAuthority = authority or 1        -- fraction of caps.pitch the feedforward may use
  self.trimFadeStart = fadeStart or 0        -- |pitch| (rad) below which trim is full strength
  self.trimFade = fade or math.huge          -- |pitch| (rad) at which trim is fully faded out
end
function Loop:setActive(d)
  self.scheme, self.mixer, self.caps = d.scheme, d.mixer, d.caps or self.caps
  self.scheme:reset()
end
function Loop:getMode() return self.mode end
function Loop:clearDamped()
  self.mode = "NORMAL"
  if self.osc then self.osc:reset() end
end
function Loop:setFuelScale(x)
  if self.pwm and self.pwm.setFuelScale then self.pwm:setFuelScale(x) end
  if self.sd and self.sd.setFuelScale then self.sd:setFuelScale(x) end
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
    self._ffPitch = 0
    return { mode = self.mode, m = m, demands = nil, duties = nil }
  end
  local grounded = m.onGround == true
  -- Previous-cycle envelope saturation (same one-tick-delayed anti-windup pattern as the
  -- heave band's _heaveSat): a demand railed by its cap must stop integrating into that rail.
  local demands = self.scheme:update(self.sp, m, dt, grounded, self._sat)
  -- Forward trim (master-mode feedforward): the craft pitches nose-up under forward thrust because
  -- its CoM is not vertically centered. Bias the pitch DEMAND (realized as a lift-thruster
  -- differential by the mixer -- never the forward thrusters) proportional to the forward thrust
  -- demand, so the craft holds its intended pitch during acceleration. Applied before the DAMPED
  -- block so a genuine oscillation trip still zeroes it.
  -- BOUNDED (flip-guard, spec 2026-09-04): the raw feedforward can exceed caps.pitch and rail the
  -- whole pitch demand nose-down, starving the stabilizer -> forward somersault (observed in CRU).
  -- (a) attitude fade: full trim below trimFadeStart, ramp to 0 by trimFade, so it eases off as the
  -- craft departs level; (b) authority floor: never use more than trimAuthority of the pitch cap,
  -- reserving (1 - trimAuthority) for the stabilizer to recover with.
  local ffRaw = (self.trimDir or 0) * (self.trimGain or 0) * (demands.surge or 0)
  local mag = math.abs(m.pitch or 0)
  local fs, fe = self.trimFadeStart or 0, self.trimFade or math.huge
  local fade
  if mag <= fs then fade = 1
  elseif mag >= fe then fade = 0
  else fade = 1 - (mag - fs) / (fe - fs) end
  local ff = ffRaw * fade
  local ffCap = ((self.caps and self.caps.pitch) or math.huge) * (self.trimAuthority or 1)
  if ff > ffCap then ff = ffCap elseif ff < -ffCap then ff = -ffCap end
  self._ffPitch = ff
  demands.pitch = (demands.pitch or 0) + ff
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
  local clamped, sat = envelope.clamp(demands, self.caps)
  demands = clamped
  self._sat = sat   -- consumed by the scheme NEXT tick
  local duties = self.mixer:mix(demands)
  self:apply(duties, dt)
  return { mode = self.mode, m = m, demands = demands, duties = duties }
end
-- Pure log-site read: bundles PID terms + saturation + trim from already-stored loop/scheme
-- state. No mutation, no :update()/:cycle() call. Log-time only (called from a gated logCycle).
function Loop:diag(sp, m)
  local level = (self.scheme and self.scheme.inner) or self.scheme
  return {
    terms = (level and level.terms) and level:terms(sp, m) or nil,
    sat = self._sat or {},
    heaveBanded = (level and level._heaveSat) or false,
    trimDir = self.trimDir or 0,
    trimGain = self.trimGain or 0,
    ffPitch = self._ffPitch or 0,
  }
end
return Loop
