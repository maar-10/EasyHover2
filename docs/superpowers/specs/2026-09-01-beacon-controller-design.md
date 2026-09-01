# EasyHover 2 — GPS Beacon Controller (Design)

**Date:** 2026-09-01
**Status:** Design — awaiting operator review before implementation.

---

## 1. Motivation

A beacon disabled by an accidental `[E]` (or one that goes offline) is **invisible from anywhere but
the beacon itself** — a silent beacon simply vanishes from the mesh, and diagnosing/fixing it means a
13–19 km flight to its physical console. A **beacon controller** — one advanced PC running a Basalt 2.0
shell UI — makes the whole constellation **visible and remotely manageable** from a single screen.

The enabling insight: the beacons already run a **token-guarded broadcast command channel** — the
remote-update system (`beacon/update.lua`: `Update.command` → fail-closed `accepts` → `ack`; `beacon/
app.lua` listens + acks). The controller is a **richer client of that same trusted protocol** — no new
security surface to invent.

## 2. Goals / Non-goals

**Goals**
- See every beacon's presence + health at a glance, including **silent** ones (disabled or offline).
- Remotely issue the safe, useful beacon operations without a physical visit.
- Reuse the beacons' existing token-guarded, fail-closed command discipline.
- **Comms-hygiene clean:** passive by default; active polling only during active use.

**Non-goals**
- **No remote channel switch** — moving a beacon off the controller's channel orphans it (physical
  recovery only). Channel stays a local-console-only setting.
- Not a NAV replacement — this manages beacons; NAV consumes their GPS.

## 3. The model

### 3.1 Discovery — hybrid (passive normal, active only in DIAG)

- **Passive (normal operation):** the controller listens on the GPS channel and builds a live roster
  from heard broadcasts. **Zero added traffic.** A known beacon it stops hearing shows as `SILENT`.
- **DIAG menu (active poll):** while the DIAG page is **open**, the controller polls each known beacon
  (`query` → status-reply) on a rate-gated cadence, with a visible **"polling…" indicator**. It is a
  **NO-OP when the page is closed** — polling fires only while open. This is what distinguishes
  `DISABLED` (a silent beacon that *replies*, because `enabled` gates broadcasting, not listening) from
  `OFFLINE` (no reply at all).

### 3.2 Command set (all token-guarded)

`enable` · `disable` · `verify now` · `query status` (DIAG) · `set position` · `set interval` ·
`reboot` · `trigger update` (folds the standalone `launchers/beaconupdate.lua` into the controller).

**Deliberately excluded:** `set channel` (footgun — orphans the beacon).

### 3.3 Roster — a persisted registry (modeled on the UI monitor registry)

Mirrors the existing UI monitor-assignment registry pattern (auto-populate detected → friendly names →
list with status + assignment → never forget except manual delete):

- **Auto-populates** from heard broadcasts **and** DIAG query-all replies (disabled beacons answer, so
  the roster captures them too).
- **Persists** so a beacon that goes silent stays listed (`SILENT — last seen 6462 200 6107, 3m ago`).
- **Friendly names** — operator-labelled (`beacon-68` → `"Buddy's Base"`), stored controller-side; the
  beacon's own id is untouched.
