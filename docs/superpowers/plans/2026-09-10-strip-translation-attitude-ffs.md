# Strip Translation→Attitude FFs (rate-robust CRU) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the CRU translation↔attitude limit cycle by defaulting the decouple FF off and making CRU trim forward-only (`brakeTrim=false`), keeping the code revivable, and commit the closed-loop rig as the acceptance test.

**Architecture:** Two isolated changes. (1) Tuning defaults: `decouple` gains → 0 (no-op the loop already honors) and `CRUISE.feel.brakeTrim` → false; no control-law code deleted. (2) Commit the reproduction rig (`tools/simrig*`) plus a relative-invariant regression test that proves stripping reduces the post-maneuver ring, independent of the shipped defaults.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), headless test harness via CraftOS-PC (`bash tests/run_headless.sh`), framework at `tests/framework.lua` (`t.test`, `t.eq`, `t.near`, `t.truthy`).

## Global Constraints

- Test runner: `bash tests/run_headless.sh` (whole suite; must be green + manifest IN SYNC at the end of each task).
- **Nothing deleted** — the decouple keeps its `setDecouple` method and loop FF (0 gains = no-op); prior values preserved in a comment. CRU trim keeps the accel-lean; only the brake-side lean is dropped.
- Do NOT change: the decouple FF math in `loop.lua`, the trim FF math, `caps.*`, `tiltBrake.*` curve values, or any other mode's `brakeTrim`.
- Exact values: `decouple = { swayRoll = 0, surgePitch = 0, authority = 0.3 }`; `CRUISE.feel.brakeTrim = false`.
- Angles are radians. ASCII-only comments, no em-dash (`--`). Follow existing EH2 comment idiom.
- Commit after each task; end commit messages with the attribution block used below.

---

### Task 1: Strip decouple + CRU brakeTrim (`fcs/io/tuningdefaults.lua`)

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (decouple gains → 0; `CRUISE.feel.brakeTrim` → false)
- Test: `tests/test_tuningdefaults.lua` (decouple block expectation), `tests/test_tuning_modes.lua` (CRU brakeTrim expectation)

**Interfaces:**
- Consumes: nothing new.
- Produces: `DEFAULTS.decouple = { swayRoll = 0, surgePitch = 0, authority = 0.3 }`; `DEFAULTS.modes.CRUISE.feel.brakeTrim = false`. Every other mode's `brakeTrim` and the whole `decouple`/`setDecouple` code path unchanged.

- [ ] **Step 1: Update the two failing test expectations**

In `tests/test_tuningdefaults.lua`, the test titled "defaults expose a decouple block (translation->attitude FF)" — replace the two `t.near` gain assertions so they expect the stripped defaults (keep the presence + authority checks):

```lua
t.test("defaults expose a decouple block (translation->attitude FF), stripped off", function()
  local d = require("fcs.io.tuningdefaults").get()
  t.truthy(d.decouple, "decouple present")
  t.near(d.decouple.swayRoll, 0, 1e-9, "swayRoll stripped to 0 (was 0.10)")
  t.near(d.decouple.surgePitch, 0, 1e-9, "surgePitch stripped to 0 (was -0.05)")
  t.near(d.decouple.authority, 0.3, 1e-9, "authority preserved for revival")
end)
```

In `tests/test_tuning_modes.lua`, the test titled "brakeTrim: symmetric (tilt-to-brake) only in CRU/DRN, forward-only elsewhere" — change the CRU line and the test title/DRN note to reflect CRU now forward-only (DRN stays symmetric):

```lua
t.test("brakeTrim: symmetric only in DRN, forward-only elsewhere (CRU stripped 2026-09-10)", function()
  t.eq(tuning.forMode("CRUISE").feel.brakeTrim, false, "CRU forward-only (brake-side lean stripped)")
  t.eq(tuning.forMode("DRN").feel.brakeTrim,    true,  "DRN keeps symmetric (pitch is its accel/decel)")
  t.eq(tuning.forMode("PRECISION").feel.brakeTrim, false, "PRE forward-only")
  t.eq(tuning.forMode("MAN").feel.brakeTrim,    false, "MAN forward-only")
  t.eq(tuning.forMode("LDG").feel.brakeTrim,    false, "LDG forward-only")
end)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: the two updated tests FAIL (source still has `swayRoll=0.10`/`surgePitch=-0.05` and CRU `brakeTrim=true`).

- [ ] **Step 3: Strip the decouple gains**

In `fcs/io/tuningdefaults.lua`, replace the `decouple` line (currently
`decouple = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 },`) and its preceding
comment with:

```lua
  -- Translation->attitude decoupling FF: STRIPPED 2026-09-10 (defaulted off). It amplified the
  -- coupling it was meant to cancel (rig: doubled the roll ring 22->43deg) and drove the CRU
  -- limit cycle; the craft was stable before it. setDecouple + the loop FF (fcs/runtime/loop.lua)
  -- are KEPT -- 0 gains are a no-op there -- so a correctly-signed, rig-validated version can be
  -- rebuilt later. Prior values: swayRoll = 0.10, surgePitch = -0.05.
  decouple = { swayRoll = 0, surgePitch = 0, authority = 0.3 },
