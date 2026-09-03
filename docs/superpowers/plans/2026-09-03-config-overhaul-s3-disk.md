# Config Overhaul — S3 (Per-role disk courier)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Disk transfers move only the owning role's files. UI DTC can export/import FCS (live) and UI (local) separately; FCS boot-from-disk still reads only FCS files. NAV waypoint disk stays on the existing NAV-menu courier.

**Architecture:** A pure role registry (`fcs/io/cfgroles.lua`) lists kinds per role and disk filenames. DTC `_scan`/`_export`/`_import` take a `role`. FCS kinds on the UI PC have no local files anymore — their "local" side is the running FCS via `runtime.cfgClient` (serialised bodies written to the same disk paths `loaderui.diskSource` already reads). UI kinds stay local `eh2_ui_config.tbl`. NAV kinds are visible on disk but the UI DTC never writes them to the UI PC (NAV menu + `nav/wptdisk.lua` already own `eh2_nav_wpt.tbl`; `eh2_nav.tbl` lives on the NAV PC).

**Tech Stack:** Lua 5.1, CraftOS-PC headless, Basalt 2.0, existing `ui/basalt/bitconfig/dtc.lua` + `tests/test_bitconfig_dtc.lua`.

**Spec:** `docs/superpowers/specs/2026-09-01-config-overhaul-design.md` §3.4 / §4 S3.

## Global Constraints

- Disk path for FCS kinds MUST remain `"/" .. mount .. "/" .. cfgspec.FILES[kind]` (boot `diskSource`).
- UI DTC FCS export/import requires the FCS to be answering (same as TUNING). Graceful: no disk write on silent FCS.
- UI DTC must never write `eh2_devbind.tbl` / `eh2_senscal.tbl` / `eh2_tuning.tbl` / `eh2_fuelcal.tbl` / `eh2_nav.tbl` / `eh2_nav_wpt.tbl` onto the UI PC.
- GPS channel already lives in `nav.config` (`eh2_nav.tbl`.channel). Do NOT fold Suite `/eh2_channel.txt` (min/dev marker) into NAV.
- ASCII. No optimistic UI. Manifests generated. dist via `node tools/build.mjs`.
- Gates green before each commit. Work on `feat/config-overhaul`. Do not push. Do not merge.
- Trailer: `Co-Authored-By: Grok 4.6 <noreply@x.ai>`

---

### Task 1: Pure role registry (`fcs/io/cfgroles.lua`)

**Files:**
- Create: `fcs/io/cfgroles.lua`
- Test: `tests/test_cfgroles.lua` (new) + append `"tests.test_cfgroles"` to BOTH headless runners

**Interfaces:**
- `cfgroles.ROLES = { fcs, ui, nav }`
- `cfgroles.kinds(role) -> {kind,...}`
- `cfgroles.file(kind) -> filename` (bare, no slash)
- `cfgroles.roleOf(kind) -> role|nil`
- `cfgroles.FILES` aliases: fcs kinds from `cfgspec.FILES`; ui = `eh2_ui_config.tbl`; nav = `eh2_nav.tbl`; nav_wpt = `eh2_nav_wpt.tbl`

- [ ] **Step 1: Write failing tests (RED)**

Create `tests/test_cfgroles.lua`:

```lua
local t = require("tests.framework")
local R = require("fcs.io.cfgroles")
local cfgspec = require("fcs.io.cfgspec")

t.test("fcs kinds are the four cfgspec files", function()
  local k = R.kinds("fcs")
  t.eq(#k, 4)
  local set = {}
  for _, x in ipairs(k) do set[x] = true end
  t.truthy(set.devbind and set.senscal and set.tuning and set.fuelcal)
  t.eq(R.file("devbind"), cfgspec.FILES.devbind)
  t.eq(R.file("fuelcal"), cfgspec.FILES.fuelcal)
end)

t.test("ui kind is only uicfg", function()
  local k = R.kinds("ui")
  t.eq(#k, 1); t.eq(k[1], "uicfg")
  t.eq(R.file("uicfg"), "eh2_ui_config.tbl")
  t.eq(R.roleOf("uicfg"), "ui")
end)

t.test("nav kinds are nav + nav_wpt; GPS channel is NOT a separate file", function()
  local k = R.kinds("nav")
  t.eq(#k, 2)
  local set = {}
  for _, x in ipairs(k) do set[x] = true end
  t.truthy(set.nav and set.nav_wpt)
  t.eq(R.file("nav"), "eh2_nav.tbl")
  t.eq(R.file("nav_wpt"), "eh2_nav_wpt.tbl")
  t.eq(R.roleOf("channel"), nil, "Suite eh2_channel.txt is not a nav config")
end)

t.test("roleOf maps every registered kind and rejects unknown", function()
  t.eq(R.roleOf("tuning"), "fcs")
  t.eq(R.roleOf("uicfg"), "ui")
  t.eq(R.roleOf("nav_wpt"), "nav")
  t.eq(R.roleOf("nope"), nil)
end)
```

