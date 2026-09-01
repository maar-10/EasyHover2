-- fcs/comauto.lua
-- CoM auto-trim: prereq lamp + climb/hold/capture/descend procedure. No Basalt/peripherals.
local Mixer = require("fcs.mixer.level_flight")

local M = {}

M.PREREQS = { "bind", "senscal", "span", "engine", "ground", "gndSafe", "still", "fuel", "engaged", "mode" }

local LABELS = {
  bind     = "MDB BIND",
  senscal  = "SENS CAL",
  span     = "COM SPAN",
  engine   = "ENG MASTER",
  ground   = "ON GROUND",
  gndSafe  = "GND SAFE",
  still    = "NOT MOVING",
  fuel     = "FUEL 20%",
  engaged  = "FCS ENGAGE",
  mode     = "LDG/PRE",
}

function M.label(id) return LABELS[id] or tostring(id) end

local function bound(name)
  return type(name) == "string" and name ~= ""
end

function M.missing(ctx)
  ctx = ctx or {}
  local th = ctx.thrusters or {}
  local se = ctx.sensors or {}
  if not (bound(th.FL) and bound(th.FR) and bound(th.RL) and bound(th.RR)
      and bound(se.altimeter) and bound(se.gimbal)) then
    return "bind"
  end
  local sc = ctx.senscal or {}
  if sc.signPitch == nil or sc.signHeading == nil then return "senscal" end
  local spanFwd = ctx.comSpanFwd or ctx.comSpan
  local spanRight = ctx.comSpanRight or ctx.comSpan
  if type(spanFwd) ~= "number" or spanFwd < 0.1 or type(spanRight) ~= "number" or spanRight < 0.1 then
    return "span"
  end
  if not ctx.engineOn then return "engine" end
  if ctx.onGround ~= true then return "ground" end
  if ctx.gndSafety then return "gndSafe" end
  if ctx.moving then return "still" end
  if type(ctx.fuelFrac) ~= "number" or ctx.fuelFrac < 0.20 then return "fuel" end
  if not ctx.engaged then return "engaged" end
  -- Auto-COM is a pad procedure and needs a real onGround reading, which only LDG produces
  -- (groundSense is LDG-only). So LDG is the eligible pad mode (boot default); PRECISION stays
  -- accepted for heritage but can never reach here on a live craft (it fails `ground` first).
  -- Requiring PRECISION alone deadlocked the lamp: onGround needs LDG, mode needed PRECISION.
  local mode = ctx.flightMode
  if mode ~= "PRECISION" and mode ~= "LDG" then return "mode" end
  return nil
end

function M.lamp(ctx, running)
  if running then return "blue" end
  if M.missing(ctx) then return "red" end
  return "green"
end

local P = {}
P.__index = P

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    phase = "IDLE",
    spanFwd = opts.spanFwd or opts.span or 1,
    spanRight = opts.spanRight or opts.span or 1,
    climbHeight = opts.climbHeight or 8,
    tiltLim = opts.tiltLim or 0.15,
    posLim = opts.posLim or 4,
    -- Capture is now a WINDOWED AVERAGE, not a single-instant snapshot: the craft hunts around its
    -- natural CoM tilt (ki=0), so one read is noise (repeat runs measured -0.7/-0.1/-0.3). settleDelay
    -- lets the climb transient die; then offsetFromDuties is averaged over captureWindow.
    settleDelay = opts.settleDelay or 1.5,
    captureWindow = opts.captureWindow or 3.0,
    climbRate = opts.climbRate or 0.6,
    descendRate = opts.descendRate or 0.7,
    landEps = opts.landEps or 0.4,
    watchdog = opts.watchdog or 45,
    -- 0 = measure at the craft's natural ki=0 CoM tilt (the P differential already encodes the CoM).
    -- The old 0.02 integral barely built (log: max 0.005) and just added noise; averaging replaces it.
    captureKi = opts.captureKi or 0,
    originSway = 0, originSurge = 0, originHdg = 0, baseAlt = 0,
    target = 0, elapsed = 0, settleT = 0, capT = 0, capN = 0, capSumFwd = 0, capSumRight = 0,
    captured = nil, abortReason = nil,
  }, P)
end

function P:active()
  return self.phase == "CLIMB" or self.phase == "HOLD" or self.phase == "DESCEND"
end

function P:start(meas)
  meas = meas or {}
  self.phase = "CLIMB"
  self.elapsed = 0
  self.settleT = 0; self.capT = 0; self.capN = 0; self.capSumFwd = 0; self.capSumRight = 0
  self.captured = nil
  self.abortReason = nil
  self.baseAlt = meas.altitude or 0
  self.target = self.baseAlt
  self.originSway = meas.swayPos or 0
  self.originSurge = meas.surgePos or 0
  self.originHdg = meas.heading or 0
  return true
