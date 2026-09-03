-- tests/test_bitconfig_dtc.lua
-- DTC (Data Cartridge) sub-menu (ui/basalt/bitconfig/dtc.lua): tests the PURE M.plan map, the
-- disk-layout path helpers (MUST match fcs/boot/loaderui.lua's diskSource byte-for-byte -- see
-- Task 9's integration concern), M._detect/M._scan/M._export/M._import with an in-memory fs
-- stub (no real disk), plus a real-CraftOS-PC Basalt construction probe.
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.dtc")
local Nav = require("ui.basalt.nav")
local BasaltApp = require("ui.basalt.app")
local cfgspec = require("fcs.io.cfgspec")

-- ===== M.KINDS: canonical ordered list, resolves via cfgspec.FILES =====

t.test("KINDS: four kinds in devbind/senscal/tuning/uicfg order", function()
  t.eq(#M.KINDS, 4)
  t.eq(M.KINDS[1], "devbind"); t.eq(M.KINDS[2], "senscal"); t.eq(M.KINDS[3], "tuning")
  t.eq(M.KINDS[4], "uicfg")
end)

-- ===== M.plan: PURE, no IO ===== (TDD cases from the task brief)

t.test("plan: kind present locally but not on disk -> canExport true, canImport false", function()
  local present = { localHas = { devbind = true }, diskHas = {} }
  local plan = M.plan(present)
  local row = plan[1] -- devbind is KINDS[1]
  t.eq(row.kind, "devbind")
  t.eq(row.hasLocal, true); t.eq(row.hasDisk, false)
  t.eq(row.canExport, true); t.eq(row.canImport, false)
end)

t.test("plan: kind present on disk only -> canExport false, canImport true", function()
  local present = { localHas = {}, diskHas = { senscal = true } }
  local plan = M.plan(present)
  local row = plan[2] -- senscal is KINDS[2]
  t.eq(row.kind, "senscal")
  t.eq(row.hasLocal, false); t.eq(row.hasDisk, true)
  t.eq(row.canExport, false); t.eq(row.canImport, true)
end)

t.test("plan: kind present both local and disk -> both true", function()
  local present = { localHas = { tuning = true }, diskHas = { tuning = true } }
  local plan = M.plan(present)
  local row = plan[3] -- tuning is KINDS[3]
  t.eq(row.kind, "tuning")
  t.eq(row.canExport, true); t.eq(row.canImport, true)
end)

t.test("plan: kind absent both -> both false", function()
  local plan = M.plan({ localHas = {}, diskHas = {} })
  for _, row in ipairs(plan) do
    t.eq(row.hasLocal, false); t.eq(row.hasDisk, false)
    t.eq(row.canExport, false); t.eq(row.canImport, false)
  end
end)

t.test("plan: filename resolves via M.FILE for every row (equals cfgspec.FILES for FCS kinds)", function()
  local plan = M.plan({ localHas = {}, diskHas = {} })
  for _, row in ipairs(plan) do
    t.eq(row.filename, M.FILE[row.kind])
  end
  t.eq(M.FILE.devbind, cfgspec.FILES.devbind)
  t.eq(M.FILE.senscal, cfgspec.FILES.senscal)
  t.eq(M.FILE.tuning, cfgspec.FILES.tuning)
end)

t.test("plan: exportable/importable convenience lists reflect canExport/canImport correctly", function()
  local present = {
    localHas = { devbind = true, tuning = true },
    diskHas  = { senscal = true, tuning = true },
  }
  local plan = M.plan(present)
  t.eq(#plan.exportable, 2)
  t.eq(plan.exportable[1], "devbind"); t.eq(plan.exportable[2], "tuning")
  t.eq(#plan.importable, 2)
  t.eq(plan.importable[1], "senscal"); t.eq(plan.importable[2], "tuning")
end)

t.test("plan: empty present -> empty exportable/importable lists, four rows still present", function()
  local plan = M.plan({})
  t.eq(#plan, 4)
  t.eq(#plan.exportable, 0)
  t.eq(#plan.importable, 0)
end)

-- ===== Path helpers: MUST match loaderui.lua's diskSource byte-for-byte =====
-- loaderui's diskSource reads realRead("/" .. mount .. "/" .. cfgspec.FILES[kind]).

t.test("localPath/diskPath: resolve to the exact paths the boot loader's own/disk sources use", function()
  t.eq(M.localPath("devbind"), "/eh2_devbind.tbl")
  t.eq(M.localPath("devbind"), "/" .. cfgspec.FILES.devbind)
  t.eq(M.diskPath("disk", "devbind"), "/disk/eh2_devbind.tbl")
  t.eq(M.diskPath("disk", "devbind"), "/" .. "disk" .. "/" .. cfgspec.FILES.devbind)
  t.eq(M.diskPath("disk", "senscal"), "/disk/eh2_senscal.tbl")
  t.eq(M.diskPath("disk", "tuning"), "/disk/eh2_tuning.tbl")
end)

t.test("diskPath: works with an arbitrary mount name (not hardcoded to 'disk')", function()
  t.eq(M.diskPath("disk3_1", "tuning"), "/disk3_1/eh2_tuning.tbl")
end)

-- ===== M._detect: drive presence/label detection, injected find =====

t.test("_detect: no drive peripheral found -> present false, driveFound false", function()
  local d = M._detect({ find = function(kind) return nil end })
  t.eq(d.present, false)
  t.eq(d.driveFound, false)
  t.eq(d.mount, nil)
end)

t.test("_detect: drive found but no disk inserted -> present false, driveFound true", function()
  local drive = { isDiskPresent = function() return false end }
  local d = M._detect({ find = function(kind) t.eq(kind, "drive"); return drive end })
  t.eq(d.present, false)
  t.eq(d.driveFound, true)
  t.eq(d.mount, nil)
end)

t.test("_detect: disk present -> present true, mount + label surfaced", function()
  local drive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local d = M._detect({ find = function() return drive end })
  t.eq(d.present, true)
  t.eq(d.mount, "disk")
  t.eq(d.label, "CART1")
end)

t.test("_detect: disk present with no label -> label falls back to 'unlabeled'", function()
  local drive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return nil end,
  }
  local d = M._detect({ find = function() return drive end })
  t.eq(d.label, "unlabeled")
end)

-- ===== M._scan: which files exist locally / on disk, injected exists =====

t.test("_scan: reports localHas/diskHas per kind via the injected exists()", function()
  local existsSet = {
    ["/eh2_devbind.tbl"] = true,
    ["/disk/eh2_senscal.tbl"] = true,
  }
  local scan = M._scan("disk", { exists = function(p) return existsSet[p] == true end })
  t.eq(scan.localHas.devbind, true)
  t.eq(scan.localHas.senscal, false)
  t.eq(scan.localHas.tuning, false)
  t.eq(scan.diskHas.devbind, false)
  t.eq(scan.diskHas.senscal, true)
  t.eq(scan.diskHas.tuning, false)
end)

t.test("_scan: with mount=nil (no disk), diskHas is false for every kind regardless of exists()", function()
  local scan = M._scan(nil, { exists = function(p) return true end })
  t.eq(scan.diskHas.devbind, false)
  t.eq(scan.diskHas.senscal, false)
  t.eq(scan.diskHas.tuning, false)
end)

t.test("_scan feeds directly into M.plan", function()
  local existsSet = { ["/eh2_devbind.tbl"] = true, ["/disk/eh2_devbind.tbl"] = true }
  local scan = M._scan("disk", { exists = function(p) return existsSet[p] == true end })
  local plan = M.plan(scan)
  t.eq(plan[1].canExport, true); t.eq(plan[1].canImport, true) -- devbind
  t.eq(plan[2].canExport, false); t.eq(plan[2].canImport, false) -- senscal
end)

-- ===== M._export / M._import: in-memory fs stub, atomic tmp-then-move =====

local function fakeFsDeps(initialFiles)
  local files = {}
  for k, v in pairs(initialFiles or {}) do files[k] = v end
  local log = { write = {}, delete = {}, move = {} }
  local deps = {
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) log.write[#log.write + 1] = p; files[p] = body end,
    delete = function(p) log.delete[#log.delete + 1] = p; files[p] = nil end,
    move   = function(from, to) log.move[#log.move + 1] = { from = from, to = to }; files[to] = files[from]; files[from] = nil end,
  }
  return files, deps, log
end

t.test("_export: copies ONLY fcsGet-present FCS kinds to the CORRECT diskPath, returns exported kinds", function()
  local files, deps, log = fakeFsDeps({})
  deps.fcsGet = function(kind)
    if kind == "devbind" then return "BODY-DEVBIND" end
    if kind == "tuning" then return "BODY-TUNING" end
    return nil
  end

  local exported = M._export("disk", deps)

  t.eq(#exported, 2)
  t.eq(exported[1], "devbind"); t.eq(exported[2], "tuning")

  t.eq(files["/disk/eh2_devbind.tbl"], "BODY-DEVBIND")
  t.eq(files["/disk/eh2_tuning.tbl"], "BODY-TUNING")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "senscal had no fcsGet body, so never exported")
  t.eq(files["/eh2_devbind.tbl"], nil, "no UI-local FCS file created")
  t.eq(files["/eh2_tuning.tbl"], nil, "no UI-local FCS file created")

  -- atomic: wrote to a .tmp path, then moved into place (no direct write to the final path)
  local wroteTmp = false
  for _, p in ipairs(log.write) do
    if p == "/disk/eh2_devbind.tbl.tmp" then wroteTmp = true end
  end
  t.truthy(wroteTmp, "wrote to a .tmp path before moving")
  local movedIntoPlace = false
  for _, mv in ipairs(log.move) do
    if mv.from == "/disk/eh2_devbind.tbl.tmp" and mv.to == "/disk/eh2_devbind.tbl" then movedIntoPlace = true end
  end
  t.truthy(movedIntoPlace, "moved the tmp file to the final diskPath")
end)

t.test("_export: overwriting an existing disk file deletes the old one before moving the new one in", function()
  local files, deps, log = fakeFsDeps({
    ["/disk/eh2_devbind.tbl"] = "OLD-BODY",
  })
  deps.fcsGet = function(kind) return kind == "devbind" and "NEW-BODY" or nil end
  M._export("disk", deps)
  t.eq(files["/disk/eh2_devbind.tbl"], "NEW-BODY")
  t.eq(files["/eh2_devbind.tbl"], nil, "no UI-local FCS file created")
  local deletedOld = false
  for _, p in ipairs(log.delete) do if p == "/disk/eh2_devbind.tbl" then deletedOld = true end end
  t.truthy(deletedOld, "old disk file deleted before the atomic move")
end)

t.test("_export: with mount=nil, exports nothing (no disk to export to)", function()
  local files, deps = fakeFsDeps({ ["/eh2_devbind.tbl"] = "X" })
  local exported = M._export(nil, deps)
  t.eq(#exported, 0)
end)

t.test("_import: FCS kinds call fcsSet from disk and never write UI-local FCS paths", function()
  local files, deps, log = fakeFsDeps({
    ["/disk/eh2_senscal.tbl"] = "BODY-SENSCAL",
    ["/disk/eh2_tuning.tbl"]  = "BODY-TUNING",
    ["/disk/eh2_ui_config.tbl"] = "BODY-UI",
    -- devbind deliberately absent on disk
  })
  local sets = {}
  deps.fcsSet = function(kind, body) sets[kind] = body; return true end

  local imported = M._import("disk", deps)

  t.eq(#imported, 3)
  t.eq(imported[1], "senscal"); t.eq(imported[2], "tuning"); t.eq(imported[3], "uicfg")
  t.eq(sets.senscal, "BODY-SENSCAL")
  t.eq(sets.tuning, "BODY-TUNING")
  t.eq(files["/eh2_senscal.tbl"], nil, "no UI-local FCS file created")
  t.eq(files["/eh2_tuning.tbl"], nil, "no UI-local FCS file created")
  t.eq(files["/eh2_ui_config.tbl"], "BODY-UI")

  local wroteTmp = false
  for _, p in ipairs(log.write) do
    if p == "/eh2_ui_config.tbl.tmp" then wroteTmp = true end
  end
  t.truthy(wroteTmp, "uicfg import still writes to a .tmp path before moving")
  local movedIntoPlace = false
  for _, mv in ipairs(log.move) do
    if mv.from == "/eh2_ui_config.tbl.tmp" and mv.to == "/eh2_ui_config.tbl" then movedIntoPlace = true end
  end
  t.truthy(movedIntoPlace, "moved the tmp file to the final uicfg localPath")
end)

t.test("_import: with mount=nil, imports nothing", function()
  local files, deps = fakeFsDeps({})
  local imported = M._import(nil, deps)
  t.eq(#imported, 0)
end)

-- ===== path-layout assertion: byte-for-byte match to loaderui.diskSource =====

t.test("diskPath layout matches what fcs/boot/loaderui.lua's diskSource reads", function()
  -- loaderui.diskSource: realRead("/" .. mount .. "/" .. cfgspec.FILES[kind]) -- only the 3 FCS
  -- kinds are ever read by the boot loader; "uicfg" has no cfgspec.FILES entry (it's FCS-opaque).
  local mount = "disk"
  for _, kind in ipairs({ "devbind", "senscal", "tuning" }) do
    local loaderuiPath = "/" .. mount .. "/" .. cfgspec.FILES[kind]
    t.eq(M.diskPath(mount, kind), loaderuiPath)
  end
end)

-- ===== M._fmtRow: display-only status line, MUST fit a real ~14-col monitor =====

t.test("_fmtRow: at width=14 (a real monitor's ~14 cols), every row is <= 14 chars", function()
  local plan = M.plan({
    localHas = { devbind = true, senscal = true, tuning = true },
    diskHas  = { devbind = true, senscal = true, tuning = true },
  })
  for _, row in ipairs(plan) do
    local s = M._fmtRow(row, 14)
    t.truthy(#s <= 14, row.kind .. ": " .. s .. " (" .. #s .. " chars) must be <= 14")
  end
end)

t.test("_fmtRow: kind name truncates (tail-preserving ~) rather than overflow the suffix", function()
  local row = { kind = "devbind", hasLocal = true, hasDisk = false } -- longest kind name, 7 chars
  local s = M._fmtRow(row, 14)
  t.eq(#s, 14)
  t.truthy(s:find("L:OK", 1, true) ~= nil, "local:OK status still present: " .. s)
  t.truthy(s:find("D:%-%-") ~= nil, "disk:-- status still present: " .. s)
end)

t.test("_fmtRow: underlying present/plan data is unaffected -- display-only", function()
  local row = { kind = "tuning", hasLocal = true, hasDisk = false }
  M._fmtRow(row, 14)
  t.eq(row.hasLocal, true)
  t.eq(row.hasDisk, false)
end)

t.test("_fmtRow: wide width (no real truncation) still reads 'kind  L:.. D:..'", function()
  local row = { kind = "tuning", hasLocal = true, hasDisk = true }
  t.eq(M._fmtRow(row, 40), "tuning  L:OK D:OK")
end)

t.test("_fmtRow: nil/<=0 width is unbounded (matches fitLabel's own contract), never errors", function()
  local row = { kind = "senscal", hasLocal = false, hasDisk = true }
  t.eq(M._fmtRow(row, nil), "senscal  L:-- D:OK")
  t.eq(M._fmtRow(row, 0), "senscal  L:-- D:OK")
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals/disk =====

t.test("M.build (no disk): 'top' screen constructs; disk summary is 'no disk'; EXPORT/IMPORT "
  .. "disabled, REFRESH enabled; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local deps = {
    find = function(kind) return nil end,
    exists = function(p) return false end,
    read = function(p) return nil end,
    write = function(p, b) end,
    delete = function(p) end,
    move = function(f, t) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  t.eq(h.id, "dtc")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.headerLabel ~= nil, "headerLabel present")

  local region = h.elements.region
  t.truthy(region ~= nil, "region exposed")
  t.eq(region:top(), "top", "region starts at the top screen")

  local rec = region.built.top
  t.truthy(rec ~= nil, "top screen built eagerly by M.build")
  local els = rec.handle.elements
  t.truthy(els.diskLabel ~= nil, "diskLabel present")

  -- Restyle: EXPORT/IMPORT/IMPORT ALL/SCAN/REFRESH are individual bracketSwitches (blue/orange), not
  -- one actionRow. Their disabled look is a "disabled" STATE (gray), not setEnabled(false).
  t.truthy(els.exportBtn ~= nil and els.importBtn ~= nil, "EXPORT + IMPORT bracket buttons present")
  t.truthy(els.refreshBtn ~= nil and els.scanBtn ~= nil, "REFRESH + SCAN bracket buttons present")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "backRow (<) present")

  -- No disk detected -> EXPORT/IMPORT/SCAN start in the "disabled" state; REFRESH stays "off".
  t.eq(els.exportBtn.state, "disabled", "EXPORT disabled: no disk")
  t.eq(els.importBtn.state, "disabled", "IMPORT disabled: no disk")
  t.eq(els.refreshBtn.state, "off", "REFRESH always available")

  t.truthy(els.diskLabel:getText():find("NO DISK", 1, true), "disk summary reads NO DISK")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("M.build (stub disk present): disk summary shows label + valid count; EXPORT/IMPORT enabled",
function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = { ["/eh2_devbind.tbl"] = "BODY1" }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements

  -- Disk present -> the summary reads DISK FOUND (a status line, not a valid-count string anymore).
  t.truthy(els.diskLabel:getText():find("DISK FOUND", 1, true), "disk summary reads DISK FOUND")

  -- Disk present -> EXPORT/IMPORT leave the disabled state (their "off" resting state).
  t.eq(els.exportBtn.state, "off", "EXPORT enabled: disk present")
  t.eq(els.importBtn.state, "off", "IMPORT enabled: disk present")

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("top screen: EXPORT/IMPORT/SCAN/IMPORT ALL/REFRESH bracket buttons + BACK row", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local deps = { find = function() return nil end, exists = function() return false end }
  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements
  t.eq(els.exportBtn.button:getText(), "EXPORT")
  t.eq(els.importBtn.button:getText(), "IMPORT")
  t.truthy(els.refreshBtn ~= nil, "REFRESH bracket button present")
  t.truthy(els.scanBtn ~= nil and els.importAllBtn ~= nil, "SCAN + IMPORT ALL bracket buttons present")
  t.truthy(els.backRow ~= nil and #els.backRow.buttons == 1, "BACK its own row")
  t.eq(els.backRow.buttons[1].button:getText(), "\27", "BACK is CC-native left arrow")
  -- no disk -> EXPORT/IMPORT disabled state, REFRESH available
  t.eq(els.exportBtn.state, "disabled", "EXPORT disabled: no disk")
  t.eq(els.importBtn.state, "disabled", "IMPORT disabled: no disk")
  t.eq(els.refreshBtn.state, "off", "REFRESH always available")
end)

t.test("M.build: top screen's BACK pops the FRAME nav stack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  nav:push("dtc")
  t.eq(nav:top(), "dtc")

  local deps = { find = function() return nil end, exists = function() return false end }
  local h = M.build(basalt, frame, nil, nav, deps)
  local els = h.elements.region.built.top.handle.elements
  t.truthy(els.backRow ~= nil, "backRow present")
  t.truthy(els.backRow.buttons[1].button ~= nil, "back button present")

  -- Directly invoke nav:pop() the same way the "<" button's onClick does (a real click needs
  -- basalt.run(), forbidden here).
  nav:pop()
  t.eq(nav:top(), "bitconfig")
end)

t.test("M.build: EXPORT drilldown -- devbind row enabled (local present), CONFIRM runs "
  .. "M._exportKind, pops back, and leaves a status line", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = {}
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
    fcsGet = function(kind) return kind == "devbind" and "BODY1" or nil end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region

  region:push("export")
  h.apply({})
  t.eq(region:top(), "export")

  local listEls = region.built.export.handle.elements
  t.eq(#listEls.kindRows, 4, "one row per M.KINDS kind")
  -- devbind is KINDS[1] and fcsGet returns a body -> row 1 enabled; senscal/tuning/uicfg absent.
  t.eq(listEls.kindRows[1].buttons[1].state, "off", "devbind export row enabled")
  t.eq(listEls.kindRows[2].buttons[1].state, "disabled", "senscal export row disabled")

  -- Drill into the confirm screen the same way the enabled row's onClick does.
  region:push("confirm_export_devbind")
  h.apply({})
  t.eq(region:top(), "confirm_export_devbind")

  local confirmEls = region.built.confirm_export_devbind.handle.elements
  t.truthy(confirmEls.questionLabel:getText():find(M.FILE.devbind, 1, true),
    "confirm question names the devbind filename")
  t.truthy(confirmEls.confirmRow ~= nil and #confirmEls.confirmRow.buttons == 1, "CONFIRM present")
  t.truthy(confirmEls.backRow ~= nil and #confirmEls.backRow.buttons == 1, "'<' cancel present")

  -- Fire CONFIRM's registered click directly (mirrors test_bitconfig_senssource.lua's established
  -- btn:fireEvent("mouse_click", 1, 1, 1) pattern -- a real click needs basalt.run()).
  confirmEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})

  t.eq(region:top(), "export", "CONFIRM pops back to the export list")
  t.truthy(files["/disk/eh2_devbind.tbl"] ~= nil, "CONFIRM wrote the disk copy via M._exportKind")
  t.truthy(listEls.statusLabel:getText():find("OK", 1, true), "status line shows the export result")
end)

-- ===== Task 9: registry (M.KINDS/M.FILE/M.LABEL) + M.validateKind =====

t.test("registry carries 4 kinds incl uicfg; filenames match cfgspec for FCS kinds", function()
  local cfgspec = require("fcs.io.cfgspec")
  t.eq(#M.KINDS, 4)
  t.eq(M.FILE.devbind, cfgspec.FILES.devbind)
  t.eq(M.FILE.uicfg, "eh2_ui_config.tbl")
end)
t.test("validateKind uses cfgspec for FCS kinds and table-shape for uicfg", function()
  t.eq(M.validateKind("uicfg", {}), true)
  t.eq(M.validateKind("uicfg", nil), false)
  t.eq(M.validateKind("devbind", { thrusters = {}, sensors = {} }), true)
  t.eq(M.validateKind("devbind", { thrusters = {} }), false)  -- missing sensors
end)

-- ===== Task 11: per-kind IO (_scanKind/_exportKind/_importKind) + backup-before-import =====

t.test("_importKind backs up the local file before overwriting it", function()
  local store = { ["/disk/eh2_ui_config.tbl"] = "NEW", ["/eh2_ui_config.tbl"] = "OLD" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,   -- atomic write shim
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  local ok = M._importKind("disk", "uicfg", deps)
  t.eq(ok, true)
  t.eq(store["/eh2_ui_config.tbl"], "NEW", "local overwritten from disk")
  t.eq(backedUp[1], "/eh2_ui_config.tbl", "local backed up before overwrite")
end)

t.test("_importKind: local file absent -> no backup call, still imports", function()
  local store = { ["/disk/eh2_ui_config.tbl"] = "NEW" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  local ok = M._importKind("disk", "uicfg", deps)
  t.eq(ok, true)
  t.eq(#backedUp, 0, "no local file existed, so no backup call")
  t.eq(store["/eh2_ui_config.tbl"], "NEW")
end)

t.test("_importKind FCS kind calls fcsSet and never writes UI-local FCS paths", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "NEW", ["/eh2_tuning.tbl"] = "OLD" }
  local sets, backedUp = {}, {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
    fcsSet = function(kind, body) sets[kind] = body; return true end,
  }
  t.eq(M._importKind("disk", "tuning", deps), true)
  t.eq(sets.tuning, "NEW")
  t.eq(store["/eh2_tuning.tbl"], "OLD", "UI-local FCS file not overwritten")
  t.eq(#backedUp, 0, "no backup of UI-local FCS file")
end)

t.test("_importKind: disk file absent -> false, no backup, no copy", function()
  local store = { ["/eh2_tuning.tbl"] = "OLD" }
  local backedUp = {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read = function(p) return store[p] end,
    write = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move = function(a,b) store[b] = store[a]; store[a] = nil end,
    backup = function(p) backedUp[#backedUp+1] = p end,
  }
  t.eq(M._importKind("disk", "tuning", deps), false)
  t.eq(#backedUp, 0)
  t.eq(store["/eh2_tuning.tbl"], "OLD", "local untouched")
end)

t.test("_importKind: mount=nil -> false, no-op", function()
  local deps = { exists = function() return true end, read = function() return "X" end }
  t.eq(M._importKind(nil, "tuning", deps), false)
end)

-- ===== Task B5: M._importAll(mount, deps) -- one-shot import of all valid disk kinds =====

t.test("_importAll: imports only valid disk kinds via fcsSet, skips the rest, never writes UI-local FCS", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })   -- valid tuning
  local store = {
    ["/disk/eh2_tuning.tbl"]  = good,
    ["/disk/eh2_senscal.tbl"] = "corrupt {{{",   -- present but invalid
    ["/eh2_tuning.tbl"]       = "OLD-TUNING",
  }
  local sets, backedUp = {}, {}
  local deps = {
    exists = function(p) return store[p] ~= nil end,
    read   = function(p) return store[p] end,
    write  = function(p, b) store[p] = b end,
    delete = function(p) store[p] = nil end,
    move   = function(a, b) store[b] = store[a]; store[a] = nil end,
    attributes = function(p) return store[p] and { modified = 1 } or nil end,
    backup = function(p) backedUp[#backedUp + 1] = p end,
    fcsSet = function(kind, body) sets[kind] = body; return true end,
  }
  local r = M._importAll("disk", deps)
  t.eq(#r.imported, 1); t.eq(r.imported[1], "tuning")
  t.eq(sets.tuning, good)
  t.eq(store["/eh2_tuning.tbl"], "OLD-TUNING", "UI-local FCS file not overwritten")
  t.eq(#backedUp, 0, "no backup of UI-local FCS file")
  -- senscal present-but-invalid, devbind/uicfg absent -> all skipped
  local skippedSet = {}; for _, k in ipairs(r.skipped) do skippedSet[k] = true end
  t.truthy(skippedSet.senscal, "invalid senscal skipped")
  t.truthy(skippedSet.devbind and skippedSet.uicfg, "absent kinds skipped")
end)

t.test("_importAll: mount=nil -> nothing imported, nothing skipped-with-error", function()
  local r = M._importAll(nil, { exists = function() return true end })
  t.eq(#r.imported, 0)
end)

-- ===== Task B6: IMPORT ALL button + confirm_importall screen =====

t.test("M.build: IMPORT ALL button present; enabled only with a valid importable kind; "
  .. "CONFIRM imports all valid kinds and pops", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local files = { ["/disk/eh2_tuning.tbl"] = good }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local sets = {}
  local deps = {
    find = function(k) return k == "drive" and fakeDrive or nil end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
    fcsSet = function(kind, body) sets[kind] = body; return true end,
  }
  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region
  local top = region.built.top.handle.elements
  t.truthy(top.importAllBtn ~= nil, "IMPORT ALL present")
  t.eq(top.importAllBtn.state, "off", "enabled: one valid disk kind exists")

  region:push("confirm_importall"); h.apply({})
  local cEls = region.built.confirm_importall.handle.elements
  cEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})
  t.eq(region:top(), "top", "CONFIRM pops back to top")
  t.eq(sets.tuning, good, "IMPORT ALL shipped valid tuning via fcsSet")
  t.eq(files["/eh2_tuning.tbl"], nil, "IMPORT ALL must not write UI-local FCS files")
end)

t.test("_exportKind writes fcsGet body to disk, not a UI-local FCS file", function()
  local store = {}
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    write=function(p,b) store[p]=b end, delete=function(p) store[p]=nil end, move=function(a,b) store[b]=store[a]; store[a]=nil end,
    fcsGet=function(kind) return kind == "tuning" and "L" or nil end }
  t.eq(M._exportKind("disk", "tuning", deps), true)
  t.eq(store["/disk/eh2_tuning.tbl"], "L")
  t.eq(store["/eh2_tuning.tbl"], nil)
end)

t.test("_exportKind: local file absent -> false, no copy", function()
  local store = {}
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    write=function(p,b) store[p]=b end, delete=function(p) store[p]=nil end, move=function(a,b) store[b]=store[a]; store[a]=nil end }
  t.eq(M._exportKind("disk", "tuning", deps), false)
end)

t.test("_exportKind: mount=nil -> false, no-op", function()
  local deps = { exists = function() return true end, read = function() return "X" end }
  t.eq(M._exportKind(nil, "tuning", deps), false)
end)

t.test("_scanKind reports presence, mtime and disk validity", function()
  local store = { ["/eh2_tuning.tbl"] = textutils.serialise({ gains={}, caps={}, feel={} }) }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 5 } or nil end }
  local s = M._scanKind(nil, "tuning", deps)
  t.eq(s.localHas, true); t.eq(s.localMs, 5); t.eq(s.diskHas, false)
end)

t.test("_scanKind: disk file present and valid -> diskHas true, diskValid true, diskMs surfaced", function()
  local store = {
    ["/disk/eh2_tuning.tbl"] = textutils.serialise({ gains={}, caps={}, feel={} }),
  }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 9 } or nil end }
  local s = M._scanKind("disk", "tuning", deps)
  t.eq(s.localHas, false); t.eq(s.localMs, nil)
  t.eq(s.diskHas, true); t.eq(s.diskMs, 9)
  t.eq(s.diskValid, true)
end)

t.test("_scanKind: disk file present but invalid/corrupt -> diskValid false", function()
  local store = { ["/disk/eh2_tuning.tbl"] = "not valid lua {{{" }
  local deps = { exists=function(p) return store[p]~=nil end, read=function(p) return store[p] end,
    attributes=function(p) return store[p] and { modified = 9 } or nil end }
  local s = M._scanKind("disk", "tuning", deps)
  t.eq(s.diskHas, true)
  t.eq(s.diskValid, false)
end)

t.test("_scanKind: honors resolveDeps real defaults when deps omit fields (no crash)", function()
  -- exists/read/attributes provided; write/delete/move/find/backup fall back to real fs/peripheral
  -- defaults but are never invoked by _scanKind, so this must not error.
  local ok, err = pcall(M._scanKind, nil, "tuning", { exists = function() return false end })
  t.truthy(ok, "should not error: " .. tostring(err))
end)

-- ===== Task 10: fmtTime + row =====

t.test("fmtTime formats ms epoch and handles nil", function()
  t.eq(M.fmtTime(nil), "--")
  t.truthy(#M.fmtTime(1000000000000) >= 10, "formatted")
end)
t.test("row computes the local-vs-disk relation", function()
  t.eq(M.row("tuning", { localHas=true, localMs=200, diskHas=true, diskMs=100, diskValid=true }).rel, "newer")
  t.eq(M.row("tuning", { localHas=true, localMs=100, diskHas=true, diskMs=200, diskValid=true }).rel, "older")
  t.eq(M.row("tuning", { localHas=true, diskHas=false }).rel, "local-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=true, diskValid=true }).rel, "disk-only")
  t.eq(M.row("tuning", { localHas=false, diskHas=false }).rel, "none")
end)

-- ===== Task 12: M._confirmText (pure per-row confirm question seam) =====

t.test("_confirmText names the direction and file", function()
  local e = M._confirmText("export", "tuning")
  t.truthy(e:find("disk", 1, true), "export mentions disk")
  local i = M._confirmText("import", "tuning")
  t.truthy(i:find("UI", 1, true) or i:find("local", 1, true), "import mentions local/UI")
end)

t.test("_confirmText uses M.FILE (never a hardcoded filename) and covers all four kinds", function()
  for _, kind in ipairs(M.KINDS) do
    t.truthy(M._confirmText("export", kind):find(M.FILE[kind], 1, true), "export text names " .. M.FILE[kind])
    t.truthy(M._confirmText("import", kind):find(M.FILE[kind], 1, true), "import text names " .. M.FILE[kind])
  end
end)

-- ===== Task C1: M._scanDisk(mount, deps) -- pure classify (valid/invalid/foreign), no UI (SCAN =====
-- ===== button itself is Task C3). =====

local function scanDeps(mount, byName)
  -- byName: { ["eh2_tuning.tbl"] = "<body>", ["foo.txt"] = "x", ... }
  local files = {}
  for name, body in pairs(byName) do files["/" .. mount .. "/" .. name] = body end
  local names = {}; for name in pairs(byName) do names[#names + 1] = name end
  return {
    list   = function(p) return (p == mount or p == "/" .. mount) and names or {} end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
  }
end

t.test("_scanDisk: classifies valid EH2 config, invalid EH2 file, and foreign file", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })  -- valid tuning
  local deps = scanDeps("disk", {
    ["eh2_tuning.tbl"]  = good,           -- valid
    ["eh2_senscal.tbl"] = "corrupt {{{",  -- EH2-named but invalid
    ["notes.txt"]       = "hello",        -- foreign
  })
  local s = M._scanDisk("disk", deps)
  t.eq(#s.valid, 1); t.eq(s.valid[1], "tuning")
  t.eq(#s.invalid, 1); t.truthy(s.invalid[1]:find("eh2_senscal.tbl", 1, true), s.invalid[1])
  t.eq(#s.foreign, 1); t.truthy(s.foreign[1]:find("notes.txt", 1, true), s.foreign[1])
end)

t.test("_scanDisk: mount=nil -> everything empty", function()
  local s = M._scanDisk(nil, { list = function() return { "x" } end })
  t.eq(#s.valid, 0); t.eq(#s.invalid, 0); t.eq(#s.foreign, 0)
end)

-- ===== Task C2: M._cleanDisk(mount, deps) + M._scanSummary(scan) -- pure delete-junk / display =====
-- ===== summary, no UI (SCAN/CLEAN buttons themselves are Task C3). =====

t.test("_cleanDisk: deletes only foreign+invalid, keeps valid EH2 configs", function()
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local byName = { ["eh2_tuning.tbl"] = good, ["eh2_senscal.tbl"] = "bad {{{", ["notes.txt"] = "x" }
  local files = {}
  for name, body in pairs(byName) do files["/disk/" .. name] = body end
  local names = {}; for name in pairs(byName) do names[#names + 1] = name end
  local deps = {
    list   = function(p) return (p == "disk") and names or {} end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    delete = function(p) files[p] = nil end,
  }
  local r = M._cleanDisk("disk", deps)
  t.eq(#r.deleted, 2, "two junk files deleted")
  t.truthy(files["/disk/eh2_tuning.tbl"] ~= nil, "valid config kept")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "invalid EH2 file deleted")
  t.eq(files["/disk/notes.txt"], nil, "foreign file deleted")
end)

t.test("_cleanDisk: mount=nil -> nothing deleted", function()
  t.eq(#M._cleanDisk(nil, { list = function() return {} end }).deleted, 0)
end)

t.test("_scanSummary: counts and flags clean-advised when only junk present", function()
  t.eq(M._scanSummary({ valid = { "tuning" }, foreign = {}, invalid = {} }), "valid 1 . foreign 0 . invalid 0")
  local s = M._scanSummary({ valid = {}, foreign = { "/disk/x" }, invalid = { "/disk/eh2_senscal.tbl" } })
  t.truthy(s:find("CLEAN ADVISED", 1, true), "clean advised when no valid config but junk present: " .. s)
end)

-- ===== Task C3: SCAN + CLEAN UI (buttons + screens) =====

t.test("M.build: SCAN screen summarizes disk; CLEAN confirm deletes only junk and pops", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")
  local good = textutils.serialise({ gains = {}, caps = {}, feel = {} })
  local files = {
    ["/disk/eh2_tuning.tbl"] = good, ["/disk/junk.dat"] = "x", ["/disk/eh2_senscal.tbl"] = "bad {{{",
  }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find = function(k) return k == "drive" and fakeDrive or nil end,
    list = function(p) return (p == "disk") and { "eh2_tuning.tbl", "junk.dat", "eh2_senscal.tbl" } or {} end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }
  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region
  local top = region.built.top.handle.elements
  t.truthy(top.scanBtn ~= nil, "SCAN button present")

  region:push("scan"); h.apply({})
  local sEls = region.built.scan.handle.elements
  t.truthy(sEls.summaryLabel:getText():find("valid 1", 1, true), "scan summary reads valid 1: " .. sEls.summaryLabel:getText())

  region:push("confirm_clean"); h.apply({})
  local cEls = region.built.confirm_clean.handle.elements
  cEls.confirmRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.apply({})
  t.truthy(files["/disk/eh2_tuning.tbl"] ~= nil, "valid config kept after CLEAN")
  t.eq(files["/disk/junk.dat"], nil, "foreign deleted")
  t.eq(files["/disk/eh2_senscal.tbl"], nil, "invalid deleted")
end)

-- ===== Task 12: construction probe -- generic "no error" smoke test (works against any M.build =====
-- ===== shape, old or new; the point of this probe is just to prove build/apply/render never error). =====

t.test("T12 M.build: constructs headless with injected in-memory deps, apply+render do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  local files = {}
  local deps = {
    find = function(kind) return nil end,
    exists = function(p) return files[p] ~= nil end,
    read = function(p) return files[p] end,
    write = function(p, b) files[p] = b end,
    delete = function(p) files[p] = nil end,
    move = function(a, b) files[b] = files[a]; files[a] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  t.eq(h.id, "dtc")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")

  local ok, err = pcall(h.apply, {})
  t.truthy(ok, "apply should not error: " .. tostring(err))
  local ok2, err2 = pcall(h.apply, {})
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

-- ===== Regression: export-row gating must not fall through to the disk clause when a kind is =====
-- ===== absent locally but valid on disk (Lua `and/or` precedence bug on the old
-- `(dir=="export") and info.localHas or (info.diskHas and info.diskValid)` line let a
-- disk-valid/local-absent kind's EXPORT row wrongly enable -- CONFIRM would then no-op and
-- show FAILED, since M._exportKind requires a local source). Mirrors the EXPORT-drilldown
-- integration test's navigation (region:push / region.built.<screen>.handle.elements).

t.test("M.build: export row stays DISABLED for a kind that is valid on disk but absent locally "
  .. "(import row for the same kind stays ENABLED)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local nav = Nav.new("bitconfig")

  -- tuning: valid-serialised on disk, no local file at all.
  local files = {
    ["/disk/eh2_tuning.tbl"] = textutils.serialise({ gains = {}, caps = {}, feel = {} }),
  }
  local fakeDrive = {
    isDiskPresent = function() return true end,
    getMountPath  = function() return "disk" end,
    getDiskLabel  = function() return "CART1" end,
  }
  local deps = {
    find   = function(kind) if kind == "drive" then return fakeDrive end return nil end,
    exists = function(p) return files[p] ~= nil end,
    read   = function(p) return files[p] end,
    write  = function(p, body) files[p] = body end,
    delete = function(p) files[p] = nil end,
    move   = function(from, to) files[to] = files[from]; files[from] = nil end,
    attributes = function(p) return files[p] and { modified = 1 } or nil end,
    backup = function(p) end,
  }

  local h = M.build(basalt, frame, nil, nav, deps)
  local region = h.elements.region

  region:push("export")
  h.apply({})
  t.eq(region:top(), "export")

  local exportEls = region.built.export.handle.elements
  -- tuning is KINDS[3]: diskValid true, localHas false -> export row MUST be disabled.
  t.eq(exportEls.kindRows[3].buttons[1].state, "disabled",
    "tuning export row disabled: valid on disk but absent locally")

  region:pop()
  region:push("import")
  h.apply({})
  t.eq(region:top(), "import")

  local importEls = region.built.import.handle.elements
  -- Same kind's IMPORT row must stay enabled (diskHas and diskValid) -- pins the fix didn't
  -- regress the already-correct import branch.
  t.eq(importEls.kindRows[3].buttons[1].button:getEnabled(), true,
    "tuning import row enabled: valid on disk")
end)

-- ===== S3 Task 2 fix: unscoped FCS I/O without seams must skip, not recreate UI-local files =====

t.test("unscoped export/import skips FCS kinds when fcsGet/fcsSet absent (no UI-local FCS files)", function()
  local files, deps = fakeFsDeps({
    ["/eh2_tuning.tbl"] = "LOCAL",
    ["/disk/eh2_tuning.tbl"] = "DISK",
    ["/eh2_ui_config.tbl"] = "UI-LOCAL",
  })
  local imported = M._import("disk", deps)
  t.eq(#imported, 0)
  t.eq(files["/eh2_tuning.tbl"], "LOCAL", "unscoped import must not overwrite UI-local FCS files")
  local exported = M._export("disk", deps)
  t.eq(#exported, 1)
  t.eq(exported[1], "uicfg")
  t.eq(files["/disk/eh2_tuning.tbl"], "DISK", "unscoped export must not copy UI-local FCS files to disk")
  t.eq(files["/disk/eh2_ui_config.tbl"], "UI-LOCAL")
  t.eq(M._exportKind("disk", "tuning", deps), false)
  t.eq(M._importKind("disk", "tuning", deps), false)
  t.eq(files["/eh2_tuning.tbl"], "LOCAL")
end)

-- ===== S3 Task 2: role-scoped DTC transfers (FCS live / NAV no-op on UI) =====

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

return true
