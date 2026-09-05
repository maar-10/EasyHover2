# CRU active braking + generalized tilt-braking + brake button (fix #3)

**Date:** 2026-09-04
**Branch:** `fix/cru-braking` (suggested)
**Status:** approved design, ready for implementation plan
**Roadmap:** `docs/superpowers/plans/2026-09-04-cru-flight-fixes-roadmap.md` (fix #3)
**Handoff:** `docs/superpowers/plans/2026-09-04-fix3-cru-braking-HANDOFF.md`
**Builds on #1:** `docs/superpowers/specs/2026-09-04-attitude-leveling-design.md` (the aggressive
roll+pitch leveling integral this design assumes is holding attitude)

## Problem (from the CRU extended flight log)

In CRU the craft **will not actively brake**. Two root causes:

1. **Throttle can't reverse / surge never arrests.** CRU surge is `policy.surge=="throttle"`
   (`registry.lua:20`). The throttle is clamped `[0, max]` (`pilot.lua:149`) and, critically, CRU
   *bypasses the surge position loop* — `cruise.lua:10` does `d.surge = sp.surgeThrottle`, and the
   pilot pins `sp.surgePos = meas.surgePos` every tick (`pilot.lua:110`). So holding **S** only ramps
   MAIN down to 0, and on release the craft **coasts on air drag** (validated: surgePos ran 16,124
   blocks, swayPos — which *is* leashed — arrested at 1,728).
2. **No aerobrake.** The trim feed-forward is `trimDir·trimGain·demands.surge` (`loop.lua:87`). With
   `demands.surge = throttle ≥ 0`, braking drives throttle→0→`ff`→0 (log: `ff_pitch=0`, `FRL/FRR=0`).
   The lift-thruster pitch-up brake never fires.

The plant is already capable: `mixSurge` (`mixer/level_flight.lua:42`) maps `surge < 0` →
`FRL`/`FRR` frontal thrusters; a negative surge *demand* would fire them today. And #1's now-aggressive
pitch/roll integral can *hold* a commanded attitude. #3 generates the right demands and reworks the
trim from an output feed-forward into an attitude **setpoint** the #1 loop holds.

## Design overview — a directional tilt-brake vector, layered on thruster arrest

Braking authority must follow the **horizontal velocity vector**, not a fixed axis (operator's
yaw-90°-at-200-blk/s case: after a yaw the momentum is lateral, so pitch-only braking loses all
authority). The craft frame carries `surgeVel` (fore/aft) and `swayVel` (lateral); together they are
the drift vector. The FCS tilts the lift vector to oppose that drift, **decomposed into `sp.pitch`
(fore/aft) + `sp.roll` (lateral)** — full 4-lift-thruster braking authority in any horizontal
direction.

**Drift speed:** `s = sqrt(surgeVel² + swayVel²)` (current speed, craft frame).

Three stacked layers:

1. **Directional thruster arrest — every mode, always (CPL).** The surge/sway translate loops fire
   the frontal/side thrusters against drift; the `−kd·vel` term rails to full thrust at speed. Craft
   stays **level**. This already runs in the position modes; **CRU gains it at throttle 0** (below).
   Below the tilt-brake engage speed this is the *only* braking.
2. **Auto tilt-brake — CRU / MAN / DRN, above the engage speed.** On top of layer 1, a nose-into-drift
   tilt (pitch+roll + lift thrusters), scaling with `s`, held as an attitude setpoint the #1 loop
   holds. **Off in PRE / LDG** (precision/landing stay level; they should never reach these speeds).
3. **Manual brake button (typewriter CTRL) — every mode, while held.** Maximum-aggression brake +
   station-hold, overriding the master mode (arrests even under DCPL). Below the engage speed:
   aggressive lateral-thruster hold, no tilt. Above it: the steeper button tilt curve. **Release is
   instant** → the craft falls straight back to the auto behavior (which may still be a large tilt if
   still fast — no jump to level).

### The brake curves

`θ_engage = 30 blk/s`, `θ_sat = 100 blk/s` (both live-tunable). `lerp` clamps to the endpoints.

