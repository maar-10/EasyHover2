-- controller/app.lua
-- GPS beacon controller: Basalt 2.0 shell UI on an advanced computer terminal (native 51x19, no
-- monitor scaling), wired to the P3b controller.runtime. Phase P5a builds the app skeleton PLUS the
-- ROSTER page only -- per-beacon detail + DIAG are P5b, UPDATE ALL (folding the standalone updater
-- in) is P6. Follows ui/basalt/pages/*.lua's exact contract: M.build(basalt, frame, runtime) ->
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

-- ===== M._onEnableAll: the TESTABLE intent seam for the ENABLE ALL footer button. No Basalt. =====
--
-- Fail-closed by construction: runtime:sendCommandAll (controller/runtime.lua) itself refuses (no
-- transmit) when the controller has no valid token, so this seam needs no extra gating.
function M._onEnableAll(runtime, now)
  return runtime:sendCommandAll("enable", nil, now)
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

  local actionRow = configkit.actionRow(frame, { x = 1, y = actionY, w = w }, {
    diagSpec,
    { label = "ENABLE ALL",  kind = "function", onClick = function() M._onEnableAll(runtime, os.epoch("utc")) end },
    -- P6 folds launchers/beaconupdate.lua's standalone updater into this button; stays disabled
    -- (no onClick) until then -- "set channel" is deliberately never offered here (design §3.2).
    { label = "UPDATE ALL",  kind = "function", state = "disabled" },
  })

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

-- ===== M.buildApp: wires the ROSTER + DIAG pages together (Phase P5b) =====
--
-- M.buildApp(basalt, base, runtime, opts) -> { apply(view), poll(now), elements }
-- Builds both pages as sibling full-size child frames on `base` (roster visible, diag hidden,
-- mirroring ui/basalt/region.lua's build-both/toggle-visibility idiom, but hand-rolled here since
-- neither page needs its own internal nav stack). The roster's DIAG button shows the diag frame
-- and opens controller/diag.lua's poll gate; the diag page's BACK button reverses both. `poll(now)`
-- forwards to the gate -- the ONLY path to runtime:queryAll, and only while the diag page is shown
-- (M.run calls this from its existing ~1s timer coroutine, right alongside repaint -- no new loop).
function M.buildApp(basalt, base, runtime, opts)
  opts = opts or {}
  local w, h = base:getSize()
  local rosterFrame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  local diagFrame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  diagFrame:setVisible(false)

  local gate = Diag.new(opts.diag)
  local lastView = {}

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

  local rosterHandle = M.build(basalt, rosterFrame, runtime, { onDiag = showDiag })
  local diagHandle = M.buildDiag(basalt, diagFrame, runtime, { onBack = hideDiag })

  --- apply(view): repaints BOTH pages from the same runtime:view(now) list (cheap Label/Image
  --- writes, no peripheral access) -- so whichever one is visible is always current, and switching
  --- never shows stale data while a hidden page waits for its next tick.
  local function apply(view)
    lastView = view or {}
    rosterHandle.apply(lastView)
    diagHandle.apply(lastView, gate:isShown())
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
    elements = {
      roster = rosterHandle, diag = diagHandle,
      rosterFrame = rosterFrame, diagFrame = diagFrame,
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

function M.run(deps)
  deps = deps or {}
  local BasaltApp = require("ui.basalt.app")

  local saved = Config.load(Config.PATH)
  local cfg = Config.withDefaults(saved or {})

  local modem = deps.modem or findModem()
  if modem then modem.open(cfg.channel) end

  local rt = deps.runtime or Runtime.new({ config = cfg, modem = modem, now = function() return os.epoch("utc") end })

  local basalt = BasaltApp.ensureBasalt(deps.basaltOpts)
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
