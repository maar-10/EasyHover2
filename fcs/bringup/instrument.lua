-- Pure instrumentation for the hover bring-up runner: CSV rows + an incremental summary
-- (no in-memory row hoarding). No CC dependencies.
local frame = require("fcs.frame")
local M = {}

local DUTY_IDS = {}
for _, id in ipairs(frame.LIFT)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.LATERAL) do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.MAIN)    do DUTY_IDS[#DUTY_IDS+1] = id end
for _, id in ipairs(frame.FRONTAL) do DUTY_IDS[#DUTY_IDS+1] = id end

local SCALAR_COLS = { "t","dt_ms","hz","phase","mode","sp_alt","alt","vSpeed","pitch","roll",
  "heading","yawRate","swayVel","surgeVel","swayPos","surgePos","onGround","heave",
  "dPitch","dRoll","dYaw","dSway","dSurge" }

-- The 6 axes shared by the PID split, saturation flags, and per-axis Summary peaks. Order here
-- drives the P_/I_/D_ and sat_ column order in THE COLUMN CONTRACT.
local TERM_AXES = { "alt", "pitch", "roll", "yaw", "sway", "surge" }
local SAT_AXES  = { "heave", "pitch", "roll", "yaw", "sway", "surge" }

-- New columns appended by THE COLUMN CONTRACT, in order: setpoints(5), PID split(18),
-- saturation+heaveBanded(7), trim ff(1), context(2). SCHEMA v2 dropped the 6 derived err_*
-- columns (err = sp - measured, recomputable on the analysis side; summary keeps peak_err).
local NEW_COLS = {
  "sp_pitch", "sp_roll", "sp_hdg", "sp_sway", "sp_surge",
  "P_alt", "I_alt", "D_alt", "P_pitch", "I_pitch", "D_pitch", "P_roll", "I_roll", "D_roll",
  "P_yaw", "I_yaw", "D_yaw", "P_sway", "I_sway", "D_sway", "P_surge", "I_surge", "D_surge",
  "sat_heave", "sat_pitch", "sat_roll", "sat_yaw", "sat_sway", "sat_surge", "heaveBanded",
  "ff_pitch",
  "master", "noFuel",
}

-- SCHEMA v2 enum codes: phase/mode shrink to 1-2 chars per row; the mapping ships in the
-- formatSummary legend. Unknown values pass through verbatim (never silently remapped).
local PHASE_CODES = {
  CLIMB = "C", HOLD = "H", DESCEND = "D", LANDED = "L",
  ENGAGED = "E", ["ENG-GND"] = "G", IDLE = "I",
}
local MODE_CODES = {
  NORMAL = "N", DAMPED = "D", CRUISE = "C", HOVER = "V", MANUAL = "M", STANDBY = "S",
}

local function enum(map, v)
  if v == nil then return "" end
  return map[v] or tostring(v)
end

-- SCHEMA v2 per-column printf precision + trailing-zero trim. Dump-time only (formatRow is never
-- on the hot path). Angles keep 3dp (values like 0.002 matter); positions/velocities 2-3dp;
-- duties are whole thruster steps 0..15 (fractional safety net at 2dp).
local COL_FMT = {
  t = "%.2f", dt_ms = "%.1f", hz = "%.1f",
  sp_alt = "%.2f", alt = "%.2f", vSpeed = "%.2f",
  pitch = "%.3f", roll = "%.3f", heading = "%.2f", yawRate = "%.3f",
  swayVel = "%.3f", surgeVel = "%.3f", swayPos = "%.3f", surgePos = "%.3f", heave = "%.3f",
  dPitch = "%.3f", dRoll = "%.3f", dYaw = "%.3f", dSway = "%.3f", dSurge = "%.3f",
  sp_pitch = "%.3f", sp_roll = "%.3f", sp_hdg = "%.2f", sp_sway = "%.3f", sp_surge = "%.3f",
  ff_pitch = "%.4f",
}
local TERM_FMT = { P = "%.4f", I = "%.4f", D = "%.4f" }

function M.header()
  local cols = {}
  for _, c in ipairs(SCALAR_COLS) do cols[#cols+1] = c end
  for _, c in ipairs(NEW_COLS) do cols[#cols+1] = c end
  for _, id in ipairs(DUTY_IDS) do cols[#cols+1] = id end
  return table.concat(cols, ",")
end

-- Format one number at its column precision, then trim trailing zeros and a dangling dot.
-- Only touches strings that contain a decimal point, so "100" and "-0.5" pass through intact.
local function num(v, fmt)
  local s = string.format(fmt or "%.4f", v or 0)
  if s:find(".", 1, true) then s = s:gsub("0+$", ""):gsub("%.$", "") end
  return s
end

-- Nil-safe reads into s.terms/s.sat -- both are OPTIONAL on the sample (hover_test.lua's samples
-- never supply them). Returns nil rather than erroring when the axis or table is absent.
local function termField(s, axis, field)
  local t = s.terms and s.terms[axis]
  return t and t[field]
end
local function satField(s, axis)
  return s.sat and s.sat[axis]
end

-- err_* is DERIVED (not stored on the sample) = setpoint - measured, plain subtraction (no
-- heading wrap). Guards both sides so a sample missing an sp_* field (hover_test path) yields
-- err = 0 - measured instead of erroring on nil arithmetic.
local function axisErr(s, axis)
  if axis == "alt" then return (s.sp_alt or 0) - (s.alt or 0)
  elseif axis == "pitch" then return (s.sp_pitch or 0) - (s.pitch or 0)
  elseif axis == "roll" then return (s.sp_roll or 0) - (s.roll or 0)
  elseif axis == "yaw" then return (s.sp_hdg or 0) - (s.heading or 0)
  elseif axis == "sway" then return (s.sp_sway or 0) - (s.swayPos or 0)
  elseif axis == "surge" then return (s.sp_surge or 0) - (s.surgePos or 0)
  end
  return 0
end

function M.formatRow(s)
  local dt = s.dt or 0
  local vals = {
    num(s.t, COL_FMT.t), num(dt*1000, COL_FMT.dt_ms), num(dt > 0 and 1/dt or 0, COL_FMT.hz),
    enum(PHASE_CODES, s.phase), enum(MODE_CODES, s.mode),
    num(s.sp_alt, COL_FMT.sp_alt), num(s.alt, COL_FMT.alt), num(s.vSpeed, COL_FMT.vSpeed),
    num(s.pitch, COL_FMT.pitch), num(s.roll, COL_FMT.roll), num(s.heading, COL_FMT.heading),
    num(s.yawRate, COL_FMT.yawRate), num(s.swayVel, COL_FMT.swayVel), num(s.surgeVel, COL_FMT.surgeVel),
    num(s.swayPos, COL_FMT.swayPos), num(s.surgePos, COL_FMT.surgePos), s.onGround and "1" or "0",
    num(s.heave, COL_FMT.heave),
    num(s.dPitch, COL_FMT.dPitch), num(s.dRoll, COL_FMT.dRoll), num(s.dYaw, COL_FMT.dYaw),
    num(s.dSway, COL_FMT.dSway), num(s.dSurge, COL_FMT.dSurge),
  }
  -- setpoints (stored, from pilot.sp via s.sp_*)
  vals[#vals+1] = num(s.sp_pitch, COL_FMT.sp_pitch); vals[#vals+1] = num(s.sp_roll, COL_FMT.sp_roll)
  vals[#vals+1] = num(s.sp_hdg, COL_FMT.sp_hdg)
  vals[#vals+1] = num(s.sp_sway, COL_FMT.sp_sway); vals[#vals+1] = num(s.sp_surge, COL_FMT.sp_surge)
  -- PID split (stored, from loop:diag().terms). CAVEAT: on a non-usable tick (dt overrun or
  -- saturated) the loop uses d=0 for that cycle's demand, but D here reflects the controller's
  -- live dFilt state at log time -- they can disagree on such ticks; see Task 1/3 :terms()/:diag().
  for _, axis in ipairs(TERM_AXES) do
    vals[#vals+1] = num(termField(s, axis, "P"), TERM_FMT.P)
    vals[#vals+1] = num(termField(s, axis, "I"), TERM_FMT.I)
    vals[#vals+1] = num(termField(s, axis, "D"), TERM_FMT.D)
  end
  -- saturation + heave band (stored, from loop:diag().sat / .heaveBanded)
  for _, axis in ipairs(SAT_AXES) do vals[#vals+1] = satField(s, axis) and "1" or "0" end
  vals[#vals+1] = s.heaveBanded and "1" or "0"
  -- trim feedforward (stored)
  vals[#vals+1] = num(s.ff_pitch, COL_FMT.ff_pitch)
  -- context (stored)
  vals[#vals+1] = tostring(s.master or "")
  vals[#vals+1] = s.noFuel and "1" or "0"

  local d = s.duties or {}
  for _, id in ipairs(DUTY_IDS) do vals[#vals+1] = num(d[id], "%.2f") end
  return table.concat(vals, ",")
end

-- capture(s): make a per-cycle sample safe to BUFFER for deferred formatRow. The control loop
-- reuses/overwrites its duties table in place each cycle, so the ONLY unsafe reference in `s` is
-- `s.duties`; every other field is already a per-cycle scalar. Snapshot just the emitted duty
-- columns into a private table so formatRow(s) at DUMP time reflects THIS cycle, not the latest.
-- Cheap (11 field copies) vs the 34-column string.format that formatRow does -- which now runs only
-- at dump, off the hot control loop. Mutates+returns `s` (a fresh literal at the call site).
function M.capture(s)
  local d = s.duties or {}
  local snap = {}
  for _, id in ipairs(DUTY_IDS) do snap[id] = d[id] end
  s.duties = snap
  return s
end

local Summary = {}
Summary.__index = Summary
M.Summary = Summary

local function newAxisPeaks()
  local p = {}
  for _, axis in ipairs(TERM_AXES) do p[axis] = 0 end
  return p
end

function Summary.new()
  return setmetatable({
    n = 0, tFirst = nil, tLast = 0,
    hzMin = math.huge, hzMax = 0, hzSum = 0, hzN = 0,
    heading0 = nil, headingDrift = 0,
    swayMin = math.huge, swayMax = -math.huge, surgeMin = math.huge, surgeMax = -math.huge,
    maxPitch = 0, maxRoll = 0, peakClimbV = 0, peakDescentV = 0,
    holdAltMin = math.huge, holdAltMax = -math.huge,
    perr = { CLIMB={sum=0,max=0,n=0}, HOLD={sum=0,max=0,n=0}, DESCEND={sum=0,max=0,n=0} },
    damped = false, touchdownV = nil, lastPhase = nil,
    peakErr = newAxisPeaks(), peakD = newAxisPeaks(),
  }, Summary)
end

function Summary:add(s)
  self.n = self.n + 1
  if self.tFirst == nil then self.tFirst = s.t or 0 end
  self.tLast = s.t or self.tLast
  local dt = s.dt or 0
  if dt > 0 then
    local hz = 1/dt
    if hz < self.hzMin then self.hzMin = hz end
    if hz > self.hzMax then self.hzMax = hz end
    self.hzSum = self.hzSum + hz; self.hzN = self.hzN + 1
  end
  if self.heading0 == nil then self.heading0 = s.heading or 0 end
  local hd = math.abs((s.heading or 0) - self.heading0)
  if hd > self.headingDrift then self.headingDrift = hd end
  local sp, su = s.swayPos or 0, s.surgePos or 0
  if sp < self.swayMin then self.swayMin = sp end
  if sp > self.swayMax then self.swayMax = sp end
  if su < self.surgeMin then self.surgeMin = su end
  if su > self.surgeMax then self.surgeMax = su end
  if math.abs(s.pitch or 0) > self.maxPitch then self.maxPitch = math.abs(s.pitch or 0) end
  if math.abs(s.roll or 0) > self.maxRoll then self.maxRoll = math.abs(s.roll or 0) end
  local v = s.vSpeed or 0
  if v > self.peakClimbV then self.peakClimbV = v end
  if v < self.peakDescentV then self.peakDescentV = v end
  if s.mode == "DAMPED" then self.damped = true end
  if s.phase == "HOLD" then
    local a = s.alt or 0
    if a < self.holdAltMin then self.holdAltMin = a end
    if a > self.holdAltMax then self.holdAltMax = a end
  end
  local pe = self.perr[s.phase]
  if pe then
    local e = math.abs((s.alt or 0) - (s.sp_alt or 0))
    pe.sum = pe.sum + e; pe.n = pe.n + 1
    if e > pe.max then pe.max = e end
  end
  if s.phase == "LANDED" and self.lastPhase ~= "LANDED" then self.touchdownV = v end
  self.lastPhase = s.phase
  -- per-axis peak |err| (derived, same definition as formatRow's err_*) and peak |D| (from
  -- s.terms, optional -- guarded so a hover_test-path sample with no terms is a cheap no-op).
  for _, axis in ipairs(TERM_AXES) do
    local e = math.abs(axisErr(s, axis))
    if e > self.peakErr[axis] then self.peakErr[axis] = e end
    local d = termField(s, axis, "D")
    if d then
      local ad = math.abs(d)
      if ad > self.peakD[axis] then self.peakD[axis] = ad end
    end
  end
end

local function mean(sum, n) return n > 0 and (sum / n) or 0 end

function Summary:finalize()
  local dur = (self.tFirst ~= nil) and (self.tLast - self.tFirst) or 0
  local bob = (self.holdAltMax >= self.holdAltMin) and (self.holdAltMax - self.holdAltMin) or 0
  local function perrOf(k) local p = self.perr[k]; return { mean = mean(p.sum, p.n), max = p.max } end
  return {
    samples = self.n, duration = dur,
    hzMin = self.hzMin == math.huge and 0 or self.hzMin, hzMax = self.hzMax,
    hzAvg = mean(self.hzSum, self.hzN),
    bobAmplitude = bob, peakClimbV = self.peakClimbV, peakDescentV = self.peakDescentV,
    maxPitch = self.maxPitch, maxRoll = self.maxRoll,
    swayRange = (self.swayMax >= self.swayMin) and (self.swayMax - self.swayMin) or 0,
    surgeRange = (self.surgeMax >= self.surgeMin) and (self.surgeMax - self.surgeMin) or 0,
    headingDrift = self.headingDrift, touchdownV = self.touchdownV or 0, damped = self.damped,
    errClimb = perrOf("CLIMB"), errHold = perrOf("HOLD"), errDescend = perrOf("DESCEND"),
    peakErr = self.peakErr, peakD = self.peakD,
  }
end

local function legendLine()
  local function pairsOf(map)
    local keys = {}
    for k in pairs(map) do keys[#keys+1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out+1] = map[k] .. "=" .. k end
    return table.concat(out, " ")
  end
  return "# legend: phase " .. pairsOf(PHASE_CODES) .. " | mode " .. pairsOf(MODE_CODES)
    .. " | err = sp - measured (derived, not logged) | schema: v2"
end

-- Every summary line is #-prefixed so logcodec.decode can tell summary lines from CSV rows
-- (hover_test writes the summary BEFORE the rows; flight.lua appends it after).
function M.formatSummary(m)
  local lines = {
    "# EasyHover 2 hover bring-up log",
    legendLine(),
    "# samples: " .. m.samples,
    string.format("# duration_s: %.2f", m.duration),
    string.format("# loop_hz: min %.2f avg %.2f max %.2f", m.hzMin, m.hzAvg, m.hzMax),
    string.format("# hold_bob_amplitude_blocks: %.3f", m.bobAmplitude),
    string.format("# peak_climb_vSpeed: %.3f", m.peakClimbV),
    string.format("# peak_descent_vSpeed: %.3f", m.peakDescentV),
    string.format("# touchdown_vSpeed: %.3f", m.touchdownV),
    string.format("# max_pitch: %.4f  max_roll: %.4f", m.maxPitch, m.maxRoll),
    string.format("# horizontal_drift_blocks: sway %.3f  surge %.3f", m.swayRange, m.surgeRange),
    string.format("# heading_drift: %.4f", m.headingDrift),
    string.format("# alt_err_climb: mean %.3f max %.3f", m.errClimb.mean, m.errClimb.max),
    string.format("# alt_err_hold: mean %.3f max %.3f", m.errHold.mean, m.errHold.max),
    string.format("# alt_err_descend: mean %.3f max %.3f", m.errDescend.mean, m.errDescend.max),
    "# damped_tripped: " .. (m.damped and "YES" or "no"),
    string.format("# peak_err: alt %.3f pitch %.4f roll %.4f yaw %.4f sway %.3f surge %.3f",
      m.peakErr.alt, m.peakErr.pitch, m.peakErr.roll, m.peakErr.yaw, m.peakErr.sway, m.peakErr.surge),
    string.format("# peak_D: alt %.3f pitch %.4f roll %.4f yaw %.4f sway %.3f surge %.3f",
      m.peakD.alt, m.peakD.pitch, m.peakD.roll, m.peakD.yaw, m.peakD.sway, m.peakD.surge),
  }
  return table.concat(lines, "\n")
end

return M
