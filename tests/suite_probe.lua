--[[ In-computer probe for tests/run_suite_e2e.sh.

     Runs one phase against the real Suite, fetching from the localhost mirror, and asserts on
     FILESYSTEM OUTCOMES rather than on printed output -- what matters is what ended up on
     disk, and that survives any wording change.

     The phase name is read from /pc_phase.txt; results are written to /pc_result.txt.
]]

local phase = (function()
  local f = fs.open("/pc_phase.txt", "r")
  if not f then return "?" end
  local s = f.readAll()
  f.close()
  return (s or ""):gsub("%s+$", "")
end)()

-- Force the plain text/keyboard install flow (Suite.performPlan) rather than the mouse-driven
-- advanced dashboard (Suite.runUI). CraftOS-PC's headless computer 0 reports an advanced
-- (colour) terminal, but a headless probe has no mouse to click the dashboard's buttons -- and
-- both paths call the exact same engine underneath, so pinning this down changes only which UI
-- shell wraps the run, never what is actually being verified.
if term.isColour then
  term.isColour = function() return false end
end

local lines = {}
local failed = 0

local function ok(msg) lines[#lines + 1] = "  ok   " .. msg end
local function fail(msg)
  lines[#lines + 1] = "  FAIL " .. msg
  failed = failed + 1
end
local function check(condition, msg, detail)
  if condition then ok(msg) else fail(msg .. (detail and ("  -- " .. detail) or "")) end
end

local function read(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s
end

local function write(path, content)
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

local function runSuite(...)
  local args = { ... }
  local before = os.epoch("utc")
  shell.run("/easyhover2_suite.lua", table.unpack(args))
  return os.epoch("utc") - before
end

--- Loads the Suite as a plain module (Suite.main does NOT run), so the pure, documented
--- decision functions (Suite.choosePlan, Suite.isProtected, ...) can be exercised directly,
--- exactly as the module's own comments say they are meant to be testable.
local function loadSuiteModule()
  _G.EH2_SUITE_NO_RUN = true
  local Suite = dofile("/easyhover2_suite.lua")
  _G.EH2_SUITE_NO_RUN = nil
  return Suite
end

--- Every file under the backup root, flattened.
local function backupFiles()
  local out = {}
  local function walk(dir)
    if not fs.exists(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then walk(path) else out[#out + 1] = "/" .. path end
    end
  end
  walk("/easyhover2_backup")
  return out
end

local function anyBackupMatching(pattern)
  for _, path in ipairs(backupFiles()) do
    if path:find(pattern) then return path end
  end
  return nil
end

--- Search backup CONTENTS, not names. Earlier phases leave their own backups behind, so
--- matching on the filename alone can find the wrong generation of the same config.
local function anyBackupContaining(pattern)
  for _, path in ipairs(backupFiles()) do
    local body = read(path)
    if body and body:find(pattern, 1, true) then return path end
  end
  return nil
end

local function stateField(field)
  local raw = read("/easyhover2_install.txt") or ""
  return raw:match(field .. "=([^\n]+)")
end

local function manifestVersion()
  local body = read("/mirror_manifest.lua")
  if not body then return nil end
  local m = textutils.unserialise(body)
  return m and m.version or nil
end

--- The manifest's own record for one shipped file, e.g. manifestEntry("fcs", "tools/flight.lua").
--- Channel-independent: works the same whether the mirror shipped source or minified bytes,
--- because the manifest's sum/size are generated FROM whatever was actually shipped.
local function manifestEntry(role, dst)
  local body = read("/mirror_manifest.lua")
  if not body then return nil end
  local m = textutils.unserialise(body)
  local spec = m and m.roles and m.roles[role]
  if not spec or not spec.files then return nil end
  for _, entry in ipairs(spec.files) do
    if entry.dst == dst then return entry end
  end
  return nil
end

local function noStagingLeftBehind()
  local leftovers = {}
  local function walk(dir)
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if fs.isDir(path) then
        if path ~= "rom" then walk(path) end
      elseif path:find("%.eh2new$") then
        leftovers[#leftovers + 1] = path
      end
    end
  end
  walk("/")
  return leftovers
end

-- A hand-written hardware config that is deliberately MISSING most fields, with distinctive
-- values in the two it does set (one nested scalar, one top-level scalar).
local HAND_CONFIG = textutils.serialise({
  bindings = { heightOffset = 13, yawBaseline = 7 },
  fuelRelay = true,
})

-- ---------------------------------------------------------------- phases

if phase == "install" then
  runSuite("fcs")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/fcs/frame.lua"), "role files installed")
  check(fs.exists("/fcs/actuate/level.lua"), "nested role files installed")
  check(fs.exists("/tools/flight.lua"), "the fcs entry point tool was installed")
  check(stateField("role") == "fcs", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release",
    tostring(stateField("version")) .. " vs " .. tostring(manifestVersion()))
  local launcher = read("/startup.lua") or ""
  -- Task 9 changed launchers/fcs.lua to boot the interactive boot-loader UI (which assembles
  -- /eh2_hw_config.tbl + /eh2_tuning.tbl from the pilot's chosen sources) and only then shell.run
  -- the flight app, rather than requiring tools.flight directly.
  check(launcher:find('require%("fcs%.boot%.loaderui"%)') ~= nil,
    "launcher boots the fcs boot loader UI", launcher)
  -- cut-on-boot added pcall(cut.all) to this shim (~210 B minified). Still tiny vs tools/flight.lua.
  check(#launcher < 400, "launcher is a thin shim, not a copy of the entry point",
    ("%d bytes"):format(#launcher))
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

elseif phase == "current" then
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "still at the same version")
  check(#backupFiles() == 0, "an up-to-date run backs nothing up",
    table.concat(backupFiles(), ", "))
  check(#noStagingLeftBehind() == 0, "no staging files")

elseif phase == "configkeep" then
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  -- force the update path even though the version matches
  runSuite("--repair")

  local body = read("/eh2_hw_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "config still parses")
  if type(cfg) == "table" then
    check(cfg.bindings and cfg.bindings.heightOffset == 13,
      "MY value survived (bindings.heightOffset = 13)",
      tostring(cfg.bindings and cfg.bindings.heightOffset))
    check(cfg.bindings and cfg.bindings.yawBaseline == 7,
      "MY second value survived (bindings.yawBaseline = 7)")
    check(cfg.bindings and cfg.bindings.onGroundThreshold ~= nil,
      "a field my file never had was ADDED (bindings.onGroundThreshold)")
    check(cfg.thrusters ~= nil and cfg.sensors ~= nil,
      "whole sections were added (thrusters, sensors)")
    check(cfg.fuelRelay == true, "my top-level value survived (fuelRelay = true)")
  end
  check(anyBackupMatching("eh2_hw_config") ~= nil, "the config was backed up first")

elseif phase == "update" then
  -- Pure check first: Suite.choosePlan is documented as pure and testable without a network
  -- or a filesystem, so exercise its actual decision boundary directly -- a version mismatch
  -- with intact files is "update", not "repair" (that distinction is the whole point of the
  -- version stamp: files differing from a manifest they were never built against is what an
  -- update IS, not corruption).
  local Suite = loadSuiteModule()
  check(Suite.choosePlan({ anyInstall = true, mismatched = false, sameVersion = false,
    noRecord = false, forceRepair = false }) == "update",
    "a version mismatch with intact files chooses 'update'")
  check(Suite.choosePlan({ anyInstall = true, mismatched = true, sameVersion = true,
    noRecord = false, forceRepair = false }) == "repair",
    "a version match with corrupt files chooses 'repair'")
  check(Suite.choosePlan({ anyInstall = false, mismatched = false, sameVersion = false,
    noRecord = true, forceRepair = false }) == "install",
    "no install on disk chooses 'install'")

  -- End-to-end: doctor the install record to claim an old version while every file on disk
  -- is actually still correct and current. This is exactly the state a real update finds a
  -- computer in, without needing a second manifest to fetch from.
  local raw = read("/easyhover2_install.txt") or ""
  local doctored = raw:gsub("version=[%w]+", "version=deadbeef00")
  check(doctored ~= raw, "test setup: could doctor the version field")
  write("/easyhover2_install.txt", doctored)
  check(stateField("version") == "deadbeef00", "test setup: version now looks stale")

  runSuite()

  check(stateField("version") == manifestVersion(),
    "the update re-synced the state record to the real release",
    tostring(stateField("version")) .. " vs " .. tostring(manifestVersion()))
  local flightBody = read("/tools/flight.lua") or ""
  -- Channel-independent "is this the real content" check: luamin strips comments (so the
  -- default/minified channel never contains the source string "FCS runtime"), but the manifest's
  -- checksum+size are generated from whatever was actually shipped in this channel, exactly the
  -- same comparison Suite.integrity() itself makes -- so this holds against source and minified
  -- installs alike.
  local flightEntry = manifestEntry("fcs", "tools/flight.lua")
  check(flightEntry ~= nil, "test setup: manifest has an entry for tools/flight.lua")
  check(flightEntry ~= nil and #flightBody == flightEntry.size
    and Suite.checksum(flightBody) == flightEntry.sum,
    "role files are still the real content, verified against the manifest checksum",
    flightEntry and ("%d/%s vs manifest %d/%s"):format(
      #flightBody, tostring(Suite.checksum(flightBody)), flightEntry.size, tostring(flightEntry.sum)))
  check(fs.exists("/eh2_hw_config.tbl"), "config untouched by a plain update")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value from before")
  check(#noStagingLeftBehind() == 0, "no staging files left behind")

elseif phase == "repair" then
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  -- corrupt a role file the way a half-finished download or a chunk unload would
  write("/tools/flight.lua", "-- CORRUPTED\n")
  local extra = "/fcs/leftover_from_old_release.lua"
  write(extra, "-- stale file from an older release\n")

  runSuite()

  local restored = read("/tools/flight.lua") or ""
  check(#restored > 1000, "the corrupt file was replaced with the real one",
    ("%d bytes"):format(#restored))
  -- Same channel-independent check as the update phase above: verify against the manifest's
  -- checksum+size rather than a source comment luamin strips in the default/minified channel.
  local Suite = loadSuiteModule()
  local flightEntry = manifestEntry("fcs", "tools/flight.lua")
  check(flightEntry ~= nil, "test setup: manifest has an entry for tools/flight.lua")
  check(flightEntry ~= nil and #restored == flightEntry.size
    and Suite.checksum(restored) == flightEntry.sum,
    "and it is the real content, verified against the manifest checksum",
    flightEntry and ("%d/%s vs manifest %d/%s"):format(
      #restored, tostring(Suite.checksum(restored)), flightEntry.size, tostring(flightEntry.sum)))
  check(not fs.exists(extra), "a stale file inside the role directory was cleared")
  check(fs.exists("/eh2_hw_config.tbl"), "MY CONFIG SURVIVED THE REPAIR")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value")
  check(anyBackupMatching("eh2_hw_config") ~= nil, "config backed up before the repair")
  check(stateField("version") == manifestVersion(), "back at the release version")

elseif phase == "badconfig" then
  write("/eh2_hw_config.tbl", "this is not a lua table at all {{{")
  runSuite("--repair")

  local body = read("/eh2_hw_config.tbl") or ""
  local cfg = textutils.unserialise(body)
  check(type(cfg) == "table", "the unparseable config was replaced with a valid one")
  if type(cfg) == "table" then
    check(cfg.thrusters ~= nil and cfg.bindings ~= nil, "and it holds real defaults")
  end
  local kept = anyBackupContaining("not a lua table")
  check(kept ~= nil, "the broken original was backed up, not just discarded",
    "no backup contains the broken bytes")
  if kept then check(kept:find("eh2_hw_config"), "backed up under its own name", kept) end

elseif phase == "detect" then
  -- The install record is what the Suite normally trusts; without it, it must work out the
  -- role from the files on disk rather than asking (asking would hang a headless run).
  fs.delete("/easyhover2_install.txt")
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  runSuite("--verify")
  check(stateField("role") == "fcs", "role re-detected from the files on disk",
    tostring(stateField("role")))
  check(fs.exists("/eh2_hw_config.tbl"), "config untouched by the recovery")

elseif phase == "protect" then
  -- Unit-test the exposed, documented-pure isProtected predicate directly: this is the last
  -- line of defence guard() asserts before every release write and delete.
  local Suite = loadSuiteModule()
  check(Suite.isProtected("/eh2_hw_config.tbl") == true, "a hardware config is protected")
  check(Suite.isProtected("/eh2_something.log") == true, "an eh2 log file is protected")
  check(Suite.isProtected("/easyhover2_backup/whatever") == true, "the backup root is protected")
  check(Suite.isProtected("/easyhover2_install.txt") == true, "the install record is protected")
  check(Suite.isProtected("/easyhover2_suite_src.txt") == true, "the source pointer is protected")
  check(Suite.isProtected("/easyhover2_suite_token.txt") == true, "the token file is protected")
  check(Suite.isProtected("/fcs/frame.lua") == false, "a role file is NOT protected")
  check(Suite.isProtected("/startup.lua") == false, "the launcher is NOT protected")

  -- And on the filesystem: anything the operator owns must survive the most destructive path
  -- the Suite has.
  write("/eh2_hw_config.tbl", HAND_CONFIG)
  write("/my_notes.txt", "operator's own file, not part of any release")

  runSuite("--repair")

  check(fs.exists("/eh2_hw_config.tbl"), "config survived --repair")
  local cfg = textutils.unserialise(read("/eh2_hw_config.tbl") or "")
  check(type(cfg) == "table" and cfg.bindings and cfg.bindings.heightOffset == 13,
    "and it still holds my value")
  check(read("/my_notes.txt") == "operator's own file, not part of any release",
    "an unrelated file of mine was not touched by --repair")

elseif phase == "check" then
  -- --check must be a true dry run.
  write("/tools/flight.lua", "-- CORRUPTED AGAIN\n")
  local before = read("/tools/flight.lua")
  runSuite("--check")
  check(read("/tools/flight.lua") == before, "--check wrote nothing, even to a corrupt file")
  check(#noStagingLeftBehind() == 0, "--check staged nothing")

  -- The channel marker must not be persisted by a dry run either -- not even when a flag
  -- would actually change it. `install` (earlier in this chain) already wrote /eh2_channel.txt
  -- as "min" with a real run, so pairing --check with --dev here is the case that actually
  -- exercises the write: a bug that skips the checkOnly gate would flip the marker to "dev".
  local channelBefore = read("/eh2_channel.txt")
  runSuite("--check", "--dev")
  check(read("/eh2_channel.txt") == channelBefore,
    "--check --dev did not persist a channel switch",
    tostring(read("/eh2_channel.txt")) .. " vs " .. tostring(channelBefore))

  -- --list is the sibling read-only/informational flag: it must not persist a channel switch
  -- either, for the same reason.
  local channelBefore2 = read("/eh2_channel.txt")
  runSuite("--list", "--dev")
  check(read("/eh2_channel.txt") == channelBefore2,
    "--list --dev did not persist a channel switch",
    tostring(read("/eh2_channel.txt")) .. " vs " .. tostring(channelBefore2))

elseif phase == "ui" then
  -- A FRESH install of the OTHER released role, on a bare computer. Nothing else here covers
  -- ui, and it is structurally different from fcs: a whole separate ui/ source tree, and it
  -- boots the Basalt cockpit (ui.basalt.app) instead of tools.flight.
  runSuite("ui")
  check(stateField("role") == "ui", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/ui/basalt/app.lua"), "role files installed")
  check(fs.exists("/ui/panels/engine.lua"), "nested ui files installed")
  check(fs.exists("/cockpit"), "the cockpit launcher tool was installed")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("ui%.basalt%.app"%)') ~= nil,
    "the launcher starts the ui role", launcher)
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

  -- No fcs-only files on a ui computer: this is a cockpit screen, not a spare flight computer.
  check(not fs.exists("/tools/flight.lua"), "no fcs entry point on a ui computer")
  check(not fs.exists("/fcs/input/pilot.lua"), "no fcs-only input files on a ui computer")
  check(not fs.exists("/fcs/runtime/flight.lua"), "no fcs-only runtime files on a ui computer")

  -- And re-running is a no-op, the same as it is for fcs.
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run changes nothing",
    tostring(stateField("version")))

elseif phase == "switch" then
  -- A role SWITCH is a different operation from a fresh install: it lands on a computer that
  -- already has the OTHER role's files on disk. Self-contained on a bare computer: install fcs
  -- first, then switch it to ui, so this phase does not depend on where it sits in the chain.
  runSuite("fcs")
  check(stateField("role") == "fcs", "test setup: fcs installed first",
    tostring(stateField("role")))
  check(fs.exists("/tools/flight.lua"), "test setup: fcs entry point present")
  -- fcs ships a root-level /flight launcher; ui does not. Assert it is here BEFORE the switch so
  -- the "gone after" check below passes for the right reason (it was removed, not never present).
  check(fs.exists("/flight"), "test setup: fcs root launcher /flight present before switch")

  runSuite("ui")

  check(stateField("role") == "ui", "the install record now names the new role",
    tostring(stateField("role")))
  check(fs.exists("/ui/basalt/app.lua"), "the new role's files landed")
  check(fs.exists("/cockpit"), "the new role's launcher tool landed")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("ui%.basalt%.app"%)') ~= nil,
    "the launcher now starts the new role, not the old one", launcher)

  -- pruneRole runs after every commit: a file that lived inside one of the NEW role's directories
  -- (fcs, tools, ui) under the old role but is not part of the new role's manifest is dropped once
  -- the switch completes. Root-level launchers are swept the same way (see the /flight check below).
  check(not fs.exists("/tools/flight.lua"), "the old role's entry point was pruned")
  check(not fs.exists("/fcs/input/pilot.lua"), "the old role's fcs-only files were pruned")
  check(not fs.exists("/fcs/runtime/flight.lua"), "the old role's runtime files were pruned")
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

  -- Root-level launchers are pruned on a switch too, not just in-dir modules: the OLD role's
  -- orphan /flight (whose /tools/flight.lua dependency is now gone) must be removed, or running
  -- it throws "module not found". A launcher the NEW role ships (/cockpit) and a launcher both
  -- roles ship (/probe) must survive -- pruning only ever touches suite launchers this role drops.
  check(not fs.exists("/flight"), "the old role's orphan ROOT launcher /flight was pruned")
  check(fs.exists("/cockpit"), "a root launcher the new role ships (/cockpit) survived the switch")
  check(fs.exists("/probe"), "a root launcher both roles ship (/probe) survived the switch")

  -- Idempotent afterwards, same as any other role.
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run after switching changes nothing")

elseif phase == "nav" then
  -- A FRESH install of the NAV role on a bare computer: its own nav/ source tree, it ships Basalt
  -- (like ui) and boots nav.app -- but must NOT drag in the fcs flight stack or the ui cockpit.
  runSuite("nav")
  check(stateField("role") == "nav", "install record names the role", tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/nav/app.lua"), "nav role files installed")
  check(fs.exists("/nav/lib/trilaterate.lua"), "nested nav files installed")
  check(fs.exists("/nav/comms/receiver.lua"), "nav comms installed")
  check(fs.exists("/basalt-full.lua"), "the nav role ships Basalt")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("nav%.app"%)') ~= nil, "the launcher starts the nav role", launcher)
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")
  -- Closure hygiene: nav reuses fcs.comms.modem but must not ship the flight stack or the cockpit.
  check(fs.exists("/fcs/comms/modem.lua"), "nav ships the reused comms link")
  check(not fs.exists("/tools/flight.lua"), "no fcs flight entry point on a nav computer")
  check(not fs.exists("/fcs/runtime/flight.lua"), "no fcs runtime on a nav computer")
  check(not fs.exists("/ui/basalt/pages/emc.lua"), "no cockpit pages dragged onto a nav computer")
  check(not fs.exists("/calibrate"), "no fcs diagnostic launchers on a nav computer")
  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run changes nothing")

elseif phase == "beacon" then
  -- A FRESH install of the BEACON role on a bare computer: keyboard-UI role for a BASIC computer,
  -- so it ships NO Basalt. It reuses nav.comms + nav.lib.geometry but nothing else.
  runSuite("beacon")
  check(stateField("role") == "beacon", "install record names the role", tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release")
  check(fs.exists("/beacon/app.lua"), "beacon role files installed")
  check(fs.exists("/beacon/console.lua"), "beacon console installed")
  check(fs.exists("/nav/comms/gpsproto.lua"), "beacon reuses the nav broadcast frame")
  check(fs.exists("/nav/lib/geometry.lua"), "beacon reuses nav geometry grading")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("beacon%.app"%)') ~= nil, "the launcher starts the beacon role", launcher)
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")
  -- A basic computer must not carry Basalt, the cockpit, or the flight stack.
  check(not fs.exists("/basalt-full.lua"), "no Basalt on a basic-computer beacon")
  check(not fs.exists("/nav/app.lua"), "no NAV Basalt app on a beacon")
  check(not fs.exists("/tools/flight.lua"), "no fcs flight entry point on a beacon")

elseif phase == "beaconcontrol" then
  -- A FRESH install of the BEACON CONTROLLER role on a bare computer: advanced-computer Basalt UI
  -- (opposite of the beacon's "no Basalt" assertion), roster + remote control of the GPS mesh --
  -- but must NOT drag in the fcs flight stack, same hard isolation rule as nav/beacon.
  runSuite("beaconcontrol")
  check(stateField("role") == "beaconcontrol", "install record names the role",
    tostring(stateField("role")))
  check(stateField("version") == manifestVersion(), "install record matches the release")
  check(fs.exists("/startup.lua"), "launcher installed as /startup.lua")
  check(fs.exists("/controller/app.lua"), "controller app installed")
  check(fs.exists("/controller/runtime.lua"), "controller runtime installed")
  check(fs.exists("/controller/config.lua"), "controller config installed")
  check(fs.exists("/controller/diag.lua"), "controller diag installed")
  check(fs.exists("/beacon/update.lua"), "controller reuses the beacon update wire format")
  check(fs.exists("/nav/comms/gpsproto.lua"), "controller reuses the nav broadcast frame")
  local launcher = read("/startup.lua") or ""
  check(launcher:find('require%("controller%.app"%)') ~= nil,
    "the launcher starts the beaconcontrol role", launcher)
  check(#noStagingLeftBehind() == 0, "no .eh2new staging files left behind")

  -- An advanced-computer UI role: Basalt IS present (the opposite assertion from the beacon
  -- role's basic-computer check above).
  check(fs.exists("/basalt-full.lua"), "the beaconcontrol role ships Basalt")

  -- The key isolation guarantee: no fcs/ flight code or flight entry point on this computer.
  check(not fs.exists("/tools/flight.lua"), "no fcs flight entry point on a beaconcontrol computer")
  check(not fs.exists("/fcs/runtime/flight.lua"), "no fcs runtime on a beaconcontrol computer")
  check(not fs.exists("/fcs/loop.lua"), "no fcs flight loop on a beaconcontrol computer")
  check(not fs.exists("/fcs/control/pid.lua"), "no fcs control-loop code on a beaconcontrol computer")
  check(not fs.exists("/fcs/actuate/level.lua"), "no fcs actuator code on a beaconcontrol computer")
  check(not fs.exists("/ui/basalt/pages/emc.lua"), "no cockpit pages dragged onto a beaconcontrol computer")
  check(not fs.exists("/calibrate"), "no fcs diagnostic launchers on a beaconcontrol computer")
  check(not fs.exists("/nav/app.lua"), "no NAV Basalt app on a beaconcontrol computer")

  local versionBefore = stateField("version")
  runSuite()
  check(stateField("version") == versionBefore, "an up-to-date re-run changes nothing")

else
  fail("unknown phase: " .. tostring(phase))
end

-- ---------------------------------------------------------------- report

local header = ("=== %s === %s"):format(phase, failed == 0 and "PASS" or "FAIL")
table.insert(lines, 1, header)
write("/pc_result.txt", table.concat(lines, "\n") .. "\n")

-- SHUT THE COMPUTER DOWN. Without this the probe finishes, CraftOS-PC drops to its shell and
-- sits there until the runner's `timeout 180` kills it -- every phase paying the full 180s
-- even though its work took about a second. pc_result.txt is already written by then, so the
-- runner would still report the right verdict, but the run would take far longer than it needs
-- to for no reason.
os.shutdown()
