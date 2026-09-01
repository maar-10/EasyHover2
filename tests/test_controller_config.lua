package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local C = require("controller.config")

t.test("defaults carry the shared GPS channel, no token, and an empty roster", function()
  local d = C.defaults()
  t.eq(d.channel, 65000)
  t.eq(d.updateToken, nil)       -- fail-closed: unset until an operator provisions one
  t.truthy(type(d.roster) == "table", "has a roster table")
  t.eq(next(d.roster), nil, "roster starts empty")
end)

t.test("withDefaults deep-merges a saved roster over fresh defaults", function()
  local m = C.withDefaults({
    channel = 65001,
    roster = { B1 = { name = "North pad", expectedPos = { x = 10, y = 20, z = 30 } } },
  })
  t.eq(m.channel, 65001)                       -- saved wins
  t.eq(m.updateToken, nil)                      -- untouched default survives
  t.truthy(m.roster.B1, "saved beacon entry survives the merge")
  t.eq(m.roster.B1.name, "North pad")
  t.eq(m.roster.B1.expectedPos.x, 10)
  t.eq(m.roster.B1.expectedPos.y, 20)
  t.eq(m.roster.B1.expectedPos.z, 30)
end)

t.test("a saved updateToken is preserved through withDefaults; absent stays nil (fail-closed)", function()
  t.eq(C.withDefaults({ updateToken = "abc" }).updateToken, "abc", "saved token kept")
  t.eq(C.withDefaults({}).updateToken, nil, "absent -> nil (fail-closed)")
end)

t.test("save then load round-trips a roster entry (pre-merge, exact)", function()
  local path = "/test_eh2_beacon_control.tbl"
  if fs.exists(path) then fs.delete(path) end
  local cfg = {
    channel = 65000,
    updateToken = "secret",
    roster = {
      B1 = { name = "North pad", expectedPos = { x = 1, y = 2, z = 3 }, lastPos = { x = 1, y = 2, z = 3 } },
    },
  }
  t.truthy(C.save(path, cfg))
  local loaded, existed = C.load(path)
  t.eq(existed, true)
  t.eq(loaded.updateToken, "secret")
  t.eq(loaded.roster.B1.name, "North pad")
  t.eq(loaded.roster.B1.expectedPos.z, 3)
  t.eq(loaded.roster.B1.lastPos.x, 1)
  fs.delete(path)
end)

t.test("load of a missing file returns nil, existed=false, no error", function()
  local path = "/test_eh2_beacon_control_missing.tbl"
  if fs.exists(path) then fs.delete(path) end
  local cfg, existed, err = C.load(path)
  t.eq(cfg, nil)
  t.eq(existed, false)
  t.eq(err, nil)
end)
