-- tests/test_modes_registry.lua
local t = require("tests.framework")
local Registry = require("fcs.modes.registry")
local golden = require("tests.modes_golden_data")

-- Minimal fake tuning exposing forMode with the golden gains for PRECISION.
-- Dot convention (matches the real fcs.tuning.forMode): forMode(id), not forMode(self, id).
local function fakeTuning()
  local g = golden.gains()
  local base = { gains = g, caps = { pitch=0.2, roll=0.2, yaw=0.6, sway=0.9, surge=1.0 },
    feel = { headingRate=2.2, climbRate=4.5, surgeSpeed=10, swaySpeed=5 } }
  local function coupledRecord()
    return { gains=g, caps={pitch=0.4,roll=0.4,yaw=0.6,sway=0.9,surge=1.0,yawRear=0.6},
      feel={ throttleRate=1.0, throttleDecay=1.0, brakeGain=0.5, slowSurgeRate=0.3,
             strafeRate=0.3, climbRampTime=1.0, climbBoost=2.0, trimGain=0.1, trimDir=-1 } }
  end
  return { forMode = function(id)
    if id == "MAN" then return { gains=g, caps={pitch=0.4,roll=0.4,yaw=0.6,sway=0.9,surge=1.0},
      feel={ tiltRate=0.8, tiltCap=0.4 } } end
    if id == "CRUISE" then return { gains=g, caps=base.caps,
      feel={ cruiseThrottleRate=1.0, cruiseThrottleMax=1.0 } } end
    if id == "CPL" or id == "DCPL" then return coupledRecord() end
    return base
  end }
end

t.test("registry builds all modes with correct policy + default", function()
  local reg = Registry.build(fakeTuning())
  t.eq(reg.default, "LDG", "default is LDG")
  t.eq(reg.byId.MAN.policy.tilt, true, "MAN tilt enabled")
  t.eq(reg.byId.CRUISE.policy.surge, "throttle", "CRUISE surge throttle")
  t.eq(reg.byId.PRECISION.policy.tilt, false, "PRECISION no tilt")
  t.truthy(reg.byId.PRECISION.scheme and reg.byId.PRECISION.mixer, "PRECISION has scheme+mixer")
end)

t.test("registry: five flight modes, no CPL/DCPL, MAN has no relaxTiltDrift flag", function()
  local reg = require("fcs.modes.registry").build(require("fcs.tuning"))
  t.eq(#reg.order, 5, "five flight modes")
  t.eq(reg.byId.CPL, nil, "CPL removed")
  t.eq(reg.byId.DCPL, nil, "DCPL removed")
  t.eq(reg.default, "LDG", "boot default LDG")
  t.eq(reg.byId.MAN.policy.relaxTiltDrift, nil, "MAN relaxTiltDrift flag gone (generalized in pilot)")
  t.truthy(reg.byId.MAN.policy.tilt, "MAN still tilts")
  t.eq(reg.byId.DRN.policy.translate, false, "DRN keeps translate=false (no direct translate keys)")
end)

t.test("registry defaults to LDG and carries groundSense/canPark flags", function()
  local reg = Registry.build(fakeTuning())
  t.eq(reg.default, "LDG", "boot default is LDG")
  -- LDG: senses ground + can park
  t.eq(reg.byId.LDG.groundSense, true, "LDG groundSense")
  t.eq(reg.byId.LDG.canPark, true, "LDG canPark")
  -- DRN: neither
  t.eq(reg.byId.DRN.groundSense, false, "DRN groundSense off")
  t.eq(reg.byId.DRN.canPark, false, "DRN canPark off")
  -- others default false
  t.eq(reg.byId.PRECISION.groundSense, false, "PRECISION groundSense off")
  t.eq(reg.byId.PRECISION.canPark, false, "PRECISION canPark off")
end)

t.test("PRECISION descriptor reproduces the golden baseline", function()
  local reg = Registry.build(fakeTuning())
  local d = reg.byId.PRECISION
  for i, c in ipairs(golden.BATTERY) do
    d.scheme:reset()
    local duties = d.mixer:mix(d.scheme:update(c.sp, c.m, 0.05, c.m.onGround))
    for k, want in pairs(golden.EXPECT[i]) do
      t.near(duties[k], want, 1e-9, string.format("case %d %s", i, k))
    end
  end
end)

t.test("registry applies keepWarm config to the shared mixer", function()
  local Registry = require("fcs.modes.registry")
  local tuning = require("fcs.tuning")
  local reg = Registry.build(tuning)
  local mixer = reg.byId[reg.default].mixer
  t.truthy(mixer.keepWarm and mixer.keepWarm.floor >= 0, "keepWarm applied to shared mixer")
  t.near(mixer.keepWarm.mainRatio, tuning.keepWarm.mainRatio, 1e-9, "mainRatio from tuning")
end)
