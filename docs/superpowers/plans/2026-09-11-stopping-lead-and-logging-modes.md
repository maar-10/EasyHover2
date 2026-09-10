# Stopping-lead + Three-way Logging Modes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (A) Fix the yaw/altitude/strafe release overshoot with a velocity-anticipating capture (+modest CRU yaw/sway authority). (B) Add a boot-time Full / Loop-rate-only / None logging choice, with a minimal-impact loop-rate mode that measures the true FCS loop rate.

**Architecture:** Two independent feature groups. A = `pilot.lua` capture change + `tuningdefaults` knobs, verified with the sim rig. B = a tiny numeric-ring module + boot-prompt change + `tools/flight.lua` mode gating. No control-law math changes beyond the setpoint capture.

**Tech Stack:** CC:Tweaked Lua (MC 1.21.1); headless suite `bash tests/run_headless.sh`; framework `tests/framework.lua` (`t.test`, `t.eq`, `t.near`, `t.truthy`); sim rig `tools/simrig*`.

## Global Constraints

- `bash tests/run_headless.sh` green + manifest IN SYNC at the end of each task.
- Angles radians. `*StopLead` in seconds; `*StopMax` clamps (rad for heading, blocks for alt/sway).
- Feed-forward only — no per-tick dt terms in the capture (dt-robust). nil lead ⇒ bare capture (legacy).
- Logging: both Full and Loop modes must be NO-OP when not booted with (single boolean check/cycle). Loop mode must do ZERO periodic I/O (that is the whole point).
- Do NOT change: control PID/cascade math, other modes' caps, the full-log format/stream path.
- Exact first-estimate values (all TUNE): `yawStopLead=0.6, altStopLead=0.4, swayStopLead=0.4` s; `yawStopMax=0.5, altStopMax=6, swayStopMax=6`; `CRUISE.caps.yaw=0.8, CRUISE.caps.sway=1.0`.
- ASCII-only comments, no em-dash. Follow EH2 idiom. Commit after each task with the attribution block.

---

### Task 1: Stopping-lead capture + CRU authority (`fcs/input/pilot.lua`, `fcs/io/tuningdefaults.lua`)

**Files:**
- Modify: `fcs/input/pilot.lua` (three release-edge captures)
- Modify: `fcs/io/tuningdefaults.lua` (feel `*StopLead`/`*StopMax`; CRU `caps.yaw`/`caps.sway`)
- Test: `tests/test_pilot_modes.lua`, `tests/test_tuningdefaults.lua`, `tests/test_tuning_modes.lua`

**Interfaces:**
- Consumes: `self.cfg.yawStopLead/altStopLead/swayStopLead/yawStopMax/altStopMax/swayStopMax` (feel; may be nil), and measured `meas.yawRate/vSpeed/swayVel` already passed to `Pilot:update`.
- Produces: on a rate-command release edge, `sp.heading/altitude/swayPos = meas + clamp(lead*vel, ±max)`. New feel defaults. CRU caps 0.8/1.0.

- [ ] **Step 1: Write failing pilot tests**

Append to `tests/test_pilot_modes.lua`:

