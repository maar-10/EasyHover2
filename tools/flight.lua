-- EasyHover 2 FCS runtime. Parallel tasks over a single-writer snapshot.
-- FCS PC handles ONLY control + input routing + telemetry-send + command-receive.
-- IN-GAME ONLY (real peripherals + CC globals). Not unit-tested; validated in flight.
package.path = "/?.lua;/?/init.lua;" .. package.path

local cut = require("fcs.io.cut")
pcall(cut.all)

local hwconfig  = require("fcs.io.hwconfig")
local cfgspec   = require("fcs.io.cfgspec")
local fueltable = require("fcs.fueltable")
local tuning    = require("fcs.tuning")
local Backend   = require("fcs.io.backend")
local shim      = require("fcs.io.shim")
local frame     = require("fcs.frame")
local hover     = require("tools.hover_test")
local Flight    = require("fcs.runtime.flight")
local fault     = require("fcs.runtime.fault")
local fsx       = require("fcs.io.fsx")
local keymap    = require("fcs.input.keymap")
local Pilot     = require("fcs.input.pilot")
local inputCfg  = require("fcs.input.config")
local modemlib  = require("fcs.comms.modem")
local telemetry = require("fcs.comms.telemetry")
local command   = require("fcs.comms.command")
local health    = require("fcs.comms.health")
local Inst      = require("fcs.bringup.instrument")
local Status    = require("fcs.bringup.status")
local LogBuffer = require("fcs.bringup.logbuffer")
local cfgsync   = require("fcs.comms.cfgsync")
local cfgaccess = require("fcs.io.cfgaccess")

local CH = { telemetry = 101, command = 102, ack = 103, health = 104 }
-- Config responder pair (105/106): separate from telemetry/command/ack/health so live config
-- traffic never touches the control-loop comms budget. Ownership moved here from fcs/boot/loaderui
-- (S2): the boot no longer pulls config from the UI; the UI now reads/writes THIS FCS live.
local CFG_CH = { req = 105, reply = 106 }
local CONFIG_PATH = "/eh2_hw_config.tbl"

-- Clear the boot-loader's console and show a status the operator can see during the (short)
-- synchronous build below -- otherwise the flight computer looks dead after "boot FCS? Y". The
-- status task (registered further down) takes over the moment the flight tasks start.
pcall(function() term.clear(); term.setCursorPos(1, 1); term.write(Status.statusLine("LOADING")) end)

-- ---- Build the flight-proven control stack (mirror tools/hover_test.lua) ----
local function loadConfig()
  local function readSplit(name)
    local p = "/" .. name
    if not fs.exists(p) then return nil end
    local f = fs.open(p, "r"); local body = f.readAll(); f.close(); return body
  end
  local assembled = cfgspec.tryAssemble(readSplit)
  if assembled then return hwconfig.merge(assembled, hwconfig.defaults()) end
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end

local config  = loadConfig()
local backend = Backend.new(shim, config)
local loop, registry = hover.buildLoop(backend)   -- SINGLE arg; buildLoop reads tuning itself

-- ---- Fuel calibration: load the persisted selection and apply its scale at boot ----
local function readFile(name)
  local p = "/" .. name
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r"); local body = f.readAll(); f.close(); return body
end
local function writeFile(name, body)
  return fsx.writeAtomic("/" .. name, body)
end
local fuelcal = cfgspec.load("fuelcal", readFile)   -- { fuel = "Biodiesel" } by default
local fuelScale0 = fueltable.scaleFor(fuelcal.fuel) or 1.0
loop:setFuelScale(fuelScale0)

-- Fuel state lives here so the §11.8 no-fuel interlock (Flight) can read the same decoupled
-- 1 Hz snapshot pollFuel fills. No extra peripheral reads on the control path; UI/NAV still
-- consume the telemetry snapshot only (comms-hygiene).
local fuelState = { thrusterFuel = {}, fuelMain = nil }

