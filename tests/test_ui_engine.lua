package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Engine = require("ui.engine")

local function fakeWriter()
  local w = { calls = {}, last = nil }
  w.fn = function(signal) w.calls[#w.calls+1] = signal; w.last = signal; return true end
  return w
end
local CFG = { pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false }

t.test("boots blocked -> physical HIGH, logical feeding=false", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:tick(0)
  t.eq(w.last, true); t.eq(e:status(0).master, false); t.eq(e:status(0).feeding, false)
end)

t.test("master ON kickstarts a feed pulse (LOW) then blocks (HIGH) after pulseMs", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.last, false); t.eq(e:status(0).feeding, true)
  e:tick(100); t.eq(w.last, false)
  e:tick(250); t.eq(w.last, true)
end)

t.test("feeds again (LOW) after intervalMs", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  e:setMaster(true, 0); e:tick(250)
  e:tick(1000); t.eq(w.last, true)
  e:tick(1750); t.eq(w.last, false)
end)

t.test("invert flips the physical polarity only", function()
  local w = fakeWriter()
  local e = Engine.new({ pulseMs = 250, intervalMs = 1500, invert = true, kickstart = true, masterDefault = false }, w.fn)
  e:tick(0)
  t.eq(w.last, false); t.eq(e:status(0).feeding, false)
end)

t.test("feedNow errors when master off, pulses (LOW) when on", function()
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)
  local ok = e:feedNow(0); t.eq(ok, false)
  e:setMaster(true, 0)
  local ok2 = e:feedNow(500); t.eq(ok2, true); t.eq(w.last, false)
end)

t.test("a failed write is retried on the next call (lastWritten only set on success)", function()
  local calls, ret = 0, false
  local function w(signal) calls = calls + 1; return ret end
  local e = Engine.new(CFG, w)     -- CFG = masterDefault false -> boots blocked
  e:tick(0)                        -- write attempt #1: signal=true, writer returns false
  t.eq(calls, 1)
  ret = true
  e:tick(1)                        -- must attempt again (not deduped), now succeeds
  t.eq(calls, 2)
  e:tick(2)                        -- now lastWritten==true -> deduped, no new call
  t.eq(calls, 2)
end)

-- A capturing 2-arg writer for latch mode.
local function fakeLatchWriter()
  local w = { calls = {} }
  w.fn = function(line, value) w.calls[#w.calls+1] = { line = line, value = value }; return true end
  return w
end
local LATCH_CFG = { mode = "latch", pulseMs = 250, intervalMs = 1500, kickstart = true, masterDefault = false }

t.test("latch: boot asserts a BLOCK pulse (raise then drop), feeding=false", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0)
  t.eq(w.calls[1].line, "block"); t.eq(w.calls[1].value, true)  -- raised at tick 0
  e:tick(150)                                                    -- >= LATCH_LINE_MS -> lowered
  t.eq(w.calls[2].line, "block"); t.eq(w.calls[2].value, false)
  t.eq(e:status(150).feeding, false)
end)

t.test("latch: master ON kickstarts a FEED pulse then BLOCK pulse after pulseMs", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:setMaster(true, 0)
  t.eq(w.calls[1].line, "feed"); t.eq(w.calls[1].value, true)   -- feed line raised
  e:tick(150); t.eq(w.calls[2].line, "feed"); t.eq(w.calls[2].value, false)  -- feed line dropped
  e:tick(250)                                                    -- pulseMs -> re-block
  t.eq(w.calls[3].line, "block"); t.eq(w.calls[3].value, true)
end)

t.test("latch: feed line is fully dropped before the block pulse rises", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:setMaster(true, 0)
  local feedDown, blockUp
  -- drive the timeline
  e:tick(150); e:tick(250)
  for i, c in ipairs(w.calls) do
    if c.line == "feed" and c.value == false then feedDown = i end
    if c.line == "block" and c.value == true and not blockUp then blockUp = i end
  end
  t.eq(feedDown ~= nil and blockUp ~= nil and feedDown < blockUp, true)
end)

