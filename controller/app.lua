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

-- ===== M._onEnableAll: the TESTABLE intent seam for the ENABLE ALL footer button. No Basalt. =====
--
-- Fail-closed by construction: runtime:sendCommandAll (controller/runtime.lua) itself refuses (no
-- transmit) when the controller has no valid token, so this seam needs no extra gating.
function M._onEnableAll(runtime, now)
  return runtime:sendCommandAll("enable", nil, now)
end

-- ===== M.build: construct the element tree =====
--
-- M.build(basalt, frame, runtime) -> { apply(view), elements }
-- `runtime` is a controller.runtime instance (R:view/R:sendCommandAll). `apply(view)` takes
-- exactly runtime:view(now)'s return shape -- a list of { id, name, pos, ageMs, status, ... },
-- already sorted by id -- and repaints the roster; idempotent, never touches peripherals.
function M.build(basalt, frame, runtime)
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

  local actionRow = configkit.actionRow(frame, { x = 1, y = actionY, w = w }, {
    -- P5b builds the per-beacon detail/DIAG page; the button exists now so the layout is final,
    -- but stays disabled (no onClick) until that page lands.
    { label = "DIAG",        kind = "menu",     state = "disabled" },
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
--   * a ~1s repaint timer so ages keep ticking between broadcasts even with no traffic.
-- Both live in their own basalt.schedule() coroutine using os.pullEvent/sleep -- event-driven, never
-- a busy loop -- while basalt.run()'s own dispatcher concurrently services button clicks. NO active
-- polling in P5a (queryAll is DIAG-only, P5b): passive listening only.
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
  local w, h = base:getSize()
  local frame = base:addFrame({ x = 1, y = 1, width = w, height = h })
  local handle = M.build(basalt, frame, rt)

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
      repaint()
    end
  end)

  basalt.run()
end

return M
