package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local C = require("nav.config")

t.test("defaults pin the shared GPS channel, the relay channel and the sign default", function()
  local d = C.defaults()
  t.eq(d.channel, 65000)          -- same channel the beacons broadcast on
  t.eq(d.relay.channel, 107)      -- wired relay channel the FCS never opens
  t.eq(d.navtable.sign, 1)
  t.eq(d.thresholds.maxAgeMs, 3000)
  t.eq(d.thresholds.minQuality, 0.5)
end)

t.test("withDefaults deep-merges saved values over fresh defaults", function()
  local m = C.withDefaults({ navtable = { name = "nav_0", sign = -1 }, relay = { channel = 109 } })
  t.eq(m.navtable.name, "nav_0")
  t.eq(m.navtable.sign, -1)        -- saved wins
  t.eq(m.relay.channel, 109)
  t.eq(m.channel, 65000)           -- untouched default survives
end)

t.test("save then load round-trips the saved (pre-merge) table", function()
  local path = "/test_eh2_nav.tbl"
  if fs.exists(path) then fs.delete(path) end
  local cfg = { channel = 65000, navtable = { name = "nav_1", sign = -1 }, relay = { channel = 107 } }
  t.truthy(C.save(path, cfg))
  local loaded, existed = C.load(path)
  t.eq(existed, true)
  t.eq(loaded.navtable.name, "nav_1")
  t.eq(loaded.navtable.sign, -1)
  fs.delete(path)
end)

t.test("GPS channel lives in eh2_nav.tbl defaults, not a sidecar file", function()
  local C = require("nav.config")
  t.eq(type(C.defaults().channel), "number")
  t.eq(C.PATH, "/eh2_nav.tbl")
end)