| Source | `s < 30` | `30 → 100 blk/s` | `s ≥ 100` |
|---|---|---|---|
| **Auto tilt-brake** (CRU throttle-0; MAN/DRN hands-off) | `θ = 0` — thrusters only, level | `θ = lerp(15°→30°)` | `θ = 30°` |
| **CTRL button** (all modes) | `θ = 0`; **aggressive lateral-only hold** | `θ = lerp(15°→45°)` | `θ = 45°` |

`lerp(a→b)` = `a + (s − 30)/(100 − 30) · (b − a)`. Note the intentional **step from 0 to the 15°
minimum at exactly 30 blk/s** — per operator. If it jolts in-world we smooth the engage; flagged as a
feel item, not a code decision.

Angles in rad: 15° = 0.2618, 30° = 0.5236, 45° = 0.7854.

### Tilt-brake vector decomposition

Magnitude `θ` from the curve; direction opposes the drift, split by the velocity components so the
**total tilt magnitude stays `θ`** regardless of drift direction:

```
if s > eps and θ > 0:
    sp.pitch_brake = ±θ · (surgeVel / s)     -- nose-up brakes forward motion
    sp.roll_brake  = ±θ · (swayVel  / s)     -- bank brakes lateral drift
```

**Signs are pinned by a unit test, not asserted here** — a wrong sign accelerates instead of brakes,
so the test is the authority. Expected physical behavior the test encodes: moving **forward**
(`surgeVel>0`) → **nose-up**; drifting **right** (`swayVel>0`) → bank so the lift vector pushes
**left**. (Frame reference for the implementer: in `mixer/level_flight.lua`, `corners()` gives
`FL=h+p+r`; positive pitch demand raises the front pair = **nose-up**; positive surge demand → MAIN
forward; positive sway demand → right. Derive the two signs from these and lock them with the test.)

`sqrt(pitch² + roll²) = θ` — verify in the test.

## Where each piece lives

### `pilot.lua` — computes ALL brake/attitude setpoints (new home of the "trim")

The pilot already owns `sp.pitch`/`sp.roll`, the mode policy, the tilting/hands-off state, the master
drift flag (`driftArrest`), `meas.surgeVel`/`meas.swayVel`, and now `held.brake`. So the entire
tilt-brake computation is a pilot concern. It composes with the existing setpoint logic:

- **Non-tilt modes (PRE/CRU/LDG):** today `sp.pitch, sp.roll = 0, 0` (`pilot.lua:143`). Replace the
  hard 0 with the computed tilt-brake vector (0 when not braking).
- **Tilt modes (MAN/DRN):** today `sp.pitch, sp.roll = self.tilt.*` (the pilot's tilt). The tilt-brake
  is injected **only when hands-off tilt** (the existing `tilting` predicate, `pilot.lua:120`, is
  false) — while the pilot tilts, they own attitude and the brake stands down, so the FCS never fights
  the tilt-to-fly.

**Engage conditions (auto tilt-brake):** the axis must be *arresting* (not commanded) — i.e. the same
condition the thruster arrest uses:
- CRU: `throttle == 0` (forward cruise `throttle > 0` never auto-brakes — coasting is the cruise).
- MAN/DRN: hands-off tilt (`not tilting`).
- **AND** `driftArrest` (CPL). Under DCPL the craft is allowed to drift → no auto brake (matches the
  existing drift law). Speed `s > θ_engage`. Mode's `feel.tiltBrake.enabled`.

**Brake button (`held.brake`):** overrides the master mode — forces the arrest + tilt regardless of
`driftArrest`, in every mode. Uses the button curve (45° max) where `tiltBrake.enabled`; in PRE/LDG
(disabled) the button still commands the **aggressive lateral-thruster station-hold** but **no tilt**.
"Aggressive hold" = force the surge/sway setpoints to the current position and let the thruster loops
arrest at full authority (the `−kd·vel` term already rails at speed; the P term plants it once stopped).

### CRU surge at throttle 0 — arrest instead of bypass

`cruise.lua`: keep the throttle bypass **only while pushing forward**; at throttle 0, let the inner
position loop's surge output through so the craft arrests (and its negative demand fires the frontal
thrusters):

