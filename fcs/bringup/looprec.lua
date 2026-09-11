-- fcs/bringup/looprec.lua -- minimal-impact loop-rate recorder for LOOP logging mode. Per control
-- cycle put(dt) appends one number (full per-cycle resolution, ~free). The stream flush calls
-- drain() every LOOP_PERIOD to get + clear the accumulated samples and append them compactly.
-- Safety cap: if the stream stalls and the buffer exceeds cap, drop the OLDEST so it can't OOM
-- (the recent window is what matters). No per-put I/O; drain formatting happens off the flight path.
local Looprec = {}
Looprec.__index = Looprec
function Looprec.new(cap)
  return setmetatable({ cap = cap or 20000, buf = {} }, Looprec)
end
function Looprec:put(dt)
  local b = self.buf
  b[#b + 1] = dt
  if #b > self.cap then table.remove(b, 1) end   -- drop oldest past cap (stalled-stream guard)
end
function Looprec:count() return #self.buf end
function Looprec:drain()
  local b = self.buf
  self.buf = {}
  return b
end
return Looprec
