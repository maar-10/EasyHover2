-- tests/test_controller_diag.lua
-- The DIAG poll-gate (controller/diag.lua): a pure, Basalt/peripheral-free state machine that is
-- the WHOLE comms-hygiene guarantee behind Phase P5b -- runtime:queryAll must NEVER fire unless
-- the DIAG page is currently shown AND at least pollIntervalMs has elapsed since the last poll.
-- A fake runtime records queryAll calls; `now` is injected (no os.epoch here).
local t = require("tests.framework")
local Diag = require("controller.diag")

local function fakeRuntime()
  local calls = {}
  return { calls = calls, queryAll = function(self, now) calls[#calls + 1] = now; return true end }, calls
end

t.test("new(): defaults to a 2000ms poll interval, starts hidden", function()
  local g = Diag.new()
  t.eq(g.pollIntervalMs, 2000)
  t.eq(g:isShown(), false)
end)

t.test("new({ pollIntervalMs = ... }): honours an explicit interval", function()
  local g = Diag.new({ pollIntervalMs = 500 })
  t.eq(g.pollIntervalMs, 500)
end)

t.test("poll while hidden: NEVER calls queryAll, even repeatedly / with time elapsed", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 100 })
  t.eq(g:poll(rt, 0), false)
  t.eq(g:poll(rt, 1000), false)
  t.eq(g:poll(rt, 5000), false)
  t.eq(#calls, 0, "hidden must be a true NO-OP: no transmit at all")
end)

t.test("show() + poll while due: calls queryAll exactly once", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 100 })
  g:show()
  t.eq(g:isShown(), true)
  local fired = g:poll(rt, 1000)
  t.truthy(fired, "first poll after show() is always due")
  t.eq(#calls, 1)
  t.eq(calls[1], 1000)
end)

t.test("shown but NOT yet due (before pollIntervalMs elapsed): does not poll again", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 2000 })
  g:show()
  g:poll(rt, 1000)
  t.eq(#calls, 1)
  local fired = g:poll(rt, 1000 + 1999) -- 1ms short of due
  t.eq(fired, false)
  t.eq(#calls, 1, "not due yet -- no second call")
end)

t.test("shown and due again (>= pollIntervalMs since last poll): polls again", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 2000 })
  g:show()
  g:poll(rt, 1000)
  local fired = g:poll(rt, 3000) -- exactly pollIntervalMs later
  t.truthy(fired)
  t.eq(#calls, 2)
  t.eq(calls[2], 3000)
end)

t.test("hide() then a due poll: NOT called (comms hygiene -- closing stops polling immediately)", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 100 })
  g:show()
  g:poll(rt, 0)
  t.eq(#calls, 1)
  g:hide()
  t.eq(g:isShown(), false)
  local fired = g:poll(rt, 10000) -- long due, but hidden
  t.eq(fired, false)
  t.eq(#calls, 1, "hide() must stop polling even though it would otherwise be due")
end)

t.test("show() again after hide(): first poll is immediately due (does not remember a stale cadence)", function()
  local rt, calls = fakeRuntime()
  local g = Diag.new({ pollIntervalMs = 2000 })
  g:show()
  g:poll(rt, 0)
  g:hide()
  g:show()
  local fired = g:poll(rt, 50) -- well under pollIntervalMs since the earlier poll at t=0
  t.truthy(fired, "reopening polls immediately, not on the old cadence")
  t.eq(#calls, 2)
end)

t.test("poll() never transmits when runtime is nil and gate is hidden (defensive: no crash, no call)", function()
  local g = Diag.new()
  local ok = pcall(function() g:poll(nil, 0) end)
  t.truthy(ok, "hidden poll must not even touch runtime")
end)

return true
