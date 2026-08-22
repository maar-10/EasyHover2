# EasyHover 2 — Core FCS design

**Status:** design, pre-implementation. Reviewed in brainstorming by the pilot (project owner)
and a consulting developer. Every section here is *provisional and revisable until code is
written* — this document is the thing we agree on *before* anything is built.

**What this is:** the Flight Control System (FCS) that turns a Create: Simulated VTOL into a
fly-by-wire aircraft. The pilot flies; the FCS keeps the craft stable, level, and exactly where
the pilot left it.

**Relationship to EasyHover 1:** same *outcome*, rebuilt clean. v1's two failure areas — the
control loop and the inter-computer comms — are written **from scratch**. Concepts and hard-won
*lessons* carry over; **no v1 FCS / PI(D) / mixer / comms code is reused.** NAV + GPS beacons are
reused; UI *layout* is kept familiar but its comms is rebuilt; features (sensor calibration, CoM
leveling) are re-implemented fresh.

---

## 1. Scope

### In scope — the core FCS
A craft that **flies flat** and holds everything the pilot isn't actively moving:

- **Attitude:** hold pitch = 0 and roll = 0 (level). Stabilization only — the pilot does *not*
  command tilt in the core.
- **Altitude:** hold the pilot's last commanded height.
- **Heading:** hold the pilot's last commanded heading.
- **Horizontal position:** hold station — brake residual drift to zero.

Pilot flight inputs (all as *setpoints*, see §2): **surge** (forward/back), **sway** (left/right),
**yaw** (turn), **heave** (climb/descend).

### Deferred (designed-for, not built yet)
- Manual pitch/roll as a pilot input ("banking"/"aerobatic" mode).
- A **"pitchable"** control scheme that tilts the lift thrusters to propel/brake forward.
- NAV/GPS absolute station-keeping and autopilot (drift-free position hold, waypoints).
- Precision-mode braking, fuel-type profiles, the 4 side proximity sensors.
- Config schema-versioning + a migrator (additive merge until then, §15); a UI for the Suite (§16).

These land later as alternate **control schemes** and NAV-layer features on the pluggable
architecture (§8), without disturbing the core.

---

## 2. Control philosophy — setpoint fly-by-wire

> **The FCS always owns the actuators. The pilot never drives a thruster, not even for an
> instant. Every pilot input only *moves a setpoint* (a SOLL), and the FCS is *always* closing
> the loop onto whatever the setpoint currently is.**

There is no "pilot mode" versus "hold mode" to switch between. It is *always* hold. Holding an
input just walks the target around:

- Hold **climb** → the altitude setpoint ramps upward while held; release → it stays → you now
  hold that altitude. No capture event, no mode flip.
- Hold **turn right** → the heading setpoint ramps; release → hold the new heading.
- Hold **move right** → a target-position offset ramps rightward; the FCS flies to it.

### The leash — how a position controller commands a *speed*
A translation setpoint is **never allowed to run more than a bounded lead-distance ahead of the
craft's actual position**, and that bound is tied to a configured cruise speed. Chasing a leashed
setpoint *is* velocity control: the setpoint advances at the target speed, the craft follows one
leash-length behind, and the leash caps the commanded effort. This is the safety rail that stops
"hold the button" from ever commanding infinite force.

Without GPS, the position reference is **integrated velocity** (from the velocity sensors), which
drifts slowly. For the core that is acceptable — the leash and the zero-velocity hold-when-stopped
behave well over the timescales that matter — and the reference is written to be **swappable** so
NAV/GPS later makes the hold drift-free with no control-law change.

### The decoupling rule
The FCS holds all degrees of freedom; a pilot input on an axis releases *that axis and only the
translation it is meant to produce*, while everything else — including the disturbances the
commanded axis's own thrusters dump into the others — stays pinned. Because the craft flies flat
and translation is done by dedicated thrusters (§4), most cross-coupling that plagued v1 simply
does not exist here: e.g. yawing with the lateral thrusters produces a sideways shove that the
horizontal-position hold cancels, but tilting-to-translate (and its altitude coupling) is gone.

---

## 3. The canonical frame and the binding layer

**One canonical craft body frame. Every sensor axis, every thruster, every pilot input is *bound*
to it. Nothing in the control math ever sees Minecraft's x/y/z.**

Axes (standard aircraft principal axes):

| Axis | Name | Rotation about it |
|---|---|---|
| **Lon** | Longitudinal (nose–tail) | **Roll** |
| **Lat** | Lateral (wing–wing) | **Pitch** |
| **Vert** | Vertical (up–down) | **Yaw** |

