-- tests/test_loop_trim.lua
local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")

-- Minimal fakes: a scheme returning fixed demands, a mixer echoing demands, a no-op backend.
local function fakeScheme(demands)
  return { reset = function() end, update = function()
    local o = {} for k,v in pairs(demands) do o[k]=v end return o end }
end
local function fakeMixer() return { mix = function(_, d) return d end } end
local function fakeBackend() return { sensors = function() return { onGround = false } end } end
local function fakePwm() return { apply = function() end } end

-- Forward-accel lean feed-forward is RE-ENABLED (fix #3): a calibrated, capped nose-down bias
-- added to demands.pitch as dir*gain*demands.surge, faded out linearly over
-- [trimFadeStart, trimFade] |pitch| and clamped to authority*caps.pitch. When brakeTrim is false
-- the half of the ff opposite `dir` (i.e. the brake-side lean) is blocked (forward-only).

t.test("loop trim: nose-down ff scales with demands.surge (lean on)", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.0, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, true)   -- dir -1 (nose-down), gain 0.3, authority 1, fade 0.25..0.6
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })   -- |pitch|<fadeStart => full ff
  t.near(r.demands.pitch, -0.3 * 0.8, 1e-9, "pitch = ff = dir*gain*surge (nose-down)")
  t.near(lp:diag({}, { pitch = 0 }).ffPitch, -0.3 * 0.8, 1e-9, "diag reports applied ff")
end)

t.test("loop trim: gain 0 is a no-op (LDG)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0, 1.0, 0.25, 0.6, false); lp:arm(true)
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, 0.1, 1e-9, "no ff when gain 0")
end)

t.test("loop trim: authority cap limits ff to authority*caps.pitch", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6, true); lp:arm(true)  -- raw -0.35, cap 0.4*0.2=0.08
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, -0.08, 1e-9, "ff clamped to -authority*cap")
end)

t.test("loop trim: fade zeroes ff by trimFade (|pitch|>=fade)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 10, surge = 1 } })
  lp:setTrim(-1, 0.4, 1.0, 0.25, 0.6, true); lp:arm(true)
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0.60 }).demands.pitch, 0, 1e-9, "ff fully faded at trimFade")
end)

t.test("loop trim forward-only (brakeTrim=false) blocks the brake half", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = -1.0 }),   -- surge<0 = braking
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, false); lp:arm(true)  -- dir -1, brake would give +0.3 -> blocked
  t.near(lp:cycle(0.05, { onGround = false, pitch = 0 }).demands.pitch, 0, 1e-9, "forward-only blocks brake-side ff")
end)

t.test("loop: DAMPED trip still zeroes pitch (ff irrelevant)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp.osc = { update = function() return true end, reset = function() end }
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, true); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(r.mode, "DAMPED"); t.near(r.demands.pitch, 0, 1e-9, "osc trip zeroes pitch")
end)
