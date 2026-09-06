# CRU Rate-Command Stability & Control-Feel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the CRU vertical limit-cycle and stiff/laggy control feel by moving altitude, yaw, and strafe to a "rate while held, position-hold on release" scheme, re-enabling a calibrated pitch feedforward (all modes except LDG), and fixing the altitude derivative D-kill defect.

**Architecture:** While a key is held, each of altitude/yaw/strafe is driven by a velocity controller (bounded by *rate* error, so the actuator never rails on a phantom position lead); on release the axis captures its current position/heading and hands off to the existing position-hold PID. The pilot generates rate commands into new setpoint fields (`climbCmd`/`yawCmd`/`strafeCmd`, nil when released); each scheme axis branches rate-vs-hold on the presence of its field. Pitch nose-up under acceleration is countered by the (previously disabled) nose-down feedforward in `loop.lua`, calibrated per mode.

**Tech Stack:** Pure Lua (CC:Tweaked / Basalt 2.0), headless-tested via CraftOS-PC. Test framework: `tests/framework.lua` (`t.test/t.eq/t.near/t.truthy`).

## Global Constraints

- Authoritative tuning source: `fcs/io/tuningdefaults.lua` (read by `fcs/tuning.lua` via `cfgspec.merge`). Never hardcode tuning in `fcs/input/config.lua` (boot pre-mode default only).
- Every `fcs/**` edit must keep the manifest in sync: run `bash tools/run_gen.sh` (and it is guarded by `tests/run_headless.sh`).
- Source gate: `bash tests/run_headless.sh` must be green (runs the whole suite from its hardcoded list in `startup.lua`). Add new tests to EXISTING registered files — do not create new test files (avoids editing the suite list).
- Dist gate after source is green: `node tools/build.mjs` then `bash tests/run_headless_dist.sh`.
- Per-axis rate targets repurpose existing `feel` keys as ACHIEVED-rate targets: `climbRate` (blk/s), `headingRate` (rad/s), `swaySpeed` (blk/s). New velocity gains: `gains.alt.kv`, `gains.yaw.kw`, `gains.sway.ks`.
- Retired keys (must be unreferenced after this batch): `leadCapVert`, `altStopLead`, `leadCapHeading`, `yawStopLead`, `swayLead`, `climbBoost`, `climbRampTime`.
- Surge (forward W) is NOT rate-commanded: keep its position leash / CRU throttle path and `surgeSpeed`/`surgeLead` untouched.
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01VFXqgb19Zb36zDKKpNwQGL
  ```

---

## Task 1: Fix the altitude D-kill defect in `fcs/control/pid.lua`

**Files:**
- Modify: `fcs/control/pid.lua:18-42` (`Pid:update`)
- Test: `tests/test_pid.lua` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Pid:update(sp, meas, dt, saturated)` — unchanged signature. New behavior: the derivative is computed whenever `dt` is valid (`dt>0 and dt<=dtMax`), **regardless of `saturated`**; only integration is frozen by `saturated`.

- [ ] **Step 1: Write the failing test** (append to `tests/test_pid.lua`)

```lua
t.test("saturated freezes integration but NOT the derivative (D-kill fix)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1, false)                 -- seed lastMeas = 0
  -- saturated tick with a real one-tick move: integral must NOT accumulate, but D MUST react
  local out = p:update(0, 1, 0.1, true)      -- meas rose 1 over dt 0.1 => dMeas=10, D=-10; i stays 0
  t.near(out, -10, 1e-9, "D live under saturation (integral still frozen)")
  t.near(p.i, 0, 1e-9, "integration stayed frozen while saturated")
end)

t.test("saturated still skips a stale-dt derivative (bad dt overrides)", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1, false)
  local out = p:update(0, 100, 5.0, true)    -- dt>dtMax AND saturated: D still skipped (stale dt)
  t.near(out, 0, 1e-9, "bad dt skips D even when saturated")
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh` (look for `FAIL saturated freezes integration but NOT the derivative`).
Expected: FAIL — current code returns 0 for the derivative under `saturated` (D killed).

- [ ] **Step 3: Write minimal implementation** — split the gate in `Pid:update`:

```lua
function Pid:update(sp, meas, dt, saturated)
  local err = sp - meas
  local dtok = (dt > 0) and (dt <= self.dtMax)         -- valid timestep (stale/overrun dt skips D & I)
  local integrate = dtok and not saturated
    and not (self.iBand and (err > self.iBand or err < -self.iBand))
  if integrate then
    self.i = self.i + self.ki * err * dt
    if self.i > self.iMax then self.i = self.iMax elseif self.i < self.iMin then self.i = self.iMin end
  end
  local d = 0
  if self.kd ~= 0 then
    if dtok and self.lastMeas ~= nil then               -- D keys off dtok ONLY, not saturation
      local dMeas = (meas - self.lastMeas) / dt
      local alpha = dt / (self.tauD + dt)
      self.dFilt = self.dFilt + alpha * (dMeas - self.dFilt)
      d = -self.kd * self.dFilt
    end
    self.lastMeas = meas
  end
  return self.kp * err + self.i + d
end
```

