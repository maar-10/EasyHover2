local t = require("tests.framework")
local I = require("fcs.bringup.instrument")
local frame = require("fcs.frame")

-- CSV split that preserves EMPTY cells (unlike gmatch("[^,]+"), needed to index a row
-- that may legitimately contain "" for a missing string column like `master`).
local function splitCSV(row)
  local cells, start = {}, 1
  while true do
    local commaPos = row:find(",", start, true)
    if commaPos then
      cells[#cells+1] = row:sub(start, commaPos - 1)
      start = commaPos + 1
    else
      cells[#cells+1] = row:sub(start)
      break
    end
  end
  return cells
end

local HEADER_COLS = {}
for c in I.header():gmatch("[^,]+") do HEADER_COLS[#HEADER_COLS+1] = c end
local function idxOf(name)
  for i, c in ipairs(HEADER_COLS) do if c == name then return i end end
  error("no such column: " .. name)
end

t.test("header and formatRow agree on column count", function()
  local ncols = select(2, I.header():gsub(",", ",")) + 1
  local row = I.formatRow({ t=0, dt=0.1, phase="CLIMB", mode="NORMAL", onGround=false, duties={} })
  local nrow = select(2, row:gsub(",", ",")) + 1
  t.eq(nrow, ncols)
end)
t.test("capture snapshots the live duties table so deferred formatRow is immune to later mutation", function()
  -- The control loop reuses/overwrites its duties table each cycle. To move formatRow OFF the hot
  -- path we buffer the raw sample and format at dump time -- which is only safe if the shared duties
  -- reference is snapshotted at capture. This is the correctness guard for that deferral.
  local live = { FL = 0.1, FR = 0.2, RL = 0.3, RR = 0.4 }
  local sample = { t = 1, dt = 0.1, phase = "ENGAGED", mode = "NORMAL", pitch = 0.05, duties = live }
  local rec = I.capture(sample)
  local atCapture = I.formatRow(rec)
  live.FL = 0.99; live.FR = 0.88   -- next cycle overwrites the live duties in place
  t.eq(I.formatRow(rec), atCapture, "captured record's formatRow is unaffected by later duties mutation")
  local cells = splitCSV(atCapture)
  t.eq(cells[idxOf("FL")], "0.1", "the FL=0.1 snapshot is preserved for the deferred format")
end)

t.test("Summary computes bob amplitude from HOLD samples", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="HOLD", alt=5.0, sp_alt=5, heading=0 })
  s:add({ t=0.1, dt=0.1, phase="HOLD", alt=5.3, sp_alt=5, heading=0 })
  s:add({ t=0.2, dt=0.1, phase="HOLD", alt=4.8, sp_alt=5, heading=0 })
  t.near(s:finalize().bobAmplitude, 0.5, 1e-9)
end)
t.test("Summary tracks per-phase alt error and average Hz", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.2, phase="CLIMB", alt=1.0, sp_alt=1.5, heading=0 })
  s:add({ t=0.2, dt=0.2, phase="CLIMB", alt=2.0, sp_alt=2.0, heading=0 })
  local m = s:finalize()
  t.near(m.errClimb.mean, 0.25, 1e-9); t.near(m.errClimb.max, 0.5, 1e-9)
  t.near(m.hzAvg, 5, 1e-9)
end)
t.test("Summary flags DAMPED and captures touchdown + drift + heading drift", function()
  local s = I.Summary.new()
  s:add({ t=0,   dt=0.1, phase="DESCEND", alt=1,   sp_alt=1,   vSpeed=-0.5, mode="NORMAL", swayPos=0,   surgePos=0,    heading=0 })
  s:add({ t=0.1, dt=0.1, phase="DESCEND", alt=0.5, sp_alt=0.5, vSpeed=-0.3, mode="DAMPED", swayPos=0.4, surgePos=-0.2, heading=0.1 })
  s:add({ t=0.2, dt=0.1, phase="LANDED",  alt=0,   sp_alt=0,   vSpeed=-0.1, mode="NORMAL", swayPos=0.2, surgePos=0,    heading=0.05 })
  local m = s:finalize()
  t.eq(m.damped, true)
  t.near(m.touchdownV, -0.1, 1e-9)
  t.near(m.swayRange, 0.4, 1e-9)
  t.near(m.surgeRange, 0.2, 1e-9)
  t.near(m.headingDrift, 0.1, 1e-9)
end)
t.test("formatSummary produces readable key: value lines", function()
  local s = I.Summary.new(); s:add({ t=0, dt=0.1, phase="HOLD", alt=5, sp_alt=5, heading=0 })
  local out = I.formatSummary(s:finalize())
  t.truthy(out:find("hold_bob_amplitude_blocks:"))
  t.truthy(out:find("loop_hz:"))
end)