Positive senses, defined in human terms:

| Quantity | Positive means |
|---|---|
| Surge (Lon) | forward (toward nose) |
| Sway (Lat) | right (starboard) |
| Heave (Vert) | up |
| Roll | right wing down |
| Pitch | nose up |
| Yaw | nose right |

### Signs are *measured*, never assumed — the v1 antidote
v1's worst bug was a hand-derived sign convention that the simulator *shared*, so every test
passed and the craft would have braked *with* its drift on the first flight. The cure:

> **The sensor-calibration procedure empirically discovers the binding.** The pilot performs a
> known motion ("pitch the nose up now"); the FCS observes which sensor/axis/sign actually
> responds and records the binding (`gimbal.axis[2] → +Pitch`, `velocity.front → +Sway`, …). **No
> human ever writes a sign into the control law**, so the simulator cannot inherit a hand-made
> mistake — there is none to inherit.

Config allows manual bindings too, but calibration is the trusted path. The barometer carries a
**height-offset** so the loop reasons about the *thrusters'* altitude, not the sensor's.

---

## 4. The airframe — sensors and actuators

### Thrusters — 11 total, none vectoring, craft flies flat

| Group | Count | Facing | Produces |
|---|---|---|---|
| **Lift** | 4 (one per corner) | down | **heave** (collective) + **pitch/roll** (differential) |
| **Lateral** | 4 (one per corner) | sideways | **sway** (collective) + **yaw** (differential) |
| **Main** | 1 (large) | rear | **surge forward** |
| **Frontal** | 2 | forward | **brake forward / reverse** |

Each thruster is bang-bang (§7). Lift and lateral groups each do double duty — a collective
component and a differential component — separated by the mixer.

### Sensors

| Sensor | Count | Gives |
|---|---|---|
| Velocity (lateral) | 2 (front, rear) | sway velocity; **yaw rate** = front−rear difference |
| Velocity (medial) | 1 | surge velocity |
| Barometer | 1 | altitude (+ height-offset config), air pressure |
| Gimbal | 1 | pitch/roll attitude |
| Nav table + magnet | 1 | true heading (complements GPS later) |
| Optical (down) | 1 | **ON GND** / airborne state |
| Optical (sides) | 4 | proximity — *unused in core* |

### Fuel / arming
A **redstone relay** drives the smart chute feeding the fuel-pump engine. Fuel delivery is the
**arm** signal: no fuel flowing ⇒ the FCS is **disarmed** (§11). Mass ≈ 327.75 kpg, CoM-balanced
(shifts with payload). Everything above rides one Create: Simulated contraption.

### Free failsafe (design it in from day one)
A thruster hands control to the computer when a peripheral attaches and **reverts to redstone on
detach**. Wire a constant analog redstone "limp-home hover" level into the lift thrusters: inert
while the FCS is attached, and the instant the flight computer breaks, unloads, or reboots, the
craft falls back to that level instead of dropping.

---

## 5. Control architecture — the cascade

**Decoupled per-axis PI(D) in a two-tier cascade.** SISO loops (not a coupled MIMO model): they
match the pilot's mental model, tune one knob at a time, and let the *mixer* — not the controller
— carry the airframe layout.

```
PILOT INPUTS → setpoints (leashed; §2)
      │
      ▼
OUTER LOOPS (slow) — emit setpoints, never touch a thruster
   • Altitude hold        → heave (collective) demand
   • Heading hold         → yaw setpoint
   • Horizontal-vel/pos    → sway demand + surge demand
      ▼
INNER LOOPS (fast) — attitude, always level
   • Roll  PI(D) → roll moment      (setpoint 0)
   • Pitch PI(D) → pitch moment     (setpoint 0)
   • Yaw   PI(D) → yaw moment
      ▼
MIXER — the one place that knows the airframe (§7)
      ▼
PWM / ACTUATOR LAYER — demand → on/off pulses, synchronized, on-toggle only
      ▼
THRUSTERS
```

### The controller
One controller type, `u = Kp·e + Ki·∫e·dt + Kd·(filtered d(measurement)/dt)`.

- **PI is PID with `Kd = 0`** — a config value, not a code fork. When `Kd = 0` the derivative path
  is **bypassed entirely** (no filter state, no differentiation of noise), so PI is a true subset.
- Derivative is **on the measurement, never the setpoint** (no derivative kick), **low-pass
  filtered** (one per-second `alpha`).
- **Conditional integration + clamp:** freeze the integrator when the output is saturated or a
  thruster reports obstruction; hard-clamp `I` to a band. No windup.
