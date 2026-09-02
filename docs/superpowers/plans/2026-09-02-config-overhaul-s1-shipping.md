# Config Overhaul — S1 (Shipping Cleanup) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop shipping the FCS flight-control loop and the shared diagnostic launchers (`calibrate`/`hovertest`/`probe*`) to the `ui` role, so the flight stack lives on the FCS PC only — without changing any config behaviour.

**Architecture:** Role membership is the `require()` dependency closure of each role's launcher roots (`tools/closure.lua`, driven by `tools/gen_manifest.lua`'s `ROLES`). The `ui` role currently opts into `sharedDiag = true`, which adds the five diagnostic launchers as extra closure roots; those launchers `require()` the whole control loop, so the UI PC carries a full second copy of it. Removing `sharedDiag` from `ui` drops the diagnostic commands **and** every control-loop module that only they dragged in, while the cockpit app's own closure — which legitimately needs `fcs.comauto`, the `fcs.comms.*` link, and the `fcs.io.*` config layer — is untouched.

**Tech Stack:** Lua 5.1 (CC:Tweaked), CraftOS-PC headless test harness, `tools/gen_manifest.lua` + `tools/closure.lua` manifest generator, the `tests/framework.lua` unit harness, and the `tests/suite_probe.lua` end-to-end Suite-install harness.

## Global Constraints

