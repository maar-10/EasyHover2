-- tests/test_bitconfig_tuning.lua
-- FCS TUNING sub-menu (ui/basalt/bitconfig/tuning.lua): tests the PURE view-model (M.rows /
-- M.apply), the TESTABLE save/reset seams (M._save / M._reset) with capturing read/write/delete
-- spies (no real fs), plus a real-CraftOS-PC Basalt construction probe -- build the element tree
-- on a frame bound to term.current(), click through +/-/page/save/reset, then one
-- basalt.update(...) render pass. NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.tuning")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")
local tuningdefaults = require("fcs.io.tuningdefaults")

-- ===== M.rows: pure, reads cfg at the dotted path (nil-safe) =====

t.test("rows: returns a row for gains.pitch.kp whose value reflects cfg and id path is correct", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.37
  local rows = M.rows(cfg)
  local found
  for _, r in ipairs(rows) do
    if r.id == "gains.pitch.kp" then found = r end
  end
  t.truthy(found, "gains.pitch.kp row present")
  t.eq(found.value, 0.37)
  t.eq(found.group, "GAINS")
end)

t.test("rows: missing value in cfg falls back to the tuningdefaults value", function()
  local rows = M.rows({})
  local defaults = tuningdefaults.get()
  local found
  for _, r in ipairs(rows) do
    if r.id == "caps.yaw" then found = r end
  end
  t.truthy(found, "caps.yaw row present")
  t.eq(found.value, defaults.caps.yaw)
end)

t.test("rows: covers caps.* and feel.* groups", function()
  local rows = M.rows(tuningdefaults.get())
  local groups = {}
  for _, r in ipairs(rows) do groups[r.group] = true end
  t.truthy(groups.GAINS, "GAINS group present")
  t.truthy(groups.CAPS, "CAPS group present")
  t.truthy(groups.FEEL, "FEEL group present")
end)

-- ===== M.apply: pure, deep-copies, clamps, rounds ===== (TDD cases from the task brief)

t.test("apply(cfg, 'gains.pitch.kp', +1) raises gains.pitch.kp by exactly one step, leaves the rest equal", function()
  local cfg = tuningdefaults.get()
  local before = cfg.gains.pitch.kp
  local out = M.apply(cfg, "gains.pitch.kp", 1)
  t.near(out.gains.pitch.kp, before + 0.01, 1e-9)
  -- everything else in gains.pitch untouched
  t.eq(out.gains.pitch.ki, cfg.gains.pitch.ki)
  t.eq(out.gains.pitch.kd, cfg.gains.pitch.kd)
  t.eq(out.gains.pitch.tauD, cfg.gains.pitch.tauD)
  -- other axes untouched
  t.eq(out.gains.roll.kp, cfg.gains.roll.kp)
  t.eq(out.gains.yaw.kp, cfg.gains.yaw.kp)
  -- caps/feel untouched
  t.eq(out.caps.pitch, cfg.caps.pitch)
  t.eq(out.feel.headingRate, cfg.feel.headingRate)
end)

t.test("apply com.fwd steps by 0.1 and stays on the top-level com table", function()
  local cfg = tuningdefaults.get()
  local out = M.apply(cfg, "com.fwd", 1)
  t.near(out.com.fwd, 0.1, 1e-9)
  t.eq(out.gains.hoverDuty, cfg.gains.hoverDuty, "other tuning untouched")
end)

t.test("apply at min with -1 clamps (does not go below min)", function()
  local cfg = tuningdefaults.get()
  cfg.caps.yaw = 0 -- already at min
  local out = M.apply(cfg, "caps.yaw", -1)
  t.eq(out.caps.yaw, 0)
end)

t.test("apply at max with +1 clamps (does not go above max)", function()
  local cfg = tuningdefaults.get()
  cfg.gains.hoverDuty = 1 -- already at max
  local out = M.apply(cfg, "gains.hoverDuty", 1)
  t.eq(out.gains.hoverDuty, 1)
end)

t.test("apply does NOT mutate the input cfg", function()
  local cfg = tuningdefaults.get()
  local beforeKp = cfg.gains.pitch.kp
  local out = M.apply(cfg, "gains.pitch.kp", 1)
  t.eq(cfg.gains.pitch.kp, beforeKp, "original cfg unchanged")
  t.truthy(out ~= cfg, "apply returns a different table")
  t.truthy(out.gains ~= cfg.gains, "nested tables are deep-copied too")
end)

t.test("apply: unknown rowId returns an unchanged (but copied) cfg", function()
  local cfg = tuningdefaults.get()
  local out = M.apply(cfg, "gains.bogus.zz", 1)
  t.eq(out.gains.hoverDuty, cfg.gains.hoverDuty)
  t.truthy(out ~= cfg, "still a copy even for an unknown id")
end)

t.test("apply: repeated +1 clicks accumulate without float drift", function()
  local cfg = tuningdefaults.get()
  cfg.caps.roll = 0
  local out = cfg
  for i = 1, 10 do out = M.apply(out, "caps.roll", 1) end
  t.near(out.caps.roll, 0.5, 1e-9) -- 10 * 0.05 step
end)

-- ===== M.window: pure windowing helper for a scrollable edit screen =====

t.test("M.window clamps offset and returns the visible index range", function()
  local T = require("ui.basalt.bitconfig.tuning")
  -- 13 rows, window of 8
  local w = T.window(13, 0, 8)
  t.eq(w.offset, 0); t.eq(w.first, 1); t.eq(w.last, 8); t.eq(w.maxOffset, 5)
  w = T.window(13, 5, 8)              -- offset at max: shows rows 6..13
  t.eq(w.offset, 5); t.eq(w.first, 6); t.eq(w.last, 13)
  w = T.window(13, 99, 8)             -- over-max clamps to maxOffset
  t.eq(w.offset, 5); t.eq(w.first, 6); t.eq(w.last, 13)
  w = T.window(13, -3, 8)             -- negative clamps to 0
  t.eq(w.offset, 0); t.eq(w.first, 1); t.eq(w.last, 8)
end)

t.test("M.window: rows that fit -> maxOffset 0, full range, no scroll needed", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local w = T.window(6, 0, 8)
  t.eq(w.maxOffset, 0); t.eq(w.first, 1); t.eq(w.last, 6)
end)

t.test("M.window: count==0 -> empty window (first=1,last=0,maxOffset=0)", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local w = T.window(0, 0, 8)
  t.eq(w.first, 1); t.eq(w.last, 0); t.eq(w.maxOffset, 0); t.eq(w.offset, 0)
end)

t.test("M.window: every row reachable by paging with n", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local count, n, seen = 13, 8, {}
  local off = 0
  while true do
    local w = T.window(count, off, n)
    for i = w.first, w.last do seen[i] = true end
    if off >= w.maxOffset then break end
    off = math.min(off + n, w.maxOffset)
  end
  for i = 1, count do t.truthy(seen[i], "row " .. i .. " reachable") end
end)

-- ===== Per-mode tuning model: M.MODES / M.pathFor / M.rows(cfg,mode) / =====
-- ===== M.apply(cfg,mode,rowId,delta) / M.resetMode(cfg,mode)          =====
-- PRECISION reads/writes the top-level gains/caps/feel (unchanged pre-existing behaviour).
-- MAN/CRUISE read/write their `modes.<mode>` subtree, PLUS their own extra FEEL rows
-- (MAN: tiltRate/tiltCap; CRUISE: cruiseThrottleRate/cruiseThrottleMax). Strict isolation:
-- touching one mode must never touch the others (mirrors the flight-modes isolation property).

