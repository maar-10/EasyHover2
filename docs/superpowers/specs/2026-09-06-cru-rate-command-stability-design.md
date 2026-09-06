# CRU rate-command stability & control-feel redesign

**Date:** 2026-09-06
**Branch:** `feat/cru-rate-command-stability`
**Status:** approved (design signed off), ready for implementation plan
**Log:** `eh2 flight log CRU extended test.txt` — carbide paste `cc.lynx.rodeo/18d0824954` (254 s, CRU/CPL)

## Problem (from the 2026-09-06 CRU extended fcslog)

Four reported problems, root-caused against the code and quantified from the log (decoded via
`fcs/bringup/logcodec.lua` delta format — carry-forward `i:value` deltas).

**Headline: the whole flight was a violent vertical limit-cycle.** `heave` pinned at a rail
(≤0.05 or ≥0.85) **63%** of airborne time (`heaveBanded` 49%); `|vSpeed|>10 blk/s` 30% of the
time, `>20` 10%, peaks **+32 / −31 blk/s**; altitude swings up to **86 blocks** in a 20 s window
with `sp_alt` **fixed**. No DAMPED trip, no EMRCVR the whole flight. Every "feel" complaint below
is contaminated by this — the vertical instability is the dominant failure.

### #1 Altitude limit-cycle — a real BUG plus a saturating command model

`sp_alt` is fixed while `alt` swings ±10–19 blocks → a genuine limit-cycle, not a setpoint problem.
Mechanism, confirmed in `D_alt`:

- **The heave-band anti-windup silently disables the altitude DERIVATIVE.** In `fcs/control/pid.lua`,
  `usable = (dt>0) and (dt<=dtMax) and not saturated`, and the D term is computed **only when
  `usable`** (`pid.lua:29-40`). `fcs/schemes/level_flight.lua:28` passes `_heaveSat` (collective hit
  the band last tick) as `saturated`. So **every tick after the collective bands, `D_alt = 0` in the
  actual demand** — the only vertical damping is dead ~63% of the time. In the log `D_alt` sits frozen
  (e.g. −0.863) for ~1.5 s stretches *while `vSpeed` reverses from +6 to −9*. `pid.lua:20-23`'s own
  comment says "the derivative must stay live … that D damping is what arrests the climb" — the
  `saturated` path violates that.
- **The command model saturates the collective on every climb.** CRU `alt.kp=0.045`, `leadCapVert=12`
  → `kp·leadCapVert = 0.54`, which alone rails `heave` against a band only ~0.21 wide below hover.
  The "climb speed ≈ kp·leadCapVert/kd" model assumes *no* saturation; here it's saturated constantly,
  so the loop just bang-bangs between rails. This was latent until the 2026-09-04/05 kp/leadCapVert
  climb-authority bumps started railing the collective on every altitude change.

### #2 Throttle → uncommanded nose-up → climb (confirmed; feeds #1)

`MAIN>0.5`: pitch **mean 0.27 rad (16°), max 0.63 rad (36°)**, above 11° for **61%** of throttle-up;
idle (`MAIN<0.05`) pitch only ~0.05 rad (3°). The body-fixed `MAIN` engine (`fcs/mixer/level_flight.lua:42`)
vectors upward as the nose rises → adds vertical thrust → compounds #1. There is **no acceleration
trim at all** right now: the output feedforward is commented out (`fcs/runtime/loop.lua:87-105`,
`self._ffPitch = 0` at line 106) and `pilot.lua` injects only a *brake* tilt. The pitch loop can't
reject it alone: `kp=0.10` is weak, and the leveling integral barely engages (`I_pitch` max 0.052 <
`iMax=0.10`, gated off when `|pitch|>iBand=0.35`).

### #3 "General instability" = #1 + #2, NOT the attitude integral

The log clears the reintroduced pitch/roll leveling integral of blame: `I_pitch` mean 0.005,
`|pitch|>iBand` only 3% of the time — mostly dormant, not oscillating. No separate fix; #3 resolves
when #1 and #2 are fixed. Verify-only.

### #4 Yaw sluggish + snaps back; strafe underpowered

- **Yaw — architecture.** Held turns run at only ~0.4–0.5 rad/s while the leash builds a **1.0–1.4 rad
  (60–80°) lead that is DISCARDED on release** (the edge-capture snaps `sp_hdg` to current). So a held
  turn under-delivers by that whole lead — "you almost have no effective heading change."
- **Strafe — doubly rate-limited (and unmeasurable here).** Under the vertical chaos `sp_sway` is
  mostly frozen/drifting, so it can't be measured cleanly, but the code is unambiguous: sway is a leash
  slew (`swaySpeed`, `fcs/leash.lua`) **and** a low-gain push (`translate.lua`, `kp=0.2`), so demand
  builds over seconds; LDG pins it hardest (`swaySpeed=2, swayLead=4, caps.sway=0.3`).

## Architecture — "rate while held, position-hold on release"

