# Remove tilt-to-brake (forward-only trim) except CRU/DRN

**Date:** 2026-09-04
**Branch:** `tune/brake-no-pitch`
**Status:** approved, ready to implement

## Problem (greenhouse-pad fcslog, braking event t≈903–905)

Braking pitches the nose up hard (+28° measured) in modes where it shouldn't. The "Pitchable"
tilt-to-brake scheme was **deferred by design** (`docs/FCS_CORE_DESIGN.md:300`); braking is meant to
be the dedicated **frontal thrusters**, craft level. Log evidence (surgeVel 7.2→0):

```
t=903.0 pitch +5.9°  dPitch +0.002  P_pitch -0.010 D_pitch -0.067  ff_pitch +0.08(railed) dSurge -0.97
t=904.5 pitch +28.0° dPitch -0.075  P_pitch -0.049 D_pitch -0.036  ff_pitch +0.01          dSurge -0.09
sp_pitch = 0 for the entire flight (0/2021 nonzero ticks)
```

Mechanism: `sp_pitch` is always 0 (FCS told to hold level). During hard braking a **physical brake
reaction** pitches the nose up; the pitch loop correctly commands nose-down (P+D ≈ −0.078); but the
**trim feed-forward rails at +0.08 nose-up** (`ff = trimDir·trimGain·surge`, dSurge≈−1 → +0.08 floor),
which **cancels the correction** → net pitch demand ≈ 0 → the craft pitches to +28° unopposed. The
trim isn't commanding the tilt — it's **disabling the FCS's attempt to stop it**.

## Fix — forward-only trim (brake half blocked) except CRU/DRN

The trim's forward-lean half (nose-down for the default `trimDir=−1`) is legitimate (holds level
under forward thrust). The brake half (nose-up) re-creates the deferred tilt-to-brake and cancels
the level-hold. Block the brake half where not wanted.

- **New per-mode `feel.brakeTrim`** (bool): `true` = symmetric (forward + brake lean); `false` =
  forward-only (brake half clamped to 0). Base default **false**; **CRUISE = true**, **DRN = true**;
  PRE/MAN/LDG inherit **false**.
  - DRN is moot for the trim (it forces `demands.surge = 0`, so `ff = trimDir·gain·0 = 0`); DRN brakes
    by the pilot's own pitch tilt, unaffected. Set `true` anyway to document intent.
  - CRU keeps the symmetric lean (wanted — cruiser brakes by leaning).

### Edits

**`fcs/runtime/loop.lua`**
1. `Loop:setTrim(dir, gain, authority, fadeStart, fade)` → add 6th arg `brakeTrim`; store
   `self.brakeTrim` with legacy default **true** (symmetric) when nil (so existing 5-arg callers/tests
   keep the old symmetric behavior). Use an explicit nil check, not `or` (brakeTrim is a boolean —
   `false or true` would wrongly flip it).
2. In `Loop:cycle`, AFTER the existing flip-guard fade+floor clamp (the `if ff > ffCap ... end` line)
   and BEFORE `self._ffPitch = ff`, insert the forward-only gate:
   ```lua
   -- Forward-only trim (brakeTrim off): the trim's brake-direction (opposite trimDir -- nose-up for
   -- the default -1) cancels the pitch loop's level-hold during hard braking, letting a physical
   -- brake reaction pitch the nose way up (log 2026-09-04: +28deg). Where brakeTrim is off
   -- (PRE/MAN/LDG) block that half so braking stays level (frontal thrusters brake); CRU/DRN keep
   -- the full symmetric lean.
   if not self.brakeTrim then
     local dir = self.trimDir or 0
     if dir < 0 then if ff > 0 then ff = 0 end
     elseif dir > 0 then if ff < 0 then ff = 0 end end
   end
   ```
   `self._ffPitch` then stores the gated value (truthful logging), `demands.pitch` adds it.

**`fcs/runtime/flight.lua`**
3. `Flight.new`: after the `trimFade` seeder (line ~55-59), add a `brakeTrim` seeder (boolean-safe —
   default **true** when the descriptor's feel has no `brakeTrim`):
   ```lua
   brakeTrim = (function()
     local d = deps.registry and deps.registry.byId and deps.registry.default
       and deps.registry.byId[deps.registry.default]
     local b = d and d.feel and d.feel.brakeTrim
     if b == nil then return true end
     return b
   end)(),
   ```
4. `flightMode` branch: after the `self.trimFade = ...` refresh (line ~117), add a boolean-safe refresh:
   ```lua
   if d.feel and d.feel.brakeTrim ~= nil then self.brakeTrim = d.feel.brakeTrim end
   ```
5. All three `setTrim` call sites (lines ~118, ~127, ~311) — append `self.brakeTrim` as the 6th arg:
   `self.loop:setTrim(self.trimDir, self.trimGain, self.trimAuthority, self.trimFadeStart, self.trimFade, self.brakeTrim)`.

**`fcs/io/tuningdefaults.lua`**
6. Base `feel`: add `brakeTrim = false` (near the trim block).
7. `DEFAULTS.modes.CRUISE.feel.brakeTrim = true` (with the other CRUISE feel overrides).
8. `DEFAULTS.modes.DRN.feel.brakeTrim = true` (with the DRN feel block).
   (PRE/MAN/LDG inherit base false — no lines needed.)

## Testing

**`tests/test_loop_trim.lua`** (loop mechanics):
- `brakeTrim=false`: with `trimDir=-1`, a braking surge demand (negative → raw ff nose-up, +) →
  applied `ff` clamped to 0 (no nose-up); a forward surge demand (positive → ff nose-down, −) → ff
  unchanged (forward lean kept). Assert `demands.pitch`/`diag().ffPitch` accordingly.
- `brakeTrim=true`: both directions pass through (the flip-guard fade/floor still bound magnitude) —
  braking ff stays nonzero nose-up.
- Legacy: `setTrim(dir,gain,authority,fadeStart,fade)` (5-arg, no brakeTrim) behaves symmetric
  (nil→true), so the existing brake-direction trim is unchanged for old callers.

**`tests/test_tuning_modes.lua`**: `feel.brakeTrim` resolves false for PRECISION/MAN/LDG, true for
CRUISE/DRN.

**`tests/test_flight*.lua`**: `flight.lua` threads `brakeTrim` into `setTrim` (6th arg) on boot +
mode switch (extend the existing capturing-fake-loop test from the flip-guard task).

Manifest-sync gate after `fcs/**` edits (`bash tools/run_gen.sh`). Source gate, dist rebuild
(`node tools/build.mjs`), dist gate — all green.

## Not live-tunable (noted)

`brakeTrim` is a per-mode boolean; the BIT/CONFIG tuning UI is numeric-row-based, so it ships as a
default, not a live toggle. Fine — it's a mode-behavior switch, not a fine-tune.

## Residual caveat (out of scope, verify in-world)

Freeing the pitch loop should cut the +28° dramatically. If a physical brake reaction still pushes
some nose-up past what the loop holds in PRE/MAN/LDG, a follow-up could add an active nose-down brake
correction (or raise pitch authority) — decide from a targeted post-fix braking fcslog.
