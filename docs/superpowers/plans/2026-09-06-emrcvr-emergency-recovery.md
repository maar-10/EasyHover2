# EMRCVR Emergency Recovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A safety mode that trips on >75° tilt, locks out pilot/UI, aggressively rights the craft to a level hover (even inverted), restores the pre-trip altitude, and exits to a clean PRE/CPL hover — abortable only by disengaging the FCS.

**Architecture:** `flight.lua` owns the EMRCVR latch (detect / recovery setpoints / gain-mutation / exit / command gating); `loop.lua` gains an `EMRCVR` mode (elevated-authority attitude correction, DAMPED suppressed); an `emrcvr` config block feeds tunable thresholds, exposed as a new global BIT/CONFIG screen.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0, luamin dist, headless CraftOS-PC tests.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-09-06-emrcvr-emergency-recovery-design.md` — authority.
- **Trip:** `|pitch|>tripAngle OR |roll|>tripAngle`, engaged + airborne (`meas.onGround ~= true`). Defaults:
  `tripAngle=1.309 (75°)`, `exitAngle=0.175 (10°)`, `maxDrift=2.0`, `dwell=0.5`, `levelBand=0.5`,
  `kpAtt=0.6`, `capAtt=0.8` (rad).
- **No give-up timeout** — latched until stable-hover exit; the only abort is FCS `disengage`.
- **Exit:** `|pitch|,|roll|<exitAngle` AND `hypot(surgeVel,swayVel)<maxDrift`, held `dwell` → restore saved
  kp/caps, `loop:setEmrcvr(false)`, re-apply master→CPL + flight→PRECISION (unconditionally, via shared
  helpers), `pilot:reset(meas)`, clear latch.
- **Command gating while latched:** block `flightMode`/`masterMode`/`gndSafety`/`positionHold`/`comAuto`/
  `setCom`/`flightTrim`/`fuel`/`paramsWatch`/`clearDamped`; allow `engage`/`disengage`/`fuelPump`.
- **Loop:** `EMRCVR` mode is top priority, does NOT zero attitude, suppresses the osc trip; `setEmrcvr(false)`
  resets the osc detector.
- **Attitude is full ±180°** (verified) — recovery error `0−meas` drives shortest path; inverted works.
- **Gain restore scoping:** save the mutated scheme reference at entry; restore kp to THAT scheme (not
  whatever is active at exit) — mirrors the comAuto ki-scoping (`flight.lua:_restoreComKi`).
- **Test framework:** `require("tests.framework")` → `t.test/t.eq/t.near/t.truthy`. New `test_flight_emrcvr.lua`
  must be registered in the `suites` list of BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh`.
