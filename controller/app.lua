-- controller/app.lua
-- GPS beacon controller: Basalt 2.0 shell UI on an advanced computer terminal (native 51x19, no
-- monitor scaling), wired to the P3b controller.runtime. ROSTER (P5a), DIAG (P5b), per-beacon
-- DETAIL (P5c), and UPDATE/UPDATE ALL (P6, folding the retired standalone updater in) are all
-- built. Follows ui/basalt/pages/*.lua's exact contract: M.build(basalt, frame, runtime) ->
-- { apply(view), elements }, Basalt-free/testable intent seams for every button, and a thin M.run()
-- that wires peripherals + the event loop -- so `require("controller.app")` loads clean headless.
--
-- Mount pattern mirrors ui/basalt/app.lua's M.run: basalt.getMainFrame() (bound to term.current())
-- as the base, one full-size CHILD frame added on top for the page (never build straight on the
-- base -- see tools/render/README.md's "mount like the real app" rule), then basalt.run() so
-- Basalt's own dispatcher services button clicks. Our own comms/repaint logic rides
-- basalt.schedule() coroutines using os.pullEvent/sleep -- EVENT-DRIVEN, never a busy loop (mirrors
-- beacon/app.lua's discipline), just running where basalt.run()'s dispatcher can resume them.
--
-- NO peripheral/Basalt/fs access at module LOAD -- everything lives inside M.build/M._*/M.run.
local Config    = require("controller.config")
local Runtime   = require("controller.runtime")
local Diag      = require("controller.diag")
local Theme     = require("ui.theme")
local configkit = require("ui.basalt.configkit")
local Keypad    = require("ui.basalt.keypad")

local M = {}
M.id = "roster"
M.title = "EH2 BEACON CONTROL"

-- ===== pure formatting helpers (testable with no Basalt/peripherals) =====

-- round(v): half-away-from-zero, correct for negative block coordinates (math.floor(v+0.5) alone
-- rounds -0.5 to 0 instead of -1).
local function round(v)
  if v >= 0 then return math.floor(v + 0.5) end
  return -math.floor(-v + 0.5)
end

--- M.formatPos(pos) -> "x y z" (rounded to whole blocks) | "--" when pos is nil.
function M.formatPos(pos)
  if not pos then return "--" end
  return string.format("%d %d %d", round(pos.x or 0), round(pos.y or 0), round(pos.z or 0))
end

--- M.formatAge(ms) -> a short humanised age ("820ms" / "3.4s" / "12m" / "1.5h") | "--" when nil
--- (never heard). Matches the design sketch's "3m" / "0.6s" style.
function M.formatAge(ms)
  if ms == nil then return "--" end
  if ms < 0 then ms = 0 end
  if ms < 1000 then return string.format("%dms", ms) end
  local s = ms / 1000
  if s < 60 then return string.format("%.1fs", s) end
  local m = s / 60
  if m < 60 then return string.format("%.0fm", m) end
  local h = m / 60
  return string.format("%.1fh", h)
end

