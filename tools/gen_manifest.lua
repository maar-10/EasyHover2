-- tools/gen_manifest.lua
-- Generates manifest.lua -- the release description easyhover2_suite.lua fetches over HTTPS.
--
--   tools/gen_manifest.lua           write manifest.lua
--   tools/gen_manifest.lua --check   assert manifest.lua is in sync, no write
--   tools/gen_manifest.lua --selftest  print reference fnv1a checksums
--
-- Run inside CraftOS-PC (needs fs/textutils/bit32); tests/run_headless.sh style harness only.
-- CraftOS-PC's --headless mode has no process exit code, so the outcome is ALSO written as one
-- line to /gen_result.txt: "WROTE <version>" / "IN SYNC" / "OUT OF SYNC" / "ERROR <msg>".
--
-- Unlike v1 (../EasyHover/tools/gen_manifest.js), role membership is NOT a directory walk: each
-- role's shipped files are the require() dependency closure (tools/closure.lua) of its launchers,
-- so a file ships only if something reachable from the role's boot chain actually requires it.
package.path = "/?.lua;/?/init.lua;" .. package.path

local fnv1a = require("tools.fnv1a")
local closure = require("tools.closure")

local SCHEMA = 1 -- bump ONLY when persisted config layout changes incompatibly
local REPO = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

