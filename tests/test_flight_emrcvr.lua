-- tests/test_flight_emrcvr.lua
-- Task 2: emrcvr config threading into Flight (defaults fallback + live setter).
local t = require("tests.framework")
local Flight = require("fcs.runtime.flight")
local Pilot = require("fcs.input.pilot")

local CFG = { headingRate=0.6, climbRate=0.8, leadCapVert=3, cruiseSpeed=1, maxLead=4 }
local function fakeLoop()
  local L = { armed = false, sp = nil, cycles = 0, mode = "NORMAL" }
  function L:setActive(d) self.scheme = d.scheme end
  function L:arm(b) self.armed = b and true or false end
  function L:setpoints(x) self.sp = x end
  function L:getMode() return self.mode end
  function L:cycle(dt, m) self.cycles = self.cycles + 1
    return { mode = self.mode, m = m, demands = nil, duties = nil } end
  return L
end

t.test("Flight.new with no emrcvr dep falls back to tuningdefaults", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local D = require("fcs.io.tuningdefaults").get().emrcvr
  t.eq(type(f.emr), "table", "flight stores an emr config table")
  t.near(f.emr.tripAngle, D.tripAngle, 1e-9)
  t.near(f.emr.exitAngle, D.exitAngle, 1e-9)
  t.near(f.emr.maxDrift, D.maxDrift, 1e-9)
  t.near(f.emr.dwell, D.dwell, 1e-9)
  t.near(f.emr.levelBand, D.levelBand, 1e-9)
  t.near(f.emr.kpAtt, D.kpAtt, 1e-9)
  t.near(f.emr.capAtt, D.capAtt, 1e-9)
  t.near(f.emr.tripAngle, 1.309, 1e-9)
end)

t.test("Flight.new deep-copies the injected emrcvr dep (mutation doesn't leak back)", function()
  local dep = { tripAngle = 1.0, exitAngle = 0.1, maxDrift = 1.0, dwell = 0.2,
                levelBand = 0.2, kpAtt = 0.5, capAtt = 0.5 }
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG), emrcvr = dep })
  f.emr.tripAngle = 9.9
  t.eq(dep.tripAngle, 1.0, "mutating flight.emr must not mutate the caller's dep table")
end)

t.test("Flight:setEmrcvrCfg merges numeric fields live, leaving others intact", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local before = f.emr.exitAngle
  f:setEmrcvrCfg({ tripAngle = 1.2 })
  t.near(f.emr.tripAngle, 1.2, 1e-9, "tripAngle updated")
  t.near(f.emr.exitAngle, before, 1e-9, "exitAngle untouched")
end)

t.test("Flight:setEmrcvrCfg ignores non-numeric values and non-table input", function()
  local f = Flight.new({ loop = fakeLoop(), pilot = Pilot.new(CFG) })
  local before = f.emr.tripAngle
  f:setEmrcvrCfg({ tripAngle = "nope" })
  t.near(f.emr.tripAngle, before, 1e-9, "non-numeric value ignored")
  f:setEmrcvrCfg("not a table")   -- must not error
  t.near(f.emr.tripAngle, before, 1e-9)
  f:setEmrcvrCfg(nil)             -- must not error
  t.near(f.emr.tripAngle, before, 1e-9)
end)