- PID-vs-PI is settled **empirically against the sim** (§13), not by folklore. Note: bang-bang is
  prone to limit-cycling, and a derivative/rate term is the classic cure — so the core likely
  *wants* some `Kd`.

---

## 6. Rate adaptivity — no fixed time step, no hardcoded rate

The single hardest lesson from v1's timing saga, made a design rule:

- **`dt` is measured every cycle** from `os.epoch("utc")`, clamped to `[dt_min, dt_max]`. If a
  cycle overruns (a `mainThread` stall, a chunk hiccup) the integrator and derivative are
  **skipped for that cycle** rather than fed a huge `dt` — a `dt` spike through a naive PID is a
  guaranteed kick.
- **No hardcoded loop rate.** The loop frees up as much time as it can (minimal work per cycle,
  minimal `mainThread` writes — bang-bang-on-*toggle* means a steady hover barely writes) and
  fires as often per second as possible.
- **Every tunable is per-*second*, never per-*cycle*** — ramp rates, filter constants, oscillation
  thresholds, leash speeds. So the craft feels identical whether the loop runs at 3 Hz or 15 Hz;
  the rate can vary within a flight without changing behavior.
- **Graceful degradation.** Target is a high rate (~12–18 Hz looks plausible; Lua compute is
  sub-ms, the ceiling is `mainThread` writes / throttled peripheral events). It must remain stable
  at ~2 Hz. We *measure* the achieved rate with the instrumentation; we assume nothing.

The inner attitude loop should still run several times faster than the outer loops; the *ratio* is
enforced by counting elapsed time, not by a fixed schedule.

---

## 7. The mixer and PWM

### Mixer — duty cycles from demands
Each lift thruster's duty cycle *is* its effective thrust. Four corners, three demands
(schematic; actual signs are calibration-bound):

```
d_FL = H + P + R      H = collective (hover duty ≈ 1 / thrust-to-weight)
d_FR = H + P − R      P = pitch demand  (small — disturbance rejection only)
d_RL = H − P + R      R = roll  demand  (small)
d_RR = H − P − R      → each clamped to [0,1]
```

Steady level hover = all four ≈ H, with pitch/roll as tiny perturbations. Lateral group is the
same idea: collective = sway, differential = yaw. Main and frontal thrusters are single-axis.

### PWM — synchronized bang-bang
Thrusters run **full-throttle on/off**; resolution is recovered in the **time domain** (0 and
15/15 are exact grid points, so the 16-step throttle quantiser never bites — we simply never use
the middle).

**Phasing is synchronized** — all four lift pulses fire together. The tradeoff, decided
deliberately:

- Synchronized ⇒ **zero moment ripple** when duties are equal (rock-steady attitude), at the cost
  of **heave ripple** (all-on then all-off → a gentle vertical bob).
- Interleaved ⇒ smoother heave but a wandering pitch/roll moment (the craft cones).

For a craft whose job is to stay flat, attitude steadiness wins; the bob is absorbed by inertia
and the altitude loop. Moment ripple then scales only with the small differential demand.

**Writes happen on toggle only** — a thruster costs a `mainThread` tick when it changes state, not
every cycle. Commands are compared against the block's *own reported* target (`getTarget…`), never
against our record of what we sent, because a second writer can undo a write between cycles (v1
lesson).

### The one real empirical risk, and why it's low-risk to get wrong
With only **4 lift thrusters** and a possibly-low loop rate, temporal PWM is coarse, and we
*cannot* spatially average across the lift group without inducing a moment (killing one corner =
instant pitch+roll). So **vertical bob magnitude is unknown until measured** and depends on Sable's
physics we can't compute a priori. Mitigation: the **PWM/actuator layer is a pluggable module**
(§8). We ship bang-bang, **instrument the bob from day one**, and if it's ugly we swap the
modulator — sigma-delta (better at low, jittery rates), or a hybrid using the 16 discrete steps for
the steady collective and pulsing only the fine trim — **without touching any control logic.**

---

## 8. Pluggable architecture

The FCS *runtime* is generic. Only two things encode a *control scheme* — the **loops** and the
**mixer** — so both sit behind interfaces, and the runtime drives them without knowing their
internals.

```
   ┌── FCS runtime (scheme-agnostic) ─────────────────────────────┐
   │ input→setpoints · sensor→measurements · dt/timing · comms ·  │
   │ PWM actuation · write-scheduling · instrumentation           │
   └──────────────┬──────────────────────────▲───────────────────┘
        setpoints, │ measurements             │ per-thruster demands
                   ▼                          │
          ┌──────── ControlScheme ───────────┴──┐
          │ ControlLoopSet → axis demands        │
          │ Mixer          → per-thruster cmds    │
          └───────────────────────────────────────┘
```