```lua
-- Stopping-lead (2026-09-11): rate-command release captures ahead of the craft by its stopping
-- distance (meas + lead*velocity, clamped to *StopMax) so residual velocity doesn't overshoot.
local FEEL_LEAD = { headingRate=1.5, climbRate=6, surgeSpeed=10, surgeLead=20, swaySpeed=6,
  tiltRate=0.8, tiltCap=0.4, cruiseThrottleRate=1.0, cruiseThrottleMax=1.0,
  yawStopLead=0.6, altStopLead=0.4, swayStopLead=0.4, yawStopMax=0.5, altStopMax=6, swayStopMax=6 }

t.test("yaw release captures heading + yawStopLead*yawRate", function()
  local p = Pilot.new(FEEL_LEAD); p:setMode({ tilt=false, surge="throttle" }, FEEL_LEAD); p:reset(meas())
  p:update(0.1, { yawRight = true }, { altitude=0, heading=1.0, swayPos=0, surgePos=0, yawRate=0.5 })
  local sp = p:update(0.1, {}, { altitude=0, heading=1.0, swayPos=0, surgePos=0, yawRate=0.5 })  -- release
  t.near(sp.heading, 1.0 + 0.6*0.5, 1e-6, "heading lead = yawStopLead*yawRate")
end)

t.test("climb release captures altitude + altStopLead*vSpeed", function()
  local p = Pilot.new(FEEL_LEAD); p:setMode({ tilt=false, surge="throttle" }, FEEL_LEAD); p:reset(meas())
  p:update(0.1, { up = true }, { altitude=50, heading=0, swayPos=0, surgePos=0, vSpeed=8 })
  local sp = p:update(0.1, {}, { altitude=50, heading=0, swayPos=0, surgePos=0, vSpeed=8 })
  t.near(sp.altitude, 50 + 0.4*8, 1e-6, "alt lead = altStopLead*vSpeed")
end)

t.test("sway release captures swayPos + swayStopLead*swayVel", function()
  local p = Pilot.new(FEEL_LEAD); p:setMode({ tilt=false, surge="throttle" }, FEEL_LEAD); p:reset(meas())
  p:update(0.1, { swayRight = true }, { altitude=0, heading=0, swayPos=2, surgePos=0, swayVel=5 })
  local sp = p:update(0.1, {}, { altitude=0, heading=0, swayPos=2, surgePos=0, swayVel=5 })
  t.near(sp.swayPos, 2 + 0.4*5, 1e-6, "sway lead = swayStopLead*swayVel")
end)

t.test("lead is clamped to *StopMax", function()
  local p = Pilot.new(FEEL_LEAD); p:setMode({ tilt=false, surge="throttle" }, FEEL_LEAD); p:reset(meas())
  p:update(0.1, { up = true }, { altitude=0, heading=0, swayPos=0, surgePos=0, vSpeed=100 })
  local sp = p:update(0.1, {}, { altitude=0, heading=0, swayPos=0, surgePos=0, vSpeed=100 })  -- 0.4*100=40 -> clamp 6
  t.near(sp.altitude, 6, 1e-6, "alt lead clamped to altStopMax")
end)

t.test("nil lead => bare capture (legacy)", function()
  local NO = { headingRate=1.5, climbRate=6, surgeSpeed=10, surgeLead=20, swaySpeed=6, cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 }
  local p = Pilot.new(NO); p:setMode({ tilt=false, surge="throttle" }, NO); p:reset(meas())
  p:update(0.1, { up = true }, { altitude=50, heading=0, swayPos=0, surgePos=0, vSpeed=8 })
  local sp = p:update(0.1, {}, { altitude=50, heading=0, swayPos=0, surgePos=0, vSpeed=8 })
  t.near(sp.altitude, 50, 1e-9, "no lead field => bare capture")
end)
```

- [ ] **Step 2: Run to verify fail**

Run: `bash tests/run_headless.sh` — the new pilot cases FAIL (captures are bare).

- [ ] **Step 3: Implement the leads in `fcs/input/pilot.lua`**

Add a file-level helper near `approach` (from the brake-slew batch):

```lua
-- Stopping-lead: capture ahead of the craft by its predicted stopping distance (lead*vel),
-- clamped to +-maxd, so a rate-command release does not overshoot the captured hold. lead nil => 0.
local function leadCap(base, vel, lead, maxd)
  local d = (lead or 0) * (vel or 0)
  if maxd then if d > maxd then d = maxd elseif d < -maxd then d = -maxd end end
  return base + d
end
```

In `Pilot:update`, change the three release captures:

- yaw (was `sp.heading = meas.heading or sp.heading`):
```lua
    if self.yawWasHeld then sp.heading = leadCap(meas.heading or sp.heading, meas.yawRate, c.yawStopLead, c.yawStopMax); self.yawWasHeld = false end
```
- climb (was `sp.altitude = meas.altitude or sp.altitude`):
```lua
    if self.climbWasHeld then sp.altitude = leadCap(meas.altitude or sp.altitude, meas.vSpeed, c.altStopLead, c.altStopMax); self.climbWasHeld = false end
```
- sway (was `sp.swayPos = meas.swayPos or sp.swayPos`):
```lua
    if self.swayWasHeld then sp.swayPos = leadCap(meas.swayPos or sp.swayPos, meas.swayVel, c.swayStopLead, c.swayStopMax); self.swayWasHeld = false end
```
(`c` is the existing `local c, sp = self.cfg, self.sp`. Keep the `nil`-guards: `meas.heading or sp.heading` stays the base.)

