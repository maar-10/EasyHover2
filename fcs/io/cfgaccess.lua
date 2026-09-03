-- fcs/io/cfgaccess.lua
-- Pure FCS-side config provider/applier for the live config responder (tools/flight.lua's
-- configTask). getKind resolves a kind's live cfg EXACTLY as tools/flight.lua's loadConfig does
-- (session overlay > split file > fused /eh2_hw_config.tbl fallback); setKind validates and
-- persists to the FCS's OWN files (never the fused legacy), drops that kind's session overlay
-- (explicit save ends DEFAULT-for-this-boot), and materializes the sibling split for
-- devbind/senscal so cfgspec.tryAssemble (which needs BOTH splits) actually uses the operator's
-- change next boot. read/write/delete are injected (bare filename, matching cfgspec +
-- tools/flight.lua's readFile/writeFile). NO peripherals/os/Basalt.
local cfgspec = require("fcs.io.cfgspec")

local M = {}
M.FUSED = "eh2_hw_config.tbl"   -- read-only legacy fallback (retired in S5); never written here

local SIBLING = { devbind = "senscal", senscal = "devbind" }

-- splitLegacy(fused) | nil (nil = no/unparseable fused file). PURE.
local function fusedSplit(read)
  local body = read(M.FUSED)
  if body == nil then return nil end
  local hw = textutils.unserialise(body)
  if type(hw) ~= "table" then return nil end
  return cfgspec.splitLegacy(hw)
end

-- getKind(kind, read) -> the FCS's live cfg TABLE. Prefers session overlay (DEFAULT-for-this-boot)
-- over the current file, matching tools/flight.lua loadConfig / loadTuning. tuning/fuelcal: own
-- file merged with defaults. devbind/senscal: session > split > fused legacy slice > defaults
-- (a fresh FCS stays editable -- never a nil the UI would read as "FCS silent").
function M.getKind(kind, read)
  if kind == "tuning" or kind == "fuelcal" then
    return (cfgspec.loadLive(kind, read))
  end
  if kind == "devbind" or kind == "senscal" then
    local cfg, existed, err = cfgspec.loadLive(kind, read)
    if existed and not err then return cfg end
    local split = fusedSplit(read)
    local seed = split and split[kind]
    if seed ~= nil then return cfgspec.merge(kind, seed) end
    return cfgspec.merge(kind, {})
  end
  error("cfgaccess: unknown kind " .. tostring(kind))
end

local function dropSession(kind, delete)
  if not delete then return end
  local sf = cfgspec.sessionFile(kind)
  if sf then delete(sf) end
end

-- setKind(kind, body, read, write, delete) -> ok, err. Validate then persist. Successful save
-- deletes that kind's session overlay (explicit save ends DEFAULT-for-this-boot). For
-- devbind/senscal also materialize the sibling split when absent (seeded from the fused slice
-- if any, else defaults).
function M.setKind(kind, body, read, write, delete)
  local ok, err = cfgspec.validate(kind, body)
  if not ok then return false, err end
  if kind == "tuning" or kind == "fuelcal" then
    cfgspec.save(kind, body, write)
    dropSession(kind, delete)
    return true
  end
  if kind == "devbind" or kind == "senscal" then
    cfgspec.save(kind, body, write)
    dropSession(kind, delete)
    local sib = SIBLING[kind]
    local _, sibExisted = cfgspec.load(sib, read)
    if not sibExisted then
      local split = fusedSplit(read)
      local seed = split and split[sib]
      cfgspec.save(sib, cfgspec.merge(sib, seed or {}), write)
    end
    return true
  end
  return false, "unknown kind"
end

return M
