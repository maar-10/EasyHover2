-- ui/basalt/pages/nav.lua
-- NAV cockpit page: placeholder navigation/routing interface.
-- This page establishes the nav-aware build signature: M.build(basalt, frame, runtime, nav)
-- with a `nav` parameter (per-monitor navigation stack) that navigating pages (BIT/CONFIG hub,
-- sub-menus, etc.) will use to push/pop screens on the stack.
--
-- Current content: a placeholder body Label + one enabled [BIT/CONFIG] Button that pushes
-- "bitconfig" onto the nav stack. Future expansion: map/route visualization, flight plan UI.
--
-- Follows the Task 15 template EXACTLY (see ui/basalt/pages/emc.lua's header comment for the
-- full Basalt API provenance notes -- not re-derived here): module exports `M.id`, `M.title`,
-- a Basalt-free testable `M._onButton(nav, id, now)` intent seam, and `M.build(basalt,
-- frame, runtime, nav) -> { id, apply(state), elements }` with an idempotent apply() that only
-- reads `state` (the canonical flat cadence state -- ui/basalt/app.lua:M.buildState) and never
-- polls peripherals.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/M._onButton/the
-- apply() closure, so `require("ui.basalt.pages.nav")` loads clean headless.

local Region    = require("ui.basalt.region")
local WL        = require("ui.basalt.waypointlist")
local W         = require("nav.waypoints")
local configkit = require("ui.basalt.configkit")
local Picker    = require("ui.basalt.listpicker")
local Keypad    = require("ui.basalt.keypad")

local M = {}
M.id = "nav"
M.title = "NAV"

-- ===== M._wptArgs: PURE builder of the wpt_op the WPT EDIT actions send to the NAV PC. =====
-- kind: "addHere" (copy craft GPS pos), "addManual" (parse form x/y/z), "edit" (fields onto the
-- selected name), "delete" (the selected name). `form` = {name,x,y,z,type} strings, `craft` =
-- {x,y,z} the current fix (addHere only), `selectedName` = the list-selected waypoint (edit/delete).
-- Returns { op, args } or nil, err. No Basalt/peripherals.
function M._wptArgs(kind, form, craft, selectedName)
  form = form or {}
  local function num(s) return tonumber(s) end
  if kind == "addHere" then
    if type(form.name) ~= "string" or form.name == "" then return nil, "name required" end
    if not (craft and type(craft.x) == "number" and type(craft.y) == "number" and type(craft.z) == "number") then
      return nil, "no GPS fix"
    end
    return { op = "addWpt", args = { name = form.name, x = craft.x, y = craft.y, z = craft.z, type = form.type } }
  elseif kind == "addManual" then
    if type(form.name) ~= "string" or form.name == "" then return nil, "name required" end
    local x, y, z = num(form.x), num(form.y), num(form.z)
    if not (x and y and z) then return nil, "x/y/z must be numbers" end
    return { op = "addWpt", args = { name = form.name, x = x, y = y, z = z, type = form.type } }
  elseif kind == "edit" then
    if not selectedName then return nil, "select a waypoint" end
    local fields = {}
    if num(form.x) then fields.x = num(form.x) end
    if num(form.y) then fields.y = num(form.y) end
    if num(form.z) then fields.z = num(form.z) end
    if form.type then fields.type = form.type end
    if type(form.name) == "string" and form.name ~= "" then fields.name = form.name end
    return { op = "editWpt", args = { name = selectedName, fields = fields } }
  elseif kind == "delete" then
    if not selectedName then return nil, "select a waypoint" end
    return { op = "deleteWpt", args = { name = selectedName } }
  end
  return nil, "unknown action"
end

function M._emptyDraft()
  return { name = "", x = "", y = "", z = "", type = "base", kind = "add", selectedName = nil }
end

function M._draftFromWpt(wpt)
  if type(wpt) ~= "table" then return M._emptyDraft() end
  return {
    name = tostring(wpt.name or ""),
    x = tostring(wpt.x or ""), y = tostring(wpt.y or ""), z = tostring(wpt.z or ""),
    type = wpt.type or "base", kind = "edit", selectedName = wpt.name,
  }
end

