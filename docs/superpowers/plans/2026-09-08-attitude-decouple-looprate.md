# Attitude decouple + loop-rate fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Kill the residual hover attitude rocking (±6°) and restore the control-loop rate that keep-warm regressed, from flight `bf9a45213f`.

**Architecture:** Three coordinated changes. (1) Raise the keep-warm actuator write tolerance so it stops writing every tick (the ~40ms/cycle mainThread penalty that dropped the loop ~14.5→~9.6Hz). (2) Add a bounded translation→attitude decoupling feedforward in the loop (the yaw-ring/surge thrusters fire off the CoM → roll from sway, pitch from surge; pre-inject the counter-torque). (3) Stiffen the default LDG pitch/roll gains so the attitude loop rejects the disturbance faster.

**Tech Stack:** Lua 5.1 (CC:Tweaked), project test framework, headless CraftOS-PC (`bash tests/run_headless.sh`, `bash tests/run_headless_dist.sh`).

## Global Constraints

- Branch: `feat/attitude-decouple-looprate` (already created off `main`).
- The decoupling feedforward MUST be hard-bounded to a fraction of `caps.roll`/`caps.pitch` (like the existing trim flip-guard) — a mis-tuned gain must never dominate the attitude loop. Default gains are conservative and off-safe (0 ⇒ no-op).
- Measured coupling (flight `bf9a45213f`, settled hover): `roll ≈ −0.10·dSway`, `pitch ≈ +0.05·dSurge`. Decouple signs CANCEL these: `demands.roll += +swayRoll·demands.sway`, `demands.pitch += −|surgePitch|·demands.surge`.
- Do not touch keep-warm's correctness (only its `tol` default), the mixer, or the lateral-hold gains.
- New tuning keys deep-merge through `cfgspec` (like `keepWarm`); no cfgspec schema edit needed.
- Suite lists live in `tests/run_headless.sh` and `tests/run_headless_dist.sh` (both hardcoded). `dist/` is a committed build artifact; user untracked files (`E2E-TEST-REPORT-*.md`, `TASKING *.md`, `eh2 flight log *.txt`, `image.png`) must never be staged (`git add <paths>`, never `-A`).

---

### Task 1: Raise keep-warm write tolerance (loop-rate fix)

**Files:**
- Modify: `fcs/actuate/keepwarm.lua` (the `tol` default in `KeepWarm.new`)
- Test: `tests/test_keepwarm.lua`

**Interfaces:** Produces: `KeepWarm.new{}` default `tol` = 0.04 (was 0.01); explicit `tol` still honored.

- [ ] **Step 1: Write the failing test** (append to `tests/test_keepwarm.lua`)

```lua
t.test("default write tolerance is 0.04 (coarser writes -> fewer mainThread calls)", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })   -- no tol -> default
  a:apply({ YFL = 0.20 }, 0.05); t.eq(b.writes, 1)     -- first write
  a:apply({ YFL = 0.23 }, 0.05); t.eq(b.writes, 1)     -- +0.03 < 0.04 default -> no write
  a:apply({ YFL = 0.25 }, 0.05); t.eq(b.writes, 2)     -- +0.05 from last-written 0.20 -> write
end)
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect the new case FAIL (default tol still 0.01 → the 0.23 apply writes).

- [ ] **Step 3: Implement** — in `fcs/actuate/keepwarm.lua`, `KeepWarm.new`, change `tol = cfg.tol or 0.01` to:

```lua
    tol = cfg.tol or 0.04,
```

Update the module header comment's tol note if it names 0.01.

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; the new case green, existing keepwarm tests (which pass explicit `tol` or don't depend on the default) still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/actuate/keepwarm.lua tests/test_keepwarm.lua
git commit -m "perf(fcs): raise keep-warm write tol 0.01->0.04 (restore loop rate)"
```

---

### Task 2: Translation→attitude decoupling feedforward (loop)

