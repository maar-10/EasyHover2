-- beacon/update.lua
-- PURE codec + fail-closed token gate for the remote beacon-update protocol. No peripherals/os/fs.
-- Rides the shared GPS channel (default 65000) using the SAME wire format as nav/comms/gpsproto
-- (fcs.comms.protocol), so a beacon/NAV that also hears GPS frames is never confused: gpsproto
-- rejects these (no numeric x/y/z) and this codec rejects GPS frames (wrong `k`).
local protocol = require("fcs.comms.protocol")

local M = {}
M.CMD_KIND = "eh2_beacon_update"
M.ACK_KIND = "eh2_beacon_update_ack"
M.CMD2_KIND = "eh2_beacon_cmd"       -- generalized op-tagged remote command
M.STATUS_KIND = "eh2_beacon_status"  -- query reply (Task 3)
M.OPS = { enable = true, disable = true, verify = true, query = true,
          setPos = true, setInterval = true, reboot = true }

function M.cmd(op, token, args) return { k = M.CMD2_KIND, op = op, token = token, args = args } end

--- A token is valid iff it is a non-empty string once whitespace is stripped.
function M.validToken(t)
  return type(t) == "string" and t:gsub("%s", "") ~= ""
end

function M.command(token) return { k = M.CMD_KIND, token = token } end
function M.ack(id) return { k = M.ACK_KIND, id = id } end

function M.encode(frame) return protocol.encode(frame) end

--- decode(str) -> frame | nil. Only returns frames of a known kind.
function M.decode(str)
  local f = protocol.decode(str)
  if type(f) ~= "table" then return nil end
  if f.k == M.CMD_KIND or f.k == M.ACK_KIND then return f end
  return nil
end

--- The single fail-closed gate: accept a command only when both tokens are valid and equal.
function M.accepts(frame, cfgToken)
  if type(frame) ~= "table" or frame.k ~= M.CMD_KIND then return false end
  if not M.validToken(cfgToken) then return false end
  if not M.validToken(frame.token) then return false end
  return frame.token == cfgToken
end

return M
