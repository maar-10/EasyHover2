-- tests/test_wptclient.lua
-- Cockpit-side NAV store sync client (ui/basalt/wptclient.lua): PURE request-frame builders + the
-- reply->cache seam. The modem round-trip (send on 108, await on 109 w/ timeout+retry) is in-game
-- glue in nav/app.lua's peer; here we test the framing + cache logic headless.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Client = require("ui.basalt.wptclient")

t.test("request-frame builders have the wire shapes wptserver expects", function()
  t.eq(Client.getFrame().k, "wpt_get")
  local op = Client.opFrame("addWpt", { name = "A" }, 7)
  t.eq(op.k, "wpt_op"); t.eq(op.op, "addWpt"); t.eq(op.args.name, "A"); t.eq(op.rev, 7)
  local dk = Client.diskFrame("export")
  t.eq(dk.k, "wpt_disk"); t.eq(dk.op, "export")
end)

t.test("a fresh client starts offline with an empty store", function()
  local c = Client.new({})
  t.eq(c.online, false)
  t.eq(#c.store.waypoints, 0); t.eq(#c.store.routes, 0)
  t.eq(c.rev, -1)
end)

t.test("onReply(wpt_store) refreshes the cache + marks online", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_store",
    store = { waypoints = { { name = "Home", x = 1, y = 2, z = 3, type = "base" } }, routes = {} },
    rev = 4 })
  t.eq(changed, true)
  t.eq(c.online, true); t.eq(c.rev, 4)
  t.eq(#c.store.waypoints, 1); t.eq(c.store.waypoints[1].name, "Home")
end)

t.test("onReply(wpt_store) with an err carries it but still updates the store", function()
  local c = Client.new({})
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 2, err = "name exists" })
  t.eq(c.lastErr, "name exists"); t.eq(c.online, true)
end)

t.test("onReply(wpt_disk_res) records the disk result + marks online, not a store update", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_disk_res", op = "scan", result = { hasDisk = true, valid = true } }, 10)
  t.eq(changed, false); t.eq(c.online, true)
  t.truthy(c.lastDisk ~= nil and c.lastDisk.op == "scan")
end)

t.test("onReply(wpt_err) records the error, is not a store update", function()
  local c = Client.new({})
  local changed = c:onReply({ k = "wpt_err", err = "bad" })
  t.eq(changed, false); t.eq(c.lastErr, "bad")
end)

t.test("onReply ignores garbage without crashing", function()
  local c = Client.new({})
  t.eq(c:onReply(nil), false)
  t.eq(c:onReply({ k = "nope" }), false)
  t.eq(c:onReply("string"), false)
  t.eq(#c.store.waypoints, 0)
end)

t.test("stale: no reply is stale; a fresh reply is not; past 6000 ms is", function()
  local c = Client.new({ now = function() return 10000 end })
  t.eq(c:stale(10000), true)
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  t.eq(c:stale(10000), false)
  t.eq(c:stale(10000 + 6000), false)
  t.eq(c:stale(10000 + 6001), true)
end)

t.test("refreshOnline clears online when stale", function()
  local c = Client.new({ now = function() return 20000 end })
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  t.eq(c.online, true)
  t.eq(c:refreshOnline(20000), false)
  t.eq(c.online, false)
end)

t.test("mutate and diskOp do not send when stale; request still does", function()
  local sent = {}
  local c = Client.new({
    now = function() return 20000 end,
    link = { send = function(_, f) sent[#sent + 1] = f end },
  })
  c:onReply({ k = "wpt_store", store = { waypoints = {}, routes = {} }, rev = 1 }, 10000)
  c:mutate("addWpt", { name = "X" })
  c:diskOp("export")
  t.eq(#sent, 0)
  c:request()
  t.eq(#sent, 1)
  t.eq(sent[1].k, "wpt_get")
end)

t.test("requestNavCfg sends nav_cfg_get", function()
  local sent = {}
  local c = Client.new({ link = { send = function(_, f) sent[#sent + 1] = f end } })
  c:requestNavCfg()
  t.eq(#sent, 1)
  t.eq(sent[1].k, "nav_cfg_get")
end)

t.test("setNavCfg sends nav_cfg_set with the body", function()
  local sent = {}
  local c = Client.new({ link = { send = function(_, f) sent[#sent + 1] = f end } })
  local body = { fuelReserve = 40 }
  c:setNavCfg(body)
  t.eq(#sent, 1)
  t.eq(sent[1].k, "nav_cfg_set")
  t.eq(sent[1].body, body)
end)

t.test("onReply(nav_cfg) caches navCfg, marks online, fires callback", function()
  local c = Client.new({})
  local got
  c:requestNavCfg(function(body) got = body end)
  local body = { fuelReserve = 40, units = "m" }
  local changed = c:onReply({ k = "nav_cfg", body = body }, 42)
  t.eq(changed, true)
  t.eq(c.online, true)
  t.eq(c.lastReplyAt, 42)
  t.eq(c.navCfg, body)
  t.eq(got, body)
end)

t.test("onReply(nav_cfg_ack) marks online and fires ack callback", function()
  local c = Client.new({})
  local okSeen, errSeen
  c:setNavCfg({ fuelReserve = 1 }, function(ok, err) okSeen = ok; errSeen = err end)
  local changed = c:onReply({ k = "nav_cfg_ack", ok = false, err = "not a table" }, 7)
  t.eq(changed, true)
  t.eq(c.online, true)
  t.eq(c.lastReplyAt, 7)
  t.eq(okSeen, false)
  t.eq(errSeen, "not a table")
end)

return true
