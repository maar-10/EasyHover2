# Config Overhaul — S2 (Live Write Path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invert the FCS config flow so the UI's BIT/CONFIG menus read and write the config on the **running FCS** live (FCS = single source of truth), and remove the old boot-pull-from-UI path.

**Architecture:** The FCS gains an always-listening, stateless per-request config responder **task** (a sibling of `tools/flight.lua`'s `commandTask`) on the existing `CFG_CH` channel pair `{req=105, reply=106}`. It serves reads and applies writes through a new pure module (`fcs/io/cfgaccess.lua`) that mirrors `tools/flight.lua`'s own `loadConfig` file-resolution (split-file preferred, fused legacy fallback). The pure protocol `fcs/comms/cfgsync.lua` is extended with `set`/`ack` frames. The UI drives it with an event-driven client (`ui/basalt/cfgclient.lua`, modeled on the proven `ui/basalt/wptclient.lua` — **not** `loaderui`'s blocking `uiSource`, because a blocking `os.pullEvent` inside the Basalt loop would eat the cockpit's own events), the BIT/CONFIG menus swap their default fs read/write seams for FCS-backed seams (`ui/basalt/cfgseam.lua`), and the old `ui/cfgserver.lua` + the FCS boot's "ui" source are deleted.

**Tech Stack:** Lua 5.1 (CC:Tweaked), CraftOS-PC headless test harness, Basalt 2.0 (loaded at runtime), `fcs.comms.modem` link wrapper + `fcs.comms.protocol` codec, `tests/framework.lua` unit harness, `tools/gen_manifest.lua` + `tools/closure.lua` manifest generator, `node tools/build.mjs` dist minifier.

## SCOPE NOTE — operator directive 2026-09-03 (S2 vs S2b split)

The operator directed: **all BIT/CONFIG menus that write FCS config must be self-contained** — their own measure/set logic writing config files **directly to the FCS** (the same files the FCS's own shell tools produce), with **no dependency on the diagnostic root tools S1 dropped**. The menus that currently lean on those tool concerns (measurement/binding) are to be **wired up in a dedicated later phase (S2b), before the whole-branch review — and deferred out of S2.**

**S2 executes ONLY: Task 1, 2, 3, 4, 5, 6, 7, 11, 12.** This is the live-write *foundation* (codec, provider, responder, client, seam, app wiring), the one **tool-independent** config menu (**TUNING**, T7), the FCS SYNC read-only checker (T11), and killing the boot-pull-from-UI path (T12 — forced by the CFG_CH inversion in T6: the UI cannot be both the config server and the client on the same channel pair).

**DEFERRED to phase S2b (a separate plan, before the final review): Tasks 8, 9, 10, 13** — repoint **MDB / SENS CAL / SENS SOURCE** and make them self-contained, repoint the **PFD "FCS" sens source** (`ui/basalt/senssource.lua M.resolve`, left as-is through S2), and only THEN remove the UI's local FCS config-file copies from the manifest (T13). Rationale: those menus + the PFD reader still read the UI-local `senscal`/`devbind` files, so the copies must stay until S2b repoints every reader. In the S2→S2b interim (all on one branch, merged only after the final review) those menus write local files the FCS no longer boot-pulls — a transitional gap S2b closes; every gate stays green throughout because those menus use injected/local seams.

## Global Constraints

- **Preserve apply-timing:** a `set` persists to the FCS's own file and hot-applies ONLY what is already hot today — CoM, via the existing `setCom` command path (`fcs/runtime/flight.lua:132`). Tuning/bindings still require an FCS reload; the UI must say so ("saved to FCS · reload to apply").
- **The fused `/eh2_hw_config.tbl` is READ-ONLY here** (a legacy fallback, retired in S5). Never write it.
- **Config trust boundary:** config writes ride the same craft-local trust as the existing `setCom` command — **no new auth token.**
- **Manifests are generated, never hand-edited:** after any `tools/gen_manifest.lua` edit run `bash tools/run_gen.sh`; the src/dist runners begin with `tools/run_gen.sh --check`.
- **`dist/` is generated:** S2 changes source bytes, so before every dist gate run `node tools/build.mjs` to regenerate the minified tree (the dist suite loads app modules from `dist/`). This is unlike S1, which changed no source bytes.
- **All gates green before each commit:** `bash tests/run_headless.sh` (src), `node tools/build.mjs` then `bash tests/run_headless_dist.sh` (dist), `bash tests/run_suite_e2e.sh` (e2e). Pure-logic tasks are fully TDD'd; modem/peripheral wiring is NOT headless-testable — keep the logic in pure modules and test those, mirroring `fcs/boot/loaderui.lua`'s and `beacon/update.lua`'s "the round-trip is the only in-game part" convention.
- **Test discovery is an EXPLICIT list, in TWO places:** `tests/run_headless.sh:33` and `tests/run_headless_dist.sh:31` each hold their own `suites` array. Every NEW test file must be appended to BOTH; every DELETED test file must be removed from BOTH. Prefer appending to an existing relevant test file where natural.
- **Commit trailers on every commit:**
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
  ```

---

## File Structure

**New files:**
- `fcs/io/cfgaccess.lua` — pure FCS-side provider/applier (per-kind file mapping). Task 2.
- `ui/basalt/cfgclient.lua` — pure event-driven UI cfg client over `CFG_CH`. Task 4.
- `ui/basalt/cfgseam.lua` — pure filename↔kind read/write seams the menus use. Task 5.
- `tests/test_cfgaccess.lua`, `tests/test_cfgclient.lua`, `tests/test_cfgseam.lua` — unit tests.

**Modified files:**
- `fcs/comms/cfgsync.lua` — add `set`/`ack`; extend `Responder.decide` with an applier. Task 1.
- `tools/flight.lua` — new `configTask` responder (wiring). Task 3.
- `ui/basalt/app.lua` — client + cache wiring, routing, tick, menu-open gate; drop cfgserver usage. Task 6.
- `ui/basalt/bitconfig/tuning.lua` / `mdb.lua` / `senscal.lua` / `senssource.lua` — swap default read/write seams. Tasks 7–10.
- `ui/basalt/bitconfig/fcssync.lua` — rewrite as a read-only checker. Task 11.
- `fcs/boot/loaderui.lua`, `fcs/boot/loader.lua` — remove the "ui" source. Task 12.
- `tools/gen_manifest.lua` + regenerated `manifest.lua`/`manifest-dev.lua` — ui `configs` → `/eh2_ui_config.tbl` only. Task 13.

**Deleted files:** `ui/cfgserver.lua`, `tests/test_cfgserver.lua`. Task 12.

**Deliberately unchanged — the fuel-cal menu:** the EMC CAL FUEL menu (`ui/basalt/regions/emc.lua` `M.calfuel` / `M._onFuel`) is ALREADY live against the FCS: picking a fuel sends a **command** (`EnginePanel.fuelCommand(id)` on the command channel), the FCS applies the scale and **persists** it itself (`tools/flight.lua:86` `saveFuel = cfgspec.save("fuelcal", ...)`), and the menu reflects the FCS's reported `state.fuel` from telemetry. It never reads or writes a UI-local `eh2_fuelcal.tbl` (the ui role's `configs` never even listed it). So there is **no fuelcal menu to repoint** — S2 leaves it untouched. (Covered in Self-Review.)

## Verified facts this plan rests on (research already done)

- **`fcs/comms/cfgsync.lua`** is pure tagged tables (`k` field): `M.hello/req/cfg`, `M.Responder.decide(frame, provider)`, `M.Client`. Existing tests: `tests/test_cfgsync.lua`.
- **`tools/flight.lua:40-53` `loadConfig`** prefers `cfgspec.tryAssemble(readSplit)` (the split pair) and falls back to the fused `/eh2_hw_config.tbl`; `tuning` via `hover.buildLoop`; `fuelcal` via `cfgspec.load("fuelcal", readFile)` at line 68. `readFile`/`writeFile` (lines 60-67) take a bare name and add `/`. `commandTask` is at lines 332-343; `flight` object and `modem` exist (lines 81, 109); `fault`, `modemlib` are required.
- **`fcs/io/cfgspec.lua`**: `FILES = {devbind, senscal, tuning, fuelcal}`; `load(kind, read) -> cfg, existed, err`; `save(kind, cfg, write)`; `merge`, `validate`, `splitLegacy(hw) -> {devbind, senscal}`, `tryAssemble(read)` (needs BOTH splits). `validate` required keys: devbind `{thrusters,sensors}`, senscal `{signPitch,signHeading}`, tuning `{gains,caps,feel}`, fuelcal `{fuel}`.
- **`fcs/boot/loaderui.lua`**: `M.CFG_CH = {req=105, reply=106}` (line 28); `ownSource` (81-97) is the split-else-fused pattern; `uiSource`/`waitForReply` (113-164) are the blocking client; `buildSources` (167-177) has the "ui" branch; `closeCfgChannels` (221-228). `loader.SOURCES` (`fcs/boot/loader.lua:4-9`) lists `"ui"` for binding/sensor/tuning.
- **`ui/basalt/app.lua`**: `M.CFG_CH = {req=105, reply=106}` (line 102); `buildRuntime` wires `cfgLink = modemlib.wrap(modem, {txCh=CFG_CH.reply, rxCh=CFG_CH.req})` (line 446, **server** direction) and `cfgserver = CfgServer.new{...}` (548); `routeModem` routes `CFG_CH.req` → `cfgserver:onMessage` (607-614). `wptClient` (an event-driven request/reply client) is the in-app precedent: `ui/basalt/wptclient.lua` (`:onReply(frame,now)`, `:refreshOnline`, fire-and-forget sends; ticked in a 2s `basalt.schedule` loop). `showScreen` (line ~) builds a page frame once and caches it in `frameRec.built[screenId]`.
- **The BIT/CONFIG menus abstract fs behind injected seams**: `M.build(basalt, frame, runtime, nav, read, write[, ...])`, defaulting `read`/`write` to module-local `realRead`/`realWrite` (fs). Menu tests inject their own `read`/`write` (or call `M._save` with a write spy) — so swapping only the DEFAULT seam leaves those tests untouched. `tuning.lua`'s COM screen already hot-applies CoM via `runtime.sender:send({k="setCom",...})` on the command channel (`pushCom`, lines 756-764) — that stays.
- **`ui/basalt/senssource.lua` `M.resolve`** (the PFD attitude reader, distinct from the bitconfig menu) reads the UI's LOCAL `eh2_senscal.tbl`+`eh2_devbind.tbl` for its "FCS" source. This coupling is flagged for the controller (see Self-Review §4); S2 does not change this reader.

---

### Task 1: Extend the `cfgsync` codec with `set`/`ack`

**Files:**
- Modify: `fcs/comms/cfgsync.lua` (add frames + extend `Responder.decide`)
- Test: `tests/test_cfgsync.lua` (append)

**Interfaces:**
- Produces: `cfgsync.set(sid, kind, body) -> {k="set",...}`; `cfgsync.ack(sid, kind, ok, err) -> {k="ack", ok=<bool>, err=<string|nil>}`; `cfgsync.Responder.decide(frame, provider, applier)` — for `req` returns `cfg` when `provider(kind)~=nil` (unchanged), for `set` returns `ack` from `applier(kind, body) -> ok, err`, else `nil`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests (RED)**

Append to `tests/test_cfgsync.lua`:

```lua
t.test("set/ack frame builders carry sid/kind/ok/err", function()
  local s = S.set("s2", "tuning", { gains = 1 })
  t.eq(s.k, "set"); t.eq(s.sid, "s2"); t.eq(s.kind, "tuning"); t.eq(s.body.gains, 1)
  local a = S.ack("s2", "tuning", true, nil)
  t.eq(a.k, "ack"); t.eq(a.sid, "s2"); t.eq(a.kind, "tuning"); t.eq(a.ok, true); t.eq(a.err, nil)
  t.eq(S.ack("s2", "tuning", false, "bad").ok, false)
  t.eq(S.ack("s2", "tuning", nil, "bad").ok, false, "ok is always a bool")
end)

t.test("responder applies a set via the injected applier and returns an ack", function()
  local seen = {}
  local applier = function(kind, body) seen.kind = kind; seen.body = body; return true, nil end
  local reply = S.Responder.decide(S.set("s3", "devbind", { thrusters = {} }), nil, applier)
  t.eq(reply.k, "ack"); t.eq(reply.kind, "devbind"); t.eq(reply.ok, true); t.eq(reply.sid, "s3")
  t.eq(seen.kind, "devbind"); t.truthy(seen.body.thrusters ~= nil)
end)

t.test("responder ack carries the applier's failure reason", function()
  local reply = S.Responder.decide(S.set("s4", "tuning", {}), nil, function() return false, "missing gains" end)
  t.eq(reply.k, "ack"); t.eq(reply.ok, false); t.eq(reply.err, "missing gains")
end)

t.test("a set with no applier is ignored (nil), and req still works unchanged", function()
  t.eq(S.Responder.decide(S.set("s5", "tuning", {}), nil, nil), nil, "no applier -> silent")
  local r = S.Responder.decide(S.req("s5", "tuning"), function(k) return k == "tuning" and "BODY" or nil end)
  t.eq(r.k, "cfg"); t.eq(r.body, "BODY")
end)
```

- [ ] **Step 2: Run the tests to verify they FAIL**

Run: `bash tests/run_headless.sh`
Expected: FAIL in `tests.test_cfgsync` — `S.set`/`S.ack` are nil, and `decide` ignores the third argument.

- [ ] **Step 3: Implement `set`/`ack` and extend `Responder.decide`**

In `fcs/comms/cfgsync.lua`, add the two builders after the existing `M.cfg` line (line 12):

```lua
function M.set(sid, kind, body) return { k = "set", sid = sid, kind = kind, body = body } end
function M.ack(sid, kind, ok, err) return { k = "ack", sid = sid, kind = kind, ok = ok and true or false, err = err } end
```

Replace the existing `Responder.decide` (lines 16-21) with:

```lua
-- Responder: gated. `req` is answered only when the provider holds the requested kind (unchanged);
-- `set` is applied via the injected applier (validate + persist) and always acked (ok=false+err on
-- failure). `applier(kind, body) -> ok, err`. A `set` with no applier is ignored.
function M.Responder.decide(frame, provider, applier)
  if type(frame) ~= "table" then return nil end
  if frame.k == "req" then
    local body = provider and provider(frame.kind)
    if body ~= nil then return M.cfg(frame.sid, frame.kind, body) end
    return nil
  elseif frame.k == "set" then
    if not applier then return nil end
    local ok, err = applier(frame.kind, frame.body)
    return M.ack(frame.sid, frame.kind, ok, err)
  end
  return nil
end
```

- [ ] **Step 4: Run the tests to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: `tests.test_cfgsync` passes, including the existing `responder answers req...` and `client walks hello...` tests (backward-compatible: `decide(req, provider)` behaves exactly as before).

- [ ] **Step 5: Run the dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green.

```bash
git add fcs/comms/cfgsync.lua tests/test_cfgsync.lua dist/fcs/comms/cfgsync.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): cfgsync codec gains set/ack frames

Add set(sid,kind,body)/ack(sid,kind,ok,err) frames and extend
Responder.decide with an injected applier so a set is validated+persisted
and acked. req/cfg reads are unchanged and backward-compatible. Pure, TDD.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 2: FCS config provider/applier (`fcs/io/cfgaccess.lua`)

**Files:**
- Create: `fcs/io/cfgaccess.lua`
- Test: `tests/test_cfgaccess.lua` (new)
- Modify: `tests/run_headless.sh:33` and `tests/run_headless_dist.sh:31` (append `"tests.test_cfgaccess"` to each `suites` list)

**Interfaces:**
- Consumes: `fcs.io.cfgspec` (`load/save/merge/validate/splitLegacy/FILES`).
- Produces:
  - `cfgaccess.getKind(kind, read) -> cfgTable` — the FCS's live cfg for `kind`.
  - `cfgaccess.setKind(kind, body, read, write) -> ok, err` — validate + persist (+ materialize sibling split for devbind/senscal).
  - `cfgaccess.FUSED = "eh2_hw_config.tbl"`.
  - `read`/`write` are injected `(name)->body|nil` / `(name, body)` seams using bare filenames (matching `cfgspec`'s contract and `tools/flight.lua`'s `readFile`/`writeFile`).

- [ ] **Step 1: Write the failing tests (RED)**

Create `tests/test_cfgaccess.lua`:

```lua
-- tests/test_cfgaccess.lua
local t = require("tests.framework")
local A = require("fcs.io.cfgaccess")
local cfgspec = require("fcs.io.cfgspec")
local hwconfig = require("fcs.io.hwconfig")

-- A fake fs: bare-name keyed store, matching cfgspec's write(name, body)/read(name) contract.
local function fakeFs(seed)
  local files = {}
  for k, v in pairs(seed or {}) do files[k] = v end
  return files,
    function(name) return files[name] end,
    function(name, body) files[name] = body; return true end
end

t.test("getKind tuning/fuelcal load their own file (merged with defaults)", function()
  local files, read = fakeFs({ ["eh2_tuning.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.42 } }) })
  local tuning = A.getKind("tuning", read)
  t.eq(tuning.gains.hoverDuty, 0.42, "saved value survives the merge")
  t.truthy(tuning.caps ~= nil, "defaults fill the rest")
  local fuel = A.getKind("fuelcal", (select(2, fakeFs({}))))
  t.truthy(fuel.fuel ~= nil, "fuelcal defaults when no file")
end)

t.test("getKind devbind prefers the split file when present", function()
  local db = cfgspec.defaults("devbind"); db.fuelRelay = "relay_7"
  local _, read = fakeFs({ ["eh2_devbind.tbl"] = textutils.serialise(db) })
  t.eq(A.getKind("devbind", read).fuelRelay, "relay_7")
end)

t.test("getKind devbind falls back to the fused legacy slice when no split", function()
  local legacy = hwconfig.defaults(); legacy.thrusters.MAIN = "main_thruster_9"
  local _, read = fakeFs({ [A.FUSED] = textutils.serialise(legacy) })
  local db = A.getKind("devbind", read)
  t.eq(db.thrusters.MAIN, "main_thruster_9", "reads the fused thrusters slice")
end)

t.test("getKind devbind returns merged defaults when neither split nor fused exists", function()
  local _, read = fakeFs({})
  local db = A.getKind("devbind", read)
  t.truthy(db.thrusters ~= nil and db.sensors ~= nil, "fresh FCS is still editable, never nil")
end)

t.test("setKind rejects an invalid body without writing", function()
  local files, read, write = fakeFs({})
  local ok, err = A.setKind("tuning", { caps = {} }, read, write)  -- missing gains/feel
  t.eq(ok, false); t.truthy(err)
  t.eq(files["eh2_tuning.tbl"], nil, "nothing written on a failed validate")
end)

t.test("setKind tuning validates and persists to its own file", function()
  local files, read, write = fakeFs({})
  local ok = A.setKind("tuning", cfgspec.defaults("tuning"), read, write)
  t.eq(ok, true); t.truthy(files["eh2_tuning.tbl"] ~= nil)
end)

t.test("setKind devbind writes the split AND materializes the senscal sibling from the fused slice", function()
  local legacy = hwconfig.defaults()
  local files, read, write = fakeFs({ [A.FUSED] = textutils.serialise(legacy) })
  local ok = A.setKind("devbind", cfgspec.defaults("devbind"), read, write)
  t.eq(ok, true)
  t.truthy(files["eh2_devbind.tbl"] ~= nil, "devbind split written")
  t.truthy(files["eh2_senscal.tbl"] ~= nil, "sibling senscal split materialized so tryAssemble uses the pair")
  local sib = textutils.unserialise(files["eh2_senscal.tbl"])
  t.truthy(sib.signPitch ~= nil, "sibling seeded from the fused senscal slice")
end)

t.test("setKind senscal materializes a devbind sibling from defaults when no fused exists", function()
  local files, read, write = fakeFs({})
  local ok = A.setKind("senscal", cfgspec.defaults("senscal"), read, write)
  t.eq(ok, true)
  t.truthy(files["eh2_devbind.tbl"] ~= nil, "sibling devbind materialized from defaults")
end)

t.test("setKind does NOT clobber an existing sibling split", function()
  local db = cfgspec.defaults("devbind"); db.fuelRelay = "keep_me"
  local files, read, write = fakeFs({ ["eh2_devbind.tbl"] = textutils.serialise(db) })
  A.setKind("senscal", cfgspec.defaults("senscal"), read, write)
  t.eq(textutils.unserialise(files["eh2_devbind.tbl"]).fuelRelay, "keep_me", "present sibling untouched")
end)
```

- [ ] **Step 2: Run to verify FAIL (module missing)**

Run: `lua tests/test_cfgaccess.lua` is not the harness — instead add the suite entry first so the runner picks it up. Append `"tests.test_cfgaccess"` to the `suites` list in `tests/run_headless.sh:33` (end of the array, before the closing `}`) and identically in `tests/run_headless_dist.sh:31`. Then:
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'fcs.io.cfgaccess' not found`.

- [ ] **Step 3: Implement `fcs/io/cfgaccess.lua`**

Create `fcs/io/cfgaccess.lua`:

```lua
-- fcs/io/cfgaccess.lua
-- Pure FCS-side config provider/applier for the live config responder (tools/flight.lua's
-- configTask). getKind resolves a kind's live cfg EXACTLY as tools/flight.lua's loadConfig does
-- (split file preferred, fused /eh2_hw_config.tbl as a read-only fallback); setKind validates and
-- persists to the FCS's OWN files (never the fused legacy) and materializes the sibling split for
-- devbind/senscal so cfgspec.tryAssemble (which needs BOTH splits) actually uses the operator's
-- change next boot. read/write are injected (bare filename, matching cfgspec + tools/flight.lua's
-- readFile/writeFile). NO peripherals/os/Basalt.
local cfgspec = require("fcs.io.cfgspec")

local M = {}
M.FUSED = "eh2_hw_config.tbl"   -- read-only legacy fallback (retired in S5); never written here

local SIBLING = { devbind = "senscal", senscal = "devbind" }

-- splitLegacy(fused) | nil (nil = no/unparseable fused file). PURE.
local function fusedSplit(read)
  local body = read(M.FUSED)
  if body == nil then return nil end
  local hw = textutils.unserialise(body)
  if type(hw) ~= "table" then return nil end
  return cfgspec.splitLegacy(hw)
end

-- getKind(kind, read) -> the FCS's live cfg TABLE. tuning/fuelcal: their own file, merged with
-- defaults. devbind/senscal: the split file if present; else the fused legacy slice, merged
-- (mirrors fcs/boot/loaderui.lua's ownSource); else merged defaults (a fresh FCS stays editable --
-- never a nil the UI would read as "FCS silent").
function M.getKind(kind, read)
  if kind == "tuning" or kind == "fuelcal" then
    return (cfgspec.load(kind, read))
  end
  if kind == "devbind" or kind == "senscal" then
    local cfg, existed, err = cfgspec.load(kind, read)
    if existed and not err then return cfg end
    local split = fusedSplit(read)
    local seed = split and split[kind]
    if seed ~= nil then return cfgspec.merge(kind, seed) end
    return cfgspec.merge(kind, {})
  end
  error("cfgaccess: unknown kind " .. tostring(kind))
end

-- setKind(kind, body, read, write) -> ok, err. Validate then persist. For devbind/senscal also
-- materialize the sibling split when absent (seeded from the fused slice if any, else defaults).
function M.setKind(kind, body, read, write)
  local ok, err = cfgspec.validate(kind, body)
  if not ok then return false, err end
  if kind == "tuning" or kind == "fuelcal" then
    cfgspec.save(kind, body, write)
    return true
  end
  if kind == "devbind" or kind == "senscal" then
    cfgspec.save(kind, body, write)
    local sib = SIBLING[kind]
    local _, sibExisted = cfgspec.load(sib, read)
    if not sibExisted then
      local split = fusedSplit(read)
      local seed = split and split[sib]
      cfgspec.save(sib, cfgspec.merge(sib, seed or {}), write)
    end
    return true
  end
  return false, "unknown kind"
end

return M
```

- [ ] **Step 4: Run to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: `tests.test_cfgaccess` passes (all 9 cases).

- [ ] **Step 5: Dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green (the new module is now in `dist/`).

```bash
git add fcs/io/cfgaccess.lua tests/test_cfgaccess.lua tests/run_headless.sh tests/run_headless_dist.sh dist/fcs/io/cfgaccess.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): pure FCS config provider/applier (cfgaccess)

