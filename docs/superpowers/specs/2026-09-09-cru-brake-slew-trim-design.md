# CRU high-speed braking: tilt-slew + trim-magnitude fix

Date: 2026-09-09
Status: design approved (brainstorm), ready for plan
Batch: **A/B only** — prevention. Decouple-FF fade and EMRCVR rebuild (C/D) are a
separate follow-up batch, explicitly out of scope here.

## Problem (from flight log cc.lynx.rodeo/56bf2651ec)

Braking from high forward speed in CRU departed twice. Confirmed from the log +
source (angles below are converted from the log's **radians**):

- On throttle-down the tilt-brake commands a nose-up pitch setpoint up to
  `maxAngle` (30°). Because the setpoint is applied as a **step**, and the
  leveling loop's damping is crippled at the high-speed loop rate (~8-11 Hz, dt
  spikes to 200 ms), the achieved pitch **overshoots massively**:
  - Event 1: `sp_pitch = 29°` chased to **69°** (138% overshoot) → stayed under
    the 75° EMRCVR trip → self-recovered.
  - Event 2: overshoot crossed **75° = `emrcvr.tripAngle` (1.309 rad)** →
    EMRCVR latched → (EMRCVR's own failure to arrest an inverted/spinning tumble
    is the C/D batch) → 167-block fall into a river.
- Separately, the **forward-accel trim** (nose-down FF, `brakeTrim`/`trimGain`)
  is **too harsh**: it holds the craft at a steep nose-down lean during
  acceleration. The trim's *job* is correct (it stops the nose pitching up under
  forward thrust); only its *magnitude* is wrong.

Root enabler (loop-rate collapse at high speed) is **not** fixed directly this
batch; the slew limit is chosen specifically so the brake is *tolerant* of a low,
jittery loop rate without depending on the `dt` signal being trustworthy.

## Scope

**In:**
- (A) Fixed-rate **slew limiter** on the tilt-brake pitch/roll setpoint so the
  leveling loop can track it without overshooting the commanded brake angle.
- (B) **Reduce the forward-accel trim magnitude** while keeping its reaction
  time / fade behaviour identical.

**Out (next batch — do not touch here):**
- (C) Decouple-FF (`setDecouple`) pitch/roll fade.
- (D) EMRCVR rebuild (spin arrest, active drift-kill).
- Any change to `caps.pitch`/`caps.roll` (user: current caps are fine), to
  `tiltBrake.maxAngle`/`buttonMax`, or to the trim fade params
  (`trimFadeStart`/`trimFade`).

## Design

### A. Brake tilt slew limiter (`fcs/input/pilot.lua`)

The tilt-brake angle is produced in `Pilot:_brakeSetpoint` (via `brake.angle` /
`brake.vector`) and becomes `sp.pitch`/`sp.roll` in `Pilot:update`. Today it is
applied instantly. Add a per-axis first-order slew on the **brake contribution
only** (the pilot's manual `self.tilt` already has its own `tiltRate` ramp and is
untouched).

- New state on the Pilot: `self.brakeTilt = { pitch = 0, roll = 0 }`.
  Reset to `{0,0}` everywhere `self.tilt` is reset: `new()`, `reset()`, `setMode()`.
- In `Pilot:update(dt, held, meas)`, after computing the raw brake vector
  `(bpRaw, brRaw)` from `_brakeSetpoint`, slew the stored `brakeTilt` toward it:
  ```
  local rate = (self.cfg.tiltBrake and self.cfg.tiltBrake.slewRate) or math.huge
  local step = rate * dt                       -- dt==0 (overrun) => no move, matches loop dt-discipline
  self.brakeTilt.pitch = approach(self.brakeTilt.pitch, bpRaw, step)
  self.brakeTilt.roll  = approach(self.brakeTilt.roll,  brRaw, step)
  local bp, br = self.brakeTilt.pitch, self.brakeTilt.roll
  ```
  where `approach(cur, target, step)` moves `cur` toward `target` by at most
  `step` (clamped), i.e. `cur + clamp(target-cur, -step, step)`.
- Use the slewed `(bp, br)` in **both** branches of the existing setpoint code:
  - `policy.tilt` true (MAN/DRN): `sp.pitch, sp.roll = self.tilt.pitch + bp, self.tilt.roll + br`
  - else (CRU/PRE/LDG): `sp.pitch, sp.roll = bp, br`
- **Symmetric**: the same rate limits ramp-up (engage) and ramp-down (release /
  as speed bleeds off and the target angle shrinks). One knob, both directions.
