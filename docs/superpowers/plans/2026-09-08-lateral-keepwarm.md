# Lateral keep-warm actuation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the lateral (yaw-ring) and surge thruster banks ever going cold in flight, so they never pay Create Propulsion's 0.5 s spool ramp on a reversal — curing the hover lateral limit cycle while preserving commanded force exactly.

**Architecture:** Lift thrusters stay on the existing 16-step `Level` actuator (untouched). The "rest" group (yaw ring `YFL/YFR/YRL/YRR` + `MAIN` + `FRL/FRR`) moves to a new continuous `setPowerNormalized` keep-warm actuator, via the `Loop`'s existing lift-vs-rest seam. Keep-warm biasing (a uniform additive idle floor, net-force-neutral) is computed in the mixer; the `Loop` gates it on flight state (armed + airborne + `NORMAL`). Global config, since the spool is a hardware property identical in every mode.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 UI (not touched here), project test framework (`tests/framework.lua`), headless CraftOS-PC suite (`bash tests/run_headless.sh`).

## Global Constraints

- **Wrapped CC peripherals take NO `self`** — call `p.setPowerNormalized(x)`, never `p:setPowerNormalized(x)`.
- **At keep-warm floor 0, every behaviour must be byte-for-byte identical to today** (regression guard + off-switch).
- **Net commanded force/torque must be preserved** by keep-warm (uniform additive floor is neutral); only a small top-of-range headroom may be lost.
- **Continuous throttle is required** (not 16-step) so MAIN can idle at ~0.003 to balance the frontals (thrust ratio MAIN:2·frontal ≈ 20:1).
- **No lateral-hold retune** in this plan (ka/ks/vmax/leash unchanged).
- New test files MUST be registered in `tests/suite_probe.lua`'s `suites` list or they will not run.
- Run the suite with `bash tests/run_headless.sh` from the repo root.
- Branch: `feat/lateral-keepwarm` (already created; spec committed there).

---

### Task 1: Backend continuous-throttle write

**Files:**
- Modify: `fcs/io/backend.lua` (add method next to `setThrusterLevel`, ~line 28-31)
- Test: `tests/test_backend.lua`

**Interfaces:**
- Produces: `Backend:setThrusterNormalized(id, throttle)` — writes `p.setPowerNormalized(throttle)` for the peripheral bound to `id`; no-op if unbound.

- [ ] **Step 1: Write the failing test** (append to `tests/test_backend.lua`)

```lua
t.test("setThrusterNormalized writes setPowerNormalized on the bound peripheral", function()
  local got = {}
  local shim = { wrap = function(name)
    if name == "phys_yfl" then return { setPowerNormalized = function(v) got.v = v end } end
    return nil
  end }
  local b = Backend.new(shim, { thrusters = { YFL = "phys_yfl" }, sensors = {} })
  b:setThrusterNormalized("YFL", 0.42)
  t.near(got.v, 0.42, 1e-9, "throttle passed through to setPowerNormalized")
end)
t.test("setThrusterNormalized is a no-op when the id is unbound", function()
  local shim = { wrap = function() return nil end }
  local b = Backend.new(shim, { thrusters = {}, sensors = {} })
  b:setThrusterNormalized("YFL", 0.5)   -- must not error
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `test_backend` reports `setThrusterNormalized` nil / method missing.

- [ ] **Step 3: Implement** (in `fcs/io/backend.lua`, immediately after `setThrusterLevel`)

```lua
function Backend:setThrusterNormalized(id, throttle)
  local p = self:_periph(self.config.thrusters[id])
  if p then p.setPowerNormalized(throttle) end   -- 0..1 continuous; wrapped peripherals take NO self
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `test_backend` green; whole suite still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/backend.lua tests/test_backend.lua
git commit -m "feat(fcs): backend setThrusterNormalized (continuous throttle write)"
```

---

### Task 2: Continuous keep-warm actuator

**Files:**
- Create: `fcs/actuate/keepwarm.lua`
- Create: `tests/test_keepwarm.lua`
- Modify: `tests/suite_probe.lua` (register the new test)

**Interfaces:**
- Consumes: `Backend:setThrusterNormalized(id, throttle)` (Task 1).
- Produces: `KeepWarm.new({ backend, tol?, fuelScale?, dispatch? })`, `:apply(duties, dt)`, `:state(id)`, `:setFuelScale(x)`. Drives `backend:setThrusterNormalized`; writes only when the (fuel-scaled) throttle moves more than `tol` (default 0.01); dispatches changed writes concurrently. Same interface shape as `fcs/actuate/level.lua`.

- [ ] **Step 1: Write the failing test** (`tests/test_keepwarm.lua`)

```lua
local t = require("tests.framework")
local KeepWarm = require("fcs.actuate.keepwarm")

