-- fcs/input/keymap.lua
local M = {}

-- axis+dir -> held flag name
local FLAG = {
  yaw   = { [-1] = "yawLeft",  [1] = "yawRight" },
  lift  = { [-1] = "down",     [1] = "up" },
  sway  = { [-1] = "swayLeft", [1] = "swayRight" },
  surge = { [-1] = "surgeBack",[1] = "surgeFwd" },
  pitch = { [-1] = "pitchDown", [1] = "pitchUp" },
  roll  = { [-1] = "rollLeft",  [1] = "rollRight" },
  finesurge = { [-1] = "fineBack", [1] = "fineFwd" },
  rudder    = { [-1] = "rudderLeft", [1] = "rudderRight" },
}

-- The held-flag name a single bound code drives, or nil when unbound. Exposed for the
-- event-driven input path, which applies one key press/release at a time.
function M.flagFor(map, code)
  local m = map[code]
  if not m then return nil end
  return FLAG[m.axis] and FLAG[m.axis][m.dir] or nil
end

function M.resolve(map, codes)
  local held = {}
  for _, code in ipairs(codes) do
    local flag = M.flagFor(map, code)
    if flag then held[flag] = true end
  end
  return held
end

-- Default typewriter layout (WASD move, QE yaw, R/Space up, F/LShift down). keys.* provided by CC.
M.default = {
  [keys.w] = {axis="surge", dir=1},  [keys.s] = {axis="surge", dir=-1},
  [keys.a] = {axis="sway",  dir=-1}, [keys.d] = {axis="sway",  dir=1},
  [keys.q] = {axis="yaw",   dir=-1}, [keys.e] = {axis="yaw",   dir=1},
  [keys.r] = {axis="lift",  dir=1},  [keys.f] = {axis="lift",  dir=-1},
  [keys.space]     = {axis="lift", dir=1},   -- climb  (alias for R)
  [keys.leftShift] = {axis="lift", dir=-1},  -- descend (alias for F)
  [keys.up]    = {axis="pitch", dir=-1}, [keys.down]  = {axis="pitch", dir=1},
  [keys.left]  = {axis="roll",  dir=-1}, [keys.right] = {axis="roll",  dir=1},
}

-- CPL/DCPL "plane-style" coupled layout: L-Shift/Space throttle+brake, WASD pitch/roll,
-- QE rear-only rudder, comma/period full yaw, R/F rampable climb/descend, arrows fine
-- surge (slow fwd/back), left/right strafe (sway).
M.coupled = {
  [keys.leftShift] = {axis="surge", dir=1},   -- throttle
  [keys.space]     = {axis="surge", dir=-1},   -- brake
  [keys.w] = {axis="pitch", dir=-1}, [keys.s] = {axis="pitch", dir=1},   -- nose down / up
  [keys.a] = {axis="roll",  dir=-1}, [keys.d] = {axis="roll",  dir=1},
  [keys.q] = {axis="rudder", dir=-1}, [keys.e] = {axis="rudder", dir=1}, -- rear-only rudder
  [keys.comma] = {axis="yaw", dir=-1}, [keys.period] = {axis="yaw", dir=1}, -- full yaw
  [keys.r] = {axis="lift", dir=1}, [keys.f] = {axis="lift", dir=-1},     -- rampable climb/descend
  [keys.up] = {axis="finesurge", dir=1}, [keys.down] = {axis="finesurge", dir=-1}, -- slow surge
  [keys.left] = {axis="sway", dir=-1}, [keys.right] = {axis="sway", dir=1},         -- strafe
}

function M.forMode(id)
  if id == "CPL" or id == "DCPL" then return M.coupled end
  return M.default
end

return M