- **Fallback**: `slewRate` nil ⇒ `math.huge` ⇒ instant (legacy). Real flight
  always has the key (added to defaults); tests that omit it keep current
  behaviour. A **pre-existing saved `eh2_tuning.tbl` must be reloaded from DEFAULT
  in-world** to gain the new key — standard EH2 tuning gotcha, called out in OWED.

Direction note: `brake.vector` returns pitch/roll whose *direction* opposes the
drift and rotates as the craft yaws. Slewing pitch and roll **independently** is
correct — each component ramps through zero on a sign flip; magnitude
`sqrt(p²+r²)` is no longer exactly `theta` mid-ramp, which is fine (it is the
*rate of onset* we are bounding, not the final geometry).

### B. Trim magnitude reduction (`fcs/io/tuningdefaults.lua`)

Pure tuning change to the default `feel`. Mechanism, fade, and reaction time are
unchanged — only the magnitude knobs move. First estimates (TUNE in-world):

| knob            | old   | new (first est.) | effect                                    |
|-----------------|-------|------------------|-------------------------------------------|
| `trimGain`      | 0.30  | **0.18**         | less nose-down FF per unit surge demand   |
| `trimAuthority` | 0.40  | **0.30**         | lower hard cap (`authority * caps.pitch`) |

Unchanged: `trimFadeStart` (0.25), `trimFade` (0.6), `brakeTrim` per-mode flags,
`caps.*`. LDG already pins `trimGain=0` and is unaffected. MAN/DRN inherit via the
deep-copies (same as today); confirm no per-mode override needs re-pinning.

### Config / tuning surface

- Add `slewRate = 0.3` (rad/s, first estimate) to `DEFAULTS.feel.tiltBrake` in
  `fcs/io/tuningdefaults.lua`, so it deep-copies into every mode's `feel.tiltBrake`
  alongside `engageSpeed`/`satSpeed`/`maxAngle`/`buttonMax`. Same tunability path
  as those (edit default + reload; it is not an individually live-editable
  BIT/CONFIG field, matching the rest of the `tiltBrake` block).
- `flight.lua` already loads `feel` into the pilot via `setMode`, so `tiltBrake`
  (and its new `slewRate`) reaches `Pilot.cfg` with no wiring change. Verify.

## Testing (TDD, headless via `bash tests/run_headless.sh`)

Extend existing suites; assert observable state, not geometry getters.

- `test_pilot_modes.lua` / new cases:
  - **Slew ramps, never steps**: CRU, engage brake at high `surgeVel`; across the
    first few `update()` ticks `sp.pitch` increases by ≤ `slewRate*dt` per tick
    (never jumps to `maxAngle` in one tick).
  - **Slew converges**: held long enough, `sp.pitch` reaches `brake.angle(s)`.
  - **Ramp-down**: after disengage, `sp.pitch` returns toward 0 bounded by the
    same rate.
  - **dt==0 holds**: an overrun tick moves the brake tilt by 0.
  - **nil slewRate ⇒ legacy instant** (guards existing behaviour / other tests).
  - **MAN sum intact**: brake tilt still sums onto `self.tilt` (slewed), pilot
    manual tilt path unchanged.
- `test_loop_trim.lua`: same-shape FF, lower magnitude — for a fixed
  `demands.surge`, the reduced `trimGain`/`trimAuthority` produce a smaller (but
  same-sign, same-fade) `ff_pitch`; cap = `trimAuthority*caps.pitch`.
- `test_tuningdefaults.lua` / `test_tuning_modes.lua`: new default values present
  and propagated to CRU/MAN/DRN `feel.tiltBrake.slewRate`; LDG `trimGain` still 0.
- Full suite green (`test_brake.lua`, `test_scheme_cruise.lua`, `test_flight_*`,
  `test_pilot_drift.lua` regressions).

## Risks / OWED

- **First-estimate values**: `slewRate=0.3`, `trimGain=0.18`, `trimAuthority=0.30`
  are starting points. OWED: in-world verify (brake no longer overshoots its
  commanded angle; accel lean less harsh) and tune.
- **Saved-tbl gotcha**: the in-flight craft runs a saved `eh2_tuning.tbl`; these
  default changes only take effect after a DEFAULT reload (or re-save) in-world.
- **Loop-rate collapse** remains the underlying enabler and is untouched; the slew
  is the mitigation. If overshoot persists even slewed, revisit loop-rate as its
  own track.

## Files touched

- `fcs/input/pilot.lua` — brake-tilt slew state + limiter.
- `fcs/io/tuningdefaults.lua` — `feel.tiltBrake.slewRate`; reduced `trimGain`/`trimAuthority`.
- tests: `test_pilot_modes.lua`, `test_loop_trim.lua`, `test_tuningdefaults.lua`
  / `test_tuning_modes.lua` (extend).
