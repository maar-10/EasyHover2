# CRU Brake Tilt-Slew + Trim-Magnitude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the high-speed CRU brake from overshooting its commanded tilt (30°→75° → departure) by slewing the tilt-brake setpoint at a fixed rate, and reduce the too-harsh forward-accel trim magnitude without changing its reaction time.

**Architecture:** Two isolated changes. (1) A per-axis first-order slew limiter on the tilt-brake pitch/roll contribution in `fcs/input/pilot.lua` — the pilot's manual `self.tilt` ramp is untouched. (2) A pure tuning change in `fcs/io/tuningdefaults.lua`: add `feel.tiltBrake.slewRate` and lower `feel.trimGain`/`trimAuthority`. No changes to `brake.lua` (stays pure), `loop.lua` (trim FF math unchanged), caps, `maxAngle`, or the trim fade params.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1), headless test harness via CraftOS-PC (`bash tests/run_headless.sh`), framework at `tests/framework.lua` (`t.test`, `t.eq`, `t.near`, `t.truthy`).

## Global Constraints

- Test runner: `bash tests/run_headless.sh` (runs the whole suite headless). All tests must pass at the end of each task.
- Angles are **radians** throughout the FCS.
- `slewRate` is in **rad/s**; nil ⇒ `math.huge` ⇒ instant (legacy) so tests/configs that omit it keep current behaviour.
- First-estimate tuning values (TUNE in-world, do not treat as final): `slewRate = 0.3`, `trimGain = 0.18`, `trimAuthority = 0.30`.
- Do NOT change: `caps.*`, `tiltBrake.maxAngle`/`buttonMax`/`engageSpeed`/`satSpeed`/`minAngle`, `trimFadeStart` (0.25), `trimFade` (0.6), `brakeTrim` per-mode flags.
- Assert observable state (returned setpoints, default values), never geometry getters.
- Follow existing file style; keep comments in the terse EH2 idiom, ASCII only (no em-dash: use `--`).
- Commit after each task. End commit messages with the attribution block (see Task commits).

---

### Task 1: Brake tilt slew limiter in `fcs/input/pilot.lua`

**Files:**
- Modify: `fcs/input/pilot.lua` (add `approach` helper; add `self.brakeTilt` state in `new`/`reset`/`setMode`; slew the brake contribution in `update`)
- Test: `tests/test_pilot_modes.lua` (append cases)

**Interfaces:**
- Consumes: `self.cfg.tiltBrake.slewRate` (rad/s, may be nil), the existing `Pilot:_brakeSetpoint(held, meas, tilting) -> bp, br` (raw brake pitch/roll), and the existing local `tilting` computed in `update`.
- Produces: no new public method. `Pilot:update(dt, held, meas)` still returns a setpoint snapshot; `sp.pitch`/`sp.roll` now contain the **slewed** brake contribution (plus `self.tilt.*` in tilt modes). New per-instance field `self.brakeTilt = { pitch, roll }` persists slew state across ticks.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_pilot_modes.lua` (after the existing cases):

```lua
-- Brake tilt slew (2026-09-09): the tilt-brake setpoint must ramp in at a bounded rate
-- (feel.tiltBrake.slewRate, rad/s) so the leveling loop can track it without overshooting the
-- commanded angle. Applies to the brake contribution only; manual self.tilt keeps its tiltRate.
local FEEL_TB = { headingRate=2.2, climbRate=4.5, surgeSpeed=10, surgeLead=20, swaySpeed=5,
  tiltRate=0.8, tiltCap=0.4, cruiseThrottleRate=1.0, cruiseThrottleMax=1.0,
  tiltBrake = { enabled=true, engageSpeed=30, satSpeed=100, minAngle=0.2618,
                maxAngle=0.5236, buttonMax=0.7854, slewRate=0.3 } }
local function fast() return { altitude=0, heading=0, swayPos=0, surgePos=0, surgeVel=100, swayVel=0 } end

