-- fcs/brake.lua -- pure tilt-brake geometry: drift-speed -> angle curve + drift-opposing
-- pitch/roll decomposition. No state, no peripherals. Consumed by fcs.input.pilot.
local M = {}

-- Linear-ramp brake angle from drift speed s (blk/s). < engageSpeed -> 0 (thrusters brake alone).
-- At engageSpeed -> minAngle. Ramps to maxAngle (auto) or buttonMax (button) by satSpeed; capped.
function M.angle(s, cfg, button)
  s = s or 0
  local top = (button and cfg.buttonMax) or cfg.maxAngle
  if s < cfg.engageSpeed then return 0 end
  if s >= cfg.satSpeed then return top end
  local f = (s - cfg.engageSpeed) / (cfg.satSpeed - cfg.engageSpeed)
  return cfg.minAngle + f * (top - cfg.minAngle)
end

-- Decompose tilt magnitude theta into pitch/roll opposing the (surgeVel, swayVel) drift.
-- sqrt(pitch^2+roll^2) == theta. Signs (see fcs/mixer/level_flight.lua corners()): positive pitch
-- demand = nose-up (front lift pair higher) brakes forward motion; positive roll = lift tilts right,
-- so braking rightward drift needs negative roll.
function M.vector(theta, surgeVel, swayVel)
  surgeVel = surgeVel or 0; swayVel = swayVel or 0
  local s = math.sqrt(surgeVel * surgeVel + swayVel * swayVel)
  if theta <= 0 or s < 1e-6 then return 0, 0 end
  return theta * (surgeVel / s), -theta * (swayVel / s)
end

return M