--- M.fitField(text, width) -> text truncated or space-padded to EXACTLY width columns.
function M.fitField(text, width)
  text = tostring(text)
  if #text >= width then return text:sub(1, width) end
  return text .. string.rep(" ", width - #text)
end

-- Status word -> colour. LIVE green, SILENT gray (lightGray -- CC's darker `gray` slot barely
-- reads on the black panel background), DISABLED orange, OFFLINE red. Unknown/missing -> white.
M.STATUS_COLOR = {
  LIVE = colors.green, SILENT = colors.lightGray, DISABLED = colors.orange, OFFLINE = colors.red,
}

-- Fixed column widths for one roster row: "> " marker, name (falls back to id), status word,
-- position, age. Sums to 48 columns -- fits the 51-wide terminal with room to spare.
M.NAME_W, M.STATUS_W, M.POS_W, M.AGE_W = 13, 9, 14, 7

--- M.rowLine(item, selected) -> the full row text ("> Buddy's Base   SILENT    6462 200 6107  3m ")
--- plus the column (1-based) where the status field starts, so the caller can recolour just that
--- span. PURE -- no Basalt.
function M.rowLine(item, selected)
  local mark = selected and "> " or "  "
  local name = M.fitField((item and (item.name or item.id)) or "?", M.NAME_W)
  local statusWord = tostring(item and item.status or "SILENT")
  local status = M.fitField(statusWord, M.STATUS_W)
  local pos = M.fitField(M.formatPos(item and item.pos), M.POS_W)
  local age = M.fitField(M.formatAge(item and item.ageMs), M.AGE_W)
  local line = mark .. name .. " " .. status .. " " .. pos .. " " .. age
  local statusAt = 1 + #mark + #name + 1
  return line, statusAt, #status, statusWord
end

--- M.headerText(items) -> "EH2 BEACON CONTROL   N live / M known".
function M.headerText(items)
  local live, known = 0, 0
  for _, it in ipairs(items or {}) do
    known = known + 1
    if it.status == "LIVE" then live = live + 1 end
  end
  return string.format("EH2 BEACON CONTROL   %d live / %d known", live, known)
end

-- ===== DIAG page: pure formatting helpers (testable with no Basalt/peripherals) =====
--
-- The DIAG page's status table reads runtime:view(now)'s per-row `enabled`/`health`/
-- `lastReplyAgeMs` fields (controller/runtime.lua) -- the beacon's own §3.5 status-reply payload,
-- collected by active polling (controller/diag.lua's gate) rather than the passive roster feed.

--- M.formatEnabled(enabled) -> "ON" | "OFF" | "?" (never heard an enabled flag at all).
function M.formatEnabled(enabled)
  if enabled == true then return "ON" end
  if enabled == false then return "OFF" end
  return "?"
end

--- M.formatSelfCheck(health) -> "OK" | "N MISM" | "--" (no health/selfCheck known yet).
function M.formatSelfCheck(health)
  local sc = health and health.selfCheck
  if not sc then return "--" end
  if sc.ok then return "OK" end
  return string.format("%d MISM", sc.mismatches or 0)
end

--- M.formatConstellation(health) -> "H/4 GRADE" | "--" (no constellation known yet).
function M.formatConstellation(health)
  local c = health and health.constellation
  if not c then return "--" end
  return string.format("%s/4 %s", tostring(c.hosts or 0), tostring(c.grade or "?"))
end

--- M.formatInterval(health) -> the beacon's own broadcast interval, humanised via formatAge's
--- ms/s/m/h bands (same scale as an age; "--" when never reported).
function M.formatInterval(health)
  return M.formatAge(health and health.intervalMs)
end

-- Fixed column widths for one DIAG row: name (falls back to id), enabled, self-check,
-- constellation, interval, last-reply age. Sums to 45 + 5 single-space separators = 50 columns --
-- fits the 51-wide terminal.
M.DIAG_NAME_W, M.DIAG_EN_W, M.DIAG_SC_W, M.DIAG_CONST_W, M.DIAG_INT_W, M.DIAG_AGE_W = 12, 4, 8, 9, 6, 6

-- Colour cues, same vocabulary as the roster's M.STATUS_COLOR: green = healthy, orange = a known
-- but off/disabled state, red = a real problem (mismatch), lightGray = unknown/never reported.
M.EN_COLOR = { ON = colors.green, OFF = colors.orange, ["?"] = colors.lightGray }
local function scColor(word)
  if word == "OK" then return colors.green end
  if word == "--" then return colors.lightGray end
  return colors.red -- "N MISM"
end

--- M.diagRowLine(item) -> the full row text plus (1-based) column + length + word for the two
--- colour-coded fields (enabled, self-check), so the caller can recolour just those spans. PURE --
--- no Basalt. `item` is one row from runtime:view(now) (or nil for a blank row).
function M.diagRowLine(item)
  local name = M.fitField((item and (item.name or item.id)) or "?", M.DIAG_NAME_W)
  local enWord = M.formatEnabled(item and item.enabled)
  local en = M.fitField(enWord, M.DIAG_EN_W)
  local scWord = M.formatSelfCheck(item and item.health)
  local sc = M.fitField(scWord, M.DIAG_SC_W)
  local co = M.fitField(M.formatConstellation(item and item.health), M.DIAG_CONST_W)
  local iv = M.fitField(M.formatInterval(item and item.health), M.DIAG_INT_W)
  local age = M.fitField(M.formatAge(item and item.lastReplyAgeMs), M.DIAG_AGE_W)
  local line = name .. " " .. en .. " " .. sc .. " " .. co .. " " .. iv .. " " .. age
  local enAt = 1 + #name + 1
  local scAt = enAt + #en + 1
  return line, enAt, #en, enWord, scAt, #sc, scWord
end

--- M.diagColHeader() -> the column-title row, aligned to the same widths as M.diagRowLine.
function M.diagColHeader()
  local name = M.fitField("NAME", M.DIAG_NAME_W)
  local en = M.fitField("EN", M.DIAG_EN_W)
  local sc = M.fitField("SELFCHK", M.DIAG_SC_W)
  local co = M.fitField("CONST", M.DIAG_CONST_W)
  local iv = M.fitField("INT", M.DIAG_INT_W)
  local age = M.fitField("AGE", M.DIAG_AGE_W)
  return name .. " " .. en .. " " .. sc .. " " .. co .. " " .. iv .. " " .. age
end

--- M.pollingText(active) -> "polling..." while the DIAG gate is shown, else "" (the design's
--- required visible indicator -- §3.1).
function M.pollingText(active)
  return active and "polling..." or ""
end

-- ===== DETAIL page: pure formatting helpers (testable with no Basalt/peripherals) =====

--- M.findItem(view, id) -> the entry in `view` (a runtime:view(now) list) whose id matches, or nil
--- (never-seen / vanished id). PURE.
function M.findItem(view, id)
  if id == nil then return nil end
  for _, it in ipairs(view or {}) do
    if it.id == id then return it end
  end
  return nil
end

--- M.detailHeaderLines(item, id) -> nameLine, idLine. Friendly name (falls back to id, then "?")
--- on top; the raw beacon id always shown on its own line underneath, same "name may lie, id never
--- does" discipline as the roster's M.rowLine.
function M.detailHeaderLines(item, id)
  local name = (item and item.name) or id or "?"
  return tostring(name), "ID: " .. tostring(id or "?")
end

M.DETAIL_LABEL_W = 9

--- M.detailLine(label, value) -> "LABEL    value", label padded to M.DETAIL_LABEL_W. PURE.
function M.detailLine(label, value)
  return M.fitField(label, M.DETAIL_LABEL_W) .. " " .. tostring(value)
end

--- M.detailLines(item) -> the DETAIL page's fixed 7-line info block (status/enabled/pos/expected/
--- interval/selfcheck/constellation), reusing the same formatters the roster + DIAG pages already
--- rely on. `item` may be nil (id not present in the current view) -- every field then falls back
--- to its own "unknown" placeholder, same as a never-seen beacon everywhere else in this module.
function M.detailLines(item)
  return {
    M.detailLine("STATUS",   (item and item.status) or "SILENT"),
    M.detailLine("ENABLED",  M.formatEnabled(item and item.enabled)),
    M.detailLine("POS",      M.formatPos(item and item.pos)),
    M.detailLine("EXPECTED", M.formatPos(item and item.expectedPos)),
    M.detailLine("INTERVAL", M.formatInterval(item and item.health)),
    M.detailLine("SELFCHK",  M.formatSelfCheck(item and item.health)),
    M.detailLine("CONST",    M.formatConstellation(item and item.health)),
  }
end

--- M.parseNum(s) -> an integer, or nil for anything that isn't one ("", "-", non-numeric text). No
--- decimals -- matches the keypad's own num-mode buffer, which only ever holds digits + a leading
--- "-" (ui/basalt/keypad.lua:M.apply), and the roster/DETAIL display's whole-block rounding.
function M.parseNum(s)
  if s == nil or s == "" or s == "-" then return nil end
  local n = tonumber(s)
  if type(n) ~= "number" then return nil end
  return n
end

-- ===== DETAIL page: per-action TESTABLE intent seams. No Basalt. =====
--
-- Each mirrors beacon/command.lua's OPS table EXACTLY -- same op name, same args shape -- so a
-- token-valid send round-trips through the beacon's own M.apply with no translation layer to drift
-- out of sync. Direct-send ops (enable/disable/verify/reboot) carry no args at all; setPos/
-- setInterval carry EXACTLY the {pos={x,y,z}} / {intervalMs=n} shapes beacon/command.lua expects.
-- Fail-closed by construction: runtime:sendCommand itself refuses (no transmit) without a valid
-- token, so none of these need extra gating.
function M._onEnable(runtime, id, now) return runtime:sendCommand(id, "enable", nil, now) end
function M._onDisable(runtime, id, now) return runtime:sendCommand(id, "disable", nil, now) end
function M._onVerify(runtime, id, now) return runtime:sendCommand(id, "verify", nil, now) end
function M._onReboot(runtime, id, now) return runtime:sendCommand(id, "reboot", nil, now) end

--- M._onSetPos(runtime, id, pos, now) -> sendCommand(id, "setPos", { pos = pos }, now). `pos` must
--- already be a plain { x, y, z } (the keypad-chain caller in M.buildDetail parses the three
--- numeric prompts before calling this; a malformed pos is beacon/command.lua's own problem to
--- reject, not this seam's).
function M._onSetPos(runtime, id, pos, now)
  return runtime:sendCommand(id, "setPos", { pos = pos }, now)
end

--- M._onSetInterval(runtime, id, intervalMs, now) -> sendCommand(id, "setInterval",
--- { intervalMs = intervalMs }, now).
function M._onSetInterval(runtime, id, intervalMs, now)
  return runtime:sendCommand(id, "setInterval", { intervalMs = intervalMs }, now)
end

--- M._onRename(runtime, id, name) -> runtime:setName(id, name) (controller-side annotation, not a
--- beacon command -- persists via runtime's own injected save/path, no channel traffic).
function M._onRename(runtime, id, name)
  return runtime:setName(id, name)
end

--- M._onPinExpected(runtime, id, lastPos) -> pins `lastPos` (the beacon's current broadcast
--- position) as the operator-surveyed "correct" position. No-op (returns false, does not touch the
--- runtime at all) when lastPos is nil -- a beacon the controller has never actually heard has
--- nothing to pin.
function M._onPinExpected(runtime, id, lastPos)
  if not lastPos then return false end
  runtime:setExpectedPos(id, lastPos)
  return true
end

--- M._onUpdate(runtime, id, now) -> runtime:sendReinstall(id, now) -- Phase P6, folding
--- launchers/beaconupdate.lua's retired standalone updater into the per-beacon DETAIL page. The
--- caller (M.buildDetail's UPDATE button) gates this behind a two-tap confirm, since a reinstall
--- reboots the beacon; this seam only fires the actual send, never the arming step.
function M._onUpdate(runtime, id, now)
  return runtime:sendReinstall(id, now)
end

--- M._onRemove(runtime, id) -> runtime:remove(id). Always succeeds (removing an already-absent id
--- is a harmless no-op inside runtime:remove itself); the caller (M.buildDetail's REMOVE button)
--- follows this with a return to the roster.
function M._onRemove(runtime, id)
  runtime:remove(id)
  return true
end

-- ===== M._onEnableAll: the TESTABLE intent seam for the ENABLE ALL footer button. No Basalt. =====
--
-- Fail-closed by construction: runtime:sendCommandAll (controller/runtime.lua) itself refuses (no
-- transmit) when the controller has no valid token, so this seam needs no extra gating.
function M._onEnableAll(runtime, now)
  return runtime:sendCommandAll("enable", nil, now)
end

--- M._onUpdateAll: the TESTABLE intent seam for the UPDATE ALL footer button (Phase P6, folding
--- launchers/beaconupdate.lua's retired standalone updater in). Fail-closed by construction:
--- runtime:sendReinstallAll (controller/runtime.lua) itself refuses (no transmit) when the
--- controller has no valid token. UPDATE ALL reboots every beacon on the mesh, so the caller
--- (M.build's footer button below) gates this behind a two-tap confirm -- this seam only fires the
--- actual send, never the arming step.
function M._onUpdateAll(runtime, now)
  return runtime:sendReinstallAll(now)
end

-- ===== M.build: construct the element tree =====
--
-- M.build(basalt, frame, runtime, opts) -> { apply(view), elements }
-- `runtime` is a controller.runtime instance (R:view/R:sendCommandAll). `apply(view)` takes
-- exactly runtime:view(now)'s return shape -- a list of { id, name, pos, ageMs, status, ... },
-- already sorted by id -- and repaints the roster; idempotent, never touches peripherals.
-- opts.onDiag (optional): wires the footer DIAG button live (state "off", calls opts.onDiag() on
-- click) instead of P5a's disabled stub -- M.buildApp passes this to open the DIAG page below.
function M.build(basalt, frame, runtime, opts)
  opts = opts or {}
  local w, h = frame:getSize()
  local FONT = Theme.role("font")

  -- ----- static chrome (built once; never changes) -----
  local headerLbl = frame:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "" })
  headerLbl:setForeground(FONT)
  local divTop = frame:addLabel({ x = 1, y = 2, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divTop:setForeground(FONT)

  -- Fixed overhead below the list: 1 divider + 1 scroll row + 1 action row = 3, plus the 2 rows
  -- above (header + top divider) = 5 total, so ROWS = h - 5. At the real 51x19 terminal size this
  -- is exactly 14 visible rows (1+1+14+1+1+1 = 19).
  local listTop = 3
  local ROWS = math.max(1, h - 5)
  local divBottomY = listTop + ROWS
  local scrollY = divBottomY + 1
  local actionY = scrollY + 1

  local divBottom = frame:addLabel({ x = 1, y = divBottomY, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divBottom:setForeground(FONT)

  -- Coloured row text lives on an Image (mixed per-row colours -- name/pos/age in the font colour,
  -- status in its own status colour -- a plain Label can only carry one foreground per element,
  -- same technique ui/basalt/pages/config.lua's monitor list uses). IMPORTANT: Image pixel
  -- coordinates (setText/setFg/setBg/getText/getFg) are LOCAL to the image (1..ROWS) -- Basalt
  -- already offsets by the image's own x/y (listTop) when it draws the element onto the frame, so
  -- every image-pixel call below uses the visible row index `r` (1..ROWS) directly, NEVER
  -- `listTop + r - 1` (that double-offsets: rows 1..listTop-1 stay blank and the last
  -- listTop-1 rows silently fall off the image's own height, since setText no-ops past it).
  local listImg = frame:addImage({ x = 1, y = listTop, width = w, height = ROWS })
  listImg:resizeImage(w, ROWS)
  listImg.set("z", 1)
  local BLACK = colors.toBlit(colors.black)
  local FONT_BLIT = colors.toBlit(FONT)

  -- Click-catchers: one transparent full-width label per visible row, purely for hit-testing (text
  -- stays "" always -- the Image beneath carries the visible glyphs), same idiom as
  -- ui/basalt/pages/config.lua's `hits` list.
  local hits = {}

  -- ----- live state (closure-local; NOT part of `view` -- selection/scroll persist across apply) -----
  local items, offset, selectedId = {}, 0, nil

  local function clearRow(ry)
    listImg:setText(1, ry, string.rep(" ", w))
    listImg:setBg(1, ry, string.rep(BLACK, w))
    listImg:setFg(1, ry, string.rep(FONT_BLIT, w))
  end

  local function drawRow(ry, item)
    clearRow(ry)
    if not item then return end
    local line, statusAt, statusLen, statusWord = M.rowLine(item, item.id == selectedId)
    if #line > w then line = line:sub(1, w) end
    listImg:setText(1, ry, line)
    listImg:setFg(1, ry, string.rep(FONT_BLIT, #line))
    local scolor = colors.toBlit(M.STATUS_COLOR[statusWord] or colors.white)
    listImg:setFg(statusAt, ry, string.rep(scolor, statusLen))
  end

  local render -- forward-declared: selectRow/scrollBy call it before its own definition below

  local function selectRow(visIdx)
    local it = items[offset + visIdx]
    if not it then return end
    if selectedId == it.id then selectedId = nil else selectedId = it.id end
    render()
    -- Opening the DETAIL page (opts.onRowSelect, wired by M.buildApp) fires only on a genuine
    -- SELECT, never on the second click that deselects -- deselecting a row should never navigate
    -- away. A bare M.build call (render-recipe / older tests) passes no onRowSelect -- no-op.
    if selectedId and opts.onRowSelect then opts.onRowSelect(selectedId) end
  end

  for i = 1, ROWS do
    local hb = frame:addLabel({ x = 1, y = listTop + i - 1, width = w, height = 1, autoSize = false, text = "" })
    local idx = i
    hb:onClick(function() selectRow(idx) end)
    hits[i] = hb
  end

  render = function()
    headerLbl:setText(M.headerText(items))
    local maxOff = math.max(0, #items - ROWS)
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end
    for r = 1, ROWS do
      drawRow(r, items[offset + r])
    end
  end

  local function scrollBy(delta)
    offset = offset + delta
    render()
  end

  -- ----- footer: scroll row (UP/DOWN) + action row (DIAG / ENABLE ALL / UPDATE ALL) -----
  local scrollRow = configkit.actionRow(frame, { x = 1, y = scrollY, w = w }, {
    { label = "UP",   kind = "function", onClick = function() scrollBy(-ROWS) end },
    { label = "DOWN", kind = "function", onClick = function() scrollBy(ROWS) end },
  })

  -- DIAG: live (opens the P5b DIAG page) when the caller wires opts.onDiag (M.buildApp does);
  -- stays a disabled stub for a bare M.build call with no page to open (e.g. the render-recipe /
  -- construction-probe fake-runtime tests that predate P5b).
  local diagSpec = { label = "DIAG", kind = "menu" }
  if opts.onDiag then diagSpec.state = "off"; diagSpec.onClick = opts.onDiag
  else diagSpec.state = "disabled" end

  -- UPDATE ALL folds launchers/beaconupdate.lua's retired standalone updater into this button
  -- (Phase P6). Rebooting every beacon on the mesh is destructive, so it needs a confirm step: the
  -- first click just arms it (label flips to CONFIRM?); a second click while armed actually sends
  -- via M._onUpdateAll, then disarms. "set channel" is deliberately never offered here (design
  -- §3.2). updateAllBtn is captured right after actionRow builds it, below.
  local updateAllArmed = false
  local updateAllBtn
  local function onUpdateAllClick()
    if updateAllArmed then
      updateAllArmed = false
      updateAllBtn.setLabel("UPDATE ALL")
      M._onUpdateAll(runtime, os.epoch("utc"))
    else
      updateAllArmed = true
      updateAllBtn.setLabel("CONFIRM?")
    end
  end

  local actionRow = configkit.actionRow(frame, { x = 1, y = actionY, w = w }, {
    diagSpec,
    { label = "ENABLE ALL",  kind = "function", onClick = function() M._onEnableAll(runtime, os.epoch("utc")) end },
    { label = "UPDATE ALL",  kind = "function", onClick = onUpdateAllClick },
  })
  updateAllBtn = actionRow.buttons[3]

  --- apply(view): repaint from runtime:view(now)'s list. Idempotent; never polls peripherals.
  local function apply(view)
    items = view or {}
    if selectedId then
      local still = false
      for _, it in ipairs(items) do if it.id == selectedId then still = true; break end end
      if not still then selectedId = nil end
    end
    render()
  end

  render()

  return {
    id = M.id,
    apply = apply,
    elements = {
      header = headerLbl, divTop = divTop, divBottom = divBottom,
      listImg = listImg, hits = hits,
      scrollRow = scrollRow, actionRow = actionRow,
      selected = function() return selectedId end,
      selectRow = selectRow,
      scrollBy = scrollBy,
    },
  }
end

-- ===== M.buildDiag: the DIAG page (Phase P5b) =====
--
-- M.buildDiag(basalt, frame, runtime, opts) -> { id = "diag", apply(view, active), elements }
-- `apply(view, active)` takes the SAME runtime:view(now) shape the roster consumes, plus a second
-- boolean: whether the DIAG poll gate (controller/diag.lua) is currently shown -- drives the
-- visible "polling..." indicator (design §3.1). `active` defaults to true so a bare
-- apply(view) call (tests, render recipes) still shows the indicator. opts.onBack (optional):
-- wired to the pinned BACK button (configkit.actionRow's "back" id -> the CC-native left arrow).
-- Never calls runtime:queryAll itself -- that is entirely controller/diag.lua's job, driven by the
-- app's own timer coroutine; this page only ever READS runtime:view(now)'s already-collected rows.
function M.buildDiag(basalt, frame, runtime, opts)
  opts = opts or {}
  local w, h = frame:getSize()
  local FONT = Theme.role("font")

  -- ----- static chrome -----
  local POLL_W = 12
  local titleLbl = frame:addLabel({ x = 1, y = 1, width = w - POLL_W, height = 1, autoSize = false, text = "EH2 BEACON DIAG" })
  titleLbl:setForeground(FONT)
  local pollingLbl = frame:addLabel({ x = w - POLL_W + 1, y = 1, width = POLL_W, height = 1, autoSize = false, text = "" })
  pollingLbl:setForeground(colors.yellow)

  local divTop = frame:addLabel({ x = 1, y = 2, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divTop:setForeground(FONT)
  local colHeaderLbl = frame:addLabel({ x = 1, y = 3, width = w, height = 1, autoSize = false, text = M.diagColHeader() })
  colHeaderLbl:setForeground(FONT)

  -- Fixed overhead: 3 rows above (title + divider + column header) + 3 below (divider + scroll row
  -- + the BACK action row, pinned to the bottom row by configkit.actionRow) = 6 total.
  local listTop = 4
  local ROWS = math.max(1, h - 6)
  local divBottomY = listTop + ROWS
  local scrollY = divBottomY + 1

  local divBottom = frame:addLabel({ x = 1, y = divBottomY, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divBottom:setForeground(FONT)

  -- Same per-row-coloured-text technique as the roster (M.build): a black-background Image carries
  -- the row glyphs so the ENABLED/SELFCHK fields can each carry their own colour, which a plain
  -- Label (one foreground only) can't. Image pixel coords are LOCAL (1..ROWS) -- see M.build's
  -- header comment on this exact gotcha.
  local listImg = frame:addImage({ x = 1, y = listTop, width = w, height = ROWS })
  listImg:resizeImage(w, ROWS)
  listImg.set("z", 1)
  local BLACK = colors.toBlit(colors.black)
  local FONT_BLIT = colors.toBlit(FONT)

  local items, offset = {}, 0

  local function clearRow(ry)
    listImg:setText(1, ry, string.rep(" ", w))
    listImg:setBg(1, ry, string.rep(BLACK, w))
    listImg:setFg(1, ry, string.rep(FONT_BLIT, w))
  end

  local function drawRow(ry, item)
    clearRow(ry)
    if not item then return end
    local line, enAt, enLen, enWord, scAt, scLen, scWord = M.diagRowLine(item)
    if #line > w then line = line:sub(1, w) end
    listImg:setText(1, ry, line)
    listImg:setFg(1, ry, string.rep(FONT_BLIT, #line))
    listImg:setFg(enAt, ry, string.rep(colors.toBlit(M.EN_COLOR[enWord] or colors.white), enLen))
    listImg:setFg(scAt, ry, string.rep(colors.toBlit(scColor(scWord)), scLen))
  end

  local function render()
    local maxOff = math.max(0, #items - ROWS)
    if offset > maxOff then offset = maxOff end
    if offset < 0 then offset = 0 end
    for r = 1, ROWS do
      drawRow(r, items[offset + r])
    end
  end

  local function scrollBy(delta)
    offset = offset + delta
    render()
  end

  local scrollRow = configkit.actionRow(frame, { x = 1, y = scrollY, w = w }, {
    { label = "UP",   kind = "function", onClick = function() scrollBy(-ROWS) end },
    { label = "DOWN", kind = "function", onClick = function() scrollBy(ROWS) end },
  })

  local actionRow = configkit.actionRow(frame, { x = 1, y = h, w = w }, {
    { label = "BACK", id = "back", kind = "menu", onClick = function() if opts.onBack then opts.onBack() end end },
  })

  --- apply(view, active): repaint the status table + polling indicator. Idempotent; never polls
  --- peripherals (that is controller/diag.lua's `poll(runtime, now)`, driven separately).
  local function apply(view, active)
    items = view or {}
    if active == nil then active = true end
    pollingLbl:setText(M.pollingText(active))
    render()
  end

  render()

  return {
    id = "diag",
    apply = apply,
    elements = {
      title = titleLbl, polling = pollingLbl, colHeader = colHeaderLbl,
      divTop = divTop, divBottom = divBottom, listImg = listImg,
      scrollRow = scrollRow, actionRow = actionRow, scrollBy = scrollBy,
    },
  }
end

-- ===== M.buildDetail: the per-beacon DETAIL page (Phase P5c) =====
--
-- M.buildDetail(basalt, frame, runtime, opts) -> { id = "detail", apply(view, id), elements }
-- `apply(view, id)` takes the SAME runtime:view(now) shape the roster/DIAG pages consume, plus the
-- id of the beacon currently on screen (M.buildApp drives this from the roster's row-select).
-- opts.onBack (optional): wired to the pinned BACK button AND to REMOVE (removing the beacon shown
-- has nothing left to display, so it returns to the roster same as BACK). Every action button is a
-- thin Basalt wrapper around a pure M._on* intent seam above -- direct sends (ENABLE/DISABLE/
-- VERIFY/REBOOT) fire immediately; SET POS/SET INTERVAL/RENAME reuse ui/basalt/keypad.lua's overlay
-- (SET POS chains three numeric prompts, X -> Y -> Z, before sending -- matching beacon/command.
-- lua's {x,y,z} contract exactly); UPDATE sends a targeted reinstall (P6, beacon/update.lua's
-- LEGACY M.command), gated behind a two-tap confirm since it reboots the beacon.
function M.buildDetail(basalt, frame, runtime, opts)
  opts = opts or {}
  local w, h = frame:getSize()
  local FONT = Theme.role("font")

  local currentId, currentItem = nil, nil

  -- ----- header: name (falls back to id) + the raw id underneath + a divider -----
  local nameLbl = frame:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "" })
  nameLbl:setForeground(FONT)
  local idLbl = frame:addLabel({ x = 1, y = 2, width = w, height = 1, autoSize = false, text = "" })
  idLbl:setForeground(FONT)
  local divTop = frame:addLabel({ x = 1, y = 3, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divTop:setForeground(FONT)

  -- ----- info block: the fixed 7 lines M.detailLines returns, starting row 4 -----
  local infoTop = 4
  local infoLbls = {}
  for i = 1, 7 do
    local lbl = frame:addLabel({ x = 1, y = infoTop + i - 1, width = w, height = 1, autoSize = false, text = "" })
    lbl:setForeground(FONT)
    infoLbls[i] = lbl
  end

  local divMidY = infoTop + 7
  local divMid = frame:addLabel({ x = 1, y = divMidY, width = w, height = 1, autoSize = false, text = string.rep("-", w) })
  divMid:setForeground(FONT)

  -- ----- action grid (above the pinned BACK row) -----
  local gridY = divMidY + 1

  local function nowMs() return os.epoch("utc") end

  local keypad = Keypad.make(frame)

  -- ----- SET POS sub-form: three field buttons (X/Y/Z) + SEND/CANCEL, each field independently
  -- opening the SHARED keypad for numeric entry -- exactly ui/basalt/pages/nav.lua's wptform idiom
  -- (one keypad.show() per user tap; the keypad's own OK always closes back to whichever screen
  -- called it -- ui/basalt/keypad.lua's ctrl.ok() runs onOk() THEN unconditionally hides, so
  -- chaining keypad.show() calls INSIDE one another's onOk is not this component's contract; three
  -- independent field buttons is the supported multi-field pattern). A modal black overlay (same
  -- opaque-cover idiom keypad.lua itself uses) so nothing underneath is reachable while it's up.
  local posDraft = { x = "", y = "", z = "" }
  local renderPosForm -- forward-declared: the field buttons' onClick close over it
  local posOverlay = frame:addFrame({ x = 1, y = 1, width = w, height = h })
  posOverlay:setZ(50)
  posOverlay:setBackground(colors.black)
  posOverlay:setVisible(false)
  local posTitleLbl = posOverlay:addLabel({ x = 1, y = 1, width = w, height = 1, autoSize = false, text = "SET POSITION" })
  posTitleLbl:setForeground(FONT)
  local function posFieldRow(label, y)
    local lbl = posOverlay:addLabel({ x = 1, y = y, width = 4, height = 1, autoSize = false, text = label })
    lbl:setForeground(FONT)
    local btn = posOverlay:addButton({ x = 6, y = y, width = 12, height = 1, text = "" })
    return lbl, btn
  end
  local xLbl, xBtn = posFieldRow("X", 3)
  local yLbl, yBtn = posFieldRow("Y", 4)
  local zLbl, zBtn = posFieldRow("Z", 5)

  renderPosForm = function()
    xBtn:setText(posDraft.x ~= "" and posDraft.x or "...")
    yBtn:setText(posDraft.y ~= "" and posDraft.y or "...")
    zBtn:setText(posDraft.z ~= "" and posDraft.z or "...")
  end

  xBtn:onClick(function() keypad.show({ title = "X", mode = "num", value = posDraft.x, onOk = function(v) posDraft.x = v; renderPosForm() end }) end)
  yBtn:onClick(function() keypad.show({ title = "Y", mode = "num", value = posDraft.y, onOk = function(v) posDraft.y = v; renderPosForm() end }) end)
  zBtn:onClick(function() keypad.show({ title = "Z", mode = "num", value = posDraft.z, onOk = function(v) posDraft.z = v; renderPosForm() end }) end)

  local posActionRow = configkit.actionRow(posOverlay, { x = 1, y = h, w = w }, {
    { label = "SEND", id = "send", kind = "function", onClick = function()
        local id = currentId
        local x, y, z = M.parseNum(posDraft.x), M.parseNum(posDraft.y), M.parseNum(posDraft.z)
        if id and x ~= nil and y ~= nil and z ~= nil then
          M._onSetPos(runtime, id, { x = x, y = y, z = z }, nowMs())
        end
        posOverlay:setVisible(false)
      end },
    { label = "CANCEL", id = "cancel", kind = "menu", onClick = function() posOverlay:setVisible(false) end },
  })

  local function startSetPos()
    local id = currentId
    if not id then return end
    local p = currentItem and currentItem.pos
    posDraft = { x = p and tostring(round(p.x)) or "", y = p and tostring(round(p.y)) or "", z = p and tostring(round(p.z)) or "" }
    renderPosForm()
    posOverlay:setVisible(true)
  end

  local function startSetInterval()
    local id = currentId
    if not id then return end
    keypad.show({ title = "INTERVAL", mode = "num", value = "", onOk = function(s)
      local n = M.parseNum(s)
      if n ~= nil then M._onSetInterval(runtime, id, n, nowMs()) end
    end })
  end

  local function startRename()
    local id = currentId
    if not id then return end
    keypad.show({ title = "NAME", mode = "name", value = (currentItem and currentItem.name) or "", onOk = function(name)
      if name ~= nil and name ~= "" then M._onRename(runtime, id, name) end
    end })
  end

  local function doRemove()
    if not currentId then return end
    M._onRemove(runtime, currentId)
    if opts.onBack then opts.onBack() end
  end

  -- UPDATE folds launchers/beaconupdate.lua's retired standalone updater into this per-beacon
  -- button (Phase P6). Rebooting the beacon is destructive, so it needs a confirm step, same
  -- two-tap idiom as the roster's UPDATE ALL: first click arms (label -> CONFIRM?), a second click
  -- while armed sends via M._onUpdate then disarms. `grid` is forward-declared -- startUpdate reads
  -- grid.buttons.update (assigned once configkit.menuColumn builds it, below) only when actually
  -- clicked, by which point construction has finished.
  local grid
  local updateArmed = false
  local function startUpdate()
    local id = currentId
    if not id then return end
    if updateArmed then
      updateArmed = false
      grid.buttons.update.setLabel("UPDATE")
      M._onUpdate(runtime, id, nowMs())
    else
      updateArmed = true
      grid.buttons.update.setLabel("CONFIRM?")
    end
  end

  grid = configkit.menuColumn(frame, {
    y = gridY, cols = 3,
    items = {
      { id = "enable",  label = "ENABLE",   kind = "function", onClick = function() if currentId then M._onEnable(runtime, currentId, nowMs()) end end },
      { id = "disable", label = "DISABLE",  kind = "function", onClick = function() if currentId then M._onDisable(runtime, currentId, nowMs()) end end },
      { id = "verify",  label = "VERIFY",   kind = "function", onClick = function() if currentId then M._onVerify(runtime, currentId, nowMs()) end end },
      { id = "reboot",  label = "REBOOT",   kind = "function", onClick = function() if currentId then M._onReboot(runtime, currentId, nowMs()) end end },
      { id = "setpos",  label = "SET POS",  kind = "function", onClick = startSetPos },
      { id = "setint",  label = "SET INT",  kind = "function", onClick = startSetInterval },
      { id = "rename",  label = "RENAME",   kind = "function", onClick = startRename },
      { id = "pinexp",  label = "PIN EXP",  kind = "function", onClick = function() if currentId then M._onPinExpected(runtime, currentId, currentItem and currentItem.pos) end end },
      { id = "update",  label = "UPDATE",   kind = "function", onClick = startUpdate },
      { id = "remove",  label = "REMOVE",   kind = "function", onClick = doRemove },
    },
  })

  local backRow = configkit.actionRow(frame, { x = 1, y = h, w = w }, {
    { label = "BACK", id = "back", kind = "menu", onClick = function() if opts.onBack then opts.onBack() end end },
  })

  local function render()
    local name, idLine = M.detailHeaderLines(currentItem, currentId)
    nameLbl:setText(name)
    idLbl:setText(idLine)
    local lines = M.detailLines(currentItem)
    for i = 1, 7 do infoLbls[i]:setText(lines[i] or "") end
  end

  --- apply(view, id): repaint from runtime:view(now)'s list + the id currently on screen. Idempotent;
  --- never touches peripherals. Navigating to a different beacon (or away entirely) disarms a
  --- pending UPDATE confirm -- a confirm armed for one beacon must never fire against another.
  local function apply(view, id)
    if id ~= currentId and updateArmed then
      updateArmed = false
      grid.buttons.update.setLabel("UPDATE")
    end
    currentId = id
    currentItem = M.findItem(view, id)
    render()
  end

  apply({}, nil)

  return {
    id = "detail",
    apply = apply,
    elements = {
      nameLbl = nameLbl, idLbl = idLbl, infoLbls = infoLbls,
      divTop = divTop, divMid = divMid,
      grid = grid, backRow = backRow, keypad = keypad,
      posOverlay = posOverlay, posXBtn = xBtn, posYBtn = yBtn, posZBtn = zBtn, posActionRow = posActionRow,
      current = function() return currentId end,
    },
  }
end

-- ===== M.buildApp: wires the ROSTER + DIAG + DETAIL pages together (Phases P5b/P5c) =====
--
-- M.buildApp(basalt, base, runtime, opts) -> { apply(view), poll(now), elements }
-- Builds all three pages as sibling full-size child frames on `base` (roster visible, diag + detail
-- hidden, mirroring ui/basalt/region.lua's build-both/toggle-visibility idiom, but hand-rolled here
-- since none of the three needs its own internal nav stack). The roster's DIAG button shows the
-- diag frame and opens controller/diag.lua's poll gate; the diag page's BACK button reverses both.
-- Selecting a roster row (M.build's opts.onRowSelect) opens the DETAIL page for that beacon id;
-- DETAIL's BACK (and REMOVE, which has nothing left to show once it succeeds) return to the
-- roster. `poll(now)` forwards to the gate -- the ONLY path to runtime:queryAll, and only while the
-- diag page is shown (M.run calls this from its existing ~1s timer coroutine, right alongside
-- repaint -- no new loop).
function M.buildApp(basalt, base, runtime, opts)
  opts = opts or {}
  local w, h = base:getSize()
  local rosterFrame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  local diagFrame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  local detailFrame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  diagFrame:setVisible(false)
  detailFrame:setVisible(false)

  local gate = Diag.new(opts.diag)
  local lastView = {}
  local currentDetailId = nil
  local detailHandle -- forward-declared: showDetail/hideDetail close over it, assigned below

  local function showDiag()
    gate:show()
    rosterFrame:setVisible(false)
    diagFrame:setVisible(true)
  end
  local function hideDiag()
    gate:hide()
    diagFrame:setVisible(false)
    rosterFrame:setVisible(true)
  end

  local function showDetail(id)
    currentDetailId = id
    rosterFrame:setVisible(false)
    diagFrame:setVisible(false)
    detailFrame:setVisible(true)
    if detailHandle then detailHandle.apply(lastView, currentDetailId) end
  end
  local function hideDetail()
    currentDetailId = nil
    detailFrame:setVisible(false)
    rosterFrame:setVisible(true)
  end

  local rosterHandle = M.build(basalt, rosterFrame, runtime, { onDiag = showDiag, onRowSelect = showDetail })
  local diagHandle = M.buildDiag(basalt, diagFrame, runtime, { onBack = hideDiag })
  detailHandle = M.buildDetail(basalt, detailFrame, runtime, { onBack = hideDetail })

  --- apply(view): repaints ALL THREE pages from the same runtime:view(now) list (cheap Label/Image
  --- writes, no peripheral access) -- so whichever one is visible is always current, and switching
  --- never shows stale data while a hidden page waits for its next tick.
  local function apply(view)
    lastView = view or {}
    rosterHandle.apply(lastView)
    diagHandle.apply(lastView, gate:isShown())
    detailHandle.apply(lastView, currentDetailId)
  end

  --- poll(now): the app's ONE call site for controller/diag.lua's gate -- a true no-op whenever the
  --- diag page isn't shown (see controller/diag.lua + tests/test_controller_diag.lua).
  local function poll(now)
    return gate:poll(runtime, now)
  end

  apply({})

  return {
    id = "app",
    apply = apply,
    poll = poll,
    gate = gate,
    showDiag = showDiag,
    hideDiag = hideDiag,
    showDetail = showDetail,
    hideDetail = hideDetail,
    elements = {
      roster = rosterHandle, diag = diagHandle, detail = detailHandle,
      rosterFrame = rosterFrame, diagFrame = diagFrame, detailFrame = detailFrame,
    },
  }
end

-- ===== M.run: top-level controller entry point (IN-GAME ONLY) =====
--
-- basalt.run() blocks on os.pullEventRaw() forever -- NEVER call this from a test (same rule as
-- every ui/basalt/*.lua page's M.build*/M.run header notes).
--
-- Find the ender/wireless modem (mirrors beacon/app.lua's findModem -- no configurable side here;
-- the controller has no modemSide setting), open the configured channel, build the Runtime
-- (controller/runtime.lua) over it, then run:
--   * a modem_message listener -> rt:onMessage(...) -> repaint on a match (roster changes land
--     immediately, not just on the 1s tick);
--   * a ~1s timer that drives BOTH the DIAG poll gate (M.buildApp's handle.poll -- a true no-op
--     whenever the DIAG page isn't shown, controller/diag.lua) and the repaint.
-- Both live in their own basalt.schedule() coroutine using os.pullEvent/sleep -- event-driven, never
-- a busy loop -- while basalt.run()'s own dispatcher concurrently services button clicks. Active
-- polling (queryAll) is DIAG-only (P5b) and rate-gated -- see controller/diag.lua; the roster and
-- every other view stay purely passive.
local function findModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m.isWireless and m.isWireless() then return m end
    end
  end
  return nil
end

-- ===== M.ensureBasalt: load the vendored Basalt 2.0 build =====
--
-- Mirrors nav/app.lua's own M.ensureBasalt -- deliberately NOT required from ui.basalt.app,
-- which would drag that module's top-level requires (the whole cockpit page registry PLUS the
-- fcs comms/flight-loop stack) into the beaconcontrol role's require() dependency closure
-- (tools/closure.lua just follows require() text statically; it does not care that only that
-- module's ensureBasalt function would ever actually be called). loadfile(path, nil,
-- _ENV), never dofile(): CC:Tweaked's dofile loads with the BIOS's bare _G (no require/
-- package), and the vendored bundle needs package.path for its own module loader. The
-- beaconcontrol role ships release/basalt-full.lua via gen_manifest's extraFiles (same as ui/
-- nav), so a candidate path always exists on a real install.
M.BASALT_PATHS = { "/basalt-full.lua", "/release/basalt-full.lua" }

function M.ensureBasalt(opts)
  opts = opts or {}
  local paths = opts.paths or M.BASALT_PATHS
  local exists = opts.exists or fs.exists
  local doLoadfile = opts.loadfile or loadfile
  for _, path in ipairs(paths) do
    if exists(path) then
      local chunk, err = doLoadfile(path, nil, _ENV)
      if not chunk then error("Basalt did not parse: " .. tostring(err)) end
      local ok, basalt = pcall(chunk)
      if not ok or type(basalt) ~= "table" then error("Basalt failed to load: " .. tostring(basalt)) end
      return basalt
    end
  end
  error("Basalt not found -- reinstall the beaconcontrol role via the Suite")
end

function M.run(deps)
  deps = deps or {}

  local saved = Config.load(Config.PATH)
  local cfg = Config.withDefaults(saved or {})

  local modem = deps.modem or findModem()
  if modem then modem.open(cfg.channel) end

  local rt = deps.runtime or Runtime.new({ config = cfg, modem = modem, now = function() return os.epoch("utc") end })

  local basalt = M.ensureBasalt(deps.basaltOpts)
  Theme.applyTheme(basalt, Theme.DEFAULTS)
  Theme.applyPalette(term, Theme.DEFAULTS)

  local base = basalt.getMainFrame()
  local handle = M.buildApp(basalt, base, rt)

  local function repaint()
    handle.apply(rt:view(os.epoch("utc")))
  end
  repaint()

  basalt.schedule(function()
    while true do
      local _, _, ch, replyCh, msg, dist = os.pullEvent("modem_message")
      local matched = rt:onMessage(ch, replyCh, msg, dist, os.epoch("utc"))
      if matched then repaint() end
    end
  end)

  basalt.schedule(function()
    while true do
      sleep(1)
      -- gate on the SAME shown flag M.buildApp's DIAG button/back control drive: poll() is a true
      -- no-op unless the DIAG page is currently shown (controller/diag.lua) -- no other call site
      -- reaches runtime:queryAll.
      handle.poll(os.epoch("utc"))
      repaint()
    end
  end)

  basalt.run()
end

return M
