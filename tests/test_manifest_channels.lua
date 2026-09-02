-- Both committed manifests describe the SAME roles/dst structure over the SAME closure, differ
-- ONLY in each file entry's src (dist/ vs source) + sums, and carry DIFFERENT version digests.
-- The basalt entry (release/basalt-full.lua, never minified) is byte-identical across channels.
local t = require("tests.framework")

local function load(path)
  local f = fs.open(path, "r"); if not f then error("missing " .. path) end
  local body = f.readAll(); f.close()
  return textutils.unserialise(body)
end

t.test("manifest.lua (min) and manifest-dev.lua (dev) are parallel; basalt identical; versions differ", function()
  local min = load("/manifest.lua")
  local dev = load("/manifest-dev.lua")
  t.eq(type(min), "table"); t.eq(type(dev), "table")
  t.eq(min.version ~= dev.version, true, "each channel has its own version digest")
  t.eq(min.basalt.sum, dev.basalt.sum, "basalt bytes identical across channels")
  t.eq(min.updater.sum, dev.updater.sum, "suite (updater) identical across channels")
  for role, mrole in pairs(min.roles) do
    local drole = dev.roles[role]
    t.eq(type(drole), "table", "dev manifest also has role " .. role)
    t.eq(#mrole.files, #drole.files, "same file count for " .. role)
    for i, mf in ipairs(mrole.files) do
      local df = drole.files[i]
      t.eq(mf.dst, df.dst, "same dst[" .. i .. "] in " .. role)
      if mf.dst == "basalt-full.lua" then
        t.eq(mf.src, df.src, "basalt src identical")
        t.eq(mf.src, "release/basalt-full.lua", "basalt src stays source in both channels")
      else
        t.eq(mf.src:sub(1, 5), "dist/", "min channel " .. role .. " file points into dist/: " .. mf.src)
        t.eq(df.src:sub(1, 5) ~= "dist/", true, "dev channel points at source: " .. df.src)
      end
    end
  end
end)

-- fcs and ui roles must back up all 4 of their config files (not just eh2_hw_config.tbl), so
-- the Suite's backup step actually preserves everything a fresh install would otherwise clobber.
local function toSet(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

t.test("fcs and ui roles back up all their config files", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = load(path)

    local fcs = toSet(m.roles.fcs.configs)
    t.eq(#m.roles.fcs.configs, 4, path .. ": fcs has 4 configs")
    t.truthy(fcs["/eh2_devbind.tbl"] and fcs["/eh2_senscal.tbl"] and fcs["/eh2_tuning.tbl"] and fcs["/eh2_hw_config.tbl"],
      path .. ": fcs configs are the expected set")

    local ui = toSet(m.roles.ui.configs)
    t.eq(#m.roles.ui.configs, 4, path .. ": ui has 4 configs")
    t.truthy(ui["/eh2_devbind.tbl"] and ui["/eh2_senscal.tbl"] and ui["/eh2_tuning.tbl"] and ui["/eh2_ui_config.tbl"],
      path .. ": ui configs are the expected set")
  end
end)

-- ===== S1 (config overhaul): the FCS flight/diagnostic stack ships ONLY to the fcs role =====
-- The shared diagnostic launchers (calibrate/hovertest/probe*) require() the whole flight control
-- loop; before S1 the `ui` role opted into them (sharedDiag) and so carried a full second copy of
-- the control stack. S1 drops sharedDiag from `ui`, so those commands + the control-loop modules
-- they alone dragged in must be ABSENT from every non-fcs role, while the UI's real dependencies
-- (comauto for its FCS TUNING menu, the comms link, the fcs.io config layer, tools.fnv1a) STAY.
-- The UI's FCS config FILES (devbind/senscal/tuning) are deliberately UNCHANGED here -- their
-- removal is S2 (see docs/superpowers/plans/2026-09-02-config-overhaul-s1-shipping.md), which is
-- why the "back up all their config files" test above is left exactly as it is.

local function dstSet(role)
  local s = {}
  for _, f in ipairs(role.files) do s[f.dst] = true end
  return s
end

-- The diagnostic COMMANDS (bare-name launcher dst) + the control-loop modules they alone pull in.
-- None of these has a ui/nav/beacon require() path: no ui file requires fcs.control/runtime/
-- schemes/safety/modes, and ui.basalt.bitconfig.tuning requires fcs.comauto -> fcs.mixer.
-- level_flight (thrust math), NOT fcs.schemes.level_flight (the control scheme listed here).
-- NOTE: the calibrate/probe COMMANDS leave, but the MODULE tools/calibrate.lua STAYS on the ui role
-- and is asserted in UI_KEEPS below -- SENS CAL (ui/basalt/bitconfig/senscal.lua:75) require()s
-- tools.calibrate to reuse its pure helpers for byte-identical parity with the terminal tool, so it
-- is a genuine UI dependency, not diagnostic-only. Only the diag tool BODIES with no ui requirer
-- (hover_test, probe) belong in this leave-list.
local FCS_ONLY_STACK = {
  "calibrate", "hovertest", "probe", "probemodem", "probebatch",   -- diagnostic commands (launchers)
  "tools/hover_test.lua", "tools/probe.lua",                        -- diag tool bodies, no ui requirer
  "fcs/runtime/loop.lua", "fcs/modes/registry.lua",
  "fcs/schemes/level_flight.lua", "fcs/control/pid.lua",
  "fcs/safety/oscillation.lua", "fcs/actuate/level.lua", "fcs/tuning.lua",
}

-- The UI's LEGITIMATE fcs/tools dependencies -- these MUST survive S1 (the config menus need them).
-- tools/calibrate.lua (SENS CAL parity) and tools/binddevices.lua (the MDB device-bind menu,
-- ui/basalt/bitconfig/mdb.lua:22) are shared helper modules the cockpit require()s directly -- the
-- calibrate COMMAND leaves, but this module stays.
local UI_KEEPS = {
  "cockpit", "ui/basalt/app.lua", "tools/fnv1a.lua",
  "tools/calibrate.lua", "tools/binddevices.lua",
  "fcs/comauto.lua", "fcs/mixer/level_flight.lua", "fcs/comms/telemetry.lua",
  "fcs/io/cfgspec.lua", "fcs/io/tuningdefaults.lua", "fcs/io/calibration.lua",
  "ui/basalt/bitconfig/tuning.lua", "ui/basalt/bitconfig/senscal.lua",
}

t.test("S1: the fcs flight/diagnostic stack ships only to the fcs role", function()
  for _, path in ipairs({ "/manifest.lua", "/manifest-dev.lua" }) do
    local m = load(path)
    -- fcs KEEPS the whole stack (S1 does not touch the fcs role).
    local fcs = dstSet(m.roles.fcs)
    for _, dst in ipairs(FCS_ONLY_STACK) do
      t.truthy(fcs[dst], path .. ": fcs still ships " .. dst)
    end
    -- Every non-fcs role is free of it.
    for _, role in ipairs({ "ui", "nav", "beacon", "beaconcontrol" }) do
      local set = dstSet(m.roles[role])
      for _, dst in ipairs(FCS_ONLY_STACK) do
        t.truthy(not set[dst], path .. ": " .. role .. " does not ship " .. dst)
      end
    end
    -- The UI keeps its real config-menu dependencies.
    local ui = dstSet(m.roles.ui)
    for _, dst in ipairs(UI_KEEPS) do
      t.truthy(ui[dst], path .. ": ui still ships " .. dst)
    end
  end
end)
