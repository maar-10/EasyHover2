-- ui/basalt/regions/emc.lua
-- EMC region screens for the merged "flight" cockpit page (top region over an FCS region --
-- see docs/superpowers/specs/2026-08-10-eh2-merged-flight-page-design.md). Each screen is a
-- BUILDER `function(basalt, subFrame, region, runtime) -> { apply = function(state) end }`
-- matching ui/basalt/region.lua's contract EXACTLY -- `subFrame:getSize()` gives the region's
-- fixed area (width ~= 14 on the target overhead monitor at text scale 0.5); `region:push(id)` /
-- `region:pop()` drive THIS region's own nav stack.
--
-- Three screens, drilling deeper each time:
--   M.main    ("emc_main")    -- flight-glance: gauges + ENG SW/PRIME + MASTER/FEED lights + CONFIG
--   M.config  ("emc_config")  -- relay/pulse/interval/bind controls, reusing UI CAL's tested seams
--   M.calfuel ("emc_calfuel") -- manual max steppers (no auto-cal) that the gauges divide against
--
-- REUSE, not reimplementation:
--   * ui/basalt/switchbtn.lua's Switch.make/set for the ENG SW color-state button.
--   * ui/basalt/bitconfig/uical.lua's M._onButton for the config-drill button ids that stay
--     buttons (pulseUp/Dn, intervalUp/Dn) via M._cfg below -- NOT "calFuel" (the old single-button
--     auto-cal); this module's own M._setMax is the manual replacement.
--   * ui/basalt/picker.lua's Picker.make + uical.lua's _sideOptions/_fuelCandidates/
--     _relayCandidates/_toOptions/_pickBind/_pickSide for RELAY SIDE and BIND PUMP/TANK/RELAY --
--     DROPDOWNS, not click-to-cycle buttons (cycling abbreviated peripheral names to find the
--     right one proved unusable in-game). These bypass M._cfg/_onButton entirely (a Picker's
--     onPick hands back the tapped value directly, so there's nothing to "cycle to next" through
--     ConfigPanel.action) -- each onPick calls uical's _pickBind/_pickSide then bumps
--     runtime.uiRev itself (see M.config's local `bump()`).
--   * ui/fuel.lua's Fuel.manualFrac for both gauges' fill fraction (amount / config-set max).
--
-- RENDER-PATH DISCIPLINE: apply(state) reads ONLY `state` (the polled cadence snapshot -- already
-- carries pumpAmount/tankMb, ui/basalt/app.lua:M.buildState) and `runtime.config` (edits bump
-- runtime.uiRev, which the cadence gate already keys on) -- it NEVER calls a peripheral or a
-- fuelReader directly. Every apply() is idempotent -- safe to call repeatedly.
--
-- ASCII-ONLY (real CC:Tweaked font has no bullet glyph): the MASTER/FEED "lights" are a 1-char
-- Label whose BACKGROUND is set green/red (a colored block), not a unicode dot, plus a short text
-- label beside it -- verified against ui/basalt/switchbtn.lua's own note on the same point.
--
-- Basalt element/method surface verified against release/basalt-full.lua (not from memory):
--   * Button:render() (release/basalt-full.lua:3980-3984) truncates its OWN text to `width` via
--     `da:sub(1,width)` -- so a bind button's text can safely exceed width; it just clips, no wrap.
--   * Label.autoSize=false (release/basalt-full.lua:4822-4825, see ui/basalt/pages/emc.lua's header
--     note) WRAPS text at the label's current width instead of clipping -- every Label text here is
--     pre-truncated with the local `fit()` helper so a long value can never push later rows down.
--   * addProgressBar/addLabel/addButton/getSize/setProgress/setText/setBackground/setForeground/
--     setEnabled/onClick -- all confirmed call sites already exist in ui/basalt/pages/emc.lua and
--     ui/basalt/bitconfig/uical.lua (same auto-generated Container:add<Element> / defineProperty
--     accessor pattern), reused verbatim here.
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.main/M.config/M.calfuel/
-- M._onEngine/M._cfg/M._setMax, so `require("ui.basalt.regions.emc")` loads clean headless.
local Switch = require("ui.basalt.switchbtn")
local Gfx    = require("ui.basalt.instruments.panelgfx")
local Theme  = require("ui.theme")
local Fuel   = require("ui.fuel")
local Uical  = require("ui.basalt.bitconfig.uical")
local Config = require("ui.config")
local ConfigPanel = require("ui.panels.config")
local btnfit = require("ui.basalt.btnfit")
local EnginePanel = require("ui.panels.engine")
local Gfxpicker = require("ui.basalt.instruments.gfxpicker")
local fueltable = require("fcs.fueltable")

local M = {}

-- Border edges the EMC region draws. Stacked in the merged flight page the FCS region below draws
-- the BOTTOM edge, so the default omits it; a standalone single-region host (ui/basalt/pages/emc.lua)
-- passes opts.edges = a full box to close it. PURE.
M.DEFAULT_EDGES = { top = true, left = true, right = true, bottom = false }
function M._resolveEdges(opts)
  return (opts and opts.edges) or M.DEFAULT_EDGES
end

-- Manual-max stepper sizes: a stack (64) for the solid pump max, one bucket (1000 mB) for the
-- liquid tank max -- pinned constants so M.calfuel's onClick wiring and tests agree on the exact
-- delta without duplicating the literal. Task 4 adds fine (+/-1) and larger liquid batches
-- (50/100 buckets) so the calfuel screen can reach any max quickly without hundreds of taps.
M.SOLID_STEP  = 64
M.LIQUID_STEP = 1000
M.SOLID_FINE  = 1
M.LIQUID_50   = 50000
M.LIQUID_100  = 100000

-- Abbreviated fuel-source names for M.main's two gauge labels (Task 3 fuel-panel redesign).
M.SOLID_ABBR  = "BZC"
M.LIQUID_ABBR = "BDSL"

-- Truncate (never wrap) a Label's text to its element width -- see the header note on
-- Label.autoSize=false's wrap-at-width behaviour. Buttons don't need this (Button:render() already
-- clips its own text), but every Label built below routes through this first.
local function fit(s, w)
  s = tostring(s)
  if type(w) == "number" and w > 0 and #s > w then
    return s:sub(1, w)
  end
  return s
end

-- Standard round-half-up, used for the gauge bars' 0..100 progress value (Basalt's ProgressBar
-- clamps/floors internally, but we round here so e.g. 79.6% shows as 80 not 79).
local function round(x)
  return math.floor((x or 0) + 0.5)
