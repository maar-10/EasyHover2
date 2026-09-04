# CRU extended flight — fixes roadmap

Master roadmap for the batch of FCS issues found in the 2026-09-04 "CRU extended" test flight.
Each numbered fix becomes its own spec → implement → dual-gate → merge (subagent-driven), in the
order in Part 2. This doc is the shared reference across those branches.

---

## Part 1 — Source

**Flight log:** `eh2 flight log CRU extended test.txt` (EasyHover2 project root, 1.48 MB, 6453 rows,
461 s: ~2m30s CRU flight + a few minutes of landing). fcslog CSV, 67-col schema (sparse-diff format).

**Operator's report (verbatim):**

> Okay, there is a flight log in the EasyHover 2 project root. It has CRU extended in its name. Please
> read that log, analyze it carefully. It is the flight log of about 2m30s CRU flight time and a
> couple more minutes of landing process. Several issues to discuss, and some tweaks. Most importantly,
> over the whole flight, there were severe roll issues. Nothing flight breaking. But enough to limit
> maneuverability/effectiveness. It seemed like the FCS got stuck in 5-15° bank angles and just held
> the bank instead of leveling. Sometimes dozens of seconds long. And the overall stabilitly of
> leveling was pretty rough. A lot of wobble and shaking. Like i said, nothing that made me/the FCS
> lose control. But it wasnt graceful and certainly not helpful in maneuvering. Thats the base FCS
> issue that bothers me alot right now.
>
> Next, the second big issue, this time, even in CRU mode, the craft didnt want to brake properly at
> all. You should be able to see where i was deccelerating out of forward thrust and into braking
> (holding S), and it took dozens of seconds before the craft came to a stop. And it didnt even
> attempt to pitch up in order to use the lift thrusters to brake now, even though we wanted to keep
> it for CRU mode.
>
> Then, a couple issues that are probably tuning related. Yaw is still extremely slow. It needs to be
> way faster in all modes except LDG, especially in CRU. Strafing is also to slow in CRU. And PRE
> needs faster climb/descend. Also, climb/descend needs way more snappy controls. It should
> climb/descend while holding down climb/descend. But almost immediatly hold the altitude when
> releasing, without bouncing back/overcorrecting back. Same for yaw (even in its slow state currently,
> it isnt snappy enough and steers back).
>
> In addition to these findings that need to be addressed, please also bring up any issues/errors/
> critical things you find yourself. :)

**Operator directives (follow-up):**
- **CRU has NO speed cap.** The four 2×2 lift thrusters + pitch-braking/aerobraking must be able to
  stop even a 270 blk/s top speed. A (manageable) brake *distance* is acceptable — braking authority,
  not a governor, is the answer.
- **Loop jitter is deferred.** 14 Hz (logging on) is deemed plenty for a stable FCS; revisit only if
  needed after the base issues are fixed (better with logging off).

---

## Part 2 — Analysis, verdicts, and ordered action plan

Data reconstructed from the sparse-diff CSV (parser in scratchpad). Engaged = 5212 ticks / 398 s.
Whole-flight facts: surgePos span **16,124 blk**, swayPos span **1,728 blk**, peak surgeVel **272 blk/s**
(velocities are real, validated against position). No DAMPED trips, no NaN, no fuel interlock.

### 1. Roll stuck in banks — VERDICT: missing roll integral (`ki_roll = 0`)  *(primary)*
Evidence: ~60 s of 398 s in sustained banks (5–26°). In a 17 s hold at −7.8° (t=139–156): `sp_roll=0`
(level commanded), `sat_roll=0` (cap 0.2, using 0.014 — huge unused authority), roll demand is a
constant tiny `P_roll≈0.014`, `D_roll≈0`, and it never grows. With `ki_roll=0` the P-only loop cannot
cancel a steady roll disturbance (lateral CoM/lift asymmetry) → equilibrium standing bank held
indefinitely. Pitch shares `ki_pitch=0` (same failure with any standing pitch offset).
**Fix:** add roll (and pitch) integral with conditional-integration anti-windup (the altitude `iBand`
pattern), so standing banks/pitch are cancelled without winding up during active maneuvers; likely a
modest `kp_roll` bump. Highest-value change.

