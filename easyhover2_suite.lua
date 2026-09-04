-- ===================================================================
-- EasyHover 2 Suite  --  the setup tool: installs any role, updates every role
--
--   wget run https://raw.githubusercontent.com/maar-10/EasyHover2/main/easyhover2_suite.lua
--
-- The official way to put EasyHover 2 on a computer and the official way to keep it current.
-- It carries no payload: it asks GitHub what the current release contains and fetches only
-- what this computer actually needs.
--
-- Run it with no arguments and it works out what to do:
--   * nothing installed   -> asks which role this computer should be, and installs it
--   * a role installed    -> updates that role, fetching only the files that differ
--   * a BROKEN install    -> repairs it, clearing the role's own files first
--
--   easyhover2_suite.lua              install (asking for a role) or update, as appropriate
--   easyhover2_suite.lua --check      say what WOULD change; write nothing
--   easyhover2_suite.lua --repair     clear and reinstall the role's files
--   easyhover2_suite.lua --fast       trust the version stamp and skip the checksums
--   easyhover2_suite.lua --list       list every role
--   easyhover2_suite.lua --flag-defaults  snapshot current configs as DEFAULT (backup first)
--   easyhover2_suite.lua --migrate-config split leftover eh2_hw_config.tbl into current files
--   easyhover2_suite.lua <role>       go straight to a role, no questions -- also switches one
--
-- The role's hardware config lives at /eh2_hw_config.tbl.
--
-- FIVE PROPERTIES, because they are why this is safer than re-running an installer:
--
--   * IT CHECKSUMS EVERY FILE, EVERY RUN. A version stamp only says the files were correct
--     when they were written; it cannot know one has since been truncated by a chunk unload or
--     hand-edited. Finding that is the job, so it is the default, and it costs no network.
--   * VERIFIED BEFORE IT LANDS, AND REPLACED IN PLACE. Every file is checksum-verified BEFORE it
--     is written, so a corrupt download is refused without the file on disk ever being touched.
--     Each verified file then replaces its target directly, one at a time -- no second full copy
--     of the role is ever held on disk. (This used to stage the WHOLE set into `.eh2new` files
--     and commit them at the end; that needed roughly double the role's size free and hit "disk
--     full" on a cramped computer, which is why it was dropped.) The trade for the small
--     footprint: a connection dropped part way leaves the earlier files updated and the rest not.
--     That is self-healing, not damage -- the install record is stamped only once every file is
--     in place, so a half-finished run still reads as out-of-date, and the next run (which
--     re-checks every file) simply re-fetches whatever still differs.
--   * CONFIG IS SACRED. Nothing matching the protected list is ever deleted, and `guard()` is
--     asserted immediately before every write, so a wrong manifest still could not clobber a
--     config. The guarantee does not depend on the manifest being right.
--   * CONFIG IS EXTENDED, NEVER REPLACED. A saved config is backed up, then re-saved through
--     the role's own Config.withDefaults, which deep-merges it over fresh defaults. Fields
--     added by a new release appear; every value you set is kept. The only case that replaces
--     a config is one that will not parse at all, and even then the original is backed up
--     first and you are told.
--   * REPAIR NEVER COSTS YOU SETTINGS. Repairing a corrupt install deletes only inside the
--     directories the role owns. Configs live at the root and are backed up before anything
--     is touched.
--
-- Trust model: HTTPS to a pinned raw.githubusercontent.com URL is the trust root, exactly as
-- it is for `wget run`. The checksums answer "did this change" and "did this arrive intact" --
-- they are not a signature and do not defend against a hostile GitHub.
-- ===================================================================

local DEFAULT_BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

--- A computer may point itself at a fork, a local mirror, or a LAN server. One line, the base
--- URL, no trailing slash. This is also how the test harness serves the repo from localhost.
local SOURCE_FILE = "/easyhover2_suite_src.txt"

--- Optional. One line: a GitHub token, sent as an Authorization header. Only needed while the
--- repository is private -- see the note printed by --help. A token sitting in plain text on a
--- Minecraft computer is a poor secret; making the repo public is the better answer.
local TOKEN_FILE = "/easyhover2_suite_token.txt"

--- What is installed here.
local STATE_FILE = "/easyhover2_install.txt"

--- Which release channel to install: "min" (minified, default) or "dev" (readable source).
--- One line, persisted so a bare update stays on the operator's choice.
local CHANNEL_FILE = "/eh2_channel.txt"

--- Backups land here: a single-latest folder, one file per path, replaced on each run that needed them.
local BACKUP_ROOT = "/easyhover2_backup"

--- Snapshot-DEFAULT copies land here, separate from the update-backup.
local DEFAULTS_BACKUP = "/easyhover2_defaults_backup"

--- Staging suffix. Everything lands here first and is verified before anything moves.
local STAGE = ".eh2new"

--- NEVER deleted, and never written except by the config-extension step, which backs the file
--- up first. Everything the operator owns rather than the release. Lua patterns.
local PROTECTED = {
  "^/eh2_.*%.tbl$",
  "^/eh2_.*%.log$",
  "^/easyhover2_backup",
  "^/easyhover2_defaults_backup",
  "^/easyhover2_install%.txt$",
  "^/eh2_channel%.txt$",
  "^/easyhover2_suite_src%.txt$",
  "^/easyhover2_suite_token%.txt$",
}

local Suite = {}
Suite.DEFAULTS_BACKUP = DEFAULTS_BACKUP

--- Output sink. When set to a function(text, colour), say() routes output to it.
--- When nil (the default), say() prints normally (classic behavior).
Suite.sink = nil

-- ---------------------------------------------------------------- output

local function colour(c)
  if term.isColour and term.isColour() then term.setTextColour(c) end
end
local function say(text, c)
  if Suite.sink then Suite.sink(text, c); return end
  colour(c or colours.white); print(text)
end
Suite.emit = say
local function warn(text) say(text, colours.yellow) end
local function bad(text) say(text, colours.red) end
local function good(text) say(text, colours.lime) end
local function dim(text) say(text, colours.lightGrey) end

local function die(text)
  bad(text)
  colour(colours.white)
  error("", 0)
end

-- ---------------------------------------------------------------- checksum

-- FNV-1a, 32 bit, lower-case hex. MUST agree byte for byte with fnv1a() in
-- tools/gen_manifest.lua; tests/run_headless.sh asserts that it does.
local FNV_PRIME, FNV_OFFSET = 16777619, 2166136261

function Suite.checksum(s)
  local h, n, i = FNV_OFFSET, #s, 1
  while i <= n do
    local j = i + 255
    if j > n then j = n end
    -- string.byte in 256-value batches: one call per byte is many times slower.
    local b = { string.byte(s, i, j) }
    for k = 1, #b do
      h = bit32.bxor(h, b[k])
      -- 32-bit multiply split into 16-bit halves. The naive product reaches ~7.2e16, past the
      -- 2^53 exact-integer limit of a double, and would silently lose precision.
      local lo = h % 65536
      local hi = (h - lo) / 65536
      h = ((hi * FNV_PRIME % 65536) * 65536 + lo * FNV_PRIME) % 4294967296
    end
    i = j + 1
  end
  return ("%08x"):format(h)
end

-- ---------------------------------------------------------------- files

local function readFile(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local s = f.readAll()
  f.close()
  return s or ""
end

--- Unguarded write. Only for files the Suite itself owns: the state record and backups.
local function writeRaw(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(content)
  f.close()
  return true
end

--- Bare-name fs adapters for cfgdefault (eh2_devbind.tbl <-> /eh2_devbind.tbl).
function Suite.cfgRead(name)
  if type(name) ~= "string" or name == "" then return nil end
  if not name:match("^/") then name = "/" .. name end
  return readFile(name)
end

function Suite.cfgWrite(name, body)
  if type(name) ~= "string" or name == "" then return false end
  if not name:match("^/") then name = "/" .. name end
  return writeRaw(name, body)
end

--- Is this path the operator's rather than the release's?
function Suite.isProtected(path)
  if not path:match("^/") then path = "/" .. path end
  for _, pattern in ipairs(PROTECTED) do
    if path:match(pattern) then return true end
  end
  return false
end

--- The last line of defence. Every release write and every delete goes through here.
local function guard(path, what)
  if Suite.isProtected(path) then
    die(("REFUSED to %s a protected path: %s\nThis is a bug; nothing was changed.")
      :format(what or "write", path))
  end
end

local function writeRelease(path, content)
  guard(path, "write")
  return writeRaw(path, content)
end

-- ---------------------------------------------------------------- http

local token = nil

local function fetchOnce(url)
  -- CACHE-BUST. raw.githubusercontent.com is served through a CDN (Fastly) that can keep serving a
  -- file for minutes after a push. Left alone, a just-pushed manifest/file is invisible until the
  -- edge TTL expires -- exactly the "Already current" that hid a real update. A unique query string
  -- is a fresh cache key, and no-cache headers ask the edge to revalidate; together the update lands
  -- immediately. GitHub ignores the extra query param and returns the same file.
  local sep = url:find("?", 1, true) and "&" or "?"
  local bustUrl = url .. sep .. "cb=" .. tostring((os.epoch and os.epoch("utc")) or os.time())
  local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
  if token then headers.Authorization = "token " .. token end
  local ok, handle, err = pcall(http.get, bustUrl, headers)
  if not ok then return nil, tostring(handle) end
  if not handle then return nil, tostring(err or "no response") end
  local body = handle.readAll()
  handle.close()
  if body == nil or body == "" then return nil, "empty response" end
  return body
end

--- Two attempts: a single dropped packet should not fail a whole install.
local function fetch(url)
  local body, err = fetchOnce(url)
  if body then return body end
  sleep(1)
  local retry, err2 = fetchOnce(url)
  if retry then return retry end
  return nil, tostring(err2 or err)
end

-- ---------------------------------------------------------------- state

--- Parse the install record. Tolerant: a truncated or hand-mangled file yields nils rather
--- than an error, and the Suite then falls back to detecting the role from what is on disk.
function Suite.parseState(raw)
  raw = raw or ""
  return {
    version = raw:match("version=([%w]+)"),
    schema = tonumber(raw:match("schema=(%d+)")),
    role = raw:match("role=([%w_]+)"),
    at = raw:match("at=([^\n]+)"),
  }
end

function Suite.formatState(state)
  return ("version=%s\nschema=%d\nrole=%s\nat=%s\n"):format(
    tostring(state.version), tonumber(state.schema) or 1,
    tostring(state.role), tostring(state.at or ""))
end

--- Pick the release channel. An explicit flag wins; otherwise a valid marker; otherwise min.
function Suite.resolveChannel(flag, markerRaw)
  if flag == "dev" or flag == "min" then return flag end
  markerRaw = markerRaw and markerRaw:gsub("%s+", "") or ""
  if markerRaw == "dev" or markerRaw == "min" then return markerRaw end
  return "min"
end

-- Persist /eh2_channel.txt only after the release manifest is readable, and never on
-- --check/--list. A failed --dev fetch must not flip the computer onto the dev channel.
function Suite.shouldPersistChannel(checkOnly, listOnly, manifestOk)
  return (not checkOnly) and (not listOnly) and manifestOk == true
end

--- Which manifest a channel fetches.
function Suite.manifestName(channel)
  return (channel == "dev") and "manifest-dev.lua" or "manifest.lua"
end

--- Which role do the files on disk look like? Used when the install record is missing or
--- unreadable, which is exactly the corrupt-install case the operator most needs handled.
--- Returns role, why.
-- Identify the installed role. Primary signal: the installed /startup.lua matches exactly one
-- role's startup launcher (size+sum). Fallback: the role with the most of its UNIQUE files
-- present (files whose dst appears in only one role).
function Suite.detectRole(manifest, exists, read)
  exists = exists or function(p) return fs.exists(p) and not fs.isDir(p) end
  read = read or function(p)
    if not fs.exists(p) or fs.isDir(p) then return nil end
    local f = fs.open(p, "r"); local s = f.readAll(); f.close(); return s
  end

  -- Primary: startup.lua fingerprint.
  local startupBody = read("/startup.lua")
  if startupBody then
    local size, sum = #startupBody, Suite.checksum(startupBody)
    for roleName, spec in pairs(manifest.roles) do
      if spec.status == "released" then
        for _, e in ipairs(spec.files) do
          if e.dst == "startup.lua" and e.size == size and e.sum == sum then
            return roleName, "startup"
          end
        end
      end
    end
  end

  -- Fallback: unique-file count. Build dst -> #roles-owning.
  local owners = {}
  for _, spec in pairs(manifest.roles) do
    if spec.status == "released" then
      for _, e in ipairs(spec.files) do owners[e.dst] = (owners[e.dst] or 0) + 1 end
    end
  end
  local best, bestScore = nil, 0
  for roleName, spec in pairs(manifest.roles) do
    if spec.status == "released" then
      local score = 0
      for _, e in ipairs(spec.files) do
        if owners[e.dst] == 1 and exists("/" .. e.dst) then score = score + 1 end
      end
      if score > bestScore then best, bestScore = roleName, score end
    end
  end
  if bestScore == 0 then return nil, "none" end
  return best, "unique-files"
end

-- ---------------------------------------------------------------- DEFAULT snapshot / migrate (S5)

function Suite.parseArgs(args)
  args = args or {}
  local o = {
    wantRole = nil, checkOnly = false, forceRepair = false, listOnly = false,
    fastPath = false, wantChannel = nil, noUI = false, help = false,
    flagDefaults = false, migrateConfig = false,
  }
  for _, arg in ipairs(args) do
    local a = tostring(arg):lower()
    if a == "--check" or a == "-n" then o.checkOnly = true
    elseif a == "--verify" then o.fastPath = false
    elseif a == "--fast" then o.fastPath = true
    elseif a == "--repair" then o.forceRepair = true
    elseif a == "--list" then o.listOnly = true
    elseif a == "--dev" then o.wantChannel = "dev"
    elseif a == "--min" then o.wantChannel = "min"
    elseif a == "--yes" or a == "--go" then o.noUI = true
    elseif a == "--help" or a == "-h" then o.help = true; break
    elseif a == "--flag-defaults" then o.flagDefaults = true
    elseif a == "--migrate-config" then o.migrateConfig = true
    elseif a:sub(1, 2) == "--" then
      die("unknown option: " .. tostring(arg))
    else
      o.wantRole = a
    end
  end
  return o
end

--- Copy each existing current file into DEFAULTS_BACKUP/<filename>, then snapshot to DEFAULT.
function Suite.flagDefaults(role, read, write)
  local cfgdefault = require("fcs.io.cfgdefault")
  local cfgroles = require("fcs.io.cfgroles")
  read = read or Suite.cfgRead
  write = write or Suite.cfgWrite
  for _, kind in ipairs(cfgroles.kinds(role) or {}) do
    local name = cfgroles.file(kind)
    if name then
      local body = read(name)
      if body then
        write(Suite.DEFAULTS_BACKUP .. "/" .. name, body)
      end
    end
  end
  return cfgdefault.snapshot(role, read, write)
end

function Suite.migrateConfig(read, write, role)
  local cfgdefault = require("fcs.io.cfgdefault")
  read = read or Suite.cfgRead
  write = write or Suite.cfgWrite
  return cfgdefault.migrate(read, write, role)
end

--- Local config ops: never install. require() failure is a printed error, not a throw.
---
--- The config modules live at absolute /fcs/io/... . CC's require resolves RELATIVE package.path
--- patterns ("?.lua") against the RUNNING PROGRAM's directory -- so a suite launched off a floppy
--- or any non-root folder searches <progdir>/fcs/io/... and misses the installed /fcs/io/... (it
--- only works when launched from /). Prepend the absolute "/?.lua" patterns, once, so resolution
--- works wherever we launch from -- the same augmentation the install path (extendConfig) and the
--- FCS runtime startup already do. The prefix check keeps it idempotent across repeated ops.
function Suite.runConfigFlags(opts, role, read, write)
  local ROOT_PATH = "/?.lua;/?/init.lua;"
  if package.path:sub(1, #ROOT_PATH) ~= ROOT_PATH then
    package.path = ROOT_PATH .. package.path
  end
  local ok, mod = pcall(require, "fcs.io.cfgdefault")
  if not ok then
    -- Surface the real reason (module-not-found vs a load error) instead of always blaming the
    -- install -- "not found" means the role's config files really are missing here.
    bad("could not load fcs.io.cfgdefault: " .. tostring(mod))
    bad("If this persists, Update or Repair this role -- its config files may be missing.")
    return false
  end
  if not role then
    bad("no role detected; install a role first or pass one as an argument")
    return false
  end
  read = read or Suite.cfgRead
  write = write or Suite.cfgWrite
  if opts.migrateConfig then
    local r = Suite.migrateConfig(read, write, role)
    good(("migrate-config: %s"):format((r and r.action) or "?"))
  end
  if opts.flagDefaults then
    local r = Suite.flagDefaults(role, read, write)
    good(("flag-defaults %s: copied %d, skipped %d"):format(
      role, (r and #r.copied) or 0, (r and #r.skipped) or 0))
  end
  return true
end

-- ---------------------------------------------------------------- integrity

--- Compare every file of a role against the manifest. Pure enough to test: `read` and `size`
--- are injectable.
--- Returns { ok, missing = {}, corrupt = {}, present = n, total = n }
function Suite.integrity(spec, read)
  read = read or readFile
  local report = { missing = {}, corrupt = {}, present = 0, total = #spec.files }
  for _, entry in ipairs(spec.files) do
    local path = "/" .. entry.dst
    local body = read(path)
    if body == nil then
      report.missing[#report.missing + 1] = entry.dst
    else
      report.present = report.present + 1
      if #body ~= entry.size or Suite.checksum(body) ~= entry.sum then
        report.corrupt[#report.corrupt + 1] = entry.dst
      end
    end
  end
  report.ok = (#report.missing == 0 and #report.corrupt == 0)
  return report
end

-- ---------------------------------------------------------------- backups

local backedUp = {}

local function timestamp()
  local ok, stamp = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
  if ok and type(stamp) == "string" then return stamp end
  return tostring(os.epoch("utc"))
end

-- Single-latest PER FILE: the backup folder holds one copy of each distinct file. Each call
-- clears only THAT file's prior backup, so multiple configs coexist. Copy-never-move, so a
-- failed run costs nothing.
function Suite.backupConfig(path, version)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  if not fs.exists(BACKUP_ROOT) then fs.makeDir(BACKUP_ROOT) end
  local name = path:gsub("^/", ""):gsub("/", "_")
  local target = ("%s/%s"):format(BACKUP_ROOT, name)
  if fs.exists(target) then fs.delete(target) end
  local f = fs.open(path, "r"); local body = f.readAll(); f.close()
  local w = fs.open(target, "w"); w.write(body or ""); w.close()
  backedUp[#backedUp + 1] = target
  return target
end

-- ---------------------------------------------------------------- config

--- Extend a saved config with any defaults a new release added, in place.
---
--- The role's own Config.withDefaults does the deep merge (lists replaced, maps merged, each
--- thruster/relay entry merged over its template), so this cannot invent semantics of its own:
--- it is the same code path the program itself uses at load time. Which is also why this step
--- is a convenience rather than a guarantee -- the program merges on load regardless.
---
--- Returns one of: "extended" | "fresh" | "absent" | "quarantined" | "skipped: <why>"
function Suite.extendConfig(spec, path, version)
  if not spec.configModule then return "skipped: no config module" end
  if not spec.luaPath or spec.luaPath == "" then return "skipped: no lua path" end
  if not fs.exists(path) then return "absent" end

  Suite.backupConfig(path, version)

  local ok, result = pcall(function()
    package.path = spec.luaPath .. "/?.lua;" .. spec.luaPath .. "/?/init.lua;" .. package.path
    -- drop any cached copy so the freshly installed module is the one used
    package.loaded[spec.configModule] = nil
    local Config = require(spec.configModule)

    local cfg, existed, err = Config.load(path)
    if err then return "corrupt" end
    if not existed then return "absent" end

    -- EH2's standalone config module returns the saved table pre-merge, so the merge
    -- over fresh defaults is explicit here (v1's lib.config merged inside load()).
    cfg = Config.withDefaults(cfg, path)
    local saved, saveErr = Config.save(path, cfg)
    if not saved then error(tostring(saveErr), 0) end
    return "extended"
  end)

  if not ok then return "skipped: " .. tostring(result) end

  if result == "corrupt" then
    -- The one case where a config is replaced: it does not parse, so there is nothing to
    -- preserve. It is already backed up above, and the operator is told.
    local ok2 = pcall(function()
      local Config = require(spec.configModule)
      local fresh = Config.withDefaults({}, path)
      local saved, saveErr = Config.save(path, fresh)
      if not saved then error(tostring(saveErr), 0) end
    end)
    return ok2 and "quarantined" or "skipped: unparseable and could not rewrite"
  end

  return result
end

-- ---------------------------------------------------------------- repair

--- Delete the role's own files so a corrupt install is cleared before reinstalling.
---
--- Scoped to the directories the manifest says the role owns, plus root-level files it ships.
--- Configs live at the root and are not in the file list, so they are structurally out of
--- reach -- and guard() is asserted on every delete anyway.
function Suite.clearRole(spec, dryRun)
  local removed = {}
  for _, dir in ipairs(spec.dirs or {}) do
    local path = "/" .. dir
    if fs.exists(path) and fs.isDir(path) then
      guard(path, "delete")
      if not dryRun then fs.delete(path) end
      removed[#removed + 1] = path .. "/"
    end
  end
  for _, entry in ipairs(spec.files) do
    if not entry.dst:find("/") then          -- a root-level file such as startup.lua
      local path = "/" .. entry.dst
      if fs.exists(path) then
        guard(path, "delete")
        if not dryRun then fs.delete(path) end
        removed[#removed + 1] = path
      end
    end
  end
  return removed
end

--- Decide what this run is: "install" | "repair" | "current" | "update".
---
--- UPDATE AND CORRUPTION LOOK IDENTICAL ON DISK, and the version stamp is what tells them
--- apart. Files differing from a manifest they were never built from is exactly what an update
--- IS -- so treating that as corruption, as this once did, meant the Suite could only ever
--- "fix" a computer and never update one. The files ended up right either way, but it told the
--- operator their install was broken every single time a release shipped.
---
--- It is corruption only when the stamp claims THESE EXACT FILES are already correct and the
--- bytes disagree, or when files are present and nothing on the computer records what they are.
--- MISSING FILES ALONE PROVE NOTHING: a release that adds a module leaves an older install
--- legitimately missing it.
---
--- Pure, so the decision is testable without a network or a filesystem.
function Suite.choosePlan(s)
  if not s.anyInstall then return "install" end
  if s.forceRepair then return "repair" end
  if s.noRecord then return "repair" end
  if s.sameVersion then
    return s.mismatched and "repair" or "current"
  end
  return "update"
end

--- The root-level suite launchers this role does NOT ship -- the orphan set a switch must prune.
---
--- Root-level files (a `dst` with no "/", e.g. `flight`, `cockpit`, `probe`) live outside every
--- directory Suite.pruneRole walks, so on a role switch the OLD role's launchers would survive
--- while their in-dir dependencies (e.g. /tools/flight.lua) are pruned -- running the orphan
--- /flight then throws "module not found".
---
--- SAFE UNIVERSE = every role's root-level `dst` in the manifest (the known set of suite-shipped
--- launchers). Subtracting THIS role's own dst leaves only launchers some role ships but this one
--- does not; an arbitrary root file the operator owns is never in the universe, so never a
--- candidate. `startup.lua` is shipped by every role, so it is in the keep set and never returned.
---
--- Pure: fed the role spec and the manifest, returns sorted "/name" paths, no filesystem access,
--- so the decision is unit-testable without an install.
function Suite.orphanLaunchers(spec, manifest)
  local keep = {}
  for _, entry in ipairs(spec.files or {}) do keep["/" .. entry.dst] = true end

  local out, seen = {}, {}
  if manifest and type(manifest.roles) == "table" then
    for _, r in pairs(manifest.roles) do
      for _, entry in ipairs(r.files or {}) do
        if not entry.dst:find("/") then          -- root-level launcher, not a module in a dir
          local path = "/" .. entry.dst
          if not keep[path] and not seen[path] then
            seen[path] = true
            out[#out + 1] = path
          end
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- Delete files the release no longer ships: modules under the role's own directories, and
--- root-level launchers the old role shipped but the new one does not.
---
--- An update rewrites every file it knows about, but a module the new release DROPPED would
--- otherwise sit there for ever -- invisible to the integrity check, which only looks for the
--- files the manifest lists. Run AFTER the new files are committed, never before: clearing up
--- front would turn a failed download into a destroyed install.
---
--- `manifest` is needed only for the root-launcher sweep (Suite.orphanLaunchers): the in-dir
--- walk is self-contained in the spec. guard() is asserted before EVERY delete, so a protected
--- path (a config) can never be reached even if one somehow appeared in a candidate list.
function Suite.pruneRole(spec, dryRun, manifest)
  local keep = {}
  for _, entry in ipairs(spec.files) do keep["/" .. entry.dst] = true end

  local removed = {}
  local function drop(path)
    guard(path, "delete")
    if not dryRun then fs.delete(path) end
    removed[#removed + 1] = path
  end

  local function walk(dir)
    if not fs.exists(dir) or not fs.isDir(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
      local path = fs.combine(dir, name)
      if not path:match("^/") then path = "/" .. path end
      if fs.isDir(path) then
        walk(path)
      elseif not keep[path] and not Suite.isProtected(path) and not path:find("%" .. STAGE .. "$") then
        drop(path)
      end
    end
  end
  for _, dir in ipairs(spec.dirs or {}) do walk("/" .. dir) end

  -- Sweep the old role's orphan root-level launchers (only ones some role ships; never an
  -- arbitrary root file). isProtected is belt-and-suspenders: the candidate set is drawn from
  -- manifest launchers, which are never configs, so it can only ever be false here.
  for _, path in ipairs(Suite.orphanLaunchers(spec, manifest)) do
    if fs.exists(path) and not fs.isDir(path)
       and not Suite.isProtected(path) and not path:find("%" .. STAGE .. "$") then
      drop(path)
    end
  end

  return removed
end

--- Carry out the plan Suite.choosePlan decided: back up configs, clear a broken install when
--- repairing, stage-fetch-verify every file, commit, extend configs, prune anything the release
--- no longer ships, record the new state, and check whether the Suite itself is stale.
---
--- THIS IS THE ENGINE. The v1 keyboard flow and Suite.runUI's "Go"/"Repair" buttons both call
--- it, unmodified, so an install performed by clicking a button cannot differ from one performed
--- by running the Suite on a basic terminal.
function Suite.performPlan(base, manifest, spec, role, plan, fresh)
  local backupCountBefore = #backedUp

  -- ---- back up configs BEFORE touching anything
  for _, cfgPath in ipairs(spec.configs or {}) do
    if fs.exists(cfgPath) then
      local target = Suite.backupConfig(cfgPath, manifest.version)
      if target then dim("backed up " .. cfgPath) end
    end
  end

  -- ---- clear a broken install (never configs)
  if plan == "repair" then
    local cleared = Suite.clearRole(spec, false)
    for _, path in ipairs(cleared) do dim("cleared " .. path) end
  end

  -- ---- fetch, verify, and replace EACH file in place, one at a time.
  --
  -- Direct in-place replacement -- deliberately NOT the old download-everything-into-.eh2new-
  -- then-commit staging. Staging held a SECOND copy of every file at once, so a big role needed
  -- roughly double its own size in free space and hit "disk full" on a cramped computer. Writing
  -- each verified file straight over its target keeps the peak footprint to a single file's worth
  -- of headroom. The trade: the SET is no longer all-or-nothing -- an interruption part way
  -- through leaves earlier files updated and later ones not. That is self-healing, because the
  -- state stamp is written only once every file is in place (far below), so a half-finished run
  -- still scores as "update"/"repair" and the next run re-fetches whatever still differs. Content
  -- is still checksum-verified BEFORE it is written, so a corrupt download can never land on disk.
  --
  -- doFetch resolves to Suite.fetch (the exposed engine fetch) so a test can inject a failing
  -- fetch and assert the in-place semantics; it is `fetch` verbatim in every real run.
  local doFetch = Suite.fetch or fetch
  print("")
  say(("Installing %d file(s) in place..."):format(#spec.files))
  local written = 0

  -- Truthful failure: by the time this fires, `written` files have ALREADY been replaced in
  -- place, so "nothing was changed" would be a lie. Say what really happened and how to recover.
  local function interrupted(reason)
    if written > 0 then
      die(("%s\n%d of %d file(s) were already replaced. Run the Suite again to finish -- it "
        .. "re-checks every file and re-fetches whatever still differs.")
        :format(reason, written, #spec.files))
    end
    die(reason .. "\nNothing was changed; the install is as it was.")
  end

  for index, entry in ipairs(spec.files) do
    local url = ("%s/%s"):format(base, entry.src)
    local content, fetchErr = doFetch(url)
    if not content then
      interrupted(("failed on %s (%s)"):format(entry.src, tostring(fetchErr)))
    end
    -- GitHub raw serves what is committed; a proxy that rewrites line endings would show up here
    -- as a size mismatch rather than as a mysterious runtime error later. Verified BEFORE the
    -- write below, so a corrupt download is refused without the file on disk ever being touched.
    if #content ~= entry.size or Suite.checksum(content) ~= entry.sum then
      interrupted(("%s arrived corrupt (expected %d bytes / %s, got %d / %s)")
        :format(entry.src, entry.size, entry.sum, #content, Suite.checksum(content)))
    end
    -- Delete-then-write, deliberately NOT write-temp-then-move. temp+move would keep the old file
    -- until the new one is durably written (surviving a disk-full mid-write), but at a peak cost of
    -- one extra file of headroom -- and for basalt-full.lua (~306 KB) that extra copy pushes a large
    -- role toward CC:T's hard 1 MB disk ceiling, the very wall this change exists to stay under.
    -- Frugality wins: deleting first frees the old file's space so the new write almost never fails,
    -- and the rare disk-full-mid-write is self-healing (the state stamp far below is withheld until
    -- every file lands, so a re-run re-fetches the one missing file). guard() below runs BEFORE the
    -- delete, so a PROTECTED operator path (a config, /eh2_*.tbl, the install record) can never be
    -- deleted or overwritten here -- it dies first.
    local final = "/" .. entry.dst
    guard(final, "replace")
    if fs.exists(final) then fs.delete(final) end
    if not writeRelease(final, content) then
      interrupted("could not write " .. final .. " (disk full?)")
    end
    written = written + 1
    if index % 5 == 0 or index == #spec.files then
      dim(("  %d/%d"):format(index, #spec.files))
    end
  end
  good(("Installed %d file(s)."):format(written))

  -- ---- configs: extend with any newly added defaults, in place
  print("")
  for _, cfgPath in ipairs(spec.configs or {}) do
    local result = Suite.extendConfig(spec, cfgPath, manifest.version)
    if result == "extended" then
      good(("config extended with new defaults: %s"):format(cfgPath))
    elseif result == "quarantined" then
      warn(("config %s would not parse: backed up and replaced with defaults"):format(cfgPath))
    elseif result == "absent" then
      dim(("no config yet at %s (it is created on first run)"):format(cfgPath))
    else
      dim(("config %s: %s"):format(cfgPath, result))
    end
  end

  -- ---- drop anything this release no longer ships (after the new files are safely in place)
  local pruned = Suite.pruneRole(spec, false, manifest)
  for _, path in ipairs(pruned) do dim("removed " .. path .. " (no longer shipped)") end

  -- ---- record what is now installed
  writeRaw(STATE_FILE, Suite.formatState({
    version = manifest.version,
    schema = manifest.schema or 1,
    role = role,
    at = timestamp(),
  }))

  print("")
  -- Delta over THIS call only: a long-lived Suite.runUI session can call performPlan several
  -- times in one process, and #backedUp is a whole-process counter, so reading it raw here
  -- would double-count backups made by an earlier action in the same session.
  local backedUpThisRun = #backedUp - backupCountBefore
  if backedUpThisRun > 0 then
    warn(("%d file(s) backed up in %s"):format(backedUpThisRun, BACKUP_ROOT))
  end
  good(("Now at %s as role '%s'."):format(manifest.version, role))
  if spec.entry ~= "" then
    if written > 0 and not fresh then
      -- THIS COMPUTER IS STILL RUNNING THE OLD CODE. CC loads a program once; new files on
      -- disk do nothing until something starts them. Updating a running cockpit and then
      -- wondering why the new buttons do not work is exactly what happens without this line,
      -- so it is a warning rather than a dim hint.
      warn("REBOOT THIS COMPUTER -- it is still running the old version.")
      dim("  reboot     (or run: " .. spec.entry .. ")")
    else
      dim("Reboot to run it, or: " .. spec.entry)
    end
  end

  Suite.selfUpdateNotice(base, manifest)
  colour(colours.white)
  return true
end

-- ---------------------------------------------------------------------- UI

--- Where do the main status screen's panels go on THIS terminal?
---
--- Pure, so tests/test_suite.lua can check it against every supported terminal size instead
--- of us discovering on a turtle's 39x13 screen that a block ran off the bottom.
---
--- Five blocks stacked top to bottom: a title bar, a status block (role/plan), an integrity
--- block (progress bar + counts), an actions row (the prompt line, pinned to the bottom),
--- and a diagnostics block (scrolling log) that soaks up whatever rows are left between them.
---
--- width/height are the terminal's columns/rows. Returns rects {x,y,w,h}, all within
--- [1,width] x [1,height] and non-overlapping.
function Suite.uiPanels(width, height)
  local w = math.max(1, width or 51)
  local h = math.max(1, height or 19)

  local title = { x = 1, y = 1, w = w, h = 1 }
  local actions = { x = 1, y = h, w = w, h = 1 }

  local bodyTop = title.y + title.h
  local bodyH = math.max(1, actions.y - bodyTop)

  local statusH = math.min(bodyH, math.max(1, math.floor(bodyH * 0.25 + 0.5)))
  local integrityH = math.min(bodyH - statusH, math.max(1, math.floor(bodyH * 0.25 + 0.5)))
  local diagH = math.max(1, bodyH - statusH - integrityH)

  local status = { x = 1, y = bodyTop, w = w, h = statusH }
  local integrity = { x = 1, y = bodyTop + statusH, w = w, h = integrityH }
  local diag = { x = 1, y = bodyTop + statusH + integrityH, w = w, h = diagH }

  return { title = title, status = status, integrity = integrity, actions = actions, diag = diag }
end

--- How many cells of a `barWidth`-wide progress bar should be filled for done/total?
---
--- Pure and rounded to the nearest cell rather than floored, so a bar that is e.g. 9/10 of the
--- way there reads as "almost full" instead of visibly one cell short.
function Suite.progressFill(done, total, barWidth)
  if not total or total <= 0 then return 0 end
  return math.min(barWidth, math.floor(done / total * barWidth + 0.5))
end

--- Which colour signals a plan on the status screen?
function Suite.statusColour(plan)
  if plan == "current" then return colours.lime end
  if plan == "update" then return colours.yellow end
  if plan == "repair" then return colours.orange end
  if plan == "install" then return colours.cyan end
  return colours.white
end

--- What to call files that differ from the manifest, given the plan. Under an UPDATE a differing
--- file is simply the NEW version (outdated on disk), not corruption -- calling it "corrupt" every
--- release was the long-standing EH1/EH2 papercut. It is corruption only in a same-version repair.
function Suite.diffLabel(plan)
  return plan == "update" and "outdated" or "corrupt"
end

--- Is the running Suite a persistent, saved copy worth keeping current? `wget run` executes from
--- memory / a transient path, so its "self" is never our saved file -- attempting a self-update
--- there reads the wrong file, never matches the manifest, and cried "Suite out of date" on every
--- run. Only a real, saved easyhover2_suite.lua should self-update.
function Suite.selfIsPersistent(path)
  return type(path) == "string" and path:match("easyhover2_suite%.lua$") ~= nil
end

--- The shipped diagnostic commands for a role: root-level shipped files (`dst` has no "/"),
--- excluding `startup.lua` (that is the boot launcher, not something you run by hand).
--- In manifest order (gen_manifest sorts `files` by dst), so the list is deterministic.
--- Pure: fed a role spec, never touches the filesystem.
function Suite.diagTools(spec)
  local tools = {}
  for _, entry in ipairs(spec.files) do
    if entry.dst ~= "startup.lua" and not entry.dst:find("/") then
      tools[#tools + 1] = entry.dst
    end
  end
  return tools
end

--- Which action-row buttons apply to this ctx, and what should they say? Pure: only reads
--- ctx.plan. "Go" (Install/Update/Repair, whichever the plan is) is omitted once the plan is
--- already "current" -- there is nothing for it to do. "Repair" stays as a standing manual
--- override regardless of plan, matching --repair on the keyboard flow. There is no separate
--- dry-run/"Check" button: the status and integrity panels already show what a run would find
--- (missing/corrupt counts, the plan) continuously, without needing to ask.
function Suite.actionSpec(ctx)
  local list = {}
  if ctx.plan and ctx.plan ~= "current" then
    local label = (ctx.plan == "install" and "Install")
      or (ctx.plan == "repair" and "Repair") or "Update"
    list[#list + 1] = { key = "go", label = label }
  end
  list[#list + 1] = { key = "verify", label = "Verify" }
  if ctx.plan ~= "repair" then list[#list + 1] = { key = "repair", label = "Repair" } end
  list[#list + 1] = { key = "switch", label = "Switch" }
  list[#list + 1] = { key = "tools", label = "Tools" }
  list[#list + 1] = { key = "quit", label = "Quit" }
  return list
end

--- Lays out `actions` (ordered {key=, label=}) as "[Label]" buttons left to right in `rect`,
--- one row. When they all fit, everything is on page 1 with no nav buttons. When they do not,
--- pages through them with reserved "<"/">" nav buttons -- the 26-wide advanced pocket computer
--- cannot show six buttons on one row, so this is not an edge case to special-case away.
---
--- Pure: no term calls, so every width can be asserted without a screen. Returns
--- { buttons = { {key=,label=,x=,y=,w=}, ... }, pages = n, page = clamped }.
function Suite.actionButtons(rect, actions, page)
  local w = rect.w
  local function labelW(a) return #a.label + 2 end -- "[Label]"

  local totalW = 0
  for i, a in ipairs(actions) do
    totalW = totalW + labelW(a) + (i > 1 and 1 or 0)
  end

  if totalW <= w then
    local buttons, x = {}, rect.x
    for _, a in ipairs(actions) do
      local lw = labelW(a)
      buttons[#buttons + 1] = { key = a.key, label = a.label, x = x, y = rect.y, w = lw }
      x = x + lw + 1
    end
    return { buttons = buttons, pages = 1, page = 1 }
  end

  -- Doesn't fit on one row: reserve nav-arrow space on every page (even the ones that don't
  -- need it) so the button positions don't jump around from page to page.
  local usable = math.max(1, w - 4)
  local pageOf, curPage, curW, start = {}, 1, 0, 1
  for i, a in ipairs(actions) do
    local lw = labelW(a) + (i > start and 1 or 0)
    if curW + lw > usable and curW > 0 then
      curPage, start, curW = curPage + 1, i, labelW(a)
    else
      curW = curW + lw
    end
    pageOf[i] = curPage
  end
  local pages = curPage
  page = math.max(1, math.min(page or 1, pages))

  local buttons, x = {}, rect.x
  if page > 1 then
    buttons[#buttons + 1] = { key = "__prev", label = "<", x = x, y = rect.y, w = 1 }
    x = x + 2
  end
  for i, a in ipairs(actions) do
    if pageOf[i] == page then
      local lw = labelW(a)
      buttons[#buttons + 1] = { key = a.key, label = a.label, x = x, y = rect.y, w = lw }
      x = x + lw + 1
    end
  end
  if page < pages then
    buttons[#buttons + 1] = { key = "__next", label = ">", x = rect.x + w - 1, y = rect.y, w = 1 }
  end

  return { buttons = buttons, pages = pages, page = page }
end

--- Which button (if any) sits under a click at (x, y)? Pure hit test, shared by the actions
--- row and every other clickable list the UI draws (tool picker, yes/no confirm).
function Suite.hitTestButtons(buttons, x, y)
  for _, b in ipairs(buttons) do
    if y == b.y and x >= b.x and x <= b.x + b.w - 1 then return b.key end
  end
  return nil
end

--- Lays out a vertical list of clickable rows inside `rect`, one item per row, clipped to the
--- panel's height. `items` is an ordered array of {key=, label=}. Pure; feeds the same
--- Suite.hitTestButtons used for the actions row.
function Suite.listRows(rect, items)
  local rows = {}
  local last = math.min(#items, math.max(0, rect.h))
  for i = 1, last do
    rows[#rows + 1] = { key = items[i].key, label = items[i].label,
      x = rect.x, y = rect.y + i - 1, w = rect.w }
  end
  return rows
end

-- ---------------------------------------------------------------- role picker

--- How should the role list be laid out on THIS terminal?
---
--- Pure, so tests/test_suite.lua can check it against every terminal size instead of us
--- discovering on a basic computer that the first four roles scrolled off with no way back.
---
--- released/reserved are counts; `height` is the terminal's rows. Returns:
---   mode    "blurbs"  one line per role plus a blurb for the INSTALLABLE ones
---           "compact" one line per role
---           "paged"   one line per role, split across pages
---   perPage how many roles fit on a page (only meaningful for "paged")
function Suite.rolePickerLayout(released, reserved, height)
  local total = released + reserved
  -- Reserved rows: title, blank, blank, prompt, input line.
  local available = math.max(1, (height or 19) - 5)

  -- Blurbs only for the roles you can actually install -- that is where the detail helps, and
  -- it is what makes the list fit on an advanced terminal.
  if (released * 2) + reserved <= available then
    return { mode = "blurbs", perPage = total }
  end
  if total <= available then
    return { mode = "compact", perPage = total }
  end
  -- Paged: one row goes to the "page x/y" footer.
  return { mode = "paged", perPage = math.max(1, available - 1) }
end

--- Exposed so tests can drive the real draw-and-input loop with a stubbed read().
function Suite.askForRole(manifest, order)
  local width, height = term.getSize()

  local choices = {}
  local released, reserved = 0, 0
  for _, name in ipairs(order) do
    if manifest.roles[name] then
      choices[#choices + 1] = name
      if manifest.roles[name].status == "released" then
        released = released + 1
      else
        reserved = reserved + 1
      end
    end
  end
  if #choices == 0 then return nil end

  local layout = Suite.rolePickerLayout(released, reserved, height)
  local pages = math.max(1, math.ceil(#choices / layout.perPage))
  local page = 1

  local function fit(text)
    text = tostring(text)
    if #text > width then return text:sub(1, width) end
    return text
  end

  local function draw()
    -- Start from a clean screen every time. Whatever the Suite printed before this point has
    -- already scrolled, and the operator cannot scroll back in a CC terminal.
    term.clear()
    term.setCursorPos(1, 1)
    colour(colours.cyan)
    print(fit("EasyHover 2 -- which role is this computer?"))

    local first = (page - 1) * layout.perPage + 1
    local last = math.min(#choices, first + layout.perPage - 1)
    for index = first, last do
      local name = choices[index]
      local spec = manifest.roles[name]
      local isReleased = spec.status == "released"
      local line
      if layout.mode == "blurbs" then
        line = ("%d) %s"):format(index, spec.title or name)
      else
        -- name AND title, so a typed answer is obvious too
        line = ("%d) %-9s %s"):format(index, name, spec.title or "")
      end
      if not isReleased then line = line .. " (soon)" end
      say(fit(line), isReleased and colours.white or colours.lightGrey)
      if layout.mode == "blurbs" and isReleased then
        dim(fit("   " .. (spec.blurb or "")))
      end
    end

    if pages > 1 then
      colour(colours.lightGrey)
      print(fit(("page %d/%d -- 'n' next, 'p' previous"):format(page, pages)))
    end
    print("")
    colour(colours.lightGrey)
    print(fit("number or name, blank to cancel"))
    colour(colours.white)
    write("> ")
  end

  while true do
    draw()
    local answer = read()
    if answer == nil or answer == "" then return nil end
    answer = answer:lower():gsub("%s", "")

    if pages > 1 and (answer == "n" or answer == "next") then
      page = page % pages + 1
    elseif pages > 1 and (answer == "p" or answer == "prev" or answer == "previous") then
      page = (page - 2) % pages + 1
    else
      local index = tonumber(answer)
      if index and choices[index] then return choices[index] end
      if manifest.roles[answer] then return answer end
      bad(fit("Not a role: " .. tostring(answer)))
      sleep(1.2)
    end
  end
end

-- ---------------------------------------------------------------- dashboard drawing
--
-- Every function below is fed only a rect and the already-prepared ctx/ui state -- no fs, no
-- http, no engine calls. The one exception is the terminal itself: these functions are the
-- screen output, so writing to `term`/`paintutils` is the point, not a violation of "no IO".
--
-- Borders are deliberately plain ASCII ("." "'" "-" "|"), not box-drawing Unicode: CC:Tweaked's
-- built-in font is its own small glyph set, not a real Unicode font, and CraftOS-PC's dev-time
-- font does not reliably match it -- a border that looks right here could still be mangled on
-- real hardware. "." and "'" for the corners is the "pseudo-rounded" look the design calls for
-- while staying inside plain, portable ASCII.

local function fillRect(rect, bg)
  if rect.w <= 0 or rect.h <= 0 then return end
  if paintutils and paintutils.drawFilledBox then
    paintutils.drawFilledBox(rect.x, rect.y, rect.x + rect.w - 1, rect.y + rect.h - 1, bg)
    return
  end
  term.setBackgroundColour(bg)
  for row = rect.y, rect.y + rect.h - 1 do
    term.setCursorPos(rect.x, row)
    term.write((" "):rep(rect.w))
  end
end

local function drawBorder(rect, border, bg)
  if rect.w < 3 or rect.h < 3 then return end
  term.setBackgroundColour(bg)
  term.setTextColour(border)
  local x2, y2 = rect.x + rect.w - 1, rect.y + rect.h - 1
  term.setCursorPos(rect.x, rect.y)
  term.write("." .. ("-"):rep(rect.w - 2) .. ".")
  for row = rect.y + 1, y2 - 1 do
    term.setCursorPos(rect.x, row); term.write("|")
    term.setCursorPos(x2, row); term.write("|")
  end
  term.setCursorPos(rect.x, y2)
  term.write("'" .. ("-"):rep(rect.w - 2) .. "'")
end

--- The writable area inside a bordered panel. Panels too small for a border (some panels can be
--- 1-2 rows tall on a cramped terminal) just use the whole rect as content.
local function inset(rect)
  if rect.w < 3 or rect.h < 3 then return rect end
  return { x = rect.x + 1, y = rect.y + 1, w = rect.w - 2, h = rect.h - 2 }
end

local function putLine(x, y, text, fg, bg, maxW)
  term.setCursorPos(x, y)
  term.setBackgroundColour(bg)
  term.setTextColour(fg)
  text = tostring(text)
  if maxW and maxW >= 0 and #text > maxW then text = text:sub(1, maxW) end
  term.write(text)
end

local function drawPanel(rect, title, bg, border)
  fillRect(rect, bg)
  drawBorder(rect, border, bg)
  if title and rect.w >= #title + 6 then
    putLine(rect.x + 2, rect.y, " " .. title .. " ", border, bg, rect.w - 4)
  end
end

local PANEL_BG, BORDER, LOG_BG = colours.black, colours.lightGrey, colours.black

local function drawTitle(rect, ctx)
  fillRect(rect, colours.blue)
  putLine(rect.x, rect.y,
    ("EasyHover 2 Suite -- %s (%s)"):format(ctx.role, ctx.spec.title or ctx.role),
    colours.white, colours.blue, rect.w)
end

local function drawStatus(rect, ctx)
  drawPanel(rect, "status", PANEL_BG, BORDER)
  local c = inset(rect)
  local lines = {
    { text = ("role       %s"):format(ctx.role), fg = colours.white },
    { text = ("installed  %s"):format(ctx.state.version or "none"), fg = colours.white },
    { text = ("release    %s"):format(ctx.manifest.version), fg = colours.white },
    { text = ("plan       %s"):format(ctx.plan), fg = Suite.statusColour(ctx.plan) },
    { text = ("source     %s"):format(ctx.base), fg = colours.lightGrey },
  }
  for i = 1, math.min(#lines, c.h) do
    putLine(c.x, c.y + i - 1, lines[i].text, lines[i].fg, PANEL_BG, c.w)
  end
end

local function drawIntegrity(rect, ctx)
  drawPanel(rect, "integrity", PANEL_BG, BORDER)
  local c = inset(rect)
  if c.h < 1 then return end
  local report = ctx.report
  local ok = math.max(0, report.total - #report.missing - #report.corrupt)
  local barWidth = math.max(1, c.w - 2)
  local filled = Suite.progressFill(ok, report.total, barWidth)
  local bar = "[" .. ("#"):rep(filled) .. ("-"):rep(barWidth - filled) .. "]"
  putLine(c.x, c.y, bar, colours.lime, PANEL_BG, c.w)
  if c.h >= 2 then
    putLine(c.x, c.y + 1, ("%d ok / %d missing / %d %s"):format(ok, #report.missing,
      #report.corrupt, Suite.diffLabel(ctx.plan)), colours.white, PANEL_BG, c.w)
  end
end

local function drawActions(rect, buttons)
  fillRect(rect, colours.grey)
  for _, b in ipairs(buttons) do
    local text = (b.key == "__prev" and "<") or (b.key == "__next" and ">") or ("[" .. b.label .. "]")
    putLine(b.x, b.y, text, colours.white, colours.grey, b.w)
  end
end

--- lines: array of { text =, colour = }.
local function drawDiag(rect, title, lines)
  drawPanel(rect, title, LOG_BG, BORDER)
  local c = inset(rect)
  for i = 1, math.min(#lines, c.h) do
    local ln = lines[i]
    putLine(c.x, c.y + i - 1, ln.text, ln.colour or colours.lightGrey, LOG_BG, c.w)
  end
end

--- Draws the whole dashboard from ctx (role/versions/report/plan/source) and `ui` (the small
--- bit of view state runUI owns: mode, log, action page, pending tool). Returns the full set of
--- clickable rects for THIS frame, already positioned in screen coordinates, so runUI only ever
--- needs one Suite.hitTestButtons call against whatever this returns.
function Suite.drawDashboard(ctx, ui)
  local w, h = term.getSize()
  local panels = Suite.uiPanels(w, h)

  term.setBackgroundColour(colours.black)
  term.clear()

  drawTitle(panels.title, ctx)
  drawStatus(panels.status, ctx)
  drawIntegrity(panels.integrity, ctx)

  local layout = Suite.actionButtons(panels.actions, Suite.actionSpec(ctx), ui.actionPage)
  ui.actionPage = layout.page
  drawActions(panels.actions, layout.buttons)

  local hitAreas = {}
  for _, b in ipairs(layout.buttons) do hitAreas[#hitAreas + 1] = b end

  if ui.mode == "tools" then
    local names = Suite.diagTools(ctx.spec)
    local items, lines = {}, {}
    for _, name in ipairs(names) do
      items[#items + 1] = { key = name, label = name }
      lines[#lines + 1] = { text = name, colour = colours.white }
    end
    if #items == 0 then lines[1] = { text = "(no shipped tools)", colour = colours.lightGrey } end
    drawDiag(panels.diag, "launch tool", lines)
    local rows = Suite.listRows(inset(panels.diag), items)
    for _, r in ipairs(rows) do hitAreas[#hitAreas + 1] = r end
  elseif ui.mode == "confirm" then
    local c = inset(panels.diag)
    drawDiag(panels.diag, "confirm", {
      { text = "Launch '" .. tostring(ui.pendingTool) .. "'?", colour = colours.yellow },
    })
    if c.h >= 2 then
      local confirmRow = { x = c.x, y = c.y + 1, w = c.w, h = 1 }
      local confirmLayout = Suite.actionButtons(confirmRow,
        { { key = "__yes", label = "Yes" }, { key = "__no", label = "No" } }, 1)
      drawActions(confirmRow, confirmLayout.buttons)
      for _, b in ipairs(confirmLayout.buttons) do hitAreas[#hitAreas + 1] = b end
    end
  else
    drawDiag(panels.diag, "diagnostics", ui.log)
  end

  term.setCursorPos(1, 1)
  return { hitAreas = hitAreas }
end

-- ---------------------------------------------------------------- event loop

--- Keys the action row / confirm row can produce -- everything else, while a tool list is
--- showing, is a tool name picked off Suite.diagTools instead.
local RESERVED_KEYS = {
  go = true, verify = true, repair = true, switch = true, tools = true, quit = true,
  __prev = true, __next = true, __yes = true, __no = true,
}

--- The graphical dashboard for an advanced (colour) terminal. `ctx` is exactly what
--- Suite.main has already computed: role, spec, state, manifest, the integrity report, the
--- plan, and the source base URL. Every action here calls the SAME engine functions the v1
--- keyboard flow uses (Suite.performPlan, Suite.integrity, Suite.choosePlan, Suite.clearRole,
--- Suite.askForRole) -- runUI only adds hit-testing and redraw on top.
function Suite.runUI(ctx)
  local ui = { mode = "dashboard", log = {}, actionPage = 1, pendingTool = nil }

  local function pushLog(text, col)
    ui.log[#ui.log + 1] = { text = text, colour = col or colours.lightGrey }
  end

  --- Re-derive report/plan/fresh/schemaBump from the CURRENT ctx.spec/state/role -- the same
  --- computation Suite.main does before ever calling runUI, so Verify/Switch/after-Go all see
  --- the install exactly as choosePlan would score it fresh.
  local function recompute()
    ctx.switching = (ctx.state.role ~= nil and ctx.state.role ~= ctx.role)
    local sameVersion = (ctx.state.version == ctx.manifest.version) and not ctx.switching
    local report
    if ctx.fastPath and sameVersion then
      report = { ok = true, missing = {}, corrupt = {}, present = #ctx.spec.files,
        total = #ctx.spec.files }
    else
      report = Suite.integrity(ctx.spec)
    end
    ctx.report = report
    local anyInstall = report.present > 0
    ctx.fresh = not anyInstall
    ctx.plan = Suite.choosePlan({
      anyInstall = anyInstall, mismatched = not report.ok, sameVersion = sameVersion,
      noRecord = (ctx.state.version == nil), forceRepair = false,
    })
    ctx.schemaBump = (ctx.state.schema ~= nil and (ctx.manifest.schema or 1) > (ctx.state.schema or 0))
  end

  --- Runs Suite.performPlan (the SAME engine the keyboard flow calls) for the given plan. Its
  --- progress text scrolls the real terminal -- the dashboard is redrawn once it returns -- so
  --- the next event is swallowed here rather than acted on, giving the operator a moment to
  --- read the summary before the screen clears back to the dashboard.
  ---
  --- Wrapped in pcall: performPlan's die() throws on a failed fetch (network blip, corrupt
  --- download), which is fine for the one-shot keyboard flow -- the process was about to exit
  --- anyway -- but would otherwise take the whole dashboard session down with it. die() already
  --- printed the red reason before throwing; this just keeps the UI alive to show it and retry.
  local function runPlan(plan)
    term.setBackgroundColour(colours.black)
    term.clear()
    term.setCursorPos(1, 1)
    local ok = pcall(Suite.performPlan, ctx.base, ctx.manifest, ctx.spec, ctx.role, plan, ctx.fresh)
    if ok and ctx.channel and Suite.shouldPersistChannel(false, false, true) then
      writeRaw(CHANNEL_FILE, ctx.channel .. "\n")
    end
    ctx.state = Suite.parseState(readFile(STATE_FILE))
    recompute()
    if not ok then
      colour(colours.white)
      pushLog("action failed -- see message above", colours.red)
    end
    print("")
    dim("click or press any key to return to the dashboard...")
    os.pullEvent()
  end

  local hitAreas = Suite.drawDashboard(ctx, ui).hitAreas
  while true do
    local ev, _, mx, my = os.pullEvent()
    if ev == "mouse_click" then
      local key = Suite.hitTestButtons(hitAreas, mx, my)
      if key == "__prev" then
        ui.actionPage = math.max(1, ui.actionPage - 1)
      elseif key == "__next" then
        ui.actionPage = ui.actionPage + 1
      elseif ui.mode == "confirm" and key == "__yes" then
        local tool = ui.pendingTool
        ui.mode, ui.pendingTool = "dashboard", nil
        if tool then
          term.setBackgroundColour(colours.black)
          term.clear()
          term.setCursorPos(1, 1)
          local ok, err = pcall(shell.run, tool)
          if not ok then pushLog("tool error: " .. tostring(err), colours.red) end
          print("")
          dim("click or press any key to return to the dashboard...")
          os.pullEvent()
        end
      elseif ui.mode == "confirm" then
        ui.mode, ui.pendingTool = "dashboard", nil -- any other click cancels
      elseif ui.mode == "tools" and key and not RESERVED_KEYS[key] then
        ui.pendingTool, ui.mode = key, "confirm"
      elseif ui.mode == "tools" and key == nil then
        ui.mode = "dashboard" -- click away cancels
      elseif key == "go" then
        -- Safe no-op when already current: nothing to install/update/repair, so do not touch
        -- the engine. (Suite.actionSpec already folds the Go button away when current, so this
        -- only fires if a click somehow lands on it.)
        if ctx.plan == "current" then
          pushLog("already current: " .. ctx.manifest.version, colours.lime)
        else
          runPlan(ctx.plan)
        end
      elseif key == "verify" then
        recompute()
        pushLog("verified: " .. ctx.plan, colours.white)
      elseif key == "repair" then
        runPlan("repair")
      elseif key == "switch" then
        local newRole = Suite.askForRole(ctx.manifest, ctx.order)
        if newRole and newRole ~= ctx.role then
          local newSpec = ctx.manifest.roles[newRole]
          -- Same reserved-role guard the keyboard flow applies: a reserved/fileless role must
          -- not become the active spec, or recompute() -> Suite.integrity(spec) crashes on
          -- #spec.files. Stay on the current role and report why.
          if not Suite.isReleased(newSpec) then
            pushLog(("role %s is reserved -- ships no files yet"):format(newRole), colours.orange)
          else
            ctx.role, ctx.spec = newRole, newSpec
            recompute()
            pushLog("switched to role " .. newRole, colours.yellow)
          end
        end
      elseif key == "tools" then
        ui.mode = "tools"
      elseif key == "quit" then
        return true
      end
    elseif ev == "term_resize" then
      -- no-op: the next redraw below re-reads term.getSize()
    end
    hitAreas = Suite.drawDashboard(ctx, ui).hitAreas
  end
end

-- ---------------------------------------------------------------- main

--- Is this role installable, or a reserved-but-unshipped design placeholder?
---
--- Shared by the keyboard flow's reserved-role guard and the dashboard's Switch handler so both
--- refuse a reserved role identically. A reserved/fileless spec would otherwise crash
--- Suite.integrity (#spec.files / ipairs(spec.files)) the moment one exists -- unreachable with
--- today's two released roles, but the guard is what keeps a planned future role (e.g. NAV) safe.
--- Pure: reads only spec.status.
function Suite.isReleased(spec)
  return type(spec) == "table" and spec.status == "released"
end

function Suite.main(args)
  args = args or {}
  local opts = Suite.parseArgs(args)
  local wantRole, checkOnly, forceRepair, listOnly, fastPath =
    opts.wantRole, opts.checkOnly, opts.forceRepair, opts.listOnly, opts.fastPath
  local wantChannel = opts.wantChannel
  local noUI = opts.noUI   -- --yes/--go: force the non-interactive install even on a colour terminal

  if opts.help then
    say("EasyHover 2 Suite", colours.cyan)
    dim("  easyhover2_suite.lua              install or update, as appropriate")
    dim("  easyhover2_suite.lua --check      report what would change, write nothing")
    dim("  easyhover2_suite.lua --repair     clear the role's files and reinstall")
    dim("  easyhover2_suite.lua --fast       trust the version stamp, skip checksums")
    dim("  easyhover2_suite.lua --list       list every role")
    dim("  easyhover2_suite.lua --flag-defaults  snapshot current configs as DEFAULT (backup first)")
    dim("  easyhover2_suite.lua --migrate-config split leftover eh2_hw_config.tbl into current files")
    dim("  easyhover2_suite.lua --yes        install non-interactively (no dashboard; for remote/unattended installs)")
    dim("  easyhover2_suite.lua <role>       install or switch to a role")
    dim("  easyhover2_suite.lua --dev        install the readable (un-minified) channel")
    dim("  easyhover2_suite.lua --min        force back to the minified channel (default)")
    print("")
    dim("Source override: put a base URL in " .. SOURCE_FILE)
    dim("Private repo:    put a GitHub token in " .. TOKEN_FILE)
    dim("Hardware config: /eh2_hw_config.tbl")
    return true
  end

  -- --flag-defaults / --migrate-config are local ops on an installed computer. --check/--list
  -- still win (never write, never skip the list). When a role is already known from argv or
  -- the install record, skip the fetch/install path entirely.
  local wantConfigOp = (opts.flagDefaults or opts.migrateConfig)
    and not checkOnly and not listOnly
  if wantConfigOp then
    local state = Suite.parseState(readFile(STATE_FILE))
    local role = wantRole or state.role
    if role then
      return Suite.runConfigFlags(opts, role)
    end
  end

  -- ---- where to fetch from
  local base = readFile(SOURCE_FILE)
  base = base and base:gsub("%s+$", ""):gsub("/+$", "") or nil
  if base == "" then base = nil end
  base = base or DEFAULT_BASE

  token = readFile(TOKEN_FILE)
  token = token and token:gsub("%s+$", "") or nil
  if token == "" then token = nil end

  say("EasyHover 2 Suite", colours.cyan)
  dim("source: " .. base .. (token and "  (token)" or ""))
  print("")

  if not http then
    die("The http API is disabled on this server, so nothing can be fetched.\n"
      .. "Ask the server owner to enable http, or install from a floppy disk.")
  end

  -- ---- release channel: minified (default) or readable source (--dev)
  local channel = Suite.resolveChannel(wantChannel, readFile(CHANNEL_FILE))
  local manifestFile = Suite.manifestName(channel)
  dim("channel: " .. channel .. (wantChannel and " (from flag)" or ""))

  -- ---- the release manifest
  local body, err = fetch(base .. "/" .. manifestFile)
  if not body then
    bad("could not reach the release manifest (" .. manifestFile .. "): " .. tostring(err))
    print("")
    dim("If the repository is private, raw.githubusercontent.com returns 404 without a")
    dim("token. Put one in " .. TOKEN_FILE .. ", or make the repository public.")
    die("nothing was changed.")
  end

  -- Parsed as DATA, not run as code: unserialise evaluates a table constructor in an empty
  -- environment, so the manifest cannot do anything but describe files.
  local manifest = textutils.unserialise(body)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
    die("the release manifest (" .. manifestFile .. ") is not readable (is the source URL right?)")
  end

  local order = {}
  for name in pairs(manifest.roles) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    local ra, rb = manifest.roles[a], manifest.roles[b]
    local sa = (ra.status == "released") and 0 or 1
    local sb = (rb.status == "released") and 0 or 1
    if sa ~= sb then return sa < sb end
    return a < b
  end)

  if listOnly then
    say(("release %s, schema %d"):format(manifest.version, manifest.schema or 1))
    print("")
    for _, name in ipairs(order) do
      local spec = manifest.roles[name]
      local tag = (spec.status == "released")
        and ("%d file(s)"):format(#spec.files) or "not released yet"
      say(("  %-9s %-26s %s"):format(name, spec.title or "", tag),
        spec.status == "released" and colours.white or colours.lightGrey)
    end
    colour(colours.white)
    return true
  end

  -- ---- what is installed here
  local state = Suite.parseState(readFile(STATE_FILE))
  local detected = Suite.detectRole(manifest)

  local role = wantRole or state.role or detected
  if wantConfigOp then
    -- detectRole filled in a missing install record; still do not install.
    return Suite.runConfigFlags(opts, role)
  end
  if role and not manifest.roles[role] then
    die("no such role: " .. tostring(role) .. "  (try --list)")
  end

  if not role then
    role = Suite.askForRole(manifest, order)
    if not role then
      warn("Cancelled. Nothing was changed.")
      return false
    end
  end

  local spec = manifest.roles[role]

  if not Suite.isReleased(spec) then
    warn(("The '%s' role (%s) is reserved in the design but ships no files yet.")
      :format(role, spec.title or role))
    dim("Nothing was installed. Re-run the Suite once it is released.")
    dim("Its config will be at: " .. table.concat(spec.configs or {}, ", "))
    return false
  end

  say(("role %s  (%s)"):format(role, spec.title or role))
  if state.role and state.role ~= role then
    warn(("switching role: %s -> %s"):format(state.role, role))
  end
  if not state.role and detected then
    dim(("no install record; detected role '%s' from files on disk"):format(detected))
  end
  dim(("installed %s -> release %s"):format(state.version or "unknown", manifest.version))

  -- ---- integrity
  local switching = (state.role ~= nil and state.role ~= role)
  local sameVersion = (state.version == manifest.version) and not switching

  -- ALWAYS checksum, unless explicitly asked not to.
  --
  -- A version stamp says "these files were correct when they were written". It cannot know
  -- that one has since been truncated by a chunk unload, hand-edited, or half-overwritten.
  -- Detecting exactly that is a core job of this tool, so trusting the stamp by default would
  -- defeat the point -- and the cost is reading a few hundred KB locally, with no network.
  -- `--fast` exists for anyone who wants the old behaviour.
  local report
  if fastPath and sameVersion then
    report = { ok = true, missing = {}, corrupt = {}, present = #spec.files, total = #spec.files }
    dim("--fast: version matches, checksums skipped")
  else
    report = Suite.integrity(spec)
    if report.ok and sameVersion then dim("all " .. report.total .. " file(s) verified") end
  end

  local anyInstall = (report.present > 0)
  local fresh = not anyInstall
  local mismatched = not report.ok
  local noRecord = (state.version == nil)
  local corrupt = anyInstall and ((sameVersion and mismatched) or noRecord)
  local plan = Suite.choosePlan({
    anyInstall = anyInstall, mismatched = mismatched,
    sameVersion = sameVersion, noRecord = noRecord, forceRepair = forceRepair,
  })

  print("")
  if plan == "install" then
    good("Fresh install.")
  elseif plan == "repair" then
    if noRecord then
      bad("Broken install: files are here but nothing records what they are.")
    else
      bad(("Broken install: version %s says these files are correct, but %d missing "
        .. "and %d differ of %d."):format(tostring(state.version), #report.missing,
        #report.corrupt, report.total))
    end
    for _, name in ipairs(report.missing) do dim("  missing  " .. name) end
    for _, name in ipairs(report.corrupt) do dim("  corrupt  " .. name) end
    say("Repairing: the role's own files will be cleared and reinstalled.")
    say("Configs are backed up first and never deleted.", colours.lime)
  elseif plan == "current" then
    good("Already current: " .. manifest.version)
  else
    say(("Update available: %s -> %s"):format(state.version or "unknown", manifest.version))
    dim(("%d new, %d changed, %d unchanged"):format(#report.missing, #report.corrupt,
      report.total - #report.missing - #report.corrupt))
  end

  local schemaBump = (state.schema ~= nil and (manifest.schema or 1) > state.schema)
  if schemaBump then
    warn(("Config schema %d -> %d: saved configs will be backed up before anything changes.")
      :format(state.schema, manifest.schema or 1))
  end

  -- ---- dry run stops here
  if checkOnly then
    print("")
    if plan == "current" then
      dim("Nothing to do.")
    else
      say(("Would %s role '%s': %d file(s)."):format(plan, role, #spec.files))
      local cleared = (plan == "repair") and Suite.clearRole(spec, true) or {}
      for _, path in ipairs(cleared) do dim("  would clear  " .. path) end
      for _, cfgPath in ipairs(spec.configs or {}) do
        if fs.exists(cfgPath) then dim("  would back up and extend  " .. cfgPath) end
      end
    end
    dim("--check: nothing was written.")
    colour(colours.white)
    return true
  end

  -- ---- advanced (colour) terminals get the graphical dashboard; everything else -- basic
  -- computers, and --check/--list, which already returned above -- keeps the v1 text flow.
  -- Both paths call Suite.performPlan, the same engine, so neither can drift from the other.
  --
  -- "current" is deliberately NOT an early return here for advanced terminals: an up-to-date
  -- computer still opens the dashboard so its Switch / Launch-tool / Quit affordances stay
  -- reachable in the common steady state. Its "Go" button is folded away (Suite.actionSpec) and
  -- guarded to a no-op in runUI, so no install runs. Suite.performPlan is what normally fires the
  -- self-staleness check at its end; a current dashboard never calls it, so run that check here
  -- first -- ONLY when current, so an update/install/repair still gets its single check inside
  -- performPlan and it is never run twice.
  -- --yes/--go forces the non-interactive text install even on a colour terminal: an unattended
  -- remote install (a beacon reinstalling itself over the air) must never block in the graphical
  -- dashboard waiting for a human "Go" click. Basic computers already take the text path.
  local advanced = term.isColour and term.isColour()
  if advanced and not checkOnly and not listOnly and not noUI then
    if plan == "current" then Suite.selfUpdateNotice(base, manifest) end
    return Suite.runUI({
      base = base, manifest = manifest, order = order,
      role = role, spec = spec, state = state,
      plan = plan, report = report, fresh = fresh,
      switching = switching, schemaBump = schemaBump, fastPath = fastPath,
      channel = channel,
    })
  end

  -- Non-advanced (basic terminal): a current install has nothing to do but check whether the
  -- Suite itself is stale, then it is done. Byte-for-byte the pre-existing behaviour.
  if plan == "current" then
    Suite.selfUpdateNotice(base, manifest)
    colour(colours.white)
    return true
  end

  local ok = Suite.performPlan(base, manifest, spec, role, plan, fresh)
  if ok and Suite.shouldPersistChannel(false, false, true) then
    writeRaw(CHANNEL_FILE, channel .. "\n")
  end
  return ok
end

--- Is the Suite itself current? If not, fetch the new one now -- we are done with our own file
--- by this point, so replacing it is safe, and the next run uses it.
function Suite.selfUpdateNotice(base, manifest)
  if type(manifest.updater) ~= "table" then return end
  -- `shell` is a program-scoped API in CC:Tweaked; guard it so the engine never hard-crashes when
  -- loaded in an environment without it (there's no running-program file to self-update anyway).
  if type(shell) ~= "table" or type(shell.getRunningProgram) ~= "function" then return end
  local ok, selfPath = pcall(shell.getRunningProgram)
  if not ok then return end
  -- `wget run` executes transiently (no saved file of ours to update); only a real saved
  -- easyhover2_suite.lua should self-update. Otherwise we'd read the wrong file and falsely
  -- report the Suite out of date on every run.
  if not Suite.selfIsPersistent(selfPath) then return end
  if not selfPath:match("^/") then selfPath = "/" .. selfPath end

  local mine = readFile(selfPath)
  if mine == nil then return end
  if #mine == manifest.updater.size and Suite.checksum(mine) == manifest.updater.sum then
    return
  end

  -- Dim, not yellow. This is a routine step that then SUCCEEDS, and a warning colour at the
  -- very end of a clean install reads as "something is wrong" -- which is how it was reported.
  -- The warning colours below are for the cases that actually leave the Suite stale.
  print("")
  dim("The Suite itself is out of date; fetching the new one.")
  local body = fetch(base .. "/easyhover2_suite.lua")
  if not body then
    warn("could not fetch the new Suite. Update by hand with:")
    dim("  wget " .. base .. "/easyhover2_suite.lua easyhover2_suite.lua")
    return
  end
  if #body ~= manifest.updater.size or Suite.checksum(body) ~= manifest.updater.sum then
    -- The PUBLISHED Suite does not match the stamp in the PUBLISHED manifest, so the release
    -- is inconsistent -- nothing is wrong with this computer. Saying "arrived corrupt" pointed
    -- the blame the wrong way, and because the local copy can never match either, every single
    -- run repeated the whole dance. Name the real fault so it is fixable at the source.
    warn("release inconsistency: the published Suite does not match the manifest.")
    dim(("  manifest expects %d bytes / %s, the server sent %d / %s")
      :format(manifest.updater.size, tostring(manifest.updater.sum), #body,
        tostring(Suite.checksum(body))))
    dim("  the role's files are fine; regenerate the manifest at the source.")
    return
  end
  local stagePath = selfPath .. STAGE
  if writeRaw(stagePath, body) then
    if fs.exists(selfPath) then fs.delete(selfPath) end
    fs.move(stagePath, selfPath)
    good("Suite updated. The next run uses the new one.")
  end
end

-- Engine surface: exposed so SuiteX front-ends can reuse the Suite's installation engine.
Suite.fetch = fetch
Suite.writeRelease = writeRelease   -- guarded release write, reused by SuiteX's standalone tool install
Suite.readFile = readFile
Suite.STATE_FILE = STATE_FILE
Suite.CHANNEL_FILE = CHANNEL_FILE
Suite.base = DEFAULT_BASE
function Suite.checkFile(entry, read)
  local body = read(entry.dst)
  if body == nil then return "missing" end
  if #body ~= entry.size or Suite.checksum(body) ~= entry.sum then return "corrupt" end
  return "ok"
end

-- Exposed so tests can exercise the pure logic without running an install.
if not _G.EH2_SUITE_NO_RUN then
  Suite.main({ ... })
end

return Suite
