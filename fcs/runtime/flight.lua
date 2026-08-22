-- fcs/runtime/flight.lua
local ComAuto = require("fcs.comauto")
local Flight = {}
Flight.__index = Flight

-- Default trimDir at boot: the default mode's own feel.trimDir when the registry descriptor
-- carries one (real fcs.io.tuningdefaults-built feels do), else -1 (nose-down trim convention).
local function defaultTrimDir(reg)
  local d = reg and reg.byId and reg.default and reg.byId[reg.default]
  local t = d and d.feel and d.feel.trimDir
  return t or -1
end

function Flight.new(deps)
  return setmetatable({
    loop = deps.loop, pilot = deps.pilot, registry = deps.registry,
    moveEps = deps.moveEps or 0.5,   -- ground-idle motion gate (blocks/s)
    -- §11.8 no-fuel interlock: deps.fuel is an injected getter returning the mean lift-thruster
    -- fuel fraction (0..1) or nil when the gauge has never read. minFuel trips the latch;
    -- re-arm requires 2x minFuel (hysteresis, so a sloshing near-empty tank cannot chatter).
    fuel = deps.fuel, minFuel = deps.minFuel or 0.05,
    engaged = false, gndSafety = true, positionHold = false,
    fuelPump = false, flightMode = (deps.registry and deps.registry.default) or "PRECISION", parked = false,
    trimDir = defaultTrimDir(deps.registry),
    _needReset = false, _loopHz = 0, noFuel = false,
  }, Flight)
end

function Flight:handleCommand(cmd)
  local k = cmd and cmd.k
  if k == "gndSafety" then
    self.gndSafety = cmd.on and true or false; return true
  elseif k == "engage" then
    if self.gndSafety or self.noFuel then return false end
    -- Also consult the live gauge: engage may arrive before any step has run the latch.
    local frac = self.fuel and self.fuel() or nil
    if frac ~= nil and frac < self.minFuel then return false end
    -- Engage only marks intent; arming is decided every step by the ground-idle gate, so
    -- engaging while parked on the pad stays silent until the pilot commands a climb.
    self.engaged = true; self._needReset = true; return true
  elseif k == "disengage" then
    self.engaged = false; self.positionHold = false
    self.pilot:setPositionHold(false); self.loop:arm(false); return true
  elseif k == "positionHold" then
    self.positionHold = cmd.on and true or false
    self.pilot:setPositionHold(self.positionHold); return true
  elseif k == "fuelPump" then
    self.fuelPump = cmd.on and true or false; return true
  elseif k == "clearDamped" then
    self.loop:clearDamped(); return true
  elseif k == "flightMode" then
    local reg = self.registry
    local d = reg and reg.byId[cmd.id]
    if not d then return true end                 -- unknown id: stay on current mode
    self.loop:setActive(d)
    self.pilot:setMode(d.policy, d.feel)
    self.flightMode = cmd.id
    self.trimDir = (d.feel and d.feel.trimDir) or self.trimDir
    return true
    elseif k == "flightTrim" then
    local dir = (cmd.dir and cmd.dir < 0) and -1 or 1
    self.trimDir = dir
    if self.pilot.setTrimDir then self.pilot:setTrimDir(dir) end
    return true
  elseif k == "comAuto" then
    if cmd.op == "abort" then
      if self.comAuto then self.comAuto:abort("ABORT") end
      return true
    end
    if cmd.op == "start" then
      if not self.engaged or self.gndSafety then return false end
      self.comAuto = ComAuto.new({
        spanFwd = cmd.spanFwd or cmd.span or 1,
        spanRight = cmd.spanRight or cmd.span or 1,
      })
      self.comAuto:start(self._lastMeas or {})
      return true
    end
    return false
  end
  return false
end

-- Ground-idle predicate: the FCS is "parked" (engaged but should output ZERO thrust) only when it
-- sits still on the ground with no climb intent. Requiring at-rest as well as onGround defends the
-- fly-low-over-terrain case: a MOVING craft (onGround can flicker true over a tree/hill) is treated
-- as in-flight so the controller stays live. Isolated on purpose -- the next hardening (fuse baro /
-- altitude-vs-liftoff for uneven ground) is a one-function change here.
function Flight:_parked(held, meas)
  if self.comAuto and self.comAuto:active() then return false end
  if not (meas and meas.onGround == true) then return false end
  if held and held.up == true then return false end        -- climb un-parks (liftoff)
  local eps = self.moveEps
  return math.abs(meas.vSpeed or 0) < eps
     and math.abs(meas.swayVel or 0) < eps
     and math.abs(meas.surgeVel or 0) < eps                 -- moving => in-flight, not parked
