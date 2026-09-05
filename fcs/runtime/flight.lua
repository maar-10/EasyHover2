-- fcs/runtime/flight.lua
local ComAuto = require("fcs.comauto")
local fueltable = require("fcs.fueltable")
local Master = require("fcs.modes.master")
local Flight = {}
Flight.__index = Flight

-- Deep-copy helper (mirrors fcs/io/tuningdefaults.lua's `deep`): an injected deps.emrcvr, or the
-- shared tuningdefaults table, must never be mutated by a later live setEmrcvrCfg edit.
local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deepCopy(x) end
  return o
end

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
    -- EMRCVR config (Task 2): deps.emrcvr, or the shared tuningdefaults block when no dep is
    -- injected (tests / callers that don't care). Deep-copied so a later setEmrcvrCfg live edit
    -- can never mutate the caller's dep table or the shared tuningdefaults singleton.
    emr = deepCopy(deps.emrcvr or require("fcs.io.tuningdefaults").get().emrcvr),
    -- §11.8 no-fuel interlock: deps.fuel is an injected getter returning the mean lift-thruster
    -- fuel fraction (0..1) or nil when the gauge has never read. Reads the FCS's already-polled
    -- 1 Hz snapshot -- no extra mainThread I/O, no UI/NAV sensor polling. minFuel trips the
    -- latch; re-arm requires 2x minFuel (hysteresis so a sloshing near-empty tank cannot chatter).
    fuel = deps.fuel, minFuel = deps.minFuel or 0.05,
    -- Global parked latch (§3.3): setGroundSense(fn(bool)|nil) toggles the backend's ground
    -- sensor per mode switch; park(table|nil) carries the LDG landed-detector's thresholds
    -- (consumed starting Task 8). canPark/groundSense mirror the active descriptor's flags
    -- (updated by handleCommand's flightMode branch); both default false until a mode switch
    -- (or Task 9's boot wiring) applies the active descriptor.
    setGroundSense = deps.setGroundSense, park = deps.park,
    -- §Task 6 fuel calibration: setFuelScale(fn|nil) applies the actuator scale for the selected
    -- fuel, saveFuel(fn|nil) persists the selection; both called as PLAIN functions (no self).
    -- fuelName defaults to fueltable.default (the calibrated baseline, "Biodiesel").
    setFuelScale = deps.setFuelScale, saveFuel = deps.saveFuel,
    fuelName = deps.fuelName or fueltable.default,
    canPark = false, groundSense = false,
    -- EMRCVR (Task 3): latch + captured recovery target + dwell timer + scope-save for the
    -- entry-mutated scheme/gains (comAuto ki-scoping pattern; see _emrEnter/_emrExit).
    emrcvr = false, emrcvrAlt = nil, emrStableT = 0, _emrSch = nil, _emrSaved = nil,
    engaged = false, gndSafety = true, positionHold = false,
    fuelPump = false, flightMode = (deps.registry and deps.registry.default) or "PRECISION", parked = false,
    trimDir = defaultTrimDir(deps.registry),
    masterMode = (deps.masterDefault) or Master.default,
    trimGain = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimGain) or 0
    end)(),
    trimAuthority = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimAuthority) or 1
    end)(),
    trimFadeStart = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimFadeStart) or 0
    end)(),
    trimFade = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimFade) or math.huge
    end)(),
    brakeTrim = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      local b = d and d.feel and d.feel.brakeTrim   -- boolean: nil -> true (legacy symmetric)
      if b == nil then return true end
      return b
    end)(),
    compassSign = deps.compassSign or (deps.config and deps.config.bindings and deps.config.bindings.compassSign) or 1,
    _needReset = false, _loopHz = 0, noFuel = false,
    -- PARAMS extras (devWarn/disk) ride telemetry only while paramsWatch is on.
    paramsWatch = false, disk = false, devWarn = false, diskPresent = deps.diskPresent,
  }, Flight)
end

