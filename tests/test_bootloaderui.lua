-- tests/test_bootloaderui.lua
-- Headless smoke for fcs/boot/loaderui.lua: the testable seam (commit/finish) only.
-- The interactive run()/buildSources() loop is in-game only and NOT exercised here.
local t = require("tests.framework")

t.test("loaderui module loads clean (no peripheral/modem/disk access at load time)", function()
  local ok = pcall(require, "fcs.boot.loaderui")
  t.eq(ok, true)
end)

local M = require("fcs.boot.loaderui")
local hwconfig = require("fcs.io.hwconfig")
local cfgspec = require("fcs.io.cfgspec")
local tuningdefaults = require("fcs.io.tuningdefaults")

t.test("finish resolves own+own+defaults and commits both handoff files, no real fs / read()", function()
  local legacy = hwconfig.defaults()
  local split = cfgspec.splitLegacy(legacy)
  local stub = { get = function(concern, src)
    if concern == "binding" and src == "own" then return split.devbind end
    if concern == "sensor" and src == "own" then return split.senscal end
    if concern == "tuning" and src == "defaults" then return tuningdefaults.get() end
    return nil
  end }
  local written = {}
  local function captureWrite(path, body) written[path] = body end

  local ok, assembled = M.finish({ binding = "own", sensor = "own", tuning = "defaults" }, stub, captureWrite)
  t.eq(ok, true)
  t.truthy(assembled and assembled.hw and assembled.tuning, "finish returns the assembled result")

  local hw = textutils.unserialise(written["/eh2_hw_config.tbl"])
  t.truthy(hw and hw.thrusters and hw.bindings, "captured hw_config has thrusters + bindings")

  local tuning = textutils.unserialise(written["/eh2_tuning.tbl"])
  t.truthy(tuning and tuning.gains, "captured tuning has gains")
end)

t.test("finish surfaces loader.resolve failures without writing anything", function()
  local stub = { get = function() return nil end }
  local written = {}
  local ok, assembled, err = M.finish({ binding = "disk", sensor = "own", tuning = "disk" }, stub,
    function(path, body) written[path] = body end)
  t.eq(ok, false)
  t.truthy(err)
  t.eq(next(written), nil, "no file written on a failed resolve")
end)

t.test("needsConfirm is true only for the disk source", function()
  t.eq(M.needsConfirm("disk"), true)
  t.eq(M.needsConfirm("ui"), false)
  t.eq(M.needsConfirm("own"), false)
  t.eq(M.needsConfirm("defaults"), false)
end)

t.test("retired UI-pull surface is gone (CFG_CH, closeCfgChannels)", function()
  t.eq(M.CFG_CH, nil)
  t.eq(M.closeCfgChannels, nil)
end)
