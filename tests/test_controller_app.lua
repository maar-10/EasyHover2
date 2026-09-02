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
  local calls = {}
  return {
    calls = calls,
    sendCommandAll = function(self, op, args, now)
      calls[#calls + 1] = { op = op, args = args, now = now }
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

return true
