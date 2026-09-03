-- tests/test_waypoints.lua
-- Pure NAV waypoint/route store (nav/waypoints.lua): the model + CRUD + validation + persistence
-- that lives on the NAV PC. No Basalt/peripherals (load/save use fs, exercised headless).
package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local W = require("nav.waypoints")

-- ---- schema / types ----
t.test("defaults is an empty store; withDefaults fills missing keys", function()
  local d = W.defaults()
  t.eq(type(d.waypoints), "table"); t.eq(#d.waypoints, 0)
  t.eq(type(d.routes), "table"); t.eq(#d.routes, 0)
  local m = W.withDefaults({ waypoints = { { name = "A", x = 1, y = 2, z = 3, type = "base" } } })
  t.eq(#m.waypoints, 1); t.eq(type(m.routes), "table")
end)

t.test("TYPES is the fixed vocabulary; isType guards it", function()
  t.eq(#W.TYPES, 4)
  t.truthy(W.isType("base") and W.isType("outpost") and W.isType("facility") and W.isType("poi"))
  t.eq(W.isType("banana"), false)
  t.eq(W.isType(nil), false)
end)

-- ---- waypoint CRUD ----
t.test("addWpt validates and appends; rejects bad input and duplicate names", function()
  local s = W.defaults()
  local wpt, err = W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(wpt ~= nil and err == nil); t.eq(#s.waypoints, 1)
  t.eq(W.addWpt(s, { name = "", x = 1, y = 1, z = 1, type = "base" }), nil, "empty name rejected")
  t.eq(W.addWpt(s, { name = "X", x = "no", y = 1, z = 1, type = "base" }), nil, "non-number coord rejected")
  t.eq(W.addWpt(s, { name = "X", x = 1, y = 1, z = 1, type = "nope" }), nil, "bad type rejected")
  t.eq(W.addWpt(s, { name = "Home", x = 1, y = 1, z = 1, type = "poi" }), nil, "duplicate name rejected")
  t.eq(#s.waypoints, 1, "no bad/dup waypoint was added")
end)

t.test("find / editWpt / deleteWpt operate by name", function()
  local s = W.defaults()
  W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(W.find(s, "Home") ~= nil); t.eq(W.find(s, "Nope"), nil)
  t.truthy(W.editWpt(s, "Home", { y = 5, type = "outpost" }))
  local h = W.find(s, "Home"); t.eq(h.y, 5); t.eq(h.type, "outpost"); t.eq(h.x, 10)
  t.eq(W.editWpt(s, "Ghost", { y = 1 }), nil, "edit of a missing name fails")
  t.truthy(W.editWpt(s, "Home", { name = "Hangar" }))
  t.eq(W.find(s, "Home"), nil, "old name gone after rename")
  t.eq(W.find(s, "Hangar").y, 5)
  W.addWpt(s, { name = "Other", x = 2, y = 2, z = 2, type = "poi" })
  t.eq(W.editWpt(s, "Hangar", { name = "Other" }), nil, "rename onto an existing name fails")
  t.truthy(W.deleteWpt(s, "Hangar")); t.eq(#s.waypoints, 1)
  t.truthy(W.deleteWpt(s, "Other")); t.eq(#s.waypoints, 0)
  t.eq(W.deleteWpt(s, "Home"), nil, "delete of a missing name fails")
end)

t.test("filter returns a type's waypoints, or all when type is nil/all", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  W.addWpt(s, { name = "B", x = 2, y = 2, z = 2, type = "poi" })
  W.addWpt(s, { name = "C", x = 3, y = 3, z = 3, type = "base" })
  t.eq(#W.filter(s, "base"), 2)
  t.eq(#W.filter(s, "poi"), 1)
  t.eq(#W.filter(s, nil), 3); t.eq(#W.filter(s, "all"), 3)
  -- stable insertion order
  t.eq(W.filter(s, "base")[1].name, "A"); t.eq(W.filter(s, "base")[2].name, "C")
end)

-- ---- merge (used by disk import) ----
t.test("mergeWpts adds new and replaces same-name (dedupe by name)", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  W.mergeWpts(s, { { name = "A", x = 9, y = 9, z = 9, type = "poi" },   -- replaces A
                   { name = "B", x = 2, y = 2, z = 2, type = "outpost" } }) -- new
  t.eq(#s.waypoints, 2)
  t.eq(W.find(s, "A").x, 9); t.eq(W.find(s, "A").type, "poi")
  t.truthy(W.find(s, "B") ~= nil)
end)

-- ---- routes (Phase 2): ordered connected legs with per-leg altitude ----
t.test("addRoute validates + appends; rejects blank + duplicate names", function()
  local s = W.defaults()
  local r = W.addRoute(s, "Patrol"); t.truthy(r ~= nil); t.eq(#s.routes, 1); t.eq(#r.legs, 0)
  t.eq(W.addRoute(s, ""), nil, "blank name rejected")
  t.eq(W.addRoute(s, "Patrol"), nil, "duplicate rejected")
  t.truthy(W.findRoute(s, "Patrol") ~= nil); t.eq(W.findRoute(s, "Nope"), nil)
end)

t.test("deleteRoute / renameRoute by name", function()
  local s = W.defaults(); W.addRoute(s, "A")
  t.truthy(W.renameRoute(s, "A", "B")); t.truthy(W.findRoute(s, "B") ~= nil); t.eq(W.findRoute(s, "A"), nil)
  t.truthy(W.deleteRoute(s, "B")); t.eq(#s.routes, 0)
  t.eq(W.deleteRoute(s, "B"), nil)
end)

t.test("addLeg appends a waypoint leg; alt defaults to the waypoint's y", function()
  local s = W.defaults()
  W.addWpt(s, { name = "P1", x = 10, y = 70, z = 20, type = "base" })
  W.addRoute(s, "R")
  local leg = W.addLeg(s, "R", "P1")
  t.truthy(leg ~= nil); t.eq(leg.wpt, "P1"); t.eq(leg.alt, 70, "alt seeded from wpt.y")
  local leg2 = W.addLeg(s, "R", "P1", 120)   -- explicit alt override
  t.eq(leg2.alt, 120)
  t.eq(W.addLeg(s, "R", "ghost"), nil, "leg for a missing waypoint rejected")
  t.eq(W.addLeg(s, "Nope", "P1"), nil, "leg on a missing route rejected")
  t.eq(#W.findRoute(s, "R").legs, 2)
end)

t.test("editLegAlt / deleteLeg / moveLeg reorder the leg list", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 1, y = 1, z = 1, type = "base" })
  W.addWpt(s, { name = "B", x = 2, y = 2, z = 2, type = "poi" })
  W.addWpt(s, { name = "C", x = 3, y = 3, z = 3, type = "poi" })
  W.addRoute(s, "R"); W.addLeg(s, "R", "A"); W.addLeg(s, "R", "B"); W.addLeg(s, "R", "C")
  t.truthy(W.editLegAlt(s, "R", 2, 99)); t.eq(W.findRoute(s, "R").legs[2].alt, 99)
  t.truthy(W.moveLeg(s, "R", 1, 1))   -- A<->B
  t.eq(W.findRoute(s, "R").legs[1].wpt, "B"); t.eq(W.findRoute(s, "R").legs[2].wpt, "A")
  t.eq(W.moveLeg(s, "R", 1, -1), nil, "cannot move the first leg up")
  t.truthy(W.deleteLeg(s, "R", 3)); t.eq(#W.findRoute(s, "R").legs, 2)
end)

t.test("resolveLegs pairs each leg with its waypoint x/z + per-leg alt; flags unresolved", function()
  local s = W.defaults()
  W.addWpt(s, { name = "A", x = 10, y = 5, z = 20, type = "base" })
  W.addRoute(s, "R"); W.addLeg(s, "R", "A", 88); W.addLeg(s, "R", "Gone")  -- addLeg("Gone") is rejected...
  -- ...so inject an unresolved leg directly to prove resolveLegs flags it
  W.findRoute(s, "R").legs[2] = { wpt = "Gone", alt = 40 }
  local legs = W.resolveLegs(s, W.findRoute(s, "R"))
  t.eq(#legs, 2)
  t.eq(legs[1].resolved, true); t.eq(legs[1].x, 10); t.eq(legs[1].z, 20); t.eq(legs[1].y, 88, "per-leg alt")
  t.eq(legs[2].resolved, false); t.eq(legs[2].wpt, "Gone")
end)

-- ---- persistence ----
t.test("save then load round-trips the store", function()
  local path = "/eh2_nav_wpt_test.tbl"
  if fs.exists(path) then fs.delete(path) end
  local s = W.defaults()
  W.addWpt(s, { name = "Home", x = 10, y = -47, z = 20, type = "base" })
  t.truthy(W.save(path, s))
  local loaded, existed = W.load(path)
  t.eq(existed, true)
  t.eq(#loaded.waypoints, 1); t.eq(loaded.waypoints[1].name, "Home"); t.eq(loaded.waypoints[1].y, -47)
  fs.delete(path)
end)

t.test("load of a missing file is absent, not an error", function()
  local s, existed = W.load("/nope_nav_wpt.tbl")
  t.eq(s, nil); t.eq(existed, false)
end)

-- Break this test would catch: waypoint load of current ignoring a session overlay.
t.test("load prefers eh2_nav_wpt.session.tbl over current when it parses", function()
  local current = "/eh2_nav_wpt.tbl"
  local session = "/eh2_nav_wpt.session.tbl"
  if fs.exists(current) then fs.delete(current) end
  if fs.exists(session) then fs.delete(session) end
  local cur = W.defaults()
  W.addWpt(cur, { name = "Current", x = 1, y = 1, z = 1, type = "base" })
  local ses = W.defaults()
  W.addWpt(ses, { name = "Session", x = 9, y = 9, z = 9, type = "poi" })
  t.truthy(W.save(current, cur))
  t.truthy(W.save(session, ses))
  local loaded, existed = W.load(current)
  t.eq(existed, true)
  t.eq(#loaded.waypoints, 1)
  t.eq(loaded.waypoints[1].name, "Session")
  fs.delete(current); fs.delete(session)
end)

t.test("load falls back to current when wpt session is missing or unparseable", function()
  local current = "/eh2_nav_wpt.tbl"
  local session = "/eh2_nav_wpt.session.tbl"
  if fs.exists(current) then fs.delete(current) end
  if fs.exists(session) then fs.delete(session) end
  local cur = W.defaults()
  W.addWpt(cur, { name = "Current", x = 1, y = 1, z = 1, type = "base" })
  t.truthy(W.save(current, cur))
  local loaded = select(1, W.load(current))
  t.eq(loaded.waypoints[1].name, "Current")
  local f = fs.open(session, "w"); f.write("not a table"); f.close()
  local loaded2 = select(1, W.load(current))
  t.eq(loaded2.waypoints[1].name, "Current")
  fs.delete(current); fs.delete(session)
end)

return true
