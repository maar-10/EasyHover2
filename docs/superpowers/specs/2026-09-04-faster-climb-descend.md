# Faster climb/descend — vertical authority tuning

**Date:** 2026-09-04
**Branch:** `tune/faster-climb`
**Status:** approved (numbers signed off), ready to implement

## Problem (from the greenhouse-pad fcslog, cc.lynx.rodeo/6dd88eee7e)

Manual climb crawls at ~1 blk/s and holding the climb key for minutes barely helps. Diagnosis
from the log (engaged climb ticks):

- `sp_alt − alt` pins at **8.0** = the `leadCapVert = 8` leash caps the altitude error the PID sees.
- `P_alt` rails at **0.16** (= `kp 0.02 × 8`); `D_alt ≈ −0.15` (= `kd 0.15 × vSpeed`) cancels most of it.
- **heave sits at ~0.27 (≈ hover 0.26), peaks 0.39, `sat_heave` = 0/1683** — the lift thrusters
  NEVER rail. ~55% of vertical authority is unused. NOT thrust-limited.

The steady climb self-limits where P-authority equals D-damping:

> **v_climb ≈ (kp · leadCapVert) / kd = (0.02·8)/0.15 ≈ 1.07 blk/s** — exactly the measured rate.

`climbRate` (the "blocks/s slew") is a red herring: it only moves the setpoint, which the leash
clamps to +leadCapVert within ~2 s. The achieved rate is `kp·leadCapVert/kd`, identical in every
mode (LDG's lower slew doesn't change it), which is why it feels equally slow everywhere.

## Fix — raise vertical AUTHORITY per mode (spend the spare heave)

Lever identities: **steady v ≈ kp·leadCapVert/kd**; **peak heave during accel ≈ hover(0.26) + kp·leadCapVert**
(keep ≲ 0.85 cap). `climbRate` must stay ≥ the target so the setpoint leads. Descent is symmetric
(same alt PID, same `alt − leadCapVert` leash below), so it speeds up by the same factor.

Authoritative source: `fcs/io/tuningdefaults.lua`. The pilot reads `climbRate`/`leadCapVert` from the
per-mode `feel` (via `Pilot:setMode(policy, feel)` → `self.cfg = feel`, `fcs/input/pilot.lua:38`), and
the alt PID is built from the per-mode `gains.alt`. `fcs/input/config.lua` is only the pre-mode boot
default (overridden the instant a flight mode is applied) — leave it.

### Target per mode

| Mode | alt.kp | leadCapVert | alt.kd | climbRate | → steady v | peak heave |
|---|---|---|---|---|---|---|
| **PRE** (base) | 0.02→**0.035** | 8→**10** | 0.15 | 4.5→**5.0** | ~2.3 blk/s | 0.61 |
| **MAN / DRN** | inherit base 0.035 | inherit 10 | 0.15 | inherit 5.0 | ~2.3 blk/s | 0.61 |
| **CRU** | 0.02→**0.045** | 8→**12** | 0.15→**0.08** | 4.5→**12.0** | ~6.8 blk/s | 0.80 |
| **LDG** (pinned) | **0.02** | **8** | **0.15** | 2.5 | ~1.07 (unchanged) | — |

- **CRU is the aggressive tier** (user: "even more"): lower `kd` = livelier/more overshoot on
  level-off; heave briefly rails (~0.80→0.85) while accelerating. Accepted.
- **MAN/DRN "match PRE"**: they inherit the moderate base automatically (they only override tilt feel).
- **LDG must be explicitly pinned** to the pre-change values, because it deep-copies the base *after*
  the base is raised — without pins it would inherit 0.035/10 and stop being gentle.

### Exact edits to `fcs/io/tuningdefaults.lua`

1. Base `gains.alt` (line 20): `kp = 0.02` → `kp = 0.035` (kd/ki/tauD/iMax/iMin/iBand unchanged).
2. Base `feel.climbRate` (line 45): `4.5` → `5.0`.
3. Base `feel.leadCapVert` (line 46): `8.0` → `10.0`.
4. Update the stale iBand comment (line 16): `leadCapVert(8)` → `leadCapVert(10)`.
5. After the CRUISE feel overrides (after line 82), add:
   ```lua
   -- Fast cruise climb/descend (log 2026-09-04: vertical was authority-limited ~1 blk/s with masses of
   -- unused heave). v ~= kp*leadCapVert/kd; peak heave ~= hover + kp*leadCapVert. ~6-7 blk/s here
   -- (peak heave ~0.80, brief rail on accel; lower kd = livelier, more overshoot on level-off).
   DEFAULTS.modes.CRUISE.gains.alt.kp     = 0.045
   DEFAULTS.modes.CRUISE.gains.alt.kd     = 0.08
   DEFAULTS.modes.CRUISE.feel.leadCapVert = 12.0
   DEFAULTS.modes.CRUISE.feel.climbRate   = 12.0
   ```
6. In the LDG section (after line 94, `DEFAULTS.modes.LDG.feel.climbRate = 2.5`), add:
   ```lua
   -- LDG stays a GENTLE landing mode: pin vertical authority to the pre-2026-09-04 base so the
   -- raised base kp/leadCapVert don't apply here (LDG only wants the slow climbRate slew above).
   DEFAULTS.modes.LDG.gains.alt.kp     = 0.02
   DEFAULTS.modes.LDG.gains.alt.kd     = 0.15
   DEFAULTS.modes.LDG.feel.leadCapVert = 8.0
   ```
7. MAN/DRN: no change (inherit moderate base).

## Live tuning

All four knobs are already BIT/CONFIG rows — `feel.climbRate` (CLIMB RATE, 0–20), `feel.leadCapVert`
(VERT LEAD CAP, 0–50), and `gains.alt.kp`/`gains.alt.kd` (ALT axis GAINS screen, 0–5). So CRU can be
fine-tuned in-world with no reboot. No UI changes needed.

## Testing (TDD, `tests/test_tuning_modes.lua`)

Assert the resolved per-mode values via `tuning.forMode(...)`:
- PRECISION: `gains.alt.kp == 0.035`, `feel.leadCapVert == 10`, `feel.climbRate == 5`, `gains.alt.kd == 0.15`.
- CRUISE: `gains.alt.kp == 0.045`, `gains.alt.kd == 0.08`, `feel.leadCapVert == 12`, `feel.climbRate == 12`.
- MAN and DRN: `gains.alt.kp == 0.035`, `feel.leadCapVert == 10`, `feel.climbRate == 5` (inherit base).
- LDG (gentle preserved): `gains.alt.kp == 0.02`, `gains.alt.kd == 0.15`, `feel.leadCapVert == 8`,
  `feel.climbRate == 2.5`.

Also: grep the test suite for any existing assertion encoding the OLD base values (`0.02` alt kp,
`4.5` climbRate, `8.0`/`8` leadCapVert) and update it to the new values (like the trim task's
row-count bumps). Manifest-sync gate must stay green after editing `fcs/**` (run `bash tools/run_gen.sh`).

## Build / verify

Source gate `bash tests/run_headless.sh`, rebuild dist `node tools/build.mjs`, dist gate
`bash tests/run_headless_dist.sh` — all green. Then in-world: fly PRE and CRU climbs/descents, confirm
the faster rates and acceptable overshoot; fine-tune CRU (`ALT KP`/`ALT KD`/`VERT LEAD CAP`/`CLIMB RATE`)
live if needed.

## Out of scope (noted)

- Loop-rate jitter (log: dt mean 65 ms, max 309 ms, ~15 Hz) — the known logging-on penalty; separate.
