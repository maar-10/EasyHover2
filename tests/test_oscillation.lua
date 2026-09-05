local t = require("tests.framework")
local Osc = require("fcs.safety.oscillation")

-- New contract: Osc:update(pitch, roll, dt) -> tripped(bool).
--  * amplitude deadband: near-zero dither manufactures no crossings (the false-trip bug);
--  * per-axis: pitch and roll are counted independently (trip if EITHER oscillates);
--  * auto-recover: the trip releases after the signal is calm for calmTime.

t.test("a real oscillation on pitch alone trips (roll flat)", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02 })
  local fired, p = false, 0.4
  for _ = 1, 10 do fired = o:update(p, 0.0, 0.1) or fired; p = -p end   -- pitch flips, roll flat
  t.truthy(fired, "pitch oscillation must trip")
end)

t.test("a real oscillation on roll alone trips (pitch flat)", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02 })
  local fired, r = false, 0.4
  for _ = 1, 10 do fired = o:update(0.0, r, 0.1) or fired; r = -r end
  t.truthy(fired, "roll oscillation must trip")
end)

t.test("near-zero dither below the deadband never trips (the level-climb false-trip bug)", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02 })
  local any, p = false, 0.005            -- 0.005 rad << 0.02 deadband: sensor noise, not oscillation
  for _ = 1, 40 do any = o:update(p, -p, 0.1) or any; p = -p end
  t.truthy(any == false, "sub-deadband dither must NOT manufacture crossings")
end)

t.test("a steady (non-oscillating) error stays quiet", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02 })
  local any = false
  for _ = 1, 30 do any = o:update(0.4, 0.4, 0.1) or any end   -- constant, no sign changes
  t.truthy(any == false)
end)

t.test("old changes age out of the window", function()
  local o = Osc.new({ window = 0.5, minChanges = 4, deadband = 0.02, calmTime = 0.3 })
  local p = 0.4
  for _ = 1, 3 do o:update(p, 0.0, 0.1); p = -p end     -- a few flips
  for _ = 1, 20 do o:update(0.4, 0.0, 0.1) end          -- then steady > window+calmTime
  t.truthy(o:update(0.4, 0.0, 0.1) == false, "window + calm cleared the trip")
end)

t.test("the trip auto-recovers after the signal is calm for calmTime", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02, calmTime = 1.0 })
  local p = 0.4
  for _ = 1, 10 do o:update(p, 0.0, 0.1); p = -p end     -- trip it
  t.truthy(o:update(0.4, 0.0, 0.1), "still latched right after the oscillation")
  local still = true
  for _ = 1, 25 do still = o:update(0.4, 0.0, 0.1) end   -- 2.5s of calm > window + calmTime
  t.truthy(still == false, "trip must release after sustained calm")
end)

t.test("reset() clears the detector state", function()
  local o = Osc.new({ window = 1.0, minChanges = 4, deadband = 0.02 })
  local p = 0.4
  for _ = 1, 10 do o:update(p, 0.0, 0.1); p = -p end
  o:reset()
  t.truthy(o:update(0.4, 0.0, 0.1) == false, "no counted crossings survive a reset")
end)

t.test("steady large pitch does not trip DAMPED (no oscillation)", function()
  local Osc = require("fcs.safety.oscillation")
  local o = Osc.new({ window=1.0, minChanges=6, deadband=0.02, calmTime=1.0 })
  local tripped = false
  for _ = 1, 40 do tripped = o:update(0.7, 0.0, 0.05) end   -- constant 0.7 rad nose-up
  t.eq(tripped, false, "constant angle never oscillates -> no trip")
end)
