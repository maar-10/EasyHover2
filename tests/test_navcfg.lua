-- tests/test_navcfg.lua
-- Pure NAV-settings frames (nav/navcfg.lua) for the cockpit DTC.
-- Transport is 108/109 (same link as waypoints); this module is request->reply only.
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local M = require("nav.navcfg")

t.test("get returns cfg body and leaves cfg unchanged", function()
  local cfg = { fuelReserve = 12, units = "m" }
  local reply, newCfg = M.apply(cfg, M.getFrame())
  t.eq(reply.k, "nav_cfg")
  t.eq(reply.body, cfg)
  t.eq(newCfg, cfg)
end)

t.test("set with table replaces cfg and acks true", function()
  local cfg = { fuelReserve = 12 }
  local body = { fuelReserve = 40, units = "m" }
  local reply, newCfg = M.apply(cfg, M.setFrame(body))
  t.eq(reply.k, "nav_cfg_ack")
  t.eq(reply.ok, true)
  t.eq(reply.err, nil)
  t.eq(newCfg, body)
  t.eq(cfg.fuelReserve, 12, "original cfg table is not mutated")
end)

t.test("set with non-table keeps cfg and acks false", function()
  local cfg = { fuelReserve = 12 }
  local reply, newCfg = M.apply(cfg, { k = "nav_cfg_set", body = "nope" })
  t.eq(reply.k, "nav_cfg_ack")
  t.eq(reply.ok, false)
  t.eq(reply.err, "not a table")
  t.eq(newCfg, cfg)
end)

t.test("unknown k returns nil so wptserver can still own the rest", function()
  local cfg = { fuelReserve = 12 }
  local reply, newCfg = M.apply(cfg, { k = "wpt_get" })
  t.eq(reply, nil)
  t.eq(newCfg, cfg)
  local reply2, newCfg2 = M.apply(cfg, nil)
  t.eq(reply2, nil)
  t.eq(newCfg2, cfg)
end)

return true
