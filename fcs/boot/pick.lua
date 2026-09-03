-- fcs/boot/pick.lua
-- Pure per-config boot picker shared by UI and NAV launchers.
-- resolve(choice, sources) -> cfg|nil, err. apply writes session vs current.
-- No peripheral/disk/read() at module load -- sources/write/delete are injected.

local M = {
  SOURCES = { "current", "default", "disk" },
}

local function isMember(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- Empty/invalid input maps to current so unattended boot still works.
function M.parseChoice(input)
  local n = tonumber(input)
  return M.SOURCES[n] or "current"
end

function M.resolve(choice, sources)
  if not isMember(M.SOURCES, choice) then
    return nil, "invalid source '" .. tostring(choice) .. "'"
  end
  local cfg = sources.get(choice)
  if cfg == nil and choice ~= "current" then
    return nil, choice .. ": no config available"
  end
  return cfg, nil
end

-- DEFAULT writes the session overlay and does not clobber current.
-- Disk import writes current and deletes any leftover session.
-- Current deletes the session overlay and does not rewrite current.
function M.apply(choice, cfg, write, delete, paths)
  if not isMember(M.SOURCES, choice) then
    return false, "invalid source '" .. tostring(choice) .. "'"
  end
  if choice == "default" then
    if type(cfg) ~= "table" then return false, "default: no config available" end
    write(paths.session, textutils.serialise(cfg))
    return true
  end
  if choice == "disk" then
    if type(cfg) ~= "table" then return false, "disk: no config available" end
    write(paths.current, textutils.serialise(cfg))
    delete(paths.session)
    return true
  end
  delete(paths.session)
  return true
end

-- In-game wiring for UI/NAV launchers. Uses real fs/peripheral/read(); not headless-tested.
-- Empty/invalid input is current so unattended boot still works.
function M.applyKind(kind, label)
  local cfgroles = require("fcs.io.cfgroles")
  local fsx = require("fcs.io.fsx")

  local function readTable(path)
    local body = fsx.read(path)
    if not body then return nil end
    local ok, tbl = pcall(textutils.unserialise, body)
    if ok and type(tbl) == "table" then return tbl end
    return nil
  end

  local function diskTable(filename)
    local drive = peripheral.find("drive")
    if not drive or not drive.isDiskPresent or not drive.isDiskPresent() then return nil end
    local mount = drive.getMountPath and drive.getMountPath()
    if not mount then return nil end
    return readTable("/" .. mount .. "/" .. filename)
  end

  print("")
  print("== " .. label .. " ==")
  print("  1) current")
  print("  2) DEFAULT")
  print("  3) disk")
  write("choice [1]: ")
  local choice = M.parseChoice(read())
  local filename = cfgroles.file(kind)
  if not filename then
    print("FAILED: unknown config kind")
    return false
  end
  local sources = {
    get = function(src)
      if src == "current" then return readTable("/" .. filename) end
      if src == "default" then return readTable("/" .. cfgroles.defaultFile(kind)) end
      if src == "disk" then return diskTable(filename) end
      return nil
    end,
  }
  local cfg, err = M.resolve(choice, sources)
  if err then
    print("FAILED: " .. tostring(err))
    return false
  end
  return M.apply(choice, cfg, fsx.writeAtomic, fsx.delete, {
    current = "/" .. filename,
    session = "/" .. cfgroles.sessionFile(kind),
  })
end

return M