```lua
function Cruise:update(sp, m, dt, freeze, sat)
  local d = self.inner:update(sp, m, dt, freeze, sat)
  local thr = sp.surgeThrottle or 0
  if thr > 0 then d.surge = thr end   -- forward cruise: throttle bypasses the position loop
  -- thr == 0: keep the inner surge loop output (arrest + frontal brake)
  return d
end
```

`pilot.lua` (throttle branch, currently `sp.surgePos = meas.surgePos` unconditionally at `:110`):
- `throttle > 0` → keep pinning `sp.surgePos = meas.surgePos` (so the moment throttle hits 0 the
  arrest holds the *current* position — stops where you are).
- `throttle == 0` → **stop pinning**; leash `sp.surgePos` toward the current position like the other
  modes so the surge loop arrests + holds station. Honors the master drift law: under DCPL + hands-off
  the existing drift rule (`pilot.lua:126`) relaxes it (coast); under CPL it holds (arrest). The brake
  button forces the hold regardless.

### DRN — directional thruster authority when hands-off

DRN is `translate = false` today (`registry.lua:23`) — the leash block is skipped so sway/surge
setpoints freeze at reset. New behavior: **when hands-off tilt (and CPL, or brake button)**, DRN
arrests drift with the directional thrusters + tilt-brake, exactly like the others; **while tilting**,
the pilot owns attitude and the arrest/brake stands down. Implementation keeps DRN's `translate=false`
(no translate *keys*) but lets the arrest path run when hands-off — the surge/sway loops hold the
current position and the tilt-brake injects as above. (The Drone scheme already runs the full inner
translate loop — `drone.lua:18` — so this is a pilot-setpoint change, not a scheme change.)

### `loop.lua` — retire the output feed-forward trim (comment out, preserve)

The trim moves to `pilot.lua` as a setpoint, so the `ff` block in `Loop:cycle` (`loop.lua:76-108`,
the `ffRaw`/fade/floor/`brakeTrim` computation and `demands.pitch = demands.pitch + ff`) is no longer
applied. Per operator: **comment it out cleanly, do not delete** — the forward-acceleration nose-down
lean it produces currently oversteers but also keeps the craft out of a loop under high acceleration;
we may re-enable it. `luamin.minify` strips all comments (`tools/build.mjs`), so the commented block is
**zero bytes in `dist/`** — confirmed.

- Comment out the `ffRaw … demands.pitch = demands.pitch + ff` computation, with a clear banner
  explaining it is the preserved forward-accel lean and how to re-enable (uncomment; it composes as an
  output bias on top of the new setpoints — do not run both the lean *and* a forward-accel setpoint or
  they double).
- **Keep `self._ffPitch = 0`** set (the `diag`/fcslog reader reads it — `loop.lua:137`) so logging
  stays valid with the lean off.
- **Keep `Loop:setTrim` and its plumbing** (`flight.lua` seeders + 3 `setTrim` sites) intact — it only
  stores params, is harmless dormant, and the commented lean needs it to re-enable. No behavior while
  the lean is commented.

### Input — the brake button

`keymap.lua`: `brake` is a momentary boolean, not an axis+dir. Add one special-case so both input
paths (`resolve` poll + `events.lua` `flagFor`) set `held.brake`:

```lua
function M.flagFor(map, code)
  local m = map[code]
  if not m then return nil end
  if m.axis == "brake" then return "brake" end          -- momentary; no dir
  return FLAG[m.axis] and FLAG[m.axis][m.dir] or nil
end
```

Bind CTRL in **both** layouts (brake works in every mode): add `[keys.leftCtrl] = {axis="brake"}` to
`M.default` and `M.drone`. `keys.leftCtrl` exists in CC:Tweaked.

