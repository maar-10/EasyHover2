-- tests/e2e_stress.lua
-- Exhaustive integrated flight/stress harness for EasyHover 2. NOT a unit suite -- it flies the
-- PRODUCTION control stack (Flight runtime -> Loop -> scheme/mixer -> Level 16-step actuator ->
-- a leveled physics sim) headless in CraftOS-PC across a broad matrix of modes, maneuvers, faults
-- and stress, checking per-tick invariants. Returns (ok, reportText). Run via a startup that
-- requires it and writes the report to /results.txt.
local frame     = require("fcs.frame")
local hover     = require("tools.hover_test")
local Flight    = require("fcs.runtime.flight")
local Pilot     = require("fcs.input.pilot")
local inputCfg  = require("fcs.input.config")
local Master    = require("fcs.modes.master")
local tuning    = require("fcs.tuning")

-- ---------------------------------------------------------------------------
-- Report accumulator
-- ---------------------------------------------------------------------------
local R = { lines = {}, fails = 0, checks = 0, scenarios = 0 }
function R:log(s) self.lines[#self.lines + 1] = s end
function R:head(s) self:log(""); self:log("== " .. s .. " ==") end
function R:pass(s) self.checks = self.checks + 1; self:log("  ok   " .. s) end
function R:fail(s) self.checks = self.checks + 1; self.fails = self.fails + 1; self:log("  FAIL " .. s) end
function R:note(s) self:log("       " .. s) end
function R:check(cond, s) if cond then self:pass(s) else self:fail(s) end return cond and true or false end

local function finite(x) return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge end
local KNOWN_MODES = { NORMAL = true, GROUND = true, DAMPED = true, PARKED = true }

-- ---------------------------------------------------------------------------
-- Leveled physics sim: models setThrusterLevel(0..steps) as proportional force so the PRODUCTION
-- Level actuator (setThrusterLevel) drives it. Geometry matches tests/sim.lua. fPer sized so the
-- calibrated hoverDuty (~0.26) actually hovers (mass*g / (4*fPer) = hoverDuty).
-- ---------------------------------------------------------------------------
local FRONT = { FL = 1, FR = 1, RL = -1, RR = -1 }
local ROLL  = { FL = 1, FR = -1, RL = 1, RR = -1 }
local YAWD  = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
local SWAYD = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }
local SimL = {}
SimL.__index = SimL
local function newSim()
  local self = setmetatable({}, SimL)
  self.cfg = { mass = 4, g = 10, fPer = 38.5, inertia = 2, armX = 1, armZ = 1,
               fPerLat = 8, yawInertia = 8, fMain = 20, fFrontal = 10 }
  self.steps = 15
  self.altitude, self.vSpeed = 0, 0
  self.pitch, self.pitchRate, self.roll, self.rollRate = 0, 0, 0, 0
  self.heading, self.yawRate = 0, 0
  self.swayVel, self.surgeVel, self.swayPos, self.surgePos = 0, 0, 0, 0
  self.frac = {}
  for _, grp in ipairs({ frame.LIFT, frame.LATERAL, frame.MAIN, frame.FRONTAL }) do
    for _, id in ipairs(grp) do self.frac[id] = 0 end
  end
  self.maxLevel, self.badLevel = 0, false
  return self
end
function SimL:liftIds() return frame.LIFT end
function SimL:lateralIds() return frame.LATERAL end
function SimL:mainIds() return frame.MAIN end
function SimL:frontalIds() return frame.FRONTAL end
function SimL:setThruster(id, s) self.frac[id] = s and 1 or 0 end
function SimL:setThrusterLevel(id, level)
  if not (type(level) == "number" and level >= 0 and level <= self.steps and level == math.floor(level)) then
    self.badLevel = true
  end
  if type(level) == "number" and level > self.maxLevel then self.maxLevel = level end
  self.frac[id] = (type(level) == "number") and (level / self.steps) or 0