t.test("CRU brake tilt slews in, never steps to maxAngle", function()
  local p = Pilot.new(FEEL_TB); p:setMode({ tilt=false, surge="throttle" }, FEEL_TB); p:reset(meas())
  local a = p:update(0.1, {}, fast())   -- throttle 0 => autoArrest => brake engaged; target = maxAngle
  t.truthy(a.pitch > 0, "brake pitch begins ramping nose-up")
  t.truthy(a.pitch <= 0.3 * 0.1 + 1e-9, "first tick bounded by slewRate*dt (0.03), not stepped to 0.5236")
end)

t.test("CRU brake tilt converges to brake.angle target over time", function()
  local p = Pilot.new(FEEL_TB); p:setMode({ tilt=false, surge="throttle" }, FEEL_TB); p:reset(meas())
  local last
  for _=1,60 do last = p:update(0.1, {}, fast()) end
  t.near(last.pitch, 0.5236, 1e-3, "reaches maxAngle target (pure forward drift)")
end)

t.test("CRU brake tilt ramps back down when brake disengages", function()
  local p = Pilot.new(FEEL_TB); p:setMode({ tilt=false, surge="throttle" }, FEEL_TB); p:reset(meas())
  for _=1,60 do p:update(0.1, {}, fast()) end            -- ramped up to ~maxAngle
  p:update(0.2, { surgeFwd = true }, fast())             -- throttle>0 => autoArrest false => brake off
  local a = p:update(0.1, {}, fast())                    -- target now 0; slews down
  t.truthy(a.pitch < 0.5236 - 1e-6, "brake tilt decreasing after disengage")
end)

t.test("CRU brake tilt holds through a dt==0 overrun tick", function()
  local p = Pilot.new(FEEL_TB); p:setMode({ tilt=false, surge="throttle" }, FEEL_TB); p:reset(meas())
  local a = p:update(0.1, {}, fast())
  local b = p:update(0, {}, fast())
  t.near(b.pitch, a.pitch, 1e-9, "dt==0 => brake tilt unchanged")
end)

t.test("nil slewRate => brake tilt applied instantly (legacy)", function()
  local FEEL_NO = { headingRate=2.2, climbRate=4.5, surgeSpeed=10, surgeLead=20, swaySpeed=5,
    tiltRate=0.8, tiltCap=0.4, cruiseThrottleRate=1.0, cruiseThrottleMax=1.0,
    tiltBrake = { enabled=true, engageSpeed=30, satSpeed=100, minAngle=0.2618,
                  maxAngle=0.5236, buttonMax=0.7854 } }   -- no slewRate
  local p = Pilot.new(FEEL_NO); p:setMode({ tilt=false, surge="throttle" }, FEEL_NO); p:reset(meas())
  local a = p:update(0.1, {}, fast())
  t.near(a.pitch, 0.5236, 1e-4, "no slewRate => steps straight to maxAngle")
end)