-- ===== SCHEMA v2: slimmed (err_* dropped, short numbers, enum codes) =====

t.test("header() emits the slimmed v2 columns in contract order, between the 23 existing and the duties", function()
  local nDuties = #frame.LIFT + #frame.LATERAL + #frame.MAIN + #frame.FRONTAL
  t.eq(#HEADER_COLS, 23 + 33 + nDuties, "total column count == 23 + 33 + duties (v2 drops the 6 derived err_*)")
  t.eq(HEADER_COLS[1], "t"); t.eq(HEADER_COLS[23], "dSurge")   -- existing 23 unchanged/first
  t.eq(idxOf("sp_pitch"), 24); t.eq(idxOf("sp_surge"), 28)
  t.eq(idxOf("P_alt"), 29); t.eq(idxOf("I_alt"), 30); t.eq(idxOf("D_alt"), 31)
  t.eq(idxOf("P_surge"), 44); t.eq(idxOf("D_surge"), 46)
  t.eq(idxOf("sat_heave"), 47); t.eq(idxOf("sat_surge"), 52); t.eq(idxOf("heaveBanded"), 53)
  t.eq(idxOf("ff_pitch"), 54)
  t.eq(idxOf("master"), 55); t.eq(idxOf("noFuel"), 56)
  t.eq(HEADER_COLS[57], frame.LIFT[1], "duty columns immediately follow, unchanged/last")
  t.eq(select(2, I.header():gsub("err_", "")), 0, "no err_* columns in the v2 header")
end)

t.test("formatRow(fullSample) places setpoints/PID-split/sat/trim/context in contract cells, slim format", function()
  local full = {
    t = 1, dt = 0.05, phase = "HOLD", mode = "NORMAL", onGround = false,
    sp_alt = 5, alt = 4.5, vSpeed = 0.1, pitch = 0.02, roll = -0.01, heading = 10, yawRate = 0.5,
    swayVel = 0, surgeVel = 0, swayPos = 1.0, surgePos = 2.0, heave = 0.3,
    dPitch = 0.1, dRoll = 0.2, dYaw = 0.3, dSway = 0.4, dSurge = 0.5,
    sp_pitch = 0.05, sp_roll = 0.0, sp_hdg = 15, sp_sway = 1.5, sp_surge = 2.5,
    terms = {
      alt   = { err = 0.5,  P = 1.0, I = 0.1,  D = 0.01 },
      pitch = { err = 0.03, P = 0.6, I = 0.02, D = 0.003 },
      roll  = { err = 0.01, P = 0.2, I = 0.01, D = 0.001 },
      yaw   = { err = 5,    P = 0.5, I = 0.05, D = 0.005 },
      sway  = { err = 0.5,  P = 0.4, I = 0.04, D = 0.004 },
      surge = { err = 0.5,  P = 0.3, I = 0.03, D = 0.002 },
    },
    sat = { heave = true, pitch = false, roll = true, yaw = false, sway = false, surge = true },
    heaveBanded = true, ff_pitch = 0.12, master = "CPL", noFuel = false, duties = {},
  }
  local cells = splitCSV(I.formatRow(full))
  t.eq(#cells, #HEADER_COLS, "row cell count matches header cell count")
  local function cell(name) return cells[idxOf(name)] end
  t.eq(cell("sp_pitch"), "0.05"); t.eq(cell("sp_hdg"), "15")
  t.eq(cell("P_alt"), "1"); t.eq(cell("I_alt"), "0.1"); t.eq(cell("D_alt"), "0.01")
  t.eq(cell("P_yaw"), "0.5"); t.eq(cell("I_yaw"), "0.05"); t.eq(cell("D_yaw"), "0.005")
  t.eq(cell("P_surge"), "0.3"); t.eq(cell("I_surge"), "0.03"); t.eq(cell("D_surge"), "0.002")
  t.eq(cell("sat_heave"), "1"); t.eq(cell("sat_pitch"), "0"); t.eq(cell("sat_roll"), "1")
  t.eq(cell("sat_yaw"), "0"); t.eq(cell("sat_sway"), "0"); t.eq(cell("sat_surge"), "1")
  t.eq(cell("heaveBanded"), "1")
  t.eq(cell("ff_pitch"), "0.12")
  t.eq(cell("master"), "CPL")
  t.eq(cell("noFuel"), "0")
  t.eq(cell("phase"), "H", "HOLD encodes to its short code")
  t.eq(cell("mode"), "N", "NORMAL encodes to its short code")
end)

t.test("formatRow encodes the loop's GROUND mode to its short code", function()
  local row = splitCSV(I.formatRow({ t = 0, dt = 0.1, phase = "ENG-GND", mode = "GROUND", duties = {} }))
  t.eq(row[idxOf("phase")], "G")
  t.eq(row[idxOf("mode")], "G")
end)

t.test("formatRow(minimalSample) (hover_test path: no terms/sat/sp_*/ff/master/noFuel) does not error", function()
  local minimal = {
    t = 1, dt = 0.1, phase = "CLIMB", mode = "NORMAL",
    sp_alt = 5, alt = 4, vSpeed = 0.1, pitch = 0.01, roll = 0, heading = 0, yawRate = 0,
    swayVel = 0, surgeVel = 0, swayPos = 0, surgePos = 0, onGround = false, heave = 0.2,
    dPitch = 0.1, dRoll = 0, dYaw = 0, dSway = 0, dSurge = 0, duties = {},
  }
  local ok, row = pcall(I.formatRow, minimal)
  t.truthy(ok, "formatRow must not error on a sample missing terms/sat/sp_*/etc: " .. tostring(row))
  local cells = splitCSV(row)
  t.eq(#cells, #HEADER_COLS)
  local function cell(name) return cells[idxOf(name)] end
  t.eq(cell("sp_pitch"), "0")
  t.eq(cell("P_alt"), "0"); t.eq(cell("D_surge"), "0")
  t.eq(cell("sat_heave"), "0"); t.eq(cell("sat_surge"), "0")
  t.eq(cell("heaveBanded"), "0")
  t.eq(cell("ff_pitch"), "0")
  t.eq(cell("master"), "")
  t.eq(cell("noFuel"), "0")
  t.eq(cell("phase"), "C", "CLIMB encodes to its short code")
  t.eq(cell("mode"), "N")
end)

t.test("formatRow passes unknown enum values through verbatim (no silent mapping)", function()
  local row = splitCSV(I.formatRow({ t = 0, dt = 0.1, phase = "WEIRD", mode = "M2", duties = {} }))
  t.eq(row[idxOf("phase")], "WEIRD")
  t.eq(row[idxOf("mode")], "M2")
end)

t.test("formatRow sanitizes CSV-hostile characters out of pass-through strings", function()
  -- A comma would corrupt cell boundaries; ':' and '=' would corrupt the logcodec delta format.
  local row = splitCSV(I.formatRow({ t = 0, dt = 0.1, phase = "A,B", mode = "C:D=E", master = "x,y", duties = {} }))
  t.eq(row[idxOf("phase")], "AB")
  t.eq(row[idxOf("mode")], "CDE")
  t.eq(row[idxOf("master")], "xy")
end)

t.test("num never emits -0 (values rounding to zero from either sign print as 0)", function()
  local row = splitCSV(I.formatRow({ t = 0, dt = 1/16, alt = -0.0001, vSpeed = -0.00001,
    phase = "HOLD", duties = {} }))
  t.eq(row[idxOf("alt")], "0")
  t.eq(row[idxOf("vSpeed")], "0")
end)

t.test("formatRow trims trailing zeros but never loses the decimal point or sign", function()
  local row = splitCSV(I.formatRow({ t = 12.5, dt = 1/16, alt = 64, vSpeed = -0.5,
    pitch = 0, heading = 270, phase = "HOLD", duties = { [frame.LIFT[1]] = 7 } }))
  t.eq(row[idxOf("t")], "12.5")
  t.eq(row[idxOf("alt")], "64")
  t.eq(row[idxOf("vSpeed")], "-0.5")
  t.eq(row[idxOf("pitch")], "0")
  t.eq(row[idxOf("heading")], "270")
  t.eq(row[idxOf(frame.LIFT[1])], "7", "duty 0..15 prints as a compact integer")
  t.eq(row[idxOf("hz")], "16")
end)

t.test("formatSummary carries the schema version and the enum legend", function()
  local s = I.Summary.new(); s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5, heading = 0 })
  local out = I.formatSummary(s:finalize())
  t.truthy(out:find("# legend:"), "summary includes the enum legend line")
  t.truthy(out:find("schema: v2"), "summary names the schema version")
  t.truthy(out:find("C=CLIMB"), "legend maps phase codes")
  t.truthy(out:find("N=NORMAL"), "legend maps mode codes")
  t.truthy(out:find("G=GROUND"), "legend maps the loop's GROUND mode")
  t.truthy(out:find("err = sp"), "legend documents that err_* is derived, not logged")
end)

t.test("every formatSummary line starts with # (machine-distinguishable from CSV rows)", function()
  local s = I.Summary.new(); s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5, heading = 0 })
  for line in I.formatSummary(s:finalize()):gmatch("[^\n]+") do
    t.eq(line:sub(1, 1), "#", "line must start with #: " .. line)
  end