-- Live EMRCVR config update (e.g. from BIT/CONFIG or config-sync): merge numeric fields only,
-- leaving unspecified fields (and any non-numeric junk) untouched.
function Flight:setEmrcvrCfg(t)
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do if type(v) == "number" then self.emr[k] = v end end
end

function Flight:handleCommand(cmd)
  local k = cmd and cmd.k
  -- EMRCVR lockout: while recovering, only ENG SW (fuelPump) and FCS engage/disengage are honored.
  -- disengage is the sole abort; the hardware fuel relay + gndSafety interlock remain the physical override.
  if self.emrcvr and not (k == "disengage" or k == "engage" or k == "fuelPump") then
    return false
  end
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
    if self._comKiSaved then self:_restoreComKi() end
    self:_emrAbort()
    self.pilot:setPositionHold(false); self.loop:arm(false); return true
  elseif k == "positionHold" then
    self.positionHold = cmd.on and true or false
    self.pilot:setPositionHold(self.positionHold); return true
  elseif k == "fuelPump" then
    self.fuelPump = cmd.on and true or false; return true
  elseif k == "clearDamped" then
    self.loop:clearDamped(); return true
  elseif k == "fuel" then
    if fueltable.pctOf(cmd.id) then
      self.fuelName = cmd.id
      if self.setFuelScale then self.setFuelScale(fueltable.scaleFor(cmd.id)) end
      if self.saveFuel then self.saveFuel(cmd.id) end
    end
    return true
  elseif k == "flightMode" then
    self:_applyFlightMode(cmd.id)
    return true
    elseif k == "flightTrim" then
    local dir = (cmd.dir and cmd.dir < 0) and -1 or 1
    self.trimDir = dir
    if self.pilot.setTrimDir then self.pilot:setTrimDir(dir) end
    if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain, self.trimAuthority, self.trimFadeStart, self.trimFade, self.brakeTrim) end
    return true
  elseif k == "masterMode" then
    self:_applyMasterMode(cmd.id)
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
  elseif k == "setCom" then
    -- Manual CoM trim from the UI COM screen: apply the offset to the mixer LIVE (same path Auto-CoM
    -- uses on capture) so the operator can fly a hand-set trim immediately, no reboot. Persistence to
    -- the FCS's own config still goes through the config courier.
    if self.loop and self.loop.mixer and self.loop.mixer.setCom then
      self.loop.mixer:setCom({
        fwd = tonumber(cmd.fwd) or 0, right = tonumber(cmd.right) or 0,
        spanFwd = cmd.spanFwd, spanRight = cmd.spanRight,
      })
    end
    return true
  elseif k == "paramsWatch" then
    local on = cmd.on and true or false
    if on and not self.paramsWatch and self.diskPresent then
      self.disk = self.diskPresent() and true or false
    end
    self.paramsWatch = on
    return true
  end
  return false
end

-- Shared mode-transition helpers (pure refactor out of handleCommand's flightMode/masterMode
-- branches -- behavior-preserving). Both are also called directly by _emrExit (below) to drop
-- the craft into a clean CPL/PRECISION hover once recovery completes, without re-parsing a
-- synthetic command.
function Flight:_applyFlightMode(id)
  local reg = self.registry
  local d = reg and reg.byId[id]
  if not d then return end                       -- unknown id: stay on current mode
  if self._comKiSaved and self._comKiSch == self.loop.scheme then
    self:_restoreComKi()                         -- mode switch mid-HOLD: restore BEFORE switching
  end
  self.loop:setActive(d)
  self.pilot:setMode(d.policy, d.feel)
  self.flightMode = id
  -- §3.3 latch wiring: mirror the new descriptor's flags and (re)gate the ground sensor.
  -- self.parked is deliberately left untouched here -- HONOR/CLEAR is step()'s sole authority
  -- (Task 7), so the latch persists across a switch away from LDG.
  self.canPark = d.canPark or false
  self.groundSense = d.groundSense or false
  if self.setGroundSense then self.setGroundSense(self.groundSense) end
  self.trimDir = (d.feel and d.feel.trimDir) or self.trimDir
  self.trimGain = (d.feel and d.feel.trimGain) or self.trimGain
  self.trimAuthority = (d.feel and d.feel.trimAuthority) or self.trimAuthority
  self.trimFadeStart = (d.feel and d.feel.trimFadeStart) or self.trimFadeStart
  self.trimFade = (d.feel and d.feel.trimFade) or self.trimFade
  if d.feel and d.feel.brakeTrim ~= nil then self.brakeTrim = d.feel.brakeTrim end
  if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain, self.trimAuthority, self.trimFadeStart, self.trimFade, self.brakeTrim) end
  -- A1: reseed pilot setpoints from last meas so a CRUISE-leashed surgePos cannot slam
  -- reverse under CPL after the switch. Skip when _lastMeas is nil (boot, before first step).
  if self._lastMeas and self.pilot.reset then self.pilot:reset(self._lastMeas) end
