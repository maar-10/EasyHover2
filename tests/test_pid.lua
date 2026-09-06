local t = require("tests.framework")
local Pid = require("fcs.control.pid")
t.test("P term is kp*error", function()
  local p = Pid.new({ kp = 2, ki = 0, kd = 0 })
  t.near(p:update(10, 4, 0.1), 12, 1e-9)   -- 2 * (10-4)
end)
t.test("I accumulates over time", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5); p:update(1, 0, 0.5)     -- err=1 each, dt=0.5 -> i=1.0
  t.near(p:update(1, 0, 0), 1.0, 1e-9)         -- dt=0 adds nothing; output = i
end)
t.test("I clamps to iMax (anti-windup)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0, iMax = 0.3 })
  for _ = 1, 100 do p:update(1, 0, 0.1) end
  t.near(p:update(1, 0, 0), 0.3, 1e-9)
end)
t.test("saturated freezes integration", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })
  p:update(1, 0, 0.5)                          -- i = 0.5
  p:update(1, 0, 0.5, true)                    -- saturated: no change
  t.near(p:update(1, 0, 0), 0.5, 1e-9)
end)
t.test("iBand freezes integration OUTSIDE the error band (conditional-integration anti-windup)", function()
  -- Conditional integration: an integrator with a band only accumulates while the error is small
  -- (steady-state trim). A large, sustained error -- e.g. a moving setpoint that leads the craft --
  -- is left to P/D so the integrator never winds up on the transient.
  local p = Pid.new({ kp = 0, ki = 1, kd = 0, iBand = 3 })
  for _ = 1, 20 do p:update(10, 0, 0.1) end     -- err=10 > band 3: no integration over 2s
  t.near(p:update(10, 0, 0), 0, 1e-9)           -- i stayed 0
  p:update(2, 0, 0.5)                           -- err=2 <= band 3: i += 1*2*0.5 = 1.0
  t.near(p:update(2, 0, 0), 1.0, 1e-9)
  p:update(-2, 0, 0.5)                          -- err=-2 within band: i += 1*-2*0.5 -> 0.0
  t.near(p:update(-2, 0, 0), 0.0, 1e-9)
end)
t.test("no iBand integrates at any error (backward compat)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 0 })   -- no band
  p:update(10, 0, 0.1)                             -- err=10 still integrates -> i=1.0
  t.near(p:update(10, 0, 0), 1.0, 1e-9)
end)
t.test("D opposes a rising measurement", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0 })  -- tauD 0 => alpha 1, unfiltered
  p:update(0, 0, 0.1)                        -- seed lastMeas
  local out = p:update(0, 1, 0.1)            -- meas rose 1 over 0.1 => dMeas=10, D=-10
  t.near(out, -10, 1e-9)
end)
t.test("Kd 0 fully bypasses derivative (no crash, pure PI)", function()
  local p = Pid.new({ kp = 1, ki = 0, kd = 0 })
  t.near(p:update(0, 5, 0.1), -5, 1e-9)      -- only P, even with a moving measurement
  t.near(p:update(0, 9, 0.1), -9, 1e-9)
end)
t.test("dt spike produces no derivative kick", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1)                        -- seed
  local out = p:update(0, 100, 5.0)          -- huge jump AND huge dt (a stall)
  t.near(out, 0, 1e-9)                        -- skipped: no kick
end)
t.test("a non-usable tick still tracks the measurement (no stale-derivative spike next tick)", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1)                        -- seed lastMeas = 0
  p:update(0, 100, 5.0)                      -- non-usable (dt>dtMax): d skipped, but must track meas=100
  local out = p:update(0, 100.1, 0.1)        -- real one-tick move of 0.1 over dt 0.1 => rate 1.0
  t.near(out, -1.0, 1e-9)                     -- a stale lastMeas(=0) would give -(100.1/0.1) = -1001
end)
t.test("saturated freezes integration but NOT the derivative (D-kill fix)", function()
  local p = Pid.new({ kp = 0, ki = 1, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1, false)                 -- seed lastMeas = 0
  -- saturated tick with a real one-tick move: integral must NOT accumulate, but D MUST react
  local out = p:update(0, 1, 0.1, true)      -- meas rose 1 over dt 0.1 => dMeas=10, D=-10; i stays 0
  t.near(out, -10, 1e-9, "D live under saturation (integral still frozen)")
  t.near(p.i, 0, 1e-9, "integration stayed frozen while saturated")
end)
t.test("saturated still skips a stale-dt derivative (bad dt overrides)", function()
  local p = Pid.new({ kp = 0, ki = 0, kd = 1, tauD = 0, dtMax = 0.5 })
  p:update(0, 0, 0.1, false)
  local out = p:update(0, 100, 5.0, true)    -- dt>dtMax AND saturated: D still skipped (stale dt)
  t.near(out, 0, 1e-9, "bad dt skips D even when saturated")
end)
