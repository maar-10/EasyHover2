local t = require("tests.framework")
local Loop = require("fcs.runtime.loop")
local Mixer = require("fcs.mixer.level_flight")

local function fakeBackend()
  local b = { reads = 0, thrusts = {} }
  b.sensors = function()
    b.reads = b.reads + 1
    return { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }
  end
  b.setThruster = function(id, on) b.thrusts[id] = on end
  return b
end
local function fakeScheme()
  return { reset = function() end,
           update = function() return { heave=0.5, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
end
local function fakePwm() return { apply = function() end, state = function() return false end } end
local function build()
  local b = fakeBackend()
  local loop = Loop.new({ scheme = fakeScheme(), mixer = Mixer.new(), pwm = fakePwm(),
    backend = b, dtMax = 0.5 })
  return loop, b
end
local M0 = { altitude=0, vSpeed=0, pitch=0, roll=0, heading=0, yawRate=0,
             swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }

t.test("cycle(dt, m) uses the provided measurement (no internal sensor read)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1, M0)
  t.eq(b.reads, 0)
end)
t.test("cycle(dt) with no m reads internally (backward compat)", function()
  local loop, b = build(); loop:arm(true)
  loop:cycle(0.1)
  t.eq(b.reads, 1)
end)
t.test("cycle returns diagnostics when armed", function()
  local loop = build(); loop:arm(true)
  local d = loop:cycle(0.1, M0)
  t.eq(d.mode, "NORMAL"); t.truthy(d.demands ~= nil); t.truthy(d.duties.FL ~= nil)
end)
t.test("cycle returns nil demands/duties when disarmed", function()
  local loop = build()
  local d = loop:cycle(0.1, M0)
  t.eq(d.demands, nil); t.eq(d.duties, nil)
end)

-- ---- oscillation safety (new per-axis, auto-recovering detector) --------------------------
local function mkM(p, r)
  return { altitude=0, vSpeed=0, pitch=p or 0, roll=r or 0, heading=0, yawRate=0,
           swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }
end
local function steeringScheme()   -- nonzero steering so DAMPED zeroing is observable
  return { reset = function() end,
           update = function() return { heave=0.5, pitch=0.3, roll=0.3, yaw=0.2, sway=0.1, surge=0.1 } end }
end
local function buildOsc(cfg)
  local b = fakeBackend()
  local loop = Loop.new({ scheme = steeringScheme(), mixer = Mixer.new(), pwm = fakePwm(),
    backend = b, dtMax = 0.5, osc = cfg.osc, hoverDuty = cfg.hoverDuty })
  return loop, b
end
local OSC = { window = 1.0, minChanges = 4, deadband = 0.02, calmTime = 1.0 }

t.test("a sustained pitch oscillation trips DAMPED, zeroes steering, holds heave at hoverDuty", function()
  local loop = buildOsc({ osc = OSC, hoverDuty = 0.26 }); loop:arm(true)
  local d
  for i = 1, 12 do d = loop:cycle(0.1, mkM((i % 2 == 0) and 0.4 or -0.4, 0)) end
  t.eq(loop:getMode(), "DAMPED")
  t.eq(d.demands.pitch, 0); t.eq(d.demands.roll, 0); t.eq(d.demands.yaw, 0)
  t.eq(d.demands.sway, 0); t.eq(d.demands.surge, 0)
  t.near(d.demands.heave, 0.26, 1e-9)      -- held neutral, NOT the scheme's 0.5 climb demand
end)

t.test("a roll-only oscillation also trips DAMPED (per-axis)", function()
  local loop = buildOsc({ osc = OSC }); loop:arm(true)
  for i = 1, 12 do loop:cycle(0.1, mkM(0, (i % 2 == 0) and 0.4 or -0.4)) end
  t.eq(loop:getMode(), "DAMPED")
end)

t.test("DAMPED auto-recovers to NORMAL once the oscillation stops (non-sticky)", function()
  local loop = buildOsc({ osc = OSC }); loop:arm(true)
  for i = 1, 12 do loop:cycle(0.1, mkM((i % 2 == 0) and 0.4 or -0.4, 0)) end
  t.eq(loop:getMode(), "DAMPED")
  for _ = 1, 30 do loop:cycle(0.1, mkM(0, 0)) end   -- 3s of calm > window + calmTime
  t.eq(loop:getMode(), "NORMAL")
end)

t.test("sub-deadband level dither never trips DAMPED (the false-trip runaway)", function()
  local loop = buildOsc({ osc = OSC }); loop:arm(true)
  local p = 0.005
  for _ = 1, 40 do loop:cycle(0.1, mkM(p, -p)); p = -p end   -- noise below the 0.02 deadband
  t.eq(loop:getMode(), "NORMAL")
end)

t.test("without hoverDuty configured, DAMPED leaves heave to the scheme", function()
  local loop = buildOsc({ osc = OSC }); loop:arm(true)   -- no hoverDuty
  local d
  for i = 1, 12 do d = loop:cycle(0.1, mkM((i % 2 == 0) and 0.4 or -0.4, 0)) end
  t.eq(loop:getMode(), "DAMPED")
  t.near(d.demands.heave, 0.5, 1e-9)       -- scheme heave preserved
end)

-- ---- §6 dt discipline: an overrun cycle is SKIPPED, not integrated ----
t.test("an overrun dt reaches controllers as 0 (integration+derivative skipped, P still acts)", function()
  local loop = build(); loop:arm(true)
  local seen
  loop.scheme = { reset = function() end,
    update = function(_, sp, m, dt) seen = dt; return { heave=0.5, pitch=0, roll=0, yaw=0, sway=0, surge=0 } end }
  loop:cycle(3.0, M0)      -- stall: raw dt 3 s > dtMax 0.5
  t.eq(seen, 0, "overrun cycle passes dt=0 to the scheme")
  seen = nil
  loop:cycle(0.1, M0)
  t.near(seen, 0.1, 1e-9, "normal cycle passes its real dt")
end)

t.test("a dt spike produces no integrator kick (real PID through the loop)", function()
  local Pid = require("fcs.control.pid")
  local alt = Pid.new({ kp = 0.2, ki = 0.4 })
  local loop = build(); loop:arm(true)
  loop.scheme = { reset = function() end,
    update = function(_, sp, m, dt)
      return { heave = alt:update(sp.altitude, m.altitude, dt), pitch=0, roll=0, yaw=0, sway=0, surge=0 }
    end }
  loop:setpoints({ altitude = 2 })   -- constant +error drives the integrator up
  -- settle some error into the integrator at normal rate
  for _ = 1, 10 do loop:cycle(0.1, { altitude=1, vSpeed=0, pitch=0, roll=0, heading=0,
    yawRate=0, swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false }) end
  local iBeforeStall = alt.i
  t.truthy(iBeforeStall > 0, "integrator alive before the spike")
  -- the stall: a huge single-cycle gap must not integrate (and must not kick on recovery)
  loop:cycle(3.0, { altitude=1, vSpeed=0, pitch=0, roll=0, heading=0,
    yawRate=0, swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false })
  t.eq(alt.i, iBeforeStall, "stall cycle integrated NOTHING")
  loop:cycle(0.1, { altitude=1, vSpeed=0, pitch=0, roll=0, heading=0,
    yawRate=0, swayVel=0, surgeVel=0, swayPos=0, surgePos=0, onGround=false })
  t.truthy(alt.i > iBeforeStall, "integration resumes normally after the gap")
end)
