# Trim Flip-Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound the forward-trim pitch feed-forward so it still assists nose-down during acceleration but can never starve the pitch stabilizer or flip the craft.

**Architecture:** The feed-forward `trimDir·trimGain·surge` gets two bounds inside `Loop:cycle`: an *attitude fade* (full below `trimFadeStart`, ramps to 0 by `trimFade`) and an *authority floor* (`|ff| ≤ trimAuthority·caps.pitch`, reserving the rest for the stabilizer). New per-mode `feel` params carry the tunables; `flight.lua` threads them into `Loop:setTrim`; the applied bias is logged truthfully.

**Tech Stack:** Lua 5.x (CC:Tweaked target), custom test framework (`tests/framework.lua`), Node build (`tools/build.mjs` → `dist/`), dual headless gates.

## Global Constraints

- **Language:** Lua, CC:Tweaked-compatible. No new dependencies.
- **Test framework:** `local t = require("tests.framework")`; assertions `t.test`, `t.eq`, `t.near(a,b,eps,msg)`, `t.truthy`. Match existing style in the target test file.
- **Dual gate:** Source suite `bash tests/run_headless.sh` AND dist suite `bash tests/run_headless_dist.sh` must both be green. All tests here extend EXISTING test files, so no `run_headless*.sh` suite-list edits are required.
- **Dist is generated:** never hand-edit `dist/`. Rebuild with `node tools/build.mjs` after source changes.
- **Legacy behavior preserved when unset:** `setTrim` with only `(dir, gain)` (existing callers/tests) must behave exactly as before — `authority` nil → 1, `fadeStart` nil → 0, `fade` nil → `math.huge`.
- **Commit trailers (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z
  ```
- **Spec:** `docs/superpowers/specs/2026-09-04-trim-flip-guard-design.md`.

---

### Task 1: Bound the trim feed-forward in the Loop

**Files:**
- Modify: `fcs/runtime/loop.lua` (`Loop:setTrim` line 17; `Loop:cycle` line 73; `Loop:diag` lines 94-103)
- Test: `tests/test_loop_trim.lua`

**Interfaces:**
- Produces: `Loop:setTrim(dir, gain, authority, fadeStart, fade)` — stores `self.trimAuthority` (nil→1), `self.trimFadeStart` (nil→0), `self.trimFade` (nil→`math.huge`).
- Produces: `Loop:cycle(rawDt, m)` adds a bounded bias `self._ffPitch` to `demands.pitch` (fade then authority-floor), computed from `m.pitch`, `demands.surge`, and `self.caps.pitch`.
- Produces: `Loop:diag(sp, m)` return table gains a field `ffPitch = self._ffPitch or 0` (existing `trimDir`/`trimGain`/`terms`/`sat`/`heaveBanded` unchanged).

- [ ] **Step 1: Write the failing tests** — append to `tests/test_loop_trim.lua`:

```lua
t.test("loop trim floor: feedforward clamped to -trimAuthority*caps.pitch", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- raw = -0.35; floor = 0.4*0.2 = 0.08
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, -0.08, 1e-9, "trim clamped to the authority floor, not the raw -0.35")
end)

t.test("loop trim anti-flip: stabilizer keeps net nose-up authority under huge surge", function()
  -- Stabilizer wants full nose-up (+caps.pitch); trim wants huge nose-down. Post-add pitch must
  -- stay net nose-up -- the exact case that flipped the craft (raw -0.35 would give 0.2-0.35=-0.15).
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.2, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- ff floored to -0.08
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0.12, 1e-9, "0.2 stabilizer + (-0.08) trim = +0.12 reserved nose-up")
  t.truthy(r.demands.pitch > 0, "pitch demand stays net nose-up (no flip)")
end)

