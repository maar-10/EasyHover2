-- tools/simrig_run.lua -- scenario driver for the closed-loop reproduction rig (tools/simrig.lua).
-- Isolates the three translation->attitude feed-forwards (trim / tilt-brake / decouple) by toggling
-- each and measuring the post-maneuver attitude ring, across a loop-rate sweep. Writes a report.
local rig = require("tools.simrig")
local function fmt(x) return string.format("%5.1f", x) end
local function deg(x) return x * 180 / math.pi end

-- Fly a scenario script; return {phaseTag = {peakP, peakR, endP, endR, ovrH, ovrA, ovrS}}.
-- ovrH/ovrA/ovrS: max |measured - captured setpoint| of heading(deg)/altitude(blocks)/
-- swayPos(blocks), where "captured setpoint" is pilot.sp.heading/altitude/swayPos -- the value
-- the release-edge leadCap() (fcs/input/pilot.lua) writes on the FIRST tick of that phase (with
-- lead OFF this is a bare zero-order capture of the measurement; with lead ON it is captured
-- ahead by the stopping distance). This is the actual "ring past the held setpoint" the
-- stopping-lead is meant to shrink -- NOT the raw release-tick measurement, which the leaded
-- setpoint is deliberately ahead of.
local function run(simParams, toggles, dt, script)
  local ctx = rig.buildStack(simParams, toggles)
  local F, S, P = ctx.flight, ctx.sim, ctx.pilot
  F:handleCommand({ k = "gndSafety", on = false })
  F:handleCommand({ k = "flightMode", id = "CRUISE" })
  F:handleCommand({ k = "masterMode", id = "CPL" })
  F:handleCommand({ k = "engage" })
  local ph = {}
  for _, seg in ipairs(script) do
    local peakP, peakR, lastP, lastR = 0, 0, 0, 0
    local ovrH, ovrA, ovrS = 0, 0, 0
    local capH, capA, capS
    local n = math.floor(seg.secs / dt)
    for i = 1, n do
      F:step(dt, seg.held, S:sensors())
      if i == 1 then capH, capA, capS = deg(P.sp.heading), P.sp.altitude, P.sp.swayPos end
      S:step(dt)
      local m = S:sensors()
      peakP = math.max(peakP, math.abs(deg(m.pitch))); peakR = math.max(peakR, math.abs(deg(m.roll)))
      lastP, lastR = deg(m.pitch), deg(m.roll)
      ovrH = math.max(ovrH, math.abs(deg(m.heading) - capH))
      ovrA = math.max(ovrA, math.abs(m.altitude - capA))
      ovrS = math.max(ovrS, math.abs(m.swayPos - capS))
    end
    ph[seg.tag] = { peakP = peakP, peakR = peakR, endP = lastP, endR = lastR,
      ovrH = ovrH, ovrA = ovrA, ovrS = ovrS }
  end
  return ph
end

local SURGE = { { secs = 6, held = { up = true }, tag = "climb" }, { secs = 3, held = {}, tag = "s0" },
  { secs = 6, held = { surgeFwd = true }, tag = "surge" }, { secs = 3, held = { surgeBack = true }, tag = "brake" },
  { secs = 8, held = {}, tag = "recover" } }
local STRAFE = { { secs = 6, held = { up = true }, tag = "climb" }, { secs = 3, held = {}, tag = "s0" },
  { secs = 5, held = { swayRight = true }, tag = "strafe" }, { secs = 8, held = {}, tag = "srecover" } }

-- Release scenarios: hold a rate command then let go, isolating the stopping-lead's effect on
-- the post-release ring past the capture point (see ovrH/ovrA/ovrS above).
local YAWREL   = { { secs = 6, held = { up = true }, tag = "climb" }, { secs = 3, held = {}, tag = "s0" },
  { secs = 4, held = { yawRight = true }, tag = "turn" }, { secs = 8, held = {}, tag = "yawrec" } }
local CLIMBREL = { { secs = 3, held = {}, tag = "s0" }, { secs = 5, held = { up = true }, tag = "climb" },
  { secs = 8, held = {}, tag = "altrec" } }
local STRAFEREL= { { secs = 6, held = { up = true }, tag = "climb" }, { secs = 3, held = {}, tag = "s0" },
  { secs = 4, held = { swayRight = true }, tag = "strafe" }, { secs = 8, held = {}, tag = "swayrec" } }

