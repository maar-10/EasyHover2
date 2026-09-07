local t = require("tests.framework")
local Translate = require("fcs.control.translate")

t.test("hold: near target behaves like PD-via-cascade (ks*ka*err - ks*vel)", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  -- err = 2, vel = 0  -> velTarget = 2 (uncapped) -> out = 0.4*(2 - 0) = 0.8
  t.near(c:hold(2, 0, 0), 0.8, 1e-9)
  -- err = 0, vel = 3  -> velTarget = 0 -> out = 0.4*(0 - 3) = -1.2 (pure braking)
  t.near(c:hold(0, 0, 3), -1.2, 1e-9)
end)

t.test("hold: velocity target clamps to +-vmax", function()
  local c = Translate.new({ ks = 0.5, ka = 1.0 })
  -- err = 10 -> ka*err = 10, clamped to vmax 3 -> out = 0.5*(3 - 0) = 1.5
  t.near(c:hold(10, 0, 0, 3), 1.5, 1e-9)
  -- err = -10 -> clamped to -3 -> out = 0.5*(-3 - 0) = -1.5
  t.near(c:hold(-10, 0, 0, 3), -1.5, 1e-9)
end)

t.test("hold: nil vel defaults to 0", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  t.near(c:hold(1, 0, nil, 6), 0.4 * 1, 1e-9)
end)

t.test("hold is stateless: repeated calls return the same value, no reset needed", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  local a = c:hold(2, 0, 0.5, 6)
  local b = c:hold(2, 0, 0.5, 6)
  t.near(a, b, 1e-9)
end)

t.test("hold converges without overshoot (does not diverge) from a large displacement", function()
  -- Discrete sim: single-integrator-ish plant vel += a*out*dt, pos += vel*dt.
  -- vmax bounds speed so |pos| never grows after the first approach.
  local c = Translate.new({ ks = 0.3, ka = 1.0 })
  local pos, vel, a, dt, vmax = 8.0, 0.0, 6.0, 0.05, 3.0
  local peak = 0
  for _ = 1, 2000 do
    local out = c:hold(0, pos, vel, vmax)
    if out > 0.3 then out = 0.3 elseif out < -0.3 then out = -0.3 end -- duty cap
    vel = vel + a * out * dt
    pos = pos + vel * dt
    if math.abs(pos) > peak then peak = math.abs(pos) end
  end
  t.truthy(peak <= 8.0 + 1e-6, "never overshoots the initial displacement")
  t.truthy(math.abs(pos) < 0.2, "settles near the hold point, pos=" .. pos)
  t.truthy(math.abs(vel) < 0.2, "settles near zero velocity, vel=" .. vel)
end)

t.test("rate: commands velocity error (unchanged)", function()
  local c = Translate.new({ ks = 0.4 })
  t.near(c:rate(6, 2, 0.05), 0.4 * (6 - 2), 1e-9)
  t.near(c:rate(3, nil, 0.05), 0.4 * 3, 1e-9)
  t.near(c:rate(nil, 2, 0.05), 0.4 * (0 - 2), 1e-9)
end)

t.test("terms: P + I + D reconstructs hold() exactly and does not mutate", function()
  local c = Translate.new({ ks = 0.4, ka = 1.0 })
  local out = c:hold(2, 0, 0.5, 6)
  local tm = c:terms(2, 0, 0.5, 6)
  t.near(tm.P + tm.I + tm.D, out, 1e-9, "P+I+D == hold")
  t.near(tm.I, 0, 1e-9, "I is zero (no integrator)")
  t.near(tm.err, 2, 1e-9, "err = sp - pos")
  local tm2 = c:terms(2, 0, 0.5, 6)
  t.near(tm2.P, tm.P, 1e-9, "terms is pure/repeatable")
end)

t.test("terms: honors vmax clamp in P", function()
  local c = Translate.new({ ks = 0.5, ka = 1.0 })
  local tm = c:terms(10, 0, 0, 3)
  t.near(tm.P, 0.5 * 3, 1e-9, "P uses the clamped velocity target")
end)
