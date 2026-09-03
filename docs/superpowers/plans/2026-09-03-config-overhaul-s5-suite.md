# Config Overhaul — S5 (Suite Advanced: migrate + flag DEFAULT)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** Suite/SuiteX Advanced can (1) snapshot current configs as DEFAULT (skip FCS tuning) with a backup separate from the update-backup, and (2) migrate leftover fused `hw_config` into split current files without loss. Idempotent.

**Architecture:** Pure `fcs/io/cfgdefault.lua`. Snapshot copies each current file to `cfgroles.defaultFile(kind)` except `tuning`. Migrate: if split files missing and fused `/eh2_hw_config.tbl` exists, `cfgspec.splitLegacy` + save splits; never delete fused (runtime artifact). Suite functions call these with fsx. SuiteX Advanced tab two buttons. Classic suite `--flag-defaults` and `--migrate-config`.

**Spec:** `docs/superpowers/specs/2026-09-01-config-overhaul-design.md` §3.6 / §4 S5 / §5.

## Global Constraints

- FCS tuning DEFAULT is never written by snapshot (code baseline).
- Snapshot backup dir `/easyhover2_defaults_backup/` — not `/easyhover2_backup/`.
- Migrate is idempotent; does not delete fused.
- ASCII. Gates. `feat/config-overhaul`. No push until controller merge.
- Trailer: `Co-Authored-By: Grok 4.6 <noreply@x.ai>`

---

### Task 1: Pure snapshot + migrate

**Files:** create `fcs/io/cfgdefault.lua`; test `tests/test_cfgdefault.lua`; both runners.

```lua
-- snapshot(role, read, write, kinds) -> { copied = {kind,...}, skipped = {kind,...} }
-- For each kind in cfgroles.kinds(role) except tuning: body=read(file); if body then write(defaultFile, body)
-- migrate(read, write) -> { action = "split"|"noop", ... }
-- If both eh2_devbind.tbl and eh2_senscal.tbl exist: noop
-- Else if fused eh2_hw_config.tbl parses: splitLegacy, save missing splits, action=split
-- Else noop
```

TDD with fakeFs like cfgaccess tests.

Commit: `feat(config-overhaul S5): DEFAULT snapshot and fused-to-split migrate`

---

### Task 2: Suite CLI + backup dir

**Files:** `easyhover2_suite.lua`, `tests/test_suite.lua`

- `Suite.DEFAULTS_BACKUP = "/easyhover2_defaults_backup"`
- `Suite.flagDefaults(role, read, write)`: copy current files that exist into DEFAULTS_BACKUP then cfgdefault.snapshot
- `Suite.migrateConfig(read, write)`: cfgdefault.migrate
- Parse `--flag-defaults` and `--migrate-config` in Suite.main; run and exit (do not install)

Tests with injected fs.

Commit: `feat(config-overhaul S5): suite --flag-defaults and --migrate-config`

---

### Task 3: SuiteX Advanced buttons

**Files:** `easyhover2_suitex.lua`, existing SuiteX tests if any

On Advanced tab, below existing checkboxes, two buttons:
- `FLAG DEFAULTS` → `Suite.flagDefaults(ctx.role, ...)` with status in the log
- `MIGRATE CONFIG` → `Suite.migrateConfig(...)`

Use `el:onClick`. ASCII labels. Guard with `ctx.opInFlight` like other engine ops.

If SuiteX tests are glue-only, add a pure helper `SuiteX.advancedOps()` returning the two ids.

Commit: `feat(config-overhaul S5): SuiteX FLAG DEFAULTS and MIGRATE CONFIG`

---

## Self-Review

Spec §3.6 two Advanced options. §5 migrate fused into splits, UI copies already gone (S2b). Tuning DEFAULT skipped. Separate backup path. Idempotent migrate.
