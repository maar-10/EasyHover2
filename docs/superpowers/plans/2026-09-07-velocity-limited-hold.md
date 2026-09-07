# Velocity-Limited Position Hold (sway & surge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the saturating PD position-hold for sway and surge with a velocity-limited cascade so the lateral hover hold can no longer diverge into a growing oscillation.

**Architecture:** The hold becomes two stages: an outer P on position error producing a *bounded* velocity target (`clamp(ka·err, ±vmax)`), and an inner P on velocity (`ks·(velTarget − vel)`) producing the duty. Because the commanded velocity is capped, momentum is bounded and the craft can always arrest → the diverging bang-bang is structurally impossible. The pilot rate-command path (`Translate:rate`) is untouched; only the hold changes. `vmax` reuses each mode's existing `feel.swaySpeed`/`surgeSpeed`, carried to the scheme on the setpoint table.

**Tech Stack:** Lua 5.1 (CC:Tweaked), headless test suite via CraftOS-PC. Spec: `docs/superpowers/specs/2026-09-07-velocity-limited-hold-design.md`.

## Global Constraints

- Target runtime: CC:Tweaked Lua 5.1 — no Lua 5.2+ idioms.
- The pilot rate-command path (`Translate:rate` = `ks·(cmd − vel)`) MUST stay behaviorally identical — active strafing feel does not change.
- `Translate:hold` MUST be stateless (no integrator): repeated calls with the same args return the same value; no `reset()` needed for correctness.
- Reconstruction invariant: `Translate:terms(...)` must return `{err, P, I, D}` with `P + I + D == Translate:hold(...)` for the same inputs (`I == 0`).
- Gains live in `fcs/io/tuningdefaults.lua` (single source; `cfgspec.lua` deep-merges from it — do NOT add per-gain descriptors there).
- Full green = three gates, in order: `bash tests/run_headless.sh` (src), then `node tools/build.mjs && bash tools/run_gen.sh` (rebuild dist + manifest), then `bash tests/run_headless_dist.sh` (dist) and `bash tests/run_suite_e2e.sh` (e2e).
- Commit message trailer on every commit:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL`

---

## File Structure

- `fcs/control/translate.lua` — MODIFY: add `hold()`, rewrite `terms()`, retire `update()`; `rate()` unchanged.
- `fcs/schemes/level_flight.lua` — MODIFY: sway/surge hold branches call `hold()`; `terms()` passes vmax.
- `fcs/input/pilot.lua` — MODIFY: publish `sp.swayVmax`/`sp.surgeVmax` from feel.
- `fcs/io/tuningdefaults.lua` — MODIFY: sway/surge gain records → `{ ks, ka }`; per-mode `ks`.
- `ui/basalt/bitconfig/tuning.lua` — MODIFY: sway/surge rows → `ka`,`ks` (drop `kp`/`ki`/`kd` for those two axes).
- Tests updated in-task: `test_translate.lua`, `test_control_terms.lua`, `test_scheme_rate.lua`, `tests/modes_golden_data.lua`, `test_bitconfig_tuning.lua`.
- `dist/` + `manifest.lua` — regenerated in the final task.

---

## Task 1: Velocity-limited cascade in `Translate`

**Files:**
- Modify: `fcs/control/translate.lua`
- Test: `tests/test_translate.lua`, `tests/test_control_terms.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Translate.new(cfg)` now reads `self.ka = cfg.ka or 0` (alongside existing `kp,ki,kd,ks`).
  - `Translate:hold(sp, pos, vel, vmax) -> number` — cascade output. `vmax` nil or ≤0 means no clamp.
  - `Translate:terms(sp, pos, vel, vmax) -> {err, P, I, D}` — `P = ks·velTarget`, `I = 0`, `D = -ks·vel`, so `P+I+D == hold(...)`.
  - `Translate:rate(cmd, vel, dt)` — UNCHANGED (`ks·(cmd-vel)`).
  - `Translate:update` — REMOVED.

- [ ] **Step 1: Rewrite `tests/test_translate.lua` to the failing hold spec**

Replace the entire file with:

```lua
local t = require("tests.framework")
local Translate = require("fcs.control.translate")

