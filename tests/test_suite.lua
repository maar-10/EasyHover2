-- EasyHover 2 Suite unit tests. Run under tests/run_headless.sh.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")   -- existing project test framework

local fnv1a = require("tools.fnv1a")

t.test("fnv1a reference vectors", function()
  t.eq(fnv1a(""), "811c9dc5")
  t.eq(fnv1a("a"), "e40c292c")
  t.eq(fnv1a("hello"), "4f9f2cab")
end)

local Config = require("fcs.io.config")

t.test("config withDefaults is additive over hwconfig", function()
  local merged = Config.withDefaults({ bindings = { signPitch = -1 } })
  t.eq(merged.bindings.signPitch, -1)      -- kept
  t.eq(merged.bindings.signRoll, 1)        -- filled from defaults
  t.eq(merged.fuelRelay, false)            -- filled from defaults
end)

t.test("config save then load round-trips", function()
  local path = "/eh2_test_cfg.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { bindings = { yawBaseline = 3 } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil); t.eq(cfg.bindings.yawBaseline, 3)
  fs.delete(path)
end)

t.test("config load reports absent + unparseable distinctly", function()
  local cfg, existed = Config.load("/eh2_nope.tbl")
  t.eq(existed, false)
  local bad = "/eh2_bad_cfg.tbl"
  local f = fs.open(bad, "w"); f.write("this is not = a table {{{"); f.close()
  local c2, ex2, err2 = Config.load(bad)
  t.eq(ex2, true)          -- the file exists
  t.eq(err2 ~= nil, true)  -- but did not parse
  fs.delete(bad)
end)

local closure = require("tools.closure")

t.test("closure follows literal require() and dedupes", function()
  local files = {
    ["a.lua"]     = 'local b = require("b")\nlocal c = require("pkg.c")',
    ["b.lua"]     = 'local c = require("pkg.c")',
    ["pkg/c.lua"] = '-- leaf, no requires',
  }
  local read = function(p) return files[p] end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(err, nil)
  t.eq(table.concat(out, ","), "a.lua,b.lua,pkg/c.lua")
end)

t.test("closure resolves init.lua form and unions multiple roots", function()
  local files = {
    ["app.lua"]      = 'require("mod")',
    ["mod/init.lua"] = '-- package',
    ["tool.lua"]     = 'require("mod")',
  }
  local out = closure.resolve({ "tool.lua", "app.lua" }, function(p) return files[p] end)
  t.eq(table.concat(out, ","), "app.lua,mod/init.lua,tool.lua")
end)

t.test("closure errors on unresolvable require", function()
  local read = function(p) if p == "a.lua" then return 'require("ghost")' end end
  local out, err = closure.resolve({ "a.lua" }, read)
  t.eq(out, nil)
  t.eq(err:find("ghost") ~= nil, true)
end)

-- tools/gen_manifest.lua exposes its pure helpers (deterministic serialiser, dirs derivation)
-- on a table when _G.EH2_GEN_TEST is set, so they can be unit-tested without touching fs.
_G.EH2_GEN_TEST = true
local gen = require("tools.gen_manifest")
_G.EH2_GEN_TEST = nil

t.test("gen_manifest luaValue serialises map keys in sorted order", function()
  t.eq(gen.luaValue({ b = 2, a = 1 }, 0), "{\n  [\"a\"] = 1,\n  [\"b\"] = 2,\n}")
end)

t.test("gen_manifest luaValue keeps array order and quotes/escapes strings", function()
  t.eq(gen.luaValue({ "x", "y" }, 0), "{\n  \"x\",\n  \"y\",\n}")
  t.eq(gen.luaValue('a"b\\c', 0), '"a\\"b\\\\c"')
  t.eq(gen.luaValue({}, 0), "{}")
end)

t.test("gen_manifest dirsOf derives the top-level directory repair scope", function()
  local dirs = gen.dirsOf({ "fcs/x.lua", "tools/y.lua", "startup.lua" })
  t.eq(table.concat(dirs, ","), "fcs,tools")
end)

_G.EH2_SUITE_NO_RUN = true
local Suite = require("easyhover2_suite")

t.test("shouldPersistChannel is false until the manifest is readable", function()
  t.eq(Suite.shouldPersistChannel(false, false, false), false, "failed fetch")
  t.eq(Suite.shouldPersistChannel(true, false, true), false, "--check")
  t.eq(Suite.shouldPersistChannel(false, true, true), false, "--list")
  t.eq(Suite.shouldPersistChannel(false, false, true), true, "real install succeeded")
end)

t.test("suite checksum matches shared fnv1a", function()
  t.eq(Suite.checksum("hello"), fnv1a("hello"))
  t.eq(Suite.checksum(""), "811c9dc5")
end)

t.test("isProtected covers EH2 config + suite files", function()
  t.eq(Suite.isProtected("/eh2_hw_config.tbl"), true)
  t.eq(Suite.isProtected("/easyhover2_install.txt"), true)
  t.eq(Suite.isProtected("/easyhover2_backup/x"), true)
  t.eq(Suite.isProtected("/fcs/io/config.lua"), false)  -- code is not protected
end)

