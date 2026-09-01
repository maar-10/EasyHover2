-- beacon/command.lua
-- PURE handler for the CONFIG/control remote-command ops (enable/disable/setInterval/setPos/verify/
-- reboot). NOT `query` -- that reply needs the runtime's live selfCheck/constellation, so it is built
-- in app.lua from Update.status(cfg.id, rt:statusPayload()) instead. Mutates the given cfg table in
-- place (mirrors the console's own [E]/[P]/[U] handlers) and returns what the caller (app.lua, the
-- peripheral glue) should DO about it: { save, verify, reboot, rearm }. No os/fs/peripheral access
-- here, so this self-tests headless.
local config = require("beacon.config")

local M = {}

local function validPos(p)
  return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local OPS = {
  enable = function(cfg) cfg.enabled = true; return { save = true } end,
  disable = function(cfg) cfg.enabled = false; return { save = true } end,
  setInterval = function(cfg, args)
    cfg.intervalMs = config.clampInterval(args and args.intervalMs)
    return { save = true, rearm = true }
  end,
  setPos = function(cfg, args)
    local pos = args and args.pos
    if validPos(pos) then
      cfg.pos = { x = pos.x, y = pos.y, z = pos.z }
      return { save = true }
    end
    return {}   -- malformed pos: ignore, no crash, no save
  end,
  verify = function() return { verify = true } end,
  reboot = function() return { reboot = true } end,
}

--- apply(cfg, op, args) -> { save?, verify?, reboot?, rearm? }. Mutates cfg for the mutating ops.
--- An unknown op is a defensive no-op (the fail-closed gate in beacon/update.lua already filters
--- to M.OPS, so this should never see one in practice).
function M.apply(cfg, op, args)
  local handler = OPS[op]
  if not handler then return {} end
  return handler(cfg, args)
end

return M