The failure common to #1 and #4 is that a large **position error** is allowed to build (a leash lead)
and then either saturates the actuator (#1) or is discarded (#4). A **rate command never builds a
position error**. Applied identically to altitude, yaw, and strafe:

- **While the key is held →** command a target *rate* directly (velocity control). Actuator effort is
  bounded by the *rate* error, so it can't rail on a phantom position lead. Faster PRE climb = a bigger
  target rate, not a hotter gain.
- **On release →** capture the current altitude / heading / swayPos and hand off to the **existing**
  position-hold PIDs (`altPid` / `headingPid` / `swayTc`) to hold station. Bumpless: the hold target is
  the measured value at the release tick, so there is no step.

This also **avoids the D-kill path** (which only triggers under saturation), because the held phase
never saturates on a position error and the hold phase sits near its setpoint. The D-kill defect is
**still fixed** in `pid.lua` as cheap hardening for the hold phase.

### Pilot → scheme interface

The pilot's setpoint table carries, per rate-command axis, EITHER a hold target (always present,
captured) OR a rate command (present only while held; `nil` on release):

| Axis | hold field (existing) | rate field (new, nil when released) |
|---|---|---|
| altitude | `sp.altitude` | `sp.climbCmd` (target vSpeed, blk/s) |
| yaw | `sp.heading` | `sp.yawCmd` (target yaw rate, rad/s) |
| strafe | `sp.swayPos` | `sp.strafeCmd` (target lateral vel, blk/s) |

`fcs/input/pilot.lua:update()` sets the rate field while its key is held and clears it + captures the
hold field on release (replacing today's leash-slew + `*StopLead` edge-capture blocks at
`pilot.lua:83-93, 96-111, 120-160, 190-210`). Each scheme axis branches: rate field present → velocity
control; else → position-hold PID. **Surge is NOT rate-commanded** (not in the complaint) — it keeps
its position leash / CRU throttle path unchanged.

### Velocity control laws (held phase)

- **Altitude** (`fcs/schemes/level_flight.lua`): `heave = hover + kv·(climbCmd − vSpeed)`, then the
  existing `heaveMin/heaveMax` band. Optional small velocity integral `kiv` (default 0) to zero the
  steady-state drag error so it *holds* the commanded rate; dial in-world only if the craft undershoots.
  Descend is the same law with a negative `climbCmd`, bounded by `heaveMin`.
- **Yaw** (`fcs/control/heading.lua`): `yawDemand = kw·(yawCmd − yawRate)`.
- **Strafe** (`fcs/control/translate.lua`): `swayDemand = ks·(strafeCmd − swayVel)`.

Each controller gains a `:rate(cmd, meas, dt)` path alongside its existing `:update(...)` hold path;
the scheme calls one or the other per axis based on the pilot's setpoint fields. Keeping both paths in
the same small controller keeps each axis's behavior in one testable unit.

### D-kill defect fix (`fcs/control/pid.lua`)

Split the two gates that are currently conflated in `usable`:

- `dtok = (dt>0) and (dt<=dtMax)` — a bad/stale dt (lag spike) SHOULD skip the derivative.
- Saturation (`saturated`) SHOULD freeze **integration only**, never the derivative.

So: integrate only when `dtok and not saturated and within iBand`; compute D whenever `dtok` (fresh
measurement), regardless of `saturated`. This implements the module's own stated intent and restores
vertical damping during the hold phase's brief band touches.

## Per-mode rate targets (defaults; all live-tunable)

Repurpose the existing rate-named `feel` keys as the achieved-rate targets, retire the lead/stop knobs
(below). Velocity gains `kv/kw/ks` are new per-axis `gains` (starting points; tune in-world).

| Mode | `climbRate` (blk/s) | `headingRate` (rad/s) | `swaySpeed` (blk/s) |
|---|---|---|---|
| **PRE** (base) | 8 | 1.2 (~69°/s) | 6 |
| **CRU** | 12 | 1.5 (~86°/s) | 10 |
| **MAN** | 6 (inherit base 8 → set 6) | 1.2 | 6 |
| **LDG** (gentle, pinned) | 2.5 | 0.6 (~34°/s) | 3 |
| **DRN** | 6 | 1.2 | — (tilt-fly, no strafe) |

DRN keeps `translate=false` (no strafe axis). LDG stays gentle across all three. Exact base-vs-override
placement (base `DEFAULTS`, per-mode `DEFAULTS.modes.*`) mirrors the current
`fcs/io/tuningdefaults.lua` structure; the implementation plan pins each value explicitly so a raised
base can't leak into LDG (the same pin discipline as the 2026-09-04 faster-climb spec).

## Pitch feedforward + modest authority (#2)

**Re-enable** the feedforward in `fcs/runtime/loop.lua:87-105` (uncomment; delete the
`self._ffPitch = 0` override at line 106): `ff = trimDir · trimGain · demands.surge`, keeping its
existing **fade** (`trimFadeStart`/`trimFade`) and **authority cap** (`trimAuthority · caps.pitch`).
`demands.surge` is the correct source — it is the actual commanded forward thrust (throttle in CRU,
surge-PID elsewhere). Direction is nose-**down** on forward accel (`trimDir = −1`).

