-- fcs/comms/protocol.lua
local M = {}

-- Compact serialization: telemetry frames cross the modem at 10 Hz and the default pretty
-- printer's newlines/indentation are pure airtime + CPU on both ends. compact=true emits a
-- single line with identical fidelity. Falls back to the default serializer if the option is
-- unsupported (older CC:T).
function M.encode(frame)
  local ok, str = pcall(textutils.serialize, frame, { compact = true })
  if ok then return str end
  return textutils.serialize(frame)
end

function M.decode(str)
  if type(str) ~= "string" then return nil end
  local ok, val = pcall(textutils.unserialize, str)
  if not ok or type(val) ~= "table" then return nil end
  return val
end

return M
