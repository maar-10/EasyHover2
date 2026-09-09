-- fcs/io/tuningdefaults.lua
-- Committed checkpoint tuning, shared by fcs/tuning.lua and fcs/io/cfgspec.lua
-- so "load defaults" and an absent eh2_tuning.tbl both yield current flight.

local function deep(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deep(x) end
  return o
end

local DEFAULTS = {
  gains = {
    hoverDuty = 0.26,
    -- iBand: conditional-integration anti-windup, kept from the earlier lead-based climb scheme:
    -- integrate only within 3 blocks of the setpoint so P/D drive the climb and I only trims the
    -- steady-state hover residual near the target (prevents the old long, oscillatory drop after
    -- climb caused by the integrator winding up over a wide, sustained altitude error).
    -- Rate-command batch (2026-09-06): the pilot/scheme now command a velocity directly (feel.climbRate
    -- is the ACHIEVED climb rate, not a setpoint-lead slew) via the new kv term below, instead of
    -- leaning on a wide setpoint lead (feel.leadCapVert, retired) to imply speed through P*lead. kp/kd
    -- here still drive the position-hold/error-correction path; kv is the added velocity feedforward.
    alt   = { kp = 0.06, ki = 0.01, kd = 0.15, tauD = 0.35, iMax = 0.3, iMin = -0.3, iBand = 3.0,
              kv = 0.06 },
    -- Attitude leveling integral (2026-09-04, fix #1): ki+iBand cancels standing banks/pitch that
    -- P+D alone leaves as a held equilibrium (log: 5-24deg banks held for dozens of s). iBand=0.35rad
    -- (~20deg) integrates to level the standing error but not during hard maneuvers (anti-windup);
    -- iMax caps it well above the measured ~0.014 disturbance. MAN/DRN pin ki=0 (pilot flies attitude).
    -- Rate-command batch (2026-09-06): kp raised 0.10->0.15 (+caps.pitch 0.2->0.3) in PRE/CRU so the
    -- pitch stabilizer has the extra authority to hold level against the re-enabled accel trim
    -- residual; MAN/LDG/DRN pin kp back to 0.10 (pilot-flown attitude, no accel residual to fight).
    pitch = { kp = 0.15, ki = 0.05, kd = 0.22, tauD = 0.2, iMax = 0.10, iMin = -0.10, iBand = 0.35 },
    roll  = { kp = 0.10, ki = 0.05, kd = 0.22, tauD = 0.2, iMax = 0.10, iMin = -0.10, iBand = 0.35 },
    yaw   = { kp = 0.95, ki = 0, kd = 1.8, kw = 0.8 },   -- kd 1.0->1.8: damp the heavy craft's release ring
    sway  = { ks = 0.4, ka = 1.0 },
    surge = { ks = 0.4, ka = 1.0 },
    heaveMin = 0.05,
    heaveMax = 0.85,
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.3, roll = 0.2, yaw = 0.6, sway = 0.9, surge = 1.0 },
  -- Oscillation detector: a crossing counts only past +/-deadband (rad) so level-flight sensor
  -- dither can't false-trip; a trip auto-releases after calmTime (s) of calm. Per-axis (pitch/roll).
  osc = { window = 1.0, minChanges = 6, deadband = 0.02, calmTime = 1.0 },
  -- Emergency recovery (EMRCVR): active righting when attitude departs level far past normal
  -- flight (see the emrcvr spec/plan). tripAngle/exitAngle are the trip/release hysteresis pair
  -- (rad); maxDrift bounds how far the recovery lets the craft drift while righting; dwell (s)
  -- gates a brief settle before release; levelBand (rad) is the "level enough" exit tolerance;
  -- kpAtt/capAtt are the recovery attitude loop's own gain/cap (independent of the flying mode's).
  emrcvr = { tripAngle = 1.309, exitAngle = 0.175, maxDrift = 2.0, dwell = 0.5,
             levelBand = 0.5, kpAtt = 0.6, capAtt = 0.8 },
  dtMax = 0.5,
  attLimit = 0.6,
  com = { fwd = 0, right = 0, spanFwd = 0, spanRight = 0 },
  -- Keep-warm idle floors for the unidirectional lateral/surge thrusters. GLOBAL (the Create
  -- Propulsion 0.5s spool ramp is a hardware property, identical in every mode). floor 0 disables.
  -- mainRatio = 2*wFront/wMain balances the surge idle net-zero; source-derived for a 3x3x3 MAIN
  -- (thrust ~40.5) vs two 1x1 frontals (~1 each): 2/40.5 ~ 0.049. Tune in-world if the craft differs.
  keepWarm = { floor = 0.08, surgeFront = 0.07, mainRatio = 0.049 },
  -- Translation->attitude decoupling feedforward gains (flight bf9a45213f). GLOBAL (a physical
  -- thruster-vs-CoM property). Signs CANCEL the measured coupling (roll=-0.10*sway, pitch=+0.05*surge).
  -- Conservative starting values, hard-bounded by authority*caps in the loop; tune from the next log.
  decouple = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 },
  park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 },
  profile = { climbHeight = 6, climbRate = 0.6, holdTime = 20, descendRate = 0.7,
              landEps = 0.4, watchdog = 60, overshootMargin = 2, leadCap = 1.0 },
  feel = {
    -- Rate-command batch (2026-09-06): these are now ACHIEVED-rate targets the pilot/scheme command
    -- and hold directly (via the gains.*.k{v,w,s} velocity-gain terms above), not setpoint-lead slew
    -- rates -- so the numbers are real physical rates again (rad/s, blk/s), not the inflated
    -- lead-implied speeds the old leash scheme needed. leadCapVert/altStopLead/leadCapHeading/
    -- yawStopLead/swayLead (the old setpoint-lead leash + release-edge capture) are RETIRED -- the
    -- direct rate command replaces them; see fcs/input/pilot.lua.
    headingRate    = 1.2,    -- rad/s achieved turn rate

    climbRate      = 8.0,    -- blk/s achieved climb rate
    surgeSpeed     = 10.0,
    surgeLead      = 20.0,   -- surge stays lead-based (not rate-commanded, see fcs/control/translate.lua)
    swaySpeed      = 6.0,    -- blk/s achieved strafe rate

    trimGain       = 0.18,  -- forward-trim ff gain (was 0.30): reduced magnitude, same reaction --
                            -- the nose-down accel lean was too harsh. First estimate -- TUNE in-world.
    -- Flip-guard bounds (spec 2026-09-04): fade the trim out as the craft departs level, and cap the
    -- feedforward at a fraction of caps.pitch so it can never starve the pitch stabilizer.
    trimFadeStart  = 0.25,  -- rad: full trim below this |pitch| (normal accel tilt stays fully assisted)
    trimFade       = 0.6,   -- rad: trim fully faded to 0 by this |pitch| (== attLimit)
    trimAuthority  = 0.30,  -- max fraction of caps.pitch the ff may consume (was 0.40): lower hard
                            -- cap on the accel lean. First estimate -- TUNE in-world.
    brakeTrim      = false, -- symmetric trim (lean to accel AND brake)? true only for CRU/DRN; every
                            -- other mode is forward-only (brake stays level, frontal thrusters brake)
    -- Tilt-brake (fix #3): speed-scaled pitch/roll brake into the drift direction. Base OFF so
    -- PRECISION (reads top-level) and LDG stay level-braking; CRU/MAN/DRN enable it below.
    tiltBrake = {
      enabled     = false,
      engageSpeed = 30.0,   -- blk/s: below this, directional thrusters brake alone (level)
      satSpeed    = 100.0,  -- blk/s: tilt reaches its max angle here
      minAngle    = 0.2618, -- 15deg: tilt at the engage speed
      maxAngle    = 0.5236, -- 30deg: auto max at/above satSpeed
      buttonMax   = 0.7854, -- 45deg: CTRL-brake max at/above satSpeed
      slewRate    = 0.3,    -- rad/s: max onset rate of the brake tilt setpoint. Fixed slew so the
                            -- leveling loop tracks the brake angle without overshoot at low loop
                            -- rate (high-speed brake departed by overshooting to the EMRCVR trip).
                            -- First estimate -- TUNE in-world.
    },
  },
}