local function deepEq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

t.test("_comAutoReason: live run shows the phase; a finished run surfaces the abort reason; else prereq/READY", function()
  -- During a run the AUTO COM status shows PROGRESS (phase), NOT the ON GROUND prereq -- which goes
  -- false the moment the craft lifts off and stays false on a slope, masking everything. After a
  -- failed run it surfaces WHY (POS/TILT/TIME) so the operator isn't flying blind.
  t.eq(M._comAutoReason({ phase = "HOLD" }, "ON GROUND"), "HOLD")                     -- running -> phase, prereq ignored
  t.eq(M._comAutoReason({ phase = "CLIMB" }, nil), "CLIMB")
  t.eq(M._comAutoReason({ phase = "DONE", abortReason = "POS" }, "ON GROUND"), "ABORT POS")  -- abort beats the masking prereq
  t.eq(M._comAutoReason({ phase = "DONE" }, nil), "DONE")                             -- clean finish on the pad
  t.eq(M._comAutoReason({ phase = "DONE" }, "ON GROUND"), "ON GROUND")                -- finished but on a slope
  t.eq(M._comAutoReason({}, nil), "READY")                                           -- idle, all prereqs met
  t.eq(M._comAutoReason(nil, nil), "READY")                                          -- nil-safe
end)

t.test("M.MODES lists PRECISION, MAN, CRUISE, LDG, DRN in that order (Task 14: CPL/DCPL are master modes, not flight modes)", function()
  t.eq(#M.MODES, 5)
  t.eq(M.MODES[1], "PRECISION")
  t.eq(M.MODES[2], "MAN")
  t.eq(M.MODES[3], "CRUISE")
  t.eq(M.MODES[4], "LDG")
  t.eq(M.MODES[5], "DRN")
end)

t.test("tuning editor: no CPL/DCPL extra rows; trim/ramp are shared base FEEL rows", function()
  local T = require("ui.basalt.bitconfig.tuning")
  -- CPL/DCPL are no longer tunable flight modes
  local has = {}; for _, m in ipairs(T.MODES) do has[m] = true end
  t.truthy(not has.CPL and not has.DCPL, "CPL/DCPL are not tunable flight modes")
  local specCPL = T.specFor and T.specFor("CPL", "feel.trimGain")
  t.eq(specCPL, nil, "no CPL-scoped trimGain row")
  -- trimGain/climbBoost/climbRampTime now resolve for a base flight mode (e.g. MAN)
  t.truthy(T.specFor("MAN", "feel.trimGain"), "trimGain tunable on a flight mode")
  t.truthy(T.specFor("MAN", "feel.climbBoost"), "climbBoost tunable on a flight mode")
  t.truthy(T.specFor("MAN", "feel.climbRampTime"), "climbRampTime tunable on a flight mode")
end)

t.test("M.rows(cfg,'LDG') includes the 34 base rows + the 6 rows shared by every flight mode (trim/ramp/flip-guard), no own extras", function()
  local rows = M.rows(tuningdefaults.get(), "LDG")
  t.eq(#rows, 40, "34 base + 6 shared trim/ramp/flip-guard rows")
  local ids = {}
  for _, r in ipairs(rows) do ids[r.id] = r end
  local defaults = tuningdefaults.get()
  for _, id in ipairs({ "feel.climbRampTime", "feel.climbBoost", "feel.trimGain" }) do
    t.truthy(ids[id], "LDG row present: " .. id)
    t.eq(ids[id].group, "FEEL")
    t.eq(ids[id].value, defaults.modes.LDG.feel[id:match("feel%.(.+)")])
  end
end)

t.test("M.rows(cfg,'DRN') includes the 34 base rows + its own tiltRate/tiltCap + 5 brake rows + the 6 shared trim/ramp/flip-guard rows", function()
  local rows = M.rows(tuningdefaults.get(), "DRN")
  t.eq(#rows, 47, "34 base + 2 DRN tilt extras + 5 brake rows + 6 shared trim/ramp/flip-guard rows")
  local ids = {}
  for _, r in ipairs(rows) do ids[r.id] = r end
  local defaults = tuningdefaults.get()
  for _, id in ipairs({ "feel.tiltRate", "feel.tiltCap", "feel.climbRampTime", "feel.climbBoost", "feel.trimGain" }) do
    t.truthy(ids[id], "DRN row present: " .. id)
    t.eq(ids[id].group, "FEEL")
    t.eq(ids[id].value, defaults.modes.DRN.feel[id:match("feel%.(.+)")])
  end
end)

t.test("ISOLATION: M.apply(cfg,'LDG','feel.trimGain',+1) writes modes.LDG.feel.trimGain only -- DRN/MAN/CRUISE/top-level untouched", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "LDG", "feel.trimGain", 1)
  t.near(out.modes.LDG.feel.trimGain, before.modes.LDG.feel.trimGain + 0.01, 1e-9)
  t.truthy(deepEq(out.modes.DRN, before.modes.DRN), "modes.DRN unchanged")
  t.truthy(deepEq(out.modes.MAN, before.modes.MAN), "modes.MAN unchanged")
  t.truthy(deepEq(out.modes.CRUISE, before.modes.CRUISE), "modes.CRUISE unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
end)

t.test("M.resetMode(cfg,'DRN') resets ONLY modes.DRN -- modes.LDG and rest of the tree intact", function()
  local cfg = tuningdefaults.get()
  cfg.modes.DRN.feel.trimGain = 0.999
  cfg.modes.LDG.feel.trimGain = 0.888
  cfg.gains.pitch.kp = 0.777

  local out = M.resetMode(cfg, "DRN")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.modes.DRN, defaults.modes.DRN), "modes.DRN reset to defaults")
  t.eq(out.modes.LDG.feel.trimGain, 0.888, "modes.LDG left intact")
  t.eq(out.gains.pitch.kp, 0.777, "top-level left intact")
end)

t.test("pathFor: PRECISION (or nil mode) returns the dotted path as-is (top-level)", function()
  t.eq(M.pathFor("PRECISION", "gains.pitch.kp"), "gains.pitch.kp")
  t.eq(M.pathFor(nil, "gains.pitch.kp"), "gains.pitch.kp")
end)

t.test("pathFor: MAN/CRUISE prefix under modes.<mode>.", function()
  t.eq(M.pathFor("MAN", "gains.pitch.kp"), "modes.MAN.gains.pitch.kp")
  t.eq(M.pathFor("CRUISE", "caps.yaw"), "modes.CRUISE.caps.yaw")
end)

t.test("REGRESSION: M.rows(cfg) with no mode arg == M.rows(cfg,'PRECISION')", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.37
  local a = M.rows(cfg)
  local b = M.rows(cfg, "PRECISION")
  t.eq(#a, #b)
  for i = 1, #a do
    t.eq(a[i].id, b[i].id)
    t.eq(a[i].value, b[i].value)
  end
  t.eq(#a, 40, "34 base rows + the 6 rows shared by every flight mode (trim/ramp/flip-guard)")
end)

t.test("REGRESSION: M.apply(cfg,rowId,delta) with no mode arg == M.apply(cfg,'PRECISION',rowId,delta)", function()
  local cfg = tuningdefaults.get()
  local out1 = M.apply(cfg, "gains.pitch.kp", 1)
  local out2 = M.apply(cfg, "PRECISION", "gains.pitch.kp", 1)
  t.truthy(deepEq(out1, out2), "3-arg and explicit-PRECISION 4-arg calls must agree")
end)

t.test("M.rows(cfg,'MAN') reads from modes.MAN subtree, not top-level", function()
  local cfg = tuningdefaults.get()
  cfg.modes.MAN.gains.pitch.kp = 0.55
  local rows = M.rows(cfg, "MAN")
  local found
  for _, r in ipairs(rows) do if r.id == "gains.pitch.kp" then found = r end end
  t.truthy(found, "gains.pitch.kp row present for MAN")
  t.eq(found.value, 0.55)
  -- top-level (PRECISION) untouched by that mutation
  local precisionRows = M.rows(cfg, "PRECISION")
  local pFound
  for _, r in ipairs(precisionRows) do if r.id == "gains.pitch.kp" then pFound = r end end
  t.eq(pFound.value, tuningdefaults.get().gains.pitch.kp)
end)

t.test("M.rows(cfg,'MAN') includes the 34 base rows + tiltRate/tiltCap + 5 brake rows + the 6 shared trim/ramp/flip-guard rows (FEEL group)", function()
  local rows = M.rows(tuningdefaults.get(), "MAN")
  t.eq(#rows, 47, "34 base + 2 MAN tilt extras + 5 brake rows + 6 shared trim/ramp/flip-guard rows")
  local tiltRate, tiltCap
  for _, r in ipairs(rows) do
    if r.id == "feel.tiltRate" then tiltRate = r end
    if r.id == "feel.tiltCap" then tiltCap = r end
  end
  t.truthy(tiltRate, "feel.tiltRate row present for MAN")
  t.truthy(tiltCap, "feel.tiltCap row present for MAN")
  t.eq(tiltRate.group, "FEEL")
  t.eq(tiltCap.group, "FEEL")
  t.eq(tiltRate.value, tuningdefaults.get().modes.MAN.feel.tiltRate)
  t.eq(tiltCap.value, tuningdefaults.get().modes.MAN.feel.tiltCap)
end)

t.test("M.rows(cfg,'CRUISE') includes the 34 base rows + cruiseThrottleRate/Max + 5 brake rows + the 6 shared trim/ramp/flip-guard rows (FEEL group)", function()
  local rows = M.rows(tuningdefaults.get(), "CRUISE")
  t.eq(#rows, 47, "34 base + 2 CRUISE throttle extras + 5 brake rows + 6 shared trim/ramp/flip-guard rows")
  local rate, max
  for _, r in ipairs(rows) do
    if r.id == "feel.cruiseThrottleRate" then rate = r end
    if r.id == "feel.cruiseThrottleMax" then max = r end
  end
  t.truthy(rate, "feel.cruiseThrottleRate row present for CRUISE")
  t.truthy(max, "feel.cruiseThrottleMax row present for CRUISE")
  t.eq(rate.group, "FEEL")
  t.eq(max.group, "FEEL")
  t.eq(rate.value, tuningdefaults.get().modes.CRUISE.feel.cruiseThrottleRate)
  t.eq(max.value, tuningdefaults.get().modes.CRUISE.feel.cruiseThrottleMax)
end)

t.test("M.rows(cfg,'PRECISION') has no tilt/cruise-throttle extras, but DOES have the 6 shared trim/ramp/flip-guard rows (40 rows)", function()
  local rows = M.rows(tuningdefaults.get(), "PRECISION")
  t.eq(#rows, 40, "34 base + 6 shared trim/ramp/flip-guard rows")
  local ids = {}
  for _, r in ipairs(rows) do
    ids[r.id] = r
    t.truthy(r.id ~= "feel.tiltRate" and r.id ~= "feel.tiltCap"
      and r.id ~= "feel.cruiseThrottleRate" and r.id ~= "feel.cruiseThrottleMax",
      "no per-mode extra leaked into PRECISION rows: " .. r.id)
  end
  for _, id in ipairs({ "feel.climbRampTime", "feel.climbBoost", "feel.trimGain" }) do
    t.truthy(ids[id], "PRECISION row present: " .. id)
    t.eq(ids[id].group, "FEEL")
  end
end)

t.test("rows: trim flip-guard feel rows present with ranges (shared across modes)", function()
  local rows = M.rows(tuningdefaults.get())
  local byId = {}
  for _, r in ipairs(rows) do byId[r.id] = r end
  for _, id in ipairs({ "feel.trimAuthority", "feel.trimFadeStart", "feel.trimFade" }) do
    t.truthy(byId[id], id.." row present")
    t.eq(byId[id].group, "FEEL", id.." is a FEEL row")
  end
  t.near(byId["feel.trimAuthority"].value, 0.4, 1e-9, "value from defaults")
  -- M.rows() rows carry {id,label,group,value,step}, not min/max -- range checks go through
  -- M.specFor, the same pure accessor the CPL/DCPL specFor test above already uses.
  t.eq(M.specFor("PRECISION", "feel.trimAuthority").max, 1.0, "authority max 1.0")
  t.eq(M.specFor("PRECISION", "feel.trimFade").max, 1.5, "fade max 1.5")
end)

t.test("ISOLATION: M.apply(cfg,'MAN',rowId,delta) changes ONLY modes.MAN -- top-level (PRECISION) and modes.CRUISE byte-unchanged", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "MAN", "gains.pitch.kp", 1)

  t.near(out.modes.MAN.gains.pitch.kp, before.modes.MAN.gains.pitch.kp + 0.01, 1e-9)
  -- top-level gains/caps/feel (PRECISION) byte-unchanged
  t.truthy(deepEq(out.gains, before.gains), "top-level gains unchanged")
  t.truthy(deepEq(out.caps, before.caps), "top-level caps unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
  -- CRUISE subtree byte-unchanged
  t.truthy(deepEq(out.modes.CRUISE, before.modes.CRUISE), "modes.CRUISE unchanged")
  -- rest of MAN subtree (besides the touched field) unchanged
  t.truthy(deepEq(out.modes.MAN.caps, before.modes.MAN.caps), "modes.MAN.caps unchanged")
  t.truthy(deepEq(out.modes.MAN.feel, before.modes.MAN.feel), "modes.MAN.feel unchanged")
end)

t.test("ISOLATION: M.apply(cfg,'CRUISE',rowId,delta) changes ONLY modes.CRUISE -- top-level and modes.MAN byte-unchanged", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "CRUISE", "caps.yaw", 1)

  t.near(out.modes.CRUISE.caps.yaw, before.modes.CRUISE.caps.yaw + 0.05, 1e-9)
  t.truthy(deepEq(out.gains, before.gains), "top-level gains unchanged")
  t.truthy(deepEq(out.caps, before.caps), "top-level caps unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
  t.truthy(deepEq(out.modes.MAN, before.modes.MAN), "modes.MAN unchanged")
end)

t.test("M.apply(cfg,'MAN','feel.tiltRate',+1) writes modes.MAN.feel.tiltRate only", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "MAN", "feel.tiltRate", 1)
  t.near(out.modes.MAN.feel.tiltRate, before.modes.MAN.feel.tiltRate + 0.1, 1e-9)
  t.eq(out.modes.MAN.feel.tiltCap, before.modes.MAN.feel.tiltCap)
  t.truthy(deepEq(out.modes.CRUISE, before.modes.CRUISE), "modes.CRUISE unchanged")
  t.truthy(deepEq(out.feel, before.feel), "top-level feel unchanged")
end)

t.test("M.apply(cfg,'CRUISE','feel.cruiseThrottleMax',-1) writes modes.CRUISE.feel.cruiseThrottleMax only", function()
  local cfg = tuningdefaults.get()
  local before = tuningdefaults.get()
  local out = M.apply(cfg, "CRUISE", "feel.cruiseThrottleMax", -1)
  t.near(out.modes.CRUISE.feel.cruiseThrottleMax, before.modes.CRUISE.feel.cruiseThrottleMax - 0.05, 1e-9)
  t.eq(out.modes.CRUISE.feel.cruiseThrottleRate, before.modes.CRUISE.feel.cruiseThrottleRate)
  t.truthy(deepEq(out.modes.MAN, before.modes.MAN), "modes.MAN unchanged")
end)

t.test("M.apply(cfg,'PRECISION','feel.tiltRate',+1) is a no-op (tiltRate is not a PRECISION row)", function()
  local cfg = tuningdefaults.get()
  local out = M.apply(cfg, "PRECISION", "feel.tiltRate", 1)
  t.truthy(deepEq(out, cfg), "unknown-for-this-mode rowId leaves cfg unchanged (still copied)")
  t.truthy(out ~= cfg, "still a copy")
end)

t.test("M.resetMode(cfg,'MAN') resets ONLY modes.MAN to defaults -- rest of the tree intact", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.999
  cfg.modes.MAN.gains.pitch.kp = 0.111
  cfg.modes.MAN.feel.tiltRate = 1.999
  cfg.modes.CRUISE.caps.yaw = 0.123

  local out = M.resetMode(cfg, "MAN")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.modes.MAN, defaults.modes.MAN), "modes.MAN reset to defaults")
  -- everything else left intact (not reverted to defaults)
  t.eq(out.gains.pitch.kp, 0.999)
  t.eq(out.modes.CRUISE.caps.yaw, 0.123)
end)

t.test("M.resetMode(cfg,'PRECISION') resets ONLY top-level gains/caps/feel -- modes.* intact", function()
  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.999
  cfg.caps.yaw = 0.123
  cfg.feel.headingRate = 9.9
  cfg.modes.MAN.gains.pitch.kp = 0.111
  cfg.modes.CRUISE.caps.yaw = 0.222

  local out = M.resetMode(cfg, "PRECISION")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.gains, defaults.gains), "top-level gains reset to defaults")
  t.truthy(deepEq(out.caps, defaults.caps), "top-level caps reset to defaults")
  t.truthy(deepEq(out.feel, defaults.feel), "top-level feel reset to defaults")
  t.eq(out.modes.MAN.gains.pitch.kp, 0.111)
  t.eq(out.modes.CRUISE.caps.yaw, 0.222)
end)

t.test("M.resetMode(cfg,'CRUISE') resets ONLY modes.CRUISE -- modes.MAN and top-level intact", function()
  local cfg = tuningdefaults.get()
  cfg.modes.CRUISE.feel.cruiseThrottleMax = 0.01
  cfg.modes.MAN.feel.tiltCap = 0.01
  cfg.gains.pitch.kp = 0.999

  local out = M.resetMode(cfg, "CRUISE")
  local defaults = tuningdefaults.get()

  t.truthy(deepEq(out.modes.CRUISE, defaults.modes.CRUISE), "modes.CRUISE reset to defaults")
  t.eq(out.modes.MAN.feel.tiltCap, 0.01)
  t.eq(out.gains.pitch.kp, 0.999)
end)

t.test("M.resetMode does NOT mutate the input cfg", function()
  local cfg = tuningdefaults.get()
  local beforeKp = cfg.modes.MAN.gains.pitch.kp
  local out = M.resetMode(cfg, "MAN")
  t.eq(cfg.modes.MAN.gains.pitch.kp, beforeKp, "original cfg unchanged")
  t.truthy(out ~= cfg, "resetMode returns a different table")
end)

-- ===== M._save / M._reset: Basalt-free, capturing spies =====

t.test("_save writes the serialised cfg under eh2_tuning.tbl via the injected write", function()
  local calls = {}
  local function write(filename, body) calls[#calls + 1] = { filename = filename, body = body } end

  local cfg = tuningdefaults.get()
  cfg.gains.pitch.kp = 0.42
  M._save(cfg, write)

  t.eq(#calls, 1)
  t.eq(calls[1].filename, "eh2_tuning.tbl")
  t.eq(calls[1].filename, cfgspec.FILES.tuning)
  local parsed = textutils.unserialise(calls[1].body)
  t.eq(parsed.gains.pitch.kp, 0.42)
end)

t.test("_reset deletes the file at the full path and returns fresh defaults", function()
  local deletedPaths = {}
  local function deleteFn(path) deletedPaths[#deletedPaths + 1] = path end

  local result = M._reset(deleteFn)

  t.eq(#deletedPaths, 1)
  t.eq(deletedPaths[1], "/eh2_tuning.tbl")
  t.eq(deletedPaths[1], "/" .. cfgspec.FILES.tuning)
  t.eq(result.gains.hoverDuty, tuningdefaults.get().gains.hoverDuty)
  t.eq(result.caps.yaw, tuningdefaults.get().caps.yaw)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====
-- Task 8: the old flat paged-stepper UI (rowSlots/prevBtn/nextBtn/saveBtn/resetBtn/backBtn on
-- ONE screen) is replaced by a mode->category->axis region.lua drilldown (root "modes"). These
-- tests exercise the NEW screen tree, mirroring ui/basalt/bitconfig/mdb.lua's/senscal.lua's own
-- construction-probe idiom: drill via region:push(id) (the SAME effect a button's onClick has),
-- then h.apply({}) to lazily build/repaint (never basalt.run(), which blocks on pullEventRaw).

-- populatedSlots(rowSlots): the CURRENTLY VISIBLE rows out of a windowed buildEditScreen's fixed
-- N rowSlots (Task 2, 2026-09-05 brake-tune-scroll-menu -- rowSlots is now N FIXED slots, blank
-- past the window tail, so a plain ipairs() over it includes blanks with slot.id == nil). Every
-- pre-existing construction-probe test below that inspects row ids/labels/-+ buttons via rowSlots
-- filters through this so it sees exactly the same "one entry per actual row" shape it always did
-- -- count assertions ("exactly N rows") were updated to check elements.rowIds instead (the
-- windowing-independent logical row-id list), which is unaffected by N/offset.
local function populatedSlots(rowSlots)
  local out = {}
  for _, slot in ipairs(rowSlots) do
    if slot.id then out[#out + 1] = slot end
  end
  return out
end

local function newHarness()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame() -- binds to term.current(), per ui/basalt/app.lua's header
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end
  return basalt, frame, nav, read, write, delete, function() return stored end
end

t.test("M.build: modes screen (root) has PRECISION/MAN/CRUISE buttons + '?' + '<'; apply()/render do not error", function()
  local basalt, frame, nav, read, write, delete = newHarness()

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  t.eq(h.id, "tuning")
  t.truthy(type(h.apply) == "function", "apply should be a function")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "modes", "region starts at the modes root")

  local modesHandle = region.built.modes.handle
  -- No frame-level header anymore: each region screen self-titles with its own ||title||.
  t.truthy(modesHandle.elements.titleLabel ~= nil, "modes root self-titles (||FCS TUNING||)")
  t.truthy(modesHandle.elements.titleLabel:getText():find("FCS TUNING", 1, true), "title text is FCS TUNING")
  for _, mode in ipairs(M.MODES) do
    t.truthy(modesHandle.elements.modeBtns[mode] ~= nil, "modes screen has a button for " .. mode)
  end
  t.eq(#modesHandle.elements.footerRow.buttons, 2, "modes footer row has exactly '?' and '<'")
  t.truthy(modesHandle.elements.comBtn ~= nil, "COM sibling on the modes root")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build: drilling PRECISION -> cat -> GAINS axis -> ALT shows KP/KI/KD steppers with -/+", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  t.eq(region:top(), "cat_PRECISION")
  local catHandle = region.built.cat_PRECISION.handle
  t.truthy(catHandle.elements.catBtns.GAINS ~= nil, "cat screen has a GAINS button")
  t.truthy(catHandle.elements.catBtns.CAPS ~= nil, "cat screen has a CAPS button")
  t.truthy(catHandle.elements.catBtns.FEEL ~= nil, "cat screen has a FEEL button")

  region:push("gains_axis_PRECISION"); h.apply({})
  t.eq(region:top(), "gains_axis_PRECISION")
  local axisHandle = region.built.gains_axis_PRECISION.handle
  t.truthy(axisHandle.elements.axisBtns.alt ~= nil, "GAINS axis screen has an ALT button")
  t.truthy(axisHandle.elements.baseBtn ~= nil, "GAINS axis screen has a BASE button")

  region:push("edit_PRECISION_GAINS_alt"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_GAINS_alt")
  local editHandle = region.built.edit_PRECISION_GAINS_alt.handle
  t.eq(#editHandle.elements.rowIds, 3, "ALT gains edit screen has exactly 3 rows (KP/KI/KD)")
  local ids = {}
  for _, slot in ipairs(populatedSlots(editHandle.elements.rowSlots)) do
    ids[slot.id] = true
    t.truthy(slot.minus ~= nil and slot.plus ~= nil, "row " .. slot.id .. " has -/+ buttons")
  end
  t.truthy(ids["gains.alt.kp"], "gains.alt.kp row present")
  t.truthy(ids["gains.alt.ki"], "gains.alt.ki row present")
  t.truthy(ids["gains.alt.kd"], "gains.alt.kd row present")
end)

t.test("M.build: GAINS axis screen's BASE button homes the 3 non-axis gains rows (hoverDuty/heaveMin/heaveMax)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("gains_axis_PRECISION"); h.apply({})
  region:push("edit_PRECISION_GAINS_base"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_GAINS_base")

  local baseHandle = region.built.edit_PRECISION_GAINS_base.handle
  t.eq(#baseHandle.elements.rowIds, 3, "BASE screen has exactly the 3 non-axis gains rows")
  local ids = {}
  for _, slot in ipairs(populatedSlots(baseHandle.elements.rowSlots)) do ids[slot.id] = true end
  t.truthy(ids["gains.hoverDuty"], "gains.hoverDuty present on BASE screen")
  t.truthy(ids["gains.heaveMin"], "gains.heaveMin present on BASE screen")
  t.truthy(ids["gains.heaveMax"], "gains.heaveMax present on BASE screen")
end)

t.test("M.build: CAPS/FEEL have no axis layer -- CAPS is flat; every mode's FEEL splits into BASE/MODE FEEL (fit fix, Task 14: PRECISION joins the split now that trim/ramp are shared)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("edit_PRECISION_CAPS"); h.apply({})
  t.eq(region:top(), "edit_PRECISION_CAPS")
  t.eq(#region.built.edit_PRECISION_CAPS.handle.elements.rowIds, 5, "5 CAPS rows")

  region:pop(); h.apply({})
  -- PRECISION's FEEL is now 14 rows (8 base + 6 shared trim/ramp/flip-guard) -- too many for one
  -- flat screen (title+14+footer=16 > budget 10) -- so it now ALSO routes through feel_menu, same
  -- as every other mode.
  region:push("feel_menu_PRECISION"); h.apply({})
  t.eq(region:top(), "feel_menu_PRECISION")
  local precFeelMenu = region.built.feel_menu_PRECISION.handle
  t.truthy(precFeelMenu.elements.baseBtn ~= nil, "feel_menu_PRECISION has a BASE FEEL button")
  t.truthy(precFeelMenu.elements.extraBtn ~= nil, "feel_menu_PRECISION has a MODE FEEL button")

  region:push("edit_PRECISION_FEEL_base"); h.apply({})
  t.eq(#region.built.edit_PRECISION_FEEL_base.handle.elements.rowIds, 8, "8 base FEEL rows for PRECISION")

  region:pop(); h.apply({})
  region:push("edit_PRECISION_FEEL_extra"); h.apply({})
  local precFeelExtraHandle = region.built.edit_PRECISION_FEEL_extra.handle
  t.eq(#precFeelExtraHandle.elements.rowIds, 6, "PRECISION MODE FEEL has exactly the 6 shared trim/ramp/flip-guard rows (no own extras)")
  local precExtraIds = {}
  for _, slot in ipairs(populatedSlots(precFeelExtraHandle.elements.rowSlots)) do precExtraIds[slot.id] = true end
  t.truthy(precExtraIds["feel.trimGain"], "PRECISION MODE FEEL includes feel.trimGain")
  t.truthy(precExtraIds["feel.climbRampTime"], "PRECISION MODE FEEL includes feel.climbRampTime")
  t.truthy(precExtraIds["feel.climbBoost"], "PRECISION MODE FEEL includes feel.climbBoost")
  t.truthy(precExtraIds["feel.trimAuthority"], "PRECISION MODE FEEL includes feel.trimAuthority")
  t.truthy(precExtraIds["feel.trimFadeStart"], "PRECISION MODE FEEL includes feel.trimFadeStart")
  t.truthy(precExtraIds["feel.trimFade"], "PRECISION MODE FEEL includes feel.trimFade")

  region:pop(); region:pop(); region:pop() -- back to modes
  region:push("cat_MAN"); h.apply({})
  local catMan = region.built.cat_MAN.handle
  t.truthy(catMan.elements.catBtns.FEEL ~= nil, "cat_MAN has a FEEL button")

  -- MAN's FEEL button routes to the small feel_menu_MAN (BASE FEEL / MODE FEEL), NOT a flat
  -- 10-row edit screen -- that flat screen would overflow a realistic ~12-row monitor's region
  -- budget (title 1 + 10 rows + footer 1 = 12 > 10; see the fit-regression test below).
  region:push("feel_menu_MAN"); h.apply({})
  t.eq(region:top(), "feel_menu_MAN")
  local feelMenu = region.built.feel_menu_MAN.handle
  t.truthy(feelMenu.elements.baseBtn ~= nil, "feel_menu_MAN has a BASE FEEL button")
  t.truthy(feelMenu.elements.extraBtn ~= nil, "feel_menu_MAN has a MODE FEEL button")

  region:push("edit_MAN_FEEL_base"); h.apply({})
  local manFeelBaseHandle = region.built.edit_MAN_FEEL_base.handle
  t.eq(#manFeelBaseHandle.elements.rowIds, 8, "BASE FEEL has the 8 base feel rows, no per-mode extras")
  for _, slot in ipairs(populatedSlots(manFeelBaseHandle.elements.rowSlots)) do
    t.truthy(slot.id ~= "feel.tiltRate" and slot.id ~= "feel.tiltCap", "BASE FEEL excludes MAN's own extras: " .. slot.id)
  end

  region:pop(); h.apply({})
  region:push("edit_MAN_FEEL_extra"); h.apply({})
  local manFeelExtraHandle = region.built.edit_MAN_FEEL_extra.handle
  t.eq(#manFeelExtraHandle.elements.rowIds, 13, "MODE FEEL has MAN's 2 own extras + 5 brake rows + the 6 rows shared by every flight mode")
  local extraIds = {}
  for _, slot in ipairs(populatedSlots(manFeelExtraHandle.elements.rowSlots)) do extraIds[slot.id] = true end
  t.truthy(extraIds["feel.tiltRate"], "MODE FEEL includes feel.tiltRate")
  t.truthy(extraIds["feel.tiltCap"], "MODE FEEL includes feel.tiltCap")
  t.truthy(extraIds["feel.tiltBrake.engageSpeed"], "MODE FEEL includes feel.tiltBrake.engageSpeed")
  t.truthy(extraIds["feel.tiltBrake.buttonMax"], "MODE FEEL includes feel.tiltBrake.buttonMax")
  t.truthy(extraIds["feel.trimGain"], "MODE FEEL includes shared feel.trimGain")
  t.truthy(extraIds["feel.climbRampTime"], "MODE FEEL includes shared feel.climbRampTime")
  t.truthy(extraIds["feel.climbBoost"], "MODE FEEL includes shared feel.climbBoost")
  t.truthy(extraIds["feel.trimAuthority"], "MODE FEEL includes shared feel.trimAuthority")
  t.truthy(extraIds["feel.trimFadeStart"], "MODE FEEL includes shared feel.trimFadeStart")
  t.truthy(extraIds["feel.trimFade"], "MODE FEEL includes shared feel.trimFade")
end)

t.test("M.build: CRUISE FEEL also splits into BASE/MODE FEEL, with CRUISE's own throttle extras + the 6 shared trim/ramp/flip-guard rows", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_CRUISE"); h.apply({})
  region:push("feel_menu_CRUISE"); h.apply({})
  region:push("edit_CRUISE_FEEL_extra"); h.apply({})
  local extraHandle = region.built.edit_CRUISE_FEEL_extra.handle
  t.eq(#extraHandle.elements.rowIds, 13, "MODE FEEL has CRUISE's 2 own extras + 5 brake rows + the 6 rows shared by every flight mode")
  local ids = {}
  for _, slot in ipairs(populatedSlots(extraHandle.elements.rowSlots)) do ids[slot.id] = true end
  t.truthy(ids["feel.cruiseThrottleRate"], "MODE FEEL includes feel.cruiseThrottleRate")
  t.truthy(ids["feel.cruiseThrottleMax"], "MODE FEEL includes feel.cruiseThrottleMax")
  t.truthy(ids["feel.tiltBrake.engageSpeed"], "MODE FEEL includes feel.tiltBrake.engageSpeed")
  t.truthy(ids["feel.tiltBrake.buttonMax"], "MODE FEEL includes feel.tiltBrake.buttonMax")
  t.truthy(ids["feel.trimGain"], "MODE FEEL includes shared feel.trimGain")
  t.truthy(ids["feel.climbRampTime"], "MODE FEEL includes shared feel.climbRampTime")
  t.truthy(ids["feel.climbBoost"], "MODE FEEL includes shared feel.climbBoost")
  t.truthy(ids["feel.trimAuthority"], "MODE FEEL includes shared feel.trimAuthority")
  t.truthy(ids["feel.trimFadeStart"], "MODE FEEL includes shared feel.trimFadeStart")
  t.truthy(ids["feel.trimFade"], "MODE FEEL includes shared feel.trimFade")
end)

t.test("M.build: LDG FEEL splits into BASE/MODE FEEL, with only the 6 rows shared by every flight mode (no own extras)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_LDG"); h.apply({})
  region:push("feel_menu_LDG"); h.apply({})
  region:push("edit_LDG_FEEL_extra"); h.apply({})
  local extraHandle = region.built.edit_LDG_FEEL_extra.handle
  t.eq(#extraHandle.elements.rowIds, 6, "MODE FEEL has exactly the 6 rows shared by every flight mode -- LDG gets no brake rows")
  local ids = {}
  for _, slot in ipairs(populatedSlots(extraHandle.elements.rowSlots)) do ids[slot.id] = true end
  t.truthy(ids["feel.trimGain"], "MODE FEEL includes feel.trimGain")
  t.truthy(ids["feel.climbRampTime"], "MODE FEEL includes feel.climbRampTime")
  t.truthy(ids["feel.climbBoost"], "MODE FEEL includes feel.climbBoost")
  t.truthy(ids["feel.trimAuthority"], "MODE FEEL includes feel.trimAuthority")
  t.truthy(ids["feel.trimFadeStart"], "MODE FEEL includes feel.trimFadeStart")
  t.truthy(ids["feel.trimFade"], "MODE FEEL includes feel.trimFade")
  for id in pairs(ids) do
    t.truthy(not id:match("^feel%.tiltBrake%."), "LDG MODE FEEL has no brake row: " .. id)
  end

  region:pop(); h.apply({})
  region:push("edit_LDG_FEEL_base"); h.apply({})
  local baseHandle = region.built.edit_LDG_FEEL_base.handle
  t.eq(#baseHandle.elements.rowIds, 8, "BASE FEEL has the 8 base feel rows, no per-mode extras")
  for _, slot in ipairs(populatedSlots(baseHandle.elements.rowSlots)) do
    t.truthy(ids[slot.id] == nil, "BASE FEEL excludes LDG's shared extras: " .. slot.id)
  end
end)

t.test("M.build: DRN FEEL splits into BASE/MODE FEEL, with DRN's own tiltRate/tiltCap + 5 brake rows + the 6 shared trim/ramp/flip-guard rows", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_DRN"); h.apply({})
  region:push("feel_menu_DRN"); h.apply({})
  region:push("edit_DRN_FEEL_extra"); h.apply({})
  local extraHandle = region.built.edit_DRN_FEEL_extra.handle
  t.eq(#extraHandle.elements.rowIds, 13, "MODE FEEL has DRN's 2 own tilt extras + 5 brake rows + the 6 rows shared by every flight mode")
  local ids = {}
  for _, slot in ipairs(populatedSlots(extraHandle.elements.rowSlots)) do ids[slot.id] = true end
  t.truthy(ids["feel.tiltRate"], "MODE FEEL includes feel.tiltRate")
  t.truthy(ids["feel.tiltCap"], "MODE FEEL includes feel.tiltCap")
  t.truthy(ids["feel.tiltBrake.engageSpeed"], "MODE FEEL includes feel.tiltBrake.engageSpeed")
  t.truthy(ids["feel.tiltBrake.buttonMax"], "MODE FEEL includes feel.tiltBrake.buttonMax")
  t.truthy(ids["feel.trimGain"], "MODE FEEL includes shared feel.trimGain")
  t.truthy(ids["feel.trimAuthority"], "MODE FEEL includes shared feel.trimAuthority")
  t.truthy(ids["feel.trimFadeStart"], "MODE FEEL includes shared feel.trimFadeStart")
  t.truthy(ids["feel.trimFade"], "MODE FEEL includes shared feel.trimFade")
end)

t.test("M.build: '?' opens a help screen with real glossary content (help_alt, help_modes)", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  region:push("gains_axis_PRECISION"); h.apply({})
  region:push("edit_PRECISION_GAINS_alt"); h.apply({})
  region:push("help_alt"); h.apply({})
  t.eq(region:top(), "help_alt")
  local helpHandle = region.built.help_alt.handle
  t.truthy(helpHandle.elements.lineLabels ~= nil and #helpHandle.elements.lineLabels >= 1, "help_alt has line labels")
  t.truthy(helpHandle.elements.row ~= nil, "help_alt has its UP/DN/< action row")

  -- help_modes reachable straight from the modes root.
  region:pop(); region:pop(); region:pop(); region:pop() -- unwind back to modes
  t.eq(region:top(), "modes")
  region:push("help_modes"); h.apply({})
  t.truthy(region.built.help_modes ~= nil, "help_modes screen built")
end)

t.test("M.build: cat_<mode>'s exposed doSave/doReset call M._save/M.resetMode for the active mode", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- Seed the injected read with an ALREADY-MUTATED cfg (gains.pitch.kp off its default) so
  -- M.build's workingCfg starts mutated -- doReset's effect (M.resetMode, PRECISION-scoped) is
  -- then directly observable through doSave's serialised output, without needing a real Basalt
  -- click (same "exercise the seams directly" idiom the old flat-UI test used).
  local mutated = tuningdefaults.get()
  mutated.gains.pitch.kp = 0.999
  local stored = textutils.serialise(mutated)
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  region:push("cat_PRECISION"); h.apply({})
  local catHandle = region.built.cat_PRECISION.handle
  t.truthy(type(catHandle.elements.doSave) == "function", "doSave exposed")
  t.truthy(type(catHandle.elements.doReset) == "function", "doReset exposed")

  catHandle.elements.doSave()
  local before = textutils.unserialise(stored)
  t.eq(before.gains.pitch.kp, 0.999, "doSave persisted the seeded (mutated) workingCfg via M._save")

  catHandle.elements.doReset()
  t.eq(region:top(), "cat_PRECISION", "doReset repaints the still-visible cat screen (region:apply(nil)), no nav change")

  catHandle.elements.doSave()
  local after = textutils.unserialise(stored)
  t.eq(after.gains.pitch.kp, tuningdefaults.get().gains.pitch.kp,
    "doReset (M.resetMode(workingCfg,'PRECISION')) reverted the mutation to defaults")
end)

t.test("M.build: '<' -- modes pops the FRAME-level nav; region screens pop the REGION's own nav", function()
  local basalt, frame, nav, read, write, delete = newHarness()
  nav:push("tuning")
  t.eq(nav:top(), "tuning")

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  -- modes' "<" is wired to nav:pop() (FRAME-level) -- invoke the same effect directly.
  nav:pop()
  t.eq(nav:top(), "bitconfig", "modes' back pops the frame-level nav")

  -- cat_<mode>'s "<" is wired to region:pop() -- drilling in then backing out never touches nav.
  region:push("cat_PRECISION"); h.apply({})
  t.eq(region:top(), "cat_PRECISION")
  region:pop(); h.apply({})
  t.eq(region:top(), "modes", "cat screen's back returns to modes via region:pop()")
  t.eq(nav:top(), "bitconfig", "frame-level nav untouched by region-internal drilldown")
end)

-- ===== REGRESSION: every screen must fit a REALISTIC monitor, not the wide headless terminal =====
-- The old flat MAN/CRUISE FEEL edit screen (10 rows: 8 base + 2 per-mode extras) rendered its
-- footer/"<" row ~2 rows past a realistic ~12-row monitor's region budget (title 1 + 10 rows +
-- footer 1 = 12 > budget 10) -- a genuine user trap (no way back). The wide term.current() frame
-- every other construction-probe test above builds on (see newHarness()) never exercises this: it
-- has plenty of headroom regardless of row count. This test builds on an EXPLICIT short/narrow
-- child frame (14x12, mirroring test_region.lua's own convention of an explicit small
-- width/height rather than the parent's inherited term size) so `frame:getSize()` inside M.build
-- really does return a realistic monitor size, and walks EVERY registered screen (skipping the
-- help_* ones, which have their own established scrollable-content contract via
-- configkit.helpScreen) asserting its deepest row (lastRowY, exposed by every screen builder)
-- fits the SAME `height - 2` region budget M.build itself computes.
t.test("REGRESSION: every tuning screen's deepest row fits a realistic ~12-row monitor's region budget", function()
  local basalt = BasaltApp.ensureBasalt()
  local root = basalt.createFrame()
  -- Explicit short/narrow child frame -- NOT term.current()'s wide default -- mirrors
  -- tests/test_region.lua's Region.new({width=14,height=8,...}) convention of passing an explicit
  -- small size, applied here to the PAGE frame M.build itself measures via frame:getSize().
  local frame = root:addFrame({ x = 1, y = 1, width = 14, height = 12 })
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  local frameW, frameH = frame:getSize()
  t.eq(frameH, 12, "sanity: the page frame really is the short/realistic size, not the wide headless default")
  -- Task 2 (2026-09-05 brake-tune-scroll-menu): buildEditScreen now windows to a FIXED N =
  -- height-2 (or height-3 with a paged "up"/"down" row) stepper slots, whose footer/"?"/"<" row
  -- ALWAYS lands on the frame's own bottom row (configkit.actionRow's "back" item auto-pins the
  -- whole row to the frame's bottom regardless of the y passed in -- true before this retrofit
  -- too, just previously masked by lastRowY tracking the un-pinned logical y instead of the real
  -- pinned one). So every edit_* screen's lastRowY now equals frameH exactly, windowed or not --
  -- widen ONLY the edit_* budget to frameH (still catches any windowed screen whose deepest row
  -- would spill past the physical frame -- the real invariant this test protects). Every OTHER
  -- builder (modes/cat_*/gains_axis_*/feel_menu_*) is untouched by this retrofit, is NOT windowed,
  -- and can still genuinely overflow -- keep their original frameH-2 safety margin.
  local editBudget = frameH
  local otherBudget = frameH - 2

  local checked = 0
  for id, _ in pairs(region.screens) do
    if id:sub(1, 5) ~= "help_" then
      region:push(id)
      h.apply({})
      local rec = region.built[id]
      t.truthy(rec ~= nil, id .. " built")
      local handle = rec.handle
      t.truthy(handle.elements.lastRowY ~= nil, id .. " exposes lastRowY")
      local regionBudget = (id:sub(1, 5) == "edit_") and editBudget or otherBudget
      t.truthy(handle.elements.lastRowY <= regionBudget,
        id .. ": lastRowY=" .. tostring(handle.elements.lastRowY) .. " exceeds region budget " .. tostring(regionBudget))
      checked = checked + 1
    end
  end
  -- Sanity floor: modes(1) + cat*5 + gains_axis*5 + edit GAINS axis(30) + GAINS base*5 + CAPS*5 +
  -- (feel_menu*5 + FEEL base*5 + FEEL extra*5) = 1+5+5+30+5+5+15 = 66
  -- (5 modes: PRECISION, MAN, CRUISE, LDG, DRN -- Task 14: EVERY mode now splits FEEL into
  -- BASE/MODE, including PRECISION, since the 6 rows shared by every flight mode -- trim/ramp/
  -- flip-guard -- push its FEEL past the flat-screen budget too).
  t.truthy(checked >= 66, "walked all non-help screens across every mode, got " .. checked)
end)

-- ===== Task 2 (2026-09-05 brake-tune-scroll-menu): brake-curve rows + windowed edit screens =====

t.test("brake rows: present in MODE FEEL for CRU/MAN/DRN, absent for PRE/LDG", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local function feelExtraIds(mode)
    local ids = {}
    for _, r in ipairs(T.rows({}, mode)) do
      if r.id:match("^feel%.tiltBrake%.") then ids[r.id] = true end
    end
    return ids
  end
  for _, mode in ipairs({ "CRUISE", "MAN", "DRN" }) do
    local ids = feelExtraIds(mode)
    t.truthy(ids["feel.tiltBrake.engageSpeed"], mode .. " has BRAKE ENGAGE")
    t.truthy(ids["feel.tiltBrake.buttonMax"],  mode .. " has BRAKE BTN")
  end
  for _, mode in ipairs({ "PRECISION", "LDG" }) do
    local ids = feelExtraIds(mode)
    t.eq(next(ids), nil, mode .. " has no brake rows")
  end
end)

t.test("brake row apply writes the nested per-mode path, clamped to step/min/max", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local cfg = T.apply({}, "CRUISE", "feel.tiltBrake.engageSpeed", 1)  -- from default 30, step 1 -> 31
  t.near(cfg.modes.CRUISE.feel.tiltBrake.engageSpeed, 31, 1e-9)
  -- min clamp: buttonMax default 0.7854, step 0.02; huge negative delta floors at 0
  local cfg2 = T.apply({}, "MAN", "feel.tiltBrake.buttonMax", -1000)
  t.near(cfg2.modes.MAN.feel.tiltBrake.buttonMax, 0, 1e-9)
end)

-- ===== Construction probe: windowed edit screen paging (real CraftOS-PC Basalt) =====
-- edit_CRUISE_FEEL_extra is now 13 rows (2 CRUISE throttle extras + 5 new brake rows + 6 shared
-- trim/ramp/flip-guard rows) -- too many for ANY realistic monitor's stepper budget, so it must
-- page. Built on an explicit SHORT/NARROW child frame (mirrors the fit-regression test's own
-- 14x12 convention above), but at height=8 -- narrow enough that N (the actual windowed slot
-- count) lands below 7, so offset-0 genuinely hides some of the brake rows (which sit right after
-- CRUISE's own 2 throttle rows, i.e. rows 3-7 of the 13) and paging down surfaces them -- verified
-- against the real configkit.actionRow width math (see buildEditScreen's header comment) rather
-- than assumed.
t.test("M.build: edit_CRUISE_FEEL_extra windows to <= height-2 slots and pages a hidden brake row into view", function()
  local basalt = BasaltApp.ensureBasalt()
  local root = basalt.createFrame()
  local frame = root:addFrame({ x = 1, y = 1, width = 14, height = 8 })
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region

  local frameW, frameH = frame:getSize()
  t.eq(frameH, 8, "sanity: short/realistic paging frame")

  region:push("cat_CRUISE"); h.apply({})
  region:push("feel_menu_CRUISE"); h.apply({})
  region:push("edit_CRUISE_FEEL_extra"); h.apply({})
  local extraHandle = region.built.edit_CRUISE_FEEL_extra.handle
  local els = extraHandle.elements

  t.eq(#els.rowIds, 13, "13 rows: 2 CRUISE own extras + 5 brake rows + 6 shared")
  -- (a) windowed, not all 13 laid out -- at most N = height-2 stepper slots
  t.truthy(#els.rowSlots <= frameH - 2, "rowSlots windowed to <= height-2, got " .. #els.rowSlots)
  t.truthy(#els.rowSlots < 13, "fewer slots than the full 13-row set (actually paging)")
  t.truthy(els.lastRowY <= frameH, "footer/lastRowY fits inside the frame")

  -- (b) rows overflow -> scrollUp/scrollDown handles present
  t.truthy(els.scrollUp ~= nil, "scrollUp present when rows overflow")
  t.truthy(els.scrollDown ~= nil, "scrollDown present when rows overflow")

  local function visibleIds()
    local ids = {}
    for _, slot in ipairs(els.rowSlots) do if slot.id then ids[slot.id] = true end end
    return ids
  end
  local before = visibleIds()

  els.pageDown()
  local after = visibleIds()
  local newBrakeRow = false
  for id in pairs(after) do
    if id:match("^feel%.tiltBrake%.") and not before[id] then newBrakeRow = true end
  end
  t.truthy(newBrakeRow, "paging down surfaces a brake row that was not visible at offset 0")

  -- (c) a screen that FITS has no scroll buttons
  region:push("edit_CRUISE_CAPS"); h.apply({})
  local capsHandle = region.built.edit_CRUISE_CAPS.handle
  t.eq(capsHandle.elements.scrollUp, nil, "fitting screen (CAPS) has no scrollUp")
  t.eq(capsHandle.elements.scrollDown, nil, "fitting screen (CAPS) has no scrollDown")
  t.truthy(#capsHandle.elements.rowSlots >= 5, "fitting screen shows every one of its 5 rows at offset 0")
end)

-- FIX 1 (review, 2026-09-05): a fitting screen must stay PIXEL-IDENTICAL to the pre-retrofit
-- layout -- exactly #rowIds stepper slots, footer landing right after the last row, no blank
-- padding slots down to the frame's bottom. buildEditScreen's non-overflow branch must cap N at
-- #rowIds (not the full height-2 budget). Verified against the current (post-FIX1) code as GREEN;
-- against the pre-FIX1 code (N always fixed at height-2 regardless of row count) this would have
-- FAILED -- e.g. edit_CRUISE_CAPS has 5 rows but a 14x12 frame's N_fit=10, so the old fixed-N code
-- built 10 rowSlots (5 populated + 5 blank) instead of exactly 5.
t.test("FIX 1: a fitting edit screen (edit_CRUISE_CAPS) lays out exactly #rowIds rowSlots -- no blank padding", function()
  local basalt = BasaltApp.ensureBasalt()
  local root = basalt.createFrame()
  local frame = root:addFrame({ x = 1, y = 1, width = 14, height = 12 })
  local nav = Nav.new("bitconfig")
  local stored = nil
  local function read(filename) return stored end
  local function write(filename, body) stored = body end
  local function delete(path) stored = nil end

  local h = M.build(basalt, frame, nil, nav, read, write, delete)
  local region = h.elements.region
  region:push("cat_CRUISE"); h.apply({})
  region:push("edit_CRUISE_CAPS"); h.apply({})
  local capsHandle = region.built.edit_CRUISE_CAPS.handle

  t.eq(#capsHandle.elements.rowIds, 5, "sanity: CAPS has 5 rows")
  t.eq(#capsHandle.elements.rowSlots, 5, "fitting screen creates exactly #rowIds rowSlots, no blank padding")
  for i, slot in ipairs(capsHandle.elements.rowSlots) do
    t.truthy(slot.id ~= nil, "slot " .. i .. " is populated, not blank")
  end
  -- footer lands right after the last (5th) row, not padded down to the frame's bottom
  t.eq(capsHandle.elements.lastRowY, 2 + 5, "footer lands right after the last row (y0=2 + 5 rows)")
end)

return true
