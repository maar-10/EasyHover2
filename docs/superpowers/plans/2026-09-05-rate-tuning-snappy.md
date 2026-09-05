# Rate Tuning + Snappy Release Implementation Plan (fix #4–#9)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Faster/snappier yaw + CRU strafe + PRE/MAN/DRN climb, and kill the climb-release bounce with a new altitude release-edge capture — all live-tunable, LDG unchanged.

**Architecture:** Aggressive default bumps in `fcs/io/tuningdefaults.lua` (per-mode, LDG pinned); a new altitude release-edge capture in `fcs/input/pilot.lua` mirroring the yaw one; two new snappiness rows (`yawStopLead`, `altStopLead`) in `ui/basalt/bitconfig/tuning.lua`'s shared FEEL rows.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0, luamin dist, headless CraftOS-PC tests.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-09-05-rate-tuning-snappy-design.md` — authority.
- **Default bumps (exact):** base `feel.headingRate` 2.2→**4.5**, `feel.leadCapHeading` 0.45→**1.1**,
  `feel.yawStopLead` 0.15→**0.05**, `feel.altStopLead` **0.10** (new field), `gains.alt.kp` 0.035→**0.06**,
  `feel.leadCapVert` 10.0→**14.0**. CRUISE overrides (new): `feel.headingRate`=**5.5**,
  `feel.leadCapHeading`=**1.5**, `feel.swaySpeed`=**10.0**, `feel.swayLead`=**20.0**. LDG overrides (new):
  `feel.headingRate`=**2.2**, `feel.leadCapHeading`=**0.45** (pin to today).
- **LDG must end unchanged**; CRU `alt.kp`/`leadCapVert` stay 0.045/12 (its own overrides); PRE/MAN/DRN
  inherit the base bumps.
- **#9 capture:** on climb/descend release, `sp.altitude = meas.altitude + altStopLead*meas.vSpeed`,
  edge-triggered via `climbWasHeld`, cleared in `reset`/`setMode`. Mirror the yaw capture at `pilot.lua:158-163`.
- **New BIT/CONFIG rows** appended to `SHARED_FEEL_EXTRA_ROWS`: `feel.yawStopLead` "YAW STOP LEAD" step
  0.01/0..1.0; `feel.altStopLead` "ALT STOP LEAD" step 0.01/0..1.0.