- [ ] **Step 4: Add the tuning defaults**

In `fcs/io/tuningdefaults.lua` `DEFAULTS.feel`, add (near the rate-command feel block):

```lua
    -- Stopping-lead (2026-09-11): rate-command release captures ahead by lead*velocity (clamped
    -- to *StopMax), so releasing a fast yaw/climb/strafe does not overshoot the hold. TUNE in-world.
    yawStopLead    = 0.6,   -- s (heading lead = yawStopLead*yawRate)
    altStopLead    = 0.4,   -- s (altitude lead = altStopLead*vSpeed)
    swayStopLead   = 0.4,   -- s (swayPos lead = swayStopLead*swayVel)
    yawStopMax     = 0.5,   -- rad (~29deg) clamp
    altStopMax     = 6,     -- blk clamp
    swayStopMax    = 6,     -- blk clamp
```

After the CRUISE overrides block (near the other `DEFAULTS.modes.CRUISE.*` lines), add the
authority bump:

```lua
-- Authority (2026-09-11): yaw/strafe railed at caps (sat=1 in flight) -> slow. Modest CRU bump so
-- the controller can command more yaw/lateral thrust; the envelope still clamps. TUNE in-world.
DEFAULTS.modes.CRUISE.caps.yaw  = 0.8   -- was 0.6
DEFAULTS.modes.CRUISE.caps.sway = 1.0   -- was 0.9
```

- [ ] **Step 5: Update tuning-defaults tests**

In `tests/test_tuningdefaults.lua` add a case:

```lua
t.test("defaults expose stopping-lead knobs", function()
  local d = require("fcs.io.tuningdefaults").get().feel
  t.near(d.yawStopLead, 0.6, 1e-9); t.near(d.altStopLead, 0.4, 1e-9); t.near(d.swayStopLead, 0.4, 1e-9)
  t.near(d.yawStopMax, 0.5, 1e-9); t.near(d.altStopMax, 6, 1e-9); t.near(d.swayStopMax, 6, 1e-9)
end)
```

In `tests/test_tuning_modes.lua` add:

```lua
t.test("CRU authority bump: yaw 0.8, sway 1.0", function()
  local c = tuning.forMode("CRUISE").caps
  t.near(c.yaw, 0.8, 1e-9); t.near(c.sway, 1.0, 1e-9)
  t.near(tuning.forMode("MAN").caps.yaw, 0.6, 1e-9)   -- other modes unchanged
end)
```

- [ ] **Step 6: Run to verify pass**

Run: `bash tests/run_headless.sh` — all new cases pass; whole suite green; manifest IN SYNC.

- [ ] **Step 7: Commit**

```bash
git add fcs/input/pilot.lua fcs/io/tuningdefaults.lua tests/test_pilot_modes.lua tests/test_tuningdefaults.lua tests/test_tuning_modes.lua
git commit -m "$(cat <<'EOF'
feat(fcs): stopping-lead on rate-command captures + CRU yaw/sway authority

Yaw/alt/strafe release now captures meas + lead*velocity (clamped to *StopMax)
so a fast release stops at the target instead of overshooting (log: yaw
released at 34deg/s overshot 80deg). Feed-forward on the setpoint => dt-robust.
Modest CRU caps bump (yaw .6->.8, sway .9->1.0) for the authority-limited
"slow" half. All first estimates, TUNE in-world. nil lead => bare capture.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 2: Rig release scenarios + overshoot regression (`tools/simrig_run.lua`, `tests/test_simrig.lua`)

**Files:**
- Modify: `tools/simrig_run.lua` (add YAWREL / CLIMBREL / STRAFEREL scenarios + a lead-toggle path)
- Modify: `tools/simrig.lua` (apply feel `*StopLead`/`*StopMax` via a `lead` toggle so ON/OFF is comparable under identical physics)
- Test: `tests/test_simrig.lua` (lead ON overshoot < lead OFF, both axes)

**Interfaces:**
- Consumes: `rig.run(simParams, toggles, dt, script)` returns phase-keyed `{peakP,peakR,endP,endR}`; extend `run`/scenarios so a scenario can report peak heading/alt/sway excursion past the captured setpoint.
- Produces: `toggles.lead = {yaw,alt,sway,...}` (or `false`) that sets the feel `*StopLead` on the CRUISE feel before the mode is used (same deep-copy pattern as the existing feel overrides in `buildStack`).

- [ ] **Step 1: Add a `lead` override to `buildStack` (`tools/simrig.lua`)**

In the existing CRUISE-feel deep-copy block (where `cf` is copied), after the trim/brakeTrim overrides add:

```lua
    if toggles.lead ~= nil then
      local L = toggles.lead or {}
      cf.yawStopLead  = L.yaw;  cf.altStopLead  = L.alt;  cf.swayStopLead  = L.sway
      cf.yawStopMax   = L.yawMax  or cf.yawStopMax
      cf.altStopMax   = L.altMax  or cf.altStopMax
      cf.swayStopMax  = L.swayMax or cf.swayStopMax
    end
