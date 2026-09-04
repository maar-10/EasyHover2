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

t.test("loop trim: demands.pitch += trimDir*trimGain*demands.surge; surge untouched", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.35)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1 + (-1) * 0.35 * 0.8, 1e-9, "nose-down trim added to pitch")
  t.eq(r.demands.surge, 0.8, "surge demand unchanged (no braking)")
end)

t.test("loop trim: zero gain is a no-op", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1, 1e-9, "no trim when gain 0")
end)

t.test("loop trim floor: feedforward clamped to -trimAuthority*caps.pitch", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- raw = -0.35; floor = 0.4*0.2 = 0.08
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, -0.08, 1e-9, "trim clamped to the authority floor, not the raw -0.35")
end)

t.test("loop trim anti-flip: stabilizer keeps net nose-up authority under huge surge", function()
  -- Stabilizer wants full nose-up (+caps.pitch); trim wants huge nose-down. Post-add pitch must
  -- stay net nose-up -- the exact case that flipped the craft (raw -0.35 would give 0.2-0.35=-0.15).
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.2, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- ff floored to -0.08
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0.12, 1e-9, "0.2 stabilizer + (-0.08) trim = +0.12 reserved nose-up")
  t.truthy(r.demands.pitch > 0, "pitch demand stays net nose-up (no flip)")
end)

t.test("loop trim fade: full below trimFadeStart, zero at/above trimFade, linear between", function()
  local function ffAt(pitchMag)
    local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
      mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 10, surge = 1 } })
    lp:setTrim(-1, 0.4, 1.0, 0.25, 0.6)  -- authority 1 & big cap: only the fade acts; raw = -0.4
    lp:arm(true)
    return lp:cycle(0.05, { onGround = false, pitch = pitchMag }).demands.pitch
  end
  t.near(ffAt(0.10),  -0.4, 1e-9, "full trim inside deadzone")
  t.near(ffAt(0.25),  -0.4, 1e-9, "full trim at fade start")
  t.near(ffAt(0.425), -0.2, 1e-9, "half-faded at midpoint")   -- (0.425-0.25)/(0.6-0.25)=0.5
  t.near(ffAt(0.60),   0.0, 1e-9, "zero trim at fade end")
  t.near(ffAt(0.80),   0.0, 1e-9, "zero trim beyond fade end")
end)

t.test("loop diag: ffPitch equals the bias actually added (clamped, not raw)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  local d = lp:diag({}, { pitch = 0 })
  t.near(d.ffPitch, -0.08, 1e-9, "diag reports the clamped applied bias")
  t.near(d.ffPitch, r.demands.pitch, 1e-9, "matches the pitch bias added (scheme pitch was 0)")
end)

t.test("loop trim: DAMPED trip zeroes pitch even with trim active", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp.osc = { update = function() return true end, reset = function() end }  -- force a trip
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(r.mode, "DAMPED")
  t.near(r.demands.pitch, 0, 1e-9, "osc trip zeroes pitch despite trim (order preserved)")
end)
