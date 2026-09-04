-- tests/test_tuning_modes.lua
local t = require("tests.framework")
local tuning = require("fcs.tuning")
local tuningdefaults = require("fcs.io.tuningdefaults")

t.test("forMode PRECISION returns the top-level tuning", function()
  local p = tuning.forMode("PRECISION")
  t.eq(p.gains, tuning.gains, "PRECISION gains are the top-level gains")
  t.eq(p.caps, tuning.caps, "PRECISION caps are the top-level caps")
end)

t.test("forMode MAN relaxes tilt and adds tilt feel", function()
  local m = tuning.forMode("MAN")
  t.truthy(m.caps.pitch > 0.2, "MAN pitch cap relaxed above default 0.2")
  t.truthy(m.feel.tiltRate and m.feel.tiltCap, "MAN has tilt feel params")
end)

t.test("forMode CRUISE adds surge-throttle feel", function()
  local c = tuning.forMode("CRUISE")
  t.truthy(c.feel.cruiseThrottleMax and c.feel.cruiseThrottleRate, "CRUISE has throttle feel")
end)

t.test("yaw defaults detuned for a crisp release stop (lower turn rate + more damping)", function()
  -- Higher-momentum heavy craft overshoots on release. Halve the turn rate (leadCapHeading) and
  -- raise yaw kd so the craft stops near release instead of ringing back 20-30deg.
  local p = tuning.forMode("PRECISION")
  t.near(p.gains.yaw.kd, 1.8, 1e-9, "yaw kd raised for damping")
  t.near(p.feel.leadCapHeading, 0.45, 1e-9, "yaw turn rate (lead cap) reduced from 0.70, nudged up from 0.35")
  local man = tuning.forMode("MAN")
  t.near(man.gains.yaw.kd, 1.8, 1e-9, "MAN inherits the damped yaw")
  t.near(man.feel.leadCapHeading, 0.45, 1e-9, "MAN inherits the turn rate")
end)

t.test("yawStopLead is a live feel knob across the tilt modes (snappy-yaw release stop)", function()
  t.truthy(tuning.forMode("PRECISION").feel.yawStopLead ~= nil, "PRECISION has yawStopLead")
  t.truthy(tuning.forMode("MAN").feel.yawStopLead ~= nil, "MAN has yawStopLead")
  t.truthy(tuning.forMode("CPL").feel.yawStopLead ~= nil, "CPL has yawStopLead")
end)

t.test("mode records are independent (mutating MAN never touches PRECISION/CRUISE)", function()
  local man = tuning.forMode("MAN")
  man.gains.yaw.kp = 999
  t.truthy(tuning.forMode("PRECISION").gains.yaw.kp ~= 999, "PRECISION untouched")
  t.truthy(tuning.forMode("CRUISE").gains.yaw.kp ~= 999, "CRUISE untouched")
end)

t.test("tuning.park block has ground-park defaults", function()
  t.near(tuning.park.groundClear, 1.0, 1e-9, "park.groundClear default")
  t.near(tuning.park.parkDriftEps, 0.15, 1e-9, "park.parkDriftEps default")
  t.near(tuning.park.parkTiltBand, 0.12, 1e-9, "park.parkTiltBand default")
end)

t.test("forMode LDG has reduced surge/sway/pitch caps", function()
  local ldg = tuning.forMode("LDG")
  t.near(ldg.caps.surge, 0.25, 1e-9, "LDG surge cap")
  t.near(ldg.caps.sway, 0.3, 1e-9, "LDG sway cap")
  t.near(ldg.caps.pitch, 0.2, 1e-9, "LDG pitch cap")
  t.near(ldg.caps.roll, 0.2, 1e-9, "LDG roll cap")
  t.near(ldg.caps.yaw, 0.4, 1e-9, "LDG yaw cap")
end)

t.test("forMode LDG has gentle landing feel overrides", function()
  local ldg = tuning.forMode("LDG")
  t.near(ldg.feel.surgeSpeed, 3.0, 1e-9, "LDG surgeSpeed")
  t.near(ldg.feel.surgeLead, 6.0, 1e-9, "LDG surgeLead")
  t.near(ldg.feel.swaySpeed, 2.0, 1e-9, "LDG swaySpeed")
  t.near(ldg.feel.swayLead, 4.0, 1e-9, "LDG swayLead")
  t.near(ldg.feel.climbRate, 2.5, 1e-9, "LDG climbRate")
end)