```
(so `toggles.lead=false` -> `L={}` -> nil leads -> bare capture; a table sets them.)

- [ ] **Step 2: Add release scenarios + overshoot metric (`tools/simrig_run.lua`)**

Add scenarios and, in `run`, track the peak excursion of heading/alt/swayPos PAST the
value captured at the release tick. Concretely add helper metrics to the per-phase record:
`ovrH` (deg past captured heading), `ovrA` (blocks past captured alt), `ovrS` (blocks past
captured swayPos). Capture the setpoint at the first tick of the post-release phase, then track
max |measured - captured| over that phase. Scenarios:

```lua
local YAWREL   = { {secs=6,held={up=true},tag="climb"}, {secs=3,held={},tag="s0"},
  {secs=4,held={yawRight=true},tag="turn"}, {secs=8,held={},tag="yawrec"} }
local CLIMBREL = { {secs=3,held={},tag="s0"}, {secs=5,held={up=true},tag="climb"}, {secs=8,held={},tag="altrec"} }
local STRAFEREL= { {secs=6,held={up=true},tag="climb"}, {secs=3,held={},tag="s0"},
  {secs=4,held={swayRight=true},tag="strafe"}, {secs=8,held={},tag="swayrec"} }
```

- [ ] **Step 3: Write the failing regression test (`tests/test_simrig.lua`)**

Append:

```lua
local LEAD = { yaw=0.6, alt=0.4, sway=0.4 }
t.test("simrig: stopping-lead cuts yaw release overshoot", function()
  local base = { spoolTime=0.5, tiltTrans=1.0, latRoll=0.6, surgePitch=0.1 }
  local off = rig.run(base, { lead=false }, 0.1, rig.YAWREL)
  local on  = rig.run(base, { lead=LEAD }, 0.1, rig.YAWREL)
  t.truthy(on.yawrec.ovrH < off.yawrec.ovrH,
    string.format("yaw overshoot lead=%.0f < nolead=%.0f", on.yawrec.ovrH, off.yawrec.ovrH))
end)
t.test("simrig: stopping-lead cuts altitude release overshoot", function()
  local base = { spoolTime=0.5, tiltTrans=1.0, latRoll=0.6, surgePitch=0.1 }
  local off = rig.run(base, { lead=false }, 0.1, rig.CLIMBREL)
  local on  = rig.run(base, { lead=LEAD }, 0.1, rig.CLIMBREL)
  t.truthy(on.altrec.ovrA < off.altrec.ovrA,
    string.format("alt overshoot lead=%.1f < nolead=%.1f", on.altrec.ovrA, off.altrec.ovrA))
end)
```

- [ ] **Step 4: Implement metrics until tests pass; verify across Hz**

Implement `ovrH/ovrA/ovrS` in `run`. Run: `bash tests/run_headless.sh` (both cases pass) and
`bash tools/run_simrig.sh` (smoke: print a release-overshoot table for dt 0.1 and 0.2 showing
lead ON < OFF on yaw/alt/strafe — confirm the improvement is rate-independent). If the lead does
NOT reduce overshoot in the rig, STOP and report BLOCKED (the fix or the metric is wrong) rather
than weakening the assertion.

- [ ] **Step 5: Commit**

```bash
git add tools/simrig.lua tools/simrig_run.lua tests/test_simrig.lua
git commit -m "$(cat <<'EOF'
test(fcs): rig release scenarios + stopping-lead overshoot regression

simrig gains yaw/climb/strafe release scenarios and a `lead` toggle; test_simrig
asserts the stopping-lead rings less past the captured setpoint than the bare
capture, under identical physics.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 3: Loop-rate ring buffer (`fcs/bringup/looprec.lua` + test)