t.test("hold: near target behaves like PD-via-cascade (ks*ka*err - ks*vel)", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  -- err = 2, vel = 0  -> velTarget = 2 (uncapped) -> out = 0.4*(2 - 0) = 0.8
  t.near(c:hold(2, 0, 0), 0.8, 1e-9)
  -- err = 0, vel = 3  -> velTarget = 0 -> out = 0.4*(0 - 3) = -1.2 (pure braking)
  t.near(c:hold(0, 0, 3), -1.2, 1e-9)
end)

t.test("hold: velocity target clamps to +-vmax", function()
  local c = Translate.new({ ks = 0.5, ka = 1.0 })
  -- err = 10 -> ka*err = 10, clamped to vmax 3 -> out = 0.5*(3 - 0) = 1.5
  t.near(c:hold(10, 0, 0, 3), 1.5, 1e-9)
  -- err = -10 -> clamped to -3 -> out = 0.5*(-3 - 0) = -1.5
  t.near(c:hold(-10, 0, 0, 3), -1.5, 1e-9)
end)

t.test("hold: nil vel defaults to 0", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  t.near(c:hold(1, 0, nil, 6), 0.4 * 1, 1e-9)
end)

t.test("hold is stateless: repeated calls return the same value, no reset needed", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  local a = c:hold(2, 0, 0.5, 6)
  local b = c:hold(2, 0, 0.5, 6)
  t.near(a, b, 1e-9)
end)

t.test("hold converges monotonically from a large displacement (no divergence)", function()
  -- Discrete sim: single-integrator-ish plant vel += a*out*dt, pos += vel*dt.
  -- vmax bounds speed so |pos| never grows after the first approach.
  local c = Translate.new({ ks = 0.3, ka = 1.0 })
  local pos, vel, a, dt, vmax = 8.0, 0.0, 6.0, 0.05, 3.0
  local peak = 0
  for _ = 1, 2000 do
    local out = c:hold(0, pos, vel, vmax)
    if out > 0.3 then out = 0.3 elseif out < -0.3 then out = -0.3 end -- duty cap
    vel = vel + a * out * dt
    pos = pos + vel * dt
    if math.abs(pos) > peak then peak = math.abs(pos) end
  end
  t.truthy(peak <= 8.0 + 1e-6, "never overshoots the initial displacement")
  t.truthy(math.abs(pos) < 0.2, "settles near the hold point, pos=" .. pos)
  t.truthy(math.abs(vel) < 0.2, "settles near zero velocity, vel=" .. vel)
end)

t.test("rate: commands velocity error (unchanged)", function()
  local c = Translate.new({ ks = 0.4 })
  t.near(c:rate(6, 2, 0.05), 0.4 * (6 - 2), 1e-9)
  t.near(c:rate(3, nil, 0.05), 0.4 * 3, 1e-9)
  t.near(c:rate(nil, 2, 0.05), 0.4 * (0 - 2), 1e-9)
end)

t.test("terms: P + I + D reconstructs hold() exactly and does not mutate", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  local out = c:hold(2, 0, 0.5, 6)
  local tm = c:terms(2, 0, 0.5, 6)
  t.near(tm.P + tm.I + tm.D, out, 1e-9, "P+I+D == hold")
  t.near(tm.I, 0, 1e-9, "I is zero (no integrator)")
  t.near(tm.err, 2, 1e-9, "err = sp - pos")
  local tm2 = c:terms(2, 0, 0.5, 6)
  t.near(tm2.P, tm.P, 1e-9, "terms is pure/repeatable")
end)