- [ ] **Step 2: Run focus — expect module not found.** Append the suite to BOTH runners.

- [ ] **Step 3: Implement**

```lua
-- fcs/io/cfgroles.lua
-- Pure role -> config-kind registry for the per-role disk courier (S3).
-- Disk filenames for FCS kinds MUST equal cfgspec.FILES (boot diskSource).
local cfgspec = require("fcs.io.cfgspec")

local M = {}
M.ROLES = { "fcs", "ui", "nav" }

local KINDS = {
  fcs = { "devbind", "senscal", "tuning", "fuelcal" },
  ui  = { "uicfg" },
  nav = { "nav", "nav_wpt" },
}

local FILES = {
  devbind = cfgspec.FILES.devbind,
  senscal = cfgspec.FILES.senscal,
  tuning  = cfgspec.FILES.tuning,
  fuelcal = cfgspec.FILES.fuelcal,
  uicfg   = "eh2_ui_config.tbl",
  nav     = "eh2_nav.tbl",
  nav_wpt = "eh2_nav_wpt.tbl",
}

local ROLE_OF = {}
for role, kinds in pairs(KINDS) do
  for _, kind in ipairs(kinds) do ROLE_OF[kind] = role end
end

function M.kinds(role) return KINDS[role] end
function M.file(kind) return FILES[kind] end
function M.roleOf(kind) return ROLE_OF[kind] end

return M
```

- [ ] **Step 4: GREEN + src + build.mjs + dist + e2e. Commit**

```
feat(config-overhaul S3): per-role config kind registry (cfgroles)
```

---