**In-world verification owed:** the Create Simulated Linked Typewriter only forwards keys bound to its
frequency and we poll `getPressedKeyCodes` (per `minecraft-mod-docs`). Confirm `leftCtrl` is bindable/
forwarded in-world; **fallback** = an unused letter key (e.g. `keys.c`) if not. This is a wiring
verify, not a code blocker.

## Config / tuning (`fcs/io/tuningdefaults.lua`)

New `feel.tiltBrake` block (base, disabled), enabled per mode:

```lua
tiltBrake = {
  enabled     = false,   -- base off  → PRE (reads top-level) and LDG stay level-braking
  engageSpeed = 30.0,    -- blk/s: below this, thrusters only (level)
  satSpeed    = 100.0,   -- blk/s: tilt reaches its max angle here
  minAngle    = 0.2618,  -- rad (15°): tilt at the engage speed
  maxAngle    = 0.5236,  -- rad (30°): auto max at/above satSpeed
  buttonMax   = 0.7854,  -- rad (45°): brake-button max at/above satSpeed
}
```

- `CRUISE`, `MAN`, `DRN`: `feel.tiltBrake.enabled = true` (deep-copy base then flip, matching the
  `brakeTrim` pattern). `PRE`/`LDG` leave it false.
- **Live-tunable:** expose `engageSpeed`, `satSpeed`, `minAngle`, `maxAngle`, `buttonMax` as BIT/CONFIG
  FEEL rows (like the existing trim rows) so the curve is dialable in-world with no reboot.
- The old `feel.trimGain/trimDir/trimFadeStart/trimFade/trimAuthority/brakeTrim` stay in config (the
  commented lean reads them if re-enabled). No values change.

## Coupling: `caps.pitch/roll` are torque caps, not angle caps

`caps.pitch/roll` bound the pitch/roll **demand** (differential torque), *not* the achieved angle
(`attLimit=0.6` is only the comauto/profile abort threshold — `tuning.lua:14` — not a live clamp). To
actually *hold* 30–45° nose-into-drift, the attitude loop needs enough torque headroom. CRU's is only
**0.2 rad**; MAN/DRN have 0.4/0.5. Expect to **raise CRU `caps.pitch`/`caps.roll`** so the loop can
reach/hold the brake angle — left as an **in-world tuning step** (make the caps live-tunable if not
already), not a fixed spec value, since the right number depends on the craft's thrust/mass. The spec
ships the curve; the hold strength is tuned on the real craft.

## Interactions (must not regress)

- **#1 leveling integral** (`ki=0.05, iBand=0.35` in PRE/CRU/LDG): the tilt-brake sets `sp.pitch`/
  `sp.roll` to a large value (up to 0.79 rad) — **outside** `iBand` (0.35). So during a hard brake the
  integrator does **not** wind up on the transient (conditional integration gates it off, `pid.lua:23`);
  P/D drive the brake, I only trims near-level. Correct by construction — assert it in a test.
- **DAMPED** (`oscillation.lua`) keys on measured pitch/roll **sign-flips past a deadband**, not
  absolute angle — a steady 45° hold produces no crossings → **no false trip**. Assert with a test that
  feeds a constant large angle and shows no trip.
- **Master mode CPL/DCPL:** auto brake only under CPL (`driftArrest`); DCPL coasts. Button overrides.
- **comAuto/profile:** unaffected — comAuto forces `held={}` (so `held.brake` is never set during
  autopilot) and drives its own setpoints; the tilt-brake is gated behind pilot hands-off/CRU-throttle
  which comAuto does not exercise. Verify a comAuto tick still zeroes as before.
- **`Pilot:reset`/`setMode`:** clear any brake state the same way tilt/throttle are cleared on
  transition (`pilot.lua:29,39`) so a disengage/mode-switch can't strand a brake setpoint.

## Testing (TDD)

`tests/` (mirror existing suites — `test_pilot*`, `test_tuning_modes`, `test_scheme_*`, `test_pid`):

1. **Curve** (pure function): a `tiltBrakeAngle(s, {engage,sat,min,max})` helper returns 0 below 30,
   `min` at 30, `max` at/above 100, linear between; button variant reaches `buttonMax`. Boundary values
   at 30 and 100 exact.
