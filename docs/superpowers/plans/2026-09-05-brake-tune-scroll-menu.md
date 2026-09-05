# Scrollable BIT/CONFIG Edit Screen + Brake Curve Rows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the BIT/CONFIG stepper-edit screen button-paged (up/down bracket buttons, no mouse-wheel) when its rows overflow the visible budget, then add the 5 `feel.tiltBrake` curve rows to CRU/MAN/DRN's MODE FEEL so the fix #3 brake curve is live-tunable in-world.

**Architecture:** A small pure windowing helper (`M.window`, mirroring `waypointlist.M.view`) makes the offset math unit-testable; `buildEditScreen` in `ui/basalt/bitconfig/tuning.lua` uses it to render a fixed set of visible slots over a clamped offset, showing `↑`/`↓` only when rows overflow. The 5 brake rows are appended to each mode's `MODE_OWN_EXTRA_ROWS` (CRU/MAN/DRN only).

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 full build, luamin dist, headless CraftOS-PC tests, `basalt-render` for the visual check.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-09-05-brake-tune-scroll-menu-design.md` — authority.
- **No mouse-wheel scroll** — clickable `↑`/`↓` bracket buttons only (CC monitor scroll events are unreliable). Reuse the `ui/basalt/waypointlist.lua` pattern (windowed slots + clamped offset + `configkit.bracketBtn` UP/DOWN).
- **Visible count `N` = frame `height − 2`** (title row + footer row) — the existing budget.
- **`↑`/`↓` appear ONLY when `#rowIds > N`.** Fitting screens stay pixel-identical (footer = `?`/`<` only).
- **Brake rows (CRU/MAN/DRN only)**, appended to `MODE_OWN_EXTRA_ROWS`, ASCII labels, values in rad:
  `feel.tiltBrake.engageSpeed` "BRAKE ENGAGE" step 1 / 0..100; `.satSpeed` "BRAKE SAT" step 1 / 0..200;
  `.minAngle` "BRAKE MIN" step 0.02 / 0..1.57; `.maxAngle` "BRAKE MAX" step 0.02 / 0..1.57;
  `.buttonMax` "BRAKE BTN" step 0.02 / 0..1.57.
