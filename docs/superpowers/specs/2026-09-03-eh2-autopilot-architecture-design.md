# EasyHover 2 — Autopilot architecture

**Date:** 2026-09-03
**Status:** Architecture agreed. Not an implementation spec. No code, no FCS/config wiring, no writing-plans until the current EH2 config overhaul and in-world tests/tweaks are done.
**Do not use EasyHover 1 as a source.**

When implementation is actually next: brainstorm any still-open extras in §9 if they should be v1, then writing-plans. Do not reopen locked §§1–7 unless the operator does.

---

## 1. What A/P is

A fully fledged **robotic pilot** on its **own advanced CC:T PC**.

- Simple holds through **full route execution** and **auto-takeoff / auto-land**.
- Reads **FCS snapshots** (and fuel flow / endurance) as feedback.
- Flies by **emulated pilot inputs**: virtual stick + only the cockpit commands it is allowed to use.
- Does **not** reach into FCS control math. That is the modularity seam.
- **Now:** thruster hovercraft only.
- **Later (interface only):** rotor drones, helicopters, VTOL planes, jets, airships. No logic for those now; the adapter boundary must still be real.

Human makes the craft flight-ready. A/P can fly it and can make it safe/parked.

---

## 2. Computers

```
  engines / GND-safety OFF / FCS ENGAGE     <-- human only
                 |
                 v
  [FCS PC]  inner loop, local typewriter, actuators
       |  snapshot + fuel
       v
  [A/P PC]  mission layer  -->  hovercraft adapter
       ^                         |
       | fix + wpt/route store   | virtual stick
       |                         | + allowed commands
  [NAV PC]                       v
                            [FCS PC]  (as if a pilot)
       ^
       | selections / reported A/P state
  [UI PC]  cockpit A/P page (ops)
           A/P PC shell = boot / BIT / log only
```

| PC | Job for A/P |
|---|---|
| **FCS** | Inner loop. Accepts virtual stick + allowed commands. Emits snapshots + fuel. Notices typewriter breakout (stick lives here). |
| **NAV** | Only GPS + waypoint/route store. A/P is a **client**, like the cockpit NAV page. |
| **UI** | Operational A/P panel (modes, knobs, CONNECT, switches). Paints **reported** A/P state only. |
| **A/P** | Brain. New Suite role. Own boot phase. Does not own GPS or waypoint files. |

**A/P never:** engine/fuel-feed, FCS engage, GND-safety OFF, powering the CC:T PC, owning GPS, owning the waypoint database.

---

## 3. Two layers on the A/P PC

### Mission layer (airframe-agnostic)

- Function interlocking (holds, WPT, RT, POS).
- CONNECT / DISCONNECT / master ON/OFF / breakout policy.
- NAV client.
- Jobs: hold these; go to this WPT; fly this route; take off; land at this pad on this heading.
- Fuel **display** (flow + time remaining). Refuse/bingo is **not** in this architecture — see §9.

### Hovercraft adapter (this airframe only)

- **Master mode: CPL only.** On CONNECT, set CPL if needed.
- Flight-mode schedule: **LDG** (TO / on ground, and again when about to autoland) → **CRU** (enroute) → **PRE** (approach / get into landing position) → **LDG** (vertical land).
- Virtual stick for this craft's axes.
- Hover-VTOL TO/LAND, optical flare, land-heading align, optional park.
- VSPD auto = envelope-limited max climb/descend ("as fast as possible without crashing").

A future jet/airship is a **new adapter**, not a rewrite of holds/WPT/RT.

---

## 4. Arming, CONNECT, override

1. **A/P ON/OFF** — start/stop the A/P **program**, never the CC:T PC (CC:T auto-boots on right-click). OFF→ON = boot phase and **reset selections**.
2. **CONNECT / DISCONNECT** — take or release control **without** resetting selections. Typewriter **hotkey** toggles this.
3. **Stick breakout (default ON)** — any manual flight input → DISCONNECT (idle, still master-ON). A switch disables breakout for ride-along.

Boot defaults: no holds, no WPT/RT, disconnected, TO/LAND off.

---

## 5. Functions (cockpit A/P page)

**Combinable holds:** ALT HLD, HDG HLD, SPD HLD. Capture current snapshot, then knobs:

- HDG knob, SPD knob.
- ALT knob + **VSPD** knob (auto = envelope max; set = rate cap).

**SPD quantity:** GPS ground speed; SAS (body-forward) fallback with annunciation if NAV is dead.

