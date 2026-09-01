package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local BR = require("beacon.runtime")

-- The mesh self-check: a beacon compares each peer's MEASURED range (CC modem distance) against the
-- geometric distance implied by both beacons' CONFIGURED coordinates. A typo in anyone's position
-- makes those disagree -> MISMATCH, which is how a mis-entered coordinate gets caught before it
-- silently ruins every NAV fix.

t.test("geoDistance is plain Euclidean distance", function()
  t.near(BR.geoDistance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }), 5, 1e-9)
end)

t.test("selfCheck passes when measured ranges match the configured geometry", function()
  local selfPos = { x = 0, y = 0, z = 0 }
  local peers = {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },
    C = { pos = { x = 0, y = 0, z = 40 }, dist = 40 },
  }
  local r = BR.selfCheck(selfPos, peers)
  t.truthy(r.ok, "no mismatches")
  t.eq(r.checked, 2)
  t.eq(#r.mismatches, 0)
end)

t.test("selfCheck flags a beacon whose configured coordinates disagree with its measured range", function()
  local selfPos = { x = 0, y = 0, z = 0 }
  local peers = {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },     -- consistent
    C = { pos = { x = 0, y = 0, z = 40 }, dist = 12 },     -- says 40 blocks away, measured 12 -> typo
  }
  local r = BR.selfCheck(selfPos, peers)
  t.truthy(not r.ok)
  t.eq(#r.mismatches, 1)
  t.eq(r.mismatches[1].id, "C")
  t.near(r.mismatches[1].expected, 40, 1e-9)
  t.near(r.mismatches[1].measured, 12, 1e-9)
end)

t.test("selfCheck skips peers heard without a measured distance", function()
  local r = BR.selfCheck({ x = 0, y = 0, z = 0 }, {
    B = { pos = { x = 30, y = 0, z = 0 }, dist = 30 },
    D = { pos = { x = 1, y = 1, z = 1 } },   -- no dist (cross-dimension) -> not checkable
  })
  t.eq(r.checked, 1)
  t.truthy(r.ok)
end)

t.test("a small measurement error within tolerance is not a mismatch", function()
  local r = BR.selfCheck({ x = 0, y = 0, z = 0 },
    { B = { pos = { x = 30, y = 0, z = 0 }, dist = 30.4 } }, 1.0)
  t.truthy(r.ok, "0.4 blocks < 1.0 tolerance")
end)

t.test("a placement/reference offset (config coord vs actual modem block) does NOT false-flag", function()
  -- Real world (operator screenshot): the modem-measured range and the config-coordinate range differ
  -- by ~1.4 blocks because the entered coordinate is not the exact modem block. The check exists to
  -- catch gross TYPOS (tens+ of blocks), so the DEFAULT tolerance must clear this placement noise.
  local r = BR.selfCheck({ x = 6462, y = 200, z = 6107 },
    { ["beacon-70"] = { pos = { x = -7210, y = 64, z = -7260 }, dist = 19122.6 } })   -- DEFAULT tolerance
  t.truthy(r.ok, "~1.4-block placement offset is within the default tolerance, not a mismatch")
end)

t.test("a real coordinate typo (tens+ of blocks off) is still caught at the default tolerance", function()
  local r = BR.selfCheck({ x = 0, y = 0, z = 0 },
    { X = { pos = { x = 0, y = 0, z = 100 }, dist = 88 } })   -- 12 blocks off, DEFAULT tolerance
  t.truthy(not r.ok, "a 12-block disagreement still flags a typo")
  t.eq(#r.mismatches, 1)
end)