local function fakeBackend()
  local b = { writes = 0, thr = {} }
  function b:setThrusterNormalized(id, v) self.writes = self.writes + 1; self.thr[id] = v end
  return b
end

t.test("passes continuous throttle straight through (no quantization)", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ YFL = 0.0, YFR = 0.333, MAIN = 0.003 }, 0.05)
  t.near(b.thr.YFL, 0.0, 1e-9); t.near(b.thr.YFR, 0.333, 1e-9); t.near(b.thr.MAIN, 0.003, 1e-9)
end)
t.test("clamps throttle to [0,1]", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ H = 1.4, L = -0.2 }, 0.05)
  t.near(b.thr.H, 1.0, 1e-9); t.near(b.thr.L, 0.0, 1e-9)
end)
t.test("writes only when throttle moves beyond tol", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b, tol = 0.01 })
  a:apply({ YFL = 0.20 }, 0.05); t.eq(b.writes, 1)   -- first write
  a:apply({ YFL = 0.205 }, 0.05); t.eq(b.writes, 1)  -- within tol -> no write
  a:apply({ YFL = 0.22 }, 0.05); t.eq(b.writes, 2)   -- beyond tol -> write
end)
t.test("fuelScale scales the throttle", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:setFuelScale(0.5)
  a:apply({ YFL = 0.4 }, 0.05)
  t.near(b.thr.YFL, 0.2, 1e-9, "0.4 * 0.5")
end)
t.test("setFuelScale ignores nil/non-positive", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:setFuelScale(nil); a:setFuelScale(0); a:setFuelScale(-1)
  a:apply({ YFL = 0.4 }, 0.05)
  t.near(b.thr.YFL, 0.4, 1e-9, "invalid scale leaves 1.0 in effect")
end)
t.test("dispatches changed writes as one concurrent batch", function()
  local b = fakeBackend(); local sizes = {}
  local a = KeepWarm.new({ backend = b,
    dispatch = function(fns) sizes[#sizes+1] = #fns; for i = 1, #fns do fns[i]() end end })
  a:apply({ YFL = 0.5, YFR = 0.0, MAIN = 0.1 }, 0.05)
  t.eq(sizes[1], 3)
  a:apply({ YFL = 0.5, YFR = 0.0, MAIN = 0.1 }, 0.05)  -- all unchanged
  t.eq(sizes[2], 0)
end)
t.test("state returns the last written throttle, 0 if unseen", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b })
  a:apply({ YFL = 0.7 }, 0.05)
  t.near(a:state("YFL"), 0.7, 1e-9); t.eq(a:state("XX"), 0)
end)
```

- [ ] **Step 2: Register the test** — in `tests/suite_probe.lua`, add `"tests.test_keepwarm"` to the `suites` list (e.g. right after `"tests.test_level"`).

- [ ] **Step 3: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — module `fcs.actuate.keepwarm` not found.

- [ ] **Step 4: Implement** (`fcs/actuate/keepwarm.lua`)

```lua
-- Continuous keep-warm thruster actuator. Drives setPowerNormalized(0..1) so a thruster held
-- at a small idle floor stays SPOOLED (Create Propulsion spools 0->full over 0.5s on every
-- 0->on edge; a warm bank has no spool lag on a reversal). Writes only when the fuel-scaled
-- throttle moves beyond `tol` (a steady hover -> almost no writes), dispatched concurrently so
-- N changes cost ~1 server tick (same reasoning as fcs/actuate/level.lua). Same interface as Level.
local KeepWarm = {}
KeepWarm.__index = KeepWarm

local function defaultDispatch(fns)
  local n = #fns
  if n == 0 then return end
  if n == 1 then fns[1](); return end
  if parallel and parallel.waitForAll then
    parallel.waitForAll(table.unpack(fns, 1, n))
  else
    for i = 1, n do fns[i]() end
  end
end

function KeepWarm.new(cfg)
  return setmetatable({ backend = cfg.backend, last = {},
    tol = cfg.tol or 0.01, fuelScale = cfg.fuelScale or 1.0,
    dispatch = cfg.dispatch or defaultDispatch }, KeepWarm)
end

function KeepWarm:state(id) return self.last[id] or 0 end

-- Compensation-layer multiplier: scales the throttle only, base tuning untouched.
function KeepWarm:setFuelScale(x)
  if type(x) == "number" and x > 0 then self.fuelScale = x end
end

local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 else return v end end

function KeepWarm:apply(duties, dt)
  local writes = {}
  for id, duty in pairs(duties) do
    local throttle = clamp((duty or 0) * self.fuelScale)
    local prev = self.last[id]
    if prev == nil or math.abs(throttle - prev) > self.tol then
      self.last[id] = throttle
      writes[#writes + 1] = function() self.backend:setThrusterNormalized(id, throttle) end
    end
  end
  self.dispatch(writes)
end

return KeepWarm
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: `test_keepwarm` green; suite green.

- [ ] **Step 6: Commit**

```bash
git add fcs/actuate/keepwarm.lua tests/test_keepwarm.lua tests/suite_probe.lua
git commit -m "feat(fcs): continuous keep-warm actuator (setPowerNormalized, write-on-change)"
```

---

### Task 3: Mixer keep-warm biasing

**Files:**
- Modify: `fcs/mixer/level_flight.lua` (`mixLateral`, `mixSurge`, `mix`; add `setKeepWarm`; add thrust-weight constants)
- Test: `tests/test_mixer.lua` (ring + `mix` gate), `tests/test_surge_mixer.lua` (surge balance)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Mixer:setKeepWarm({ floor, surgeFront, mainRatio })` (stores config; missing fields -> 0). `Mixer:mixLateral(sway, yaw, yawRear, floor)`, `Mixer:mixSurge(surge, floorFront, mainRatio)` (extra args optional, default 0). `Mixer:mix(demands, warm)` — when `warm` is truthy and keep-warm is configured, applies the stored floors; otherwise (or `warm` falsy) behaves exactly as before. `floorMain = floorFront * mainRatio`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_mixer.lua`:

```lua
t.test("keepwarm OFF (warm=false) reproduces the plain mix byte-for-byte", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.07, mainRatio = 0.05 })
  local a = m:mix({ heave = 0.5, pitch = 0, roll = 0, sway = 0.2, yaw = 0.1, surge = -0.3 }, false)
  local b = m:mix({ heave = 0.5, pitch = 0, roll = 0, sway = 0.2, yaw = 0.1, surge = -0.3 })  -- no warm arg
  for _, id in ipairs({ "YFL","YFR","YRL","YRR","MAIN","FRL","FRR" }) do
    t.near(a[id], b[id], 1e-9, id .. " identical with warm=false")
  end
end)
t.test("keepwarm ON keeps every yaw-ring thruster >= floor", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.07, mainRatio = 0.05 })
  local out = m:mix({ heave = 0.5, sway = 0.2, yaw = 0.0, surge = 0 }, true)
  for _, id in ipairs({ "YFL","YFR","YRL","YRR" }) do
    t.truthy(out[id] >= 0.08 - 1e-9, id .. " warm (>= floor)")
  end
end)
t.test("keepwarm ON preserves net sway force and net yaw torque", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.07, mainRatio = 0.05 })
  local function netSway(o) return (o.YFL + o.YRL) - (o.YFR + o.YRR) end   -- SWAY_DIR
  local function netYaw(o)  return (o.YFL - o.YFR) - (o.YRL - o.YRR) end   -- YAW_DIR (+,-,-,+)
  local cold = m:mix({ heave = 0.5, sway = 0.15, yaw = 0.1, surge = 0 }, false)
  local warm = m:mix({ heave = 0.5, sway = 0.15, yaw = 0.1, surge = 0 }, true)
  t.near(netSway(warm), netSway(cold), 1e-9, "net sway unchanged")
  t.near(netYaw(warm),  netYaw(cold),  1e-9, "net yaw unchanged")
end)
```

Append to `tests/test_surge_mixer.lua`:

```lua
t.test("keepwarm surge idle is net-zero and both sides warm at surge=0", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.06, mainRatio = 0.05 })
  local out = m:mix({ heave = 0.5, surge = 0 }, true)
  -- floorMain = 0.06*0.05 = 0.003 ; both sides warm
  t.truthy(out.MAIN >= 0.003 - 1e-9, "MAIN warm")
  t.truthy(out.FRL >= 0.06 - 1e-9 and out.FRR >= 0.06 - 1e-9, "frontals warm")
  -- net-zero requires mainRatio == 2*wFront/wMain; here the test just asserts the idle formula:
  t.near(out.MAIN, 0.003, 1e-9); t.near(out.FRL, 0.06, 1e-9)
end)
t.test("keepwarm surge preserves the commanded differential", function()
  local m = Mixer.new(); m:setKeepWarm({ floor = 0.08, surgeFront = 0.06, mainRatio = 0.05 })
  local warm = m:mix({ heave = 0.5, surge = -0.3 }, true)
  local cold = m:mix({ heave = 0.5, surge = -0.3 }, false)
  -- differential (command part) preserved: warm - idle == cold
  t.near(warm.FRL - 0.06, cold.FRL, 1e-9, "frontal differential preserved")
  t.near(warm.MAIN - 0.003, cold.MAIN, 1e-9, "MAIN idle-only when reversing")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `setKeepWarm` nil / `mix` ignores `warm`.

- [ ] **Step 3: Implement** — in `fcs/mixer/level_flight.lua`:

Add after `Mixer.new` (constructor), initialise the config so `mix` without `setKeepWarm` still works:

```lua
-- (inside Mixer.new's returned table, add:)  keepWarm = { floor = 0, surgeFront = 0, mainRatio = 0 }
```

Add a setter (near `setCom`):

```lua
function Mixer:setKeepWarm(cfg)
  cfg = cfg or {}
  self.keepWarm = {
    floor = tonumber(cfg.floor) or 0,
    surgeFront = tonumber(cfg.surgeFront) or 0,
    mainRatio = tonumber(cfg.mainRatio) or 0,
  }
  return self
end
```

Replace `mixLateral`:

```lua
function Mixer:mixLateral(sway, yaw, yawRear, floor)
  floor = floor or 0
  local out = {}
  for id, ydir in pairs(YAW_DIR) do
    local raw = (SWAY_DIR[id] or 0) * (sway or 0)
              + ydir * (yaw or 0)
              + (YAWREAR_DIR[id] or 0) * (yawRear or 0)
    out[id] = clamp((raw > 0 and raw or 0) + floor)   -- max(0,raw)+floor ; uniform floor is net-neutral
  end
  return out
end
```

Replace `mixSurge`:

```lua
function Mixer:mixSurge(surge, floorFront, mainRatio)
  surge = surge or 0
  floorFront = floorFront or 0
  local floorMain = floorFront * (mainRatio or 0)
  local fwd = surge > 0 and surge or 0
  local rev = surge < 0 and -surge or 0
  return {
    MAIN = clamp(fwd + floorMain),
    FRL  = clamp(rev + floorFront),
    FRR  = clamp(rev + floorFront),
  }
end
```

Replace `mix`:

```lua
function Mixer:mix(d, warm)
  local FL, FR, RL, RR = mixLift(d.heave or 0, d.pitch or 0, d.roll or 0, self.com)
  local out = { FL = FL, FR = FR, RL = RL, RR = RR }
  local kw = warm and self.keepWarm or nil
  local floor      = kw and kw.floor      or 0
  local frontFloor = kw and kw.surgeFront or 0
  local mainRatio  = kw and kw.mainRatio  or 0
  for id, duty in pairs(self:mixLateral(d.sway, d.yaw, d.yawRear, floor)) do out[id] = duty end
  for id, duty in pairs(self:mixSurge(d.surge, frontFloor, mainRatio)) do out[id] = duty end
  return out
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: new mixer + surge tests green; existing `test_mixer`/`test_surge_mixer`/`test_yaw_mixer`/`test_mixer_yawrear` still green (they call `mix(d)` / `mixLateral(a,b,c)` with no floor → floor defaults 0 → identical).

- [ ] **Step 5: Commit**

```bash
git add fcs/mixer/level_flight.lua tests/test_mixer.lua tests/test_surge_mixer.lua
git commit -m "feat(fcs): mixer keep-warm biasing (uniform net-neutral idle floor, gated by warm flag)"
```

---

### Task 4: Loop gates keep-warm on flight state

**Files:**
- Modify: `fcs/runtime/loop.lua` (`cycle` — pass the `warm` flag to `mixer:mix`)
- Test: `tests/test_loop.lua`

**Interfaces:**
- Consumes: `Mixer:mix(demands, warm)` (Task 3).
- Produces: `Loop:cycle` calls `self.mixer:mix(demands, warm)` where `warm = self.armed and (m.onGround ~= true) and self.mode == "NORMAL"`. In DAMPED/EMRCVR/grounded/disarmed, `warm` is false → mixer floor 0 → lateral thrusters coldable.

- [ ] **Step 1: Write the failing test** (append to `tests/test_loop.lua`)

Use a mixer spy so the assertion is on the `warm` argument the loop passes. Follow the existing `test_loop.lua` construction of a `Loop` (scheme/mixer/pwm/backend); add:

```lua
t.test("loop passes warm=true only when armed, airborne and NORMAL", function()
  local seen = {}
  local spyMixer = { mix = function(_, d, warm) seen[#seen+1] = warm; return {} end }
  local loop = makeLoop({ mixer = spyMixer })   -- helper already in this file; NORMAL osc, armed
  loop:arm(true)
  loop:cycle(0.05, { onGround = false, pitch = 0, roll = 0, heading = 0, yawRate = 0,
                     altitude = 10, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 })
  t.eq(seen[#seen], true, "airborne+armed+NORMAL -> warm")
  loop:cycle(0.05, { onGround = true, pitch = 0, roll = 0, heading = 0, yawRate = 0,
                     altitude = 10, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 })
  t.eq(seen[#seen], false, "grounded -> not warm")
end)
```

> NOTE for implementer: `tests/test_loop.lua` already builds a `Loop` for its other cases — reuse that construction (a real `Mixer` or a stub with `setCom`). If the existing helper doesn't accept a mixer override, add a minimal local `makeLoop` in the test that injects `spyMixer` (it needs only a `mix` method here; the loop's non-armed path applies zeros via `pwm`, so give the loop a no-op `pwm`/`sd` too). Assert on the `warm` argument, not on thruster values.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — loop calls `mix(demands)` with no second arg, so `seen[#seen]` is `nil`, not `true`.

- [ ] **Step 3: Implement** — in `fcs/runtime/loop.lua`, `cycle`, replace the mix call (currently `local duties = self.mixer:mix(demands)`, ~line 119):

```lua
  local warm = self.armed and (m.onGround ~= true) and self.mode == "NORMAL"
  local duties = self.mixer:mix(demands, warm)
```

(`self.mode` is already set above this line; `m.onGround` is the sensor snapshot used earlier for `grounded`.)

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: new loop test green; `test_loop`, `test_loop_setactive`, `test_loop_trim`, `test_integration` still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop.lua
git commit -m "feat(fcs): loop gates keep-warm floor on armed+airborne+NORMAL"
```

---

### Task 5: Keep-warm defaults + registry wiring

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (top-level `keepWarm` block, near `com`/`osc`)
- Modify: `fcs/modes/registry.lua` (`M.build` — call `mixer:setKeepWarm`)
- Test: `tests/test_tuningdefaults.lua`, `tests/test_modes_registry.lua`

**Interfaces:**
- Consumes: `Mixer:setKeepWarm` (Task 3); `tuning.keepWarm` (from defaults, deep-merged through `cfgspec`).
- Produces: `DEFAULTS.keepWarm = { floor, surgeFront, mainRatio }`; `registry.build` applies it to the shared mixer once at boot.

Derivation of `mainRatio` default: net-neutral surge idle needs `wMain·floorMain = 2·wFront·floorFront`, i.e. `mainRatio = floorMain/floorFront = 2·wFront/wMain`. From mod source, thrust ∝ `width³ × multiblockMult`: MAIN 3×3×3 = `27×1.5 = 40.5`, each frontal 1×1×1 = `1` ⇒ `mainRatio = 2·1/40.5 ≈ 0.0494`. Craft/config-specific → tunable.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_tuningdefaults.lua`:

```lua
t.test("defaults expose a keepWarm block with floor/surgeFront/mainRatio", function()
  local d = require("fcs.io.tuningdefaults").get()
  t.truthy(d.keepWarm, "keepWarm present")
  t.truthy(d.keepWarm.floor and d.keepWarm.floor > 0, "floor set")
  t.truthy(d.keepWarm.surgeFront and d.keepWarm.surgeFront > 0, "surgeFront set")
  t.near(d.keepWarm.mainRatio, 0.0494, 0.005, "mainRatio ~ 2*wFront/wMain")
end)
```

Append to `tests/test_modes_registry.lua`:

```lua
t.test("registry applies keepWarm config to the shared mixer", function()
  local seen
  local FakeMixer = { setCom = function(s) return s end,
    setKeepWarm = function(s, cfg) seen = cfg; return s end }
  -- Inject via a tuning stub carrying keepWarm; use the real build path with a mixer spy.
  -- If registry.build constructs the mixer internally, assert instead on the built descriptor's
  -- mixer having keepWarm applied: build with real Mixer and read mixer.keepWarm.
  local Registry = require("fcs.modes.registry")
  local tuning = require("fcs.tuning")
  local reg = Registry.build(tuning)
  local mixer = reg.byId[reg.default].mixer
  t.truthy(mixer.keepWarm and mixer.keepWarm.floor >= 0, "keepWarm applied to shared mixer")
  t.near(mixer.keepWarm.mainRatio, tuning.keepWarm.mainRatio, 1e-9, "mainRatio from tuning")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `keepWarm` missing from defaults / not applied by registry.

- [ ] **Step 3: Implement**

In `fcs/io/tuningdefaults.lua`, inside the `DEFAULTS` table near `com`/`osc`/`dtMax`:

```lua
  -- Keep-warm idle floors for the unidirectional lateral/surge thrusters. GLOBAL (the Create
  -- Propulsion 0.5s spool ramp is a hardware property, identical in every mode). floor 0 disables.
  -- mainRatio = 2*wFront/wMain balances the surge idle net-zero; source-derived for a 3x3x3 MAIN
  -- (thrust ~40.5) vs two 1x1 frontals (~1 each): 2/40.5 ~ 0.049. Tune in-world if the craft differs.
  keepWarm = { floor = 0.08, surgeFront = 0.07, mainRatio = 0.049 },
```

In `fcs/modes/registry.lua`, `M.build`, right after `if tuning.com then mixer:setCom(tuning.com) end`:

```lua
  if tuning.keepWarm and mixer.setKeepWarm then mixer:setKeepWarm(tuning.keepWarm) end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: new tests green; `test_tuningdefaults`, `test_modes_registry`, `test_tuning`, `test_cfgspec` still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/io/tuningdefaults.lua fcs/modes/registry.lua tests/test_tuningdefaults.lua tests/test_modes_registry.lua
git commit -m "feat(fcs): keepWarm defaults + registry wires the shared mixer"
```

---

### Task 6: Wire the keep-warm actuator into the flight loop

**Files:**
- Modify: `tools/hover_test.lua` (`buildLoop` — the real flight loop, used by `tools/flight.lua`)
- Test: `tests/test_buildloop_modes.lua`, and the full suite / golden baseline

**Interfaces:**
- Consumes: `KeepWarm` (Task 2), the `Loop`'s lift-vs-rest split (`sd` non-nil → rest thrusters routed to `sd`).
- Produces: the flown loop drives lift via `Level` and the yaw ring + `MAIN` + `FRL/FRR` via `KeepWarm`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_buildloop_modes.lua`)

```lua
t.test("buildLoop routes lift to Level and the rest group to a keep-warm actuator", function()
  local hover = require("tools.hover_test")
  local seen = { level = {}, warm = {} }
  local backend = {
    setThrusterLevel = function(_, id, l) seen.level[id] = l end,
    setThrusterNormalized = function(_, id, v) seen.warm[id] = v end,
    sensors = function() return { onGround = false, pitch = 0, roll = 0, heading = 0, yawRate = 0,
      altitude = 0, vSpeed = 0, swayPos = 0, surgePos = 0, swayVel = 0, surgeVel = 0 } end,
    liftIds = function() return { "FL","FR","RL","RR" } end,
    lateralIds = function() return { "YFL","YFR","YRL","YRR" } end,
    mainIds = function() return { "MAIN" } end,
    frontalIds = function() return { "FRL","FRR" } end,
  }
  local loop = hover.buildLoop(backend)
  loop:arm(true)
  loop:cycle(0.05, backend:sensors())
  t.truthy(next(seen.level) ~= nil, "lift thrusters written via setThrusterLevel")
  t.truthy(seen.warm.YFL ~= nil or seen.warm.MAIN ~= nil, "rest thrusters written via setPowerNormalized")
end)
```

> NOTE: `buildLoop` returns `loop, registry`; the test uses only the loop. The fake backend's methods take an explicit first arg because they are called as `backend:method(...)`. Keep-warm floor is live here (armed+airborne+NORMAL) so idle values appear on the rest group.

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh`
Expected: FAIL — today `sd=nil`, so the rest group goes through `Level` (`setThrusterLevel`), and `seen.warm` stays empty.

- [ ] **Step 3: Implement** — in `tools/hover_test.lua`:

Add the require near the other actuator require:

```lua
local KeepWarm = require("fcs.actuate.keepwarm")
```

In `buildLoop`, change the `Loop.new` actuator wiring:

```lua
  local loop = Loop.new({ scheme = d.scheme, mixer = d.mixer, caps = d.caps,
    pwm = Level.new({ backend = backend, steps = 15 }),
    sd = KeepWarm.new({ backend = backend }),
    backend = backend, dtMax = tuning.dtMax, osc = tuning.osc,
    hoverDuty = tuning.gains.hoverDuty })
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/run_headless.sh`
Expected: new test green. `test_hover_test`, `test_flight`, `test_integration`, `test_buildloop_modes` green.

- [ ] **Step 5: Regenerate the golden baseline if the suite flags it, and confirm full green**

Some suites assert a golden duties/manifest baseline. If `test_modes_golden` or a manifest check fails purely because the actuator wiring changed, regenerate per the project's method (`bash tools/run_gen.sh` for the manifest; follow the golden-regen note the failing test prints). Re-run:

Run: `bash tests/run_headless.sh`
Expected: full suite green (src and dist gates).

- [ ] **Step 6: Commit**

```bash
git add tools/hover_test.lua tests/test_buildloop_modes.lua
# plus any regenerated golden/manifest files
git commit -m "feat(fcs): fly the yaw-ring + surge thrusters through the keep-warm actuator"
```

---

## Self-Review

**Spec coverage:**
- Continuous actuator (`setPowerNormalized`) — Tasks 1, 2, 6. ✓
- Lift unchanged / rest group only — Task 6 (`pwm=Level`, `sd=KeepWarm`); Task 3 biasing touches only ring+surge. ✓
- Uniform net-neutral floor math, F=0 identical — Task 3 tests. ✓
- Surge balanced idle (`mainRatio`, continuous) — Tasks 3, 5. ✓
- State gating (armed+airborne+NORMAL; cold otherwise) — Task 4. ✓
- Global config + defaults — Task 5. ✓
- Fuel-scale preserved — Task 2 (actuator applies `fuelScale`; `Loop:setFuelScale` already reaches `sd`). ✓
- Tests: warm/neutral/cold, F=0 regression, disarmed/grounded/DAMPED cold — Tasks 2–4, 6. ✓
- **Deferred (documented, not in this plan):** BIT/CONFIG live-tune rows for `floor`/`surgeFront`/`mainRatio`. First in-world A/B is keep-warm ON (this plan's default) vs the already-logged OFF flight `487b634ca6`; live-tune rows are a fast-follow once the mechanism is confirmed. `keepWarm.floor=0` in defaults is the code-level off-switch until then.

**Placeholder scan:** none — every step has concrete code and a run command.

**Type consistency:** `setThrusterNormalized(id, throttle)` (Task 1) is what `KeepWarm.apply` calls (Task 2) and what Task 6's fake backend records. `Mixer:mix(d, warm)` (Task 3) is what `Loop:cycle` calls (Task 4). `mixer:setKeepWarm({floor,surgeFront,mainRatio})` (Task 3) matches `tuning.keepWarm` fields (Task 5). `floorMain = surgeFront * mainRatio` consistent across Task 3 impl and Task 5 derivation. ✓

## Verification note

Headless tests prove the math and wiring; the **cure is confirmed in-world** (the spool physics are not in CraftOS). After the suite is green: deploy, hover with logging on, and compare against flight `487b634ca6`. Expect the lateral limit cycle to collapse; if surge shows a slow steady idle drift, trim `keepWarm.mainRatio` (that is the expected first surge tuning step).