-- Which source files are minified into dist/ (mirror of tools/build.mjs MINIFY_DIRS).
local MINIFY_PREFIXES = { "fcs/", "ui/", "launchers/", "tools/", "nav/", "beacon/", "controller/" }
local function isMinifiable(src)
  if not src:match("%.lua$") then return false end
  for _, p in ipairs(MINIFY_PREFIXES) do
    if src:sub(1, #p) == p then return true end
  end
  return false
end
-- For a channel ("min"|"dev") return (manifestSrc, readPath) for a source path. In the min
-- channel a minifiable file is described AND read from dist/; everything else (basalt, config
-- data) is identical to dev.
local function channelPaths(src, channel)
  if channel == "min" and isMinifiable(src) then
    return "dist/" .. src, "dist/" .. src
  end
  return src, src
end

-- Diagnostic launchers every released role ships identically, as their declared command name.
local SHARED_DIAG = {
  { src = "launchers/calibrate.lua",  dst = "calibrate"  },
  { src = "launchers/hovertest.lua",  dst = "hovertest"  },
  { src = "launchers/probe.lua",      dst = "probe"      },
  { src = "launchers/probemodem.lua", dst = "probemodem" },
  { src = "launchers/probebatch.lua", dst = "probebatch" },
}
local CONFIG_MODULE = "fcs.io.config"
local ROLES = {
  fcs = {
    title = "Flight computer", status = "released",
    blurb = "Thrusters, sensors, pilot input, control loops. Boots the flight app.",
    configs = { "/eh2_devbind.tbl", "/eh2_senscal.tbl", "/eh2_tuning.tbl", "/eh2_hw_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/fcs.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/flight.lua", dst = "flight" },
                { src = "launchers/fcslog.lua", dst = "fcslog" } }, -- + SHARED_DIAG + config module
    sharedDiag = true,
    -- S5: Suite --flag-defaults/--migrate-config require() this on the installed computer. The
    -- suite is wget-run, so closure discovery never sees it; extraFiles ships it anyway.
    extraFiles = { { src = "fcs/io/cfgdefault.lua", dst = "fcs/io/cfgdefault.lua" } },
  },
  ui = {
    title = "Cockpit display", status = "released",
    blurb = "Receives telemetry, renders reported state, sends commands on touch. Boots the cockpit.",
    -- S1 (config overhaul): NO sharedDiag. The diagnostic launchers (calibrate/hovertest/probe*)
    -- require() the whole flight control loop; shipping them here made the UI PC carry a second copy
    -- of the FCS control stack. The cockpit's own closure keeps the deps its config menus actually
    -- use (fcs.comauto, fcs.comms.*, fcs.io.*) -- those are separate require() paths.
    -- S2b: the UI reads/writes the FCS config live (no local copies), so it backs up only its own
    -- eh2_ui_config.tbl. The FCS role still owns the FCS config files. DTC FCS export from the UI
    -- PC is empty until S3 rewires the courier.
    configs = { "/eh2_ui_config.tbl" }, configModule = CONFIG_MODULE, luaPath = "/",
    startup = { src = "launchers/ui.lua", dst = "startup.lua" },
    roots   = { { src = "launchers/cockpit.lua", dst = "cockpit" } },
    -- Basalt is loadfile()'d at RUNTIME by ui/basalt/app.lua's M.ensureBasalt (never require()'d
    -- -- see that file's header comment), so tools/closure.lua's require()-following discovery
    -- can never find it. extraFiles ships it alongside the closure anyway, at exactly
    -- "/basalt-full.lua" -- M.BASALT_PATHS' first (installed-location) candidate.
    extraFiles = {
      { src = "release/basalt-full.lua", dst = "basalt-full.lua" },
      { src = "fcs/io/cfgdefault.lua", dst = "fcs/io/cfgdefault.lua" },
    },
  },
  -- NAV + beacon roles (Batch 1). NO sharedDiag: the FCS diagnostic launchers (calibrate/hovertest/
  -- probe*) pull the whole flight stack through their require() closure, which nav/beacon must never
  -- ship. Each declares its own configModule so launcherEntries ships the right config file.
  nav = {
    title = "Navigation computer", status = "released",
    blurb = "Broadcast-GPS position fix + heading; relays to the craft wire. Boots the NAV UI.",
    configs = { "/eh2_nav.tbl" }, configModule = "nav.config", luaPath = "/",
    startup = { src = "launchers/nav.lua", dst = "startup.lua" },
    roots   = {},
    -- Like the ui role: nav ships Basalt (loadfile'd at runtime by nav/app.lua's own ensureBasalt).
    extraFiles = {
      { src = "release/basalt-full.lua", dst = "basalt-full.lua" },
      { src = "fcs/io/cfgdefault.lua", dst = "fcs/io/cfgdefault.lua" },
    },
  },
  beacon = {
    title = "GPS beacon", status = "released",
    blurb = "Broadcasts its surveyed position on the GPS channel; hears the mesh; self-checks. Basic computer, keyboard UI.",
    configs = { "/eh2_beacon.tbl" }, configModule = "beacon.config", luaPath = "/",
    startup = { src = "launchers/beacon.lua", dst = "startup.lua" },
    roots   = {},   -- no Basalt: a beacon runs on a basic computer
  },
  beaconcontrol = {
    title = "Beacon controller", status = "released",
    blurb = "Roster + remote control of every GPS beacon on the mesh. Advanced computer, Basalt UI.",
    configs = { "/eh2_beacon_control.tbl" }, configModule = "controller.config", luaPath = "/",
    startup = { src = "launchers/beaconcontrol.lua", dst = "startup.lua" },
    roots   = {},   -- no extra command entry points; NO sharedDiag (those launchers pull the
                     -- whole flight stack, which this role must never ship -- same rule as nav/beacon).
    -- Like the ui/nav roles: the controller UI loadfile's Basalt at RUNTIME (controller/app.lua's
    -- own M.ensureBasalt -- deliberately not require("ui.basalt.app"), which would drag the fcs
    -- comms/flight-loop stack into this closure), so tools/closure.lua's require()-following
    -- discovery can never find it. extraFiles ships it alongside the closure anyway, at exactly
    -- "/basalt-full.lua" -- M.BASALT_PATHS' first (installed-location) candidate.
    extraFiles = { { src = "release/basalt-full.lua", dst = "basalt-full.lua" } },
  },
}

-- Standalone TOOLS: a tool is a shell command SuiteX can install onto any PC, independent of any
-- role. Simpler than a role: no config module, no shared diagnostics, no startup.lua -- just the
-- require() closure of one launcher root, with that launcher shipped at its command `entry` and
-- every other closure file at dst = src. Folded into `manifest.tools` (both channels).
local TOOLS = {
  splitconfig = {
    title = "Split legacy config",
    entry = "splitconfig",
    root  = "launchers/splitconfig.lua",
  },
  fcs2disk = {
    title = "FCS config dump",
    entry = "fcs2disk",
    root  = "launchers/fcs2disk.lua",
  },
}

