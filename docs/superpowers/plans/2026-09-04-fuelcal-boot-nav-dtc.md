# Config Overhaul leftovers — fuelcal boot/SYNC + NAV settings DTC

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fuelcal is a first-class FCS boot + SYNC concern (DEFAULT/current/disk, session overlay). The cockpit DTC NAV role dumps/loads `eh2_nav.tbl` from the running NAV PC over the existing 108/109 link (body over the wire; UI writes the disk it sees). Never write NAV files onto the UI PC.

**Architecture:** Fuelcal reuses the S4 session-overlay commit path already used for binding/sensor/tuning. Flight loads fuelcal via `cfgspec.loadLive`. FCS SYNC adds `fuelcal` to `M.KINDS`. NAV settings reuse the waypoint client's 108/109 link with new `nav_cfg_get` / `nav_cfg_set` frames; DTC `navGet`/`navSet` mirror `fcsGet`/`fcsSet`.

**Tech Stack:** Lua 5.1, CraftOS-PC headless, existing `fcs/boot/loader.lua`, `loaderui.lua`, `ui/basalt/bitconfig/fcssync.lua`, `nav/app.lua`, `ui/basalt/wptclient.lua`, `ui/basalt/bitconfig/dtc.lua`.

**Spec:** `docs/superpowers/specs/2026-09-01-config-overhaul-design.md` §3.1 (fuelcal is an FCS file), §3.4 (UI DTC exports all three roles), §3.5 (per-config boot picker).

## Global Constraints

- ASCII only. No optimistic UI. Dist via `node tools/build.mjs`. Manifests generated never hand-edited.
- Gates green before each commit: src, dist, e2e.
- Work on `feat/config-overhaul-leftovers` in-place. Do not push until the controller merge.
- Fuelcal DEFAULT has **no** code-baseline fallback (unlike tuning). Missing sibling = unavailable, same as binding/sensor.
- FLAG DEFAULTS still **skips** FCS tuning. Do not change `cfgdefault.snapshot`.
- NAV `eh2_nav.tbl` never written to the UI PC (only to the disk the UI detected).
- Trailer: `Co-Authored-By: Grok 4.6 <noreply@x.ai>`
- Windows: `"C:/Program Files/Git/bin/bash.exe" tests/run_headless.sh`

---

### Task 1: FCS loader resolves fuelcal as a fourth concern

**Files:**
- Modify: `fcs/boot/loader.lua`
- Test: `tests/test_bootloader.lua`

**Interfaces:**
- `SOURCES.fuelcal = { "current", "default", "disk" }`
- `KIND.fuelcal = "fuelcal"`
- `resolve` iterates `binding, sensor, tuning, fuelcal`
- `assembled.fuelcal` is the chosen table (validated by `cfgspec.validate("fuelcal", cfg)`)

- [ ] **Step 1: Write failing tests (append)**

```lua
t.test("SOURCES lists current/default/disk for fuelcal", function()
  t.eq(L.SOURCES.fuelcal[1], "current")
  t.eq(L.SOURCES.fuelcal[2], "default")
  t.eq(L.SOURCES.fuelcal[3], "disk")
  t.eq(L.SOURCES.fuelcal[4], nil)
end)

t.test("resolve includes assembled.fuelcal from the fuelcal source", function()
  local src = { get = function(concern, s)
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
    if concern == "fuelcal" then return { fuel = "Bioethanol" } end
  end }
  local ok, out = L.resolve({
    binding="current", sensor="current", tuning="default", fuelcal="current",
  }, src)
  t.eq(ok, true)
  t.eq(out.fuelcal.fuel, "Bioethanol")
end)

t.test("missing fuelcal source fails that concern (no code-baseline fallback)", function()
  local src = { get = function(concern, s)
    if concern == "fuelcal" then return nil end
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, _, err, failed = L.resolve({
    binding="current", sensor="current", tuning="current", fuelcal="default",
  }, src)
  t.eq(ok, false)
  t.eq(failed, "fuelcal")
end)
```

Update existing resolve tests that omit `fuelcal` in choices: add `fuelcal="current"` and a stub that returns `C.defaults("fuelcal")`. Otherwise they fail as `fuelcal: invalid source`.

- [ ] **Step 2: RED** `SUITES=tests.test_bootloader bash tests/run_focus.sh`

- [ ] **Step 3: Implement** `SOURCES`, `KIND`, loop, `assembled.fuelcal`.

- [ ] **Step 4: GREEN + src + build.mjs + dist + e2e. Commit**

```
feat(config-overhaul): FCS loader resolves fuelcal as a fourth concern
```

---

### Task 2: loaderui picker + session overlay for fuelcal; flight loadLive