**Interfaces**
- `ControlLoopSet:update(setpoints, measurements, dt) → axisDemands`
  (`{heave, pitchMoment, rollMoment, yawMoment, sway, surge}`). Pure math, no hardware.
- `Mixer:mix(axisDemands) → perThrusterCommands`. The *only* place that knows the airframe.

**What plugs in**

| Scheme | Status |
|---|---|
| `LevelFlight` (lift + lateral split, flat) | **the core — build this** |
| `Pitchable` (lift-thrusters tilt to propel/brake) | deferred mode |
| Test doubles (`ConstantLoop`, `RecordingMixer`, …) | for headless debugging |

Two payoffs: (1) a future scheme is a new `{loops, mixer}` pair with zero runtime changes; (2) a
`RecordingMixer` proves exactly what the loops commanded, or a `ConstantLoop` proves mixer + PWM in
isolation — the substrate for real TDD and the antidote to v1's "a net number is not evidence about
a part."

The PWM/actuator modulator is likewise a swappable module (§7).

---

## 9. Comms — FCS ↔ UI ↔ NAV

**v1's root cause, designed against:** telemetry was produced *by* the 1.6 Hz control cycle, so the
cockpit ran at 1.6 Hz and clicks felt swallowed. **The rule: comms cadence is decoupled from
control cadence.**

```
        ┌──────── FCS (flight PC) ────────┐
        │ owns typewriter + flight monitor │
        │ tasks: control · input · telem-tx│
        │        command-rx · health        │
        └───┬──────────────────▲────────────┘
 telemetry  │                  │ commands
 (state,    ▼                  │ (mode/config/nav,
 latest-win) ┌── UI PC ──┐     │  ack+retry)
             │ renders    │─────┘
             │ btns→cmds  │   ┌── NAV PC ──┐
             └────────────┘   │ NAV + GPS  │
                              └────────────┘
```

1. **Single writer, shared snapshot.** The control loop is the only writer of flight state; comms
   tasks only *read* a snapshot. One source of truth, no races.
2. **Parallel tasks, not one loop** (`parallel.waitForAny`): control, input, telemetry-out,
   command-in, health. A stall in the control task (mainThread writes) does not stop the others
   servicing their own timers. We **prove** the decoupling with the instrumentation (cockpit
   cadence vs control cadence), not by assuming the scheduler.
3. **Telemetry is a STATE stream** — whole snapshot at a fixed cadence, **latest-wins,
   fire-and-forget.** A dropped packet is harmless; the next supersedes it. No ACKs, no ordering.
