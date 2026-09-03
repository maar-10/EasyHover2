-- fcs/boot/loaderui.lua
-- Terminal boot UI: lets the pilot pick a SOURCE per config concern (binding/sensor/tuning),
-- assembles the runtime config via fcs.boot.loader, and writes the files the flight app
-- reads (/eh2_hw_config.tbl plus /eh2_tuning.tbl or /eh2_tuning.session.tbl). Sources are
-- current / default / disk (the FCS boots from its own files, a sibling DEFAULT, or a
-- config disk). DEFAULT for binding/sensor/tuning is a session overlay and does not clobber current.
-- Boot UI and the flight app never run concurrently: this program returns (or the launcher
-- exits) before launchers/flight.lua starts. No Basalt here on purpose -- keeps the FCS
-- boot path light and dependency-free.
--
-- CRITICAL: no peripheral/disk access at module load time -- headless has no disk,
-- so `require("fcs.boot.loaderui")` must load clean. All peripheral access lives inside
-- run()/buildSources() (and the real read/write helpers they call), never at the top level.

local loader         = require("fcs.boot.loader")
local cfgspec         = require("fcs.io.cfgspec")
local cfgroles        = require("fcs.io.cfgroles")
local tuningdefaults  = require("fcs.io.tuningdefaults")
local fsx             = require("fcs.io.fsx")

local M = {}

local HW_CONFIG_PATH  = "/eh2_hw_config.tbl"
local TUNING_PATH     = "/eh2_tuning.tbl"
local TUNING_SESSION_PATH = "/eh2_tuning.session.tbl"
local LEGACY_CONFIG_PATH = HW_CONFIG_PATH -- same file; legacy read-through source, not the write target