-- Per-mode tuning: MAN/CRUISE are full, independent records seeded from the base
-- (PRECISION is NOT here -- it reads the top-level tuning, keeping its calibration).
DEFAULTS.modes = {
  MAN = {
    gains = deep(DEFAULTS.gains),
    caps  = { pitch = 0.4, roll = 0.4, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
    feel  = deep(DEFAULTS.feel),
  },
  CRUISE = {
    gains = deep(DEFAULTS.gains),
    caps  = deep(DEFAULTS.caps),
    feel  = deep(DEFAULTS.feel),
  },
}
-- Tilt feel (MAN): arrow-key tilt, rad and rad/s; keep tiltCap < attLimit (0.6).
DEFAULTS.modes.MAN.feel.tiltRate = 0.8
DEFAULTS.modes.MAN.feel.tiltCap  = 0.40
-- MAN/DRN fly attitude directly (pilot tilt); no leveling integral on the axis being flown -- keep the
-- crisp pure-P+D auto-level-on-release feel. (fix #1)
DEFAULTS.modes.MAN.gains.pitch.ki = 0
DEFAULTS.modes.MAN.gains.roll.ki  = 0
-- Tilt-brake (fix #3): MAN pilots directly, so enable speed-scaled brake tilt.
DEFAULTS.modes.MAN.feel.tiltBrake.enabled = true
-- MAN pilots pitch directly (no accel residual to fight) -- pin back to 0.10, unaffected by the
-- PRE/CRU pitch-authority bump above (2026-09-06).
DEFAULTS.modes.MAN.gains.pitch.kp = 0.10
DEFAULTS.modes.MAN.feel.climbRate = 6.0
-- Surge-throttle feel (CRUISE): W ramps up, release holds, S ramps down; 0..1 of MAIN.
DEFAULTS.modes.CRUISE.feel.cruiseThrottleRate = 1.0
DEFAULTS.modes.CRUISE.feel.cruiseThrottleMax  = 1.0
-- Fast cruise climb/descend: aggressive alt kp/kd, unchanged by the rate-command batch (still the
-- position-hold/error-correction path; gains.alt.kv above is the added velocity feedforward).
DEFAULTS.modes.CRUISE.gains.alt.kp     = 0.045
DEFAULTS.modes.CRUISE.gains.alt.kd     = 0.08
DEFAULTS.modes.CRUISE.feel.climbRate   = 12.0
-- CRU keeps the symmetric trim: the cruiser leans back to brake hard (wanted).
DEFAULTS.modes.CRUISE.feel.brakeTrim   = true
-- Tilt-brake (fix #3): CRU's active braking, speed-scaled.
DEFAULTS.modes.CRUISE.feel.tiltBrake.enabled = true
-- CRUISE gets the fastest yaw turn-rate and lateral strafe of any mode -- it's the mode built for
-- covering distance fast (rate-command batch, 2026-09-06: real achieved rad/s and blk/s now).
DEFAULTS.modes.CRUISE.feel.headingRate = 1.5
DEFAULTS.modes.CRUISE.feel.swaySpeed   = 10.0
DEFAULTS.modes.CRUISE.gains.yaw.kw     = 0.9
DEFAULTS.modes.CRUISE.gains.sway.ks    = 0.5
-- gains.pitch.kp/caps.pitch inherit the raised PRE base (0.15/0.3) via the deep-copies above --
-- CRU gets the same pitch-authority bump for the same reason (accel trim residual).

DEFAULTS.modes.LDG = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.2, roll = 0.2, yaw = 0.4, sway = 0.3, surge = 0.25 },
  feel  = deep(DEFAULTS.feel),
}
-- Gentle landing feel: slow the achieved rates so approach/descent is precise.
DEFAULTS.modes.LDG.feel.surgeSpeed = 3.0
DEFAULTS.modes.LDG.feel.surgeLead  = 6.0
DEFAULTS.modes.LDG.feel.swaySpeed  = 3.0
DEFAULTS.modes.LDG.feel.climbRate  = 2.5
-- LDG stays a GENTLE landing mode: pin vertical authority to stay off the raised PRE/CRU base.
DEFAULTS.modes.LDG.gains.alt.kp     = 0.02
DEFAULTS.modes.LDG.gains.alt.kd     = 0.15
DEFAULTS.modes.LDG.gains.alt.kv     = 0.04
-- Pin yaw/sway velocity gains and turn rate gentle too -- LDG stays as-tuned; the PRE/CRU bumps
-- must not reach the gentle landing mode.
DEFAULTS.modes.LDG.feel.headingRate = 0.6
DEFAULTS.modes.LDG.gains.yaw.kw     = 0.5
DEFAULTS.modes.LDG.gains.sway.ks    = 0.3
DEFAULTS.modes.LDG.gains.surge.ks   = 0.3
-- LDG pilots/lands gently: no accel-trim residual to fight, and no forward-trim feedforward wanted
-- on the ground -- pin trimGain to 0 (base is now 0.30) and pitch kp back to 0.10 (base is 0.15).
DEFAULTS.modes.LDG.feel.trimGain    = 0
DEFAULTS.modes.LDG.gains.pitch.kp   = 0.16
DEFAULTS.modes.LDG.gains.pitch.kd   = 0.28
DEFAULTS.modes.LDG.gains.roll.kp    = 0.16
DEFAULTS.modes.LDG.gains.roll.kd    = 0.28

DEFAULTS.modes.DRN = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.5, roll = 0.5, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
  feel  = deep(DEFAULTS.feel),
}
-- Drone tilt feel (WASD tilt): keep tiltCap < attLimit (0.6).
DEFAULTS.modes.DRN.feel.tiltRate = 0.8
DEFAULTS.modes.DRN.feel.tiltCap  = 0.5
-- DRN keeps symmetric trim to document intent (pitch/roll ARE its accel+decel). Moot in practice:
-- DRN forces surge demand = 0, so the surge-scaled trim feedforward is 0 anyway; DRN brakes by pilot tilt.
DEFAULTS.modes.DRN.feel.brakeTrim = true
DEFAULTS.modes.DRN.gains.pitch.ki = 0   -- fix #1: DRN flies attitude directly, no leveling integral
DEFAULTS.modes.DRN.gains.roll.ki  = 0
-- DRN pilots pitch directly (no accel residual to fight) -- pin back to 0.10, same reasoning as MAN.
DEFAULTS.modes.DRN.gains.pitch.kp = 0.10
DEFAULTS.modes.DRN.feel.climbRate = 6.0
-- Tilt-brake (fix #3): DRN pilots directly, so enable speed-scaled brake tilt.
DEFAULTS.modes.DRN.feel.tiltBrake.enabled = true

local M = {}

function M.get()
  return deep(DEFAULTS)
end

return M
