-- fcs/bringup/logstream.lua
-- PURE streaming-mode control for the FCS flight-log carbide upload. P toggles: idle -> start
-- (the caller creates the stream + uploads the window), streaming -> stop (the caller flushes
-- pending rows first, then leaves streaming). tick() tells the 10s timer task whether an
-- auto-append is due. No IO -- the caller owns the file/carbide write, exactly like the
-- FCS logger (fcs.bringup.logbuffer) and the UI logger (ui/basalt/uilog).
local M = {}

--- Auto-append cadence in seconds. 10s is ~160 rows at 16Hz -- far inside the 3000-row
--- ring window, so the stream can no longer overrun between uploads, at half the
--- carbide traffic of a 5s tick.
M.PERIOD = 10

--- new() -> control state. streaming=false: P starts; streaming=true: P stops.
function M.new()
  return { streaming = false }
end

--- key(s, ch) -> "start" | "stop" | "ignore". Applies the toggle transition for P/p;
--- every other key is ignored and never touches the state (stray keys can't stop a stream).
function M.key(s, ch)
  if ch ~= "p" and ch ~= "P" then return "ignore" end
  if s.streaming then
    s.streaming = false
    return "stop"
  end
  s.streaming = true
  return "start"
end

--- tick(s) -> "dump" | "skip". The timer task appends only while streaming.
function M.tick(s)
  if s.streaming then return "dump" end
  return "skip"
end

--- auto(s, sustainable) -> "dump" | "skip" | "leave". The timer task's decision each
--- period: dump while streaming and sustainable; skip when idle; leave when streaming
--- became unsustainable (plain mode flipped on mid-stream, stream verbs gone) -- leaving
--- is an explicit transition that also ends streaming, so an unsustainable stream can
--- never paste on a timer. Pure: sustainable is probed by the caller (plain flag +
--- carbide verbs), which has no yield, so test-then-act stays atomic under CC's
--- cooperative multitasking.
function M.auto(s, sustainable)
  if M.tick(s) == "skip" then return "skip" end
  if sustainable then return "dump" end
  s.streaming = false
  return "leave"
end

--- finish(s) -> true when an exit flush is due (a stream was left on), clearing streaming;
--- false when idle. Independent of the live-capture flag: buffered rows stay valid after
--- capture disables itself, only the per-cycle capture stopped.
function M.finish(s)
  if not s.streaming then return false end
  s.streaming = false
  return true
end

return M
