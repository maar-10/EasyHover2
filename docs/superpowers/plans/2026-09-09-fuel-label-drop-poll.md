# Fuel label fix + drop thruster fuel poll — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) Make the FLIGHT-panel "Liquid Main" fuel label reflect the *selected* fuel type instead of a hardcoded "BDSL". (2) Remove the per-thruster fuel poll (a 1Hz mainThread drain feeding only the now-unwanted §11.8 no-fuel interlock).

**Architecture:** The "Liquid Main" label was a static constant (`M.LIQUID_ABBR="BDSL"`); wire it to `state.fuel` via a fuel-abbreviation lookup in `fueltable`. The thruster fuel poll (`pollFuel`/`fuelTask` in `tools/flight.lua`) feeds only `deps.fuel` (the §11.8 interlock getter) + two telemetry fields nothing displays; remove it. The interlock self-disables when no fuel getter is provided (`fcs/runtime/flight.lua:252` `if not self.fuel then return end`), so `noFuel` simply stays `false` — the UI still reads that field safely.

**Tech Stack:** Lua 5.1 (CC:Tweaked), Basalt 2.0 UI, project test framework, headless CraftOS-PC.

## Global Constraints

- Branch `fix/fuel-label-drop-poll` (off `main`, already created).
- Do NOT remove the `noFuel` telemetry field — the UI consumes it (`ui/basalt/regions/emc.lua:124` refuses master-on; `ui/engine.lua:291` forces chute-off). It just stays permanently `false` after the poll is gone.
- Leave the §11.8 interlock CODE in `fcs/runtime/flight.lua` intact (it self-disables without a fuel getter); only remove the READING in `tools/flight.lua`. Its unit tests inject a fake fuel getter and must stay green.
- Only the LIQUID (tank) label is fuel-type-dynamic; the SOLID/pump label (`M.SOLID_ABBR="BZC"`, blaze cake) is unchanged.
- Suite lists live in `tests/run_headless.sh` and `tests/run_headless_dist.sh`. `dist/` is a committed artifact. Never stage user untracked files (`E2E-TEST-REPORT-*.md`, `TASKING *.md`, `eh2 flight log *.txt`, `image.png`) — targeted `git add` only.
- Run: `bash tests/run_headless.sh` (src), `bash tests/run_headless_dist.sh` (dist).

---

### Task 1: "Liquid Main" label reflects the selected fuel

**Files:**
- Modify: `fcs/fueltable.lua` (add `abbrevOf`)
- Modify: `ui/basalt/regions/emc.lua` (M.main: wire `mainLabel` to `state.fuel` in `apply`)
- Test: `tests/test_fueltable.lua`, `tests/test_region_emc.lua`