local pilot  = Pilot.new(inputCfg.default)
pilot:setMode(registry.byId[registry.default].policy, registry.byId[registry.default].feel)
local Master = require("fcs.modes.master")
pilot:setMaster(Master.byId[Master.default].driftArrest)
local flight = Flight.new({ loop = loop, pilot = pilot, registry = registry, config = config,
  park = tuning.park,
  setGroundSense = function(b) backend:setGroundSense(b) end,
  fuel = function() return fuelState.fuelMain end,
  setFuelScale = function(x) loop:setFuelScale(x) end,
  saveFuel = function(id) cfgspec.save("fuelcal", { fuel = id }, writeFile) end,
  fuelName = fuelcal.fuel,
  diskPresent = function()
    local ok, drive = pcall(peripheral.find, "drive")
    if not ok or not drive or not drive.isDiskPresent then return false end
    local ok2, present = pcall(drive.isDiskPresent)
    return ok2 and present and true or false
  end })

-- Seed the loop trim once at boot from the flight object's own defaults (trimDir/trimGain come
-- from the default flight mode's feel -- see fcs/runtime/flight.lua defaultTrimDir/Flight.new).
loop:setTrim(flight.trimDir, flight.trimGain)

-- Apply the boot default descriptor's flags so ground-sense matches the starting mode (LDG).
do
  local d0 = registry.byId[registry.default]
  flight.canPark = d0.canPark or false
  flight.groundSense = d0.groundSense or false
  backend:setGroundSense(flight.groundSense)
end

-- ---- Comms ----
-- FCS RECEIVES commands on 102 and SENDS: telemetry on 101, acks on 103, heartbeat on 104.
local modem = assert(peripheral.find("modem"), "FCS needs a modem")
for _, c in pairs(CH) do modem.open(c) end
for _, c in pairs(CFG_CH) do modem.open(c) end
local cfgLink = modemlib.wrap(modem, { txCh = CFG_CH.reply, rxCh = CFG_CH.req })
local telLink = modemlib.wrap(modem, { txCh = CH.telemetry, rxCh = CH.command })
local cmdLink = modemlib.wrap(modem, { txCh = CH.ack,       rxCh = CH.command })
local hbLink  = modemlib.wrap(modem, { txCh = CH.health,    rxCh = CH.command })
local tx      = telemetry.Tx.new()
local recv    = command.Receiver.new()
local hbTx    = health.Tx.new({ period = 1.0 })

-- ---- Shared single-writer snapshot ----
local shared = { snap = flight:snapshot(nil, backend:sensors()) }
local typewriter = peripheral.find("linked_typewriter")
local heldRef = { held = {} }

-- ---- Optional flight instrumentation (NO-OP unless launched via `fcslog`) ----
-- `fcslog` sets _G.EH2_FLIGHTLOG before requiring this module; production `fcs`/`flight` do not,
-- so LOGGING stays false and every logging branch below is a single boolean check per cycle.
-- Same 34-column CSV + summary as tools/hover_test.lua, so flight logs compare 1:1 with hover_test.
local LOGGING   = _G.EH2_FLIGHTLOG == true
local LOG_PATH  = "/eh2_flight_log.csv"
local MAX_ROWS  = 3000   -- bound RAM/disk (~0.5MB); the in-memory summary still covers the whole run
local logSummary, logT0, logRows
-- ROLLING ring buffer of the last MAX_ROWS formatted rows (fcs.bringup.logbuffer): P dumps a
-- bounded, recent window on demand while the FCS keeps flying. CC file writes are synchronous +
-- non-yielding, so the write happens ONLY on a P press / on exit, never on the control loop --
-- same "nothing that can block belongs on the hot path" lesson as the fuel decouple.
local function logStart()
  if not LOGGING then return end
  logSummary = Inst.Summary.new(); logT0 = os.epoch("utc"); logRows = LogBuffer.new(MAX_ROWS)