getKind resolves a kind's live cfg exactly as tools/flight.lua's loadConfig
(split preferred, fused legacy fallback, merged defaults for a fresh FCS);
setKind validates + persists to the FCS's own files and materializes the
sibling split for devbind/senscal so tryAssemble uses the pair next boot.
Never writes the fused legacy. Pure, TDD.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 3: FCS live config responder task (`tools/flight.lua`)

**Files:**
- Modify: `tools/flight.lua` (add `CFG_CH`, `cfgsync`/`cfgaccess` requires, `configTask`, register it in both `parallel.waitForAny` groups)

**Interfaces:**
- Consumes: `cfgsync.Responder.decide` (Task 1), `cfgaccess.getKind/setKind` (Task 2), the file `readFile`/`writeFile` (lines 60-67), the `flight` object (`flight:handleCommand`, line 132), `modem`, `modemlib`, `fault.protect`.
- Produces: an always-listening responder on `CFG_CH = {req=105, reply=106}` (rx `req`, tx `reply`). Stateless per request.

> **Not headless-tested** (no modem in the CraftOS-PC harness): this is thin wiring around the pure, tested `cfgaccess` + `cfgsync` — mirroring `fcs/boot/loaderui.lua`'s and `tools/flight.lua`'s own "in-game only, validated in flight" convention. There is no failing-test step; the deliverable is verified by the src/dist/e2e gates staying green (the module still loads and the existing FCS tests pass) plus code review against the mirrored `commandTask`.

