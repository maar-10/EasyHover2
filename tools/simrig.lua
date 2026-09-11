-- tools/simrig.lua -- closed-loop FCS reproduction rig (headless, dev-only). Flies the PRODUCTION
-- stack (Flight -> Loop -> scheme/mixer -> Level/KeepWarm actuators) against a physics sim that
-- ADDS the three dynamics the base tests/e2e sim omits and which drive the real instability:
--   1. thruster SPOOL ramp (Create Propulsion ~0.5s linear ramp on every power change)
--   2. tilt->translate coupling (pitch -> surge accel, roll -> sway accel: the lift vector tilts)
--   3. off-CoM thruster->attitude coupling (lateral->roll, surge/frontal->pitch: what decouple targets)
-- Params are tunable so the rig can be calibrated to the real flight logs. NOT a unit test; a probe.
local frame    = require("fcs.frame")
local Flight   = require("fcs.runtime.flight")
local Pilot    = require("fcs.input.pilot")
local inputCfg = require("fcs.input.config")
local Master   = require("fcs.modes.master")
local tuning   = require("fcs.tuning")
local hover    = require("tools.hover_test")

local FRONT = { FL = 1, FR = 1, RL = -1, RR = -1 }   -- +1 front -> +pitch (nose-up)
local ROLL  = { FL = 1, FR = -1, RL = 1, RR = -1 }    -- +1 LEFT -> +roll (right-wing-down)
local YAWD  = { YFL = 1, YFR = -1, YRL = -1, YRR = 1 }
local SWAYD = { YFL = 1, YFR = -1, YRL = 1, YRR = -1 }

local Sim = {}
Sim.__index = Sim
local function newSim(p)
  local self = setmetatable({}, Sim)
  self.cfg = { mass = 4, g = 10, fPer = 38.5, inertia = 2, armX = 1, armZ = 1,
               fPerLat = 8, yawInertia = 8, fMain = 20, fFrontal = 10 }
  local pp = p or {}
  for _, k in ipairs({ "mass","inertia","fPer","fPerLat","fMain","fFrontal","armX","armZ","yawInertia" }) do
    if pp[k] then self.cfg[k] = pp[k] end                 -- allow plant-param overrides for calibration
  end
  self.steps = 15
  self.p = p or {}                     -- coupling/spool params
  self.spoolTime = self.p.spoolTime or 0.5
  self.tiltTrans = self.p.tiltTrans or 1.0    -- gain on g*sin(tilt) horizontal accel
  self.latRoll   = self.p.latRoll   or 0.0    -- off-CoM: lateral thruster -> roll moment arm
  self.surgePitch= self.p.surgePitch or 0.0   -- off-CoM: main/frontal -> pitch moment arm
  -- Real-world realism knobs (default off => identical to before, existing tests unaffected):
  self.noiseVel  = self.p.noiseVel  or 0.0    -- +-half-range uniform noise on the sensed velocity (blk/s)
  self.biasVel   = self.p.biasVel   or 0.0    -- constant sway-velocity SENSOR bias (blk/s)
  self.comRoll   = self.p.comRoll   or 0.0    -- constant CoM roll torque (N*m) -- lateral CoM offset
  self.comPitch  = self.p.comPitch  or 0.0    -- constant CoM pitch torque -- fore/aft CoM offset
  self.deadReckon= self.p.deadReckon          -- report dead-reckoned pos from the (noisy) sensed vel (like backend.lua)
  self.drSway, self.drSurge = 0, 0            -- dead-reckoned positions
  self.senseSway, self.senseSurge = 0, 0      -- last sensed (noisy) velocity reported to the FCS
  if self.p.seed then math.randomseed(self.p.seed) end
  self.altitude, self.vSpeed = 0, 0
  self.pitch, self.pitchRate, self.roll, self.rollRate = 0, 0, 0, 0
  self.heading, self.yawRate = 0, 0
  self.swayVel, self.surgeVel, self.swayPos, self.surgePos = 0, 0, 0, 0
  self.target, self.frac = {}, {}
  for _, grp in ipairs({ frame.LIFT, frame.LATERAL, frame.MAIN, frame.FRONTAL }) do
    for _, id in ipairs(grp) do self.target[id] = 0; self.frac[id] = 0 end
  end
  return self
