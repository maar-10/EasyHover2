-- fcs/input/pilot.lua
local leash = require("fcs.leash")
local angle = require("fcs.angle")

local Pilot = {}
Pilot.__index = Pilot

function Pilot.new(cfg)
  return setmetatable({
    cfg = cfg,
    sp = { altitude = 0, heading = 0, swayPos = 0, surgePos = 0 },
    hold = false,
    policy = { tilt = false, surge = "position" },
    tilt = { pitch = 0, roll = 0 },
    throttle = 0,
    climbHeld = 0,
    yawWasHeld = false,
    driftArrest = true,
  }, Pilot)
end

function Pilot:reset(meas)
  self.sp = { altitude = meas.altitude, heading = meas.heading,
              swayPos = meas.swayPos, surgePos = meas.surgePos }
  -- Drop the persistent held-input accumulators too (same neutralization as setMode's transition):
  -- reset reseeds sp from measured, but update() re-derives sp.surgeThrottle/pitch/roll from these.
  -- A CRUISE throttle detent (self.throttle) surviving a disengage would otherwise slam MAIN back on
  -- at re-engage with no W held (F2). tilt/climbHeld cleared for the same reason on any reseed.
  self.tilt.pitch, self.tilt.roll, self.throttle, self.climbHeld = 0, 0, 0, 0
  self.yawWasHeld = false
  return self.sp
end

function Pilot:setPositionHold(b) self.hold = b and true or false end

function Pilot:setMode(policy, feel)
  self.policy = policy or { tilt = false, surge = "position" }
  if feel then self.cfg = feel end
  self.tilt.pitch, self.tilt.roll, self.throttle, self.climbHeld = 0, 0, 0, 0   -- transition: center tilt, drop throttle
end

function Pilot:setTrimDir(dir) self.cfg.trimDir = (dir and dir < 0) and -1 or 1 end

function Pilot:setMaster(driftArrest) self.driftArrest = driftArrest ~= false end

local function dirOf(held, neg, pos)
  return (held[pos] and 1 or 0) - (held[neg] and 1 or 0)
end

function Pilot:update(dt, held, meas)
  if self.hold then return self.sp end
  local c, sp = self.cfg, self.sp

  -- Yaw: slew heading setpoint, angle-wrapped, leashed to lead the CURRENT heading by at most
  -- leadCapHeading. The leash bounds the standing lead (hence the steady turn RATE) while held;
  -- mirrors the altitude (leadCapVert) and position (maxLead) leashes. The post-release coast --
  -- the craft continuing to turn out the remaining lead -- is killed separately by the release-edge
  -- capture near the end of update() (snaps the setpoint to current heading + a small stop lead).
  local yd = dirOf(held, "yawLeft", "yawRight")
  local yawActive = (yd ~= 0)   -- drives the release-capture below
  if yd ~= 0 then
    sp.heading = angle.wrap(sp.heading + c.headingRate * dt * yd)
    local cap = c.leadCapHeading
    if cap then
      local err = angle.wrap(sp.heading - (meas.heading or 0))
      if err > cap then sp.heading = angle.wrap((meas.heading or 0) + cap)
      elseif err < -cap then sp.heading = angle.wrap((meas.heading or 0) - cap) end
    end
  end

  -- Lift: slew altitude, leashed to current altitude +/- leadCapVert. The rate ramps with hold
  -- time (tap = base climbRate nudge, sustained hold -> climbRate*(1+climbBoost)), always on.
  local ld = dirOf(held, "down", "up")
  local climbRate = c.climbRate
  if ld ~= 0 then
    self.climbHeld = (self.climbHeld or 0) + dt
    local ramp = math.min(1, self.climbHeld / (c.climbRampTime or 1.0))
    climbRate = c.climbRate * (1 + (c.climbBoost or 0) * ramp)
  else
    self.climbHeld = 0
  end
  if ld ~= 0 then
    local a = sp.altitude + climbRate * dt * ld
    local lo, hi = meas.altitude - c.leadCapVert, meas.altitude + c.leadCapVert
    if a < lo then a = lo elseif a > hi then a = hi end
    sp.altitude = a
  end

  -- Sway / surge: leashed position setpoints. Held => ramp toward the lead cap in that direction at
  -- the axis cruise speed; released => hold current setpoint. Surge (fore/aft, the main engine) and
  -- sway (lateral) have SEPARATE speed/lead so forward can be much faster than sideways; both fall
  -- back to the shared cruiseSpeed/maxLead when the split params are absent (keeps old configs valid).
  -- DRN sets policy.translate=false: skip the leash entirely so sway/surge setpoints stay
  -- frozen at their reset value and the craft moves by tilt only. Nil (every other mode) is
  -- ~= false, so behavior there is unchanged.
  if self.policy.translate ~= false then
    local swaySpeed, swayLead = c.swaySpeed or c.cruiseSpeed, c.swayLead or c.maxLead
    local swd = dirOf(held, "swayLeft", "swayRight")
    local starget = (swd ~= 0) and (meas.swayPos + swayLead * swd) or sp.swayPos
    sp.swayPos = leash.step(sp.swayPos, starget, meas.swayPos, dt, swaySpeed, swayLead)

    -- CRUISE (policy.surge=="throttle"): do not leash surge ahead of the craft. Throttle
    -- overwrites surge demand; a standing lead under CPL rails reverse on mode exit (A1).
    if self.policy.surge ~= "throttle" then
      local surgeSpeed, surgeLead = c.surgeSpeed or c.cruiseSpeed, c.surgeLead or c.maxLead
      local sud = dirOf(held, "surgeBack", "surgeFwd")
      local utarget = (sud ~= 0) and (meas.surgePos + surgeLead * sud) or sp.surgePos
      sp.surgePos = leash.step(sp.surgePos, utarget, meas.surgePos, dt, surgeSpeed, surgeLead)
    else
      -- CRUISE throttle mode. While pushing forward (throttle>0) surge = throttle and we track meas
      -- so the arrest, when throttle reaches 0, holds the CURRENT position. At throttle 0 we stop
      -- pinning and leash surgePos toward current (like the position modes) so the surge loop arrests
      -- and holds station instead of coasting.
      if (self.throttle or 0) > 0 then
        sp.surgePos = meas.surgePos or sp.surgePos
      else
        local surgeSpeed, surgeLead = c.surgeSpeed or c.cruiseSpeed, c.surgeLead or c.maxLead
        sp.surgePos = leash.step(sp.surgePos, sp.surgePos, meas.surgePos, dt, surgeSpeed, surgeLead)
      end
    end
  end

  -- Unified horizontal drift rule (master mode). "relax" = snap the position setpoint to measured
  -- so the translate loop applies no corrective force. Per axis: relax while the pilot tilts to
  -- steer (any tilt mode -- generalizes MAN's old relaxTiltDrift, and gives DRN its "hold altitude,
  -- don't fight the tilt" feel), OR under DCPL (driftArrest=false) whenever that axis is not being
  -- directly translated (momentum coasts). CPL hands-off leaves the leash's held setpoint in place
  -- (arrest drift). DRN has translate=false so it never "directly translates".
  local tilting = self.policy.tilt and
    (held.pitchUp or held.pitchDown or held.rollLeft or held.rollRight) and true or false
  local canTranslate = self.policy.translate ~= false
  local swayCmd  = canTranslate and (held.swayLeft or held.swayRight)  or false
  local surgeCmd = canTranslate and (held.surgeFwd or held.surgeBack)  or false
  if tilting or (not self.driftArrest and not swayCmd)  then sp.swayPos  = meas.swayPos  end
  if tilting or (not self.driftArrest and not surgeCmd) then sp.surgePos = meas.surgePos end

  -- Mode policy: tilt (MAN pitch/roll setpoint, auto-levels on release) and throttle
  -- (CRUISE held forward-throttle). Applied here so the existing altitude/heading/sway/surge
  -- ramp logic above stays untouched; positionHold (self.hold) never reaches this point.
  if self.policy.tilt then
    local function toward(cur, dir, rate, cap)
      if dir ~= 0 then cur = cur + rate * dt * dir
      elseif cur > 0 then cur = math.max(0, cur - rate * dt)
      else cur = math.min(0, cur + rate * dt) end          -- auto-level toward 0 on release
      if cur >  cap then cur =  cap elseif cur < -cap then cur = -cap end
      return cur
    end
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
  else
    sp.pitch, sp.roll = 0, 0
  end
  if self.policy.surge == "throttle" then
    local d = dirOf(held, "surgeBack", "surgeFwd")
    local maxT = c.cruiseThrottleMax or 1.0
    self.throttle = self.throttle + (c.cruiseThrottleRate or 1.0) * dt * d
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > maxT then self.throttle = maxT end
    sp.surgeThrottle = self.throttle
  end

  -- Yaw release-edge capture: on the tick the pilot lets go of yaw/rudder, drop the leashed lead
  -- and snap the heading setpoint to the current heading plus a small predictive stop
  -- (yawStopLead * yawRate), so the loop brakes to a halt where you released instead of coasting
  -- the ~leadCapHeading lead out -- the old oversteer. Edge-triggered (yawWasHeld): once captured,
  -- the setpoint stays fixed so the heading PID fights drift rather than re-tracking meas.heading.
  if yawActive then
    self.yawWasHeld = true
  elseif self.yawWasHeld then
    sp.heading = angle.wrap((meas.heading or 0) + (c.yawStopLead or 0) * (meas.yawRate or 0))
    self.yawWasHeld = false
  end

  -- Return a snapshot copy: sp is self.sp, mutated in place as internal ramp state across calls
  -- (needed so leash/tilt/throttle math can reference the previous tick's values). Callers that
  -- hold onto a returned setpoint across later update() calls (e.g. comparing tilt/throttle before
  -- and after release) must see the value AT THAT TICK, not a live view of ongoing mutation.
  local out = {}
  for k, v in pairs(sp) do out[k] = v end
  return out
end

return Pilot