Also update the comment block at `pid.lua:8-13/20-23` to state that `saturated` freezes integration only; the derivative keys off `dtok`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: PASS. The existing `"saturated freezes integration"` and `"dt spike produces no derivative kick"` and `"a non-usable tick still tracks the measurement"` tests must ALSO still pass (verify in output).

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/control/pid.lua tests/test_pid.lua manifest.lua manifest-dev.lua
git commit -m "fix(fcs): keep alt derivative live under saturation (D-kill defect)"
```

---

## Task 2: Add a yaw-rate path to `fcs/control/heading.lua`

**Files:**
- Modify: `fcs/control/heading.lua` (constructor + new `:rate`)
- Test: `tests/test_control_terms.lua` (append)

**Interfaces:**
- Produces: `Heading:rate(cmd, yawRate, dt) -> demand` where `demand = kw * (cmd - (yawRate or 0))`. Constructor reads `cfg.kw` (default 0). Existing `:update`/`:terms` unchanged.

- [ ] **Step 1: Write the failing test** (append to `tests/test_control_terms.lua`)

```lua
t.test("Heading:rate commands yaw-rate error (kw * (cmd - yawRate))", function()
  local h = Heading.new({ kp = 3, kd = 0.2, kw = 0.8 })
  t.near(h:rate(1.5, 0.5, 0.05), 0.8 * (1.5 - 0.5), 1e-9, "kw * rate error")
  t.near(h:rate(1.0, nil, 0.05), 0.8, 1e-9, "nil yawRate defaults to 0")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/run_headless.sh` — Expected: FAIL (`attempt to call ... 'rate'` / nil).

- [ ] **Step 3: Implement** — in `heading.lua`, add `self.kw = cfg.kw or 0` in `H.new`, and:

```lua
function H:rate(cmd, yawRate, dt)
  return self.kw * ((cmd or 0) - (yawRate or 0))
end
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/control/heading.lua tests/test_control_terms.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): Heading:rate yaw-rate command path"
```

---

## Task 3: Add a velocity path to `fcs/control/translate.lua`

**Files:**
- Modify: `fcs/control/translate.lua` (constructor + new `:rate`)
- Test: `tests/test_control_terms.lua` (append)

**Interfaces:**
- Produces: `Translate:rate(cmd, vel, dt) -> demand` where `demand = ks * (cmd - (vel or 0))`. Constructor reads `cfg.ks` (default 0). Existing `:update`/`:terms` unchanged.

- [ ] **Step 1: Write the failing test** (append to `tests/test_control_terms.lua`)

```lua
t.test("Translate:rate commands velocity error (ks * (cmd - vel))", function()
  local tr = Translate.new({ kp = 1.5, kd = 0.25, ks = 0.4 })
  t.near(tr:rate(6, 2, 0.05), 0.4 * (6 - 2), 1e-9, "ks * velocity error")
  t.near(tr:rate(3, nil, 0.05), 0.4 * 3, 1e-9, "nil vel defaults to 0")
end)
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement** — in `translate.lua`, add `self.ks = cfg.ks or 0` in `T.new`, and:

```lua
function T:rate(cmd, vel, dt)
  return self.ks * ((cmd or 0) - (vel or 0))
end
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/control/translate.lua tests/test_control_terms.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): Translate:rate velocity command path"
```

---

## Task 4: Scheme velocity paths + bumpless handoff in `fcs/schemes/level_flight.lua`

**Files:**
- Modify: `fcs/schemes/level_flight.lua` (`Scheme.new`, `Scheme:update`)
- Test: `tests/test_level.lua` (append)

**Interfaces:**
- Consumes: `Pid`(Task 1), `Heading:rate`(Task 2), `Translate:rate`(Task 3).
- Produces: `Scheme:update(sp, m, dt, freeze, sat)` now branches per axis:
  - altitude: `sp.climbCmd ~= nil` → `heave = hoverDuty + kv*(climbCmd - vSpeed)` (then band); else the existing `altPid:update` hold path.
  - yaw: `sp.yawCmd ~= nil` → `headingPid:rate(sp.yawCmd, m.yawRate, dt)`; else `headingPid:update(...)`.
  - sway: `sp.strafeCmd ~= nil` → `swayTc:rate(sp.strafeCmd, m.swayVel, dt)`; else `swayTc:update(...)`.
  - On each tick an axis is in rate mode, its idle position controller is `:reset()` so the release hold starts clean (bumpless). `self.kv = (cfg.alt and cfg.alt.kv) or 0`.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_level.lua`; check its existing `require` header for the `Scheme` local name and reuse it)

```lua
t.test("scheme altitude rate: heave = hover + kv*(climbCmd - vSpeed), banded", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0.15, kv = 0.06 }, pitch = {}, roll = {}, yaw = {}, sway = {}, surge = {} })
  local d = sc:update({ climbCmd = 8, altitude = 100 }, { altitude = 100, vSpeed = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 8, 1e-9, "velocity controller drives heave up from rest")
  local d2 = sc:update({ climbCmd = 8, altitude = 100 }, { altitude = 120, vSpeed = 8 }, 0.05, false, {})
  t.near(d2.heave, 0.26, 1e-9, "at target rate heave settles to hover (no rail)")
end)