2. **Vector decomposition + signs:** given `surgeVel`/`swayVel` and a θ, the produced `sp.pitch`/
   `sp.roll` (a) have magnitude `sqrt(p²+r²)==θ`, (b) **oppose** the drift (the physical sign cases:
   forward→nose-up, right-drift→bank-left). This test **is** the sign authority.
3. **Pilot engage gating:** auto tilt-brake fires only when CRU `throttle==0` / MAN·DRN hands-off,
   under CPL, above engage speed, in an enabled mode; **not** when throttle>0, tilting, DCPL, below
   speed, or in PRE/LDG. `held.brake` overrides master mode and forces the arrest; button in PRE/LDG =
   lateral hold, no tilt.
4. **CRU arrest:** at `throttle==0` with a forward `surgeVel`, `d.surge` from `cruise.lua` is
   **negative** (fires frontal, drives brake); at `throttle>0`, `d.surge==throttle`. Pilot leashes
   `sp.surgePos` at throttle 0 (holds station) and pins to meas at throttle>0.
5. **DRN hands-off arrest:** hands-off + CPL → surge/sway arrest + tilt-brake engage; tilting → stand
   down (pilot owns attitude).
6. **Keymap brake flag:** `resolve`/`flagFor` set `held.brake` for the CTRL code in both layouts; a
   non-brake code is unaffected.
7. **#1 integral anti-windup under brake:** a `sp.pitch` beyond `iBand` does not accumulate the
   integrator (existing `pid.lua` behavior, re-asserted in the brake context).
8. **DAMPED no-false-trip:** constant large pitch (no oscillation) does not trip the detector.
9. **Loop lean commented:** with the `ff` block commented, `demands.pitch` equals the scheme's pitch
   output (no feed-forward added) and `_ffPitch==0` in `diag`. (Guards against a stray re-enable.)
10. **Tuning resolve:** `tiltBrake.enabled` true for CRU/MAN/DRN, false for PRE/LDG; curve params
    resolve to the defaults.

**Golden** (`tests/modes_golden_data.lua`): the scheme's first-tick output is unchanged when not
braking (tilt-brake is 0 at rest). Verify no golden regen is needed; if a case shifts, regen via
`tools/capture_precision_golden.lua` inside CraftOS-PC.

## Build / verify

Dual gate: `bash tests/run_headless.sh` (source), `node tools/build.mjs` + `bash
tests/run_headless_dist.sh` (dist); regen manifests with `bash tools/run_gen.sh` after any `fcs/**`
edit (source gate has a manifest-sync check). Review (subagent) → `git merge --no-ff` → push →
in-world verify.

**In-world checklist:**
1. CRU: accelerate, release W (keeps cruising), press S to throttle 0 → craft brakes to a stop and
   **holds station**, frontal thrusters + nose-up aerobrake visible; no speed cap (stops from 200+).
2. Yaw 90° at speed → brake decomposes into **roll** (bank into the drift), not just pitch.
3. CTRL button: instant hard brake + plant; **release → instant** return to normal (still-large tilt
   if still fast, no snap to level). Below 30 blk/s = firm lateral hold, no tilt.
4. MAN/DRN: hands-off at speed brakes (tilt), tilting flies (no fight). DRN thrusters arrest hands-off.
5. Tune `caps.pitch/roll` (CRU) up until the 30–45° hold is achieved; tune the curve (engage/sat/
   angles) to feel.

## Out of scope (this fix)

- Snappy release (#9 altitude capture) + yaw capture tuning (#6) — next.
- Rate tuning: yaw (#5), CRU strafe (#7), PRE climb (#8) — last, on the stabilized craft.
- **Extreme-attitude / control-loss auto-recovery in hand-flown modes** — surfaced during this
  brainstorm (DAMPED is oscillation-only; there is no "force-level past N°" in manual flight). A
  **separate future safety item** — add to the roadmap, not built here.
- Re-enabling / retuning the forward-accel lean (kept commented).
- Loop jitter (deferred per directive).
```