end
local function logCycle(dt, m)
  if not LOGGING then return end
  local r = flight.lastDiag or {}
  local dem = r.demands or {}
  -- Log-site-only pure read (never called when LOGGING is false): reconstructs the PID
  -- split/saturation/trim bundle from already-stored loop/scheme state. See fcs/runtime/loop.lua
  -- Loop:diag. ONE call per logged cycle -- no per-cycle work is added to the control path.
  local d = flight.loop:diag(pilot.sp, m)
  local sample = {
    t = (os.epoch("utc") - logT0) / 1000, dt = dt,
    phase = flight.engaged and (m.onGround and "ENG-GND" or "ENGAGED") or "IDLE",
    mode = r.mode or flight.flightMode,
    sp_alt = pilot.sp and pilot.sp.altitude or 0,
    alt = m.altitude, vSpeed = m.vSpeed, pitch = m.pitch, roll = m.roll,
    heading = m.heading, yawRate = m.yawRate, swayVel = m.swayVel, surgeVel = m.surgeVel,
    swayPos = m.swayPos, surgePos = m.surgePos, onGround = m.onGround,
    heave = dem.heave, dPitch = dem.pitch, dRoll = dem.roll, dYaw = dem.yaw,
    dSway = dem.sway, dSurge = dem.surge, duties = r.duties,
    -- Setpoints (THE COLUMN CONTRACT new columns 1): from pilot.sp, log-site read only.
    sp_pitch = pilot.sp and pilot.sp.pitch or 0, sp_roll = pilot.sp and pilot.sp.roll or 0,
    sp_hdg = pilot.sp and pilot.sp.heading or 0, sp_sway = pilot.sp and pilot.sp.swayPos or 0,
    sp_surge = pilot.sp and pilot.sp.surgePos or 0,
    -- PID split / saturation (new columns 3-4): STORED, from Loop:diag (pure read above).
    terms = d.terms, sat = d.sat, heaveBanded = d.heaveBanded,
    -- Trim feedforward (new column 5): the exact bias Loop:cycle adds to demands.pitch.
    ff_pitch = (d.trimDir or 0) * (d.trimGain or 0) * ((dem.surge) or 0),
    -- Context (new column 6): plain fields already published on the Flight instance
    -- (fcs/runtime/flight.lua Flight.new / :snapshot) -- no new peripheral read.
    master = flight.masterMode, noFuel = flight.noFuel or false,
  }
  logSummary:add(sample)                                   -- summary always covers the whole flight
  -- Buffer the RAW captured sample (duties snapshotted), NOT a formatted string. The 34-column
  -- string.format (Inst.formatRow) is the costly part and now runs only at dump time (logWriteFile),
  -- OFF the control loop -- so logging no longer steals hot-path time from the FCS. See analysis:
  -- logging-on flights ran ~15Hz jittery; this removes the per-cycle format work.
  logRows:push(Inst.capture(sample))                       -- RAM ring; oldest rolls off past MAX_ROWS
end
-- Compose the CSV body (header + buffered rows + running summary) and write it to LOG_PATH.
-- Returns rowCount. Off the flight path (called only from logDump/logFinish).
local function logWriteFile()
  -- Format the buffered raw samples to CSV rows HERE, at dump time (P press / exit), not per cycle.
  local recs = logRows:rows()
  local rows = {}
  for i = 1, #recs do rows[i] = Inst.formatRow(recs[i]) end
  local summaryText = Inst.formatSummary(logSummary:finalize())
  pcall(function()
    if fs.exists(LOG_PATH) then fs.delete(LOG_PATH) end     -- reclaim space from a prior write
    local f = fs.open(LOG_PATH, "w")
    if f then
      f.write(Inst.header() .. "\n" .. table.concat(rows, "\n") .. "\n\n" .. summaryText .. "\n")
      f.close()
    end
  end)
  return #rows