t.test("scheme yaw/sway rate paths use the controllers' :rate()", function()
  local sc = Level.new({ hoverDuty = 0.26, alt = {}, pitch = {}, roll = {},
    yaw = { kd = 1.8, kw = 0.8 }, sway = { kp = 0.2, ks = 0.4 }, surge = {} })
  local d = sc:update({ yawCmd = 1.5, strafeCmd = 6 },
    { yawRate = 0.5, swayVel = 2, heading = 0, swayPos = 0 }, 0.05, false, {})
  t.near(d.yaw, 0.8 * (1.5 - 0.5), 1e-9, "yaw uses rate path")
  t.near(d.sway, 0.4 * (6 - 2), 1e-9, "sway uses rate path")
end)

t.test("scheme falls back to position-hold PIDs when no rate cmd present", function()
  local sc = Level.new({ hoverDuty = 0.26, heaveMin = 0.05, heaveMax = 0.85,
    alt = { kp = 0.06, kd = 0, kv = 0.06 }, pitch = {}, roll = {},
    yaw = { kp = 0.95, kd = 0 }, sway = { kp = 0.2, kd = 0 }, surge = {} })
  local d = sc:update({ altitude = 105, heading = 0.2, swayPos = 1 },
    { altitude = 100, vSpeed = 0, heading = 0, swayPos = 0, yawRate = 0, swayVel = 0 }, 0.05, false, {})
  t.near(d.heave, 0.26 + 0.06 * 5, 1e-9, "alt hold = hover + kp*err (position PID)")
  t.near(d.yaw, 0.95 * 0.2, 1e-9, "yaw hold = kp*err (heading PID)")
  t.near(d.sway, 0.2 * 1, 1e-9, "sway hold = kp*err (translate PID)")
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL (rate branches not implemented; `d.heave` uses position path).

- [ ] **Step 3: Implement** — in `Scheme.new` add `self.kv = (cfg.alt and cfg.alt.kv) or 0`. Rewrite `Scheme:update` to branch each axis. Sketch:

```lua
function Scheme:update(sp, m, dt, freeze, sat)
  sat = sat or {}
  -- Altitude: rate (velocity controller) while climbCmd present, else position hold.
  local heave
  if sp.climbCmd ~= nil then
    self.altPid:reset()                                  -- keep hold PID clean for release handoff
    heave = self.hoverDuty + self.kv * (sp.climbCmd - (m.vSpeed or 0))
  else
    heave = self.hoverDuty + self.altPid:update(sp.altitude, m.altitude, dt,
      freeze or self._heaveSat or sat.heave)
  end
  local banded = false
  if self.heaveMin and heave < self.heaveMin then heave = self.heaveMin; banded = true end
  if self.heaveMax and heave > self.heaveMax then heave = self.heaveMax; banded = true end
  self._heaveSat = banded
  -- Yaw: rate vs heading-hold.
  local yaw
  if sp.yawCmd ~= nil then self.headingPid:reset(); yaw = self.headingPid:rate(sp.yawCmd, m.yawRate, dt)
  else yaw = self.headingPid:update(sp.heading or 0, m.heading or 0, m.yawRate or 0, dt, freeze or sat.yaw) end
  -- Sway: rate vs position-hold.
  local sway
  if sp.strafeCmd ~= nil then self.swayTc:reset(); sway = self.swayTc:rate(sp.strafeCmd, m.swayVel, dt)
  else sway = self.swayTc:update(sp.swayPos or 0, m.swayPos or 0, m.swayVel or 0, dt, freeze or sat.sway) end
  return {
    heave = heave,
    pitch = self.pitchPid:update(sp.pitch or 0, m.pitch, dt, freeze or sat.pitch),
    roll = self.rollPid:update(sp.roll or 0, m.roll, dt, freeze or sat.roll),
    yaw = yaw, sway = sway,
    surge = self.surgeTc:update(sp.surgePos or 0, m.surgePos or 0, m.surgeVel or 0, dt, freeze or sat.surge),
  }
end
```

Leave `Scheme:terms` unchanged (log-time position-PID reads; a follow-up may add vcmd columns — out of scope).

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS. Confirm existing `test_level`/`test_scheme_heave`/`test_scheme_cruise`/`test_scheme_drone`/`test_scheme_manual` still pass (they call `update` with position setpoints only → hold path, unchanged).

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/schemes/level_flight.lua tests/test_level.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): scheme rate paths (alt/yaw/sway) with bumpless hold handoff"
```

---

## Task 5: Pilot altitude rate-command in `fcs/input/pilot.lua`

**Files:**
- Modify: `fcs/input/pilot.lua` (lift block ~`96-111`, alt release-capture ~`204-210`, `update` return)
- Test: `tests/test_pilot.lua` (replace the two altitude tests)

**Interfaces:**
- Produces: `Pilot:update` returns `sp.climbCmd` = `cfg.climbRate * dir` while up/down held (dir = +1 up, −1 down), and `sp.climbCmd = nil` on release with `sp.altitude` captured to `meas.altitude`. Removes the `leadCapVert` leash and `altStopLead` edge-capture. `cfg.climbRate` is the ACHIEVED target rate.

- [ ] **Step 1: Write the failing tests** — in `tests/test_pilot.lua`, replace the test `"lift held ramps altitude, leashed to meas.alt +/- leadCapVert"` (lines 37-42) with:

```lua
t.test("lift held commands a climb RATE (climbCmd), not a leashed setpoint", function()
  local p = Pilot.new({ climbRate = 8, headingRate = 1, swaySpeed = 1 }); p:reset(meas{altitude=100})
  local sp = p:update(0.05, {up=true}, meas{altitude=100, vSpeed=3})
  t.near(sp.climbCmd, 8, 1e-9, "up held -> climbCmd = +climbRate")
  sp = p:update(0.05, {down=true}, meas{altitude=100})
  t.near(sp.climbCmd, -8, 1e-9, "down held -> climbCmd = -climbRate")
end)

