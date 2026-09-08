# FCS Week Audit & Retrospective — 2026-09-08

**Scope:** every FCS-touching change from the last-known-stable-hover baseline
`pre-test-2026-08-31b` (HEAD 17aad60) to current `main` (HEAD a392a0e) — 67 commits.
**Trigger:** a week of successive FCS fix-waves (runaway → trim/stuck-bank → altitude
bumps → lateral drift) raised the concern that we drifted from "stable hover with flight
issues" to "a differently-behaving FCS that still has lateral drift." This audit
re-evaluates each change against **Create Propulsion / Create Simulated mod source** and
the **project specs**, and asks whether any of it should be reverted or redone.

Baseline is treated as the last version where **hover was stable**, NOT as a good-flying
version — it flew sluggishly and carried the runaway/flip + random-thruster-firing bug.

---

## TL;DR verdict

**We are on the right track. Do NOT revert.** The week's work is a **net improvement**
everywhere *except one axis*: the **horizontal (sway/surge) hold**, which was
**structurally down-tuned for stability** while chasing "faster strafe" and chasing a
symptom (a ±16 divergence) whose true cause is at the **actuator layer**, not the
controller.

The single most important finding of the whole week (found today): the lateral limit
cycle is driven by **Create Propulsion's 0.5 s thruster spool ramp** on the
**unidirectional** lateral thrusters. This is a hardware/mod property that has been
constant the entire time — no controller change caused it, and no controller retune can
fully cure it. It imposes a **hard bandwidth ceiling** on direct lateral thrust. The
week's lateral retunes repeatedly pushed the loop *past* that ceiling.

**Recommendation:** keep all the attitude/vertical/safety/braking/trim work (it is sound
and wanted); fix the **actuator** (keep the lateral thruster banks "warm" so they never
re-spool from zero on a reversal — exactly how the lift thrusters already behave); *then*
re-tune the lateral hold with the ceiling raised. This is a **targeted forward fix, not a
revert.**

---

## 1. The regression, precisely located

### Lateral hold, baseline vs now (LDG mode, the boot default and the flown mode)

| | Baseline `08-31b` | Current `a392a0e` |
|---|---|---|
| Structure | PD, independent gains: `kp·err + i − kd·vel` | Velocity-limited cascade: `ks·(clamp(ka·err, ±vmax) − vel)` |
| Sway gains | `kp=0.2, kd=0.25` (Kd/Kp = **1.25**, damping-dominant) | `ks=0.3, ka=1.0` → Kp=0.3, Kd=0.3 (Kd/Kp = **1.0**) |
| Effective stiffness | Kp = 0.2 | Kp = 0.3 (**+50 %**, higher bandwidth) |
| Damping | independent `kd` (tunable without touching stiffness) | **coupled**: Kd = ks, so more damping ⇒ more stiffness too |
| Setpoint discipline | **leashed** (`swayLead=4.0`, `swaySpeed=2.0`) | **leash retired** on sway; `swaySpeed=3.0` (⇒ vmax=3.0) |

**Why this matters against the actuator:** a loop with ~0.5 s of feedback lag (the spool
ramp, see §4) has a stability boundary on loop gain. Baseline sat comfortably under it —
low stiffness, damping-dominant, leash-bounded, gentle speed. The week's changes raised
stiffness ~1.5×, coupled damping so it couldn't be raised independently, removed the leash
that bounded the setpoint excursion, and raised the commanded speed. Every one of those
moves the loop *toward* the instability boundary. Together they crossed it → the growing
~10.5 s oscillation that saturates into the ±16-block bang-bang seen in flight
`487b634ca6`.

### This is confined to lateral. Attitude, vertical, yaw are fine.

Roll/pitch std ≈ 3° in the same flight; altitude tracks; the craft holds attitude through
the entire lateral limit cycle. The reason is structural and important: the **lift**
thrusters run at ~0.5 hover duty **continuously** (banded off the 0/1 rails in
`mixer/level_flight.lua`), so they are **always spooled** and behave linearly. The
attitude loop therefore never pays the spool penalty. The lateral thrusters do (§4).

---

## 2. Per-batch audit

### KEEP — sound, correctly implemented, wanted