t.test("loop trim fade: full below trimFadeStart, zero at/above trimFade, linear between", function()
  local function ffAt(pitchMag)
    local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
      mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 10, surge = 1 } })
    lp:setTrim(-1, 0.4, 1.0, 0.25, 0.6)  -- authority 1 & big cap: only the fade acts; raw = -0.4
    lp:arm(true)
    return lp:cycle(0.05, { onGround = false, pitch = pitchMag }).demands.pitch
  end
  t.near(ffAt(0.10),  -0.4, 1e-9, "full trim inside deadzone")
  t.near(ffAt(0.25),  -0.4, 1e-9, "full trim at fade start")
  t.near(ffAt(0.425), -0.2, 1e-9, "half-faded at midpoint")   -- (0.425-0.25)/(0.6-0.25)=0.5
  t.near(ffAt(0.60),   0.0, 1e-9, "zero trim at fade end")
  t.near(ffAt(0.80),   0.0, 1e-9, "zero trim beyond fade end")
end)

t.test("loop diag: ffPitch equals the bias actually added (clamped, not raw)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  local d = lp:diag({}, { pitch = 0 })
  t.near(d.ffPitch, -0.08, 1e-9, "diag reports the clamped applied bias")
  t.near(d.ffPitch, r.demands.pitch, 1e-9, "matches the pitch bias added (scheme pitch was 0)")
end)

t.test("loop trim: DAMPED trip zeroes pitch even with trim active", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp.osc = { update = function() return true end, reset = function() end }  -- force a trip
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(r.mode, "DAMPED")
  t.near(r.demands.pitch, 0, 1e-9, "osc trip zeroes pitch despite trim (order preserved)")
end)
```

- [ ] **Step 2: Run the tests, verify they fail**

Run: `cd "$(git rev-parse --show-toplevel)" && lua -e "require('tests.test_loop_trim')"` (or the repo's single-file harness if that errors — see how `tests/run_headless.sh` invokes a suite file).
Expected: the new tests FAIL (`setTrim` ignores extra args / `demands.pitch` = raw −0.35 / `diag` has no `ffPitch`). The two pre-existing trim tests still PASS.

- [ ] **Step 3: Extend `Loop:setTrim`** (`fcs/runtime/loop.lua:17`)

```lua
function Loop:setTrim(dir, gain, authority, fadeStart, fade)
  self.trimDir = dir or 0; self.trimGain = gain or 0
  self.trimAuthority = authority or 1        -- fraction of caps.pitch the feedforward may use
  self.trimFadeStart = fadeStart or 0        -- |pitch| (rad) below which trim is full strength
  self.trimFade = fade or math.huge          -- |pitch| (rad) at which trim is fully faded out
end
```

- [ ] **Step 4: Replace the feed-forward line** (`fcs/runtime/loop.lua:73`) with the bounded block:

```lua
  -- Forward trim (master-mode feedforward): the craft pitches nose-up under forward thrust because
  -- its CoM is not vertically centered. Bias the pitch DEMAND (realized as a lift-thruster
  -- differential by the mixer -- never the forward thrusters) proportional to the forward thrust
  -- demand, so the craft holds its intended pitch during acceleration. Applied before the DAMPED
  -- block so a genuine oscillation trip still zeroes it.
  -- BOUNDED (flip-guard, spec 2026-09-04): the raw feedforward can exceed caps.pitch and rail the
  -- whole pitch demand nose-down, starving the stabilizer -> forward somersault (observed in CRU).
  -- (a) attitude fade: full trim below trimFadeStart, ramp to 0 by trimFade, so it eases off as the
  -- craft departs level; (b) authority floor: never use more than trimAuthority of the pitch cap,
  -- reserving (1 - trimAuthority) for the stabilizer to recover with.
  local ffRaw = (self.trimDir or 0) * (self.trimGain or 0) * (demands.surge or 0)
  local mag = math.abs(m.pitch or 0)
  local fs, fe = self.trimFadeStart or 0, self.trimFade or math.huge
  local fade
  if mag <= fs then fade = 1
  elseif mag >= fe then fade = 0
  else fade = 1 - (mag - fs) / (fe - fs) end
  local ff = ffRaw * fade
  local ffCap = ((self.caps and self.caps.pitch) or math.huge) * (self.trimAuthority or 1)
  if ff > ffCap then ff = ffCap elseif ff < -ffCap then ff = -ffCap end
  self._ffPitch = ff
  demands.pitch = (demands.pitch or 0) + ff
