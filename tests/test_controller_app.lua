-- tests/test_controller_app.lua
-- Controller Basalt app (controller/app.lua): pure formatting/intent-seam tests (no Basalt, no
-- peripherals), then a real-CraftOS-PC Basalt construction probe for the ROSTER page -- build the
-- element tree on a frame bound to term.current(), apply() a mock roster view spanning
-- LIVE/SILENT/DISABLED/OFFLINE, one basalt.update(...) render pass, and assert OBSERVABLE state
-- (Image getText/getFg, Label getText) -- never a geometry getter on an unrendered element (see
-- feedback-basalt-headless-test-gotchas.md). NEVER basalt.run() (blocks on pullEventRaw).
local t = require("tests.framework")
local M = require("controller.app")
local BasaltApp = require("ui.basalt.app")

-- ===== pure formatting helpers =====

t.test("formatPos: nil -> '--'; rounds to whole blocks, handles negatives", function()
  t.eq(M.formatPos(nil), "--")
  t.eq(M.formatPos({ x = 1, y = 2, z = 3 }), "1 2 3")
  t.eq(M.formatPos({ x = -7737.4, y = -54.6, z = 7579.5 }), "-7737 -55 7580")
end)

t.test("formatAge: nil -> '--'; ms/s/m/h bands", function()
  t.eq(M.formatAge(nil), "--")
  t.eq(M.formatAge(820), "820ms")
  t.eq(M.formatAge(3400), "3.4s")
  t.eq(M.formatAge(125000), "2m")
  t.eq(M.formatAge(7200000), "2.0h")
end)

