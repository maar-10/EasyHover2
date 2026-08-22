local frame = require("fcs.frame")
-- Max sample period the velocity filter / position integrators will act on (seconds). Matches
-- Loop:cycle's dtMax. A gap larger than this (a stall) is integrated as if it were this long --
-- bounded, never a teleport.
local MAX_INTEGRATION_DT = 0.5
local Backend = {}
Backend.__index = Backend
function Backend.new(shim, config, clock)
  local self = setmetatable({}, Backend)
  self.shim = shim; self.config = config
  self.clock = clock or function() return os.epoch("utc") end
  self.wrapped = {}                 -- name -> peripheral cache
  self.lastT, self.lastAlt, self.vFilt = nil, nil, 0
  self.swayPos, self.surgePos = 0, 0
  return self
end
function Backend:_periph(name)
  if not name then return nil end
  if self.wrapped[name] == nil then self.wrapped[name] = self.shim.wrap(name) or false end
  return self.wrapped[name] or nil
end
function Backend:setThruster(id, on)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setPower(on and 15 or 0) end   -- real Create thruster method is setPower(0..15); no self
end
function Backend:setThrusterLevel(id, level)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setPower(level) end   -- 0..15; wrapped peripherals take NO self
end
function Backend:_read(name, method, ...)
  local p = self:_periph(name)
  if not p then return nil end
  return p[method](...)   -- CC wrapped peripherals take NO self
end
function Backend:sensors()
  local c, b = self.config, self.config.bindings
  -- Finite-guard: a peripheral that glitches to NaN/inf must not poison the control loop or the
  -- position integrators. Each guarded read holds its last-good value (0 until first seen).
  self._lg = self._lg or {}
  local lg = self._lg
  local function san(name, v)
    if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
      lg[name] = v; return v
    end
    return lg[name] or 0
  end
  local rawAlt = san("rawAlt", self:_read(c.sensors.altimeter, "getHeight") or 0)
  local altitude = rawAlt + (b.baroThrusterOffset or 0) + (b.heightOffset or 0)
  local angles = self:_read(c.sensors.gimbal, "getAngles") or {0, 0}
  local gScale = b.gimbalScale or 1
  local pitch = san("pitch", (b.signPitch or 1) * gScale * (angles[b.gimbalPitchIdx or 1] or 0))
  local roll  = san("roll",  (b.signRoll  or 1) * gScale * (angles[b.gimbalRollIdx  or 2] or 0))
  local rawHeading = self:_read(c.sensors.navTable, "getRelativeAngle") or 0
  local heading = san("heading", (b.signHeading or 1) * (b.headingScale or 1) * rawHeading)
  local vf = san("vf", (b.signVelFront or 1) * (self:_read(c.sensors.velFront, "getVelocity") or 0))
  local vr = san("vr", (b.signVelRear  or 1) * (self:_read(c.sensors.velRear,  "getVelocity") or 0))
  local vm = san("vm", (b.signVelMedial or 1) * (self:_read(c.sensors.velMedial,"getVelocity") or 0))
  local baseline = b.yawBaseline or 1
  local yawRate = (b.signYawRate or 1) * (vf - vr) / (baseline ~= 0 and baseline or 1)
  local swayVel = (vf + vr) / 2
  local surgeVel = vm
  local optD = self:_read(c.sensors.downOptical, "getDistance")
  local onGround = (optD ~= nil) and (optD < (b.onGroundThreshold or 1.5)) or false

  local now = self.clock()
  local vSpeed = 0
  if self.lastT ~= nil then
    local dt = (now - self.lastT) / 1000
    -- Clamp the sample period like Loop:cycle clamps the loop dt: after a stall (mainThread
    -- hiccup, lag spike) raw dt would integrate a huge step -- rawV spikes into the alt-PID's
    -- derivative and sway/surge "teleport" into the pilot leashes. Bound it; lastT still moves
    -- to now, so the next sample starts fresh.
    if dt > MAX_INTEGRATION_DT then dt = MAX_INTEGRATION_DT end
    if dt > 0 then
      local rawV = (altitude - self.lastAlt) / dt
      local tau = b.vSpeedTau or 0
      local alpha = tau > 0 and (dt / (tau + dt)) or 1
      self.vFilt = self.vFilt + alpha * (rawV - self.vFilt)
      vSpeed = self.vFilt
      self.swayPos = self.swayPos + swayVel * dt
      self.surgePos = self.surgePos + surgeVel * dt
    end
  end
  self.lastT, self.lastAlt = now, altitude
  return { altitude=altitude, baroMsl=rawAlt, vSpeed=vSpeed, pitch=pitch, roll=roll, heading=heading,
    yawRate=yawRate, swayVel=swayVel, surgeVel=surgeVel, swayPos=self.swayPos, surgePos=self.surgePos,
    onGround=onGround }
end
function Backend:liftIds() return frame.LIFT end
function Backend:lateralIds() return frame.LATERAL end
function Backend:mainIds() return frame.MAIN end
function Backend:frontalIds() return frame.FRONTAL end
return Backend
