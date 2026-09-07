local Pid = require("fcs.control.pid")
local Heading = require("fcs.control.heading")
local Translate = require("fcs.control.translate")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5,
    heaveMin = cfg.heaveMin, heaveMax = cfg.heaveMax }, Scheme)
  self.kv = (cfg.alt and cfg.alt.kv) or 0
  self.altPid = Pid.new(cfg.alt or {})
  self.pitchPid = Pid.new(cfg.pitch or {})
  self.rollPid = Pid.new(cfg.roll or {})
  self.headingPid = Heading.new(cfg.yaw or {})
  self.swayTc = Translate.new(cfg.sway or {})
  self.surgeTc = Translate.new(cfg.surge or {})
  return self
end
function Scheme:reset()
  self.altPid:reset(); self.pitchPid:reset(); self.rollPid:reset(); self.headingPid:reset()
  self.swayTc:reset(); self.surgeTc:reset()
  self._heaveSat = false
end
function Scheme:update(sp, m, dt, freeze, sat)
  -- Anti-windup: freeze alt integration whenever the collective was pinned to the heave band on
  -- the PREVIOUS tick (or the caller froze it, or the envelope clipped heave). Without this the
  -- integrator keeps accumulating while heave is railed, then overshoots the altitude on the way
  -- back down (climb-stop bounce).
  sat = sat or {}
  -- Altitude: rate (velocity controller) while the pilot's climbCmd is present, else position hold.
  local heave
  if sp.climbCmd ~= nil then
    self.altPid:reset()   -- keep the hold PID clean for a bumpless release handoff
    heave = self.hoverDuty + self.kv * (sp.climbCmd - (m.vSpeed or 0))
  else
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt,
      freeze or self._heaveSat or sat.heave)
  end
  -- Band the collective so lift thrusters never saturate to 0 or 1 -- shared-duty bang-bang
  -- loses ALL pitch/roll differential authority at the rails. Attitude survival > climb speed.
  local banded = false
  if self.heaveMin and heave < self.heaveMin then heave = self.heaveMin; banded = true end
  if self.heaveMax and heave > self.heaveMax then heave = self.heaveMax; banded = true end
  self._heaveSat = banded
  -- Yaw: rate (yaw-rate command) vs heading-hold.
  local yaw
  if sp.yawCmd ~= nil then
    self.headingPid:reset()
    yaw = self.headingPid:rate(sp.yawCmd, m.yawRate, dt)
  else
    yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt, freeze or sat.yaw)
  end
  -- Sway: rate (strafe velocity command) vs velocity-limited position-hold.
  local sway
  if sp.strafeCmd ~= nil then
    self.swayTc:reset()
    sway = self.swayTc:rate(sp.strafeCmd, m.swayVel, dt)
  else
    sway = self.swayTc:hold(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, sp.swayVmax)
  end
  return {
    heave = heave,
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt, freeze or sat.pitch),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt, freeze or sat.roll),
    yaw = yaw, sway = sway,
    surge = self.surgeTc:hold(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, sp.surgeVmax),
  }
end
-- Pure read: assembles the 6 per-axis {err,P,I,D} term tables by delegating to each
-- controller's own :terms(). No mutation, no :update() call. Log-time only.
function Scheme:terms(sp, m)
  return {
    alt   = self.altPid:terms(sp.altitude or 0, m.altitude or 0),
    pitch = self.pitchPid:terms(sp.pitch or 0, m.pitch or 0),
    roll  = self.rollPid:terms(sp.roll or 0, m.roll or 0),
    yaw   = self.headingPid:terms(sp.heading or 0, m.heading or 0, m.yawRate or 0),
    sway  = self.swayTc:terms(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, sp.swayVmax),
    surge = self.surgeTc:terms(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, sp.surgeVmax),
  }
end
return Scheme
