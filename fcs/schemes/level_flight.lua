local Pid = require("fcs.control.pid")
local Heading = require("fcs.control.heading")
local Translate = require("fcs.control.translate")
local Scheme = {}
Scheme.__index = Scheme
function Scheme.new(cfg)
  local self = setmetatable({ hoverDuty = cfg.hoverDuty or 0.5,
    heaveMin = cfg.heaveMin, heaveMax = cfg.heaveMax }, Scheme)
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
  local heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt,
    freeze or self._heaveSat or sat.heave)
  -- Band the collective so lift thrusters never saturate to 0 or 1 -- shared-duty bang-bang
  -- loses ALL pitch/roll differential authority at the rails. Attitude survival > climb speed.
  local banded = false
  if self.heaveMin and heave < self.heaveMin then heave = self.heaveMin; banded = true end
  if self.heaveMax and heave > self.heaveMax then heave = self.heaveMax; banded = true end
  self._heaveSat = banded
  return {
    heave = heave,
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt, freeze or sat.pitch),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt, freeze or sat.roll),
    yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt, freeze or sat.yaw),
    sway = self.swayTc:update(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, dt, freeze or sat.sway),
    surge = self.surgeTc:update(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, dt, freeze or sat.surge),
  }
end
return Scheme
