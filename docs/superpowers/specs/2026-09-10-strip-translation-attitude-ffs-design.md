# Strip destabilizing translation→attitude feed-forwards (rate-robust CRU)

Date: 2026-09-10
Status: design approved (brainstorm), ready for plan

## Problem

CRU flight is unstable in normal low-thrust maneuvers (climb, forward surge, post-brake
recovery, strafe): the craft rings ±20–45° in pitch/roll for many seconds and is "nearly
uncontrollable." Flight logs (cc.lynx.rodeo/4c2643ca46, c9ae4e4e00) show it; the user
notes it was **stable at 5 Hz before recent changes**, so this is a regression, not a
loop-rate problem.

Root cause (isolated with a new closed-loop rig, see below): a **translation↔attitude
limit cycle**. To arrest surge/sway velocity the craft tilts; the tilt (lift-vector
tilt-to-translate) *creates* velocity the other way; weak attitude damping overshoots →
it rings. Three translation→attitude feed-forwards pour into this loop and amplify it:
the accel **trim** (surge→pitch), the **tilt-brake** (drift→pitch/roll setpoint), and the
**decouple** (surge→pitch, sway→roll, shipped 2026-09-09 as "first estimates").

**Rig isolation (post-maneuver ring, deg; lower = stabler; rate-independent):**

| config | pitch (after brake) | roll (after strafe) |
|---|---|---|
| ALL ON (production today) | 44 | 43 |
| decouple OFF | 37 (10Hz) / 8.5 (5Hz) | 22 |
| trim OFF | 35 | 41 |
| tiltBrake OFF | 31 | 41 |
| **decouple off + brakeTrim=false (PROPOSED)** | **9** | **19** |
| ALL OFF (fully stripped) | 9 | 19 |

Findings: the **decouple is the primary amplifier** — it *doubles* the roll ring
(22→43°; with it off the residual ~20° is the raw physical coupling, so the decouple is
**amplifying the coupling it was meant to cancel** — wrong sign/over-gained). The **trim's
brake-side lean** is the secondary pitch contributor. `brakeTrim=false` removes exactly
that brake-side contribution while keeping the wanted accel lean, and lands on the
fully-stripped result. Behavior is essentially identical at 5/10/20 Hz — structural, not
loop-rate.

## Scope

**In:**
- **Default the decouple OFF** — gains → 0 (a no-op the loop already honors). Keep the
  `setDecouple` code and the `decouple` block (commented, values preserved) so a
  correctly-signed, rig-validated version can be rebuilt later.
- **Set CRU `brakeTrim = false`** — forward-only trim (accel lean kept, brake-side lean
  dropped). Comment the reversed prior choice.
- **Commit the closed-loop rig** (`tools/simrig.lua`, `tools/simrig_run.lua`,
  `tools/run_simrig.sh`) as reusable dev tooling — the acceptance test across a Hz sweep.
- Update tests that asserted the old defaults; add one relative-invariant regression test.

**Out (deferred):**
- The residual base-cascade ring (~9° pitch / ~20° roll after stripping) — active
  velocity-damping on the tilt to push below ~20°. Decide after in-world confirms the
  stripped craft is "stable enough." Keep tilt-brake as-is this batch.
- Any decouple *redesign* (sign fix + rig validation) — future, only if the physical
  coupling proves to need active cancellation.
- Loop-rate work — out of scope by user decision (10 Hz is plenty; fix is structural).

## Design

### A. Decouple default-off (`fcs/io/tuningdefaults.lua`)

Change the `decouple` block so the gains are 0 (no-op), preserving the old values and the
authority in a comment for revival:

```lua
-- Translation->attitude decoupling FF: STRIPPED 2026-09-10 (defaulted off). It amplified the
-- coupling it was meant to cancel (rig: doubled the roll ring 22->43deg) and drove the CRU
-- limit cycle. setDecouple + the loop FF are kept (0 gains = no-op) for a future, correctly-
-- signed, rig-validated rebuild. Prior values: swayRoll=0.10, surgePitch=-0.05.
decouple = { swayRoll = 0, surgePitch = 0, authority = 0.3 },
```

The loop's decouple FF (`loop.lua:116-127`) and `setDecouple` stay untouched — 0 gains are
already a no-op there (`dcRoll = 0*sway = 0`). No code deleted.

### B. CRU forward-only trim (`fcs/io/tuningdefaults.lua`)

```lua
-- STRIPPED 2026-09-10: was true (symmetric "lean back to brake hard"). The brake-side lean
-- fed the post-brake pitch ring (rig: brakeTrim=false drops it 44->9deg). Accel lean kept
-- (forward-only, like every other mode). Revisit if a damped brake-lean is wanted later.
DEFAULTS.modes.CRUISE.feel.brakeTrim   = false
```

### C. The rig (already written; commit as tooling)

- `tools/simrig.lua` — physics sim adding the three real dynamics the base sim omits
  (spool ramp, tilt→translate coupling, off-CoM torque) + `buildStack(simParams, toggles)`
  flying the production Flight→Loop stack; `toggles = {decouple, trim, brakeTrim, tiltBrake}`.
- `tools/simrig_run.lua` — CRUISE surge/brake/strafe scenarios; `run()` returns per-phase
  peak/end pitch/roll; `report()` prints the isolation matrix across a Hz sweep.
- `tools/run_simrig.sh` — runs it headless in CraftOS-PC, prints the report.

Calibration note: sim params (`spoolTime 0.5`, `tiltTrans 1.0`, `latRoll 0.6`,
`surgePitch 0.1`, mass/inertia from `e2e_stress`) reproduce the logs' post-brake ring
(~35–45°) qualitatively. It is a *probe*, not ground truth; conclusions rest on
**relative** comparisons (config A vs B under identical physics), which are robust to the
exact params.

### D. Tests

- `test_tuning_modes.lua:117` — CRU `brakeTrim` expectation `true → false` (+message).
- `test_tuningdefaults.lua` (decouple block test) — assert the stripped defaults:
  `swayRoll == 0`, `surgePitch == 0`, `authority == 0.3` (block still present).
- `test_buildloop_modes.lua:54-55` — unchanged (asserts loop == tuning value; both 0 now).
- `test_loop_trim.lua` decouple/trim mechanism tests — unchanged (they pass explicit gains
  to exercise the retained code path; correct that they still verify the FF math).
- **New light regression test** (`test_simrig.lua`): under the rig at dt=0.1, assert the
  proposed strip rings **strictly less** than production on both axes — a relative
  invariant that guards against re-introducing a destabilizing FF, robust to exact params.
  (One scenario each; keep it light. If it proves slow/flaky in the suite, downgrade to
  tooling-only and note it.)

## Acceptance

- Rig: proposed strip rings **≤ ~10° pitch / ~20° roll** and **< production** at 5/10/20 Hz.
- Full suite green (`bash tests/run_headless.sh`), manifest in sync.
- OWED in-world: verify CRU is controllable in climb/surge/brake/strafe at low thrust; the
  decouple/brake-lean stay revivable. Then deploy (build dist + manifests, see
  `eh2-deploy-pipeline`).

## Files touched

- `fcs/io/tuningdefaults.lua` — decouple gains → 0; CRU `brakeTrim` → false.
- `tools/simrig.lua`, `tools/simrig_run.lua`, `tools/run_simrig.sh` — commit (new tooling).
- tests: `test_tuning_modes.lua`, `test_tuningdefaults.lua`, new `test_simrig.lua`.