- **Pure view-model unchanged** except adding `M.window` and the rows — `M.rows`/`M.apply`/`M.pathFor`/`getPath`/`setPath` already handle the 3-level `feel.tiltBrake.*` path (same depth as `gains.pitch.kp`); do NOT add path code.
- **Test framework:** `require("tests.framework")` → `t.test/t.eq/t.near/t.truthy`. `test_bitconfig_tuning.lua` and `test_waypointlist.lua` already registered.
- **Every tracked-file edit:** `node tools/build.mjs` + `bash tools/run_gen.sh`, commit regenerated `dist/**` + `manifest.lua` + `manifest-dev.lua`; `bash tests/run_headless.sh` must print OK / exit 0; `bash tools/run_gen.sh --check` clean.
- **Commit trailer:** end every commit with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL`.

## File Structure

- **Modify** `ui/basalt/bitconfig/tuning.lua` — add pure `M.window`; retrofit `buildEditScreen` (windowing + `↑`/`↓`); append 5 brake rows to `MODE_OWN_EXTRA_ROWS` for MAN/CRUISE/DRN.
- **Modify** `tests/test_bitconfig_tuning.lua` — windowing/visibility/resolve tests; update the fit-budget assertion to pass by windowing.
- **Generated:** `dist/**`, `manifest.lua`, `manifest-dev.lua`.

---

### Task 1: Pure windowing helper `M.window`

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua` (add `M.window` near the other pure view-model fns, ~after `M.rows`/`M.apply`)
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Produces: `M.window(count, offset, n) -> { first, last, offset, maxOffset }` where `first`/`last` are the 1-based inclusive index range of the visible window into a list of `count` rows (`last < first` ⇒ empty), `offset` is the clamped offset, `maxOffset = max(0, count - n)`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_bitconfig_tuning.lua`)

```lua
t.test("M.window clamps offset and returns the visible index range", function()
  local T = require("ui.basalt.bitconfig.tuning")
  -- 13 rows, window of 8
  local w = T.window(13, 0, 8)
  t.eq(w.offset, 0); t.eq(w.first, 1); t.eq(w.last, 8); t.eq(w.maxOffset, 5)
  w = T.window(13, 5, 8)              -- offset at max: shows rows 6..13
  t.eq(w.offset, 5); t.eq(w.first, 6); t.eq(w.last, 13)
  w = T.window(13, 99, 8)             -- over-max clamps to maxOffset
  t.eq(w.offset, 5); t.eq(w.first, 6); t.eq(w.last, 13)
  w = T.window(13, -3, 8)             -- negative clamps to 0
  t.eq(w.offset, 0); t.eq(w.first, 1); t.eq(w.last, 8)
end)

t.test("M.window: rows that fit -> maxOffset 0, full range, no scroll needed", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local w = T.window(6, 0, 8)
  t.eq(w.maxOffset, 0); t.eq(w.first, 1); t.eq(w.last, 6)
end)

t.test("M.window: every row reachable by paging with n", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local count, n, seen = 13, 8, {}
  local off = 0
  while true do
    local w = T.window(count, off, n)
    for i = w.first, w.last do seen[i] = true end
    if off >= w.maxOffset then break end
    off = math.min(off + n, w.maxOffset)
  end
  for i = 1, count do t.truthy(seen[i], "row " .. i .. " reachable") end
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (`T.window` nil).

- [ ] **Step 3: Implement** — add to `ui/basalt/bitconfig/tuning.lua` (pure, near `M.rows`):

```lua
-- M.window(count, offset, n) -> { first, last, offset, maxOffset }: the 1-based inclusive visible
-- index range into a `count`-row list shown `n` at a time, with the offset clamped to
-- [0, max(0, count-n)]. last < first means an empty window (count == 0). PURE. Mirrors the
-- windowing in ui/basalt/waypointlist.lua so the stepper-edit screen pages the same way the NAV list does.
function M.window(count, offset, n)
  count = math.max(0, math.floor(count or 0))
  n = math.max(1, math.floor(n or 1))
  local maxOffset = math.max(0, count - n)
  offset = math.floor(tonumber(offset) or 0)
  if offset < 0 then offset = 0 elseif offset > maxOffset then offset = maxOffset end
  local first = offset + 1
  local last = math.min(offset + n, count)
  return { first = first, last = last, offset = offset, maxOffset = maxOffset }
end
```

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS (window tests; all else green — pure addition).

- [ ] **Step 5: Commit** (this is a `ui/**` edit → regen)

```bash
node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua dist manifest.lua manifest-dev.lua
git commit -m "feat(ui): pure windowing helper M.window for scrollable edit screens" # + trailer
```

---

### Task 2: Retrofit `buildEditScreen` to window + `↑`/`↓`, and add the brake rows

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua` (`buildEditScreen` ~L519-586; `MODE_OWN_EXTRA_ROWS` ~L235-248)
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Consumes: `M.window` (Task 1); `configkit.bracketBtn(frame, x, y, text, color) -> { button }`; `configkit.actionRow(frame, {x,y,w}, items)`; `M.rows`/`M.apply`.
- Produces: a MODE FEEL screen for CRU/MAN/DRN with 13 rows that pages; a screen's returned `elements` gains `offset`/`scrollUp`/`scrollDown`/`visibleN` for tests (0/no-ops when the screen fits).

- [ ] **Step 1: Write the failing tests** (append to `tests/test_bitconfig_tuning.lua`)

```lua
t.test("brake rows: present in MODE FEEL for CRU/MAN/DRN, absent for PRE/LDG", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local function feelExtraIds(mode)
    local ids = {}
    for _, r in ipairs(T.rows({}, mode)) do
      if r.id:match("^feel%.tiltBrake%.") then ids[r.id] = true end
    end
    return ids
  end
  for _, mode in ipairs({ "CRUISE", "MAN", "DRN" }) do
    local ids = feelExtraIds(mode)
    t.truthy(ids["feel.tiltBrake.engageSpeed"], mode .. " has BRAKE ENGAGE")
    t.truthy(ids["feel.tiltBrake.buttonMax"],  mode .. " has BRAKE BTN")
  end
  for _, mode in ipairs({ "PRECISION", "LDG" }) do
    local ids = feelExtraIds(mode)
    t.eq(next(ids), nil, mode .. " has no brake rows")
  end
end)

t.test("brake row apply writes the nested per-mode path, clamped to step/min/max", function()
  local T = require("ui.basalt.bitconfig.tuning")
  local cfg = T.apply({}, "CRUISE", "feel.tiltBrake.engageSpeed", 1)  -- from default 30, step 1 -> 31
  t.near(cfg.modes.CRUISE.feel.tiltBrake.engageSpeed, 31, 1e-9)
  -- min clamp: buttonMax default 0.7854, step 0.02; huge negative delta floors at 0
  local cfg2 = T.apply({}, "MAN", "feel.tiltBrake.buttonMax", -1000)
  t.near(cfg2.modes.MAN.feel.tiltBrake.buttonMax, 0, 1e-9)
end)
```

Plus a Basalt construction test — follow the existing region/screen-build harness already in
`test_bitconfig_tuning.lua` (it builds screens headless via `basalt.update("timer",-1)` per the repo
convention). Assert, for the built `edit_CRUISE_FEEL_extra` screen at a realistic ~12-row frame:
```lua
-- (a) it lays out at most N = height-2 stepper slots (windowed, not all 13) -> lastRowY <= height
-- (b) elements.scrollUp / elements.scrollDown exist (rows overflow), and paging down then reading
--     the visible row labels surfaces a brake row that was NOT visible at offset 0
-- (c) a screen that FITS (e.g. edit_CRUISE_CAPS) has elements.scrollUp == nil (no scroll buttons)
```
Mirror the exact build/probe calls the existing fit-regression test in this file uses (reuse its frame
sizing + region setup helpers rather than inventing new ones).

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (brake rows absent; and, once added without windowing, the fit test would fail — windowing makes it pass).

- [ ] **Step 3a: Add the brake rows** — append to MAN, CRUISE, and DRN inside `MODE_OWN_EXTRA_ROWS` (`tuning.lua:235`), after each mode's existing 2 rows:

```lua
    { id = "feel.tiltBrake.engageSpeed", label = "BRAKE ENGAGE", group = "FEEL", step = 1,    min = 0, max = 100  },
    { id = "feel.tiltBrake.satSpeed",    label = "BRAKE SAT",    group = "FEEL", step = 1,    min = 0, max = 200  },
    { id = "feel.tiltBrake.minAngle",    label = "BRAKE MIN",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
    { id = "feel.tiltBrake.maxAngle",    label = "BRAKE MAX",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
    { id = "feel.tiltBrake.buttonMax",   label = "BRAKE BTN",    group = "FEEL", step = 0.02, min = 0, max = 1.57 },
```

- [ ] **Step 3b: Retrofit `buildEditScreen`** (`tuning.lua:519`) to window. Replace the fixed
one-slot-per-row layout with `N = height − 2` slots over a clamped offset, and add `↑`/`↓` to the footer
only when `#rowIds > N`. Key points: slots are fixed at N; each slot's `id` is reassigned every
`refresh()` from the window, so the `+`/`-` closures must reference `slot.id` (current), not a captured
`rid`; blank slots hide their `+`/`-`.

```lua
  local function buildEditScreen(mode, filterFn, screenTitle, helpId)
    return function(b, f, region)
      local fw, fh = f:getSize()
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local titleLabel = configkit.titleRow(f, fw, screenTitle)
      local y0 = 2                                   -- first stepper row (row 1 = title)

      local labelW = math.max(1, fiw - 8)
      local minusX = fx + labelW + 1
      local plusX  = minusX + 4

      local rowIds = {}
      for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do rowIds[#rowIds + 1] = r.id end

      local N = math.max(1, fh - 2)                  -- visible stepper rows (title + footer reserved)
      local overflow = #rowIds > N
      local offset = 0
      local refresh

      local rowSlots = {}
      for i = 1, N do
        local yy = y0 + i - 1
        local lbl   = f:addLabel({ x = fx, y = yy, width = labelW, height = 1, autoSize = false, text = "" })
        local minus = configkit.bracketBtn(f, minusX, yy, "-", colors.orange).button
        local plus  = configkit.bracketBtn(f, plusX,  yy, "+", colors.orange).button
        local slot = { id = nil, label = lbl, minus = minus, plus = plus }
        minus:onClick(function() if slot.id then workingCfg = M.apply(workingCfg, mode, slot.id, -1); refresh() end end)
        plus:onClick(function()  if slot.id then workingCfg = M.apply(workingCfg, mode, slot.id,  1); refresh() end end)
        rowSlots[i] = slot
      end

      local footerY = y0 + N
      local footerItems = {
        { label = "?", onClick = function() region:push("help_" .. helpId) end },
        { id = "back", label = "<", onClick = function() region:pop() end },
      }
      local scrollUp, scrollDown
      if overflow then
        footerItems[#footerItems + 1] = { id = "up",   label = string.char(30), onClick = function()  -- ▲
          local w = M.window(#rowIds, offset - N, N); offset = w.offset; refresh(); bump() end }
        footerItems[#footerItems + 1] = { id = "down", label = string.char(31), onClick = function()  -- ▼
          local w = M.window(#rowIds, offset + N, N); offset = w.offset; refresh(); bump() end }
      end
      local footerRow = configkit.actionRow(f, { x = fx, y = footerY, w = fiw }, footerItems)

      refresh = function()
        local byId = {}
        for _, r in ipairs(filterFn(M.rows(workingCfg, mode))) do byId[r.id] = r end
        local win = M.window(#rowIds, offset, N)
        offset = win.offset
        for i = 1, N do
          local slot = rowSlots[i]
          local rid = rowIds[win.first + i - 1]       -- nil past the window tail
          slot.id = rid
          local r = rid and byId[rid]
          if r then
            slot.label:setText(configkit.fitLabel(r.label .. " " .. fmtVal(r.value, r.step), labelW))
            slot.minus.setVisible and slot.minus:setVisible(true); slot.plus.setVisible and slot.plus:setVisible(true)
          else
            slot.label:setText("")
            if slot.minus.setVisible then slot.minus:setVisible(false); slot.plus:setVisible(false) end
          end
        end
      end
      refresh()

      return {
        apply = function(_state) refresh() end,
        elements = { titleLabel = titleLabel, rowSlots = rowSlots, footerRow = footerRow,
                     lastRowY = footerY, visibleN = N,
                     scrollUp = scrollUp, scrollDown = scrollDown,
                     -- expose paging for tests without a real click:
                     pageDown = function() local w = M.window(#rowIds, offset + N, N); offset = w.offset; refresh() end,
                     pageUp   = function() local w = M.window(#rowIds, offset - N, N); offset = w.offset; refresh() end,
                     rowIds = rowIds },
      }
    end
  end
```

Notes for the implementer:
- `string.char(30)`/`char(31)` are the CC ▲/▼ glyphs. If `basalt-render`/in-world shows them not
  rendering, fall back to ASCII `"^"` / `"v"` bracket buttons — confirm in the render step.
- Verify `configkit.bracketBtn`'s returned button supports `setVisible`; if not, blank the label and set
  the button text to `""` (a no-op click guarded by `if slot.id`), and note it. Do NOT invent a new API.
- Set `scrollUp`/`scrollDown` in `elements` to the actual button handles if `configkit.actionRow`
  returns them (check its return shape); if it doesn't expose per-item handles, keep the `pageUp`/
  `pageDown` closures as the test hook and set `scrollUp = overflow or nil` as a boolean presence flag —
  adjust the test in Step 1(c) to match whichever you expose. Keep the test asserting "present iff overflow".
- The footer `actionRow` now holds up to 4 items on CRU/MAN/DRN's MODE FEEL. Confirm width fit in the
  render step (Step 5); if too tight, move `↑`/`↓` to their own row at `footerY` and push the `?`/`<`
  row to `footerY+1` with `N = fh - 3` — update `lastRowY`/`visibleN` accordingly and re-run tests.

- [ ] **Step 4: Run and verify it passes** — `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh` → OK. All pre-existing `test_bitconfig_tuning` cases green (fitting screens unchanged: `overflow=false`, footer identical, `N` slots ≥ their row count so every row shows at offset 0).

- [ ] **Step 5: Visual check with `basalt-render`** — render the built `edit_CRUISE_FEEL_extra` screen at a realistic monitor size; confirm the brake rows read correctly and the `↑`/`↓` footer isn't clipped. If clipped or glyphs missing, apply the fallbacks noted above and re-run Step 4. Attach/save the render for the report.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua dist manifest.lua manifest-dev.lua
git commit -m "feat(ui): page long edit screens + live-tunable brake curve rows (CRU/MAN/DRN)" # + trailer
```

---

## Self-Review

**Spec coverage:** windowing helper (T1) ✓; `buildEditScreen` windowing + `↑`/`↓` only-on-overflow (T2 Step 3b) ✓; brake rows CRU/MAN/DRN, absent PRE/LDG (T2 Step 3a + test) ✓; nested-path apply (T2 test) ✓; fit-budget passes by windowing (T2 test) ✓; `basalt-render` check (T2 Step 5) ✓; live-apply — inherited from the existing menu path, no code change ✓.

**Placeholder scan:** no TBD/TODO. The `setVisible`/`actionRow`-return-shape/glyph uncertainties are explicit "verify against the real API and use the named fallback" instructions with concrete fallbacks — not open-ended placeholders.

**Type consistency:** `M.window(count, offset, n) -> {first,last,offset,maxOffset}` used identically in T1 (tests) and T2 (`buildEditScreen`). `elements.pageDown/pageUp/visibleN/rowIds` are the test hooks named in both the T2 test step and the T2 code.

## Post-merge
- `superpowers:finishing-a-development-branch` → merge `--no-ff` to `main`, push, in-world verify (page MODE FEEL on CRU, tune the brake curve, confirm live apply).
- Then proceed to piece B (#4–#9 rate tuning + snappy release) — its own spec/plan.