- **Scope is the `ui` role's `sharedDiag` opt-in only.** Do **not** touch the `fcs` role (it keeps the diagnostic tools and the flight stack — they belong there). Do **not** touch `nav`/`beacon`/`beaconcontrol` (already `sharedDiag`-free; S1 only adds regression locks).
- **Config FILES are OUT OF SCOPE for S1.** The `ui` role's `configs` list (`/eh2_devbind.tbl`, `/eh2_senscal.tbl`, `/eh2_tuning.tbl`, `/eh2_ui_config.tbl`) is **unchanged**. Removing the FCS config-file copies from the UI is **deferred to S2**, because the FCS pulls its config from the UI's `cfgserver` at boot and a role's `configs` list is exactly the set of files the Suite backs up and preserves-across-repair (`easyhover2_suite.lua:561,568,641`) — dropping them now would make a UI reinstall delete them and silently feed the FCS defaults. `tests/test_manifest_channels.lua:45` ("fcs and ui roles back up all their config files") therefore **stays green and unmodified**.
- **All standard gates green before commit:** src suite (`bash tests/run_headless.sh`), dist suite (`bash tests/run_headless_dist.sh`), and e2e (`bash tests/run_suite_e2e.sh`). The src/dist runners begin with a manifest sync check (`tools/run_gen.sh --check`), so the manifests **must** be regenerated after the `ROLES` edit or every gate fails fast.
- **Manifests are generated, never hand-edited.** After editing `tools/gen_manifest.lua`, regenerate both channels with `bash tools/run_gen.sh` (writes `manifest.lua` + `manifest-dev.lua`). No `node tools/build.mjs` rebuild is needed: S1 removes files from a role's list but changes no source bytes, and `dist/` already mirrors every source file.
- **Attribution** on the commit (per session policy):
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
  ```

---

## Verified facts this plan rests on (research already done)

- **The cockpit app closure does not include the control loop.** No `ui/` file requires `fcs.control/runtime/schemes/safety/modes`. The control loop reaches the UI PC *only* through the `sharedDiag` launchers (`launchers/hovertest.lua` → `tools.hover_test` → `fcs.runtime.loop` + `fcs.modes.registry` → schemes → `fcs.control.*`; `launchers/calibrate.lua`/`probe.lua` pull only `fcs.io.*`).
- **The UI's legitimate FCS dependencies survive.** `ui/basalt/bitconfig/tuning.lua:77` requires `fcs.comauto` → `fcs.mixer.level_flight` (the thrust-mix math — **not** `fcs.schemes.level_flight`, the control scheme). `ui/basalt/app.lua` requires `fcs.comms.{modem,telemetry,command,health}` and `tools.fnv1a`. These are separate closure paths from the diagnostic launchers and are unaffected.
- **`tools/` stays in `ui.dirs`.** The cockpit closure require()s three `tools.*` modules directly: `tools.fnv1a` (`ui/basalt/app.lua:38`), `tools.binddevices` (`ui/basalt/bitconfig/mdb.lua:22`, the MDB device-bind menu), and `tools.calibrate` (`ui/basalt/bitconfig/senscal.lua:75`, SENS CAL reusing calibrate's pure helpers for byte-parity with the terminal tool). So `tools/fnv1a.lua`, `tools/binddevices.lua`, and `tools/calibrate.lua` remain in the UI closure — the diagnostic COMMANDS leave, these shared helper MODULES stay. The role's `tools/` repair scope is preserved, so the existing switch-prune of `/tools/flight.lua` (`suite_probe.lua:416`) keeps working.
- **The FCS-config menus don't depend on the diagnostic tools.** FCS TUNING / SENS CAL / DEVBIND are Basalt panels inside the `ui.basalt.app` closure; they read/write local config via `fcs.io.cfgspec` (nil-safe → `fcs.io.tuningdefaults`). Dropping the diagnostic launchers leaves every dependency they use in place. **Operator caveat satisfied: the config menus still work after S1.**
- **Only two test files hard-code the current UI shipping:** `tests/test_manifest_channels.lua` (append new assertions) and `tests/suite_probe.lua` (ui + switch phases). `tests/test_suite.lua` uses synthetic role fixtures and is unaffected.

---

### Task 1: `ui` role drops the diagnostic tools + flight stack

**Files:**
- Modify: `tools/gen_manifest.lua:61-73` (the `ui` role in `ROLES`) — remove `sharedDiag = true`.
- Regenerate: `manifest.lua`, `manifest-dev.lua` (via `bash tools/run_gen.sh`; do not hand-edit).
- Test (append): `tests/test_manifest_channels.lua` (end of file).
- Test (modify): `tests/suite_probe.lua` — the `phase == "ui"` block (after line 383) and the `phase == "switch"` block (lines ~421-427).

**Interfaces:**
- Consumes: the committed manifest shape — `m.roles.<name>.files` is an array of `{ src, dst, size, sum }`; a command launcher ships as a file whose `dst` is a bare name (no `/`, e.g. `"calibrate"`); a module ships at `dst = "<path>.lua"`. `m.roles.<name>.configs` is an array of `/`-prefixed config paths. Helpers `load(path)` and `toSet(list)` already exist at the top of `tests/test_manifest_channels.lua`.
- Produces: a manifest in which the FCS flight/diagnostic stack is present only under `m.roles.fcs`, and a regenerated `manifest.lua`/`manifest-dev.lua` pair that passes `tools/run_gen.sh --check`.

- [ ] **Step 1: Write the failing manifest assertion (RED)**

Append to the end of `tests/test_manifest_channels.lua`:

```lua
-- ===== S1 (config overhaul): the FCS flight/diagnostic stack ships ONLY to the fcs role =====
-- The shared diagnostic launchers (calibrate/hovertest/probe*) require() the whole flight control
-- loop; before S1 the `ui` role opted into them (sharedDiag) and so carried a full second copy of
-- the control stack. S1 drops sharedDiag from `ui`, so those commands + the control-loop modules
-- they alone dragged in must be ABSENT from every non-fcs role, while the UI's real dependencies
-- (comauto for its FCS TUNING menu, the comms link, the fcs.io config layer, tools.fnv1a) STAY.
-- The UI's FCS config FILES (devbind/senscal/tuning) are deliberately UNCHANGED here -- their
-- removal is S2 (see docs/superpowers/plans/2026-09-02-config-overhaul-s1-shipping.md), which is
-- why the "back up all their config files" test above is left exactly as it is.

local function dstSet(role)
  local s = {}
  for _, f in ipairs(role.files) do s[f.dst] = true end
  return s
end

