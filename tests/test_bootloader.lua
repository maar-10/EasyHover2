local t = require("tests.framework")
local L = require("fcs.boot.loader")
local C = require("fcs.io.cfgspec")
local TD = require("fcs.io.tuningdefaults")

t.test("resolve assembles hw + tuning from chosen valid sources", function()
  local src = { get = function(concern, s)
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, out = L.resolve({ binding="current", sensor="current", tuning="default" }, src)
  t.eq(ok, true); t.truthy(out.hw.thrusters and out.hw.bindings and out.tuning.gains)
end)
t.test("SOURCES lists current/default/disk for binding, sensor, and tuning", function()
  t.eq(L.SOURCES.binding[1], "current")
  t.eq(L.SOURCES.binding[2], "default")
  t.eq(L.SOURCES.binding[3], "disk")
  t.eq(L.SOURCES.binding[4], nil)
  t.eq(L.SOURCES.sensor[1], "current")
  t.eq(L.SOURCES.sensor[2], "default")
  t.eq(L.SOURCES.sensor[3], "disk")
  t.eq(L.SOURCES.sensor[4], nil)
  t.eq(L.SOURCES.tuning[1], "current")
  t.eq(L.SOURCES.tuning[2], "default")
  t.eq(L.SOURCES.tuning[3], "disk")
  t.eq(L.SOURCES.tuning[4], nil)
end)
t.test("resolve fails clearly on a missing/invalid source", function()
  local src = { get = function() return nil end }
  local ok, _, err = L.resolve({ binding="disk", sensor="current", tuning="disk" }, src)
  t.eq(ok, false); t.truthy(err)
end)
t.test("resolve reports WHICH concern failed (for per-concern re-pick)", function()
  -- only the sensor source is missing; binding + tuning resolve fine
  local src = { get = function(concern)
    if concern == "sensor" then return nil end
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }
  local ok, _, err, failed = L.resolve({ binding="current", sensor="current", tuning="default" }, src)
  t.eq(ok, false); t.eq(failed, "sensor", "the failing concern is returned")
  -- an invalid source string reports its concern too
  local ok2, _, _, failed2 = L.resolve({ binding="bogus", sensor="current", tuning="default" }, src)
  t.eq(ok2, false); t.eq(failed2, "binding")
end)
-- Break this test would catch: "default" rejected as invalid for binding, or tuning
-- DEFAULT without a sibling file not allowed to use the code baseline.
t.test("default with missing sibling fails for binding and succeeds for tuning (code baseline)", function()
  local src = { get = function(concern, s)
    if s == "default" then
      -- missing sibling DEFAULT file: binding/sensor have no fallback; tuning uses code baseline
      if concern == "tuning" then return TD.get() end
      return nil
    end
    if concern == "binding" then return C.defaults("devbind") end
    if concern == "sensor" then return C.defaults("senscal") end
    if concern == "tuning" then return C.defaults("tuning") end
  end }

  local okB, _, errB, failedB = L.resolve({ binding="default", sensor="current", tuning="current" }, src)
  t.eq(okB, false)
  t.eq(failedB, "binding")
  t.truthy(tostring(errB):find("no config available", 1, true),
    "missing sibling is unavailable, not an invalid source")

  local okT, outT = L.resolve({ binding="current", sensor="current", tuning="default" }, src)
  t.eq(okT, true)
  t.truthy(outT and outT.hw and outT.hw.thrusters and outT.hw.bindings)
  t.eq(outT.tuning.gains.hoverDuty, 0.26)
end)
