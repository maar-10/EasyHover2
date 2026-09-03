-- ui/basalt/cfgseam.lua
-- FCS-backed read/write seams for the BIT/CONFIG menus. read() serves a serialised body from
-- runtime.cfgCache (populated by the cfg client's read replies); write() ships the change to the
-- running FCS via runtime.cfgClient:writeKind. Filename<->kind is cfgspec.FILES reversed, so the
-- menus keep calling cfgspec.load/save(kind, ...) unchanged -- only their DEFAULT seam moves from
-- local fs to the FCS. NO Basalt/peripheral/fs access here.
local cfgspec = require("fcs.io.cfgspec")

local M = {}

local KIND_BY_FILE = {}
for kind, file in pairs(cfgspec.FILES) do KIND_BY_FILE[file] = kind end

-- menus pass the bare filename (no leading slash), matching cfgspec.save/load's own contract.
function M.kindOf(filename) return KIND_BY_FILE[filename] end

-- read(runtime) -> function(filename) -> serialised body | nil (nil => cfgspec.load merges defaults)
function M.read(runtime)
  return function(filename)
    local kind = M.kindOf(filename)
    local c = kind and runtime.cfgCache and runtime.cfgCache[kind]
    if c and c.body ~= nil then return textutils.serialise(c.body) end
    return nil
  end
end

-- write(runtime, onDone) -> function(filename, body). Unserialises the menu's serialised cfg and
-- ships it to the FCS. onDone(kind, ok, err) fires when the ack (or timeout) arrives.
function M.write(runtime, onDone)
  return function(filename, body)
    local kind = M.kindOf(filename)
    if not kind then return false end
    local tbl = textutils.unserialise(body)
    if type(tbl) ~= "table" then return false end
    runtime.cfgClient:writeKind(kind, tbl, function(ok, err)
      if onDone then onDone(kind, ok, err) end
    end)
    return true
  end
end

return M
