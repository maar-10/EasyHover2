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

t.test("finish resolves current+current+default and commits fused + session overlay, no real fs / read()", function()
  local legacy = hwconfig.defaults()
  local split = cfgspec.splitLegacy(legacy)
  local stub = { get = function(concern, src)
    if concern == "binding" and src == "current" then return split.devbind end
    if concern == "sensor" and src == "current" then return split.senscal end
    if concern == "tuning" and src == "default" then return tuningdefaults.get() end
    return nil
  end }
  local written = { ["/eh2_tuning.tbl"] = "SEEDED-CURRENT" }
  local function captureWrite(path, body) written[path] = body end

  local ok, assembled = M.finish({ binding = "current", sensor = "current", tuning = "default" }, stub, captureWrite)
  t.eq(ok, true)
  t.truthy(assembled and assembled.hw and assembled.tuning, "finish returns the assembled result")

  local hw = textutils.unserialise(written["/eh2_hw_config.tbl"])
  t.truthy(hw and hw.thrusters and hw.bindings, "captured hw_config has thrusters + bindings")

  t.eq(written["/eh2_tuning.tbl"], "SEEDED-CURRENT", "finish DEFAULT must not clobber current")
  local tuning = textutils.unserialise(written["/eh2_tuning.session.tbl"])
  t.truthy(tuning and tuning.gains, "captured session overlay has gains")
end)

t.test("finish surfaces loader.resolve failures without writing anything", function()
  local stub = { get = function() return nil end }
  local written = {}
  local ok, assembled, err = M.finish({ binding = "disk", sensor = "current", tuning = "disk" }, stub,
    function(path, body) written[path] = body end)
  t.eq(ok, false)
  t.truthy(err)
  t.eq(next(written), nil, "no file written on a failed resolve")
end)

t.test("needsConfirm is true only for the disk source", function()
  t.eq(M.needsConfirm("disk"), true)
  t.eq(M.needsConfirm("current"), false)
  t.eq(M.needsConfirm("default"), false)
  t.eq(M.needsConfirm("ui"), false)
end)

t.test("retired UI-pull surface is gone (CFG_CH, closeCfgChannels)", function()
  t.eq(M.CFG_CH, nil)
  t.eq(M.closeCfgChannels, nil)
end)

-- Break this test would catch: DEFAULT commit writing /eh2_tuning.tbl (clobbering current)
-- instead of the session overlay.
t.test("commit default writes session overlay and leaves current tuning untouched", function()
  local assembled = { hw = hwconfig.defaults(), tuning = tuningdefaults.get() }
  assembled.tuning.gains.hoverDuty = 0.11
  local files = { ["/eh2_tuning.tbl"] = "SEEDED-CURRENT" }
  local function captureWrite(path, body) files[path] = body end

  M.commit(assembled, captureWrite, { tuning = "default" })

  t.eq(files["/eh2_tuning.tbl"], "SEEDED-CURRENT", "DEFAULT must not clobber current")
  local session = textutils.unserialise(files["/eh2_tuning.session.tbl"])
  t.eq(session and session.gains and session.gains.hoverDuty, 0.11)
  local hw = textutils.unserialise(files["/eh2_hw_config.tbl"])
  t.truthy(hw and hw.thrusters and hw.bindings, "fused hw is always written")
end)

t.test("commit disk writes current tuning and deletes the session overlay", function()
  local assembled = { hw = hwconfig.defaults(), tuning = tuningdefaults.get() }
  assembled.tuning.gains.hoverDuty = 0.33
  local files = { ["/eh2_tuning.session.tbl"] = "OLD-SESSION", ["/eh2_tuning.tbl"] = "OLD-CURRENT" }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end

  M.commit(assembled, captureWrite, { tuning = "disk" }, captureDelete)

  t.eq(files["/eh2_tuning.session.tbl"], nil, "disk import deletes session overlay")
  local current = textutils.unserialise(files["/eh2_tuning.tbl"])
  t.eq(current and current.gains and current.gains.hoverDuty, 0.33)
end)

t.test("commit current deletes session overlay and does not rewrite current tuning", function()
  local assembled = { hw = hwconfig.defaults(), tuning = tuningdefaults.get() }
  local files = { ["/eh2_tuning.session.tbl"] = "OLD-SESSION", ["/eh2_tuning.tbl"] = "SEEDED-CURRENT" }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end

  M.commit(assembled, captureWrite, { tuning = "current" }, captureDelete)

  t.eq(files["/eh2_tuning.session.tbl"], nil, "current boot drops leftover session overlay")
  t.eq(files["/eh2_tuning.tbl"], "SEEDED-CURRENT", "current file already is the source")
end)

