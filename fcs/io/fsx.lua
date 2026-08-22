-- fcs/io/fsx.lua
-- Shared atomic-fs helper: the PURE-of-serialisation fs primitives that used to be duplicated as
-- realRead/realWrite (and friends) closures across tools/calibrate.lua, tools/binddevices.lua,
-- ui/basalt/bitconfig/{tuning,mdb,senscal,dtc}.lua, ui/basalt/app.lua and fcs/boot/loaderui.lua.
-- This module does fs ops ONLY -- no textutils.serialise/unserialise, no cfgspec knowledge, no
-- concept of a config "kind". Callers that need serialisation stay on fcs/io/config.lua or
-- cfgspec.lua, which are a different, frozen layer.
--
-- NO fs access at module load -- everything lives inside these functions, so
-- `require("fcs.io.fsx")` loads clean headless.
local M = {}

-- M.read(path) -> file body string, or nil if the path is absent, a directory, or fails to open.
-- Mirrors the existing realRead/readFile closures exactly.
function M.read(path)
  if fs and fs.exists(path) and not fs.isDir(path) then
    local f = fs.open(path, "r")
    if not f then return nil end
    local body = f.readAll()
    f.close()
    return body
  end
  return nil
end

-- M.writeAtomic(path, body) -> true on success. Writes to `path .. ".tmp"`, deletes an existing
-- `path`, then fs.move(tmp, path) -- the crash-safe tmp-then-move pattern mirrored EXACTLY from
-- the existing realWrite/saveConfig closures.
-- Returns false (not a crash) when the tmp file cannot be opened (disk full, read-only media).
-- The destination is only deleted AFTER the tmp write succeeds, so a failure here leaves the
-- previous good file untouched.
function M.writeAtomic(path, body)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false end
  f.write(body)
  f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

-- M.delete(path) -> deletes path if present; no-op (not an error) if absent.
function M.delete(path)
  if fs.exists(path) then fs.delete(path) end
end

-- M.exists(path) -> boolean.
function M.exists(path)
  return fs and fs.exists(path) or false
end

return M
