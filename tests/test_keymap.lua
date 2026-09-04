-- tests/test_keymap.lua
local t = require("tests.framework")
local keymap = require("fcs.input.keymap")

-- Synthetic map using raw numeric codes so the test does not depend on the keys API.
local M = {
  [1] = {axis="yaw",  dir=-1}, [2] = {axis="yaw",  dir=1},
  [3] = {axis="lift", dir=1},  [4] = {axis="lift", dir=-1},
  [5] = {axis="sway", dir=-1}, [6] = {axis="sway", dir=1},
  [7] = {axis="surge",dir=1},  [8] = {axis="surge",dir=-1},
}

t.test("keymap resolves each axis+dir to the right held flag", function()
  local h = keymap.resolve(M, {1,3,6,7})
  t.truthy(h.yawLeft, "yawLeft"); t.truthy(h.up, "up")
  t.truthy(h.swayRight, "swayRight"); t.truthy(h.surgeFwd, "surgeFwd")
  t.eq(h.yawRight, nil, "yawRight unset")
  t.eq(h.down, nil, "down unset")
end)

t.test("keymap ignores unmapped codes and empty input", function()
  local h = keymap.resolve(M, {99, 100})
  t.eq(next(h), nil, "no flags for unmapped")
  local e = keymap.resolve(M, {})
  t.eq(next(e), nil, "no flags for empty")
end)

t.test("keymap.default exists and maps WASD/QE/RF", function()
  t.truthy(keymap.default[keys.w], "w mapped")
  t.truthy(keymap.default[keys.q], "q mapped")
  t.truthy(keymap.default[keys.r], "r mapped")
end)

t.test("keymap.drone: WASD tilt, QE yaw, Space/LShift lift", function()
  local drone = keymap.forMode("DRN")
  t.eq(keymap.flagFor(drone, keys.w), "pitchDown", "W nose-down")
  t.eq(keymap.flagFor(drone, keys.s), "pitchUp", "S nose-up")
  t.eq(keymap.flagFor(drone, keys.a), "rollLeft", "A roll left")
  t.eq(keymap.flagFor(drone, keys.d), "rollRight", "D roll right")
  t.eq(keymap.flagFor(drone, keys.q), "yawLeft", "Q yaw left")
  t.eq(keymap.flagFor(drone, keys.e), "yawRight", "E yaw right")
  t.eq(keymap.flagFor(drone, keys.space), "up", "Space lift up")
  t.eq(keymap.flagFor(drone, keys.leftShift), "down", "LShift lift down")
end)

t.test("keymap.forMode routes DRN to drone and LDG to default", function()
  t.truthy(keymap.forMode("LDG") == keymap.default, "LDG uses default layout")
  t.truthy(keymap.forMode("DRN") == keymap.drone, "DRN uses drone layout")
end)

t.test("keymap.forMode: only DRN diverges; coupled layout removed", function()
  local km = require("fcs.input.keymap")
  t.eq(km.coupled, nil, "M.coupled removed")
  t.eq(km.forMode("DRN"), km.drone, "DRN -> drone layout")
  t.eq(km.forMode("PRECISION"), km.default, "PRECISION -> default")
  t.eq(km.forMode("MAN"), km.default, "MAN -> default")
  t.eq(km.forMode("CRUISE"), km.default, "CRUISE -> default")
  t.eq(km.forMode("LDG"), km.default, "LDG -> default")
end)

t.test("CTRL resolves to held.brake in default and drone layouts", function()
  local km = require("fcs.input.keymap")
  local held = km.resolve(km.forMode("PRECISION"), { keys.leftCtrl })
  t.eq(held.brake, true, "default layout brake")
  local heldD = km.resolve(km.forMode("DRN"), { keys.leftCtrl })
  t.eq(heldD.brake, true, "drone layout brake")
  -- a non-brake code is unaffected
  local heldW = km.resolve(km.forMode("PRECISION"), { keys.w })
  t.eq(heldW.brake, nil, "w does not set brake")
end)
