-- ui/basalt/bitconfig/fcssync.lua
-- FCS SYNC sub-menu (BIT/CONFIG hub, screen id "fcssync"): a READ-ONLY checker. Post-S2 the FCS is
-- the config source of truth, so this no longer starts/stops any UI-side server -- it requests each
-- config kind from the running FCS (via runtime.cfgClient) and reports whether the FCS answered.
-- NEVER writes.
--
-- Exports M.id/M.title, a PURE view-model (M.KINDS / M.checkStatus), and M.build(basalt, frame,
-- runtime, nav) -> { id, apply(state), elements }. NO peripheral/Basalt access at module LOAD.
local configkit = require("ui.basalt.configkit")

local M = {}
M.id = "fcssync"
M.title = "FCS SYNC"

-- The FCS config kinds this checker probes.
M.KINDS = { "tuning", "devbind", "senscal", "fuelcal" }

-- ===== M.checkStatus: PURE per-kind status from runtime.cfgCache. =====
-- "OK" = a body arrived; "NO ANSWER" = the last attempt failed (FCS silent); "SYNC" = in flight or
-- not yet requested.
function M.checkStatus(cfgCache, kinds)
  cfgCache = cfgCache or {}
  local out = {}
  for _, kind in ipairs(kinds or M.KINDS) do
    local c = cfgCache[kind]
    if c and c.status == "ok" and c.body ~= nil then out[kind] = "OK"
    elseif c and c.status == "fail" then out[kind] = "NO ANSWER"
    else out[kind] = "SYNC" end
  end
  return out
end

-- ===== M.build: per-kind status lines + a REFRESH button. =====
function M.build(basalt, frame, runtime, nav)
  local w, h = frame:getSize()
  local x = 2
  local iw = math.max(1, w - 2)

  local titleLabel = configkit.titleRow(frame, w, M.title)

  local rowLabels = {}
  local y0 = 3
  for i, kind in ipairs(M.KINDS) do
    rowLabels[kind] = frame:addLabel({ x = x, y = y0 + (i - 1), width = iw, height = 1,
      autoSize = false, text = kind:upper() .. ": --" })
  end

  -- REFRESH: re-request every kind live (fire-and-forget; replies flip runtime.cfgCache and the
  -- next apply() repaints). PURE-of-fs: only touches the cfg client + cache.
  local function refreshAll()
    for _, kind in ipairs(M.KINDS) do
      runtime.cfgCache[kind] = { body = nil, status = "sync" }
      runtime.cfgClient:readKind(kind, function(body)
        runtime.cfgCache[kind] = { body = body, status = body ~= nil and "ok" or "fail" }
        runtime.uiRev = (runtime.uiRev or 0) + 1
      end)
    end
    runtime.uiRev = (runtime.uiRev or 0) + 1
  end

  local footerY = y0 + #M.KINDS + 1
  local actionRow = configkit.actionRow(frame, { x = x, y = footerY, w = iw }, {
    { label = "REFRESH", onClick = refreshAll },
  })
  local backRow = configkit.actionRow(frame, { x = x, y = footerY + 1, w = iw }, {
    { id = "back", label = "<", onClick = function() if nav then nav:pop() end end },
  })

  local function apply(_state)
    local st = M.checkStatus(runtime.cfgCache, M.KINDS)
    for _, kind in ipairs(M.KINDS) do
      rowLabels[kind]:setText(kind:upper() .. ": " .. st[kind])
    end
  end

  -- Kick a first probe so opening the page immediately queries the FCS.
  refreshAll()
  apply()

  return {
    id = M.id,
    apply = apply,
    elements = { titleLabel = titleLabel, rowLabels = rowLabels, actionRow = actionRow, backRow = backRow },
  }
end

return M