t.test("terms: honors vmax clamp in P", function()
  local c = Translate.new({ ks = 0.5, ka = 1.0 })
  local tm = c:terms(10, 0, 0, 3)
  t.near(tm.P, 0.5 * 3, 1e-9, "P uses the clamped velocity target")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_focus.sh test_translate` (or the full `bash tests/run_headless.sh`)
Expected: FAIL — `hold` is not a method / `update` still present.

- [ ] **Step 3: Rewrite `fcs/control/translate.lua`**

Replace the whole file with:

```lua
local T = {}
T.__index = T
function T.new(cfg)
  local self = setmetatable({}, T)
  self.ks = cfg.ks or 0
  self.ka = cfg.ka or 0
  self:reset(); return self
end
-- Hold has no integrator; reset is kept as a harmless no-op so existing callers
-- (Scheme:reset, the rate-branch handoff) need no change.
function T:reset() end
-- Velocity-limited position hold (cascade). Outer P on position error produces a
-- velocity target bounded to +-vmax; inner P on velocity (ks) produces the duty.
-- Because the commanded velocity is capped, momentum is bounded and the craft can
-- always arrest -- the old saturating-PD divergence (spec 2026-09-07) is impossible.
function T:hold(sp, pos, vel, vmax)
  local velTarget = self.ka * (sp - pos)
  if vmax and vmax > 0 then
    if velTarget > vmax then velTarget = vmax elseif velTarget < -vmax then velTarget = -vmax end
  end
  return self.ks * (velTarget - (vel or 0))
end
-- Pilot rate command: fly to a commanded velocity directly. UNCHANGED.
function T:rate(cmd, vel, dt)
  return self.ks * ((cmd or 0) - (vel or 0))
end
-- Pure read: reconstruct {err, P, I, D} matching :hold() exactly. Log-time only.
-- P is the position->velocity-target->duty contribution (clamped), D the damping.
function T:terms(sp, pos, vel, vmax)
  local err = sp - pos
  local velTarget = self.ka * err
  if vmax and vmax > 0 then
    if velTarget > vmax then velTarget = vmax elseif velTarget < -vmax then velTarget = -vmax end
  end
  return {
    err = err,
    P = self.ks * velTarget,
    I = 0,
    D = -self.ks * (vel or 0),
  }
end
return T
```

- [ ] **Step 4: Update the `Translate` section of `tests/test_control_terms.lua`**

The three `Translate:update`/`Translate:terms` tests (the block under the `-- Translate ---` comment) assume the old PD. Replace those with cascade equivalents; keep the `Translate:rate` test as-is. Find:

```lua
t.test("Translate:terms P+I+D sums to update() and does not mutate", function()
  local tr = Translate.new({ kp = 1.5, ki = 0.3, kd = 0.25 })
  local out = tr:update(4, 1, 0.5, 0.1, false) -- sp=4, pos=1, vel=0.5, dt=0.1
```

Replace the `...terms P+I+D sums to update()...` test and the `...terms defaults vel to 0 like update()...` test with:

```lua
t.test("Translate:terms P+I+D sums to hold() and does not mutate", function()
  local tr = Translate.new({ ks = 0.4, ka = 1.5 })
  local out = tr:hold(4, 1, 0.5, 6)   -- sp=4, pos=1, vel=0.5, vmax=6
  local tm = tr:terms(4, 1, 0.5, 6)
  t.near(tm.P + tm.I + tm.D, out, 1e-9, "P+I+D == hold")
  local tm2 = tr:terms(4, 1, 0.5, 6)
  t.near(tm2.P + tm2.I + tm2.D, out, 1e-9, "terms is pure/repeatable")
end)

t.test("Translate:terms defaults vel to 0 like hold()", function()
  local tr = Translate.new({ ks = 0.4, ka = 1.0 })
  local out = tr:hold(2, 0, nil, 6)
  local tm = tr:terms(2, 0, nil, 6)
  t.near(tm.P + tm.I + tm.D, out, 1e-9, "nil vel treated as 0 in both")
end)
```

(Leave the `Translate:rate commands velocity error` test untouched.)

- [ ] **Step 5: Run to verify pass**

Run: `bash tests/run_headless.sh`
Expected: `test_translate` and `test_control_terms` PASS. (Other suites may still fail — Tasks 2–5 fix them.) Confirm the manifest sync check passes (no files added/removed).

- [ ] **Step 6: Commit**

```bash
git add fcs/control/translate.lua tests/test_translate.lua tests/test_control_terms.lua
git commit -m "feat(fcs): velocity-limited cascade hold in Translate (retire PD update)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Task 2: Scheme wires sway/surge to `hold()`

**Files:**
- Modify: `fcs/schemes/level_flight.lua`
- Test: `tests/test_scheme_rate.lua` (update), `tests/test_scheme_terms.lua` (verify still green)

**Interfaces:**
- Consumes: `Translate:hold(sp, pos, vel, vmax)`, `Translate:terms(sp, pos, vel, vmax)` (Task 1).
- Produces: `Scheme:update` reads `sp.swayVmax`/`sp.surgeVmax` (nil → no cap); `Scheme:terms` passes the same vmax through.

- [ ] **Step 1: Update `tests/test_scheme_rate.lua` "position-hold" test to the failing cascade spec**

Replace the third test (`"scheme falls back to position-hold PIDs when no rate cmd present"`) with:

```lua
t.test("scheme falls back to velocity-limited hold when no rate cmd present", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0, kv = 0.06 }, pitch = {}, roll = {},
    yaw = { kp = 0.95, kd = 0 }, sway = { ks = 0.4, ka = 1.0 }, surge = { ks = 0.4, ka = 1.0 } })
  local d = sc:update({ altitude = 105, heading = 0.2, swayPos = 1, surgePos = 2, swayVmax = 6, surgeVmax = 6 },
    { altitude = 100, vSpeed = 0, heading = 0, swayPos = 0, surgePos = 0, yawRate = 0,
      swayVel = 0, surgeVel = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 5, 1e-9, "alt hold = hover + kp*err (position PID)")
  t.near(d.yaw, 0.95 * 0.2, 1e-9, "yaw hold = kp*err (heading PID)")
  -- sway: err=1, vel=0 -> velTarget=min(1,6)=1 -> 0.4*(1-0)=0.4
  t.near(d.sway, 0.4 * 1, 1e-9, "sway hold = ks*(clamp(ka*err,vmax) - vel)")
  -- surge: err=2, vel=0 -> velTarget=min(2,6)=2 -> 0.4*(2-0)=0.8
  t.near(d.surge, 0.4 * 2, 1e-9, "surge hold = ks*(clamp(ka*err,vmax) - vel)")
end)

t.test("scheme hold honors sp.swayVmax / sp.surgeVmax speed cap", function()
  local sc = Level.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {}, yaw = {},
    sway = { ks = 0.5, ka = 1.0 }, surge = { ks = 0.5, ka = 1.0 } })
  local d = sc:update({ altitude = 0, swayPos = 10, surgePos = 10, swayVmax = 3, surgeVmax = 3 },
    { altitude = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0,
      heading = 0, yawRate = 0, pitch = 0, roll = 0 }, 0.05, false, {})
  t.near(d.sway, 0.5 * 3, 1e-9, "sway clamped to vmax=3")
  t.near(d.surge, 0.5 * 3, 1e-9, "surge clamped to vmax=3")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: `test_scheme_rate` FAILs (scheme still calls `:update`, `d.sway`/`d.surge` wrong).

- [ ] **Step 3: Edit the sway and surge branches in `fcs/schemes/level_flight.lua`**

In `Scheme:update`, change the sway branch (currently the `else` calls `self.swayTc:update(...)`) and the surge line:

```lua
  -- Sway: rate (strafe velocity command) vs velocity-limited position-hold.
  local sway
  if sp.strafeCmd ~= nil then
    self.swayTc:reset()
    sway = self.swayTc:rate(sp.strafeCmd, m.swayVel, dt)
  else
    sway = self.swayTc:hold(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, sp.swayVmax)
  end
  return {
    heave = heave,
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt, freeze or sat.pitch),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt, freeze or sat.roll),
    yaw = yaw, sway = sway,
    surge = self.surgeTc:hold(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, sp.surgeVmax),
  }
