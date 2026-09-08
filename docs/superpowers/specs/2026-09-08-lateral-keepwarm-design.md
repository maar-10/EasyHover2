# Lateral keep-warm actuation — design

**Date:** 2026-09-08
**Status:** approved for planning
**Related:** `docs/2026-09-08-fcs-week-audit.md` (retrospective), memory
`eh2-actuator-spool-mismatch`.

## Problem

In a hover, the horizontal position hold (sway *and* surge) grows a ~10.5 s oscillation
that saturates into a ±16-block bang-bang limit cycle, while attitude and altitude stay
stable. Root cause (verified against Create Propulsion source and the flight's per-thruster
output columns, flight `487b634ca6`):

- Create Propulsion thrusters **spool thrust 0 → full over 10 ticks (0.5 s)** on every 0→on
  transition (`AbstractThrusterBlockEntity.getStartupProgress`, `STARTUP_DURATION_TICKS=10`)
  and fade over 0.5 s on every on→0 transition.
- The lateral thrusters are **unidirectional** (`fcs/frame.lua`: yaw ring `YFL/YRL`=+x,
  `YFR/YRR`=−x; surge `MAIN`=forward, `FRL/FRR`=reverse). So on **every reversal** the
  newly-commanded bank goes from level 0 → on and must spool from *zero thrust* over 0.5 s
  while the old bank fades — delayed, mis-phased restoring force → net negative damping →
  the limit cycle.
- **Lift thrusters are immune** because they run banded permanently on (~0.5 hover duty,
  `mixer/level_flight.lua`), so they stay spooled and linear. That is exactly why
  attitude/altitude are stable — and the model for the fix.

The flight already drives thrusters **continuously** through the 16-step
`fcs/actuate/level.lua` (`setPower(0..15)`), not sigma-delta; so "switch to continuous
throttle" is a non-fix. The fix is to stop the lateral thrusters ever going cold.

## Goal & scope

Keep the lateral (sway/yaw-ring) **and** surge thruster banks **warm** — never below a small
idle floor while flying — so neither pays the 0.5 s spool penalty on a reversal, exactly as
the lift thrusters already avoid it. Net commanded force is preserved to within a small
top-of-range headroom cost.

**In scope:** the actuation/mixer change for the yaw ring + MAIN + frontals, its state
gating, its tuning knobs, and tests.

**Explicitly NOT in scope (deliberate, one variable at a time):**
- No lateral-hold *re-tune* (ka/ks/vmax/leash). Those stay as-is and remain live-tunable in
  BIT/CONFIG; we verify keep-warm against the current gains first.
- No change to the lift/attitude/altitude actuation or controllers — they work; we don't
  touch them.

## Mod-source facts this design relies on

- `ThrusterPeripheral.setPowerNormalized(double 0..1)` → `ThrusterComputerHelpers
  .setThrottleNormalized` → sets `ControlMode.PERIPHERAL` + `digitalInput = clampNormalized`.
  A steady input holds steady thrust (after the one-time spool). Continuous, unquantized.
- A thruster is "operational" (stays spooled) whenever `getPower() > epsilon`
  (`updateStartupState`); any idle throttle above ~1e-6 keeps it warm.
- Thrust scales as `n × multiblockThrustMultiplier(width)` with `n = width³`
  (`ThrusterBlockEntity` line ~610). Defaults: `MULTIBLOCK_3X_THRUST_MULTIPLIER = 1.5`.
  Craft geometry: MAIN is 3×3×3 (width 3) ⇒ `27 × 1.5 = 40.5`; each frontal is 1×1×1 ⇒ `1`.
  So **MAIN : (both frontals) ≈ 40.5 : 2 ≈ 20 : 1**. This asymmetry is why surge needs the
  continuous actuator (a warm MAIN at the 16-step minimum, 1/15, already out-thrusts both
  frontals at full).
- `LOWEST_POWER_THRESHOLD = 5/15` does **not** gate thrust (only `ThrusterDamager` uses it).

## Architecture

Reuse the `Loop`'s existing lift-vs-rest actuation seam (`Loop:apply` routes `self.isLift`
ids → `pwm`, the rest → `sd`; today `sd=nil` so everything goes to the 16-step `Level`).

- **Lift group (`FL/FR/RL/RR`): unchanged** — stays on `Level` (16-step `setPower`).
- **Rest group (`YFL/YFR/YRL/YRR`, `MAIN`, `FRL/FRR`): new continuous keep-warm actuator**
  driving `setPowerNormalized` — writes only on change, concurrent dispatch, and the same
  `setFuelScale` hook as `Level`.

Keep-warm **biasing is computed in the mixer** (it owns the geometry and thrust weights).
The **`Loop` computes the effective floor from flight state** each cycle and passes it to
`mixer:mix(demands, keepWarmFloor)`.

## The math (preserves today's net force, adds warmth)

Let `F` be the keep-warm floor (0 when not flying — see gating). The fix is a **uniform
additive floor on the post-clamp mix**. Adding the same amount to opposing unidirectional
thrusters is net-neutral, so commanded force/torque is unchanged; the only cost is a small
loss of top-of-range headroom.

**Yaw ring (symmetric).** With today's per-thruster mix
`mix[id] = clamp(SWAY_DIR·sway + YAW_DIR·yaw + YAWREAR·yawRear, 0, 1)`:

