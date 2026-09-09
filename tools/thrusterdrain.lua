-- thrusterdrain.lua -- STANDALONE utility (no FCS deps). Detects every connected Create
-- Propulsion thruster and fires them all at a fixed low throttle on a toggle, to burn the
-- residual fuel out of them (e.g. when switching fuel types). TETHER THE CRAFT FIRST.
--
-- Controls:
--   SPACE      toggle draining ON / OFF (fires again if pressed while on)
--   UP / DOWN  raise / lower the drain throttle by 0.05 (applies live while firing)
--   Q          cut all thrust and quit
--
-- Run it on any CC computer wired to the thrusters (grab it via `carbide put` / pastebin, or
-- deploy with the tree). It re-asserts the throttle every second so a warmed thruster holds.

local THROTTLE = 0.30          -- start value: low enough not to fly a tethered craft, high
local STEP     = 0.05          -- enough to drain in minutes not hours. Tune live with UP/DOWN.
local MINT, MAXT = 0.05, 1.00

-- Detect thrusters by duck-typing the CC method (works regardless of the peripheral type string).
local function findThrusters()
  local list = {}
  for _, name in ipairs(peripheral.getNames()) do
    local methods = peripheral.getMethods(name) or {}
    local hasNorm, hasPow = false, false
    for _, m in ipairs(methods) do
      if m == "setPowerNormalized" then hasNorm = true end
      if m == "setPower" then hasPow = true end
    end
    if hasNorm or hasPow then
      list[#list + 1] = { name = name, norm = hasNorm }
    end
  end
  return list
end

local thr = findThrusters()

-- Wrapped peripherals take NO self: p.setPowerNormalized(v), never p:setPowerNormalized(v).
local function setAll(v)
  for _, t in ipairs(thr) do
    local p = peripheral.wrap(t.name)
    if p then
      if t.norm then pcall(p.setPowerNormalized, v)
      else pcall(p.setPower, math.floor(v * 15 + 0.5)) end
    end
  end
end

local function status(firing)
  term.clear(); term.setCursorPos(1, 1)
  print("THRUSTER DRAIN  --  " .. #thr .. " thruster(s) found")
  if #thr == 0 then print("  (none detected -- check the wired-modem connections)") end
  print("")
  print("  state    : " .. (firing and "DRAINING" or "stopped"))
  print(string.format("  throttle : %.2f", THROTTLE))
  print("")
  print("  SPACE toggle | UP/DOWN throttle +-0.05 | Q quit")
  print("  ** tether the craft before draining **")
end

local firing = false
status(firing)
local timer = os.startTimer(1)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    if firing then setAll(THROTTLE) end          -- re-assert so warmed thrusters hold
    timer = os.startTimer(1)
  elseif ev[1] == "key" then
    local k = ev[2]
    if k == keys.space then
      firing = not firing
      setAll(firing and THROTTLE or 0)
      status(firing)
    elseif k == keys.up then
      THROTTLE = math.min(MAXT, THROTTLE + STEP)
      if firing then setAll(THROTTLE) end
      status(firing)
    elseif k == keys.down then
      THROTTLE = math.max(MINT, THROTTLE - STEP)
      if firing then setAll(THROTTLE) end
      status(firing)
    elseif k == keys.q then
      setAll(0)
      term.clear(); term.setCursorPos(1, 1)
      print("thrust cut. bye.")
      break
    end
  end
end