```

In `Scheme:terms`, pass the vmax through so the logged `P_sway`/`P_surge` match the applied output:

```lua
    sway  = self.swayTc:terms(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, sp.swayVmax),
    surge = self.surgeTc:terms(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, sp.surgeVmax),
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`
Expected: `test_scheme_rate` PASS; `test_scheme_terms` PASS (its sway/surge checks are finiteness-only — the cascade `terms()` returns finite `P/I/D`). `test_modes_golden` will still FAIL — Task 4 regenerates its baseline. Note that failure and continue.

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/level_flight.lua tests/test_scheme_rate.lua
git commit -m "feat(fcs): scheme sway/surge use velocity-limited hold with sp vmax

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Task 3: Pilot publishes `sp.swayVmax` / `sp.surgeVmax`

**Files:**
- Modify: `fcs/input/pilot.lua`
- Test: `tests/test_pilot.lua`

**Interfaces:**
- Consumes: `self.cfg.swaySpeed`, `self.cfg.surgeSpeed` (feel; already present per mode).
- Produces: every returned setpoint carries `swayVmax = feel.swaySpeed` and `surgeVmax = feel.surgeSpeed` (including the position-hold early-return path).

- [ ] **Step 1: Add a failing test to `tests/test_pilot.lua`**

Append:

```lua
t.test("pilot publishes swayVmax/surgeVmax from feel on every setpoint", function()
  local p = Pilot.new({ swaySpeed = 6, surgeSpeed = 10, headingRate = 1, climbRate = 8 })
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 0 })
  local sp = p:update(0.05, {}, { altitude = 0, heading = 0, swayPos = 0, surgePos = 0,
    swayVel = 0, surgeVel = 0, yawRate = 0, vSpeed = 0 })
  t.near(sp.swayVmax, 6, 1e-9, "swayVmax = feel.swaySpeed")
  t.near(sp.surgeVmax, 10, 1e-9, "surgeVmax = feel.surgeSpeed")
