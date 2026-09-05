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

-- Forward-accel lean feed-forward is RETIRED (fix #3, PRESERVED/DISABLED in loop.lua): the trim is
-- now an attitude SETPOINT computed in fcs/input/pilot.lua that the leveling loop holds. Loop:cycle
-- must no longer add any ff bias to demands.pitch, regardless of setTrim config, and diag().ffPitch
-- must always read 0. setTrim itself stays plumbed (harmless dormant state) -- these tests only pin
-- that its stored params are no longer APPLIED.

t.test("loop trim: setTrim config no longer biases demands.pitch (lean off); surge untouched", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, roll = 0, yaw = 0, sway = 0, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0.35)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1, 1e-9, "pitch equals the scheme's own output -- no ff added")
  t.eq(r.demands.surge, 0.8, "surge demand unchanged (no braking)")
  t.near(lp._ffPitch or 0, 0, 1e-9, "ffPitch zero (lean off)")
end)

t.test("loop trim: zero gain is (still) a no-op", function()
  local lp = Loop.new({ scheme = fakeScheme({ heave = 0.5, pitch = 0.1, surge = 0.8 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp:setTrim(-1, 0); lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false })
  t.near(r.demands.pitch, 0.1, 1e-9, "no trim when gain 0")
end)

t.test("loop trim: authority-floor config no longer biases pitch (lean off)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- raw would have been -0.35; floor would have been 0.4*0.2=0.08
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0, 1e-9, "pitch equals the scheme's own output (0) -- no ff, no floor applied")
end)

t.test("loop trim: huge-surge config no longer biases pitch (lean off, stabilizer output passes through)", function()
  -- Previously the exact case that flipped the craft (raw -0.35 vs stabilizer +0.2). Now there is no
  -- ff at all, so the scheme's own stabilizer output passes through untouched.
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.2, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0.2, 1e-9, "pitch equals the scheme's stabilizer output unmodified")
  t.truthy(r.demands.pitch > 0, "pitch demand stays net nose-up (no flip -- there is no ff to flip it)")
end)

t.test("loop trim: fade config is inert (lean off) at every pitch magnitude", function()
  local function pitchAt(pitchMag)
    local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
      mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 10, surge = 1 } })
    lp:setTrim(-1, 0.4, 1.0, 0.25, 0.6)
    lp:arm(true)
    return lp:cycle(0.05, { onGround = false, pitch = pitchMag }).demands.pitch
  end
  t.near(pitchAt(0.10), 0, 1e-9, "no ff inside old deadzone")
  t.near(pitchAt(0.25), 0, 1e-9, "no ff at old fade start")
  t.near(pitchAt(0.425), 0, 1e-9, "no ff at old fade midpoint")
  t.near(pitchAt(0.60), 0, 1e-9, "no ff at old fade end")
  t.near(pitchAt(0.80), 0, 1e-9, "no ff beyond old fade end")
end)

t.test("loop diag: ffPitch is always 0 regardless of trim config or demands", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  local d = lp:diag({}, { pitch = 0 })
  t.near(d.ffPitch, 0, 1e-9, "diag reports zero ff (lean off)")
  t.near(r.demands.pitch, 0, 1e-9, "scheme pitch (0) passes through with no bias")
end)

t.test("loop trim: DAMPED trip zeroes pitch (independent of retired trim)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0.1, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 1, surge = 1 } })
  lp.osc = { update = function() return true end, reset = function() end }  -- force a trip
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.eq(r.mode, "DAMPED")
  t.near(r.demands.pitch, 0, 1e-9, "osc trip zeroes pitch")
end)

t.test("loop diag: ffPitch stays 0 when disarmed (and was already 0 while armed)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)
  lp:arm(true)
  lp:cycle(0.05, { onGround = false, pitch = 0 })
  lp:arm(false)
  lp:cycle(0.05, { onGround = false, pitch = 0 })   -- disarmed cycle
  t.near(lp:diag({}, { pitch = 0 }).ffPitch, 0, 1e-9, "ffPitch stays 0 while disarmed")
end)

-- brakeTrim config (symmetric vs forward-only) no longer has any effect since the ff itself is
-- retired: both branches must produce the same (unbiased) pitch demand.
t.test("loop trim forward-only (brakeTrim=false): no ff to block or keep -- pitch unbiased", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = -1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6, false)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0, 1e-9, "no ff applied regardless of brakeTrim")
  t.near(lp:diag({}, { pitch = 0 }).ffPitch, 0, 1e-9, "ffPitch reflects the retired lean (0)")
end)

t.test("loop trim forward-only (brakeTrim=false), forward surge: no ff -- pitch unbiased", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = 1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6, false)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0, 1e-9, "no forward-lean applied -- lean is retired")
end)

t.test("loop trim symmetric (brakeTrim=true): no ff -- pitch unbiased (CRU/DRN)", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = -1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6, true)
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0, 1e-9, "no brake lean applied even when brakeTrim true -- lean is retired")
end)

t.test("loop trim: 5-arg setTrim (brakeTrim nil->true) is also inert -- no ff applied", function()
  local lp = Loop.new({ scheme = fakeScheme({ pitch = 0, surge = -1.0 }),
    mixer = fakeMixer(), pwm = fakePwm(), backend = fakeBackend(), caps = { pitch = 0.2, surge = 1 } })
  lp:setTrim(-1, 0.35, 0.4, 0.25, 0.6)   -- no brakeTrim arg -> defaults true, but ff is retired
  lp:arm(true)
  local r = lp:cycle(0.05, { onGround = false, pitch = 0 })
  t.near(r.demands.pitch, 0, 1e-9, "5-arg call still adds no ff")
end)
