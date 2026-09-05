# EMRCVR — emergency attitude-recovery mode

**Date:** 2026-09-06
**Branch:** `feat/emrcvr`
**Status:** approved design, ready for implementation plan
**Origin:** the "extreme-attitude / control-loss auto-recovery" future safety item flagged during the fix #3
brainstorm (DAMPED is oscillation-only, not a righting failsafe). Now being built.

## Goal

When the craft's attitude exceeds a hard limit, the FCS must take over instantly, lock out the pilot/UI,
and drive the craft back to a stable, level hover — **even from a fully tipped-over / inverted state**,
persisting until stable (no give-up timeout). The only human abort is shutting the FCS off.

## Attitude measurement (verified — enables inverted recovery)

`meas.pitch`/`meas.roll` come from the Create Simulated gimbal (`backend.lua:53-54`,
`gimbal.getAngles() * gimbalScale`). The gimbal computes each axis as `atan2(down.z, -down.y)` /
`atan2(down.x, -down.y)` on the craft's down-vector
(`Simulated GimbalSensorBlockEntity:118-119`) → **full ±180° range** (radians after `gimbalScale`).
So an inverted craft reads ~±π and the recovery error `sp(0) − meas` drives the short way back to level.
**Caveat (accepted):** a *perfectly*-balanced inversion is a measure-zero singularity that reads ~(0,0);
any real perturbation reads the true angle. Not handled; physically negligible.

## Design — a `flight.lua` latch + a `loop.lua` mode

EMRCVR spans two layers (like the DAMPED contrast it mirrors):

- **`fcs/runtime/flight.lua` owns the latch** — the only place that can skip `pilot:update`, reject UI
  commands, feed recovery setpoints, and manage entry/exit. Detection + state machine live in `step`.
- **`fcs/runtime/loop.lua` gets an `EMRCVR` mode** — the mirror of DAMPED: DAMPED *zeros* attitude
  demands (passive, to break an oscillation); EMRCVR must let attitude correction run at **elevated
  authority** and must **suppress DAMPED** (so the osc detector can't zero the very correction righting
  the craft).

### Detection (`flight.lua:step`, engaged only)

Each engaged tick, before the pilot/comAuto branch:
`tilted = |meas.pitch| > tripAngle OR |meas.roll| > tripAngle` (default 75° = 1.309 rad).
Gate on **airborne** — `meas.onGround ~= true` (a grounded 75° is a craft resting/tipped on the pad or a
sensor glitch; only LDG reads onGround, so other modes are always "airborne"). If tilted & airborne &
not already latched → **enter EMRCVR**. EMRCVR **overrides comAuto** (autopilot is suspended while latched).

### While latched (recovery)

