-- tools/fcs2disk.lua
-- STANDALONE FCS console tool (SuiteX-installed like tools/splitconfig.lua -- NOT a flight-app
-- change): dumps the FCS's 4 local split config files (eh2_devbind/senscal/tuning/fuelcal) onto a
-- shared networked disk so the UI PC's DTC can IMPORT ALL them. PURE core here (plan()); M.run()
-- below resolves the drive + writes and is deps-injected (headless-testable via fakeDeps; the
-- launcher itself is not unit-tested). Filenames NEVER hardcoded -- always cfgspec.FILES[kind].
local cfgspec = require("fcs.io.cfgspec")

local M = {}

-- FCS kinds this tool dumps, in cfgspec order (uicfg is UI-only and not on the FCS).
M.KINDS = { "devbind", "senscal", "tuning", "fuelcal" }

-- plan(existing) -> { action, kinds, missing, err? }.
-- existing = { present = {kind=bool}, mount = <string|nil> }.
function M.plan(existing)
  existing = existing or {}
  local present = existing.present or {}
  if existing.mount == nil then return { action = "no-mount", kinds = {}, missing = {} } end
  local kinds, missing = {}, {}
  for _, k in ipairs(M.KINDS) do
    if present[k] == true then kinds[#kinds + 1] = k else missing[#missing + 1] = k end
  end
  if #kinds == 0 then return { action = "abort", kinds = kinds, missing = missing, err = "no local FCS configs to dump" } end
  return { action = "write", kinds = kinds, missing = missing }
end

-- ---- in-game run: resolve the drive, dump present local kinds to the disk. Not headless-tested. ----
local fsx = require("fcs.io.fsx")

local function realExists(path) return fs.exists(path) and not fs.isDir(path) end
local function realFind(kind) return peripheral.find(kind) end

-- run(deps) -> human summary string. deps.read/write/exists default to fsx; deps.find to peripheral.find.
function M.run(deps)
  deps = deps or {}
  local read   = deps.read   or fsx.read
  local write  = deps.write  or fsx.writeAtomic
  local exists = deps.exists or realExists
  local find   = deps.find   or realFind

  local drive = find("drive")
  local mount = drive and drive.getMountPath and drive.getMountPath() or nil

  local present = {}
  for _, k in ipairs(M.KINDS) do present[k] = exists("/" .. cfgspec.FILES[k]) end

  local r = M.plan({ present = present, mount = mount })
  if r.action == "no-mount" then return "No disk drive/disk found -- nothing written. Insert the shared disk and retry." end
  if r.action == "abort" then return "ABORT: " .. tostring(r.err) .. " (nothing written)." end

  local wrote = {}
  for _, k in ipairs(r.kinds) do
    local body = read("/" .. cfgspec.FILES[k])
    if body ~= nil then
      write("/" .. mount .. "/" .. cfgspec.FILES[k], body)
      wrote[#wrote + 1] = k
    end
  end
  local missing = (#r.missing > 0) and (" (missing locally: " .. table.concat(r.missing, ", ") .. ")") or ""
  return "Dumped " .. table.concat(wrote, ", ") .. " to disk '" .. mount .. "'" .. missing .. "."
end

return M
