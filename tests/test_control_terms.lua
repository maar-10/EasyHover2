local t = require("tests.framework")
local Pid = require("fcs.control.pid")
local Heading = require("fcs.control.heading")
local Translate = require("fcs.control.translate")

-- Pid ------------------------------------------------------------------

t.test("Pid:terms P+I+D sums to update() and does not mutate", function()
  local p = Pid.new({ kp = 2, ki = 0.5, kd = 0.1, tauD = 0 })
  p:update(1.0, 0.0, 0.1, false) -- prime lastMeas so dFilt gets populated next cycle
  local out = p:update(1.0, 0.3, 0.1, false) -- sp=1, meas=0.3, dt=0.1
  local i0, d0 = p.i, p.dFilt
  local tm = p:terms(1.0, 0.3)
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
  t.near(tm.err, 0.7, 1e-9, "err == sp - meas")
  t.eq(tm.I, p.i, "terms.I == controller.i")
  t.near(tm.P, p.kp * 0.7, 1e-9, "P == kp*err")
  t.near(tm.D, -p.kd * p.dFilt, 1e-9, "D == -kd*dFilt")
  -- no mutation
  local tm2 = p:terms(1.0, 0.3)
  t.eq(p.i, i0, "terms must not mutate i")
  t.eq(p.dFilt, d0, "terms must not mutate dFilt")
  t.eq(tm2.I, tm.I, "second terms call is stable")
  -- subsequent update() unaffected by terms() calls
  local out2 = p:update(1.0, 0.5, 0.1, false)
  local i1, d1 = p.i, p.dFilt
  p:terms(1.0, 0.5)
  p:terms(1.0, 0.5)
  local expectI, expectD = i1, d1
  t.eq(p.i, expectI, "i unchanged by terms after update")
  t.eq(p.dFilt, expectD, "dFilt unchanged by terms after update")
  -- sanity: out2 reproducible math didn't drift
  t.truthy(out2 ~= nil, "update still returns a value")
end)

t.test("Pid:terms with kd == 0 returns D = 0 (matches update)", function()
  local p = Pid.new({ kp = 1, ki = 0, kd = 0 })
  local out = p:update(2.0, 0.5, 0.1, false)
  local tm = p:terms(2.0, 0.5)
  t.eq(tm.D, 0, "D is exactly 0 when kd == 0")
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
end)

t.test("Pid:terms does not mutate when saturated on prior update", function()
  local p = Pid.new({ kp = 1, ki = 1, kd = 0.2, tauD = 0 })
  p:update(1.0, 0.0, 0.1, false)
  p:update(1.0, 0.2, 0.1, true) -- saturated: i and dFilt frozen this tick
  local iBefore, dBefore = p.i, p.dFilt
  local tm = p:terms(1.0, 0.2)
  t.eq(p.i, iBefore, "terms does not mutate i after saturated update")
  t.eq(p.dFilt, dBefore, "terms does not mutate dFilt after saturated update")
  t.eq(tm.I, iBefore, "terms.I reflects frozen i")
end)

-- Heading ----------------------------------------------------------------

t.test("Heading:terms P+I+D sums to update() and does not mutate", function()
  local h = Heading.new({ kp = 3, ki = 0.4, kd = 0.2 })
  local out = h:update(1.0, 0.3, 1.5, 0.1, false) -- sp=1.0, meas=0.3 rad, yawRate=1.5, dt=0.1
  local i0 = h.i
  local tm = h:terms(1.0, 0.3, 1.5)
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
  t.near(tm.err, 0.7, 1e-9, "err == wrapped(sp-meas)")
  t.eq(tm.I, h.i, "terms.I == controller.i")
  t.near(tm.P, h.kp * 0.7, 1e-9, "P == kp*err")
  t.near(tm.D, -h.kd * 1.5, 1e-9, "D == -kd*yawRate")
  local tm2 = h:terms(1.0, 0.3, 1.5)
  t.eq(h.i, i0, "terms must not mutate i")
  t.eq(tm2.I, tm.I, "second terms call is stable")
end)

t.test("Heading:terms wraps error across the +-pi boundary like update()", function()
  local PI = math.pi
  local h = Heading.new({ kp = 1, ki = 0, kd = 0 })
  -- setpoint just below +pi, measurement just above -pi: raw diff is ~2pi, wrapped is small negative
  local out = h:update(PI - 0.05, -PI + 0.05, 0, 0.1, false)
  local tm = h:terms(PI - 0.05, -PI + 0.05, 0)
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return across wrap")
  t.near(tm.err, -0.1, 1e-6, "err is the wrapped delta, not the raw ~2pi difference")
end)

t.test("Heading:terms defaults yawRate to 0 like update()", function()
  local h = Heading.new({ kp = 1, ki = 0, kd = 0.5 })
  h:update(0, 0, nil, 0.1, false)
  local out = h:update(1.0, 0, nil, 0.1, false)
  local tm = h:terms(1.0, 0, nil)
  t.near(tm.D, 0, 1e-9, "D == 0 when yawRate is nil")
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
end)

t.test("Heading:rate commands yaw-rate error (kw * (cmd - yawRate))", function()
  local h = Heading.new({ kp = 3, kd = 0.2, kw = 0.8 })
  t.near(h:rate(1.5, 0.5, 0.05), 0.8 * (1.5 - 0.5), 1e-9, "kw * rate error")
  t.near(h:rate(1.0, nil, 0.05), 0.8, 1e-9, "nil yawRate defaults to 0")
end)

-- Translate ----------------------------------------------------------------

t.test("Translate:terms P+I+D sums to update() and does not mutate", function()
  local tr = Translate.new({ kp = 1.5, ki = 0.3, kd = 0.25 })
  local out = tr:update(4, 1, 0.5, 0.1, false) -- sp=4, pos=1, vel=0.5, dt=0.1
  local i0 = tr.i
  local tm = tr:terms(4, 1, 0.5)
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
  t.near(tm.err, 3, 1e-9, "err == sp - pos")
  t.eq(tm.I, tr.i, "terms.I == controller.i")
  t.near(tm.P, tr.kp * 3, 1e-9, "P == kp*err")
  t.near(tm.D, -tr.kd * 0.5, 1e-9, "D == -kd*vel")
  local tm2 = tr:terms(4, 1, 0.5)
  t.eq(tr.i, i0, "terms must not mutate i")
  t.eq(tm2.I, tm.I, "second terms call is stable")
end)

t.test("Translate:terms defaults vel to 0 like update()", function()
  local tr = Translate.new({ kp = 1, ki = 0, kd = 0.4 })
  local out = tr:update(2, 0, nil, 0.1, false)
  local tm = tr:terms(2, 0, nil)
  t.near(tm.D, 0, 1e-9, "D == 0 when vel is nil")
  t.near(tm.P + tm.I + tm.D, out, 1e-6, "P+I+D == update() return")
end)
