# Rate-command stopping-lead (yaw/alt/strafe) + three-way logging modes

Date: 2026-09-11
Status: design (brainstorm) — for review, then plan
Checkpoint to revert to if needed: git tag `cru-stable-2026-09-11` (@ 9c3dbd9).

Two independent features in one batch:
- **A. Stopping-lead** on the rate-command release captures — fixes the yaw/altitude/strafe
  overshoot + the yaw/strafe "slow" (authority) half.
- **B. Three-way logging mode** at boot (Full / Loop-rate-only / None), with a minimal-impact
  loop-rate mode so we can measure the TRUE FCS loop rate.

---

## Feature A — Stopping-lead on rate-command captures

### Problem (from flight log cc.lynx.rodeo/7d9da73455)

Yaw, altitude, and strafe are **rate-command axes** (hold = fly a rate; release = capture a
hold setpoint). The release capture in `fcs/input/pilot.lua` is **bare** — `sp.X = meas.X` —
so the velocity present at release carries the craft PAST the captured point:
- **Yaw:** release at 34°/s → **80° overshoot** (never settles); at 5°/s → ~10°. Scales with
  release rate. (Plus `sat_yaw=1` during turns → also authority-limited = the "slow" half.)
- **Altitude:** climb release with vSpeed +11.5 → **+10-block overshoot** then bobs to −6.4.
- **Strafe:** `sat_sway=1` (authority-limited, slow to move) + swayPos overshoot on release.

`tuningdefaults` documents the old `yawStopLead`/`altStopLead`/`swayLead` were **retired** in
the rate-command batch — removing them is what caused this.

### Design

**A1. Velocity-anticipating capture (`fcs/input/pilot.lua`).** On each rate-command release
edge, capture ahead of the craft by its stopping distance instead of at the current value:

```
-- yaw release (yawWasHeld):
sp.heading = meas.heading + (c.yawStopLead or 0) * (meas.yawRate or 0)
-- climb release (climbWasHeld):
sp.altitude = meas.altitude + (c.altStopLead or 0) * (meas.vSpeed or 0)
-- sway release (swayWasHeld):
sp.swayPos = meas.swayPos + (c.swayStopLead or 0) * (meas.swayVel or 0)
```

- `*StopLead` are in **seconds** (stopping-time estimate). Feed-forward on the captured
  setpoint → **dt-robust** (no per-tick term; behaves identically at any loop rate).
- **Bound** the lead so a velocity spike can't capture absurdly far: clamp each lead term to
  `±(c.*StopMax)` (a per-axis max lead distance; rad for heading, blocks for alt/sway).
  `*StopLead` nil ⇒ 0 ⇒ bare capture (legacy) so existing tests/config are unaffected.
- Heading wrap: adding a small radian lead to `meas.heading` is safe (the heading PID already
  handles wrapped error); no special-casing needed for the small leads involved.

**A2. Authority (the "slow" half).** Yaw and strafe rail at their caps (`sat_yaw`/`sat_sway`=1).
Raise the CRU demand caps modestly as **first estimates** so the controller can command more
yaw/lateral thrust (the envelope still clamps; low-risk):
- `CRUISE.caps.yaw` 0.6 → **0.8** (first estimate, TUNE)
- `CRUISE.caps.sway` 0.9 → **1.0** (first estimate, TUNE)