t.test("lift release clears climbCmd and captures current altitude (bumpless hold)", function()
  local p = Pilot.new({ climbRate = 8, headingRate = 1, swaySpeed = 1 }); p:reset(meas{altitude=100})
  p:update(0.05, {up=true}, meas{altitude=100})
  local sp = p:update(0.05, {}, meas{altitude=137})
  t.eq(sp.climbCmd, nil, "released -> no rate command")
  t.near(sp.altitude, 137, 1e-9, "hold setpoint captured to current altitude")
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL (`climbCmd` nil).

- [ ] **Step 3: Implement** — replace the lift leash block (`pilot.lua:96-111`) and the alt release-capture (`pilot.lua:204-210`) with rate-command logic. Sketch inside `update`:

```lua
-- Lift: rate command while held; capture altitude on release (bumpless hold).
local ld = dirOf(held, "down", "up")
if ld ~= 0 then
  sp.climbCmd = (c.climbRate or 0) * ld
  self.climbWasHeld = true
else
  if self.climbWasHeld then sp.altitude = meas.altitude or sp.altitude; self.climbWasHeld = false end
  sp.climbCmd = nil
end
```

Remove `self.climbHeld`/ramp usage and the `climbBoost`/`climbRampTime` references. Ensure the returned snapshot copies `climbCmd` (the `for k,v in pairs(sp)` copy already does, since it's set on `sp`; when nil it is simply absent — that is the intended "no rate cmd" signal the scheme reads).

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS. (Other pilot tests for yaw/sway still use the OLD behavior and pass until Tasks 6/7.)

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/input/pilot.lua tests/test_pilot.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): pilot altitude rate-command (climbCmd) + bumpless capture"
```

---

## Task 6: Pilot yaw rate-command in `fcs/input/pilot.lua`

**Files:**
- Modify: `fcs/input/pilot.lua` (yaw block ~`83-93`, yaw release-capture ~`190-200`)
- Test: `tests/test_pilot.lua` (replace the yaw leash/release tests)

**Interfaces:**
- Produces: `sp.yawCmd = cfg.headingRate * dir` while yawLeft/yawRight held; `sp.yawCmd = nil` on release with `sp.heading` captured to `meas.heading`. Removes `leadCapHeading` leash and `yawStopLead` capture. `cfg.headingRate` is the target yaw rate (rad/s).

- [ ] **Step 1: Write the failing tests** — replace `"yaw held ramps heading by headingRate*dt, wrapped"` (lines 18-24) and `"yaw held is leashed to leadCapHeading ahead of current heading"` (26-35) and `"yaw release captures current heading + predictive stop, dropping the leashed lead"` (66+) with:

```lua
t.test("yaw held commands a yaw RATE (yawCmd = headingRate * dir)", function()
  local p = Pilot.new({ headingRate = 1.2, climbRate = 1, swaySpeed = 1 }); p:reset(meas())
  local sp = p:update(0.05, {yawRight=true}, meas{heading=0})
  t.near(sp.yawCmd, 1.2, 1e-9, "right -> +headingRate")
  sp = p:update(0.05, {yawLeft=true}, meas{heading=0})
  t.near(sp.yawCmd, -1.2, 1e-9, "left -> -headingRate")
end)

t.test("yaw release clears yawCmd and captures current heading", function()
  local p = Pilot.new({ headingRate = 1.2, climbRate = 1, swaySpeed = 1 }); p:reset(meas())
  p:update(0.05, {yawRight=true}, meas{heading=0.3})
  local sp = p:update(0.05, {}, meas{heading=0.5})
  t.eq(sp.yawCmd, nil, "released -> no rate command")
  t.near(sp.heading, 0.5, 1e-9, "heading captured to current")
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement** — replace the yaw leash block and yaw release-capture with:

```lua
-- Yaw: rate command while held; capture heading on release.
local yd = dirOf(held, "yawLeft", "yawRight")
if yd ~= 0 then
  sp.yawCmd = (c.headingRate or 0) * yd
  self.yawWasHeld = true
else
  if self.yawWasHeld then sp.heading = meas.heading or sp.heading; self.yawWasHeld = false end
  sp.yawCmd = nil
end
```

Remove the old `angle.wrap` setpoint-slew and `leadCapHeading` clamp. (`angle` require may become unused — remove it if so.)

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/input/pilot.lua tests/test_pilot.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): pilot yaw rate-command (yawCmd), no discarded lead"
```

---

## Task 7: Pilot strafe rate-command in `fcs/input/pilot.lua`

**Files:**
- Modify: `fcs/input/pilot.lua` (sway block within `120-160`, sway release/master-law path)
- Test: `tests/test_pilot.lua` (replace the sway tests) + `tests/test_pilot_drift.lua` (verify master-law hold still holds)

**Interfaces:**
- Produces: `sp.strafeCmd = cfg.swaySpeed * dir` while swayLeft/swayRight held (only when `policy.translate ~= false`); on release `sp.strafeCmd = nil` and the master drift law governs `sp.swayPos` (CPL captures measured = arrest; DCPL / while-tilting relaxes to measured = coast) — unchanged semantics, just applied to the hold phase. Removes the `swayLead` leash for the held phase. `cfg.swaySpeed` is the target lateral velocity.

- [ ] **Step 1: Write the failing tests** — replace `"sway held ramps swayPos at cruiseSpeed, clamped to maxLead"` (44-50) and `"release holds setpoints where they are"` (58-64) with:

```lua
t.test("sway held commands a lateral velocity (strafeCmd)", function()
  local p = Pilot.new({ swaySpeed = 6, headingRate = 1, climbRate = 1 }); p:reset(meas())
  local sp = p:update(0.05, {swayRight=true}, meas{swayVel=2})
  t.near(sp.strafeCmd, 6, 1e-9, "right -> +swaySpeed")
  sp = p:update(0.05, {swayLeft=true}, meas())
  t.near(sp.strafeCmd, -6, 1e-9, "left -> -swaySpeed")
end)

t.test("sway release clears strafeCmd and holds captured swayPos under CPL", function()
  local p = Pilot.new({ swaySpeed = 6, headingRate = 1, climbRate = 1 }); p:reset(meas())
  p:setMaster(true)                                      -- CPL: arrest drift
  p:update(0.05, {swayRight=true}, meas{swayPos=0})
  local sp = p:update(0.05, {}, meas{swayPos=1.5})
  t.eq(sp.strafeCmd, nil, "released -> no rate command")
  t.near(sp.swayPos, 1.5, 1e-9, "CPL captures current swayPos (arrest)")
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement** — in the `policy.translate ~= false` block, replace the sway leash with a rate command while held, and route the released case through the existing master drift rule (`sp.swayPos = meas.swayPos` on CPL arrest / relax while tilting / DCPL). Sketch:

```lua
if self.policy.translate ~= false then
  local swd = dirOf(held, "swayLeft", "swayRight")
  if swd ~= 0 then
    sp.strafeCmd = (c.swaySpeed or 0) * swd
  else
    sp.strafeCmd = nil
    -- hold phase: master drift law (arrest under CPL / relax while tilting or DCPL) sets sp.swayPos
    -- (keep the existing tilting / driftArrest logic that assigns sp.swayPos = meas.swayPos)
  end
  -- surge unchanged (position leash / CRU throttle) ...
end
```

Preserve the existing `braking`/`tilting`/`driftArrest` assignments to `sp.swayPos` (`pilot.lua:159`) for the hold phase. Leave surge exactly as-is.

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS (including `test_pilot_drift`).

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/input/pilot.lua tests/test_pilot.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): pilot strafe rate-command (strafeCmd); master-law hold on release"
```

---

## Task 8: Re-enable the calibrated nose-down feedforward in `fcs/runtime/loop.lua`

**Files:**
- Modify: `fcs/runtime/loop.lua:81-106` (uncomment the ff block; remove the `self._ffPitch = 0` override)
- Test: `tests/test_loop_trim.lua` (rewrite the suite to assert the ff IS applied)

**Interfaces:**
- Consumes: `Loop:setTrim(dir, gain, authority, fadeStart, fade, brakeTrim)` (unchanged).
- Produces: `Loop:cycle` adds `ff = clampByFadeAndAuthority(dir*gain*demands.surge)` to `demands.pitch`; `diag().ffPitch` reports the applied ff. `brakeTrim=false` blocks the wrong-sign (brake) half; `gain=0` is a no-op (LDG).

- [ ] **Step 1: Rewrite the tests** — replace the body of `tests/test_loop_trim.lua` so each test asserts the ff is APPLIED. Key cases (use the existing fake scheme/mixer/backend helpers at the top of the file):

```lua
t.test("loop trim: nose-down ff scales with demands.surge (lean on)", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.0, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, true)   -- dir -1 (nose-down), gain 0.3, authority 1, fade 0.25..0.6
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })   -- |pitch|<fadeStart => full ff
  t.near(r.demands.pitch, -0.3 * 0.8, 1e-9, "pitch = ff = dir*gain*surge (nose-down)")
  t.near(lp:diag({}, { pitch = 0 }).ffPitch, -0.3 * 0.8, 1e-9, "diag reports applied ff")
