-- fcs/input/pilot.lua
local leash = require("fcs.leash")
local brake = require("fcs.brake")

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
    yawWasHeld = false,
    climbWasHeld = false,
    swayWasHeld = false,
    driftArrest = true,
  }, Pilot)
end

function Pilot:reset(meas)
  self.sp = { altitude = meas.altitude, heading = meas.heading,
              swayPos = meas.swayPos, surgePos = meas.surgePos }
  -- Drop the persistent held-input accumulators too (same neutralization as setMode's transition):
  -- reset reseeds sp from measured, but update() re-derives sp.surgeThrottle/pitch/roll from these.
  -- A CRUISE throttle detent (self.throttle) surviving a disengage would otherwise slam MAIN back on
  -- at re-engage with no W held (F2). tilt cleared for the same reason on any reseed.
  self.tilt.pitch, self.tilt.roll, self.throttle = 0, 0, 0
  self.yawWasHeld = false
  self.climbWasHeld = false
  self.swayWasHeld = false
  return self.sp
end

function Pilot:setPositionHold(b) self.hold = b and true or false end

function Pilot:setMode(policy, feel)
  self.policy = policy or { tilt = false, surge = "position" }
  if feel then self.cfg = feel end
  self.tilt.pitch, self.tilt.roll, self.throttle = 0, 0, 0   -- transition: center tilt, drop throttle
  self.yawWasHeld = false
  self.climbWasHeld = false
  self.swayWasHeld = false
end

function Pilot:setTrimDir(dir) self.cfg.trimDir = (dir and dir < 0) and -1 or 1 end

function Pilot:setMaster(driftArrest) self.driftArrest = driftArrest ~= false end

local function dirOf(held, neg, pos)
  return (held[pos] and 1 or 0) - (held[neg] and 1 or 0)
end

-- Tilt-brake setpoint (fix #3): a speed-scaled pitch/roll tilt opposing the horizontal drift, held
-- as an attitude setpoint the leveling loop maintains. Engages when this craft is arresting (CRU at
-- throttle 0 / MAN|DRN hands-off) under CPL, above the engage speed, in a tiltBrake-enabled mode.
-- held.brake overrides the master mode in any mode and uses the steeper button curve; where tilt is
-- disabled (PRE/LDG) the button still forces a lateral hold but injects no tilt (returns 0,0).
function Pilot:_brakeSetpoint(held, meas, tilting)
  local tb = self.cfg.tiltBrake
  local btn = held.brake and true or false
  local autoArrest
  if self.policy.surge == "throttle" then autoArrest = (self.throttle or 0) <= 0
  elseif self.policy.tilt then autoArrest = not tilting
  else autoArrest = true end
  local engaged = btn or (autoArrest and self.driftArrest)
  if not engaged or not (tb and tb.enabled) then return 0, 0 end
  local sv, wv = meas.surgeVel or 0, meas.swayVel or 0
  local s = math.sqrt(sv * sv + wv * wv)
  return brake.vector(brake.angle(s, tb, btn), sv, wv)
end

function Pilot:update(dt, held, meas)
  if self.hold then
    -- Finding 1 fix: positionHold can be engaged WHILE a climb/yaw/sway key is still held (no
    -- release tick first), leaving a stale rate-command field on self.sp. If left alone, the
    -- scheme keeps taking the rate branch for the whole duration hold is engaged instead of
    -- holding. Clear the *Cmd fields on that transition tick and capture the CURRENT measured
    -- pose (not the stale pre-hold sp.altitude/heading/swayPos, which the rate-command path never
    -- updates) so the hold is bumpless.
    if self.sp.climbCmd ~= nil or self.sp.yawCmd ~= nil or self.sp.strafeCmd ~= nil then
      self.sp.climbCmd, self.sp.yawCmd, self.sp.strafeCmd = nil, nil, nil
      self.sp.altitude = (meas and meas.altitude) or self.sp.altitude
      self.sp.heading  = (meas and meas.heading)  or self.sp.heading
      self.sp.swayPos  = (meas and meas.swayPos)  or self.sp.swayPos
    end
    return self.sp
  end
  local c, sp = self.cfg, self.sp

  -- Yaw: rate command while held (the scheme's yaw-rate controller flies to it directly);
  -- capture heading on release for a bumpless heading hold. Mirrors the altitude
  -- (climbCmd/climbWasHeld) rate-command pattern above.
  local yd = dirOf(held, "yawLeft", "yawRight")
  if yd ~= 0 then
    sp.yawCmd = (c.headingRate or 0) * yd
    self.yawWasHeld = true
  else
    if self.yawWasHeld then sp.heading = meas.heading or sp.heading; self.yawWasHeld = false end
    sp.yawCmd = nil
  end

  -- Lift: rate command while held (the scheme's velocity controller flies to it directly);
  -- capture altitude on release for a bumpless position hold. See #9 -- this replaces the
  -- old leadCapVert leash + altStopLead release-edge capture with a direct rate command.
  local ld = dirOf(held, "down", "up")
  if ld ~= 0 then
    sp.climbCmd = (c.climbRate or 0) * ld
    self.climbWasHeld = true
  else
    if self.climbWasHeld then sp.altitude = meas.altitude or sp.altitude; self.climbWasHeld = false end
    sp.climbCmd = nil
  end

  -- Sway: rate command while held (the scheme's lateral-velocity controller flies to it directly);
  -- capture swayPos on release for a bumpless handoff, then the unified drift law below governs it
  -- (CPL arrests at the captured position; DCPL / tilting relaxes it to measured = coast). Mirrors
  -- the altitude (climbCmd/climbWasHeld) and yaw (yawCmd/yawWasHeld) rate-command pattern above.
  -- Surge (fore/aft, the main engine) is NOT rate-commanded -- it keeps its leashed position
  -- setpoint / CRUISE throttle handling below, untouched.
  -- DRN sets policy.translate=false: skip this block entirely so sway/surge setpoints stay
  -- frozen at their reset value and the craft moves by tilt only. Nil (every other mode) is
  -- ~= false, so behavior there is unchanged.
  if self.policy.translate ~= false then
    local swd = dirOf(held, "swayLeft", "swayRight")
    if swd ~= 0 then
      sp.strafeCmd = (c.swaySpeed or 0) * swd
      self.swayWasHeld = true
    else
      if self.swayWasHeld then sp.swayPos = meas.swayPos or sp.swayPos; self.swayWasHeld = false end
      sp.strafeCmd = nil
    end

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
      if (self.throttle or 0) > 0 and not held.brake then
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
  local braking = held.brake and true or false
  if not braking and (tilting or (not self.driftArrest and not swayCmd))  then sp.swayPos  = meas.swayPos  end
  if not braking and (tilting or (not self.driftArrest and not surgeCmd)) then sp.surgePos = meas.surgePos end

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
    local bp, br = self:_brakeSetpoint(held, meas, tilting)   -- 0,0 while tilting
    -- Brake button (btn) intentionally SUMS onto the pilot's active tilt (btn overrides the
    -- hands-off gate); the total is bounded by the envelope's demand clamp, not the tilt setpoint.
    sp.pitch, sp.roll = self.tilt.pitch + bp, self.tilt.roll + br
  else
    sp.pitch, sp.roll = self:_brakeSetpoint(held, meas, false)   -- 0,0 unless braking
  end
  if self.policy.surge == "throttle" then
    local d = dirOf(held, "surgeBack", "surgeFwd")
    local maxT = c.cruiseThrottleMax or 1.0
    self.throttle = self.throttle + (c.cruiseThrottleRate or 1.0) * dt * d
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > maxT then self.throttle = maxT end
    sp.surgeThrottle = (held.brake and 0) or self.throttle   -- brake cuts MAIN; detent resumes on release
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