t.test("latch: repeated blocked ticks emit no repeat BLOCK pulses", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0); e:tick(150)          -- one block raise + drop
  local n = #w.calls
  e:tick(300); e:tick(450); e:tick(600)  -- still master-off, still blocked
  t.eq(#w.calls, n)               -- no new pulses
end)

t.test("latch: blockNow re-fires a BLOCK pulse (force)", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0); e:tick(150)
  local n = #w.calls
  e:blockNow()
  t.eq(w.calls[n+1].line, "block"); t.eq(w.calls[n+1].value, true)
end)

t.test("latch: a mis-set pulseMs (100, below the 150+50 line-drop floor) still drops FEED before BLOCK rises", function()
  local w = fakeLatchWriter()
  local e = Engine.new({ mode = "latch", pulseMs = 100, intervalMs = 1500, kickstart = true, masterDefault = false }, w.fn)
  e:setMaster(true, 0)              -- feed line raised at tick 0
  -- Drive the timeline through the raw pulseMs (100, where an un-clamped pulse would end and
  -- try to raise BLOCK) and on to the clamped effective end (max(100,150+50)=200), and past the
  -- feed line's own LATCH_LINE_MS drop point (150), in ticks that straddle each boundary.
  e:tick(100); e:tick(150); e:tick(200)
  local feedDown, blockUp
  for i, c in ipairs(w.calls) do
    if c.line == "feed" and c.value == false and not feedDown then feedDown = i end
    if c.line == "block" and c.value == true and not blockUp then blockUp = i end
  end
  t.eq(feedDown ~= nil and blockUp ~= nil, true, "both events happened")
  t.eq(feedDown < blockUp, true, "FEED must drop before BLOCK rises -- no both-lines-high overlap")
end)

t.test("basic mode: pulseMs timing is unchanged (blocks exactly at tick(250))", function()
  local w = fakeWriter()
  local e = Engine.new({ pulseMs = 250, intervalMs = 1500, invert = false, kickstart = true, masterDefault = false }, w.fn)
  e:setMaster(true, 0)
  t.eq(w.last, false)
  e:tick(249); t.eq(w.last, false)
  e:tick(250); t.eq(w.last, true)
end)

t.test("basic mode: the blocked state is physically RE-DRIVEN every reassertMs", function()
  -- A relay reboot silently drops its physical output while our RAM `lastWritten` still matches
  -- the desired signal -> write-on-change would never restore it, and an unblocked funnel with
  -- the master off drains the vault. After reassertMs the dedup must be invalidated so the safe
  -- state is written again.
  local w = fakeWriter(); local e = Engine.new(CFG, w.fn)   -- CFG.reassertMs defaults to 2000
  e:tick(0)                          -- blocked write #1 (signal=true)
  e:tick(1000); e:tick(1999)         -- deduped: still inside the reassert window
  local n = #w.calls
  t.eq(n, 1)
  e:tick(2000)                       -- >= reassertMs since the last successful write
  t.eq(#w.calls, n + 1, "blocked state physically re-written")
  t.eq(w.calls[n+1], true, "re-driven value is the blocked (HIGH) signal")
  e:tick(2500)                       -- freshly re-asserted -> deduped again until next window
  t.eq(#w.calls, n + 1)
end)

t.test("latch: a lost BLOCK latch is re-fired by the periodic re-assert", function()
  local w = fakeLatchWriter(); local e = Engine.new(LATCH_CFG, w.fn)
  e:tick(0); e:tick(150)             -- BLOCK raise + line drop; lastWriteAt ~= 150
  e:tick(2100)                       -- past reassertMs -> BLOCK trigger must fire again
  local refired
  for _, c in ipairs(w.calls) do
    if c.line == "block" and c.value == true then refired = c end
  end
  t.truthy(refired, "BLOCK latch re-asserted")
end)