-- The diagnostic COMMANDS (bare-name launcher dst) + the control-loop modules they alone pull in.
-- None of these has a ui/nav/beacon require() path: no ui file requires fcs.control/runtime/
-- schemes/safety/modes, and ui.basalt.bitconfig.tuning requires fcs.comauto -> fcs.mixer.
-- level_flight (thrust math), NOT fcs.schemes.level_flight (the control scheme listed here).
-- NOTE: the calibrate/probe COMMANDS leave, but the MODULE tools/calibrate.lua STAYS on the ui role
-- and is asserted in UI_KEEPS below -- SENS CAL (ui/basalt/bitconfig/senscal.lua:75) require()s
-- tools.calibrate to reuse its pure helpers for byte-identical parity with the terminal tool, so it
-- is a genuine UI dependency, not diagnostic-only. Only the diag tool BODIES with no ui requirer
-- (hover_test, probe) belong in this leave-list.
local FCS_ONLY_STACK = {
  "calibrate", "hovertest", "probe", "probemodem", "probebatch",   -- diagnostic commands (launchers)
  "tools/hover_test.lua", "tools/probe.lua",                        -- diag tool bodies, no ui requirer
  "fcs/runtime/loop.lua", "fcs/modes/registry.lua",
  "fcs/schemes/level_flight.lua", "fcs/control/pid.lua",
  "fcs/safety/oscillation.lua", "fcs/actuate/level.lua", "fcs/tuning.lua",
}

-- The UI's LEGITIMATE fcs/tools dependencies -- these MUST survive S1 (the config menus need them).
-- tools/calibrate.lua (SENS CAL parity) and tools/binddevices.lua (the MDB device-bind menu,
-- ui/basalt/bitconfig/mdb.lua:22) are shared helper modules the cockpit require()s directly -- the
-- calibrate COMMAND leaves, but this module stays.
local UI_KEEPS = {
  "cockpit", "ui/basalt/app.lua", "tools/fnv1a.lua",
  "tools/calibrate.lua", "tools/binddevices.lua",
  "fcs/comauto.lua", "fcs/mixer/level_flight.lua", "fcs/comms/telemetry.lua",
  "fcs/io/cfgspec.lua", "fcs/io/tuningdefaults.lua", "fcs/io/calibration.lua",
  "ui/basalt/bitconfig/tuning.lua", "ui/basalt/bitconfig/senscal.lua",
}

