# HANDOFF — Fix #3: CRU active braking + trim-as-setpoint aerobrake

**For:** a fresh session / other account picking up fix #3 of the CRU-flight fixes batch.
**Repo:** `C:\Users\m-kri\Claude Code\EasyHover2` — `main` at `ea8f53c` (all prior fixes merged & pushed).
**Status of this fix:** design AGREED in brainstorm, **NOT yet spec'd or implemented.** Start by
brainstorming it into a spec, then implement subagent-driven, dual-gate, merge (workflow at the end).

---

## Read these first (full plan + progress)

- **Roadmap (the master plan + all analysis + progress):**
  `docs/superpowers/plans/2026-09-04-cru-flight-fixes-roadmap.md` — Part 1 = operator report + directives,
  Part 2 = per-issue analysis/verdicts, plus the ordered action plan with ✅ status.
- **Memory:** `eh2-cru-flight-fixes` (batch overview + status), and the entangled prior fixes it links:
  `eh2-brake-no-pitch`, `eh2-trim-flip-guard`, `eh2-faster-climb`, `eh2-flight-master-mode-split`,
  `eh2-alt-windup-fix`.
- **Flight log this is based on:** `eh2 flight log CRU extended test.txt` (repo root, fcslog CSV,
  67-col sparse-diff schema; a Python reconstructor was used — see roadmap for the numbers).
- **#1 spec (just shipped, context for the pitch coupling):**
  `docs/superpowers/specs/2026-09-04-attitude-leveling-design.md`.

## Where the batch stands
- **#1 base stability (roll+pitch leveling integral)** — ✅ SHIPPED (`main` 09d7539). Added
  `ki=0.05, iBand=0.35, iMax=±0.10` to `gains.roll`/`gains.pitch` in PRE/CRU/LDG; `ki=0` in MAN/DRN.
  **In-world verify is OWED** — ideally flight-test #1 before/while building #3, since #3's pitch
  design assumes the craft now levels aggressively.
- **#2 sway rail (53%)** — expected to be a symptom of #1; re-measure in-world, don't touch sway yet.
- **#3 — THIS handoff.**
- **#4 rate tuning** (yaw/strafe/climb + snappy release) — deliberately LAST, on the stabilized craft.

---

## Fix #3 — the problem (diagnosed from the log)

In CRU the craft **will not actively brake**. At the 272 blk/s decel (log t≈211) it **coasts on air
drag only**: `dSurge=0`, `FRL/FRR=0` (frontal brake thrusters idle), `ff_pitch=0` (no pitch-up). Two
root causes, both in `fcs/input/pilot.lua`:

1. **Throttle can't reverse** (`pilot.lua:145-151`): CRU surge is `policy.surge=="throttle"`; the
   throttle is clamped to **[0, max]** — holding **S** only ramps MAIN *down to 0*, never negative. No
   active brake, and no negative surge demand → the trim brake-lean (`ff = trimDir·trimGain·surge`)
   never fires, so no aerobrake either.
2. **Surge never stabilizes** (`pilot.lua:110`): in throttle mode `sp.surgePos = meas.surgePos` every
   tick → the surge position controller sees **zero error → applies zero arresting force**. So even
   when the pilot releases S, the craft keeps drifting on momentum. (Contrast **sway**, `pilot.lua:100`,
   which is *leashed* → genuinely arrests drift. That asymmetry is why lateral stabilizes but fore/aft
   coasts — validated in the log: swayPos arrested, surgePos ran 16,124 blocks.)

Operator's framing (correct): every axis should *stabilize toward its target when the pilot isn't
actively commanding it, not fight normal input, and re-engage on release* — surge in CRU lacks this.

## Fix #3 — the AGREED design direction (from brainstorm)

Two coupled pieces, one principle ("the FCS holds the commanded target; the trim/throttle sets it"):

### A. CRU surge stabilizes / brakes when not throttling forward
Make CRU surge **arrest drift like sway does** when the pilot isn't holding forward throttle — i.e.
holding **S** (past zero throttle) commands an **active brake**: a negative surge demand that (a) fires
the frontal thrusters and (b) drives the aerobrake (below), and on release the surge **holds station**
(arrests) instead of coasting. Exact input mapping (reverse-throttle vs surge-position-hold-brake) is a
brainstorm decision. **NO speed cap** — operator directive: the four 2×2 lift thrusters + aerobrake must
stop even 270 blk/s over a *manageable brake distance*; braking authority, not a governor.