**Files:**
- Create: `fcs/bringup/looprec.lua`
- Test: `tests/test_looprec.lua`

**Interfaces:**
- Produces: `Looprec.new(cap)` -> object with `:put(dt)` (O(1), stores a dt sample, wraps at cap keeping the most-recent window) and `:samples()` -> ordered list of dt values (oldest-first) for dump. `:count()` -> stored count.

- [ ] **Step 1: Write the failing test (`tests/test_looprec.lua`)**

```lua
local t = require("tests.framework")
local Looprec = require("fcs.bringup.looprec")
t.test("looprec stores dt samples in order", function()
  local r = Looprec.new(4)
  r:put(0.05); r:put(0.06); r:put(0.05)
  t.eq(r:count(), 3)
  local s = r:samples(); t.near(s[1], 0.05, 1e-9); t.near(s[3], 0.05, 1e-9)
end)
t.test("looprec wraps at cap keeping the most-recent window", function()
  local r = Looprec.new(3)
  for i=1,5 do r:put(i/100) end   -- 0.01..0.05, cap 3 keeps 0.03,0.04,0.05
  t.eq(r:count(), 3)
  local s = r:samples(); t.near(s[1], 0.03, 1e-9); t.near(s[3], 0.05, 1e-9)
end)
```

- [ ] **Step 2: Run to verify fail** — `bash tests/run_headless.sh` (module missing).

- [ ] **Step 3: Implement `fcs/bringup/looprec.lua`**

```lua
-- fcs/bringup/looprec.lua -- minimal-impact loop-rate recorder: a fixed-capacity numeric ring of
-- per-cycle dt (seconds). O(1) put, no allocation per put after warmup, no I/O. Dumped off the
-- flight path (P/exit) into t,dt_ms,hz. Used only in LOOP logging mode.
local Looprec = {}
Looprec.__index = Looprec
function Looprec.new(cap)
  return setmetatable({ cap = cap or 20000, buf = {}, n = 0, head = 1, full = false }, Looprec)
end
function Looprec:put(dt)
  self.buf[self.head] = dt
  self.head = self.head + 1
  if self.head > self.cap then self.head = 1; self.full = true end
  if not self.full then self.n = self.head - 1 end
end
function Looprec:count() return self.full and self.cap or self.n end
function Looprec:samples()
  local out, c = {}, self:count()
  local start = self.full and self.head or 1        -- oldest-first
  for i = 0, c - 1 do out[i + 1] = self.buf[((start - 1 + i) % self.cap) + 1] end
  return out
end
return Looprec
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run_headless.sh` green.

- [ ] **Step 5: Commit**

```bash
git add fcs/bringup/looprec.lua tests/test_looprec.lua
git commit -m "$(cat <<'EOF'
feat(fcs): looprec -- minimal-impact loop-rate ring buffer

Fixed-capacity numeric ring of per-cycle dt for the LOOP logging mode: O(1) put,
no per-cycle allocation, no I/O; dumped off the flight path. Keeps the recent
window so a long test is RAM-safe.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 4: Three-way boot prompt + launcher (`fcs/boot/loaderui.lua`, `launchers/`)

**Files:**
- Modify: `fcs/boot/loaderui.lua` (`confirmLogMode` + pure `logModeOf`; `run()` returns the mode)
- Modify: `launchers/fcs.lua` (pass the mode into `_G.EH2_FLIGHTLOG`)
- Create: `launchers/fcslooprate.lua`
- Test: `tests/test_bootloaderui.lua`

**Interfaces:**
- Produces: `loaderui.logModeOf(input) -> "full"|"loop"|nil|"?"` (pure: "?" = unrecognized, loop again). `run()` returns `assembled, mode` where mode is `"full"|"loop"|nil`. `launchers/fcs.lua` sets `_G.EH2_FLIGHTLOG = mode`.

- [ ] **Step 1: Write failing test for the pure mapper (`tests/test_bootloaderui.lua`)**

```lua
t.test("logModeOf maps F/L/N (any case) to full/loop/nil, else '?'", function()
  local M = require("fcs.boot.loaderui")
  t.eq(M.logModeOf("f"), "full");  t.eq(M.logModeOf("Full"), "full")
  t.eq(M.logModeOf("l"), "loop");  t.eq(M.logModeOf("LOOP"), "loop")
  t.eq(M.logModeOf("n"), nil);     t.eq(M.logModeOf("none"), nil)
  t.eq(M.logModeOf("x"), "?")
end)
```

- [ ] **Step 2: Run to verify fail.**

- [ ] **Step 3: Implement in `fcs/boot/loaderui.lua`**

Add the pure mapper (exported on M) and rewrite `confirmLogging` -> `confirmLogMode`:

```lua
function M.logModeOf(input)
  input = (input or ""):lower()
  if input == "f" or input == "full" then return "full" end
  if input == "l" or input == "loop" then return "loop" end
  if input == "n" or input == "none" or input == "" then return nil end   -- default = none
  return "?"