end)

t.test("Summary tracks per-axis peak |err| and peak |D|", function()
  local s = I.Summary.new()
  s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5.2, pitch = 0.1, sp_pitch = 0.0,
    roll = 0, sp_roll = 0, heading = 0, sp_hdg = 3, swayPos = 0, sp_sway = 0.4, surgePos = 0, sp_surge = -0.6,
    terms = {
      alt = { err = 0, P = 0, I = 0, D = 0.02 }, pitch = { err = 0, P = 0, I = 0, D = -0.5 },
      roll = { err = 0, P = 0, I = 0, D = 0.01 }, yaw = { err = 0, P = 0, I = 0, D = 0.03 },
      sway = { err = 0, P = 0, I = 0, D = 0.04 }, surge = { err = 0, P = 0, I = 0, D = -0.07 },
    } })
  s:add({ t = 0.1, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 4.9, pitch = 0.1, sp_pitch = 0.2,
    roll = 0, sp_roll = -0.1, heading = 0, sp_hdg = 2, swayPos = 0, sp_sway = -0.1, surgePos = 0, sp_surge = 0.1,
    terms = {
      alt = { err = 0, P = 0, I = 0, D = 0.01 }, pitch = { err = 0, P = 0, I = 0, D = 0.05 },
      roll = { err = 0, P = 0, I = 0, D = 0.2 }, yaw = { err = 0, P = 0, I = 0, D = 0.9 },
      sway = { err = 0, P = 0, I = 0, D = -0.01 }, surge = { err = 0, P = 0, I = 0, D = 0.02 },
    } })
  local m = s:finalize()
  t.near(m.peakErr.alt, 0.2, 1e-9)     -- max(|5.2-5|, |4.9-5|)
  t.near(m.peakErr.pitch, 0.1, 1e-9)   -- max(|0-0.1|, |0.2-0.1|)
  t.near(m.peakErr.yaw, 3, 1e-9)       -- max(|3-0|, |2-0|)
  t.near(m.peakD.pitch, 0.5, 1e-9)
  t.near(m.peakD.yaw, 0.9, 1e-9)
  t.near(m.peakD.surge, 0.07, 1e-9)
  local out = I.formatSummary(m)
  t.truthy(out:find("peak_err"), "formatSummary includes peak_err line")
  t.truthy(out:find("peak_D"), "formatSummary includes peak_D line")
end)

t.test("Summary handles samples with no terms/sp_* (hover_test path) without erroring", function()
  local s = I.Summary.new()
  local ok = pcall(function()
    s:add({ t = 0, dt = 0.1, phase = "HOLD", alt = 5, sp_alt = 5, heading = 0 })
  end)
  t.truthy(ok, "Summary:add must not error on a sample missing terms/sp_pitch/etc")
  local m = s:finalize()
  t.eq(m.peakErr.pitch, 0)
  t.eq(m.peakD.pitch, 0)
end)
