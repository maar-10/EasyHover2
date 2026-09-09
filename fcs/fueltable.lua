-- fcs/fueltable.lua -- fuel thrust-ratio table + compensation math. Pure; no globals/peripherals.
-- Biodiesel (60% thrust on this server) is the calibrated BASELINE: fuelScale 1.0 = today's tuning.
-- fuelScale(name) = BASELINE_PCT / pct(name): stronger fuel -> < 1 (less power, less burn); weaker
-- fuel -> > 1 (more power, saturates -> "BAD FUEL"). Percentages are the server's current values.
local M = {}
M.BASELINE_PCT = 60
M.default = "Biodiesel"
-- Display order (as the picker lists them).
M.list = {
  { name = "Plant Oil",         pct = 20 },
  { name = "Ethanol",           pct = 200 },
  { name = "Biodiesel",         pct = 60 },
  { name = "Sulfurized Diesel", pct = 75 },
  { name = "Diesel",            pct = 80 },
  { name = "Gasoline",          pct = 125 },
  { name = "Kerosene",          pct = 150 },
  { name = "Turpentine",        pct = 30 },
}
local byName = {}
for _, f in ipairs(M.list) do byName[f.name] = f.pct end
function M.pctOf(name) return byName[name] end
function M.scaleFor(name)
  local p = byName[name]
  if not p or p <= 0 then return nil end
  return M.BASELINE_PCT / p
end
function M.isBad(name)
  local p = byName[name]
  return (p ~= nil) and (p < M.BASELINE_PCT) or false
end
function M.options()
  local o = {}
  for i, f in ipairs(M.list) do o[i] = { text = f.name .. " " .. f.pct .. "%", value = f.name } end
  return o
end
M.abbr = {
  ["Plant Oil"] = "POIL", ["Ethanol"] = "ETH", ["Biodiesel"] = "BDSL",
  ["Sulfurized Diesel"] = "SDSL", ["Diesel"] = "DSL", ["Gasoline"] = "GAS",
  ["Kerosene"] = "KERO", ["Turpentine"] = "TURP",
}
function M.abbrevOf(name)
  if name == nil then name = M.default end
  return M.abbr[name] or (name and name:sub(1, 4):upper()) or "?"
end
return M
