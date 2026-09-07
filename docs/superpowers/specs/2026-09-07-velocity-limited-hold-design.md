# Velocity-limited position hold (sway & surge)

**Date:** 2026-09-07
**Status:** Approved — ready for implementation plan
**Branch:** `feat/velocity-limited-hold`

## Problem

Hover flight log `cc.lynx.rodeo/dcc6b215c6` (took off in LDG, held a hover): the
lateral (**sway**) position-hold diverges into a **growing oscillation** —
`swayPos` 1.6 → 3.2 → 8.5 → 16.5 blocks at ~0.65 Hz, `swayVel` to ±3.7 blk/s.
It never trips DAMPED. Surge (fore/aft) is comparatively stable in this flight,
but shares the identical control structure and the same latent weakness.

## Root cause

The sway/surge hold is a saturating PD on a double integrator
(`fcs/control/translate.lua` `:update`): `out = kp·(sp−pos) − kd·vel`, then the
mixer clamps the output to `caps.sway` (LDG = 0.3 duty).

1. **Unbounded position error → runaway P.** With `kp=0.2`, just 1.5 blocks of
   drift demands the entire 0.3 cap; the craft reached 8+ blocks, so the raw
   demand hit −1.97 — **6× the cap**. `sat_sway` railed almost continuously.
2. **Saturation drowns the damping term.** Once `|kp·posErr|` ≫ cap, the
   `−kd·vel` term no longer changes the output's sign — the loop degrades to
   **bang-bang on the sign of position error**.
3. **Loop delay pumps energy.** Bang-bang + the loop period (~57 ms median, tail
   to 270 ms) + the 0.3 s PWM actuator period (≈4–5 ticks) delays each switch
   past the zero crossing → energy added every cycle → **amplitude grows**, and
   velocity (momentum) grows unbounded with it.
4. **DAMPED never trips** because the oscillation detector watches pitch/roll
   attitude only (deadband 0.02 rad); this is a translation oscillation with
   roll staying within ±0.1 rad — the detector is blind to sway/surge.

**Regression link:** the sway PD gains did not change, but the rate-command
batch (`ee2ff61`, 2026-09-06) **retired the `swayLead` leash** that previously
bounded the hold correction. The new "hold the captured position directly" path
has no bound, so P runs away. Surge kept its `leash.step` (bounded to
`surgeLead`), which is why surge survived — the same protection sway lost.

## Design

Replace the saturating PD hold with a **two-stage velocity-limited cascade**.

### Control law (`fcs/control/translate.lua`)

```
posErr    = sp - pos
velTarget = clamp(ka * posErr, -vmax, +vmax)   -- outer: position → bounded velocity target
output    = ks * (velTarget - vel)             -- inner: velocity → duty (reuses ks)
```

- **Inner loop** is a P-controller on velocity (a single integrator): it cannot
  overshoot velocity, so **actual speed never exceeds `vmax`**.
- **Bounded momentum** ⇒ the craft can always arrest within its decel authority
  ⇒ the diverging bang-bang is structurally impossible.
- **Near the target** it behaves like a gentle PD: effective `kp = ks·ka`,
  effective `kd = ks`. **Far out** it simply caps the approach speed at `vmax`.
- **Stateless** — no integrator; nothing to wind up, no `reset()` needed for the
  hold path.

**Bumpless by construction:** on strafe-key release the pilot captures
`sp.swayPos = meas.swayPos`, so `posErr=0 → velTarget=0 → output = −ks·vel`,
which brakes residual strafe velocity smoothly to a stop, then holds.

### Gain surface

Per axis, per mode, the hold uses exactly two gains plus a speed cap:

| Param | Meaning | Source |
|-------|---------|--------|
| `ka`  | position → velocity-target stiffness (new) | `gains.sway.ka` / `gains.surge.ka` |
| `ks`  | velocity-target → duty (reused; already on sway) | `gains.sway.ks` / `gains.surge.ks` |
| `vmax`| max approach/return speed | `feel.swaySpeed` / `feel.surgeSpeed` (no new knob) |

`kp` and `kd` become meaningless for the hold and are **dropped** from the
sway/surge gain records. `vmax` reuses the mode's existing strafe/surge speed so
the auto-return-to-station never moves faster than a pilot strafe; it is carried
to the scheme on the setpoint table (`sp.swayVmax` / `sp.surgeVmax`).

