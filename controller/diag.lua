-- controller/diag.lua
-- The DIAG page's poll gate -- Phase P5b's comms-hygiene centerpiece, PURE and Basalt/peripheral-
-- free so it self-tests headless with no CraftOS-PC involved (tests/test_controller_diag.lua).
--
-- Contract: `runtime:queryAll(now)` (controller/runtime.lua) fires ONLY while the DIAG page is
-- shown AND at least `pollIntervalMs` has elapsed since the last poll. While hidden this is a TRUE
-- no-op -- poll() never even looks at `runtime` -- so there is no code path from a closed DIAG page
-- to a transmit. controller/app.lua owns exactly one of these per app instance, calling show()/
-- hide() from the DIAG button / back control, and poll(runtime, now) from its existing ~1s timer
-- coroutine (the SAME coroutine already driving repaint -- no new busy loop, no sleep-eating).
local M = {}
local D = {}
D.__index = D

local DEFAULT_POLL_MS = 2000

--- new(opts): opts.pollIntervalMs (default 2000). Starts hidden, never polled.
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    pollIntervalMs = opts.pollIntervalMs or DEFAULT_POLL_MS,
    shown = false,
    lastPoll = nil,
  }, D)
end

--- show(): DIAG page opened. Resets the poll cadence so the very next poll() fires immediately
--- (reopening never waits out a stale interval from a previous session).
function D:show()
  self.shown = true
  self.lastPoll = nil
end

--- hide(): DIAG page closed. Polling stops on the next tick, unconditionally -- no drain/grace
--- period, no in-flight follow-up.
function D:hide()
  self.shown = false
end

function D:isShown() return self.shown end

--- poll(runtime, now): the ONLY path to runtime:queryAll. Hidden -> untouched no-op (returns
--- false, `runtime` is never even indexed). Shown but not yet due -> false, no call. Shown and due
--- (never polled yet, or >= pollIntervalMs since the last poll) -> calls runtime:queryAll(now),
--- records `now` as the last poll, returns true.
function D:poll(runtime, now)
  if not self.shown then return false end
  if self.lastPoll ~= nil and (now - self.lastPoll) < self.pollIntervalMs then return false end
  runtime:queryAll(now)
  self.lastPoll = now
  return true
end

return M