t.test("commit with two args still writes fused + current tuning (legacy callers)", function()
  local assembled = { hw = hwconfig.defaults(), tuning = tuningdefaults.get() }
  assembled.tuning.gains.hoverDuty = 0.44
  local files = {}
  local function captureWrite(path, body) files[path] = body end

  M.commit(assembled, captureWrite)

  local hw = textutils.unserialise(files["/eh2_hw_config.tbl"])
  t.truthy(hw and hw.thrusters)
  local tuning = textutils.unserialise(files["/eh2_tuning.tbl"])
  t.eq(tuning and tuning.gains and tuning.gains.hoverDuty, 0.44)
  t.eq(files["/eh2_tuning.session.tbl"], nil)
end)

t.test("tools/flight.lua prefers eh2_tuning.session.tbl over eh2_tuning.tbl", function()
  local f = fs.open("/tools/flight.lua", "r")
  t.truthy(f, "tools/flight.lua readable")
  local body = f.readAll(); f.close()
  local sessionAt = body:find('"/eh2_tuning.session.tbl"', 1, true)
  local currentAt = body:find('"/eh2_tuning.tbl"', 1, true)
  t.truthy(sessionAt, "flight loadConfig must look for the session overlay")
  t.truthy(currentAt, "flight loadConfig still falls back to current tuning")
  t.truthy(sessionAt < currentAt, "session overlay is preferred before current")
end)

-- Break this test would catch: DEFAULT binding writing fused hw only, so loadConfig's
-- tryAssemble of the existing splits ignores the pick and flies CURRENT.
t.test("commit binding default: loadConfig-equivalent is DEFAULT; current splits byte-identical", function()
  local currentDb = cfgspec.defaults("devbind"); currentDb.fuelRelay = "CURRENT_RELAY"
  local currentSc = cfgspec.defaults("senscal"); currentSc.signHeading = 1
  local defaultDb = cfgspec.defaults("devbind"); defaultDb.fuelRelay = "DEFAULT_RELAY"
  local dbBody = textutils.serialise(currentDb)
  local scBody = textutils.serialise(currentSc)
  local files = {
    ["/eh2_devbind.tbl"] = dbBody,
    ["/eh2_senscal.tbl"] = scBody,
  }
  local assembled = {
    hw = cfgspec.assembleHw(defaultDb, currentSc),
    tuning = tuningdefaults.get(),
  }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end

  M.commit(assembled, captureWrite, {
    binding = "default", sensor = "current", tuning = "current",
  }, captureDelete)

  t.eq(files["/eh2_devbind.tbl"], dbBody, "DEFAULT must not clobber current binding split")
  t.eq(files["/eh2_senscal.tbl"], scBody, "current sensor split untouched")
  local function readBare(name) return files["/" .. name] end
  local hw = cfgspec.tryAssemble(readBare)
  t.eq(hw and hw.fuelRelay, "DEFAULT_RELAY", "loadConfig-equivalent must fly DEFAULT binding")
  t.eq(hw and hw.bindings and hw.bindings.signHeading, 1, "sensor stays current")
end)

t.test("commit binding disk writes current split and deletes the session overlay", function()
  local diskDb = cfgspec.defaults("devbind"); diskDb.fuelRelay = "DISK_RELAY"
  local sc = cfgspec.defaults("senscal")
  local files = {
    ["/eh2_devbind.tbl"] = "OLD-CURRENT",
    ["/eh2_devbind.session.tbl"] = "OLD-SESSION",
    ["/eh2_senscal.tbl"] = textutils.serialise(sc),
  }
  local assembled = { hw = cfgspec.assembleHw(diskDb, sc), tuning = tuningdefaults.get() }
  local function captureWrite(path, body) files[path] = body end
  local function captureDelete(path) files[path] = nil end

  M.commit(assembled, captureWrite, {
    binding = "disk", sensor = "current", tuning = "current",
  }, captureDelete)

  t.eq(files["/eh2_devbind.session.tbl"], nil, "disk import deletes binding session overlay")
  local current = textutils.unserialise(files["/eh2_devbind.tbl"])
  t.eq(current and current.fuelRelay, "DISK_RELAY")
end)
