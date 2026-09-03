local t = require("tests.framework")
local C = require("fcs.io.cfgspec")

t.test("defaults + merge are additive per kind", function()
  local d = C.defaults("devbind")
  t.truthy(d.thrusters and d.sensors, "devbind shape")
  local m = C.merge("devbind", { thrusters = { FL = "thruster_3" } })
  t.eq(m.thrusters.FL, "thruster_3", "saved wins")
  t.eq(m.thrusters.FR, false, "default fills the rest")
end)

t.test("validate accepts good, rejects wrong shape", function()
  t.eq((C.validate("tuning", C.defaults("tuning"))), true)
  local ok, err = C.validate("devbind", { nope = 1 })
  t.eq(ok, false)
  t.truthy(err)
end)

t.test("load merges saved over defaults via injected reader", function()
  local body = textutils.serialise({ bindings = nil, thrusters = { MAIN = "thruster_9" } })
  local m = C.load("devbind", function() return body end)
  t.eq(m.thrusters.MAIN, "thruster_9")
end)

t.test("cfgspec fuelcal: default + file + validate", function()
  t.eq(C.FILES.fuelcal, "eh2_fuelcal.tbl", "filename")
  t.eq(C.defaults("fuelcal").fuel, "Biodiesel", "default fuel")
  -- absent file -> merged default
  local cfg = C.load("fuelcal", function() return nil end)
  t.eq(cfg.fuel, "Biodiesel", "absent -> default")
  -- saved file round-trips
  local stored
  C.save("fuelcal", { fuel = "Ethanol" }, function(_, body) stored = body end)
  local back = C.load("fuelcal", function() return stored end)
  t.eq(back.fuel, "Ethanol", "round-trip")
  t.eq((C.validate("fuelcal", { fuel = "Diesel" })), true, "valid")
  t.eq((C.validate("fuelcal", {})), false, "missing fuel invalid")
end)

t.test("legacy hw_config splits and reassembles losslessly (no calibration lost)", function()
  local hw = require("fcs.io.hwconfig").merge({
    thrusters = { FL = "thruster_1" }, sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0", bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, require("fcs.io.hwconfig").defaults())
  local split = C.splitLegacy(hw)
  t.eq(split.devbind.thrusters.FL, "thruster_1"); t.eq(split.senscal.signHeading, -1)
  local hw2 = C.assembleHw(split.devbind, split.senscal)
  t.eq(hw2.thrusters.FL, "thruster_1"); t.eq(hw2.sensors.gimbal, "gimbal_0")
  t.eq(hw2.fuelRelay, "relay_0"); t.eq(hw2.bindings.heightOffset, -94.5); t.eq(hw2.bindings.signHeading, -1)
end)

t.test("tryAssemble uses split files when present", function()
  local files = {
    ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = { FL = "t_fl" }, sensors = { altimeter = "alt" } }),
    ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = -1 }),
  }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(err, nil)
  t.eq(hw.thrusters.FL, "t_fl")
  t.eq(hw.bindings.signHeading, -1)
end)

t.test("tryAssemble returns nil,nil when neither split exists", function()
  local hw, err = C.tryAssemble(function() return nil end)
  t.eq(hw, nil); t.eq(err, nil)
end)

-- F3: a split is only usable when BOTH files exist. If only one is present, load() returns
-- IDENTITY defaults for the missing kind (signHeading=1, gimbalRollIdx=2, ...); assembling then
-- would fly a real craft (signHeading=-1) with an identity sign map -- the Flight #9 negative
-- spring. tryAssemble must instead return nil so the caller falls through to the fused config.
t.test("tryAssemble returns nil,nil when only devbind exists (falls through to fused)", function()
  local files = { ["eh2_devbind.tbl"] = textutils.serialise({ thrusters = { FL = "t_fl" }, sensors = { altimeter = "alt" } }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.eq(err, nil)
end)

t.test("tryAssemble returns nil,nil when only senscal exists (falls through to fused)", function()
  local files = { ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = -1, signHeading = -1 }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.eq(err, nil)
end)

t.test("tryAssemble still returns nil,err on a corrupt split (no silent fused-over-corrupt)", function()
  local files = { ["eh2_devbind.tbl"] = "not a table",
                  ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = 1, signHeading = 1 }) }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(hw, nil); t.truthy(err)
end)

t.test("loadLive prefers parseable session overlay over current", function()
  local files = {
    ["eh2_tuning.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.1 } }),
    ["eh2_tuning.session.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.9 } }),
  }
  local cfg = C.loadLive("tuning", function(name) return files[name] end)
  t.eq(cfg.gains.hoverDuty, 0.9, "session overlay wins")
end)

t.test("loadLive falls through to current when session is unparseable", function()
  local files = {
    ["eh2_tuning.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.1 } }),
    ["eh2_tuning.session.tbl"] = "not a table",
  }
  local cfg = C.loadLive("tuning", function(name) return files[name] end)
  t.eq(cfg.gains.hoverDuty, 0.1, "unparseable session must not hide current")
end)

t.test("tryAssemble prefers parseable binding session over current splits", function()
  local files = {
    ["eh2_devbind.tbl"] = textutils.serialise({
      thrusters = { FL = "current_fl" }, sensors = { altimeter = "alt" }, fuelRelay = "CUR",
    }),
    ["eh2_senscal.tbl"] = textutils.serialise({ signPitch = 1, signHeading = 1 }),
    ["eh2_devbind.session.tbl"] = textutils.serialise({
      thrusters = { FL = "default_fl" }, sensors = { altimeter = "alt" }, fuelRelay = "DEF",
    }),
  }
  local hw, err = C.tryAssemble(function(name) return files[name] end)
  t.eq(err, nil)
  t.eq(hw.fuelRelay, "DEF", "session binding must win over current split")
  t.eq(hw.thrusters.FL, "default_fl")
  t.eq(hw.bindings.signHeading, 1, "sensor still from current split")
end)

-- L2: the loop steers by signHeading; the PFD tape reads rawHeading*compassSign. A senscal saved
-- before compassSign existed has signHeading but no compassSign -> merge defaults it to +1, so on a
-- craft with signHeading=-1 the tape reads mirrored vs the turn. Backfill compassSign := signHeading
-- at load when it is absent, so the tape matches the loop without a heading re-cal.
t.test("senscal load backfills compassSign from signHeading when the cal predates compassSign", function()
  local body = textutils.serialise({ signPitch = 1, signHeading = -1, signYawRate = 1 })  -- no compassSign
  local cfg = C.load("senscal", function() return body end)
  t.eq(cfg.signHeading, -1)
  t.eq(cfg.compassSign, -1, "backfilled to match signHeading, not defaulted to +1")
end)

t.test("senscal load keeps an explicit compassSign that differs from signHeading", function()
  local body = textutils.serialise({ signPitch = 1, signHeading = -1, compassSign = 1 })
  local cfg = C.load("senscal", function() return body end)
  t.eq(cfg.compassSign, 1, "operator's explicit compassSign is never overridden")
end)

t.test("senscal backfill does not fire for other kinds or when signHeading is absent", function()
  local dev = C.merge("devbind", { thrusters = { FL = "t" } })
  t.eq(dev.compassSign, nil, "devbind has no compassSign key to invent")
  local sc = C.merge("senscal", {})                 -- nothing saved -> pure defaults
  t.eq(sc.compassSign, 1, "default compassSign stays +1 when nothing was saved")
end)
