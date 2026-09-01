local t = require("tests.framework")
local C = require("fcs.comauto")

local function ctx(over)
  local c = {
    thrusters = { FL = "a", FR = "b", RL = "c", RR = "d" },
    sensors = { altimeter = "alt", gimbal = "gim" },
    senscal = { signPitch = 1, signHeading = 1 },
    comSpanFwd = 4,
    comSpanRight = 3,
    engineOn = true,
    onGround = true,
    gndSafety = false,
    moving = false,
    fuelFrac = 0.5,
    engaged = true,
    flightMode = "PRECISION",
  }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

t.test("missing is nil when every prereq is met", function()
  t.eq(C.missing(ctx()), nil)
end)

t.test("missing reports the first unmet prereq in order", function()
  t.eq(C.missing(ctx({ thrusters = { FL = false, FR = "b", RL = "c", RR = "d" } })), "bind")
  t.eq(C.missing(ctx({ senscal = {} })), "senscal")
  t.eq(C.missing(ctx({ comSpanFwd = 0 })), "span")
  t.eq(C.missing(ctx({ comSpanRight = 0 })), "span")
  t.eq(C.missing(ctx({ engineOn = false })), "engine")
  t.eq(C.missing(ctx({ onGround = false })), "ground")
  t.eq(C.missing(ctx({ gndSafety = true })), "gndSafe")
  t.eq(C.missing(ctx({ moving = true })), "still")
  t.eq(C.missing(ctx({ fuelFrac = 0.1 })), "fuel")
  t.eq(C.missing(ctx({ engaged = false })), "engaged")
  t.eq(C.missing(ctx({ flightMode = "MAN" })), "mode")
end)

t.test("LDG and PRECISION satisfy the mode prereq; other modes do not", function()
  -- L1: Auto-COM is a pad procedure. groundSense (hence a real onGround) is LDG-only, so LDG is
  -- the mode the pilot is actually in on the pad (boot default) -- it MUST satisfy `mode`, or the
  -- lamp deadlocks (onGround requires LDG, mode required PRECISION -- mutually exclusive live).
  t.eq(C.missing(ctx({ flightMode = "LDG" })), nil)          -- the pad mode: allowed
  t.eq(C.missing(ctx({ flightMode = "PRECISION" })), nil)    -- still allowed (heritage; dead on a real pad)
  t.eq(C.missing(ctx({ flightMode = "CRUISE" })), "mode")    -- non-pad mode rejected
  t.eq(C.missing(ctx({ flightMode = "CPL" })), "mode")       -- CPL is a master mode now, not a flight mode
end)

t.test("lamp is red/green/blue", function()
  t.eq(C.lamp(ctx({ engineOn = false }), false), "red")
  t.eq(C.lamp(ctx(), false), "green")
  t.eq(C.lamp(ctx(), true), "blue")
end)

t.test("label is a short ASCII reason", function()
  t.eq(C.label("engine"), "ENG MASTER")
  t.truthy(#C.label("bind") > 0)
end)

t.test("procedure climbs, then captures the windowed-average CoM, then descends", function()
  local p = C.new({ span = 4, climbHeight = 8, settleDelay = 0.2, captureWindow = 0.4,
                    climbRate = 8, descendRate = 8, landEps = 0.5 })
  local meas = { altitude = 0, pitch = 0, roll = 0, onGround = true, swayPos = 0, surgePos = 0, heading = 0 }
  t.eq(p:start(meas), true)
  t.eq(p.phase, "CLIMB")
  local r
  for _ = 1, 20 do
    meas.altitude = math.min(8, (meas.altitude or 0) + 1)
    meas.onGround = meas.altitude < 0.5
    r = p:tick(0.2, meas, { FL = 0.5, FR = 0.5, RL = 0.3, RR = 0.3 }, "NORMAL")
  end
  t.truthy(p.phase == "HOLD" or p.phase == "DESCEND", "reached hover")
  for _ = 1, 10 do
    r = p:tick(0.2, meas, { FL = 0.5, FR = 0.5, RL = 0.3, RR = 0.3 }, "NORMAL")
  end
  t.truthy(p.captured and p.captured.fwd > 0, "captured forward CoM from extra front duty")
  t.truthy(p.phase == "DESCEND" or p.phase == "DONE")
end)

t.test("capture AVERAGES offsetFromDuties over the window (not a single-instant snapshot)", function()
  -- The bug the log exposed: a wobbling craft read at one instant gave -0.7/-0.1/-0.3 across runs.
  -- Averaging the duty-derived offset over the window makes it repeatable. Feed a front-heavy read and
  -- an equal-and-opposite rear-heavy read; the capture must land on their MEAN (~0), not either snapshot.
  local p = C.new({ span = 4, climbHeight = 2, settleDelay = 0, captureWindow = 0.4,
                    climbRate = 100, descendRate = 8, landEps = 0.5 })
  local meas = { altitude = 2, pitch = 0, roll = 0, onGround = false, swayPos = 0, surgePos = 0, heading = 0 }
  p:start({ altitude = 0, pitch = 0, roll = 0, onGround = true, swayPos = 0, surgePos = 0, heading = 0 })
  p:tick(0.1, meas, { FL = 0.5, FR = 0.5, RL = 0.5, RR = 0.5 }, "NORMAL")   -- one big step -> HOLD
  t.eq(p.phase, "HOLD")
  p:tick(0.1, meas, { FL = 0.6, FR = 0.6, RL = 0.4, RR = 0.4 }, "NORMAL")   -- fwd = +0.8
  p:tick(0.1, meas, { FL = 0.6, FR = 0.6, RL = 0.4, RR = 0.4 }, "NORMAL")   -- fwd = +0.8
  p:tick(0.1, meas, { FL = 0.4, FR = 0.4, RL = 0.6, RR = 0.6 }, "NORMAL")   -- fwd = -0.8
  p:tick(0.1, meas, { FL = 0.4, FR = 0.4, RL = 0.6, RR = 0.6 }, "NORMAL")   -- fwd = -0.8 ; capT hits window
  t.truthy(p.captured, "captured after the window elapsed")
  t.near(p.captured.fwd, 0, 1e-6, "captured the MEAN (0), not any single snapshot (+/-0.8)")
end)

t.test("procedure aborts on DAMPED", function()
  local p = C.new({ span = 4, climbHeight = 8 })
  local meas = { altitude = 3, pitch = 0, roll = 0, onGround = false, swayPos = 0, surgePos = 0, heading = 0 }
  p:start({ altitude = 0, pitch = 0, roll = 0, onGround = true, swayPos = 0, surgePos = 0, heading = 0 })
  local r = p:tick(0.05, meas, { FL = 0.4, FR = 0.4, RL = 0.4, RR = 0.4 }, "DAMPED")
  t.eq(p.phase, "DESCEND")
  t.eq(r.abortReason, "DAMPED")
end)

t.test("procedure aborts on tilt", function()
  local p = C.new({ span = 4, tiltLim = 0.1 })
  local meas = { altitude = 1, pitch = 0.2, roll = 0, onGround = false, swayPos = 0, surgePos = 0, heading = 0 }
  p:start({ altitude = 0, pitch = 0, roll = 0, onGround = true, swayPos = 0, surgePos = 0, heading = 0 })
  p.phase = "CLIMB"
  local r = p:tick(0.05, meas, { FL = 0.4, FR = 0.4, RL = 0.4, RR = 0.4 }, "NORMAL")
  t.eq(p.phase, "DESCEND")
  t.eq(r.abortReason, "TILT")
end)