- **Expected-position pinning** — mark a beacon's *correct* coords so the controller flags a beacon
  broadcasting a drifted position (a second line of defense beyond the beacon's own self-check).
- **Manual remove** is the only way to forget a beacon (decommissioned).

### 3.4 Protocol + auth — one channel, one secret, one gate

- **Single shared token** (the beacons' existing update token) gates **all** remote ops — control and
  update. Same trust boundary: a remote reinstall already subsumes enable/disable, so a separate control
  secret is key-management overhead with no security gain.
- **Extend `beacon/update.lua`** — same codec (`fcs.comms.protocol`) and same fail-closed `accepts`
  (token must be valid + equal) — with the new command kinds and a **status-reply** kind. A beacon only
  ever acts on a token-valid command; a stray GPS frame or bad token is ignored, exactly as today.

### 3.5 Status-reply payload (a beacon's own view of the mesh)

`enabled` · `position` · `intervalMs` · `selfCheck` (ok? + #mismatches) · `constellation` (peers heard
+ grade + error est) · `seq`/broadcast count. So one poll yields, per beacon:

```
beacon-70  ENABLED   6462 200 6107   1 Hz   self-check OK   sees 3/4 GOOD ~1blk
beacon-68  DISABLED  (replied, off)                          <- the missclick case
beacon-67  OFFLINE   (no reply)
```

## 4. UI layout (sketch — the real thing is rendered + iterated in build)

Basalt 2.0 on an advanced PC. Three views. **These are sketches; the actual layout is designed via the
basalt-render loop during implementation, not fixed here.**

**Roster (main):**
```
EH2 BEACON CONTROL          peers 3/4          token: SET
------------------------------------------------------------
> Buddy's Base   beacon-68   SILENT   6462 200 6107   3m
  North Pillar   beacon-67   LIVE     -7737 -54 7579  0.6s
  East Spire     beacon-69   LIVE      7144  65 -7266 0.8s
  South Mark     beacon-70   LIVE     -7210  64 -7260 1.0s
------------------------------------------------------------
[DIAG]  [ENABLE ALL]  [UPDATE ALL]                    [Q]uit
```

**Per-beacon detail / actions** (select a row): name/id/status/position/interval + action buttons —
`ENABLE`/`DISABLE` · `VERIFY` · `SET POS` · `SET INTERVAL` · `REBOOT` · `UPDATE` · `RENAME` ·
`PIN EXPECTED` · `REMOVE`.

**DIAG (active poll):** live per-beacon status table (§3.5 payload) with a `polling…` indicator;
closes → polling stops.

## 5. Decomposition (phases)

| Phase | Scope | Risk |
|------|-------|------|
| **P1 — protocol** | Extend `beacon/update.lua` with command kinds + status-reply; TDD the fail-closed gate for each. | Low |
| **P2 — beacon handlers** | `beacon/app.lua`/`runtime`: act on each token-valid command (enable/disable/setPos/setInterval/verify/query→reply/reboot); persist config changes; keep the FCS-safety timer discipline. | Med |
| **P3 — controller core** | Pure roster registry (persist, names, expected-pos, status merge) + command sender + status collector; TDD headless. | Med |
| **P4 — controller role** | New role: launcher, `gen_manifest` `ROLES` entry (its own closure — no FCS/flight code), config file, install. | Low |
| **P5 — Basalt UI** | Roster / detail / DIAG pages; render-iterate via basalt-render. | Med |
| **P6 — fold updater** | Retire `launchers/beaconupdate.lua` + `tools/beaconupdate.lua` into the controller's UPDATE action. | Low |

## 6. Comms hygiene + safety

- **Passive by default; DIAG polling only while open, rate-gated, with an indicator; NO-OP closed.** No
  constant streaming. Mirrors the config-overhaul "traffic only during active use" rule.
- The controller is its **own advanced PC** — it never opens the FCS channel and can't touch the flight
  loop's budget (same isolation as NAV/beacon roles).
- Every command rides the **fail-closed token gate**; a beacon ignores anything without a valid token.

## 7. Testing

- **Protocol (P1):** each command kind encodes/decodes; `accepts` rejects wrong-kind / blank / mismatched
  tokens (extends the existing `test_beacon_update` suite).
- **Handlers (P2):** a token-valid `disable` flips + persists `enabled=false`; `query` returns the §3.5
  payload; an invalid token is a no-op.
- **Controller core (P3):** roster auto-populates + persists + never-forgets-except-remove; SILENT vs
  OFFLINE vs DISABLED classification; expected-position drift flag.
- **Role (P4):** manifest/closure — the controller ships no FCS/flight code; the beacon role gains the
  new handlers without gaining Basalt.
- Standard gates green each phase: src + dist + e2e + manifest sync.

## 8. Risks / open

- **Query-all traffic burst** — a DIAG query-all makes every beacon reply at once; the reply cadence
  must be bounded/staggered so it can't flood the channel. Finalize in P1/P3.
- **UI layout** — sketches in §4 are provisional; finalized via render iteration in P5.
- **Interval floor** — remote `set interval` must still honor `config.MIN_INTERVAL_MS` (1 Hz floor) so
  the controller can't be used to make a beacon spam under the FCS-safety floor.