- **Every fcs/** or ui/** edit:** `node tools/build.mjs` + `bash tools/run_gen.sh`, commit regenerated
  `dist/**` + `manifest.lua` + `manifest-dev.lua`; `bash tests/run_headless.sh` OK/exit 0; `run_gen.sh --check` clean.
- **Commit trailer:** end every commit with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL`.

## File Structure

- **Modify** `fcs/runtime/loop.lua` — `setEmrcvr` + EMRCVR mode in `cycle`.
- **Modify** `fcs/io/tuningdefaults.lua` — `emrcvr` config block; thread it to flight via the runtime wiring.
- **Modify** `fcs/runtime/flight.lua` — extract mode-transition helpers; EMRCVR state machine in `step`;
  command gating in `handleCommand`; `snapshot.mode` priority; live threshold setter.
- **Modify** `ui/basalt/bitconfig/tuning.lua` — global EMRCVR screen (3 rows).
- **Modify** the runtime that constructs `Flight` (e.g. `tools/flight.lua` / the bringup wiring) — pass the
  `emrcvr` config into flight's deps. (Find the `Flight.new{...}` call site.)
- **Create** `tests/test_flight_emrcvr.lua`; **modify** `test_loop*.lua`, `test_tuningdefaults.lua`,
  `test_bitconfig_tuning.lua`, and the two `run_headless*.sh`.

---

### Task 1: `loop.lua` EMRCVR mode

**Files:** Modify `fcs/runtime/loop.lua`; Test `tests/test_loop.lua` (or a focused new case there).

**Interfaces:** Produces `Loop:setEmrcvr(b)`; when set, `cycle` reports `mode=="EMRCVR"`, does NOT zero
attitude demands, and suppresses the osc trip; `setEmrcvr(false)` resets the osc detector.

- [ ] **Step 1: Write the failing test** (append to `tests/test_loop.lua`, matching its existing loop-construction harness)

```lua
t.test("EMRCVR mode: active attitude correction, DAMPED suppressed", function()
  -- build a loop with an osc detector primed to trip; assert setEmrcvr overrides it
  -- (reuse this file's existing loop/scheme/mixer/backend construction helper)
  local loop = <build a loop with cfg.osc set>   -- see existing test_loop setup
  loop:setEmrcvr(true)
  local r = loop:cycle(0.05, { pitch = 1.2, roll = 0.0, altitude = 0, heading = 0 })
  t.eq(r.mode, "EMRCVR")
  t.truthy((r.demands.pitch or 0) ~= 0, "attitude demand NOT zeroed in EMRCVR (unlike DAMPED)")
  loop:setEmrcvr(false)
  t.truthy(loop:getMode() ~= "EMRCVR", "mode leaves EMRCVR when cleared")
end)
```

(Adapt the loop construction to whatever `test_loop.lua` already uses — arm it, give it a scheme + caps
so `demands.pitch` is nonzero for a tilted `m.pitch`.)

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (`setEmrcvr` nil).

- [ ] **Step 3: Implement** — in `fcs/runtime/loop.lua`:

```lua
function Loop:setEmrcvr(b)
  self._emrcvr = b and true or false
  if not self._emrcvr and self.osc then self.osc:reset() end   -- clean slate on exit
end
```

In `cycle`'s mode block (replace the `tripped`/`self.mode =` lines ~106-107):

```lua
  -- EMRCVR (emergency recovery) is top priority and mirrors DAMPED: it must NOT zero attitude (the
  -- flight layer feeds level setpoints + elevated gains to actively right the craft), and it suppresses
  -- the osc trip so the detector can't zero the correction that is righting a violent tumble.
  local tripped = (not self._emrcvr) and self.osc and self.osc:update(m.pitch, m.roll, dt) or false
  self.mode = self._emrcvr and "EMRCVR" or (tripped and "DAMPED" or (grounded and "GROUND" or "NORMAL"))
  if self.mode == "DAMPED" then
    -- (unchanged zeroing block; EMRCVR never enters here)
```

- [ ] **Step 4: Run and verify it passes** — `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh` → OK. Existing DAMPED/loop tests green (EMRCVR defaults off; behavior unchanged when `_emrcvr` nil).

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop.lua dist manifest.lua manifest-dev.lua
git commit -m "feat(fcs): loop EMRCVR mode - active righting, DAMPED suppressed" # + trailer
```

---

### Task 2: `emrcvr` config block + threading to flight

**Files:** Modify `fcs/io/tuningdefaults.lua`; the `Flight.new{...}` call site (grep for it — likely
`tools/flight.lua` / bringup); `fcs/runtime/flight.lua` (accept + store + live setter). Test
`tests/test_tuningdefaults.lua`, `tests/test_flight_emrcvr.lua` (create + register).

**Interfaces:** Produces `DEFAULTS.emrcvr` (the block from Global Constraints); `Flight.new` accepts
`deps.emrcvr` (falls back to the defaults); `Flight:setEmrcvrCfg(tbl)` merges live updates.

- [ ] **Step 1: Write failing tests** — (a) in `test_tuningdefaults.lua`: `require("fcs.io.tuningdefaults").get().emrcvr.tripAngle == 1.309` etc. (all 7 fields). (b) create `tests/test_flight_emrcvr.lua` with a first case asserting a `Flight.new{}` with no `emrcvr` dep still exposes working defaults (e.g. via a getter or by tripping at 75° in Task 3 — for now assert `flight` constructs and `flight.emr` (or however stored) has `tripAngle==1.309`). Register `tests.test_flight_emrcvr` in both `run_headless.sh` and `run_headless_dist.sh` suites lists.

- [ ] **Step 2: Run and verify it fails.**

- [ ] **Step 3: Implement** — add to `tuningdefaults.lua` (top level, near `osc`):

```lua
  emrcvr = { tripAngle = 1.309, exitAngle = 0.175, maxDrift = 2.0, dwell = 0.5,
             levelBand = 0.5, kpAtt = 0.6, capAtt = 0.8 },
```

In `flight.lua:new`, store `self.emr = deps.emrcvr or require("fcs.io.tuningdefaults").get().emrcvr` (deep-copy). Add:

```lua
function Flight:setEmrcvrCfg(t)
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do if type(v) == "number" then self.emr[k] = v end end
end
```

Wire `emrcvr = <tuning>.emrcvr` into the `Flight.new{...}` deps at the runtime construction site (mirror
how `osc`/tuning already flow there).

- [ ] **Step 4: Run and verify passes.** (`node build`, `run_gen`, `run_headless` OK.)

- [ ] **Step 5: Commit** (`fcs/io/tuningdefaults.lua`, `fcs/runtime/flight.lua`, the wiring file, both tests, both run_headless scripts, dist, manifests).

---

### Task 3: `flight.lua` EMRCVR state machine (detect / recover / exit)

**Files:** Modify `fcs/runtime/flight.lua`; Test `tests/test_flight_emrcvr.lua`.

**Interfaces:** Consumes `self.emr` (Task 2), `loop:setEmrcvr` (Task 1). Produces the latch `self.emrcvr`,
recovery setpoints, gain/caps mutation, exit→CPL/PRE, and `snapshot.mode=="EMRCVR"`.

- [ ] **Step 1: Extract shared mode-transition helpers first** (behavior-preserving refactor). Pull the
`flightMode` branch body (`flight.lua:~104-130`) into `Flight:_applyFlightMode(id)` and the `masterMode`
branch body (`~137-141`) into `Flight:_applyMasterMode(id)`; have both `handleCommand` branches call the
helpers. Run `bash tests/run_headless.sh` → all existing flight/mode tests still green (pure refactor).

- [ ] **Step 2: Write the failing EMRCVR tests** (in `tests/test_flight_emrcvr.lua`) — use the project's
Flight test harness (see `tests/test_flight.lua`/`test_flight_modes.lua` for how Flight is constructed
with mock loop/pilot/backend). Cover: trip at 80° airborne+engaged sets `snapshot.mode=="EMRCVR"` and
ignores held input; grounded/disengaged 80° does NOT trip; recovery setpoints (pitch/roll 0; alt=meas
while >levelBand, alt=captured-trip-alt while <levelBand; translate frozen); entry mutates the scheme
pitch/roll kp + loop caps to `kpAtt/capAtt` and exit restores the exact saved values to the same scheme;
exit only after `<exitAngle` & `<maxDrift` held `dwell`, then master=CPL + flightMode=PRECISION applied
and `pilot:reset` called; an inverted `pitch=170°` yields a nonzero (leveling) pitch demand; an active
comAuto is suspended while latched.

- [ ] **Step 3: Run and verify they fail.**

- [ ] **Step 4: Implement the state machine** in `Flight:step` (place the EMRCVR check at the top of the
`self.engaged` block, before the parked/comAuto/pilot branches so it overrides them). Sketch:

```lua
-- EMRCVR emergency recovery (top priority within engaged): detect >tripAngle tilt while airborne,
-- lock out pilot/UI, right the craft with elevated authority, restore altitude, exit to a clean hover.
local emr = self.emr
local tiltMag = math.max(math.abs(meas.pitch or 0), math.abs(meas.roll or 0))
local airborne = not (meas.onGround == true)
if self.engaged and not self.emrcvr and airborne and tiltMag > emr.tripAngle then
  self:_emrEnter(meas)
end
if self.emrcvr then
  self:_emrStep(dt, meas)
  local r = self.loop:cycle(dt, meas)
  self.lastDiag = r
  if dt > 0 then self._loopHz = 1 / dt end
  return self:snapshot(r, meas)
end
-- ... existing engaged logic unchanged below ...
```

Helpers:

```lua
function Flight:_emrEnter(meas)
  self.emrcvr = true
  self.emrcvrAlt = meas.altitude          -- restore target
  self.emrStableT = 0
  if self.comAuto and self.comAuto.abort then self.comAuto:abort("EMRCVR") end
  -- elevate attitude authority; SCOPE the save to the exact scheme we mutate (comAuto-style)
  local sch = self.loop.scheme
  self._emrSch = sch
  self._emrSaved = { kp_p = sch.pitchPid.kp, kp_r = sch.rollPid.kp, caps = self.loop.caps }
  sch.pitchPid.kp, sch.rollPid.kp = self.emr.kpAtt, self.emr.kpAtt
  self.loop.caps = { pitch = self.emr.capAtt, roll = self.emr.capAtt,
                     yaw = self._emrSaved.caps.yaw, sway = self._emrSaved.caps.sway, surge = self._emrSaved.caps.surge }
  if self.loop.setEmrcvr then self.loop:setEmrcvr(true) end
  self.pilot:setPositionHold(false)
end

function Flight:_emrStep(dt, meas)
  local emr = self.emr
  local tiltMag = math.max(math.abs(meas.pitch or 0), math.abs(meas.roll or 0))
  local alt = (tiltMag < emr.levelBand) and self.emrcvrAlt or meas.altitude
  self.loop:setpoints({ pitch = 0, roll = 0, heading = meas.heading,
                        altitude = alt, swayPos = meas.swayPos, surgePos = meas.surgePos })
  self.loop:arm(true)
  local drift = math.sqrt((meas.surgeVel or 0)^2 + (meas.swayVel or 0)^2)
  if math.abs(meas.pitch or 0) < emr.exitAngle and math.abs(meas.roll or 0) < emr.exitAngle
     and drift < emr.maxDrift then
    self.emrStableT = (self.emrStableT or 0) + (dt > 0 and dt or 0)
    if self.emrStableT >= emr.dwell then self:_emrExit(meas) end
  else
    self.emrStableT = 0
  end
end

function Flight:_emrExit(meas)
  -- restore the exact scheme we mutated (not whatever is active now)
  local sch = self._emrSch
  if sch and self._emrSaved then
    sch.pitchPid.kp = self._emrSaved.kp_p; sch.rollPid.kp = self._emrSaved.kp_r
    self.loop.caps = self._emrSaved.caps
  end
  self._emrSch, self._emrSaved = nil, nil
  if self.loop.setEmrcvr then self.loop:setEmrcvr(false) end
  self.emrcvr = false; self.emrStableT = 0
  self:_applyMasterMode("CPL")            -- clean slate (Task 3 Step 1 helpers)
  self:_applyFlightMode("PRECISION")
  if self.pilot.reset then self.pilot:reset(meas) end
end
```

`snapshot` (`flight.lua:335`): make EMRCVR top priority —
`mode = self.emrcvr and "EMRCVR" or (self.parked and "PARKED" or ((r and r.mode) or self.loop:getMode()))`,
and add `emrcvr = self.emrcvr and true or false` to the snapshot table.

Init `self.emrcvr=false`, `self.emrcvrAlt`, `self.emrStableT`, `self._emrSch`, `self._emrSaved` in `Flight.new`.

**Verify the scheme shape:** `self.loop.scheme.pitchPid`/`rollPid` — for CRUISE/DRN the scheme wraps an
`inner` (see `fcs/schemes/cruise.lua`/`drone.lua`). Use `(self.loop.scheme.inner or self.loop.scheme)`
for the PID access (mirror `loop:diag`'s `level = scheme.inner or scheme`). Fix the helper accordingly.

- [ ] **Step 5: Run and verify passes** — all EMRCVR tests green; existing flight tests green.

- [ ] **Step 6: Commit** (`fcs/runtime/flight.lua`, `tests/test_flight_emrcvr.lua`, dist, manifests).

---

### Task 4: `handleCommand` gating while latched

**Files:** Modify `fcs/runtime/flight.lua:handleCommand`; Test `tests/test_flight_emrcvr.lua`.

**Interfaces:** While `self.emrcvr`, `handleCommand` returns false for blocked commands, still acts on the allowed ones.

- [ ] **Step 1: Write the failing test** — while latched: `handleCommand{k="flightMode",id="CRUISE"}`→false
(mode unchanged), `{k="masterMode",id="DCPL"}`→false, `{k="gndSafety",on=true}`→false; but
`{k="fuelPump",on=true}` acts, and `{k="disengage"}` disengages (clears the latch via the normal path).

- [ ] **Step 2: Run and verify it fails.**

- [ ] **Step 3: Implement** — at the top of `Flight:handleCommand`, after `local k = cmd and cmd.k`:

```lua
  -- EMRCVR lockout: while recovering, only ENG SW (fuelPump) and FCS engage/disengage are honored.
  -- disengage is the sole abort; the hardware fuel relay + gndSafety interlock remain the physical override.
  if self.emrcvr and not (k == "disengage" or k == "engage" or k == "fuelPump") then
    return false
  end
```

(`disengage` runs its normal branch; ensure the latch is cleared on disengage — add `self.emrcvr=false`
and restore any saved gains in the `disengage` branch via `if self._emrSaved then <restore> end`, or call
a shared `_emrAbort()` so a disengage mid-recovery doesn't strand the mutated kp/caps.)

- [ ] **Step 4: Run and verify passes.**

- [ ] **Step 5: Commit.**

---

### Task 5: BIT/CONFIG EMRCVR screen (3 tunable rows)

**Files:** Modify `ui/basalt/bitconfig/tuning.lua`; Test `tests/test_bitconfig_tuning.lua`. Plus a
`basalt-render` check (controller).

**Interfaces:** A global "EMRCVR" screen (sibling of COM/AUTO COM) with rows editing
`emrcvr.tripAngle` / `emrcvr.exitAngle` / `emrcvr.maxDrift`; edits flow to `Flight:setEmrcvrCfg` via the
existing live-apply/config-courier path.

- [ ] **Step 1: Write the failing test** — the EMRCVR row spec exists (`emrcvr.tripAngle` etc. present with
step/min/max), and `M.apply({}, nil, "emrcvr.tripAngle", 1)` writes `emrcvr.tripAngle` clamped (these are
global paths, not per-mode — follow the COM_SPEC pattern which uses top-level `com.*` paths and
`M.pathFor` returns them as-is). Rows: TRIP ANGLE (step 0.05, 0.5..1.8 rad), EXIT ANGLE (step 0.02,
0..0.6), MAX DRIFT (step 0.5, 0..20).

- [ ] **Step 2: Run and verify it fails.**

- [ ] **Step 3: Implement** — add an `EMRCVR_SPEC` (mirroring `COM_SPEC`, `tuning.lua:178-184`):

```lua
local EMRCVR_SPEC = {
  { id = "emrcvr.tripAngle", label = "TRIP ANGLE", group = "EMRCVR", step = 0.05, min = 0.5, max = 1.8 },
  { id = "emrcvr.exitAngle", label = "EXIT ANGLE", group = "EMRCVR", step = 0.02, min = 0,   max = 0.6 },
  { id = "emrcvr.maxDrift",  label = "MAX DRIFT",  group = "EMRCVR", step = 0.5,  min = 0,   max = 20  },
}
M.EMRCVR_SPEC = EMRCVR_SPEC
```

Register it in `SPEC_BY_ID`; make `M.pathFor` treat `emrcvr.*` as top-level (add `if dotted:sub(1,7)=="emrcvr." then return dotted end`, like the `com.` guard at `:203`); add an EMRCVR button + screen to the tuning region root next to the COM screen (mirror `buildComScreen` + its registration — a global stepper-edit screen over `EMRCVR_SPEC`). Reuse `buildEditScreen`-style rows or the COM screen's builder.

- [ ] **Step 4: Run and verify passes** — `node build`, `run_gen`, `run_headless` OK; the tuning-menu
fit/nav tests still green (new screen fits at 36×10 — 3 rows).

- [ ] **Step 5: Controller `basalt-render`** of the EMRCVR screen (add a `render_panel.lua` recipe pushing
the EMRCVR screen; `render.sh` + `render_png.sh`; the controller Reads the PNG) to confirm layout. (This
step is performed by the controller, not the implementer.)

- [ ] **Step 6: Commit.**

---

## Self-Review

**Spec coverage:** loop EMRCVR mode + DAMPED suppression (T1) ✓; config + threading + live setter (T2) ✓;
detect/latch/recovery two-phase/gain-mutation-scoped/exit→CPL+PRE/snapshot/comAuto-override (T3) ✓; command
gating whitelist + disengage-abort-doesn't-strand-gains (T4) ✓; 3 tunable rows + global screen (T5) ✓;
inverted recovery (T3 test at 170°) ✓; airborne+engaged gating (T3) ✓.

**Placeholder scan:** the loop/flight test harness references ("reuse the existing construction",
"see test_flight.lua") point at real in-repo patterns the implementer must match — not invented APIs; the
code blocks are concrete. The scheme-`inner` access note is an explicit verify-and-adapt instruction.

**Type consistency:** `self.emr` fields, `loop:setEmrcvr`, `_emrEnter/_emrStep/_emrExit/_emrAbort`,
`_emrSch/_emrSaved`, `_applyFlightMode/_applyMasterMode` used consistently across T1–T4. `emrcvr.*` config
paths consistent across T2/T5.

## Post-merge
- `superpowers:finishing-a-development-branch` → merge `--no-ff` to `main`, push.
- In-world: tip past 75° and fully flip; confirm lockout, aggressive righting to level hover, altitude
  restore, exit to PRE/CPL; confirm FCS-disengage aborts mid-recovery (no stranded gains); dial the 3
  thresholds. Update the roadmap's deferred "extreme-attitude auto-recovery" item to shipped + memory.