- **Test framework:** `require("tests.framework")` → `t.test/t.eq/t.near/t.truthy`.
- **Every fcs/** or ui/** edit:** `node tools/build.mjs` + `bash tools/run_gen.sh`, commit regenerated
  `dist/**` + `manifest.lua` + `manifest-dev.lua`; `bash tests/run_headless.sh` OK/exit 0;
  `bash tools/run_gen.sh --check` clean.
- **Commit trailer:** end every commit with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL`.

## File Structure

- **Modify** `fcs/io/tuningdefaults.lua` — base bumps + CRU/LDG overrides + new `altStopLead` field.
- **Modify** `fcs/input/pilot.lua` — altitude release-edge capture + `climbWasHeld` (init/reset/setMode).
- **Modify** `ui/basalt/bitconfig/tuning.lua` — 2 rows in `SHARED_FEEL_EXTRA_ROWS`.
- **Modify** tests: `test_tuning_modes.lua`/`test_tuningdefaults.lua`, `test_pilot.lua`, `test_bitconfig_tuning.lua`; possibly `modes_golden_data.lua` (regen).

---

### Task 1: Default bumps + `altStopLead` field (`tuningdefaults.lua`)

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (base `gains.alt`, base `feel`; CRUISE/LDG mode overrides)
- Test: `tests/test_tuning_modes.lua` (or `test_tuningdefaults.lua`)

**Interfaces:**
- Produces: the resolved per-mode values in the Global Constraints table; new `feel.altStopLead`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_tuning_modes.lua`)

```lua
t.test("rate-tuning defaults resolve per mode (fix #5-#9)", function()
  local T = require("fcs.tuning")
  local function feel(m) return T.forMode(m).feel end
  local function gains(m) return T.forMode(m).gains end
  -- base (PRECISION reads top-level)
  local pf, pg = feel("PRECISION"), gains("PRECISION")
  t.near(pf.headingRate, 4.5, 1e-9); t.near(pf.leadCapHeading, 1.1, 1e-9)
  t.near(pf.yawStopLead, 0.05, 1e-9); t.near(pf.altStopLead, 0.10, 1e-9)
  t.near(pf.leadCapVert, 14.0, 1e-9); t.near(pg.alt.kp, 0.06, 1e-9)
  -- MAN/DRN inherit the base bumps
  for _, m in ipairs({ "MAN", "DRN" }) do
    t.near(feel(m).headingRate, 4.5, 1e-9); t.near(feel(m).altStopLead, 0.10, 1e-9)
    t.near(gains(m).alt.kp, 0.06, 1e-9)
  end
  -- CRU: fastest yaw + strafe; keeps its own climb
  local cf, cg = feel("CRUISE"), gains("CRUISE")
  t.near(cf.headingRate, 5.5, 1e-9); t.near(cf.leadCapHeading, 1.5, 1e-9)
  t.near(cf.swaySpeed, 10.0, 1e-9); t.near(cf.swayLead, 20.0, 1e-9)
  t.near(cg.alt.kp, 0.045, 1e-9); t.near(cf.leadCapVert, 12.0, 1e-9)
  -- LDG unchanged
  local lf, lg = feel("LDG"), gains("LDG")
  t.near(lf.headingRate, 2.2, 1e-9); t.near(lf.leadCapHeading, 0.45, 1e-9)
  t.near(lg.alt.kp, 0.02, 1e-9); t.near(lf.leadCapVert, 8.0, 1e-9)
end)
```

(Confirm the correct accessor is `fcs.tuning.forMode` — see `test_tuning_modes.lua` header/existing cases;
if that file resolves modes differently, match its existing pattern.)

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (old values / `altStopLead` nil).

- [ ] **Step 3: Implement** — edit `fcs/io/tuningdefaults.lua`:
  - Base `gains.alt`: `kp = 0.035` → `kp = 0.06`.
  - Base `feel`: `headingRate = 2.2` → `4.5`; `leadCapHeading = 0.45` → `1.1`; `yawStopLead = 0.15` → `0.05`;
    `leadCapVert = 10.0` → `14.0`; add `altStopLead = 0.10` (near `yawStopLead`, with a one-line comment:
    predictive altitude stop-lead for the climb release capture, fix #9).
  - After the CRUISE block's existing overrides, add: `DEFAULTS.modes.CRUISE.feel.headingRate = 5.5`,
    `.leadCapHeading = 1.5`, `.swaySpeed = 10.0`, `.swayLead = 20.0`.
  - After the LDG block's existing overrides, add: `DEFAULTS.modes.LDG.feel.headingRate = 2.2`,
    `.leadCapHeading = 0.45` (pin — a comment: LDG stays as-tuned; the base yaw bump must not reach it).

- [ ] **Step 4: Run and verify it passes** — `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh`.
  If `test_modes_golden` shifts (the `alt.kp` change moves alt-bearing golden cases), regenerate the golden
  via `tools/capture_precision_golden.lua` inside CraftOS-PC (see `tests/run_focus.sh` for the invocation),
  confirm ONLY alt-bearing cases moved (yaw/roll/pitch/translate cases with unchanged gains must not), and
  include `tests/modes_golden_data.lua` in the commit. If nothing shifts, no golden change.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuning_modes.lua dist manifest.lua manifest-dev.lua
# + tests/modes_golden_data.lua IF regenerated
git commit -m "feat(fcs): aggressive yaw/strafe/climb default bumps + altStopLead (fix #5-#8)" # + trailer
```

---

### Task 2: Altitude release-edge capture (`pilot.lua`, fix #9)

**Files:**
- Modify: `fcs/input/pilot.lua` (init `climbWasHeld`; clear in `reset`/`setMode`; capture near the yaw capture)
- Test: `tests/test_pilot.lua`

**Interfaces:**
- Consumes: existing `ld` climb dir (`pilot.lua:73`), `self.cfg.altStopLead`, `meas.altitude`/`meas.vSpeed`.
- Produces: on climb/descend release, `sp.altitude` snaps to `meas.altitude + altStopLead*vSpeed`, held after.

- [ ] **Step 1: Write the failing test** (append to `tests/test_pilot.lua`, mirroring the yaw-capture tests at :66-92)

```lua
t.test("altitude release captures current alt + predictive stop, dropping the leashed lead (fix #9)", function()
  local CFG3 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, altStopLead = 0.1 }
  local p = Pilot.new(CFG3); p:reset(meas())
  -- hold climb: sp.altitude leads meas.altitude(10) by leadCapVert(2) -> 12
  local held = p:update(3.0, {up=true},
    { altitude=10, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(held.altitude, 12, 1e-9, "held: leashed +leadCapVert ahead")
  -- release at meas.altitude=11, vSpeed=1 -> capture 11 + 0.1*1 = 11.1 (NOT the 12 lead)
  local rel = p:update(0.1, {},
    { altitude=11, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(rel.altitude, 11.1, 1e-9, "release: current + predictive stop, not the leashed lead")
  t.truthy(rel.altitude < held.altitude, "setpoint drops behind the held lead -> no bounce")
end)

t.test("altitude release is edge-triggered: settled release holds alt, fights drift (fix #9)", function()
  local CFG3 = { headingRate = 1.0, leadCapHeading = 0.35, climbRate = 0.5, leadCapVert = 2.0,
    cruiseSpeed = 1.0, maxLead = 3.0, altStopLead = 0.0 }
  local p = Pilot.new(CFG3); p:reset(meas())
  p:update(1.0, {up=true}, { altitude=10, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  local r1 = p:update(0.1, {}, { altitude=11, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(r1.altitude, 11, 1e-9, "captured current alt (11) on the release edge")
  local r2 = p:update(0.1, {}, { altitude=13, heading=0, swayPos=0, surgePos=0, vSpeed=1, yawRate=0 })
  t.near(r2.altitude, 11, 1e-9, "held at 11, not re-tracking the 13 drift")
end)
```

(Check the file's `meas()` helper — if it doesn't include `vSpeed`, pass `vSpeed` explicitly as above.)

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (release retains the 12 lead).

- [ ] **Step 3: Implement** — in `fcs/input/pilot.lua`:
  - `Pilot.new`: add `climbWasHeld = false` to the initial state table.
  - `Pilot:reset` and `Pilot:setMode`: set `self.climbWasHeld = false` (alongside `self.yawWasHeld = false`).
  - Near the yaw release capture (after it), add the altitude capture. `ld` is already computed at
    `pilot.lua:73` (`dirOf(held,"down","up")`); reference it:

```lua
  -- Altitude release-edge capture (fix #9): mirror the yaw capture. On release of climb/descend, drop
  -- the leadCapVert lead and snap sp.altitude to current + a small predictive stop, so the craft holds
  -- where you released instead of climbing the lead out (the bounce). Edge-triggered (climbWasHeld).
  if ld ~= 0 then
    self.climbWasHeld = true
  elseif self.climbWasHeld then
    sp.altitude = (meas.altitude or sp.altitude) + (c.altStopLead or 0) * (meas.vSpeed or 0)
    self.climbWasHeld = false
  end
```

  (`c` is `self.cfg`, `sp` is `self.sp` — same locals the surrounding code uses. Place it before the
  final snapshot-copy return so the captured value is in the returned setpoint.)

- [ ] **Step 4: Run and verify it passes** — `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh` → OK. Pre-existing pilot tests green (the capture only fires on the climb release edge; held-climb and steady-hover behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot.lua dist manifest.lua manifest-dev.lua
git commit -m "feat(fcs): altitude release-edge capture - snappy climb, no bounce (fix #9)" # + trailer
```

---

### Task 3: BIT/CONFIG rows for `yawStopLead` + `altStopLead`

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua` (`SHARED_FEEL_EXTRA_ROWS`, ~L220-227)
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Consumes: the pure `M.rows`/`M.apply`/`pathFor` view-model (already handles `feel.*`).
- Produces: `feel.yawStopLead` + `feel.altStopLead` rows in every mode's MODE FEEL.

- [ ] **Step 1: Write the failing test** (append to `tests/test_bitconfig_tuning.lua`)

```lua
t.test("yaw/alt stop-lead rows present in MODE FEEL for all modes + apply writes path", function()
  local T = require("ui.basalt.bitconfig.tuning")
  for _, mode in ipairs({ "PRECISION", "MAN", "CRUISE", "LDG", "DRN" }) do
    local ids = {}
    for _, r in ipairs(T.rows({}, mode)) do ids[r.id] = true end
    t.truthy(ids["feel.yawStopLead"], mode .. " has YAW STOP LEAD")
    t.truthy(ids["feel.altStopLead"], mode .. " has ALT STOP LEAD")
  end
  -- apply writes the per-mode path (PRECISION = top-level), clamped to step
  local cfg = T.apply({}, "PRECISION", "feel.altStopLead", 1)  -- default 0.10, step 0.01 -> 0.11
  t.near(cfg.feel.altStopLead, 0.11, 1e-9)
  local cfg2 = T.apply({}, "CRUISE", "feel.yawStopLead", -1)   -- default 0.05, step 0.01 -> 0.04
  t.near(cfg2.modes.CRUISE.feel.yawStopLead, 0.04, 1e-9)
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (rows absent).

- [ ] **Step 3: Implement** — append to `SHARED_FEEL_EXTRA_ROWS` in `ui/basalt/bitconfig/tuning.lua`:

```lua
  { id = "feel.yawStopLead", label = "YAW STOP LEAD", group = "FEEL", step = 0.01, min = 0, max = 1.0 },
  { id = "feel.altStopLead", label = "ALT STOP LEAD", group = "FEEL", step = 0.01, min = 0, max = 1.0 },
```

- [ ] **Step 4: Run and verify it passes** — `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh` → OK. The MODE FEEL row-count regression test still passes: PRE/LDG grow 6→8 (fits, no scroll); CRU/MAN/DRN already scroll (windowing absorbs the +2). If the fit-regression test hard-codes a per-mode extra count, update it to the new counts.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua dist manifest.lua manifest-dev.lua
git commit -m "feat(ui): live-tunable YAW/ALT STOP LEAD rows (fix #6/#9)" # + trailer
```

---

## Self-Review

**Spec coverage:** #5 yaw rate (T1 base+CRU+LDG) ✓; #6 yawStopLead default + row (T1 + T3) ✓; #7 CRU strafe
(T1) ✓; #8 PRE/MAN/DRN climb (T1 base alt.kp/leadCapVert) ✓; #9 altitude capture (T2) + altStopLead field
(T1) + row (T3) ✓; LDG unchanged (T1 pins + inheritance test) ✓; #4 none ✓; golden regen contingency (T1
Step 4) ✓.

**Placeholder scan:** no TBD/TODO. The two "confirm the accessor / meas helper / fit-count" notes are
explicit verify-against-the-real-file instructions with the fallback stated, not open placeholders.

**Type consistency:** `feel.altStopLead`/`feel.yawStopLead` ids identical across T1 (defaults), T2 (pilot
reads `c.altStopLead`), T3 (rows). `climbWasHeld` init/reset/clear/use consistent within T2.

## Post-merge
- `superpowers:finishing-a-development-branch` → merge `--no-ff` to `main`, push, in-world verify (yaw
  faster + stops where released; CRU strafe faster; PRE/MAN/DRN climb faster + no release bounce; LDG
  unchanged; dial the rate + stop-lead rows to taste).
- This closes the CRU-extended flight-fixes batch (#1–#9). Update the roadmap + memory.
