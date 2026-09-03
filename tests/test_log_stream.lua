-- tests/test_log_stream.lua
-- PURE streaming-mode control for the FCS flight-log upload (fcs/bringup/logstream.lua):
-- P toggles streaming (idle -> start, streaming -> flush+stop); the 10s timer task
-- asks tick() whether an auto-append is due. No IO -- tools/flight.lua owns the
-- file/carbide write, exactly like the FCS logger.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local LogStream = require("fcs.bringup.logstream")

t.test("P when idle returns start and enters streaming", function()
  local s = LogStream.new()
  t.eq(LogStream.key(s, "p"), "start")
  t.eq(s.streaming, true)
end)

t.test("uppercase P also starts when idle", function()
  local s = LogStream.new()
  t.eq(LogStream.key(s, "P"), "start")
  t.eq(s.streaming, true)
end)

t.test("P when streaming returns stop and leaves streaming", function()
  local s = LogStream.new()
  LogStream.key(s, "p")
  t.eq(LogStream.key(s, "p"), "stop")
  t.eq(s.streaming, false)
end)

t.test("P toggles back to start after a stop", function()
  local s = LogStream.new()
  LogStream.key(s, "p")
  LogStream.key(s, "p")
  t.eq(LogStream.key(s, "P"), "start")
  t.eq(s.streaming, true)
end)

t.test("other keys are ignored and leave state untouched", function()
  local s = LogStream.new()
  t.eq(LogStream.key(s, "l"), "ignore")
  t.eq(LogStream.key(s, "x"), "ignore")
  t.eq(s.streaming, false)
  LogStream.key(s, "p")
  t.eq(LogStream.key(s, "l"), "ignore")
  t.eq(s.streaming, true, "stray keys never stop a stream")
end)

t.test("tick is skip when idle, dump when streaming", function()
  local s = LogStream.new()
  t.eq(LogStream.tick(s), "skip")
  LogStream.key(s, "p")
  t.eq(LogStream.tick(s), "dump")
  LogStream.key(s, "p")
  t.eq(LogStream.tick(s), "skip")
end)

t.test("auto-append period is 10 seconds", function()
  t.eq(LogStream.PERIOD, 10)
end)

t.test("auto dumps while streaming and sustainable, skips when idle", function()
  local s = LogStream.new()
  t.eq(LogStream.auto(s, true), "skip")
  LogStream.key(s, "p")
  t.eq(LogStream.auto(s, true), "dump")
  t.eq(s.streaming, true, "dump leaves the stream running")
end)

t.test("auto leaves (no dump) when streaming turned unsustainable", function()
  local s = LogStream.new()
  LogStream.key(s, "p")
  t.eq(LogStream.auto(s, false), "leave")
  t.eq(s.streaming, false, "plain-mode tripwire is an explicit leave")
  t.eq(LogStream.auto(s, false), "skip", "settled idle stays skipped")
end)

t.test("finish flushes only when a stream was left on, then clears", function()
  local s = LogStream.new()
  t.eq(LogStream.finish(s), false)
  LogStream.key(s, "p")
  t.eq(LogStream.finish(s), true)
  t.eq(s.streaming, false, "exit flush ends streaming")
  t.eq(LogStream.finish(s), false, "second finish is a no-op")
end)

return true