4. **Commands are EVENTS** — ID'd, **ACK'd + retried** — but the UI **shows only reported state.**
   A button press never updates the display; the display changes when the *next telemetry snapshot*
   reflects it. The ACK only stops the retry; telemetry is the truth. (This is the "no optimistic
   UI" rule, enforced structurally.)
5. **Health/heartbeat, and the FCS flies alone.** Every node beats; a missing UI/NAV is
   *annunciated*. Since pilot input is **local to the FCS**, losing the UI or NAV must never
   destabilize the craft.

**Transport:** raw `modem` on well-known channels (telemetry / command / health), small versioned
table messages. Predictable, filterable, trivially instrumented; no rednet host/lookup layer needed
on a fixed 3-node topology.

---

## 10. Pilot input

Device-agnostic from line one. The FCS consumes only abstract **control intents** — `surge, sway,
yawRate, climbRate` (and mode/config actions) — and a config-driven mapping layer translates
physical inputs into them. Swapping input hardware later is a config change, never a control-code
change.

- **For now:** typewriter (widest button range) in a **hybrid** input path. The original rule
  was poll-only — older Simulated emitted no typewriter events, so `getPressedKeyCodes()` was
  the only signal ("a v1 lesson"). As of Simulated 1.3.0 the typewriter *does* emit peripheral
  `key`/`key_up` events synchronously with the physical interaction (verified in-game and in the
  decompiled block entity), so input is now **event-driven pre-apply + polled authority**
  (`fcs/input/events.lua`): events land intent within a tick; the 50 ms poll remains the
  trusted re-sync. Caveat: the mod reuses CC's bare `"key"` event name — local-terminal keys
  carry a string key-name arg while typewriter events carry a boolean/nil, which is the
  discriminator the hybrid relies on.
- **Wired directly to the FCS computer** for lowest latency — pilot intent never makes a network
  hop before reaching the loop.

---

## 11. The safety contract

Each protection carries a test. Adapted from v1's hard-won set for a flat, non-vectoring,
bang-bang craft:

1. **dt discipline** (§6) — measured, clamped, integ/deriv skipped on spikes.
2. **Conditional integration + clamp** — no windup at saturation or obstruction.
3. **Derivative on filtered measurement** — no kick, no amplified noise.
4. **Rate/slew limiting** on setpoints and demands — bounds how fast the plant can be excited.
5. **Envelope limiter** — hard caps on vertical speed, yaw rate, translation speed (the leash),
   and the small pitch/roll authority. The pilot commands *within* the envelope; it is not
   negotiable by any module.
6. **Oscillation detector + auto-degrade** — count error sign-changes/second per axis; above
   threshold, cut that axis's gains (and annunciate); if it persists, drop to a **DAMPED HOVER**
   safe state. The loop watches itself and gives up authority before diverging. *The detector is
   tested too* (must fire on a deliberately over-gained run), not merely trusted.
7. **Ground-state gating** — on the ground (down optical + near-zero vertical speed): integrators
   zeroed and frozen, attitude loop idle. Prevents the "leaps on takeoff" windup.
8. **Disarm on no-fuel** — fuel not flowing (relay/master off) ⇒ hold neutral, cut demand, reset
   loops so they resume clean, do not run the mixer. (v1's "DISARMED on the ground".)
9. **Terminate is never swallowed** — a Ctrl+T arriving mid-`mainThread` call is re-raised, not
   caught by the device-fault `pcall`.

---

## 12. Instrumentation & observability

Timing instrumentation from day one, **behind a switch that is a true no-op when off** (the calls
are swapped for no-op stubs at init, so normal ops pay nothing). It covers three things v1 left
blind: **comms round-trips, control-cycle duration, and `mainThread` write cost per cycle.**

- **Telemetry is state; profiling is events.** Profiling emits discrete **spans/traces** (start /
  stop / duration) as an event stream, separate from the latest-wins state snapshots — giving real
  observability into where the milliseconds go.
- First job it earns its keep: **measuring the achieved loop rate and the heave bob** (§6, §7).

---

## 13. Testing strategy

Nothing flies until it is green headless (CraftOS-PC), per the workspace convention.

- **Plant simulator** (`tests/sim.lua`) — a vertical + pitch/roll/yaw model that *deliberately*
  reproduces the trouble-makers: bang-bang thrust, variable/jittery `dt`, sensor noise, and the
  synchronized-PWM ripple. The controller runs against it headless and the suite asserts: settles
  to setpoint within tolerance/time; **no limit cycle** (oscillation strictly decreasing); no
  windup after saturation; a `dt` spike produces no kick; the oscillation detector *does* fire when
  provoked.
- **Test doubles** (§8) isolate layers — `RecordingMixer` to pin what the loops commanded,
  `ConstantLoop` to pin the mixer + PWM.
- **Physics pinned against physics, not against the other half of the code** — every sign/direction
  test must fail when its fix is reverted (the v1 discipline that caught the shared-mistake bug).
- Mod peripherals don't exist in CraftOS-PC — they're mocked, and the mocks must be able to express
  the *physics* (e.g. an unfuelled thruster holds throttle but makes zero thrust) or a
  physical-semantics bug can't be tested.

---

## 14. Proposed module / file layout

```
EasyHover2/
  easyhover2_suite.lua  run-from-GitHub installer/updater (no self-update; §16)
  manifest.lua          generated: per-file checksums + version, per-role file lists
  docs/            FCS_CORE_DESIGN.md (this), MOD_API notes, etc.
  fcs/             the flight computer
    startup.lua
    runtime/       loop timing, dt, parallel task wiring
    control/       ControlLoopSet + PI(D) controller (scheme-agnostic controller type)
    schemes/       LevelFlight (loops+mixer); later: Pitchable
    mixer/         Mixer interface + LevelFlight mixer
    actuate/       PWM modulator(s) + write scheduler (pluggable)
    io/            sensor binding, thruster wrappers, redstone relay
    input/         intent mapping (typewriter/monitor → intents)
    comms/         modem channels, telemetry-tx, command-rx, health
    instrument/    spans/traces, the no-op switch
    config/        persisted config + calibration bindings
  ui/              renderer of reported state (layout ~ v1), btns→commands
  nav/             reused NAV + GPS
  shared/          util, log, protocol schema
  tests/           sim.lua, test doubles, per-module suites, run_headless
```

Boundaries chosen so each module is testable in isolation — the opposite of v1's 79 KB
`app.lua`.

---

## 15. Configuration & persistence

### Additive now, versioned + migrator later
- **Now — additive config.** Config is a namespaced table of values, persisted per role. On load,
  the app **merges defaults *under* the loaded config**: any key the running code expects but the
  saved file lacks is filled from its default; existing pilot values are never touched. New builds
  may *add* keys (with defaults) but must not rename or repurpose existing ones. So there is **no
  migration step and no reconfiguration on update** — a newer build sees its new keys defaulted and
  every old setting preserved.
- **Later — schema-versioned config + migrator.** Config gains a `schemaVersion`; when the code's
  schema is newer, a migrator transforms old → new (rename, restructure, derive) so even *drastic*
  structural changes never force a reconfig. We build additive now with **sound, namespaced
  structure** precisely so that future migrator starts from clean ground.

### Config is never clobbered
- **Config is not part of the code-integrity check (§16).** Telling a corrupt config from a
  legitimately pilot-changed one isn't reliably possible without overcomplex heuristics, so we don't
  try: the Suite's checksum / reinstall logic covers **code only.** Config is only ever
  additively-merged or (later) migrated — never overwritten by an update or repair.
- **Runtime handles true corruption**, separately from the Suite: if a role app can't *parse* its
  config at boot, it sets the bad file aside, regenerates defaults, and **annunciates** — rather than
  flying on garbage or refusing to boot.
- **At most one automatic config backup on disk** at a time — the latest, replacing the previous
  (no backup spam). Deliberate backups at meaningful points stay the pilot's to make.

---

## 16. Install / update Suite — IMPLEMENTED

A single tool — `easyhover2_suite.lua` — run **directly from GitHub** (`wget run …`) that installs
and updates any role on a fresh or existing PC. Stepped up from prior suites. Built per
[`docs/superpowers/specs/2026-08-07-easyhover2-suite-design.md`](superpowers/specs/2026-08-07-easyhover2-suite-design.md)
and its [13-task plan](superpowers/plans/2026-08-07-easyhover2-suite.md); full unit + e2e suites
green.

- **Engine:** `easyhover2_suite.lua` (root) — the single file a pilot `wget run`s.
- **Manifest:** `manifest.lua` (root), generated by `tools/gen_manifest.lua` /
  `tools/run_gen.sh` from the actual `require()` closure of each role's launchers
  (`tools/closure.lua`) — never a hand-maintained file list, never a directory walk. FNV-1a
  checksums per file, rolled up into one version digest; `tools/run_gen.sh --check` regenerates
  the manifest in memory and diffs it against the committed one (exit non-zero, "OUT OF SYNC" if
  stale), wired into `tests/run_headless.sh` so a forgotten regen fails the suite run.
- **Roles shipped:** `fcs` (flight computer, boots `launchers/flight.lua`) and `ui` (cockpit
  display, boots `launchers/cockpit.lua`). `NAV` from the original design sketch was not built —
  no NAV role exists yet in the manifest or the Suite.
- **Config handling:** additive, quarantine-on-corruption, **single-latest rolling backup** per
  §15 — code updates and repairs never touch a pilot's saved tuning.
- **UI:** a custom, pure-CC, single-file cockpit UI (`ui/main.lua`, `ui/render.lua`,
  `ui/dispatch.lua`, `ui/widget.lua`) with a keyboard fallback for terminals without mouse/touch
  events — no Basalt dependency for the Suite's own screens.

### It never nags about itself
The Suite **does not self-update.** It runs from GitHub each time, does its job, and exits — no "the
Suite itself is out of date" loop, ever. It changes only when we deliberately ship a new one (a fix,
a new role, or a UI-role app update per §11's build-out).

### What it does, each run
`wget run` the Suite, then:

| Situation | Action |
|---|---|
| Nothing installed | ask role (**FCS / UI**) → install that role |
| Installed, **version mismatch** | update to the manifest version |
| Installed, version matches, **files intact** | nothing to do |
| Installed, version matches, **files mismatch** (checksum) | **clean reinstall of code** (config untouched) |

- **Integrity is checksum-based** against a published `manifest.lua` (per-file sum + size, plus a
  rolled-up version digest). Trust root is **HTTPS to a pinned raw GitHub URL**; the checksum only
  answers "did this arrive intact / has a file drifted."
- **A clean reinstall replaces code files only.** Config is excluded by design (§15) — an update or
  repair never costs the pilot their tuning.
- **One rolling config backup**, latest only.

### Roles
`FCS` (flight computer) and `UI` (cockpit displays) are built and released. `NAV` (navigation +
GPS) was part of the original design sketch but was never implemented — no NAV role exists in the
manifest or the Suite today; adding one is future work, not scheduled. Each role declares its
files, directories, entry point, and config path in the manifest; the Suite installs exactly the
chosen role on that PC.

### Next project: the UI-role cockpit application
The Suite installs and updates the UI role's *files*, but the on-screen cockpit application itself
— monitor assignment per panel (including mirroring the overhead panels and flight-path markers
across monitors), and config/calibration exposed as UI menus instead of the `tools/` terminal
commands — is deliberately **deferred**, per
[spec §11](superpowers/specs/2026-08-07-easyhover2-suite-design.md#11-deferred-ui-role-application-build-out-next-project).
It is sequenced as its **own spec → plan**, after this Suite; the Suite ships whatever the UI app
happens to be at each release, so building it out does not block or depend on the Suite itself.

---

## 17. Open questions — validate in sim / in-game, don't assume

1. **Heave bob magnitude** under synchronized bang-bang (depends on Sable gravity/thrust scaling).
   → decides whether the modulator gets swapped (§7).
2. **Achieved loop rate** on the real contraption, and which peripheral events get "throttled."
   → sets the outer/inner rate split (§6).
3. **Gimbal** — axis count, order, units, sign, ship- vs world-relative. → resolved by calibration
   (§3), but probe to confirm.
4. **Velocity sensors** — units (blocks/tick vs /s) and the ~0.05 deadband in practice.
5. **PID vs PI** — settle against the sim (§5).
6. Thruster peripheral survival across assembly; re-scan/re-wrap after every assembly.
7. **Attitude disturbance-rejection limit cycle (found building the kernel).** With the seed gains, a *disturbed* pitch/roll settles into a **bounded ~0.5 rad (~29°) bang-bang limit cycle** rather than tight level — altitude hover is solid, but attitude *hold under disturbance* needs a dedicated tuning pass (more D / slower attitude loop / finer resolution — i.e. the sigma-delta or hybrid modulator from §7) before the craft flies flat against real disturbances. This is the attitude-side echo of the §7 bob question. (Roll-moment sign was inverted in the sim and is now fixed + guarded by recovery tests; see the plan's Task 8 correction note.)
8. **Pure-yaw bang-bang resolution floor (found building Plan 2).** Unlike the lift group — which modulates pitch/roll *finely* around the ~66% hover baseline — the lateral thrusters sit at **zero** at rest, so yaw corrections are coarse on/off pulses from nothing, giving a **~0.12 rad (~7°) yaw-hold floor** at the placeholder plant params. The heading *controller* is correct and converges (proven; sign verified end-to-end against the mixer), and the acceptance reached tight tolerance via a permitted `yawInertia` sim-cfg choice — but the *real* yaw-hold tightness is a hardware / finer-modulator question. Likely fixes for Plan 4 / hardware: a small standing lateral "yaw bias" baseline (so yaw modulates around a nonzero operating point like the lift group does), or the §7 sigma-delta / hybrid modulator for sub-pulse resolution.
9. **Envelope-on-demands can destabilize if set too tight (found building Plan 4's safety contract).** The envelope limiter clamps the loops' *combined moment demands* (pitch/roll/yaw/sway/surge). Set **below the loop's damping (`kd`) authority** it starves the derivative term and the axis *diverges* — a 0.05 pitch-demand cap gave |pitch| ≈ 8.8 rad, vs bounded at 0.2. So the demand-clamp is only a **coarse** safety net (keep caps comfortably above the damping the loop needs; the oscillation-detector → DAMPED HOVER is the real anti-divergence guard). A **fine** attitude/rate envelope must instead cap the pilot's **setpoints / commanded rates upstream** (which is what §11's "hard caps on commanded bank/pitch, vertical speed, yaw rate" actually means) — wire that when the pilot-input layer lands, and keep the demand-clamp only as the coarse backstop.

---

## 18. Pilot control + comms + cockpit

The complete FCS implementation (Tasks C3–D4) spans two programs and five parallel tasks, communicating over fixed modem channels.

### Programs

**FCS runtime** (`tools/flight.lua`, flight PC):
- Five parallel tasks over a single-writer snapshot (§9, §8 pattern).
- **Control task:** owns the plant — `Flight:step(dt, held, meas)` runs the loop, pilot, and mixer every cycle. Reads measurements from the backend; writes the unique snapshot.
- **Input task:** polls typewriter key codes (~50 ms cadence), resolves them to held-flags via `keymap.lua` (default: WASD move, QE yaw, RF lift), and feeds the held map to Control.
- **Telemetry task:** reads the snapshot (~100 ms cadence), frames it, and transmits on channel 101 (fire-and-forget).
- **Command task:** listens for incoming commands on channel 102, dispatches them to `Flight:handleCommand()`, and ACKs on channel 103.
- **Health task:** polls every ~250 ms and emits a heartbeat on channel 104 once per configured period (~1 s, the `health.Tx` default).

**UI cockpit** (`ui/main.lua`, UI PC):
- Three parallel tasks over received snapshots.
- **Network task:** listens on all channels (101, 103, 104), updates the latest-snapshot on telemetry, processes ACKs for command retry, marks health-link alive, and triggers redraw.
- **Touch task:** polls monitor/terminal for clicks, dispatches to button, composes a command, and sends it via the command sender.
- **Retry task:** ticks the command sender (~250 ms), resends any unACK'd commands.

A custom **immediate-mode cockpit** (ui toolkit: `cockpit`, `dispatch`, `render`, `widget`) displays only **reported state** from telemetry — the "no optimistic UI" rule enforced by design. Button presses never update the display; only the next telemetry snapshot does.

### Channel map

| Channel | Direction | Content |
|---|---|---|
| **101** | FCS → UI | Telemetry snapshot (fire-and-forget) |
| **102** | UI → FCS | Commands (event, ACK'd + retried) |
| **103** | FCS → UI | ACK (command received) |
| **104** | FCS → UI | Heartbeat / health (presence) |

### Commands (UI → FCS)

`Flight:handleCommand()` (§9) recognizes:

- **`engage`** — arm the FCS and begin stabilization. **Gated:** only honored when `gndSafety == false`.
- **`disengage`** — disarm. Resets integrators, stops the mixer, holding neutral.
- **`gndSafety{on}`** — engage ground-safety mode (interlocks armed flight; arm requires `gndSafety==false`).
- **`positionHold{on}`** — freeze the position/heading setpoints; pilot input no longer ramps them. Leashed translation becomes zero-velocity hold.
- **`fuelPump{on}`** — mirrors the fuel-pump toggle state for the cockpit display. The physical no-fuel-disarm interlock (§4 / §11) is a hardware mechanism, not enforced by this command handler.
- **`clearDamped`** — reset the oscillation detector (clears auto-degraded axis authority; §11, item 6).
- **`flightMode{id}`** — select control scheme (e.g., `NORMAL` vs planned `AEROBATIC`; deferred schemes per §1). Currently FCS-side only — no cockpit button sends this yet.

### Telemetry snapshot (FCS → UI)

`Flight:snapshot()` (runtime/flight.lua, lines 49–59) produces:

- **Status:** `engaged` (bool), `gndSafety` (bool), `positionHold` (bool), `fuelPump` (bool)
- **Mode:** `mode` (from loop state), `flightMode` (pilot-selected scheme ID string)
- **Measurements** (passthrough from sensors): `altitude`, `vSpeed`, `heading`, `yawRate`, `swayPos`, `surgePos`, `onGround` (bool)
- **Instrumentation:** `loopHz` (achieved control loop rate)
- **Fuel detail** (added by runtime wiring): `thrusterFuel[]` (per-lift-thruster fuel level, fraction of tank capacity remaining, for UI fuel gauges); `fuelMain` (mean of the available per-thruster fuel fractions, for the main FUEL gauge — there is no separate main-tank peripheral)

### Pilot input

Typewriter held-keys (polled) → `keymap.resolve()` → held-flag names (`surgeFwd`, `swayLeft`, `yawRight`, `up`, etc.) → `Pilot:update()` → setpoint ramps.

**Setpoints** (all measured in craft frame, §3):
- **Yaw:** slew `heading` at configured `headingRate` per second while held; release freezes it.
- **Lift:** slew `altitude` at configured `climbRate` per second, leashed to current altitude ± `leadCapVert`.
- **Sway / surge:** ramp position setpoints toward ±`maxLead` at configured `cruiseSpeed`; leash (§2) caps the lead distance and enforces velocity control.

**Position-hold mode:** when engaged, `Pilot:update()` returns the frozen setpoint table unchanged; pilot input does not move the targets. The leashed translation loop becomes zero-velocity hold (drift braking).

---

*Next step after review: turn this into a step-by-step implementation plan (superpowers
writing-plans), TDD module by module against `tests/sim.lua`.*
