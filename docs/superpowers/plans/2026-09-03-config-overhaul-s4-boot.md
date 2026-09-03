# Config Overhaul — S4 (Boot loaders: DEFAULT / current / disk)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.

**Goal:** FCS, UI, and NAV each pick per-config **Load DEFAULT · Load current · Load from disk** at boot. Load DEFAULT applies for this session and does not overwrite the current file.

**Architecture:** Sibling DEFAULT files `eh2_<name>.default.tbl` (cfgroles.defaultFile). Tuning DEFAULT with no sibling file is the immutable code baseline (`tuningdefaults.get()`). A session overlay `eh2_tuning.session.tbl` lets DEFAULT/disk-for-this-boot apply without clobbering `eh2_tuning.tbl` current. `tools/flight.lua` loadConfig prefers the session overlay when present. Disk import **does** write current (it is an import). UI/NAV boot pickers write a session overlay next to their current file, same rule.

**Tech Stack:** Lua 5.1, existing `fcs/boot/loader.lua` + `loaderui.lua`, `launchers/ui.lua`, `launchers/nav.lua`.

**Spec:** `docs/superpowers/specs/2026-09-01-config-overhaul-design.md` §3.2 / §3.5 / §4 S4.

## Global Constraints

- Load DEFAULT never overwrites current files.
- Load disk **does** write current (import).
- FCS tuning DEFAULT is code baseline when no sibling DEFAULT file exists; never write the tuning DEFAULT file in this phase (S5 snapshot skips it).
- ASCII. Gates green. `feat/config-overhaul`. No push/merge.
- Trailer: `Co-Authored-By: Grok 4.6 <noreply@x.ai>`
- Windows: Git Bash `tests/run_headless.sh` etc.

---

### Task 1: DEFAULT / session path helpers on cfgroles

**Files:** `fcs/io/cfgroles.lua`, `tests/test_cfgroles.lua`

```lua
function M.defaultFile(kind)
  local f = M.file(kind)
  if not f then return nil end
  return (f:gsub("%.tbl$", ".default.tbl"))
end
function M.sessionFile(kind)
  local f = M.file(kind)
  if not f then return nil end
  return (f:gsub("%.tbl$", ".session.tbl"))
end
```

Tests: `defaultFile("tuning") == "eh2_tuning.default.tbl"`; `sessionFile("uicfg") == "eh2_ui_config.session.tbl"`; `defaultFile("nope") == nil`.

TDD RED then implement. Gates. Commit: `feat(config-overhaul S4): DEFAULT and session sibling filenames`

---

### Task 2: FCS loader sources = current / default / disk

**Files:** `fcs/boot/loader.lua`, `tests/test_bootloader.lua`

SOURCES become:

```lua
  SOURCES = {
    binding = { "current", "default", "disk" },
    sensor  = { "current", "default", "disk" },
    tuning  = { "current", "default", "disk" },
  },
```

Rename `"own"` → `"current"` (same split-else-fused read). `"default"`: read `cfgroles.defaultFile(kind)` via injected read; if missing and kind==tuning, `tuningdefaults.get()`; else nil. `"disk"` unchanged.

`tests/test_bootloader.lua`: replace remaining `"own"` with `"current"`; add a case that default+missing sibling fails for binding and succeeds for tuning (code baseline).

Commit: `feat(config-overhaul S4): FCS loader current/default/disk sources`

---

### Task 3: loaderui picker + DEFAULT does not clobber current

**Files:** `fcs/boot/loaderui.lua`, `tests/test_bootloaderui.lua`, `tools/flight.lua` (session overlay read)

- `ownSource` stays the current-file reader; expose as current.
- `defaultSource(concern)`: read `"/" .. cfgroles.defaultFile(KIND[concern])`; tuning falls back to `tuningdefaults.get()`.
- `needsConfirm` still disk only.
- `M.commit(assembled, write, choices)`: always write fused `/eh2_hw_config.tbl` from assembled.hw. For tuning: if choices.tuning == "current", delete session overlay if present and write `/eh2_tuning.tbl`. If choices.tuning == "default" or `"disk"`-as-session: write `/eh2_tuning.session.tbl` from assembled.tuning and do **not** write `/eh2_tuning.tbl`. Ruling: disk for tuning **does** write current (`/eh2_tuning.tbl`) and deletes session overlay — disk is an import. Only DEFAULT writes the session overlay.

Wait — spec: disk import writes current. DEFAULT uses session. Implement:

```
if choices.tuning == "default" then write session; do not write current
elseif choices.tuning == "disk" then write current; delete session
else -- current: delete session; current file already is the source (no write required, or rewrite identical)
```

Flight loadConfig: if `eh2_tuning.session.tbl` exists, load it, else `eh2_tuning.tbl`.

Tests: `commit` with choices.tuning="default" writes session, leaves a pre-seeded current tuning file untouched.

Commit: `feat(config-overhaul S4): DEFAULT tuning is a session overlay`

---

### Task 4: UI and NAV boot pickers

**Files:** `launchers/ui.lua`, `launchers/nav.lua`, new pure `fcs/boot/pick.lua` (shared picker logic, testable)

`pick.lua`:

```lua
-- resolveUi(choice, sources) -> cfg|nil, err
-- choices: "current"|"default"|"disk"
-- sources.get(src) as loader
```

UI launcher after logging Y/N: print BINDING-style lines for UI CONFIG: [1] current [2] DEFAULT [3] disk. Apply: current = load eh2_ui_config.tbl; default = load eh2_ui_config.default.tbl (fail if missing); disk = disk file same name. DEFAULT → write session overlay `eh2_ui_config.session.tbl`; `ui.basalt.app` / `ui.config.load` prefers session if present.

NAV launcher: before `nav.app`.run(), same picker for `nav` and `nav_wpt` independently. Session overlays `eh2_nav.session.tbl` / `eh2_nav_wpt.session.tbl`. `nav.config.load` / waypoints load prefer session.

If a full terminal UI is too large for one task: a 3-key prompt (1/2/3) per config is enough. ASCII. No Basalt on FCS; UI/NAV launchers are terminal prompts like today's Y/N.

Tests: `tests/test_bootpick.lua` for pick.lua resolve (injected sources). Launcher wiring is in-game (like loaderui.run) — keep logic in pick.lua.

Commit: `feat(config-overhaul S4): UI and NAV boot DEFAULT/current/disk pickers`

---

## Self-Review

Spec §3.5 per-config picker on FCS/UI/NAV. DEFAULT session overlay satisfies "never overwrites current". Disk import writes current. Tuning DEFAULT = code baseline. Sibling naming matches spec proposal `eh2_tuning.default.tbl`.