t.test("MAN hands-off brake tilt is slewed (bounded first tick)", function()
  local p = Pilot.new(FEEL_TB); p:setMode({ tilt=true, surge="position" }, FEEL_TB); p:reset(meas())
  local a = p:update(0.1, {}, fast())   -- no tilt keys => autoArrest true => brake engages, slewed
  t.truthy(a.pitch > 0 and a.pitch <= 0.3 * 0.1 + 1e-9, "MAN brake tilt slewed onto setpoint")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run_headless.sh` then inspect the output for the six new case names.
Expected: the new cases FAIL (brake tilt currently steps instantly, so "never steps to maxAngle" and the bounded/dt==0 cases fail; `self.brakeTilt` does not exist yet).

- [ ] **Step 3: Add the `approach` helper**

In `fcs/input/pilot.lua`, next to the existing `local function dirOf(...)` (around line 52), add:

```lua
-- Move `cur` toward `target` by at most `step` (>=0). step==math.huge => jump to target (legacy);
-- step==0 (dt==0 overrun) => hold. Used to slew the tilt-brake setpoint so the leveling loop can
-- track it without overshooting the commanded brake angle.
local function approach(cur, target, step)
  local d = target - cur
  if d > step then d = step elseif d < -step then d = -step end
  return cur + d
end
```

- [ ] **Step 4: Add `self.brakeTilt` state to `new`, `reset`, `setMode`**

In `Pilot.new` (the `setmetatable({ ... }, Pilot)` table), add a field alongside `tilt = { pitch = 0, roll = 0 }`:

```lua
    brakeTilt = { pitch = 0, roll = 0 },
```

In `Pilot:reset(meas)`, where it clears `self.tilt.pitch, self.tilt.roll, self.throttle = 0, 0, 0`, add on the next line:

```lua
  self.brakeTilt.pitch, self.brakeTilt.roll = 0, 0
```

In `Pilot:setMode(policy, feel)`, where it clears `self.tilt.pitch, self.tilt.roll, self.throttle = 0, 0, 0`, add on the next line:

```lua
  self.brakeTilt.pitch, self.brakeTilt.roll = 0, 0
```

- [ ] **Step 5: Slew the brake contribution in `Pilot:update`**

In `Pilot:update`, the current block is:

```lua
  if self.policy.tilt then
    local function toward(cur, dir, rate, cap)
      if dir ~= 0 then cur = cur + rate * dt * dir
      elseif cur > 0 then cur = math.max(0, cur - rate * dt)
      else cur = math.min(0, cur + rate * dt) end          -- auto-level toward 0 on release
      if cur >  cap then cur =  cap elseif cur < -cap then cur = -cap end
      return cur
    end
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    local bp, br = self:_brakeSetpoint(held, meas, tilting)   -- 0,0 while tilting
    -- Brake button (btn) intentionally SUMS onto the pilot's active tilt (btn overrides the
    -- hands-off gate); the total is bounded by the envelope's demand clamp, not the tilt setpoint.
    sp.pitch, sp.roll = self.tilt.pitch + bp, self.tilt.roll + br
  else
    sp.pitch, sp.roll = self:_brakeSetpoint(held, meas, false)   -- 0,0 unless braking
  end
