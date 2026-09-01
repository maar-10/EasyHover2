-- fcs/bringup/logbuffer.lua
-- PURE rolling ring buffer of log records (raw captured samples in the flight runtime). Keeps
-- only the last `cap` rows so a P-to-dump always writes/uploads a bounded, RECENT window (RAM-safe
-- on a CC computer) while the FCS keeps flying. No IO -- the caller formats + delta-encodes rows
-- (fcs.bringup.instrument / fcs.bringup.logcodec) and does the file/carbide write.
local M = {}
local B = {}
B.__index = B

--- new(cap) -> buffer. cap defaults to 3000 (~3 min at 16Hz, ~80KB delta-encoded).
function M.new(cap)
  return setmetatable({ cap = (cap and cap > 0) and cap or 3000, buf = {}, head = 0, n = 0 }, B)
end

--- push(row): append, overwriting the oldest once at capacity.
function B:push(row)
  self.head = (self.head % self.cap) + 1
  self.buf[self.head] = row
  if self.n < self.cap then self.n = self.n + 1 end
end

--- rows() -> a fresh array of the buffered rows, oldest-to-newest (snapshot; safe to keep).
function B:rows()
  local out = {}
  -- oldest is head-n+1 (mod cap); walk forward n entries.
  local start = ((self.head - self.n) % self.cap) + 1
  for i = 0, self.n - 1 do
    out[#out + 1] = self.buf[((start - 1 + i) % self.cap) + 1]
  end
  return out
end

--- count() -> number of buffered rows (<= cap).
function B:count() return self.n end

return M