- **Attitude leveling integral (roll+pitch)** `0b4ee3b` — adds `ki` to the roll/pitch PID
  to null steady banks. Uses `iBand` conditional integration so it only trims near the
  setpoint. Standard, correct. Fixes the "stuck 5–24° bank" bug.
- **D-kill fix** `29def0a` — baseline `pid.lua` gated *both* I and D on `not saturated`,
  so the derivative (damping) vanished whenever the output railed — exactly when you need
  damping. Fix splits the gate: **D computes whenever `dt` is valid; only integration
  freezes under saturation.** This is a genuine, important bug fix; it resolved the CRU
  vertical limit-cycle. Cross-checked: correct anti-windup practice.
- **Altitude conditional-integration anti-windup (`iBand`)** `d68b6b6` — integrate only
  while `|err| ≤ iBand`, so a setpoint that leads the craft during a climb doesn't wind up
  and overshoot. Correct.
- **CoM handoff / Auto-CoM descent damping** `f22a72f`, `9ac42b8`, `71de5e7` — zero the
  pitch/roll integrators at CoM capture, velocity-damp the auto-descent. These killed a
  real CoM-driven lateral runaway. Keep.
- **LDG parks on calibrated ground contact** `6e16e6b` — the parked detector had gated on
  an orphan `groundClear=1.0`, so the FCS stabilized *on the ground* (thrusters firing at
  rest — part of the "random thruster firing" report). Now gates on calibrated
  `meas.onGround`. Correct, keep.
- **EMRCVR emergency recovery** `5e0ec2d…dcf3de9` — >75° tilt trip → pilot lockout →
  active righting → altitude restore → clean handback; abort on any disarm. Independent of
  hover dynamics (only triggers at extreme attitude). Sound state machine. Keep.
- **Tilt-braking (pitch + roll) + brake button** `0aef6a6…325fd22` — brakes by *tilting*
  the craft, i.e. it drives the **attitude** actuators (the well-behaved, always-spooled
  path), not the lateral thrusters. So braking authority is not spool-limited. Keep.
- **Trim flip-guard + forward-only trim** `4180675…2866d96`, `285db54` — bounds the
  nose-down accel feedforward (fade + authority floor so it can't starve the pitch
  stabilizer). Correct, keep. Preserves the wanted nose-down-on-acceleration behaviour.
- **Faster climb/descend authority** `e831360` — raised per-mode vertical authority. The
  vertical loop drives lift thrusters (spooled) so it is not spool-limited; this is safe.
  Keep.
- **Config overhaul + schema-v2 logging** — non-control-path; no effect on flight
  dynamics. Keep.

### RE-EVALUATE — right idea, wrong sequencing (the lateral story)

The lateral hold was retuned **three times in a week**, each attempt chasing the previous
attempt's regression, none recognising the actuator ceiling:

1. `f6136f8` **"aggressive strafe default bumps"** (2026-09-05) — raised lateral gains for
   snappier strafe.
2. Rate-command redesign `ea62ab0` (2026-09-06) — sway became a **rate command while
   held** and **retired the `swayLead` leash**. The leash had bounded the setpoint
   excursion; without it, at the bumped gains the hold could drive the duty into
   saturation. Diagnosed at the time as "retired swayLead left error unbounded → saturating
   PD → ±16 divergence."
3. Velocity-limited cascade `aebd6fd…22ed701` (2026-09-07) — replaced the saturating PD
   with `ks·(clamp(ka·err,±vmax) − vel)` to bound momentum. **Still limit-cycles today**,
   because bounding momentum does not address the spool lag, and the retune raised
   stiffness to Kp=0.3 and coupled damping to it.

None of these three is "wrong" in isolation. The cascade is a reasonable structure; the
rate command is a reasonable feel model; faster strafe is a legitimate goal. The problem is
they were all **controller-side responses to an actuator-side limit**, applied without the
actuator diagnosis in hand. That diagnosis is §4.

*(Note: dropping the integrator in the cascade is NOT a behavioural regression — baseline
already ran `ki=0` on sway/surge, so no integral was active.)*

---

## 3. Answer to "should we revert?"

**No — and a revert would not even fix the lateral drift.** Because the drift is
actuator-rooted (§4), reverting to the baseline PD would only be more stable insofar as it
is *gentler* (lower gain + leash) — it would reintroduce the sluggish, sloppy lateral feel
you were trying to get rid of, and it would drag back the runaway/flip and stuck-bank bugs
that the week's keep-list fixed. The correct move is forward and targeted:

