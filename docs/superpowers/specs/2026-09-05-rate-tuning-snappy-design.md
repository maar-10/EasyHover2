# Rate tuning + snappy release (fix #4–#9)

**Date:** 2026-09-05
**Branch:** `feat/rate-tuning-snappy`
**Status:** approved design, ready for implementation plan
**Roadmap:** `docs/superpowers/plans/2026-09-04-cru-flight-fixes-roadmap.md` (fixes #5–#9; #4 = no action)
**Follows:** fix #1 (attitude leveling, shipped), fix #3 (CRU braking, shipped), brake-tune scroll menu (shipped).

## Problem (from the CRU extended flight report)

- **#5 Yaw too slow** — peak yaw rate only ~17°/s; `leadCapHeading` caps the steady turn rate.
- **#6 Yaw "steers back"** — the yaw release-capture exists but still overshoots the release heading.
- **#7 CRU strafe slow** — CRU `swaySpeed/swayLead` too low.
- **#8 PRE climb/descend slow** — base vertical authority modest.
- **#9 Climb bounces on release** — there is **no altitude release-edge capture**: while held, `sp.altitude`
  leads by up to `leadCapVert`; on release that lead persists and the craft climbs it out → overshoot →
  pulled back → bounce. (Yaw has this capture; altitude doesn't.)
- **#4 Speed governor** — not wanted; no action.

**Scope:** LDG stays exactly as it flies today (operator: "LDG feels good") — pinned wherever a base
change would otherwise touch it. PRE/MAN/CRU/DRN get the yaw + snappy changes; PRE/MAN/DRN get the
faster base climb; CRU gets the strafe bump + fastest yaw. All values live-tunable in BIT/CONFIG.

## Design

### #9 — Altitude release-edge capture (new mechanism, `fcs/input/pilot.lua`)

Mirror the yaw release-edge capture (`pilot.lua:158-163`). Track a `climbWasHeld` edge flag; on the tick
the pilot releases climb/descend (`ld == 0` after being non-zero), snap the altitude setpoint to the
current altitude plus a small predictive stop-lead:

```lua
-- Altitude release-edge capture (fix #9): on release of climb/descend, drop the leadCapVert lead and
-- snap sp.altitude to current + a small predictive stop (altStopLead * vSpeed), so the craft holds the
-- altitude where you released instead of climbing the lead out (the bounce). Mirrors the yaw capture.
local climbActive = (ld ~= 0)
...
if climbActive then
  self.climbWasHeld = true
elseif self.climbWasHeld then
  sp.altitude = (meas.altitude or sp.altitude) + (c.altStopLead or 0) * (meas.vSpeed or 0)
  self.climbWasHeld = false
end
```

- Placed alongside the yaw capture near the end of `Pilot:update`. `ld` is the existing climb dir
  (`dirOf(held,"down","up")`, `pilot.lua:73`); reference it (don't recompute).
- `meas.vSpeed` and `meas.altitude` are already provided each tick.
- Clear `self.climbWasHeld` in `Pilot:reset` and `Pilot:setMode` (alongside the existing
  `self.yawWasHeld = false` resets, `pilot.lua:31,39`), so a disengage/mode-switch can't strand it.
- New `feel.altStopLead` (see defaults). All modes (climb is universal).
- Composes with the alt integral windup fix (`iBand=3.0`): the capture snaps `sp.altitude` to ≈current,
  so `err_alt` is small on release → integrator behaves.

### #5–#8 — aggressive default bumps (`fcs/io/tuningdefaults.lua`)

| # | Param | From → To | Where |
|---|---|---|---|
| 5 | `feel.headingRate` | 2.2 → **4.5** | base |
| 5 | `feel.leadCapHeading` | 0.45 → **1.1** | base |
| 5 | `modes.CRUISE.feel.headingRate` / `.leadCapHeading` | → **5.5 / 1.5** | CRU override (new) |
| 5 | `modes.LDG.feel.headingRate` / `.leadCapHeading` | → **2.2 / 0.45** | LDG override (new; pins to today's values) |
| 6 | `feel.yawStopLead` | 0.15 → **0.05** | base (harder stop) |
| 7 | `modes.CRUISE.feel.swaySpeed` / `.swayLead` | 5/10 → **10 / 20** | CRU override (new) |
| 8 | `gains.alt.kp` | 0.035 → **0.06** | base |
| 8 | `feel.leadCapVert` | 10.0 → **14.0** | base |
| 9 | `feel.altStopLead` | — → **0.10** | base (new field) |

**Inheritance check (verify in tests):**
- LDG deep-copies base then overrides: it already pins `alt.kp=0.02`, `leadCapVert=8`, `swaySpeed/swayLead`,
  `climbRate` — so the base `alt.kp`/`leadCapVert` bumps do NOT reach LDG. The new LDG `headingRate`/
  `leadCapHeading` overrides pin yaw too. Net: **LDG unchanged**.
- CRU overrides `alt.kp=0.045`/`leadCapVert=12` already, so the base climb bump doesn't reach CRU; CRU
  gets its own faster yaw (5.5/1.5) + strafe (10/20).
- PRE (reads top-level) and MAN/DRN (deep-copy base) get the base bumps: faster yaw (4.5/1.1), snappier
  yaw stop (0.05), faster climb (0.06/14), the new altStopLead (0.10). ✓ (MAN/DRN included per operator.)

### New BIT/CONFIG rows (`ui/basalt/bitconfig/tuning.lua`)

Expose the two snappiness params as shared FEEL rows (the scroll menu from the prior feature absorbs
them). Append to `SHARED_FEEL_EXTRA_ROWS`:

```lua
{ id = "feel.yawStopLead", label = "YAW STOP LEAD", group = "FEEL", step = 0.01, min = 0, max = 1.0 },
{ id = "feel.altStopLead", label = "ALT STOP LEAD", group = "FEEL", step = 0.01, min = 0, max = 1.0 },
```

Applies to every mode's MODE FEEL. PRE/LDG MODE FEEL grows 6→8 (still fits, no scroll); CRU/MAN/DRN
grow (already scrolling). `headingRate`/`leadCapHeading`/`leadCapVert`/`swaySpeed`/`swayLead`/`alt.kp`
are already rows — only the two stop-leads are new.

## Testing

- **`tests/test_tuning_modes.lua` / `test_tuningdefaults.lua`:** resolve the new per-mode values — base
  `headingRate=4.5, leadCapHeading=1.1, yawStopLead=0.05, altStopLead=0.10, alt.kp=0.06, leadCapVert=14`;
  CRU `headingRate=5.5, leadCapHeading=1.5, swaySpeed=10, swayLead=20` (and CRU `alt.kp/leadCapVert`
  unchanged at 0.045/12); LDG `headingRate=2.2, leadCapHeading=0.45, alt.kp=0.02, leadCapVert=8` (unchanged);
  PRE/MAN/DRN inherit the base bumps.
- **`tests/test_pilot.lua`:** altitude release-edge capture — hold climb so `sp.altitude` leads
  `meas.altitude` by up to `leadCapVert`; on the release tick assert `sp.altitude == meas.altitude +
  altStopLead*meas.vSpeed` (edge-triggered), and it HOLDS on the next hands-off tick. Must FAIL without
  the capture (sp.altitude would retain the leash lead). Mirror the existing yaw-capture test's shape.
  Also: `reset`/`setMode` clear `climbWasHeld` (no stranded capture).
- **`tests/test_bitconfig_tuning.lua`:** `feel.yawStopLead` + `feel.altStopLead` rows present in MODE FEEL
  for all modes; `M.apply` on them writes the per-mode path clamped to step/min/max.
- **Golden (`tests/modes_golden_data.lua`):** the golden runs the scheme with base gains; `alt.kp` change
  shifts integral-bearing/first-tick alt output. Regen if the golden battery shifts (run
  `tools/capture_precision_golden.lua` inside CraftOS-PC, as `run_focus.sh` does) and commit the regen;
  the leveling/yaw/translate cases with unchanged gains stay put.

## Build / verify

Dual gate (source + dist), manifest regen after `fcs/**` + `ui/**` edits. In-world: yaw noticeably
faster (esp. CRU), stops where released (no steer-back); CRU strafe faster; PRE/MAN/DRN climb faster and
**hold on release without bouncing**; LDG unchanged; dial `YAW/ALT STOP LEAD` + the rate rows to taste.

## Out of scope
- Brake behavior/curve (shipped). Sway tuning beyond CRU strafe (#2 re-measure is an in-world step, not
  code). Extreme-attitude auto-recovery (separate future safety item). Loop jitter (deferred).