end

-- §11.8 no-fuel interlock. An unfuelled thruster HOLDS its commanded level while producing zero
-- thrust, so an integrator flying into an empty tank winds up against a plant that stopped
-- responding. When the gauge reads below minFuel: disarm exactly like disengage (cut demand,
-- reset loops so they resume clean), latch noFuel, and refuse engage until the tank recovers to
-- 2x minFuel. A nil reading (gauge never polled / peripheral gone) never trips the gate -- the
-- hardware relay remains the physical arm path; this is the software mirror of it.
function Flight:_checkFuel(meas)
  if not self.fuel then return end
  local frac = self.fuel()
  if frac == nil then return end
  if frac < self.minFuel then
    if not self.noFuel then
      self.noFuel = true
      self.engaged = false
      self.positionHold = false
      if self.pilot.setPositionHold then self.pilot:setPositionHold(false) end
      self.pilot:reset(meas)
      self.loop:arm(false)
    end
  elseif self.noFuel and frac >= self.minFuel * 2 then
    self.noFuel = false   -- refuelled past hysteresis; re-engage is manual
  end
end

function Flight:step(dt, held, meas)
  self._lastMeas = meas
  local autoOn = self.comAuto and self.comAuto:active()
  if autoOn then held = {} end
  self:_checkFuel(meas)
  if self.engaged then
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    self.parked = self:_parked(held, meas)
    if self.parked then
      self.pilot:reset(meas)
      self.loop:arm(false)
    else
      if autoOn then
        local duties = self.lastDiag and self.lastDiag.duties
        local ar = self.comAuto:tick(dt, meas, duties, self.loop:getMode())
        local sch = self.loop.scheme
        if sch and sch.pitchPid then
          if ar.captureKi and ar.captureKi > 0 then
            if not self._comKiSaved then
              self._comKiSaved = { p = sch.pitchPid.ki, r = sch.rollPid.ki }
            end
            sch.pitchPid.ki = ar.captureKi
            sch.rollPid.ki = ar.captureKi
          elseif self._comKiSaved then
            sch.pitchPid.ki = self._comKiSaved.p
            sch.rollPid.ki = self._comKiSaved.r
            self._comKiSaved = nil
          end
        end
        if ar.captured and self.loop.mixer and self.loop.mixer.setCom then
          self.loop.mixer:setCom({
            fwd = ar.captured.fwd, right = ar.captured.right,
            spanFwd = self.comAuto.spanFwd, spanRight = self.comAuto.spanRight,
          })
        end
        if ar.setpoints then self.loop:setpoints(ar.setpoints) end
        self.loop:arm(true)
        if ar.done then
          self.engaged = false
          self.loop:arm(false)
        end
      else
        self.loop:setpoints(self.pilot:update(dt, held or {}, meas))
        self.loop:arm(true)
      end
    end
  else
    self.parked = false
    self.loop:arm(false)
  end
  local r = self.loop:cycle(dt, meas)
  self.lastDiag = r   -- exposed for optional flight instrumentation (demands/duties)
  if dt > 0 then self._loopHz = 1 / dt end
  return self:snapshot(r, meas)
end

-- Base snapshot: flags + measurement passthrough. Fuel/thruster detail is added
-- by the runtime wiring (Task D3) which has the backend handle.
function Flight:snapshot(r, meas)
  local m = meas or {}
  return {
    engaged = self.engaged, gndSafety = self.gndSafety,
    positionHold = self.positionHold, fuelPump = self.fuelPump, parked = self.parked,
    noFuel = self.noFuel,
    mode = self.parked and "PARKED" or ((r and r.mode) or self.loop:getMode()),
    flightMode = self.flightMode,
    trimDir = self.trimDir,
    -- DISPLAY altitude = true-Y baro (baroMsl) so the cockpit ALT matches F3. The control loop
    -- cycles on m.altitude (AGL) independently; only this telemetry field is retargeted. Falls back
    -- to m.altitude when baroMsl is absent (older backends / tests).
    altitude = m.baroMsl or m.altitude, vSpeed = m.vSpeed, heading = m.heading,
    yawRate = m.yawRate, swayPos = m.swayPos, surgePos = m.surgePos,
    onGround = m.onGround, loopHz = self._loopHz,
    comAuto = self.comAuto and {
      phase = self.comAuto.phase, abortReason = self.comAuto.abortReason,
      captured = self.comAuto.captured,
    } or nil,
  }
end

return Flight
