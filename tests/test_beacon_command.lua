package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Command = require("beacon.command")
local config = require("beacon.config")

t.test("enable sets cfg.enabled=true and requests a save", function()
  local cfg = { enabled = false }
  local r = Command.apply(cfg, "enable")
  t.eq(cfg.enabled, true)
  t.eq(r.save, true)
end)

t.test("disable sets cfg.enabled=false and requests a save", function()
  local cfg = { enabled = true }
  local r = Command.apply(cfg, "disable")
  t.eq(cfg.enabled, false)
  t.eq(r.save, true)
end)

t.test("setInterval clamps via beacon.config and requests save + rearm", function()
  local cfg = { intervalMs = 3000 }
  local r = Command.apply(cfg, "setInterval", { intervalMs = 10 })
  t.eq(cfg.intervalMs, config.MIN_INTERVAL_MS, "clamped up to the floor")
  t.eq(r.save, true)
  t.eq(r.rearm, true)

  local r2 = Command.apply(cfg, "setInterval", { intervalMs = 999999 })
  t.eq(cfg.intervalMs, config.MAX_INTERVAL_MS, "clamped down to the ceiling")
  t.eq(r2.save, true); t.eq(r2.rearm, true)

  local r3 = Command.apply(cfg, "setInterval", nil)
  t.eq(cfg.intervalMs, config.DEFAULT_INTERVAL_MS, "missing args -> clampInterval's default")
  t.eq(r3.save, true); t.eq(r3.rearm, true)
end)

t.test("setPos with a valid numeric x/y/z sets cfg.pos and requests a save", function()
  local cfg = { pos = { x = 0, y = 0, z = 0 } }
  local r = Command.apply(cfg, "setPos", { pos = { x = 1, y = 2, z = 3 } })
  t.eq(cfg.pos.x, 1); t.eq(cfg.pos.y, 2); t.eq(cfg.pos.z, 3)
  t.eq(r.save, true)
end)

t.test("setPos with a malformed pos leaves cfg.pos unchanged and does not save", function()
  local orig = { x = 5, y = 6, z = 7 }
  local cfg = { pos = orig }
  local r1 = Command.apply(cfg, "setPos", { pos = { x = 1, y = "nope", z = 3 } })
  t.eq(cfg.pos, orig, "unchanged: y not numeric")
  t.eq(r1.save, nil, "no save requested")

  local r2 = Command.apply(cfg, "setPos", { pos = nil })
  t.eq(cfg.pos, orig, "unchanged: no pos at all")
  t.eq(r2.save, nil)

  local r3 = Command.apply(cfg, "setPos", nil)
  t.eq(cfg.pos, orig, "unchanged: no args at all")
  t.eq(r3.save, nil)
end)

t.test("verify requests a verify broadcast, no cfg mutation", function()
  local cfg = { enabled = true, pos = { x = 1, y = 2, z = 3 } }
  local before = { enabled = cfg.enabled, pos = cfg.pos }
  local r = Command.apply(cfg, "verify")
  t.eq(r.verify, true)
  t.eq(cfg.enabled, before.enabled); t.eq(cfg.pos, before.pos)
  t.eq(r.save, nil)
end)

t.test("reboot requests a reboot, no cfg mutation", function()
  local cfg = { enabled = true }
  local r = Command.apply(cfg, "reboot")
  t.eq(r.reboot, true)
  t.eq(r.save, nil)
end)

t.test("an unknown op is a defensive no-op", function()
  local cfg = { enabled = true, intervalMs = 3000, pos = { x = 1, y = 2, z = 3 } }
  local r = Command.apply(cfg, "nuke", { intervalMs = 1, pos = { x = 9, y = 9, z = 9 } })
  t.eq(cfg.enabled, true); t.eq(cfg.intervalMs, 3000); t.eq(cfg.pos.x, 1)
  t.eq(r.save, nil); t.eq(r.verify, nil); t.eq(r.reboot, nil); t.eq(r.rearm, nil)
end)