end
function SimL:step(dt)
  local c = self.cfg
  local fz, pm, rm = 0, 0, 0
  for _, id in ipairs(frame.LIFT) do
    local f = (self.frac[id] or 0) * c.fPer
    fz = fz + f; pm = pm + f * FRONT[id] * c.armZ; rm = rm + f * ROLL[id] * c.armX
  end
  local aV = fz / c.mass - c.g
  self.vSpeed = self.vSpeed + aV * dt
  self.altitude = self.altitude + self.vSpeed * dt
  if self.altitude < 0 then self.altitude = 0; if self.vSpeed < 0 then self.vSpeed = 0 end end
  self.pitchRate = self.pitchRate + (pm / c.inertia) * dt; self.pitch = self.pitch + self.pitchRate * dt
  self.rollRate  = self.rollRate  + (rm / c.inertia) * dt; self.roll  = self.roll  + self.rollRate * dt
  local ym, sway = 0, 0
  for _, id in ipairs(frame.LATERAL) do
    local f = (self.frac[id] or 0) * c.fPerLat
    ym = ym + YAWD[id] * f; sway = sway + SWAYD[id] * f
  end
  self.yawRate = self.yawRate + (ym / c.yawInertia) * dt; self.heading = self.heading + self.yawRate * dt
  local surge = 0
  if (self.frac.MAIN or 0) > 0 then surge = surge + (self.frac.MAIN) * c.fMain end
  for _, id in ipairs(frame.FRONTAL) do surge = surge - (self.frac[id] or 0) * c.fFrontal end
  self.swayVel  = self.swayVel  + (sway / c.mass) * dt;  self.swayPos  = self.swayPos  + self.swayVel * dt
  self.surgeVel = self.surgeVel + (surge / c.mass) * dt; self.surgePos = self.surgePos + self.surgeVel * dt
end
function SimL:sensors()
  return { altitude = self.altitude, baroMsl = self.altitude, vSpeed = self.vSpeed,
    pitch = self.pitch, pitchRate = self.pitchRate, roll = self.roll, rollRate = self.rollRate,
    heading = self.heading, rawHeading = math.deg(self.heading), yawRate = self.yawRate,
    swayVel = self.swayVel, surgeVel = self.surgeVel, swayPos = self.swayPos, surgePos = self.surgePos,
    groundDist = math.max(0, self.altitude),
    onGround = (self.altitude <= 0.001 and math.abs(self.vSpeed) < 0.05) }
end

-- ---------------------------------------------------------------------------
-- Build the production stack on the leveled sim.
-- ---------------------------------------------------------------------------
local function buildStack(fuelLevel)
  local sim = newSim()
  local loop, reg = hover.buildLoop(sim)   -- Level actuator, real registry/tuning/schemes/mixer
  local pilot = Pilot.new(inputCfg.default)
  pilot:setMode(reg.byId[reg.default].policy, reg.byId[reg.default].feel)
  pilot:setMaster(Master.byId[Master.default].driftArrest)
  local fuel = fuelLevel
  local flight = Flight.new({ loop = loop, pilot = pilot, registry = reg, config = { bindings = {} },
    park = tuning.park, setGroundSense = function() end,
    fuel = function() return fuel end })
  return { flight = flight, sim = sim, loop = loop, reg = reg, pilot = pilot,
    setFuel = function(v) fuel = v end }
end

-- Per-tick invariant check. Returns violation string or nil.
local function tickViolation(ctx, snap)
  local d = ctx.flight.lastDiag
  for _, k in ipairs({ "altitude", "vSpeed", "pitch", "roll", "heading", "yawRate",
                       "swayPos", "surgePos", "loopHz" }) do
    local v = snap[k]
    if v ~= nil and not finite(v) then return "snapshot." .. k .. " not finite (" .. tostring(v) .. ")" end
  end
  if not KNOWN_MODES[snap.mode] then return "unknown loop mode: " .. tostring(snap.mode) end
  if d then
    if d.demands then
      for k, v in pairs(d.demands) do if not finite(v) then return "demand." .. k .. " not finite" end end
    end
    if d.duties then
      for id, v in pairs(d.duties) do
        if not finite(v) then return "duty." .. id .. " not finite" end
        if v < -1e-6 or v > 1 + 1e-6 then return "duty." .. id .. " out of [0,1]: " .. tostring(v) end
      end
    end
  end
  if ctx.sim.badLevel then return "actuator wrote an out-of-range thruster level" end
  return nil
end