### 2. Sway railed 53% + 1.7 km lateral drift — VERDICT: symptom of #1
`sat_sway` 2766/5212 (53%); during it `D_sway≈−1.95` (cap 0.9) — the sway controller maxed fighting
lateral slide from the tilted lift vector of the standing banks. **Expected to largely resolve once
#1 lands.** Re-measure after #1 before touching sway tuning.

### 3. CRU braking doesn't work — VERDICT: design gap (throttle can't reverse)
At the 272 blk/s decel (t≈211) the craft **coasts on drag only**: `dSurge=0`, `FRL/FRR=0`,
`ff_pitch=0`. Cause (`fcs/input/pilot.lua:145-151`): CRU throttle is clamped to **[0, max]** — holding
S only ramps MAIN down to 0, never negative, so there is no active brake and no negative surge demand
to drive the trim brake-lean (hence no pitch-up-to-brake).
**Fix:** let CRU's S go past zero into an **active brake** — a negative throttle/surge demand that
fires the frontal thrusters AND drives the trim brake-lean (pitch-up aerobrake with the 4 lift
thrusters, which per operator must be sufficient to stop even 270 blk/s over a manageable distance).
**No speed cap** (per directive).

### 4. Speed governor — VERDICT: not wanted
Craft hit 272 blk/s / 16 km. Per directive, CRU stays uncapped; braking authority (#3) is the answer.
No action beyond #3.

### 5. Yaw too slow — VERDICT: tuning (`leadCapHeading` caps the rate)
Peak yaw rate only **17°/s**; `leadCapHeading=0.45` bounds the steady turn rate. Raise
`leadCapHeading` (+ `headingRate`) for all modes except LDG, most for CRU.

### 6. Yaw not snappy ("steers back") — VERDICT: release-capture tuning
The yaw release-edge capture exists (`yawStopLead=0.15`, `pilot.lua:158-163`) but still overshoots.
Tune `yawStopLead` down and/or `kd_yaw` up so it stops where released.

### 7. Strafe slow in CRU — VERDICT: tuning (after #1)
`swaySpeed=5, swayLead=10`. Raise for CRU — but the sway controller is currently saturated (#2), so
tune this only after #1 frees it.

### 8. PRE climb/descend faster — VERDICT: tuning
Bump PRE's `alt.kp` / `leadCapVert` further than the 2026-09-04 climb change.

### 9. Climb/yaw "snappy, hold on release, no bounce" — VERDICT: needs an altitude release-capture
Climb bounces because there is **no altitude release-edge capture**: while held, the setpoint leads by
`leadCapVert`; on release that lead persists so the craft climbs it out → overshoot → pulled back →
bounce. Add a release capture that snaps `sp.altitude` to current + a tiny stop-lead on release
(mirror the yaw capture). Pair with the yaw capture tuning (#6).

### 10. Loop jitter — VERDICT: deferred (per directive)
`dt` mean 73 ms, p99 154, max 574 (~14 Hz, logging on). Roughens all loops / adds wobble, but deferred.

---

## Ordered action plan

1. **Base stability** — roll + pitch integral (anti-windup). Fixes #1, most of #2 and the wobble.
   Lands first because it changes how everything else feels (re-tune rates on the stabilized craft).
2. **CRU active braking** — reverse/brake throttle → frontal thrusters + trim pitch-up aerobrake (#3).
   No speed cap (#4).
3. **Snappy release** — altitude release-capture (#9) + yaw release-capture tuning (#6).
4. **Rate tuning pass** — yaw rate (#5), CRU strafe (#7), PRE climb/descend (#8). Last, on the
   stabilized craft; re-measure sway (#2) here.

Each step: brainstorm → spec → subagent-driven implement → dual-gate → merge → in-world verify.