```
out[id] = min(1, max(0, raw[id]) + F)      -- raw = the signed sum before clamp
```

i.e. clamp negatives to 0 (today's behaviour), then lift everyone by `F`. Every thruster
sits at ≥ F (warm through zero-crossings); the uniform lift adds **zero net x-force and zero
net yaw-torque** (verified: `Σ dir·F = 0` for both the sway pattern `+,−,+,−` and the yaw
pattern `+,−,−,+`). At `F=0` this is byte-for-byte today's behaviour.

**Surge (asymmetric — balanced floor).** With thrust weights `w_main=40.5`, `w_front=1`:

```
MAIN = min(1, max(0,  surge) + floorMain)
FRL  = FRR = min(1, max(0, -surge) + floorFront)
floorMain = (2·w_front / w_main) · floorFront          -- ≈ 0.049 · floorFront
```

The idle terms cancel in net force (`w_main·floorMain = 2·w_front·floorFront`), so surge
authority is unchanged; both sides stay warm. `floorMain ≈ 0.003` is unrepresentable at
16-step — hence the continuous actuator. The ratio `2·w_front/w_main` is a **config constant
(`mainIdleRatio`)** with the source-derived default `≈ 0.049`, tunable in-world (covers a
different craft, a server-overridden multiblock multiplier, or measured thrust).

## State gating

The `Loop` sets the floor per cycle:

- `F = keepWarmFloor` (configured) only when `armed AND airborne (not grounded) AND
  mode == "NORMAL"`.
- `F = 0` in every other state: disarmed, on-ground/parked, `DAMPED`, `EMRCVR`. Those already
  zero the lateral demand; with `F=0` the lateral thrusters are fully cold — preserving the
  established no-thrust-at-rest safety property. The disarm/cut path (`cut.lua`,
  `killThrusters`, `setThruster(id,false)`) is unchanged (`setPower(0)` still cuts).

## Tuning (BIT/CONFIG live-tune rows, per project convention)

| knob | default | meaning |
|---|---|---|
| `keepWarmFloor` | ~0.08 | yaw-ring idle throttle; **0 disables keep-warm entirely** (in-world A/B) |
| `surgeFloorFront` | ~0.07 | frontal (reverse) idle throttle |
| `mainIdleRatio` | ~0.049 | `floorMain / floorFront` balance; source default `2·w_front/w_main` |

Exposed alongside the existing sway/surge `ka/ks` rows so a single flight can A/B keep-warm
(floor 0 vs on) and trim the surge balance.

## Fuel

Honest cost: 4 yaw + 3 surge thrusters idle continuously while hovering. Bounded by a small
floor, airborne-only gating, and the `keepWarmFloor=0` off-switch. Watch it against the
endurance/LEFT readout during the verification flight.

## Testing (headless CraftOS, mocked peripherals)

- `backend:setThrusterNormalized(id, throttle)` calls `p.setPowerNormalized(throttle)` (no
  self); mock records last value per id.
- Keep-warm actuator: writes only on change; applies `fuelScale`; concurrent-dispatch
  fallback to sequential off-CC.
- Mixer, flying (`F>0`): every rest-group thruster ≥ its floor; net sway, net yaw-torque, and
  net surge equal the `F=0` mix (differentials/neutrality preserved); surge idle is
  net-zero at `surge=0`.
- Mixer, `F=0`: byte-for-byte identical to current mix (regression guard).
- Loop gating: `F=0` (all rest thrusters coldable) when disarmed / grounded / `DAMPED` /
  `EMRCVR`; `F=keepWarmFloor` only in armed+airborne+`NORMAL`.
- Golden-baseline / e2e suites stay green.

## File-level change list

- `fcs/io/backend.lua` — add `setThrusterNormalized(id, throttle)`.
- `fcs/actuate/keepwarm.lua` — **new** continuous keep-warm actuator (write-on-change,
  dispatch, fuelScale).
- `fcs/mixer/level_flight.lua` — keep-warm biasing in `mixLateral`/`mixSurge`; `mix` takes
  `keepWarmFloor`; thrust-weight/`mainIdleRatio` constants.
- `fcs/runtime/loop.lua` — compute `keepWarmFloor` from state; thread to `mixer:mix`; ensure
  `setFuelScale` reaches the new actuator.
- `tools/hover_test.lua` (`buildLoop`) — wire `sd = KeepWarm.new{…}` for the rest group; lift
  stays `Level`.
- `fcs/io/tuningdefaults.lua` + BIT/CONFIG (`ui`) — the three tuning rows.
- Tests: new `tests/test_keepwarm.lua`; extend mixer + loop tests; regen golden baseline.

## Risks / open items

- **Headroom:** at large simultaneous sway+yaw (or surge) commands, `mix+F` can top-clamp and
  shave a little differential. Negligible in hover; bounded by caps. If it ever bites under
  aggressive input, revisit with an airmode down-scale (as `mixLift` already does).
- **Surge balance accuracy:** `mainIdleRatio` default is geometry+config-derived; if MAIN's
  effective thrust differs in-world, surge will show a small steady idle drift → trim
  `mainIdleRatio` live. This is the expected first tuning step for surge.
- **Verification is in-world** (spool physics aren't in CraftOS); headless tests prove the
  math/wiring, the flight proves the cure. Log on, `keepWarmFloor` 0→on A/B.
