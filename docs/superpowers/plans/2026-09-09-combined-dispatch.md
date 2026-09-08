# Combined actuator dispatch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Restore the control-loop rate (~10Hz → ~14Hz) that keep-warm regressed, by issuing ONE concurrent write-dispatch per cycle instead of two.

**Architecture:** Since keep-warm, `Loop:apply` runs two separate `parallel.waitForAll` batches per cycle — lift via `Level`, rest via `KeepWarm` — and each batch costs a full server tick (~50ms), so a cycle writing both groups pays ~2 ticks. Fix: each actuator exposes its write closures via `:planWrites(duties)` (no dispatch); `Loop:apply` collects both and dispatches them together in ONE batch. `:apply` is kept (calls planWrites + dispatch) for standalone use and existing tests.

**Tech Stack:** Lua 5.1 (CC:Tweaked), project test framework, headless CraftOS-PC.

## Global Constraints

- Branch `perf/combined-dispatch` (off `main`, already created).
- Behavior-preserving: the SAME thruster writes happen with the SAME values and the SAME write-on-change gating; only the number of `dispatch`/`waitForAll` calls per cycle changes (2 → 1). `Level:apply`/`KeepWarm:apply` standalone behavior is unchanged (existing `test_level`/`test_keepwarm` stay green).
- Concurrent batching (the Flight #6 fix) must be preserved — one `waitForAll` for the combined set, never sequential per-write.
- Suite lists live in `tests/run_headless.sh` and `tests/run_headless_dist.sh`. `dist/` is a committed artifact. Never stage user untracked files (`E2E-TEST-REPORT-*.md`, `TASKING *.md`, `eh2 flight log *.txt`, `image.png`) — targeted `git add` only.
- Run: `bash tests/run_headless.sh` (src), `bash tests/run_headless_dist.sh` (dist).

---

### Task 1: Actuators expose `planWrites` (Level + KeepWarm)

**Files:**
- Modify: `fcs/actuate/level.lua`, `fcs/actuate/keepwarm.lua`
- Test: `tests/test_level.lua`, `tests/test_keepwarm.lua`

**Interfaces:**
- Produces: `Level:planWrites(duties)` and `KeepWarm:planWrites(duties)` each return an array of zero-arg write closures for the thrusters whose (quantized/tolerance-gated) output changed, updating the actuator's `last` state as it collects — WITHOUT dispatching. `:apply(duties, dt)` becomes `self.dispatch(self:planWrites(duties))` (unchanged external behavior).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_level.lua`:

```lua
t.test("planWrites returns closures for changed levels without dispatching", function()
  local b = fakeBackend(); local a = Level.new({ backend = b, steps = 15 })
  local w = a:planWrites({ FL = 1.0, FR = 0.0 })
  t.eq(#w, 2, "two changed levels planned")
  t.eq(b.writes, 0, "nothing written yet (not dispatched)")
  for i = 1, #w do w[i]() end            -- execute the closures
  t.eq(b.level.FL, 15); t.eq(b.level.FR, 0)
  local w2 = a:planWrites({ FL = 1.0 })  -- unchanged -> no closure
  t.eq(#w2, 0, "unchanged level plans no write")
end)
```

Append to `tests/test_keepwarm.lua`:

```lua
t.test("planWrites returns closures for changed throttles without dispatching", function()
  local b = fakeBackend(); local a = KeepWarm.new({ backend = b, tol = 0.01 })
  local w = a:planWrites({ YFL = 0.5, MAIN = 0.0 })
  t.eq(#w, 2, "two changed throttles planned")
  t.eq(b.writes, 0, "nothing written yet")
  for i = 1, #w do w[i]() end
  t.near(b.thr.YFL, 0.5, 1e-9); t.near(b.thr.MAIN, 0.0, 1e-9)
  local w2 = a:planWrites({ YFL = 0.505 })   -- within tol -> no closure
  t.eq(#w2, 0, "within-tol change plans no write")
end)
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect FAIL (`planWrites` nil).

- [ ] **Step 3: Implement**

In `fcs/actuate/level.lua`, replace `Level:apply` with a `planWrites` + thin `apply`:

```lua
function Level:planWrites(duties)
  local writes = {}
  for id, duty in pairs(duties) do
    local level = quantize((duty or 0) * self.fuelScale * self.steps, self.steps)
    if self.last[id] ~= level then
      self.last[id] = level
      writes[#writes + 1] = function() self.backend:setThrusterLevel(id, level) end
    end
  end
  return writes
end

function Level:apply(duties, dt)
  self.dispatch(self:planWrites(duties))
end
```

In `fcs/actuate/keepwarm.lua`, replace `KeepWarm:apply` likewise:

```lua
function KeepWarm:planWrites(duties)
  local writes = {}
  for id, duty in pairs(duties) do
    local throttle = clamp((duty or 0) * self.fuelScale)
    local prev = self.last[id]
    if prev == nil or math.abs(throttle - prev) > self.tol then
      self.last[id] = throttle
      writes[#writes + 1] = function() self.backend:setThrusterNormalized(id, throttle) end
    end
  end
  return writes
end

function KeepWarm:apply(duties, dt)
  self.dispatch(self:planWrites(duties))
end
```

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; new tests green; existing `test_level`/`test_keepwarm` (which use `:apply` and the injected `dispatch` spy) still green.

- [ ] **Step 5: Commit**

```bash
git add fcs/actuate/level.lua fcs/actuate/keepwarm.lua tests/test_level.lua tests/test_keepwarm.lua
git commit -m "refactor(fcs): actuators expose planWrites (write closures without dispatch)"
```

---

### Task 2: Loop dispatches lift + rest in ONE batch

**Files:**
- Modify: `fcs/runtime/loop.lua` (`Loop:apply`)
- Test: `tests/test_loop.lua`

**Interfaces:**
- Consumes: `pwm:planWrites`, `sd:planWrites` (Task 1).
- Produces: `Loop:apply` collects lift closures (`self.pwm:planWrites(lift)`) and rest closures (`self.sd:planWrites(rest)`) into ONE list and dispatches it with a single call (`self.pwm.dispatch(fns)`). When `self.sd` is nil, unchanged (`self.pwm:apply(duties, dt)`).

- [ ] **Step 1: Write the failing test** (append to `tests/test_loop.lua`)

```lua
t.test("apply dispatches lift + rest thruster writes in a single batch", function()
  local batches = {}
  local dispatch = function(fns) batches[#batches + 1] = #fns; for i = 1, #fns do fns[i]() end end
  local wroteLevel, wroteNorm = {}, {}
  local pwm = { dispatch = dispatch,
    planWrites = function(_, d) local w = {}; for id, v in pairs(d) do w[#w+1] = function() wroteLevel[id] = v end end; return w end }
  local sd = {
    planWrites = function(_, d) local w = {}; for id, v in pairs(d) do w[#w+1] = function() wroteNorm[id] = v end end; return w end }
  local Loop = require("fcs.runtime.loop")
  local loop = Loop.new({ scheme = { reset = function() end }, mixer = {}, pwm = pwm, sd = sd, backend = {} })
  loop:apply({ FL = 0.5, FR = 0.5, RL = 0.5, RR = 0.5, YFL = 0.1, MAIN = 0.2 }, 0.05)
  t.eq(#batches, 1, "exactly ONE dispatch batch for the whole cycle")
  t.eq(batches[1], 6, "all six writes (4 lift + 2 rest) in the one batch")
  t.eq(wroteLevel.FL, 0.5, "lift routed to pwm.planWrites")
  t.eq(wroteNorm.YFL, 0.1, "rest routed to sd.planWrites")
end)
```

> NOTE: `self.isLift` is built in `Loop.new` from `frame.LIFT` = {FL,FR,RL,RR}; YFL/MAIN are not lift, so they route to `sd`. The stub `planWrites` methods take an explicit first arg (called as `self.pwm:planWrites(...)`).

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect FAIL (current `Loop:apply` calls `self.pwm:apply` + `self.sd:apply` = two dispatches; the stub pwm/sd here have no `:apply`, so it errors — confirming the old path is exercised).

- [ ] **Step 3: Implement** — in `fcs/runtime/loop.lua`, replace `Loop:apply`:

```lua
function Loop:apply(duties, dt)
  if not self.sd then
    self.pwm:apply(duties, dt)
    return
  end
  local lift, rest = {}, {}
  for id, duty in pairs(duties) do
    if self.isLift[id] then lift[id] = duty else rest[id] = duty end
  end
  -- ONE combined concurrent dispatch: two separate waitForAll batches cost two server ticks
  -- (~100ms) and halved the loop rate; collecting both actuators' write closures into a single
  -- dispatch restores ~1 tick/cycle. Concurrent batching (Flight #6) is preserved.
  local fns = self.pwm:planWrites(lift)
  local rw = self.sd:planWrites(rest)
  for i = 1, #rw do fns[#fns + 1] = rw[i] end
  self.pwm.dispatch(fns)
end
```

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; new test green; `test_loop`, `test_integration`, `test_buildloop_modes`, `test_hover_test` green (the real `Level`/`KeepWarm` have `planWrites` from Task 1 and `.dispatch`).

- [ ] **Step 5: Commit**

```bash
git add fcs/runtime/loop.lua tests/test_loop.lua
git commit -m "perf(fcs): Loop:apply issues ONE combined write-dispatch per cycle (restore loop rate)"
```

---

### Task 3: Dist rebuild + both acceptance gates

**Files:** `dist/`, `manifest.lua`, `manifest-dev.lua` (regenerated); no new source.

- [ ] **Step 1:** `node tools/build.mjs && bash tools/run_gen.sh`
- [ ] **Step 2:** Run BOTH gates green, record counts: `bash tests/run_headless.sh`, `bash tests/run_headless_dist.sh`
- [ ] **Step 3:** `git add dist manifest.lua manifest-dev.lua` (targeted — never `-A`, never the user untracked files); commit `build: regenerate dist tree + manifests for combined dispatch`
- [ ] **Step 4:** `git status --short` shows only the four user untracked files.

---

## Self-Review
**Spec coverage:** planWrites on both actuators (Task 1); single combined dispatch in the loop (Task 2); dist/gates (Task 3). ✓
**Placeholder scan:** none.
**Type consistency:** `planWrites(duties) -> {closures}` defined in Task 1, consumed by `Loop:apply` in Task 2; `self.pwm.dispatch` is the Level actuator's dispatch field (present). `:apply` retained on both actuators for standalone callers/tests. ✓

## Verification note
Headless proves the write-routing and single-batch contract; the loop-rate cure is in-world. Next hover log should show dt median back toward ~60ms (~14-16Hz) and less jitter. If it does, we move from hover testing to flight testing.