t.test("forMode DRN has agile pitch/roll caps", function()
  local drn = tuning.forMode("DRN")
  t.near(drn.caps.pitch, 0.5, 1e-9, "DRN pitch cap")
  t.near(drn.caps.roll, 0.5, 1e-9, "DRN roll cap")
  t.near(drn.caps.yaw, tuning.caps.yaw, 1e-9, "DRN yaw cap matches base")
end)

t.test("forMode DRN has tilt feel", function()
  local drn = tuning.forMode("DRN")
  t.near(drn.feel.tiltRate, 0.8, 1e-9, "DRN tiltRate")
  t.near(drn.feel.tiltCap, 0.5, 1e-9, "DRN tiltCap")
end)

t.test("tuning: trim/ramp feel is shared on the base feel (all flight modes inherit)", function()
  local D = require("fcs.io.tuningdefaults").get()
  t.eq(D.feel.trimGain, 0.35, "base trimGain")
  t.eq(D.feel.climbRampTime, 1.0, "base climbRampTime")
  t.eq(D.feel.climbBoost, 2.0, "base climbBoost")
  -- CPL/DCPL are no longer flight-mode tuning records
  t.eq(D.modes.CPL, nil, "no CPL mode record")
  t.eq(D.modes.DCPL, nil, "no DCPL mode record")
  -- DRN horizontal thrusters have real authority now (loop stabilizes on release)
  t.truthy(D.modes.DRN.caps.sway > 0, "DRN sway cap off zero")
  t.truthy(D.modes.DRN.caps.surge > 0, "DRN surge cap off zero")
end)

t.test("trim flip-guard: fade/floor feel defaults present and inherited by every mode", function()
  local base = tuning.forMode("PRECISION").feel
  t.near(base.trimAuthority, 0.4,  1e-9, "PRECISION trimAuthority default")
  t.near(base.trimFadeStart, 0.25, 1e-9, "PRECISION trimFadeStart default")
  t.near(base.trimFade, 0.6,       1e-9, "PRECISION trimFade default")
  for _, mode in ipairs({ "MAN", "CRUISE" }) do
    local f = tuning.forMode(mode).feel
    t.near(f.trimAuthority, 0.4, 1e-9, mode.." inherits trimAuthority")
    t.near(f.trimFade, 0.6,      1e-9, mode.." inherits trimFade")
  end
  local d = tuningdefaults.get()
  t.near(d.modes.LDG.feel.trimAuthority, 0.4, 1e-9, "LDG inherits")
  t.near(d.modes.DRN.feel.trimFade, 0.6,      1e-9, "DRN inherits")
end)

t.test("faster climb/descend: per-mode vertical authority (kp/leadCapVert/kd/climbRate)", function()
  -- steady climb v ~= kp*leadCapVert/kd. PRE(base)+MAN/DRN moderate; CRUISE aggressive; LDG pinned gentle.
  for _, mode in ipairs({ "PRECISION", "MAN", "DRN" }) do
    local m = tuning.forMode(mode)
    t.near(m.gains.alt.kp, 0.035, 1e-9, mode.." alt kp raised (0.02->0.035)")
    t.near(m.gains.alt.kd, 0.15,  1e-9, mode.." alt kd unchanged")
    t.near(m.feel.leadCapVert, 10.0, 1e-9, mode.." leadCapVert raised (8->10)")
    t.near(m.feel.climbRate,   5.0,  1e-9, mode.." climbRate raised (4.5->5)")
  end
  local cru = tuning.forMode("CRUISE")
  t.near(cru.gains.alt.kp, 0.045, 1e-9, "CRU alt kp aggressive")
  t.near(cru.gains.alt.kd, 0.08,  1e-9, "CRU alt kd lowered (livelier)")
  t.near(cru.feel.leadCapVert, 12.0, 1e-9, "CRU leadCapVert")
  t.near(cru.feel.climbRate,   12.0, 1e-9, "CRU climbRate keeps setpoint ahead")
  local ldg = tuning.forMode("LDG")
  t.near(ldg.gains.alt.kp, 0.02, 1e-9, "LDG alt kp pinned gentle (not the raised base)")
  t.near(ldg.gains.alt.kd, 0.15, 1e-9, "LDG alt kd pinned")
  t.near(ldg.feel.leadCapVert, 8.0, 1e-9, "LDG leadCapVert pinned to 8")
  t.near(ldg.feel.climbRate,   2.5, 1e-9, "LDG climbRate stays gentle")
end)
