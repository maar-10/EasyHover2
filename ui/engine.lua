--[[ UI-side engine pulse machine: drives the fuel chute relay over an injected writer.

     THE INVERSION IS THE WHOLE POINT. The funnel above the engine passes items only while it
     is UNPOWERED, so holding the redstone HIGH blocks it and dropping the signal briefly lets
     exactly one item through. That inverts everything you would expect:

       master OFF -> signal held HIGH, continuously. Funnel blocked, nothing feeds the engine,
                     the vehicle is off. This is also the state at boot, and the state we fall
                     back to on any error -- an engine that will not start is a much better
                     failure than a funnel that empties the whole vault into it.
       master ON  -> one interrupt pulse immediately (the kickstart), then an interrupt every
                     `intervalMs` to feed one more item and keep it running.

     Timings are configurable because they depend on the build: `pulseMs` must be long enough
     for one item to pass and short enough that a second cannot follow, and `intervalMs` must
     be shorter than the engine's burn time.

     The state machine reasons entirely in the logical `feeding` boolean (true = an item is
     being let through right now). `writer(signal)` is the ONLY impure edge, and it is a dumb
     passthrough -- it applies NO inversion of its own. `_write` is the single place that turns
     logical `feeding` into the physical `signal`: `signal = not feeding` by default (blocked =
     HIGH), then `invert` flips it once more for a build wired the other way round. Everything
     else is written in terms of "blocked" and "feeding" rather than high and low, so the
     inversion lives in exactly one place.

     Ported from EasyHover 1's flight/lib/io/engine.lua, matching its `_write` formula exactly.
     Retargeted for the UI PC: the physical write is an injected `writer(signal)` closure instead
     of a direct peripheral call, and there is no log/state/available() -- those belonged to the
     flight-side peripheral registry. `now` is always passed in; this module never calls
     os.epoch itself.
]]

local LATCH_LINE_MS = 150   -- ms a latch trigger line is held; >= 1 redstone tick + margin.

local Engine = {}
Engine.__index = Engine

function Engine.new(cfg, writer)
  local self = setmetatable({}, Engine)
  self.cfg = cfg
  self.writer = writer

  self.master = cfg.masterDefault and true or false
  self.feeding = false          -- true while the funnel is being allowed to pass an item
  self.pulseEndsAt = nil
  self.nextPulseAt = nil
  self.pulses = 0
  self.lastWritten = nil        -- what we last told the relay, for write-on-change
  -- Periodic re-assert: write-on-change defeats itself across a relay/peripheral reboot (RAM
  -- `lastWritten` still matches the desired signal while the PHYSICAL output was lost). Every
  -- reassertMs the dedup state is invalidated so the safe state is physically re-driven.
  self.reassertMs = cfg.reassertMs or 2000
  self.lastWriteAt = nil        -- ms timestamp of the last successful write

  self.mode = (cfg.mode == "latch") and "latch" or "basic"
  self.lastFeeding = nil       -- latch: last logical state a pulse was fired for
  self.feedLineDownAt = nil    -- latch: when to drop the FEED trigger line
  self.blockLineDownAt = nil   -- latch: when to drop the BLOCK trigger line
  self.lastNow = 0             -- latch: last tick timestamp (for now-less blockNow)
  return self
end

--- Write the physical output. `feeding` true means "let an item through" (the logical state).
-- The single place the inversion is applied; `writer` receives the physical signal and applies
-- no inversion of its own. Write-on-change is on the physical signal, not the logical one.
function Engine:_write(feeding, now)
  if self.mode == "latch" then return self:_writeLatch(feeding, now) end

  local signal = not feeding            -- blocked = signal HIGH, by default
  if self.cfg.invert then signal = not signal end

  self.feeding = feeding
  if self.lastWritten == signal then return true end

  local ok = self.writer(signal)
  if ok then self.lastWritten = signal; self.lastWriteAt = now end
  return ok
end

-- Latch mode: pulse the FEED (feeding=true) or BLOCK (feeding=false) trigger line on the logical
-- transition only; the latch HOLDS between pulses. The raised line is dropped by tick() after
-- LATCH_LINE_MS. now is threaded from tick/setMaster/_startPulse; blockNow passes nil -> lastNow.
function Engine:_writeLatch(feeding, now)
  now = now or self.lastNow
  self.feeding = feeding
  if self.lastFeeding == feeding then return true end

  local line = feeding and "feed" or "block"
  local ok = self.writer(line, true)
  if ok then
    self.lastFeeding = feeding
    self.lastWriteAt = now
    if feeding then self.feedLineDownAt = now + LATCH_LINE_MS
    else self.blockLineDownAt = now + LATCH_LINE_MS end
  end
  return ok
