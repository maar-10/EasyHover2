-- fcs/input/events.lua
-- Hybrid typewriter input: event-driven pre-apply + polled authority.
--
-- Simulated >=1.3.0 emits peripheral "key"/"key_up" events from the linked typewriter
-- (verified in-game 2026-08-22 and in the decompiled LinkedTypewriterBlockEntity: pressKey/
-- releaseKey queue the event synchronously, same tick as the physical interaction). Events
-- let pilot intent land within a tick; the 50 ms poll (design §10) stays as the AUTHORITATIVE
-- re-sync -- it heals missed/duplicate events, multi-key flag overlaps, and anything else the
-- event stream gets wrong. Neither path alone is trusted; together they are both fast and true.
--
-- Disambiguation (the mod emits the bare CC "key" name): typewriter events carry a numeric
-- code plus a boolean-or-nil second arg; CC:T's LOCAL keyboard events carry (code, string
-- keyName). Anything with a string second arg is not craft input and is ignored here.
local keymap = require("fcs.input.keymap")

local E = {}
E.__index = E

function E.new(deps)
  -- deps.codes() -> current pressed-code list from the device (never nil)
  -- deps.map()   -> active code->binding table (keymap.forMode(flightMode))
  -- deps.held    -> the SHARED held-flag table the control loop reads; mutated IN PLACE so the
  --                 reference the control task holds never goes stale
  return setmetatable({ codes = deps.codes, map = deps.map, held = deps.held }, E)
end

-- Returns true when the event was consumed as craft input.
function E:event(name, code, arg2)
  if name ~= "key" and name ~= "key_up" then return false end
  if type(arg2) == "string" then return false end          -- local terminal keyboard
  if type(code) ~= "number" then return false end
  if name == "key" then
    -- pressKey adds to pressedKeys BEFORE queueing, so a genuine press is always visible in
    -- the device's own set by delivery time. A local scancode colliding with an entry code
    -- must not drive the craft -> require membership for presses.
    local present = false
    for _, c in ipairs(self.codes()) do
      if c == code then present = true break end
    end
    if not present then return false end
  end
  -- key_up skips the membership check on purpose: releaseKey REMOVES the code before queuing,
  -- so a genuine release is always already absent. A colliding local key_up can at worst clear
  -- one flag for <1 poll period (50 ms), after which sync restores the truth.
  local flag = keymap.flagFor(self.map(), code)
  if not flag then return false end
  self.held[flag] = (name == "key") or nil
  return true
end

-- Authoritative rebuild from the device snapshot; replaces contents in place.
function E:sync()
  local resolved = keymap.resolve(self.map(), self.codes())
  for k in pairs(self.held) do self.held[k] = nil end
  for k, v in pairs(resolved) do self.held[k] = v end
end

return E