t.test("resolveChannel: flag wins, else marker, else default min; corrupt -> min", function()
  t.eq(Suite.resolveChannel("dev", nil), "dev", "explicit --dev")
  t.eq(Suite.resolveChannel("min", "dev"), "min", "explicit --min overrides a dev marker")
  t.eq(Suite.resolveChannel(nil, "dev"), "dev", "marker chosen when no flag")
  t.eq(Suite.resolveChannel(nil, "min"), "min", "marker chosen when no flag")
  t.eq(Suite.resolveChannel(nil, nil), "min", "absent marker defaults to min")
  t.eq(Suite.resolveChannel(nil, "garbage"), "min", "corrupt marker defaults to min")
  t.eq(Suite.resolveChannel(nil, "  dev\n"), "dev", "marker is trimmed")
end)

t.test("manifestName maps channel to the fetched file", function()
  t.eq(Suite.manifestName("min"), "manifest.lua")
  t.eq(Suite.manifestName("dev"), "manifest-dev.lua")
end)

t.test("the channel marker is a PROTECTED path (install cannot clobber the operator's choice)", function()
  t.eq(Suite.isProtected(Suite.CHANNEL_FILE), true)
end)

t.test("choosePlan truth table (carried from v1)", function()
  t.eq(Suite.choosePlan({ anyInstall = false }), "install")
  t.eq(Suite.choosePlan({ anyInstall = true, forceRepair = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, noRecord = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = true }), "repair")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = true, mismatched = false }), "current")
  t.eq(Suite.choosePlan({ anyInstall = true, sameVersion = false }), "update")
end)

