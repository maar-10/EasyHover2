-- ui/basalt/bitconfig/senssource.lua
-- SENS SOURCE sub-menu (BIT/CONFIG hub, screen id "senssource"): picks which sensor-cal profile
-- to use -- FCS / SELF / OFF -- and runs SELF-cal. PFD attitude/SAS already come from the FCS
-- snapshot; this menu does not feed the PFD render. SELF-cal's sampler reads FCS-cached
-- eh2_devbind sensor names via ui.basalt.cfgseam; picker/SELF-cal still persist config.sens
-- (source/self) into the UI's own /eh2_ui_config.tbl via local realWrite (not an FCS config
-- file -- must never go through cfgseam). SELF-cal reuses ui/basalt/senssource.lua's
-- selfSteps/selfApply pure helpers.
--
-- ===== PURE intent seam: M._select =====
-- M._select(config, source, save): sets config.sens.source = source, then calls save() if given.
-- Basalt-free, unit-testable with a plain table + a fake save spy (tests/test_bitconfig_senssource
-- .lua). Mirrors senscal.lua's M._save pattern of a small, directly-callable persistence seam.
--
-- ===== M.build: root source-picker + SELF's CAL drilldown (ui/basalt/region.lua) =====
-- Hosts a region.lua drilldown (root "source") inside this page's own frame, below a static
-- "SENS SOURCE" headerLabel -- mirrors senscal.lua's steplist->step_<id> shape, just far smaller:
--   * "source": three switchbtn rows (FCS/SELF/OFF), each showing "on" iff it is the currently
--     active config.sens.source and calling M._select(config, <src>, save) on click; a
--     "CAL (SELF)" row drills into the SELF-cal capture ("callist"); "<" pops the FRAME-level nav.
--   * "callist": one row per ui.basalt.senssource's M.selfSteps() (done/pending marker + label),
--     an APPLY row (enabled only once every step has been captured -- calls
--     ui.basalt.senssource.selfApply(samples), writes the result into config.sens.self AND sets
--     config.sens.source = "SELF" via the SAME M._select/save seam -- finishing SELF-cal both
--     saves the profile and switches to it, per the task brief) + "<" pops back to "source".
--   * "cal_<id>" (one per selfSteps() entry, each its own screen -- there is no shared controller
--     to re-target since every step screen is independent and Region.lua caches each build()
--     result permanently once visited): title/prompt + a single CAPTURE row that reads the live
--     gimbal angles + medial velocity via the injected sampler (defaulted to a real sampler
--     wrapping the eh2_devbind-bound sensors, mirroring senscal.lua's M._realSampler) -- ONE
--     instantaneous read, NOT a multi-second stream capture like SENS CAL's phases (selfSteps()'s
--     prompts are all "hold X, then CAPTURE" one-shots, so no basalt.schedule coroutine is
--     needed here) -- then pops back to "callist".
--
-- NO peripheral/Basalt/fs access at module LOAD -- everything lives inside M.build's closures, so
-- `require("ui.basalt.bitconfig.senssource")` loads clean headless.

local Region     = require("ui.basalt.region")
local configkit  = require("ui.basalt.configkit")
local switchbtn  = require("ui.basalt.switchbtn")
local cfgspec    = require("fcs.io.cfgspec")
local shim       = require("fcs.io.shim")
local fsx        = require("fcs.io.fsx")
local senssource = require("ui.basalt.senssource")
local cfgseam    = require("ui.basalt.cfgseam")

local M = {}
M.id = "senssource"
M.title = "SENS SOURCE"

-- ===== M._select: PURE intent seam. Sets config.sens.source and persists via `save`. =====
function M._select(config, source, save)
  config.sens = config.sens or {}
  config.sens.source = source
  if save then save() end
  return source
end

-- ===== real write (default injected seam; never called at module load) =====
-- `read` defaults to cfgseam.read(runtime) so SELF-cal wraps FCS-cached eh2_devbind sensor
-- names. `write` stays LOCAL: persists the SAME /eh2_ui_config.tbl ui/config.lua's M.load/M.save
-- round-trip -- not an FCS config file -- so it must never go through cfgseam.
--
-- DECISION: this reuses the injected write(filename, body) seam -- the SAME convention senscal.lua
-- /tuning.lua/mdb.lua/dtc.lua all use -- rather than calling ui.config's M.save(path, cfg)
-- directly, so this module follows the SAME read/write/sampler shape the task brief pins and never
-- needs a lazy require("ui.basalt.app") just to reach its own CONFIG_PATH constant (the filename
-- is fixed at module scope below instead, and resolves to the identical absolute path).
local UI_CONFIG_FILE = "eh2_ui_config.tbl" -- same file as ui/basalt/app.lua's M.CONFIG_PATH ("/eh2_ui_config.tbl")