- [ ] **Step 1: Add the requires and the channel constant**

In `tools/flight.lua`, after `local LogBuffer = require("fcs.bringup.logbuffer")` (line 29) add:

```lua
local cfgsync   = require("fcs.comms.cfgsync")
local cfgaccess = require("fcs.io.cfgaccess")
```

Change line 31 (`local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }`) to add the config pair beneath it:

```lua
local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
-- Config responder pair (105/106): separate from telemetry/command/ack/health so live config
-- traffic never touches the control-loop comms budget. Ownership moved here from fcs/boot/loaderui
-- (S2): the boot no longer pulls config from the UI; the UI now reads/writes THIS FCS live.
local CFG_CH = { req = 105, reply = 106 }
```

- [ ] **Step 2: Open the config channels next to the others**

In the `-- ---- Comms ----` block, after `for _, c in pairs(CH) do modem.open(c) end` (line 110), add:

```lua
for _, c in pairs(CFG_CH) do modem.open(c) end
local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.reply, rxCh = CFG_CH.req })
```

- [ ] **Step 3: Add the `configTask` (model on `commandTask`, lines 332-343)**

Immediately after `commandTask` (after its closing `end` at line 343) add:

```lua
-- ---- Live config responder (CFG_CH): serves the UI's BIT/CONFIG menus from THIS FCS's own config
-- files and applies their writes. Stateless per request (a sibling of commandTask): each req/set is
-- self-contained, handled between control ticks -- no config "session" state. Traffic occurs only
-- when the operator opens/saves a menu. Reads/writes go through fcs.io.cfgaccess (pure, tested).
local function cfgProvider(kind) return cfgaccess.getKind(kind, readFile) end
local function cfgApplier(kind, body)
  local ok, err = cfgaccess.setKind(kind, body, readFile, writeFile)
  -- Apply-timing preserved: the ONLY hot config change is CoM. A tuning set carrying com{} is
  -- pushed to the mixer LIVE via the same setCom path the COM screen uses, so a hand trim takes
  -- effect now; tuning/bindings otherwise need an FCS reload. Idempotent with the COM screen's own
  -- command-channel setCom (fcs/runtime/flight.lua:132).
  if ok and kind == "tuning" and type(body) == "table" and type(body.com) == "table" then
    pcall(function()
      flight:handleCommand({ k = "setCom",
        fwd = body.com.fwd or 0, right = body.com.right or 0,
        spanFwd = body.com.spanFwd or body.com.span, spanRight = body.com.spanRight or body.com.span })
    end)
  end
  return ok, err
end

local function configTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame_ = cfgLink:onMessage(ch, msg)
    if frame_ then
      fault.protect(function()
        local reply = cfgsync.Responder.decide(frame_, cfgProvider, cfgApplier)
        if reply then cfgLink:send(reply) end
      end)
    end
  end
end
```

- [ ] **Step 4: Register `configTask` in both task groups**

In the `if LOGGING then` branch (line 398-399) add `configTask` to the `parallel.waitForAny` argument list, and identically in the `else` branch (line 404-405):

```lua
-- LOGGING branch:
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask,
                        healthTask, fuelTask, statusTask, logKeyTask, configTask)
```
```lua
-- non-LOGGING branch:
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask,
                        healthTask, fuelTask, statusTask, configTask)
```

- [ ] **Step 5: Verify module still loads clean + all gates green, then commit**

`tools/flight.lua` is in-game only (not required by any test), but the dist/e2e install phases copy it — a syntax error would break them. Run:
Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green (no test change; regression-only).

```bash
git add tools/flight.lua dist/tools/flight.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): FCS live config responder task (CFG_CH)

Add configTask, a stateless per-request sibling of commandTask on the 105/106
config pair: serves the UI's config-menu reads from this FCS's own files and
applies writes via the pure cfgaccess module, hot-applying CoM through the
existing setCom path (tuning/bindings still need a reload). Not headless-tested
(no modem in the harness); logic lives in the tested pure modules.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 4: UI config client (`ui/basalt/cfgclient.lua`)

**Files:**
- Create: `ui/basalt/cfgclient.lua`
- Test: `tests/test_cfgclient.lua` (new) + append `"tests.test_cfgclient"` to both `suites` lists.

**Interfaces:**
- Consumes: `fcs.comms.cfgsync` (`hello/req/set/cfg/ack`), an injected `link` (a `fcs.comms.modem` Link with `:send(frame)`), injected `now()`.
- Produces:
  - `cfgclient.new({ link, timeout=2.0, retries=3, now }) -> client`
  - `client:readKind(kind, cb) -> sid` (`cb(bodyTable|nil)`; nil = FCS silent after all retries)
  - `client:writeKind(kind, bodyTable, cb) -> sid` (`cb(ok, err)`; `false, "FCS not answering"` on timeout)
  - `client:onReply(frame, now) -> bool` (resolves a pending request; called by the UI modem router)
  - `client:tick(now)` (resend timed-out requests up to `retries`, then fail the callback)

> Timeout/retry policy = **2 s × 3 attempts**, matching `fcs/boot/loaderui.lua`'s `UI_TIMEOUT`/`UI_RETRIES`. The client is event-driven (never blocks), modeled on `ui/basalt/wptclient.lua` — a blocking wait inside the Basalt loop would eat the cockpit's own events.

- [ ] **Step 1: Write the failing tests (RED)**

Create `tests/test_cfgclient.lua`:

```lua
-- tests/test_cfgclient.lua
local t = require("tests.framework")
local C = require("ui.basalt.cfgclient")
local S = require("fcs.comms.cfgsync")