-- ---------------------------------------------------------------- pure helpers (unit-tested)

local function luaStr(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- A table is an "array" for serialisation purposes iff its keys are exactly 1..n.
local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- A deterministic Lua table-constructor literal: sorted keys, arrays kept in order, so the
-- manifest only changes when shipped bytes change (never from hash-order jitter).
local function luaValue(v, indent)
  local ty = type(v)
  if ty == "string" then return luaStr(v) end
  if ty == "number" then return tostring(v) end
  if ty == "boolean" then return v and "true" or "false" end
  if ty ~= "table" then error("luaValue: unsupported type " .. ty) end

  local pad, padIn = ("  "):rep(indent), ("  "):rep(indent + 1)
  if isArray(v) then
    if #v == 0 then return "{}" end
    local items = {}
    for i = 1, #v do items[i] = padIn .. luaValue(v[i], indent + 1) .. "," end
    return "{\n" .. table.concat(items, "\n") .. "\n" .. pad .. "}"
  end

  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then return "{}" end
  local items = {}
  for i, k in ipairs(keys) do
    items[i] = padIn .. "[" .. luaStr(k) .. "] = " .. luaValue(v[k], indent + 1) .. ","
  end
  return "{\n" .. table.concat(items, "\n") .. "\n" .. pad .. "}"
end

-- The sorted set of top-level directory segments among a role's dst paths that contain a "/" --
-- this is the role's repair scope (what the Suite may delete-and-reinstall-into).
local function dirsOf(dstList)
  local set = {}
  for _, dst in ipairs(dstList) do
    local seg = dst:match("^([^/]+)/")
    if seg then set[seg] = true end
  end
  local out = {}
  for seg in pairs(set) do out[#out + 1] = seg end
  table.sort(out)
  return out
end

-- Pure-helper escape hatch for tests/test_suite.lua: no filesystem touched above this line.
if _G.EH2_GEN_TEST then
  return { luaValue = luaValue, dirsOf = dirsOf, isArray = isArray }
end

-- ---------------------------------------------------------------- fs helpers (real CraftOS-PC)

local function readNorm(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local body = f.readAll() or ""
  f.close()
  return (body:gsub("\r\n", "\n"))
end

local function writeResult(line)
  local f = fs.open("/gen_result.txt", "w")
  if f then f.write(line); f.close() end
end

-- Launcher entries for a role: {startup} + role.roots + SHARED_DIAG + the config module file.
-- The closure roots are the `src` of every one of these.
local function launcherEntries(spec)
  local entries = { spec.startup }
  for _, e in ipairs(spec.roots or {}) do entries[#entries + 1] = e end
  -- SHARED_DIAG only for roles that opt in (fcs/ui): these launchers require() the whole flight
  -- stack, so shipping them into nav/beacon would drag the entire FCS into those roles.
  if spec.sharedDiag then
    for _, e in ipairs(SHARED_DIAG) do entries[#entries + 1] = e end
  end
  -- Ship the role's OWN config module file (fcs/ui -> fcs/io/config.lua, unchanged; nav/beacon ->
  -- their own), so the Suite's extendConfig can require it.
  local cfgFile = spec.configModule:gsub("%.", "/") .. ".lua"
  entries[#entries + 1] = { src = cfgFile, dst = cfgFile }
  return entries
end

-- Discovered files ship with dst = src UNLESS their src is a launcher entry, in which case they
-- keep that launcher's declared dst. Every launcher src is itself a closure root, so it is
-- guaranteed to appear in `discovered` -- no separate union step needed.
local function buildRole(roleName, spec, channel)
  local entries = launcherEntries(spec)
  local srcToDst, rootSrcs, seenSrc = {}, {}, {}
  for _, e in ipairs(entries) do
    srcToDst[e.src] = e.dst
    if not seenSrc[e.src] then seenSrc[e.src] = true; rootSrcs[#rootSrcs + 1] = e.src end
  end

  local discovered, err = closure.resolve(rootSrcs, readNorm)
  if not discovered then return nil, ("role %s: %s"):format(roleName, err) end

  local files, digestParts = {}, {}
  for _, src in ipairs(discovered) do
    local manifestSrc, readPath = channelPaths(src, channel)
    local body = readNorm(readPath)
    if body == nil then return nil, ("role %s: cannot read file: %s (did you run `node tools/build.mjs`?)"):format(roleName, readPath) end
    local dst = srcToDst[src] or src
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = manifestSrc, dst = dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = roleName .. ":" .. dst .. ":" .. sum .. ":" .. size
  end

  -- extraFiles (optional): shipped alongside the require() closure but never discoverable BY it
  -- (e.g. Basalt -- loadfile'd at runtime, not require()'d). Each entry ships at its own `dst`
  -- and folds into the digest exactly like a discovered file, so `version` still moves when an
  -- extra file's bytes change. A role with no extraFiles field is completely unaffected (the loop
  -- below runs zero times), preserving buildRole's existing contract for every other role.
  for _, e in ipairs(spec.extraFiles or {}) do
    local manifestSrc, readPath = channelPaths(e.src, channel)
    local body = readNorm(readPath)
    if body == nil then return nil, ("role %s: cannot read extra file: %s"):format(roleName, readPath) end
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = manifestSrc, dst = e.dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = roleName .. ":" .. e.dst .. ":" .. sum .. ":" .. size
  end

  table.sort(files, function(a, b) return a.dst < b.dst end)

  local dstList = {}
  for i, f in ipairs(files) do dstList[i] = f.dst end

  local role = {
    title = spec.title,
    blurb = spec.blurb,
    status = spec.status,
    dirs = dirsOf(dstList),
    configs = spec.configs,
    configModule = spec.configModule,
    luaPath = spec.luaPath,
    entry = spec.startup.dst,
    files = files,
  }
  return role, nil, digestParts
end

-- buildTool mirrors buildRole for a standalone tool: resolve the closure of the single launcher
-- root, ship that root at spec.entry and every other closure file at dst = src, and fold each file
-- into the digest so `version` moves when any shipped byte changes.
local function buildTool(name, spec, channel)
  local rootSrc = spec.root
  local discovered, err = closure.resolve({ rootSrc }, readNorm)
  if not discovered then return nil, ("tool %s: %s"):format(name, err) end

  local files, digestParts = {}, {}
  for _, src in ipairs(discovered) do
    local manifestSrc, readPath = channelPaths(src, channel)
    local body = readNorm(readPath)
    if body == nil then return nil, ("tool %s: cannot read file: %s (did you run `node tools/build.mjs`?)"):format(name, readPath) end
    local dst = (src == rootSrc) and spec.entry or src
    local size, sum = #body, fnv1a(body)
    files[#files + 1] = { src = manifestSrc, dst = dst, size = size, sum = sum }
    digestParts[#digestParts + 1] = "tool:" .. name .. ":" .. dst .. ":" .. sum .. ":" .. size
  end

  table.sort(files, function(a, b) return a.dst < b.dst end)
  local dstList = {}
  for i, f in ipairs(files) do dstList[i] = f.dst end

  local tool = {
    title = spec.title,
    entry = spec.entry,
    dirs = dirsOf(dstList),
    files = files,
  }
  return tool, nil, digestParts
end

local HEADER = [==[
-- EasyHover 2 release manifest. GENERATED by tools/gen_manifest.lua -- do not edit by hand.
--
-- Read by easyhover2_suite.lua over HTTPS and parsed with textutils.unserialise, so this is a
-- plain data table: no function calls, no `return`, nothing executable.
--
-- `sum` is FNV-1a 32-bit over the file's LF-normalised bytes, paired with `size`. Together they
-- answer "did this change" and "did the download arrive intact". The trust root is HTTPS to the
-- pinned raw.githubusercontent.com URL, not this checksum.
--
-- `version` is a digest of every shipped file's sum+size, so it moves only when shipped bytes
-- move. `schema` is the persisted-config generation: a bump means saved configs get backed up.
--
-- Role membership is the require() dependency closure of each role's launchers (tools/closure.lua),
-- not a directory walk -- a file ships only if something reachable from the role's boot chain
-- actually requires it. `dirs` is the resulting repair scope: top-level directory segments among
-- the role's shipped dst paths.
]==]

local function build(channel)
  local roleTable, allDigestParts = {}, {}
  local roleNames = {}
  for name in pairs(ROLES) do roleNames[#roleNames + 1] = name end
  table.sort(roleNames)
  for _, name in ipairs(roleNames) do
    local role, err, digestParts = buildRole(name, ROLES[name], channel)
    if not role then return nil, err end
    roleTable[name] = role
    for _, part in ipairs(digestParts) do allDigestParts[#allDigestParts + 1] = part end
  end

  local toolTable = {}
  local toolNames = {}
  for name in pairs(TOOLS) do toolNames[#toolNames + 1] = name end
  table.sort(toolNames)
  for _, name in ipairs(toolNames) do
    local tool, err, digestParts = buildTool(name, TOOLS[name], channel)
    if not tool then return nil, err end
    toolTable[name] = tool
    for _, part in ipairs(digestParts) do allDigestParts[#allDigestParts + 1] = part end
  end

  table.sort(allDigestParts)
  local version = fnv1a(table.concat(allDigestParts, "|")):sub(1, 12)

  -- easyhover2_suite.lua doesn't exist until Task 6/8. Tolerate its absence with a placeholder
  -- so the generator still runs (and still writes) before the suite is ported.
  local suiteBody = readNorm("easyhover2_suite.lua")
  local updater
  if suiteBody then
    updater = { size = #suiteBody, sum = fnv1a(suiteBody) }
  else
    updater = { size = 0, sum = "00000000" }
  end

  -- release/basalt-full.lua is the pinned Basalt 2.0 full build. Tolerate its absence (though
  -- it should always be present post-Task 2) with a placeholder like updater.
  local basaltBody = readNorm("release/basalt-full.lua")
  local basalt
  if basaltBody then
    basalt = { size = #basaltBody, sum = fnv1a(basaltBody) }
  else
    basalt = { size = 0, sum = "00000000" }
  end

  local manifest = {
    version = version, schema = SCHEMA, base = REPO,
    updater = updater, basalt = basalt, roles = roleTable, tools = toolTable,
  }
  local out = HEADER .. luaValue(manifest, 0) .. "\n"
  return out, nil, version, roleTable
end

-- ---------------------------------------------------------------- modes

local args = { ... }
local mode = args[1]

if mode == "--selftest" then
  local lines = {
    "empty=" .. fnv1a(""),
    "a=" .. fnv1a("a"),
    "hello=" .. fnv1a("hello"),
  }
  for _, line in ipairs(lines) do print(line) end
  -- CraftOS-PC --headless captures no stdout for run_gen.sh, so mirror it to the result file too.
  writeResult(table.concat(lines, "\n"))
  return
end

local CHANNELS = {
  { channel = "min", path = "manifest.lua" },
  { channel = "dev", path = "manifest-dev.lua" },
}

if mode == "--check" then
  local anyDrift = false
  for _, c in ipairs(CHANNELS) do
    local out, err = build(c.channel)
    if not out then print("ERROR " .. tostring(err)); writeResult("ERROR " .. tostring(err)); return end
    local existing = readNorm(c.path) or ""
    if existing ~= out then anyDrift = true; print(c.path .. " is OUT OF SYNC") end
  end
  writeResult(anyDrift and "OUT OF SYNC" or "IN SYNC")
  return
end

-- write mode
local wroteVersions = {}
for _, c in ipairs(CHANNELS) do
  local out, err, version = build(c.channel)
  if not out then print("ERROR " .. tostring(err)); writeResult("ERROR " .. tostring(err)); return end
  local f = fs.open(c.path, "w")
  if not f then print("ERROR could not open " .. c.path); writeResult("ERROR could not open " .. c.path); return end
  f.write(out); f.close()
  wroteVersions[#wroteVersions + 1] = c.path .. "=" .. version
  print(c.path .. " written: version " .. version)
end
writeResult("WROTE " .. table.concat(wroteVersions, " "))
