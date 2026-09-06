local T = {}
T.__index = T
function T.new(cfg)
  local self = setmetatable({}, T)
  self.kp = cfg.kp or 0; self.ki = cfg.ki or 0; self.kd = cfg.kd or 0
  self.ks = cfg.ks or 0
  self.iMin = cfg.iMin or -math.huge; self.iMax = cfg.iMax or math.huge
  self.dtMax = cfg.dtMax or 0.5
  self:reset(); return self
end
function T:reset() self.i = 0 end
function T:update(sp, meas, vel, dt, freeze)
  local err = sp - meas
  if not freeze and dt > 0 and dt <= self.dtMax then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  return self.kp * err + self.i - self.kd * (vel or 0)
end
-- Pure read: reconstructs {err, P, I, D} from ALREADY-STORED state (self.i), matching
-- :update()'s last return exactly. No mutation. Log-time only.
function T:terms(sp, pos, vel)
  local err = sp - pos
  return {
    err = err,
    P = self.kp * err,
    I = self.i,
    D = -self.kd * (vel or 0),
  }
end
function T:rate(cmd, vel, dt)
  return self.ks * ((cmd or 0) - (vel or 0))
end
return T
