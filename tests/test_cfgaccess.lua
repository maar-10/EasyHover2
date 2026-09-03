-- tests/test_cfgaccess.lua
local t = require("tests.framework")
local A = require("fcs.io.cfgaccess")
local cfgspec = require("fcs.io.cfgspec")
local hwconfig = require("fcs.io.hwconfig")

-- A fake fs: bare-name keyed store, matching cfgspec's write(name, body)/read(name) contract.
local function fakeFs(seed)
  local files = {}
  for k, v in pairs(seed or {}) do files[k] = v end
  return files,
    function(name) return files[name] end,
    function(name, body) files[name] = body; return true end,
    function(name) files[name] = nil end
end

t.test("getKind tuning/fuelcal load their own file (merged with defaults)", function()
  local files, read = fakeFs({ ["eh2_tuning.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.42 } }) })
  local tuning = A.getKind("tuning", read)
  t.eq(tuning.gains.hoverDuty, 0.42, "saved value survives the merge")
  t.truthy(tuning.caps ~= nil, "defaults fill the rest")
  local fuel = A.getKind("fuelcal", (select(2, fakeFs({}))))
  t.truthy(fuel.fuel ~= nil, "fuelcal defaults when no file")
end)

t.test("getKind devbind prefers the split file when present", function()
  local db = cfgspec.defaults("devbind"); db.fuelRelay = "relay_7"
  local _, read = fakeFs({ ["eh2_devbind.tbl"] = textutils.serialise(db) })
  t.eq(A.getKind("devbind", read).fuelRelay, "relay_7")
end)

t.test("getKind devbind falls back to the fused legacy slice when no split", function()
  local legacy = hwconfig.defaults(); legacy.thrusters.MAIN = "main_thruster_9"
  local _, read = fakeFs({ [A.FUSED] = textutils.serialise(legacy) })
  local db = A.getKind("devbind", read)
  t.eq(db.thrusters.MAIN, "main_thruster_9", "reads the fused thrusters slice")
end)

t.test("getKind devbind returns merged defaults when neither split nor fused exists", function()
  local _, read = fakeFs({})
  local db = A.getKind("devbind", read)
  t.truthy(db.thrusters ~= nil and db.sensors ~= nil, "fresh FCS is still editable, never nil")
end)

t.test("setKind rejects an invalid body without writing", function()
  local files, read, write = fakeFs({})
  local ok, err = A.setKind("tuning", { caps = {} }, read, write)  -- missing gains/feel
  t.eq(ok, false); t.truthy(err)
  t.eq(files["eh2_tuning.tbl"], nil, "nothing written on a failed validate")
end)

t.test("setKind tuning validates and persists to its own file", function()
  local files, read, write = fakeFs({})
  local ok = A.setKind("tuning", cfgspec.defaults("tuning"), read, write)
  t.eq(ok, true); t.truthy(files["eh2_tuning.tbl"] ~= nil)
end)

t.test("setKind devbind writes the split AND materializes the senscal sibling from the fused slice", function()
  local legacy = hwconfig.defaults()
  local files, read, write = fakeFs({ [A.FUSED] = textutils.serialise(legacy) })
  local ok = A.setKind("devbind", cfgspec.defaults("devbind"), read, write)
  t.eq(ok, true)
  t.truthy(files["eh2_devbind.tbl"] ~= nil, "devbind split written")
  t.truthy(files["eh2_senscal.tbl"] ~= nil, "sibling senscal split materialized so tryAssemble uses the pair")
  local sib = textutils.unserialise(files["eh2_senscal.tbl"])
  t.truthy(sib.signPitch ~= nil, "sibling seeded from the fused senscal slice")
end)

t.test("setKind senscal materializes a devbind sibling from defaults when no fused exists", function()
  local files, read, write = fakeFs({})
  local ok = A.setKind("senscal", cfgspec.defaults("senscal"), read, write)
  t.eq(ok, true)
  t.truthy(files["eh2_devbind.tbl"] ~= nil, "sibling devbind materialized from defaults")
end)

t.test("setKind does NOT clobber an existing sibling split", function()
  local db = cfgspec.defaults("devbind"); db.fuelRelay = "keep_me"
  local files, read, write = fakeFs({ ["eh2_devbind.tbl"] = textutils.serialise(db) })
  A.setKind("senscal", cfgspec.defaults("senscal"), read, write)
  t.eq(textutils.unserialise(files["eh2_devbind.tbl"]).fuelRelay, "keep_me", "present sibling untouched")
end)

t.test("getKind prefers session overlay over current for tuning", function()
  local _, read = fakeFs({
    ["eh2_tuning.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.1 } }),
    ["eh2_tuning.session.tbl"] = textutils.serialise({ gains = { hoverDuty = 0.9 } }),
  })
  t.eq(A.getKind("tuning", read).gains.hoverDuty, 0.9)
end)

t.test("getKind prefers session overlay over split for devbind", function()
  local dbCur = cfgspec.defaults("devbind"); dbCur.fuelRelay = "CUR"
  local dbSes = cfgspec.defaults("devbind"); dbSes.fuelRelay = "SES"
  local _, read = fakeFs({
    ["eh2_devbind.tbl"] = textutils.serialise(dbCur),
    ["eh2_devbind.session.tbl"] = textutils.serialise(dbSes),
  })
  t.eq(A.getKind("devbind", read).fuelRelay, "SES")
end)

t.test("setKind deletes the session overlay after a successful save", function()
  local files, read, write, delete = fakeFs({
    ["eh2_tuning.session.tbl"] = "SESSION",
    ["eh2_devbind.session.tbl"] = "DB-SESSION",
  })
  t.eq(A.setKind("tuning", cfgspec.defaults("tuning"), read, write, delete), true)
  t.eq(files["eh2_tuning.session.tbl"], nil, "explicit save ends DEFAULT-for-this-boot")
  t.truthy(files["eh2_tuning.tbl"] ~= nil)
  A.setKind("devbind", cfgspec.defaults("devbind"), read, write, delete)
  t.eq(files["eh2_devbind.session.tbl"], nil, "split save also drops its session overlay")
end)