end

-- relayBound: NOT part of the canonical flat cadence state -- derive it from runtime.config.relay
-- at the point of use, exactly like ui/basalt/pages/emc.lua's own relayBound() does (config edits
-- bump uiRev, which forces a repaint through the cadence gate, so this stays fresh).
local function relayBound(runtime)
  -- Prefer the real wrapped-relay flag when app.lua wires it (honest ENG SW: config.relay.name
  -- alone must not green the switch / allow master-on -- the peripheral has to have actually
  -- resolved; isRelayReady() is a pure read, no peripheral call). Fall back to the config name for
  -- headless construction/tests that don't provide isRelayReady.
  if runtime.isRelayReady ~= nil then return runtime.isRelayReady() and true or false end
  local r = runtime.config.relay
  return r ~= nil and r.name ~= nil
end

-- ===== M._onEngine: the TESTABLE intent seam for emc_main's ENG SW / PRIME controls. No Basalt. =====
--
-- id=="engSw" -> toggles the engine master, but ONLY when a relay is bound (gated inert otherwise,
-- no text about it -- per the design). id=="prime" -> forces one manual feed pulse, but ONLY when a
-- relay is bound AND the master is currently on. Returns the action taken ({op=...}) or nil when
-- gated off / an unrecognised id.
function M._onEngine(runtime, id, now)
  if id == "engSw" then
    if not relayBound(runtime) then return nil end
    -- Refuse master-on while FCS reports noFuel; master-off stays allowed.
    local latest = runtime.rx and runtime.rx.latest and runtime.rx:latest()
    if not runtime.engine.master and latest and latest.noFuel then return nil end
    runtime.engine:toggleMaster(now)
    return { op = "toggleMaster" }
  elseif id == "prime" then
    if not relayBound(runtime) then return nil end
    local st = runtime.engine:status(now)
    if not st.master then return nil end
    runtime.engine:feedNow(now)
    return { op = "feedNow" }
  end
  return nil
end

