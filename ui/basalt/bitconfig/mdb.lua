-- ui/basalt/bitconfig/mdb.lua
-- MDB-CONF sub-menu (BIT/CONFIG hub, screen id "mdb"): the native-Basalt manual device-binding
-- menu. Binds the FCS thruster/sensor slots + fuel relay to peripheral names visible on THIS
-- PC's wired network and saves via ui.basalt.cfgseam -- SAVE ships a `set` to the running FCS
-- (which persists the devbind and materializes the senscal sibling). This is a reskin of the
-- bare terminal tool tools/binddevices.lua (Task 6) -- it REUSES that module's pure
-- M.assign/M.candidates rather than reimplementing them, and a parity test enforces that this
-- menu writes a BYTE-IDENTICAL body to the bare tool for the same assignments.
--
-- Each of the 19 slots is bound via a DROPDOWN (ui/basalt/picker.lua), not a click-to-cycle
-- button -- cycling through abbreviated peripheral names to find the right one in-game proved
-- unusable; a dropdown lets the operator see the whole candidate list and tap the right name.
--
-- Follows the Task 21 (ui/basalt/bitconfig/tuning.lua) template EXACTLY: module exports `M.id`,
-- `M.title`, a Basalt-free PURE view-model (M.SLOTS / M.view / M.pickerOptions / M.applyBinding),
-- a Basalt-free save seam (M._save), and `M.build(basalt, frame, runtime, nav, read, write, scan)
-- -> { id, apply(state), elements }` with an idempotent apply() (config menu, no live telemetry).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.mdb")` loads clean headless.

local cfgspec      = require("fcs.io.cfgspec")
local binddevices   = require("tools.binddevices")
local Picker        = require("ui.basalt.picker")
local configkit      = require("ui.basalt.configkit")
local switchbtn      = require("ui.basalt.switchbtn")
local Region         = require("ui.basalt.region")
local cfgseam        = require("ui.basalt.cfgseam")

local M = {}
M.id = "mdb"
M.title = "MDB-CONF"

-- ===== M.SLOTS: canonical ordered slot list, derived from cfgspec.defaults("devbind") so it =====
-- ===== can never drift from the schema. Sorted per-kind for a stable, predictable page order. =====

