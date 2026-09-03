local t = require("tests.framework")
local R = require("fcs.io.cfgroles")
local cfgspec = require("fcs.io.cfgspec")

t.test("fcs kinds are the four cfgspec files", function()
  local k = R.kinds("fcs")
  t.eq(#k, 4)
  local set = {}
  for _, x in ipairs(k) do set[x] = true end
  t.truthy(set.devbind and set.senscal and set.tuning and set.fuelcal)
  t.eq(R.file("devbind"), cfgspec.FILES.devbind)
  t.eq(R.file("fuelcal"), cfgspec.FILES.fuelcal)
end)

t.test("ui kind is only uicfg", function()
  local k = R.kinds("ui")
  t.eq(#k, 1); t.eq(k[1], "uicfg")
  t.eq(R.file("uicfg"), "eh2_ui_config.tbl")
  t.eq(R.roleOf("uicfg"), "ui")
end)

t.test("nav kinds are nav + nav_wpt; GPS channel is NOT a separate file", function()
  local k = R.kinds("nav")
  t.eq(#k, 2)
  local set = {}
  for _, x in ipairs(k) do set[x] = true end
  t.truthy(set.nav and set.nav_wpt)
  t.eq(R.file("nav"), "eh2_nav.tbl")
  t.eq(R.file("nav_wpt"), "eh2_nav_wpt.tbl")
  t.eq(R.roleOf("channel"), nil, "Suite eh2_channel.txt is not a nav config")
end)

t.test("roleOf maps every registered kind and rejects unknown", function()
  t.eq(R.roleOf("tuning"), "fcs")
  t.eq(R.roleOf("uicfg"), "ui")
  t.eq(R.roleOf("nav_wpt"), "nav")
  t.eq(R.roleOf("nope"), nil)
end)