end

function Flight:_applyMasterMode(id)
  local d = Master.byId[id]
  if not d then return end
  self.masterMode = id
  if self.pilot.setMaster then self.pilot:setMaster(d.driftArrest) end
end

-- LDG landed-detector (design §4.3). Permissive, for uneven/tilted ground: parks when the craft is
-- ON the ground (the CALIBRATED onGround flag), drifting only very slightly, rested within the tilt
-- band, and the pilot is hands-off. Only reached in LDG (self.canPark). Autopilot never parks.
function Flight:_ldgLanded(held, meas)
  if self.comAuto and self.comAuto:active() then return false end
  local pk = self.park; if not pk then return false end
  if held and held.up then return false end                         -- climb intent never parks
  if held and (held.pitchUp or held.pitchDown or held.rollLeft or held.rollRight) then
    return false                                                    -- active tilt input
  end
  -- Ground contact = the CALIBRATED onGround flag (backend: optD < onGroundThreshold), NOT the
  -- separate, uncalibrated park.groundClear -- otherwise a craft whose landed optical distance
  -- exceeds the stock groundClear (1.0) never parks and the FCS keeps stabilizing on the pad.
  if meas == nil or meas.onGround ~= true then return false end
  local eps = pk.parkDriftEps or 0.15
  if math.abs(meas.vSpeed or 0) >= eps then return false end
  if math.abs(meas.swayVel or 0) >= eps then return false end
  if math.abs(meas.surgeVel or 0) >= eps then return false end
  local tb = pk.parkTiltBand or 0.12
  if math.abs(meas.pitch or 0) > tb or math.abs(meas.roll or 0) > tb then return false end
  return true
end

-- §11.8 no-fuel interlock. An unfuelled Create thruster HOLDS its commanded level while producing
-- zero thrust, so an integrator flying into an empty tank winds up against a plant that stopped
-- responding. When the (already-polled) gauge reads below minFuel: disarm like disengage (cut
-- demand, restore any comAuto ki, reset loops), latch noFuel, refuse engage until the tank
-- recovers to 2x minFuel. A nil reading (gauge never polled / peripheral gone) never trips --
-- the hardware relay remains the physical arm path; this is the software mirror of it.
-- noFuel is published on the telemetry snapshot (reported state only; UI must not invent it).
function Flight:_checkFuel(meas)
  if not self.fuel then return end
  local frac = self.fuel()
  if frac == nil then return end
  if frac < self.minFuel then
    if not self.noFuel then
      self.noFuel = true
      self.engaged = false
      self.positionHold = false
      if self._comKiSaved then self:_restoreComKi() end
      self:_emrAbort()
      if self.comAuto and self.comAuto.abort then self.comAuto:abort("NOFUEL") end
      if self.pilot.setPositionHold then self.pilot:setPositionHold(false) end
      self.pilot:reset(meas)
      self.loop:arm(false)
    end
  elseif self.noFuel and frac >= self.minFuel * 2 then
    self.noFuel = false   -- refuelled past hysteresis; re-engage is manual
  end
end