- **Pilot input skipped**; forced recovery setpoints fed to the loop each tick:
  - `pitch = 0`, `roll = 0` (level).
  - `heading = meas.heading` (hold current → yaw PID's D-term arrests any spin; no chase).
  - `swayPos = meas.swayPos`, `surgePos = meas.surgePos` (freeze translate; the loop arrests drift).
  - **Two-phase altitude:** while steeply tilted (`max(|pitch|,|roll|) ≥ levelBand`, default ~30°),
    `altitude = meas.altitude` (err≈0 → heave≈hoverDuty; all authority to leveling, no wasted sideways
    heave-blast). Once `< levelBand`, `altitude = emrcvrAlt` — the altitude **captured at trip time** —
    so the craft climbs back to where it was if it fell during the tumble.
- **Aggressive righting:** on entry, save the scheme's pitch/roll `kp` and the loop `caps`, then set an
  aggressive recovery set — `kpAtt` (default 0.6, vs 0.10) and `capAtt` (default 0.8 rad, vs 0.2). At 75°
  that rails ~full righting torque; past 90° it stays railed and eases only near level. `kd` unchanged
  (damps the spin). Restored exactly on exit (mirrors the comAuto ki save/restore pattern,
  `flight.lua:_restoreComKi`). `loop:setEmrcvr(true)` sets the mode + suppresses DAMPED.
- **Telemetry:** `snapshot.mode = "EMRCVR"` (top priority — above PARKED/DAMPED/GROUND/NORMAL) so the
  PFD/UI show it; a `snapshot.emrcvr` boolean too.

### Command gating (`flight.lua:handleCommand`, while latched)

- **Blocked** (return false): `flightMode`, `masterMode`, `gndSafety`, and all other flight/config/
  autopilot commands (`positionHold`, `comAuto`, `setCom`, `flightTrim`, `fuel`, `paramsWatch`,
  `clearDamped`).
- **Allowed:** `fuelPump` (ENG SW) and `engage`/`disengage`. **`disengage` is the sole abort** — it is
  the shutdown button if EMRCVR ever misbehaves; the hardware fuel relay + `gndSafety` interlock remain
  the physical override. (`disengage` clears the latch via the normal disengage path.)

### Exit — "stable hover achieved"

When `|pitch| < exitAngle` AND `|roll| < exitAngle` (default 10° = 0.175 rad) AND horizontal drift
`hypot(surgeVel, swayVel) < maxDrift` (default ~2 blk/s), sustained for `dwell` (default ~0.5 s):
1. Restore the saved `kp`/`caps`; `loop:setEmrcvr(false)`.
2. **Always re-apply master → CPL and flight → PRECISION** (unconditionally — verified safe: re-applying
   a mode you're already in just runs `loop:setActive`→`scheme:reset` (fresh integrators) + `pilot:setMode`
   (centered tilt/throttle) + `pilot:reset`, which is exactly the clean slate wanted post-recovery, so
   **no mode-check needed**). Reuse the same internal transitions `handleCommand`'s `flightMode`/
   `masterMode` branches use (factored into helpers so the exit and the command path share them).
3. `pilot:reset(meas)`, clear the latch → hand back to the pilot in a level PRE/CPL hover.

Hysteresis: 75° in / 10° out → no chatter.

### `loop.lua` EMRCVR mode

- Add `Loop:setEmrcvr(b)` → `self._emrcvr`.
- In `cycle`'s mode block: skip the osc trip when `_emrcvr` (`tripped = (not self._emrcvr) and osc:update(...)`)
  and set `self.mode = self._emrcvr and "EMRCVR" or (tripped and "DAMPED" or grounded and "GROUND" or "NORMAL")`.
  The `if self.mode == "DAMPED"` zeroing block is unchanged (EMRCVR never enters it → attitude correction
  flows through at the elevated gains flight set). Heave is governed by the two-phase `sp.altitude` above,
  so no special EMRCVR heave handling is needed in the loop.

## Config / tunables

New top-level `emrcvr` block in `fcs/io/tuningdefaults.lua` (mode-independent safety params, like `osc`):

```lua
emrcvr = {
  tripAngle = 1.309,  -- rad (75°): enter threshold
  exitAngle = 0.175,  -- rad (10°): recovered threshold
  maxDrift  = 2.0,    -- blk/s: max horizontal drift to count as "stable hover"
  dwell     = 0.5,    -- s: stable-hold before exit
  levelBand = 0.5,    -- rad (~30°): below this, restore captured altitude (else hold hover)
  kpAtt     = 0.6,    -- aggressive recovery attitude kp
  capAtt    = 0.8,    -- aggressive recovery pitch/roll cap (rad)
},
```

Threaded to `flight.lua` (via its deps/config, same wiring `osc` uses to reach the loop; a live setter so
BIT/CONFIG edits apply without reboot). **Exposed as live-tunable BIT/CONFIG rows** — a new **global
"EMRCVR" screen** in the tuning menu (a sibling of the mode buttons, like the existing COM / AUTO COM
screens, `bitconfig/tuning.lua`): **TRIP ANGLE**, **EXIT ANGLE**, **MAX DRIFT** (the operator's three).
`dwell/levelBand/kpAtt/capAtt` ship as internal defaults (not rows).

## Testing

- **`loop.lua`:** `setEmrcvr(true)` → `mode=="EMRCVR"`, attitude demands are NOT zeroed (contrast a DAMPED
  test), osc trip is suppressed while emrcvr; `setEmrcvr(false)` restores normal mode logic.
- **`flight.lua` (new `test_flight_emrcvr.lua`):**
  - Trip: a step with `meas.pitch=80°` (airborne, engaged) latches EMRCVR; `snapshot.mode=="EMRCVR"`;
    pilot input (held keys) is ignored (setpoints are the recovery ones, not pilot-driven).
  - Grounded 80° does NOT trip; disengaged does not trip.
  - Recovery setpoints: pitch/roll sp = 0; while `>levelBand` altitude sp = meas; `<levelBand` altitude sp
    = the captured trip altitude; drift frozen.
  - Gain/caps: entry mutates scheme kp/loop caps to the aggressive set; exit restores the exact saved values.
  - Command gating: while latched, `flightMode`/`masterMode`/`gndSafety` return false; `disengage`/`fuelPump`/
    `engage` still act.
  - Exit: once `|pitch|,|roll|<exitAngle` & drift`<maxDrift` for `dwell`, latch clears, master=CPL &
    flightMode=PRECISION applied, `pilot:reset` called; a below-dwell stable window does NOT exit yet.
  - comAuto override: an active comAuto is suspended while latched.
- **inverted:** a `meas.pitch = 170°` step produces a large negative pitch demand (drives toward level),
  not zero — confirms recovery isn't limited to <90°.
- **config/BIT-CONFIG:** `emrcvr` defaults resolve; the 3 EMRCVR rows present + apply writes
  `emrcvr.tripAngle/exitAngle/maxDrift` clamped; live setter updates flight's thresholds.

## Build / verify

Dual gate (source + dist), manifest regen. `basalt-render` the new EMRCVR tuning screen. In-world:
tip the craft past 75° (and fully flip it) and confirm it locks out input, rights to a level hover,
climbs back to altitude, then hands back in PRE/CPL; confirm FCS-disengage aborts; dial the 3 thresholds.

## Out of scope
- Any change to normal-flight control laws, DAMPED (kept for oscillation), or the brake/tuning work (shipped).
- Terrain-aware recovery / obstacle avoidance. Recovering a perfectly-balanced inversion (singularity).
- A dedicated EMRCVR audio/annunciator beyond the `mode` telemetry (UI can style the existing mode field).