```

- [ ] **Step 5: Add `ffPitch` to `Loop:diag`** (`fcs/runtime/loop.lua`, in the returned table ~line 100):

```lua
    trimDir = self.trimDir or 0,
    trimGain = self.trimGain or 0,
    ffPitch = self._ffPitch or 0,
```

- [ ] **Step 6: Run the tests, verify they pass**

Run the trim tests (and the whole file). Expected: all PASS, including the two pre-existing trim tests.

- [ ] **Step 7: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop_trim.lua
git commit -m "fix(fcs): bound forward-trim feedforward (fade + authority floor)

The raw trimDir*trimGain*surge bias could exceed caps.pitch and rail the
whole pitch demand nose-down, starving the stabilizer -> CRU somersault.
Add an attitude fade (full below trimFadeStart, 0 by trimFade) and an
authority floor (|ff| <= trimAuthority*caps.pitch) inside Loop:cycle, and
expose the applied bias as diag().ffPitch. setTrim gains 3 optional args
(legacy 2-arg callers unchanged).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

---

### Task 2: Feel defaults for the flip-guard tunables

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (base `feel` table, near `trimGain` line 54)
- Test: `tests/test_tuning_modes.lua`

**Interfaces:**
- Produces: base `DEFAULTS.feel.trimAuthority = 0.4`, `.trimFadeStart = 0.25`, `.trimFade = 0.6`. All modes deep-copy `feel`, so every mode inherits them.

- [ ] **Step 1: Write the failing test** — append to `tests/test_tuning_modes.lua`:

```lua
t.test("trim flip-guard: fade/floor feel defaults present and inherited by every mode", function()
  local base = tuning.forMode("PRECISION").feel
  t.near(base.trimAuthority, 0.4,  1e-9, "PRECISION trimAuthority default")
  t.near(base.trimFadeStart, 0.25, 1e-9, "PRECISION trimFadeStart default")
  t.near(base.trimFade, 0.6,       1e-9, "PRECISION trimFade default")
  for _, mode in ipairs({ "MAN", "CRUISE" }) do
    local f = tuning.forMode(mode).feel
    t.near(f.trimAuthority, 0.4, 1e-9, mode.." inherits trimAuthority")
    t.near(f.trimFade, 0.6,      1e-9, mode.." inherits trimFade")
  end
  local d = tuningdefaults.get()
  t.near(d.modes.LDG.feel.trimAuthority, 0.4, 1e-9, "LDG inherits")
  t.near(d.modes.DRN.feel.trimFade, 0.6,      1e-9, "DRN inherits")
end)
```

- [ ] **Step 2: Run it, verify it fails**

Run the tuning-modes test file. Expected: FAIL — `trimAuthority`/`trimFadeStart`/`trimFade` are nil.

- [ ] **Step 3: Add the defaults** — in `fcs/io/tuningdefaults.lua`, inside `DEFAULTS.feel` right after the `trimGain` line (line 54):

```lua
    trimGain       = 0.35,  -- forward-trim feedforward gain: demands.pitch += trimDir*trimGain*demands.surge
    -- Flip-guard bounds (spec 2026-09-04): fade the trim out as the craft departs level, and cap the
    -- feedforward at a fraction of caps.pitch so it can never starve the pitch stabilizer.
    trimFadeStart  = 0.25,  -- rad: full trim below this |pitch| (normal accel tilt stays fully assisted)
    trimFade       = 0.6,   -- rad: trim fully faded to 0 by this |pitch| (== attLimit)
    trimAuthority  = 0.4,   -- max fraction of caps.pitch the feedforward may consume