**Files:**
- Modify: `fcs/boot/loaderui.lua` (KIND, CURRENT_PATH, SESSION_PATH, CONCERNS, LABEL, commit loop, header)
- Modify: `tools/flight.lua` — fuelcal load uses `cfgspec.loadLive("fuelcal", readFile)`
- Test: `tests/test_bootloaderui.lua` (commit overlay for fuelcal; current file untouched on DEFAULT)

**Interfaces:**
- `KIND.fuelcal = "fuelcal"`
- `CURRENT_PATH.fuelcal = "/eh2_fuelcal.tbl"`
- `SESSION_PATH.fuelcal = "/eh2_fuelcal.session.tbl"`
- `CONCERNS` includes `"fuelcal"`; `LABEL.fuelcal = "FUELCAL"`
- `commit` writes `assembled.fuelcal` under the same default/disk/current rules as tuning
- `ownSource` for fuelcal: `cfgspec.load` of the split file only (no fused seed — `splitLegacy` has no fuelcal)
- `diskSource` already uses `cfgspec.FILES[kind]` once KIND is set
- `defaultSource` has **no** fuelcal code fallback (only tuning)

- [ ] **Step 1: Failing tests**

```lua
t.test("commit DEFAULT fuelcal writes session overlay and does not clobber current", function()
  local files = { ["/eh2_fuelcal.tbl"] = "CURRENT-FUEL" }
  local write = function(p, b) files[p] = b end
  local delete = function(p) files[p] = nil end
  local assembled = {
    hw = { thrusters = {}, sensors = {}, fuelRelay = nil, bindings = {} },
    tuning = { gains = {}, caps = {}, feel = {} },
    fuelcal = { fuel = "Bioethanol" },
  }
  M.commit(assembled, write, {
    binding="current", sensor="current", tuning="current", fuelcal="default",
  }, delete)
  t.eq(files["/eh2_fuelcal.tbl"], "CURRENT-FUEL")
  t.truthy(files["/eh2_fuelcal.session.tbl"])
  local parsed = textutils.unserialise(files["/eh2_fuelcal.session.tbl"])
  t.eq(parsed.fuel, "Bioethanol")
end)
```

Also: disk writes current and deletes session; 2-arg commit still does not invent a fuelcal session.

- [ ] **Step 2: RED, then implement, GREEN.** Flight: replace `cfgspec.load("fuelcal", readFile)` with `cfgspec.loadLive("fuelcal", readFile)`.

- [ ] **Step 3: Gates + commit**

```
feat(config-overhaul): fuelcal DEFAULT/current/disk at FCS boot
```

---

### Task 3: FCS SYNC probes fuelcal

**Files:**
- Modify: `ui/basalt/bitconfig/fcssync.lua` `M.KINDS`
- Test: `tests/test_bitconfig_fcssync.lua`

Change `M.KINDS = { "tuning", "devbind", "senscal", "fuelcal" }`.

Test:

```lua
t.test("M.KINDS includes fuelcal", function()
  local set = {}
  for _, k in ipairs(M.KINDS) do set[k] = true end
  t.truthy(set.tuning and set.devbind and set.senscal and set.fuelcal)
end)
```

Keep the existing `>= 3` test or replace it with this one.

Commit: `feat(config-overhaul): FCS SYNC reports fuelcal`

---

### Task 4: Pure NAV settings get/set protocol

**Files:**
- Create: `nav/navcfg.lua`
- Test: `tests/test_navcfg.lua` + both runners

```lua
-- nav/navcfg.lua
-- Pure NAV-settings frames for the cockpit DTC. Transport is 108/109 (same link as waypoints).
local M = {}
function M.getFrame() return { k = "nav_cfg_get" } end
function M.setFrame(body) return { k = "nav_cfg_set", body = body } end
function M.cfgFrame(body) return { k = "nav_cfg", body = body } end
function M.ackFrame(ok, err) return { k = "nav_cfg_ack", ok = ok and true or false, err = err } end

-- apply(cfg, msg) -> reply, newCfg
-- get returns the current table; set replaces it when body is a table.
function M.apply(cfg, msg)
  msg = msg or {}
  if msg.k == "nav_cfg_get" then
    return M.cfgFrame(cfg), cfg
  end
  if msg.k == "nav_cfg_set" then
    if type(msg.body) ~= "table" then
      return M.ackFrame(false, "not a table"), cfg
    end
    return M.ackFrame(true), msg.body
  end
  return nil, cfg
end

return M
```

Tests: get returns body; set with table replaces; set with non-table keeps cfg and acks false; unknown k returns nil (so wptserver can still own the rest).

