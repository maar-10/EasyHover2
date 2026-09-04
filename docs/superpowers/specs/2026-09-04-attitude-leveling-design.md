# Attitude leveling — roll + pitch integral (fix #1)

**Date:** 2026-09-04
**Branch:** `fix/attitude-leveling`
**Status:** approved design, ready for implementation plan
**Roadmap:** `docs/superpowers/plans/2026-09-04-cru-flight-fixes-roadmap.md` (fix #1)

## Problem

From the CRU extended flight log: the craft settles into **5–24° standing banks and holds them for
dozens of seconds** instead of leveling (~60 s of 398 s engaged in sustained banks >5°), plus rough
leveling / wobble. Root cause: **`ki_roll = ki_pitch = 0`** (`tuningdefaults.lua:24-25`). A P+D-only
attitude loop cannot cancel a *steady* disturbance (lateral CoM/lift asymmetry) — it settles into an
equilibrium bank where the tiny P output balances the disturbance and never grows. Evidence: in a 17 s
hold at −7.8°, `sp_roll=0`, `sat_roll=0` (huge unused authority), roll demand a constant `≈0.014`,
`D_roll≈0`. Textbook missing-integral steady-state error.

Secondary: `sat_sway` railed 53% of the flight fighting the lateral slide the banks cause; expected to
drop sharply once the craft actually levels (re-measure after this lands, don't tune sway yet — fix #7).

## Design — add a leveling integral (config only)

`fcs/control/pid.lua` already implements conditional-integration anti-windup (`ki` + `iBand` + `iMax/iMin`),
identical to the altitude loop; the loop already **freezes integration when grounded** (`grounded → freeze`,
`loop.lua`) and **per-axis on saturation** (`sat.pitch/roll`). So this is purely populating
`gains.roll` / `gains.pitch` — no code change to the PID, scheme, or loop.

**How `iBand` gives the desired behavior:** the integral only accumulates while `|error| ≤ iBand`, so it
cancels a *standing* bank/pitch (levels to the setpoint) but never winds up during a hard maneuver
(error outside the band → left to P/D). It is **not a cap** — `attLimit` / `caps.pitch/roll` still handle
tip-over; the integral only removes steady-state error and never restricts pilot input.

### Per-mode aggressiveness

| Mode(s) | intent | `ki` (roll & pitch) | `iBand` | `iMax/iMin` |
|---|---|---|---|---|
| **PRE / LDG / CRU** (level-hold) | aggressive — the craft should not pitch/roll; level to ~0 | **0.05** | **0.35 rad** (~20°) | **±0.10** |
| **MAN / DRN** (tilt) | pilot flies attitude directly; high tolerance, don't auto-trim the axis being flown | **0** (keep today's pure P+D, auto-level on release) | n/a | n/a |

- `kp` unchanged (0.10) for now — isolate the integral's effect; tune from there in-world if needed.
- `iBand 0.35 rad` covers the observed 5–24° standing banks while treating a >20° maneuver as
  "maneuvering, don't auto-trim". `iMax ±0.10` is half the roll cap — the measured disturbance was only
  ~0.014, so this is ample headroom and cannot over-authority.

### Trim interaction (accurate; full redesign deferred to #3)

Both trim modifications of pitch — the **forward-acceleration trim** (nose-down, UI-switchable, keeps
the craft pointed forward under main-thruster accel) **and** the **CRU brake pitch-up (aerobrake)** —
are deliberate pitch commands, and both are true trim-vs-leveling cases. This spec does **not** rework
the trim; it stays the output feed-forward built in the flip-guard / brake-no-pitch work. Consequence
during forward acceleration in CRU/PRE/LDG: the new aggressive pitch integral will itself cancel the
forward-thrust reaction (steady disturbance) and hold the craft level — largely taking over the job the
forward-accel trim's feed-forward does today, making that feed-forward partly redundant/overlapping. Net
result is still "craft stays level during acceleration," which is the goal, so no #1 change is needed —
but the clean reconciliation (trim/aerobrake **shaping the pitch setpoint**, option A, so the loop holds
the commanded lean instead of the two fighting) is **fix #3's** design. The CRU brake pitch-up is weak/
broken today (log: `ff_pitch=0` during braking) and is rebuilt in #3.

### Exact edits — `fcs/io/tuningdefaults.lua`

1. Base `gains.pitch` (line 24): `{ kp = 0.10, ki = 0, kd = 0.22, tauD = 0.2 }` →
   `{ kp = 0.10, ki = 0.05, kd = 0.22, tauD = 0.2, iMax = 0.10, iMin = -0.10, iBand = 0.35 }`
2. Base `gains.roll` (line 25): same shape →
   `{ kp = 0.10, ki = 0.05, kd = 0.22, tauD = 0.2, iMax = 0.10, iMin = -0.10, iBand = 0.35 }`
   (PRE reads top-level; CRUISE/LDG deep-copy base → inherit the aggressive integral.)
3. MAN override (after the MAN feel overrides): pin attitude integral OFF —
   `DEFAULTS.modes.MAN.gains.pitch.ki = 0` and `DEFAULTS.modes.MAN.gains.roll.ki = 0`.
4. DRN override (after the DRN feel overrides): same —
   `DEFAULTS.modes.DRN.gains.pitch.ki = 0` and `DEFAULTS.modes.DRN.gains.roll.ki = 0`.

(No change to `pid.lua`, `level_flight.lua`, `loop.lua`, or `flight.lua`.)

## Live tuning

`ki`/`kd`/`kp` for pitch & roll are BIT/CONFIG GAINS-axis rows (0–5 range) — strength dialable in-world
with no reboot. `iBand`/`iMax` ship as defaults (not rows).

## Testing

**`tests/test_tuning_modes.lua`:**
- PRE/CRU/LDG resolve `gains.pitch.ki == 0.05`, `gains.roll.ki == 0.05`, `iBand == 0.35`, `iMax == 0.10`.
- MAN/DRN resolve `gains.pitch.ki == 0` and `gains.roll.ki == 0` (pinned).

**`tests/test_pid.lua` (or `test_scheme_*`):** a behavioral test proving integral leveling — drive the
roll PID with a *sustained* error (constant `meas` offset, `sp=0`) across several ticks and assert the
output magnitude **grows** (integral accumulates) and would drive the error toward zero, while `ki=0`
holds a constant P-only output. Also assert `iBand` gates it: an error beyond `iBand` does **not**
accumulate (anti-windup), and grounded/saturated freezes it (existing behavior — assert it still holds).

**Golden:** `tests/modes_golden_data.lua` — the golden battery runs the scheme with base gains; adding
`ki`/`iBand` changes integral-bearing cases only on later ticks. The golden does a single `:update`
after `:reset` (integral starts at 0), so first-tick outputs are unchanged — **verify no golden update
is needed**; if any case shifts, update it with the arithmetic shown.

## Build / verify

Manifest regen (`tools/run_gen.sh`), source gate, dist rebuild (`node tools/build.mjs`), dist gate — all
green. In-world: confirm the 5–24° stuck banks level within ~2 s and the sway rail drops; then re-assess
whether roll/pitch `kp` or `ki` need a live nudge.

## Out of scope (this fix)
- Trim-as-setpoint rework / CRU aerobrake / forward-accel-trim role → **fix #3**.
- Sway tuning (#7), yaw rate (#5), climb (#8), snappy release (#9), loop jitter (deferred).