```

- [ ] **Step 4: Run it, verify it passes** — the new test PASSES; the existing tuning-modes tests stay green.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "feat(fcs): trim flip-guard feel defaults (trimAuthority/trimFadeStart/trimFade)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

---

### Task 3: Thread the feel params through flight.lua

**Files:**
- Modify: `fcs/runtime/flight.lua` (`Flight.new` seed ~lines 40-44; `flightMode` branch line 98-100; `flightTrim` branch line 105-110; `:step` re-apply line 293)
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: `Loop:setTrim(dir, gain, authority, fadeStart, fade)` (Task 1); `feel.trimAuthority/.trimFadeStart/.trimFade` (Task 2).
- Produces: `self.trimAuthority` / `self.trimFadeStart` / `self.trimFade` on the Flight instance, seeded at boot from the default descriptor's `feel` and refreshed on mode switch; all three passed at every `setTrim` call.

- [ ] **Step 1: Write the failing test** — append to `tests/test_flight.lua`:

```lua
local function trimFakeLoop()
  local L = fakeLoop()
  function L:setTrim(dir, gain, authority, fadeStart, fade)
    self.trimArgs = { dir, gain, authority, fadeStart, fade }
  end
  return L
end
local function trimFakePilot()
  return { setMode = function() end, reset = function() end, setTrimDir = function() end,
    setPositionHold = function() end, setMaster = function() end, update = function() return {} end }
end

t.test("flight seeds + threads trim fade/floor feel into loop:setTrim", function()
  local L = trimFakeLoop()
  local feel = { trimDir = -1, trimGain = 0.35, trimAuthority = 0.4, trimFadeStart = 0.25, trimFade = 0.6 }
  local desc = { feel = feel, policy = {}, canPark = false, groundSense = false,
    scheme = { reset = function() end } }
  local reg = { default = "CRUISE", byId = { CRUISE = desc } }
  local f = Flight.new({ loop = L, pilot = trimFakePilot(), registry = reg })
  t.near(f.trimAuthority, 0.4, 1e-9, "seeded from default descriptor at boot")
  t.near(f.trimFadeStart, 0.25, 1e-9, "fadeStart seeded")
  t.near(f.trimFade, 0.6, 1e-9, "fade seeded")
  f:handleCommand({ k = "flightMode", id = "CRUISE" })
  t.truthy(L.trimArgs, "setTrim was called on mode switch")
  t.eq(L.trimArgs[3], 0.4,  "authority threaded")
  t.eq(L.trimArgs[4], 0.25, "fadeStart threaded")
  t.eq(L.trimArgs[5], 0.6,  "fade threaded")
end)
```

- [ ] **Step 2: Run it, verify it fails**

Run the flight test file. Expected: FAIL — `f.trimAuthority` nil and `L.trimArgs[3..5]` nil (flight passes only 2 args).

- [ ] **Step 3: Seed the three fields in `Flight.new`** — after the `trimGain = (function() ... end)(),` block (~line 44), add three sibling seeders reading the same default descriptor:

```lua
    trimAuthority = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimAuthority) or 1
    end)(),
    trimFadeStart = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimFadeStart) or 0
    end)(),
    trimFade = (function()
      local d = deps.registry and deps.registry.byId and deps.registry.default
        and deps.registry.byId[deps.registry.default]
      return (d and d.feel and d.feel.trimFade) or math.huge
    end)(),
```

- [ ] **Step 4: Refresh them on mode switch** — in the `flightMode` branch, after the existing `self.trimGain = (d.feel and d.feel.trimGain) or self.trimGain` (line 99), add:

```lua
    self.trimAuthority = (d.feel and d.feel.trimAuthority) or self.trimAuthority
    self.trimFadeStart = (d.feel and d.feel.trimFadeStart) or self.trimFadeStart
    self.trimFade = (d.feel and d.feel.trimFade) or self.trimFade
```

- [ ] **Step 5: Pass all five at every `setTrim` call** — replace all three occurrences of
`self.loop:setTrim(self.trimDir, self.trimGain)` (lines 100, 109, 293) with:

```lua
self.loop:setTrim(self.trimDir, self.trimGain, self.trimAuthority, self.trimFadeStart, self.trimFade)
```

(Verify the count first: `grep -n "setTrim(self.trimDir" fcs/runtime/flight.lua` — expect exactly 3.)

- [ ] **Step 6: Run it, verify it passes** — the new test PASSES; existing flight tests stay green (they use a `fakeLoop` without `setTrim`, and the `if self.loop.setTrim then` guards already skip it).

- [ ] **Step 7: Commit**

```bash
git add fcs/runtime/flight.lua tests/test_flight.lua
git commit -m "feat(fcs): thread trim flip-guard feel (authority/fade) into setTrim

