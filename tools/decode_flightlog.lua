-- decode_flightlog <in> [out]
-- Restores plain slim CSV from a delta-encoded flight log (fcs.bringup.logcodec wire format).
-- Summary (#) lines pass through above the CSV. Runs in-game (fs) or on a PC (io).
-- No args: in = /eh2_flight_log.csv (eh2_flight_log.csv on PC).
package.path = "/?.lua;/?/init.lua;" .. package.path
local Codec = require("fcs.bringup.logcodec")

local args = { ... }
local inp = args[1] or (fs and "/eh2_flight_log.csv" or "eh2_flight_log.csv")
local outp = args[2]

local raw
if fs then
  local f = fs.open(inp, "r")
  if not f then error("cannot open " .. tostring(inp)) end
  raw = f.readAll() or ""
  f.close()
else
  local f = io.open(inp, "r")
  if not f then error("cannot open " .. tostring(inp)) end
  raw = f:read("*a") or ""
  f:close()
end

local rows, header = Codec.decode(raw)
local summary = {}
for line in raw:gmatch("([^\n]*)\n?") do
  if line:sub(1, 1) == "#" then summary[#summary+1] = line end
end
local text = table.concat(summary, "\n") .. (#summary > 0 and "\n\n" or "")
  .. (header and header .. "\n" or "")
  .. table.concat(rows, "\n") .. (#rows > 0 and "\n" or "")

if outp then
  if fs then
    local o = fs.open(outp, "w"); o.write(text); o.close()
  else
    local o = io.open(outp, "w"); o:write(text); o:close()
  end
else
  print(text)
end