function M._nextType(cur)
  for i, tp in ipairs(W.TYPES) do
    if tp == cur then return W.TYPES[(i % #W.TYPES) + 1] end
  end
  return W.TYPES[1]
end

function M._hereName(store)
  local n = 1
  while W.find(store or { waypoints = {} }, "here" .. n) do n = n + 1 end
  return "here" .. n
end

-- ===== M._onButton: the TESTABLE intent seam. No Basalt here. =====
--
-- Navigational intent dispatch: button presses that affect the nav stack.
-- If id == "bitconfig", push "bitconfig" onto the nav stack and return the id.
-- All other ids return nil (no effect).
--
-- Guard: nav must be present (a Nav instance from ui/basalt/nav.lua).
function M._onButton(nav, id, now)
  if not nav then return nil end
  if id == "bitconfig" then
    nav:push("bitconfig")
    return "bitconfig"
  end
  return nil
end

-- ===== M.build: NAV menu -- a region.lua drilldown (navmain + wptedit) over the NAV-PC store. =====
-- The store is read from runtime.wptClient.store (the sync client cache); mutations go through
-- client:mutate (the NAV PC persists + replies). Selecting a waypoint sets runtime.nav.target for
-- the PFD steering cue (Task 1d). NO peripheral access -- only the cached store + the fix state.

function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local activeType = "all"

  local function client() return runtime and runtime.wptClient end
  local function store() local c = client(); return (c and c.store) or { waypoints = {}, routes = {} } end

  -- Craft position for "ADD here": x/z from the NAV fix, y from the FCS baro (true-Y) telemetry.
  local function craftPos()
    local nv = (runtime and runtime.nav) or {}
    if type(nv.fixX) ~= "number" or type(nv.fixZ) ~= "number" then return nil end
    local latest = (runtime and runtime.rx and runtime.rx:latest()) or {}
    return { x = nv.fixX, y = latest.altitude or 0, z = nv.fixZ }
  end

  local function sendMutation(kind, form, selectedName)
    local eff = M._wptArgs(kind, form, craftPos(), selectedName)
    if eff and client() then client():mutate(eff.op, eff.args) end
    return eff
  end

  local function mutateOp(op, args) if client() then client():mutate(op, args) end end

  local function bump() if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end end
  local draft = M._emptyDraft()
  local selectedName = nil
  -- No "NAV" header row -- it wasted a line; the region uses the full frame above the BIT/CONFIG row.

  -- ---------- navmain: action row + type-filter row + waypoint list ----------
  local function buildNavmain(b, f, region)
    local fw, fh = f:getSize()
    local refresh   -- forward decl (filter buttons call it)

    -- Short labels that fit their cell without fitLabel truncation, + a 1-col gap so the buttons
    -- read as separate cells instead of one merged bar.
    local actionRow = configkit.actionRow(f, { x = 1, y = 1, w = fw, gap = 1 }, {
      { label = "WPT", onClick = function() region:push("wptedit") end },
      { label = "RT",  onClick = function() region:push("rtedit") end },
      { label = "DTC", onClick = function() region:push("dtc") end },
    })

    -- Filter: ONE full-width cycling button. Five tiny type buttons were unreadable on a narrow
    -- monitor (OUT/FAC/POI truncated to ~T/~C/~I); a single button shows the FULL type name and
    -- clicking cycles all -> base -> outpost -> facility -> poi -> all.
    local FILTER_CYCLE = { "all", "base", "outpost", "facility", "poi" }
    local filterBtn = f:addButton({ x = 1, y = 2, width = fw, height = 1, text = "FILTER: " .. activeType })
    filterBtn:onClick(function()
      local i = 1
      for k, tp in ipairs(FILTER_CYCLE) do if tp == activeType then i = k end end
      activeType = FILTER_CYCLE[(i % #FILTER_CYCLE) + 1]
      filterBtn:setText("FILTER: " .. activeType)
      refresh()
    end)

    local listTop = 3
    local listH = math.max(4, fh - listTop + 1)
    local listFrame = f:addFrame({ x = 1, y = listTop, width = fw, height = listH })
    local list = WL.make(listFrame, { rows = math.max(1, listH - 1), selColor = colors.green,
      onSelect = function(it)
        if runtime then runtime.nav = runtime.nav or {}; runtime.nav.target = it end   -- PFD target (task 1d)
        bump()
      end })

    refresh = function() list.setItems(W.filter(store(), activeType)) end
    refresh()

    return { apply = function(_s) refresh() end,
      elements = { actionRow = actionRow, filterBtn = filterBtn, list = list } }
  end

  -- ---------- wptedit: HERE / MAN / EDIT / DEL + list. MAN/EDIT drill into wptform. ----------
  local function buildWptedit(b, f, region)
    local fw, fh = f:getSize()
    local refresh

    local actionRow = configkit.actionRow(f, { x = 1, y = 1, w = fw, gap = 1 }, {
      { label = "HERE", onClick = function()
          sendMutation("addHere", { name = M._hereName(store()), type = "base" })
          refresh()
        end },
      { label = "MAN",  onClick = function()
          draft = M._emptyDraft()
          region:push("wptform")
        end },
      { label = "EDIT", onClick = function()
          local wpt = selectedName and W.find(store(), selectedName)
          if not wpt then return end
          draft = M._draftFromWpt(wpt)
          region:push("wptform")
        end },
      { label = "DEL",  onClick = function()
          sendMutation("delete", {}, selectedName)
          selectedName = nil
          draft = M._emptyDraft()
          refresh()
        end },
    })

    local listTop = 2
    local listH = math.max(3, fh - listTop)
    local listFrame = f:addFrame({ x = 1, y = listTop, width = fw, height = listH })
    local list = WL.make(listFrame, { rows = math.max(1, listH - 1), selColor = colors.green,
      onSelect = function(it) selectedName = it and it.name or nil end })

    local backRow = configkit.actionRow(f, { x = 1, y = fh, w = fw }, {
      { label = "< BACK", onClick = function() region:pop() end },
    })

    refresh = function() list.setItems(W.filter(store(), "all")) end
    refresh()

    return { apply = function(_s) refresh() end,
      elements = { actionRow = actionRow, list = list, backRow = backRow } }
  end

  -- ---------- wptform: tap NAME (keypad), TYPE (cycle), X/Y/Z (numpad); SAVE / BACK ----------
  local function buildWptform(b, f, region)
    local fw, fh = f:getSize()
    local refresh
    local keypad = Keypad.make(f)
    local labelW = math.max(4, math.min(6, math.floor(fw * 0.25)))
    local dropW = math.max(1, fw - labelW - 1)
    local dropX = 1 + labelW + 1

    local function fieldRow(labelText, y)
      local lbl = f:addLabel({ x = 1, y = y, width = labelW, height = 1, autoSize = false, text = labelText })
      local btn = f:addButton({ x = dropX, y = y, width = dropW, height = 1, text = "" })
      return lbl, btn
    end

    local nameLbl, nameBtn = fieldRow("NAME", 1)
    local typeLbl, typeBtn = fieldRow("TYPE", 2)
    local xLbl, xBtn = fieldRow("X", 3)
    local yLbl, yBtn = fieldRow("Y", 4)
    local zLbl, zBtn = fieldRow("Z", 5)

    nameBtn:onClick(function()
      keypad.show({ title = "NAME", mode = "name", value = draft.name,
        onOk = function(v) draft.name = v; refresh() end })
    end)
    typeBtn:onClick(function() draft.type = M._nextType(draft.type); refresh() end)
    xBtn:onClick(function()
      keypad.show({ title = "X", mode = "num", value = draft.x,
        onOk = function(v) draft.x = v; refresh() end })
    end)
    yBtn:onClick(function()
      keypad.show({ title = "Y", mode = "num", value = draft.y,
        onOk = function(v) draft.y = v; refresh() end })
    end)
    zBtn:onClick(function()
      keypad.show({ title = "Z", mode = "num", value = draft.z,
        onOk = function(v) draft.z = v; refresh() end })
    end)

    local saveRow = configkit.actionRow(f, { x = 1, y = 6, w = fw }, {
      { label = "SAVE", onClick = function()
          local kind = (draft.kind == "edit") and "edit" or "addManual"
          local eff = sendMutation(kind, draft, draft.selectedName)
          if eff then draft = M._emptyDraft(); region:pop() end
        end },
    })
    local backRow = configkit.actionRow(f, { x = 1, y = fh, w = fw }, {
      { label = "< BACK", onClick = function() region:pop() end },
    })

    refresh = function()
      nameBtn:setText(draft.name ~= "" and draft.name or "...")
      typeBtn:setText(draft.type or "base")
      xBtn:setText(draft.x ~= "" and draft.x or "...")
      yBtn:setText(draft.y ~= "" and draft.y or "...")
      zBtn:setText(draft.z ~= "" and draft.z or "...")
    end
    refresh()

    return { apply = function(_s) refresh() end,
      elements = {
        nameLbl = nameLbl, nameBtn = nameBtn, typeLbl = typeLbl, typeBtn = typeBtn,
        xLbl = xLbl, xBtn = xBtn, yLbl = yLbl, yBtn = yBtn, zLbl = zLbl, zBtn = zBtn,
        saveRow = saveRow, backRow = backRow, keypad = keypad,
      } }
  end

  -- ---------- dtc: NAV-PC disk courier (scan / import / export / clean) ----------
  local function buildDtc(b, f, region)
    local fw, fh = f:getSize()
    f:addLabel({ x = 1, y = 1, width = fw, height = 1, autoSize = false, text = "DTC - NAV disk" })
    local function disk(op) if client() then client():diskOp(op) end end
    local row1 = configkit.actionRow(f, { x = 1, y = 2, w = fw }, {
      { label = "SCAN",   onClick = function() disk("scan") end },
      { label = "IMPORT", onClick = function() disk("import") end },
    })
    local row2 = configkit.actionRow(f, { x = 1, y = 3, w = fw }, {
      { label = "EXPORT", onClick = function() disk("export") end },
      { label = "CLEAN",  onClick = function() disk("clean") end },
    })
    local resultLabel = f:addLabel({ x = 1, y = 5, width = fw, height = 1, autoSize = false, text = "" })
    local backRow = configkit.actionRow(f, { x = 1, y = fh, w = fw }, {
      { label = "< BACK", onClick = function() region:pop() end },
    })
    local function refresh()
      local c = client()
      local ld = c and c.lastDisk
      if ld and ld.op == "scan" and ld.result then
        resultLabel:setText(ld.result.valid and "disk: valid nav file"
          or (ld.result.hasDisk and "disk: foreign file" or "disk: no nav file"))
      elseif ld then
        resultLabel:setText(tostring(ld.op) .. ": " .. (ld.ok and "ok" or tostring(ld.err or "fail")))
      else
        resultLabel:setText((c and c.online) and "ready" or "NAV offline")
      end
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { row1 = row1, row2 = row2, resultLabel = resultLabel, backRow = backRow } }
  end

  -- ---------- rtedit: routes (blue) -- a nested drilldown routes -> legs ----------
  local function buildRtedit(b, f, region)
    local openRoute = nil   -- the route being edited on the legs screen

    -- routes screen: the route list + NEW / DEL / OPEN / ACTIVATE
    local function buildRoutes(bb, ff, inner)
      local ffw, ffh = ff:getSize()
      local sel, refresh = nil, nil
      local row1 = configkit.actionRow(ff, { x = 1, y = 1, w = ffw }, {
        { label = "NEW", onClick = function()
            mutateOp("addRoute", { name = "route" .. (#(store().routes or {}) + 1) }); refresh() end },
        { label = "DEL", onClick = function() if sel then mutateOp("deleteRoute", { name = sel }); sel = nil end; refresh() end },
      })
      local row2 = configkit.actionRow(ff, { x = 1, y = 2, w = ffw }, {
        { label = "OPEN", onClick = function() if sel then openRoute = sel; inner:push("legs") end end },
        { label = "ACT",  onClick = function()
            if sel and runtime then runtime.nav = runtime.nav or {}
              runtime.nav.routeActive = { name = sel, i = 1 }; runtime.nav.target = nil; bump() end end },
      })
      local listFrame = ff:addFrame({ x = 1, y = 3, width = ffw, height = math.max(3, ffh - 3) })
      local list = WL.make(listFrame, { rows = math.max(1, ffh - 4), selColor = colors.blue,
        fmt = function(r) return tostring(r.name) end, onSelect = function(r) sel = r and r.name or nil end })
      local backRow = configkit.actionRow(ff, { x = 1, y = ffh, w = ffw }, {
        { label = "< BACK", onClick = function() region:pop() end } })
      refresh = function() list.setItems(store().routes or {}) end
      refresh()
      return { apply = function(_s) refresh() end, elements = { row1 = row1, row2 = row2, list = list, backRow = backRow } }
    end

    -- legs screen: the open route's legs + ADD LEG (waypoint picker) / DEL / ALT-+ / UP / DN
    local function buildLegs(bb, ff, inner)
      local ffw, ffh = ff:getSize()
      local selLeg, refresh = nil, nil
      local picker = Picker.make(ff)
      local function route() return W.findRoute(store(), openRoute) end
      local function legAlt(i, d)
        local r = route(); local leg = r and r.legs[i]
        if leg then mutateOp("editLegAlt", { route = openRoute, i = i, alt = (leg.alt or 0) + d }); refresh() end
      end
      local row1 = configkit.actionRow(ff, { x = 1, y = 1, w = ffw }, {
        { label = "ADD", onClick = function()
            local opts = {}
            for _, wp in ipairs(store().waypoints or {}) do opts[#opts + 1] = { text = wp.name .. "  " .. wp.type, value = wp.name } end
            picker.show({ title = "add leg wpt", options = opts,
              onPick = function(name) mutateOp("addLeg", { route = openRoute, wpt = name }); refresh() end })
          end },
        { label = "DEL", onClick = function() if selLeg then mutateOp("deleteLeg", { route = openRoute, i = selLeg }); selLeg = nil; refresh() end end },
      })
      local row2 = configkit.actionRow(ff, { x = 1, y = 2, w = ffw }, {
        { label = "ALT-", onClick = function() if selLeg then legAlt(selLeg, -5) end end },
        { label = "ALT+", onClick = function() if selLeg then legAlt(selLeg, 5) end end },
        { label = "UP",   onClick = function() if selLeg then mutateOp("moveLeg", { route = openRoute, i = selLeg, dir = -1 }); selLeg = math.max(1, selLeg - 1); refresh() end end },
        { label = "DN",   onClick = function() if selLeg then mutateOp("moveLeg", { route = openRoute, i = selLeg, dir = 1 })
            -- Clamp like UP does: an unclamped +1 walked the selection past the last leg, and
            -- DEL/moveLeg then targeted a nonexistent index (server rejects, selection drifts).
            local r = route(); local n = (r and r.legs) and #r.legs or selLeg
            selLeg = math.min(n, selLeg + 1); refresh() end end },
      })
      local listFrame = ff:addFrame({ x = 1, y = 3, width = ffw, height = math.max(3, ffh - 3) })
      local list = WL.make(listFrame, { rows = math.max(1, ffh - 4), selColor = colors.blue,
        fmt = function(it) return (it.wpt or "?") .. " @" .. tostring(it.alt) end,
        keyOf = function(it) return it._i end,
        onSelect = function(it) selLeg = it and it._i or nil end })
      local backRow = configkit.actionRow(ff, { x = 1, y = ffh, w = ffw }, {
        { label = "< ROUTES", onClick = function() inner:pop() end } })
      refresh = function()
        local r = route(); local items = {}
        if r then for i, leg in ipairs(r.legs) do items[i] = { wpt = leg.wpt, alt = leg.alt, _i = i } end end
        list.setItems(items)
      end
      refresh()
      return { apply = function(_s) refresh() end, elements = { row1 = row1, row2 = row2, list = list, backRow = backRow } }
    end

    local inner = Region.new(basalt, f, { x = 1, y = 1, width = ({ f:getSize() })[1], height = ({ f:getSize() })[2],
      root = "routes", onNav = bump, screens = { routes = buildRoutes, legs = buildLegs } })
    inner:apply(nil)
    return { apply = function(s) inner:apply(s) end, elements = { inner = inner } }
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 1, width = w, height = math.max(1, h - 1), root = "navmain", onNav = bump,
    screens = { navmain = buildNavmain, wptedit = buildWptedit, wptform = buildWptform, dtc = buildDtc, rtedit = buildRtedit },
  })
  region:apply(nil)

  -- BIT/CONFIG entry (frame-level nav push) -- the NAV page was its only entry; kept reachable at the
  -- bottom row (relocate to CONFIG later if the NAV menu needs the space).
  local bitconfigBtn = frame:addButton({ x = 2, y = h, width = math.max(1, w - 2), height = 1, text = "[BIT/CONFIG]" })
  bitconfigBtn:onClick(function() M._onButton(nav, "bitconfig", os.epoch("utc")) end)

  return { id = M.id, apply = function(state) region:apply(state) end,
    elements = { region = region, bitconfigBtn = bitconfigBtn } }
end

return M
