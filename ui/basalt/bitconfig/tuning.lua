-- ui/basalt/bitconfig/tuning.lua
-- FCS TUNING sub-menu (BIT/CONFIG hub, screen id "tuning"): lets the operator edit the FCS
-- tuning cfg (fcs/io/tuningdefaults.lua's shape) on the UI PC. Default read/write seams go
-- through ui.basalt.cfgseam -- SAVE ships a `set` to the running FCS (persisted there; tuning
-- needs a reload to apply). CoM is the hot-apply exception via the COM screen's pushCom
-- (command-channel setCom) AND the FCS responder. This menu no longer edits the on-disk cfg
-- the boot loader reads. RST (per-mode, Task 8) resets ONLY the active mode's subtree to the
-- committed defaults in fcs/io/tuningdefaults.lua -- see M.resetMode; the OLDER whole-file
-- M._reset/delete flow stays defined (still tested) but is no longer called from M.build.
--
-- Follows the Task 15/17 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`, a
-- Basalt-free PURE view-model (M.ROW_SPEC / M.rows / M.apply / M.MODES / M.pathFor / M.resetMode),
-- Basalt-free save/reset seams (M._save / M._reset), and `M.build(basalt, frame, runtime, nav,
-- read, write, delete) -> { id, apply(state), elements }` with an idempotent apply() (this menu
-- shows CONFIG, not live telemetry, so nothing here polls peripherals).
--
-- ===== Task 8 UI SHAPE: mode -> category -> axis drilldown (ui/basalt/region.lua) =====
-- The old flat build crammed 34 stepper rows onto ONE paged screen. M.build now hosts a
-- region.lua drilldown (root "modes") inside this page's own frame, mirroring
-- ui/basalt/bitconfig/mdb.lua's/senscal.lua's overview->sub-screen construction:
--   * "modes": PRECISION/MAN/CRUISE/LDG/DRN buttons (one per M.MODES, region:push("cat_"..mode))
--     + "?"(help_modes) + "<" (FRAME-level nav:pop -- this is the page's own top). Task 14: CPL/
--     DCPL are MASTER modes now (a separate, always-on selector; see fcs/modes/registry.lua's
--     SPECS for the canonical 5 flight modes), not flight modes -- they left this list; LDG/DRN
--     (already-shipped flight modes) took their place.
--   * "cat_<mode>" (one per M.MODES): GAINS/CAPS/FEEL buttons (region:push into the axis layer
--     for GAINS, straight to a flat edit screen for CAPS, into "feel_menu_<mode>" for FEEL -- see
--     below) + a SAVE/RST row (SAVE calls M._save(workingCfg, write); RST calls
--     M.resetMode(workingCfg, mode) -- a MODE-SCOPED reset, replacing the old whole-file
--     M._reset/delete flow) + a "?"(help_modes)/"<" (region:pop, back to "modes") row.
--   * "gains_axis_<mode>": ALT/PITCH/ROLL/YAW/SWAY/SURGE buttons (one per M.rows "gains.<axis>."
--     id prefix) PLUS a "BASE" button homing the 3 non-axis gains rows (hoverDuty/heaveMin/
--     heaveMax -- these have no axis and would otherwise be dropped by an axis-only layer) +
--     "?"(help_gains) + "<" (region:pop, back to "cat_<mode>"). CAPS has NO axis layer.
--   * FEEL fit fix: EVERY mode's FEEL button opens "feel_menu_<mode>" (a small BASE FEEL / MODE
--     FEEL chooser, mirroring the GAINS axis/BASE split above), which fans out to
--     "edit_<mode>_FEEL_base" (the 8 base rows shared by every mode, filtered via FEEL_BASE_IDS)
--     and "edit_<mode>_FEEL_extra" (that mode's own extras, if any -- 2 for MAN/CRUISE/DRN, none
--     for PRECISION/LDG -- PLUS the 6 rows Task 14/trim-flip-guard-Task-5 made shared by ALL
--     flight modes now that forward-trim/rampable-climb/flip-guard apply everywhere:
--     feel.trimGain/feel.climbRampTime/feel.climbBoost/feel.trimAuthority/feel.trimFadeStart/
--     feel.trimFade, see SHARED_FEEL_EXTRA_ROWS below). BASE FEEL is always exactly 8 rows
--     (title+8+footer=10, the ~12-row monitor's region budget EXACTLY); MODE FEEL is 6 rows for
--     PRECISION/LDG (title+6+footer=8) or 8 rows for MAN/CRUISE/DRN (title+8+footer=10) -- both
--     fit inside the same budget (MAN/CRUISE/DRN now lands EXACTLY on it). PRECISION used to skip
--     this menu entirely (its FEEL was flat, 8 rows fit alone on one screen) -- Task 14 folded the
--     shared trim/ramp rows into EVERY mode's extras, so PRECISION's FEEL no longer fits one flat
--     screen and needs the SAME split, closing that exception -- every mode, including PRECISION,
--     now routes through feel_menu_<mode>.
--   * "edit_<mode>_<GROUP>[_<axis>]"/"edit_<mode>_FEEL_base"/"edit_<mode>_FEEL_extra": the actual
--     +/- stepper rows -- built by one shared factory (buildEditScreen) parameterised by a pure
--     filter over M.rows(workingCfg, mode), so a screen's row SET (ids) is fixed at build time
--     (M.ROW_SPEC/the per-mode extras never change at runtime) while each row's displayed
--     value/step is re-read live on every refresh(). Each +/- click calls
--     M.apply(workingCfg, mode, rowId, +-1) (the UNCHANGED Task 7 pure model) and repaints just
--     this screen's own labels. "?" pushes a context help screen (help_<axis> for a GAINS axis
--     screen, help_gains for the BASE screen, help_caps/help_feel for CAPS/FEEL); "<" pops back to
--     the axis/menu layer (GAINS/FEEL) or straight to "cat_<mode>" (CAPS).
--   * help_modes/help_gains/help_caps/help_feel/help_<axis> (alt/pitch/roll/yaw/sway/surge): each
--     `function(b,f,r) return configkit.helpScreen(b,f,r,"<entryId>") end` -- configkit.helpScreen
--     already wires its OWN "<" to region:pop(), so no extra back-wiring is needed for these.
--   * Every screen builder exposes `elements.lastRowY` -- the y its deepest row (the footer) was
--     placed at -- a generic, layout-derived fit signal a regression test in
--     tests/test_bitconfig_tuning.lua asserts against the SAME `height - 2` region budget M.build
--     itself computes, at a REALISTIC ~12-row monitor size (not the wide headless terminal, which
--     is what let the MAN/CRUISE FEEL overflow ship in the first place).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.tuning")` loads clean headless.

local cfgspec        = require("fcs.io.cfgspec")
local tuningdefaults  = require("fcs.io.tuningdefaults")
local fsx             = require("fcs.io.fsx")
local Region          = require("ui.basalt.region")
local configkit       = require("ui.basalt.configkit")
local switchbtn       = require("ui.basalt.switchbtn")
local ComAuto         = require("fcs.comauto")
local cfgseam         = require("ui.basalt.cfgseam")

local M = {}
M.id = "tuning"
M.title = "FCS TUNING"

-- ===== dotted-path helpers (pure, no Basalt/fs) =====

local function getPath(t, path)
  local cur = t
  for key in path:gmatch("[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[key]
  end
  return cur
end

local function setPath(t, path, value)
  local cur = t
  local keys = {}
  for key in path:gmatch("[^.]+") do keys[#keys + 1] = key end
  for i = 1, #keys - 1 do
    local k = keys[i]
    if type(cur[k]) ~= "table" then cur[k] = {} end
    cur = cur[k]
  end
  cur[keys[#keys]] = value
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deepcopy(x) end
  return o
end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- Number of decimal places implied by a step (0.01 -> 2, 0.1 -> 1, 1 -> 0, 0.05 -> 2), so
-- +/- clicks land on exact, driftless values instead of accumulating float noise.
local function decimalsForStep(step)
  local d = 0
  local s = step
  while s < 1 and d < 6 do
    s = s * 10
    d = d + 1
  end
  return d
end

local function roundTo(v, decimals)
  local mult = 10 ^ decimals
  if v >= 0 then return math.floor(v * mult + 0.5) / mult end
  return math.ceil(v * mult - 0.5) / mult
end

-- ===== M.ROW_SPEC: canonical ordered list of tunables =====
-- {id=<dotted path into the tuning cfg>, label, group, step, min, max}. Covers the gain axes'
-- kp/ki/kd, gains.hoverDuty/heaveMin/heaveMax, caps.*, and feel.* -- the tunables named in the
-- task brief. tauD/iMax/iMin (alt's extra PID terms) are intentionally out of scope here.
local AXES = { "alt", "pitch", "roll", "yaw", "sway", "surge" }
local AXIS_LABEL = { alt = "ALT", pitch = "PITCH", roll = "ROLL", yaw = "YAW", sway = "SWAY", surge = "SURGE" }

local ROW_SPEC = {}
local function addRow(id, label, group, step, min, max)
  ROW_SPEC[#ROW_SPEC + 1] = { id = id, label = label, group = group, step = step, min = min, max = max }
end

addRow("gains.hoverDuty", "HOVER DUTY", "GAINS", 0.01, 0, 1)
addRow("gains.heaveMin",  "HEAVE MIN",  "GAINS", 0.01, 0, 1)
addRow("gains.heaveMax",  "HEAVE MAX",  "GAINS", 0.01, 0, 1)
for _, axis in ipairs(AXES) do
  local al = AXIS_LABEL[axis]
  addRow("gains." .. axis .. ".kp", al .. " KP", "GAINS", 0.01, 0, 5)
  addRow("gains." .. axis .. ".ki", al .. " KI", "GAINS", 0.01, 0, 1)
  addRow("gains." .. axis .. ".kd", al .. " KD", "GAINS", 0.01, 0, 5)
end

addRow("caps.pitch", "PITCH CAP", "CAPS", 0.05, 0, 2)
addRow("caps.roll",  "ROLL CAP",  "CAPS", 0.05, 0, 2)
addRow("caps.yaw",   "YAW CAP",   "CAPS", 0.05, 0, 2)
addRow("caps.sway",  "SWAY CAP",  "CAPS", 0.05, 0, 2)
addRow("caps.surge", "SURGE CAP", "CAPS", 0.05, 0, 2)

addRow("feel.headingRate",    "HEADING RATE",     "FEEL", 0.1, 0, 10)
addRow("feel.leadCapHeading", "HEADING LEAD CAP", "FEEL", 0.05, 0, 5)
addRow("feel.climbRate",      "CLIMB RATE",       "FEEL", 0.1, 0, 20)
addRow("feel.leadCapVert",    "VERT LEAD CAP",    "FEEL", 0.5, 0, 50)
addRow("feel.surgeSpeed",     "SURGE SPEED",      "FEEL", 0.5, 0, 50)
addRow("feel.surgeLead",      "SURGE LEAD",       "FEEL", 1.0, 0, 100)
addRow("feel.swaySpeed",      "SWAY SPEED",       "FEEL", 0.5, 0, 50)
addRow("feel.swayLead",       "SWAY LEAD",        "FEEL", 0.5, 0, 100)

M.ROW_SPEC = ROW_SPEC

local COM_SPEC = {
  { id = "com.fwd",       label = "FWD",    group = "COM", step = 0.1, min = -20, max = 20 },
  { id = "com.right",     label = "RIGHT",  group = "COM", step = 0.1, min = -20, max = 20 },
  { id = "com.spanFwd",   label = "SP FWD", group = "COM", step = 0.1, min = 0.1, max = 20 },
  { id = "com.spanRight", label = "SP LAT", group = "COM", step = 0.1, min = 0.1, max = 20 },
}
M.COM_SPEC = COM_SPEC

local SPEC_BY_ID = {}
for _, spec in ipairs(ROW_SPEC) do SPEC_BY_ID[spec.id] = spec end
for _, spec in ipairs(COM_SPEC) do SPEC_BY_ID[spec.id] = spec end

-- ===== per-mode tuning: PRECISION is the top-level gains/caps/feel (unchanged); MAN/CRUISE =====
-- ===== live under modes.MAN / modes.CRUISE and carry their own extra FEEL rows on top      =====
-- ===== of the 34 base rows (see fcs/io/tuningdefaults.lua's DEFAULTS.modes).                =====

-- Task 14: CPL/DCPL became MASTER modes (a separate, always-on selector -- see
-- docs/superpowers/specs/2026-08-29-flight-master-mode-split-design.md) and are no longer
-- tunable flight modes here. LDG/DRN (already-shipped flight modes, see
-- fcs/modes/registry.lua's SPECS) took their place -- these 5 are the canonical flight modes.
M.MODES = { "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }

-- M.pathFor(mode, dotted) -> dotted path into the cfg tree for that mode. PRECISION (or a nil
-- mode) is the top-level path as-is; MAN/CRUISE are prefixed under modes.<mode>. PURE.
function M.pathFor(mode, dotted)
  if type(dotted) == "string" and dotted:sub(1, 4) == "com." then return dotted end
  if mode == nil or mode == "PRECISION" then return dotted end
  return "modes." .. mode .. "." .. dotted
end

-- SHARED_FEEL_EXTRA_ROWS: forward-trim + rampable-climb feel now apply to EVERY flight mode
-- (Task 14 -- these were moved into the shared DEFAULTS.feel, tuningdefaults.lua, in an earlier
-- task of this SDD, once CPL/DCPL stopped being the only place trim/ramp lived). Kept OUT of the
-- 8 base FEEL rows (ROW_SPEC) on purpose: adding them there would push PRECISION's flat 8-row
-- FEEL screen (which already fit the ~12-row budget EXACTLY, title+8+footer=10) well past it.
-- Routing them through the SAME base/extra FEEL split MAN/CRUISE already used (see
-- feel_menu_<mode> below) keeps every mode's BASE FEEL screen a flat 8 (10 total) and every mode's
-- MODE FEEL screen at 6-8 rows (8-10 total) -- still inside budget. trim-flip-guard-Task-5 added
-- feel.trimAuthority/feel.trimFadeStart/feel.trimFade here (3 -> 6 shared rows): MAN/CRUISE/DRN's
-- MODE FEEL screen (their 2 own extras + these 6) now lands EXACTLY on the 10-row budget
-- (title+8+footer=10) -- verified by the REGRESSION construction probe in
-- tests/test_bitconfig_tuning.lua, not by hand -- any further shared row needs a new split.
local SHARED_FEEL_EXTRA_ROWS = {
  { id = "feel.climbRampTime", label = "CLIMB RAMP TIME", group = "FEEL", step = 0.1,  min = 0.1, max = 5.0 },
  { id = "feel.climbBoost",    label = "CLIMB BOOST",     group = "FEEL", step = 0.1,  min = 0.5, max = 5.0 },
  { id = "feel.trimGain",      label = "TRIM GAIN",       group = "FEEL", step = 0.01, min = 0,   max = 1.0 },
  { id = "feel.trimAuthority", label = "TRIM AUTH",       group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
  { id = "feel.trimFadeStart", label = "TRIM FADE LO",    group = "FEEL", step = 0.05, min = 0,   max = 1.5 },
  { id = "feel.trimFade",      label = "TRIM FADE HI",    group = "FEEL", step = 0.05, min = 0,   max = 1.5 },
}

-- MODE_OWN_EXTRA_ROWS: each flight mode's OWN extra feel rows, on top of the 8 base ROW_SPEC rows
-- AND SHARED_FEEL_EXTRA_ROWS above -- MAN/DRN get arrow-key/WASD tilt feel, CRUISE gets
-- surge-throttle feel (see tuningdefaults.lua's DEFAULTS.modes.MAN/.CRUISE/.DRN.feel).
-- PRECISION/LDG have none of their own: LDG only overrides base feel VALUES (surgeSpeed/
-- surgeLead/swaySpeed/swayLead/climbRate) -- no new field names to tune -- and PRECISION never
-- had per-mode feel to begin with.
local MODE_OWN_EXTRA_ROWS = {
  MAN = {
    { id = "feel.tiltRate", label = "TILT RATE", group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.tiltCap",  label = "TILT CAP",  group = "FEEL", step = 0.05, min = 0,   max = 0.6 },
  },
  CRUISE = {
    { id = "feel.cruiseThrottleRate", label = "THROTTLE RATE", group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.cruiseThrottleMax",  label = "THROTTLE MAX",  group = "FEEL", step = 0.05, min = 0,   max = 1.0 },
  },
  DRN = {
    { id = "feel.tiltRate", label = "TILT RATE", group = "FEEL", step = 0.1,  min = 0.1, max = 2.0 },
    { id = "feel.tiltCap",  label = "TILT CAP",  group = "FEEL", step = 0.05, min = 0,   max = 0.6 },
  },
}

-- MODE_EXTRA_ROWS(mode) = that mode's own extras (if any) + SHARED_FEEL_EXTRA_ROWS -- built once
-- here for every flight mode in M.MODES, so PRECISION/LDG (no own extras) still get the 6 shared
-- rows and MAN/CRUISE/DRN get their own extras PLUS the 6 shared rows.
local MODE_EXTRA_ROWS = {}
for _, mode in ipairs(M.MODES) do
  local extra = {}
  for _, r in ipairs(MODE_OWN_EXTRA_ROWS[mode] or {}) do extra[#extra + 1] = r end
  for _, r in ipairs(SHARED_FEEL_EXTRA_ROWS) do extra[#extra + 1] = r end
  MODE_EXTRA_ROWS[mode] = extra
end

-- specFor(mode, rowId) -> the {id,label,group,step,min,max} spec for rowId, scoped to mode: the
-- 34 base specs are shared by every mode; a mode's own extras (e.g. MAN's feel.tiltRate) only
-- resolve when looked up under THAT mode, so e.g. M.apply(cfg,"PRECISION","feel.tiltRate",...)
-- is correctly a no-op (PRECISION has no such row).
local function specFor(mode, rowId)
  local base = SPEC_BY_ID[rowId]
  if base then return base end
  local extras = MODE_EXTRA_ROWS[mode]
  if extras then
    for _, s in ipairs(extras) do
      if s.id == rowId then return s end
    end
  end
  return nil
end
M.specFor = specFor

-- ===== M.rows / M.apply: the PURE view-model. No Basalt, no fs, no mutation of `cfg`. =====

-- M.rows(cfg, mode) -> ordered list of {id, label, group, value, step}, value read from cfg at
-- pathFor(mode, spec.id) (nil-safe: falls back to the tuningdefaults value at that same path,
-- then 0). `mode` defaults to "PRECISION" (byte-identical to the pre-existing M.rows(cfg)
-- behaviour). MAN/CRUISE additionally append that mode's extra FEEL rows. PURE.
function M.rows(cfg, mode)
  mode = mode or "PRECISION"
  cfg = cfg or {}
  local defaults = tuningdefaults.get()

  local function row(spec)
    local path = M.pathFor(mode, spec.id)
    local v = getPath(cfg, path)
    if v == nil then v = getPath(defaults, path) end
    if v == nil then v = 0 end
    return { id = spec.id, label = spec.label, group = spec.group, value = v, step = spec.step }
  end

  local out = {}
  for _, spec in ipairs(ROW_SPEC) do out[#out + 1] = row(spec) end
  for _, spec in ipairs(MODE_EXTRA_ROWS[mode] or {}) do out[#out + 1] = row(spec) end
  return out
end

-- M.apply([mode,] cfg-or-rowId, rowId-or-delta, [delta]) -> a NEW cfg (deep-copied; `cfg` is
-- never mutated) with the value at pathFor(mode, rowId) set to
-- clamp(currentValue + delta*step, min, max), rounded to the step's precision. Unknown rowId (for
-- that mode) -> unchanged (deep-copied) cfg. `delta` is a signed integer (+1/-1).
--
-- Two call shapes, told apart by argument count so existing 3-arg call sites keep working
-- byte-identically (mode defaults to "PRECISION"):
--   M.apply(cfg, rowId, delta)        -- legacy/PRECISION shorthand
--   M.apply(cfg, mode, rowId, delta)  -- explicit mode (PRECISION/MAN/CRUISE)
function M.apply(...)
  local n = select("#", ...)
  local cfg, mode, rowId, delta
  if n <= 3 then
    cfg, rowId, delta = ...
    mode = "PRECISION"
  else
    cfg, mode, rowId, delta = ...
  end
  mode = mode or "PRECISION"

  local copy = deepcopy(cfg or {})
  local spec = specFor(mode, rowId)
  if not spec then return copy end

  local path = M.pathFor(mode, rowId)
  local defaults = tuningdefaults.get()
  local cur = getPath(copy, path)
  if cur == nil then cur = getPath(defaults, path) end
  if cur == nil then cur = 0 end

  local dn = tonumber(delta) or 0
  local raw = clamp(cur + dn * spec.step, spec.min, spec.max)
  raw = roundTo(raw, decimalsForStep(spec.step))
  setPath(copy, path, raw)
  return copy
end

-- M.resetMode(cfg, mode) -> a NEW cfg (deep-copied; `cfg` is never mutated) with ONLY that mode's
-- subtree reset to tuningdefaults.get() values -- PRECISION resets the top-level gains/caps/feel,
-- MAN/CRUISE reset modes.<mode> (including that mode's extra feel, e.g. tiltRate/tiltCap) --
-- leaving the rest of the tree (including the other modes) untouched.
function M.resetMode(cfg, mode)
  mode = mode or "PRECISION"
  local copy = deepcopy(cfg or {})
  local defaults = tuningdefaults.get()
  if mode == "PRECISION" then
    copy.gains = deepcopy(defaults.gains)
    copy.caps  = deepcopy(defaults.caps)
    copy.feel  = deepcopy(defaults.feel)
  else
    copy.modes = copy.modes or {}
    copy.modes[mode] = deepcopy(defaults.modes[mode])
  end
  return copy
end

-- ===== AUTO COM status line: TESTABLE, Basalt-free =====
-- The text shown under the lamp. Priority: a LIVE run shows its phase (CLIMB/HOLD/DESCEND) as
-- progress; a finished/aborted run surfaces the abort REASON -- so a failure isn't masked by the
-- ON GROUND prereq, which goes false the instant the craft lifts off and stays false on a slope.
-- Otherwise the missing-prereq label (missLabel = the already-resolved ComAuto.label(miss) or nil),
-- else the phase or READY.
function M._comAutoReason(ca, missLabel)
  ca = ca or {}
  local running = ca.phase == "CLIMB" or ca.phase == "HOLD" or ca.phase == "DESCEND"
  if running then return ca.phase end
  if ca.abortReason then return "ABORT " .. tostring(ca.abortReason) end
  if missLabel then return missLabel end
  return ca.phase or "READY"
end

-- ===== Save / reset: TESTABLE, Basalt-free seams =====

-- M._save(workingCfg, write) -> serialises workingCfg to /eh2_tuning.tbl via cfgspec (write is
-- injected: write(filename, body), filename WITHOUT a leading slash -- matches cfgspec.save's own
-- contract, see fcs/io/cfgspec.lua).
function M._save(workingCfg, write)
  return cfgspec.save("tuning", workingCfg, write)
end

-- M._reset(deleteFn) -> deletes /eh2_tuning.tbl (deleteFn is called with the FULL path, leading
-- slash included -- matches fs.delete's own contract) and returns fresh defaults
-- (tuningdefaults.get()), for the caller to adopt as the new working cfg.
function M._reset(deleteFn)
  deleteFn("/" .. cfgspec.FILES.tuning)
  return tuningdefaults.get()
end

-- ===== real fs delete (default injected seam; never called at module load) =====
-- Default read/write now come from cfgseam (FCS cache + cfgClient). realDelete stays for
-- signature/API compat (per-mode RST no longer deletes; M._reset still tested with spies).

local function realDelete(path)
  fsx.delete(path)
end

-- ===== M.build: construct the mode->category->axis drilldown element tree =====

local function fmtVal(v, step)
  return string.format("%." .. decimalsForStep(step) .. "f", v)
end

-- abbrev(mode): a short, fixed-width mode tag for screen titles ("PRECISION" -> "PRECIS", "MAN"
-- -> "MAN", "CRUISE" -> "CRUISE") -- plain head-truncation (not configkit.fitLabel's tail-with-"~"
-- behaviour, which would read oddly for a mode name), display-only.
local function abbrev(mode)
  return tostring(mode):sub(1, 6)
end

-- BASE_GAINS_IDS: the 3 non-axis gains.* rows (hoverDuty/heaveMin/heaveMax) that the GAINS axis
-- layer (ALT/PITCH/ROLL/YAW/SWAY/SURGE) has no home for -- they get their own "BASE" button/screen
-- instead so they are never dropped.
local BASE_GAINS_IDS = { ["gains.hoverDuty"] = true, ["gains.heaveMin"] = true, ["gains.heaveMax"] = true }

local function gainsAxisFilter(axis)
  local prefix = "gains." .. axis .. "."
  return function(rows)
    local out = {}
    for _, r in ipairs(rows) do
      if r.group == "GAINS" and r.id:sub(1, #prefix) == prefix then out[#out + 1] = r end
    end
    return out
  end
end

local function gainsBaseFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if BASE_GAINS_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

local function groupFilter(group)
  return function(rows)
    local out = {}
    for _, r in ipairs(rows) do
      if r.group == group then out[#out + 1] = r end
    end
    return out
  end
end

local capsFilter = groupFilter("CAPS")

-- FEEL_BASE_IDS: the 8 base feel.* ids from M.ROW_SPEC (shared by every mode). Every mode's own
-- extra FEEL rows (feel.tiltRate/tiltCap, feel.cruiseThrottleRate/cruiseThrottleMax, and the 6
-- rows shared by ALL modes -- feel.trimGain/feel.climbRampTime/feel.climbBoost/feel.trimAuthority/
-- feel.trimFadeStart/feel.trimFade, Task 14 + trim-flip-guard Task 5) are NOT
-- in this set -- M.rows(cfg,mode) appends them after the 8 base ones, with the same "FEEL" group,
-- so filtering on "group==FEEL and not in FEEL_BASE_IDS" cleanly isolates just the per-mode
-- extras. title(1) + 8 base rows + footer(1) = 10 == the ~12-row monitor's region budget (h-2)
-- EXACTLY -- adding any extras to that same flat screen would push it past the frame (the bug
-- this split fixes: see "gains_axis_<mode>"'s ALT/PITCH/.../BASE split for the established
-- precedent of splitting a group that doesn't fit one screen).
local FEEL_BASE_IDS = {}
for _, spec in ipairs(ROW_SPEC) do
  if spec.group == "FEEL" then FEEL_BASE_IDS[spec.id] = true end
end

local function feelBaseFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.group == "FEEL" and FEEL_BASE_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

local function feelExtraFilter(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.group == "FEEL" and not FEEL_BASE_IDS[r.id] then out[#out + 1] = r end
  end
  return out
end

-- HELP_IDS: every configkit.GLOSSARY entry this page's "?" buttons can reach -- registered under
-- screen ids "help_<id>" in the region's screens map below.
local HELP_IDS = { "modes", "gains", "caps", "feel", "alt", "pitch", "roll", "yaw", "sway", "surge" }

function M.build(basalt, frame, runtime, nav, read, write, delete)
  -- S2: default seams read the FCS's live tuning cfg from runtime.cfgCache and ship SAVE as a `set`
  -- to the running FCS (persisted there; tuning needs a reload to apply -- CoM is the exception,
  -- hot-applied via the COM screen's pushCom below AND the FCS responder). Tests still inject
  -- read/write and never touch cfgseam.
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  delete = delete or realDelete -- kept for signature/API compat (per-mode RST no longer deletes)

  local workingCfg = (cfgspec.load("tuning", read))

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  -- No persistent frame-level title: each region screen owns its single ||title|| (root = "FCS TUNING"),
  -- so sub-screens don't double up + the region gets the full frame (2 more rows for the stepper lists).
  local headerLabel = nil

  -- A region-internal nav push/pop (drilling a mode/category/axis, or backing out of one) isn't a
  -- FRAME-level nav change, so it wouldn't otherwise wake the dirty-gated render loop -- bump
  -- runtime.uiRev, exactly like mdb.lua's/senscal.lua's regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- ===== shared stepper-list factory: one screen = a fixed row-id set (from a pure filter over =====
  -- ===== M.rows(workingCfg, mode), evaluated once at build time -- M.ROW_SPEC/the per-mode extra =====
  -- ===== rows never change at runtime, so the SET of ids is stable; only each row's displayed    =====
  -- ===== value/step is re-read live on every refresh()) + a "?"/"<" footer row.                  =====
  local function buildEditScreen(mode, filterFn, screenTitle, helpId)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = configkit.titleRow(f, fw, screenTitle)   -- ||screenTitle|| centred, top row
      y = y + 1

      local labelW = math.max(1, fiw - 8)
      local minusX = fx + labelW + 1
      local plusX  = minusX + 4

      local rowIds = {}
      for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do rowIds[#rowIds + 1] = r.id end

      -- Forward-declared: minus/plus onClick closures reference refresh() before it's DEFINED
      -- (not before it's called) -- same upvalue-before-assignment discipline as
      -- configkit.helpScreen's `row`/`render`.
      local refresh

      local rowSlots = {}
      for i, rid in ipairs(rowIds) do
        local yy = y + i - 1
        local lbl   = f:addLabel({ x = fx, y = yy, width = labelW, height = 1, autoSize = false, text = "" })
        local minus = configkit.bracketBtn(f, minusX, yy, "-", colors.orange).button   -- [-] orange function
        local plus  = configkit.bracketBtn(f, plusX,  yy, "+", colors.orange).button   -- [+]
        rowSlots[i] = { id = rid, label = lbl, minus = minus, plus = plus }

        minus:onClick(function()
          workingCfg = M.apply(workingCfg, mode, rid, -1)
          refresh()
        end)
        plus:onClick(function()
          workingCfg = M.apply(workingCfg, mode, rid, 1)
          refresh()
        end)
      end
      y = y + #rowIds

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_" .. helpId) end },
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      refresh = function()
        local byId = {}
        for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do byId[r.id] = r end
        for _, slot in ipairs(rowSlots) do
          local r = byId[slot.id]
          if r then
            slot.label:setText(configkit.fitLabel(r.label .. " " .. fmtVal(r.value, r.step), labelW))
          end
        end
      end
      refresh()

      return {
        apply = function(_state) refresh() end,
        -- lastRowY: the y this screen's DEEPEST row (the footer) was placed at -- a generic,
        -- layout-derived fit signal every screen builder exposes (see the fit-regression test in
        -- tests/test_bitconfig_tuning.lua, which asserts lastRowY <= the region's own height for
        -- every registered screen at a REALISTIC ~12-row monitor size).
        elements = { titleLabel = titleLabel, rowSlots = rowSlots, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== gains_axis_<mode>: ALT/PITCH/ROLL/YAW/SWAY/SURGE + BASE (the 3 non-axis gains rows) =====
  local function buildGainsAxisScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = configkit.titleRow(f, ({ f:getSize() })[1], "GAINS " .. abbrev(mode))
      y = y + 1

      local items = {}
      for _, axis in ipairs(AXES) do
        items[#items + 1] = { id = axis, label = AXIS_LABEL[axis],
          onClick = function() region:push("edit_" .. mode .. "_GAINS_" .. axis) end }
      end
      items[#items + 1] = { id = "base", label = "BASE",
        onClick = function() region:push("edit_" .. mode .. "_GAINS_base") end }
      local menu = configkit.menuColumn(f, { y = y, items = items })
      local axisBtns = {}
      for _, axis in ipairs(AXES) do axisBtns[axis] = menu.buttons[axis] end
      local baseBtn = menu.buttons.base
      y = menu.nextY

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_gains") end },
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = { titleLabel = titleLabel, axisBtns = axisBtns, baseBtn = baseBtn, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== feel_menu_<mode> (EVERY mode, Task 14): BASE FEEL / MODE FEEL -- FEEL's own axis-less =====
  -- ===== split (mirrors gains_axis_<mode>'s ALT/../BASE split). Every mode's FEEL is now at    =====
  -- ===== least 14 rows (8 base + the 6 rows shared by all modes -- trim/ramp/flip-guard) and   =====
  -- ===== MAN/CRUISE/DRN's is 16 (8 base + 2 own + 6 shared) -- none of that fits ONE ~10-row   =====
  -- ===== screen budget (title+14(or 16)+footer overflows it), so this menu fans out to two     =====
  -- ===== screens that each fit on their own (8 base -> 10 rows; extras -> 6 or 8 rows -> 8 or  =====
  -- ===== 10 total -- MAN/CRUISE/DRN's extra screen lands exactly on the 10-row budget).         =====
  local function buildFeelMenuScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = configkit.titleRow(f, ({ f:getSize() })[1], "FEEL " .. abbrev(mode))
      y = y + 1

      local menu = configkit.menuColumn(f, { y = y, items = {
        { id = "base",  label = "BASE FEEL", onClick = function() region:push("edit_" .. mode .. "_FEEL_base") end },
        { id = "extra", label = "MODE FEEL", onClick = function() region:push("edit_" .. mode .. "_FEEL_extra") end },
      } })
      local baseBtn = menu.buttons.base
      local extraBtn = menu.buttons.extra
      y = menu.nextY

      local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_feel") end },
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = { titleLabel = titleLabel, baseBtn = baseBtn, extraBtn = extraBtn, footerRow = footerRow, lastRowY = y },
      }
    end
  end

  -- ===== cat_<mode>: GAINS/CAPS/FEEL + SAVE/RST + "?"/"<" =====
  local function buildCatScreen(mode)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = configkit.titleRow(f, ({ f:getSize() })[1], "TUNE " .. abbrev(mode))
      y = y + 1

      -- Every mode's FEEL now routes through the small BASE/MODE FEEL menu (Task 14: PRECISION
      -- lost its flat-screen exception once the 3 shared trim/ramp rows pushed its FEEL past the
      -- one-screen budget too -- see buildFeelMenuScreen's header note).
      local feelTarget = "feel_menu_" .. mode
      local CATS = {
        { id = "GAINS", target = "gains_axis_" .. mode },
        { id = "CAPS",  target = "edit_" .. mode .. "_CAPS" },
        { id = "FEEL",  target = feelTarget },
      }
      local catItems = {}
      for _, c in ipairs(CATS) do
        catItems[#catItems + 1] = { id = c.id, label = c.id, onClick = function() region:push(c.target) end }
      end
      local catMenu = configkit.menuColumn(f, { y = y, items = catItems })
      local catBtns = {}
      for _, c in ipairs(CATS) do catBtns[c.id] = catMenu.buttons[c.id] end
      y = catMenu.nextY

      -- doSave/doReset exposed directly on `elements` (not just wired into the row) so a test can
      -- invoke the EXACT effect SAVE/RST's onClick has, same convention as mdb.lua's exposed
      -- `rescan`.
      local function doSave()
        M._save(workingCfg, write)
      end
      local function doReset()
        workingCfg = M.resetMode(workingCfg, mode)
        region:apply(nil)
      end

      local saveRstRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "SAVE", onClick = doSave },
        { label = "RST",  onClick = doReset },
      })
      y = y + 1

      local helpBackRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "?", onClick = function() region:push("help_modes") end },
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      return {
        apply = function(_state) end,
        elements = {
          titleLabel = titleLabel, catBtns = catBtns,
          saveRstRow = saveRstRow, helpBackRow = helpBackRow,
          doSave = doSave, doReset = doReset,
          lastRowY = y,
        },
      }
    end
  end

  -- ===== modes (root): PRECISION/MAN/CRUISE + "?"/"<" (FRAME-level nav:pop) =====
  local function buildModesScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)

    -- Compact centred menu column (sized to the widest mode label), not full-width bars.
    local items = {}
    for _, mode in ipairs(M.MODES) do
      items[#items + 1] = { id = mode, label = mode, onClick = function() region:push("cat_" .. mode) end }
    end
    items[#items + 1] = { id = "COM", label = "COM", onClick = function() region:push("com") end }
    local titleLabel = configkit.titleRow(f, fw, M.title)          -- ||FCS TUNING|| (self-titled, per screen)
    local menu = configkit.menuColumn(f, { y = 3, items = items }) -- gap at row 2 (detach from title)
    local modeBtns = {}
    for _, mode in ipairs(M.MODES) do modeBtns[mode] = menu.buttons[mode] end
    local comBtn = menu.buttons.COM

    local y = menu.nextY
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "?", onClick = function() region:push("help_modes") end },
      { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
    })

    return {
      apply = function(_state) end,
      elements = { titleLabel = titleLabel, modeBtns = modeBtns, comBtn = comBtn, footerRow = footerRow, lastRowY = y },
    }
  end

  local function sendCom(op)
    if not (runtime and runtime.links and runtime.links.tel and runtime.sender) then return end
    local c = workingCfg.com or {}
    runtime.links.tel:send(runtime.sender:send({
      k = "comAuto", op = op,
      spanFwd = c.spanFwd or c.span or 1,
      spanRight = c.spanRight or c.span or 1,
    }))
  end

  -- Push a hand-set CoM to the FCS LIVE (applied to the mixer immediately, no reboot) so the operator
  -- can fly a manual trim now; the config file still persists it for the courier. Called from SAVE/RST.
  local function pushCom()
    if not (runtime and runtime.links and runtime.links.tel and runtime.sender) then return end
    local c = workingCfg.com or {}
    runtime.links.tel:send(runtime.sender:send({
      k = "setCom",
      fwd = c.fwd or 0, right = c.right or 0,
      spanFwd = c.spanFwd or c.span or 1, spanRight = c.spanRight or c.span or 1,
    }))
  end

  local function buildComScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1
    local titleLabel = configkit.titleRow(f, ({ f:getSize() })[1], "COM")
    y = y + 1
    local labelW = math.max(1, fiw - 8)
    local minusX = fx + labelW + 1
    local plusX = minusX + 4
    local refresh
    local rowSlots = {}
    for i, spec in ipairs(COM_SPEC) do
      local yy = y + i - 1
      local lbl = f:addLabel({ x = fx, y = yy, width = labelW, height = 1, autoSize = false, text = "" })
      local minus = f:addButton({ x = minusX, y = yy, width = 3, height = 1, text = "-" })
      local plus = f:addButton({ x = plusX, y = yy, width = 3, height = 1, text = "+" })
      rowSlots[i] = { id = spec.id, label = lbl, minus = minus, plus = plus }
      minus:onClick(function()
        workingCfg = M.apply(workingCfg, spec.id, -1)
        refresh()
      end)
      plus:onClick(function()
        workingCfg = M.apply(workingCfg, spec.id, 1)
        refresh()
      end)
    end
    y = y + #COM_SPEC
    local autoRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "AUTO", onClick = function() region:push("comauto") end },
    })
    y = y + 1
    local saveRstRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SAVE", onClick = function() M._save(workingCfg, write); pushCom() end },
      { label = "RST", onClick = function()
          workingCfg.com = workingCfg.com or {}
          workingCfg.com.fwd = 0
          workingCfg.com.right = 0
          refresh()
          pushCom()
        end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })
    refresh = function()
      for _, slot in ipairs(rowSlots) do
        local spec = SPEC_BY_ID[slot.id]
        local path = M.pathFor("PRECISION", slot.id)
        local v = workingCfg
        for key in path:gmatch("[^.]+") do v = v and v[key] end
        if v == nil then v = 0 end
        slot.label:setText(spec.label .. " " .. fmtVal(v, spec.step))
      end
    end
    refresh()
    return {
      apply = function(_s) refresh() end,
      elements = { titleLabel = titleLabel, rowSlots = rowSlots, autoRow = autoRow,
        saveRstRow = saveRstRow, footerRow = footerRow, lastRowY = y },
    }
  end

  local function buildComAutoScreen(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1
    local titleLabel = configkit.titleRow(f, ({ f:getSize() })[1], "AUTO COM")
    y = y + 1
    local lamp = switchbtn.make(f, { x = fx, y = y, width = fiw, height = 1, text = "LAMP" }) -- audit:full-width-ok status lamp (readout, not a pick target)
    y = y + 1
    local reason = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local startRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "START", onClick = function() sendCom("start") end },
    })
    y = y + 1
    local abortRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "ABORT", onClick = function() sendCom("abort") end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })
    local savedCap = false
    local function refresh(state)
      state = state or {}
      local db = cfgspec.load("devbind", read)
      local sc = cfgspec.load("senscal", read)
      local ca = state.comAuto or {}
      local running = ca.phase == "CLIMB" or ca.phase == "HOLD" or ca.phase == "DESCEND"
      local ctx = {
        thrusters = db.thrusters, sensors = db.sensors, senscal = sc,
        comSpanFwd = (workingCfg.com and workingCfg.com.spanFwd) or 0,
        comSpanRight = (workingCfg.com and workingCfg.com.spanRight) or 0,
        engineOn = state.engineMaster and true or false,
        onGround = state.onGround == true,
        gndSafety = state.gndSafety,
        moving = math.abs(state.vSpeed or 0) > 0.5,
        fuelFrac = state.tankFrac or 0,
        engaged = state.engaged and true or false,
        flightMode = state.flightMode,
      }
      local miss = ComAuto.missing(ctx)
      local color = ComAuto.lamp(ctx, running)
      if color == "blue" then
        lamp.set("on")
        lamp.button:setBackground(colors.blue)
        lamp.button:setText("RUN")
      elseif color == "green" then
        lamp.set("on")
        lamp.button:setText("READY")
      else
        lamp.set("off")
        lamp.button:setText("WAIT")
      end
      reason:setText(configkit.fitLabel(M._comAutoReason(ca, miss and ComAuto.label(miss)), fiw))
      startRow.setState(1, (miss or running) and "disabled" or "off")
      -- ABORT only does anything while the procedure is running (comAuto:abort() no-ops on IDLE/DONE);
      -- leaving it live after a finished/aborted run reads as a dead button -- disable it when idle.
      abortRow.setState(1, running and "off" or "disabled")
      if ca.captured and not savedCap then
        workingCfg.com = workingCfg.com or {}
        workingCfg.com.fwd = ca.captured.fwd
        workingCfg.com.right = ca.captured.right
        M._save(workingCfg, write)
        savedCap = true
      end
      if not running then savedCap = false end
    end
    refresh({})
    return {
      apply = function(state) refresh(state) end,
      elements = { titleLabel = titleLabel, lamp = lamp, reason = reason,
        startRow = startRow, abortRow = abortRow, footerRow = footerRow, lastRowY = y },
    }
  end

  -- ===== assemble the region's screens map =====
  local screens = { modes = buildModesScreen, com = buildComScreen, comauto = buildComAutoScreen }
  for _, mode in ipairs(M.MODES) do
    screens["cat_" .. mode] = buildCatScreen(mode)
    screens["gains_axis_" .. mode] = buildGainsAxisScreen(mode)
    for _, axis in ipairs(AXES) do
      screens["edit_" .. mode .. "_GAINS_" .. axis] =
        buildEditScreen(mode, gainsAxisFilter(axis), AXIS_LABEL[axis] .. " " .. abbrev(mode), axis)
    end
    screens["edit_" .. mode .. "_GAINS_base"] = buildEditScreen(mode, gainsBaseFilter, "BASE " .. abbrev(mode), "gains")
    screens["edit_" .. mode .. "_CAPS"] = buildEditScreen(mode, capsFilter, "CAPS " .. abbrev(mode), "caps")
    -- Every mode (including PRECISION, Task 14) routes FEEL through the BASE/MODE FEEL split --
    -- see buildFeelMenuScreen's header note for why none of the 5 modes fit a flat FEEL screen
    -- anymore now that trim/ramp are shared across all of them.
    screens["feel_menu_" .. mode] = buildFeelMenuScreen(mode)
    screens["edit_" .. mode .. "_FEEL_base"] = buildEditScreen(mode, feelBaseFilter, "FEEL " .. abbrev(mode), "feel")
    screens["edit_" .. mode .. "_FEEL_extra"] = buildEditScreen(mode, feelExtraFilter, "MODE FEEL " .. abbrev(mode), "feel")
  end
  for _, entryId in ipairs(HELP_IDS) do
    screens["help_" .. entryId] = function(b, f, r) return configkit.helpScreen(b, f, r, entryId) end
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = h,
    root = "modes", screens = screens, onNav = bump,
  })

  -- Force the modes screen to build now (not on the first scheduled apply()), so its elements
  -- exist as soon as M.build returns -- mirrors mdb.lua's/senscal.lua's identical eager-build call.
  region:apply(nil)

  -- apply(state): this menu shows CONFIG, not live telemetry -- forwards to the region, which
  -- lazily builds/shows its current nav top and repaints only that screen. Never polls
  -- peripherals on its own; +/- is the only thing that mutates workingCfg, and only on click.
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