```

Replace it with (hoist the brake computation, slew it once, use in both branches):

```lua
  -- Tilt-brake setpoint, slew-limited (2026-09-09): ramp the brake tilt in/out at a bounded rate
  -- (cfg.tiltBrake.slewRate, rad/s) so the leveling loop tracks it without overshooting the
  -- commanded angle -- the high-speed CRU brake was stepping to maxAngle and overshooting ~2.4x
  -- at the starved loop rate, departing past the EMRCVR trip. nil slewRate => math.huge => instant
  -- (legacy). Slews the brake contribution only; the pilot's manual self.tilt keeps its tiltRate.
  -- `tilting` (computed above) already forces _brakeSetpoint to 0,0 in tilt modes while the pilot
  -- steers, and is always false when policy.tilt is false, so one call serves both branches.
  local slew = (self.cfg.tiltBrake and self.cfg.tiltBrake.slewRate) or math.huge
  local step = slew * (dt or 0)
  local bpRaw, brRaw = self:_brakeSetpoint(held, meas, tilting)
  self.brakeTilt.pitch = approach(self.brakeTilt.pitch, bpRaw, step)
  self.brakeTilt.roll  = approach(self.brakeTilt.roll,  brRaw, step)
  local bp, br = self.brakeTilt.pitch, self.brakeTilt.roll
  if self.policy.tilt then
    local function toward(cur, dir, rate, cap)
      if dir ~= 0 then cur = cur + rate * dt * dir
      elseif cur > 0 then cur = math.max(0, cur - rate * dt)
      else cur = math.min(0, cur + rate * dt) end          -- auto-level toward 0 on release
      if cur >  cap then cur =  cap elseif cur < -cap then cur = -cap end
      return cur
    end
    self.tilt.pitch = toward(self.tilt.pitch, dirOf(held, "pitchDown", "pitchUp"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    self.tilt.roll  = toward(self.tilt.roll,  dirOf(held, "rollLeft",  "rollRight"), c.tiltRate or 0.8, c.tiltCap or 0.4)
    -- Brake tilt (slewed) SUMS onto the pilot's active tilt; the total is bounded by the envelope's
    -- demand clamp, not the tilt setpoint.
    sp.pitch, sp.roll = self.tilt.pitch + bp, self.tilt.roll + br
  else
    sp.pitch, sp.roll = bp, br
  end
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: the six new cases PASS, and the whole suite is green (existing `test_pilot_modes`, `test_pilot_drift`, `test_scheme_cruise`, `test_brake`, `test_flight_*` regressions all pass — the brake math is unchanged, only its onset rate is bounded).

- [ ] **Step 7: Commit**

```bash
git add fcs/input/pilot.lua tests/test_pilot_modes.lua
git commit -m "$(cat <<'EOF'
feat(fcs): slew-limit the tilt-brake setpoint (CRU high-speed brake anti-overshoot)

Ramp the tilt-brake pitch/roll setpoint in/out at a fixed rate
(feel.tiltBrake.slewRate, rad/s) so the leveling loop tracks it without
overshooting the commanded angle. The high-speed CRU brake was stepping
to maxAngle and overshooting ~2.4x (29deg->69deg, then 75deg -> EMRCVR
departure) at the starved loop rate. Slews the brake contribution only;
manual self.tilt keeps its tiltRate. nil slewRate => instant (legacy).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 2: Tuning defaults -- add `slewRate`, reduce trim magnitude (`fcs/io/tuningdefaults.lua`)

**Files:**
- Modify: `fcs/io/tuningdefaults.lua` (`feel.tiltBrake.slewRate`; `feel.trimGain`; `feel.trimAuthority`)
- Test: `tests/test_tuningdefaults.lua` (extend the tiltBrake case), `tests/test_tuning_modes.lua` (update the trim assertions)

**Interfaces:**
- Consumes: nothing new.
- Produces: `DEFAULTS.feel.tiltBrake.slewRate = 0.3` (deep-copied into every mode's `feel.tiltBrake`, so `Pilot.cfg.tiltBrake.slewRate` from Task 1 is populated in real flight via `flight.lua`'s existing `setMode(feel)` path). `DEFAULTS.feel.trimGain = 0.18`, `DEFAULTS.feel.trimAuthority = 0.30` (LDG still pins `trimGain = 0`).

- [ ] **Step 1: Write / update the failing tests**

In `tests/test_tuningdefaults.lua`, extend the existing tiltBrake case (the one titled "tiltBrake enabled for CRU/MAN/DRN, disabled for PRE/LDG, with curve defaults"): add these assertions inside it (after the `buttonMax` line):

```lua
  t.near(D.feel.tiltBrake.slewRate, 0.3, 1e-9, "base slewRate first-estimate")
  t.near(D.modes.CRUISE.feel.tiltBrake.slewRate, 0.3, 1e-9, "CRU inherits slewRate")
  t.near(D.modes.MAN.feel.tiltBrake.slewRate, 0.3, 1e-9, "MAN inherits slewRate")
  t.near(D.modes.DRN.feel.tiltBrake.slewRate, 0.3, 1e-9, "DRN inherits slewRate")
```

In `tests/test_tuning_modes.lua`, update the existing assertions to the new values:
- line ~78: `t.eq(D.feel.trimGain, 0.30, "base trimGain")` -> `t.near(D.feel.trimGain, 0.18, 1e-9, "base trimGain (reduced 2026-09-09)")`
- line ~89: `t.near(base.trimAuthority, 0.4, 1e-9, "PRECISION trimAuthority default")` -> `0.30`
- line ~94: `t.near(f.trimAuthority, 0.4, 1e-9, mode.." inherits trimAuthority")` -> `0.30`
- line ~98: `t.near(d.modes.LDG.feel.trimAuthority, 0.4, 1e-9, "LDG inherits")` -> `0.30`

(The `trimGain > 0` everywhere-except-LDG case around line 153-157 still holds: 0.18 > 0. Leave it.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/run_headless.sh`
Expected: `test_tuningdefaults` slewRate assertions FAIL (key absent), and the updated `test_tuning_modes` assertions FAIL (defaults still 0.30/0.4).

- [ ] **Step 3: Add `slewRate` to the tiltBrake defaults**

In `fcs/io/tuningdefaults.lua`, in `DEFAULTS.feel.tiltBrake`, add the `slewRate` line (after `buttonMax`):

```lua
      buttonMax   = 0.7854, -- 45deg: CTRL-brake max at/above satSpeed
      slewRate    = 0.3,    -- rad/s: max onset rate of the brake tilt setpoint. Fixed slew so the
                            -- leveling loop tracks the brake angle without overshoot at low loop
                            -- rate (high-speed brake departed by overshooting to the EMRCVR trip).
                            -- First estimate -- TUNE in-world.
```

- [ ] **Step 4: Reduce the trim magnitude defaults**

In `fcs/io/tuningdefaults.lua`, in `DEFAULTS.feel`, change `trimGain` and `trimAuthority` (leave `trimFadeStart`, `trimFade`, `brakeTrim` unchanged):

```lua
    trimGain       = 0.18,  -- forward-trim ff gain (was 0.30): reduced magnitude, same reaction --
                            -- the nose-down accel lean was too harsh. First estimate -- TUNE in-world.
```

```lua
    trimAuthority  = 0.30,  -- max fraction of caps.pitch the ff may consume (was 0.40): lower hard
                            -- cap on the accel lean. First estimate -- TUNE in-world.
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/run_headless.sh`
Expected: the extended `test_tuningdefaults` and updated `test_tuning_modes` cases PASS, and the full suite is green (LDG `trimGain` still 0 via its explicit pin; MAN/DRN/CRU inherit the reduced values via the deep-copies).

- [ ] **Step 6: Commit**

```bash
git add fcs/io/tuningdefaults.lua tests/test_tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "$(cat <<'EOF'
tune(fcs): add tiltBrake.slewRate default; soften forward-accel trim

slewRate=0.3 rad/s (bounds the brake tilt onset; consumed by the Task-1
pilot slew). trimGain 0.30->0.18 and trimAuthority 0.40->0.30: the
nose-down accel lean was too harsh -- same reaction/fade, less magnitude.
All first estimates, TUNE in-world. Saved eh2_tuning.tbl must be reloaded
from DEFAULT in-world to pick up the new/changed keys.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

## Self-Review

**1. Spec coverage:**
- Spec §Design A (brake slew) → Task 1 (helper + state + slew in `update`). ✓
- Spec §Design B (trim magnitude) → Task 2 Steps 3-4. ✓
- Spec §Config (add `slewRate` to `feel.tiltBrake`, flows via `flight.lua` setMode) → Task 2 Step 3; wiring verified in design (no code change needed, `feel` already passed). ✓
- Spec §Testing (slew ramps/converges/ramp-down/dt==0/nil-legacy/MAN-sum; trim lower same-fade; defaults present; LDG trimGain 0) → Task 1 Step 1 (6 cases) + Task 2 Step 1. ✓ (The trim-FF magnitude/fade behaviour is already covered by the unchanged `test_loop_trim.lua` cases, which exercise the `loop.lua` math directly; Task 2 only moves the default numbers, so no new `test_loop_trim` case is required.)
- Spec §Out-of-scope (decouple fade, EMRCVR, caps, maxAngle, fade params) → untouched by both tasks. ✓

**2. Placeholder scan:** No TBD/TODO; all steps carry concrete code and exact run/expected lines.

**3. Type consistency:** `approach(cur, target, step)` defined in Task 1 Step 3, used in Step 5. `self.brakeTilt.{pitch,roll}` defined in Step 4, used in Step 5. `feel.tiltBrake.slewRate` produced in Task 2, consumed by Task 1's `self.cfg.tiltBrake.slewRate`. `slewRate=0.3`, `trimGain=0.18`, `trimAuthority=0.30` consistent across spec, tasks, and tests.

## OWED (post-implementation, in-world)

- Reload DEFAULT tuning in-world (or re-save) so the saved `eh2_tuning.tbl` picks up `slewRate` and the reduced trim.
- Verify: high-speed CRU brake no longer overshoots its commanded angle (no departure); accel lean feels less harsh. Then tune `slewRate` / `trimGain` / `trimAuthority`.
- Next batch (C/D): decouple-FF fade + EMRCVR rebuild.
