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
    -- iBand: conditional-integration anti-windup. The vertical leash lets the setpoint lead the craft
    -- by up to leadCapVert(10) blocks during a climb, so err_alt is large the whole climb WITHOUT heave
    -- railing -- the integrator used to wind to iMax and then float the craft past the target (a long,
    -- oscillatory drop after climb). Integrate only within 3 blocks of the setpoint: P/D drive the
    -- climb, I only trims the steady-state hover residual near the target.
    -- Vertical authority (2026-09-04): steady climb v ~= kp*leadCapVert/kd. Base kp raised 0.02->0.035
    -- (+leadCapVert 8->10) for ~2.3 blk/s in PRE/MAN/DRN; the log showed ~55% unused heave. CRUISE
    -- overrides these harder below; LDG pins them back to stay a gentle landing mode.
    alt   = { kp = 0.035, ki = 0.01, kd = 0.15, tauD = 0.35, iMax = 0.3, iMin = -0.3, iBand = 3.0 },
    pitch = { kp = 0.10, ki = 0, kd = 0.22, tauD = 0.2 },
    roll  = { kp = 0.10, ki = 0, kd = 0.22, tauD = 0.2 },
    yaw   = { kp = 0.95, ki = 0, kd = 1.8 },   -- kd 1.0->1.8: damp the heavy craft's release ring
    sway  = { kp = 0.2, ki = 0, kd = 0.25 },
    surge = { kp = 0.15, ki = 0, kd = 0.25 },
    heaveMin = 0.05,
    heaveMax = 0.85,
  },
  pwmPeriod = 0.3,
  caps = { pitch = 0.2, roll = 0.2, yaw = 0.6, sway = 0.9, surge = 1.0 },
  -- Oscillation detector: a crossing counts only past +/-deadband (rad) so level-flight sensor
  -- dither can't false-trip; a trip auto-releases after calmTime (s) of calm. Per-axis (pitch/roll).
  osc = { window = 1.0, minChanges = 6, deadband = 0.02, calmTime = 1.0 },
  dtMax = 0.5,
  attLimit = 0.6,
  com = { fwd = 0, right = 0, spanFwd = 0, spanRight = 0 },
  park = { groundClear = 1.0, parkDriftEps = 0.15, parkTiltBand = 0.12 },
  profile = { climbHeight = 6, climbRate = 0.6, holdTime = 20, descendRate = 0.7,
              landEps = 0.4, watchdog = 60, overshootMargin = 2, leadCap = 1.0 },
  feel = {
    headingRate    = 2.2,
    leadCapHeading = 0.45,   -- 0.70->0.35 killed the overshoot; nudged to 0.45 for a bit more turn speed
    yawStopLead    = 0.15,   -- s of yaw-rate led into the release capture; LOWER = harder stop

    climbRate      = 5.0,
    leadCapVert    = 10.0,
    surgeSpeed     = 10.0,
    surgeLead      = 20.0,
    swaySpeed      = 5.0,
    swayLead       = 10.0,

    climbRampTime  = 1.0,   -- lift ramp: hold time to reach full climbBoost (rampable climb, all modes)
    climbBoost     = 2.0,   -- sustained-hold climb rate multiplier (tap = 1x, hold ramps to 1+boost)
    trimGain       = 0.35,  -- forward-trim feedforward gain: demands.pitch += trimDir*trimGain*demands.surge
    -- Flip-guard bounds (spec 2026-09-04): fade the trim out as the craft departs level, and cap the
    -- feedforward at a fraction of caps.pitch so it can never starve the pitch stabilizer.
    trimFadeStart  = 0.25,  -- rad: full trim below this |pitch| (normal accel tilt stays fully assisted)
    trimFade       = 0.6,   -- rad: trim fully faded to 0 by this |pitch| (== attLimit)
    trimAuthority  = 0.4,   -- max fraction of caps.pitch the feedforward may consume
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
-- Surge-throttle feel (CRUISE): W ramps up, release holds, S ramps down; 0..1 of MAIN.
DEFAULTS.modes.CRUISE.feel.cruiseThrottleRate = 1.0
DEFAULTS.modes.CRUISE.feel.cruiseThrottleMax  = 1.0
-- Fast cruise climb/descend (log 2026-09-04: vertical was authority-limited ~1 blk/s with masses of
-- unused heave). v ~= kp*leadCapVert/kd; peak heave ~= hover + kp*leadCapVert. ~6-7 blk/s here
-- (peak heave ~0.80, brief rail on accel; lower kd = livelier, more overshoot on level-off).
DEFAULTS.modes.CRUISE.gains.alt.kp     = 0.045
DEFAULTS.modes.CRUISE.gains.alt.kd     = 0.08
DEFAULTS.modes.CRUISE.feel.leadCapVert = 12.0
DEFAULTS.modes.CRUISE.feel.climbRate   = 12.0

DEFAULTS.modes.LDG = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.2, roll = 0.2, yaw = 0.4, sway = 0.3, surge = 0.25 },
  feel  = deep(DEFAULTS.feel),
}
-- Gentle landing feel: slow the setpoint-ramp speeds so approach/descent is precise.
DEFAULTS.modes.LDG.feel.surgeSpeed = 3.0
DEFAULTS.modes.LDG.feel.surgeLead  = 6.0
DEFAULTS.modes.LDG.feel.swaySpeed  = 2.0
DEFAULTS.modes.LDG.feel.swayLead   = 4.0
DEFAULTS.modes.LDG.feel.climbRate  = 2.5
-- LDG stays a GENTLE landing mode: pin vertical authority to the pre-2026-09-04 base so the raised
-- base kp/leadCapVert don't apply here (LDG only wants the slow climbRate slew above).
DEFAULTS.modes.LDG.gains.alt.kp     = 0.02
DEFAULTS.modes.LDG.gains.alt.kd     = 0.15
DEFAULTS.modes.LDG.feel.leadCapVert = 8.0

DEFAULTS.modes.DRN = {
  gains = deep(DEFAULTS.gains),
  caps  = { pitch = 0.5, roll = 0.5, yaw = DEFAULTS.caps.yaw, sway = DEFAULTS.caps.sway, surge = DEFAULTS.caps.surge },
  feel  = deep(DEFAULTS.feel),
}
-- Drone tilt feel (WASD tilt): keep tiltCap < attLimit (0.6).
DEFAULTS.modes.DRN.feel.tiltRate = 0.8
DEFAULTS.modes.DRN.feel.tiltCap  = 0.5

local M = {}

function M.get()
  return deep(DEFAULTS)
end

return M