end

function P:abort(reason)
  if self.phase == "IDLE" or self.phase == "DONE" then return end
  self.abortReason = self.abortReason or reason or "ABORT"
  if self.phase ~= "DESCEND" then self.phase = "DESCEND" end
end

local function hypot(a, b)
  return math.sqrt((a or 0) * (a or 0) + (b or 0) * (b or 0))
end

function P:tick(dt, meas, duties, loopMode)
  dt = (dt and dt > 0) and dt or 0
  meas = meas or {}
  local r = { phase = self.phase, holdStick = self:active(), done = false, abortReason = self.abortReason,
              captured = self.captured, setpoints = nil }

  if self.phase == "IDLE" or self.phase == "DONE" then
    r.done = self.phase == "DONE"
    return r
  end

  self.elapsed = self.elapsed + dt
  if loopMode == "DAMPED" then self:abort("DAMPED")
  elseif math.abs(meas.pitch or 0) > self.tiltLim or math.abs(meas.roll or 0) > self.tiltLim then
    self:abort("TILT")
  elseif self.phase ~= "DESCEND" and hypot((meas.swayPos or 0) - self.originSway, (meas.surgePos or 0) - self.originSurge) > self.posLim then
    -- POS guards the climb + measurement hover. On DESCEND the craft velocity-damps its position
    -- (below) and is allowed to drift, so a POS abort there would falsely flag a captured run.
    self:abort("POS")
  elseif self.elapsed >= self.watchdog then
    self:abort("TIME")
  end
  if self.phase == "ABORT" then
    r.phase = "ABORT"; r.abortReason = self.abortReason; r.done = true; r.holdStick = false
    return r
  end

  local top = self.baseAlt + self.climbHeight
  if self.phase == "CLIMB" then
    self.target = math.min(top, self.target + self.climbRate * dt)
    if meas.altitude then self.target = math.min(self.target, meas.altitude + 1.0) end
    if self.target >= top - 0.05 then self.phase = "HOLD"; self.held = 0 end
  elseif self.phase == "HOLD" then
    self.target = top
    -- Robust capture. pitch/roll run ki=0, so the craft holds its natural CoM tilt and the lift-
    -- thruster differential already encodes the CoM -- but it HUNTS, so a single read is noise. Let the
    -- climb transient settle, then AVERAGE offsetFromDuties over captureWindow: the mean lift
    -- differential is the steady CoM signature. tiltLim/POS/watchdog aborts still guard every tick, so
    -- a runaway can't feed the average.
    self.settleT = self.settleT + dt
    if self.settleT >= self.settleDelay and duties then
      local o = Mixer.offsetFromDuties(duties, { spanFwd = self.spanFwd, spanRight = self.spanRight })
      self.capSumFwd = self.capSumFwd + o.fwd
      self.capSumRight = self.capSumRight + o.right
      self.capN = self.capN + 1
      self.capT = self.capT + dt
      if self.capT >= self.captureWindow and self.capN > 0 then
        self.captured = { fwd = self.capSumFwd / self.capN, right = self.capSumRight / self.capN }
        self.phase = "DESCEND"
      end
    end
  elseif self.phase == "DESCEND" then
    self.target = math.max(self.baseAlt, self.target - self.descendRate * dt)
    if meas.altitude then self.target = math.max(self.target, meas.altitude - 1.0) end
    if meas.onGround == true or (meas.altitude and meas.altitude <= self.baseAlt + self.landEps) then
      self.phase = "DONE"
    end
  end

  r.phase = self.phase
  r.captured = self.captured
  r.abortReason = self.abortReason
  r.done = self.phase == "DONE"
  r.holdStick = self:active()
  -- CLIMB/HOLD hold the takeoff point (bounded, and useful for a stable measurement). DESCEND tracks
  -- the CURRENT position, so the translate loop only damps velocity -- it never chases a fixed point
  -- and so never winds the sway command to its saturation cap, which is what ignited the lateral
  -- descent runaway. The craft settles down roughly in place instead of sliding away.
  local descending = self.phase == "DESCEND"
  r.setpoints = {
    altitude = self.target,
    heading = self.originHdg,
    swayPos = descending and (meas.swayPos or self.originSway) or self.originSway,
    surgePos = descending and (meas.surgePos or self.originSurge) or self.originSurge,
    pitch = 0, roll = 0,
  }
  r.captureKi = (self.phase == "HOLD") and self.captureKi or 0
  return r
end

return M