Seed trimAuthority/trimFadeStart/trimFade from the default descriptor at
boot, refresh on mode switch, and pass all five to loop:setTrim at every
call site (mode switch, flightTrim, per-step re-apply).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

---

### Task 4: Truthful ff_pitch logging

**Files:**
- Modify: `tools/flight.lua:205` (the logged-sample `ff_pitch` reconstruction)

**Interfaces:**
- Consumes: `d.ffPitch` from `Loop:diag` (Task 1). `d` is the `flight.loop:diag(...)` result already fetched at line 187; `dem` is the demands table.

**Note on testing:** `tools/flight.lua` is the CraftOS-PC runtime entry (no unit-test seam for its sample assembly). Correctness of the *value* is already guaranteed by Task 1's `diag().ffPitch` test; this task only re-points the log field at that value. It is additionally exercised by the e2e suite in Task 6. No new unit test.

- [ ] **Step 1: Re-point the log field** — change `tools/flight.lua:205` from:

```lua
    ff_pitch = (d.trimDir or 0) * (d.trimGain or 0) * ((dem.surge) or 0),
```

to (use the actually-applied bias; keep the old product only as a fallback for any pre-cycle sample):

```lua
    ff_pitch = d.ffPitch or ((d.trimDir or 0) * (d.trimGain or 0) * ((dem.surge) or 0)),
```

- [ ] **Step 2: Verify by inspection** — confirm `d` is the `diag()` result (line 187) and now carries `ffPitch`. Run `bash tests/run_headless.sh` to confirm nothing regressed (the tools file loads clean).

- [ ] **Step 3: Commit**

```bash
git add tools/flight.lua
git commit -m "fix(fcs-log): log the applied (faded/clamped) ff_pitch, not the raw product

So the fcslog CSV shows the real trim bias after the flip-guard fade+floor,
making the guard visible in the next test flight.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

---

### Task 5: BIT/CONFIG live-tune rows

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua` (`SHARED_FEEL_EXTRA_ROWS`, lines 215-219)
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Consumes: the three `feel.*` defaults (Task 2) for row default values.
- Produces: three new tunable rows shared across every flight mode's FEEL screen: `feel.trimAuthority`, `feel.trimFadeStart`, `feel.trimFade`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_bitconfig_tuning.lua`. First `grep -n "trimGain" tests/test_bitconfig_tuning.lua`: if an existing test already probes the `feel.trimGain` row, mirror its exact aggregation call for the new ids; otherwise use `M.rows` as below.

```lua
t.test("rows: trim flip-guard feel rows present with ranges (shared across modes)", function()
  local rows = M.rows(tuningdefaults.get())
  local byId = {}
  for _, r in ipairs(rows) do byId[r.id] = r end
  for _, id in ipairs({ "feel.trimAuthority", "feel.trimFadeStart", "feel.trimFade" }) do
    t.truthy(byId[id], id.." row present")
    t.eq(byId[id].group, "FEEL", id.." is a FEEL row")
  end
  t.near(byId["feel.trimAuthority"].value, 0.4, 1e-9, "value from defaults")
  t.eq(byId["feel.trimAuthority"].max, 1.0, "authority max 1.0")
  t.eq(byId["feel.trimFade"].max, 1.5, "fade max 1.5")
end)
```

- [ ] **Step 2: Run it, verify it fails**

Run the bitconfig-tuning test file. Expected: FAIL — the three rows are absent. (If it fails because `M.rows` does not surface `SHARED_FEEL_EXTRA_ROWS`, switch the test to the same builder the existing `feel.trimGain` assertion uses — see Step 1 grep.)

- [ ] **Step 3: Add the rows** — in `ui/basalt/bitconfig/tuning.lua`, append to `SHARED_FEEL_EXTRA_ROWS` (after the `feel.trimGain` line, 218):

