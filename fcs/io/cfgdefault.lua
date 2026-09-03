-- fcs/io/cfgdefault.lua
-- Pure DEFAULT snapshot + fused-to-split migrate (Suite Advanced S5).
-- read/write are injected (bare filename, matching cfgspec/cfgaccess). No fs/peripherals.
local cfgroles = require("fcs.io.cfgroles")
local cfgspec = require("fcs.io.cfgspec")

local M = {}
M.FUSED = "eh2_hw_config.tbl"

-- snapshot(role, read, write) -> { copied = {kind,...}, skipped = {kind,...} }
-- Copies each current file for the role to its DEFAULT sibling except tuning (always skipped;
-- FCS tuning DEFAULT is the immutable code baseline). Missing currents are skipped.
function M.snapshot(role, read, write)
  local copied, skipped = {}, {}
  for _, kind in ipairs(cfgroles.kinds(role) or {}) do
    if kind == "tuning" then
      skipped[#skipped + 1] = kind
    else
      local body = read(cfgroles.file(kind))
      if body then
        write(cfgroles.defaultFile(kind), body)
        copied[#copied + 1] = kind
      else
        skipped[#skipped + 1] = kind
      end
    end
  end
  return { copied = copied, skipped = skipped }
end

-- migrate(read, write, role) -> { action = "split"|"noop"|"refuse" }
-- FCS-only: writing splits on UI/NAV would plant FCS files on the wrong PC. Missing/other
-- role refuses without touching files. If both split files exist: noop. Else if fused parses:
-- splitLegacy and save each missing split. Never deletes or rewrites the fused file.
function M.migrate(read, write, role)
  if role ~= "fcs" then return { action = "refuse" } end
  local dbBody = read(cfgspec.FILES.devbind)
  local scBody = read(cfgspec.FILES.senscal)
  if dbBody ~= nil and scBody ~= nil then
    return { action = "noop" }
  end
  local fusedBody = read(M.FUSED)
  if fusedBody == nil then return { action = "noop" } end
  local hw = textutils.unserialise(fusedBody)
  if type(hw) ~= "table" then return { action = "noop" } end
  local split = cfgspec.splitLegacy(hw)
  if dbBody == nil then cfgspec.save("devbind", split.devbind, write) end
  if scBody == nil then cfgspec.save("senscal", split.senscal, write) end
  return { action = "split" }
end

return M
