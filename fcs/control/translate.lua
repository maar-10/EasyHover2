local T = {}
T.__index = T
function T.new(cfg)
  local self = setmetatable({}, T)
  self.ks = cfg.ks or 0
  self.ka = cfg.ka or 0
  self:reset(); return self
end
-- Hold has no integrator; reset is kept as a harmless no-op so existing callers
-- (Scheme:reset, the rate-branch handoff) need no change.
function T:reset() end
-- Velocity-limited position hold (cascade). Outer P on position error produces a
-- velocity target bounded to +-vmax; inner P on velocity (ks) produces the duty.
-- Because the commanded velocity is capped, momentum is bounded and the craft can
-- always arrest -- the old saturating-PD divergence (spec 2026-09-07) is impossible.
function T:hold(sp, pos, vel, vmax)
  local velTarget = self.ka * (sp - pos)
  if vmax and vmax > 0 then
    if velTarget > vmax then velTarget = vmax elseif velTarget < -vmax then velTarget = -vmax end
  end
  return self.ks * (velTarget - (vel or 0))
end
-- Pilot rate command: fly to a commanded velocity directly. UNCHANGED.
function T:rate(cmd, vel, dt)
  return self.ks * ((cmd or 0) - (vel or 0))
end
-- Pure read: reconstruct {err, P, I, D} matching :hold() exactly. Log-time only.
-- P is the position->velocity-target->duty contribution (clamped), D the damping.
function T:terms(sp, pos, vel, vmax)
  local err = sp - pos
  local velTarget = self.ka * err
  if vmax and vmax > 0 then
    if velTarget > vmax then velTarget = vmax elseif velTarget < -vmax then velTarget = -vmax end
  end
  return {
    err = err,
    P = self.ks * velTarget,
    I = 0,
    D = -self.ks * (vel or 0),
  }
end
return T
