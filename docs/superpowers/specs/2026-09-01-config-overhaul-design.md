# EasyHover 2 — Config-System Overhaul (Design)

**Date:** 2026-09-01
**Status:** Design — awaiting operator review before implementation.
**Origin prompt:** `docs/config-overhaul-prompt.md` (verbatim operator direction).

---

## 1. Problem

The current config system is **safe but very verbose and redundant**, and that redundancy
is the source of operator error (loading/saving/overwriting the wrong file) and confusion.

Verified in code today:

- **Roles ship by require()-closure** (`tools/gen_manifest.lua` → `ROLES`). The redundancy is
  concrete: the **`ui` role's `configs` literally include `devbind` + `senscal` + `tuning`**
  (FCS configs) alongside `ui_config` — so the **UI PC holds a second copy of three FCS
  config files**, and shared diagnostic/config tools ship to both `fcs` and `ui`.
- **FCS config lives in four files** (`eh2_devbind.tbl`, `eh2_senscal.tbl`, `eh2_tuning.tbl`,
  `eh2_fuelcal.tbl`) plus a **legacy fused `eh2_hw_config.tbl`** the FCS boot still reads as a
  fallback (pure dead weight now).
- **NAV config is three files**: `eh2_nav.tbl` (settings), `eh2_nav_wpt.tbl` (waypoints/routes),
  `eh2_channel.txt` (GPS channel).
- **Two write paths into FCS config**: the FCS's own shell tools, *and* the UI menus (which edit
  the UI's copy, then FCS SYNC pushes it to the FCS on FCS boot) — plus disk import. Multiple
  copies of the same truth, kept in sync by hand.

## 2. Goals / Non-goals

**Goals**
- **One source of truth per config target**, on its owning role. No cross-role copies.
- **Ease of use on par with the current robustness** — remove the mental overhead and the
  overwrite hazards, without weakening safety.
- Every config recoverable to a known-good **DEFAULT**.
- All config traffic **gated by comms hygiene + the FCS mainThread convention** (config only
  moves during active configuration — never streamed).

**Non-goals (explicitly out)**
- **Changing apply-timing.** We move *where config lives and who writes it*, not *when it takes
  effect*. Whatever applies hot today (e.g. a live CoM push) stays hot; whatever needs an FCS
  reload keeps needing one.
- Offline UI editing of FCS config. There is no "FCS powered-down + no disk" case: the FCS can
  always self-config with its own tools, or import a disk at its boot.

## 3. The Model

### 3.1 Storage — one copy of each config, on its owner

No cross-role copies. Legacy fused `eh2_hw_config.tbl` **retired**.

| Role | `current` config files (the only copy on the network) |
|------|--------------------------------------------------------|
| **FCS** | `devbind` · `senscal` · `tuning` · `fuelcal` |
| **UI**  | `ui_config` |
| **NAV** | `nav` (settings **incl. GPS channel — `channel.txt` folded in**) · `nav_wpt` (waypoints/routes) |

### 3.2 DEFAULT — a golden fallback beside every config

Every `current` config gets a **`DEFAULT`** file living alongside it, untouched by normal
operation. The **only** difference between configs is *who may write the DEFAULT*:

- **FCS `tuning` DEFAULT is immutable.** It is always the code baseline (`fcs/io/tuningdefaults.lua`)
  — the hard-won stable-hover values we tune together — regenerated from code on **Suite
  install/update**. The operator snapshot (§3.5) **skips it**. It can never be overwritten at
  runtime; it sits beside `current` tuning as a permanent recovery point.
- **Every other DEFAULT is operator-set** via the suite-advanced *flag current as DEFAULT*
  snapshot (§3.5).

DEFAULTs change **only** by that snapshot (or manual file deletion). **"Load DEFAULT" runs the
golden config for that session and never overwrites `current`.**

### 3.3 Read / write contract

- **One write path per config target, straight to the owner.** No double-writing. Whatever writes
  FCS config — the FCS's own tools, the UI's FCS-config menus, or a disk import — writes the FCS's
  single file directly. Same for UI and NAV.
- **UI editing FCS config is a live remote read/write against the running FCS.** Opening an
  FCS-config menu asks the FCS for its current config and displays it; saving sends the change and
  the **FCS writes its own file**. Requires the FCS to be up and answering.
- **FCS SYNC → read-only checker.** It asks the FCS what config it is running (and may compare
  against DEFAULT / a disk) and **reports** — it never writes.
- **Disk is the offline bridge** (§3.4): seed a fresh/powered-down FCS by importing a config disk
  at *its* boot.