-- Restore the comAuto-captured ki values to the EXACT scheme object they were saved from.
-- Scoping the save to its scheme is the whole point: a mode switch mid-HOLD must never write
-- scheme A's tuning into scheme B (the old code cached bare numbers and restored them into
-- whatever scheme happened to be active at the time).
function Flight:_restoreComKi()
  local sch = self._comKiSch
  if sch and sch.pitchPid then
    if self._comKiSaved then
      sch.pitchPid.ki = self._comKiSaved.p
      sch.rollPid.ki = self._comKiSaved.r
    end
  end
  self._comKiSaved = nil
  self._comKiSch = nil
end

-- Shared abort for EVERY path that disarms (self.engaged=false) while EMRCVR is latched. The
-- EMRCVR block in step() is nested inside `if self.engaged`, so once engaged flips false the
-- latch would never run again -- leaving self.emrcvr stranded true (snapshot misreports
-- mode=="EMRCVR" while disarmed) and the elevated recovery kp/caps never restored. Mirrors
-- _emrExit's exact restore shape but WITHOUT the mode-reapply/pilot-handoff: the craft is being
-- disarmed, not handed back to the pilot.
function Flight:_emrAbort()
  if not self.emrcvr then return end
  local sch = self._emrSch
  if sch and self._emrSaved then
    local level = (sch.inner or sch)
    level.pitchPid.kp = self._emrSaved.kp_p; level.rollPid.kp = self._emrSaved.kp_r
    self.loop.caps = self._emrSaved.caps
  end
  self._emrSch, self._emrSaved = nil, nil
  if self.loop.setEmrcvr then self.loop:setEmrcvr(false) end
  self.emrcvr = false; self.emrStableT = 0
end

-- EMRCVR emergency recovery (detect / right / restore / exit). Top priority within `engaged`:
-- an excessive tilt while airborne locks out pilot/UI control, rights the craft with elevated
-- attitude authority, restores altitude, and hands back a clean CPL/PRECISION hover once level
-- and slow for `dwell` seconds. See loop:setEmrcvr (Task 1) for the mirrored, DAMPED-suppressing
-- loop-side mode, and self.emr (Task 2) for the tuning block this reads.
function Flight:_emrEnter(meas)
  self.emrcvr = true
  self.emrcvrAlt = meas.altitude          -- restore target
  self.emrStableT = 0
  if self.comAuto and self.comAuto.abort then self.comAuto:abort("EMRCVR") end
  -- Elevate attitude authority; SCOPE the save to the exact scheme object we mutate (mirrors the
  -- comAuto ki-scoping pattern in _restoreComKi -- a later mode switch must never write the
  -- recovery gain into whatever scheme happens to be active when _emrExit runs).
  -- CRUISE/DRN wrap an inner Level scheme (fcs/schemes/cruise.lua, drone.lua); mirror loop:diag's
  -- `level = scheme.inner or scheme` so the PID objects mutated here are the ones actually driving
  -- the loop.
  local sch = self.loop.scheme
  self._emrSch = sch
  local level = (sch and sch.inner) or sch
  self._emrSaved = { kp_p = level.pitchPid.kp, kp_r = level.rollPid.kp, caps = self.loop.caps }
  level.pitchPid.kp, level.rollPid.kp = self.emr.kpAtt, self.emr.kpAtt
  self.loop.caps = { pitch = self.emr.capAtt, roll = self.emr.capAtt,
                     yaw = self._emrSaved.caps.yaw, sway = self._emrSaved.caps.sway, surge = self._emrSaved.caps.surge }
  if self.loop.setEmrcvr then self.loop:setEmrcvr(true) end
  self.pilot:setPositionHold(false)
end

