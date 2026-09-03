# Config Overhaul — S2b (MDB / SENS CAL / SENS SOURCE + drop UI FCS files)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the live-write inversion: MDB, SENS CAL, and SENS SOURCE read/write the running FCS (or UI-own files where that is the truth), then drop the UI role's copies of FCS config files.

**Architecture:** Same seams as S2 Task 7 (TUNING). `ui/basalt/cfgseam.lua` already maps filename↔kind. Default `read`/`write` on the FCS-config menus swap from local `fs` to `cfgseam`. SENS SOURCE still persists `config.sens` to `eh2_ui_config.tbl` (UI-own), so only its **read** seam moves (devbind sensor names for SELF-cal CAPTURE). After those menus no longer touch UI-local FCS files, `tools/gen_manifest.lua` ui `configs` becomes `{ "/eh2_ui_config.tbl" }` only.

**Tech Stack:** Lua 5.1 (CC:Tweaked), CraftOS-PC headless, Basalt 2.0, `tests/framework.lua`, `tools/gen_manifest.lua`, `node tools/build.mjs`.

**Spec:** `docs/superpowers/specs/2026-09-01-config-overhaul-design.md` §3.3 / §4 S2. Parent plan: `docs/superpowers/plans/2026-09-03-config-overhaul-s2-livewrite.md` Tasks 8, 9, 10, 13 (deferred by operator 2026-09-03).

## Global Constraints

- Preserve apply-timing. CoM stays hot via existing `setCom`. Bindings/senscal/tuning still need an FCS reload. UI must say `"saved to FCS -- reload to apply"`.
- Never write fused `/eh2_hw_config.tbl`.
- ASCII only in Lua strings/comments. No optimistic UI.
- Manifests are generated, never hand-edited (`bash tools/run_gen.sh`). dist/ via `node tools/build.mjs`.
- All gates green before each commit: src (`bash tests/run_headless.sh`), dist (`node tools/build.mjs` then `bash tests/run_headless_dist.sh`), e2e (`bash tests/run_suite_e2e.sh`).
- Test discovery is an EXPLICIT list in BOTH `tests/run_headless.sh` and `tests/run_headless_dist.sh`. Prefer appending to an existing `tests/test_*.lua`.
- Work on `feat/config-overhaul` in-place. Do not push. Do not merge to main.
- Do not start S3 (DTC). DTC still copies UI-local FCS files; S3 rewires it. Empty UI-local FCS files after Task 4 of this plan are expected until S3.
- PFD attitude/SAS already come from the FCS snapshot (`ui/basalt/app.lua` `latest.pitch`/`roll`/`surgeVel`). Do **not** keep UI FCS config copies "for the PFD". `ui/basalt/senssource.lua` `M.resolve` is test-only for the FCS file path; do not rewire PFD render.

**Windows test runner:** Git Bash from repo root. Focus: `SUITES=tests.test_bitconfig_mdb bash tests/run_focus.sh`.

**Commit trailers on every commit:**
```
Co-Authored-By: Grok 4.6 <noreply@x.ai>
```

---

## File Structure

**Modified:**
- `ui/basalt/bitconfig/mdb.lua` — Task 1
- `ui/basalt/bitconfig/senscal.lua` — Task 2
- `ui/basalt/bitconfig/senssource.lua` — Task 3
- `tools/gen_manifest.lua` + regenerated `manifest.lua` / `manifest-dev.lua` — Task 4
- Tests: `tests/test_bitconfig_mdb.lua` / `senscal` / `senssource` only if a no-arg `M.build` path expects fs; `tests/test_manifest_channels.lua` Task 4

**Unchanged:** `ui/basalt/cfgseam.lua`, `ui/basalt/app.lua` `CFG_MENU_KINDS`, TUNING, FCS SYNC, boot loader, `ui/basalt/bitconfig/dtc.lua` (S3), UI CAL (already UI-own).

---

### Task 1: Repoint MDB-CONF to live read/write

**Files:**
- Modify: `ui/basalt/bitconfig/mdb.lua` (require + default seams; current `M.build` is line 209)
- Test: `tests/test_bitconfig_mdb.lua` (confirm green; adjust any read/write-less build path)

**Interfaces:**
- Consumes: `ui.basalt.cfgseam`, `runtime.cfgClient`/`cfgCache`. Pure model (`M.view`/`applyBinding`/`pickerOptions`/`_save`/`cloneCfg`) UNCHANGED. `scan()` stays a LOCAL peripheral scan.
- Produces: default read serves FCS-cached devbind; SAVE ships a devbind `set`.