Commit: `feat(config-overhaul): NAV settings get/set protocol`

---

### Task 5: NAV app + wptclient speak nav_cfg

**Files:**
- Modify: `nav/app.lua` `handleWptRequest` — if `navcfg.apply` returns a reply, persist cfg on set and return it (before wptserver)
- Modify: `ui/basalt/wptclient.lua` — `requestNavCfg()`, `setNavCfg(body)`, `onReply` handles `nav_cfg` / `nav_cfg_ack`
- Test: `tests/test_nav_app.lua` or existing nav request tests; `tests/test_wptclient.lua`

`handleWptRequest`:

```lua
  local navcfg = require("nav.navcfg")
  if type(msg) == "table" then
    local reply, newCfg = navcfg.apply(runtime.config, msg)
    if reply then
      if msg.k == "nav_cfg_set" and reply.ok then
        runtime.config = newCfg
        if runtime.save then pcall(runtime.save, newCfg) end
      end
      return reply
    end
  end
```

wptclient:

```lua
function C:onReply(frame, now)
  ...
  if frame.k == "nav_cfg" and type(frame.body) == "table" then
    self.navCfg = frame.body
    self.online = true
    self.lastReplyAt = now
    if self._navCfgCb then self._navCfgCb(frame.body) end
    return true
  end
  if frame.k == "nav_cfg_ack" then
    self.online = true
    self.lastReplyAt = now
    if self._navAckCb then self._navAckCb(frame.ok, frame.err) end
    return true
  end
end

function C:requestNavCfg(cb)
  self._navCfgCb = cb
  local navcfg = require("nav.navcfg")
  if self.link then self.link:send(navcfg.getFrame()) end
end

function C:setNavCfg(body, cb)
  self._navAckCb = cb
  local navcfg = require("nav.navcfg")
  if self.link then self.link:send(navcfg.setFrame(body)) end
end
```

Also route `nav_cfg_get`/`nav_cfg_set` in `nav/app.lua` modem accept list (the `f.k ==` guard around line 200).

Commit: `feat(config-overhaul): NAV PC serves settings over the wpt link`

---

### Task 6: DTC NAV role uses live navGet/navSet for eh2_nav.tbl

**Files:**
- Modify: `ui/basalt/bitconfig/dtc.lua`
- Test: `tests/test_bitconfig_dtc.lua`

**Interfaces:**
- `exportKind` for `kind=="nav"`: if `deps.navGet` then write disk from `navGet()` serialised body; never write `/eh2_nav.tbl` on the UI.
- `importKind` for `kind=="nav"`: if `deps.navSet` then `navSet(disk body)`; never write UI-local nav files.
- `nav_wpt` stays the exists-gate no-op on the UI (waypoints still use the NAV menu disk). Do not invent a second waypoint courier.
- `M.build` default `navGet`/`navSet`: from `runtime.wptClient.navCfg` (request if missing) / `setNavCfg` after unserialise.

Tests:

```lua
t.test("export nav role writes disk from navGet and never touches UI-local nav files", function()
  local written = {}
  local deps = {
    exists = function() return false end,
    read = function() return nil end,
    write = function(path, body) written[path] = body; return true end,
    delete = function() end,
    move = function(from, to) written[to] = written[from]; written[from] = nil end,
    navGet = function() return textutils.serialise({ channel = 65000 }) end,
  }
  local exported = M._export("disk0", deps, "nav")
  t.eq(#exported, 1)
  t.eq(exported[1], "nav")
  t.eq(written["/eh2_nav.tbl"], nil)
  t.truthy(written["/disk0/eh2_nav.tbl"] ~= nil)
end)

t.test("import nav role calls navSet from disk and never writes UI-local nav files", function()
  local setBody
  local localWrites = {}
  local deps = {
    exists = function(path) return path:find("eh2_nav") ~= nil end,
    read = function() return textutils.serialise({ channel = 7 }) end,
    write = function(path, body) localWrites[path] = body end,
    delete = function() end,
    move = function() end,
    navSet = function(body) setBody = body; return true end,
  }
  M._import("disk0", deps, "nav")
  t.truthy(setBody)
  t.eq(localWrites["/eh2_nav.tbl"], nil)
end)
```

Commit: `feat(config-overhaul): DTC dumps NAV settings from the running NAV PC`

---

## Self-Review

**Spec §3.1 fuelcal:** Task 1–3. **§3.5 per-config picker:** fuelcal added; missing DEFAULT fails like binding. **§3.4 UI DTC all three roles:** NAV settings (`eh2_nav.tbl`) over the wire; waypoints remain the existing NAV-menu courier (already shipped). Tuning DEFAULT snapshot still skipped (untouched).