function Flight:_emrStep(dt, meas)
  local emr = self.emr
  local tiltMag = math.max(math.abs(meas.pitch or 0), math.abs(meas.roll or 0))
  local alt = (tiltMag < emr.levelBand) and self.emrcvrAlt or meas.altitude
  self.loop:setpoints({ pitch = 0, roll = 0, heading = meas.heading,
                        altitude = alt, swayPos = meas.swayPos, surgePos = meas.surgePos })
  self.loop:arm(true)
  local drift = math.sqrt((meas.surgeVel or 0)^2 + (meas.swayVel or 0)^2)
  if math.abs(meas.pitch or 0) < emr.exitAngle and math.abs(meas.roll or 0) < emr.exitAngle
     and drift < emr.maxDrift then
    self.emrStableT = (self.emrStableT or 0) + (dt > 0 and dt or 0)
    if self.emrStableT >= emr.dwell then self:_emrExit(meas) end
  else
    self.emrStableT = 0
  end
end

function Flight:_emrExit(meas)
  -- Restore the exact scheme object (and PID) we mutated -- not whatever is active now.
  local sch = self._emrSch
  if sch and self._emrSaved then
    local level = (sch.inner) or sch
    level.pitchPid.kp = self._emrSaved.kp_p
    level.rollPid.kp = self._emrSaved.kp_r
    self.loop.caps = self._emrSaved.caps
  end
  self._emrSch, self._emrSaved = nil, nil
  if self.loop.setEmrcvr then self.loop:setEmrcvr(false) end
  self.emrcvr = false; self.emrStableT = 0
  self:_applyMasterMode("CPL")            -- clean slate
  self:_applyFlightMode("PRECISION")
  if self.pilot.reset then self.pilot:reset(meas) end
end

function Flight:step(dt, held, meas)
  self._lastMeas = meas
  local autoOn = self.comAuto and self.comAuto:active()
  if autoOn then held = {} end
  self:_checkFuel(meas)
  if self.engaged then
    -- EMRCVR check FIRST: overrides parked/comAuto/pilot below whenever latched, and can latch
    -- fresh this very tick if the trip condition just fired.
    local emr = self.emr
    local tiltMag = math.max(math.abs(meas.pitch or 0), math.abs(meas.roll or 0))
    local airborne = not (meas.onGround == true)
    if self.engaged and not self.emrcvr and airborne and tiltMag > emr.tripAngle then
      self:_emrEnter(meas)
    end
    if self.emrcvr then
      self:_emrStep(dt, meas)
      local r = self.loop:cycle(dt, meas)
      self.lastDiag = r
      if dt > 0 then self._loopHz = 1 / dt end
      return self:snapshot(r, meas)
    end
    if self._needReset then self.pilot:reset(meas); self._needReset = false end
    -- §3.3 global parked latch: HONOR and CLEAR are step()'s sole authority (SET is Task 8's
    -- LDG-only landed-detector, below). Once latched, EVERY mode honors it -- zero control, inputs
    -- ignored -- until the pilot commands a climb, or comAuto goes active. The comAuto clause
    -- matters because comAuto forces held={} above, so held.up alone could never fire while
    -- autopilot is running -- a latched-parked craft could never be un-parked by autopilot, and
    -- Auto-CoM-trim (meant to climb off a landed state) would get silently stuck.
    if self.parked then
      if (held and held.up) or autoOn then
        self.parked = false                                    -- ascend or comAuto un-parks (any mode)
      else
        self.pilot:reset(meas); self.loop:arm(false)            -- honored everywhere: zero control
      end
    end
    if not self.parked then
      if self.canPark and self:_ldgLanded(held, meas) then
        self.parked = true; self.pilot:reset(meas); self.loop:arm(false)
      elseif autoOn then
        local duties = self.lastDiag and self.lastDiag.duties
        local ar = self.comAuto:tick(dt, meas, duties, self.loop:getMode())
        local sch = self.loop.scheme
        if sch and sch.pitchPid then
          if ar.captureKi and ar.captureKi > 0 then
            if not self._comKiSaved then
              self._comKiSch = sch
              self._comKiSaved = { p = sch.pitchPid.ki, r = sch.rollPid.ki }
            end
            if self._comKiSch == sch then   -- never touch a scheme we didn't capture from
              sch.pitchPid.ki = ar.captureKi
              sch.rollPid.ki = ar.captureKi
            end
          elseif self._comKiSaved then
            self:_restoreComKi()
          end
        end
        if ar.captured and self.loop.mixer and self.loop.mixer.setCom then
          self.loop.mixer:setCom({
            fwd = ar.captured.fwd, right = ar.captured.right,
            spanFwd = self.comAuto.spanFwd, spanRight = self.comAuto.spanRight,
          })
          -- Hand-off: the captureKi integral built the level-hold differential during HOLD, and the
          -- mixer now carries that SAME compensation as the measured CoM offset. Leaving the pitch/
          -- roll integrators in place stacks the two (mixer + integral = DOUBLE compensation) -> the
          -- craft over-corrects, tilts off attitude, and the angled lift turns that into a lateral
          -- drift (the descent runaway seen right after a capture). Zero them so only the mixer
          -- carries it -- ki is already restored to 0 for DESCEND, so they stay zero.
          if sch then
            if sch.pitchPid then sch.pitchPid.i = 0 end
            if sch.rollPid then sch.rollPid.i = 0 end
          end
        end
        if ar.setpoints then self.loop:setpoints(ar.setpoints) end
        self.loop:arm(true)
        if ar.done then
          if self._comKiSaved then self:_restoreComKi() end   -- done: leave the scheme as found
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
  if self.loop.setTrim then self.loop:setTrim(self.trimDir, self.trimGain, self.trimAuthority, self.trimFadeStart, self.trimFade, self.brakeTrim) end
  local r = self.loop:cycle(dt, meas)
  self.lastDiag = r   -- exposed for optional flight instrumentation (demands/duties)
  if dt > 0 then self._loopHz = 1 / dt end
  return self:snapshot(r, meas)