local function fakeManifest()
  return { roles = {
    fcs = { status="released", files = {
      { dst="startup.lua", size=3, sum=Suite.checksum("fcs") },
      { dst="tools/flight.lua", size=1, sum="x" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
    ui = { status="released", files = {
      { dst="startup.lua", size=2, sum=Suite.checksum("ui") },
      { dst="ui/main.lua", size=1, sum="z" },
      { dst="fcs/io/backend.lua", size=1, sum="y" },
    }},
  }}
end

t.test("isReleased is true only for a released spec", function()
  t.eq(Suite.isReleased({ status = "released", files = {} }), true)
  t.eq(Suite.isReleased({ status = "reserved" }), false)  -- a planned-but-unshipped role
  t.eq(Suite.isReleased({ status = "planned" }), false)
  t.eq(Suite.isReleased({}), false)                       -- no status at all
  t.eq(Suite.isReleased(nil), false)                      -- no spec (unknown role)
end)

t.test("orphanLaunchers = suite launchers the role does not ship, never arbitrary root files", function()
  local m = { roles = {
    fcs = { files = {
      { dst = "startup.lua" }, { dst = "flight" }, { dst = "probe" }, { dst = "tools/flight.lua" },
    } },
    ui = { files = {
      { dst = "startup.lua" }, { dst = "cockpit" }, { dst = "probe" }, { dst = "ui/main.lua" },
    } },
  } }
  -- switching TO ui: fcs's /flight is the orphan; /cockpit (ui ships it), /probe (both),
  -- and /startup.lua (both) all stay. Nested modules (tools/, ui/) are never candidates.
  t.eq(table.concat(Suite.orphanLaunchers(m.roles.ui, m), ","), "/flight")
  -- switching TO fcs: ui's /cockpit is the orphan
  t.eq(table.concat(Suite.orphanLaunchers(m.roles.fcs, m), ","), "/cockpit")
  -- no manifest -> nothing to sweep (the in-dir walk stays the whole story)
  t.eq(#Suite.orphanLaunchers(m.roles.fcs, nil), 0)
end)

t.test("detectRole keys on the installed startup launcher", function()
  local m = fakeManifest()
  local disk = { ["/startup.lua"] = "ui" }  -- matches ui's startup sum
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "ui")
end)

t.test("detectRole falls back to unique files when startup is missing", function()
  local m = fakeManifest()
  local disk = { ["/tools/flight.lua"] = "a", ["/fcs/io/backend.lua"] = "b" }  -- fcs-unique present
  local exists = function(p) return disk[p] ~= nil end
  local read = function(p) return disk[p] end
  local role = Suite.detectRole(m, exists, read)
  t.eq(role, "fcs")
end)

t.test("backup keeps exactly one (latest) copy", function()
  local root = "/easyhover2_backup"
  if fs.exists(root) then fs.delete(root) end
  local src = "/eh2_hw_config.tbl"
  local f = fs.open(src, "w"); f.write("v1"); f.close()
  Suite.backupConfig(src, "verA")     -- new API: single-latest
  f = fs.open(src, "w"); f.write("v2"); f.close()
  Suite.backupConfig(src, "verB")
  -- exactly one backup file remains, containing the latest pre-backup content ("v2")
  local names = fs.list(root)
  t.eq(#names, 1)
  local bf = fs.open(root .. "/" .. names[1], "r"); local body = bf.readAll(); bf.close()
  t.eq(body, "v2")
  fs.delete(src); fs.delete(root)
end)

t.test("backupConfig keeps one latest copy PER FILE (does not wipe siblings)", function()
  local a, b = "/eh2_devbind.tbl", "/eh2_senscal.tbl"
  local fa = fs.open(a, "w"); fa.write("A"); fa.close()
  local fb = fs.open(b, "w"); fb.write("B"); fb.close()
  Suite.backupConfig(a, "v"); Suite.backupConfig(b, "v")
  t.truthy(fs.exists("/easyhover2_backup/eh2_devbind.tbl"), "first survives")
  t.truthy(fs.exists("/easyhover2_backup/eh2_senscal.tbl"), "second present")
  fs.delete(a); fs.delete(b); fs.delete("/easyhover2_backup")
end)

t.test("withDefaults on eh2_tuning.tbl path does not inject thrusters", function()
  local merged = Config.withDefaults(
    { gains = { hoverDuty = 0.26 }, caps = {}, feel = {} },
    "/eh2_tuning.tbl")
  t.eq(merged.thrusters, nil, "split tuning must not gain fused thrusters")
  t.eq(merged.gains.hoverDuty, 0.26)
end)

t.test("extendConfig on eh2_tuning.tbl does not inject thrusters", function()
  local path = "/eh2_tuning.tbl"
  Config.save(path, { gains = { hoverDuty = 0.26 }, caps = {}, feel = {} })
  local spec = { configModule = "fcs.io.config", luaPath = "/" }
  local result = Suite.extendConfig(spec, path, "verX")
  t.eq(result, "extended")
  local cfg = Config.load(path)
  t.eq(cfg.thrusters, nil, "extended tuning has no thrusters key")
  t.eq(cfg.gains.hoverDuty, 0.26)
  fs.delete(path)
end)

t.test("extendConfig uses the manifest's configModule (additive)", function()
  local path = "/eh2_hw_config.tbl"
  local Config = require("fcs.io.config")
  Config.save(path, { bindings = { signPitch = -1 } })   -- a pilot value, missing new keys
  local spec = { configModule = "fcs.io.config", luaPath = "/" }
  local result = Suite.extendConfig(spec, path, "verX")
  t.eq(result, "extended")
  local cfg = Config.load(path)
  t.eq(cfg.bindings.signPitch, -1)      -- kept
  t.eq(cfg.bindings.signRoll, 1)        -- filled from defaults
  fs.delete(path)
end)

t.test("uiPanels fit within bounds and don't overlap", function()
  local function overlaps(a, b)
    return a.x <= b.x + b.w - 1 and b.x <= a.x + a.w - 1
       and a.y <= b.y + b.h - 1 and b.y <= a.y + a.h - 1
  end
  for _, sz in ipairs({ {51,19}, {39,13} }) do
    local p = Suite.uiPanels(sz[1], sz[2])
    for _, r in pairs(p) do
      t.eq(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= sz[1] and r.y + r.h - 1 <= sz[2], true)
    end
    -- self-check: no two panels overlap
    local names, keys = {}, {}
    for name in pairs(p) do keys[#keys + 1] = name end
    for i = 1, #keys do
      for j = i + 1, #keys do
        t.eq(overlaps(p[keys[i]], p[keys[j]]), false)
      end
    end
  end
end)

t.test("progressFill is proportional and clamped", function()
  t.eq(Suite.progressFill(0, 0, 10), 0)
  t.eq(Suite.progressFill(5, 10, 10), 5)
  t.eq(Suite.progressFill(10, 10, 10), 10)
  t.eq(Suite.progressFill(99, 10, 10), 10)
end)

t.test("statusColour maps plan to colour", function()
  t.eq(Suite.statusColour("current"), colours.lime)
  t.eq(Suite.statusColour("update"), colours.yellow)
  t.eq(Suite.statusColour("repair"), colours.orange)
  t.eq(Suite.statusColour("install"), colours.cyan)
end)

t.test("diffLabel: an available update lists files as outdated, not corrupt", function()
  t.eq(Suite.diffLabel("update"), "outdated")   -- new version => changed files are outdated, NOT corrupt
  t.eq(Suite.diffLabel("repair"), "corrupt")    -- same version but bytes differ => genuine corruption
  t.eq(Suite.diffLabel("current"), "corrupt")
end)

t.test("selfIsPersistent: only a saved easyhover2_suite.lua self-updates (skip wget-run temps)", function()
  t.eq(Suite.selfIsPersistent("/easyhover2_suite.lua"), true)
  t.eq(Suite.selfIsPersistent("disk/easyhover2_suite.lua"), true)
  t.eq(Suite.selfIsPersistent("rom/programs/http/wget"), false)  -- wget run: not our saved file
  t.eq(Suite.selfIsPersistent(""), false)
  t.eq(Suite.selfIsPersistent(nil), false)
end)

-- ---------------------------------------------------------------- Task 11: dashboard UI

t.test("diagTools lists root-level shipped files, excludes startup.lua", function()
  local spec = { files = {
    { dst = "startup.lua" },
    { dst = "flight" },
    { dst = "calibrate" },
    { dst = "hovertest" },
    { dst = "fcs/io/config.lua" },   -- not root-level: excluded
    { dst = "tools/probe.lua" },     -- not root-level: excluded
  } }
  t.eq(table.concat(Suite.diagTools(spec), ","), "flight,calibrate,hovertest")
end)

t.test("diagTools is empty for a spec with no root-level files besides startup", function()
  local spec = { files = { { dst = "startup.lua" }, { dst = "fcs/io/config.lua" } } }
  t.eq(#Suite.diagTools(spec), 0)
end)

t.test("actionSpec omits Go when current, folds standalone Repair when plan is repair", function()
  local function keys(ctx)
    local out = {}
    for _, a in ipairs(Suite.actionSpec(ctx)) do out[#out + 1] = a.key end
    return table.concat(out, ",")
  end
  t.eq(keys({ plan = "current" }), "verify,repair,switch,tools,quit")
  t.eq(keys({ plan = "install" }), "go,verify,repair,switch,tools,quit")
  -- plan == repair: "go" already says Repair, so the standalone Repair button is folded away
  t.eq(keys({ plan = "repair" }), "go,verify,switch,tools,quit")
end)

t.test("actionButtons fits everything on one page on a 51-wide terminal", function()
  local actions = Suite.actionSpec({ plan = "update" })
  local layout = Suite.actionButtons({ x = 1, y = 19, w = 51, h = 1 }, actions, 1)
  t.eq(layout.pages, 1)
  t.eq(#layout.buttons, #actions)
  for _, b in ipairs(layout.buttons) do
    t.eq(b.x >= 1 and b.x + b.w - 1 <= 51, true)
    t.eq(b.y, 19)
  end
end)

t.test("actionButtons pages on a 26-wide terminal without exceeding the row", function()
  local actions = Suite.actionSpec({ plan = "update" }) -- 7 buttons
  local rect = { x = 1, y = 20, w = 26, h = 1 }
  local layout = Suite.actionButtons(rect, actions, 1)
  t.eq(layout.pages > 1, true)
  for _, b in ipairs(layout.buttons) do
    t.eq(b.x >= 1 and b.x + b.w - 1 <= 26, true)
  end
  -- every button across every page is reachable and none collide within a page
  local seen = {}
  for page = 1, layout.pages do
    local pl = Suite.actionButtons(rect, actions, page)
    local cells = {}
    for _, b in ipairs(pl.buttons) do
      seen[b.key] = true
      for cell = b.x, b.x + b.w - 1 do
        t.eq(cells[cell], nil, "button collision on page " .. page)
        cells[cell] = b.key
      end
    end
  end
  for _, a in ipairs(actions) do t.eq(seen[a.key], true, "missing action " .. a.key) end
end)

t.test("hitTestButtons finds the button under a click and misses elsewhere", function()
  local buttons = {
    { key = "go", x = 1, y = 19, w = 8 },
    { key = "quit", x = 10, y = 19, w = 6 },
  }
  t.eq(Suite.hitTestButtons(buttons, 1, 19), "go")
  t.eq(Suite.hitTestButtons(buttons, 8, 19), "go")
  t.eq(Suite.hitTestButtons(buttons, 9, 19), nil)   -- gap between buttons
  t.eq(Suite.hitTestButtons(buttons, 10, 19), "quit")
  t.eq(Suite.hitTestButtons(buttons, 1, 5), nil)    -- wrong row
end)

t.test("listRows lays out one row per item, clipped to panel height", function()
  local items = { { key = "a", label = "a" }, { key = "b", label = "b" }, { key = "c", label = "c" } }
  local rows = Suite.listRows({ x = 2, y = 5, w = 10, h = 2 }, items)
  t.eq(#rows, 2)   -- clipped: only 2 rows of height available
  t.eq(rows[1].key, "a"); t.eq(rows[1].x, 2); t.eq(rows[1].y, 5)
  t.eq(rows[2].key, "b"); t.eq(rows[2].y, 6)
end)

t.test("hit-test dispatch: clicking a diagTools row against uiPanels' diag rect resolves the tool", function()
  -- Simulates the runUI "tools" mode wiring: uiPanels -> diagTools -> listRows -> hitTestButtons,
  -- with a fake click coordinate, entirely without a terminal.
  local spec = { files = {
    { dst = "startup.lua" }, { dst = "flight" }, { dst = "calibrate" }, { dst = "hovertest" },
  } }
  local panels = Suite.uiPanels(51, 19)
  local names = Suite.diagTools(spec)
  local items = {}
  for _, n in ipairs(names) do items[#items + 1] = { key = n, label = n } end
  local rows = Suite.listRows({ x = panels.diag.x + 1, y = panels.diag.y + 1,
    w = panels.diag.w - 2, h = panels.diag.h - 2 }, items)
  t.eq(#rows, #names)
  local secondRow = rows[2]
  t.eq(Suite.hitTestButtons(rows, secondRow.x, secondRow.y), names[2])
end)

-- ---------------------------------------------------------------- Task 1: engine surface

t.test("say routes through Suite.sink when set, else prints (classic behavior)", function()
  t.eq(Suite.sink, nil, "sink defaults to nil so classic output is unchanged")
  local seen = {}
  Suite.sink = function(text, c) seen[#seen+1] = text end
  Suite.emit("hello", colours.lime)          -- Suite.emit = the shared say() exposed for the test
  Suite.sink = nil
  t.eq(seen[1], "hello", "sink received the line")
end)

t.test("engine helpers are exposed for SuiteX reuse", function()
  t.eq(type(Suite.fetch), "function")
  t.eq(type(Suite.readFile), "function")
  t.eq(type(Suite.checkFile), "function")
  t.eq(type(Suite.STATE_FILE), "string")
  t.eq(type(Suite.base), "string")
end)

t.test("checkFile classifies a file against its manifest entry", function()
  local entry = { dst = "x", size = 3, sum = Suite.checksum("abc") }
  t.eq(Suite.checkFile(entry, function() return "abc" end), "ok")
  t.eq(Suite.checkFile(entry, function() return nil end), "missing")
  t.eq(Suite.checkFile(entry, function() return "abX" end), "corrupt")
end)

-- ---------------------------------------------------------------- performPlan: in-place install
--
-- performPlan replaces each file IN PLACE, one at a time -- no download-everything-into-.eh2new-
-- then-commit staging -- so a role never needs a second full copy of itself on disk (the disk
-- pressure that motivated the change). The observable contract of "in place": when a fetch fails
-- PART WAY through, the files that already succeeded sit on disk at their FINAL paths, not rolled
-- back, and never as leftover .eh2new staging turds. The old all-or-nothing staging discarded
-- every partial write on a mid-run failure, so it would leave those final paths absent -- which
-- is exactly what this asserts against. Suite.fetch is injected so the failure needs no network.
t.test("performPlan writes each verified file in place; a mid-run failure keeps the earlier ones", function()
  local dir = "probe_inplace_dir"
  local bodies = { "AA", "BBB" }   -- files 1 and 2 fetch OK; file 3's fetch fails
  local files = {
    { src = dir .. "/a.lua", dst = dir .. "/a.lua", size = #bodies[1], sum = Suite.checksum(bodies[1]) },
    { src = dir .. "/b.lua", dst = dir .. "/b.lua", size = #bodies[2], sum = Suite.checksum(bodies[2]) },
    { src = dir .. "/c.lua", dst = dir .. "/c.lua", size = 4,          sum = "deadbeef" },
  }
  local spec = { files = files, dirs = { dir }, configs = {}, entry = "" }

  if fs.exists("/" .. dir) then fs.delete("/" .. dir) end

  local savedFetch = Suite.fetch
  local n = 0
  Suite.fetch = function() n = n + 1; if n >= 3 then return nil, "boom" end; return bodies[n] end

  local ok = pcall(Suite.performPlan, "http://mirror", { version = "vT", schema = 1 },
    spec, "fcs", "install", true)

  Suite.fetch = savedFetch

  t.eq(ok, false, "the failed fetch aborts the run (die throws)")
  t.eq(fs.exists("/" .. dir .. "/a.lua"), true, "file 1 was written straight to its FINAL path")
  t.eq(fs.exists("/" .. dir .. "/b.lua"), true, "file 2 was written straight to its FINAL path")
  t.eq(fs.exists("/" .. dir .. "/c.lua"), false, "the file whose fetch failed was never written")
  t.eq(fs.exists("/" .. dir .. "/a.lua.eh2new"), false, "no .eh2new staging copy left behind")
  t.eq(fs.exists("/" .. dir .. "/b.lua.eh2new"), false, "no .eh2new staging copy left behind")
  local f = fs.open("/" .. dir .. "/a.lua", "r"); local a = f.readAll(); f.close()
  t.eq(a, bodies[1], "file 1 holds the verified content")

  fs.delete("/" .. dir)
end)

-- The self-heal contract has a second half the test above does not pin: the install record
-- (/easyhover2_install.txt) must be WITHHELD when a run does not finish. That withheld stamp is
-- what makes "interrupted -> re-run fixes it" work instead of "interrupted -> Suite believes it is
-- current and never re-fetches the stale files". A regression that stamped the record early would
-- pass the file-placement test above yet silently break self-heal -- so assert the stamp directly.
t.test("performPlan withholds the install record when a run does not finish (self-heal stays armed)", function()
  local dir = "probe_stamp_dir"
  local bodies = { "AA" }   -- file 1 fetches OK; file 2's fetch fails part way through
  local files = {
    { src = dir .. "/a.lua", dst = dir .. "/a.lua", size = #bodies[1], sum = Suite.checksum(bodies[1]) },
    { src = dir .. "/b.lua", dst = dir .. "/b.lua", size = 4,          sum = "deadbeef" },
  }
  local spec = { files = files, dirs = { dir }, configs = {}, entry = "" }
  if fs.exists("/" .. dir) then fs.delete("/" .. dir) end

  -- Never clobber a real install record: stash and restore it around the probe.
  local savedState
  if fs.exists(Suite.STATE_FILE) then
    local f = fs.open(Suite.STATE_FILE, "r"); savedState = f.readAll(); f.close()
  end
  fs.delete(Suite.STATE_FILE)

  local savedFetch = Suite.fetch
  local n = 0
  Suite.fetch = function() n = n + 1; if n >= 2 then return nil, "boom" end; return bodies[n] end

  local ok = pcall(Suite.performPlan, "http://mirror", { version = "vT", schema = 1 },
    spec, "fcs", "install", true)

  Suite.fetch = savedFetch

  t.eq(ok, false, "the failed fetch aborts the run")
  t.eq(fs.exists(Suite.STATE_FILE), false,
    "install record NOT written after a partial run -- the next run still sees work to do")

  if fs.exists("/" .. dir) then fs.delete("/" .. dir) end
  fs.delete(Suite.STATE_FILE)
  if savedState then local f = fs.open(Suite.STATE_FILE, "w"); f.write(savedState); f.close() end
end)

-- Requirement: a file that fails verification must NOT destroy the good copy already on disk. The
-- whole safety of delete-then-write rests on verify (size+checksum) running BEFORE the delete. This
-- pre-seeds a good target, hands back a CORRUPT download for it, and proves the original survives
-- byte-for-byte. If someone ever reorders the delete ahead of the verify, this goes red.
t.test("performPlan refuses a corrupt download and leaves the existing good file intact", function()
  local dir = "probe_verify_dir"
  if fs.exists("/" .. dir) then fs.delete("/" .. dir) end
  local original = "GOOD-ORIGINAL"
  local f = fs.open("/" .. dir .. "/c.lua", "w"); f.write(original); f.close()

  local want = "NEW-VERIFIED-CONTENT"   -- what the manifest promises...
  local files = {
    { src = dir .. "/c.lua", dst = dir .. "/c.lua", size = #want, sum = Suite.checksum(want) },
  }
  local spec = { files = files, dirs = { dir }, configs = {}, entry = "" }

  local savedFetch = Suite.fetch
  Suite.fetch = function() return "CORRUPTED-BYTES" end   -- ...but the fetch hands back the wrong bytes

  local ok = pcall(Suite.performPlan, "http://mirror", { version = "vT", schema = 1 },
    spec, "fcs", "update", false)

  Suite.fetch = savedFetch

  t.eq(ok, false, "a corrupt download aborts the run")
  t.eq(fs.exists("/" .. dir .. "/c.lua"), true, "the existing good file is still there")
  local g = fs.open("/" .. dir .. "/c.lua", "r"); local now = g.readAll(); g.close()
  t.eq(now, original, "the good file was neither deleted nor overwritten by the corrupt download")
  t.eq(fs.exists("/" .. dir .. "/c.lua.eh2new"), false, "no staging turd left behind")

  fs.delete("/" .. dir)
end)

-- Config-sacred, end-to-end. Configs are handled by extendConfig, never the payload loop -- but the
-- guarantee that ultimately protects them is guard() firing BEFORE the delete. Force the issue: put
-- a PROTECTED config path in the payload file list with a download that would pass verification, so
-- the ONLY thing that can stop the overwrite is the guard. The operator's file must be untouched.
t.test("performPlan never deletes or overwrites a protected config, even if one is in the file list", function()
  local cfg = "/eh2_probe_guard.tbl"   -- matches PROTECTED ^/eh2_.*%.tbl$
  local original = "operator=owned\n"
  local f = fs.open(cfg, "w"); f.write(original); f.close()

  local want = "release-would-overwrite-this"
  local files = {
    { src = "eh2_probe_guard.tbl", dst = "eh2_probe_guard.tbl", size = #want, sum = Suite.checksum(want) },
  }
  local spec = { files = files, dirs = {}, configs = {}, entry = "" }

  local savedFetch = Suite.fetch
  Suite.fetch = function() return want end   -- size+checksum WOULD pass; only guard() stands in the way

  local ok = pcall(Suite.performPlan, "http://mirror", { version = "vT", schema = 1 },
    spec, "fcs", "update", false)

  Suite.fetch = savedFetch

  t.eq(ok, false, "the guard aborts the run before any protected path is touched")
  t.eq(fs.exists(cfg), true, "the protected config was NOT deleted")
  local g = fs.open(cfg, "r"); local now = g.readAll(); g.close()
  t.eq(now, original, "the protected config's content is untouched")

  fs.delete(cfg)
end)

-- ---------------------------------------------------------------- Task 2: manifest basalt entry

t.test("manifest records the vendored basalt for SuiteX to verify", function()
  local f = fs.open("/manifest.lua", "r")
  if not f then error("manifest.lua not found") end
  local body = f.readAll()
  f.close()
  local manifest = textutils.unserialise(body)
  t.eq(type(manifest.basalt), "table")
  t.truthy(manifest.basalt.size and manifest.basalt.size > 0, "basalt size")
  t.eq(type(manifest.basalt.sum), "string")
end)

-- ---------------------------------------------------------------- S5: --flag-defaults / --migrate-config
--
-- Bare-name keyed store, matching cfgdefault/cfgaccess read(name)/write(name, body).
local hwconfig = require("fcs.io.hwconfig")
local cfgspec = require("fcs.io.cfgspec")

local function fakeCfgFs(seed)
  local files = {}
  for k, v in pairs(seed or {}) do files[k] = v end
  return files,
    function(name) return files[name] end,
    function(name, body) files[name] = body; return true end
end

local function setOf(list)
  local s = {}
  for _, k in ipairs(list or {}) do s[k] = true end
  return s
end

t.test("DEFAULTS_BACKUP is a dedicated dir, not the update-backup", function()
  t.eq(Suite.DEFAULTS_BACKUP, "/easyhover2_defaults_backup")
  t.eq(Suite.isProtected(Suite.DEFAULTS_BACKUP), true)
  t.eq(Suite.isProtected(Suite.DEFAULTS_BACKUP .. "/eh2_devbind.tbl"), true)
  t.eq(Suite.isProtected("/easyhover2_backup/x"), true, "update-backup still protected")
end)

t.test("flagDefaults copies existing currents into DEFAULTS_BACKUP then snapshots", function()
  local db, sc, fuel, tuning = "DB-NOW", "SC-NOW", "FUEL-NOW", "TUNING-NOW"
  local files, read, write = fakeCfgFs({
    ["eh2_devbind.tbl"] = db,
    ["eh2_senscal.tbl"] = sc,
    ["eh2_fuelcal.tbl"] = fuel,
    ["eh2_tuning.tbl"] = tuning,
  })
  local r = Suite.flagDefaults("fcs", read, write)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_devbind.tbl"], db)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_senscal.tbl"], sc)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_fuelcal.tbl"], fuel)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_tuning.tbl"], tuning, "tuning current is backed up")
  t.eq(files["eh2_devbind.default.tbl"], db)
  t.eq(files["eh2_senscal.default.tbl"], sc)
  t.eq(files["eh2_fuelcal.default.tbl"], fuel)
  t.eq(files["eh2_tuning.default.tbl"], nil, "tuning DEFAULT never written")
  t.eq(files["eh2_tuning.tbl"], tuning, "current tuning untouched")
  local copied, skipped = setOf(r.copied), setOf(r.skipped)
  t.truthy(copied.devbind and copied.senscal and copied.fuelcal)
  t.eq(copied.tuning, nil)
  t.truthy(skipped.tuning)
end)

t.test("flagDefaults writes backups before any DEFAULT sibling", function()
  local files = { ["eh2_devbind.tbl"] = "DB" }
  local order = {}
  local read = function(name) return files[name] end
  local write = function(name, body)
    order[#order + 1] = name
    files[name] = body
    return true
  end
  Suite.flagDefaults("fcs", read, write)
  local firstBackup, firstDefault
  for i, name in ipairs(order) do
    if not firstBackup and name:find("easyhover2_defaults_backup", 1, true) then
      firstBackup = i
    end
    if not firstDefault and name:find("%.default%.tbl$") then
      firstDefault = i
    end
  end
  t.truthy(firstBackup, "a backup write happened")
  t.truthy(firstDefault, "a DEFAULT write happened")
  t.eq(firstBackup < firstDefault, true, "backup precedes snapshot")
end)

t.test("flagDefaults does not invent backups or DEFAULTs for missing currents", function()
  local files, read, write = fakeCfgFs({ ["eh2_devbind.tbl"] = "ONLY-DB" })
  local r = Suite.flagDefaults("fcs", read, write)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_devbind.tbl"], "ONLY-DB")
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_senscal.tbl"], nil)
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_fuelcal.tbl"], nil)
  t.eq(files["eh2_devbind.default.tbl"], "ONLY-DB")
  t.eq(files["eh2_senscal.default.tbl"], nil)
  t.eq(files["eh2_fuelcal.default.tbl"], nil)
  local copied, skipped = setOf(r.copied), setOf(r.skipped)
  t.truthy(copied.devbind)
  t.truthy(skipped.senscal and skipped.fuelcal and skipped.tuning)
end)

t.test("flagDefaults ui copies uicfg into backup and DEFAULT", function()
  local files, read, write = fakeCfgFs({ ["eh2_ui_config.tbl"] = "UI-BODY" })
  local r = Suite.flagDefaults("ui", read, write)
  t.eq(#r.copied, 1); t.eq(r.copied[1], "uicfg")
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_ui_config.tbl"], "UI-BODY")
  t.eq(files["eh2_ui_config.default.tbl"], "UI-BODY")
end)

t.test("migrateConfig splits fused into missing splits and never deletes fused", function()
  local legacy = hwconfig.merge({
    thrusters = { FL = "thruster_1" },
    sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0",
    bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, hwconfig.defaults())
  local fusedBody = textutils.serialise(legacy)
  local files, read, write = fakeCfgFs({ ["eh2_hw_config.tbl"] = fusedBody })
  local r = Suite.migrateConfig(read, write, "fcs")
  t.eq(r.action, "split")
  t.truthy(files["eh2_devbind.tbl"] ~= nil)
  t.truthy(files["eh2_senscal.tbl"] ~= nil)
  t.eq(files["eh2_hw_config.tbl"], fusedBody, "fused never deleted or rewritten")
  local db = textutils.unserialise(files["eh2_devbind.tbl"])
  local sc = textutils.unserialise(files["eh2_senscal.tbl"])
  t.eq(db.thrusters.FL, "thruster_1")
  t.eq(db.fuelRelay, "relay_0")
  t.eq(sc.signHeading, -1)
  t.eq(sc.heightOffset, -94.5)
end)

t.test("migrateConfig on ui/nav refuses and writes no FCS splits", function()
  local fusedBody = textutils.serialise(hwconfig.defaults())
  local files, read, write = fakeCfgFs({ ["eh2_hw_config.tbl"] = fusedBody })
  local r = Suite.migrateConfig(read, write, "ui")
  t.eq(r.action, "refuse")
  t.eq(files["eh2_devbind.tbl"], nil)
  t.eq(files["eh2_senscal.tbl"], nil)
  r = Suite.migrateConfig(read, write, "nav")
  t.eq(r.action, "refuse")
  t.eq(files["eh2_devbind.tbl"], nil)
end)

t.test("migrateConfig noops when both splits exist (fused left alone)", function()
  local fused = textutils.serialise(hwconfig.defaults())
  local files, read, write = fakeCfgFs({
    ["eh2_devbind.tbl"] = "DB",
    ["eh2_senscal.tbl"] = "SC",
    ["eh2_hw_config.tbl"] = fused,
  })
  local r = Suite.migrateConfig(read, write, "fcs")
  t.eq(r.action, "noop")
  t.eq(files["eh2_devbind.tbl"], "DB")
  t.eq(files["eh2_senscal.tbl"], "SC")
  t.eq(files["eh2_hw_config.tbl"], fused)
end)

-- CLI: --flag-defaults / --migrate-config run the op and return; they must not install.
-- Suite.main uses the local fetch(), so tests drive the extracted runner with injected fs.
t.test("runConfigFlags --flag-defaults writes backup+DEFAULT and does not call performPlan", function()
  local files, read, write = fakeCfgFs({ ["eh2_devbind.tbl"] = "DB" })
  local performed = false
  local saved = Suite.performPlan
  Suite.performPlan = function() performed = true; return true end
  local seen = {}
  Suite.sink = function(text) seen[#seen + 1] = text end
  local ok = Suite.runConfigFlags({ flagDefaults = true }, "fcs", read, write)
  Suite.sink = nil
  Suite.performPlan = saved
  t.eq(ok, true)
  t.eq(performed, false, "performPlan must not run")
  t.eq(files[Suite.DEFAULTS_BACKUP .. "/eh2_devbind.tbl"], "DB")
  t.eq(files["eh2_devbind.default.tbl"], "DB")
  local joined = table.concat(seen, "\n")
  t.truthy(joined:find("flag-defaults", 1, true), "one-line summary mentions flag-defaults")
end)

t.test("runConfigFlags --migrate-config reports action and does not install", function()
  local fusedBody = textutils.serialise(hwconfig.defaults())
  local files, read, write = fakeCfgFs({ ["eh2_hw_config.tbl"] = fusedBody })
  local performed = false
  local saved = Suite.performPlan
  Suite.performPlan = function() performed = true; return true end
  local seen = {}
  Suite.sink = function(text) seen[#seen + 1] = text end
  local ok = Suite.runConfigFlags({ migrateConfig = true }, "fcs", read, write)
  Suite.sink = nil
  Suite.performPlan = saved
  t.eq(ok, true)
  t.eq(performed, false)
  t.eq(files["eh2_hw_config.tbl"], fusedBody)
  t.truthy(files["eh2_devbind.tbl"] ~= nil)
  local joined = table.concat(seen, "\n")
  t.truthy(joined:find("migrate-config", 1, true), "one-line summary mentions migrate-config")
  t.truthy(joined:find("split", 1, true))
end)

t.test("parseArgs recognizes --flag-defaults and --migrate-config without dropping --check/--list/--dev/--min", function()
  local a = Suite.parseArgs({ "--flag-defaults" })
  t.eq(a.flagDefaults, true)
  t.eq(a.checkOnly, false)
  t.eq(a.listOnly, false)
  local b = Suite.parseArgs({ "--migrate-config", "fcs" })
  t.eq(b.migrateConfig, true)
  t.eq(b.wantRole, "fcs")
  local c = Suite.parseArgs({ "--check", "--list", "--dev" })
  t.eq(c.checkOnly, true)
  t.eq(c.listOnly, true)
  t.eq(c.wantChannel, "dev")
  local d = Suite.parseArgs({ "--min" })
  t.eq(d.wantChannel, "min")
  t.eq(d.flagDefaults, false)
  t.eq(d.migrateConfig, false)
end)