end)

t.test("pilot publishes swayVmax/surgeVmax even while positionHold is engaged", function()
  local p = Pilot.new({ swaySpeed = 3, surgeSpeed = 3 })
  p:reset({ altitude = 0, heading = 0, swayPos = 0, surgePos = 0 })
  p:setPositionHold(true)
  local sp = p:update(0.05, {}, { altitude = 0, heading = 0, swayPos = 0, surgePos = 0 })
  t.near(sp.swayVmax, 3, 1e-9, "swayVmax present in hold path")
  t.near(sp.surgeVmax, 3, 1e-9, "surgeVmax present in hold path")
end)
```

(If `Pilot` is not already required at the top of `test_pilot.lua`, it is — reuse the existing local.)

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: `test_pilot` FAILs — `sp.swayVmax` is nil.

- [ ] **Step 3: Publish the caps in `fcs/input/pilot.lua`**

At the very top of `Pilot:update` (before the `if self.hold` block), set the caps so both the hold early-return and the normal path carry them:

```lua
function Pilot:update(dt, held, meas)
  -- Publish the per-mode hold speed caps on the setpoint so the scheme's velocity-
  -- limited hold (spec 2026-09-07) bounds its return-to-station speed. Sourced from
  -- the same feel.swaySpeed/surgeSpeed the rate command uses -- no separate knob.
  self.sp.swayVmax  = self.cfg.swaySpeed
  self.sp.surgeVmax = self.cfg.surgeSpeed
  if self.hold then