end

-- Base snapshot: flags + measurement passthrough. Fuel/thruster detail is added
-- by the runtime wiring (Task D3) which has the backend handle.
function Flight:snapshot(r, meas)
  local m = meas or {}
  local snap = {
    engaged = self.engaged, gndSafety = self.gndSafety,
    positionHold = self.positionHold, fuelPump = self.fuelPump, parked = self.parked,
    noFuel = self.noFuel,
    fuel = self.fuelName, fuelPct = fueltable.pctOf(self.fuelName), badFuel = fueltable.isBad(self.fuelName),
    emrcvr = self.emrcvr and true or false,
    mode = self.emrcvr and "EMRCVR" or (self.parked and "PARKED" or ((r and r.mode) or self.loop:getMode())),
    flightMode = self.flightMode,
    masterMode = self.masterMode,
    trimDir = self.trimDir,
    -- DISPLAY altitude = true-Y baro (baroMsl) so the cockpit ALT matches F3. The control loop
    -- cycles on m.altitude (AGL) independently; only this telemetry field is retargeted. Falls back
    -- to m.altitude when baroMsl is absent (older backends / tests).
    altitude = m.baroMsl or m.altitude, vSpeed = m.vSpeed, heading = m.heading,
    yawRate = m.yawRate, swayPos = m.swayPos, surgePos = m.surgePos,
    pitch = m.pitch, roll = m.roll, surgeVel = m.surgeVel,
    -- Compass bearing (degrees, [0,360)) for displays -- distinct from the radians `heading`
    -- control value above. wrap360 inlined (matches nav/lib/heading.lua's absolute()) to avoid a
    -- cross-package require from fcs/.
    compassHeading = (type(m.rawHeading) == "number")
      and (function(d) d = d % 360; if d < 0 then d = d + 360 end; return d end)((m.rawHeading) * (self.compassSign or 1))
      or nil,
    onGround = m.onGround, loopHz = self._loopHz,
    comAuto = self.comAuto and {
      phase = self.comAuto.phase, abortReason = self.comAuto.abortReason,
      captured = self.comAuto.captured,
    } or nil,
  }
  if self.paramsWatch then
    snap.devWarn = self.devWarn and true or false
    snap.disk = self.disk and true or false
  end
  return snap
end

return Flight
