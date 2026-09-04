# Trim Flip-Guard — bounded pitch feed-forward

**Date:** 2026-09-04
**Branch:** `fix/trim-flip-guard`
**Status:** approved design, ready for implementation plan

## Problem

In a CRU test flight the craft did a forward somersault when accelerating hard.
Root cause, confirmed from the fcslog CSV and the code:

`fcs/runtime/loop.lua:73`

```lua
demands.pitch = (demands.pitch or 0) + (self.trimDir or 0) * (self.trimGain or 0) * (demands.surge or 0)
```

The forward-trim feed-forward (`ff_pitch = trimDir·trimGain·surge`) is the intended and
correct mechanism: forward thrust pitches the nose **up** (CoM not vertically centred), so the
trim adds a nose-down lift-differential proportional to forward thrust to hold attitude during
acceleration. Two structural faults turn it into a flip:

1. **Unbounded term.** It is linear in `demands.surge` with no limit of its own. Hard
   acceleration → large surge demand → large nose-down bias.
2. **Can consume 100 % of pitch authority — and then some.** The next line,
   `envelope.clamp(demands, caps)`, clamps the *total* pitch demand to `caps.pitch`. The logged
   `ff_pitch` is the **raw** feed-forward (reconstructed pre-clamp at `tools/flight.lua:205`): it
   reached **−0.35** while CRU's `caps.pitch` is only **0.2** — i.e. the trim bias alone is
   **1.75× the entire pitch cap**. So the envelope pinned the total pitch demand fully nose-down
   at `−caps.pitch`, completely overriding the pitch stabilizer's nose-up correction. `sat_pitch`
   latched at only −8° of pitch; with no reserve authority the craft pitched past vertical and
   flipped.

   Underlying mismatch: `trimGain` (0.35) was set with no regard to `caps.pitch` (0.2). At full
   surge (`caps.surge` = 1.0) the raw feed-forward is `0.35`, already larger than the whole pitch
   cap. The floor below makes this class of gain/cap mismatch structurally safe regardless of how
   `trimGain` is tuned.

Evidence the feed-forward (not the setpoint/surge loops) was the driver: `sp_pitch` (col 24)
stayed 0 for the entire capture, and surge **position** error was 0 (`surgePos == sp_surge`),
so neither the pitch setpoint nor the surge position loop commanded the tilt. `ff_pitch`
tracked `surgeVel` almost linearly and then railed.

## Goal

Keep the trim assisting nose-down during acceleration, but bound it so it can never starve the
pitch stabilizer or run away into a flip. Level-hold during acceleration is preserved because
the pitch **stabilizer still closes the loop** on any residual nose-up; the feed-forward only
does the fast part up to its bound.

## Design — fade + floor

Replace the single line 73 with a bounded feed-forward computed inside `Loop:cycle`:

```lua
-- raw feed-forward (unchanged intent)
local ffRaw = (self.trimDir or 0) * (self.trimGain or 0) * (demands.surge or 0)

-- (a) attitude fade: full trim while near-level, ramps to 0 as the craft tilts.
--     Deadzone below trimFadeStart keeps normal accel fully assisted.
local mag = math.abs(m.pitch or 0)
local fade
local fs, fe = self.trimFadeStart or 0, self.trimFade or math.huge
if mag <= fs then fade = 1
elseif mag >= fe then fade = 0
else fade = 1 - (mag - fs) / (fe - fs) end
local ff = ffRaw * fade

-- (b) authority floor: the feed-forward may use at most trimAuthority of the pitch cap,
--     reserving (1 - trimAuthority) for the stabilizer to recover with.
local ffCap = (self.caps.pitch or math.huge) * (self.trimAuthority or 1)
if ff >  ffCap then ff =  ffCap elseif ff < -ffCap then ff = -ffCap end

self._ffPitch = ff                        -- applied value, for truthful logging (§ Logging)
demands.pitch = (demands.pitch or 0) + ff
```

Order: fade → floor → add, all **before** the existing DAMPED-zeroing block (an osc trip still
wipes it) and before `envelope.clamp` (unchanged).

**Why it cannot flip:** the floor guarantees `|ff| ≤ trimAuthority · caps.pitch`, so after the
final `envelope.clamp` the stabilizer always retains at least `(1 − trimAuthority) · caps.pitch`
of net nose-up authority to arrest a departure. The fade additionally eases the trim off *before*
the floor engages, the moment the craft tilts past its normal cruise band.

**Legacy behavior when unset:** if `trimAuthority`/`trimFade`/`trimFadeStart` are nil (old callers,
existing tests that call `setTrim(dir, gain)`), the defaults above reproduce the old unbounded
behavior exactly (authority = 1 → no floor, fade = off). Safety in production comes from
`tuningdefaults` always supplying the values and `flight.lua` always threading them, so there is
no production path without the guard.

## Parameters (per-mode `feel`)

Added to the base `feel` table in `fcs/io/tuningdefaults.lua` (all modes deep-copy `feel`, so
every mode inherits; CRU is the one that matters most):

| param | meaning | default |
|---|---|---|
| `trimDir`, `trimGain` | existing — direction & gain | unchanged (gain 0.35) |
| `trimFadeStart` | \|pitch\| (rad) below which trim is at full strength | 0.25 (~14°) |
| `trimFade` | \|pitch\| (rad) at which trim is fully faded to 0 | 0.60 (~34°) |
| `trimAuthority` | max fraction of `caps.pitch` the feed-forward may use | 0.40 |

