-- ui/basalt/bitconfig/dtc.lua
-- DTC (Data Cartridge) sub-menu (BIT/CONFIG hub, screen id "dtc"): the disk courier. Copies the
-- three split config files (eh2_devbind.tbl / eh2_senscal.tbl / eh2_tuning.tbl) between the UI
-- PC's local storage and a networked disk drive's disk, so config assembled here can be carried
-- to the FCS PC's boot loader -- which reads a config file's "disk" source from
-- /<mount>/<cfgspec.FILES[kind]> (see fcs/boot/loaderui.lua's diskSource, lines ~98-110). This
-- module's diskPath() MUST resolve to EXACTLY that path (a path-layout test in
-- tests/test_bitconfig_dtc.lua enforces the match) or an exported cartridge would be invisible
-- to the boot loader.
--
-- Follows the Task 21/22 template (see ui/basalt/bitconfig/tuning.lua's header for the full
-- Basalt API provenance notes): module exports `M.id`, `M.title`, a Basalt-free PURE view-model
-- (M.KINDS / M.plan), Basalt-free path helpers (M.localPath / M.diskPath) and disk-IO seams
-- (M._detect / M._scan / M._export / M._import, all deps-injected so tests never touch a real
-- peripheral or fs), and `M.build(basalt, frame, runtime, nav, deps) -> { id, apply(state),
-- elements }`. Unlike MDB/TUNING/SENS CAL, this menu has no read/write/delete triple -- it needs
-- a `find` (peripheral.find) alongside fs exists/read/write/delete/move, so those six seams are
-- bundled into one injectable `deps` table instead of positional args.
--
-- apply(state): this menu shows disk-courier status, not live telemetry -- no-op/idempotent (the
-- REFRESH button is the only thing that re-detects the drive/re-scans files; apply() never polls
-- peripherals on its own, matching the "UI subordinate to FCS" cadence rule).
--
-- NO peripheral/Basalt access at module LOAD -- everything lives inside M.build/the closures it
-- returns, so `require("ui.basalt.bitconfig.dtc")` loads clean headless.

local cfgspec = require("fcs.io.cfgspec")
local cfgroles = require("fcs.io.cfgroles")
local fsx = require("fcs.io.fsx")
local configkit = require("ui.basalt.configkit")
local Region = require("ui.basalt.region")

local M = {}
M.id = "dtc"
M.title = "DTC"