-- Fly `ticks` steps at `dt`, held provided by heldFn(i), collecting metrics + invariant checks.
local function fly(ctx, ticks, dt, heldFn)
  local m = { minAlt = 1e9, maxAlt = -1e9, maxDuty = 0, maxDemand = 0, damped = 0, ticks = 0,
              err = nil, violation = nil, lastSnap = nil }
  for i = 1, ticks do
    local held = heldFn and heldFn(i) or {}
    local ok, snap = pcall(function() return ctx.flight:step(dt, held, ctx.sim:sensors()) end)
    if not ok then m.err = tostring(snap); return m end
    ctx.sim:step(dt)
    m.ticks = i; m.lastSnap = snap
    m.minAlt = math.min(m.minAlt, ctx.sim.altitude); m.maxAlt = math.max(m.maxAlt, ctx.sim.altitude)
    if snap.mode == "DAMPED" then m.damped = m.damped + 1 end
    local d = ctx.flight.lastDiag
    if d and d.duties then for _, v in pairs(d.duties) do if finite(v) then m.maxDuty = math.max(m.maxDuty, v) end end end
    if d and d.demands then for _, v in pairs(d.demands) do if finite(v) then m.maxDemand = math.max(m.maxDemand, math.abs(v)) end end end
    if not m.violation then m.violation = tickViolation(ctx, snap) end
  end
  return m
end

local function engage(ctx) ctx.flight:handleCommand({ k = "gndSafety", on = false }); ctx.flight:handleCommand({ k = "engage" }) end
local function setMode(ctx, id) ctx.flight:handleCommand({ k = "flightMode", id = id }) end
local function setMaster(ctx, id) ctx.flight:handleCommand({ k = "masterMode", id = id }) end