### B. Trim becomes a pitch SETPOINT (option A), not an output feed-forward
Today the trim is a bias added to the pitch *output* (`fcs/runtime/loop.lua`, the `ff` block with the
flip-guard fade/floor + per-mode `brakeTrim` gate). With #1's aggressive pitch integral now holding
`sp.pitch=0`, an output-bias trim **fights** the leveling. Rework it so the trim/aerobrake **shapes
`sp.pitch`** (the desired lean), and the aggressive pitch loop **holds that setpoint**:
- Coasting → `sp.pitch=0` → dead level.
- Forward accel → small nose-down `sp.pitch` (the UI-switchable forward-accel trim, `trimDir`).
- CRU braking → a **large** nose-up `sp.pitch` held hard = a **strong** lift-thruster aerobrake
  (this is what stops 270 blk/s).
- The flip-guard (fade/floor) and the `brakeTrim` per-mode gate move to **shaping/clamping that
  setpoint** (envelope + which modes get the brake-direction).

**BOTH** trim cases — the forward-accel nose-down trim AND the CRU brake pitch-up — are setpoint
modifiers under this design. (`brakeTrim=true` today for CRU/DRN, false for PRE/MAN/LDG — see
`eh2-brake-no-pitch`.) DRN forces `surge=0` so its surge-scaled trim is 0 anyway; DRN brakes by pilot
tilt — leave that path.

## Key code map
- `fcs/input/pilot.lua` — surge/sway leash + drift rule (`:96-126`), tilt setpoints (`:131-144`),
  CRU throttle (`:145-151`), yaw release capture (`:158-163`). **The braking input logic lives here.**
- `fcs/runtime/loop.lua` — the trim `ff` block (fade/floor flip-guard + `brakeTrim` forward-only gate)
  and `setTrim(dir,gain,authority,fadeStart,fade,brakeTrim)`. **The trim→setpoint rework lives here (or
  moves the trim into the scheme's `sp.pitch`).**
- `fcs/schemes/level_flight.lua` — `pitch = pitchPid:update(sp.pitch or 0, m.pitch, …)`. If the trim
  becomes a setpoint, `sp.pitch` is where it lands.
- `fcs/runtime/flight.lua` — trim params seeded/threaded to the loop (`:38-59` seeders, 3 `setTrim`
  sites); throttle→surge wiring for CRU.
- `fcs/io/tuningdefaults.lua` — `feel.trimGain=0.35`, `feel.trimDir` (via mode descriptor, default -1),
  per-mode `feel.brakeTrim`, `feel.cruiseThrottleRate/Max`, `feel.surgeSpeed/surgeLead`; `gains.pitch`
  now has `ki=0.05/iBand=0.35` (from #1 — the setpoint design must coexist with this integral).
- `fcs/control/pid.lua` — PID with `iBand` conditional integration (unchanged; understand it).

## Open questions to settle in the #3 brainstorm
1. Input mapping for the CRU brake: reverse-throttle range, or "throttle to 0 then S = surge-position
   brake/arrest"? How does releasing S behave (hold station)?
2. Aerobrake pitch-up: how large a `sp.pitch`, and does it scale with speed / with brake demand? How is
   it bounded (reuse the flip-guard envelope as a `sp.pitch` clamp)?
3. Trim-as-setpoint mechanics: compute `sp.pitch` from trim where? (pilot vs loop vs scheme). Ensure it
   composes with #1's pitch integral (loop holds it) and does not reintroduce the flip risk.
4. Forward-accel trim's role once the #1 integral also cancels the thrust reaction — keep it as an
   intentional lean setpoint, reduce it, or fold it in?
5. Frontal-thruster brake + aerobrake blend, and whether frontal thrusters still contribute at speed.

## Workflow (how this repo ships a fix)
Brainstorm (superpowers:brainstorming) → spec in `docs/superpowers/specs/` → implement
subagent-driven (or directly if the account hits session rate limits — that happened this session) →
**dual gate**: `bash tests/run_headless.sh` (source), `node tools/build.mjs` then
`bash tests/run_headless_dist.sh` (dist); regen manifests with `bash tools/run_gen.sh` after any
`fcs/**` edit (the source gate has a manifest-sync check) → review (subagent) → `git merge --no-ff`
to `main` → `git push origin main` → in-world verify. TDD throughout; golden baseline
(`tests/modes_golden_data.lua`) may need regen via `tools/capture_precision_golden.lua` if the scheme's
first-tick output changes (run it inside CraftOS-PC like `tests/run_focus.sh` does).

**Commit attribution is per-account** — the other account uses its OWN Claude-Session trailer / model
line, not this session's. Follow whatever attribution that session is told to use.

**Deferred (operator directive):** loop jitter (~14 Hz with logging on is deemed fine).
