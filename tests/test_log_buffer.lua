-- tests/test_log_buffer.lua
-- Pure rolling log ring buffer (fcs/bringup/logbuffer.lua): keeps the last N rows so P-to-dump
-- always uploads a bounded, recent window. No IO.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local LogBuffer = require("fcs.bringup.logbuffer")

t.test("under capacity returns all rows in push order", function()
  local b = LogBuffer.new(3)
  b:push("a"); b:push("b")
  local r = b:rows()
  t.eq(#r, 2); t.eq(r[1], "a"); t.eq(r[2], "b")
  t.eq(b:count(), 2)
end)

t.test("over capacity keeps only the last N rows, oldest-to-newest", function()
  local b = LogBuffer.new(3)
  for i = 1, 5 do b:push("r" .. i) end
  local r = b:rows()
  t.eq(#r, 3, "capped at N")
  t.eq(r[1], "r3"); t.eq(r[2], "r4"); t.eq(r[3], "r5")
  t.eq(b:count(), 3)
end)

t.test("keeps rolling after a dump -- rows() is a snapshot, push continues", function()
  local b = LogBuffer.new(2)
  b:push("a"); b:push("b")
  local snap = b:rows()
  b:push("c")               -- rolls: drops "a"
  t.eq(#snap, 2); t.eq(snap[1], "a")     -- earlier snapshot unaffected
  t.eq(b:rows()[1], "b"); t.eq(b:rows()[2], "c")
end)

t.test("total() counts every push monotonically, even past cap", function()
  local b = LogBuffer.new(3)
  t.eq(b:total(), 0)
  for i = 1, 7 do b:push("r" .. i) end
  t.eq(b:total(), 7, "monotonic row counter past cap")
  t.eq(b:count(), 3, "count stays capped")
end)

t.test("tail(n) returns the last n rows, oldest-to-newest", function()
  local b = LogBuffer.new(5)
  for i = 1, 4 do b:push("r" .. i) end
  local last2 = b:tail(2)
  t.eq(#last2, 2)
  t.eq(last2[1], "r3"); t.eq(last2[2], "r4", "tail(2) == the last two pushes")
end)

t.test("tail(n) returns everything when n exceeds the count", function()
  local b = LogBuffer.new(3)
  b:push("a"); b:push("b")
  local all = b:tail(10)
  t.eq(#all, 2); t.eq(all[1], "a")
end)

t.test("tail(0) is empty; tail honors recency after rolling", function()
  local b = LogBuffer.new(3)
  for i = 1, 5 do b:push("r" .. i) end
  t.eq(#b:tail(0), 0)
  local tail = b:tail(2)
  t.eq(tail[1], "r4"); t.eq(tail[2], "r5")
end)

return true
