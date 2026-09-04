local t = require("tests.framework")
local T = require("fcs.tuning")

t.test("tuning exposes the flight-tuned gains", function()
  t.near(T.gains.hoverDuty, 0.26, 1e-9)   -- Flight #7 measured true hover (~0.257)
  t.near(T.gains.alt.kd, 0.15, 1e-9)
  t.near(T.gains.alt.tauD, 0.35, 1e-9)    -- Flight #9: filter the coarse vSpeed derivative
  t.near(T.gains.yaw.kd, 1.8, 1e-9)   -- raised to damp the heavy craft's yaw-release ring
end)
t.test("attitude has a leveling integral (fix #1): kp/kd held, ki+iBand added to cancel standing banks", function()
  -- ki was 0 (P+D only) which held 5-24deg standing banks; ki+iBand added 2026-09-04 to level them.
  t.near(T.gains.pitch.kp, 0.10, 1e-9); t.near(T.gains.pitch.kd, 0.22, 1e-9)
  t.near(T.gains.pitch.ki, 0.05, 1e-9); t.near(T.gains.pitch.iBand, 0.35, 1e-9)
  t.near(T.gains.roll.kp, 0.10, 1e-9); t.near(T.gains.roll.ki, 0.05, 1e-9); t.near(T.gains.roll.iBand, 0.35, 1e-9)
end)
t.test("heave authority band keeps lift off the rails", function()
  t.near(T.gains.heaveMin, 0.05, 1e-9); t.near(T.gains.heaveMax, 0.85, 1e-9)
end)
t.test("tuning exposes actuator + safety params", function()
  t.near(T.pwmPeriod, 0.3, 1e-9)
  t.near(T.caps.pitch, 0.2, 1e-9)
  t.eq(T.osc.minChanges, 6)
  t.near(T.osc.deadband, 0.02, 1e-9)   -- ~1.1deg: above the level-flight sensor noise floor
  t.near(T.osc.calmTime, 1.0, 1e-9)    -- s of calm before a trip auto-releases
  t.near(T.dtMax, 0.5, 1e-9)
  t.near(T.attLimit, 0.6, 1e-9)
end)
t.test("tuning exposes the flight profile params", function()
  t.near(T.profile.climbHeight, 6, 1e-9)
  t.near(T.profile.climbRate, 0.6, 1e-9)
  t.near(T.profile.holdTime, 20, 1e-9)
  t.near(T.profile.descendRate, 0.7, 1e-9)
  t.near(T.profile.leadCap, 1.0, 1e-9)
end)

t.test("tuning merges eh2_tuning.tbl over checkpoint defaults", function()
  local build = require("fcs.tuning")._buildFrom   -- pure builder exposed for the test
  local base = require("fcs.io.tuningdefaults").get()
  local merged = build({ gains = { yaw = { kp = 1.23 } } })   -- injected "saved"
  t.eq(merged.gains.yaw.kp, 1.23, "saved overrides")
  t.eq(merged.caps.pitch, base.caps.pitch, "unspecified falls back to default")
end)