**WPT / RT:** unset HDG and POS. ALT/SPD may stay. If those holds are off:

- WPT: climb to waypoint **minimum height**; **never descend** except autoland when in position and slow.
- RT: current **leg height** (climb or descend); hold until next leg; adjust only if the next leg differs.

**Height priority:** ALT HLD always wins if selected, then RT leg height, then WPT height.

**POS HLD:** exclusive vs every other mode (and vice versa). Capture current NAV fix. Station-keep here.

**Auto TO / Auto LAND:** independent overlays, any mode.

- Alone: take off or land **here**.
- With WPT/RT: fly the plan; autoland at the WPT, or the **last waypoint of the route**.
- LAND waits until **in position and slow**, aligns to a **land heading** in PRE, then LDG descent, flare on down optical, optional park (NO-OP gated).

**Example:** pilot GND-safety off + FCS engage → RT + TO + LAND → CONNECT → A/P sets CPL → LDG takeoff to height → CRU along route → PRE into landing position at land heading → LDG autoland → optional park.

---

## 6. Degrade (honesty)

| Failure | A/P does |
|---|---|
| NAV dead / stale fix | Keep ALT/HDG/SPD from FCS snapshot if selected. **Disconnect WPT, RT, POS, LAND-at-pad** and say so. |
| FCS snapshot lost | DISCONNECT. Cannot fly blind. |
| Human stick (breakout on) | DISCONNECT, keep selections. |
| After LAND, park switch ON | Disengage FCS + GND safety ON. If switch OFF, leave FCS as the human left it. |

Not obstacle avoidance. Routes/WPT heights must clear terrain by design. Down optical is for flare / on-ground, not a forward look.

---

## 7. A/P PC shell vs cockpit

**Shell (A/P PC):** boot, dependency check on the wired craft network, status, NO-OP-gated logging/instrumentation, ON/OFF of the program.

**Cockpit page (UI PC):** every operational control — holds, knobs, WPT/RT, TO/LAND, CONNECT, master ON/OFF, breakout switch, park-on-land switch, land heading.

Existing POS HOLD / CLR DAMP on that page stay as **FCS** buttons until a later UI pass decides whether POS HOLD is replaced by A/P POS HLD.

---

## 8. Left for the implementation spec

Do **not** design these until EH2 base is feature-complete and this A/P work is actually next:

- Exact modem channels, virtual-stick packet shape, how FCS mutes the typewriter while CONNECT'd and still detects breakout.
- Fuel path: snapshot field vs A/P reading tanks the way the UI does (display is in-scope; bingo is not).
- How land heading is stored (A/P setting vs waypoint field).
- Default WPT/RT speeds when SPD HLD is off (need a number/source).
- Whether today's FCS POS HOLD and A/P POS HLD are the same button.

**Suggested build order when we return:** (1) A/P PC role + boot/shell + snapshot/NAV client, (2) virtual-stick + CONNECT/breakout, (3) combinable holds + knobs, (4) WPT then RT, (5) hovercraft TO/LAND adapter. Each is its own spec/plan.

---

## 9. Extra decisions — discuss after EH2 base is feature-complete

Parked until current testing/tweaks (and the config overhaul) are done. **Not part of the architecture just agreed.** Next A/P brainstorm after that should settle:

| Topic | Intent (unsettled) |
|---|---|
| **Fuel-aware refuse / bingo** | A/P already **reads** flow and endurance. Later: whether it **refuses** a WPT/RT that it cannot finish, and what bingo does (annunciate only vs disconnect vs fly home). |
| **Stable orbit** | A hold-pattern / orbit job around a WPT or current position. Shape, radius, direction, and how it interlocks with HDG/POS/WPT/RT are open. |
| **RTB as extra buttons** | Like TO/LAND: independent overlays, not a replacement for WPT/RT. Target (home/base type vs a selected WPT), whether it implies LAND, and interlocking with POS/WPT/RT are open. |

Also still open if they come up then: route loops; hardware knobs vs UI steppers.

---

## 10. Resume checklist

When picking this up in a new session:

1. Load workspace-session-start, Superpowers, minecraft-mod-docs, dev-permissions (ask grants).
2. Read **this** file. Do not reopen locked §§1–7 unless the operator does.
3. Confirm EH2 config overhaul + remaining tests are done enough to design connections.
4. Brainstorm §9 extras if they should be in v1, then writing-plans.
