-- fcs/io/cfgroles.lua
-- Pure role -> config-kind registry for the per-role disk courier (S3).
-- Disk filenames for FCS kinds MUST equal cfgspec.FILES (boot diskSource).
local cfgspec = require("fcs.io.cfgspec")

local M = {}
M.ROLES = { "fcs", "ui", "nav" }

local KINDS = {
  fcs = { "devbind", "senscal", "tuning", "fuelcal" },
  ui  = { "uicfg" },
  nav = { "nav", "nav_wpt" },
}

local FILES = {
  devbind = cfgspec.FILES.devbind,
  senscal = cfgspec.FILES.senscal,
  tuning  = cfgspec.FILES.tuning,
  fuelcal = cfgspec.FILES.fuelcal,
  uicfg   = "eh2_ui_config.tbl",
  nav     = "eh2_nav.tbl",
  nav_wpt = "eh2_nav_wpt.tbl",
}

local ROLE_OF = {}
for role, kinds in pairs(KINDS) do
  for _, kind in ipairs(kinds) do ROLE_OF[kind] = role end
end

function M.kinds(role) return KINDS[role] end
function M.file(kind) return FILES[kind] end
function M.roleOf(kind) return ROLE_OF[kind] end

function M.defaultFile(kind)
  local f = M.file(kind)
  if not f then return nil end
  return (f:gsub("%.tbl$", ".default.tbl"))
end
function M.sessionFile(kind)
  local f = M.file(kind)
  if not f then return nil end
  return (f:gsub("%.tbl$", ".session.tbl"))
end

return M