end)

t.test("loop trim: gain 0 is a no-op (LDG)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0, 1.0, 0.25, 0.6, false); lp:arm(true)
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, 0.1, 1e-9, "no ff when gain 0")
end)

t.test("loop trim: authority cap limits ff to authority*caps.pitch", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6, true); lp:arm(true)  -- raw -0.35, cap 0.4*0.2=0.08
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, -0.08, 1e-9, "ff clamped to -authority*cap")
end)

t.test("loop trim: fade zeroes ff by trimFade (|pitch|>=fade)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 10, surge = 1 } })
  lp:setTrim(-1, 0.4, 1.0, 0.25, 0.6, true); lp:arm(true)
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0.60 }).demands.pitch, 0, 1e-9, "ff fully faded at trimFade")
end)

t.test("loop trim forward-only (brakeTrim=false) blocks the brake half", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = -1.0 }),   -- surge<0 = braking
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, false); lp:arm(true)  -- dir -1, brake would give +0.3 -> blocked
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, 0, 1e-9, "forward-only blocks brake-side ff")
end)

t.test("loop: DAMPED trip still zeroes pitch (ff irrelevant)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp.osc = { update = function() return true end, reset = function() end }
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, true); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(r.mode, "DAMPED"); t.near(r.demands.pitch, 0, 1e-9, "osc trip zeroes pitch")
end)
```

Delete the old "lean off / ffPitch always 0" tests they replace.

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL (ff currently disabled → pitch passes through, ffPitch 0).

- [ ] **Step 3: Implement** — in `loop.lua`, uncomment the ff block (`loop.lua:87-105`) and delete `self._ffPitch = 0` at line 106 so the block's `self._ffPitch = ff` and `demands.pitch = demands.pitch + ff` take effect. Update the comment at `81-86` to say the lean is RE-ENABLED (calibrated, capped). Verify the fade/authority/brakeTrim math already present matches the tests above (it does: raw `dir*gain*surge`, linear fade `fadeStart..fade`, cap `authority*caps.pitch`, forward-only blocks the sign opposite `dir`).

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS. Grep for other suites asserting `ffPitch == 0` (`test_loop_diag`, instrument tests) and update any that assumed the lean was off.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/runtime/loop.lua tests/test_loop_trim.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): re-enable calibrated nose-down accel feedforward"
```