Only bump CRU (the distance/maneuver mode). With A1's lead, more authority = faster response
*without* more overshoot (arrest is quicker). Rig-verify stability; confirm real speed gain
in-world (the sim's absolute yaw/sway authority is approximate).

### First-estimate tuning (all TUNE in-world; rig brackets)

| knob | value | rad/blk | note |
|---|---|---|---|
| `feel.yawStopLead`  | 0.6 s | — | heading lead = yawStopLead·yawRate |
| `feel.altStopLead`  | 0.4 s | — | altitude lead = altStopLead·vSpeed |
| `feel.swayStopLead` | 0.4 s | — | swayPos lead = swayStopLead·swayVel |
| `feel.yawStopMax`   | 0.5 | rad (~29°) | clamp on the heading lead |
| `feel.altStopMax`   | 6 | blk | clamp on the alt lead |
| `feel.swayStopMax`  | 6 | blk | clamp on the sway lead |
| `CRUISE.caps.yaw`   | 0.8 | — | was 0.6 |
| `CRUISE.caps.sway`  | 1.0 | — | was 0.9 |

Lead applies in **CPL** (arrest) where overshoot matters; DCPL/tilt still relaxes (coast),
unchanged.

### Verification (rig, `tools/simrig*`)

Extend the rig with **release scenarios**: yaw (rotate → release), climb (up → release), strafe
(swayRight → release); measure peak overshoot past the captured setpoint. Assert **lead ON
rings less than lead OFF**, on both axes, across a 5/10/20 Hz sweep. Add cases to
`tests/test_simrig.lua`. Plus `pilot` unit tests: release edge captures `meas + lead·vel`,
clamped to `*StopMax`, and nil-lead ⇒ bare capture (legacy).

---

## Feature B — Three-way logging mode (Full / Loop-rate-only / None)

### Problem

The ~10 s loop-rate dips to 3.7 Hz are the **fcslog itself**: `logstream.lua`'s 10 s
auto-append formats ~160 rows + a synchronous CC disk write + carbide upload on the shared
coroutine → one ~250 ms stall each period. So we cannot measure the TRUE loop rate while
full-logging. We want a mode that records ONLY loop rate with near-zero flight-path impact.

### Design

**B1. Boot prompt → mode (not boolean).** Replace `loaderui.confirmLogging()` (Y/N) with
`confirmLogMode()` returning `"full" | "loop" | nil`:

```
FCS logging?  [F]ull / [L]oop-rate only / [N]one:
```

`fcs.lua` sets `_G.EH2_FLIGHTLOG = mode` (string or nil). Back-compat: `tools/flight.lua`
treats `true` as `"full"` (so the `fcslog` launcher's `_G.EH2_FLIGHTLOG = true` still means
full). Add a `fcslooprate` launcher shortcut that sets `"loop"` (mirrors `fcslog`).

**B2. `tools/flight.lua` mode gating.**
```
local LOG_MODE = _G.EH2_FLIGHTLOG
local LOGGING  = (LOG_MODE == "full" or LOG_MODE == true)   -- full instrumentation (current)
local LOOPLOG  = (LOG_MODE == "loop")
```
Every full-logging branch stays gated on `LOGGING` (NO-OP otherwise, exactly as today).

**B3. Minimal-impact loop-rate capture.** When `LOOPLOG`, the per-cycle cost is a **single
number stored** — no 73-column sample table, no delta-encode, no format:
```
-- per control cycle (loop-rate mode only):
looprec:put(dt)     -- append dt (seconds) to a pre-sized numeric ring buffer
```
- New tiny module `fcs/bringup/looprec.lua`: a fixed-capacity numeric ring of `dt` values
  (cap ~20000 ≈ 11 min at 30 Hz — RAM-safe), O(1) put, keeps the most-recent window.
- **NO periodic I/O in loop mode** — the whole point. No 10 s timer append. The loop-rate
  buffer is written ONLY on **P / exit** (off the flight path): format `t,dt_ms,hz` per sample
  to `/eh2_looprate.csv` (+ optional carbide put), reconstructing `t` by cumulative dt from a
  stored start epoch. Formatting numbers at dump time is cheap and off-loop (same principle as
  full mode's deferred format).
- Loop mode ignores the full-log P-stream machinery entirely; P in loop mode = "dump the
  loop-rate ring now" (keep flying).

**B4. NO-OP when not booted.** With `LOG_MODE` nil, both `LOGGING` and `LOOPLOG` are false and
every branch is one boolean check per cycle — identical to today's no-op guarantee.

### Why this measures the TRUE loop rate

Loop mode adds one numeric store per cycle and does zero periodic I/O, so it does not induce
the 10 s stalls (nor any other periodic cost). The recorded dt series is the FCS's real
cadence under a normal (non-log-perturbed) flight.

### Verification

- `test_looprec.lua`: ring stores dt, wraps at cap, dump reconstructs `t`/`hz` correctly.
- `test_flight` (or a focused test): `LOG_MODE="loop"` does NOT create the full-log ring / does
  not arm the 10 s stream timer; `"full"` still does; `nil` no-ops both.
- Headless self-check that loop mode's per-cycle path allocates no per-cycle sample table.

---

## Scope / out

**In:** A1 lead, A2 modest CRU caps bump, rig release scenarios + tests, B1-B4 logging modes +
tests.

**Out (deferred):** deeper yaw/lateral thruster-count/authority redesign (if the caps bump
proves thrust-limited in-world); the residual ~20° base off-CoM cascade
([[eh2-strip-translation-attitude-ffs]] deferral); making full-log's 10 s append non-blocking
(loop mode sidesteps it; full mode's stalls stay a known diagnostic cost).

## Acceptance

- Rig: yaw/alt/strafe release overshoot with lead << without, rate-independent (5-20 Hz).
- Loop-rate mode: per-cycle cost is a single numeric store, no periodic I/O; dumps a usable
  per-cycle `t,dt_ms,hz` CSV. Both log modes no-op when not booted.
- Full suite green (`bash tests/run_headless.sh`), manifest IN SYNC.
- OWED in-world: tune the six *StopLead/*StopMax + two caps values; fly a loop-rate-only test
  to capture the true (unperturbed) FCS loop rate; then deploy (build dist + manifests).

## Files touched

- `fcs/input/pilot.lua` — velocity-anticipating captures (A1).
- `fcs/io/tuningdefaults.lua` — `feel.*StopLead`/`*StopMax`; CRU `caps.yaw`/`caps.sway` (A2).
- `fcs/boot/loaderui.lua` — `confirmLogMode()` 3-way prompt (B1).
- `launchers/fcs.lua` — pass the mode; new `launchers/fcslooprate.lua` (B1).
- `tools/flight.lua` — mode gating + loop-rate capture/dump (B2-B4).
- `fcs/bringup/looprec.lua` — new numeric-ring loop-rate buffer (B3).
- tests: `test_pilot_modes.lua`, `test_simrig.lua` + rig scenarios, `test_looprec.lua`,
  `test_tuningdefaults.lua`/`test_tuning_modes.lua` (new knobs), `test_bootloaderui.lua`
  (3-way prompt), `test_flight.lua` (mode gating).