end
local function confirmLogMode()
  while true do
    print("")
    write("FCS logging?  [F]ull / [L]oop-rate only / [N]one: ")
    local m = M.logModeOf(read())
    if m ~= "?" then return m end
    print("  please answer F, L, or N")
  end
end
```
Note: `""` (blank/enter) returns nil (None) as the safe default. Replace the `confirmLogging()`
call in `run()` with `confirmLogMode()` and return the mode as the second value (was `logging`).

- [ ] **Step 4: Wire launchers**

`launchers/fcs.lua`: change `_G.EH2_FLIGHTLOG = logging == true` to `_G.EH2_FLIGHTLOG = mode`
(and rename the local `logging` -> `mode`).

Create `launchers/fcslooprate.lua` (mirror `launchers/fcslog.lua`):
```lua
-- Boots the FCS with LOOP-RATE-ONLY logging on (minimal-impact: per-cycle dt only, dumped on P/
-- exit, no periodic I/O). Skips the boot prompt. Identical to fcs/fcslog otherwise.
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_FLIGHTLOG = "loop"
require("tools.flight")
```

- [ ] **Step 5: Run to verify pass** — `bash tests/run_headless.sh` green (the run()-loop stays
in-game only / untested, matching the existing confirmLogging convention; only `logModeOf` is unit-tested).

- [ ] **Step 6: Commit**

```bash
git add fcs/boot/loaderui.lua launchers/fcs.lua launchers/fcslooprate.lua tests/test_bootloaderui.lua
git commit -m "$(cat <<'EOF'
feat(fcs): boot logging mode -- Full / Loop-rate only / None

Replaces the Y/N logging prompt with a 3-way choice; pure logModeOf() maps the
answer to "full"/"loop"/nil (blank=none). fcs launcher passes the mode into
_G.EH2_FLIGHTLOG; new fcslooprate launcher shortcut for loop-only.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

### Task 5: Flight-runtime mode gating + loop-rate capture/dump (`tools/flight.lua`)

**Files:**
- Modify: `tools/flight.lua`
- Test: `tests/test_flight.lua` (mode gating; loop mode arms no full-log machinery)

**Interfaces:**
- Consumes: `_G.EH2_FLIGHTLOG` as `"full"|"loop"|true|nil`; `fcs.bringup.looprec`.
- Produces: `LOGGING = (mode=="full" or mode==true)`, `LOOPLOG = (mode=="loop")`. In LOOP mode the
  per-cycle path does `looprec:put(dt)` only; P/exit dumps `/eh2_looprate.csv`. No periodic timer append in loop mode.

- [ ] **Step 1: Write failing test (`tests/test_flight.lua`)**

Add a headless check that the module resolves the mode flags correctly. Since `tools/flight.lua`
is a runtime script (peripheral-dependent) not a pure module, test the resolution logic via a
tiny extracted pure helper. Add to `tools/flight.lua` (exported for test) OR test the boot mapping
already covered in Task 4. Minimal concrete test — a pure helper `logFlags(mode)`:

```lua
-- in a testable module fcs/bringup/logmode.lua
local t = require("tests.framework")
local L = require("fcs.bringup.logmode")
t.test("logmode flags", function()
  t.eq(L.full("full"), true);  t.eq(L.full(true), true); t.eq(L.full("loop"), false); t.eq(L.full(nil), false)
  t.eq(L.loop("loop"), true);  t.eq(L.loop("full"), false); t.eq(L.loop(nil), false)
end)
```

- [ ] **Step 2: Run to verify fail** (module missing).

- [ ] **Step 3: Implement `fcs/bringup/logmode.lua`** (pure, tiny):

