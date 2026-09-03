-- tests/test_cfgdefault.lua
local t = require("tests.framework")
local D = require("fcs.io.cfgdefault")
local cfgroles = require("fcs.io.cfgroles")
local cfgspec = require("fcs.io.cfgspec")
local hwconfig = require("fcs.io.hwconfig")

-- Bare-name keyed store, matching cfgspec/cfgaccess read(name)/write(name, body).
local function fakeFs(seed)
  local files = {}
  for k, v in pairs(seed or {}) do files[k] = v end
  return files,
    function(name) return files[name] end,
    function(name, body) files[name] = body; return true end
end

local function setOf(list)
  local s = {}
  for _, k in ipairs(list or {}) do s[k] = true end
  return s
end

t.test("snapshot fcs copies present non-tuning kinds to DEFAULT siblings", function()
  local db = "DEVBIND-BODY"
  local sc = "SENSCAL-BODY"
  local fuel = "FUELCAL-BODY"
  local tuning = "TUNING-MUST-NOT-COPY"
  local files, read, write = fakeFs({
    ["eh2_devbind.tbl"] = db,
    ["eh2_senscal.tbl"] = sc,
    ["eh2_fuelcal.tbl"] = fuel,
    ["eh2_tuning.tbl"] = tuning,
  })
  local r = D.snapshot("fcs", read, write)
  local copied, skipped = setOf(r.copied), setOf(r.skipped)
  t.truthy(copied.devbind and copied.senscal and copied.fuelcal, "non-tuning kinds copied")
  t.eq(copied.tuning, nil, "tuning not in copied")
  t.truthy(skipped.tuning, "tuning always skipped")
  t.eq(files["eh2_devbind.default.tbl"], db)
  t.eq(files["eh2_senscal.default.tbl"], sc)
  t.eq(files["eh2_fuelcal.default.tbl"], fuel)
  t.eq(files["eh2_tuning.default.tbl"], nil, "tuning DEFAULT never written")
  t.eq(files["eh2_tuning.tbl"], tuning, "current tuning untouched")
end)

t.test("snapshot skips missing current files and still skips tuning", function()
  local files, read, write = fakeFs({
    ["eh2_devbind.tbl"] = "ONLY-DB",
    ["eh2_tuning.tbl"] = "TUNING",
  })
  local r = D.snapshot("fcs", read, write)
  local copied, skipped = setOf(r.copied), setOf(r.skipped)
  t.truthy(copied.devbind)
  t.truthy(skipped.senscal and skipped.fuelcal and skipped.tuning)
  t.eq(files["eh2_devbind.default.tbl"], "ONLY-DB")
  t.eq(files["eh2_senscal.default.tbl"], nil)
  t.eq(files["eh2_fuelcal.default.tbl"], nil)
  t.eq(files["eh2_tuning.default.tbl"], nil)
end)

t.test("snapshot ui/nav copy their kinds; no tuning path", function()
  local files, read, write = fakeFs({
    ["eh2_ui_config.tbl"] = "UI-BODY",
    ["eh2_nav.tbl"] = "NAV-BODY",
    ["eh2_nav_wpt.tbl"] = "WPT-BODY",
  })
  local ui = D.snapshot("ui", read, write)
  t.eq(#ui.copied, 1); t.eq(ui.copied[1], "uicfg")
  t.eq(#ui.skipped, 0)
  t.eq(files[cfgroles.defaultFile("uicfg")], "UI-BODY")

  local nav = D.snapshot("nav", read, write)
  local copied = setOf(nav.copied)
  t.truthy(copied.nav and copied.nav_wpt)
  t.eq(#nav.skipped, 0)
  t.eq(files[cfgroles.defaultFile("nav")], "NAV-BODY")
  t.eq(files[cfgroles.defaultFile("nav_wpt")], "WPT-BODY")
end)

t.test("migrate noops when both splits already exist (fused left alone)", function()
  local fused = textutils.serialise(hwconfig.defaults())
  local files, read, write = fakeFs({
    ["eh2_devbind.tbl"] = "DB",
    ["eh2_senscal.tbl"] = "SC",
    ["eh2_hw_config.tbl"] = fused,
  })
  local r = D.migrate(read, write)
  t.eq(r.action, "noop")
  t.eq(files["eh2_devbind.tbl"], "DB")
  t.eq(files["eh2_senscal.tbl"], "SC")
  t.eq(files["eh2_hw_config.tbl"], fused, "fused never rewritten")
end)

t.test("migrate splits fused into missing split files and never deletes fused", function()
  local legacy = hwconfig.merge({
    thrusters = { FL = "thruster_1" },
    sensors = { gimbal = "gimbal_0" },
    fuelRelay = "relay_0",
    bindings = { signHeading = -1, heightOffset = -94.5, signPitch = -1 },
  }, hwconfig.defaults())
  local fusedBody = textutils.serialise(legacy)
  local files, read, write = fakeFs({ ["eh2_hw_config.tbl"] = fusedBody })
  local r = D.migrate(read, write)
  t.eq(r.action, "split")
  t.truthy(files["eh2_devbind.tbl"] ~= nil)
  t.truthy(files["eh2_senscal.tbl"] ~= nil)
  t.eq(files["eh2_hw_config.tbl"], fusedBody, "fused never deleted or rewritten")
  local db = textutils.unserialise(files["eh2_devbind.tbl"])
  local sc = textutils.unserialise(files["eh2_senscal.tbl"])
  t.eq(db.thrusters.FL, "thruster_1")
  t.eq(db.fuelRelay, "relay_0")
  t.eq(sc.signHeading, -1)
  t.eq(sc.heightOffset, -94.5)
end)

t.test("migrate saves only the missing split when one already exists", function()
  local legacy = hwconfig.defaults()
  legacy.thrusters.MAIN = "main_from_fused"
  legacy.bindings.signHeading = -1
  local fusedBody = textutils.serialise(legacy)
  local keep = textutils.serialise(cfgspec.defaults("devbind"))
  local files, read, write = fakeFs({
    ["eh2_hw_config.tbl"] = fusedBody,
    ["eh2_devbind.tbl"] = keep,
  })
  local r = D.migrate(read, write)
  t.eq(r.action, "split")
  t.eq(files["eh2_devbind.tbl"], keep, "existing split untouched")
  t.truthy(files["eh2_senscal.tbl"] ~= nil, "missing senscal materialized")
  t.eq(textutils.unserialise(files["eh2_senscal.tbl"]).signHeading, -1)
  t.eq(files["eh2_hw_config.tbl"], fusedBody)
end)

t.test("migrate noops when fused is absent or unparseable", function()
  local files, read, write = fakeFs({})
  t.eq(D.migrate(read, write).action, "noop")
  t.eq(files["eh2_devbind.tbl"], nil)
  t.eq(files["eh2_senscal.tbl"], nil)

  files, read, write = fakeFs({ ["eh2_hw_config.tbl"] = "not a table" })
  t.eq(D.migrate(read, write).action, "noop")
  t.eq(files["eh2_devbind.tbl"], nil)
  t.eq(files["eh2_senscal.tbl"], nil)
  t.eq(files["eh2_hw_config.tbl"], "not a table")
end)