- [ ] **Step 1: Confirm existing tests inject read/write**

Read `tests/test_bitconfig_mdb.lua`. If any `M.build(basalt, frame, runtime, nav)` with fewer than 6 args expects fs, give those a `runtime = { cfgCache = { devbind = { body = <cfg> } } }`. Pure-model tests are untouched.

- [ ] **Step 2: Add the require**

After `local Region = require("ui.basalt.region")` (line 27) add:

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 3: Swap the default seams in M.build**

Replace lines 210-212:

```lua
  read = read or realRead
  write = write or realWrite
  scan = scan or realScan
```

with:

```lua
  -- S2b: read the FCS's live devbind from runtime.cfgCache; SAVE ships a devbind `set` to the FCS
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

Delete unused `realRead` (lines 180-182) and `realWrite` (lines 184-188); keep `realScan`. Update the module header (lines 1-7) to say it binds/saves on the running FCS.

- [ ] **Step 4: RED if you added a test; otherwise GREEN the existing suite**

Run: `SUITES=tests.test_bitconfig_mdb bash tests/run_focus.sh`
Expected: green. Then src + `node tools/build.mjs` + dist + e2e.

- [ ] **Step 5: Commit**

```
feat(config-overhaul S2b): MDB-CONF binds/saves on the running FCS

Default read serves the FCS-cached devbind; SAVE ships a devbind set (the FCS
materializes the senscal sibling). Local peripheral scan and the byte-parity
pure model are unchanged.
```

---

### Task 2: Repoint SENS CAL to live read/write

**Files:**
- Modify: `ui/basalt/bitconfig/senscal.lua` (current `M.build` is line 476)
- Test: `tests/test_bitconfig_senscal.lua`

**Interfaces:**
- Consumes: cfgseam. Pure model (`M.steps`/`newController`/`_save`/`_realSampler`) UNCHANGED. CAPTURE sampler stays LOCAL.
- Produces: reads FCS-cached devbind + senscal; SAVE ships a senscal `set`.

- [ ] **Step 1: Confirm tests inject read/write/sampler** (same rule as Task 1).

- [ ] **Step 2: Add the require** after `local switchbtn = require("ui.basalt.switchbtn")` (or the last local require before `M = {}`):

```lua
local cfgseam = require("ui.basalt.cfgseam")
```

- [ ] **Step 3: Swap default seams in M.build** (lines 477-479)

```lua
  -- S2b: read the FCS's live devbind (sensor names) + senscal (starting scaffold) from
  -- runtime.cfgCache; SAVE ships a senscal `set` to the FCS (which materializes the devbind
  -- sibling). The CAPTURE sampler stays LOCAL. Tests inject all.
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

