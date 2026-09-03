local cfgspec = require("fcs.io.cfgspec")

local M = {
  SOURCES = {
    binding = { "current", "default", "disk" },
    sensor  = { "current", "default", "disk" },
    tuning  = { "current", "default", "disk" },
    fuelcal = { "current", "default", "disk" },
  },
}

-- concern name -> cfgspec kind (NOT the same string for binding/sensor)
local KIND = { binding = "devbind", sensor = "senscal", tuning = "tuning", fuelcal = "fuelcal" }

local function isMember(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

function M.resolve(choices, sources)
  local cfgs = {}
  for _, concern in ipairs({ "binding", "sensor", "tuning", "fuelcal" }) do
    local src = choices[concern]
    if not isMember(M.SOURCES[concern], src) then
      return false, nil, concern .. ": invalid source '" .. tostring(src) .. "'", concern
    end
    local cfg = sources.get(concern, src)
    if cfg == nil then
      return false, nil, concern .. " (" .. tostring(src) .. "): no config available", concern
    end
    local ok, verr = cfgspec.validate(KIND[concern], cfg)
    if not ok then
      return false, nil, concern .. " (" .. tostring(src) .. "): " .. tostring(verr), concern
    end
    cfgs[concern] = cfg
  end

  local assembled = {
    hw = cfgspec.assembleHw(cfgs.binding, cfgs.sensor),
    tuning = cfgs.tuning,
    fuelcal = cfgs.fuelcal,
  }
  return true, assembled, nil
end

return M