-- ===========================================================================
-- SCENARIO 1: flight-mode x master-mode matrix (climb -> hover -> maneuver)
-- ===========================================================================
local function scMatrix()
  R:head("1. Flight-mode x master-mode matrix (climb/hover/maneuver)")
  local modes = { "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }
  local masters = { "CPL", "DCPL" }
  local maneuver = {   -- per-mode representative hold during the maneuver window
    PRECISION = { yawRight = true }, MAN = { pitchUp = true }, CRUISE = { surgeFwd = true },
    LDG = { swayRight = true }, DRN = { rollRight = true },
  }
  for _, fm in ipairs(modes) do
    for _, mm in ipairs(masters) do
      R.scenarios = R.scenarios + 1
      local ctx = buildStack(1.0)
      setMode(ctx, fm); setMaster(ctx, mm); engage(ctx)
      local climb = fly(ctx, 80, 0.05, function() return { up = true } end)     -- ~4s climb
      local hold  = fly(ctx, 60, 0.05, function() return {} end)                -- settle
      local man   = fly(ctx, 60, 0.05, function() return maneuver[fm] end)      -- maneuver
      local down  = fly(ctx, 80, 0.05, function() return { down = true } end)   -- descend
      local tag = fm .. "/" .. mm
      local err = climb.err or hold.err or man.err or down.err
      local vio = climb.violation or hold.violation or man.violation or down.violation
      R:check(not err, tag .. ": no runtime error" .. (err and (" -> " .. err) or ""))
      R:check(not vio, tag .. ": per-tick invariants hold" .. (vio and (" -> " .. vio) or ""))
      R:check(climb.maxAlt > 3.0, tag .. ": climbed off the pad (maxAlt=" .. string.format("%.1f", climb.maxAlt) .. ")")
      R:check(finite(down.lastSnap and down.lastSnap.altitude), tag .. ": altitude stayed finite through descent")
      R:note(("%s: maxDuty=%.2f maxDemand=%.2f damped=%d ticks=%d")
        :format(tag, math.max(climb.maxDuty, man.maxDuty), math.max(climb.maxDemand, man.maxDemand),
          climb.damped + hold.damped + man.damped + down.damped, climb.ticks + hold.ticks + man.ticks + down.ticks))
    end
  end
end

-- ===========================================================================
-- SCENARIO 2: extreme-input stress (all keys held, long run)
-- ===========================================================================
local function scExtreme()
  R:head("2. Extreme-input stress (all directional keys at once, long run)")
  local allKeys = { up = true, down = true, yawLeft = true, yawRight = true, swayLeft = true,
    swayRight = true, surgeFwd = true, surgeBack = true, pitchUp = true, pitchDown = true,
    rollLeft = true, rollRight = true }
  for _, fm in ipairs({ "PRECISION", "MAN", "DRN" }) do
    R.scenarios = R.scenarios + 1
    local ctx = buildStack(1.0)
    setMode(ctx, fm); engage(ctx)
    local m = fly(ctx, 2000, 0.05, function() return allKeys end)   -- 100s of contradictory input
    R:check(not m.err, fm .. " all-keys: survived 2000 ticks" .. (m.err and (" -> " .. m.err) or ""))
    R:check(not m.violation, fm .. " all-keys: invariants held" .. (m.violation and (" -> " .. m.violation) or ""))
    R:note(("%s all-keys: maxDuty=%.2f maxDemand=%.2f alt[%.1f,%.1f] damped=%d")
      :format(fm, m.maxDuty, m.maxDemand, m.minAlt, m.maxAlt, m.damped))
  end
end

-- ===========================================================================
-- SCENARIO 3: dt discipline (zero / negative / stall / tiny / alternating)
-- ===========================================================================
local function scDt()
  R:head("3. dt discipline (zero, negative, stall>dtMax, tiny, alternating)")
  R.scenarios = R.scenarios + 1
  local ctx = buildStack(1.0)
  setMode(ctx, "PRECISION"); engage(ctx)
  fly(ctx, 40, 0.05, function() return { up = true } end)     -- get airborne first
  local dts = { 0, -0.1, 5.0, 1e-6, 0.05, 5.0, 0, 0.05 }
  local err, vio, maxV = nil, nil, 0
  for pass = 1, 30 do
    for _, dt in ipairs(dts) do
      local ok, snap = pcall(function() return ctx.flight:step(dt, {}, ctx.sim:sensors()) end)
      if not ok then err = tostring(snap); break end
      if dt > 0 then ctx.sim:step(math.min(dt, 0.5)) end
      if not vio then vio = tickViolation(ctx, snap) end
      if finite(ctx.sim.vSpeed) then maxV = math.max(maxV, math.abs(ctx.sim.vSpeed)) end
    end
    if err then break end
  end
  R:check(not err, "dt storm: no runtime error" .. (err and (" -> " .. err) or ""))
  R:check(not vio, "dt storm: invariants held" .. (vio and (" -> " .. vio) or ""))
  R:check(finite(ctx.sim.altitude) and finite(ctx.sim.vSpeed), "state finite after dt storm")
  R:check(maxV < 100, "no derivative kick from stalls (max|vSpeed|=" .. string.format("%.2f", maxV) .. ")")
end

-- ===========================================================================
-- SCENARIO 4: transition stress (engage/disengage, mode switching, CRUISE re-engage F2)
-- ===========================================================================
local function scTransitions()
  R:head("4. Transition stress (engage/disengage, mode switch, CRUISE re-engage)")
  -- 4a: rapid engage/disengage x100
  R.scenarios = R.scenarios + 1
  local ctx = buildStack(1.0)
  setMode(ctx, "PRECISION"); ctx.flight:handleCommand({ k = "gndSafety", on = false })
  local err, vio = nil, nil
  for i = 1, 100 do
    ctx.flight:handleCommand({ k = (i % 2 == 1) and "engage" or "disengage" })
    local ok, snap = pcall(function() return ctx.flight:step(0.05, { up = true }, ctx.sim:sensors()) end)
    if not ok then err = tostring(snap); break end
    ctx.sim:step(0.05); if not vio then vio = tickViolation(ctx, snap) end
  end
  R:check(not err and not vio, "4a rapid engage/disengage x100: clean" .. (err and (" -> " .. err) or "") .. (vio and (" -> " .. vio) or ""))

  -- 4b: rapid mode-switch every 3 ticks through all modes while airborne
  R.scenarios = R.scenarios + 1
  local ctx2 = buildStack(1.0)
  setMode(ctx2, "PRECISION"); engage(ctx2)
  fly(ctx2, 60, 0.05, function() return { up = true } end)
  local order = { "PRECISION", "MAN", "CRUISE", "LDG", "DRN", "CRUISE", "PRECISION" }
  local e2, v2 = nil, nil
  for i = 1, 210 do
    if i % 3 == 1 then setMode(ctx2, order[(math.floor(i / 3) % #order) + 1]) end
    if i % 7 == 0 then setMaster(ctx2, (i % 14 == 0) and "DCPL" or "CPL") end
    local ok, snap = pcall(function() return ctx2.flight:step(0.05, { up = (i % 2 == 0) }, ctx2.sim:sensors()) end)
    if not ok then e2 = tostring(snap); break end
    ctx2.sim:step(0.05); if not v2 then v2 = tickViolation(ctx2, snap) end
  end
  R:check(not e2 and not v2, "4b rapid mode+master switching airborne: clean" .. (e2 and (" -> " .. e2) or "") .. (v2 and (" -> " .. v2) or ""))

  -- 4c: CRUISE detent -> disengage -> re-engage must NOT slam MAIN (F2, integration level)
  R.scenarios = R.scenarios + 1
  local ctx3 = buildStack(1.0)
  setMode(ctx3, "CRUISE"); engage(ctx3)
  fly(ctx3, 40, 0.05, function() return { up = true } end)                 -- airborne
  fly(ctx3, 30, 0.05, function() return { surgeFwd = true } end)           -- build a throttle detent
  local mainAfterDetent = 0
  local d = ctx3.flight.lastDiag; if d and d.duties then mainAfterDetent = d.duties.MAIN or 0 end
  ctx3.flight:handleCommand({ k = "disengage" })
  ctx3.flight:handleCommand({ k = "engage" })
  ctx3.flight:step(0.05, {}, ctx3.sim:sensors())                            -- first armed tick, no W
  local mainReengage = 0
  local d2 = ctx3.flight.lastDiag; if d2 and d2.duties then mainReengage = d2.duties.MAIN or 0 end
  R:check(mainAfterDetent > 0.05, "4c CRUISE built a MAIN detent while W held (MAIN=" .. string.format("%.2f", mainAfterDetent) .. ")")
  R:check(mainReengage < 0.05, "4c re-engage does NOT slam MAIN (MAIN=" .. string.format("%.2f", mainReengage) .. ")")
end

-- ===========================================================================
-- SCENARIO 5: no-fuel interlock (trip + recovery)
-- ===========================================================================
local function scNoFuel()
  R:head("5. No-fuel interlock (trip mid-flight + recovery)")
  R.scenarios = R.scenarios + 1
  local ctx = buildStack(1.0)
  setMode(ctx, "PRECISION"); engage(ctx)
  fly(ctx, 60, 0.05, function() return { up = true } end)
  R:check(ctx.loop.armed, "armed before the fuel trip")
  ctx.setFuel(0.02)                                            -- tank runs dry
  local snap = ctx.flight:step(0.05, {}, ctx.sim:sensors())
  R:check(snap.noFuel == true, "noFuel latched on the snapshot")
  R:check(ctx.flight.engaged == false and ctx.loop.armed == false, "disarmed on the trip")
  R:check(ctx.flight:handleCommand({ k = "engage" }) == false, "engage refused while dry")
  ctx.setFuel(0.5)                                             -- refuel past hysteresis
  ctx.flight:step(0.05, {}, ctx.sim:sensors())
  R:check(ctx.flight.noFuel == false, "noFuel cleared past hysteresis")
  R:check(ctx.flight:handleCommand({ k = "engage" }) == true, "re-engage honored after refuel")
end

-- ===========================================================================
-- SCENARIO 6: Auto-CoM procedure + abort (LDG)
-- ===========================================================================
local function scComAuto()
  R:head("6. Auto-CoM trim procedure + abort (LDG on the pad)")
  -- full procedure
  R.scenarios = R.scenarios + 1
  local ctx = buildStack(1.0)
  setMode(ctx, "LDG"); engage(ctx)
  R:check(ctx.flight:handleCommand({ k = "comAuto", op = "start", spanFwd = 4, spanRight = 3 }) == true,
    "comAuto start accepted (engaged, safety off)")
  local phases, err, vio, done = {}, nil, nil, false
  for i = 1, 1200 do
    local ok, snap = pcall(function() return ctx.flight:step(0.1, {}, ctx.sim:sensors()) end)
    if not ok then err = tostring(snap); break end
    ctx.sim:step(0.1); if not vio then vio = tickViolation(ctx, snap) end
    if snap.comAuto and snap.comAuto.phase then phases[snap.comAuto.phase] = true end
    if not ctx.flight.comAuto or not ctx.flight.comAuto:active() then done = true; break end
  end
  R:check(not err and not vio, "comAuto run: clean" .. (err and (" -> " .. err) or "") .. (vio and (" -> " .. vio) or ""))
  R:check(phases.CLIMB, "reached CLIMB phase")
  R:check(phases.HOLD or phases.DESCEND, "reached HOLD/DESCEND phase")
  R:note("phases seen: " .. (function() local t = {} for k in pairs(phases) do t[#t+1] = k end return table.concat(t, ",") end)())

  -- abort
  R.scenarios = R.scenarios + 1
  local ctx2 = buildStack(1.0)
  setMode(ctx2, "LDG"); engage(ctx2)
  ctx2.flight:handleCommand({ k = "comAuto", op = "start", spanFwd = 4, spanRight = 3 })
  for _ = 1, 20 do ctx2.flight:step(0.1, {}, ctx2.sim:sensors()); ctx2.sim:step(0.1) end
  ctx2.flight:handleCommand({ k = "comAuto", op = "abort" })
  local snap = ctx2.flight:step(0.1, {}, ctx2.sim:sensors())
  R:check(snap.comAuto and (snap.comAuto.phase == "DESCEND" or snap.comAuto.abortReason ~= nil),
    "abort forces a descent/annunciates a reason")
end

-- ===========================================================================
-- SCENARIO 7: oscillation -> DAMPED -> recovery
-- ===========================================================================
local function scDamped()
  R:head("7. Oscillation detector: trip to DAMPED, then recover")
  R.scenarios = R.scenarios + 1
  local ctx = buildStack(1.0)
  setMode(ctx, "PRECISION"); engage(ctx)
  fly(ctx, 40, 0.05, function() return { up = true } end)
  -- Inject a sustained pitch oscillation by forcing sim.pitch to flip each tick.
  local tripped = false
  for i = 1, 60 do
    ctx.sim.pitch = (i % 2 == 0) and 0.5 or -0.5
    local snap = ctx.flight:step(0.05, {}, ctx.sim:sensors())
    if snap.mode == "DAMPED" then tripped = true end
  end
  R:check(tripped, "sustained pitch oscillation trips DAMPED")
  -- Now hold calm and let it auto-recover.
  local recovered = false
  ctx.sim.pitch, ctx.sim.pitchRate = 0, 0
  for _ = 1, 120 do
    ctx.sim.pitch = 0
    local snap = ctx.flight:step(0.05, {}, ctx.sim:sensors())
    ctx.sim:step(0.05)
    if snap.mode ~= "DAMPED" then recovered = true; break end
  end
  R:check(recovered, "auto-recovers out of DAMPED once calm")
  R:check(ctx.flight:handleCommand({ k = "clearDamped" }) == true, "clearDamped command accepted")
end

-- ===========================================================================
-- SCENARIO 8: backend sensor pipeline stress (mock shim: NaN/inf/nil/stall)
-- ===========================================================================
local function scBackend()
  R:head("8. Backend sensor pipeline (NaN/inf/nil/stall injection)")
  local Backend = require("fcs.io.backend")
  local nan = 0 / 0
  -- Programmable fake peripherals + clock.
  local reads = { alt = 10, ang = { 0.1, 0.2 }, nav = 30, vf = 1, vr = 1, vm = 0, opt = 2 }
  local peris = {
    alt = { getHeight = function() return reads.alt end },
    gim = { getAngles = function() return reads.ang end },
    navt = { getRelativeAngle = function() return reads.nav end },
    vfp = { getVelocity = function() return reads.vf end },
    vrp = { getVelocity = function() return reads.vr end },
    vmp = { getVelocity = function() return reads.vm end },
    optp = { getDistance = function() return reads.opt end },
  }
  local shim = { wrap = function(n) return peris[n] end }
  local now = 0
  local cfg = { thrusters = {}, sensors = { altimeter = "alt", gimbal = "gim", navTable = "navt",
      velFront = "vfp", velRear = "vrp", velMedial = "vmp", downOptical = "optp" },
    bindings = { signPitch = 1, signRoll = 1, signHeading = 1, headingScale = 1, gimbalScale = 1,
      gimbalPitchIdx = 1, gimbalRollIdx = 2, signVelFront = 1, signVelRear = 1, signVelMedial = 1,
      signYawRate = 1, yawBaseline = 1, onGroundThreshold = 1.5 } }
  local be = Backend.new(shim, cfg, function() return now end)
  be:setGroundSense(true)

  R.scenarios = R.scenarios + 1
  now = 100; local s0 = be:sensors()                     -- first good sample
  now = 200; local s1 = be:sensors()                     -- establishes last-good
  R:check(finite(s1.heading) and finite(s1.pitch) and finite(s1.altitude), "clean reads produce finite sensors")

  reads.nav = nan; reads.alt = nan; reads.ang = { nan, nan }; reads.vf = math.huge
  now = 300; local sBad = be:sensors()
  R:check(finite(sBad.heading) and finite(sBad.pitch) and finite(sBad.roll) and finite(sBad.altitude)
    and finite(sBad.yawRate) and finite(sBad.vSpeed), "NaN/inf reads held to last-good (all finite)")

  reads.nav = nil                                        -- documented nav-table nil (F4 reality)
  local okNil, sNil = pcall(function() return be:sensors() end)
  R:check(okNil, "nil nav heading does not throw")
  R:check(okNil and finite(sNil.heading), "nil nav heading yields a finite value")

  -- Establish a STEADY state (constant altitude over several normal-dt samples) so vFilt settles
  -- to ~0, THEN stall. A correct backend holds the last vSpeed on dt>MAX and must NOT divide the
  -- large altitude change by the large gap (that would be a spurious derivative kick).
  reads.nav = 45; reads.alt = 12; reads.ang = { 0.1, 0.2 }; reads.vf = 1
  now = 400; be:sensors(); now = 450; be:sensors(); now = 500
  local sSteady = be:sensors()
  R:check(finite(sSteady.vSpeed) and math.abs(sSteady.vSpeed) < 1, "steady altitude => ~zero vSpeed")
  reads.alt = 62                                          -- 50-block jump...
  now = 100500; local sStall = be:sensors()              -- ...across a 100s clock gap (stall > MAX)
  R:check(finite(sStall.vSpeed) and math.abs(sStall.vSpeed) < 5,
    "sensor stall (dt>MAX) holds last vSpeed, no kick from the gap (vSpeed=" .. string.format("%.2f", sStall.vSpeed) .. ")")

  now = 100550; be:sensors(); now = 100600
  reads.vm = 2; local sInt = be:sensors()
  R:check(finite(sInt.surgePos) and finite(sInt.swayPos), "position integration stays finite across resumed sampling")
end

-- ===========================================================================
-- SCENARIO 9: comms round-trip stress (telemetry/command/health/protocol)
-- ===========================================================================
local function scComms()
  R:head("9. Comms round-trip stress (telemetry/command/health/protocol)")
  local telemetry = require("fcs.comms.telemetry")
  local command   = require("fcs.comms.command")
  local health    = require("fcs.comms.health")

  -- telemetry round-trip over many varied snapshots, THROUGH serialize/unserialize (the wire format)
  R.scenarios = R.scenarios + 1
  local tx, rx = telemetry.Tx.new(), telemetry.Rx.new()
  local accepted, serErr = 0, nil
  for i = 1, 500 do
    local snap = { engaged = (i % 2 == 0), mode = ({ "NORMAL", "DAMPED", "GROUND", "PARKED" })[(i % 4) + 1],
      flightMode = ({ "PRECISION", "MAN", "CRUISE", "LDG", "DRN" })[(i % 5) + 1],
      altitude = i * 0.5 - 100, heading = (i % 360), vSpeed = -i * 0.01, fuelPct = i % 200,
      pitch = math.sin(i) * 0.4, roll = math.cos(i) * 0.4, loopHz = 15 + (i % 5) }
    local ok = pcall(function()
      local wire = textutils.serialise(tx:frame(snap))       -- exactly what the modem transmits
      local back = textutils.unserialise(wire)
      if rx:accept(back) then accepted = accepted + 1 end
    end)
    if not ok then serErr = "serialize/accept threw at i=" .. i; break end
  end
  R:check(not serErr, "telemetry: 500 snapshots survive serialize->wire->accept" .. (serErr and (" -> " .. serErr) or ""))
  R:check(accepted == 500, "telemetry Rx accepted every in-order frame (accepted=" .. accepted .. "/500)")
  R:check(rx:latest() ~= nil and rx:latest().flightMode ~= nil, "Rx:latest() carries the last snapshot")

  -- command receive + dedup + ack (real frame shape: {k=cmd, sid, id, cmd})
  R.scenarios = R.scenarios + 1
  local recv = command.Receiver.new()
  local applied = 0
  local ack
  for _ = 1, 5 do   -- 5 identical retries of id=1: apply exactly once
    ack = recv:receive({ k = "cmd", sid = "s1", id = 1, cmd = { k = "gndSafety", on = false } },
      function() applied = applied + 1 end)
  end
  recv:receive({ k = "cmd", sid = "s1", id = 2, cmd = { k = "engage" } }, function() applied = applied + 1 end)
  R:check(applied == 2, "dedup: 5 identical id=1 frames + one id=2 => 2 applies (got " .. applied .. ")")
  R:check(type(ack) == "table" and ack.k == "ack" and ack.id == 1, "receiver returns a well-formed ack")

  -- new session id (reboot) is NOT swallowed by the old handled set
  R.scenarios = R.scenarios + 1
  local appliedReboot = 0
  recv:receive({ k = "cmd", sid = "s2", id = 1, cmd = { k = "engage" } }, function() appliedReboot = appliedReboot + 1 end)
  R:check(appliedReboot == 1, "restarted sender (new sid, id=1) is applied, not mistaken for a dup")

  -- malformed frames must not throw and must not apply
  R.scenarios = R.scenarios + 1
  local okm, spurious = true, 0
  for _, bad in ipairs({ {}, { k = "cmd" }, { k = "cmd", id = "x" }, { k = "tel", id = 1 }, "garbage", 42, false }) do
    local ok = pcall(function() recv:receive(bad, function() spurious = spurious + 1 end) end)
    if not ok then okm = false end
  end
  R:check(okm, "malformed command frames handled without throwing")
  R:check(spurious == 0, "malformed frames apply nothing (spurious applies=" .. spurious .. ")")

  -- Sender retry cap: a pending command with the FCS down is retried maxRetries then DROPPED
  R.scenarios = R.scenarios + 1
  local snd = command.Sender.new({ timeout = 1.0, maxRetries = 4 })
  snd:send({ k = "engage" })
  local totalDue, dropped = 0, {}
  for _ = 1, 10 do local due, drop = snd:tick(2.0); totalDue = totalDue + #due; for _, f in ipairs(drop) do dropped[#dropped + 1] = f end end
  R:check(#dropped == 1, "sender drops a command after maxRetries (dropped=" .. #dropped .. ", retries seen=" .. totalDue .. ")")

  -- health heartbeat cadence
  R.scenarios = R.scenarios + 1
  local hb = health.Tx.new({ period = 1.0 })
  local beats = 0
  for i = 0, 50 do if hb:beat(i * 0.25) then beats = beats + 1 end end
  R:check(beats > 0 and beats <= 20, "health heartbeat fires on cadence (beats=" .. beats .. " over ~12.5s @1s)")
end

-- ---------------------------------------------------------------------------
local function run()
  R:log("EasyHover 2 -- exhaustive integrated flight/stress harness")
  R:log("Stack: Flight runtime -> Loop -> scheme/mixer -> Level(16-step) -> leveled physics sim")
  local scenarios = { scMatrix, scExtreme, scDt, scTransitions, scNoFuel, scComAuto, scDamped, scBackend, scComms }
  for _, sc in ipairs(scenarios) do
    local ok, err = pcall(sc)
    if not ok then R:fail("scenario crashed: " .. tostring(err)) end
  end
  R:log("")
  R:log(("SUMMARY: %d checks, %d failed, across %d scenario-configs")
    :format(R.checks, R.fails, R.scenarios))
  return R.fails == 0, table.concat(R.lines, "\n")
end

return { run = run }