---

## Task 9: Tuning defaults — rate targets, velocity gains, per-mode trim, pitch authority

**Files:**
- Modify: `fcs/io/tuningdefaults.lua`
- Test: `tests/test_tuning_modes.lua` and `tests/test_tuningdefaults.lua` (update assertions)

**Interfaces:**
- Produces resolved per-mode values (via `tuning.forMode`):

| Mode | `feel.climbRate` | `feel.headingRate` | `feel.swaySpeed` | `gains.alt.kv` | `gains.yaw.kw` | `gains.sway.ks` | `feel.trimGain` | `gains.pitch.kp` | `caps.pitch` |
|---|---|---|---|---|---|---|---|---|---|
| PRE (base) | 8 | 1.2 | 6 | 0.06 | 0.8 | 0.4 | 0.30 | 0.15 | 0.3 |
| CRU | 12 | 1.5 | 10 | 0.06 | 0.9 | 0.5 | 0.30 | 0.15 | 0.3 |
| MAN | 6 | 1.2 | 6 | 0.06 | 0.8 | 0.4 | 0.30 | 0.10 | 0.4 |
| LDG | 2.5 | 0.6 | 3 | 0.04 | 0.5 | 0.3 | **0** | 0.10 | 0.2 |
| DRN | 6 | 1.2 | — | 0.06 | 0.8 | — | 0.30 | 0.10 | 0.5 |

(Velocity gains are starting points, live-tuned in-world. LDG `trimGain=0`. PRE/CRU get the pitch-authority bump; MAN/DRN keep their tilt caps. `kiv` is not added yet — P-only velocity control per the spec.)

- [ ] **Step 1: Write/update the failing tests** — in `tests/test_tuning_modes.lua`:
  - Replace the `"rate-tuning defaults resolve per mode (fix #5-#9)"` test and the `leadCapVert`/`altStopLead`/`leadCapHeading`/`yawStopLead`/`swayLead` assertions with the new-key assertions:

