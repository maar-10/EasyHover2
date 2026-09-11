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

local LEAD = { yaw=0.6, alt=0.4, sway=0.4 }
t.test("simrig: stopping-lead cuts yaw release overshoot", function()
  local base = { spoolTime=0.5, tiltTrans=1.0, latRoll=0.6, surgePitch=0.1 }
  local off = rig.run(base, { lead=false }, 0.1, rig.YAWREL)
  local on  = rig.run(base, { lead=LEAD }, 0.1, rig.YAWREL)
  t.truthy(on.yawrec.ovrH < off.yawrec.ovrH,
    string.format("yaw overshoot lead=%.0f < nolead=%.0f", on.yawrec.ovrH, off.yawrec.ovrH))
end)
t.test("simrig: stopping-lead cuts altitude release overshoot", function()
  local base = { spoolTime=0.5, tiltTrans=1.0, latRoll=0.6, surgePitch=0.1 }
  local off = rig.run(base, { lead=false }, 0.1, rig.CLIMBREL)
  local on  = rig.run(base, { lead=LEAD }, 0.1, rig.CLIMBREL)
  t.truthy(on.altrec.ovrA < off.altrec.ovrA,
    string.format("alt overshoot lead=%.1f < nolead=%.1f", on.altrec.ovrA, off.altrec.ovrA))
end)
t.test("simrig: stopping-lead cuts strafe release overshoot", function()
  local base = { spoolTime=0.5, tiltTrans=1.0, latRoll=0.6, surgePitch=0.1 }
  local off = rig.run(base, { lead=false }, 0.1, rig.STRAFEREL)
  local on  = rig.run(base, { lead=LEAD }, 0.1, rig.STRAFEREL)
  t.truthy(on.swayrec.ovrS < off.swayrec.ovrS,
    string.format("strafe overshoot lead=%.1f < nolead=%.1f", on.swayrec.ovrS, off.swayrec.ovrS))
end)