end
-- P-triggered: write the rolling window + upload to carbide, then KEEP FLYING. Repeatable -- each
-- press uploads a fresh (overlapping) window. Feedback lands on row 4, below the status rows.
local function logDump()
  if not LOGGING then return end
  local n = logWriteFile()
  pcall(function() term.setCursorPos(1, 4); term.clearLine() end)
  print(("LOG: %d rows -> carbide..."):format(n))
  if not pcall(function() return shell.run("carbide", "put", LOG_PATH) end) then
    print("(carbide unavailable -- grab " .. LOG_PATH .. " manually)")
  end
end
-- Exit-only: stop thrust, write the final window LOCALLY (no auto-upload -- P is the upload action).
local function logFinish()
  if not LOGGING then return end
  loop:arm(false); pcall(function() loop:cycle(0, backend:sensors()) end)   -- stop thrust on exit
  local n = logWriteFile()
  pcall(function() term.setCursorPos(1, 4) end)
  print(""); print(Inst.formatSummary(logSummary:finalize()))
  print(("Log saved: %s  (%d rows). Press P in-flight to upload."):format(LOG_PATH, n))
end

-- ---- Fuel readback: DECOUPLED from the control loop ----
-- getFuelAmountMb/getFuelCapacityMb are ~50ms mainThread calls. Polling all 4 lift thrusters
-- INLINE every control cycle cost ~390ms/cycle and collapsed the flight loop to ~2Hz (measured:
-- 122 cycles / 55s, ~452ms/cycle even with ZERO thruster writes), while the identical control
-- stack holds ~16.7Hz in tools/hover_test.lua -- which never polls fuel. So fuel now polls in its
-- own 1Hz task, capacity is constant and cached (read once), the reads run concurrently, and the
-- control loop only copies the latest snapshot (fuelState) -- no peripheral calls on the hot path.
local fuelPeriph, fuelCap = {}, {}
local function pollFuel()
  local tf, reads = {}, {}
  for i, id in ipairs(frame.LIFT) do
    if fuelPeriph[i] == nil then
      local name = config.thrusters and config.thrusters[id]
      fuelPeriph[i] = (name and shim.wrap(name)) or false
    end
    local p = fuelPeriph[i]
    if p and p.getFuelAmountMb and p.getFuelCapacityMb then
      reads[#reads + 1] = function()
        if fuelCap[i] == nil then
          local okc, cap = pcall(p.getFuelCapacityMb)
          fuelCap[i] = (okc and cap) or false   -- capacity is constant: read once
        end
        local oka, amt = pcall(p.getFuelAmountMb)
        local cap = fuelCap[i]
        if oka and amt and cap and cap > 0 then tf[i] = amt / cap end
      end
    end
  end
  if #reads > 0 then
    if parallel and parallel.waitForAll then parallel.waitForAll(table.unpack(reads))
    else for _, fn in ipairs(reads) do fn() end end
  end
  -- Aggregate: no separate main-tank peripheral exists (fuel is per-thruster),
  -- so the main FUEL gauge shows the mean of the available fractions.
  local sum, count = 0, 0
  for _, f in pairs(tf) do sum = sum + f; count = count + 1 end
  fuelState.thrusterFuel = tf
  fuelState.fuelMain = (count > 0) and (sum / count) or nil
end
local function fuelTask()
  while true do pollFuel(); sleep(1.0) end
end

-- ---- Tasks ----
local lastT = os.epoch("utc")
-- Typewriter events are applied on the control pull (that coroutine already wakes on
-- every event). Control MUST stay unfiltered os.pullEvent() — a timer-only dispatcher
-- filter would drop key/key_up. The 50 ms inputTask stays a filtered sleep+poll heal —
-- not a second unfiltered os.pullEvent() loop. See fcs/input/events.lua.
local inputHybrid = require("fcs.input.events").new({
  codes = function()
    if typewriter and typewriter.getPressedKeyCodes then return typewriter.getPressedKeyCodes() or {} end
    return {}
  end,
  map = function() return keymap.forMode(flight.flightMode) end,
  held = heldRef.held,
})

local function controlTask()
  -- Self-rescheduling zero-timer: fires as fast as possible while still
  -- yielding every iteration (required under parallel.waitForAny, and to
  -- avoid CC:Tweaked's "Too long without yielding" watchdog).
  local timer = os.startTimer(0)
  while true do
    -- Unfiltered: also delivers key/key_up for inputHybrid. os.pullEvent("timer") cannot.
    local ev = { os.pullEvent() }
    -- onOsEvent press-path calls getPressedKeyCodes (computer-thread today). If that
    -- peripheral method becomes mainThread, this stalls control — keep it off the step pcall.
    if not inputHybrid:onOsEvent(ev) and ev[1] == "timer" and ev[2] == timer then
      -- Guard the whole step: a single bad sensor read or step error must NOT kill the control
      -- task (a silently-dead loop = uncontrolled craft). Capture it for the console and carry on.
      local ok, err = pcall(function()
        local now = os.epoch("utc"); local dt = (now - lastT) / 1000; lastT = now
        local meas = backend:sensors()
        local snap = flight:step(dt, heldRef.held, meas)
        snap.thrusterFuel = fuelState.thrusterFuel   -- cheap copy; fuelTask does the peripheral reads
        snap.fuelMain = fuelState.fuelMain
        shared.snap = snap
        logCycle(dt, meas)
      end)
      -- §11.9: "Terminated" is NEVER swallowed by this device-fault pcall -- a Ctrl+T arriving
      -- mid-step is re-raised so parallel.waitForAny unwinds and safeShutdown() runs.
      flight.devWarn = not ok
      if not ok then shared.controlErr = fault.orReraise(err) end
      -- Hard-fail: last successful snap still goes out on tel. Stamp gated extras
      -- onto it so PARAMS DEV WRN shows ON without calling sensors()/step().
      if not ok and flight.paramsWatch and shared.snap then
        shared.snap.devWarn = true
        shared.snap.disk = flight.disk and true or false
      end
      timer = os.startTimer(0)   -- ALWAYS re-arm, even if the step threw, so the loop never stalls
    elseif ev[1] == "disk" then
      flight.disk = true
    elseif ev[1] == "disk_eject" then
      flight.disk = false
    end
  end
end

local function inputTask()
  -- Filtered: sleep yields on "timer" only, so modem/char/foreign timers do not resume us.
  -- 20 Hz getPressedKeyCodes is computer-thread (not mainThread) and heals key_up collisions.
  while true do
    inputHybrid:sync()
    sleep(0.05)
  end
end

local function telemetryTask()
  while true do
    -- Fire-and-forget: skip one frame on encode/transmit error. Terminated is re-raised (§11.9).
    local ok, err = pcall(function() telLink:send(tx:frame(shared.snap)) end)
    if not ok then fault.orReraise(err) end
    sleep(0.1)
  end
end

local function commandTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame_ = cmdLink:onMessage(ch, msg)
    if frame_ then
      fault.protect(function()
        local ack = recv:receive(frame_, function(cmd) flight:handleCommand(cmd) end)
        if ack then cmdLink:send(ack) end
      end)
    end
  end
end

-- ---- Live config responder (CFG_CH): serves the UI's BIT/CONFIG menus from THIS FCS's own config
-- files and applies their writes. Stateless per request (a sibling of commandTask): each req/set is
-- self-contained, handled between control ticks -- no config "session" state. Traffic occurs only
-- when the operator opens/saves a menu. Reads/writes go through fcs.io.cfgaccess (pure, tested).
local function cfgProvider(kind) return cfgaccess.getKind(kind, readFile) end
local function cfgApplier(kind, body)
  local ok, err = cfgaccess.setKind(kind, body, readFile, writeFile)
  -- Apply-timing preserved: the ONLY hot config change is CoM. A tuning set carrying com{} is
  -- pushed to the mixer LIVE via the same setCom path the COM screen uses, so a hand trim takes
  -- effect now; tuning/bindings otherwise need an FCS reload. Idempotent with the COM screen's own
  -- command-channel setCom (fcs/runtime/flight.lua:132).
  if ok and kind == "tuning" and type(body) == "table" and type(body.com) == "table" then
    pcall(function()
      flight:handleCommand({ k = "setCom",
        fwd = body.com.fwd or 0, right = body.com.right or 0,
        spanFwd = body.com.spanFwd or body.com.span, spanRight = body.com.spanRight or body.com.span })
    end)
  end
  return ok, err
end

local function configTask()
  while true do
    local _, _, ch, _, msg = os.pullEvent("modem_message")
    local frame_ = cfgLink:onMessage(ch, msg)
    if frame_ then
      fault.protect(function()
        local reply = cfgsync.Responder.decide(frame_, cfgProvider, cfgApplier)
        if reply then cfgLink:send(reply) end
      end)
    end
  end
end

local function healthTask()
  while true do
    local beat = hbTx:beat(os.epoch("utc") / 1000)
    if beat then
      fault.protect(function() hbLink:send(beat) end)
    end
    sleep(0.25)
  end
end

-- ---- Console status (fcs.bringup.status): tells the operator the FCS is alive + what it's doing.
-- Own low-rate (~4Hz) parallel task -- one cursor-move + write per tick, yields immediately, so it
-- never competes with the control loop. Owns rows 1-2; logDump feedback lands on row 4.
local WARMUP_MS = 20000   -- ~20s display-only settle window (never gates engagement)
local loadT0 = nil        -- set when flight tasks start; nil => LOADING
local function statusTask()
  local tick = 0
  while true do
    local elapsed = loadT0 and (os.epoch("utc") - loadT0) or nil
    local phase = Status.phase({ elapsedMs = elapsed, warmupMs = WARMUP_MS, engaged = flight.engaged })
    local spin = Status.spinner(tick, phase == "RUNNING" and "running" or "idle")
    pcall(function()
      term.setCursorPos(1, 1); term.clearLine(); term.write(Status.statusLine(phase, spin))
      term.setCursorPos(1, 2); term.clearLine(); term.write(Status.logLine(LOGGING))
    end)
    tick = tick + 1
    sleep(0.25)
  end
end

-- P dumps + uploads the rolling log window and keeps flying (only meaningful when LOGGING).
local function logKeyTask()
  while true do
    local _, key = os.pullEvent("char")
    if key == "p" or key == "P" then logDump() end
  end
end

-- However the task group ends -- a returned task, or an unhandled error in any of them -- always
-- drop thrust so a crash can't leave the craft with thrusters latched on.
local function safeShutdown()
  pcall(function() loop:arm(false); loop:cycle(0, backend:sensors()) end)   -- applies zeros via pwm
  pcall(function()
    for _, grp in ipairs({ backend:liftIds(), backend:lateralIds(), backend:mainIds(), backend:frontalIds() }) do
      for _, id in ipairs(grp) do pcall(function() backend:setThruster(id, false) end) end
    end
  end)
  pcall(cut.all)
end

loadT0 = os.epoch("utc")
if LOGGING then
  logStart()
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask,
                        healthTask, fuelTask, statusTask, logKeyTask, configTask)
  safeShutdown()
  logFinish()
  if not ok then print("FCS EXIT: " .. tostring(err)) end
else
  local ok, err = pcall(parallel.waitForAny, controlTask, inputTask, telemetryTask, commandTask,
                        healthTask, fuelTask, statusTask, configTask)
  safeShutdown()
  if not ok then print("FCS EXIT: " .. tostring(err)) end
end
