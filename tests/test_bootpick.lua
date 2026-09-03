-- tests/test_bootpick.lua
-- Headless tests for fcs/boot/pick.lua: resolve/apply/parseChoice with injected sources.
-- Launchers (ui.lua / nav.lua) are in-game wiring and are not exercised here.
local t = require("tests.framework")

t.test("pick module loads clean (no peripheral/modem/disk access at load time)", function()
  local ok = pcall(require, "fcs.boot.pick")
  t.eq(ok, true)
end)

t.test("resolve current returns sources.get current", function()
  local P = require("fcs.boot.pick")
  local current = { assign = { m = "current" } }
  local stub = { get = function(src)
    if src == "current" then return current end
    return nil
  end }
  local cfg, err = P.resolve("current", stub)
  t.eq(err, nil)
  t.eq(cfg, current)
end)

t.test("resolve default returns sources.get default", function()
  local P = require("fcs.boot.pick")
  local default = { assign = { m = "default" } }
  local stub = { get = function(src)
    if src == "default" then return default end
    return { assign = { m = "other" } }
  end }
  local cfg, err = P.resolve("default", stub)
  t.eq(err, nil)
  t.eq(cfg, default)
end)

t.test("resolve default errors when sources.get default is nil", function()
  local P = require("fcs.boot.pick")
  local stub = { get = function() return nil end }
  local cfg, err = P.resolve("default", stub)
  t.eq(cfg, nil)
  t.truthy(err)
end)

t.test("resolve disk returns sources.get disk", function()
  local P = require("fcs.boot.pick")
  local disk = { assign = { m = "disk" } }
  local stub = { get = function(src)
    if src == "disk" then return disk end
    return nil
  end }
  local cfg, err = P.resolve("disk", stub)
  t.eq(err, nil)
  t.eq(cfg, disk)
end)

t.test("resolve disk errors when sources.get disk is nil", function()
  local P = require("fcs.boot.pick")
  local stub = { get = function() return nil end }
  local cfg, err = P.resolve("disk", stub)
  t.eq(cfg, nil)
  t.truthy(err)
end)

t.test("resolve invalid choice errors", function()
  local P = require("fcs.boot.pick")
  local stub = { get = function() return { ok = true } end }
  local cfg, err = P.resolve("own", stub)
  t.eq(cfg, nil)
  t.truthy(err)
  local cfg2, err2 = P.resolve("defaults", stub)
  t.eq(cfg2, nil)
  t.truthy(err2)
  local cfg3, err3 = P.resolve(nil, stub)
  t.eq(cfg3, nil)
  t.truthy(err3)
end)

-- Break this test would catch: empty/invalid 1/2/3 input aborting unattended boot
-- instead of falling through to current.
t.test("parseChoice maps 1/2/3 and defaults empty/invalid to current", function()
  local P = require("fcs.boot.pick")
  t.eq(P.parseChoice("1"), "current")
  t.eq(P.parseChoice("2"), "default")
  t.eq(P.parseChoice("3"), "disk")
  t.eq(P.parseChoice(""), "current")
  t.eq(P.parseChoice(nil), "current")
  t.eq(P.parseChoice("x"), "current")
  t.eq(P.parseChoice("4"), "current")
end)

-- Break this test would catch: DEFAULT apply writing current instead of the session overlay.
t.test("apply default writes session overlay and leaves current untouched", function()
  local P = require("fcs.boot.pick")
  local files = { ["/eh2_ui_config.tbl"] = "SEEDED-CURRENT" }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end
  local cfg = { assign = { m = "default" } }

  local ok = P.apply("default", cfg, captureWrite, captureDelete, {
    current = "/eh2_ui_config.tbl",
    session = "/eh2_ui_config.session.tbl",
  })
  t.eq(ok, true)
  t.eq(files["/eh2_ui_config.tbl"], "SEEDED-CURRENT", "DEFAULT must not clobber current")
  local session = textutils.unserialise(files["/eh2_ui_config.session.tbl"])
  t.eq(session and session.assign and session.assign.m, "default")
end)

t.test("apply disk writes current and deletes the session overlay", function()
  local P = require("fcs.boot.pick")
  local files = { ["/eh2_ui_config.session.tbl"] = "OLD-SESSION", ["/eh2_ui_config.tbl"] = "OLD-CURRENT" }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end
  local cfg = { assign = { m = "disk" } }

  local ok = P.apply("disk", cfg, captureWrite, captureDelete, {
    current = "/eh2_ui_config.tbl",
    session = "/eh2_ui_config.session.tbl",
  })
  t.eq(ok, true)
  t.eq(files["/eh2_ui_config.session.tbl"], nil, "disk import deletes session overlay")
  local current = textutils.unserialise(files["/eh2_ui_config.tbl"])
  t.eq(current and current.assign and current.assign.m, "disk")
end)

t.test("apply current deletes session overlay and does not rewrite current", function()
  local P = require("fcs.boot.pick")
  local files = { ["/eh2_ui_config.session.tbl"] = "OLD-SESSION", ["/eh2_ui_config.tbl"] = "SEEDED-CURRENT" }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end

  local ok = P.apply("current", { assign = { m = "ignored" } }, captureWrite, captureDelete, {
    current = "/eh2_ui_config.tbl",
    session = "/eh2_ui_config.session.tbl",
  })
  t.eq(ok, true)
  t.eq(files["/eh2_ui_config.session.tbl"], nil, "current boot drops leftover session overlay")
  t.eq(files["/eh2_ui_config.tbl"], "SEEDED-CURRENT", "current file already is the source")
end)