```

(The rest of `update` is unchanged; the final snapshot copy at the end already copies all `sp` fields, so the caps flow through.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`
Expected: `test_pilot` PASS. `test_pilot_modes` / `test_pilot_drift` unaffected (they don't assert setpoint key counts).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot.lua
git commit -m "feat(fcs): pilot publishes per-mode swayVmax/surgeVmax for the hold cascade

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Task 4: Tuning defaults — sway/surge gains become `{ ks, ka }`; regenerate golden

**Files:**
- Modify: `fcs/io/tuningdefaults.lua`
- Modify: `tests/modes_golden_data.lua` (regenerate EXPECT[2],[3] — intentional behavior change)
- Test: `tests/test_tuningdefaults.lua`, `tests/test_tuning_modes.lua`, `tests/test_modes_golden.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `gains.sway = { ks, ka }`, `gains.surge = { ks, ka }` at base and per mode.

- [ ] **Step 1: Add a failing assertion to `tests/test_tuningdefaults.lua`**

Append:

```lua
t.test("sway/surge gains are the velocity-limited-hold pair {ks, ka}", function()
  local g = require("fcs.io.tuningdefaults").get().gains
  t.near(g.sway.ks, 0.4, 1e-9, "base sway ks")
  t.near(g.sway.ka, 1.0, 1e-9, "base sway ka")
  t.near(g.surge.ks, 0.4, 1e-9, "base surge ks")
  t.near(g.surge.ka, 1.0, 1e-9, "base surge ka")
  t.truthy(g.sway.kp == nil and g.sway.kd == nil, "old sway PD gains dropped")
  t.truthy(g.surge.kp == nil and g.surge.kd == nil, "old surge PD gains dropped")
end)

t.test("per-mode sway/surge ks overrides (CRU hotter, LDG gentler)", function()
  local m = require("fcs.io.tuningdefaults").get().modes
  t.near(m.CRUISE.gains.sway.ks, 0.5, 1e-9, "CRU sway ks")
  t.near(m.CRUISE.gains.surge.ks, 0.4, 1e-9, "CRU surge ks")
  t.near(m.LDG.gains.sway.ks, 0.3, 1e-9, "LDG sway ks")
  t.near(m.LDG.gains.surge.ks, 0.3, 1e-9, "LDG surge ks")
  t.near(m.LDG.gains.sway.ka, 1.0, 1e-9, "LDG sway ka inherits base")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: `test_tuningdefaults` FAILs (`g.sway.ka` nil, `g.sway.kp` present).

- [ ] **Step 3: Edit `fcs/io/tuningdefaults.lua`**

Change the base gain records (currently lines 35–36):

```lua
    sway  = { ks = 0.4, ka = 1.0 },
    surge = { ks = 0.4, ka = 1.0 },
```

Keep the existing CRUISE override `DEFAULTS.modes.CRUISE.gains.sway.ks = 0.5` and LDG override `DEFAULTS.modes.LDG.gains.sway.ks = 0.3`. Immediately after the LDG sway line, add the LDG surge override:

```lua
DEFAULTS.modes.LDG.gains.surge.ks   = 0.3
```

(Base `ka = 1.0` and base `surge.ks = 0.4` flow to MAN/CRUISE/DRN/LDG via the existing `deep(DEFAULTS.gains)` copies; only the ks values above differ per mode.)

- [ ] **Step 4: Run to verify the tuningdefaults tests pass**

Run: `bash tests/run_headless.sh`
Expected: `test_tuningdefaults` and `test_tuning_modes` PASS. `test_modes_golden` still FAILs (cases [2],[3] — sway/surge outputs changed). Proceed to regenerate.

- [ ] **Step 5: Regenerate the golden baseline via CraftOS-PC**

The golden (`tests/modes_golden_data.lua`) is a characterization lock; this change intentionally alters PRECISION's sway/surge behavior, so regenerate EXPECT with the capture tool. Run headless:

```bash
DATA="$(mktemp -d)"; COMP="$DATA/computer/0"; mkdir -p "$COMP"
cp -r fcs tools "$COMP/"
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local ok, err = pcall(function() require("tools.capture_precision_golden") end)
local out = fs.open("/golden.txt", "w")
out.write(tostring(ok) .. "\n" .. tostring(err) .. "\n")
out.close()
os.shutdown()
LUA
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1
cat "$COMP/golden.txt"
```

If `capture_precision_golden.lua` prints to `term`/`print` rather than a file, adapt the startup shim to redirect its output into `/golden.txt` (wrap the require in a captured `print`). Copy the printed per-case `FL=…YRR=…` lines into `EXPECT[2]` and `EXPECT[3]` in `tests/modes_golden_data.lua` verbatim (cases [1] and [4] have zero sway/surge state and MUST be byte-identical — if they changed, stop and investigate). Add a dated comment block documenting the intentional change, matching the file's existing precedent:

```lua
-- INTENTIONAL update 2026-09-07 (velocity-limited-hold, spec 2026-09-07): sway/surge holds
-- switched from saturating PD to the ks/ka velocity-limited cascade; base gains sway/surge
-- = {ks=0.4, ka=1.0}. Only cases [2] and [3] (nonzero sway/surge pos/vel) move: their MAIN
-- (surge) and YAW-thruster (sway via mixLateral) duties. Cases [1][4] (zero sway/surge) are
-- byte-identical. Regenerated via tools/capture_precision_golden.lua inside CraftOS-PC.
```

- [ ] **Step 6: Run to verify golden passes**

Run: `bash tests/run_headless.sh`
Expected: `test_modes_golden` PASS; full src suite green except any UI-row assertions (Task 5). Confirm cases [1]/[4] unchanged in the diff (`git diff tests/modes_golden_data.lua`).

- [ ] **Step 7: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuningdefaults.lua tests/modes_golden_data.lua
git commit -m "feat(fcs): sway/surge tuning defaults -> {ks,ka}; regen golden baseline

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Task 5: BIT/CONFIG live-tune rows for sway/surge → `ka`,`ks`

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua`
- Test: `tests/test_bitconfig_tuning.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ROW_SPEC` no longer has `gains.sway.k{p,i,d}` or `gains.surge.k{p,i,d}`; it has `gains.sway.ka`, `gains.sway.ks`, `gains.surge.ka`, `gains.surge.ks` (all group `GAINS`, step 0.01, min 0, max 5 for `ka`; min 0, max 1 for `ks`). Base row count drops by 3 (34 → 31); PRECISION 38 → 35.

- [ ] **Step 1: Update `tests/test_bitconfig_tuning.lua` to the failing row spec**

Two edits. First, the PRECISION row-count test — change `38` → `35` and its label, and adjust the presence list:

```lua
t.test("M.rows(cfg,'PRECISION') has no tilt/cruise-throttle extras, but DOES have the 4 shared trim/flip-guard rows (35 rows)", function()
  local rows = M.rows(tuningdefaults.get(), "PRECISION")
  t.eq(#rows, 35, "31 base + 4 shared trim/flip-guard rows")
```

Extend that test's present-id loop to include the new sway/surge rows and assert the old ones are gone:

```lua
  for _, id in ipairs({ "feel.trimGain", "feel.climbRate", "feel.headingRate", "feel.swaySpeed",
                        "gains.alt.kv", "gains.yaw.kw", "gains.sway.ks", "gains.sway.ka",
                        "gains.surge.ks", "gains.surge.ka" }) do
    t.truthy(ids[id], "PRECISION row present: " .. id)
  end
  for _, id in ipairs({ "gains.sway.kp", "gains.sway.ki", "gains.sway.kd",
                        "gains.surge.kp", "gains.surge.ki", "gains.surge.kd" }) do
    t.truthy(ids[id] == nil, "retired translate PD row GONE: " .. id)
  end
```

Second, add `gains.sway.ka`/`gains.surge.ka`/`gains.surge.ks` to the `specFor` expectation test (near line 1171) so each mode exposes them:

```lua
    { id = "gains.sway.ka",    label = "SWAY KA",  group = "GAINS", min = 0, max = 5 },
    { id = "gains.surge.ka",   label = "SURGE KA", group = "GAINS", min = 0, max = 5 },
    { id = "gains.surge.ks",   label = "SURGE KS", group = "GAINS", min = 0, max = 1 },
```

Any other hardcoded per-mode row-count assertions in this file (search for `#rows`) must be reduced by 3 as well.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: `test_bitconfig_tuning` FAILs on row count / missing `gains.sway.ka`.

- [ ] **Step 3: Edit `ui/basalt/bitconfig/tuning.lua`**

Restrict the generic kp/ki/kd loop to the PID axes only, and add explicit ka/ks rows for the two translate axes. Replace the axis loop (currently around lines 155–168):

```lua
-- PID axes: kp/ki/kd. sway/surge are NOT PID -- they use the velocity-limited hold
-- (ks/ka), added explicitly below (spec 2026-09-07).
for _, axis in ipairs({ "alt", "pitch", "roll", "yaw" }) do
  local al = AXIS_LABEL[axis]
  addRow("gains." .. axis .. ".kp", al .. " KP", "GAINS", 0.01, 0, 5)
  addRow("gains." .. axis .. ".ki", al .. " KI", "GAINS", 0.01, 0, 1)
  addRow("gains." .. axis .. ".kd", al .. " KD", "GAINS", 0.01, 0, 5)
end
-- Rate/velocity gains grouped onto their axis screen by the "gains.<axis>." prefix.
addRow("gains.alt.kv",   "ALT KV",   "GAINS", 0.01, 0, 1)
addRow("gains.yaw.kw",   "YAW KW",   "GAINS", 0.01, 0, 1)
-- Translate axes: velocity-limited hold pair. ka = position->velocity stiffness,
-- ks = velocity->duty (also the pilot rate-follow gain). vmax comes from feel.swaySpeed.
addRow("gains.sway.ka",  "SWAY KA",  "GAINS", 0.01, 0, 5)
addRow("gains.sway.ks",  "SWAY KS",  "GAINS", 0.01, 0, 1)
addRow("gains.surge.ka", "SURGE KA", "GAINS", 0.01, 0, 5)
addRow("gains.surge.ks", "SURGE KS", "GAINS", 0.01, 0, 1)
```

(`AXES`/`AXIS_LABEL` keep all six entries — the axis *screen* buttons ALT/PITCH/ROLL/YAW/SWAY/SURGE are unchanged; only the row generation changed.)

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/run_headless.sh`
Expected: `test_bitconfig_tuning` PASS; entire src suite green.

- [ ] **Step 5: Commit**

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua
git commit -m "feat(ui): BIT/CONFIG sway/surge live-tune rows -> ka/ks (drop PD rows)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Task 6: Rebuild dist, regenerate manifest, run all gates

**Files:**
- Modify: `dist/**`, `manifest.lua` (regenerated artifacts)

**Interfaces:** none (integration/verification task).

- [ ] **Step 1: Rebuild the minified dist and regenerate the manifest**

Run:
```bash
node tools/build.mjs && bash tools/run_gen.sh
```
Expected: build succeeds; `run_gen.sh` writes any manifest updates without error.

- [ ] **Step 2: Run the src gate**

Run: `bash tests/run_headless.sh`
Expected: PASS, 0 failures. Record the `<passed>/0` count.

- [ ] **Step 3: Run the dist gate**

Run: `bash tests/run_headless_dist.sh`
Expected: PASS, 0 failures. Record the `<passed>/0` count.

- [ ] **Step 4: Run the e2e gate**

Run: `bash tests/run_suite_e2e.sh`
Expected: PASS. Record the count.

- [ ] **Step 5: Commit the rebuilt artifacts**

```bash
git add dist manifest.lua
git commit -m "build(fcs): rebuild dist + manifest for velocity-limited hold

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL"
```

---

## Self-Review

**Spec coverage:**
- Control-law cascade → Task 1. Scheme wiring + vmax-from-setpoint → Task 2. Pilot publishes vmax → Task 3. Gains `{ks,ka}` + per-mode + defaults → Task 4. Live-tune rows → Task 5. `terms()` reconstruction → Task 1 (+ verified in Task 2 via `test_scheme_terms`). Bumpless handoff → exercised by the `posErr=0 ⇒ −ks·vel` test in Task 1 and the existing pilot capture logic (unchanged). Dist/e2e gates → Task 6. Deferred DAMPED detector / loop-rate → explicitly out of scope (spec).
- Correction vs spec: the spec's "edit `cfgspec.lua`" is dropped — `cfgspec` deep-merges from `tuningdefaults`, so no per-gain descriptor exists there to change (verified). No task touches it.

**Placeholder scan:** none — every code step carries concrete code. The golden capture (Task 4 Step 5) is the one step whose exact numbers are produced at run time by the deterministic capture tool; the step names the tool, the invariant (cases [1]/[4] unchanged), and the paste target.

**Type consistency:** `hold(sp,pos,vel,vmax)` and `terms(sp,pos,vel,vmax)` signatures match across Tasks 1→2; `sp.swayVmax`/`sp.surgeVmax` produced in Task 3 and consumed in Task 2; gain keys `ks`/`ka` consistent across Tasks 1 (`cfg.ka`), 4 (defaults), 5 (rows).