`trimFade` (0.6) deliberately equals the existing `attLimit` (0.6): the trim is fully gone by the
attitude limit, well before the ~90° point of no return.

## Threading

- `fcs/runtime/loop.lua`
  - `Loop:setTrim(dir, gain)` → `Loop:setTrim(dir, gain, authority, fadeStart, fade)`
    (backward-compatible; extra args optional). Stores `self.trimAuthority`, `self.trimFadeStart`,
    `self.trimFade`. Legacy fallbacks: `authority` nil → 1, `fadeStart` nil → 0, `fade` nil → math.huge.
  - `Loop:cycle` implements the fade+floor block above and stashes `self._ffPitch`.
  - `Loop:diag` returns `ffPitch = self._ffPitch or 0` (in addition to the existing
    `trimDir`/`trimGain`).
- `fcs/runtime/flight.lua`
  - `Flight.new` seeds `self.trimAuthority` / `self.trimFadeStart` / `self.trimFade` from the
    default descriptor's `feel` (same pattern as `trimGain`, line 40-44).
  - `flightMode` branch (line 98-100): read the three new `feel` fields (same guarded pattern as
    `trimDir`/`trimGain`) and pass all five through `setTrim`.
  - `flightTrim` branch (line 105-110): pass the current five through `setTrim`.
  - Any other `setTrim` call site (grep: line ~293 boot/reset re-apply) passes the five.
- `fcs/io/tuningdefaults.lua`: add the three fields to base `feel` (near `trimGain`, line 54).

## Logging (truthful)

`tools/flight.lua:205` currently reconstructs the logged `ff_pitch` as
`(d.trimDir or 0)*(d.trimGain or 0)*((dem.surge) or 0)`, which would hide the new fade/floor.
Change it to use the actually-applied value from `diag`:

```lua
ff_pitch = d.ffPitch or ((d.trimDir or 0) * (d.trimGain or 0) * ((dem.surge) or 0)),
```

(`d.ffPitch` when present; the old recompute only as a fallback for any pre-cycle sample.)
Result: the next test-flight CSV shows the real faded/clamped `ff_pitch`, so the fix is visible.

## Live tuning (BIT/CONFIG)

`ui/basalt/bitconfig/tuning.lua` — add three rows to `SHARED_FEEL_EXTRA_ROWS` (line ~207-218,
the block already sharing `feel.trimGain` across every mode), e.g.:

```lua
{ id = "feel.trimAuthority", label = "TRIM AUTH",  group = "FEEL", step = 0.05, min = 0, max = 1.0 },
{ id = "feel.trimFadeStart", label = "TRIM FADE0", group = "FEEL", step = 0.05, min = 0, max = 1.5 },
{ id = "feel.trimFade",      label = "TRIM FADE1", group = "FEEL", step = 0.05, min = 0, max = 1.5 },
```

The shared-rows count feeds the page layout math (comments at lines ~617, ~663 about row counts and
the flat-screen exception). Adding 3 rows takes the shared block from 3 → 6; the implementer must
re-check the layout/pagination and keep `test_bitconfig_tuning.lua` green (labels match existing
width/style — final label text is the implementer's call).

## Testing (TDD)

Extend `tests/test_loop_trim.lua`:

1. **Floor holds** — huge `surge` demand, level attitude → applied `ff` never exceeds
   `±trimAuthority · caps.pitch`.
2. **Recovery authority preserved** — big nose-up stabilizer demand *and* huge surge → resulting
   `demands.pitch` (post `envelope.clamp`) stays net nose-up (never rails at `−caps.pitch`).
   This is the anti-flip guarantee.
3. **Fade curve** — `ff` = full below `trimFadeStart`, 0 at/above `trimFade`, monotonic between;
   deadzone respected.
4. **Normal regime unchanged** — small surge, near level → `ff ≈ trimDir·trimGain·surge` (old value).
5. **Regression repro** — replay the log's runaway shape (surge ramping, `m.pitch` growing) and
   assert pitch demand does NOT pin at the nose-down cap through the sequence.
6. **Log truthfulness** — `Loop:diag().ffPitch` equals the value actually added in the last `cycle`.
7. **DAMPED still wins** — an osc trip zeroes pitch even with trim active.

Also:
- `tests/test_flight*.lua` — assert `flight.lua` threads the three `feel` fields into `setTrim`
  (feel values reach the loop) on mode switch and boot.
- `tests/test_bitconfig_tuning.lua` — the three new rows present with correct ranges; layout green.

## Build / verify

After src changes: rebuild `dist/`, run the full test suite + e2e stress. Target: src N/0,
dist N/0, e2e PASS (usual bar). In-world confirm is owed after merge (tune `trimAuthority` /
`trimFade` on the real craft via BIT/CONFIG; no reboot needed).

## Out of scope (noted, not done here)

- A forward-speed governor (surgeVel ran to 43) — a separate translation-loop concern.
- Tilt-aware descent protection (heave railed while inverted) — separate.
- PFD render cost (16–36 ms) and dt jitter (up to 237 ms) — separate open items.