-- A mock link: records every frame passed to :send.
local function mockLink()
  local sent = {}
  return { sent = sent, send = function(self, f) sent[#sent + 1] = f end }
end

t.test("readKind sends hello+req and delivers a matching cfg reply to the callback", function()
  local link = mockLink()
  local c = C.new({ link = link, now = function() return 1000 end })
  local got
  local sid = c:readKind("tuning", function(body) got = body end)
  t.eq(link.sent[1].k, "hello"); t.eq(link.sent[2].k, "req"); t.eq(link.sent[2].kind, "tuning")
  t.eq(c:onReply(S.cfg(sid, "tuning", { gains = 7 }), 1100), true, "reply resolved a pending read")
  t.eq(got.gains, 7)
  t.eq(c:onReply(S.cfg(sid, "tuning", { gains = 9 }), 1200), false, "already resolved -> no double fire")
end)

t.test("a cfg reply with a mismatched sid or kind is ignored", function()
  local c = C.new({ link = mockLink(), now = function() return 0 end })
  local fired = false
  local sid = c:readKind("tuning", function() fired = true end)
  t.eq(c:onReply(S.cfg("other", "tuning", {}), 1), false)
  t.eq(c:onReply(S.cfg(sid, "senscal", {}), 1), false)
  t.eq(fired, false)
end)

t.test("writeKind sends a set and delivers the ack (ok/err) to the callback", function()
  local link = mockLink()
  local c = C.new({ link = link, now = function() return 0 end })
  local okSeen, errSeen, called
  local sid = c:writeKind("devbind", { thrusters = {} }, function(ok, err) called = true; okSeen = ok; errSeen = err end)
  t.eq(link.sent[1].k, "set"); t.eq(link.sent[1].kind, "devbind")
  c:onReply(S.ack(sid, "devbind", false, "missing sensors"), 1)
  t.eq(called, true); t.eq(okSeen, false); t.eq(errSeen, "missing sensors")
end)

t.test("tick resends up to `retries` attempts then fails the callback", function()
  local now = 0
  local link = mockLink()
  local c = C.new({ link = link, retries = 3, timeout = 2.0, now = function() return now end })
  local failBody, failCalled = "unset", false
  c:readKind("tuning", function(body) failCalled = true; failBody = body end)
  -- attempt 1 already sent (hello+req = 2 frames). Advance past each deadline: 2 more attempts.
  now = 2000; c:tick(now)   -- attempt 2
  now = 4000; c:tick(now)   -- attempt 3
  t.truthy(#link.sent >= 6, "three attempts each sent hello+req")
  t.eq(failCalled, false, "not failed yet -- retries not exhausted")
  now = 6000; c:tick(now)   -- past attempt 3's deadline, tries == retries -> fail
  t.eq(failCalled, true); t.eq(failBody, nil, "read failure delivers nil")
end)

t.test("tick failure for a write delivers (false, 'FCS not answering')", function()
  local now = 0
  local c = C.new({ link = mockLink(), retries = 1, timeout = 2.0, now = function() return now end })
  local ok, err, called
  c:writeKind("tuning", {}, function(o, e) called = true; ok = o; err = e end)
  now = 2000; c:tick(now)
  t.eq(called, true); t.eq(ok, false); t.eq(err, "FCS not answering")
end)
```

- [ ] **Step 2: Run to verify FAIL**

Append `"tests.test_cfgclient"` to `tests/run_headless.sh:33` and `tests/run_headless_dist.sh:31`.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'ui.basalt.cfgclient' not found`.

- [ ] **Step 3: Implement `ui/basalt/cfgclient.lua`**

Create `ui/basalt/cfgclient.lua`:

```lua
-- ui/basalt/cfgclient.lua
-- Cockpit-side client for the FCS's live config responder (CFG_CH: send req/set on 105, hear
-- cfg/ack on 106). Event-driven (mirrors ui/basalt/wptclient.lua): readKind/writeKind are
-- fire-and-forget with a callback; replies land via the UI modem router -> onReply, and a periodic
-- tick() retransmits timed-out requests (2 s x 3, matching fcs/boot/loaderui.lua's UI_TIMEOUT/
-- UI_RETRIES) and fails the callback when the FCS stays silent. A blocking wait would eat the
-- cockpit's own events, so nothing here blocks. NO peripheral/Basalt access at module load.
local cfgsync = require("fcs.comms.cfgsync")

local M = {}
local C = {}
C.__index = C

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    link = opts.link,
    timeout = opts.timeout or 2.0,   -- seconds per attempt
    retries = opts.retries or 3,     -- total attempts
    now = opts.now or function() return os.epoch("utc") end,
    seq = 0,
    pending = {},   -- sid -> { kind, op="read"|"write", body?, cb, tries, deadline(ms) }
  }, C)
end

function C:_sid()
  self.seq = self.seq + 1
  return "cfg-" .. tostring(self.now()) .. "-" .. tostring(self.seq)
end

function C:_sendRead(sid, kind)
  if self.link then self.link:send(cfgsync.hello(sid)); self.link:send(cfgsync.req(sid, kind)) end
end
function C:_sendWrite(sid, kind, body)
  if self.link then self.link:send(cfgsync.set(sid, kind, body)) end
end

-- readKind(kind, cb): cb(bodyTable|nil). nil = FCS silent after all retries.
function C:readKind(kind, cb)
  local sid = self:_sid()
  self.pending[sid] = { kind = kind, op = "read", cb = cb, tries = 1,
                        deadline = self.now() + self.timeout * 1000 }
  self:_sendRead(sid, kind)
  return sid
end

-- writeKind(kind, body, cb): cb(ok, err). (false, "FCS not answering") on timeout.
function C:writeKind(kind, body, cb)
  local sid = self:_sid()
  self.pending[sid] = { kind = kind, op = "write", body = body, cb = cb, tries = 1,
                        deadline = self.now() + self.timeout * 1000 }
  self:_sendWrite(sid, kind, body)
  return sid
end

-- onReply(frame, now) -> true if it resolved a pending request. Called by the UI modem router.
function C:onReply(frame, now)
  if type(frame) ~= "table" or frame.sid == nil then return false end
  local p = self.pending[frame.sid]
  if not p then return false end
  if p.op == "read" and frame.k == "cfg" and frame.kind == p.kind then
    self.pending[frame.sid] = nil
    if p.cb then p.cb(frame.body) end
    return true
  end
  if p.op == "write" and frame.k == "ack" and frame.kind == p.kind then
    self.pending[frame.sid] = nil
    if p.cb then p.cb(frame.ok and true or false, frame.err) end
    return true
  end
  return false
end

-- tick(now): retransmit timed-out requests up to `retries`; then fail the callback.
function C:tick(now)
  now = now or self.now()
  for sid, p in pairs(self.pending) do
    if now >= p.deadline then
      if p.tries >= self.retries then
        self.pending[sid] = nil
        if p.cb then
          if p.op == "read" then p.cb(nil) else p.cb(false, "FCS not answering") end
        end
      else
        p.tries = p.tries + 1
        p.deadline = now + self.timeout * 1000
        if p.op == "read" then self:_sendRead(sid, p.kind) else self:_sendWrite(sid, p.kind, p.body) end
      end
    end
  end
end

return M
```

- [ ] **Step 4: Run to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: `tests.test_cfgclient` passes (all 5 cases).

- [ ] **Step 5: Dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green.

```bash
git add ui/basalt/cfgclient.lua tests/test_cfgclient.lua tests/run_headless.sh tests/run_headless_dist.sh dist/ui/basalt/cfgclient.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): event-driven UI cfg client over CFG_CH

Add ui/basalt/cfgclient (modeled on wptclient): readKind/writeKind are
fire-and-forget with callbacks, replies resolve via onReply, and tick()
retransmits timed-out requests 2s x 3 then fails the callback -- never
blocking the Basalt loop. Pure, tested with a mock link.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 5: FCS-backed read/write seams (`ui/basalt/cfgseam.lua`)

**Files:**
- Create: `ui/basalt/cfgseam.lua`
- Test: `tests/test_cfgseam.lua` (new) + append `"tests.test_cfgseam"` to both `suites` lists.

**Interfaces:**
- Consumes: `fcs.io.cfgspec` (`FILES`), a `runtime` with `cfgCache` (kind → `{ body = table }`) and `cfgClient` (`:writeKind`).
- Produces:
  - `cfgseam.kindOf(filename) -> kind|nil` (reverse of `cfgspec.FILES`, bare filename).
  - `cfgseam.read(runtime) -> function(filename) -> serializedBody|nil` (nil ⇒ `cfgspec.load` merges defaults).
  - `cfgseam.write(runtime, onDone) -> function(filename, body)` — unserialises the menu's cfg and ships it via `runtime.cfgClient:writeKind`; `onDone(kind, ok, err)` fires on ack/timeout.

> This is what lets the menus keep calling `cfgspec.load/save(kind, ...)` **unchanged** — only their DEFAULT seam moves from local fs to the FCS. Menu tests that inject their own `read`/`write` never touch this module.

- [ ] **Step 1: Write the failing tests (RED)**

Create `tests/test_cfgseam.lua`:

```lua
-- tests/test_cfgseam.lua
local t = require("tests.framework")
local seam = require("ui.basalt.cfgseam")
local cfgspec = require("fcs.io.cfgspec")

t.test("kindOf maps bare config filenames back to their kind", function()
  t.eq(seam.kindOf(cfgspec.FILES.devbind), "devbind")
  t.eq(seam.kindOf(cfgspec.FILES.tuning), "tuning")
  t.eq(seam.kindOf("eh2_ui_config.tbl"), nil, "non-FCS files have no kind")
end)

t.test("read serves the cached body serialised (so cfgspec.load can parse it), nil when absent", function()
  local runtime = { cfgCache = { tuning = { body = { gains = { hoverDuty = 0.5 } } } } }
  local read = seam.read(runtime)
  local parsed = textutils.unserialise(read(cfgspec.FILES.tuning))
  t.eq(parsed.gains.hoverDuty, 0.5)
  t.eq(read(cfgspec.FILES.senscal), nil, "uncached kind -> nil (load merges defaults)")
  -- cfgspec.load round-trips through this read seam exactly as the menu calls it:
  local loaded = cfgspec.load("tuning", read)
  t.eq(loaded.gains.hoverDuty, 0.5)
end)

t.test("write unserialises the menu's cfg and ships it via cfgClient:writeKind", function()
  local calls = {}
  local runtime = { cfgClient = { writeKind = function(self, kind, body, cb)
    calls[#calls + 1] = { kind = kind, body = body, cb = cb } end } }
  local done = {}
  local write = seam.write(runtime, function(kind, ok, err) done = { kind = kind, ok = ok, err = err } end)
  -- the menu calls write(filename, serialisedBody) exactly as cfgspec.save does:
  cfgspec.save("devbind", cfgspec.defaults("devbind"), write)
  t.eq(#calls, 1); t.eq(calls[1].kind, "devbind"); t.truthy(calls[1].body.thrusters ~= nil)
  calls[1].cb(true, nil)   -- simulate the ack
  t.eq(done.kind, "devbind"); t.eq(done.ok, true)
end)

t.test("write refuses a non-FCS filename (no kind) without calling writeKind", function()
  local called = false
  local runtime = { cfgClient = { writeKind = function() called = true end } }
  local write = seam.write(runtime, nil)
  t.eq(write("eh2_ui_config.tbl", textutils.serialise({})), false)
  t.eq(called, false)
end)
```

- [ ] **Step 2: Run to verify FAIL**

Append `"tests.test_cfgseam"` to both `suites` lists.
Run: `bash tests/run_headless.sh`
Expected: FAIL — `module 'ui.basalt.cfgseam' not found`.

- [ ] **Step 3: Implement `ui/basalt/cfgseam.lua`**

Create `ui/basalt/cfgseam.lua`:

```lua
-- ui/basalt/cfgseam.lua
-- FCS-backed read/write seams for the BIT/CONFIG menus. read() serves a serialised body from
-- runtime.cfgCache (populated by the cfg client's read replies); write() ships the change to the
-- running FCS via runtime.cfgClient:writeKind. Filename<->kind is cfgspec.FILES reversed, so the
-- menus keep calling cfgspec.load/save(kind, ...) unchanged -- only their DEFAULT seam moves from
-- local fs to the FCS. NO Basalt/peripheral/fs access here.
local cfgspec = require("fcs.io.cfgspec")

local M = {}

local KIND_BY_FILE = {}
for kind, file in pairs(cfgspec.FILES) do KIND_BY_FILE[file] = kind end

-- menus pass the bare filename (no leading slash), matching cfgspec.save/load's own contract.
function M.kindOf(filename) return KIND_BY_FILE[filename] end

-- read(runtime) -> function(filename) -> serialised body | nil (nil => cfgspec.load merges defaults)
function M.read(runtime)
  return function(filename)
    local kind = M.kindOf(filename)
    local c = kind and runtime.cfgCache and runtime.cfgCache[kind]
    if c and c.body ~= nil then return textutils.serialise(c.body) end
    return nil
  end
end

-- write(runtime, onDone) -> function(filename, body). Unserialises the menu's serialised cfg and
-- ships it to the FCS. onDone(kind, ok, err) fires when the ack (or timeout) arrives.
function M.write(runtime, onDone)
  return function(filename, body)
    local kind = M.kindOf(filename)
    if not kind then return false end
    local tbl = textutils.unserialise(body)
    if type(tbl) ~= "table" then return false end
    runtime.cfgClient:writeKind(kind, tbl, function(ok, err)
      if onDone then onDone(kind, ok, err) end
    end)
    return true
  end
end

return M
```

- [ ] **Step 4: Run to verify GREEN, then all gates + commit**

Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green.

```bash
git add ui/basalt/cfgseam.lua tests/test_cfgseam.lua tests/run_headless.sh tests/run_headless_dist.sh dist/ui/basalt/cfgseam.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): FCS-backed cfg read/write seams for the menus

ui/basalt/cfgseam maps config filename<->kind so the BIT/CONFIG menus keep
calling cfgspec.load/save unchanged while their default seam reads from
runtime.cfgCache and writes via runtime.cfgClient:writeKind. Pure, tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 6: UI runtime wiring — client + cache + menu-open gate (`ui/basalt/app.lua`)

**Files:**
- Modify: `ui/basalt/app.lua` (require + buildRuntime + routeModem + startScheduled + showScreen gate + `M.cfgMenuStatus`; drop cfgserver usage)
- Test: `tests/test_basalt_app.lua` (replace the cfgserver assertions/routing tests; add client-routing + gate tests)

**Interfaces:**
- Consumes: `ui.basalt.cfgclient` (Task 4), `fcs.comms.cfgsync`.
- Produces: `runtime.cfgClient`, `runtime.cfgCache` (kind → `{ body, status="ok"|"sync"|"fail" }`), `runtime.cfgSaveStatus` (string|nil); `M.cfgMenuStatus(runtime, screenId, requestFn) -> "ok"|"sync"|"fail"`; `M.CFG_MENU_KINDS`.

- [ ] **Step 1: Write/adjust the failing tests (RED)**

In `tests/test_basalt_app.lua`, replace lines 124-125 (the two `cfgserver` assertions) with:

```lua
  t.truthy(runtime.cfgClient ~= nil, "cfgClient present")
  t.truthy(type(runtime.cfgCache) == "table", "cfgCache present")
```

Replace the two cfgsync routing tests (`routeModem answers a cfgsync req...` and `routeModem stays silent...`, lines 168-183) with:

```lua
t.test("routeModem delivers a cfg reply to the cfg client's read callback", function()
  local runtime = newRuntime()
  local got
  local sid = runtime.cfgClient:readKind("tuning", function(body) got = body end)
  M.routeModem(runtime, CFG_CH.reply, protocol.encode(S.cfg(sid, "tuning", { gains = 3 })))
  t.truthy(got ~= nil and got.gains == 3, "cfg reply reached the read callback")
end)

t.test("routeModem delivers an ack to the cfg client's write callback", function()
  local runtime = newRuntime()
  local okSeen
  local sid = runtime.cfgClient:writeKind("tuning", { gains = {}, caps = {}, feel = {} },
    function(ok) okSeen = ok end)
  M.routeModem(runtime, CFG_CH.reply, protocol.encode(S.ack(sid, "tuning", true, nil)))
  t.eq(okSeen, true, "ack reached the write callback")
end)

t.test("cfgMenuStatus reports sync until cached, then ok, and requests missing kinds once", function()
  local runtime = { cfgCache = {} }
  local requested = {}
  local requestFn = function(kind) requested[#requested + 1] = kind end
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "sync", "missing kind -> sync")
  t.eq(requested[1], "devbind", "the missing kind was requested")
  runtime.cfgCache.devbind = { body = {}, status = "ok" }
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "ok")
  runtime.cfgCache.devbind = { body = nil, status = "fail" }
  t.eq(M.cfgMenuStatus(runtime, "mdb", requestFn), "fail")
  t.eq(M.cfgMenuStatus(runtime, "emc", requestFn), "ok", "a non-config screen is always ok")
end)
```

- [ ] **Step 2: Run to verify FAIL**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `runtime.cfgClient`/`runtime.cfgCache` nil, `M.cfgMenuStatus` nil, and the old cfgserver-based tests are gone.

- [ ] **Step 3: Swap the require and buildRuntime wiring**

In `ui/basalt/app.lua`, replace `local CfgServer = require("ui.cfgserver")` (line 47) with:

```lua
local CfgClient = require("ui.basalt.cfgclient")
```

In `buildRuntime`, change the cfg link direction (line 446) from the server direction to the **client** direction:

```lua
  -- CFG_CH client (S2): the UI now reads/writes the running FCS's config live -- SEND req/set on
  -- req (105), HEAR cfg/ack on reply (106). (Pre-S2 the UI was the config SERVER; that inversion
  -- retired ui/cfgserver.lua and the FCS boot's "ui" source.)
  local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.req, rxCh = CFG_CH.reply })
```

Replace the cfgserver construction (line 548) with:

```lua
  local cfgClient = CfgClient.new({ link = cfgLink })
```

In the returned runtime table (lines 550-579), replace `cfgserver = cfgserver,` (line 563) with:

```lua
    cfgClient = cfgClient,
    cfgCache = {},          -- kind -> { body = table, status = "ok"|"sync"|"fail" }
    cfgSaveStatus = nil,    -- last save result string, shown by the menus + FCS SYNC checker
```

(`cfgLink` stays in the returned table at line 552 — the client uses it via `routeModem`.)

- [ ] **Step 4: Repoint routeModem to the client**

Replace the cfgserver block in `routeModem` (lines 607-614) with:

```lua
  local c = runtime.cfgLink:onMessage(ch, msg)
  if c then
    runtime.cfgClient:onReply(c, os.epoch("utc"))
    return nil
  end
```

- [ ] **Step 5: Add the menu-open gate helper + the CFG kinds map**

After `M.CFG_CH = { req = 105, reply = 106 }` (line 102) add:

```lua
-- Which FCS config kinds each BIT/CONFIG menu needs cached before it can render live. tuning's
-- COM/AUTO-COM drilldown also reads devbind/senscal, so all three are prefetched on open.
M.CFG_MENU_KINDS = {
  tuning = { "tuning", "devbind", "senscal" },
  mdb = { "devbind" },
  senscal = { "devbind", "senscal" },
  senssource = { "devbind" },
}

-- cfgMenuStatus(runtime, screenId, requestFn) -> "ok" | "sync" | "fail". PURE given the cache: a
-- non-config screen is always "ok"; "fail" if any needed kind failed; "sync" if any is missing/in
-- flight (requestFn(kind) is invoked once per not-yet-requested kind); else "ok".
function M.cfgMenuStatus(runtime, screenId, requestFn)
  local kinds = M.CFG_MENU_KINDS[screenId]
  if not kinds then return "ok" end
  local agg = "ok"
  for _, kind in ipairs(kinds) do
    local c = runtime.cfgCache[kind]
    if c and c.status == "fail" then return "fail" end
    if not c or c.status == "sync" then
      if not c then requestFn(kind) end
      agg = "sync"
    end
  end
  return agg
end
```

- [ ] **Step 6: Gate the config menus in showScreen + wire the prefetch/tick (in-game wiring)**

> The `M.cfgMenuStatus` helper is tested (Step 1). The showScreen gate + the tick loop below are the in-game modem wiring — NOT headless-tested (mirrors the existing cfgserver routing, which was likewise only exercised via `routeModem`). Keep the logic thin.

In `M.showScreen` (the function that builds/caches a page frame), wrap the config-menu build so it renders a placeholder until the cache is ready. Immediately after resolving the page module and before building it, insert:

```lua
  -- S2: FCS config menus render only once their kinds are cached (fetched live from the FCS).
  -- While syncing / on timeout, show a placeholder instead of the menu -- the menu never sees a
  -- half-fetched cfg. requestFn kicks a client read whose reply flips the cache to "ok" and
  -- repaints (applyNow), rebuilding the real menu here.
  local cfgStatus = M.cfgMenuStatus(runtime, screenId, function(kind)
    runtime.cfgCache[kind] = { body = nil, status = "sync" }
    runtime.cfgClient:readKind(kind, function(body)
      runtime.cfgCache[kind] = { body = body, status = body ~= nil and "ok" or "fail" }
      runtime.uiRev = (runtime.uiRev or 0) + 1
      pcall(function() M.applyNow(basalt, runtime, frameRec) end)
    end)
  end)
  if cfgStatus ~= "ok" then
    return M._cfgPlaceholder(basalt, frameRec, screenId, cfgStatus)
  end
```

Add the placeholder builder near `showScreen`:

```lua
-- A minimal SYNC / FCS-NOT-ANSWERING frame shown in place of a config menu until its cfg arrives.
-- Cached under a distinct built key so the real menu rebuilds when the cache flips to "ok".
function M._cfgPlaceholder(basalt, frameRec, screenId, status)
  local key = "__cfggate_" .. screenId
  local rec = frameRec.built[key]
  if not rec then
    local w, h = frameRec.frame:getSize()
    local child = frameRec.frame:addFrame({ x = 1, y = 1, width = w, height = h })
    local msg = child:addLabel({ x = 2, y = 2, width = math.max(1, w - 2), height = 2, autoSize = false, text = "" })
    local back = child:addButton({ x = 2, y = h - 1, width = math.min(6, w - 2), height = 1, text = "<" })
    back:onClick(function() if frameRec.nav then frameRec.nav:pop() end end)
    rec = { childFrame = child, handle = { apply = function() end }, _msg = msg }
    frameRec.built[key] = rec
  end
  rec._msg:setText(status == "fail"
    and "FCS NOT ANSWERING -- seed via a config disk & reboot"
    or "SYNCING FCS...")
  for id, r in pairs(frameRec.built) do r.childFrame:setVisible(id == key) end
  return rec
end
```

> **Note for the implementer:** the exact `showScreen` signature/locals (`basalt`, `runtime`, `frameRec`, `screenId`) must match the real function — read `ui/basalt/app.lua`'s `showScreen` (it currently takes `(F, a5, ab, ac)` = basalt, runtime, frameRec, screenId in the minified form; the source uses readable names) and bind the placeholder call to those. The placeholder participates in the SAME `built[...]:setVisible` sweep the menu build uses, so entering/leaving works with the existing nav.

In `M.startScheduled`, add a cfg-client tick loop alongside the other `basalt.schedule` loops (mirror the 2 s wptClient loop):

```lua
  basalt.schedule(function()
    while true do
      pcall(function() runtime.cfgClient:tick(os.epoch("utc")) end)
      sleep(0.25)
    end
  end)
```

Update the header note (lines 1085-1086) that says "cfgserver is deliberately NOT auto-started..." to describe the client instead:

```lua
-- The FCS is the config source of truth (S2): the BIT/CONFIG menus read/write it live via
-- runtime.cfgClient over CFG_CH; there is no UI-side config server any more.
```

- [ ] **Step 7: Run src to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: `tests.test_basalt_app` passes with the new client/gate tests; the whole src suite is green.

- [ ] **Step 8: Dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: all green.

```bash
git add ui/basalt/app.lua tests/test_basalt_app.lua dist/ui/basalt/app.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): UI runtime drives the FCS config live

buildRuntime now flips the CFG_CH link to client direction and exposes
cfgClient + cfgCache; routeModem delivers cfg/ack replies to the client;
startScheduled ticks it (2s x 3 retry). showScreen gates the config menus
behind cfgMenuStatus, showing SYNCING / FCS-NOT-ANSWERING until the live cfg
arrives. The UI-side config server is gone. cfgMenuStatus is unit-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 7: Repoint FCS TUNING to live read/write (`ui/basalt/bitconfig/tuning.lua`)

**Files:**
- Modify: `ui/basalt/bitconfig/tuning.lua` (default read/write seams + save-status)
- Test: `tests/test_bitconfig_tuning.lua` (verify it still passes; add a live-write assertion if the file has no `read`/`write`-less build path — see Step 1)

**Interfaces:**
- Consumes: `ui.basalt.cfgseam` (Task 5), `runtime.cfgClient`/`runtime.cfgCache` (Task 6). The pure view-model (`M.rows/apply/resetMode/_save/pathFor/...`) is UNCHANGED.
- Produces: a TUNING menu whose default read serves the FCS-cached tuning cfg and whose SAVE ships a `set` to the FCS; the COM screen's `pushCom` (command-channel `setCom`) is unchanged.

- [ ] **Step 1: Confirm the existing tests inject read/write (they must stay green)**

Read `tests/test_bitconfig_tuning.lua`. Its `M.build`/`M._save` calls pass explicit `read`/`write` (or use `M._save` with a spy). Confirm none call `M.build(basalt, frame, runtime, nav)` with fewer than 6 args AND expect fs — if any do, they now hit `cfgseam.read(runtime)` and need a `runtime.cfgCache`; give those a `runtime = { cfgCache = { tuning = { body = <cfg> } } }`. (The pure-model tests — `M.rows`/`M.apply`/`M.resetMode`/fit-regression — are untouched.)

- [ ] **Step 2: Add the require**

In `ui/basalt/bitconfig/tuning.lua`, after `local ComAuto = require("fcs.comauto")` (line 77) add:

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 3: Swap the default seams in M.build**

In `M.build` (lines 481-487), replace:

```lua
  read = read or realRead
  write = write or realWrite
  delete = delete or realDelete -- kept for signature/API compat; ...
```

with:

```lua
  -- S2: default seams read the FCS's live tuning cfg from runtime.cfgCache and ship SAVE as a `set`
  -- to the running FCS (persisted there; tuning needs a reload to apply -- CoM is the exception,
  -- hot-applied via the COM screen's pushCom below AND the FCS responder). Tests still inject
  -- read/write and never touch cfgseam.
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  delete = delete or realDelete -- kept for signature/API compat (per-mode RST no longer deletes)
```

Then delete the now-unused module locals `realRead` (lines 384-386) and `realWrite` (lines 388-392); keep `realDelete` (still the default for `delete`). Update the module header comment (lines 5-8) to state the menu reads/writes the FCS live (no longer the on-disk cfg the boot loader reads).

- [ ] **Step 4: Run the TUNING test to verify GREEN**

Run: `bash tests/run_headless.sh 2>&1 | grep -i tuning` (or run the whole src suite).
Expected: `tests.test_bitconfig_tuning` green; the whole src suite green.

- [ ] **Step 5: Dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`

```bash
git add ui/basalt/bitconfig/tuning.lua tests/test_bitconfig_tuning.lua dist/ui/basalt/bitconfig/tuning.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): FCS TUNING reads/writes the running FCS live

Swap the menu's default read/write seams to cfgseam (FCS cache + cfgClient
set). SAVE persists to the FCS and reports "saved to FCS -- reload to apply";
CoM stays hot via the COM screen's setCom. Pure view-model + tests unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 8: Repoint MDB-CONF (device bind) to live read/write (`ui/basalt/bitconfig/mdb.lua`)

**Files:**
- Modify: `ui/basalt/bitconfig/mdb.lua`
- Test: `tests/test_bitconfig_mdb.lua` (confirm green; adjust any read/write-less build path as in Task 7 Step 1)

**Interfaces:**
- Consumes: `ui.basalt.cfgseam`, `runtime.cfgClient`/`cfgCache`. Pure model (`M.view/applyBinding/pickerOptions/_save/cloneCfg`) UNCHANGED. `scan()` (live peripheral scan) UNCHANGED.
- Produces: an MDB menu whose default read serves the FCS-cached devbind and whose SAVE ships a devbind `set` (the FCS materializes the senscal sibling).

- [ ] **Step 1: Add the require**

After `local Region = require("ui.basalt.region")` (line 27) add:

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 2: Swap the default seams in M.build**

In `M.build` (lines 209-212), replace:

```lua
  read = read or realRead
  write = write or realWrite
  scan = scan or realScan
```

with:

```lua
  -- S2: read the FCS's live devbind from runtime.cfgCache; SAVE ships a devbind `set` to the FCS
  -- (which persists it and materializes the senscal sibling). scan() stays a LOCAL peripheral scan
  -- -- the operator binds names visible on THIS PC's wired network. Tests inject read/write/scan.
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  scan = scan or realScan
```

Delete the now-unused `realRead` (lines 180-182) and `realWrite` (lines 184-188); keep `realScan`. Update the module header (lines 1-7) to say it binds/saves on the running FCS.

- [ ] **Step 3: Run to verify GREEN, then all gates + commit**

Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`

```bash
git add ui/basalt/bitconfig/mdb.lua tests/test_bitconfig_mdb.lua dist/ui/basalt/bitconfig/mdb.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): MDB-CONF binds/saves on the running FCS

Default read serves the FCS-cached devbind; SAVE ships a devbind set (the FCS
materializes the senscal sibling). Local peripheral scan and the byte-parity
pure model are unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 9: Repoint SENS CAL to live read/write (`ui/basalt/bitconfig/senscal.lua`)

**Files:**
- Modify: `ui/basalt/bitconfig/senscal.lua`
- Test: `tests/test_bitconfig_senscal.lua` (confirm green; adjust read/write-less build path per Task 7 Step 1)

**Interfaces:**
- Consumes: `ui.basalt.cfgseam`, `runtime.cfgClient`/`cfgCache`. Pure model (`M.steps/newController/_save/_realSampler`) and the CAPTURE sampling (LOCAL peripherals) UNCHANGED.
- Produces: a SENS CAL menu that reads the FCS's live devbind (for sensor names) + senscal (the starting scaffold) and whose SAVE ships a senscal `set` (the FCS materializes the devbind sibling).

- [ ] **Step 1: Add the require**

After `local switchbtn = require("ui.basalt.switchbtn")` (line 81) add:

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 2: Swap the default seams in M.build**

In `M.build` (lines 476-479), replace:

```lua
  read = read or realRead
  write = write or realWrite
  sampler = sampler or realSampler
```

with:

```lua
  -- S2: read the FCS's live devbind (sensor names) + senscal (starting scaffold) from
  -- runtime.cfgCache; SAVE ships a senscal `set` to the FCS (which materializes the devbind
  -- sibling). The CAPTURE sampler stays LOCAL (samples this PC's bound sensors). Tests inject all.
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  sampler = sampler or realSampler
```

Delete the now-unused `realRead` (lines 463-465) and `realWrite` (lines 467-471); keep `realSampler`. Update the module header (lines 1-6) to say it reads/writes the FCS's live senscal (still byte-parity with the terminal tool's file format).

> The read-on-open pulls both `devbind` and `senscal` — Task 6's `M.CFG_MENU_KINDS.senscal = {"devbind","senscal"}` prefetches both, so `sensorNames` (line 482) and the controller scaffold (line 483) are populated before the menu builds.

- [ ] **Step 3: Run to verify GREEN, then all gates + commit**

Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`

```bash
git add ui/basalt/bitconfig/senscal.lua tests/test_bitconfig_senscal.lua dist/ui/basalt/bitconfig/senscal.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): SENS CAL reads/writes the running FCS live

Default read serves the FCS-cached devbind+senscal; SAVE ships a senscal set
(the FCS materializes the devbind sibling). CAPTURE still samples local
sensors; the byte-parity pure model is unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 10: Repoint SENS SOURCE's devbind read to the FCS (`ui/basalt/bitconfig/senssource.lua`)

**Files:**
- Modify: `ui/basalt/bitconfig/senssource.lua`
- Test: `tests/test_bitconfig_senssource.lua` (confirm green; adjust read-less build path per Task 7 Step 1)

**Interfaces:**
- Consumes: `ui.basalt.cfgseam` (read only), `runtime.cfgCache`. Pure model (`M._select`) UNCHANGED.
- Produces: a SENS SOURCE menu whose SELF-cal sampler reads the FCS's live devbind for sensor names; its picker/SELF-cal persistence to `eh2_ui_config.tbl` stays LOCAL (the UI's own config, not an FCS file).

> **Nuance:** SENS SOURCE writes the UI's own `eh2_ui_config.tbl` (`config.sens`), NOT an FCS config file. So only the `read` seam moves to the FCS (devbind sensor names for the SELF-cal sampler); the `write` seam stays local `realWrite`.

- [ ] **Step 1: Add the require**

After `local senssource = require("ui.basalt.senssource")` (line 46) add:

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 2: Swap only the default read seam in M.build**

In `M.build` (lines 105-108), replace:

```lua
  read = read or realRead
  write = write or realWrite
  sampler = sampler or realSampler
```

with:

```lua
  -- S2: the SELF-cal sampler needs the FCS's live devbind sensor names, so `read` defaults to the
  -- FCS cache. `write` stays LOCAL (realWrite): this menu persists config.sens into the UI's own
  -- eh2_ui_config.tbl -- not an FCS config file -- so it must never go through cfgseam/the FCS.
  read = read or cfgseam.read(runtime)
  write = write or realWrite
  sampler = sampler or realSampler
```

Keep `realWrite` (still used) and `realSampler`; delete only the now-unused `realRead` (lines 72-74). Update the module header (lines 2-11) to note the devbind read comes from the FCS live while `config.sens` still persists to `eh2_ui_config.tbl`.

- [ ] **Step 3: Run to verify GREEN, then all gates + commit**

Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`

```bash
git add ui/basalt/bitconfig/senssource.lua tests/test_bitconfig_senssource.lua dist/ui/basalt/bitconfig/senssource.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): SENS SOURCE reads devbind from the FCS live

The SELF-cal sampler's devbind sensor names now come from the FCS cache; the
picker/SELF-cal still persist config.sens to the UI's own eh2_ui_config.tbl
(local write unchanged -- it is not an FCS config file).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 11: FCS SYNC menu → read-only checker (`ui/basalt/bitconfig/fcssync.lua`)

**Files:**
- Modify: `ui/basalt/bitconfig/fcssync.lua` (rewrite as a read-only checker)
- Test: `tests/test_bitconfig_fcssync.lua` (rewrite — the start/stop-server tests no longer apply)

**Interfaces:**
- Consumes: `runtime.cfgClient` (`readKind`), `runtime.cfgCache`, `runtime.cfgSaveStatus`. `configkit`.
- Produces: `M.id/M.title`; `M.checkStatus(cfgCache, kinds) -> { <kind> = "OK"|"SYNC"|"NO ANSWER" }` (PURE); `M.KINDS`; `M.build(...)` renders per-kind status + a REFRESH button; NO server start/stop.

> The old menu assumed the UI was the config SOURCE (start/stop the answering server). Post-S2 the FCS is the source, so this becomes a diagnostic: `req` each kind and report whether the FCS answered. Never writes.

- [ ] **Step 1: Write the failing tests (RED) — rewrite the file**

Replace the entire contents of `tests/test_bitconfig_fcssync.lua` with:

```lua
-- tests/test_bitconfig_fcssync.lua
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.fcssync")

t.test("checkStatus reports per-kind OK / SYNC / NO ANSWER from the cache", function()
  local cache = {
    tuning = { body = { gains = {} }, status = "ok" },
    devbind = { body = nil, status = "sync" },
    senscal = { body = nil, status = "fail" },
  }
  local st = M.checkStatus(cache, { "tuning", "devbind", "senscal" })
  t.eq(st.tuning, "OK")
  t.eq(st.devbind, "SYNC")
  t.eq(st.senscal, "NO ANSWER")
end)

t.test("checkStatus treats an absent cache entry as SYNC (not requested yet)", function()
  local st = M.checkStatus({}, { "tuning" })
  t.eq(st.tuning, "SYNC")
end)

t.test("M.KINDS lists the FCS config kinds the checker probes", function()
  t.truthy(#M.KINDS >= 3, "at least tuning/devbind/senscal")
end)
```

- [ ] **Step 2: Run to verify FAIL**

Run: `bash tests/run_headless.sh`
Expected: FAIL — `M.checkStatus`/`M.KINDS` are nil (and the old `_onButton`/`linkStatus` tests are gone).

- [ ] **Step 3: Rewrite `ui/basalt/bitconfig/fcssync.lua`**

Replace the entire file with:

```lua
-- ui/basalt/bitconfig/fcssync.lua
-- FCS SYNC sub-menu (BIT/CONFIG hub, screen id "fcssync"): a READ-ONLY checker. Post-S2 the FCS is
-- the config source of truth, so this no longer starts/stops any UI-side server -- it requests each
-- config kind from the running FCS (via runtime.cfgClient) and reports whether the FCS answered.
-- NEVER writes.
--
-- Exports M.id/M.title, a PURE view-model (M.KINDS / M.checkStatus), and M.build(basalt, frame,
-- runtime, nav) -> { id, apply(state), elements }. NO peripheral/Basalt access at module LOAD.
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "fcssync"
M.title = "FCS SYNC"

-- The FCS config kinds this checker probes.
M.KINDS = { "tuning", "devbind", "senscal" }

-- ===== M.checkStatus: PURE per-kind status from runtime.cfgCache. =====
-- "OK" = a body arrived; "NO ANSWER" = the last attempt failed (FCS silent); "SYNC" = in flight or
-- not yet requested.
function M.checkStatus(cfgCache, kinds)
  cfgCache = cfgCache or {}
  local out = {}
  for _, kind in ipairs(kinds or M.KINDS) do
    local c = cfgCache[kind]
    if c and c.status == "ok" and c.body ~= nil then out[kind] = "OK"
    elseif c and c.status == "fail" then out[kind] = "NO ANSWER"
    else out[kind] = "SYNC" end
  end
  return out
end

-- ===== M.build: per-kind status lines + a REFRESH button. =====
function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local titleLabel = configkit.titleRow(frame, w, M.title)

  local rowLabels = {}
  local y0 = 3
  for i, kind in ipairs(M.KINDS) do
    rowLabels[kind] = frame:addLabel({ x = x, y = y0 + (i - 1), width = iw, height = 1,
      autoSize = false, text = kind:upper() .. ": --" })
  end

  -- REFRESH: re-request every kind live (fire-and-forget; replies flip runtime.cfgCache and the
  -- next apply() repaints). PURE-of-fs: only touches the cfg client + cache.
  local function refreshAll()
    for _, kind in ipairs(M.KINDS) do
      runtime.cfgCache[kind] = { body = nil, status = "sync" }
      runtime.cfgClient:readKind(kind, function(body)
        runtime.cfgCache[kind] = { body = body, status = body ~= nil and "ok" or "fail" }
        runtime.uiRev = (runtime.uiRev or 0) + 1
      end)
    end
    runtime.uiRev = (runtime.uiRev or 0) + 1
  end

  local footerY = y0 + #M.KINDS + 1
  local actionRow = configkit.actionRow(frame, { x = x, y = footerY, w = iw }, {
    { label = "REFRESH", onClick = refreshAll },
  })
  local backRow = configkit.actionRow(frame, { x = x, y = footerY + 1, w = iw }, {
    { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
  })

  local function apply(_state)
    local st = M.checkStatus(runtime.cfgCache, M.KINDS)
    for _, kind in ipairs(M.KINDS) do
      rowLabels[kind]:setText(kind:upper() .. ": " .. st[kind])
    end
  end

  -- Kick a first probe so opening the page immediately queries the FCS.
  refreshAll()
  apply()

  return {
    id = M.id,
    apply = apply,
    elements = { titleLabel = titleLabel, rowLabels = rowLabels, actionRow = actionRow, backRow = backRow },
  }
end

return M
```

- [ ] **Step 4: Run to verify GREEN, then all gates + commit**

Run: `bash tests/run_headless.sh && node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`

```bash
git add ui/basalt/bitconfig/fcssync.lua tests/test_bitconfig_fcssync.lua dist/ui/basalt/bitconfig/fcssync.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): FCS SYNC becomes a read-only live-config checker

The FCS is the config source now, so FCS SYNC no longer starts/stops a UI-side
server -- it requests each config kind from the running FCS and reports OK /
SYNC / NO ANSWER per kind. Never writes. Pure checkStatus is unit-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 12: Kill the boot-pull-from-UI path

**Files:**
- Delete: `ui/cfgserver.lua`, `tests/test_cfgserver.lua`
- Modify: `tests/run_headless.sh:33` + `tests/run_headless_dist.sh:31` (remove `"tests.test_cfgserver"`)
- Modify: `fcs/boot/loaderui.lua` (remove the "ui" source, `uiSource`, `waitForReply`, `closeCfgChannels`, `M.CFG_CH`, the `modemlib` require, `UI_TIMEOUT`/`UI_RETRIES`)
- Modify: `fcs/boot/loader.lua` (drop `"ui"` from `SOURCES`)
- Modify: `tests/test_bootloaderui.lua` (remove the closeCfgChannels test; adjust the "ui" needsConfirm/finish cases)
- Modify: `tests/test_bootloader.lua` (the `binding="ui"` invalid-source case)
- Delete: `dist/ui/cfgserver.lua` (regenerated away by `node tools/build.mjs`)

**Interfaces:**
- Consumes: nothing new.
- Produces: an FCS boot loader that offers only `own`/`disk`/`defaults` sources (the FCS boots from its own files or a config disk — the disk seeding path the "FCS not answering" UI message points operators to). `CFG_CH` now lives solely in `tools/flight.lua` (the responder) and `ui/basalt/app.lua` (the client).

- [ ] **Step 1: Remove `"ui"` from `loader.SOURCES` and fix its tests (RED→GREEN)**

In `fcs/boot/loader.lua`, change `SOURCES` (lines 4-8) to:

```lua
  SOURCES = {
    binding = { "own", "disk" },
    sensor = { "own", "disk" },
    tuning = { "disk", "defaults" },
  },
```

In `tests/test_bootloader.lua:16`, change the invalid/missing-source case from `binding="ui"` to a still-valid-but-missing source so the test exercises the "no config available" path (its intent):

```lua
  local ok, _, err = L.resolve({ binding="disk", sensor="own", tuning="disk" }, src)
```

- [ ] **Step 2: Strip the "ui" source from `fcs/boot/loaderui.lua`**

Delete these from `fcs/boot/loaderui.lua`:
- the `local modemlib = require("fcs.comms.modem")` require (line 23) — only `uiSource` used it;
- `M.CFG_CH = { req = 105, reply = 106 }` (line 28);
- `local UI_TIMEOUT` / `local UI_RETRIES` (lines 37-38);
- the whole `waitForReply` function (lines 113-129);
- the whole `uiSource` function (lines 131-164);
- the `if src == "ui" then return uiSource(concern) end` line inside `buildSources` (line 171);
- the whole `M.closeCfgChannels` function (lines 219-228) and every call to it in `M.run` (lines 299, 308, 318);
- the "ui" branch of `M.needsConfirm` — change line 68 to `function M.needsConfirm(src) return src == "disk" end`;
- the CHANNEL CONVENTION header comment block (lines 9-13) and any "Request from UI PC" wording in the remaining comments (lines 72-73, 131-141, 233-235's confirm text still reads fine for disk).

Update the module header (lines 1-8) to drop the UI-pull description: the boot loader now assembles from `own`/`disk`/`defaults` only.

- [ ] **Step 3: Fix `tests/test_bootloaderui.lua`**

- Delete the `closeCfgChannels closes 105 and 106` test (lines 6-14) — the function is gone.
- Change the `finish surfaces loader.resolve failures` case (line 52) from `binding = "ui"` to `binding = "disk"` (a valid source the stub returns nil for), keeping `ok == false` + `err` truthy.
- Change the `needsConfirm` test (lines 59-64) to drop the `"ui"` assertion:

```lua
t.test("needsConfirm is true only for the disk source", function()
  t.eq(M.needsConfirm("disk"), true)
  t.eq(M.needsConfirm("own"), false)
  t.eq(M.needsConfirm("defaults"), false)
end)
```

- [ ] **Step 4: Delete `ui/cfgserver.lua` + its test, and de-register the suite**

```bash
git rm ui/cfgserver.lua tests/test_cfgserver.lua
```

Remove `"tests.test_cfgserver"` from the `suites` array in BOTH `tests/run_headless.sh:33` and `tests/run_headless_dist.sh:31`.

- [ ] **Step 5: Run src to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: green — `test_cfgserver` no longer runs; `test_bootloader`/`test_bootloaderui` pass with the adjusted cases; nothing still requires `ui.cfgserver` (Task 6 already removed the require).

- [ ] **Step 6: Rebuild dist (drops `dist/ui/cfgserver.lua`), dist + e2e gates, commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: green. `node tools/build.mjs` removes `dist/ui/cfgserver.lua`; `git add -A dist/` captures the deletion.

```bash
git add -A ui/cfgserver.lua tests/test_cfgserver.lua fcs/boot/loaderui.lua fcs/boot/loader.lua tests/test_bootloaderui.lua tests/test_bootloader.lua tests/run_headless.sh tests/run_headless_dist.sh dist/
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): remove the boot-pull-from-UI config path

The FCS no longer pulls config from the UI: drop the "ui" source from the boot
loader (uiSource/waitForReply/closeCfgChannels/CFG_CH) and loader.SOURCES,
delete ui/cfgserver.lua + its test. The boot loader now assembles from
own/disk/defaults only; disk seeding is the fallback the "FCS not answering" UI
message points to. CFG_CH now lives with the FCS responder + UI client.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

### Task 13: Drop the UI's FCS config-file copies from the manifest (S1-deferred)

**Files:**
- Modify: `tools/gen_manifest.lua:70` (the `ui` role `configs`)
- Regenerate: `manifest.lua`, `manifest-dev.lua` (via `bash tools/run_gen.sh`)
- Modify: `tests/test_manifest_channels.lua:45-58` (the "back up all their config files" test)

**Interfaces:**
- Consumes: the committed manifest shape (`m.roles.<name>.configs` = array of `/`-prefixed paths).
- Produces: a `ui` role that backs up ONLY `/eh2_ui_config.tbl`; `fcs` keeps its 4.

> **Why now:** S1 deferred this because the FCS boot-pulled config from the UI's `cfgserver`, so a role's `configs` (the set the Suite backs up + preserves-across-repair) had to keep the FCS files. S2 removed that pull (Task 12), so the UI no longer owns any FCS config file — see `docs/superpowers/plans/2026-09-02-config-overhaul-s1-shipping.md` Global Constraints.

- [ ] **Step 1: Write the failing manifest assertion (RED)**

In `tests/test_manifest_channels.lua`, replace the `ui` block of the `fcs and ui roles back up all their config files` test (lines 54-57) with:

```lua
    -- S2: the ui role no longer holds any FCS config file -- it reads/writes the FCS live -- so it
    -- backs up ONLY its own eh2_ui_config.tbl. (fcs still keeps its 4, asserted above.)
    local ui = toSet(m.roles.ui.configs)
    t.eq(#m.roles.ui.configs, 1, path .. ": ui has exactly 1 config")
    t.truthy(ui["/eh2_ui_config.tbl"], path .. ": ui backs up only eh2_ui_config.tbl")
    t.truthy(not (ui["/eh2_devbind.tbl"] or ui["/eh2_senscal.tbl"] or ui["/eh2_tuning.tbl"]),
      path .. ": ui no longer backs up the FCS config files")
```

- [ ] **Step 2: Run to verify FAIL**

Run: `bash tests/run_headless.sh`
Expected: FAIL in `test_manifest_channels` — the committed manifest still lists 4 ui configs.

- [ ] **Step 3: Edit the `ui` role's `configs`**

In `tools/gen_manifest.lua`, change line 70 (the `ui` role's `configs`) from:

```lua
    configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
```

to:

```lua
    -- S2: the UI reads/writes the FCS config live (no local copies), so it backs up only its own
    -- eh2_ui_config.tbl. The FCS role still owns the FCS config files.
    configs = { "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
```

Also update the S1 comment above it (lines 67-69) that says "The UI's FCS config-FILE copies stay in `configs` for now; removing them is S2..." — replace with a one-line note that S2 removed them.

- [ ] **Step 4: Regenerate both manifests**

Run: `bash tools/run_gen.sh`
Expected: rewrites `manifest.lua` + `manifest-dev.lua`.

- [ ] **Step 5: Run src to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: green — `test_manifest_channels` passes (ui has 1 config; the manifest-sync `run_gen.sh --check` at the top of the runner passes because the manifests were just regenerated).

- [ ] **Step 6: Dist + e2e gates and commit**

Run: `node tools/build.mjs && bash tests/run_headless_dist.sh && bash tests/run_suite_e2e.sh`
Expected: green.

```bash
git add tools/gen_manifest.lua manifest.lua manifest-dev.lua tests/test_manifest_channels.lua dist/
git commit -m "$(cat <<'EOF'
feat(config-overhaul S2): ui role drops its FCS config-file copies

The UI reads/writes the FCS config live now, so the ui role backs up only its
own eh2_ui_config.tbl (fcs still owns the FCS config files). Regenerated both
manifests; the "back up all config files" test now asserts ui has exactly one.
This is the S1-deferred item, unblocked by removing the boot-pull path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

## Self-Review

**1. Spec coverage (S2 deliverables 1–8):**
- (1) Extend `cfgsync` codec (set/ack + Responder applier, req/cfg unchanged) → **Task 1**. ✓
- (2) FCS provider/applier with the per-kind mapping (split-else-fused read; write + materialize sibling; tuning/fuelcal direct; never write fused) → **Task 2** (`fcs/io/cfgaccess.lua`). ✓
- (3) FCS responder task (sibling of `commandTask`, `CFG_CH`, serves reads/applies writes, CoM via `flight:handleCommand`, gated, not headless-tested) → **Task 3**. ✓
- (4) UI cfg client (readKind/writeKind, 2s×3 timeout/retry) → **Task 4** (`ui/basalt/cfgclient.lua`), event-driven per the wptClient precedent (divergence flagged below). ✓
- (5) Repoint the UI FCS-config menus (read-on-open/write-on-save via the client) + graceful degradation → **Tasks 5–10**: `cfgseam` (shared seam), tuning, mdb, senscal, senssource; degradation via Task 6's `showScreen` gate ("SYNCING…" / "FCS NOT ANSWERING — seed via a config disk & reboot"). Split per menu so a reviewer can accept/reject each. Pure view-models + their tests preserved. ✓ (fuelcal = no-op, see below.)
- (6) FCS SYNC → read-only checker → **Task 11**. ✓
- (7) Kill boot-pull-from-UI (delete `ui/cfgserver.lua` + test; remove the "ui" source from `loaderui`/`loader.SOURCES`; update tests) → **Task 12**. ✓
- (8) Remove the UI's FCS config-file copies from `gen_manifest.lua`, regen, update `test_manifest_channels.lua` → **Task 13** (the S1-deferred item). ✓
- Global Constraints header: preserve apply-timing, generated manifests, `node tools/build.mjs` for dist, all-gates-green, commit trailers, two-list test discovery — all present. ✓

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N"/"write tests for the above". Every code step carries real Lua; every test step shows the assertions; every run step names the command + expected result. The two not-headless-tested tasks (3, and the modem-wiring parts of 6) explicitly say so and are verified by the regression gates, mirroring the `loaderui`/`beacon` convention.

**3. Type consistency:** Frame shapes match across tasks — `cfgsync.set(sid,kind,body)`/`ack(sid,kind,ok,err)`/`cfg(sid,kind,body)` are produced by Task 1 and consumed by Tasks 3/4/6/11. `cfgaccess.getKind(kind,read)`/`setKind(kind,body,read,write)->ok,err` (Task 2) match the responder's `cfgProvider`/`cfgApplier` (Task 3). `cfgclient.readKind(kind,cb)`/`writeKind(kind,body,cb)`/`onReply(frame,now)`/`tick(now)` (Task 4) match app wiring (Task 6) and `cfgseam.write`'s `writeKind` call (Task 5). `runtime.cfgCache[kind] = { body, status }` is written by Task 6/11 and read by `cfgseam.read` (Task 5), `cfgMenuStatus` (Task 6), and `checkStatus` (Task 11) consistently. `read`/`write` seams are bare-filename throughout (cfgspec contract).

**4. Assumptions / uncertainties for the controller (places the code diverged from the brief):**
- **fuelcal is already FCS-live** (command path), not a UI-local file edit — so there is NO fuelcal menu to repoint; the brief's deliverable-5 fuelcal item is a no-op. Confirm this is acceptable (I left the EMC CAL FUEL menu untouched).
- **UI cfg client is event-driven (wptClient-style), not the blocking `loaderui.uiSource` the brief named as the model.** A blocking `os.pullEvent` inside the Basalt loop would eat cockpit events (per `wptclient.lua`'s own header). Timeout/retry policy (2s × 3) is preserved exactly. Flag if the controller wanted the literal blocking model.
- **PFD attitude "FCS" source coupling:** `ui/basalt/senssource.lua` `M.resolve` (the PFD attitude/SAS reader, distinct from the bitconfig menu) reads the UI's LOCAL `eh2_senscal.tbl`+`eh2_devbind.tbl` for its "FCS" source. After Task 13, a fresh UI install no longer carries those files, so that PFD source would fall back to merged identity defaults. S2 (per the brief's deliverable list) does not address this reader. **Recommend the controller decide** whether the PFD "FCS" source should also fetch from the FCS live (a follow-up), or whether it should be repointed to read the FCS cache. Not fixed here to stay within the approved scope.
- **CoM hot-apply is now double-pathed but idempotent:** the FCS responder applies CoM on a tuning `set` (per the brief) AND the COM screen still sends `setCom` on the command channel. Both just set the mixer offset; harmless. I kept `pushCom` to minimize menu churn.
- **`cfgaccess.getKind` for devbind/senscal returns merged defaults (never nil) when neither split nor fused exists**, a deliberate refinement over `loaderui.ownSource` (which returns nil to force a boot re-pick) so a brand-new FCS is still editable and the UI never confuses "empty config" with "FCS silent". Confirm acceptable.
- **`node tools/build.mjs` is assumed to be the dist rebuild command** (referenced in the S1 plan). If the dist rebuild is a different invocation, substitute it in every "dist gate" step. Also verify whether `tests/run_headless_dist.sh` rebuilds dist itself (if it does, the explicit `node tools/build.mjs` is belt-and-suspenders, not required).
- **`showScreen` gate binding:** the placeholder integration (Task 6 Step 6) must be bound to `showScreen`'s real locals; I described the source-name mapping, but the implementer should read the current `showScreen` and confirm `frameRec`/`built`/`applyNow` names before wiring.