```lua
  { id = "feel.trimAuthority", label = "TRIM AUTH",    group = "FEEL", step = 0.05, min = 0, max = 1.0 },
  { id = "feel.trimFadeStart", label = "TRIM FADE LO", group = "FEEL", step = 0.05, min = 0, max = 1.5 },
  { id = "feel.trimFade",      label = "TRIM FADE HI", group = "FEEL", step = 0.05, min = 0, max = 1.5 },
```

- [ ] **Step 4: Re-check the FEEL-screen row budget** — the header comment at lines 207-214 explains the shared block was sized so each mode's MODE-FEEL screen stays inside the ~12-13 row budget. This takes the shared block from 3 → 6 rows. Read the layout/pagination code the comment references (search `SHARED_FEEL_EXTRA_ROWS` usage and the row-count math near lines ~617/~663). If the MODE-FEEL screen now overflows, apply the file's existing overflow mechanism (the same base/extra split it already documents) — do NOT invent a new one. Adjust labels only if width forces it (match the ≤~15-char style of existing labels).

- [ ] **Step 5: Run it, verify it passes** — the new test PASSES; the existing bitconfig-tuning tests (including the real Basalt construction probe) stay green. This is the gate that catches any layout overflow.

- [ ] **Step 6: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua
git commit -m "feat(ui): live-tune trim flip-guard (TRIM AUTH / FADE LO / FADE HI) in BIT/CONFIG

Three shared FEEL rows so trimAuthority/trimFadeStart/trimFade tune in-world
without a reboot, same path as TRIM GAIN.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

---

### Task 6: Rebuild dist + full dual-gate verification

**Files:** none edited by hand (regenerates `dist/`).

- [ ] **Step 1: Source gate** — `bash tests/run_headless.sh`. Expected: all source tests pass (`N/0`), including `e2e_stress`. Fix any failure before proceeding.

- [ ] **Step 2: Rebuild dist** — `node tools/build.mjs`. Expected: `dist/` regenerated from the updated source (loop.lua, flight.lua, tuningdefaults.lua, tools/flight.lua, tuning.lua all re-minified). No new source files were added, so `manifest.lua` needs no regen; if the build or a manifest-sync check complains, run `bash tools/run_gen.sh` and re-stage `manifest.lua`.

- [ ] **Step 3: Dist gate** — `bash tests/run_headless_dist.sh`. Expected: all dist tests pass (`N/0`).

- [ ] **Step 4: Commit the rebuilt dist**

```bash
git add dist/ manifest.lua
git commit -m "build(dist): rebuild for trim flip-guard

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01REJBTttfof6dkPyJuEt92Z"
```

- [ ] **Step 5: Final report** — state the numbers reached (source `N/0`, dist `N/0`, e2e green) and note the owed follow-up: in-world test flight, then tune `TRIM AUTH` / `TRIM FADE HI` on the real craft via BIT/CONFIG (no reboot), confirming from the next fcslog that `ff_pitch` now fades/clamps and `sat_pitch` no longer latches during a hard CRU acceleration.

---

## Self-Review

**Spec coverage:** Fade + floor math → Task 1. Legacy-unset behavior → Task 1 (setTrim defaults) + existing tests kept. Params + defaults → Task 2. Threading (new/switch/step) → Task 3. Truthful logging → Task 4. Live tuning + layout budget → Task 5. Build/verify + owed in-world → Task 6. All spec sections covered.

**Placeholder scan:** No TBD/TODO. Every code and test step shows literal content. The one "match existing pattern" note (Task 5 Step 1/4) is a real, bounded instruction with a grep to resolve it, not a placeholder.

**Type consistency:** `setTrim(dir, gain, authority, fadeStart, fade)` — same 5-arg order in loop.lua (Task 1), flight.lua call sites (Task 3), and the flight test capture (`trimArgs[3..5]`). `diag().ffPitch` defined in Task 1, consumed in Task 4. Field names `trimAuthority`/`trimFadeStart`/`trimFade` identical across tuningdefaults (Task 2), flight seed/refresh (Task 3), and bitconfig ids `feel.trimAuthority`/`feel.trimFadeStart`/`feel.trimFade` (Task 5). Consistent.