```lua
t.test("rate-command defaults resolve per mode (2026-09-06)", function()
  local function fe(m) return tuning.forMode(m).feel end
  local function ga(m) return tuning.forMode(m).gains end
  t.near(fe("PRECISION").climbRate, 8, 1e-9); t.near(fe("PRECISION").headingRate, 1.2, 1e-9)
  t.near(fe("PRECISION").swaySpeed, 6, 1e-9)
  t.near(ga("PRECISION").alt.kv, 0.06, 1e-9); t.near(ga("PRECISION").yaw.kw, 0.8, 1e-9)
  t.near(ga("PRECISION").sway.ks, 0.4, 1e-9)
  t.near(fe("CRUISE").climbRate, 12, 1e-9); t.near(fe("CRUISE").headingRate, 1.5, 1e-9)
  t.near(fe("CRUISE").swaySpeed, 10, 1e-9); t.near(ga("CRUISE").yaw.kw, 0.9, 1e-9)
  t.near(fe("LDG").climbRate, 2.5, 1e-9); t.near(fe("LDG").headingRate, 0.6, 1e-9)
  t.near(fe("MAN").climbRate, 6, 1e-9); t.near(fe("DRN").climbRate, 6, 1e-9)
end)

t.test("per-mode trimGain: enabled everywhere except LDG", function()
  for _, m in ipairs({ "PRECISION", "MAN", "CRUISE", "DRN" }) do
    t.truthy(tuning.forMode(m).feel.trimGain > 0, m.." accel trim enabled")
  end
  t.near(tuning.forMode("LDG").feel.trimGain, 0, 1e-9, "LDG accel trim off (gentle)")
end)

t.test("CRU/PRE pitch authority bumped for accel residual", function()
  t.near(tuning.forMode("CRUISE").gains.pitch.kp, 0.15, 1e-9)
  t.near(tuning.forMode("CRUISE").caps.pitch, 0.3, 1e-9)
  t.near(tuning.forMode("PRECISION").gains.pitch.kp, 0.15, 1e-9)
  t.near(tuning.forMode("PRECISION").caps.pitch, 0.3, 1e-9)
end)

t.test("retired leash keys are gone", function()
  local d = require("fcs.io.tuningdefaults").get()
  for _, k in ipairs({ "leadCapVert", "altStopLead", "leadCapHeading", "yawStopLead", "swayLead",
                       "climbBoost", "climbRampTime" }) do
    t.eq(d.feel[k], nil, "base feel."..k.." retired")
  end
end)
```

  - Update the earlier tests that assert old values: `"faster climb/descend..."` and `"attitude leveling integral..."` (keep the pitch ki assertions but change `caps.pitch`/`gains.pitch.kp` expectations for CRU/PRE to 0.15/0.3), `"tuning: trim/ramp feel..."` (change base `trimGain` expectation from 0.35 to 0.30, drop `climbBoost`/`climbRampTime` assertions), and `"forMode LDG has gentle landing feel overrides"` (drop retired-key assertions; keep `climbRate 2.5`). Grep the file for each retired key and remove/replace.

- [ ] **Step 2: Run to verify they fail** — `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement** — edit `fcs/io/tuningdefaults.lua`:
  - Base `gains.alt`: add `kv = 0.06`; remove nothing else there. Base `gains.yaw`: add `kw = 0.8`. Base `gains.sway`: add `ks = 0.4`.
  - Base `gains.pitch.kp` 0.10→0.15; base `caps.pitch` 0.2→0.3. (This makes PRE the base; MAN/DRN override pitch caps already via their own caps blocks — set MAN pitch kp back to 0.10 if inheriting the base 0.15 is unwanted; per the table MAN keeps kp 0.10, so pin `DEFAULTS.modes.MAN.gains.pitch.kp = 0.10`.)
  - Base `feel`: set `climbRate = 8`, `headingRate = 1.2`, `swaySpeed = 6`, `trimGain = 0.30`. REMOVE `leadCapVert`, `altStopLead`, `leadCapHeading`, `yawStopLead`, `swayLead`, `climbBoost`, `climbRampTime`.
  - CRU overrides: `climbRate = 12`, `headingRate = 1.5`, `swaySpeed = 10`, `gains.alt.kv = 0.06` (inherit ok), `gains.yaw.kw = 0.9`, `gains.sway.ks = 0.5`, `gains.pitch.kp = 0.15`, `caps.pitch = 0.3`. Remove CRU's `leadCapVert`/`swayLead` overrides.
  - MAN: `climbRate = 6`; keep `gains.pitch.kp = 0.10`.
  - LDG pins: `climbRate = 2.5`, `headingRate = 0.6`, `swaySpeed = 3`, `gains.alt.kv = 0.04`, `gains.yaw.kw = 0.5`, `gains.sway.ks = 0.3`, `feel.trimGain = 0`, keep `caps.pitch = 0.2`, `gains.pitch.kp = 0.10`. Remove LDG's `leadCapVert`/`swayLead`/`swayLead` pins.
  - DRN: `climbRate = 6`; keep tilt caps. (No strafe.)
  - Update the stale `iBand` comment referencing `leadCapVert` and the fix-#5-#9 comments.

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS. Grep the WHOLE `tests/` tree for the retired keys and any old numeric assertions (`0.35` trimGain, `leadCapVert`, etc.) and update; re-run until green.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add fcs/io/tuningdefaults.lua tests/test_tuning_modes.lua tests/test_tuningdefaults.lua manifest.lua manifest-dev.lua
git commit -m "feat(fcs): rate-command tuning defaults + per-mode trim/pitch authority"
```

---

## Task 10: Live-tune BIT/CONFIG rows in `ui/basalt/bitconfig/tuning.lua`

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua`
- Test: `tests/test_bitconfig_tuning.lua` (update row expectations)

**Interfaces:**
- Produces: the paged MODE-FEEL edit screen exposes the new live-tune rows (`CLIMB RATE`, `YAW RATE`, `STRAFE RATE`, `ALT KV`, `YAW KW`, `SWAY KS`, `TRIM GAIN`) and drops the retired ones (`VERT LEAD CAP`, `ALT STOP LEAD`, `HDG LEAD CAP`, `YAW STOP LEAD`, `SWAY LEAD`). Ranges: rates 0–20 (yaw 0–3), velocity gains 0–1, TRIM GAIN 0–1. Pattern identical to the existing `buildEditScreen` rows.

- [ ] **Step 1: Update the failing test** — in `tests/test_bitconfig_tuning.lua`, adjust the row-set assertions (labels/keys/ranges) to expect the new rows and NOT the retired ones. (Follow the file's existing assertion style — it enumerates rows and their config paths.)

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh` — Expected: FAIL.