t.test("fitField: pads short text, truncates long text, to exactly `width` columns", function()
  t.eq(M.fitField("LIVE", 9), "LIVE     ")
  t.eq(#M.fitField("LIVE", 9), 9)
  t.eq(M.fitField("DISABLEDXX", 8), "DISABLED")
  t.eq(#M.fitField("DISABLEDXX", 8), 8)
end)

t.test("rowLine: name falls back to id; marker reflects selection; statusAt/len locate the status field", function()
  local line, statusAt, statusLen, statusWord = M.rowLine({ id = "beacon-68", status = "SILENT" }, false)
  t.eq(line:sub(1, 2), "  ", "unselected -> no marker")
  t.eq(line:sub(3, 3 + #"beacon-68" - 1), "beacon-68", "name falls back to id")
  t.eq(statusWord, "SILENT")
  t.eq(line:sub(statusAt, statusAt + statusLen - 1), M.fitField("SILENT", M.STATUS_W))

  local line2 = M.rowLine({ id = "B1", name = "Buddy's Base", status = "LIVE" }, true)
  t.eq(line2:sub(1, 2), "> ", "selected -> marker")
  t.eq(line2:sub(3, 3 + #"Buddy's Base" - 1), "Buddy's Base", "friendly name preferred over id")
end)

t.test("headerText: counts LIVE vs total known", function()
  local items = {
    { id = "A", status = "LIVE" }, { id = "B", status = "LIVE" },
    { id = "C", status = "SILENT" }, { id = "D", status = "OFFLINE" },
  }
  t.eq(M.headerText(items), "EH2 BEACON CONTROL   2 live / 4 known")
  t.eq(M.headerText({}), "EH2 BEACON CONTROL   0 live / 0 known")
end)

-- ===== M._onEnableAll: the TESTABLE intent seam. No Basalt here. =====

local function fakeRuntime()
  local calls, reinstallAllCalls = {}, {}
  return {
    calls = calls,
    reinstallAllCalls = reinstallAllCalls,
    sendCommandAll = function(self, op, args, now)
      calls[#calls + 1] = { op = op, args = args, now = now }
      return true
    end,
    sendReinstallAll = function(self, now)
      reinstallAllCalls[#reinstallAllCalls + 1] = now
      return true
    end,
  }, calls
end

t.test("_onEnableAll: sends a broadcast 'enable' command with no args", function()
  local rt, calls = fakeRuntime()
  local ok = M._onEnableAll(rt, 1234)
  t.truthy(ok)
  t.eq(#calls, 1)
  t.eq(calls[1].op, "enable")
  t.eq(calls[1].args, nil)
  t.eq(calls[1].now, 1234)
end)

-- ===== P6: M._onUpdateAll -- the TESTABLE intent seam for the UPDATE ALL footer button =====

t.test("_onUpdateAll: sends a broadcast reinstall via runtime:sendReinstallAll", function()
  local rt = fakeRuntime()
  local ok = M._onUpdateAll(rt, 1234)
  t.truthy(ok)
  t.eq(#rt.reinstallAllCalls, 1)
  t.eq(rt.reinstallAllCalls[1], 1234)
end)

-- ===== Construction probe: real CraftOS-PC Basalt, no real peripherals =====

local MOCK_VIEW = {
  { id = "beacon-67", name = "North Pillar", status = "LIVE",     pos = { x = -7737, y = -54, z = 7579 }, ageMs = 600 },
  { id = "beacon-68", name = "Buddy's Base", status = "SILENT",   pos = { x = 6462,  y = 200, z = 6107 }, ageMs = 180000 },
  { id = "beacon-69", name = nil,            status = "DISABLED", pos = { x = 7144,  y = 65,  z = -7266 }, ageMs = 900 },
  { id = "beacon-70", name = "South Mark",   status = "OFFLINE",  pos = nil, ageMs = nil },
}

t.test("M.build constructs the element tree; apply() + one render pass do not error", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()   -- binds to term.current(), per ui/basalt/app.lua's header

  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  t.eq(h.id, "roster")
  t.truthy(type(h.apply) == "function", "apply should be a function")
  t.truthy(h.elements ~= nil, "elements table should be exposed")
  t.truthy(h.elements.listImg ~= nil, "listImg element present")
  t.truthy(#h.elements.hits > 0, "row hit-catchers present")
  t.truthy(h.elements.scrollRow ~= nil, "scrollRow present")
  t.truthy(h.elements.actionRow ~= nil, "actionRow present")

  local ok, err = pcall(h.apply, MOCK_VIEW)
  t.truthy(ok, "apply should not error: " .. tostring(err))

  local ok2, err2 = pcall(h.apply, MOCK_VIEW)
  t.truthy(ok2, "apply should be safe to call repeatedly: " .. tostring(err2))

  local ok3, err3 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok3, "basalt.update should not error: " .. tostring(err3))
end)

t.test("apply() reflects the header count and each row's text/status colour", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  t.eq(h.elements.header:getText(), M.headerText(MOCK_VIEW))

  -- Image pixel coordinates are LOCAL to the image (row 1 = the first visible list row) --
  -- Basalt already offsets by the image's own y (listTop) when drawing it onto the frame.
  local img = h.elements.listImg
  for i, item in ipairs(MOCK_VIEW) do
    local expLine, statusAt, statusLen, statusWord = M.rowLine(item, false)
    t.eq(img:getText(1, i, #expLine), expLine, "row " .. i .. " text matches (unselected)")
    local expColor = colors.toBlit(M.STATUS_COLOR[statusWord])
    t.eq(img:getFg(statusAt, i, statusLen), string.rep(expColor, statusLen), "row " .. i .. " status colour: " .. statusWord)
  end
end)

t.test("selecting a row toggles the '> ' marker and the selected() getter", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  t.eq(h.elements.selected(), nil, "nothing selected initially")
  h.elements.selectRow(1)   -- row 1 -> beacon-67
  t.eq(h.elements.selected(), "beacon-67")
  t.eq(h.elements.listImg:getText(1, 1, 2), "> ", "selected row shows the marker")

  h.elements.selectRow(1)   -- click again -> deselect
  t.eq(h.elements.selected(), nil)
  t.eq(h.elements.listImg:getText(1, 1, 2), "  ", "deselected row shows no marker")
end)

t.test("apply() drops a selection whose beacon vanished from the roster", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  h.elements.selectRow(2)   -- beacon-68
  t.eq(h.elements.selected(), "beacon-68")

  h.apply({ MOCK_VIEW[1], MOCK_VIEW[3], MOCK_VIEW[4] })   -- beacon-68 no longer present
  t.eq(h.elements.selected(), nil, "vanished selection is cleared, not left dangling")
end)

t.test("ENABLE ALL button click sends the broadcast enable command via M._onEnableAll", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local rt, calls = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  -- actionRow's buttons are indexed in spec order: 1=DIAG (disabled), 2=ENABLE ALL, 3=UPDATE ALL.
  -- Click == fire the same "mouse_click" event :onClick(fn) registered a listener under (the
  -- established pattern -- see tests/test_region_emc.lua's header comment on the same point).
  h.elements.actionRow.buttons[2].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#calls, 1, "ENABLE ALL click reached the runtime")
  t.eq(calls[1].op, "enable")
end)

t.test("UPDATE ALL is destructive -- first click arms a confirm; second click (confirm) sends", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()

  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  -- actionRow's buttons are indexed in spec order: 1=DIAG (disabled), 2=ENABLE ALL, 3=UPDATE ALL.
  t.truthy(h.elements.actionRow.buttons[3].state ~= "disabled", "UPDATE ALL is a live button now (P6)")
  h.elements.actionRow.buttons[3].button:fireEvent("mouse_click", 1, 1, 1)   -- arm
  t.eq(#rt.reinstallAllCalls, 0, "first click only arms the confirm -- no send yet")

  h.elements.actionRow.buttons[3].button:fireEvent("mouse_click", 1, 1, 1)   -- confirm
  t.eq(#rt.reinstallAllCalls, 1, "second click confirms the broadcast reinstall")

  h.elements.actionRow.buttons[3].button:fireEvent("mouse_click", 1, 1, 1)   -- re-arms, not a second send
  t.eq(#rt.reinstallAllCalls, 1, "disarmed after confirming -- this click only re-arms")
end)

t.test("UPDATE ALL confirm disarms on leaving the roster (disarmUpdate), so it can't survive a round-trip", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  h.elements.actionRow.buttons[3].button:fireEvent("mouse_click", 1, 1, 1)   -- arm the confirm
  h.disarmUpdate()                                                           -- leaving the roster (DIAG/DETAIL) disarms it
  h.elements.actionRow.buttons[3].button:fireEvent("mouse_click", 1, 1, 1)   -- a later click must only re-ARM, never send
  t.eq(#rt.reinstallAllCalls, 0, "disarmed on leaving the roster -- the next click re-arms, it does not confirm a stale send")
end)

-- ===== DIAG page: pure formatting helpers =====

t.test("formatEnabled: true/false/nil -> ON/OFF/?", function()
  t.eq(M.formatEnabled(true), "ON")
  t.eq(M.formatEnabled(false), "OFF")
  t.eq(M.formatEnabled(nil), "?")
end)

t.test("formatSelfCheck: ok -> OK; not ok -> 'N MISM'; missing -> '--'", function()
  t.eq(M.formatSelfCheck(nil), "--")
  t.eq(M.formatSelfCheck({ selfCheck = { ok = true, mismatches = 0 } }), "OK")
  t.eq(M.formatSelfCheck({ selfCheck = { ok = false, mismatches = 2 } }), "2 MISM")
end)

t.test("formatConstellation: 'H/4 GRADE'; missing -> '--'", function()
  t.eq(M.formatConstellation(nil), "--")
  t.eq(M.formatConstellation({ constellation = { hosts = 3, grade = "GOOD" } }), "3/4 GOOD")
end)

t.test("formatInterval: reuses formatAge's bands; missing -> '--'", function()
  t.eq(M.formatInterval(nil), "--")
  t.eq(M.formatInterval({ intervalMs = 3400 }), M.formatAge(3400))
end)

t.test("diagRowLine: name falls back to id, fields fit their fixed widths, colour spans locate ENABLED/SELFCHK", function()
  local item = {
    id = "beacon-70", name = "South Mark", enabled = true,
    health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 1000 },
    lastReplyAgeMs = 820,
  }
  local line, enAt, enLen, enWord, scAt, scLen, scWord = M.diagRowLine(item)
  t.eq(enWord, "ON")
  t.eq(scWord, "OK")
  t.eq(line:sub(enAt, enAt + enLen - 1), M.fitField("ON", M.DIAG_EN_W))
  t.eq(line:sub(scAt, scAt + scLen - 1), M.fitField("OK", M.DIAG_SC_W))
  t.eq(line:sub(1, #"South Mark"), "South Mark")
  t.truthy(#line <= 51, "row must fit the 51-wide terminal")

  local blank = M.diagRowLine(nil)
  t.eq(blank:sub(1, 1), "?")
end)

t.test("pollingText: active -> 'polling...'; inactive -> ''", function()
  t.eq(M.pollingText(true), "polling...")
  t.eq(M.pollingText(false), "")
end)

-- ===== M.build: opts.onDiag wires the DIAG button live (default stays disabled) =====

t.test("M.build with no opts: DIAG button has no onClick (still a stub)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local h = M.build(basalt, frame, rt)
  -- Clicking a disabled bracketSwitch (no onClick registered) must not error.
  local ok = pcall(function() h.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1) end)
  t.truthy(ok, "clicking the stub DIAG button must not error")
end)

t.test("M.build with opts.onDiag: DIAG button click invokes it", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local fired = 0
  local h = M.build(basalt, frame, rt, { onDiag = function() fired = fired + 1 end })
  h.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(fired, 1)
end)

-- ===== M.buildDiag: construction probe (real CraftOS-PC Basalt, no peripherals) =====

local MOCK_DIAG_VIEW = {
  { id = "beacon-67", name = "North Pillar", enabled = true,
    health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 1000 },
    lastReplyAgeMs = 600 },
  { id = "beacon-68", name = "Buddy's Base", enabled = false,
    health = { selfCheck = { ok = false, mismatches = 2 }, constellation = { hosts = 2, grade = "FAIR" }, intervalMs = 3000 },
    lastReplyAgeMs = 4200 },
  { id = "beacon-69", name = nil, enabled = nil, health = nil, lastReplyAgeMs = nil },
}

t.test("M.buildDiag constructs the element tree; apply() renders the status table + polling indicator", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()

  local h = M.buildDiag(basalt, frame, rt)
  t.eq(h.id, "diag")
  t.truthy(h.elements.listImg ~= nil, "listImg present")
  t.truthy(h.elements.polling ~= nil, "polling indicator label present")
  t.truthy(h.elements.actionRow ~= nil, "BACK action row present")

  h.apply(MOCK_DIAG_VIEW, true)
  basalt.update("timer", -1)

  t.eq(h.elements.colHeader:getText(), M.diagColHeader())
  t.eq(h.elements.polling:getText(), "polling...", "active=true shows the visible polling indicator")

  local img = h.elements.listImg
  for i, item in ipairs(MOCK_DIAG_VIEW) do
    local line, enAt, enLen, enWord, scAt, scLen, scWord = M.diagRowLine(item)
    t.eq(img:getText(1, i, #line), line, "row " .. i .. " text matches")
    t.eq(img:getFg(enAt, i, enLen), string.rep(colors.toBlit(M.EN_COLOR[enWord] or colors.white), enLen), "row " .. i .. " ENABLED colour")
    local scWordColor = (scWord == "OK" and colors.green) or (scWord == "--" and colors.lightGray) or colors.red
    t.eq(img:getFg(scAt, i, scLen), string.rep(colors.toBlit(scWordColor), scLen), "row " .. i .. " SELFCHK colour")
  end
end)

t.test("M.buildDiag apply(view, false): polling indicator clears", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local h = M.buildDiag(basalt, frame, rt)
  h.apply(MOCK_DIAG_VIEW, false)
  basalt.update("timer", -1)
  t.eq(h.elements.polling:getText(), "")
end)

t.test("M.buildDiag BACK button click invokes opts.onBack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local fired = 0
  local h = M.buildDiag(basalt, frame, rt, { onBack = function() fired = fired + 1 end })
  h.apply(MOCK_DIAG_VIEW, true)
  basalt.update("timer", -1)
  h.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(fired, 1)
end)

-- ===== M.buildApp: wires ROSTER + DIAG together; comms-hygiene gate integration =====

local function fakeRuntimeFull()
  local sendCalls, queryCalls = {}, {}
  return {
    sendCalls = sendCalls, queryCalls = queryCalls,
    sendCommandAll = function(self, op, args, now) sendCalls[#sendCalls + 1] = { op = op, now = now }; return true end,
    queryAll = function(self, now) queryCalls[#queryCalls + 1] = now; return true end,
  }
end

t.test("M.buildApp: roster visible + diag hidden + gate hidden at construction", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeFull()
  local h = M.buildApp(basalt, base, rt)
  basalt.update("timer", -1)
  t.eq(h.elements.rosterFrame:getVisible(), true)
  t.eq(h.elements.diagFrame:getVisible(), false)
  t.eq(h.gate:isShown(), false)
end)

t.test("M.buildApp: DIAG button opens the diag page + shows the gate; BACK reverses it", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeFull()
  local h = M.buildApp(basalt, base, rt)
  h.apply(MOCK_DIAG_VIEW)
  basalt.update("timer", -1)

  h.elements.roster.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(h.gate:isShown(), true, "DIAG button shows the poll gate")
  t.eq(h.elements.diagFrame:getVisible(), true)
  t.eq(h.elements.rosterFrame:getVisible(), false)

  h.elements.diag.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(h.gate:isShown(), false, "BACK hides the poll gate")
  t.eq(h.elements.diagFrame:getVisible(), false)
  t.eq(h.elements.rosterFrame:getVisible(), true)
end)

t.test("M.buildApp.poll: comms-hygiene end to end -- NO-OP while roster is shown; polls once DIAG opens; stops again on BACK", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeFull()
  local h = M.buildApp(basalt, base, rt)
  basalt.update("timer", -1)

  h.poll(1000)
  t.eq(#rt.queryCalls, 0, "closed DIAG -- poll() must not transmit")

  h.elements.roster.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.poll(2000)
  t.eq(#rt.queryCalls, 1, "DIAG open -- poll() transmits")

  h.elements.diag.elements.actionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  h.poll(9999)
  t.eq(#rt.queryCalls, 1, "DIAG closed again -- poll() stops transmitting, even though it would be due")
end)

-- ===== DETAIL page: pure formatting helpers =====

t.test("findItem: locates by id; nil id or absent id -> nil", function()
  local view = { { id = "beacon-67", name = "North Pillar" }, { id = "beacon-68" } }
  t.eq(M.findItem(view, "beacon-68").id, "beacon-68")
  t.truthy(M.findItem(view, "nope") == nil)
  t.truthy(M.findItem(view, nil) == nil)
  t.truthy(M.findItem(nil, "beacon-67") == nil)
end)

t.test("detailHeaderLines: name falls back to id, then '?'; id line always shows the raw id", function()
  local name, idLine = M.detailHeaderLines({ name = "Buddy's Base" }, "beacon-68")
  t.eq(name, "Buddy's Base")
  t.eq(idLine, "ID: beacon-68")

  local name2, idLine2 = M.detailHeaderLines({ id = "beacon-69" }, "beacon-69")
  t.eq(name2, "beacon-69", "no name -> falls back to id")
  t.eq(idLine2, "ID: beacon-69")

  local name3, idLine3 = M.detailHeaderLines(nil, nil)
  t.eq(name3, "?")
  t.eq(idLine3, "ID: ?")
end)

t.test("detailLine: label padded to DETAIL_LABEL_W, then a space, then the value", function()
  t.eq(M.detailLine("STATUS", "LIVE"), M.fitField("STATUS", M.DETAIL_LABEL_W) .. " LIVE")
end)

t.test("detailLines: 7 fixed lines, reusing the roster/DIAG formatters; nil item -> all placeholders", function()
  local item = {
    status = "LIVE", enabled = true, pos = { x = 1, y = 2, z = 3 }, expectedPos = { x = 1, y = 2, z = 3 },
    health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 1000 },
  }
  local lines = M.detailLines(item)
  t.eq(#lines, 7)
  t.eq(lines[1], M.detailLine("STATUS", "LIVE"))
  t.eq(lines[2], M.detailLine("ENABLED", "ON"))
  t.eq(lines[3], M.detailLine("POS", "1 2 3"))
  t.eq(lines[4], M.detailLine("EXPECTED", "1 2 3"))
  t.eq(lines[5], M.detailLine("INTERVAL", M.formatAge(1000)))
  t.eq(lines[6], M.detailLine("SELFCHK", "OK"))
  t.eq(lines[7], M.detailLine("CONST", "3/4 GOOD"))

  local blank = M.detailLines(nil)
  t.eq(blank[1], M.detailLine("STATUS", "SILENT"))
  t.eq(blank[2], M.detailLine("ENABLED", "?"))
  t.eq(blank[3], M.detailLine("POS", "--"))
  t.eq(blank[4], M.detailLine("EXPECTED", "--"))
  t.eq(blank[6], M.detailLine("SELFCHK", "--"))
  t.eq(blank[7], M.detailLine("CONST", "--"))
end)

t.test("parseNum: rejects '', '-', non-numeric; accepts integers + negatives", function()
  t.truthy(M.parseNum(nil) == nil)
  t.truthy(M.parseNum("") == nil)
  t.truthy(M.parseNum("-") == nil)
  t.truthy(M.parseNum("abc") == nil)
  t.eq(M.parseNum("128"), 128)
  t.eq(M.parseNum("-64"), -64)
  t.eq(M.parseNum("0"), 0)
end)

-- ===== DETAIL page: per-action TESTABLE intent seams. No Basalt. =====

local function fakeRuntimeDetail()
  local sendCalls, nameCalls, expCalls, removeCalls, reinstallCalls = {}, {}, {}, {}, {}
  return {
    sendCalls = sendCalls, nameCalls = nameCalls, expCalls = expCalls, removeCalls = removeCalls,
    reinstallCalls = reinstallCalls,
    sendCommand = function(self, id, op, args, now)
      sendCalls[#sendCalls + 1] = { id = id, op = op, args = args, now = now }
      return true
    end,
    sendReinstall = function(self, id, now)
      reinstallCalls[#reinstallCalls + 1] = { id = id, now = now }
      return true
    end,
    setName = function(self, id, name) nameCalls[#nameCalls + 1] = { id = id, name = name } end,
    setExpectedPos = function(self, id, pos) expCalls[#expCalls + 1] = { id = id, pos = pos } end,
    remove = function(self, id) removeCalls[#removeCalls + 1] = id end,
  }
end

t.test("_onEnable/_onDisable/_onVerify/_onReboot: direct sendCommand, no args", function()
  local rt = fakeRuntimeDetail()
  M._onEnable(rt, "beacon-68", 100)
  M._onDisable(rt, "beacon-68", 200)
  M._onVerify(rt, "beacon-68", 300)
  M._onReboot(rt, "beacon-68", 400)
  t.eq(#rt.sendCalls, 4)
  t.eq(rt.sendCalls[1].op, "enable"); t.eq(rt.sendCalls[1].args, nil); t.eq(rt.sendCalls[1].now, 100)
  t.eq(rt.sendCalls[2].op, "disable"); t.eq(rt.sendCalls[2].now, 200)
  t.eq(rt.sendCalls[3].op, "verify"); t.eq(rt.sendCalls[3].now, 300)
  t.eq(rt.sendCalls[4].op, "reboot"); t.eq(rt.sendCalls[4].now, 400)
  for _, c in ipairs(rt.sendCalls) do t.eq(c.id, "beacon-68") end
end)

t.test("_onSetPos: sendCommand('setPos', { pos = {x,y,z} }) -- EXACTLY beacon/command.lua's contract", function()
  local rt = fakeRuntimeDetail()
  M._onSetPos(rt, "beacon-68", { x = 10, y = 2, z = -3 }, 500)
  t.eq(#rt.sendCalls, 1)
  t.eq(rt.sendCalls[1].op, "setPos")
  t.eq(rt.sendCalls[1].args.pos.x, 10)
  t.eq(rt.sendCalls[1].args.pos.y, 2)
  t.eq(rt.sendCalls[1].args.pos.z, -3)
  t.eq(rt.sendCalls[1].now, 500)
end)

t.test("_onSetInterval: sendCommand('setInterval', { intervalMs = n }) -- EXACTLY beacon/command.lua's contract", function()
  local rt = fakeRuntimeDetail()
  M._onSetInterval(rt, "beacon-68", 3000, 600)
  t.eq(#rt.sendCalls, 1)
  t.eq(rt.sendCalls[1].op, "setInterval")
  t.eq(rt.sendCalls[1].args.intervalMs, 3000)
  t.eq(rt.sendCalls[1].now, 600)
end)

t.test("_onRename: runtime:setName(id, name), no channel traffic", function()
  local rt = fakeRuntimeDetail()
  M._onRename(rt, "beacon-68", "Buddy's Base")
  t.eq(#rt.sendCalls, 0, "rename is a controller-side annotation, not a beacon command")
  t.eq(#rt.nameCalls, 1)
  t.eq(rt.nameCalls[1].id, "beacon-68")
  t.eq(rt.nameCalls[1].name, "Buddy's Base")
end)

t.test("_onPinExpected: pins lastPos via setExpectedPos", function()
  local rt = fakeRuntimeDetail()
  local ok = M._onPinExpected(rt, "beacon-68", { x = 1, y = 2, z = 3 })
  t.truthy(ok)
  t.eq(#rt.expCalls, 1)
  t.eq(rt.expCalls[1].id, "beacon-68")
  t.eq(rt.expCalls[1].pos.x, 1)
end)

t.test("_onPinExpected: nil lastPos is a no-op (never touches the runtime)", function()
  local rt = fakeRuntimeDetail()
  local ok = M._onPinExpected(rt, "beacon-68", nil)
  t.truthy(not ok)
  t.eq(#rt.expCalls, 0)
end)

-- ===== P6: M._onUpdate -- the TESTABLE intent seam for the DETAIL page's UPDATE button =====

t.test("_onUpdate: sends a targeted reinstall via runtime:sendReinstall", function()
  local rt = fakeRuntimeDetail()
  local ok = M._onUpdate(rt, "beacon-68", 700)
  t.truthy(ok)
  t.eq(#rt.reinstallCalls, 1)
  t.eq(rt.reinstallCalls[1].id, "beacon-68")
  t.eq(rt.reinstallCalls[1].now, 700)
end)

t.test("_onRemove: runtime:remove(id)", function()
  local rt = fakeRuntimeDetail()
  local ok = M._onRemove(rt, "beacon-68")
  t.truthy(ok)
  t.eq(#rt.removeCalls, 1)
  t.eq(rt.removeCalls[1], "beacon-68")
end)

-- ===== M.buildDetail: construction probe (real CraftOS-PC Basalt, no peripherals) =====

local MOCK_DETAIL_ITEM = {
  id = "beacon-68", name = "Buddy's Base", status = "SILENT", enabled = false,
  pos = { x = 6462, y = 200, z = 6107 }, expectedPos = { x = 6460, y = 200, z = 6105 },
  health = { selfCheck = { ok = true }, constellation = { hosts = 3, grade = "GOOD" }, intervalMs = 1000 },
}
local MOCK_DETAIL_VIEW = { MOCK_DETAIL_ITEM }

t.test("M.buildDetail constructs the element tree; apply() renders header + info + buttons", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()

  local h = M.buildDetail(basalt, frame, rt)
  t.eq(h.id, "detail")
  t.truthy(h.elements.grid ~= nil, "action grid present")
  t.truthy(h.elements.grid.buttons.enable ~= nil, "ENABLE button present")
  t.truthy(h.elements.grid.buttons.remove ~= nil, "REMOVE button present")
  t.truthy(h.elements.backRow ~= nil, "BACK row present")
  t.truthy(h.elements.keypad ~= nil, "keypad overlay present")

  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  t.eq(h.elements.nameLbl:getText(), "Buddy's Base")
  t.eq(h.elements.idLbl:getText(), "ID: beacon-68")
  local lines = M.detailLines(MOCK_DETAIL_ITEM)
  for i = 1, 7 do
    t.eq(h.elements.infoLbls[i]:getText(), lines[i])
  end
end)

t.test("M.buildDetail apply(view, id) with an id not in view: shows the id + placeholder fields", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply({}, "beacon-99")
  basalt.update("timer", -1)
  t.eq(h.elements.nameLbl:getText(), "beacon-99")
  t.eq(h.elements.idLbl:getText(), "ID: beacon-99")
  t.eq(h.elements.infoLbls[1]:getText(), M.detailLine("STATUS", "SILENT"))
end)

t.test("M.buildDetail: ENABLE/DISABLE/VERIFY/REBOOT buttons send the right op for the currently-shown id", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.enable.button:fireEvent("mouse_click", 1, 1, 1)
  h.elements.grid.buttons.disable.button:fireEvent("mouse_click", 1, 1, 1)
  h.elements.grid.buttons.verify.button:fireEvent("mouse_click", 1, 1, 1)
  h.elements.grid.buttons.reboot.button:fireEvent("mouse_click", 1, 1, 1)

  t.eq(#rt.sendCalls, 4)
  t.eq(rt.sendCalls[1].op, "enable")
  t.eq(rt.sendCalls[2].op, "disable")
  t.eq(rt.sendCalls[3].op, "verify")
  t.eq(rt.sendCalls[4].op, "reboot")
  for _, c in ipairs(rt.sendCalls) do t.eq(c.id, "beacon-68") end
end)

t.test("M.buildDetail: with no id shown, direct-send buttons are a safe no-op", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  basalt.update("timer", -1)
  local ok = pcall(function() h.elements.grid.buttons.enable.button:fireEvent("mouse_click", 1, 1, 1) end)
  t.truthy(ok, "clicking with no current id must not error")
  t.eq(#rt.sendCalls, 0)
end)

t.test("M.buildDetail: PIN EXP sends nothing to the runtime channel-side, pins via setExpectedPos; nil lastPos -> no-op", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)
  h.elements.grid.buttons.pinexp.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#rt.expCalls, 1)
  t.eq(rt.expCalls[1].id, "beacon-68")
  t.eq(rt.expCalls[1].pos.x, MOCK_DETAIL_ITEM.pos.x)

  -- Now a beacon that has never been heard (no lastPos/pos) -- PIN EXP must no-op.
  local h2 = M.buildDetail(basalt, frame, rt)
  h2.apply({ { id = "beacon-99" } }, "beacon-99")
  basalt.update("timer", -1)
  h2.elements.grid.buttons.pinexp.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#rt.expCalls, 1, "no lastPos -- PIN EXP stays a no-op")
end)

t.test("M.buildDetail: UPDATE is destructive -- first click arms a confirm, does not send", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  t.truthy(h.elements.grid.buttons.update.state ~= "disabled", "UPDATE is a live button now (P6)")
  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#rt.reinstallCalls, 0, "first click only arms the confirm -- no send yet")
end)

t.test("M.buildDetail: UPDATE -- second click (confirm) sends the targeted reinstall, then disarms", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)   -- arm
  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)   -- confirm
  t.eq(#rt.reinstallCalls, 1, "second click confirms the reinstall")
  t.eq(rt.reinstallCalls[1].id, "beacon-68")

  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)   -- back to armed, not sent again
  t.eq(#rt.reinstallCalls, 1, "disarmed after confirming -- this click only re-arms")
end)

t.test("M.buildDetail: UPDATE confirm disarms on leaving the page (disarmUpdate)", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)   -- arm the confirm
  h.disarmUpdate()                                                          -- leaving DETAIL disarms it
  h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1)   -- a later click must only re-ARM
  t.eq(#rt.reinstallCalls, 0, "disarmed on leaving detail -- the next click re-arms, no stale reinstall")
end)

t.test("M.buildDetail: UPDATE with no id shown is a safe no-op", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  basalt.update("timer", -1)
  local ok = pcall(function() h.elements.grid.buttons.update.button:fireEvent("mouse_click", 1, 1, 1) end)
  t.truthy(ok, "clicking UPDATE with no current id must not error")
  t.eq(#rt.reinstallCalls, 0)
end)

t.test("M.buildDetail: SET POS opens the X/Y/Z sub-form pre-filled from the current pos; SEND sends { pos = {x,y,z} }", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.setpos.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(h.elements.posOverlay:getVisible(), true, "SET POS opens the sub-form")
  t.eq(h.elements.posXBtn:getText(), "6462", "pre-filled from the current broadcast pos")
  t.eq(h.elements.posYBtn:getText(), "200")
  t.eq(h.elements.posZBtn:getText(), "6107")

  -- Edit X via the shared keypad (a single show/ok cycle -- keypad.lua's OK always closes back to
  -- the form that opened it, so each field is its own independent prompt, never chained).
  h.elements.posXBtn:fireEvent("mouse_click", 1, 1, 1)
  t.truthy(h.elements.keypad.visible())
  h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP")
  h.elements.keypad.tap("1"); h.elements.keypad.tap("0")
  h.elements.keypad.ok()
  t.truthy(not h.elements.keypad.visible(), "keypad closes back to the SET POS form")
  t.eq(h.elements.posXBtn:getText(), "10")

  h.elements.posZBtn:fireEvent("mouse_click", 1, 1, 1)
  h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP"); h.elements.keypad.tap("BKSP")
  h.elements.keypad.tap("-"); h.elements.keypad.tap("3")
  h.elements.keypad.ok()
  t.eq(h.elements.posZBtn:getText(), "-3")

  h.elements.posActionRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)   -- SEND
  t.eq(h.elements.posOverlay:getVisible(), false, "SEND closes the sub-form")
  t.eq(#rt.sendCalls, 1)
  t.eq(rt.sendCalls[1].op, "setPos")
  t.eq(rt.sendCalls[1].args.pos.x, 10)
  t.eq(rt.sendCalls[1].args.pos.y, 200, "Y left untouched -- keeps its pre-filled value")
  t.eq(rt.sendCalls[1].args.pos.z, -3)
end)

t.test("M.buildDetail: SET POS with a never-heard beacon pre-fills blank fields; CANCEL sends nothing", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply({ { id = "beacon-99" } }, "beacon-99")
  basalt.update("timer", -1)

  h.elements.grid.buttons.setpos.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(h.elements.posXBtn:getText(), "...", "no known pos -- field starts blank")

  h.elements.posActionRow.buttons[2].button:fireEvent("mouse_click", 1, 1, 1)   -- CANCEL
  t.eq(h.elements.posOverlay:getVisible(), false)
  t.eq(#rt.sendCalls, 0, "CANCEL must not send")
end)

t.test("M.buildDetail: SET INTERVAL keypad -> sends { intervalMs = n }", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.setint.button:fireEvent("mouse_click", 1, 1, 1)
  t.truthy(h.elements.keypad.visible())
  h.elements.keypad.tap("3"); h.elements.keypad.tap("0"); h.elements.keypad.tap("0"); h.elements.keypad.tap("0")
  h.elements.keypad.ok()

  t.eq(#rt.sendCalls, 1)
  t.eq(rt.sendCalls[1].op, "setInterval")
  t.eq(rt.sendCalls[1].args.intervalMs, 3000)
end)

t.test("M.buildDetail: RENAME keypad -> runtime:setName, no channel traffic", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local h = M.buildDetail(basalt, frame, rt)
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)

  h.elements.grid.buttons.rename.button:fireEvent("mouse_click", 1, 1, 1)
  t.truthy(h.elements.keypad.visible())
  -- RENAME pre-fills the current name for editing (same convention as ui/basalt/pages/nav.lua's
  -- wptform NAME field) -- clear it, then type the new one.
  for _ = 1, #"Buddy's Base" do h.elements.keypad.tap("BKSP") end
  h.elements.keypad.tap("X")
  h.elements.keypad.ok()

  t.eq(#rt.sendCalls, 0)
  t.eq(#rt.nameCalls, 1)
  t.eq(rt.nameCalls[1].id, "beacon-68")
  t.eq(rt.nameCalls[1].name, "X")
end)

t.test("M.buildDetail: REMOVE calls runtime:remove(id) and invokes opts.onBack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local fired = 0
  local h = M.buildDetail(basalt, frame, rt, { onBack = function() fired = fired + 1 end })
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)
  h.elements.grid.buttons.remove.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#rt.removeCalls, 1)
  t.eq(rt.removeCalls[1], "beacon-68")
  t.eq(fired, 1)
end)

t.test("M.buildDetail: BACK button invokes opts.onBack", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntimeDetail()
  local fired = 0
  local h = M.buildDetail(basalt, frame, rt, { onBack = function() fired = fired + 1 end })
  h.apply(MOCK_DETAIL_VIEW, "beacon-68")
  basalt.update("timer", -1)
  h.elements.backRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(fired, 1)
end)

-- ===== M.build: opts.onRowSelect wiring (selecting opens DETAIL; deselecting does not) =====

t.test("M.build: selecting a row invokes opts.onRowSelect(id); deselecting the same row does not", function()
  local basalt = BasaltApp.ensureBasalt()
  local frame = basalt.createFrame()
  local rt = fakeRuntime()
  local seen = {}
  local h = M.build(basalt, frame, rt, { onRowSelect = function(id) seen[#seen + 1] = id end })
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  h.elements.selectRow(1)   -- row 1 -> beacon-67, selecting
  t.eq(#seen, 1)
  t.eq(seen[1], "beacon-67")

  h.elements.selectRow(1)   -- click again -> deselect, must NOT navigate away
  t.eq(#seen, 1, "deselecting must not fire onRowSelect")

  h.elements.selectRow(2)   -- beacon-68, selecting
  t.eq(#seen, 2)
  t.eq(seen[2], "beacon-68")
end)

-- ===== M.buildApp: DETAIL page wiring (Phase P5c) =====

local function fakeRuntimeAppFull()
  local sendCalls, queryCalls, removeCalls = {}, {}, {}
  return {
    sendCalls = sendCalls, queryCalls = queryCalls, removeCalls = removeCalls,
    sendCommandAll = function(self, op, args, now) return true end,
    sendCommand = function(self, id, op, args, now) sendCalls[#sendCalls + 1] = { id = id, op = op, args = args, now = now }; return true end,
    queryAll = function(self, now) queryCalls[#queryCalls + 1] = now; return true end,
    setName = function() end,
    setExpectedPos = function() end,
    remove = function(self, id) removeCalls[#removeCalls + 1] = id end,
  }
end

t.test("M.buildApp: roster row-select opens DETAIL for that beacon; DETAIL hidden + roster visible at construction", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeAppFull()
  local h = M.buildApp(basalt, base, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  t.eq(h.elements.detailFrame:getVisible(), false)

  h.elements.roster.elements.selectRow(1)   -- beacon-67
  t.eq(h.elements.detailFrame:getVisible(), true, "selecting a row opens DETAIL")
  t.eq(h.elements.rosterFrame:getVisible(), false)
  t.eq(h.elements.detail.elements.nameLbl:getText(), "North Pillar")
  t.eq(h.elements.detail.elements.idLbl:getText(), "ID: beacon-67")
end)

t.test("M.buildApp: DETAIL's BACK button returns to the roster", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeAppFull()
  local h = M.buildApp(basalt, base, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  h.elements.roster.elements.selectRow(1)
  t.eq(h.elements.detailFrame:getVisible(), true)

  h.elements.detail.elements.backRow.buttons[1].button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(h.elements.detailFrame:getVisible(), false)
  t.eq(h.elements.rosterFrame:getVisible(), true)
end)

t.test("M.buildApp: an action button on DETAIL sends the targeted command via runtime:sendCommand", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeAppFull()
  local h = M.buildApp(basalt, base, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  h.elements.roster.elements.selectRow(2)   -- beacon-68
  h.elements.detail.elements.grid.buttons.disable.button:fireEvent("mouse_click", 1, 1, 1)

  t.eq(#rt.sendCalls, 1)
  t.eq(rt.sendCalls[1].id, "beacon-68")
  t.eq(rt.sendCalls[1].op, "disable")
end)

t.test("M.buildApp: REMOVE on DETAIL removes the beacon and returns to the roster", function()
  local basalt = BasaltApp.ensureBasalt()
  local base = basalt.createFrame()
  local rt = fakeRuntimeAppFull()
  local h = M.buildApp(basalt, base, rt)
  h.apply(MOCK_VIEW)
  basalt.update("timer", -1)

  h.elements.roster.elements.selectRow(4)   -- beacon-70
  t.eq(h.elements.detailFrame:getVisible(), true)

  h.elements.detail.elements.grid.buttons.remove.button:fireEvent("mouse_click", 1, 1, 1)
  t.eq(#rt.removeCalls, 1)
  t.eq(rt.removeCalls[1], "beacon-70")
  t.eq(h.elements.detailFrame:getVisible(), false)
  t.eq(h.elements.rosterFrame:getVisible(), true)
end)

return true
