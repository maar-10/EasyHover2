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

t.test("loop: ffPitch stays 0 when disarmed (diag)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.3, 1.0, 0.25, 0.6, true)
  lp:arm(true); lp:cycle(0.05, { onGround = false, pitch = 0 })
  lp:arm(false); lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(lp:diag({}, { pitch = 0 }).ffPitch, 0, "ffPitch cleared while disarmed")
end)

-- Translation->attitude decoupling FF (flight bf9a45213f): sway/surge thrusters fire off the CoM,
-- torquing the craft. setDecouple installs a bounded feedforward that pre-injects the counter-
-- torque: demands.roll += swayRoll*demands.sway, demands.pitch += surgePitch*demands.surge, each
-- hard-clamped to authority*caps.{roll,pitch}. Gains default 0 => no-op (exact current behavior).

t.test("decouple FF adds bounded roll/pitch from sway/surge demand", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.3, pitch = 0, roll = 0, yaw = 0, sway = 0.2, surge = 0.2 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.3, roll = 0.3 } })
  lp:setDecouple({ swayRoll = 0.10, surgePitch = -0.05, authority = 0.3 })
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0, roll = 0 })
  t.near(r.demands.roll, 0.10 * 0.2, 1e-9, "roll += swayRoll*sway")
  t.near(r.demands.pitch, -0.05 * 0.2, 1e-9, "pitch += surgePitch*surge")
end)

t.test("decouple FF is clamped to authority*caps", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.3, pitch = 0, roll = 0, yaw = 0, sway = 1.0, surge = 0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.3, roll = 0.2 } })
  lp:setDecouple({ swayRoll = 0.9, surgePitch = 0, authority = 0.5 })   -- 0.9*1.0=0.9, cap=0.5*0.2=0.1
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0, roll = 0 })
  t.near(r.demands.roll, 0.1, 1e-9, "roll decouple clamped to authority*caps.roll")
end)