```

- [ ] **Step 4: Make CRU trim forward-only**

In `fcs/io/tuningdefaults.lua`, replace the line `DEFAULTS.modes.CRUISE.feel.brakeTrim   = true`
(and its preceding comment `-- CRU keeps the symmetric trim: ...`) with:

```lua
-- CRU trim STRIPPED to forward-only 2026-09-10 (was true / symmetric "lean back to brake hard").
-- The brake-side lean fed the post-brake pitch ring (rig: brakeTrim=false drops it 44->9deg).
-- Accel lean kept (forward-only, like every other mode). Revisit if a damped brake-lean is wanted.
DEFAULTS.modes.CRUISE.feel.brakeTrim   = false
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: the two updated tests PASS; whole suite green; manifest IN SYNC. (The decouple/trim
mechanism tests in `test_loop_trim.lua` still pass — they pass explicit gains to the retained
code path. `test_buildloop_modes.lua` still passes — it asserts `loop.decoupleSwayRoll ==
tuning.decouple.swayRoll`; both are 0 now.)

- [ ] **Step 6: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "$(cat <<'EOF'
fix(fcs): strip destabilizing translation->attitude FFs (decouple off, CRU brakeTrim off)

Default the decouple FF off (gains 0; setDecouple + loop FF kept for a future
rig-validated rebuild -- 0 is a no-op) and make CRU trim forward-only. The
decouple amplified the coupling it was meant to cancel (rig: roll ring
22->43deg) and the symmetric brake-lean fed the post-brake pitch ring; both
drove the CRU limit cycle. Rig: post-maneuver ring 44/43 -> 9/19 deg,
rate-independent (5-20Hz). Accel trim + tilt-brake kept.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 2: Commit the reproduction rig + relative-invariant regression test

**Files:**
- Modify: `tools/simrig.lua` (add explicit `decoupleGains`/`brakeTrim` overrides so tests are independent of shipped defaults)
- Add (commit existing): `tools/simrig.lua`, `tools/simrig_run.lua`, `tools/run_simrig.sh`
- Test: `tests/test_simrig.lua` (new)

**Interfaces:**
- Consumes: `require("tools.simrig_run")` exposing `run(simParams, toggles, dt, script)`,
  `SURGE`, `STRAFE`. `run` returns a table keyed by phase tag; `SURGE` has phase `recover`
  with `.peakP` (deg), `STRAFE` has phase `srecover` with `.peakR` (deg).
- Produces: `buildStack(simParams, toggles)` now honors `toggles.decoupleGains` (a table
  `{swayRoll, surgePitch, authority}` set verbatim via `loop:setDecouple`) and
  `toggles.brakeTrim` (explicit `true`/`false`), so a test can pin the coupled vs stripped
  configs regardless of the defaults.

- [ ] **Step 1: Add explicit overrides to the rig (`tools/simrig.lua`)**

In `tools/simrig.lua`, in `buildStack`, replace the decouple-toggle line:

```lua
  if not on("decouple") and loop.setDecouple then loop:setDecouple({ swayRoll=0, surgePitch=0, authority=0 }) end
```

with (explicit gains win, else on/off relative to defaults):

```lua
  if toggles.decoupleGains and loop.setDecouple then loop:setDecouple(toggles.decoupleGains)
  elseif not on("decouple") and loop.setDecouple then loop:setDecouple({ swayRoll=0, surgePitch=0, authority=0 }) end
```

And replace the brakeTrim line:

```lua
    if toggles.brakeTrim == false then cf.brakeTrim = false end   -- forward-only trim (accel lean kept)
```

with (allow forcing true OR false):

```lua
    if toggles.brakeTrim ~= nil then cf.brakeTrim = toggles.brakeTrim end   -- force fwd-only (false) or symmetric (true)
```

- [ ] **Step 2: Write the failing regression test (`tests/test_simrig.lua`)**

Create `tests/test_simrig.lua`:

```lua
-- tests/test_simrig.lua -- relative-invariant guard on the closed-loop rig: stripping the
-- translation->attitude FFs (decouple off + CRU brakeTrim off) must ring LESS than the coupled
-- config under identical sim physics. Robust to the exact sim params (compares A vs B, same plant).
local t = require("tests.framework")
local rig = require("tools.simrig_run")

local P = { spoolTime = 0.5, tiltTrans = 1.0, latRoll = 0.6, surgePitch = 0.1 }
local COUPLED = { decoupleGains = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 }, brakeTrim = true }
local STRIP   = { decoupleGains = { swayRoll = 0,    surgePitch = 0,     authority = 0.3 }, brakeTrim = false }

t.test("simrig: stripping FFs reduces the post-brake pitch ring", function()
  local c = rig.run(P, COUPLED, 0.1, rig.SURGE)
  local s = rig.run(P, STRIP,   0.1, rig.SURGE)
  t.truthy(s.recover.peakP < c.recover.peakP,
    string.format("stripped pitch ring %.1f < coupled %.1f", s.recover.peakP, c.recover.peakP))
  t.truthy(s.recover.peakP < 20,
    string.format("stripped pitch ring under 20deg (got %.1f)", s.recover.peakP))
end)

t.test("simrig: stripping FFs reduces the post-strafe roll ring", function()
  local c = rig.run(P, COUPLED, 0.1, rig.STRAFE)
  local s = rig.run(P, STRIP,   0.1, rig.STRAFE)
  t.truthy(s.srecover.peakR < c.srecover.peakR,
    string.format("stripped roll ring %.1f < coupled %.1f", s.srecover.peakR, c.srecover.peakR))
  t.truthy(s.srecover.peakR < 30,
    string.format("stripped roll ring under 30deg (got %.1f)", s.srecover.peakR))
end)
```

- [ ] **Step 3: Run the test to verify it passes (rig loads + invariant holds)**

Run: `bash tests/run_headless.sh`
Expected: both `test_simrig` cases PASS (rig loads under the harness; coupled rings ~44/43,
stripped ~9/19). If the harness cannot `require("tools.simrig_run")` (tools/ not copied into
the CraftOS data dir by `run_headless.sh`), STOP and report BLOCKED — do not weaken the test;
the controller will decide whether to make the rig tooling-only.

- [ ] **Step 4: Sanity-run the rig report (tooling smoke check)**

Run: `bash tools/run_simrig.sh`
Expected: prints the isolation matrix; the "PROPOSED: decpl off + brakeTrim=false" row shows
~9 pitch / ~19 roll at 10 Hz. (No assertion; just confirms the tool runs end-to-end.)

- [ ] **Step 5: Commit**

```bash
git add tools/simrig.lua tools/simrig_run.lua tools/run_simrig.sh tests/test_simrig.lua
git commit -m "$(cat <<'EOF'
test(fcs): closed-loop reproduction rig + relative-invariant guard for the FF strip

simrig flies the production Flight->Loop stack against a physics sim that adds
the spool ramp, tilt->translate coupling, and off-CoM torque the base sim
omits -- reproducing the CRU limit cycle (post-brake ring ~35-45deg, matching
the logs). test_simrig asserts the strip rings strictly less than the coupled
config under identical physics (robust to exact params). Dev tooling; not in
any role manifest closure.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

## Self-Review

**1. Spec coverage:**
- Spec §A (decouple default-off, code kept) → Task 1 Step 3. ✓
- Spec §B (CRU brakeTrim=false) → Task 1 Step 4. ✓
- Spec §C (commit rig) → Task 2 Steps 1,5. ✓
- Spec §D (test updates + new relative-invariant test) → Task 1 Steps 1-2, Task 2 Steps 2-3. ✓
- Spec §Acceptance (rig ring, suite green) → Task 2 Steps 3-4. ✓
- Spec out-of-scope (residual cascade, decouple redesign, loop-rate) → untouched. ✓

**2. Placeholder scan:** No TBD/TODO; all steps carry concrete code and exact run/expected lines. The one contingency (Task 2 Step 3 BLOCKED if tools/ not on the harness path) is an explicit escalation, not a placeholder.

**3. Type consistency:** `rig.run(P, toggles, dt, script)` returns phase-keyed table; `SURGE.recover.peakP` and `STRAFE.srecover.peakR` match the tags/fields produced in `simrig_run.lua`. `toggles.decoupleGains` (table) and `toggles.brakeTrim` (bool) consumed in `buildStack` exactly as produced by the test. Stripped values `{0,0,0.3}` / `brakeTrim=false` consistent across spec, Task 1, and Task 2's STRIP config.

## OWED (post-implementation, in-world)

- Deploy (build dist + regen manifests, per `eh2-deploy-pipeline`), SuiteX update.
- Verify CRU is controllable in climb / forward-surge / brake / strafe at low thrust; the
  decouple and symmetric brake-lean remain revivable.
- If the residual ring (~9° pitch / ~20° roll) still feels wallowy, open the deferred batch:
  active tilt-velocity damping on the base cascade.