### Starting defaults (tuned in-world afterward)

| Mode | sway `ka` | sway `ks` | sway `vmax` (=swaySpeed) | surge `ka` | surge `ks` | surge `vmax` (=surgeSpeed) |
|------|-----------|-----------|--------------------------|------------|------------|----------------------------|
| base/PRE | 1.0 | 0.4 | 6.0 | 1.0 | 0.4 | 10.0 |
| CRUISE   | 1.0 | 0.5 | 10.0 | 1.0 | 0.4 | 10.0 |
| LDG      | 1.0 | 0.3 | 3.0 | 1.0 | 0.3 | 3.0 |
| MAN/DRN  | inherit base (deep copy) | | | | | |

(`surge` gains previously had no `ks`; it gains one here. `surge` had no `ka`;
it gains one. MAN/DRN inherit the base record via the existing deep-copy; DRN
forces `translate=false` so its hold is moot in practice.)

### Scope of edits

- **`fcs/control/translate.lua`** — add `hold(sp, pos, vel, vmax)` (the cascade);
  rewrite `terms()` so the log's `P_/D_sway`,`P_/D_surge` still reconstruct
  (`P = ks·velTarget`, `I = 0`, `D = −ks·vel`, sum == output); retire the old
  `update()` (no production caller remains after the scheme switch).
- **`fcs/schemes/level_flight.lua`** — sway and surge hold branches call
  `hold(...)` instead of `update(...)`; read `vmax` from the setpoint
  (`sp.swayVmax` / `sp.surgeVmax`), with a sane fallback when absent.
- **`fcs/input/pilot.lua`** — publish `sp.swayVmax = feel.swaySpeed` and
  `sp.surgeVmax = feel.surgeSpeed` every tick (including the hold early-return
  path) so the value is always present.
- **`fcs/io/tuningdefaults.lua`** — sway/surge gain records become `{ ks, ka }`
  (drop `kp`,`kd`); per-mode `ks`/`ka` overrides per the table above.
- **`fcs/io/cfgspec.lua`** — sway/surge tunable descriptors → `ka`,`ks` (drop
  `kp`,`kd`); keep the live-write path intact.
- **`ui/basalt/bitconfig/tuning.lua`** — live-tune rows for sway/surge → `ka`,`ks`.

### Reused / untouched

- The pilot **rate-command** path (`translate.lua :rate` = `ks·(cmd−vel)`) is
  unchanged, so active strafing feel is identical; only the hold changes.
- Surge's pilot leash (`leash.step`) stays as-is — it now sits under the cascade
  as belt-and-suspenders (bounds setpoint error; cascade bounds velocity).

## Testing

Unit (`fcs/control/translate.lua`):
- `hold()` clamps the velocity target to `±vmax`.
- From a large displacement the response **converges monotonically without
  overshoot** (regression guard for the divergence).
- `posErr = 0` ⇒ `output = −ks·vel` (pure velocity braking).
- Stateless: repeated `hold()` calls need no `reset()`; no hidden accumulation.
- `terms()` reconstructs `{P,I,D}` matching `hold()`'s output exactly.

Scheme (`fcs/schemes/level_flight.lua`):
- A large sway displacement in position-hold yields a **bounded, decaying**
  demand sequence (never the growing/railed pattern from the log).
- `vmax` sourced from the setpoint is honored; fallback when `sp.swayVmax` nil.

Regression: existing FCS/scheme/pilot suites stay green; dist rebuild + e2e.

## Out of scope (deferred)

- **Translation-axis DAMPED detector** — a safety net so any future runaway
  trips DAMPED instead of drifting. Deferred: the velocity-limited hold should
  make the divergence impossible; add the net later only if in-world testing
  shows a need.
- Loop-rate / PWM-period changes — the ~15 Hz jittery loop under logging is a
  co-factor but the fix is largely rate-independent; not touched here.

## Owed after merge

In-world verification and tuning of `ka`/`ks`/`vmax` per mode (LDG hover first,
then PRE/CRU); confirm a stable hover before resuming the broader flight-tuning
pass.