**Interfaces:**
- Produces: `fueltable.abbrevOf(name)` → short uppercase abbrev (Biodiesel→"BDSL", Diesel→"DSL", …; unknown → first 4 chars upper; nil → the default fuel's abbrev). The M.main `apply(state)` sets `mainLabel` text to `"Liquid Main " .. fueltable.abbrevOf(state.fuel)` (fit to width).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_fueltable.lua`:

```lua
t.test("abbrevOf maps known fuels and falls back for unknown", function()
  local ft = require("fcs.fueltable")
  t.eq(ft.abbrevOf("Biodiesel"), "BDSL")
  t.eq(ft.abbrevOf("Diesel"), "DSL")
  t.eq(ft.abbrevOf("Sulfurized Diesel"), "SDSL")
  t.eq(ft.abbrevOf("Gasoline"), "GAS")
  t.eq(ft.abbrevOf("Mystery Fuel"), "MYST")     -- unknown -> first 4 upper
  t.eq(ft.abbrevOf(nil), ft.abbrevOf(ft.default)) -- nil -> default fuel's abbrev
end)
```

In `tests/test_region_emc.lua`, add a case that builds M.main, calls its `apply` with a `state.fuel`, and asserts the `mainLabel` text. Follow the file's existing M.main build/apply harness (it already exercises `mainBar`/`flowLabel`); assert:

```lua
-- after building M.main and getting its apply + elements (mirror the existing M.main test setup):
apply({ fuel = "Diesel", tankMb = 200000, pumpAmount = 5 })
t.truthy(elements.mainLabel.getText():find("DSL"), "Liquid Main label shows selected fuel abbrev")
apply({ fuel = "Biodiesel", tankMb = 200000 })
t.truthy(elements.mainLabel.getText():find("BDSL"), "label updates to BDSL on Biodiesel")
```

> NOTE: use the same element-text accessor the other `test_region_emc` assertions use (e.g. `:getText()`); `mainLabel` is already exposed in M.main's returned `elements` table (`ui/basalt/regions/emc.lua:339`).

- [ ] **Step 2: Run to verify it fails** — `bash tests/run_headless.sh`; expect FAIL (`abbrevOf` nil; label still static "BDSL").

- [ ] **Step 3: Implement**

In `fcs/fueltable.lua`, before `return M`:

```lua
M.abbr = {
  ["Plant Oil"] = "POIL", ["Ethanol"] = "ETH", ["Biodiesel"] = "BDSL",
  ["Sulfurized Diesel"] = "SDSL", ["Diesel"] = "DSL", ["Gasoline"] = "GAS",
  ["Kerosene"] = "KERO", ["Turpentine"] = "TURP",
}
function M.abbrevOf(name)
  if name == nil then name = M.default end
  return M.abbr[name] or (name and name:sub(1, 4):upper()) or "?"
end
```

In `ui/basalt/regions/emc.lua`, at the top require the table if not already (`local fueltable = require("fcs.fueltable")` — check existing requires; add if missing). In M.main's `apply(state)` (the block starting near line 294), add after the `mainBar:setProgress(...)` line:

```lua
    mainLabel:setText(fit("Liquid Main " .. fueltable.abbrevOf(state.fuel), iw))
```

(`mainLabel` and `iw` are already in M.main's scope from the build at line ~245.)

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; new tests green; existing `test_region_emc`, `test_fueltable`, `test_page_flight` green.

- [ ] **Step 5: Commit**

```bash
git add fcs/fueltable.lua ui/basalt/regions/emc.lua tests/test_fueltable.lua tests/test_region_emc.lua
git commit -m "fix(ui): Liquid Main label reflects selected fuel type (was hardcoded BDSL)"
```

---

### Task 2: Remove the per-thruster fuel poll (mainThread drain)

**Files:**
- Modify: `tools/flight.lua` (remove `fuelState`, the `deps.fuel` getter, `pollFuel`/`fuelPeriph`/`fuelCap`/`fuelTask`, the two `snap.fuelMain`/`snap.thrusterFuel` lines, and `fuelTask` from both `parallel.waitForAny` lists)
- Test: `tests/test_flight.lua`

**Interfaces:**
- Consumes: nothing new. After this, `Flight.new` receives no `fuel` dep → `self.fuel` is nil → the §11.8 interlock no-ops → `noFuel` stays `false`. No peripheral fuel reads anywhere.

- [ ] **Step 1: Write the failing/guard test** (append to `tests/test_flight.lua`)

```lua
t.test("no-fuel interlock is inert when no fuel getter is provided (fuel reading removed)", function()
  local Flight = require("fcs.runtime.flight")
  -- Build a Flight with the minimum deps and NO `fuel` getter (mirrors the real assembly now).
  local f = Flight.new({ loop = { setpoints = function() end, arm = function() end,
      cycle = function() return { mode = "NORMAL", m = {}, demands = {}, duties = {} } end,
      getMode = function() return "NORMAL" end, setActive = function() end, clearDamped = function() end },
    pilot = { setMode = function() end }, registry = { default = "PRECISION", byId = { PRECISION = {} } },
    config = {} })
  t.eq(f.fuel, nil, "no fuel getter wired")
  t.eq(f.noFuel, false, "noFuel starts false")
  -- Drive a step; with no fuel getter the interlock must never latch noFuel.
  f:step(0.05, {}, { onGround = false })
  t.eq(f.noFuel, false, "interlock inert -> noFuel stays false")
end)
```

> NOTE: match `Flight.new`'s actual required-deps shape from `fcs/runtime/flight.lua` — if it needs more stubs (e.g. `masterMode`, `feel`), add the minimal stubs the existing `test_flight.lua` cases already use; the point of the test is `f.fuel == nil` and `noFuel` never latching. If a simpler existing helper builds a Flight, reuse it and just assert the two `noFuel`/`fuel` facts.

- [ ] **Step 2: Run to verify it passes-or-fails** — `bash tests/run_headless.sh`. This test should PASS immediately (the interlock already no-ops without a getter) — it's a GUARD documenting the intended end state. If it fails, fix the stub shape until it exercises `:step` cleanly. (No RED needed; this task is a removal — the real verification is Step 4's green suite after deleting the poll.)

- [ ] **Step 3: Implement — delete the fuel-poll code in `tools/flight.lua`:**
  - Remove the `local fuelState = { ... }` line (~113).
  - Remove the `fuel = function() return fuelState.fuelMain end,` line from the `Flight.new{...}` deps (~123) — drop the whole `fuel = …` entry.
  - Remove the `local fuelPeriph, fuelCap = {}, {}` line, the entire `local function pollFuel() … end`, and the entire `local function fuelTask() … end` (~489-523), plus the `-- ---- Fuel readback ----` comment block.
  - Remove `snap.thrusterFuel = fuelState.thrusterFuel` and `snap.fuelMain = fuelState.fuelMain` (~557-558) inside `controlTask`.
  - Remove `fuelTask,` from BOTH `parallel.waitForAny(...)` argument lists (~726 LOGGING branch and ~732 non-LOGGING branch).
  - Do NOT touch `noFuel` anywhere in the telemetry snapshot (it comes from `flight.noFuel`, stays false) or the §11.8 interlock code in `fcs/runtime/flight.lua`.

- [ ] **Step 4: Run to verify it passes** — `bash tests/run_headless.sh`; the guard test green; whole suite green. Confirm no dangling references: `grep -n "fuelState\|pollFuel\|fuelTask\|fuelMain\|thrusterFuel" tools/flight.lua` returns nothing.

- [ ] **Step 5: Commit**

```bash
git add tools/flight.lua tests/test_flight.lua
git commit -m "perf(fcs): drop per-thruster fuel poll (unused 1Hz mainThread drain); interlock self-disables"
```

---

### Task 3: Dist rebuild + both acceptance gates

**Files:** `dist/`, `manifest.lua`, `manifest-dev.lua` (regenerated); no new source.

- [ ] **Step 1:** `node tools/build.mjs && bash tools/run_gen.sh`
- [ ] **Step 2:** Run BOTH gates green, record counts: `bash tests/run_headless.sh`, `bash tests/run_headless_dist.sh`
- [ ] **Step 3:** `git add dist manifest.lua manifest-dev.lua` (targeted — never `-A`, never user untracked files); commit `build: regenerate dist tree + manifests for fuel-label + drop-poll`
- [ ] **Step 4:** `git status --short` shows only the four user untracked files.

---

## Self-Review
**Spec coverage:** label wired to selected fuel (Task 1); fuel poll removed, interlock self-disables, noFuel preserved (Task 2); dist/gates (Task 3). ✓
**Placeholder scan:** none.
**Type consistency:** `fueltable.abbrevOf(name)` defined in Task 1, used in the emc region same task. Task 2 removes symbols wholesale (verified no dangling refs in Step 4). `noFuel` telemetry field untouched. ✓

## Verification note
Headless proves the label wiring and that removing the poll keeps the suite green + the interlock inert. In-world: the "Liquid Main" label should now read `DSL` after you pick Diesel (and refill), and the FCS should show no more 1Hz fuel-read cost. `noFuel` stays false — the master-on refuse/chute-off safety no longer auto-triggers (intentional; the tank gauge covers it).
