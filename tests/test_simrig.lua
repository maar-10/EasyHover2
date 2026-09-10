-- tests/test_simrig.lua -- relative-invariant guard on the closed-loop rig: stripping the
-- translation->attitude FFs (decouple off + CRU brakeTrim off) must ring LESS than the coupled
-- config under identical sim physics. Robust to the exact sim params (compares A vs B, same plant).
local t = require("tests.framework")
local rig = require("tools.simrig_run")

local P = { spoolTime = 0.5, tiltTrans = 1.0, latRoll = 0.6, surgePitch = 0.1 }
local COUPLED = { decoupleGains = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 }, brakeTrim = true }
local STRIP   = { decoupleGains = { swayRoll = 0,    surgePitch = 0,     authority = 0.3 }, brakeTrim = false }

t.test("simrig: stripping FFs reduces the post-brake pitch ring", function()
  local c = rig.run(P, COUPLED, 0.1, rig.SURGE)
  local s = rig.run(P, STRIP,   0.1, rig.SURGE)
  t.truthy(s.recover.peakP < c.recover.peakP,
    string.format("stripped pitch ring %.1f < coupled %.1f", s.recover.peakP, c.recover.peakP))
  t.truthy(s.recover.peakP < 25,
    string.format("stripped pitch ring under 25deg (true ~20; got %.1f)", s.recover.peakP))
end)

t.test("simrig: stripping FFs reduces the post-strafe roll ring", function()
  local c = rig.run(P, COUPLED, 0.1, rig.STRAFE)
  local s = rig.run(P, STRIP,   0.1, rig.STRAFE)
  t.truthy(s.srecover.peakR < c.srecover.peakR,
    string.format("stripped roll ring %.1f < coupled %.1f", s.srecover.peakR, c.srecover.peakR))
  t.truthy(s.srecover.peakR < 25,
    string.format("stripped roll ring under 25deg (true ~20; got %.1f)", s.srecover.peakR))
end)