```lua
-- fcs/bringup/logmode.lua -- resolve _G.EH2_FLIGHTLOG into full/loop flags. true == full (legacy).
local M = {}
function M.full(mode) return mode == "full" or mode == true end
function M.loop(mode) return mode == "loop" end
return M
```

- [ ] **Step 4: Wire `tools/flight.lua`**

Replace `local LOGGING = _G.EH2_FLIGHTLOG == true` with:
```lua
local logmode  = require("fcs.bringup.logmode")
local LOG_MODE = _G.EH2_FLIGHTLOG
local LOGGING  = logmode.full(LOG_MODE)
local LOOPLOG  = logmode.loop(LOG_MODE)
local looprec  = LOOPLOG and require("fcs.bringup.looprec").new(20000) or nil
```
In the per-cycle logging entry point (`logCycle`, which currently `if not LOGGING then return end`),
add the loop path FIRST so full-log work stays gated:
```lua
local function logCycle(dt, m)
  if LOOPLOG then if looprec and dt and dt > 0 then looprec:put(dt) end; return end
  if not LOGGING then return end
  ...
end
```
Add a loop-rate dump (off the flight path — called from the same P-key and exit handlers that call
`dumpOnce`/`logFinish`, guarded by `LOOPLOG`): format `looprec:samples()` into `/eh2_looprate.csv`
as `t,dt_ms,hz` (reconstruct `t` by cumulative dt from a stored start; `hz = dt>0 and 1/dt or 0`),
then optionally `carbide put`. Do NOT arm the 10 s `LogStream` timer in loop mode (guard the timer
task's dump with `LOGGING`, so loop mode does zero periodic I/O). Ensure the P-key handler in loop
mode calls the loop dump, not `dumpOnce`.

- [ ] **Step 5: Run to verify pass + smoke**

Run: `bash tests/run_headless.sh` (green + manifest IN SYNC). Confirm by inspection that:
(a) `LOOPLOG` path stores only dt and returns before any full-log work; (b) the 10 s stream timer
dump is guarded by `LOGGING` (not armed in loop mode); (c) `nil` mode no-ops both.

- [ ] **Step 6: Commit**

```bash
git add tools/flight.lua fcs/bringup/logmode.lua tests/test_flight.lua tests/test_logmode.lua
git commit -m "$(cat <<'EOF'
feat(fcs): loop-rate logging mode in the flight runtime

_G.EH2_FLIGHTLOG now full/loop/nil (true==full legacy). LOOP mode records only
per-cycle dt into looprec (one numeric store/cycle) and dumps t,dt_ms,hz on
P/exit -- no periodic I/O, so it does not perturb the loop rate it measures.
Full mode unchanged; both no-op when not booted.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AuZk7e2Urqp5S6uuXWcVpJ
EOF
)"
```

---

## Self-Review

**1. Spec coverage:** A1 lead → Task 1; A2 caps → Task 1; rig verify → Task 2; looprec → Task 3;
3-way prompt+launcher → Task 4; flight mode gating + loop capture/dump → Task 5. All spec §A/§B
items mapped. ✓

**2. Placeholder scan:** Task 5 Step 4 describes the dump wiring in prose (the exact P-key/exit
handler edits depend on reading the surrounding `tools/flight.lua` structure) — the implementer is
told exactly what to guard (`LOGGING` on the timer, `LOOPLOG` on the per-cycle + dump) and the
output format; this is integration into existing code, not a placeholder. All other steps carry
concrete code.

**3. Type consistency:** `logModeOf` returns "full"/"loop"/nil/"?"; `logmode.full/loop` consume the
same "full"/"loop"/true/nil. `leadCap(base,vel,lead,maxd)` defined+used in Task 1. `Looprec`
`:put/:samples/:count` defined in Task 3, consumed in Task 5. Rig `toggles.lead` produced/consumed
Task 2. Values (0.6/0.4/0.4, 0.5/6/6, caps 0.8/1.0) consistent spec↔plan.

## OWED (post-implementation, in-world)
- Tune the six *StopLead/*StopMax + the two CRU caps.
- Fly a LOOP-rate test to capture the true (unperturbed) FCS loop rate; compare to the ~18 Hz seen.
- Deploy (build dist + regen manifests, per `eh2-deploy-pipeline`), SuiteX update, reload DEFAULT tuning.