end
function Sim:liftIds() return frame.LIFT end
function Sim:lateralIds() return frame.LATERAL end
function Sim:mainIds() return frame.MAIN end
function Sim:frontalIds() return frame.FRONTAL end
function Sim:setThruster(id, s) self.target[id] = s and 1 or 0 end
function Sim:setThrusterLevel(id, level) self.target[id] = (type(level)=="number") and (level/self.steps) or 0 end
function Sim:setThrusterNormalized(id, v) self.target[id] = (type(v)=="number") and v or 0 end
local function approach(cur, tgt, step) local d = tgt-cur; if d>step then d=step elseif d<-step then d=-step end; return cur+d end
function Sim:step(dt)
  local c = self.cfg
  -- 1. spool ramp: each thruster fraction slews toward its target at 1/spoolTime per second
  local mstep = (self.spoolTime > 0) and (dt / self.spoolTime) or 1e9
  for id, tgt in pairs(self.target) do self.frac[id] = approach(self.frac[id] or 0, tgt, mstep) end
  -- lift -> heave + pitch/roll moments
  local fz, pm, rm = 0, 0, 0
  for _, id in ipairs(frame.LIFT) do
    local f = (self.frac[id] or 0) * c.fPer
    fz = fz + f; pm = pm + f*FRONT[id]*c.armZ; rm = rm + f*ROLL[id]*c.armX
  end
  -- lateral -> yaw + sway thrust (+ off-CoM roll)
  local ym, swayF = 0, 0
  for _, id in ipairs(frame.LATERAL) do
    local f = (self.frac[id] or 0) * c.fPerLat
    ym = ym + YAWD[id]*f; swayF = swayF + SWAYD[id]*f
    rm = rm + self.latRoll * SWAYD[id] * f        -- 3. off-CoM: sway thruster torques roll
  end
  rm = rm + self.comRoll                          -- 4. constant CoM roll torque (lateral CoM offset)
  local pmCom = self.comPitch                     -- constant CoM pitch torque (fore/aft CoM offset)
  -- main/frontal -> surge thrust (+ off-CoM pitch)
  local surgeF = 0
  local fm = (self.frac.MAIN or 0) * c.fMain
  surgeF = surgeF + fm
  pm = pm + self.surgePitch * fm                  -- 3. off-CoM: MAIN torques pitch
  for _, id in ipairs(frame.FRONTAL) do
    local f = (self.frac[id] or 0) * c.fFrontal
    surgeF = surgeF - f
    pm = pm - self.surgePitch * f
  end
  -- accelerations
  local aV = fz/c.mass - c.g
  -- 2. tilt->translate: horizontal component of the (near-vertical) lift vector
  local aSurge = -(fz/c.mass) * math.sin(self.pitch) * self.tiltTrans   -- +pitch(nose-up) -> backward
  local aSway  =  (fz/c.mass) * math.sin(self.roll)  * self.tiltTrans   -- +roll(right-down) -> right
  aSurge = aSurge + surgeF/c.mass
  aSway  = aSway  + swayF/c.mass
  self.vSpeed = self.vSpeed + aV*dt; self.altitude = self.altitude + self.vSpeed*dt
  if self.altitude < 0 then self.altitude = 0; if self.vSpeed < 0 then self.vSpeed = 0 end end
  self.pitchRate = self.pitchRate + ((pm + pmCom)/c.inertia)*dt; self.pitch = self.pitch + self.pitchRate*dt
  self.rollRate  = self.rollRate  + (rm/c.inertia)*dt; self.roll  = self.roll  + self.rollRate*dt
  self.yawRate = self.yawRate + (ym/c.yawInertia)*dt; self.heading = self.heading + self.yawRate*dt
  self.swayVel  = self.swayVel  + aSway*dt;  self.swayPos  = self.swayPos  + self.swayVel*dt
  self.surgeVel = self.surgeVel + aSurge*dt; self.surgePos = self.surgePos + self.surgeVel*dt
  -- Sensor model: the FCS reads a NOISY/biased velocity and (like fcs/io/backend.lua) dead-reckons
  -- position by integrating THAT. This is what the perfect-sensor rig lacked -- the drift source.
  local function noise() return (self.noiseVel > 0) and (self.noiseVel * (2*math.random() - 1)) or 0 end
  self.senseSway  = self.swayVel  + self.biasVel + noise()
  self.senseSurge = self.surgeVel + noise()
  self.drSway  = self.drSway  + self.senseSway  * dt
  self.drSurge = self.drSurge + self.senseSurge * dt
end
function Sim:sensors()
  return { altitude=self.altitude, baroMsl=self.altitude, vSpeed=self.vSpeed,
    pitch=self.pitch, pitchRate=self.pitchRate, roll=self.roll, rollRate=self.rollRate,
    heading=self.heading, rawHeading=math.deg(self.heading), yawRate=self.yawRate,
    swayVel = (self.noiseVel>0 or self.biasVel~=0) and self.senseSway or self.swayVel,
    surgeVel = (self.noiseVel>0) and self.senseSurge or self.surgeVel,
    swayPos = self.deadReckon and self.drSway or self.swayPos,
    surgePos = self.deadReckon and self.drSurge or self.surgePos,
    groundDist=math.max(0,self.altitude), onGround=(self.altitude<=0.001 and math.abs(self.vSpeed)<0.05) }
