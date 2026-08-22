local t = require("tests.framework")
local Backend = require("fcs.io.backend")
local mocks = require("tests.mocks.peripherals")
t.test("setThruster on/off writes full/zero thrust to the bound peripheral", function()
  local th = mocks.thruster()
  local shim = mocks.shim({ thruster_1 = th })
  local cfg = { thrusters = { FL = "thruster_1" }, sensors = {}, bindings = {} }
  local b = Backend.new(shim, cfg)
  b:setThruster("FL", true);  t.near(th.thrust, 15, 1e-9)
  b:setThruster("FL", false); t.near(th.thrust, 0, 1e-9)
end)
t.test("setThruster on an unbound id is a harmless no-op", function()
  local b = Backend.new(mocks.shim({}), { thrusters = { FL = false }, sensors = {}, bindings = {} })
  b:setThruster("FL", true)   -- must not error
  t.truthy(true)
end)
t.test("liftIds returns the four lift ids", function()
  local b = Backend.new(mocks.shim({}), { thrusters = {}, sensors = {}, bindings = {} })
  t.eq(#b:liftIds(), 4)
end)
local function sensorCfg()
  return { thrusters = {},
    sensors = { altimeter="alt", gimbal="gim", velFront="vf", velRear="vr", velMedial="vm", navTable="nav", downOptical="opt" },
    bindings = { heightOffset=2, onGroundThreshold=1.5, yawBaseline=2, vSpeedTau=0.0,
      gimbalPitchIdx=1, gimbalRollIdx=2, signPitch=1, signRoll=1, signVelFront=1, signVelRear=1, signVelMedial=1 } }
end
local function sensorRig(alt, angles, vf, vr, vm, navA, optD)
  return mocks.shim({ alt=mocks.altitude(alt), gim=mocks.gimbal(angles),
    vf=mocks.velocity(vf), vr=mocks.velocity(vr), vm=mocks.velocity(vm),
    nav=mocks.navtable(navA), opt=mocks.optical(optD) })
end
t.test("altitude adds the height offset; attitude from gimbal", function()
  local clk = 0; local b = Backend.new(sensorRig(10, {0.1,-0.2}, 0,0,0, 0.3, 5), sensorCfg(), function() return clk end)
  local s = b:sensors()
  t.near(s.altitude, 12, 1e-9)     -- 10 + offset 2
  t.near(s.pitch, 0.1, 1e-9); t.near(s.roll, -0.2, 1e-9); t.near(s.heading, 0.3, 1e-9)
end)
t.test("yaw rate = (front-rear)/baseline; sway = avg; surge = medial", function()
  local b = Backend.new(sensorRig(10, {0,0}, 3, 1, 4, 0, 5), sensorCfg(), function() return 0 end)
  local s = b:sensors()
  t.near(s.yawRate, 1, 1e-9)       -- (3-1)/2
  t.near(s.swayVel, 2, 1e-9)       -- (3+1)/2
  t.near(s.surgeVel, 4, 1e-9)
end)
t.test("onGround true when optical below threshold", function()
  local b = Backend.new(sensorRig(10,{0,0},0,0,0,0, 0.5), sensorCfg(), function() return 0 end)
  t.truthy(b:sensors().onGround == true)
  local b2 = Backend.new(sensorRig(10,{0,0},0,0,0,0, 9), sensorCfg(), function() return 0 end)
  t.truthy(b2:sensors().onGround == false)
end)
t.test("vSpeed derives from altitude change over dt (tau 0 = unfiltered)", function()
  local clk = 0
  local b = Backend.new(sensorRig(10,{0,0},0,0,0,0,5), sensorCfg(), function() return clk end)
  b:sensors()                       -- first call seeds, vSpeed 0
  -- rig can't change alt after construction; rebuild with a shared mutable altitude instead:
  local altP = mocks.altitude(10)
  local shim = mocks.shim({ alt=altP, gim=mocks.gimbal({0,0}), vf=mocks.velocity(0), vr=mocks.velocity(0),
    vm=mocks.velocity(0), nav=mocks.navtable(0), opt=mocks.optical(5) })
  local clk2 = 0; local b3 = Backend.new(shim, sensorCfg(), function() return clk2 end)
  b3:sensors()                      -- seed at alt 10, t 0
  altP.getHeight = function() return 11 end; clk2 = 500   -- +1m over 0.5s
  t.near(b3:sensors().vSpeed, 2, 1e-6)   -- 1m / 0.5s
end)
t.test("a stall (huge dt) is integrated CLAMPED: vSpeed and positions stay bounded", function()
  -- After a mainThread stall the wall-clock gap must not feed a huge step into the filter or
  -- teleport sway/surge position into the pilot leashes.
  local altP = mocks.altitude(100)
  local shim = mocks.shim({ alt=altP, gim=mocks.gimbal({0,0}), vf=mocks.velocity(4), vr=mocks.velocity(0),
    vm=mocks.velocity(8), nav=mocks.navtable(0), opt=mocks.optical(9) })
  local cfg = sensorCfg(); cfg.bindings.vSpeedTau = 0.0
  local clk = 0; local b = Backend.new(shim, cfg, function() return clk end)
  b:sensors()                                     -- seed at t=0
  clk = 5000                                      -- 5 s gap (a stall)
  local s = b:sensors()
  t.near(s.swayPos, 1, 1e-6, "sway integrates 2 m/s x 0.5 s max, not x 5 s")
  t.near(s.surgePos, 4, 1e-6, "surge integrates 8 m/s x 0.5 s max")
  t.near(s.vFilt or s.vSpeed, 0, 1e-6)            -- altitude unchanged -> vSpeed stays 0
  -- next sample starts fresh from the new lastT (no residual mega-dt)
  clk = 5500
  local s2 = b:sensors()
  t.near(s2.swayVel, 2, 1e-9); t.near(s2.swayPos, 2, 1e-6)   -- +2 m/s x 0.5 s normal sample
end)
t.test("heading applies sign and scale (deg->rad)", function()
  local cfg = sensorCfg(); cfg.bindings.signHeading = -1; cfg.bindings.headingScale = math.pi/180
  local b = Backend.new(sensorRig(10, {0,0}, 0,0,0, 90, 5), cfg, function() return 0 end)
  t.near(b:sensors().heading, -math.pi/2, 1e-6)   -- -1 * (pi/180) * 90
end)
t.test("gimbalScale converts pitch/roll from degrees", function()
  local cfg = sensorCfg(); cfg.bindings.gimbalScale = math.pi/180
  local b = Backend.new(sensorRig(10, {90,-90}, 0,0,0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().pitch, math.pi/2, 1e-6); t.near(b:sensors().roll, -math.pi/2, 1e-6)
end)
t.test("signYawRate flips yaw-rate direction", function()
  local cfg = sensorCfg(); cfg.bindings.signYawRate = -1
  local b = Backend.new(sensorRig(10, {0,0}, 3, 1, 0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().yawRate, -1, 1e-9)           -- -1 * (3-1)/2
end)
t.test("baroThrusterOffset adds into altitude", function()
  local cfg = sensorCfg(); cfg.bindings.baroThrusterOffset = 5
  local b = Backend.new(sensorRig(10, {0,0}, 0,0,0, 0, 5), cfg, function() return 0 end)
  t.near(b:sensors().altitude, 17, 1e-9)          -- 10 + 5 + heightOffset 2
end)
t.test("baroMsl is the RAW barometer height (true Y), ignoring the AGL offsets", function()
  -- The FCS control loop keeps AGL (`altitude`), but the DISPLAY wants true Y that matches F3.
  -- baroMsl is getHeight untouched -- no baroThrusterOffset, no heightOffset.
  local cfg = sensorCfg(); cfg.bindings.baroThrusterOffset = 5   -- heightOffset already 2
  local b = Backend.new(sensorRig(10, {0,0}, 0,0,0, 0, 5), cfg, function() return 0 end)
  local s = b:sensors()
  t.near(s.baroMsl, 10, 1e-9)     -- raw getHeight, NOT +offsets
  t.near(s.altitude, 17, 1e-9)    -- AGL still 10+5+2 for control (unchanged)
end)
t.test("a non-finite sensor read holds the last-good value instead of poisoning control", function()
  local altP = mocks.altitude(10)
  local vfP = mocks.velocity(0)
  local shim = mocks.shim({ alt=altP, gim=mocks.gimbal({0.1,-0.2}), vf=vfP, vr=mocks.velocity(0),
    vm=mocks.velocity(0), nav=mocks.navtable(0.3), opt=mocks.optical(5) })
  local clk = 0; local b = Backend.new(shim, sensorCfg(), function() return clk end)
  local s1 = b:sensors(); clk = 100         -- seed last-good (altitude 12, pitch 0.1)
  t.near(s1.altitude, 12, 1e-9)
  altP.getHeight = function() return 0 / 0 end        -- barometer glitches to NaN
  vfP.getVelocity = function() return math.huge end   -- a velocity spikes to inf
  local s2 = b:sensors()
  t.truthy(s2.altitude == s2.altitude, "altitude is not NaN")
  t.near(s2.altitude, 12, 1e-9)                        -- held last-good, not NaN
  t.truthy(s2.yawRate == s2.yawRate and s2.yawRate ~= math.huge, "yawRate stays finite")
  t.truthy(s2.swayPos == s2.swayPos, "position integrator not poisoned by an inf velocity")
end)
t.test("setThrusterLevel writes setPower(level) to the bound peripheral", function()
  local th = mocks.thruster()
  local shim = mocks.shim({ thruster_1 = th })
  local b = Backend.new(shim, { thrusters = { FL = "thruster_1" }, sensors = {}, bindings = {} })
  b:setThrusterLevel("FL", 11); t.near(th.thrust, 11, 1e-9)
  b:setThrusterLevel("FL", 0);  t.near(th.thrust, 0, 1e-9)
end)
t.test("setThrusterLevel on an unbound id is a harmless no-op", function()
  local b = Backend.new(mocks.shim({}), { thrusters = { FL = false }, sensors = {}, bindings = {} })
  b:setThrusterLevel("FL", 7)   -- must not error
  t.truthy(true)
end)