-- concern name -> cfgspec kind (mirrors fcs/boot/loader.lua's KIND table)
local KIND = { binding = "devbind", sensor = "senscal", tuning = "tuning" }

local CURRENT_PATH = {
  binding = "/eh2_devbind.tbl",
  sensor  = "/eh2_senscal.tbl",
  tuning  = TUNING_PATH,
}
local SESSION_PATH = {
  binding = "/eh2_devbind.session.tbl",
  sensor  = "/eh2_senscal.session.tbl",
  tuning  = TUNING_SESSION_PATH,
}

-- =====================================================================================
-- Testable seam (headless) -- pure given injected write(); no read()/fs/peripheral here.
-- =====================================================================================

local realWrite = fsx.writeAtomic

-- Atomically write the assembled hw + tuning tables the flight app reads.
-- `write(path, body)` / `delete(path)` are injected for testing; defaults are fsx.
-- `choices` is optional: 2-arg callers write fused + current tuning as before.
-- DEFAULT writes the session overlay and does not clobber current splits/tuning.
-- Disk import writes current and deletes any leftover session. Current deletes the
-- session overlay and does not rewrite current (it already is the source).
function M.commit(assembled, write, choices, delete)
  write = write or realWrite
  delete = delete or fsx.delete
  write(HW_CONFIG_PATH, textutils.serialise(assembled.hw))
  local split = cfgspec.splitLegacy(assembled.hw)
  local bodies = {
    binding = split.devbind,
    sensor  = split.senscal,
    tuning  = assembled.tuning,
  }
  if not choices then
    write(TUNING_PATH, textutils.serialise(assembled.tuning))
    return true
  end
  for _, concern in ipairs({ "binding", "sensor", "tuning" }) do
    local src = choices[concern]
    local body = bodies[concern]
    if src == "default" then
      write(SESSION_PATH[concern], textutils.serialise(body))
    elseif src == "disk" then
      write(CURRENT_PATH[concern], textutils.serialise(body))
      delete(SESSION_PATH[concern])
    elseif src == "current" then
      delete(SESSION_PATH[concern])
    end
  end
  return true
end

-- Resolve the pilot's chosen sources into an assembled config, then commit it.
-- Returns true, assembled  on success, or  false, nil, err  (nothing is written on failure).
function M.finish(choices, sources, write, delete)
  local ok, assembled, err, failedConcern = loader.resolve(choices, sources)
  if not ok then return false, nil, err, failedConcern end
  M.commit(assembled, write, choices, delete)
  return true, assembled
end

-- True for sources that come from OUTSIDE this computer's own filesystem ("disk") --
-- these overwrite the FCS runtime config from an external source, so the in-game pick flow
-- confirms with the pilot before proceeding. "current"/"default" are local/inert and proceed
-- silently. Pure: no fs/peripheral/read() -- safe to unit test headless.
function M.needsConfirm(src) return src == "disk" end

-- =====================================================================================
-- In-game only from here down: real fs/peripheral/disk/read() access. NOT headless-tested
-- (no disk in the CraftOS-PC harness); kept coherent by reading, mirrored against the
-- design doc's "current / disk / DEFAULT" flow.
-- =====================================================================================

local realRead = fsx.read

-- "current": the local split file (eh2_devbind.tbl / eh2_senscal.tbl); if that file is ABSENT and
-- the legacy combined /eh2_hw_config.tbl exists, seed from splitLegacy read-through (mirrors
-- tools/calibrate.lua's M._loadCal / loadSensors so terminal tool and boot UI agree).
local function ownSource(concern)
  local kind = KIND[concern]
  local cfg, existed, err = cfgspec.load(kind, realRead)
  -- Present-but-unparseable local file: treat as UNAVAILABLE (nil) rather than silently
  -- flying with cfgspec's defaults. resolve then fails on this concern so the pilot must
  -- re-pick (the source menu shows "split file CORRUPT" so they know why).
  if err then return nil end
  if existed then return cfg end
  local legacyBody = realRead(LEGACY_CONFIG_PATH)
  if legacyBody == nil then return nil end
  local legacy = textutils.unserialise(legacyBody)
  if type(legacy) ~= "table" then return nil end
  local split = cfgspec.splitLegacy(legacy)
  local seed = split[kind]
  if seed == nil then return nil end
  return cfgspec.merge(kind, seed)
end

-- "disk": the split file read off a mounted disk drive's disk, if one is present.
local function diskSource(concern)
  local kind = KIND[concern]
  local drive = peripheral.find("drive")
  if not drive or not drive.isDiskPresent or not drive.isDiskPresent() then return nil end
  local mount = drive.getMountPath and drive.getMountPath()
  if not mount then return nil end
  local body = realRead("/" .. mount .. "/" .. cfgspec.FILES[kind])
  if body == nil then return nil end
  local saved = textutils.unserialise(body)
  if type(saved) ~= "table" then return nil end
  return cfgspec.merge(kind, saved)
end

-- "default": sibling DEFAULT file (eh2_<name>.default.tbl). Tuning with no sibling falls
-- back to the immutable code baseline. Present-but-unparseable is unavailable (except
-- tuning, which still has the code baseline).
local function defaultSource(concern)
  local kind = KIND[concern]
  local name = cfgroles.defaultFile(kind)
  local body = name and realRead("/" .. name)
  if body then
    local saved = textutils.unserialise(body)
    if type(saved) == "table" then return cfgspec.merge(kind, saved) end
  end
  if concern == "tuning" then return tuningdefaults.get() end
  return nil
end

-- Real sources table: get(concern, src) -> cfgTable | nil.
function M.buildSources()
  return {
    get = function(concern, src)
      if src == "current" then return ownSource(concern) end
      if src == "disk" then return diskSource(concern) end
      if src == "default" then return defaultSource(concern) end
      return nil
    end,
  }
end

local CONCERNS = { "binding", "sensor", "tuning" }
local LABEL = { binding = "BINDING", sensor = "SENSOR", tuning = "TUNING" }

local function diskIndicator()
  local drive = peripheral.find("drive")
  if not drive then return "no disk drive" end
  if not (drive.isDiskPresent and drive.isDiskPresent()) then return "no disk inserted" end
  local label = (drive.getDiskLabel and drive.getDiskLabel()) or "unlabeled"
  return "disk: " .. tostring(label)
end

local function ownIndicator(concern)
  local kind = KIND[concern]
  local body = realRead("/" .. cfgspec.FILES[kind])
  if body then
    local okp, parsed = pcall(textutils.unserialise, body)
    if okp and type(parsed) == "table" then return "split file present" end
    return "split file CORRUPT"
  end
  if realRead(LEGACY_CONFIG_PATH) then return "legacy read-through" end
  return "none available"
end

-- Render one concern's menu, read a pick, and return the chosen source string, the
-- sentinel "ABORT" on 'q', or nil on an invalid choice (caller re-prompts).
local function pickSource(concern)
  print("")
  print(("== %s source ==  (%s)"):format(LABEL[concern], diskIndicator()))
  local opts = loader.SOURCES[concern]
  for i, s in ipairs(opts) do
    local extra = (s == "current") and ("  [" .. ownIndicator(concern) .. "]") or ""
    print(("  %d) %s%s"):format(i, s, extra))
  end
  write("choice (q aborts): ")
  local input = read()
  if input == "q" then return "ABORT" end
  local ch = tonumber(input)
  return ch and opts[ch] or nil
end

-- After a source is picked for a concern, if it's external (M.needsConfirm), ask the pilot
-- to confirm before it overwrites the FCS runtime config. Loops until a clear Y/N answer;
-- mirrors confirmBoot's read/lower/y-n idiom.
local function confirmSource(concern, src)
  while true do
    write(LABEL[concern] .. " from " .. src .. " will overwrite the FCS runtime config -- proceed? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- Prompt for one concern until a valid source is picked; returns the source, or "ABORT" on 'q'.
-- External sources ("disk") are confirmed with the pilot before being accepted -- on N,
-- re-pick the same concern; "current"/"default" proceed silently.
local function pickUntilValid(concern)
  while true do
    local src = pickSource(concern)
    while src == nil do
      print("  invalid choice, try again")
      src = pickSource(concern)
    end
    if src == "ABORT" then return src end
    if not M.needsConfirm(src) then return src end
    if confirmSource(concern, src) then return src end
  end
end

-- After the config is written (and before the boot question), ask whether to run FCS
-- instrumentation/logging for THIS instance. y/yes -> true (logging on until reboot + N), n/no ->
-- false. Loops until a clear answer. Mirrors confirmBoot's read/lower/y-n idiom.
local function confirmLogging()
  while true do
    print("")
    write("Enable FCS logging? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- After a successful write, ask the pilot whether to boot the FCS now. Loops until a clear
-- answer; returns true (start the flight app with the chosen config) or false (return to the
-- console -- the config is on disk, nothing is started). Accepts y/yes and n/no, any case.
local function confirmBoot()
  while true do
    print("")
    write("FCS config complete -- boot FCS? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end

-- Full interactive boot loop. Only place read()/term is touched. On a successful resolve the config
-- is written, then the pilot is asked whether to enable logging and whether to boot: returns
-- `assembled {hw=,tuning=}, logging(bool)` if they choose to boot, or nil if they decline (config
-- saved, nothing started) or abort. The launcher turns `logging` into _G.EH2_FLIGHTLOG.
function M.run()
  local sources = M.buildSources()
  print("EH2 BOOT LOADER")
  local choices = {}
  local toPick = CONCERNS   -- first pass picks all three; later passes re-pick only the failed one
  while true do
    for _, concern in ipairs(toPick) do
      local src = pickUntilValid(concern)
      if src == "ABORT" then return nil end
      choices[concern] = src
    end

    print("")
    print("resolving...")
    local ok, assembled, err, failedConcern = M.finish(choices, sources)
    if ok then
      local tuningOut = (choices.tuning == "default") and TUNING_SESSION_PATH or TUNING_PATH
      print("OK -- wrote " .. HW_CONFIG_PATH .. " + " .. tuningOut)
      -- Logging choice comes first (per the boot-flow spec), then the boot question. The launcher
      -- turns `logging` into _G.EH2_FLIGHTLOG for tools/flight.lua.
      local logging = confirmLogging()
      if confirmBoot() then
        return assembled, logging
      end
      print("returning to console (config saved, FCS not started)")
      return nil
    end
    print("FAILED: " .. tostring(err))
    if failedConcern and LABEL[failedConcern] then
      print("re-pick " .. LABEL[failedConcern])
      toPick = { failedConcern }   -- keep the other concerns' picks; only redo the one that failed
    else
      print("please re-pick")
      toPick = CONCERNS
    end
  end
end

return M