-- ===== M.KINDS: canonical ordered kind registry. The 3 FCS kinds' filenames resolve via =====
-- ===== cfgspec.FILES (M.FILE below) so they can never drift from the schema; "uicfg" is a 4th,
-- ===== FCS-opaque kind (the UI's own config) transported by this same disk courier. =====
M.KINDS = { "devbind", "senscal", "tuning", "uicfg" }

function M.roleKinds(role)
  return cfgroles.kinds(role)
end

local function kindsFor(role)
  return (role and cfgroles.kinds(role)) or M.KINDS
end

local function isFcsKind(kind)
  return cfgroles.roleOf(kind) == "fcs"
end

-- ===== M.FILE: kind -> filename. FCS kinds MUST equal cfgspec.FILES[kind] byte-for-byte =====
-- ===== (fcs/boot/loaderui.lua's diskSource reads that same path) -- never hardcode those.
-- Path helpers resolve via cfgroles.file so fuelcal/nav/nav_wpt cannot drift from the registry.
M.FILE = {
  devbind = cfgspec.FILES.devbind,
  senscal = cfgspec.FILES.senscal,
  tuning = cfgspec.FILES.tuning,
  fuelcal = cfgspec.FILES.fuelcal,
  uicfg = "eh2_ui_config.tbl",
  nav = cfgroles.file("nav"),
  nav_wpt = cfgroles.file("nav_wpt"),
}

-- ===== M.LABEL: kind -> human-readable menu label. =====
M.LABEL = {
  devbind = "Craft bindings",
  senscal = "Sensor cal",
  tuning = "FCS tuning",
  fuelcal = "Fuel cal",
  uicfg = "UI config",
  nav = "NAV config",
  nav_wpt = "NAV waypoints",
}

-- ===== M.validateKind(kind, t) -> bool. FCS kinds (devbind/senscal/tuning) delegate to =====
-- ===== cfgspec.validate (coerced to a plain bool -- cfgspec.validate returns (ok, err)). "uicfg"
-- ===== has no schema of its own here: any table is a valid UI config shape (ui.config.withDefaults
-- ===== merges it against defaults), so validation is just a table-shape check. nil/non-table t,
-- ===== or an unknown kind, is always false.
function M.validateKind(kind, t)
  if isFcsKind(kind) then
    return cfgspec.validate(kind, t) == true
  end
  if kind == "uicfg" then
    return type(t) == "table"
  end
  if kind == "nav" then
    return type(t) == "table"
  end
  if kind == "nav_wpt" then
    return type(t) == "table" and type(t.waypoints) == "table"
  end
  return false
end

-- ===== M.plan(present) -> ordered per-kind rows. PURE, no IO. =====
-- present = { localHas = {kind=bool,...}, diskHas = {kind=bool,...} } (missing entries read as
-- false/absent). Returns an array (1..#M.KINDS) of
-- { kind, filename, hasLocal, hasDisk, canExport = hasLocal, canImport = hasDisk }, PLUS two
-- convenience fields on the same table: .exportable = {kinds where hasLocal} and
-- .importable = {kinds where hasDisk}, both in M.KINDS order.
function M.plan(present, role)
  present = present or {}
  local localHas = present.localHas or {}
  local diskHas = present.diskHas or {}
  local kinds = kindsFor(role)

  local rows = { exportable = {}, importable = {} }
  for i, kind in ipairs(kinds) do
    local hasLocal = localHas[kind] == true
    local hasDisk = diskHas[kind] == true
    rows[i] = {
      kind = kind,
      filename = cfgroles.file(kind) or M.FILE[kind],
      hasLocal = hasLocal,
      hasDisk = hasDisk,
      canExport = hasLocal,
      canImport = hasDisk,
    }
    if hasLocal then rows.exportable[#rows.exportable + 1] = kind end
    if hasDisk then rows.importable[#rows.importable + 1] = kind end
  end
  return rows
end

-- ===== M.fmtTime(msEpoch) -> string: format ms epoch timestamp or "--". PURE. =====
function M.fmtTime(msEpoch)
  if msEpoch == nil then return "--" end
  return os.date("%Y-%m-%d %H:%M", math.floor(msEpoch / 1000))
end

-- ===== M.row(kind, info) -> row table with local-vs-disk relation. PURE. =====
-- info = { localHas, localMs, diskHas, diskMs, diskValid }
-- Returns { kind, label, localHas, localMs, diskHas, diskMs, diskValid, rel } where
-- rel ∈ "newer"|"older"|"same"|"local-only"|"disk-only"|"none"
function M.row(kind, info)
  info = info or {}

  -- Compute the relation comparing local vs disk mtime
  local rel
  if info.localHas and info.diskHas then
    -- Both present: compare timestamps (treat missing ms as 0)
    local localMs = info.localMs or 0
    local diskMs = info.diskMs or 0
    if localMs > diskMs then
      rel = "newer"
    elseif localMs < diskMs then
      rel = "older"
    else
      rel = "same"
    end
  elseif info.localHas then
    rel = "local-only"
  elseif info.diskHas then
    rel = "disk-only"
  else
    rel = "none"
  end

  return {
    kind = kind,
    label = M.LABEL[kind],
    localHas = info.localHas,
    localMs = info.localMs,
    diskHas = info.diskHas,
    diskMs = info.diskMs,
    diskValid = info.diskValid,
    rel = rel,
  }
end

-- ===== Path helpers: PURE, Basalt/fs-free. diskPath MUST match fcs/boot/loaderui.lua's =====
-- ===== diskSource byte-for-byte for the 3 FCS kinds: realRead("/" .. mount .. "/" ..
-- ===== cfgspec.FILES[kind]) -- M.FILE[kind] equals cfgspec.FILES[kind] for those three, so this
-- ===== holds unchanged; "uicfg" resolves the same way but the FCS boot loader never reads it.
function M.localPath(kind)
  return "/" .. cfgroles.file(kind)
end

function M.diskPath(mount, kind)
  return "/" .. mount .. "/" .. cfgroles.file(kind)
end

-- ===== real fs/peripheral seams (default injected deps; never called at module load) =====

-- realRead/realDelete/realExists delegate to fcs/io/fsx.lua's shared helper. realWriteFile stays
-- a PLAIN (non-atomic) write -- atomicCopy below already implements its own generic tmp-then-move
-- dance over local<->disk paths via deps.write/exists/delete/move, so this must write the exact
-- body to the exact path handed to it (including the tmp path atomicCopy constructs), not run a
-- second nested tmp+move of its own. realMove has no fsx equivalent (fsx exposes no M.move).
local realRead = fsx.read

local function realWriteFile(path, body)
  local f = fs.open(path, "w"); f.write(body); f.close()
end

local realDelete = fsx.delete

local function realMove(from, to)
  fs.move(from, to)
end

local realExists = fsx.exists

local function realFind(kind)
  return peripheral.find(kind)
end

-- realList(path) -> array of filenames in a dir (nil/absence-safe: missing/invalid path -> {}).
local function realList(path)
  if not path or not fs.exists(path) or not fs.isDir(path) then return {} end
  return fs.list(path)
end

-- realAttributes(path) -> {modified=...}|nil. CC:Tweaked's fs.attributes ERRORS on a nonexistent
-- path, so this guards with fs.exists first (unlike realRead/realExists's fsx delegates, which are
-- already nil-safe) rather than letting that propagate to callers expecting a plain nil.
local function realAttributes(path)
  if not fs.exists(path) then return nil end
  return fs.attributes(path)
end

-- realBackup(path): self-contained single-latest-per-file backup, copying `path` to
-- /easyhover2_backup/<name> (name = path with "/" -> "_", leading "/" stripped) -- mirrors
-- easyhover2_suite.lua's Suite.backupConfig, but the UI role does not ship that file at runtime,
-- so this is a standalone reimplementation using this module's own fs seams. Only backs up when
-- the source exists; overwrites (not appends to) any prior backup of the same name via
-- fsx.writeAtomic's tmp-then-delete-then-move dance.
local function realBackup(path)
  if not realExists(path) then return end
  if not fs.exists("/easyhover2_backup") then fs.makeDir("/easyhover2_backup") end
  local name = path:gsub("^/", ""):gsub("/", "_")
  local body = realRead(path)
  if body == nil then return end
  fsx.writeAtomic("/easyhover2_backup/" .. name, body)
end

local function resolveDeps(deps)
  deps = deps or {}
  return {
    find = deps.find or realFind,
    exists = deps.exists or realExists,
    read = deps.read or realRead,
    write = deps.write or realWriteFile,
    delete = deps.delete or realDelete,
    move = deps.move or realMove,
    attributes = deps.attributes or realAttributes,
    backup = deps.backup or realBackup,
    list = deps.list or realList,
    fcsGet = deps.fcsGet,
    fcsSet = deps.fcsSet,
  }
end

-- ===== M._detect(deps): drive presence/mount/label, gated on isDiskPresent(). =====
-- deps.find(kind) defaults to peripheral.find. Returns:
--   { present=bool, driveFound=bool, mount=<getMountPath() or nil>, label=<getDiskLabel() or
--     "unlabeled", or nil when no disk> }
-- present is true ONLY when a drive is found AND isDiskPresent() is true (mirrors
-- loaderui.diskIndicator's three-state "no disk drive" / "no disk inserted" / "disk: <label>").
function M._detect(deps)
  deps = deps or {}
  local find = deps.find or realFind
  local drive = find("drive")
  if not drive then
    return { present = false, driveFound = false, mount = nil, label = nil }
  end
  local hasDisk = drive.isDiskPresent and drive.isDiskPresent()
  if not hasDisk then
    return { present = false, driveFound = true, mount = nil, label = nil }
  end
  local mount = drive.getMountPath and drive.getMountPath()
  local label = (drive.getDiskLabel and drive.getDiskLabel()) or "unlabeled"
  return { present = true, driveFound = true, mount = mount, label = label }
end

-- ===== M._scan(mount, deps): which of the 3 files exist locally / on disk. =====
-- deps.exists(path) defaults to fs.exists. Returns { localHas = {kind=bool,...},
-- diskHas = {kind=bool,...} } -- feeds directly into M.plan. With mount == nil (no disk
-- mounted), diskHas is false for every kind regardless of exists().
function M._scan(mount, deps, role)
  deps = deps or {}
  local exists = deps.exists or realExists
  local localHas, diskHas = {}, {}
  for _, kind in ipairs(kindsFor(role)) do
    if isFcsKind(kind) and deps.fcsGet then
      localHas[kind] = deps.fcsGet(kind) ~= nil
    else
      localHas[kind] = exists(M.localPath(kind)) and true or false
    end
    diskHas[kind] = (mount ~= nil) and (exists(M.diskPath(mount, kind)) and true or false) or false
  end
  return { localHas = localHas, diskHas = diskHas }
end

-- M.FILE reverse lookup: filename -> kind (built once from M.FILE). EH2-named iff FILE_KIND[name].
local FILE_KIND = {}
for kind, name in pairs(M.FILE) do FILE_KIND[name] = kind end

-- ===== M._scanDisk(mount, deps) -> { valid={kinds…}, foreign={paths…}, invalid={paths…} }. =====
-- Classify every file on the disk: valid EH2 config (collect the KIND), invalid EH2-named file
-- (collect the PATH), or foreign (collect the PATH). mount == nil -> all empty. Feature 3 SCAN.
function M._scanDisk(mount, deps)
  deps = resolveDeps(deps)
  local out = { valid = {}, foreign = {}, invalid = {} }
  if mount == nil then return out end
  for _, name in ipairs(deps.list(mount) or {}) do
    local kind = FILE_KIND[name]
    local path = "/" .. mount .. "/" .. name
    if kind then
      local body = deps.read(path)
      local parsed = body and textutils.unserialise(body) or nil
      if M.validateKind(kind, parsed) then
        out.valid[#out.valid + 1] = kind
      else
        out.invalid[#out.invalid + 1] = path
      end
    else
      out.foreign[#out.foreign + 1] = path
    end
  end
  return out
end

-- ===== M._cleanDisk(mount, deps) -> { deleted={paths…} }: delete ONLY foreign+invalid (never a =====
-- ===== valid EH2 config). Set computed via M._scanDisk so scan and clean can never disagree.
function M._cleanDisk(mount, deps)
  deps = resolveDeps(deps)
  local deleted = {}
  if mount == nil then return { deleted = deleted } end
  local scan = M._scanDisk(mount, deps)
  for _, path in ipairs(scan.foreign) do deps.delete(path); deleted[#deleted + 1] = path end
  for _, path in ipairs(scan.invalid) do deps.delete(path); deleted[#deleted + 1] = path end
  return { deleted = deleted }
end

-- ===== M._scanSummary(scan) -> "valid N · foreign M · invalid K" (+ " · CLEAN ADVISED" when there =====
-- ===== is no valid EH2 config but foreign/invalid junk is present). PURE, display-only.
function M._scanSummary(scan)
  scan = scan or {}
  local nv = #(scan.valid or {})
  local nf = #(scan.foreign or {})
  local ni = #(scan.invalid or {})
  local s = "valid " .. nv .. " . foreign " .. nf .. " . invalid " .. ni
  if nv == 0 and (nf + ni) > 0 then s = s .. " . CLEAN ADVISED" end
  return s
end

-- Atomically copy `body` (already read from `from`) into `to` via deps.write/exists/delete/move:
-- write to `to..".tmp"`, delete an existing `to` if present, then move the tmp into place --
-- mirrors fcs/boot/loaderui.lua's realWrite / other bitconfig menus' realWrite exactly, just
-- generalised to any source/destination pair (local<->disk).
local function atomicWrite(to, body, deps)
  if body == nil then return false end
  local tmp = to .. ".tmp"
  deps.write(tmp, body)
  if deps.exists(to) then deps.delete(to) end
  deps.move(tmp, to)
  return true
end

local function atomicCopy(from, to, deps)
  return atomicWrite(to, deps.read(from), deps)
end

-- FCS kinds on the UI have no local files: live cache via fcsGet/fcsSet. Without those seams,
-- skip (do not atomicCopy to/from /eh2_devbind.tbl /eh2_senscal.tbl /eh2_tuning.tbl /eh2_fuelcal.tbl).
local function exportKind(mount, kind, deps, role)
  if isFcsKind(kind) then
    if deps.fcsGet then
      return atomicWrite(M.diskPath(mount, kind), deps.fcsGet(kind), deps)
    end
    return false
  end
  if role == "nav" and not deps.exists(M.localPath(kind)) then return false end
  return atomicCopy(M.localPath(kind), M.diskPath(mount, kind), deps)
end

local function importKind(mount, kind, deps, role)
  if isFcsKind(kind) then
    if deps.fcsSet then
      local diskPath = M.diskPath(mount, kind)
      if not deps.exists(diskPath) then return false end
      local body = deps.read(diskPath)
      if body == nil then return false end
      return deps.fcsSet(kind, body) and true or false
    end
    return false
  end
  if role == "nav" and not deps.exists(M.localPath(kind)) then return false end
  return atomicCopy(M.diskPath(mount, kind), M.localPath(kind), deps)
end

-- ===== M._export(mount, deps, role): local/live -> disk. role filters kinds (cfgroles). =====
-- Returns the ordered list of kinds actually exported. mount == nil (no disk) exports nothing.
function M._export(mount, deps, role)
  if mount == nil then return {} end
  deps = resolveDeps(deps)
  local exported = {}
  for _, kind in ipairs(kindsFor(role)) do
    if exportKind(mount, kind, deps, role) then
      exported[#exported + 1] = kind
    end
  end
  return exported
end

-- ===== M._import(mount, deps, role): disk -> local/live. role filters kinds (cfgroles). =====
-- Returns the ordered list of kinds actually imported. mount == nil (no disk) imports nothing.
function M._import(mount, deps, role)
  if mount == nil then return {} end
  deps = resolveDeps(deps)
  local imported = {}
  for _, kind in ipairs(kindsFor(role)) do
    if importKind(mount, kind, deps, role) then
      imported[#imported + 1] = kind
    end
  end
  return imported
end

-- ===== M._scanKind(mount, kind, deps): per-kind presence/mtime/disk-validity -- feeds the T12 =====
-- ===== per-row confirm-gating UI. Always resolveDeps(deps) first (a caller may hand in only a
-- subset of seams, e.g. just `exists`, and this must never crash on the missing rest). Returns
-- { localHas, localMs, diskHas, diskMs, diskValid }: localMs/diskMs come from
-- deps.attributes(path).modified (nil-safe: nil whenever the file or its attributes are absent).
-- diskValid = M.validateKind(kind, <unserialised disk body>), computed ONLY when the disk file
-- exists (nil body or a parse failure -> diskValid false, never an error). mount == nil treats the
-- disk side as entirely absent -- no disk exists/read/attributes calls are made at all.
function M._scanKind(mount, kind, deps)
  deps = resolveDeps(deps)

  local localPath = M.localPath(kind)
  local localHas, localMs = false, nil
  if isFcsKind(kind) and deps.fcsGet then
    localHas = deps.fcsGet(kind) ~= nil
  else
    localHas = deps.exists(localPath) and true or false
    if localHas then
      local attrs = deps.attributes(localPath)
      localMs = attrs and attrs.modified or nil
    end
  end

  local diskHas, diskMs, diskValid = false, nil, false
  if mount ~= nil then
    local diskPath = M.diskPath(mount, kind)
    diskHas = deps.exists(diskPath) and true or false
    if diskHas then
      local attrs = deps.attributes(diskPath)
      diskMs = attrs and attrs.modified or nil
      local body = deps.read(diskPath)
      local parsed = body and textutils.unserialise(body) or nil
      diskValid = M.validateKind(kind, parsed)
    end
  end

  return { localHas = localHas, localMs = localMs, diskHas = diskHas, diskMs = diskMs, diskValid = diskValid }
end

-- ===== M._exportKind(mount, kind, deps) -> ok: atomic local->disk copy of ONE kind. =====
-- mount == nil, or the local file absent, -> false (no-op); mirrors M._export's per-kind atomicCopy
-- call but for a single kind instead of looping M.KINDS.
function M._exportKind(mount, kind, deps)
  if mount == nil then return false end
  deps = resolveDeps(deps)
  return exportKind(mount, kind, deps, nil)
end

-- ===== M._importKind(mount, kind, deps) -> ok: backs up the local file (deps.backup) FIRST -- =====
-- ===== ONLY if it currently exists -- then atomic-copies disk->local for ONE kind. EXISTS-gated
-- only: unlike a possible reading of the brief, this does NOT validate the disk body before
-- importing (M._scanKind's diskValid is the surfaced validity signal; the T12 UI gates its confirm
-- on that, not on a silent refusal buried here). mount == nil, or the disk file absent, -> false
-- with no backup call and no copy.
function M._importKind(mount, kind, deps)
  if mount == nil then return false end
  deps = resolveDeps(deps)
  if isFcsKind(kind) then
    return importKind(mount, kind, deps, nil)
  end
  if cfgroles.roleOf(kind) == "nav" and not deps.exists(M.localPath(kind)) then
    return false
  end
  local diskPath = M.diskPath(mount, kind)
  if not deps.exists(diskPath) then return false end
  local localPath = M.localPath(kind)
  if deps.exists(localPath) then
    deps.backup(localPath)
  end
  return atomicCopy(diskPath, localPath, deps)
end

-- ===== M._importAll(mount, deps) -> { imported={kinds…}, skipped={kinds…} }: import every kind =====
-- ===== whose disk copy exists AND validates (reusing M._importKind's backup-then-copy); skip the
-- rest. M.KINDS order. mount == nil -> both empty. Feature 2's one-shot "IMPORT ALL".
function M._importAll(mount, deps)
  deps = resolveDeps(deps)
  local imported, skipped = {}, {}
  if mount == nil then return { imported = imported, skipped = skipped } end
  for _, kind in ipairs(M.KINDS) do
    local sk = M._scanKind(mount, kind, deps)
    if sk.diskHas and sk.diskValid and M._importKind(mount, kind, deps) then
      imported[#imported + 1] = kind
    else
      skipped[#skipped + 1] = kind
    end
  end
  return { imported = imported, skipped = skipped }
end

-- ===== M._confirmText(dir, kind) -> string: PURE per-row confirm question text (T12). =====
-- dir == "export" (UI PC -> disk) or "import" (disk -> UI PC); any other dir returns "". Always
-- names the file via M.FILE[kind] -- never a hardcoded filename.
function M._confirmText(dir, kind)
  if dir == "export" then
    return "Overwrite " .. M.FILE[kind] .. " on the disk?"
  elseif dir == "import" then
    if isFcsKind(kind) then
      return "Overwrite " .. M.FILE[kind] .. " on the FCS?"
    end
    return "Overwrite " .. M.FILE[kind] .. " on this UI PC?"
  end
  return ""
end

-- Live FCS read: cache hit returns the serialised body. Cache miss fires a non-blocking
-- cfgClient:readKind and returns nil this call (never waits). In-flight / failed entries
-- are not re-requested here -- showScreen's DTC prefetch and the client's tick cover retry.
function M._liveFcsGet(runtime, kind)
  if not runtime then return nil end
  runtime.cfgCache = runtime.cfgCache or {}
  local c = runtime.cfgCache[kind]
  if c and c.body ~= nil then return textutils.serialise(c.body) end
  if not c and runtime.cfgClient and runtime.cfgClient.readKind then
    runtime.cfgCache[kind] = { body = nil, status = "sync" }
    runtime.cfgClient:readKind(kind, function(body)
      runtime.cfgCache[kind] = { body = body, status = body ~= nil and "ok" or "fail" }
      runtime.uiRev = (runtime.uiRev or 0) + 1
    end)
  end
  return nil
end

-- Live FCS write: fire-and-forget via cfgClient. Never reports success before the FCS ack;
-- callers must read runtime.cfgSaveStatus (and the writeKind callback) for the real result.
function M._liveFcsSet(runtime, kind, body)
  if type(body) == "string" then
    body = textutils.unserialise(body)
  end
  if type(body) ~= "table" then return false end
  if not (runtime and runtime.cfgClient and runtime.cfgClient.writeKind) then return false end
  runtime.cfgSaveStatus = "saving to FCS..."
  runtime.uiRev = (runtime.uiRev or 0) + 1
  runtime.cfgClient:writeKind(kind, body, function(ok, err)
    runtime.cfgSaveStatus = ok and "saved to FCS -- reload to apply"
      or ("SAVE FAILED: " .. tostring(err or "no FCS"))
    runtime.uiRev = (runtime.uiRev or 0) + 1
  end)
  return false
end

-- M._fmtRow(row, width): compact per-kind status line, e.g. "tuning  L:OK D:--" -- DISPLAY-ONLY,
-- row.hasLocal/hasDisk (the underlying present/plan data) are untouched. The GUARANTEE is that
-- the returned string is always <= width (width nil/<=0 -> unbounded, matching fitLabel's own
-- contract): the fixed "  L:xx D:xx" suffix is always exactly 11 chars, so `row.kind` (already
-- short: devbind/senscal/tuning) is fit to `width - #suffix` (>= 1) via configkit.fitLabel BEFORE
-- concatenating -- fitting the composite string as a whole afterwards is not an option, since
-- fitLabel/listpicker.formatLabel unconditionally strips everything up to a string's FIRST ":"
-- (its namespace-strip contract, see test_configkit.lua's own fitLabel tests), which would eat
-- the kind name and the "L" the moment the suffix's own colons entered the string. A final hard
-- clamp covers the pathological width < #suffix case (narrower than the suffix itself allows),
-- so the <= width guarantee holds for every width, not just the ~14-col target.
function M._fmtRow(row, width)
  local l = row.hasLocal and "OK" or "--"
  local d = row.hasDisk and "OK" or "--"
  local suffix = "  L:" .. l .. " D:" .. d -- always 11 chars regardless of l/d
  local w = (type(width) == "number" and width > 0) and width or nil
  local kindWidth = w and math.max(1, w - #suffix) or nil
  local kind = configkit.fitLabel(row.kind, kindWidth)
  local text = kind .. suffix
  if w and #text > w then
    text = text:sub(1, w) -- width narrower than the suffix alone can fit -- last-resort clamp
  end
  return text
end

-- RELCHAR: rel -> one-char indicator glyph for a kind-list row's selector button. PURE/display-only.
local RELCHAR = { newer = ">", older = "<", same = "=", ["local-only"] = "L", ["disk-only"] = "D", none = "-" }

-- rowSelectorText(row): "<label> <relChar> <OK|BAD|-->" for a kind-list row's clickable selector
-- button -- row comes from M.row(kind, info). "--" when the disk copy doesn't exist at all (never
-- validated); "OK"/"BAD" once it does, from row.diskValid.
local function rowSelectorText(row)
  local valid = row.diskHas and (row.diskValid and "OK" or "BAD") or "--"
  return row.label .. " " .. (RELCHAR[row.rel] or "-") .. " " .. valid
end

-- clampText(text, width): plain right-truncate to `width` chars, width nil/<=0 -> unbounded.
-- DELIBERATELY not configkit.fitLabel here: fitLabel's namespace-strip contract (strip everything
-- up to the FIRST ":") would eat a leading "disk:"/"L:"/"local:" label prefix the instant one
-- appears anywhere in the string -- every string this module builds below (disk summary, row
-- detail lines, confirm-screen local/disk lines, status lines) deliberately contains a literal
-- colon, so fitLabel is the wrong tool for them (see M._fmtRow's header note for the same trap).
local function clampText(text, width)
  local w = (type(width) == "number" and width > 0) and width or nil
  if not w or #text <= w then return text end
  return text:sub(1, w)
end

-- M.build: hosts a region.lua drilldown (root "top") below a static headerLabel -- mirrors
-- senssource.lua's/senscal.lua's shape:
--   * "top": disk summary label ("disk: <label> . valid N/4" / "no disk", from M._detect + counting
--     M._scanKind(...).diskValid across M.KINDS) + EXPORT/IMPORT/REFRESH actionRow (EXPORT/IMPORT
--     push "export"/"import"; REFRESH re-detects+re-scans and repaints) + "<" (pops the FRAME nav).
--   * "export"/"import": one row per M.KINDS kind -- a single-button actionRow selector (so
--     setState(1,...) gates it individually) showing rowSelectorText(M.row(kind,info)), plus a
--     static detail line ("L:<fmtTime> D:<fmtTime>") below it. Export rows enable iff the kind
--     exists locally; import rows enable iff the disk copy exists AND validates (never import a
--     corrupt/unreadable disk file over a good local one). An enabled row pushes
--     "confirm_<dir>_<kind>"; a status line (last CONFIRM's result) + "<" (region:pop()) sit below
--     the rows.
--   * "confirm_<dir>_<kind>" (one per dir x kind -- 8 screens, each independent, mirroring
--     senssource.lua's per-step "cal_<id>" screens): M._confirmText(dir,kind) + local/disk
--     M.fmtTime detail + a CONFIRM row that runs M._exportKind/M._importKind, records a one-line
--     status on the list screen, re-detects/re-scans, then region:pop()s back to the list (which
--     repaints via region:apply(nil)) -- plus its own "<" that pops WITHOUT acting (cancel).
--
-- apply(state): disk-courier CONFIG status, not live telemetry -- forwards to the region, which
-- lazily builds/shows its current nav top and repaints only that screen. REFRESH and a completed
-- CONFIRM are the only things that ever call deps.find/exists/read/attributes; apply() never polls
-- peripherals on its own (same "UI subordinate to FCS" cadence rule the old flat build followed).
function M.build(basalt, frame, runtime, nav, deps)
  deps = resolveDeps(deps)
  if runtime and runtime.cfgClient then
    deps.fcsGet = deps.fcsGet or function(kind)
      return M._liveFcsGet(runtime, kind)
    end
    deps.fcsSet = deps.fcsSet or function(kind, body)
      return M._liveFcsSet(runtime, kind, body)
    end
  end

  local w, h = frame:getSize()

  local headerLabel = configkit.titleRow(frame, w, M.title)

  -- A region-internal nav push/pop isn't a FRAME-level nav change, so it wouldn't otherwise wake
  -- the dirty-gated render loop -- bump runtime.uiRev, exactly like senssource.lua's/senscal.lua's
  -- regions do.
  local function bump()
    if runtime then runtime.uiRev = (runtime.uiRev or 0) + 1 end
  end

  -- ===== shared disk-courier state: drive detection + per-kind scan + last CONFIRM's status =====
  local ALL_KINDS = {}
  for _, roleName in ipairs(cfgroles.ROLES) do
    for _, kind in ipairs(cfgroles.kinds(roleName)) do
      ALL_KINDS[#ALL_KINDS + 1] = kind
    end
  end

  local drive = { present = false, driveFound = false, mount = nil, label = nil }
  local scanKindResults = {}
  for _, kind in ipairs(ALL_KINDS) do
    scanKindResults[kind] = { localHas = false, localMs = nil, diskHas = false, diskMs = nil, diskValid = false }
  end
  local dirStatus = { export = "", import = "" }

  local function doDetect()
    drive = M._detect(deps)
    local sk = {}
    for _, kind in ipairs(ALL_KINDS) do
      sk[kind] = M._scanKind(drive.mount, kind, deps)
    end
    scanKindResults = sk
  end
  doDetect()

  local function summaryText()
    if not drive.present then return "no disk" end
    local n = 0
    for _, kind in ipairs(M.KINDS) do
      if scanKindResults[kind].diskValid then n = n + 1 end
    end
    return "disk: " .. tostring(drive.label) .. " . valid " .. n .. "/" .. #M.KINDS
  end

  -- ===== "top" screen: disk summary + EXPORT/IMPORT/REFRESH + "<" =====
  local function buildTop(b, f, region)
    local fw = ({ f:getSize() })[1]
    local fx = 2
    local fiw = math.max(1, fw - 2)
    local y = 2   -- gap at row 1 (detach from title)

    -- Disk status row, centred, in <> brackets, with an indicator alongside: -( )- empty / -(*)- (a
    -- solid filled circle, string.char(7)) when a disk is found.
    local diskLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })

    -- 1-row gap, then REFRESH / SCAN. Mixed EXPORT/IMPORT/IMPORT ALL live on the FCS/UI/NAV
    -- role screens, not here -- a mixed top-screen transfer was operator-confusing.
    local topY = y + 2
    local leftX  = fx + 1
    local refreshBtn   = configkit.bracketSwitch(f, { x = leftX,  y = topY,     width = 7,  text = "REFRESH",    kind = "function" })
    local scanBtn      = configkit.bracketSwitch(f, { x = leftX,  y = topY + 1, width = 7,  text = "SCAN",       kind = "function" })
    refreshBtn.button:onClick(function() doDetect(); region:apply(nil) end)
    scanBtn.button:onClick(function() region:push("scan") end)

    local roleY = topY + 2
    local fcsBtn = configkit.bracketSwitch(f, { x = fx, y = roleY, width = 3, text = "FCS", kind = "menu" })
    local uiBtn  = configkit.bracketSwitch(f, { x = fx + 6, y = roleY, width = 2, text = "UI", kind = "menu" })
    local navBtn = configkit.bracketSwitch(f, { x = fx + 11, y = roleY, width = 3, text = "NAV", kind = "menu" })
    fcsBtn.button:onClick(function() region:push("role_fcs") end)
    uiBtn.button:onClick(function() region:push("role_ui") end)
    navBtn.button:onClick(function() region:push("role_nav") end)

    local backRow = configkit.actionRow(f, { x = fx, y = roleY + 1, w = fiw }, {
      { id = "back", label = configkit.GLYPH.BACK, onClick = function() if nav then nav:pop() end end },
    })

    local function refreshTop()
      local present = drive.present
      local ind = present and ("-(" .. string.char(7) .. ")-") or "-( )-"
      local t = "<DISK STATE: " .. (present and "DISK FOUND" or "NO DISK") .. "> " .. ind
      diskLabel:setWidth(fiw)
      diskLabel:setText(string.rep(" ", math.max(0, math.floor((fiw - #t) / 2))) .. t)
      scanBtn.set(present and "off" or "disabled")
      fcsBtn.set("off")
      uiBtn.set("off")
      navBtn.set("off")
    end
    refreshTop()

    return {
      apply = function(_state) refreshTop() end,
      elements = {
        diskLabel = diskLabel, refreshBtn = refreshBtn, scanBtn = scanBtn,
        backRow = backRow,
        fcsBtn = fcsBtn, uiBtn = uiBtn, navBtn = navBtn,
      },
    }
  end

  -- ===== "export"/"import" screens: one selector+detail row per kind + status + "<" =====
  local function buildKindList(dir)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local kindRows, detailLabels = {}, {}
      for i, kind in ipairs(M.KINDS) do
        local row = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
          { label = "", onClick = function() region:push("confirm_" .. dir .. "_" .. kind) end },
        })
        y = y + 1
        local detail = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
        y = y + 1
        kindRows[i] = row
        detailLabels[i] = detail
      end

      local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
      y = y + 1

      local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      local function refreshList()
        for i, kind in ipairs(M.KINDS) do
          local info = scanKindResults[kind]
          local row = M.row(kind, info)
          kindRows[i].buttons[1].button:setText(clampText(rowSelectorText(row), fiw))
          local enabled
          if dir == "export" then enabled = info.localHas
          else enabled = info.diskHas and info.diskValid end
          kindRows[i].setState(1, enabled and "off" or "disabled")
          detailLabels[i]:setText(clampText(
            "L:" .. M.fmtTime(info.localMs) .. " D:" .. M.fmtTime(info.diskMs), fiw))
        end
        statusLabel:setText(clampText(dirStatus[dir] or "", fiw))
      end
      refreshList()

      return {
        apply = function(_state) refreshList() end,
        elements = {
          kindRows = kindRows, detailLabels = detailLabels, statusLabel = statusLabel, backRow = backRow,
        },
      }
    end
  end

  -- ===== "confirm_<dir>_<kind>" screens: M._confirmText + local/disk times + CONFIRM/"<" =====
  local function buildConfirm(dir, kind)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1

      local questionLabel = f:addLabel({
        x = fx, y = y, width = fiw, height = 1, autoSize = false,
        text = clampText(M._confirmText(dir, kind), fiw),
      })
      y = y + 1
      local localLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
      y = y + 1
      local diskLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
      y = y + 1
      local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
      y = y + 1

      local confirmRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { label = "CONFIRM", onClick = function()
            local ok
            if dir == "export" then
              ok = M._exportKind(drive.mount, kind, deps)
            else
              ok = M._importKind(drive.mount, kind, deps)
            end
            dirStatus[dir] = M.LABEL[kind] .. ": " .. (ok and "OK" or "FAILED")
            doDetect()
            region:pop()
            region:apply(nil)
          end },
      })
      y = y + 1

      local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { id = "back", label = "<", onClick = function() region:pop() end },
      })

      local function refresh()
        local info = scanKindResults[kind] or {}
        localLabel:setText(clampText("local: " .. M.fmtTime(info.localMs), fiw))
        diskLabel:setText(clampText("disk: " .. M.fmtTime(info.diskMs), fiw))
        statusLabel:setText("")
      end
      refresh()

      return {
        apply = function(_state) refresh() end,
        elements = {
          questionLabel = questionLabel, localLabel = localLabel, diskLabel = diskLabel,
          statusLabel = statusLabel, confirmRow = confirmRow, backRow = backRow,
        },
      }
    end
  end

  -- ===== "confirm_importall" screen: summary of valid importable kinds + one-shot CONFIRM/"<" =====
  local function buildImportAllConfirm(b, f, region)
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local summaryLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local confirmRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_OK, onClick = function()
          local r = M._importAll(drive.mount, deps)
          dirStatus.import = "IMPORT ALL: " .. #r.imported .. " imported, " .. #r.skipped .. " skipped"
          doDetect(); region:pop(); region:apply(nil)
        end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_CANCEL, onClick = function() region:pop() end },
    })
    local function refresh()
      local n = 0
      for _, kind in ipairs(M.KINDS) do
        if scanKindResults[kind].diskHas and scanKindResults[kind].diskValid then n = n + 1 end
      end
      summaryLabel:setText(clampText("Import " .. n .. " valid config(s) to this UI PC?", fiw))
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { summaryLabel = summaryLabel, statusLabel = statusLabel, confirmRow = confirmRow, backRow = backRow } }
  end

  -- ===== "scan" screen: disk junk-vs-valid summary + CLEAN (gated on any junk present) + "<" =====
  local function buildScan(b, f, region)
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local summaryLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local cleanRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = "CLEAN", onClick = function() region:push("confirm_clean") end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { id = "back", label = configkit.GLYPH.BACK, onClick = function() region:pop() end },
    })
    local function refresh()
      local scan = M._scanDisk(drive.mount, deps)
      summaryLabel:setText(clampText(M._scanSummary(scan), fiw))
      cleanRow.setState(1, ((#scan.foreign + #scan.invalid) > 0) and "off" or "disabled")
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { summaryLabel = summaryLabel, cleanRow = cleanRow, backRow = backRow } }
  end

  -- ===== "confirm_clean" screen: count of junk to delete + CONFIRM (runs M._cleanDisk) / "<" =====
  local function buildCleanConfirm(b, f, region)
    local fx, fiw, y = 2, math.max(1, ({ f:getSize() })[1] - 2), 1
    local listLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
    y = y + 1
    local confirmRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_OK, onClick = function()
          local r = M._cleanDisk(drive.mount, deps)
          dirStatus.import = "CLEAN: " .. #r.deleted .. " deleted"
          doDetect(); region:pop(); region:apply(nil)
        end },
    })
    y = y + 1
    local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
      { label = configkit.GLYPH.CONFIRM_CANCEL, onClick = function() region:pop() end },
    })
    local function refresh()
      local scan = M._scanDisk(drive.mount, deps)
      listLabel:setText(clampText("Delete " .. (#scan.foreign + #scan.invalid) .. " junk file(s)? (configs kept)", fiw))
    end
    refresh()
    return { apply = function(_s) refresh() end,
      elements = { listLabel = listLabel, confirmRow = confirmRow, backRow = backRow } }
  end

  local function buildRole(role)
    return function(b, f, region)
      local fw = ({ f:getSize() })[1]
      local fx = 2
      local fiw = math.max(1, fw - 2)
      local y = 1
      local kinds = M.roleKinds(role) or {}
      local titleLabel = f:addLabel({
        x = fx, y = y, width = fiw, height = 1, autoSize = false,
        text = clampText(string.upper(role) .. " CONFIG", fiw),
      })
      y = y + 1
      local exportBtn = configkit.bracketSwitch(f, { x = fx, y = y, width = 6, text = "EXPORT", kind = "function" })
      local importBtn = configkit.bracketSwitch(f, { x = fx + 10, y = y, width = 6, text = "IMPORT", kind = "function" })
      y = y + 1
      local statusLabel = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
      y = y + 1
      local kindLabels = {}
      for i, kind in ipairs(kinds) do
        kindLabels[i] = f:addLabel({ x = fx, y = y, width = fiw, height = 1, autoSize = false, text = "" })
        y = y + 1
      end
      local backRow = configkit.actionRow(f, { x = fx, y = y, w = fiw }, {
        { id = "back", label = configkit.GLYPH.BACK, onClick = function() region:pop() end },
      })
      exportBtn.button:onClick(function()
        local exported = M._export(drive.mount, deps, role)
        dirStatus.export = string.upper(role) .. ": exported " .. tostring(#exported)
        doDetect(); region:apply(nil)
      end)
      importBtn.button:onClick(function()
        local imported = M._import(drive.mount, deps, role)
        dirStatus.import = string.upper(role) .. ": imported " .. tostring(#imported)
        doDetect(); region:apply(nil)
      end)
      local function refresh()
        local present = drive.present
        exportBtn.set(present and "off" or "disabled")
        importBtn.set(present and "off" or "disabled")
        local status = (runtime and runtime.cfgSaveStatus) or ""
        if status == "" then
          status = ((dirStatus.export or "") .. " " .. (dirStatus.import or ""))
        end
        statusLabel:setText(clampText(status, fiw))
        for i, kind in ipairs(kinds) do
          local info = scanKindResults[kind] or {}
          kindLabels[i]:setText(clampText(rowSelectorText(M.row(kind, info)), fiw))
        end
      end
      refresh()
      return {
        apply = function(_s) refresh() end,
        elements = {
          titleLabel = titleLabel, exportBtn = exportBtn, importBtn = importBtn,
          statusLabel = statusLabel, kindLabels = kindLabels, backRow = backRow,
        },
      }
    end
  end

  local screens = { top = buildTop, export = buildKindList("export"), import = buildKindList("import") }
  for _, dir in ipairs({ "export", "import" }) do
    for _, kind in ipairs(M.KINDS) do
      screens["confirm_" .. dir .. "_" .. kind] = buildConfirm(dir, kind)
    end
  end
  screens.confirm_importall = buildImportAllConfirm
  screens.scan = buildScan
  screens.confirm_clean = buildCleanConfirm
  screens.role_fcs = buildRole("fcs")
  screens.role_ui = buildRole("ui")
  screens.role_nav = buildRole("nav")

  local region = Region.new(basalt, frame, {
    x = 1, y = 2, width = w, height = math.max(1, h - 1),
    root = "top", screens = screens, onNav = bump,
  })

  -- Force the top screen to build now (not on the first scheduled apply()), so its elements exist
  -- as soon as M.build returns -- mirrors senssource.lua's/senscal.lua's identical eager-build call.
  region:apply(nil)

  local function apply(state)
    region:apply(state)
  end

  return {
    id = M.id,
    apply = apply,
    elements = { headerLabel = headerLabel, region = region },
  }
end

return M