end

-- toggles: { decouple=bool, trim=bool, tiltBrake=bool } (default all true = production).
local function buildStack(simParams, toggles)
  toggles = toggles or {}
  local function on(k) return toggles[k] ~= false end
  local sim = newSim(simParams)
  local loop, reg = hover.buildLoop(sim)
  if toggles.decoupleGains and loop.setDecouple then loop:setDecouple(toggles.decoupleGains)
  elseif not on("decouple") and loop.setDecouple then loop:setDecouple({ swayRoll=0, surgePitch=0, authority=0 }) end
  -- Isolate each translation->attitude FF on the CRUISE feel BEFORE the mode is selected
  -- (handleCommand flightMode reads it): trim off = trimGain 0; tilt-brake off = enabled false;
  -- brakeTrim forced true/false. CRITICAL: tuning.forMode returns a LIVE ref into the shared
  -- singleton, so we DEEP-COPY the feel and re-point the descriptor -- otherwise an in-place edit
  -- leaks into every later buildStack in the same process (contaminated the isolation matrix).
  local function deep(v) if type(v) ~= "table" then return v end local o = {} for k, x in pairs(v) do o[k] = deep(x) end return o end
  local cru = reg.byId["CRUISE"]
  if cru then
    local cf = deep(cru.feel); cru.feel = cf
    if not on("trim") then cf.trimGain = 0 end
    if toggles.brakeTrim ~= nil then cf.brakeTrim = toggles.brakeTrim end   -- force fwd-only (false) or symmetric (true)
    if not on("tiltBrake") and cf.tiltBrake then cf.tiltBrake.enabled = false end
    if toggles.lead ~= nil then
      local L = toggles.lead or {}
      cf.yawStopLead  = L.yaw;  cf.altStopLead  = L.alt;  cf.swayStopLead  = L.sway
      cf.yawStopMax   = L.yawMax  or cf.yawStopMax
      cf.altStopMax   = L.altMax  or cf.altStopMax
      cf.swayStopMax  = L.swayMax or cf.swayStopMax
    end
  end
  -- B-prototype hook: override attitude/hold gains on the live scheme PIDs (loop.scheme.inner for
  -- CRUISE). Lets the rig sweep "tilt-velocity damping" (pitch/roll kd) and gentler arrest
  -- (surge/sway ks/ka) without touching production tuning. toggles.tune = {pitchKd,rollKd,pitchKp,
  -- rollKp,surgeKs,swayKs,surgeKa,swayKa}.
  if toggles.tune then
    -- Target the CRUISE descriptor's scheme (swapped in by setActive on flightMode CRUISE), NOT
    -- loop.scheme which is still the boot-default (LDG) mode's scheme at build time.
    local cs = reg.byId["CRUISE"] and reg.byId["CRUISE"].scheme
    local lvl = (cs and cs.inner) or cs
    local T = toggles.tune
    if lvl then
      if lvl.pitchPid then lvl.pitchPid.kd = T.pitchKd or lvl.pitchPid.kd; lvl.pitchPid.kp = T.pitchKp or lvl.pitchPid.kp end
      if lvl.rollPid  then lvl.rollPid.kd  = T.rollKd  or lvl.rollPid.kd;  lvl.rollPid.kp  = T.rollKp  or lvl.rollPid.kp end
      if lvl.surgeTc  then lvl.surgeTc.ks  = T.surgeKs or lvl.surgeTc.ks;  lvl.surgeTc.ka  = T.surgeKa or lvl.surgeTc.ka end
      if lvl.swayTc   then lvl.swayTc.ks   = T.swayKs  or lvl.swayTc.ks;   lvl.swayTc.ka   = T.swayKa  or lvl.swayTc.ka end
    end
  end
  local pilot = Pilot.new(inputCfg.default)
  pilot:setMode(reg.byId[reg.default].policy, reg.byId[reg.default].feel)
  pilot:setMaster(Master.byId[Master.default].driftArrest)
  local fuel = 1.0
  local flight = Flight.new({ loop=loop, pilot=pilot, registry=reg, config={bindings={}},
    park=tuning.park, setGroundSense=function() end, fuel=function() return fuel end })
  return { flight=flight, sim=sim, loop=loop, reg=reg, pilot=pilot }
end

local M = {}
M.buildStack = buildStack
M.newSim = newSim
return M
