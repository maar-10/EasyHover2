-- ui/basalt/bitconfig/senscal.lua
-- SENS CAL sub-menu (BIT/CONFIG hub, screen id "senscal"): the native-Basalt guided sensor
-- calibration -- a reskin of the terminal tool tools/calibrate.lua's guided flow. Reads the
-- FCS's live devbind (sensor names) + senscal (starting scaffold) via ui.basalt.cfgseam and
-- SAVE ships a senscal `set` to the running FCS (which persists it and materializes the
-- devbind sibling). MUST still produce a byte-identical body to the terminal tool for the
-- same samples (enforced by the PARITY test in tests/test_bitconfig_senscal.lua).
--
-- This module REUSES, rather than reimplements:
--   * fcs/io/calibration.lua's pure cal.classifyGimbalAxis/classifyLateralPair/
--     classifyScalarSign/headingSignScale/computeHeightOffset/computeGroundThreshold -- the
--     SAME classify calls the terminal tool makes.
--   * tools/calibrate.lua's pure M.average/M.peakByAbs/M.argmaxAbs/M.apply* helpers and its
--     M.stream sleep-loop sampler.
-- Byte-identical parity depends on BOTH sides calling the SAME classify/apply functions on a
-- cfgspec.merge("senscal", ...)-scaffolded flat bindings table, mutating EXISTING keys only
-- (never inserting a new key -- see ui/basalt/bitconfig/mdb.lua's header for the full no-rehash
-- rationale: textutils.serialise output depends on table hash-layout, and cfgspec.merge always
-- rebuilds its output by iterating the FRESH cfgspec.defaults(...) call's own pairs() order, so
-- it -- and only it -- is safe to use as the starting scaffold).
--
-- ===== PURE STEP MODEL (M.steps()) =====
-- Six ordered guided steps: attitude (pitch+roll), lateral, surge, heading, ground, constants.
-- Each step descriptor is { id, label, prompts, capture(samples), accept(result), apply(cfg,
-- result) }. `capture`/`apply` are PURE: samples/result in, a classify result / a new-ish cfg
-- out -- no peripheral access, no read()/write(), no Basalt. `prompts` is the ORDERED list of
-- operator instruction strings for this step's guided phases (mirrors the terminal tool's
-- print()/read() prompts one-for-one; the Basalt runner below shows prompts[phaseIdx] and walks
-- the list one CAPTURE press at a time).
--
-- ===== BASALT RUNNER (M.build) =====
-- M.build() wires a step-runner UI: a per-phase CAPTURE button that samples the bound sensors
-- (from eh2_devbind) over the phase's duration on a basalt.schedule coroutine (non-blocking --
-- sleep() works inside a scheduled coroutine per ui/basalt/app.lua's M.startScheduled header notes
-- and release/basalt-full.lua's b_a.schedule/bca dispatch, verified against source), reduces the
-- raw stream into that phase's contribution to `samples`, and once every phase for the current
-- step is captured, computes `step.capture(samples)`, gates on `step.accept(result)`, and shows
-- OK/X (accept/reject). OK calls `step.apply(cfg, result)` and advances to the next step; X
-- discards the step's in-progress samples and restarts its phases. SAVE calls
-- `cfgspec.save("senscal", cfg.bindings, write)`. Default read/write come from cfgseam (FCS
-- cache + cfgClient); CAPTURE sampler stays LOCAL. Read/write/sampler are injected
-- (5th/6th/7th M.build args) so tests drive this without real peripherals/FCS; the
-- "constants" step needs no sensors at all (operator-entered numbers) and uses a +/-
-- stepper instead of CAPTURE, matching tools/calibrate.lua's stepConstants prompt-for-a-number
-- flow.
--
-- ===== UI SHAPE: step-list overview + per-step screens (ui/basalt/region.lua) =====
-- The old flat build crammed the header/prompt/status/value/minus/plus/CAPTURE/ACCEPT/REJECT/
-- STEP-nav/SAVE/BACK rows onto ONE screen -- 9 rows deep, overrunning the ~12-row monitor budget
-- once a title margin and page-level header are accounted for. M.build now hosts a region.lua
-- drilldown (root "steplist") INSIDE this page's own frame, below a static "SENS CAL" headerLabel
-- (mirrors mdb.lua/uical.lua's overview->sub-screen construction exactly):
--   * "steplist": one button per M.steps() entry (a "[x]"/"[ ] " done/pending marker + its label),
--     plus a SAVE/"<" footer row. Tapping a step button walks the controller to that step via
--     REPEATED ctrl.nextStep()/prevStep() calls (the SAME single-step nav the old STEP </> buttons
--     already exposed -- just composed to reach an arbitrary target step from the list) and pushes
--     that step's screen. "<" pops the FRAME-level nav (same as the old BACK button).
--   * "step_<id>" (one per step, all built from the SAME generic builder since there is only ever
--     ONE active controller step at a time): the step's title (N/6 LABEL), current phase's prompt
--     (via configkit.fitLabel), a status line, a value line, then FOUR SEPARATE rows -- minus/plus,
--     CAPTURE (relabelled SET for the numeric "constants" step), OK/X, and "< STEP"/"STEP >" -- so
--     no row crams more buttons than fit its width (the old single 3-button CAPTURE row clipped
--     "CAPTURE"'s label once minus+plus ate most of a 14-col line). A final "< LIST" row pops the
--     REGION's own nav back to the step list (never the frame-level nav). Every ctrl-mutating
--     handler calls a shared syncAndRefresh() that (a) re-targets the region's visible screen to
--     "step_" .. ctrl.step().id if STEP </> or OK moved the controller to a different step, then
--     (b) forces an immediate repaint -- so the visible screen always reflects the controller's
--     live state, exactly like the old flat UI's unconditional refresh() after every click.
-- `completed` (a plain id->true set, UI-side only) tracks which steps have had a successful OK --
-- the controller itself has no notion of "done" (accept() on the LAST step re-arms it for a redo,
-- matching the OLD flat UI's behaviour byte-for-byte), so completion is derived here, not stored
-- on `ctrl`.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.senscal")` loads clean headless.

local cal       = require("fcs.io.calibration")
local calibrate = require("tools.calibrate")
local cfgspec   = require("fcs.io.cfgspec")
local shim      = require("fcs.io.shim")
local Region    = require("ui.basalt.region")
local configkit = require("ui.basalt.configkit")
local switchbtn = require("ui.basalt.switchbtn")
local cfgseam   = require("ui.basalt.cfgseam")

local M = {}
M.id = "senscal"
M.title = "SENS CAL"

-- ===================================================================================
-- ===== PURE per-step capture/accept/apply, one-for-one with tools/calibrate.lua's =====
-- ===== stepAttitude/stepLateral/stepSurge/stepHeading/stepGround/stepConstants.   =====
-- ===================================================================================

-- ---- attitude: pitch AND roll, each via cal.classifyGimbalAxis(neutral, tilted) ----
local function attitudeCapture(samples)
  local pitch = cal.classifyGimbalAxis(samples.pitchNeutral, samples.pitchTilted)
  local roll  = cal.classifyGimbalAxis(samples.rollNeutral, samples.rollTilted)
  return { pitch = pitch, roll = roll }
end
local function attitudeAccept(result)
  return result.pitch.status == "ok" and result.roll.status == "ok"
end
local function attitudeApply(cfg, result)
  calibrate.applyGimbal(cfg, "pitch", result.pitch)
  calibrate.applyGimbal(cfg, "roll", result.roll)
  return cfg
end

-- ---- lateral: cal.classifyLateralPair(neutral, sway, yaw) ----
local function lateralCapture(samples)
  return cal.classifyLateralPair(samples.neutral, samples.sway, samples.yaw)
end
local function lateralAccept(result)
  return result.swayOk and result.yawOk
end
local function lateralApply(cfg, result)
  return calibrate.applyLateral(cfg, result)
end

-- ---- surge: cal.classifyScalarSign(0, peakV) where peakV is the peak of (reading - neutral) ----
local function surgeCapture(samples)
  local offs = {}
  for i, r in ipairs(samples.readings) do offs[i] = r - (samples.neutral or 0) end
  local peakV = calibrate.peakByAbs(offs)
  return cal.classifyScalarSign(0, peakV)
end
local function surgeAccept(result)
  return result.status == "ok"
end
local function surgeApply(cfg, result)
  return calibrate.applyScalarSign(cfg, "signVelMedial", result.sign)
end

-- ---- heading: cal.headingSignScale(neutral, final, yawPeak-during-the-SAME-rotation) ----
local function headingCapture(samples)
  local n = calibrate.average(samples.neutralReadings)
  local heads = samples.rotation.headings
  local m = heads[#heads]
  local yawPeak = calibrate.peakByAbs(samples.rotation.yaws)
  return cal.headingSignScale(n, m, yawPeak)
end
local function headingAccept(result)
  return result.status == "ok"
end
local function headingApply(cfg, result)
  return calibrate.applyHeading(cfg, result)
end

-- ---- ground: cal.computeHeightOffset / cal.computeGroundThreshold ----
local function groundCapture(samples)
  local rawAlt = calibrate.average(samples.altReadings)
  local optD = calibrate.average(samples.optReadings)
  local off = cal.computeHeightOffset(rawAlt, samples.baroThrusterOffset or 0)
  local thr = cal.computeGroundThreshold(optD)
  return { heightOffset = off, onGroundThreshold = thr }
end
local function groundAccept(_result)
  return true -- terminal tool's stepGround has no computed status, only a manual accept? (y/n)
end
local function groundApply(cfg, result)
  return calibrate.applyGround(cfg, result.heightOffset, result.onGroundThreshold)
end

-- ---- constants: operator-entered numbers, no classify call ----
local function constantsCapture(samples)
  return { yawBaseline = samples.yawBaseline, baroThrusterOffset = samples.baroThrusterOffset }
end
local function constantsAccept(_result)
  return true -- terminal tool's stepConstants has no gating either
end
local function constantsApply(cfg, result)
  return calibrate.applyConstants(cfg, result.yawBaseline, result.baroThrusterOffset)
end

-- ===== M.steps(): fresh ordered list every call. PURE -- no shared mutable state. =====
function M.steps()
  return {
    {
      id = "attitude", label = "PITCH/ROLL",
      prompts = {
        "Hold craft LEVEL, press CAPTURE (pitch neutral)",
        "Tilt NOSE UP ~20 deg and HOLD, press CAPTURE",
        "Hold craft LEVEL, press CAPTURE (roll neutral)",
        "Roll RIGHT WING DOWN ~20 deg and HOLD, press CAPTURE",
      },
      capture = attitudeCapture, accept = attitudeAccept, apply = attitudeApply,
    },
    {
      id = "lateral", label = "LATERAL",
      prompts = {
        "Hold still, press CAPTURE (neutral)",
        "SHOVE craft to its RIGHT, press CAPTURE then shove for 3s",
        "YAW nose to the RIGHT, press CAPTURE then yaw for 3s",
      },
      capture = lateralCapture, accept = lateralAccept, apply = lateralApply,
    },
    {
      id = "surge", label = "SURGE",
      prompts = {
        "Hold still, press CAPTURE (neutral)",
        "SHOVE craft FORWARD, press CAPTURE then shove for 3s",
      },
      capture = surgeCapture, accept = surgeAccept, apply = surgeApply,
    },
    {
      id = "heading", label = "HEADING",
      prompts = {
        "Face craft at reference heading, hold still, press CAPTURE",
        "Rotate NOSE ~90 deg to the RIGHT over ~3s -- KEEP IT MOVING, press CAPTURE",
      },
      capture = headingCapture, accept = headingAccept, apply = headingApply,
    },
    {
      id = "ground", label = "GROUND",
      prompts = {
        "Set craft ON THE GROUND at rest, press CAPTURE (altimeter)",
        "Set craft ON THE GROUND at rest, press CAPTURE (optical)",
      },
      capture = groundCapture, accept = groundAccept, apply = groundApply,
    },
    {
      id = "constants", label = "CONSTANTS",
      prompts = {
        "yawBaseline (fore/aft sensor spacing, blocks)",
        "baroThrusterOffset (+ = baro above thrusters, blocks)",
      },
      capture = constantsCapture, accept = constantsAccept, apply = constantsApply,
    },
  }
end

-- ===== M._save: TESTABLE, Basalt-free seam. =====
function M._save(cfg, write)
  return cfgspec.save("senscal", cfg.bindings, write)
end

-- =====================================================================================
-- ===== BASALT RUNNER: per-phase sampling reducers + the real (non-test) sampler.   =====
-- =====================================================================================

-- Reuses tools/calibrate.lua's M.readNum/M.readYawRate (exported additively from that module)
-- instead of keeping copy-pasted duplicates here -- readYawRate is exactly as tools/calibrate.lua's
-- local readYawRate computes it (and as fcs/io/backend.lua does at runtime), so heading's
-- cross-check sampler sees the SAME signal.
local readNum = calibrate.readNum
local readYawRate = calibrate.readYawRate

local function reduceAvgAngles(rawStream)
  local a, b = {}, {}
  for i, s in ipairs(rawStream) do a[i] = s[1] or 0; b[i] = s[2] or 0 end
  return { calibrate.average(a), calibrate.average(b) }
end

local function reduceAvgPair(rawStream)
  local f, r = {}, {}
  for i, s in ipairs(rawStream) do f[i] = s.front or 0; r[i] = s.rear or 0 end
  return { front = calibrate.average(f), rear = calibrate.average(r) }
end

-- Mirrors tools/calibrate.lua's local peak(samples, proj): pick the raw sample whose
-- proj(front-nF, rear-nR) has the largest magnitude, via calibrate.argmaxAbs (M.argmaxAbs).
local function reducePeakPair(proj)
  return function(rawStream, soFar)
    local base = (soFar and soFar.neutral) or { front = 0, rear = 0 }
    local vals = {}
    for i, s in ipairs(rawStream) do
      vals[i] = proj((s.front or 0) - (base.front or 0), (s.rear or 0) - (base.rear or 0))
    end
    return rawStream[calibrate.argmaxAbs(vals)] or base
  end
end

local function reduceIdentity(rawStream) return rawStream end

local function reduceHeadingRotation(rawStream)
  local heads, yaws = {}, {}
  for i, s in ipairs(rawStream) do heads[i] = s.heading or 0; yaws[i] = s.yaw or 0 end
  return { headings = heads, yaws = yaws }
end

-- PHASE_SPECS: per-step ordered phase list driving the CAPTURE flow. Each "stream" phase names
-- the devbind sensor keys it needs, a duration (seconds), and a reduce(rawStream, phaseSamplesSoFar)
-- that turns the raw stream into that phase's contribution to `samples[key]` -- purely a UI-side
-- convenience for assembling the SAME `samples` shape the pure capture() functions above expect;
-- it never touches classify/apply logic itself. "numeric" phases (constants step only) have no
-- sensors -- the operator adjusts a value with +/- and CAPTURE just records it.
local PHASE_SPECS = {
  attitude = {
    { key = "pitchNeutral", kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "pitchTilted",  kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "rollNeutral",  kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
    { key = "rollTilted",   kind = "stream", duration = 1, sensors = { "gimbal" }, reduce = reduceAvgAngles },
  },
  lateral = {
    { key = "neutral", kind = "stream", duration = 1, sensors = { "velFront", "velRear" }, reduce = reduceAvgPair },
    { key = "sway",     kind = "stream", duration = 3, sensors = { "velFront", "velRear" },
      reduce = reducePeakPair(function(df, dr) return df + dr end) },
    { key = "yaw",      kind = "stream", duration = 3, sensors = { "velFront", "velRear" },
      reduce = reducePeakPair(function(df, dr) return df - dr end) },
  },
  surge = {
    { key = "neutral",  kind = "stream", duration = 1, sensors = { "velMedial" }, reduce = function(s) return calibrate.average(s) end },
    { key = "readings", kind = "stream", duration = 3, sensors = { "velMedial" }, reduce = reduceIdentity },
  },
  heading = {
    { key = "neutralReadings", kind = "stream", duration = 1, sensors = { "navTable" }, reduce = reduceIdentity },
    { key = "rotation",        kind = "stream", duration = 3, sensors = { "navTable", "velFront", "velRear" }, reduce = reduceHeadingRotation },
  },
  ground = {
    { key = "altReadings", kind = "stream", duration = 1, sensors = { "altimeter" },   reduce = reduceIdentity },
    { key = "optReadings", kind = "stream", duration = 1, sensors = { "downOptical" }, reduce = reduceIdentity },
  },
  constants = {
    { key = "yawBaseline",         kind = "numeric", step = 1, cfgKey = "yawBaseline" },
    { key = "baroThrusterOffset",  kind = "numeric", step = 1, cfgKey = "baroThrusterOffset" },
  },
}
M._PHASE_SPECS = PHASE_SPECS

-- =====================================================================================
-- ===== M.newController: Basalt-free step-runner state machine.                     =====
-- ===== TESTABLE without Basalt/schedule/sleep -- the ONLY thing it does NOT do is    =====
-- ===== sampling itself: the caller (M.build's CAPTURE handler, or a test) hands it   =====
-- ===== an already-collected raw stream for "stream" phases via :captureStream(raw).  =====
-- =====================================================================================
-- cfg: {bindings=...} working senscal cfg (a defaults-scaffolded flat bindings table, e.g.
--      cfgspec.merge("senscal", cfgspec.load("senscal", read))). steps: M.steps()'s result.
function M.newController(cfg, steps)
  local self = { cfg = cfg, steps = steps, stepIdx = 1, phaseIdx = 1, phaseSamples = {}, result = nil, numericValue = 0 }
  local C = {}

  local function phases() return PHASE_SPECS[self.steps[self.stepIdx].id] end
  local function curPhase() return phases()[self.phaseIdx] end

  function C.step() return self.steps[self.stepIdx] end
  function C.phase() return curPhase() end
  function C.phases() return phases() end
  function C.stepIdx() return self.stepIdx end
  function C.phaseIdx() return self.phaseIdx end
  function C.result() return self.result end
  function C.cfg() return self.cfg end
  function C.numericValue() return self.numericValue end

  local function resetStepState()
    self.phaseIdx = 1
    self.phaseSamples = {}
    self.result = nil
    local p = curPhase()
    if p and p.kind == "numeric" then self.numericValue = self.cfg.bindings[p.cfgKey] or 0 end
  end
  C.resetStepState = resetStepState
  resetStepState()

  local function finishPhase()
    local ps = phases()
    if self.phaseIdx < #ps then
      self.phaseIdx = self.phaseIdx + 1
      local p = curPhase()
      if p.kind == "numeric" then self.numericValue = self.cfg.bindings[p.cfgKey] or 0 end
    else
      local step = C.step()
      local samples = self.phaseSamples
      if step.id == "ground" then samples.baroThrusterOffset = self.cfg.bindings.baroThrusterOffset end
      self.result = step.capture(samples)
    end
  end

  -- Capture the current STREAM phase given its already-sampled raw stream. Sampling itself
  -- (peripheral reads + sleep-loop timing) is the Basalt runner's job -- see M.build's
  -- captureBtn handler, which gathers `raw` on a basalt.schedule coroutine via the injected
  -- sampler and then calls this.
  function C.captureStream(rawStream)
    local p = curPhase()
    if not p or p.kind ~= "stream" then return end
    self.phaseSamples[p.key] = p.reduce(rawStream, self.phaseSamples)
    finishPhase()
  end

  -- Capture the current NUMERIC phase's value (constants step only).
  function C.captureNumeric()
    local p = curPhase()
    if not p or p.kind ~= "numeric" then return end
    self.phaseSamples[p.key] = self.numericValue
    finishPhase()
  end

  function C.adjustNumeric(delta)
    local p = curPhase()
    if p and p.kind == "numeric" then self.numericValue = self.numericValue + delta * (p.step or 1) end
  end

  -- Accept the computed result (if any) and gated ok by step.accept: applies it (step.apply,
  -- via the SAME M.apply* helpers tools/calibrate.lua's terminal steps use) and advances to the
  -- next step. Returns true iff it actually advanced.
  function C.accept()
    local step = C.step()
    if self.result ~= nil and step.accept(self.result) then
      self.cfg = step.apply(self.cfg, self.result)
      if self.stepIdx < #self.steps then self.stepIdx = self.stepIdx + 1 end
      resetStepState()
      return true
    end
    return false
  end

  function C.reject() resetStepState() end

  function C.nextStep()
    if self.stepIdx < #self.steps then self.stepIdx = self.stepIdx + 1 end
    resetStepState()
  end
  function C.prevStep()
    if self.stepIdx > 1 then self.stepIdx = self.stepIdx - 1 end
    resetStepState()
  end

  return C
end

-- realSampler(stepId, phase, wrapped, cfg) -> raw stream for that phase. Uses calibrate.stream
-- (tools/calibrate.lua's M.stream) so the sleep-loop sampling is REUSED, not reimplemented.
-- `wrapped` is a { sensorKey -> wrapped peripheral (or nil) } table for phase.sensors.
local function realSampler(stepId, phase, wrapped, cfg)
  if stepId == "attitude" then
    return calibrate.stream(function()
      local g = wrapped.gimbal
      return (g and g.getAngles()) or { 0, 0 }
    end, phase.duration)
  elseif stepId == "lateral" then
    return calibrate.stream(function()
      return { front = readNum(wrapped.velFront, "getVelocity"), rear = readNum(wrapped.velRear, "getVelocity") }
    end, phase.duration)
  elseif stepId == "surge" then
    return calibrate.stream(function()
      return readNum(wrapped.velMedial, "getVelocity")
    end, phase.duration)
  elseif stepId == "heading" then
    if phase.key == "neutralReadings" then
      return calibrate.stream(function()
        return readNum(wrapped.navTable, "getRelativeAngle")
      end, phase.duration)
    else
      local b = cfg.bindings
      return calibrate.stream(function()
        return { heading = readNum(wrapped.navTable, "getRelativeAngle"), yaw = readYawRate(wrapped.velFront, wrapped.velRear, b) }
      end, phase.duration)
    end
  elseif stepId == "ground" then
    if phase.key == "altReadings" then
      return calibrate.stream(function()
        return readNum(wrapped.altimeter, "getHeight")
      end, phase.duration)
    else
      return calibrate.stream(function()
        return readNum(wrapped.downOptical, "getDistance")
      end, phase.duration)
    end
  end
  return {}
end
M._realSampler = realSampler

-- ===== M.build: construct the step-list overview + per-step-screen element tree =====
-- See the header note above ("UI SHAPE") for the full region/screen-naming rationale.
-- S2b: read the FCS's live devbind (sensor names) + senscal (starting scaffold) from
-- runtime.cfgCache; SAVE ships a senscal `set` to the FCS (which materializes the devbind
-- sibling). The CAPTURE sampler stays LOCAL. Tests inject all.

function M.build(basalt, frame, runtime, nav, read, write, sampler)
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  sampler = sampler or realSampler

  local steps = M.steps()
  local sensorNames = (cfgspec.load("devbind", read)).sensors
  local cfg = { bindings = cfgspec.merge("senscal", cfgspec.load("senscal", read)) }

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = configkit.titleRow(frame, ({ frame:getSize() })[1], M.title)

  -- A region-internal nav push/pop (drilling a step, stepping </>, or backing out of one) isn't a
  -- FRAME-level nav change, so it wouldn't otherwise wake the dirty-gated render loop -- bump
  -- runtime.uiRev, exactly like mdb.lua's/uical.lua's regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- The step-runner STATE MACHINE lives in M.newController (Basalt-free, independently
  -- TESTABLE -- see tests/test_bitconfig_senscal.lua). M.build only wires Basalt elements to
  -- its methods and owns the one Basalt-specific piece: gathering a phase's raw sensor stream
  -- on a basalt.schedule coroutine before handing it to ctrl:captureStream(raw).
  local ctrl = M.newController(cfg, steps)

  -- UI-side only: which step ids have had a successful OK. The controller itself tracks no such
  -- notion (accept() on the LAST step re-arms it for a redo rather than "finishing" -- see the
  -- header note), so completion is derived here purely for the step-list's done/pending marker.
  local completed = {}

  local function wrapSensors(keys)
    local wrapped = {}
    for _, k in ipairs(keys) do
      local name = sensorNames[k]
      wrapped[k] = name and shim.wrap(name) or nil
    end
    return wrapped
  end

  -- After any ctrl-mutating action: re-target the region's visible screen to the controller's
  -- CURRENT step (a no-op unless STEP </> or OK just moved it) then force an immediate repaint --
  -- mirrors the old flat UI's unconditional refresh() after every click, just region-aware.
  local function syncAndRefresh(region)
    local wantId = "step_" .. ctrl.step().id
    if region:top() ~= wantId then
      region:pop()
      region:push(wantId)
    end
    region:apply(nil)
  end

  -- ===== steplist screen: one button per step (done/pending marker + label) + SAVE/"<" =====
  local function buildStepList(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    -- Compact centred column sized to the widest step ("[ ] " + label); the marker is refreshed live.
    local stepItems = {}
    for i, step in ipairs(steps) do
      local targetIdx = i
      stepItems[#stepItems + 1] = { id = i, label = "[ ] " .. step.label,
        onClick = function()
          -- Walk the controller to the tapped step via the SAME single-step nav STEP </> uses.
          while ctrl.stepIdx() < targetIdx do ctrl.nextStep() end
          while ctrl.stepIdx() > targetIdx do ctrl.prevStep() end
          region:push("step_" .. step.id)
          region:apply(nil)
        end }
    end
    local stepMenu = configkit.menuColumn(f, { y = y, items = stepItems })
    local stepBtns = {}
    for i = 1, #steps do stepBtns[i] = stepMenu.buttons[i] end
    local stepBtnW = stepMenu.width
    y = stepMenu.nextY

    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SAVE", onClick = function() M._save(ctrl.cfg(), write) end },
      { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
    })

    local function refresh()
      for i, step in ipairs(steps) do
        local marker = completed[step.id] and "[x] " or "[ ] "
        stepBtns[i].button:setText(configkit.fitLabel(marker .. step.label, stepBtnW))
      end
    end
    refresh()

    return { apply = function(_state) refresh() end, elements = { stepBtns = stepBtns, footerRow = footerRow } }
  end

  -- ===== step screen: title/prompt/status/value, minus/plus, CAPTURE, OK/X, STEP nav, "< LIST" =====
  -- Registered under all 6 "step_<id>" ids via the SAME builder (there's only ever ONE active
  -- controller step; see the header note) -- every row is driven live off `ctrl`, never off the
  -- screen's own id, so whichever one is visible always matches the controller's current step.
  local function buildStepScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    local titleLabel  = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" }); y = y + 1
    local promptLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" }); y = y + 1
    local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" }); y = y + 1
    local valueLabel  = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" }); y = y + 1

    -- minus/plus (numeric "constants" phases only) on its own row -- kept separate from CAPTURE so
    -- CAPTURE's own row always has the full row width to fitLabel into (never clipped).
    local numRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "-", onClick = function() ctrl.adjustNumeric(-1); syncAndRefresh(region) end },
      { label = "+", onClick = function() ctrl.adjustNumeric(1); syncAndRefresh(region) end },
    }); y = y + 1

    local captureRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "CAPTURE", onClick = function()
          local phase = ctrl.phase()
          if not phase then return end
          if phase.kind == "numeric" then
            ctrl.captureNumeric()
            syncAndRefresh(region)
            return
          end
          local step = ctrl.step()
          basalt.schedule(function()
            local wrapped = wrapSensors(phase.sensors)
            local raw = sampler(step.id, phase, wrapped, ctrl.cfg())
            ctrl.captureStream(raw)
            syncAndRefresh(region)
          end)
        end },
    }); y = y + 1

    local okxRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "OK", onClick = function()
          local doneId = ctrl.step().id
          if ctrl.accept() then completed[doneId] = true end
          syncAndRefresh(region)
        end },
      { label = "X", onClick = function() ctrl.reject(); syncAndRefresh(region) end },
    }); y = y + 1

    local navRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "< STEP", onClick = function() ctrl.prevStep(); syncAndRefresh(region) end },
      { label = "STEP >", onClick = function() ctrl.nextStep(); syncAndRefresh(region) end },
    }); y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "< LIST", onClick = function() region:pop() end },
    }); y = y + 1

    -- refresh(): idempotent repaint from `ctrl`'s live state -- byte-identical logic to the old
    -- flat UI's refresh(), just spread across separate rows/elements.
    local function refresh()
      local step = ctrl.step()
      titleLabel:setText(configkit.fitLabel(ctrl.stepIdx() .. "/" .. #steps .. " " .. step.label, fiw))
      local prompt = step.prompts[ctrl.phaseIdx()] or ""
      promptLabel:setText(configkit.fitLabel(prompt, fiw))

      if ctrl.result() ~= nil then
        statusLabel:setText(configkit.fitLabel("captured -- OK or X", fiw))
        numRow.setState(1, "disabled")
        numRow.setState(2, "disabled")
        captureRow.setState(1, "disabled")
        okxRow.setState(1, "off")
        okxRow.setState(2, "off")
        valueLabel:setText("")
      else
        statusLabel:setText(configkit.fitLabel("phase " .. ctrl.phaseIdx() .. "/" .. #ctrl.phases(), fiw))
        captureRow.setState(1, "off")
        okxRow.setState(1, "disabled")
        okxRow.setState(2, "disabled")
        local phase = ctrl.phase()
        if phase and phase.kind == "numeric" then
          numRow.setState(1, "off")
          numRow.setState(2, "off")
          valueLabel:setText(tostring(ctrl.numericValue()))
          captureRow.buttons[1].button:setText(configkit.fitLabel("SET", fiw))
        else
          numRow.setState(1, "disabled")
          numRow.setState(2, "disabled")
          valueLabel:setText("")
          captureRow.buttons[1].button:setText(configkit.fitLabel("CAPTURE", fiw))
        end
      end
    end
    refresh()

    return {
      apply = function(_state) refresh() end,
      elements = {
        titleLabel = titleLabel, promptLabel = promptLabel, statusLabel = statusLabel, valueLabel = valueLabel,
        numRow = numRow, captureRow = captureRow, okxRow = okxRow, navRow = navRow, backRow = backRow,
      },
    }
  end

  local screens = { steplist = buildStepList }
  for _, step in ipairs(steps) do
    screens["step_" .. step.id] = buildStepScreen
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 3, width = w, height = math.max(1, h - 2),
    root = "steplist", screens = screens, onNav = bump,
  })

  -- Force the steplist screen to build now (not on the first scheduled apply()), so its elements
  -- exist as soon as M.build returns -- mirrors mdb.lua's/uical.lua's identical eager-build call.
  region:apply(nil)

  -- apply(state): this menu shows a guided CONFIG flow, not live telemetry -- forwards to the
  -- region, which lazily builds/shows its current nav top and repaints only that screen. Never
  -- polls peripherals on its own; CAPTURE is the only thing that samples, and only on click, on a
  -- scheduled coroutine.
  local function apply(state)
    region:apply(state)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { headerLabel = headerLabel, region = region },
  }
end

return M