t.test("S1: the fcs flight/diagnostic stack ships only to the fcs role", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = load(path)
    -- fcs KEEPS the whole stack (S1 does not touch the fcs role).
    local fcs = dstSet(m.roles.fcs)
    for _, dst in ipairs(FCS_ONLY_STACK) do
      t.truthy(fcs[dst], path .. ": fcs still ships " .. dst)
    end
    -- Every non-fcs role is free of it.
    for _, role in ipairs({ "ui", "nav", "beacon", "beaconcontrol" }) do
      local set = dstSet(m.roles[role])
      for _, dst in ipairs(FCS_ONLY_STACK) do
        t.truthy(not set[dst], path .. ": " .. role .. " does not ship " .. dst)
      end
    end
    -- The UI keeps its real config-menu dependencies.
    local ui = dstSet(m.roles.ui)
    for _, dst in ipairs(UI_KEEPS) do
      t.truthy(ui[dst], path .. ": ui still ships " .. dst)
    end
  end
end)
```

- [ ] **Step 2: Run the src suite to verify the new test FAILS**

Run: `bash tests/run_headless.sh`
Expected: the manifest sync check passes (nothing changed yet), then the suite fails in `test_manifest_channels` with e.g. `/manifest.lua: ui does not ship calibrate` (the `ui` role currently *does* ship `calibrate`/`hovertest`/`probe*` and the control loop). This confirms the assertion is meaningful.

- [ ] **Step 3: Drop `sharedDiag` from the `ui` role**

In `tools/gen_manifest.lua`, the `ui` role (starts at line 61). Delete the `sharedDiag = true,` line (currently line 67) and update the role's comment to record the S1 decision. Change:

```lua
  ui = {
    title = "Cockpit display", status = "released",
    blurb = "Receives telemetry, renders reported state, sends commands on touch. Boots the cockpit.",
    configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/ui.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/cockpit.lua", dst = "cockpit" } },
    sharedDiag = true,
```

to:

```lua
  ui = {
    title = "Cockpit display", status = "released",
    blurb = "Receives telemetry, renders reported state, sends commands on touch. Boots the cockpit.",
    -- S1 (config overhaul): NO sharedDiag. The diagnostic launchers (calibrate/hovertest/probe*)
    -- require() the whole flight control loop; shipping them here made the UI PC carry a second copy
    -- of the FCS control stack. The cockpit's own closure keeps the deps its config menus actually
    -- use (fcs.comauto, fcs.comms.*, fcs.io.*) -- those are separate require() paths. The UI's FCS
    -- config-FILE copies stay in `configs` for now; removing them is S2 (coupled to the live-write
    -- path, since the FCS boot-pulls config from the UI's cfgserver today).
    configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/ui.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/cockpit.lua", dst = "cockpit" } },
```

(Keep the existing `extraFiles = { { src = "release/basalt-full.lua", dst = "basalt-full.lua" } },` line that follows.)

- [ ] **Step 4: Regenerate both manifests**

Run: `bash tools/run_gen.sh`
Expected: writes `manifest.lua` and `manifest-dev.lua`; prints success. (If it errors that a file can't be read, run `node tools/build.mjs` once and retry — but no source bytes changed, so this should not be needed.)

- [ ] **Step 5: Run the src suite to verify GREEN**

Run: `bash tests/run_headless.sh`
Expected: manifest sync check passes (manifests now match the generator), and the whole src suite passes — including the new `S1: the fcs flight/diagnostic stack ships only to the fcs role` test and the unchanged `fcs and ui roles back up all their config files` test.

- [ ] **Step 6: Extend the e2e — assert a UI computer is flight-stack-free**

In `tests/suite_probe.lua`, in the `phase == "ui"` block, immediately after line 383 (`check(not fs.exists("/fcs/runtime/flight.lua"), ...)`), add:

```lua
  -- S1: the shared FCS diagnostic launchers and the control loop they drag in are gone from a ui
  -- computer. The cockpit needs none of them; its config menus keep comauto + the comms link + the
  -- fcs.io layer, which are separate require() paths. (The UI's FCS config FILES are intentionally
  -- still present at this phase -- their removal is S2.)
  check(not fs.exists("/calibrate"), "no calibrate diag launcher on a ui computer")
  check(not fs.exists("/hovertest"), "no hovertest diag launcher on a ui computer")
  check(not fs.exists("/probe"), "no probe diag launcher on a ui computer")
  check(not fs.exists("/fcs/runtime/loop.lua"), "no fcs control loop on a ui computer")
  check(not fs.exists("/fcs/schemes/level_flight.lua"), "no fcs control scheme on a ui computer")
  check(not fs.exists("/tools/hover_test.lua"), "no fcs diag tool body on a ui computer")
  -- But the config menus' real dependencies DID land:
  check(fs.exists("/fcs/comauto.lua"), "the ui keeps comauto for its FCS TUNING menu")
  check(fs.exists("/fcs/comms/telemetry.lua"), "the ui keeps the comms link")
  check(fs.exists("/ui/basalt/bitconfig/tuning.lua"), "the ui keeps its FCS TUNING menu")
```

- [ ] **Step 7: Update the e2e switch phase — `/probe` is no longer shared**

In `tests/suite_probe.lua`, `phase == "switch"` block. First, after the fcs-install setup asserts (near line 401, after the `/flight present before switch` check), add a setup assertion so the "gone after" check below passes for the right reason:

```lua
  check(fs.exists("/probe"), "test setup: fcs diag launcher /probe present before switch")
```

Then update the post-switch survival check. Replace the current lines 424-427:

```lua
  -- roles ship (/probe) must survive -- pruning only ever touches suite launchers this role drops.
  check(not fs.exists("/flight"), "the old role's orphan ROOT launcher /flight was pruned")
  check(fs.exists("/cockpit"), "a root launcher the new role ships (/cockpit) survived the switch")
  check(fs.exists("/probe"), "a root launcher both roles ship (/probe) survived the switch")
```

with:

```lua
  -- The NEW role's own launcher survives; the OLD role's orphan launchers are pruned. After S1 the
  -- ui role no longer ships the FCS diagnostic launchers, so /probe is now an fcs-only orphan and is
  -- pruned on the switch, exactly like /flight. (/cockpit covers "a launcher the new role ships
  -- survives"; pre-S1 both roles shipped /probe, so it used to survive here.)
  check(not fs.exists("/flight"), "the old role's orphan ROOT launcher /flight was pruned")
  check(fs.exists("/cockpit"), "a root launcher the new role ships (/cockpit) survived the switch")
  check(not fs.exists("/probe"), "the old role's diag launcher /probe was pruned (ui no longer ships it)")
```

- [ ] **Step 8: Run the e2e suite to verify GREEN**

Run: `bash tests/run_suite_e2e.sh`
Expected: all phases pass — the `ui` phase's new flight-stack-free assertions and the `switch` phase's updated `/probe` prune check both pass.

- [ ] **Step 9: Run the dist acceptance gate**

Run: `bash tests/run_headless_dist.sh`
Expected: manifest sync check passes and the full suite passes against the minified `dist/` tree (proving the min-channel manifest is consistent too).

- [ ] **Step 10: Commit**

```bash
git add tools/gen_manifest.lua manifest.lua manifest-dev.lua tests/test_manifest_channels.lua tests/suite_probe.lua
git commit -m "$(cat <<'EOF'
feat(config-overhaul S1): ui role drops FCS diagnostic tools + flight stack

Remove sharedDiag from the ui role so the diagnostic launchers
(calibrate/hovertest/probe*) and the control-loop modules they alone pull in
stop shipping to the cockpit PC -- the flight stack now lives on the FCS role
only. The cockpit's own closure keeps the deps its config menus use (comauto,
fcs.comms.*, fcs.io.*), so FCS TUNING / SENS CAL still work.

Config-FILE copies stay on the ui role for now; their removal is S2 (coupled to
the live-write path, since the FCS boot-pulls config from the UI's cfgserver).

Tests: manifest-channel assertion that the flight/diag stack ships only to fcs
and the UI keeps its real deps; e2e asserts a ui computer is flight-stack-free
and that /probe is pruned on an fcs->ui switch. src + dist + e2e green.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Du8LP5F3JD4U6MY1cDmNrh
EOF
)"
```

---

## Self-Review

**1. Spec coverage (design §4 S1 row + §6 shipping tests):**
- "drop FCS-config **tools** from non-FCS" → Step 3 removes `sharedDiag` from `ui` (the only non-fcs role that had it); nav/beacon/beaconcontrol never had it. ✓
- "drop UI-config tools from non-UI" → no such role-shipped launchers exist (UI config is in-app Basalt menus, not launchers); nothing to remove. Noted, no-op. ✓
- "both from NAV/BEACON" → already absent; Steps 1/6 add regression locks (manifest + e2e). ✓
- "remove the UI's copies of FCS configs from its `configs`" → **deliberately deferred to S2** (operator-approved on 2026-09-02); rationale in Global Constraints. The design's own §4 order note ("each phase is its own merge-to-main unit") supports keeping S1 behaviour-safe. ✓ (documented deviation, not a gap)
- §6 "manifest/closure tests … absent from non-FCS role closures and vice-versa (extends the e2e role-install checks)" → Step 1 (manifest) + Steps 6-7 (e2e). ✓

**2. Placeholder scan:** none — every step has exact file/line targets, real Lua, and concrete run/expected lines.

**3. Type consistency:** `dstSet`/`toSet` return `{[string]=true}` sets checked with `t.truthy`; `load(path)` returns the parsed manifest table used consistently as `m.roles.<name>.files`/`.configs`; `check(cond, msg)` matches `suite_probe.lua`'s existing signature; command launchers are checked by bare-name `dst` / bare-name path, consistent with the manifest structure verified in research.

One nuance for the implementer: the exact set of `fcs.io.*` files that leave the UI (e.g. `hwconfig`/`cut`/`backend`) is decided by the deterministic closure and pinned by `run_gen.sh --check`; the tests assert only the unambiguous control-loop set and the must-keep set, so they stay robust regardless of those borderline io files.
