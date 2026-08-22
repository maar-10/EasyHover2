package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Tri = require("nav.lib.trilaterate")

-- Build an observation {pos, dist} for a beacon at p = {x,y,z} against a known target {x,y,z}.
local function obs(p, target)
  local dx, dy, dz = target[1] - p[1], target[2] - p[2], target[3] - p[3]
  return { pos = { x = p[1], y = p[2], z = p[3] }, dist = math.sqrt(dx * dx + dy * dy + dz * dz) }
end

t.test("recovers a known position from 4 non-coplanar beacons + exact distances", function()
  local target = { 3, 4, 5 }
  local o = { obs({ 0, 0, 0 }, target), obs({ 10, 0, 0 }, target),
              obs({ 0, 10, 0 }, target), obs({ 0, 0, 10 }, target) }
  local p = Tri.solve(o)
  t.truthy(p ~= nil, "returns a position")
  t.truthy(math.abs(p.x - 3) < 1e-6 and math.abs(p.y - 4) < 1e-6 and math.abs(p.z - 5) < 1e-6,
    "recovers (3,4,5)")
end)

t.test("returns nil for fewer than 4 observations", function()
  local target = { 1, 2, 3 }
  t.eq(Tri.solve({ obs({ 0, 0, 0 }, target), obs({ 10, 0, 0 }, target), obs({ 0, 10, 0 }, target) }), nil)
end)

t.test("returns nil for a coplanar constellation (degenerate, no unique fix)", function()
  local target = { 3, 4, 5 }
  local o = { obs({ 0, 0, 0 }, target), obs({ 10, 0, 0 }, target),
              obs({ 0, 10, 0 }, target), obs({ 10, 10, 0 }, target) } -- all z = 0
  t.eq(Tri.solve(o), nil)
end)

t.test("with 5+ beacons, ALL quartets are considered, not just the first four", function()
  -- The old solver hardcoded obs[1..4]: a badly-placed alphabetical quartet (here: the first
  -- four are coplanar -> old code returned nil even though beacon 5 fixes the geometry).
  local target = { 3, 4, 5 }
  local o = { obs({ 0, 0, 0 }, target), obs({ 10, 0, 0 }, target),
              obs({ 0, 10, 0 }, target), obs({ 10, 10, 0 }, target),   -- coplanar z=0
              obs({ 0, 0, 10 }, target) }                              -- breaks degeneracy
  local p = Tri.solve(o)
  t.truthy(p ~= nil, "a good quartet exists among 5 beacons")
  t.truthy(math.abs(p.x - 3) < 1e-6 and math.abs(p.y - 4) < 1e-6 and math.abs(p.z - 5) < 1e-6,
    "recovers (3,4,5)")
end)

t.test("a corrupted REFERENCE range no longer poisons the fix when a clean quartet exists", function()
  -- The old solver ALWAYS used obs[1] as the linearisation reference: one bad range on beacon 1
  -- (blocked/reflective host) poisoned every solve. Best-of-quartets can simply drop beacon 1.
  local target = { 3, 4, 5 }
  local o = { obs({ 0, 0, 0 }, target), obs({ 10, 0, 0 }, target),
              obs({ 0, 10, 0 }, target), obs({ 0, 0, 10 }, target),
              obs({ 5, 5, -12 }, target) }
  o[1].dist = o[1].dist + 8
  local p = Tri.solve(o)
  t.truthy(p ~= nil)
  t.truthy(math.abs(p.x - 3) < 1e-6 and math.abs(p.y - 4) < 1e-6 and math.abs(p.z - 5) < 1e-6,
    ("exact fix from the clean quartet: got %s,%s,%s"):format(p.x, p.y, p.z))
end)

t.test("exact 4-beacon input still solves identically (single quartet)", function()
  local target = { 7, -2, 9 }
  local o = { obs({ 0, 0, 0 }, target), obs({ 20, 0, 0 }, target),
              obs({ 0, 20, 0 }, target), obs({ 0, 0, 20 }, target) }
  local p = Tri.solve(o)
  t.truthy(math.abs(p.x - 7) < 1e-6 and math.abs(p.y + 2) < 1e-6 and math.abs(p.z - 9) < 1e-6)
end)