**Files:**
- Modify: `fcs/runtime/loop.lua` (add `setDecouple`; apply bounded decouple after the trim-FF block in `cycle`)
- Test: `tests/test_loop_trim.lua` (decouple lives beside the trim FF; test it there)

**Interfaces:**
- Produces: `Loop:setDecouple({ swayRoll, surgePitch, authority })` stores `self.decoupleSwayRoll`, `self.decoupleSurgePitch`, `self.decoupleAuthority` (missing → 0 for gains, 1 for authority). In `cycle`, after the trim-FF `demands.pitch = (demands.pitch or 0) + ff` line, adds bounded `demands.roll += clamp(swayRoll·demands.sway, ±authority·caps.roll)` and `demands.pitch += clamp(surgePitch·demands.surge, ±authority·caps.pitch)`. With no `setDecouple` call, gains default 0 ⇒ exact current behavior.

- [ ] **Step 1: Write the failing test** (append to `tests/test_loop_trim.lua`)

```lua
t.test("decouple FF adds bounded roll/pitch from sway/surge demand", function()
  -- Build a loop whose scheme returns fixed sway/surge demands, capture demands via a spy mixer.
  local seen = {}
  local spyMixer = { mix = function(_, d) seen = d; return {} end }
  local scheme = { reset = function() end,
    update = function() return { heave = 0.3, pitch = 0, roll = 0, yaw = 0, sway = 0.2, surge = 0.2 } end }
  local loop = require("fcs.runtime.loop").new({ scheme = scheme, mixer = spyMixer,
    caps = { pitch = 0.3, roll = 0.3 }, backend = { sensors = function() return {} end } })
  loop:setDecouple({ swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 })
  loop:arm(true)
  loop:cycle(0.05, { onGround = false, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    altitude = 0, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 })
  t.near(seen.roll, 0.10 * 0.2, 1e-9, "roll += swayRoll*sway")
  t.near(seen.pitch, -0.05 * 0.2, 1e-9, "pitch += surgePitch*surge")
end)
t.test("decouple FF is clamped to authority*caps", function()
  local seen = {}
  local spyMixer = { mix = function(_, d) seen = d; return {} end }
  local scheme = { reset = function() end,
    update = function() return { heave = 0.3, pitch = 0, roll = 0, yaw = 0, sway = 1.0, surge = 0 } end }
  local loop = require("fcs.runtime.loop").new({ scheme = scheme, mixer = spyMixer,
    caps = { pitch = 0.3, roll = 0.2 }, backend = { sensors = function() return {} end } })
  loop:setDecouple({ swayRoll = 0.9, surgePitch = 0, authority = 0.5 })   -- 0.9*1.0 = 0.9, cap = 0.5*0.2 = 0.1
  loop:arm(true)
  loop:cycle(0.05, { onGround = false, pitch = 0, roll = 0, heading = 0, yawRate = 0,
    altitude = 0, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 })
  t.near(seen.roll, 0.1, 1e-9, "roll decouple clamped to 0.5*caps.roll")
end)
```

> NOTE for implementer: `test_loop_trim.lua` already constructs loops; follow its existing helper/style if cleaner than the inline construction above, but keep the two assertions (value and clamp). The stub scheme must supply `heave/pitch/roll/yaw/sway/surge` so the trim-FF block and envelope don't error; `sp_pitch/sp_roll` default 0 in the scheme so no attitude setpoint is needed. If the loop's `cycle` needs `hoverDuty`/`osc`, omit them (osc nil ⇒ mode stays NORMAL).

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect FAIL (`setDecouple` nil / decouple not applied).

- [ ] **Step 3: Implement** — in `fcs/runtime/loop.lua`:

Add the setter (near `setTrim`):

```lua
function Loop:setDecouple(cfg)
  cfg = cfg or {}
  self.decoupleSwayRoll = cfg.swayRoll or 0
  self.decoupleSurgePitch = cfg.surgePitch or 0
  self.decoupleAuthority = cfg.authority or 1
end
```

In `cycle`, immediately AFTER the existing `demands.pitch = (demands.pitch or 0) + ff` line (the trim-FF apply), add:

```lua
  -- Translation->attitude decoupling (flight bf9a45213f): the yaw-ring (sway) and surge thrusters
  -- fire off the CoM, so commanding them torques the craft -- roll from sway, pitch from surge.
  -- Pre-inject the counter-torque. Hard-bounded to authority*caps (like the trim flip-guard) so a
  -- mis-tuned gain can never dominate the attitude loop. Gains default 0 => no-op.
  local dcRoll = (self.decoupleSwayRoll or 0) * (demands.sway or 0)
  local dcPitch = (self.decoupleSurgePitch or 0) * (demands.surge or 0)
  local rCap = ((self.caps and self.caps.roll) or math.huge) * (self.decoupleAuthority or 1)
  local pCap = ((self.caps and self.caps.pitch) or math.huge) * (self.decoupleAuthority or 1)
  if dcRoll > rCap then dcRoll = rCap elseif dcRoll < -rCap then dcRoll = -rCap end
  if dcPitch > pCap then dcPitch = pCap elseif dcPitch < -pCap then dcPitch = -pCap end
  demands.roll = (demands.roll or 0) + dcRoll
  demands.pitch = (demands.pitch or 0) + dcPitch
```

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; new tests green; `test_loop`, `test_loop_trim`, `test_loop_setactive`, `test_integration` green (decouple gains default 0 ⇒ no change to existing loop tests).

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop_trim.lua
git commit -m "feat(fcs): bounded translation->attitude decoupling feedforward (sway->roll, surge->pitch)"
```

---

### Task 3: Defaults (decouple gains + stiffer LDG attitude) + wiring

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (top-level `decouple` block; LDG pitch/roll gain stiffening)
- Modify: `tools/hover_test.lua` (`buildLoop` — call `loop:setDecouple(tuning.decouple)`)
- Test: `tests/test_tuningdefaults.lua`, `tests/test_buildloop_modes.lua`

**Interfaces:**
- Consumes: `Loop:setDecouple` (Task 2); `tuning.decouple` (deep-merged default).
- Produces: `DEFAULTS.decouple = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 }`; LDG `gains.pitch.kp`/`gains.roll.kp` raised to 0.16, `gains.pitch.kd`/`gains.roll.kd` to 0.28; `buildLoop` wires the decouple config into the flown loop.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_tuningdefaults.lua`:

```lua
t.test("defaults expose a decouple block (translation->attitude FF)", function()
  local d = require("fcs.io.tuningdefaults").get()
  t.truthy(d.decouple, "decouple present")
  t.near(d.decouple.swayRoll, 0.10, 1e-9)
  t.near(d.decouple.surgePitch, -0.05, 1e-9)
  t.truthy(d.decouple.authority and d.decouple.authority > 0 and d.decouple.authority <= 1, "authority in (0,1]")
end)
t.test("LDG attitude gains stiffened for disturbance rejection", function()
  local d = require("fcs.io.tuningdefaults").get()
  t.near(d.modes.LDG.gains.pitch.kp, 0.16, 1e-9)
  t.near(d.modes.LDG.gains.roll.kp, 0.16, 1e-9)
end)
```

Append to `tests/test_buildloop_modes.lua`:

```lua
t.test("buildLoop wires the decouple config into the loop", function()
  local hover = require("tools.hover_test")
  local backend = {
    setThrusterLevel = function() end, setThrusterNormalized = function() end,
    sensors = function() return { onGround = false } end,
    liftIds = function() return { "FL","FR","RL","RR" } end,
    lateralIds = function() return { "YFL","YFR","YRL","YRR" } end,
    mainIds = function() return { "MAIN" } end, frontalIds = function() return { "FRL","FRR" } end,
  }
  local loop = hover.buildLoop(backend)
  local tuning = require("fcs.tuning")
  t.near(loop.decoupleSwayRoll, tuning.decouple.swayRoll, 1e-9, "swayRoll from tuning")
  t.near(loop.decoupleSurgePitch, tuning.decouple.surgePitch, 1e-9, "surgePitch from tuning")
end)
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect FAIL (no decouple defaults; LDG kp still 0.10; buildLoop doesn't call setDecouple).

- [ ] **Step 3: Implement**

In `fcs/io/tuningdefaults.lua`, add a top-level default near `keepWarm`:

```lua
  -- Translation->attitude decoupling feedforward gains (flight bf9a45213f). GLOBAL (a physical
  -- thruster-vs-CoM property). Signs CANCEL the measured coupling (roll=-0.10*sway, pitch=+0.05*surge).
  -- Conservative starting values, hard-bounded by authority*caps in the loop; tune from the next log.
  decouple = { swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 },
