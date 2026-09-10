-- fcs/bringup/logmode.lua -- resolve _G.EH2_FLIGHTLOG into full/loop flags. true == full (legacy).
local M = {}
function M.full(mode) return mode == "full" or mode == true end
function M.loop(mode) return mode == "loop" end
return M
