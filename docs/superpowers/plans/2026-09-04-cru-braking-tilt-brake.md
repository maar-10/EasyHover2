# CRU Active Braking + Tilt-Brake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make CRU actively brake (frontal thrusters + lift-thruster aerobrake) and give CRU/MAN/DRN a
speed-scaled, drift-opposing pitch/roll tilt-brake plus a CTRL brake button, by reworking the trim from
an output feed-forward into an attitude setpoint the #1 leveling loop holds.

**Architecture:** A pure `fcs/brake.lua` computes the speed→angle curve and the drift-opposing
pitch/roll vector. `fcs/input/pilot.lua` calls it to shape `sp.pitch`/`sp.roll` (the new home of the
"trim") and to arrest CRU surge at throttle 0. `fcs/schemes/cruise.lua` stops bypassing the surge loop
at throttle 0. The old output feed-forward in `fcs/runtime/loop.lua` is commented out (preserved).

**Tech Stack:** Lua 5.1 (CC:Tweaked), luamin dist build, headless CraftOS-PC test harness.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-09-04-cru-braking-tilt-brake-design.md` — authority for behavior.
- **Angles (rad):** 15° = 0.2618, 30° = 0.5236, 45° = 0.7854. Thresholds: engage 30 blk/s, sat 100 blk/s.
- **Curve:** below engage → 0; at engage → `minAngle`; linear to `maxAngle` (auto) / `buttonMax` (button)
  by sat; capped above sat. Intentional step 0→minAngle at exactly the engage speed.
- **Tilt signs (pinned by test):** forward motion (`surgeVel>0`) → nose-up (`pitch>0`); right drift
  (`swayVel>0`) → bank left (`roll<0`). Total magnitude `sqrt(pitch²+roll²)==θ`.
- **Modes with tilt-braking:** CRU, MAN, DRN (`feel.tiltBrake.enabled=true`). PRE, LDG stay level
  (`enabled=false`, base default).
- **Engage:** auto only when arresting (CRU `throttle==0`; MAN/DRN hands-off tilt), under CPL
  (`driftArrest`), speed > engage. `held.brake` overrides master mode in every mode; button in
  PRE/LDG = lateral hold, no tilt.
- **Test framework:** `require("tests.framework")` → `t.test/t.eq/t.near/t.truthy/t.run`. New test files
  MUST be added to the `suites` list in `tests/run_headless.sh` **and** `tests/run_headless_dist.sh`.
- **Every `fcs/**` edit:** regen manifest (`bash tools/run_gen.sh`) before the source gate (it has a
  manifest-sync check).
- **Dual gate before merge:** `bash tests/run_headless.sh`; then `node tools/build.mjs` +
  `bash tests/run_headless_dist.sh`.
- **Commit trailer:** end every commit with
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL`.
- **Preserve, don't delete:** the forward-accel lean in `loop.lua` is commented out (minifier strips it).

## File Structure

- **Create** `fcs/brake.lua` — pure curve + vector math. One responsibility: brake geometry.
- **Create** `tests/test_brake.lua` — curve/vector/sign unit tests.
- **Modify** `fcs/io/tuningdefaults.lua` — `feel.tiltBrake` block + per-mode enable.
- **Modify** `fcs/input/keymap.lua` — `brake` momentary flag + CTRL bindings.
- **Modify** `fcs/schemes/cruise.lua` — throttle-0 lets the inner surge loop through.
- **Modify** `fcs/input/pilot.lua` — brake setpoints, CRU surge arrest, DRN hands-off, button.
- **Modify** `fcs/runtime/loop.lua` — comment out the `ff` lean block; keep `_ffPitch=0`.
- **Modify** tests: `test_tuningdefaults.lua` (or `test_tuning_modes.lua`), `test_keymap.lua`,
  `test_scheme_cruise.lua`, `test_pilot_modes.lua`/`test_pilot_drift.lua`, `test_loop_trim.lua`,
  `test_oscillation.lua`.
- **Modify** `tests/run_headless.sh` + `tests/run_headless_dist.sh` — register `tests.test_brake`.

---

### Task 1: Tuning config — `feel.tiltBrake` block + per-mode enable

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (base `feel` block ~L47-69; CRUISE ~L93-104; add MAN/DRN lines)
- Test: `tests/test_tuningdefaults.lua`

**Interfaces:**
- Produces: `feel.tiltBrake = { enabled, engageSpeed, satSpeed, minAngle, maxAngle, buttonMax }`
  resolved per mode via `tuning.forMode(id).feel.tiltBrake`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_tuningdefaults.lua`)

```lua
t.test("tiltBrake enabled for CRU/MAN/DRN, disabled for PRE/LDG, with curve defaults", function()
  local D = require("fcs.io.tuningdefaults").get()
  -- base (PRECISION reads top-level feel) is disabled
  t.eq(D.feel.tiltBrake.enabled, false, "base/PRE disabled")
  t.near(D.feel.tiltBrake.engageSpeed, 30.0, 1e-9)
  t.near(D.feel.tiltBrake.satSpeed, 100.0, 1e-9)
  t.near(D.feel.tiltBrake.minAngle, 0.2618, 1e-4)
  t.near(D.feel.tiltBrake.maxAngle, 0.5236, 1e-4)
  t.near(D.feel.tiltBrake.buttonMax, 0.7854, 1e-4)
  t.eq(D.modes.CRUISE.feel.tiltBrake.enabled, true, "CRU enabled")
  t.eq(D.modes.MAN.feel.tiltBrake.enabled, true, "MAN enabled")
  t.eq(D.modes.DRN.feel.tiltBrake.enabled, true, "DRN enabled")
  t.eq(D.modes.LDG.feel.tiltBrake.enabled, false, "LDG disabled")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (`tiltBrake` nil).

- [ ] **Step 3: Implement** — in `tuningdefaults.lua`, add to the base `feel` table (before its
closing `}`):

```lua
    -- Tilt-brake (fix #3): speed-scaled pitch/roll brake into the drift direction. Base OFF so
    -- PRECISION (reads top-level) and LDG stay level-braking; CRU/MAN/DRN enable it below.
    tiltBrake = {
      enabled     = false,
      engageSpeed = 30.0,   -- blk/s: below this, directional thrusters brake alone (level)
      satSpeed    = 100.0,  -- blk/s: tilt reaches its max angle here
      minAngle    = 0.2618, -- 15deg: tilt at the engage speed
      maxAngle    = 0.5236, -- 30deg: auto max at/above satSpeed
      buttonMax   = 0.7854, -- 45deg: CTRL-brake max at/above satSpeed
    },
```

Then enable per mode (place near each mode's existing feel overrides):

```lua
DEFAULTS.modes.CRUISE.feel.tiltBrake.enabled = true
DEFAULTS.modes.MAN.feel.tiltBrake.enabled    = true
DEFAULTS.modes.DRN.feel.tiltBrake.enabled    = true
```

(CRUISE/MAN/DRN deep-copy base, so `tiltBrake` exists to flip. LDG deep-copies base and is left false.)

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuningdefaults.lua
git commit -m "feat(fcs): tiltBrake tuning defaults + per-mode enable (fix #3)" # + trailer
```

---

### Task 2: `fcs/brake.lua` — pure curve + vector math

**Files:**
- Create: `fcs/brake.lua`
- Create: `tests/test_brake.lua`
- Modify: `tests/run_headless.sh`, `tests/run_headless_dist.sh` (register `tests.test_brake`)

**Interfaces:**
- Produces: `brake.angle(s, cfg, button) -> number` (rad); `brake.vector(theta, surgeVel, swayVel) ->
  pitch, roll` (rad, rad). `cfg = { engageSpeed, satSpeed, minAngle, maxAngle, buttonMax }`.

- [ ] **Step 1: Write the failing test** — create `tests/test_brake.lua`:

```lua
local t = require("tests.framework")
local brake = require("fcs.brake")
local CFG = { engageSpeed = 30, satSpeed = 100, minAngle = 0.2618, maxAngle = 0.5236, buttonMax = 0.7854 }

t.test("angle: zero below engage, min at engage, max at/above sat (auto)", function()
  t.near(brake.angle(0, CFG), 0, 1e-9)
  t.near(brake.angle(29.999, CFG), 0, 1e-9)
  t.near(brake.angle(30, CFG), 0.2618, 1e-4, "min at engage")
  t.near(brake.angle(65, CFG), 0.2618 + 0.5*(0.5236-0.2618), 1e-4, "midpoint")
  t.near(brake.angle(100, CFG), 0.5236, 1e-4, "max at sat")
  t.near(brake.angle(500, CFG), 0.5236, 1e-4, "capped above sat")
end)

t.test("angle: button variant reaches buttonMax", function()
  t.near(brake.angle(30, CFG, true), 0.2618, 1e-4, "min at engage")
  t.near(brake.angle(100, CFG, true), 0.7854, 1e-4, "buttonMax at sat")
end)

t.test("vector: magnitude preserved and opposes drift", function()
  local p, r = brake.vector(0.5, 10, 0)          -- pure forward
  t.truthy(p > 0, "forward -> nose-up (pitch>0)")
  t.near(r, 0, 1e-9)
  t.near(math.sqrt(p*p + r*r), 0.5, 1e-6, "magnitude == theta")
  p, r = brake.vector(0.5, 0, 10)                -- pure right drift
  t.truthy(r < 0, "right drift -> bank left (roll<0)")
  t.near(p, 0, 1e-9)
  local p2, r2 = brake.vector(0.5, 6, 8)         -- diagonal (s=10)
  t.near(math.sqrt(p2*p2 + r2*r2), 0.5, 1e-6, "diagonal magnitude == theta")
end)

t.test("vector: zero theta or zero speed yields zero", function()
  local p, r = brake.vector(0, 10, 10); t.eq(p, 0); t.eq(r, 0)
  p, r = brake.vector(0.5, 0, 0); t.eq(p, 0); t.eq(r, 0)
end)
```

- [ ] **Step 2: Register the suite** — add `"tests.test_brake"` to the `suites` list in BOTH
`tests/run_headless.sh` and `tests/run_headless_dist.sh` (e.g. right after `"tests.test_oscillation"`).

- [ ] **Step 3: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (module not found).

- [ ] **Step 4: Implement** — create `fcs/brake.lua`:

```lua
-- fcs/brake.lua -- pure tilt-brake geometry: drift-speed -> angle curve + drift-opposing
-- pitch/roll decomposition. No state, no peripherals. Consumed by fcs.input.pilot.
local M = {}

-- Linear-ramp brake angle from drift speed s (blk/s). < engageSpeed -> 0 (thrusters brake alone).
-- At engageSpeed -> minAngle. Ramps to maxAngle (auto) or buttonMax (button) by satSpeed; capped.
function M.angle(s, cfg, button)
  s = s or 0
  local top = (button and cfg.buttonMax) or cfg.maxAngle
  if s < cfg.engageSpeed then return 0 end
  if s >= cfg.satSpeed then return top end
  local f = (s - cfg.engageSpeed) / (cfg.satSpeed - cfg.engageSpeed)
  return cfg.minAngle + f * (top - cfg.minAngle)
end

-- Decompose tilt magnitude theta into pitch/roll opposing the (surgeVel, swayVel) drift.
-- sqrt(pitch^2+roll^2) == theta. Signs (see fcs/mixer/level_flight.lua corners()): positive pitch
-- demand = nose-up (front lift pair higher) brakes forward motion; positive roll = lift tilts right,
-- so braking rightward drift needs negative roll.
function M.vector(theta, surgeVel, swayVel)
  surgeVel = surgeVel or 0; swayVel = swayVel or 0
  local s = math.sqrt(surgeVel * surgeVel + swayVel * swayVel)
  if theta <= 0 or s < 1e-6 then return 0, 0 end
  return theta * (surgeVel / s), -theta * (swayVel / s)
end

return M
```

- [ ] **Step 5: Run and verify it passes** — `bash tests/run_headless.sh` → PASS. If a sign test fails,
the sign is wrong — flip it in `M.vector` until the physical assertions pass (this test is the authority).

- [ ] **Step 6: Commit**

```bash
git add fcs/brake.lua tests/test_brake.lua tests/run_headless.sh tests/run_headless_dist.sh
git commit -m "feat(fcs): brake geometry module (curve + drift-opposing vector) (fix #3)" # + trailer
```

---

### Task 3: Keymap — `brake` momentary flag + CTRL bindings

**Files:**
- Modify: `fcs/input/keymap.lua` (`flagFor` ~L16-20; `M.default` ~L32-41; `M.drone` ~L44-50)
- Test: `tests/test_keymap.lua`

**Interfaces:**
- Produces: `held.brake == true` when the CTRL code is pressed, in every mode's layout.

- [ ] **Step 1: Write the failing test** (append to `tests/test_keymap.lua`)

```lua
t.test("CTRL resolves to held.brake in default and drone layouts", function()
  local km = require("fcs.input.keymap")
  local held = km.resolve(km.forMode("PRECISION"), { keys.leftCtrl })
  t.eq(held.brake, true, "default layout brake")
  local heldD = km.resolve(km.forMode("DRN"), { keys.leftCtrl })
  t.eq(heldD.brake, true, "drone layout brake")
  -- a non-brake code is unaffected
  local heldW = km.resolve(km.forMode("PRECISION"), { keys.w })
  t.eq(heldW.brake, nil, "w does not set brake")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (`brake` nil).

- [ ] **Step 3: Implement** — in `keymap.lua`, special-case `brake` in `flagFor` and bind CTRL:

```lua
function M.flagFor(map, code)
  local m = map[code]
  if not m then return nil end
  if m.axis == "brake" then return "brake" end          -- momentary boolean; no dir
  return FLAG[m.axis] and FLAG[m.axis][m.dir] or nil
end
```

Add to `M.default` and `M.drone` (both):

```lua
  [keys.leftCtrl] = {axis="brake"},   -- momentary brake button (fix #3)
```

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/keymap.lua tests/test_keymap.lua
git commit -m "feat(fcs): brake button keymap flag + CTRL binding (fix #3)" # + trailer
```

---

### Task 4: CRU surge arrest at throttle 0 (cruise.lua + pilot surgePos leash)

**Files:**
- Modify: `fcs/schemes/cruise.lua:8-12`
- Modify: `fcs/input/pilot.lua:104-111` (throttle-mode surge branch)
- Test: `tests/test_scheme_cruise.lua`, `tests/test_pilot_modes.lua`

**Interfaces:**
- Consumes: `sp.surgeThrottle` (pilot), inner `surge` loop output (Level scheme).
- Produces: `Cruise:update` returns `d.surge = throttle` when `throttle>0`, else the inner position-loop
  surge (negative when arresting a forward drift → fires FRL/FRR). Pilot leashes `sp.surgePos` at
  throttle 0.

- [ ] **Step 1: Write the failing test** (append to `tests/test_scheme_cruise.lua`)

```lua
t.test("cruise arrests at throttle 0: forward drift -> negative surge demand", function()
  local Cruise = require("fcs.schemes.cruise")
  local g = { hoverDuty=0.26, alt={}, pitch={}, roll={}, yaw={},
              sway={kp=0.2,kd=0.25}, surge={kp=0.15,kd=0.25}, heaveMin=0.05, heaveMax=0.85 }
  local sc = Cruise.new(g); sc:reset()
  -- throttle 0, craft drifting forward (surgeVel>0), setpoint held behind it -> brake (surge<0)
  local sp = { surgeThrottle = 0, surgePos = 0, altitude = 0, heading = 0, swayPos = 0 }
  local m  = { surgePos = 5, surgeVel = 8, swayPos = 0, swayVel = 0, altitude = 0,
               heading = 0, pitch = 0, roll = 0, yawRate = 0 }
  local d = sc:update(sp, m, 0.05, false, {})
  t.truthy(d.surge < 0, "throttle-0 arrest fires frontal brake (surge<0)")
end)

t.test("cruise forward: throttle>0 bypasses the position loop", function()
  local Cruise = require("fcs.schemes.cruise")
  local g = { hoverDuty=0.26, alt={}, pitch={}, roll={}, yaw={}, sway={}, surge={kp=0.15,kd=0.25} }
  local sc = Cruise.new(g); sc:reset()
  local sp = { surgeThrottle = 0.7, surgePos = 0, altitude=0, heading=0, swayPos=0 }
  local m  = { surgePos = 99, surgeVel = 40, swayPos=0, swayVel=0, altitude=0, heading=0,
               pitch=0, roll=0, yawRate=0 }
  local d = sc:update(sp, m, 0.05, false, {})
  t.near(d.surge, 0.7, 1e-9, "forward throttle passes through")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (first case: current
`cruise.lua` always overwrites `d.surge = sp.surgeThrottle` (0), so `d.surge==0`, not `<0`).

- [ ] **Step 3: Implement** — `fcs/schemes/cruise.lua`:

```lua
function Cruise:update(sp, m, dt, freeze, sat)
  local d = self.inner:update(sp, m, dt, freeze, sat)
  local thr = sp.surgeThrottle or 0
  if thr > 0 then d.surge = thr end   -- forward cruise bypasses the position loop; thr==0 arrests
  return d
end
```

`fcs/input/pilot.lua` — replace the throttle-mode surge branch (currently
`sp.surgePos = meas.surgePos or sp.surgePos`) so surgePos is pinned to meas while pushing forward but
leashed (held) at throttle 0:

```lua
    else
      -- CRUISE throttle mode. While pushing forward (throttle>0) surge = throttle and we track meas
      -- so the arrest, when throttle reaches 0, holds the CURRENT position. At throttle 0 we stop
      -- pinning and leash surgePos toward current (like the position modes) so the surge loop arrests
      -- and holds station instead of coasting.
      if (self.throttle or 0) > 0 then
        sp.surgePos = meas.surgePos or sp.surgePos
      else
        local surgeSpeed, surgeLead = c.surgeSpeed or c.cruiseSpeed, c.surgeLead or c.maxLead
        sp.surgePos = leash.step(sp.surgePos, sp.surgePos, meas.surgePos, dt, surgeSpeed, surgeLead)
      end
    end
```

(Note: `self.throttle` is updated later in `update()`; at this point it still holds the previous tick's
value, which is correct — the throttle ramps at most `cruiseThrottleRate*dt` per tick, so a one-tick
lag on the pin/leash switch is immaterial and avoids reordering the function.)

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS (both cruise cases;
existing pilot tests still green).

- [ ] **Step 5: Commit**

```bash
git add fcs/schemes/cruise.lua fcs/input/pilot.lua tests/test_scheme_cruise.lua
git commit -m "feat(fcs): CRU surge arrests at throttle 0 (frontal brake) (fix #3)" # + trailer
```

---

### Task 5: Pilot brake setpoint helper + wire into non-tilt modes

**Files:**
- Modify: `fcs/input/pilot.lua` (add `_brakeSetpoint`; non-tilt branch at `:142-144`; require `brake`)
- Test: `tests/test_pilot_modes.lua`

**Interfaces:**
- Consumes: `brake.angle`, `brake.vector` (Task 2); `self.cfg.tiltBrake`, `self.policy`,
  `self.throttle`, `self.driftArrest`; `meas.surgeVel`, `meas.swayVel`; `held.brake`.
- Produces: `Pilot:_brakeSetpoint(held, meas, tilting) -> pitch, roll` (brake injection, 0 when idle).

- [ ] **Step 1: Write the failing test** (append to `tests/test_pilot_modes.lua`; add a meas helper
with velocities)

```lua
local function measv(o) o = o or {}
  return { altitude=o.altitude or 10, heading=o.heading or 0, swayPos=o.swayPos or 0,
           surgePos=o.surgePos or 0, surgeVel=o.surgeVel or 0, swayVel=o.swayVel or 0,
           pitch=o.pitch or 0, roll=o.roll or 0, yawRate=o.yawRate or 0 }
end
local TB = { enabled=true, engageSpeed=30, satSpeed=100, minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 }
local CRU_FEEL = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                   swaySpeed=5, swayLead=10, cruiseThrottleRate=1, cruiseThrottleMax=1, tiltBrake=TB }

t.test("CRU auto tilt-brake: throttle 0, fast forward drift, CPL -> nose-up pitch setpoint", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })   -- throttle 0, 80 blk/s forward
  t.truthy(sp.pitch > 0.2, "aerobrake nose-up engaged")
  t.near(sp.roll, 0, 1e-9, "no lateral drift -> no roll brake")
end)

t.test("CRU: forward throttle (throttle>0) does NOT auto tilt-brake", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  p:update(1.0, { surgeFwd=true }, measv{ surgeVel=80 })  -- ramp throttle up
  local sp = p:update(0.05, { surgeFwd=true }, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "cruising forward stays level")
end)

t.test("CRU auto tilt-brake suppressed under DCPL (drift allowed)", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(false); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "DCPL coasts, no auto brake")
end)

t.test("CRU below engage speed -> no tilt (thrusters only)", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=20 })
  t.near(sp.pitch, 0, 1e-9, "20 blk/s < 30 engage")
end)

t.test("PRE (tiltBrake disabled) never auto tilt-brakes even fast", function()
  local Pilot = require("fcs.input.pilot")
  local feel = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                 swaySpeed=5, swayLead=10, tiltBrake={ enabled=false, engageSpeed=30, satSpeed=100,
                 minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 } }
  local p = Pilot.new(feel)
  p:setMode({ tilt=false, surge="position" }, feel); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })
  t.near(sp.pitch, 0, 1e-9, "PRE stays level")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (first case: `sp.pitch`
is 0 today).

- [ ] **Step 3: Implement** — in `pilot.lua`: add `local brake = require("fcs.brake")` at the top; add
the helper; wire non-tilt branch.

```lua
-- Tilt-brake setpoint (fix #3): a speed-scaled pitch/roll tilt opposing the horizontal drift, held
-- as an attitude setpoint the leveling loop maintains. Engages when this craft is arresting (CRU at
-- throttle 0 / MAN|DRN hands-off) under CPL, above the engage speed, in a tiltBrake-enabled mode.
-- held.brake overrides the master mode in any mode and uses the steeper button curve; where tilt is
-- disabled (PRE/LDG) the button still forces a lateral hold but injects no tilt (returns 0,0).
function Pilot:_brakeSetpoint(held, meas, tilting)
  local tb = self.cfg.tiltBrake
  local btn = held.brake and true or false
  local autoArrest
  if self.policy.surge == "throttle" then autoArrest = (self.throttle or 0) <= 0
  elseif self.policy.tilt then autoArrest = not tilting
  else autoArrest = true end
  local engaged = btn or (autoArrest and self.driftArrest)
  if not engaged or not (tb and tb.enabled) then return 0, 0 end
  local sv, wv = meas.surgeVel or 0, meas.swayVel or 0
  local s = math.sqrt(sv * sv + wv * wv)
  return brake.vector(brake.angle(s, tb, btn), sv, wv)
end
```

Wire the non-tilt branch (`pilot.lua:142-144`):

```lua
  if self.policy.tilt then
    -- (unchanged tilt block; Task 6 injects the brake here)
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    sp.pitch, sp.roll = self.tilt.pitch, self.tilt.roll
  else
    sp.pitch, sp.roll = self:_brakeSetpoint(held, meas, false)   -- 0,0 unless braking
  end
```

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS (all Task-5 cases;
existing pilot tests green — non-braking still yields `sp.pitch=0`).

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_modes.lua
git commit -m "feat(fcs): pilot auto tilt-brake for non-tilt modes (fix #3)" # + trailer
```

---

### Task 6: Tilt-mode brake (MAN/DRN hands-off) + DRN hands-off arrest

**Files:**
- Modify: `fcs/input/pilot.lua` (tilt branch `:131-141`; DRN translate/drift interaction `:96-126`)
- Test: `tests/test_pilot_modes.lua`

**Interfaces:**
- Consumes: `Pilot:_brakeSetpoint` (Task 5), the existing `tilting` predicate (`:120`).
- Produces: MAN/DRN inject the brake vector onto the pilot tilt **only when hands-off**; DRN arrests
  surge/sway (holds position) when hands-off + CPL.

- [ ] **Step 1: Write the failing test** (append to `tests/test_pilot_modes.lua`)

```lua
local DRN_FEEL = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                   swaySpeed=5, swayLead=10, tiltRate=0.8, tiltCap=0.5, tiltBrake=TB }

t.test("MAN hands-off at speed brakes; while tilting it does not", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(DRN_FEEL)
  p:setMode({ tilt=true, surge="position" }, DRN_FEEL); p:setMaster(true); p:reset(measv())
  local sp = p:update(0.05, {}, measv{ surgeVel=80 })              -- hands off, fast forward
  t.truthy(sp.pitch > 0.2, "hands-off -> aerobrake")
  -- actively tilting (pilot owns attitude): brake stands down
  local p2 = Pilot.new(DRN_FEEL)
  p2:setMode({ tilt=true, surge="position" }, DRN_FEEL); p2:setMaster(true); p2:reset(measv())
  local sp2 = p2:update(0.05, { pitchUp=true }, measv{ surgeVel=80 })
  t.truthy(sp2.pitch < 0.2, "tilting -> pilot tilt only, brake suppressed")
end)

t.test("DRN hands-off + CPL holds surgePos (arrest), not frozen coast", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(DRN_FEEL)
  p:setMode({ tilt=true, surge="position", translate=false }, DRN_FEEL)
  p:setMaster(true); p:reset(measv{ surgePos=0 })
  local sp = p:update(0.05, {}, measv{ surgePos=5, surgeVel=8 })   -- drifted to +5
  -- arrest holds the reset position (0), producing a corrective error vs meas(5)
  t.near(sp.surgePos, 0, 0.5, "surgePos held near reset (arrest), not tracking meas")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (first case: `sp.pitch`
is just the pilot tilt, no brake).

- [ ] **Step 3: Implement** — tilt branch: add the brake injection when hands-off.

```lua
  if self.policy.tilt then
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    local bp, br = self:_brakeSetpoint(held, meas, tilting)   -- 0,0 while tilting
    sp.pitch, sp.roll = self.tilt.pitch + bp, self.tilt.roll + br
  else
    sp.pitch, sp.roll = self:_brakeSetpoint(held, meas, false)
  end
```

DRN hands-off arrest: DRN uses `translate=false`, which skips the leash so surge/sway stay at their
reset value; the existing drift rule (`:125-126`) sets `sp.*=meas` only when `tilting` or DCPL-uncommanded,
so hands-off CPL already **holds** the reset position (an arrest). This already satisfies the test — no
extra change needed **if** the reset position equals where you want to hold. Confirm the test passes; if
DRN should hold *current* position on entering hands-off rather than the old reset position, capture it:
in the tilt block, when transitioning from tilting→hands-off, reseed `sp.surgePos, sp.swayPos =
meas.surgePos, meas.swayPos` once (edge-triggered on a `self.tiltWasHeld` flag, mirroring the yaw
release capture at `:158-163`). Add only if the test or in-world shows it snapping to a stale position.

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_modes.lua
git commit -m "feat(fcs): tilt-mode brake (MAN/DRN hands-off) + DRN arrest (fix #3)" # + trailer
```

---

### Task 7: Brake button — master-mode override, throttle cut, aggressive hold

**Files:**
- Modify: `fcs/input/pilot.lua` (drift rule `:125-126`; throttle branch `:145-151`)
- Test: `tests/test_pilot_drift.lua`, `tests/test_pilot_modes.lua`

**Interfaces:**
- Consumes: `held.brake`.
- Produces: `held.brake` suppresses the DCPL drift-relax (forces surge/sway arrest in any master mode);
  in CRU it commands MAIN off (`sp.surgeThrottle=0`) for the tick while held.

- [ ] **Step 1: Write the failing test** (append to `tests/test_pilot_drift.lua`)

```lua
t.test("brake button forces surge arrest even under DCPL", function()
  local Pilot = require("fcs.input.pilot")
  local feel = { headingRate=1, climbRate=1, leadCapVert=10, surgeSpeed=10, surgeLead=20,
                 swaySpeed=5, swayLead=10, tiltBrake={ enabled=false, engageSpeed=30, satSpeed=100,
                 minAngle=0.2618, maxAngle=0.5236, buttonMax=0.7854 } }
  local m = { altitude=10, heading=0, swayPos=0, surgePos=0, surgeVel=5, swayVel=0, pitch=0, roll=0, yawRate=0 }
  local p = Pilot.new(feel)
  p:setMode({ tilt=false, surge="position" }, feel); p:setMaster(false); p:reset(m)  -- DCPL
  -- DCPL normally relaxes uncommanded surge to meas (coast); brake button must hold it instead
  local mDrift = { altitude=10, heading=0, swayPos=0, surgePos=7, surgeVel=5, swayVel=0, pitch=0, roll=0, yawRate=0 }
  local sp = p:update(0.05, { brake=true }, mDrift)
  t.near(sp.surgePos, 0, 0.5, "brake holds reset position under DCPL (no coast to 7)")
end)

t.test("CRU brake button cuts MAIN throttle for the tick", function()
  local Pilot = require("fcs.input.pilot")
  local p = Pilot.new(CRU_FEEL)
  p:setMode({ tilt=false, surge="throttle" }, CRU_FEEL); p:setMaster(true); p:reset(measv())
  p:update(1.0, { surgeFwd=true }, measv{ surgeVel=80 })          -- throttle up
  local sp = p:update(0.05, { brake=true }, measv{ surgeVel=80 }) -- brake overrides
  t.near(sp.surgeThrottle, 0, 1e-9, "MAIN commanded off while braking")
end)
```

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL.

- [ ] **Step 3: Implement** — suppress the drift-relax when braking, and cut MAIN in the throttle branch:

Drift rule (`:125-126`):

```lua
  local braking = held.brake and true or false
  if not braking and (tilting or (not self.driftArrest and not swayCmd))  then sp.swayPos  = meas.swayPos  end
  if not braking and (tilting or (not self.driftArrest and not surgeCmd)) then sp.surgePos = meas.surgePos end
```

Throttle branch (`:145-151`): command MAIN off while braking (keep the stored detent so cruise resumes
on release):

```lua
  if self.policy.surge == "throttle" then
    local d = dirOf(held, "surgeBack", "surgeFwd")
    local maxT = c.cruiseThrottleMax or 1.0
    self.throttle = self.throttle + (c.cruiseThrottleRate or 1.0) * dt * d
    if self.throttle < 0 then self.throttle = 0 elseif self.throttle > maxT then self.throttle = maxT end
    sp.surgeThrottle = (held.brake and 0) or self.throttle   -- brake cuts MAIN; detent resumes on release
  end
```

(When `held.brake`, the throttle-mode surge branch at `:104` also sees the arrest path — `self.throttle`
may still be >0, so also gate that pin on brake: change `if (self.throttle or 0) > 0` to
`if (self.throttle or 0) > 0 and not held.brake` so the brake leashes/holds surgePos immediately.)

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_drift.lua tests/test_pilot_modes.lua
git commit -m "feat(fcs): brake button override (DCPL arrest + MAIN cut) (fix #3)" # + trailer
```

---

### Task 8: Comment out the loop.lua forward-accel lean (preserve)

**Files:**
- Modify: `fcs/runtime/loop.lua:76-108` (the `ff` block)
- Test: `tests/test_loop_trim.lua` (update to assert the lean is OFF)

**Interfaces:**
- Produces: `Loop:cycle` no longer adds any feed-forward to `demands.pitch`; `diag().ffPitch == 0`.

- [ ] **Step 1: Update the test** — `test_loop_trim.lua` currently asserts the feed-forward is applied.
Rewrite its assertions to the new contract: with the lean commented, `demands.pitch` equals the scheme's
pitch output (no `ff` added) and `_ffPitch` is 0. Example replacement for the core case:

```lua
t.test("forward-accel lean is commented out: no feed-forward added to pitch", function()
  -- build a loop with a forward surge demand and a nonzero trim config; assert pitch is unbiased
  -- (see the existing harness in this file for loop construction; keep that setup, change asserts)
  -- After :cycle, the returned demands.pitch must equal the scheme pitch (ff == 0), and
  -- loop:diag(sp,m).ffPitch == 0.
  t.near(loop._ffPitch or 0, 0, 1e-9, "ffPitch zero (lean off)")
end)
```

Keep the file's existing loop-construction scaffolding; only the assertions change. Any assertion that
required a nonzero `ff` must be removed or inverted.

- [ ] **Step 2: Run and verify it fails** — `bash tests/run_headless.sh` → FAIL (lean still applied).

- [ ] **Step 3: Implement** — in `loop.lua:cycle`, comment out the `ff` computation and its application,
leaving `self._ffPitch = 0`:

```lua
  -- FORWARD-ACCEL LEAN (fix #3, PRESERVED / DISABLED): the trim is now an attitude SETPOINT computed
  -- in fcs/input/pilot.lua (brake + optional accel lean), which the #1 leveling loop holds. This old
  -- output feed-forward oversteered but kept the craft out of a loop under hard acceleration; kept
  -- for possible re-enable. luamin strips comments, so this is zero bytes in dist/. To re-enable:
  -- uncomment this block AND ensure pilot.lua is NOT also injecting a forward-accel setpoint (or the
  -- two double). Reads self.trimDir/trimGain/trimAuthority/trimFade* (setTrim, still plumbed).
  --[[
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
  if not self.brakeTrim then
    local dir = self.trimDir or 0
    if dir < 0 then if ff > 0 then ff = 0 end
    elseif dir > 0 then if ff < 0 then ff = 0 end end
  end
  self._ffPitch = ff
  demands.pitch = (demands.pitch or 0) + ff
  --]]
  self._ffPitch = 0   -- lean disabled; diag/fcslog read this
```

- [ ] **Step 4: Run and verify it passes** — `bash tests/run_headless.sh` → PASS (`test_loop_trim`,
`test_loop_diag`, and any fcslog schema test still green with `ffPitch=0`).

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop_trim.lua
git commit -m "refactor(fcs): retire forward-accel lean feed-forward (commented, fix #3)" # + trailer
```

---

### Task 9: Regression asserts + dual gate + manifest

**Files:**
- Test: `tests/test_oscillation.lua` (DAMPED no-trip on steady angle)
- Verify: `tests/modes_golden_data.lua` unchanged; `tools/run_gen.sh`; dist build.

- [ ] **Step 1: DAMPED no-false-trip test** (append to `tests/test_oscillation.lua`)

```lua
t.test("steady large pitch does not trip DAMPED (no oscillation)", function()
  local Osc = require("fcs.safety.oscillation")
  local o = Osc.new({ window=1.0, minChanges=6, deadband=0.02, calmTime=1.0 })
  local tripped = false
  for _ = 1, 40 do tripped = o:update(0.7, 0.0, 0.05) end   -- constant 0.7 rad nose-up
  t.eq(tripped, false, "constant angle never oscillates -> no trip")
end)
```

- [ ] **Step 2: Run source gate** — `bash tests/run_headless.sh` → PASS. Confirm the golden battery
(`test_modes_golden`) is green with **no** regen (tilt-brake is 0 at rest, so first-tick scheme output
is unchanged). If a golden case shifts, regen via `tools/capture_precision_golden.lua` inside CraftOS-PC
(see `tests/run_focus.sh` for the invocation) and commit the regenerated `modes_golden_data.lua`.

- [ ] **Step 3: Regen manifest** — `bash tools/run_gen.sh` (writes `manifest.lua` for the new
`fcs/brake.lua`); confirm `bash tools/run_gen.sh --check` is clean.

- [ ] **Step 4: Dist gate** — `node tools/build.mjs` then `bash tests/run_headless_dist.sh` → PASS.
Confirm `fcs/brake.lua` minified into `dist/fcs/brake.lua` and the commented lean produced **no** bytes
in `dist/fcs/runtime/loop.lua` (grep it for `ffRaw` — must be absent).

- [ ] **Step 5: Commit**

```bash
git add tests/test_oscillation.lua manifest.lua manifest-dev.lua
git commit -m "test(fcs): DAMPED steady-angle no-trip + manifest/dist regen (fix #3)" # + trailer
```

---

## Self-Review

**Spec coverage:** directional thruster arrest (Task 4) ✓; auto tilt-brake curve+vector (Tasks 2,5,6) ✓;
CRU throttle-0 arrest (Task 4) ✓; MAN/DRN hands-off (Task 6) ✓; PRE/LDG excluded (Task 1 enabled flag,
Task 5 test) ✓; brake button + CTRL + override (Tasks 3,7) ✓; trim→setpoint / lean commented (Task 8) ✓;
config + live-tune params (Task 1) ✓; DAMPED/integral/golden/comAuto regression (Task 9; integral
anti-windup is existing `pid.lua` behavior asserted via the >iBand angle in Task 5's 80-blk/s cases) ✓;
`caps.pitch/roll` raise — **in-world tuning step, not a code task** (spec §Coupling) — surfaced in the
merge/verify checklist below.

**Placeholder scan:** no TBD/TODO; every code step has real Lua. Task 6's optional
tiltWasHeld-capture and Task 8's test-scaffold reuse are conditional refinements with explicit
trigger conditions, not placeholders.

**Type consistency:** `brake.angle(s,cfg,button)` / `brake.vector(theta,surgeVel,swayVel)` and
`_brakeSetpoint(held,meas,tilting)` used identically across Tasks 2/5/6/7. `feel.tiltBrake` field names
(`enabled/engageSpeed/satSpeed/minAngle/maxAngle/buttonMax`) identical in Tasks 1/2/5.

## Post-merge (not code tasks)

- **Finish branch:** `superpowers:finishing-a-development-branch` → `git merge --no-ff` to `main`,
  push, then in-world verify (spec §Build/verify checklist).
- **In-world:** verify CTRL is forwarded by the typewriter (fallback `keys.c`); **raise CRU
  `caps.pitch`/`caps.roll`** until the 30–45° hold is achieved; tune the curve to feel; confirm #1 base
  stability first (owed).
- **Roadmap:** mark fix #3 shipped; add the "extreme-attitude auto-recovery (hand-flown)" future safety
  item noted in the spec.
