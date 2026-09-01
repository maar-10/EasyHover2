-- EasyHover 2 -- hover bring-up test. IN-GAME ONLY (real peripherals + CC globals).
-- Flies an automated climb->hold->land profile, logs every cycle to /eh2_hover_log.csv.
-- Controls: SPACE launch, Q abort-to-land. Physical fuel-pull = hard kill.
-- Wrapped peripherals take NO self (all peripheral IO is inside fcs.io.backend).
local hwconfig = require("fcs.io.hwconfig")
local tuning   = require("fcs.tuning")
local Backend  = require("fcs.io.backend")
local Level    = require("fcs.actuate.level")
local Loop     = require("fcs.runtime.loop")
local Registry = require("fcs.modes.registry")
local Profile  = require("fcs.bringup.profile")
local Inst     = require("fcs.bringup.instrument")
local Codec    = require("fcs.bringup.logcodec")
local cut      = require("fcs.io.cut")

local CONFIG_PATH = "/eh2_hw_config.tbl"
local LOG_PATH  = "/eh2_hover_log.csv"
local PART_PATH = "/eh2_hover_log.csv.part"

local function loadConfig()
  local saved
  if fs.exists(CONFIG_PATH) then
    local f = fs.open(CONFIG_PATH, "r"); saved = textutils.unserialise(f.readAll() or ""); f.close()
  end
  return hwconfig.merge(saved or {}, hwconfig.defaults())
end

local function buildLoop(backend)
  local reg = Registry.build(tuning)          -- tuning is the module singleton (has DOT forMode)
  local d = reg.byId[reg.default]
  local loop = Loop.new({ scheme = d.scheme, mixer = d.mixer, caps = d.caps,
    pwm = Level.new({ backend = backend, steps = 15 }),
    sd = nil,
    backend = backend, dtMax = tuning.dtMax, osc = tuning.osc,
    hoverDuty = tuning.gains.hoverDuty })   -- DAMPED holds vertical here, not just zeroes attitude
  return loop, reg
end

local function baseline(backend)
  local n, altS, hdgS, sway, surge = 5, 0, 0, 0, 0
  for _ = 1, n do
    local s = backend:sensors()
    altS = altS + s.altitude; hdgS = hdgS + s.heading
    sway, surge = s.swayPos, s.surgePos
    sleep(0.1)
  end
  return altS / n, hdgS / n, sway, surge
end

local function killThrusters(backend)
  local groups = { backend:liftIds(), backend:lateralIds(), backend:mainIds(), backend:frontalIds() }
  for _, ids in ipairs(groups) do
    for _, id in ipairs(ids) do pcall(function() backend:setThruster(id, false) end) end
  end
end

local function flight(backend, loop, profile, summary, heading0, swayPos0, surgePos0, part)
  local t0 = os.epoch("utc")
  local lastT = t0
  local timer = os.startTimer(0)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then
      local now = os.epoch("utc")
      local dt = (now - lastT) / 1000
      lastT = now
      local m = backend:sensors()
      -- magnitude abort: an attitude runaway (flight #1 flew to 131deg) ends the mission but
      -- KEEPS attitude control active (unlike DAMPED) so the FCS keeps trying to level as it lands.
      if tuning.attLimit and (math.abs(m.pitch) > tuning.attLimit or math.abs(m.roll) > tuning.attLimit) then
        profile:abort()
      end
      local pr = profile:update(dt, m.altitude, m.onGround)
      loop:setpoints({ altitude = pr.targetAlt, pitch = 0, roll = 0,
        heading = heading0, swayPos = swayPos0, surgePos = surgePos0 })
      loop:arm(pr.active)
      local diag = loop:cycle(dt, m)
      if diag.mode == "DAMPED" then profile:abort() end
      local dem = diag.demands or {}
      local sample = { t = (now - t0)/1000, dt = dt, phase = pr.phase, mode = diag.mode,
        sp_alt = pr.targetAlt, alt = m.altitude, vSpeed = m.vSpeed, pitch = m.pitch,
        roll = m.roll, heading = m.heading, yawRate = m.yawRate, swayVel = m.swayVel,
        surgeVel = m.surgeVel, swayPos = m.swayPos, surgePos = m.surgePos,
        onGround = m.onGround, heave = dem.heave, dPitch = dem.pitch, dRoll = dem.roll,
        dYaw = dem.yaw, dSway = dem.sway, dSurge = dem.surge, duties = diag.duties }
      summary:add(sample)
      part.write(Inst.formatRow(sample) .. "\n")
      if pr.done then return end
      timer = os.startTimer(0)
    elseif ev[1] == "key" then
      if ev[2] == keys.space then profile:begin(); print("LAUNCH")
      elseif ev[2] == keys.q then profile:abort(); print("ABORT -> landing") end
    end
  end
end

local function run()
  pcall(cut.all)
  local config = loadConfig()
  local backend = Backend.new(require("fcs.io.shim"), config)
  local loop = buildLoop(backend)

  print("EH2 HOVER TEST -- measuring baseline (hold still)...")
  local baseAlt, heading0, swayPos0, surgePos0 = baseline(backend)
  print(string.format("baseAlt %.2f  heading0 %.3f", baseAlt, heading0))

  local pcfg = { baseAlt = baseAlt }
  for k, v in pairs(tuning.profile) do pcfg[k] = v end
  local profile = Profile.new(pcfg)
  local summary = Inst.Summary.new()

  local part = fs.open(PART_PATH, "w"); part.write(Inst.header() .. "\n")
  print("Ready. Fuel ON. Press SPACE to launch, Q to abort.")

  local ok, err = pcall(flight, backend, loop, profile, summary, heading0, swayPos0, surgePos0, part)

  -- ALWAYS stop thrust, however we exited
  loop:arm(false)
  pcall(function() loop:cycle(0, backend:sensors()) end)
  killThrusters(backend)
  part.close()
  if not ok then print("FLIGHT ERROR: " .. tostring(err)) end

  -- compose final log: summary + delta-encoded slim CSV rows from the crash-safe part file
  -- (the part file stays plain slim CSV so a mid-flight crash still leaves a readable log)
  local dataRows, first = {}, true
  local pf = fs.open(PART_PATH, "r")
  if pf then
    for line in (pf.readAll() or ""):gmatch("[^\n]+") do
      if first then first = false else dataRows[#dataRows+1] = line end  -- skip the part header
    end
    pf.close()
  end
  local out = fs.open(LOG_PATH, "w")
  out.write(Inst.formatSummary(summary:finalize()) .. "\n\n"
    .. Codec.encode(Inst.header(), dataRows) .. "\n")
  out.close()

  print("")
  print(Inst.formatSummary(summary:finalize()))
  print("")
  print("Log written: " .. LOG_PATH)
  local okp = pcall(function() return shell.run("carbide", "put", LOG_PATH) end)
  if not okp then print("(carbide unavailable -- grab " .. LOG_PATH .. " manually)") end
end

return { run = run, buildLoop = buildLoop }