- **Enable for all modes except LDG.** `trimGain > 0` (calibrated, live-tunable) for PRE/MAN/CRU/DRN;
  `trimGain = 0` for LDG. The `trimGain·demands.surge` form self-scales: it does real work in the modes
  that command forward/MAIN thrust (CRU, PRE) and contributes ~0 in the tilt-fly modes where surge
  demand is near zero (MAN/DRN), so enabling it there is harmless and future-proofs them.
- **Calibration, not a bigger guess.** The old `trimGain=0.35` over-steered because it was uncalibrated.
  Start lower and dial the live-tune row against the measured disturbance (MAIN=1.0 → ~0.27 rad nose-up)
  until hard acceleration holds the nose level.
- **Residual authority:** bump CRU (and PRE) `pitch.kp` 0.10→~0.15 and `caps.pitch` 0.2→~0.3 so the
  leveling loop mops up what the feedforward leaves. Live-tunable.
- **Unchanged:** the pitch/roll leveling integral (`ki=0.05, iBand=0.35`) — cleared by the log.
  `brakeTrim` (the separate "also lean when *braking*" flag) stays as-is: symmetric for CRU/DRN,
  forward-only for PRE/MAN.

## Config / live-tune surface

Authoritative source `fcs/io/tuningdefaults.lua`; BIT/CONFIG rows in `ui/basalt/bitconfig/tuning.lua`
(the paged `buildEditScreen` MODE-FEEL pattern already shipped for the brake curve).

- **Retire** the lead/stop knobs of the old leash model: `leadCapVert`, `altStopLead`, `leadCapHeading`,
  `yawStopLead`, `swayLead`. (Surge keeps `surgeSpeed`/`surgeLead` — not rate-commanded.)
- **Repurpose** `climbRate` / `headingRate` / `swaySpeed` as the achieved-rate targets (new default
  numbers per the table).
- **Add** velocity gains `gains.alt.kv` (+ optional `kiv`), `gains.yaw.kw`, `gains.sway.ks`; per-mode
  `trimGain` (0 for LDG); CRU/PRE `pitch.kp`/`caps.pitch` bumps.
- **Live-tune rows:** add the new rate targets + velocity gains + `trimGain` as BIT/CONFIG MODE-FEEL
  rows; remove the retired ones. Keep the paged `▲/▼` menu working.

**Migration:** a pre-change saved `eh2_tuning.tbl` carries old keys; the `cfgspec` deep-merge ignores
unknown keys and falls back to new defaults. The plan must confirm no retired key silently overrides a
new default, and that a stale saved `leadCapVert`/etc. is inert (not read anywhere post-change).

## Testing (TDD, headless CraftOS-PC)

Failing test first for each unit:

- **`pilot.lua` rate generation** (`tests/test_pilot*.lua`): key held → correct rate field set
  (`climbCmd`/`yawCmd`/`strafeCmd`); release → rate field `nil` AND hold field captured to measured
  (bumpless, no residual lead). One test per axis + the sig/threading path per
  [[feedback-basalt-headless-test-gotchas]] (assert observable setpoints, not geometry).
- **Velocity controllers** (`tests/test_control_terms.lua` / new): converge to target rate from rest;
  hold the rate at steady state; descend bounded by `heaveMin`; yaw/strafe symmetric.
- **`pid.lua` D-kill regression:** with `saturated=true`, the derivative term is still computed and
  non-zero (integral still frozen). Direct guard against the reported bug.
- **Feedforward** (`tests/test_*loop*` / instrument): `ff` scales with `demands.surge`, respects fade +
  authority cap, is 0 for LDG (`trimGain=0`) and > 0 for PRE/MAN/CRU/DRN.
- **Tuning resolution** (`tests/test_tuning_modes.lua`): `tuning.forMode(...)` yields the per-mode rate
  targets, velocity gains, and `trimGain` from the table; LDG pinned gentle.
- Grep the suite for assertions encoding retired keys/old values and update them.

## Build / verify

- Source gate: `bash tests/run_headless.sh` (green).
- Manifest sync after editing `fcs/**`: `bash tools/run_gen.sh`.
- Rebuild dist: `node tools/build.mjs`; dist gate: `bash tests/run_headless_dist.sh` (green).
- e2e green. Standard `src N/0 dist N/0 e2e PASS` gate before anything ships.
- In-world: fly CRU/PRE — confirm the vertical limit-cycle is gone, hard-accel holds the nose level,
  yaw is snappy with a clean stop, strafe responds immediately; then dial the live-tune rows
  (rate targets, `kv/kw/ks`, `trimGain`, CRU pitch kp/caps).

## Sequencing

1. **Altitude** rate-command + D-kill fix (the dominant failure).
2. **Pitch** feedforward + authority (coupled to #1).
3. **Yaw** rate-command.
4. **Strafe** rate-command (re-measure feel in-world after #1 is confirmed).
5. **#3** verify-only.

## Out of scope (noted)

- Surge (forward W) rate-command — not in the complaint; keeps its position leash / CRU throttle path.
- Loop-rate jitter with logging on (~15 Hz, dt spikes) — the known logging-on penalty; separate.
- DRN/MAN/TRK default tuning beyond the rate targets above — deferred (per the tasking note).
