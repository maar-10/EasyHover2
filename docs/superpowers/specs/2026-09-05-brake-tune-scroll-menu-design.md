# Scrollable BIT/CONFIG edit screen + live-tunable brake curve (fix #3 follow-up)

**Date:** 2026-09-05
**Branch:** `feat/brake-tune-menu`
**Status:** approved design, ready for implementation plan
**Follows:** fix #3 (`docs/superpowers/specs/2026-09-04-cru-braking-tilt-brake-design.md`) — its
`feel.tiltBrake` curve shipped resolvable per-mode but NOT wired as BIT/CONFIG rows, because the
MODE FEEL screen was already at its row budget.

## Problem

Fix #3 added a per-mode `feel.tiltBrake` curve (`engageSpeed/satSpeed/minAngle/maxAngle/buttonMax`),
meant to be dialable in-world. It was deferred: `ui/basalt/bitconfig/tuning.lua`'s edit screens are a
fixed top-to-bottom row layout with a hard budget (`height − 2` = title + footer, asserted by
`tests/test_bitconfig_tuning.lua`). The MODE FEEL screen for MAN/CRUISE/DRN already sits **exactly** at
that budget (2 own + 6 shared = 8 rows), so the 5 brake rows have nowhere to go.

## Design

Two parts, both in `ui/basalt/bitconfig/tuning.lua` (+ tests):

### 1. Make the stepper-edit screen scrollable (button-paged, NOT mouse-wheel)

Retrofit the shared `buildEditScreen` factory (`tuning.lua:519`) to window its rows when they exceed
the visible budget, reusing the established pattern from `ui/basalt/waypointlist.lua` (a fixed set of
visible row slots + a clamped offset + clickable `↑`/`↓` bracket buttons — **no reliance on scroll
events**, which are unreliable on CC monitors).

- **Visible count `N`** = `height − 2` (title row + footer row) — the same budget the screen uses today.
- **Row slots:** create exactly `N` stepper slots (label + `-` + `+`). On `refresh()`, map the offset
  window `rowIds[offset+1 .. offset+N]` onto the `N` slots; blank any slot past the row count. This
  mirrors `waypointlist.M.view`'s windowing (clamped offset, padded tail).
- **Offset + `↑`/`↓`:** a clamped offset (`0 .. max(0, #rowIds − N)`); `↑` pages up, `↓` pages down (by
  `N`, matching `waypointlist`'s `scrollBy(±rowsN)`). Bump `runtime.uiRev` on a page so the dirty-gated
  render repaints (same as the existing `bump()` at `tuning.lua:511`).
- **`↑`/`↓` appear ONLY when `#rowIds > N`.** When the rows fit (every screen today), the footer is the
  unchanged `?`/`<` action row and there are no scroll buttons — existing screens stay pixel-identical.
- **`↑`/`↓` placement:** appended to the footer action row beside `?`/`<` (one row, no extra budget
  cost). Verify width fit on the target monitor with `basalt-render` during implementation; if the
  four items are too tight, give `↑`/`↓` their own compact row (costs one visible row — acceptable,
  the screen scrolls anyway). This is the one layout detail to confirm visually.
- **`lastRowY`** (the fit signal every builder returns) becomes `title + N + footer` (the windowed
  height), so it stays `≤ height` by construction — the fit-regression test keeps passing.

`buildEditScreen`'s row SET is still fixed at build time (pure filter over `M.rows`); only which rows
are *shown* changes with the offset. Values/steps are still re-read live each `refresh()`.

### 2. Add the 5 brake-curve rows to CRU/MAN/DRN

Append to each of MAN/CRUISE/DRN's `MODE_OWN_EXTRA_ROWS` (`tuning.lua:235`) — NOT the shared rows, so
PRE/LDG (which have no own-extras) never show them:

```lua
{ id = "feel.tiltBrake.engageSpeed", label = "BRAKE ENGAGE", group = "FEEL", step = 1,    min = 0, max = 100  },
{ id = "feel.tiltBrake.satSpeed",    label = "BRAKE SAT",    group = "FEEL", step = 1,    min = 0, max = 200  },
{ id = "feel.tiltBrake.minAngle",    label = "BRAKE MIN",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
{ id = "feel.tiltBrake.maxAngle",    label = "BRAKE MAX",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
{ id = "feel.tiltBrake.buttonMax",   label = "BRAKE BTN",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
```

- 3-level nested paths already resolve: `M.pathFor(mode, "feel.tiltBrake.engageSpeed")` →
  `modes.CRUISE.feel.tiltBrake.engageSpeed` (same depth as `gains.pitch.kp`), and `M.apply`/`M.rows`
  already walk arbitrary dotted paths — verify, no new path code expected.
- Result: MODE FEEL for CRU/MAN/DRN grows 8 → **13** rows and scrolls; PRE/LDG stay 6 (unchanged).
- Labels avoid the degree glyph (ASCII only — `BRAKE MIN`, value shown in rad by the existing
  `fmtVal`); step 0.02 rad ≈ 1.1° per press.

## Live apply

BIT/CONFIG tuning edits apply through the existing live path (the menu's `M.apply` on the working cfg +
the config courier to the FCS responder) — no reboot. The brake curve is read by `pilot.lua` from
`self.cfg.tiltBrake` each tick, so a live-applied change takes effect immediately (same as the trim
rows). The `satSpeed ≤ engageSpeed` guard already added to `fcs/brake.lua` protects against a degenerate
live edit.

## Testing

`tests/test_bitconfig_tuning.lua`:
- **Fit-budget (existing, updated):** every registered screen's `lastRowY ≤ region height` — now
  satisfied for the 13-row MODE FEEL screens by windowing (assert the builder caps laid-out rows at N).
- **Windowing (new, pure — mirror `test_waypointlist` style if present):** the view/offset logic clamps
  (`offset ∈ [0, #rows−N]`), pages by N, and **every** brake row id is reachable at some offset.
- **`↑`/`↓` visibility:** absent when `#rowIds ≤ N` (a fitting screen); present when `#rowIds > N`.
- **Tuning resolve:** the 5 `feel.tiltBrake.*` rows are present in MODE FEEL for CRU/MAN/DRN and
  **absent** for PRE/LDG; `M.apply` on `feel.tiltBrake.engageSpeed` for CRUISE writes
  `modes.CRUISE.feel.tiltBrake.engageSpeed` and respects step/min/max.

## Build / verify

Dual gate (source + dist), manifest regen after the `ui/**` edit (same as any tracked file), plus a
`basalt-render` of the MODE FEEL CRU screen to eyeball the `↑`/`↓` footer layout and confirm the rows
read correctly. In-world: page through MODE FEEL on CRU, tune the brake curve, confirm live apply.

## Out of scope

- The #4–#9 rate-tuning / snappy-release pass (separate spec, next).
- Any change to the brake behavior itself (fix #3, shipped) — this only exposes its curve for tuning.
- A per-mode brake on/off toggle row (`tiltBrake.enabled` stays a design constant; YAGNI).