local function report()
  local out = {}; local function w(s) out[#out + 1] = s end
  local P = { spoolTime = 0.5, tiltTrans = 1.0, latRoll = 0.6, surgePitch = 0.1 }
  w("simrig isolation: post-maneuver ring (peak |pitch| after brake, peak |roll| after strafe), deg")
  w("params: spoolTime=0.5 tiltTrans=1.0 latRoll=0.6 surgePitch=0.1")
  -- Explicit gains per case (do NOT rely on shipped defaults, which may already be stripped).
  local DC_ON  = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 }
  local DC_OFF = { swayRoll = 0, surgePitch = 0, authority = 0.3 }
  local cases = {
    { "COUPLED (decpl .10, brakeTrim T)",      { decoupleGains = DC_ON,  brakeTrim = true } },
    { "decouple OFF (brakeTrim T)",            { decoupleGains = DC_OFF, brakeTrim = true } },
    { "decouple OFF + brakeTrim=false",        { decoupleGains = DC_OFF, brakeTrim = false } },
    { "decouple OFF + trim OFF",               { decoupleGains = DC_OFF, trim = false } },
    { "decpl ON + trim OFF",                   { decoupleGains = DC_ON,  trim = false } },
    { "ALL OFF (decpl+trim+tiltBrake)",        { decoupleGains = DC_OFF, trim = false, tiltBrake = false } },
  }
  for _, dt in ipairs({ 0.1, 0.2 }) do
    w("")
    w(string.format("=== dt=%.2f (%.0f Hz) ===", dt, 1 / dt))
    w(string.format("%-22s | %s | %s", "config", "brake->recover |pitch|", "strafe->recover |roll|"))
    for _, c in ipairs(cases) do
      local a = run(P, c[2], dt, SURGE)
      local b = run(P, c[2], dt, STRAFE)
      w(string.format("%-22s |  brake %s  recover %s |  strafe %s  recover %s",
        c[1], fmt(a.brake.peakP), fmt(a.recover.peakP), fmt(b.strafe.peakR), fmt(b.srecover.peakR)))
    end
  end
  -- B: base-cascade damping prototypes, on the STRIP baseline (decouple off + brakeTrim false).
  local DCO = { swayRoll = 0, surgePitch = 0, authority = 0.3 }
  -- B5: correctly-signed decouple (cancel the off-CoM torque at source). Sim coupling is
  -- latRoll>0, surgePitch>0, so a CANCELLING decouple needs swayRoll<0, surgePitch<0. Sweep it.
  local Bcases = {
    { "STRIP (no B)",              { decoupleGains = DCO, brakeTrim = false } },
    { "B1 kd x3 (.66)",            { decoupleGains = DCO, brakeTrim = false, tune = { pitchKd = 0.66, rollKd = 0.66 } } },
    { "B2 softer arrest ks/2",     { decoupleGains = DCO, brakeTrim = false, tune = { surgeKs = 0.25, swayKs = 0.25 } } },
    { "B5 decpl swR-.10 suP-.05",  { decoupleGains = { swayRoll = -0.10, surgePitch = -0.05, authority = 0.3 }, brakeTrim = false } },
    { "B5 decpl swR-.20 suP-.10",  { decoupleGains = { swayRoll = -0.20, surgePitch = -0.10, authority = 0.5 }, brakeTrim = false } },
    { "B5 decpl swR-.40 suP-.20",  { decoupleGains = { swayRoll = -0.40, surgePitch = -0.20, authority = 0.8 }, brakeTrim = false } },
  }
  for _, dt in ipairs({ 0.1, 0.2 }) do
    w("")
    w(string.format("################ B damping @ dt=%.2f (%.0f Hz), STRIP baseline ################", dt, 1 / dt))
    for _, c in ipairs(Bcases) do
      local a = run(P, c[2], dt, SURGE); local b = run(P, c[2], dt, STRAFE)
      w(string.format("%-26s | pitch %s | roll %s", c[1], fmt(a.recover.peakP), fmt(b.srecover.peakR)))
    end
  end
  -- Stopping-lead release-overshoot table: lead ON vs OFF on identical physics, across dt, proving
  -- the capture-ahead-of-stopping-distance (Task 1) actually cuts the post-release ring.
  local LEAD = { yaw = 0.6, alt = 0.4, sway = 0.4 }
  w("")
  w("=== stopping-lead release overshoot: lead ON vs OFF (same physics) ===")
  for _, dt in ipairs({ 0.1, 0.2 }) do
    w("")
    w(string.format("--- dt=%.2f (%.0f Hz) ---", dt, 1 / dt))
    local yOff = run(P, { lead = false }, dt, YAWREL);    local yOn = run(P, { lead = LEAD }, dt, YAWREL)
    local aOff = run(P, { lead = false }, dt, CLIMBREL);  local aOn = run(P, { lead = LEAD }, dt, CLIMBREL)
    local sOff = run(P, { lead = false }, dt, STRAFEREL); local sOn = run(P, { lead = LEAD }, dt, STRAFEREL)
    w(string.format("%-8s | %-18s | %-18s | %-18s", "", "yaw ovrH (deg)", "alt ovrA (blk)", "strafe ovrS (blk)"))
    w(string.format("%-8s |    OFF %s          |    OFF %s          |    OFF %s",
      "", fmt(yOff.yawrec.ovrH), fmt(aOff.altrec.ovrA), fmt(sOff.swayrec.ovrS)))
    w(string.format("%-8s |    ON  %s          |    ON  %s          |    ON  %s",
      "", fmt(yOn.yawrec.ovrH), fmt(aOn.altrec.ovrA), fmt(sOn.swayrec.ovrS)))
  end
  return table.concat(out, "\n")
end

return { run = run, report = report, SURGE = SURGE, STRAFE = STRAFE,
  YAWREL = YAWREL, CLIMBREL = CLIMBREL, STRAFEREL = STRAFEREL }