Delete unused `realRead` / `realWrite`; keep `realSampler`. Update the module header to say it reads/writes the FCS live (still byte-parity with the terminal tool's file format).

Task 6 already prefetches `CFG_MENU_KINDS.senscal = {"devbind","senscal"}`.

- [ ] **Step 4: GREEN focus + full gates, then commit**

```
feat(config-overhaul S2b): SENS CAL reads/writes the running FCS live

Default read serves the FCS-cached devbind+senscal; SAVE ships a senscal set
(the FCS materializes the devbind sibling). CAPTURE still samples local
sensors; the byte-parity pure model is unchanged.
```

---

### Task 3: SENS SOURCE reads FCS live devbind; write stays UI-own

**Files:**
- Modify: `ui/basalt/bitconfig/senssource.lua` (current `M.build` is line 105)
- Test: `tests/test_bitconfig_senssource.lua`

**Interfaces:**
- Consumes: cfgseam **read only**. Pure `M._select` UNCHANGED.
- Produces: SELF-cal sampler's sensor names come from FCS-cached devbind. Picker/SELF-cal still persist `config.sens` into `eh2_ui_config.tbl` via local `realWrite`.

- [ ] **Step 1: Confirm tests inject read/write/sampler.**

- [ ] **Step 2: Add** `local cfgseam = require("ui.basalt.cfgseam")` after the existing requires.

- [ ] **Step 3: Swap ONLY the default read seam** (lines 106-108)

```lua
  -- S2b: SELF-cal sampler needs the FCS's live devbind sensor names, so `read` defaults to the
  -- FCS cache. `write` stays LOCAL (realWrite): this menu persists config.sens into the UI's own
  -- eh2_ui_config.tbl -- not an FCS config file -- so it must never go through cfgseam/the FCS.
  -- PFD attitude/SAS already come from the FCS snapshot; this menu does not feed the PFD render.
  read = read or cfgseam.read(runtime)
  write = write or realWrite
  sampler = sampler or realSampler
```

Keep `realWrite` and `realSampler`; delete only unused `realRead`. Update the module header: drop the stale claim that this is "wired into app.lua's attitude poll loop".

- [ ] **Step 4: GREEN + gates + commit**

```
feat(config-overhaul S2b): SENS SOURCE reads devbind from the FCS live

The SELF-cal sampler's devbind sensor names now come from the FCS cache; the
picker/SELF-cal still persist config.sens to the UI's own eh2_ui_config.tbl
(local write unchanged -- it is not an FCS config file).
```

---

### Task 4: Drop the UI's FCS config-file copies from the manifest

**Files:**
- Modify: `tools/gen_manifest.lua` ui role `configs` (currently line 70)
- Regenerate: `manifest.lua`, `manifest-dev.lua` via `bash tools/run_gen.sh`
- Modify: `tests/test_manifest_channels.lua` (the "back up all their config files" test, lines 45-58). Also update the S1 comment at lines 67-69 that says file copies stay until S2.

**Interfaces:**
- Produces: ui role backs up ONLY `/eh2_ui_config.tbl`. fcs still keeps its 4.

- [ ] **Step 1: Write the failing assertion (RED)**

Replace the `ui` block of `fcs and ui roles back up all their config files` (lines 54-57) with:

```lua
    -- S2b: the ui role no longer holds any FCS config file -- it reads/writes the FCS live -- so it
    -- backs up ONLY its own eh2_ui_config.tbl. (fcs still keeps its 4, asserted above.)
    local ui = toSet(m.roles.ui.configs)
    t.eq(#m.roles.ui.configs, 1, path .. ": ui has exactly 1 config")
    t.truthy(ui["/eh2_ui_config.tbl"], path .. ": ui backs up only eh2_ui_config.tbl")
    t.truthy(not (ui["/eh2_devbind.tbl"] or ui["/eh2_senscal.tbl"] or ui["/eh2_tuning.tbl"]),
      path .. ": ui no longer backs up the FCS config files")
```

Update the S1 comment (lines 67-69) so it no longer says the copies stay.

- [ ] **Step 2: Run src — expect FAIL** (ui still has 4 configs).

- [ ] **Step 3: Edit ui role configs**

Change line 70 from:

```lua
    configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
```

to:

```lua
    -- S2b: the UI reads/writes the FCS config live (no local copies), so it backs up only its own
    -- eh2_ui_config.tbl. The FCS role still owns the FCS config files. DTC FCS export from the UI
    -- PC is empty until S3 rewires the courier.
    configs = { "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
```

Replace the S1 comment above it (lines 67-69) with a one-line note that S2b removed the FCS file copies.

- [ ] **Step 4: `bash tools/run_gen.sh`** then src GREEN.

- [ ] **Step 5: `node tools/build.mjs` + dist + e2e, then commit**

```
feat(config-overhaul S2b): ui role drops its FCS config-file copies

The UI reads/writes the FCS config live now, so the ui role backs up only its
own eh2_ui_config.tbl (fcs still owns the FCS config files). Regenerated both
manifests. DTC FCS export from the UI is S3.
```

---

## Self-Review

**1. Spec coverage:** Design §3.3 one-write-path + §4 S2 "repoint UI FCS-config menus" + "remove UI copies of FCS configs". TUNING already done in S2 T7. This plan covers MDB, SENS CAL, SENS SOURCE (read-only for FCS files), and the S1-deferred file drop. UI CAL is already UI-own. Fuelcal already live on the command path. DTC is S3. Boot pickers are S4. Suite migrate/DEFAULT is S5.

**2. Placeholder scan:** none.

**3. Type consistency:** cfgseam.read/write signatures match S2 T5. Save-status string matches TUNING. Manifest test matches S2 T13 text.

**4. Rulings baked in:**
- PFD does not need UI-local FCS files (operator 2026-09-03 + code: snapshot pitch/roll/sas).
- T13 before S3 leaves UI DTC FCS export empty; S3 must rewire. Do not merge to main until S3 lands.
