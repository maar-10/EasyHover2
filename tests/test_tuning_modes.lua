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
  t.truthy(m.caps.pitch > 0.3, "MAN pitch cap relaxed above the base 0.3")
  t.truthy(m.feel.tiltRate and m.feel.tiltCap, "MAN has tilt feel params")
end)

t.test("forMode CRUISE adds surge-throttle feel", function()
  local c = tuning.forMode("CRUISE")
  t.truthy(c.feel.cruiseThrottleMax and c.feel.cruiseThrottleRate, "CRUISE has throttle feel")
end)

t.test("yaw kd detuned for a crisp release stop (heavy craft, damping only)", function()
  -- Higher-momentum heavy craft overshoots on release; raise yaw kd so the craft stops near
  -- release instead of ringing back 20-30deg. Turn RATE itself is now feel.headingRate, the
  -- achieved rad/s (rate-command batch, 2026-09-06) -- see the "rate-command defaults" test below.
  local p = tuning.forMode("PRECISION")
  t.near(p.gains.yaw.kd, 1.8, 1e-9, "yaw kd raised for damping")
  local man = tuning.forMode("MAN")
  t.near(man.gains.yaw.kd, 1.8, 1e-9, "MAN inherits the damped yaw")
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
  t.near(ldg.feel.swaySpeed, 3.0, 1e-9, "LDG swaySpeed")
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

t.test("tuning: trim feel is shared on the base feel (all flight modes inherit)", function()
  local D = require("fcs.io.tuningdefaults").get()
  t.near(D.feel.trimGain, 0.18, 1e-9, "base trimGain (reduced 2026-09-09)")
  -- CPL/DCPL are no longer flight-mode tuning records
  t.eq(D.modes.CPL, nil, "no CPL mode record")
  t.eq(D.modes.DCPL, nil, "no DCPL mode record")
  -- DRN horizontal thrusters have real authority now (loop stabilizes on release)
  t.truthy(D.modes.DRN.caps.sway > 0, "DRN sway cap off zero")
  t.truthy(D.modes.DRN.caps.surge > 0, "DRN surge cap off zero")
end)

t.test("trim flip-guard: fade/floor feel defaults present and inherited by every mode", function()
  local base = tuning.forMode("PRECISION").feel
  t.near(base.trimAuthority, 0.30,  1e-9, "PRECISION trimAuthority default")
  t.near(base.trimFadeStart, 0.25, 1e-9, "PRECISION trimFadeStart default")
  t.near(base.trimFade, 0.6,       1e-9, "PRECISION trimFade default")
  for _, mode in ipairs({ "MAN", "CRUISE" }) do
    local f = tuning.forMode(mode).feel
    t.near(f.trimAuthority, 0.30, 1e-9, mode.." inherits trimAuthority")
    t.near(f.trimFade, 0.6,      1e-9, mode.." inherits trimFade")
  end
  local d = tuningdefaults.get()
  t.near(d.modes.LDG.feel.trimAuthority, 0.30, 1e-9, "LDG inherits")
  t.near(d.modes.DRN.feel.trimFade, 0.6,      1e-9, "DRN inherits")
end)

t.test("vertical authority: per-mode alt kp/kd (position-hold path, unchanged by rate-command)", function()
  for _, mode in ipairs({ "PRECISION", "MAN", "DRN" }) do
    local m = tuning.forMode(mode)
    t.near(m.gains.alt.kp, 0.06, 1e-9, mode.." alt kp")
    t.near(m.gains.alt.kd, 0.15,  1e-9, mode.." alt kd unchanged")
  end
  local cru = tuning.forMode("CRUISE")
  t.near(cru.gains.alt.kp, 0.045, 1e-9, "CRU alt kp aggressive")
  t.near(cru.gains.alt.kd, 0.08,  1e-9, "CRU alt kd lowered (livelier)")
  local ldg = tuning.forMode("LDG")
  t.near(ldg.gains.alt.kp, 0.02, 1e-9, "LDG alt kp pinned gentle (not the raised base)")
  t.near(ldg.gains.alt.kd, 0.15, 1e-9, "LDG alt kd pinned")
end)

t.test("brakeTrim: symmetric (tilt-to-brake) only in CRU/DRN, forward-only elsewhere", function()
  t.eq(tuning.forMode("CRUISE").feel.brakeTrim, true,  "CRU keeps symmetric brake lean")
  t.eq(tuning.forMode("DRN").feel.brakeTrim,    true,  "DRN keeps symmetric (pitch is its accel/decel)")
  t.eq(tuning.forMode("PRECISION").feel.brakeTrim, false, "PRE forward-only")
  t.eq(tuning.forMode("MAN").feel.brakeTrim,    false, "MAN forward-only")
  t.eq(tuning.forMode("LDG").feel.brakeTrim,    false, "LDG forward-only")
end)

t.test("attitude leveling integral resolves per mode (fix #1)", function()
  for _, m in ipairs({ "PRECISION", "CRUISE", "LDG" }) do
    for _, ax in ipairs({ "pitch", "roll" }) do
      local g = tuning.forMode(m).gains[ax]
      t.near(g.ki, 0.05, 1e-9, m.." "..ax.." ki (aggressive leveling)")
      t.near(g.iBand, 0.35, 1e-9, m.." "..ax.." iBand")
      t.near(g.iMax, 0.10, 1e-9, m.." "..ax.." iMax")
      t.near(g.iMin, -0.10, 1e-9, m.." "..ax.." iMin")
    end
  end
  t.near(tuning.forMode("MAN").gains.pitch.ki, 0, 1e-9, "MAN pitch ki off (pilot-flown)")
  t.near(tuning.forMode("MAN").gains.roll.ki,  0, 1e-9, "MAN roll ki off")
  t.near(tuning.forMode("DRN").gains.pitch.ki, 0, 1e-9, "DRN pitch ki off")
  t.near(tuning.forMode("DRN").gains.roll.ki,  0, 1e-9, "DRN roll ki off")
end)

t.test("rate-command defaults resolve per mode (2026-09-06)", function()
  local function fe(m) return tuning.forMode(m).feel end
  local function ga(m) return tuning.forMode(m).gains end
  t.near(fe("PRECISION").climbRate, 8, 1e-9); t.near(fe("PRECISION").headingRate, 1.2, 1e-9)
  t.near(fe("PRECISION").swaySpeed, 6, 1e-9)
  t.near(ga("PRECISION").alt.kv, 0.06, 1e-9); t.near(ga("PRECISION").yaw.kw, 0.8, 1e-9)
  t.near(ga("PRECISION").sway.ks, 0.4, 1e-9)
  t.near(fe("CRUISE").climbRate, 12, 1e-9); t.near(fe("CRUISE").headingRate, 1.5, 1e-9)
  t.near(fe("CRUISE").swaySpeed, 10, 1e-9); t.near(ga("CRUISE").yaw.kw, 0.9, 1e-9)
  t.near(fe("LDG").climbRate, 2.5, 1e-9); t.near(fe("LDG").headingRate, 0.6, 1e-9)
  t.near(fe("MAN").climbRate, 6, 1e-9); t.near(fe("DRN").climbRate, 6, 1e-9)
end)

t.test("per-mode trimGain: enabled everywhere except LDG", function()
  for _, m in ipairs({ "PRECISION", "MAN", "CRUISE", "DRN" }) do
    t.truthy(tuning.forMode(m).feel.trimGain > 0, m.." accel trim enabled")
  end
  t.near(tuning.forMode("LDG").feel.trimGain, 0, 1e-9, "LDG accel trim off (gentle)")
end)

t.test("CRU/PRE pitch authority bumped for accel residual", function()
  t.near(tuning.forMode("CRUISE").gains.pitch.kp, 0.15, 1e-9)
  t.near(tuning.forMode("CRUISE").caps.pitch, 0.3, 1e-9)
  t.near(tuning.forMode("PRECISION").gains.pitch.kp, 0.15, 1e-9)
  t.near(tuning.forMode("PRECISION").caps.pitch, 0.3, 1e-9)
end)

t.test("retired leash keys are gone", function()
  local d = require("fcs.io.tuningdefaults").get()
  for _, k in ipairs({ "leadCapVert", "altStopLead", "leadCapHeading", "yawStopLead", "swayLead",
                       "climbBoost", "climbRampTime" }) do
    t.eq(d.feel[k], nil, "base feel."..k.." retired")
  end
end)

t.test("attitude leveling: level-hold roll gains integrate a standing bank; MAN does not", function()
  local Pid = require("fcs.control.pid")
  -- level-hold (CRU): a sustained bank within iBand (sp=0, meas=+0.1 rad ~6deg) -> integral accumulates,
  -- so the corrective demand GROWS over time (drives the standing bank toward level).
  local lvl = Pid.new(tuning.forMode("CRUISE").gains.roll)
  local first = lvl:update(0, 0.1, 0.1)                     -- err=-0.1: P + one tick of I
  for _ = 1, 20 do lvl:update(0, 0.1, 0.1) end              -- integral builds
  local later = lvl:update(0, 0.1, 0.0)                     -- dt=0: output = kp*err + accumulated i
  t.truthy(math.abs(later) > math.abs(first) + 1e-6, "level-hold roll integral grows to cancel the bank")
  -- MAN (ki=0): pure P, output constant -> would hold the bank (today's behavior, kept for pilot control).
  local man = Pid.new(tuning.forMode("MAN").gains.roll)
  local m1 = man:update(0, 0.1, 0.1)
  for _ = 1, 20 do man:update(0, 0.1, 0.1) end
  local m2 = man:update(0, 0.1, 0.0)
  t.near(m2, m1, 1e-9, "MAN roll ki=0 -> P-only, no integral growth")
end)