### Task 2: DTC transfers are role-scoped; FCS kinds are live on the UI

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua`
- Test: `tests/test_bitconfig_dtc.lua` (append)

**Interfaces:**
- `M.roleKinds(role)` delegates to cfgroles.
- `M.localPath` / `M.diskPath` use `cfgroles.file`.
- `M._scan(mount, deps, role)` only those kinds.
- `M._export(mount, deps, role)` / `M._import(mount, deps, role)`:
  - `role=="ui"`: existing atomicCopy localPath ↔ diskPath
  - `role=="fcs"`: `deps.fcsGet(kind) -> serialised|nil` and `deps.fcsSet(kind, serialised) -> ok`. Default deps in `M.build` wire these to `runtime.cfgClient` (readKind/writeKind, blocking not allowed — fire-and-forget with callback that sets a status string). For PURE tests, inject fcsGet/fcsSet.
  - `role=="nav"`: export/import ONLY if `deps.exists(localPath)` (NAV PC). On UI, both return `{}` and never write nav files to `/`.
- `M.validateKind` extends: fuelcal via cfgspec; nav = table with `channel` number OR any table (nav.config.withDefaults); nav_wpt = table with `waypoints` array (match `nav.wptdisk.isValidStore`).

Default `M.KINDS` used by existing tests is the **union currently tested** — do not break old tests that pass no role. Ruling: keep `M.KINDS` as today's `{devbind,senscal,tuning,uicfg}` for backward-compatible `M.plan`/`_scan` without a role arg; new role arg filters. `_export`/`_import` without role keep old behavior BUT FCS kinds in that path must use fcsGet/fcsSet when provided, else skip (do not write UI-local FCS files).

**Critical:** `_export`/`_import` of FCS kinds must NOT call `atomicCopy(M.localPath(fcsKind), ...)` on the UI (those files are gone / must not be recreated).

- [ ] **Step 1: Failing tests (append to test_bitconfig_dtc.lua)**

```lua
t.test("export fcs role writes disk from fcsGet and never touches UI-local FCS paths", function()
  local written, localWrites = {}, {}
  local deps = {
    exists = function() return false end,
    read = function() return nil end,
    write = function(path, body) written[path] = body; return true end,
    delete = function() end,
    move = function(from, to) written[to] = written[from]; written[from] = nil end,
    fcsGet = function(kind) return textutils.serialise({ kind = kind }) end,
    fcsSet = function() error("import not called") end,
  }
  local exported = M._export("disk0", deps, "fcs")
  t.truthy(#exported >= 3)
  t.eq(written["/eh2_devbind.tbl"], nil, "no UI-local FCS file created")
  t.truthy(written["/disk0/eh2_devbind.tbl"] ~= nil)
end)

t.test("import fcs role calls fcsSet from disk and never writes UI-local FCS paths", function()
  local sets, localWrites = {}, {}
  local deps = {
    exists = function(path) return path:find("^/disk0/") ~= nil end,
    read = function(path) return path:find("eh2_tuning") and textutils.serialise({ gains = {}, caps = {}, feel = {} }) or textutils.serialise({ ok = true }) end,
    write = function(path, body) localWrites[path] = body end,
    delete = function() end,
    move = function() end,
    fcsGet = function() return nil end,
    fcsSet = function(kind, body) sets[kind] = body; return true end,
  }
  M._import("disk0", deps, "fcs")
  t.truthy(sets.tuning ~= nil)
  t.eq(localWrites["/eh2_tuning.tbl"], nil)
end)

t.test("nav role export/import is a no-op when local nav files are absent (UI PC)", function()
  local writes = 0
  local deps = {
    exists = function() return false end,
    read = function() return "X" end,
    write = function() writes = writes + 1 end,
    delete = function() end,
    move = function() end,
  }
  t.eq(#(M._export("disk0", deps, "nav")), 0)
  t.eq(#(M._import("disk0", deps, "nav")), 0)
  t.eq(writes, 0)
end)
```

- [ ] **Step 2: RED, then implement role-scoped _export/_import/_scan + validateKind extensions. Wire M.build so FCS/UI/NAV buttons pass the role. FCS fcsGet/fcsSet default: from runtime.cfgCache body serialised / cfgClient:writeKind.**

For the default live seams in M.build (not unit-tested; tests inject):

```lua
  if runtime and runtime.cfgClient then
    deps.fcsGet = deps.fcsGet or function(kind)
      local c = runtime.cfgCache and runtime.cfgCache[kind]
      if c and c.body ~= nil then return textutils.serialise(c.body) end
      return nil
    end
    deps.fcsSet = deps.fcsSet or function(kind, body)
      local tbl = textutils.unserialise(body)
      if type(tbl) ~= "table" then return false end
      runtime.cfgClient:writeKind(kind, tbl, function(ok, err)
        runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
          or ("SAVE FAILED: " .. tostring(err or "no FCS"))
        runtime.uiRev = (runtime.uiRev or 0) + 1
      end)
      return true
    end
  end
```

Opening the FCS DTC group should prefetch kinds via cfgMenuStatus/cfgClient (already gated if we add `dtc` to CFG_MENU_KINDS as `{ "tuning","devbind","senscal","fuelcal" }` in `ui/basalt/app.lua`). Do that in this task so export has cache bodies.

- [ ] **Step 3: GREEN dtc tests + app tests if CFG_MENU_KINDS changed. Full gates. Commit**

```
feat(config-overhaul S3): DTC is per-role; FCS kinds go live to disk
```

---

### Task 3: fcs2disk dumps fuelcal too

**Files:**
- Modify: `tools/fcs2disk.lua` `M.KINDS`
- Test: `tests/test_fcs2disk.lua` (or whatever currently tests plan())

`M.KINDS = { "devbind", "senscal", "tuning", "fuelcal" }`

Existing `plan()` already iterates `M.KINDS`. Update any test that hard-codes 3 kinds.

Commit: `feat(config-overhaul S3): fcs2disk also dumps fuelcal`

---

### Task 4: Lock GPS channel in eh2_nav.tbl (no extra file)

**Files:**
- Test only: append to `tests/test_nav_config.lua` (or create if missing)

```lua
t.test("GPS channel lives in eh2_nav.tbl defaults, not a sidecar file", function()
  local C = require("nav.config")
  t.eq(type(C.defaults().channel), "number")
  t.eq(C.PATH, "/eh2_nav.tbl")
end)
```

Do not add `/eh2_channel.txt` to nav role `configs`. That file is the Suite min/dev marker.

If no nav config test file exists, create `tests/test_nav_config.lua` and register in BOTH runners.

Commit: `test(config-overhaul S3): GPS channel is inside eh2_nav.tbl`

---

## Self-Review

**Spec §3.4:** UI DTC exports roles separately (Task 2). FCS boot diskSource already FCS-only (unchanged paths). UI import of FCS writes the FCS live, not UI-local files. NAV files are not written onto the UI PC.

**GPS fold:** already done in nav.config; Task 4 locks it. Suite marker left alone.

**fuelcal:** registry + fcs2disk + live DTC FCS group. Boot picker for fuelcal is S4.