```

Stiffen LDG attitude (in the LDG mode block, alongside the existing `gains.pitch.kp = 0.10` pin):

```lua
DEFAULTS.modes.LDG.gains.pitch.kp = 0.16
DEFAULTS.modes.LDG.gains.pitch.kd = 0.28
DEFAULTS.modes.LDG.gains.roll.kp  = 0.16
DEFAULTS.modes.LDG.gains.roll.kd  = 0.28
```

(Replace the existing `DEFAULTS.modes.LDG.gains.pitch.kp = 0.10` line; add the three others.)

In `tools/hover_test.lua`, `buildLoop`, after `local loop = Loop.new({...})` and before `return loop, reg`, add:

```lua
  if tuning.decouple then loop:setDecouple(tuning.decouple) end
```

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`. New tests green. If `test_modes_golden` (or a golden-capture test) fails because the LDG attitude gains changed the recorded demands, regenerate that golden baseline per the note the failing test prints, and include it. Confirm `test_tuning`, `test_cfgspec`, `test_buildloop_modes`, `test_hover_test` green.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tools/hover_test.lua tests/test_tuningdefaults.lua tests/test_buildloop_modes.lua
# plus any regenerated golden + manifest (run bash tools/run_gen.sh if the sync check asks)
git commit -m "feat(fcs): decouple defaults + stiffer LDG attitude gains + buildLoop wiring"
```

---

### Task 4: Dist rebuild + both acceptance gates

**Files:** `dist/` tree, `manifest.lua`, `manifest-dev.lua` (regenerated); no new source.

- [ ] **Step 1: Rebuild dist + manifests** — `node tools/build.mjs && bash tools/run_gen.sh`
- [ ] **Step 2: Run BOTH gates green** — `bash tests/run_headless.sh` (src) and `bash tests/run_headless_dist.sh` (dist). Record both counts.
- [ ] **Step 3: Stage + commit** — `git add dist manifest.lua manifest-dev.lua` (targeted; NEVER `-A`; never the user untracked files). 

```bash
git commit -m "build: regenerate dist tree + manifests for attitude-decouple + loop-rate"
```

- [ ] **Step 4: Confirm clean** — `git status --short` shows only the four user untracked files remaining.

---

## Self-Review

**Spec coverage:** loop-rate fix (Task 1); decouple FF bounded + signed (Task 2); decouple defaults + stiffer LDG gains + wiring (Task 3); dist/gates (Task 4). ✓
**Placeholder scan:** none — concrete code + run commands throughout.
**Type consistency:** `setDecouple({swayRoll,surgePitch,authority})` (Task 2) matches `tuning.decouple` fields (Task 3) and the buildLoop call. `decoupleSwayRoll/decoupleSurgePitch` field names consistent between the setter, the `cycle` apply, and the buildLoop test. Decouple applied after the trim-FF line and before the osc/DAMPED/envelope stages (so DAMPED still zeros it and caps still bound it). ✓

## Verification note
Headless proves math/wiring/bounds; the cure is in-world. Next logged flight should show: loop rate back to ~14Hz, and reduced pitch/roll rocking. `decouple` gains and LDG kp/kd are first estimates — tune from that log (raise decouple gains if rocking persists with the coupling sign confirmed; back off if it over-corrects). `decouple.authority` bounds the FF so a wrong gain can't flip the craft.