1. Keep the entire KEEP list (§2) — it is the bulk of the week's work and it is sound.
2. Fix the **actuator ceiling** (§4/§5) so fast *and* stable lateral becomes possible.
3. Re-tune the lateral hold with the ceiling raised; optionally restore a light leash for
   graceful setpoint handling.

---

## 4. The actuator ceiling (why every "faster lateral" retune destabilised)

Traced through Create Propulsion / Create Simulated source and confirmed against the
flight's per-thruster output columns:

- **The flight already drives thrusters continuously** — `tools/flight.lua` →
  `hover.buildLoop` uses the 16-step `fcs/actuate/level.lua` (`setPower(0..15)`), *not*
  sigma-delta. So "switch to continuous throttle" is a non-fix; it is already continuous.
- **The thruster spools thrust 0 → full over 10 ticks (0.5 s) on every 0→on transition**
  (`AbstractThrusterBlockEntity.getStartupProgress`, `STARTUP_DURATION_TICKS=10`); it fades
  over 0.5 s on every on→0 transition.
- **The lateral thrusters are unidirectional** (`mixer/level_flight.lua`: `YFL/YRL` push
  +x, `YFR/YRR` push −x; surge = `MAIN` fwd, `FRL/FRR` reverse). So on **every sway
  reversal** the newly-commanded bank goes from level 0 → ~5 and must spool up from *zero
  thrust* over 0.5 s, while the old bank fades (0.5 s of residual wrong-way push). The
  restoring force is therefore **delayed and mis-phased at exactly the reversal points** →
  negative net damping → growing oscillation. The flight's thruster columns show the active
  bank flipping sides each half-cycle, confirming this.
- The velocity sensor (`velocity_sensor`, Create Simulated) is **instantaneous** (1-tick
  finite difference), so it is NOT the lag; it has a 0.05 m/s deadband. Position is
  dead-reckoned `∫vel`. `LOWEST_POWER_THRESHOLD` does **not** gate thrust (only used by the
  damage model), so there is no 0.333 thrust deadband.

**Consequence:** direct lateral thrust has a hard bandwidth ceiling set by the 0.5 s spool.
Below it (gentle, damping-dominant, leashed — i.e. baseline) the hold is stable. Above it
(the week's stiffer, faster, leash-free retunes) it limit-cycles. You cannot tune your way
past this; you must remove the spool-on-reversal.

**Why lift/attitude are immune:** lift thrusters are banded permanently on (never level 0),
so they stay spooled and linear. The fix for lateral is to make the lateral banks behave
the same way.

---

## 5. Recommended fix & sequencing

**Primary fix — keep the lateral banks warm (idle bias).** Never command level 0 on the
opposing lateral banks; hold both at a small floor (≥1) so they stay spooled, and modulate
the **differential** (left − right) for net force. This is exactly what makes lift/attitude
stable, applied to the yaw-ring and surge thrusters. It removes the spool-on-reversal lag,
which raises the lateral bandwidth ceiling — so the "faster strafe" you want becomes
achievable *and* stable. Considerations to design through:
- The yaw ring is shared between sway and yaw; the idle floor must be **yaw-symmetric** so
  it adds no net yaw torque.
- Surge's `MAIN` vs `FRL/FRR` oppose along one axis; idling both wastes a little thrust
  fighting itself — size the floor to the minimum that prevents fade.
- Small continuous fuel cost; acceptable for a hover platform, but expose it as tunable.

**Alternative if idle-bias proves impractical:** lean translation onto **tilt** (the DRN
approach — pitch/roll the craft to move, using the always-spooled attitude actuators)
rather than direct lateral thrust. This contradicts the CPL "stable platform, no tilt"
design intent, so it is a fallback, not the default.

**Sequencing:**
1. (Free, now) In-world sanity check: drop LDG `ka`/`swayVmax` via BIT/CONFIG — the limit
   cycle should shrink, confirming the ceiling story before any code.
2. Build the keep-warm actuator layer (TDD), lateral + surge banks.
3. Re-tune the lateral hold with the ceiling raised; restore a light leash if wanted.
4. In-world verify; then raise strafe speed to taste.

**Do NOT** start any of this until the design is brainstormed and approved — this audit is
input to that decision, not a licence to build.