end

-- Latch mode: drop any trigger line that has been held >= LATCH_LINE_MS. Retries next tick on
-- write failure (down-at stays set).
function Engine:_lowerDueLines(now)
  if self.mode ~= "latch" then return end
  if self.feedLineDownAt and now >= self.feedLineDownAt then
    if self.writer("feed", false) then self.feedLineDownAt = nil end
  end
  if self.blockLineDownAt and now >= self.blockLineDownAt then
    if self.writer("block", false) then self.blockLineDownAt = nil end
  end
end

--- Turn the vehicle on or off. Returns the new master state.
function Engine:setMaster(on, now)
  on = on and true or false
  if on == self.master then return self.master end
  self.master = on

  if not on then
    -- Off: block the funnel and hold it blocked. No pending pulse survives.
    self.pulseEndsAt, self.nextPulseAt = nil, nil
    self:_write(false, now)
  else
    if self.cfg.kickstart then
      self:_startPulse(now)
    else
      self:_write(false, now)
      self.nextPulseAt = now + self.cfg.intervalMs
    end
  end
  return self.master
end

function Engine:toggleMaster(now)
  return self:setMaster(not self.master, now)
end

function Engine:_startPulse(now)
  if self.mode == "latch" then
    -- Structural floor, independent of how cfg got here (uical's cycleMode clamps on save, but
    -- a hand-edited config or a pre-clamp reboot could still hand us a too-short pulseMs): the
    -- FEED trigger line takes LATCH_LINE_MS to drop, so the pulse window can never be shorter
    -- than that plus a small margin, or BLOCK could rise while FEED is still HIGH (the forbidden
    -- both-lines-high set/reset ambiguity on a latch). Basic mode is untouched.
    local latchPulseFloorMs = LATCH_LINE_MS + 50
    self.pulseEndsAt = now + math.max(self.cfg.pulseMs, latchPulseFloorMs)
  else
    self.pulseEndsAt = now + self.cfg.pulseMs
  end
  self.nextPulseAt = nil
  self.pulses = self.pulses + 1
  self:_write(true, now)
end

--- Call once per control cycle. Drives the pulse state machine.
function Engine:tick(now)
  self.lastNow = now
  self:_lowerDueLines(now)

  -- Periodic re-assert: invalidate the write-on-change dedup so the next _write physically
  -- re-drives the output. This is what makes the master-off "held blocked" state survive a
  -- relay reboot that silently dropped the physical signal (see Engine.new).
  if self.reassertMs and self.lastWriteAt and now - self.lastWriteAt >= self.reassertMs then
    self.lastWritten = nil
    self.lastFeeding = nil
  end

  if not self.master then
    -- Held blocked. Re-assert rather than assume: a rescan or a relay reboot could have
    -- dropped the output, and an unblocked funnel with the master off would quietly drain
    -- the vault.
    self:_write(false, now)
    return
  end

  if self.pulseEndsAt then
    if now >= self.pulseEndsAt then
      self.pulseEndsAt = nil
      self.nextPulseAt = now + self.cfg.intervalMs
      self:_write(false, now)
    end
    return
  end

  if self.nextPulseAt and now >= self.nextPulseAt then
    self:_startPulse(now)
    return
  end

  if not self.nextPulseAt then
    self.nextPulseAt = now + self.cfg.intervalMs
  end
  self:_write(false, now)
end

--- Force a feed now, without waiting for the interval. For a manual "prime" button.
function Engine:feedNow(now)
  if not self.master then return false, "engine master is off" end
  self:_startPulse(now)
  return true
end

--- Put the output back to blocked. Called on shutdown and on hardware change.
function Engine:blockNow()
  self.pulseEndsAt, self.nextPulseAt = nil, nil
  self.lastWritten = nil          -- basic: force the write
  self.lastFeeding = nil          -- latch: force the BLOCK pulse
  return self:_write(false)
end

function Engine:status(now)
  local remaining = nil
  if self.master and self.nextPulseAt then
    remaining = math.max(0, self.nextPulseAt - now)
  end
  return {
    master = self.master,
    feeding = self.feeding,
    pulses = self.pulses,
    nextFeedInMs = remaining,
    pulseMs = self.cfg.pulseMs,
    intervalMs = self.cfg.intervalMs,
  }
end

function Engine:applyConfig(cfg)
  self.cfg = cfg
  self.lastWritten = nil
end

return Engine