- **Gating:** every config read/write over the wire runs **only during active configuration**,
  bounded request/response, on the **FCS mainThread** — never a streamed side-channel. This
  preserves comms hygiene (the control loop's budget is untouched).

### 3.4 Disk courier (DTC) — per-role, one-way-correct

The disk carries per-role config, and each transfer only ever moves the **correct role's** files:

- The **UI DTC menu** can import/export **all three roles' configs separately** (it's the
  operator's console), each to/from disk as that role's files.
- When the **FCS reads a disk at its boot**, it writes **only FCS configs** to the FCS.
- When the **UI** or **NAV** imports/exports, it moves **only its own** configs.

### 3.5 Boot loaders — per-config picker

FCS, UI, and NAV each present, at boot, a **per-config picker** (mirroring the existing FCS boot
loader `fcs/boot/loaderui.lua`): for **each config file** choose **Load DEFAULT · Load current ·
Load from disk**. (So e.g. boot FCS with `tuning` = DEFAULT but `senscal` = current.)

- **FCS** already has the phase — adjust it to the DEFAULT/current/disk model.
- **UI** has a boot phase (logging) — extend it with the per-config picker.
- **NAV** has **no** boot phase today — it gains one.

### 3.6 Suite / SuiteX — two new *Advanced* options

- **Migrate old → new.** One-shot consolidation of the current (redundant) config system into the
  new single-source layout **with no config loss** — absorbs the legacy fused `hw_config` and the
  UI's copies of FCS config into the owner's single files (§5).
- **Flag current configs as DEFAULT.** Snapshots each role's **current** configs into their
  **DEFAULT** files and backs them up separately from the Suite's update-backup. **Skips FCS
  `tuning`** (its DEFAULT is the immutable code baseline).

## 4. Decomposition & sequencing

One coherent overhaul, implemented in **safe → risky** phases. Each phase is its own TDD'd,
merge-to-main unit.

| Phase | Scope | Risk | Depends on |
|------|-------|------|-----------|
| **S1 — shipping** | Tools + config files ship only to their owning role (`gen_manifest` ROLES + closure): drop FCS-config tools from non-FCS, UI-config tools from non-UI, both from NAV/BEACON; remove the UI's copies of FCS configs from its `configs`. | Low | — |
| **S2 — live write path** | UI FCS-config menus read/write the FCS's single config over a gated request/response; SYNC → checker; kill the UI-holds-then-pushes-on-boot flow. | **High** (new protocol) | S1 |
| **S3 — disk courier** | Per-role import/export; boot-from-disk writes only the owner's configs; fold `channel` into `nav`. | Med | S1 |
| **S4 — boot loaders** | Per-config DEFAULT/current/disk picker on FCS (adjust), UI (extend), NAV (new phase). | Med | S3 |
| **S5 — suite advanced** | Migrate old→new (no loss) + flag-current-as-DEFAULT (skips FCS tuning) with separate backup; retire fused `hw_config`. | Med | S1–S4 |

**Order:** S1 (safe cleanup) → S3 + S4 (disk + boot, the load side) → S2 (live write, riskiest) →
S5 (migration + snapshot, gates deployment). S5's migration must land before the new system is
relied on in-world so nothing is lost.

## 5. Migration & safety (no config loss)

The migration (S5) is the one-time bridge from the redundant system to single-source. For each
role it consolidates every existing source into the owner's single files, newest-wins with the
existing deep-merge semantics (`fcs/io/hwconfig.lua` `mergeInto`):

- **FCS:** fused `hw_config` split + merged into `devbind`/`senscal`; existing `tuning`/`fuelcal`
  kept. The UI's stale copies of FCS config are **discarded** (the FCS's own are canonical) — but
  the migration surfaces any divergence for operator confirmation before discarding, so a config
  the operator only ever set via the UI isn't silently lost.
- **UI / NAV:** already single-source; migration just retires the legacy names and seeds DEFAULT
  files from current.
- Migration is **idempotent** and writes DEFAULT snapshots as its final step, so a freshly migrated
  system already has a known-good fallback.

## 6. Testing

- **Storage/DEFAULT** (`cfgspec`-level): pure tests that each config resolves current vs DEFAULT
  correctly; that FCS `tuning` DEFAULT always equals the code baseline and the snapshot never
  writes it; that "Load DEFAULT" leaves `current` untouched.
- **Shipping** (S1): manifest/closure tests that FCS-config tools/files are absent from non-FCS
  role closures and vice-versa (extends the existing e2e role-install checks — cf. the beacon
  "no Basalt / no flight entry point" assertions).
- **Live write** (S2): request/response protocol unit tests (gated, bounded, mainThread) + a
  round-trip that a UI save mutates only the FCS's single file.
- **Disk/boot** (S3/S4): per-role transfer only moves the owner's files; per-config picker resolves
  each source independently.
- **Migration** (S5): idempotent; no-loss (every pre-migration value present post-migration or
  surfaced for confirmation).
- Every phase holds the standard gates green: **src + dist suites + e2e + manifest sync**.

## 7. Risks / open items (resolve during phase design)

- **S2 protocol shape** — the exact gated request/response for live FCS config read/write
  (encoding, mainThread hand-off, timeout/retry within comms hygiene). Deferred to S2 design.
- **UI menu behavior when the FCS is down** — the menus must degrade gracefully (clear "FCS not
  answering" state), and point the operator at the disk path.
- **DEFAULT file naming/location convention** — proposal: a sibling name per config (e.g.
  `eh2_tuning.default.tbl`) so `current` and `DEFAULT` are obviously paired; finalized in S4.
- **Snapshot backup location** — separate from the Suite update-backup; finalized in S5.