local function sortedKeys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function buildSlots()
  local defaults = cfgspec.defaults("devbind")
  local out = {}
  for _, k in ipairs(sortedKeys(defaults.thrusters)) do
    out[#out + 1] = { slotKind = "thruster", slot = k }
  end
  for _, k in ipairs(sortedKeys(defaults.sensors)) do
    out[#out + 1] = { slotKind = "sensor", slot = k }
  end
  out[#out + 1] = { slotKind = "relay", slot = nil }
  return out
end

M.SLOTS = buildSlots()

-- ===== M.GROUPS / M.slotsForGroup: pure grouping of M.SLOTS for the overview->group drilldown. =====
-- Thruster slots are grouped by mixer role, per fcs/frame.lua's own LIFT/LATERAL/MAIN/FRONTAL
-- split (fcs/mixer/level_flight.lua mixes them accordingly): LIFT = the 4 vertical-lift thrusters
-- (FL/FR/RL/RR, mixed from heave+pitch/roll), LATERAL = the 4 lateral thrusters (YFL/YFR/YRL/YRR,
-- mixed from sway+yaw), MAIN/FR = the main + frontal surge thrusters (MAIN forward, FRL/FRR
-- reverse pair) -- combined into one screen since together they're only 3 slots. All sensor slots
-- share one SENSORS screen; the single relay slot gets its own RELAY screen. Every M.SLOTS entry
-- belongs to EXACTLY one group (asserted by a test).
M.GROUPS = { "LIFT", "LATERAL", "MAIN/FR", "SENSORS", "RELAY" }

local THRUSTER_GROUP_KEYS = {
  LIFT        = { FL = true, FR = true, RL = true, RR = true },
  LATERAL     = { YFL = true, YFR = true, YRL = true, YRR = true },
  ["MAIN/FR"] = { MAIN = true, FRL = true, FRR = true },
}

-- M.slotsForGroup(group) -> the subset of M.SLOTS (same {slotKind,slot} row shape, in M.SLOTS'
-- own order) belonging to `group`. Unknown group -> {} (no slots). PURE.
function M.slotsForGroup(group)
  local thrusterKeys = THRUSTER_GROUP_KEYS[group]
  local out = {}
  for _, s in ipairs(M.SLOTS) do
    local belongs
    if s.slotKind == "thruster" then
      belongs = thrusterKeys ~= nil and thrusterKeys[s.slot] == true
    elseif s.slotKind == "sensor" then
      belongs = (group == "SENSORS")
    else -- "relay"
      belongs = (group == "RELAY")
    end
    if belongs then out[#out + 1] = s end
  end
  return out
end

-- Read the current binding for a slot out of a devbind cfg. Nil-safe: an absent/unbound slot
-- reads as `false` (matches cfgspec.defaults("devbind")'s own unbound representation).
local function currentAt(cfg, slotKind, slot)
  local v
  if slotKind == "thruster" then v = cfg.thrusters[slot]
  elseif slotKind == "sensor" then v = cfg.sensors[slot]
  else v = cfg.fuelRelay end
  if v == nil then v = false end
  return v
end

local function labelFor(slotKind, slot)
  if slotKind == "relay" then return "FUEL RELAY" end
  return slotKind:upper() .. " " .. tostring(slot)
end

-- ===== M.view(cfg, descriptors) -> ordered rows. PURE. =====
-- Each row: { slotKind, slot, label, current=<cfg binding, false if unbound>,
--             candidates=<binddevices.candidates(descriptors)[slotKind] or {}> }.
function M.view(cfg, descriptors)
  local candidatesByKind = binddevices.candidates(descriptors or {})
  local rows = {}
  for _, s in ipairs(M.SLOTS) do
    rows[#rows + 1] = {
      slotKind = s.slotKind,
      slot = s.slot,
      label = labelFor(s.slotKind, s.slot),
      current = currentAt(cfg, s.slotKind, s.slot),
      candidates = candidatesByKind[s.slotKind] or {},
    }
  end
  return rows
end

-- ===== M.pickerOptions(candidates) -> ordered Picker options for a slot's dropdown. PURE. =====
-- Always leads with a "(none)" entry whose value is `false` (unbind), followed by one
-- { text = name, value = name } per candidate, in the order binddevices.candidates gave them.
function M.pickerOptions(candidates)
  local opts = { { text = "(none)", value = false } }
  for _, name in ipairs(candidates or {}) do
    opts[#opts + 1] = { text = name, value = name }
  end
  return opts
end

-- ===== cloneCfg: a devbind-shaped copy that preserves cfgspec.save's serialised byte layout. =====
-- A generic recursive `pairs()`-driven deep copy rebuilds tables by incremental key insertion,
-- which measurably reorders CraftOS-PC Lua's internal hash-bucket layout relative to a table
-- built by cfgspec.defaults("devbind")'s own literal constructor -- and textutils.serialise
-- walks that layout, so a naive deep copy silently breaks the MDB<->binddevices parity
-- requirement (verified empirically; see task-22-report.md). Instead, clone by allocating a
-- FRESH cfgspec.defaults("devbind") scaffold (the exact same constructor call the bare
-- tools/binddevices path itself starts from) and overwriting only its EXISTING keys with the
-- source cfg's values -- never inserting a new key, so no rehash, so the byte layout matches.
local function cloneCfg(cfg)
  local out = cfgspec.defaults("devbind")
  for k in pairs(out.thrusters) do
    if cfg.thrusters[k] ~= nil then out.thrusters[k] = cfg.thrusters[k] end
  end
  for k in pairs(out.sensors) do
    if cfg.sensors[k] ~= nil then out.sensors[k] = cfg.sensors[k] end
  end
  if cfg.fuelRelay ~= nil then out.fuelRelay = cfg.fuelRelay end
  return out
end

-- ===== M.applyBinding(cfg, slotKind, slot, value) -> a NEW cfg (cfg NOT mutated) with that =====
-- ===== slot set to `value` (a candidate name, or false to unbind) via binddevices.assign. PURE. =====
-- This is what a dropdown pick applies: the operator taps the exact target name (or "(none)"),
-- so unlike the old click-to-cycle stepper there is no "current -> next" computation here -- the
-- cloneCfg scaffold is still used so the assignment lands on the SAME no-rehash byte layout the
-- bare tools/binddevices path produces (see cloneCfg's comment above; this is what keeps MDB's
-- saved eh2_devbind.tbl byte-identical to the bare tool's for the same assignments).
function M.applyBinding(cfg, slotKind, slot, value)
  local copy = cloneCfg(cfg)
  binddevices.assign(copy, slotKind, slot, value)
  return copy
end

-- ===== M._save: TESTABLE, Basalt-free seam. =====
function M._save(cfg, write)
  return cfgspec.save("devbind", cfg, write)
end

-- ===== live peripheral scan (default injected seam; never called at module load). =====
-- Default read/write now come from cfgseam (FCS cache + cfgClient). scan stays LOCAL -- the
-- operator binds names visible on THIS PC's wired network.

-- Live descriptor scan, {name=, type=} shape -- matches tools/binddevices.lua's buildDescriptors
-- and ui/main.lua's scanDescriptors conventions (methods= is not needed by binddevices.candidates
-- so it's omitted here).
local function realScan()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    out[#out + 1] = { name = name, type = peripheral.getType(name) }
  end
  return out
end

-- ===== M.build: construct the overview->group drilldown element tree =====
-- Each of the 19 slots still gets a Picker (ui/basalt/picker.lua) instead of a CYCLE button (see
-- the header note), but they're no longer one long paged list: ui/basalt/region.lua hosts a
-- 5-group drilldown (M.GROUPS) inside this screen's own nav stack, root "overview" -- the
-- overview screen shows the 5 group buttons + SAVE/RESCAN/BACK, and each group screen shows only
-- that group's bind rows (at most 7, for SENSORS), which is short enough that an open picker
-- overlay always has headroom (fixes the old paged-list's open-dropdown-past-bottom clip).

function M.build(basalt, frame, runtime, nav, read, write, scan)
  -- S2b: read the FCS's live devbind from runtime.cfgCache; SAVE ships a devbind `set` to the FCS
  -- (which persists it and materializes the senscal sibling). scan() stays a LOCAL peripheral scan
  -- -- the operator binds names visible on THIS PC's wired network. Tests inject read/write/scan.
  read = read or cfgseam.read(runtime)
  write = write or cfgseam.write(runtime, function(kind, ok, err)
    if runtime then
      runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
        or ("SAVE FAILED: " .. tostring(err or "no FCS"))
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end
  end)
  scan = scan or realScan

  local descriptors = scan()
  -- Normalise the loaded cfg onto the canonical cloneCfg scaffold immediately, so a SAVE with
  -- zero picks made still lands on the same no-rehash byte layout every onPick keeps it on.
  local workingCfg = cloneCfg((cfgspec.load("devbind", read)))

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = configkit.titleRow(frame, ({ frame:getSize() })[1], M.title)

  -- A region-internal nav push/pop (drilling a group, or backing out of one) isn't a FRAME-level
  -- nav change, so it wouldn't otherwise wake the dirty-gated render loop (ui/basalt/app.lua's
  -- navChanged() only watches frameRec.nav) -- bump runtime.uiRev so the next render-gate tick
  -- picks it up, exactly like ui/basalt/pages/flight.lua's regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- Give the picker a usable width for peripheral names; the trigger truncates ("~tail") anything
  -- longer than fits, per ui/basalt/picker.lua. dropdownHeight is kept modest -- with each group
  -- screen now at most 7 rows tall, an open overlay always has room below it.
  -- Compact picker rows: short label + capped dropdown, centred as a block (not spanning the row).
  local dropW = math.max(6, math.min(12, math.floor(iw * 0.5)))
  local labelW = 8
  local blockX = x + math.max(0, math.floor((iw - (labelW + 1 + dropW)) / 2))
  local dropX = blockX + labelW + 1
  local DROPDOWN_HEIGHT = 5

  -- ===== overview screen: 5 stacked group buttons + a full-width SAVE row, then a RESCAN/BACK row =====
  local function buildOverview(b, f, region)
    local fw = f:getSize()
    local fx = 2
    local fiw = math.max(1, fw - 2)

    local grpItems = {}
    for _, g in ipairs(M.GROUPS) do
      grpItems[#grpItems + 1] = { id = g, label = g, onClick = function() region:push(g) end }
    end
    local grpMenu = configkit.menuColumn(f, { y = 1, items = grpItems })
    local groupBtns = {}
    for _, g in ipairs(M.GROUPS) do groupBtns[g] = grpMenu.buttons[g] end
    local y = grpMenu.nextY

    -- Named (not inline) so a test can invoke the EXACT effect RESCAN's onClick has --
    -- reassign the `descriptors` upvalue every group screen's refresh() reads -- without needing
    -- to click through Basalt (mirrors every other sub-menu's established test convention of
    -- "directly invoke nav:pop() the same way backBtn's onClick does", just for RESCAN).
    local function doRescan()
      descriptors = scan()
    end

    local configkitGlyph = configkit.GLYPH
    local saveRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "SAVE", onClick = function() M._save(workingCfg, write) end },
    })
    y = y + 1
    local footerRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkitGlyph.RESCAN, onClick = doRescan },
      { id = "back", label = configkitGlyph.BACK, onClick = function() if nav then nav:pop() end end },
    })

    -- apply(state): the overview shows only static group labels + action buttons -- nothing here
    -- tracks live cfg state, so a no-op repaint is all that's needed.
    local function apply(_state) end

    return { apply = apply, elements = { groupBtns = groupBtns, saveRow = saveRow, footerRow = footerRow, rescan = doRescan } }
  end

  -- ===== group screen: that group's bind rows (fitLabel'd slot label + picker) + a "<" back =====
  local function buildGroupScreen(groupId)
    return function(b, f, region)
      local fw = f:getSize()
      local fx = 2
      local fiw = math.max(1, fw - 2)

      local slots = M.slotsForGroup(groupId)
      local wanted = {}
      for _, s in ipairs(slots) do wanted[s.slotKind .. ":" .. tostring(s.slot)] = true end

      local rowSlots = {}
      local y = 1
      for i, s in ipairs(slots) do
        local lbl = f:addLabel({ x = blockX, y = y, width = labelW, height = 1, autoSize = false, text = "" })
        local picker = Picker.make(f, {
          x = dropX, y = y, width = dropW, dropdownHeight = DROPDOWN_HEIGHT,
          options = {}, current = false, placeholder = "(none)",
          onPick = function(value)
            workingCfg = M.applyBinding(workingCfg, s.slotKind, s.slot, value)
          end,
        })
        rowSlots[i] = { slotKind = s.slotKind, slot = s.slot, label = lbl, picker = picker }
        y = y + 1
      end

      local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      -- refresh(): idempotent repaint of this group's rows from workingCfg/descriptors, via the
      -- UNCHANGED M.view (filtered down to this group's slots) -- so a group screen's rows are
      -- always exactly what the old flat M.view(workingCfg, descriptors) would have shown for the
      -- same slots, just scoped to one group.
      local function refresh()
        for _, row in ipairs(M.view(workingCfg, descriptors)) do
          if wanted[row.slotKind .. ":" .. tostring(row.slot)] then
            for _, slot in ipairs(rowSlots) do
              if slot.slotKind == row.slotKind and slot.slot == row.slot then
                slot.label:setText(configkit.fitLabel(row.label, labelW))
                slot.picker.setOptions(M.pickerOptions(row.candidates), row.current)
              end
            end
          end
        end
      end

      refresh()

      return { apply = function(_state) refresh() end, elements = { rowSlots = rowSlots, backRow = backRow } }
    end
  end

  local screens = { overview = buildOverview }
  for _, g in ipairs(M.GROUPS) do
    screens[g] = buildGroupScreen(g)
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 3, width = w, height = math.max(1, h - 2),
    root = "overview", screens = screens, onNav = bump,
  })

  -- Force the overview screen to build now (not on the first scheduled apply()), so its elements
  -- (SAVE/RESCAN/BACK, the group buttons) exist as soon as M.build returns -- mirrors the old
  -- code's unconditional refreshPage() call before return.
  region:apply(nil)

  -- apply(state): this menu shows CONFIG, not live telemetry -- forwards to the region, which
  -- lazily builds/shows its current nav top and repaints only that screen. Never polls
  -- peripherals on its own; RESCAN is the only thing that re-reads the peripheral list, and only
  -- on click.
  local function apply(state)
    region:apply(state)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { headerLabel = headerLabel, region = region },
  }
end

return M