-- ===== M._onFuel: remote fuel-type selection send seam for emc_calfuel's fuel picker. =====
-- Unlike M._onEngine's LOCAL engine controls above, picking a fuel is a COMMAND sent to the FCS
-- (mirrors ui/basalt/regions/fcs.lua's M._onMode: runtime.links.tel:send(runtime.sender:send(cmd))).
-- The FCS applies the scale, persists it, and reports fuel/fuelPct/badFuel back on telemetry --
-- M.calfuel's apply() below reflects THAT (state.fuel), never the just-picked value directly
-- (no-optimistic UI, same discipline as every other apply() in this module).
function M._onFuel(runtime, id)
  local cmd = EnginePanel.fuelCommand(id)
  runtime.links.tel:send(runtime.sender:send(cmd))
  return cmd
end

-- ===== M._cfg: thin delegate onto UI CAL's already-tested intent seam. No reimplementation. =====
-- Valid ids: relaySide, pulseUp/pulseDn, intervalUp/intervalDn, bindPump/bindTank/bindRelay,
-- toggleInvert/toggleKick. Deliberately never "calFuel" -- M._setMax below is the manual replacement.
--
-- uical._onButton -> _applyOp saves runtime.config to disk but does NOT bump runtime.uiRev, and
-- the cadence signature (ui/basalt/cadence.lua) has no field for relay name/side, pulseMs,
-- intervalMs, or bind names -- so a uiRev bump here is the ONLY thing that forces the merged
-- page's render-gate to repaint emc_config's labels after a bind/relaySide/pulse/interval edit
-- (mirrors ui/basalt/pages/config.lua's M._onButton, which bumps uiRev itself for the identical
-- reason). Bumped unconditionally after delegating, regardless of the effect uical returns.
function M._cfg(runtime, id, deps)
  local effect = Uical._onButton(runtime, id, os.epoch("utc"), deps)
  runtime.uiRev = (runtime.uiRev or 0) + 1
  return effect
end

-- ===== M._setMax: pure-of-Basalt manual-max stepper for emc_calfuel. =====
-- role: "pump" | "tank". Clamps at 0, persists via saveFn (default ui.config's M.save against
-- BasaltApp.CONFIG_PATH -- required LAZILY, mirroring ui/basalt/pages/config.lua's own
-- M._onButton, since ui.basalt.app does not require this module back), and bumps runtime.uiRev so
-- the cadence gate repaints. Returns the new max.
function M._setMax(runtime, role, delta, saveFn)
  local BasaltApp = require("ui.basalt.app")
  local save = saveFn or Config.save
  local fc = runtime.config.fuel[role]
  local newFull = math.max(0, (fc.full or 0) + (delta or 0))
  fc.full = newFull
  save(BasaltApp.CONFIG_PATH, runtime.config)
  runtime.uiRev = (runtime.uiRev or 0) + 1
  return newFull
end

-- ===== M.main ("emc_main"): flight-glance view, ~10 rows (Task 3 fuel-panel redesign) =====
--
-- Row 1 is a blank top margin (matches the merged page's other regions -- ui/basalt/regions/
-- fcs.lua's M.main); all content starts at internal y=2:
--   y2  "Solid Pump BZC"   label over the solid gauge (fit to width)
--   y3  <bar x=2..>  128x  green/gray ProgressBar (height 1) + right-justified int+unit value
--   y4  "Liquid Main BDSL" label (fit; falls back to "Liq Main BDSL" if the full text clips)
--   y5  <bar x=2..>  180B  same bar/value treatment, liquid units
--   y6  "FLOW <n> mB/m" (left half) / "LEFT <t>" (right half) -- fuel time-estimate readouts
--       (state.fuelEst), directly under the Liquid Main bar; split iw across ix0..ix1.
--   y7  [ENG SW][PRIME]    3-row outlined buttons, common width
--   MASTER/FEED lights + CONFIG drill sit lower, inside/beside the status box (see below)
-- Outlined 3-row button: a Basalt button with a subpixel rounded border (native addBorder). Returns
-- the button; call btn:addBorder(colour) to recolour the outline on state change.
local function outlinedButton(frame, x, y, wd, text, borderColor)
  local btn = frame:addButton({ x = x, y = y, width = wd, height = 3, text = text })
  btn:setBackground(Theme.role("button")); btn:setForeground(Theme.role("font"))
  btn:addBorder(borderColor)
  return btn
end

-- 2-row chip button (matches the FCS region): a feedback-coloured CHIP bar over a label button.
-- Returns { chip, label, setChip(colour), setText(t), onClick(fn) }.
local function chipButton(frame, x, y, wd, text, chipColor)
  local chip = frame:addButton({ x = x, y = y, width = wd, height = 1, text = "" })
  chip:setBackground(chipColor or Theme.role("button"))
  local label = frame:addButton({ x = x, y = y + 1, width = wd, height = 1, text = text })
  label:setBackground(Theme.role("button")); label:setForeground(Theme.role("font"))
  local ctrl = { chip = chip, label = label }
  function ctrl.setChip(color) chip:setBackground(color); return ctrl end
  function ctrl.setText(t) label:setText(t); return ctrl end
  function ctrl.onClick(fn) chip:onClick(fn); label:onClick(fn); return ctrl end
  return ctrl
end

-- Compact interval format for the config status box: "5m30s" (minutes + zero-padded seconds).
local function fmtIntervalCompact(ms)
  local s = math.floor((ms or 0) / 1000)
  return string.format("%dm%02ds", math.floor(s / 60), s % 60)
end

function M.main(basalt, frame, region, runtime, opts)
  local w, h = frame:getSize()

  -- ===== Background decoration (low z, behind the interactive elements) =====
  -- Panel border: black / green line / black, on TOP+LEFT+RIGHT only -- the FCS region below draws
  -- the BOTTOM edge, so the frame wraps the whole flight panel with no line between the two regions.
  -- Plus the orange double-border checkered STATUS box (lower-left), inset from the border.
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, M._resolveEdges(opts))
  -- Status box detached from the ENG SW button above (gap at h-7); 2-subpixel checkered orange border.
  local boxC0, boxR0, boxC1, boxR1 = 3, math.max(4, h - 6), 17, h - 2
  Gfx.checkerBox(bg, boxC0, boxR0, boxC1, boxR1, colors.orange)

  -- ===== Fuel gauges: label (left) + amount (right) on one row, full-width bar below =====
  local ix0, ix1 = 3, w - 2                    -- inner content x-range (inside the L/R border, 1-col gap)
  local iw = ix1 - ix0 + 1
  local pmpLabel = frame:addLabel({ x = ix0, y = 2, width = iw, height = 1, autoSize = false, text = fit("Solid Pump " .. M.SOLID_ABBR, iw) })
  local pmpValLabel = frame:addLabel({ x = ix1 - 5, y = 2, width = 6, height = 1, autoSize = false, text = "" })
  local pmpBar = frame:addProgressBar({ x = ix0, y = 3, width = iw, height = 1 })
  pmpBar:setProgressColor(colors.green); pmpBar:setBackground(colors.gray)
  local mainLabel = frame:addLabel({ x = ix0, y = 4, width = iw, height = 1, autoSize = false, text = fit("Liquid Main " .. M.LIQUID_ABBR, iw) })
  local mainValLabel = frame:addLabel({ x = ix1 - 5, y = 4, width = 6, height = 1, autoSize = false, text = "" })
  local mainBar = frame:addProgressBar({ x = ix0, y = 5, width = iw, height = 1 })
  mainBar:setProgressColor(colors.green); mainBar:setBackground(colors.gray)

  -- ===== FLOW / LEFT fuel-time readouts, directly under the Liquid Main tank bar (y5) -- the free
  -- y6 row, split into left/right halves within the inner content x-range. =====
  local flowW = math.floor(iw / 2)
  local leftW = iw - flowW
  local flowLabel = frame:addLabel({ x = ix0, y = 6, width = flowW, height = 1, autoSize = false, text = "" })
  local leftLabel = frame:addLabel({ x = ix0 + flowW, y = 6, width = leftW, height = 1, autoSize = false, text = "" })
  flowLabel:setForeground(Theme.role("font")); leftLabel:setForeground(Theme.role("font"))

  -- ===== ENG SW (green/red feedback) + PRIME (orange) -- 3-row outlined, centred + spaced =====
  local btnW, btnGap, btnY = 10, 2, 7
  local bx0 = math.max(ix0, math.floor((w - (btnW * 2 + btnGap)) / 2) + 1)
  local engBtn = outlinedButton(frame, bx0, btnY, btnW, "ENG SW", colors.red)
  local primeBtn = outlinedButton(frame, bx0 + btnW + btnGap, btnY, btnW, "PRIME", colors.orange)

  -- ===== Status text inside the box: fixed GREEN text (never recoloured), values aligned in a fixed
  -- column, plus a red/green state LED (filled circle) after each value to show on/off. =====
  local tx = boxC0 + 2
  local masterText = frame:addLabel({ x = tx, y = boxR0 + 1, width = 8, height = 1, autoSize = false, text = "" })
  local feedText   = frame:addLabel({ x = tx, y = boxR0 + 2, width = 8, height = 1, autoSize = false, text = "" })
  masterText:setForeground(Theme.role("font")); feedText:setForeground(Theme.role("font"))
  local ledX = tx + 9
  local function setLed(row, on)
    bg:setPixel(ledX, boxR0 + row, string.char(7), colors.toBlit(on and colors.green or colors.red), "f")
  end
  -- LFED = solid fuel fed on the last feed (state.lfed, from ui/fedtrack). No LED (a count, not a
  -- state), so the row may use the full box width. Driven by apply() below.
  local lfedLabel = frame:addLabel({ x = tx, y = boxR0 + 3, width = 12, height = 1, autoSize = false, text = "" })
  lfedLabel:setForeground(Theme.role("font"))

  -- ===== CONFIG (blue outline) 3-row, right of the status box -- sized to its label =====
  local configBtn = outlinedButton(frame, 22, boxR0 + 1, 10, "CONFIG", colors.blue)

  engBtn:onClick(function() M._onEngine(runtime, "engSw", os.epoch("utc")) end)
  primeBtn:onClick(function() M._onEngine(runtime, "prime", os.epoch("utc")) end)
  configBtn:onClick(function() region:push("emc_config") end)

  -- Right-justify a short value against the inner right edge (ix1).
  local function setVal(label, text)
    text = fit(text, 6)
    local tw = math.max(1, #text)
    label:setWidth(tw); label:setX(ix1 - tw + 1); label:setText(text)
  end

  -- apply(state): idempotent repaint from `state` + runtime.config ONLY -- no peripheral polling.
  local function apply(state)
    state = state or {}
    local cfg = runtime.config

    pmpBar:setProgress(round(Fuel.manualFrac(state.pumpAmount, cfg.fuel.pump.full) * 100))
    setVal(pmpValLabel, tostring(state.pumpAmount or 0) .. "x")
    mainBar:setProgress(round(Fuel.manualFrac(state.tankMb, cfg.fuel.tank.full) * 100))
    setVal(mainValLabel, tostring(math.floor((state.tankMb or 0) / 1000)) .. "B")
    mainLabel:setText(fit("Liquid Main " .. fueltable.abbrevOf(state.fuel), iw))

    flowLabel:setText(fit(EnginePanel.flowLabel(state and state.fuelEst), flowW))
    leftLabel:setText(fit(EnginePanel.leftLabel(state and state.fuelEst), leftW))

    local bound = relayBound(runtime)
    -- ENG SW outline: lime(on) / red(off) when a relay is bound, else gray (disabled).
    engBtn:addBorder(bound and (state.engineMaster and colors.lime or colors.red) or colors.gray)
    engBtn:setForeground(bound and Theme.role("font") or Theme.DISABLED_FG)
    engBtn:setEnabled(bound and true or false)

    -- PRIME keeps its ORANGE outline always (its role colour); it is just gated clickable when it
    -- can't fire (relay bound + master on).
    local primeEnabled = bound and (state.engineMaster and true or false)
    primeBtn:addBorder(colors.orange)
    primeBtn:setForeground(Theme.role("font"))
    primeBtn:setEnabled(primeEnabled)

    -- Status readouts: fixed green text with the value aligned in a fixed column; the red/green state
    -- LED (filled circle) after each value carries the on/off feedback (the text no longer recolours).
    -- Width guard (as on the tape/PFD): re-assert the width so the aligned text can't wrap-clip when
    -- the frame width hasn't settled during a rebuild.
    masterText:setWidth(8); feedText:setWidth(8)
    masterText:setText(string.format("%-5s%-3s", "ENG", state.engineMaster and "ON" or "OFF"))
    feedText:setText(string.format("%-5s%-3s", "FEED", state.feeding and "YES" or "NO"))
    setLed(1, state.engineMaster and true or false)
    setLed(2, state.feeding and true or false)
    lfedLabel:setWidth(12)
    lfedLabel:setText(string.format("%-5s%s", "LFED",
      state.lfed and (round(state.lfed) .. " " .. M.SOLID_ABBR) or ("-- " .. M.SOLID_ABBR)))
  end

  apply({})

  return {
    apply = apply,
    elements = {
      pmpLabel = pmpLabel, pmpBar = pmpBar, pmpValLabel = pmpValLabel,
      mainLabel = mainLabel, mainBar = mainBar, mainValLabel = mainValLabel,
      flowLabel = flowLabel, leftLabel = leftLabel,
      engSw = engBtn, primeBtn = primeBtn,
      masterText = masterText, feedText = feedText, lfedLabel = lfedLabel,
      configBtn = configBtn,
    },
  }
end

-- ===== M.config ("emc_config"): engine config drill, ~11 rows =====

-- deps (optional, 5th arg): { scan= } -- injectable exactly like uical.build's trailing deps;
-- defaults to Uical._realScanDescriptors (the SAME real scanner uical.lua's own menu uses -- no
-- second implementation). Scanned once at build time to populate the four pickers' candidate
-- lists; this screen has no dedicated RESCAN control (SCAN+auto-detect lives on UI CAL), so the
-- candidate lists are fixed for the screen's lifetime -- only each picker's CURRENT selection is
-- refreshed afterwards, from runtime.config, on every apply().
function M.config(basalt, frame, region, runtime, deps)
  local w, h = frame:getSize()

  -- Background: panel border (TOP+LEFT+RIGHT -- the FCS region below still draws the bottom, so the
  -- frame wraps the whole flight panel) + an orange checkered STATUS box holding the 3 readouts.
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, M._resolveEdges(deps))
  local boxC0, boxR0, boxC1, boxR1 = 8, 2, 28, 7
  Gfx.checkerBox(bg, boxC0, boxR0, boxC1, boxR1, colors.orange)

  -- Status readouts inside the box (black interior), spaced from the border. Row 1 = FUEL calibration
  -- glance readout (reported fuel + %, e.g. "BIOD 60%"); INVERT gets a red/green state LED like ENG/FEED.
  -- Width 17 so the widest value ("ETHA 200%") aligns with the PULSE/INTRVL/INVERT rows (%-8s).
  local tx = boxC0 + 2
  local fuelLabel = frame:addLabel({ x = tx, y = boxR0 + 1, width = 17, height = 1, autoSize = false, text = "" })
  fuelLabel:setForeground(Theme.role("font"))
  local pulseLbl = frame:addLabel({ x = tx, y = boxR0 + 2, width = 16, height = 1, autoSize = false, text = "" })
  local intLbl   = frame:addLabel({ x = tx, y = boxR0 + 3, width = 16, height = 1, autoSize = false, text = "" })
  local invLbl   = frame:addLabel({ x = tx, y = boxR0 + 4, width = 11, height = 1, autoSize = false, text = "" })
  local invLedX  = tx + 12
  local function setInvLed(on) bg:setPixel(invLedX, boxR0 + 4, string.char(7), colors.toBlit(on and colors.green or colors.red), "f") end

  -- Control chip row (2-row): PULSE -/+ , INT -/+ (orange actions) + INVERT toggle (green/red).
  local cy = boxR1 + 2
  local pulseDn = chipButton(frame, 3,  cy, 6, "PULSE-", colors.orange)
  local pulseUp = chipButton(frame, 10, cy, 6, "PULSE+", colors.orange)
  local intDn   = chipButton(frame, 17, cy, 5, "INT-",   colors.orange)
  local intUp   = chipButton(frame, 23, cy, 5, "INT+",   colors.orange)
  local invBtn  = chipButton(frame, 29, cy, 6, "INVERT", colors.red)

  -- CAL FUEL + BACK (blue outlined, 3-row) at the bottom, side by side.
  local by = cy + 3
  local calFuelBtn = outlinedButton(frame, 6,  by, 12, "CAL FUEL", colors.blue)
  local backBtn    = outlinedButton(frame, 20, by, 10, "< BACK",   colors.blue)

  pulseDn.onClick(function() M._cfg(runtime, "pulseDn") end)
  pulseUp.onClick(function() M._cfg(runtime, "pulseUp") end)
  intDn.onClick(function() M._cfg(runtime, "intervalDn") end)
  intUp.onClick(function() M._cfg(runtime, "intervalUp") end)
  invBtn.onClick(function() M._cfg(runtime, "toggleInvert") end)
  calFuelBtn:onClick(function() region:push("emc_calfuel") end)
  backBtn:onClick(function() region:pop() end)

  -- apply(state): reads ONLY runtime.config -- the 3 readouts + the INVERT chip colour.
  local function apply(state)
    state = state or {}
    local e = runtime.config.engine or {}
    -- Labels padded to a fixed width so the values line up vertically across the rows. Width guard
    -- (as on the tape/PFD) keeps the aligned text from wrap-clipping on an unsettled rebuild.
    fuelLabel:setWidth(17)
    fuelLabel:setText(string.format("%-8s%s", "FUEL:", EnginePanel.fuelCalText(state.fuel, state.fuelPct)))
    pulseLbl:setWidth(16); intLbl:setWidth(16); invLbl:setWidth(11)
    pulseLbl:setText(string.format("%-8s%dms", "PULSE:", e.pulseMs or 0))
    intLbl:setText(string.format("%-8s%s", "INTRVL:", fmtIntervalCompact(e.intervalMs)))
    local inv = e.invert and true or false
    invLbl:setText(string.format("%-8s%s", "INVERT:", inv and "ON" or "OFF"))
    setInvLed(inv)
    invBtn.setChip(inv and colors.lime or colors.red)
  end

  apply({})

  return {
    apply = apply,
    elements = {
      fuelLabel = fuelLabel,
      pulseLbl = pulseLbl, intLbl = intLbl, invLbl = invLbl,
      pulseDn = pulseDn, pulseUp = pulseUp, intDn = intDn, intUp = intUp, invBtn = invBtn,
      calFuelBtn = calFuelBtn, backBtn = backBtn,
    },
  }
end

-- ===== M.calfuel ("emc_calfuel"): manual max steppers, expanded (Task 4) =====
--
-- Top-margin convention (row 1 blank, content starts y=2 -- matches M.main/M.config):
--   y2  < BACK
--   y3  "SOLID <n>x" label
--   y4  solid decrements, centered via btnfit.grid: -64  -1
--   y5  solid increments, centered via btnfit.grid: +1  +64
--   y6  FUEL label + fuel-type CHIP trigger (Task 3, option a -- reuses the y6 spacer row between
--       the two checker boxes; a remote command via M._onFuel, unlike the local manual-max steppers)
--   y7  "LIQ <n>B" label (n == buckets, i.e. mB/1000)
--   y8  liquid decrements, centered: -100  -50  -1   (captions are BUCKETS)
--   y9  liquid increments, centered: +1  +50  +100
--   y11 BAD FUEL warning label (Task 9 -- reuses the y11 spacer row before BACK; red text, telemetry-
--       only, never shown until apply() sees state.badFuel true)
-- 8 content rows total (y2..y9) plus the fuel picker/warning on the two spacer rows, all well inside
-- the real 36x17 EMC region (ui/basalt/pages/flight.lua's M.split of the 36x38 overhead).
function M.calfuel(basalt, frame, region, runtime, opts)
  local w, h = frame:getSize()

  -- Background: panel border (TOP+LEFT+RIGHT -- the FCS region below draws the bottom).
  local bg = frame:addImage({ x = 1, y = 1, width = w, height = h }); bg:resizeImage(w, h); bg.set("z", 1)
  Gfx.clear(bg, w, h)
  Gfx.border(bg, w, h, colors.green, M._resolveEdges(opts))

  -- Each fuel: an orange checkered box on the LEFT (label + aligned value), with its +/- steppers on
  -- the RIGHT -- same magnitude / opposite sign grouped vertically (+ above -). Steppers are orange
  -- chip buttons (the usual stateless-action style). Both boxes at the same x so the values align.
  Gfx.checkerBox(bg, 3, 2, 17, 5, colors.orange)
  local solidLabel = frame:addLabel({ x = 5, y = 3, width = 12, height = 1, autoSize = false, text = "" })
  solidLabel:setForeground(Theme.role("font"))
  local solidUp64 = chipButton(frame, 19, 2, 6, "+64", colors.orange)
  local solidDn64 = chipButton(frame, 19, 4, 6, "-64", colors.orange)
  local solidUp1  = chipButton(frame, 26, 2, 6, "+1",  colors.orange)
  local solidDn1  = chipButton(frame, 26, 4, 6, "-1",  colors.orange)

  -- FUEL type picker: opened from the fuel button at the BOTTOM (next to BACK, mirroring the Engine
  -- config region's CAL FUEL + BACK) rather than a squeezed chip between the two checker boxes. The
  -- y6 spacer row is left free. Remote command via M._onFuel; apply() drives the button from state.fuel.
  local fuelPicker = Gfxpicker.make(frame)

  Gfx.checkerBox(bg, 3, 7, 17, 10, colors.orange)
  local liqLabel = frame:addLabel({ x = 5, y = 8, width = 12, height = 1, autoSize = false, text = "" })
  liqLabel:setForeground(Theme.role("font"))
  local liqUp100 = chipButton(frame, 19, 7, 6, "+100", colors.orange)
  local liqDn100 = chipButton(frame, 19, 9, 6, "-100", colors.orange)
  local liqUp50  = chipButton(frame, 26, 7, 4, "+50",  colors.orange)
  local liqDn50  = chipButton(frame, 26, 9, 4, "-50",  colors.orange)
  local liqUp1   = chipButton(frame, 31, 7, 4, "+1",   colors.orange)
  local liqDn1   = chipButton(frame, 31, 9, 4, "-1",   colors.orange)

  -- BAD FUEL warning (Task 9): telemetry-only, static text on the free y11 spacer row before BACK.
  -- Red foreground when state.badFuel is true, else the theme font colour (matches the header note:
  -- a Basalt Label paints no background, so the red CUE is the foreground colour, never a fill).
  local badLabel = frame:addLabel({ x = 3, y = 11, width = 12, height = 1, autoSize = false, text = "" })
  badLabel:setForeground(Theme.role("font"))

  -- Fuel picker (left) + BACK (right), 3-row blue-outlined, side by side at the bottom -- mirrors
  -- the Engine config region's CAL FUEL + BACK. The fuel button shows the current fuel and opens
  -- the gfxpicker modal.
  local fuelBtn = outlinedButton(frame, 3, 12, 20, "FUEL", colors.blue)
  local backBtn = outlinedButton(frame, 24, 12, 10, "< BACK", colors.blue)

  fuelBtn:onClick(function()
    fuelPicker.show({
      title = "FUEL",
      options = EnginePanel.fuelOptions(),
      current = (fuelPicker._current or nil),
      onPick = function(value) M._onFuel(runtime, value) end,
    })
  end)
  backBtn:onClick(function() region:pop() end)
  solidDn64.onClick(function() M._setMax(runtime, "pump", -M.SOLID_STEP) end)
  solidDn1.onClick(function() M._setMax(runtime, "pump", -M.SOLID_FINE) end)
  solidUp1.onClick(function() M._setMax(runtime, "pump", M.SOLID_FINE) end)
  solidUp64.onClick(function() M._setMax(runtime, "pump", M.SOLID_STEP) end)
  liqDn100.onClick(function() M._setMax(runtime, "tank", -M.LIQUID_100) end)
  liqDn50.onClick(function() M._setMax(runtime, "tank", -M.LIQUID_50) end)
  liqDn1.onClick(function() M._setMax(runtime, "tank", -M.LIQUID_STEP) end)
  liqUp1.onClick(function() M._setMax(runtime, "tank", M.LIQUID_STEP) end)
  liqUp50.onClick(function() M._setMax(runtime, "tank", M.LIQUID_50) end)
  liqUp100.onClick(function() M._setMax(runtime, "tank", M.LIQUID_100) end)

  -- apply(state): manual maxes from runtime.config ONLY (unchanged); the fuel picker + BAD FUEL
  -- label reflect TELEMETRY (state.fuel/fuelPct/badFuel) -- no-optimistic UI, same as every other
  -- apply() in this module. Labels padded so the values line up; width guard against the
  -- unsettled-rebuild wrap-clip.
  local function apply(state)
    local cfg = runtime.config
    solidLabel:setWidth(12); liqLabel:setWidth(12)
    solidLabel:setText(string.format("%-7s%dx", "SOLID", cfg.fuel.pump.full or 0))
    liqLabel:setText(string.format("%-7s%dB", "LIQUID", math.floor((cfg.fuel.tank.full or 0) / 1000)))

    local fuelName = state and state.fuel
    fuelPicker._current = fuelName
    local bad = EnginePanel.fuelBad(state)
    fuelBtn:setText(fit(EnginePanel.fuelLabel(state), 18))
    fuelBtn:setForeground(bad and colors.red or Theme.role("font"))
    badLabel:setWidth(12)
    badLabel:setText(bad and "BAD FUEL" or "")
    badLabel:setForeground(bad and colors.red or Theme.role("font"))
  end

  apply({})

  return {
    apply = apply,
    elements = {
      backBtn = backBtn, solidLabel = solidLabel, liqLabel = liqLabel,
      solidUp64 = solidUp64, solidDn64 = solidDn64, solidUp1 = solidUp1, solidDn1 = solidDn1,
      liqUp100 = liqUp100, liqDn100 = liqDn100, liqUp50 = liqUp50, liqDn50 = liqDn50, liqUp1 = liqUp1, liqDn1 = liqDn1,
      fuelBtn = fuelBtn, fuelPicker = fuelPicker, badLabel = badLabel,
    },
  }
end

return M