local function realWrite(filename, body)
  return fsx.writeAtomic("/" .. filename, body)
end

-- ===== real sampler: wraps eh2_devbind's gimbal/velMedial sensors, ONE instantaneous read. =====
-- Mirrors senscal.lua's M._realSampler (an injectable seam defaulted to real peripheral access,
-- never called at module load) but simpler: SELF-cal's 4 steps (ui/basalt/senssource.lua's
-- M.selfSteps()) are each a single "hold X, then CAPTURE" -- so this samples ONCE, synchronously,
-- no basalt.schedule coroutine needed.
local function realSampler(wrapped)
  local angles = { 0, 0 }
  if wrapped.gimbal then
    local ok, a = pcall(function() return wrapped.gimbal.getAngles() end)
    if ok and a then angles = a end
  end
  local vel = 0
  if wrapped.velMedial then
    local ok, v = pcall(function() return wrapped.velMedial.getVelocity() end)
    if ok and v then vel = v end
  end
  return { angles = angles, vel = vel }
end
M._realSampler = realSampler

-- ===== M.build: construct the source-picker + SELF-cal drilldown element tree =====
-- SAME signature/return convention as senscal.lua's M.build: M.build(basalt, frame, runtime, nav,
-- read, write, sampler) -> { id, apply(state), elements }. The real call site (ui/basalt/app.lua's
-- showScreen -> page.build(basalt, childFrame, runtime, frameRec.nav)) only ever passes the first
-- four args -- read/write/sampler default to the real seams above, exactly like senscal.lua.
function M.build(basalt, frame, runtime, nav, read, write, sampler)
  -- S2b: SELF-cal sampler needs the FCS's live devbind sensor names, so `read` defaults to the
  -- FCS cache. `write` stays LOCAL (realWrite): this menu persists config.sens into the UI's own
  -- eh2_ui_config.tbl -- not an FCS config file -- so it must never go through cfgseam/the FCS.
  -- PFD attitude/SAS already come from the FCS snapshot; this menu does not feed the PFD render.
  read = read or cfgseam.read(runtime)
  write = write or realWrite
  sampler = sampler or realSampler

  local config = (runtime and runtime.config) or {}
  config.sens = config.sens or { source = "FCS" }

  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local headerLabel = configkit.titleRow(frame, ({ frame:getSize() })[1], M.title)

  -- A region-internal nav push/pop isn't a FRAME-level nav change, so it wouldn't otherwise wake
  -- the dirty-gated render loop -- bump runtime.uiRev, exactly like senscal.lua's/uical.lua's
  -- regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  local function save()
    write(UI_CONFIG_FILE, textutils.serialise(config))
  end

  local steps = senssource.selfSteps()
  local calSamples = {}
  local calCompleted = {}

  -- Wraps the eh2_devbind-bound gimbal/velMedial sensors by name, mirroring senscal.lua's
  -- wrapSensors (only wraps a key whose devbind name is actually set).
  local function wrapSensors()
    local sensorNames = (cfgspec.load("devbind", read)).sensors or {}
    local wrapped = {}
    if sensorNames.gimbal then wrapped.gimbal = shim.wrap(sensorNames.gimbal) end
    if sensorNames.velMedial then wrapped.velMedial = shim.wrap(sensorNames.velMedial) end
    return wrapped
  end

  -- ===== "source" screen: FCS/SELF/OFF picker + CAL (SELF) drill + "<" =====
  local function buildSource(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    local refreshSource -- forward-declared: every source button's onClick calls this.

    local SOURCES = { "FCS", "SELF", "OFF" }
    local srcItems = {}
    for _, src in ipairs(SOURCES) do
      srcItems[#srcItems + 1] = { id = src, label = src,
        onClick = function() M._select(config, src, save); refreshSource() end }
    end
    local srcMenu = configkit.menuColumn(f, { y = y, items = srcItems })
    local srcBtns = {}
    for _, src in ipairs(SOURCES) do srcBtns[src] = srcMenu.buttons[src] end
    y = srcMenu.nextY

    local calRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "CAL (SELF)", onClick = function() region:push("callist") end },
    })
    y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
    })

    refreshSource = function()
      local active = config.sens.source or "FCS"
      for _, src in ipairs(SOURCES) do
        srcBtns[src].set(src == active and "on" or "off")
      end
    end
    refreshSource()

    return {
      apply = function(_state) refreshSource() end,
      elements = { srcBtns = srcBtns, calRow = calRow, backRow = backRow },
    }
  end

  -- ===== "callist" screen: one row per selfSteps() (done/pending marker+label) + APPLY/"<" =====
  local function buildCalList(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 1

    local refreshList -- forward-declared: step buttons + APPLY's onClick call this.

    -- Compact centred column sized to the widest step ("[ ] " + label); the marker is refreshed live.
    local stepItems = {}
    for i, step in ipairs(steps) do
      stepItems[#stepItems + 1] = { id = i, label = "[ ] " .. step.label,
        onClick = function() region:push("cal_" .. step.id) end }
    end
    local stepMenu = configkit.menuColumn(f, { y = y, items = stepItems })
    local stepBtns = {}
    for i = 1, #steps do stepBtns[i] = stepMenu.buttons[i] end
    local stepBtnW = stepMenu.width
    y = stepMenu.nextY

    local applyRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "APPLY", onClick = function()
          for _, step in ipairs(steps) do
            if not calCompleted[step.id] then return end
          end
          local cal = senssource.selfApply(calSamples)
          config.sens.self = cal
          M._select(config, "SELF", save)
          calSamples = {}
          for _, step in ipairs(steps) do calCompleted[step.id] = nil end
          region:pop()
        end },
    })
    y = y + 1

    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = "<", onClick = function() region:pop() end },
    })

    refreshList = function()
      local allDone = true
      for i, step in ipairs(steps) do
        local marker = calCompleted[step.id] and "[x] " or "[ ] "
        stepBtns[i].button:setText(configkit.fitLabel(marker .. step.label, stepBtnW))
        if not calCompleted[step.id] then allDone = false end
      end
      applyRow.setState(1, allDone and "on" or "disabled")
    end
    refreshList()

    return {
      apply = function(_state) refreshList() end,
      elements = { stepBtns = stepBtns, applyRow = applyRow, backRow = backRow },
    }
  end

  -- ===== "cal_<id>" screen: title/prompt + a single CAPTURE row + "< LIST" =====
  -- One independent screen per step -- Region.lua builds/caches each id exactly once (no shared
  -- controller needed, unlike senscal.lua's step_<id> screens, since selfSteps() never branches).
  local function buildCalStep(step)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local titleLabel = f:addLabel({
        x = fx, y = y, width = fiw, height = 1, autoSize = false,
        text = configkit.fitLabel(step.label, fiw),
      }); y = y + 1
      local promptLabel = f:addLabel({
        x = fx, y = y, width = fiw, height = 1, autoSize = false,
        text = configkit.fitLabel(step.prompt, fiw),
      }); y = y + 1
      local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" }); y = y + 1

      local captureRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "CAPTURE", onClick = function()
            local wrapped = wrapSensors()
            calSamples[step.id] = sampler(wrapped)
            calCompleted[step.id] = true
            statusLabel:setText(configkit.fitLabel("captured", fiw))
            bump()
          end },
      }); y = y + 1

      local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "< LIST", onClick = function() region:pop() end },
      })

      local function refresh()
        statusLabel:setText(calCompleted[step.id] and configkit.fitLabel("captured", fiw) or "")
      end
      refresh()

      return {
        apply = function(_state) refresh() end,
        elements = {
          titleLabel = titleLabel, promptLabel = promptLabel, statusLabel = statusLabel,
          captureRow = captureRow, backRow = backRow,
        },
      }
    end
  end

  local screens = { source = buildSource, callist = buildCalList }
  for _, step in ipairs(steps) do
    screens["cal_" .. step.id] = buildCalStep(step)
  end

  local region = Region.new(basalt, frame, {
    x = 1, y = 3, width = w, height = math.max(1, h - 2),
    root = "source", screens = screens, onNav = bump,
  })

  -- Force the source screen to build now (not on the first scheduled apply()), so its elements
  -- exist as soon as M.build returns -- mirrors senscal.lua's/mdb.lua's identical eager-build call.
  region:apply(nil)

  -- apply(state): this menu shows a source picker + guided CONFIG flow, not live telemetry --
  -- forwards to the region, which lazily builds/shows its current nav top and repaints only that
  -- screen. Never polls peripherals on its own; CAPTURE is the only thing that samples, and only
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