- [ ] **Step 3: Implement** — mirror the brake-curve row pattern in `buildEditScreen`: add rows binding `feel.climbRate`/`feel.headingRate`/`feel.swaySpeed`/`gains.alt.kv`/`gains.yaw.kw`/`gains.sway.ks`/`feel.trimGain` with the ranges above; remove the retired rows. Keep the `▲/▼` paging intact (row count changes — verify the page math still works).

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua manifest.lua manifest-dev.lua
git commit -m "feat(ui): live-tune rows for rate-command knobs; drop retired leash rows"
```

---

## Task 11: Integration test — pilot→loop→scheme rate command end-to-end

**Files:**
- Test: `tests/test_integration.lua` (append) — verify the full stack, no source change expected.

**Interfaces:**
- Consumes: everything above. Confirms `loop:setpoints(pilot:update(...))` → `scheme:update` reads `climbCmd`/`yawCmd`/`strafeCmd` and produces a bounded, non-railing heave under a held climb; and that release produces a stable hold.

- [ ] **Step 1: Write the test** — drive a Pilot + a real `level_flight` scheme (or the existing integration harness in the file) through: hold up 10 ticks with `vSpeed` ramping toward `climbRate`, assert `heave` stays within `[heaveMin, heaveMax]` and never both-rails (no bang-bang); release, assert `climbCmd` nil and `heave` → ~hover. Model it on the existing integration cases in `tests/test_integration.lua`.

```lua
t.test("rate-command climb does not rail the collective (no limit-cycle)", function()
  -- pseudo: build Scheme.new with CRU-like gains (kv=0.06, hover 0.26, band .05/.85),
  -- feed sp = pilot:update(up held) each tick with vSpeed rising 0->12,
  -- assert every heave in (heaveMin, heaveMax) exclusive once vSpeed>1 (never pinned both ways).
end)
```

Replace the pseudo with concrete calls following the file's harness. Assert with `t.truthy`/`t.near`.

- [ ] **Step 2: Run to verify it fails (or drives real behavior)** — `bash tests/run_headless.sh`.

- [ ] **Step 3: Adjust only if a real integration bug surfaces** (e.g. a setpoint field not threaded). If the stack is correct, the test passes as written — no source change.

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
bash tools/run_gen.sh
git add tests/test_integration.lua manifest.lua manifest-dev.lua
git commit -m "test(fcs): end-to-end rate-command climb stays off the rails"
```

---

## Task 12: Full gate — manifest sync, dist build, src+dist+e2e green

**Files:** none (verification + dist artifact regen).

- [ ] **Step 1: Manifest sync** — `bash tools/run_gen.sh` (regenerates `manifest.lua`/`manifest-dev.lua` if any earlier task forgot).
- [ ] **Step 2: Source gate** — `bash tests/run_headless.sh` — Expected: `N passed, 0 failed` across the suite.
- [ ] **Step 3: Rebuild dist** — `node tools/build.mjs`.
- [ ] **Step 4: Dist gate** — `bash tests/run_headless_dist.sh` — Expected: green (dist mirrors src).
- [ ] **Step 5: e2e** — confirm `tests/e2e_stress.lua` is exercised by the harness and passes (it is in the suite list).
- [ ] **Step 6: Commit** any regenerated `manifest*`/`dist/**`:

```bash
git add -A
git commit -m "build(fcs): rebuild dist + manifest for rate-command batch"
```

- [ ] **Step 7:** Report the final `src N/0 dist N/0 e2e PASS` gate. In-world verify is owed (not code): fly CRU/PRE — the vertical limit-cycle should be gone, hard-accel holds the nose level (dial `TRIM GAIN`), yaw snappy with a clean stop, strafe immediate; then dial the live-tune rows.

---

## Self-review notes

- **Spec coverage:** #1 → Tasks 1 (D-kill), 4/5 (alt rate). #2 → Tasks 8/9 (ff + authority). #4 yaw → Tasks 2/6; strafe → Tasks 3/7. Config/live-tune → Tasks 9/10. #3 → verify-only (Task 12 in-world). Testing → each task is TDD; integration → Task 11; gates → Task 12.
- **Type consistency:** rate fields `climbCmd`/`yawCmd`/`strafeCmd` (set by pilot Tasks 5/6/7, read by scheme Task 4); velocity methods `:rate(cmd, measRate, dt)` on Heading (Task 2) / Translate (Task 3); scheme reads `cfg.alt.kv`/`cfg.yaw.kw`/`cfg.sway.ks` (Task 4) which Task 9 supplies. Consistent.
- **Ordering:** controllers (1-3) → scheme (4) → pilot (5-7) → ff (8) → tuning/ui (9-10) → integration/gate (11-12). Each task independently testable; pilot tasks 5/6/7 each leave the suite green because the scheme (Task 4) handles both rate and hold paths and untouched axes keep old behavior until their pilot task lands.
