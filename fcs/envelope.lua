local M = {}
-- Clamp demands to the envelope caps. Second return: which axes were CLIPPED (nil if none) --
-- callers feed this back to the controllers as saturation so the integrators do not keep
-- winding into a rail they cannot influence (§5 conditional integration, §11.2).
function M.clamp(demands, caps)
  local out, sat = {}, nil
  for k, v in pairs(demands) do
    local c = caps[k]
    if v ~= v or v == math.huge or v == -math.huge then
      out[k] = 0                                  -- finite-guard: NaN/inf never reach the mixer
    elseif c and v > c then out[k] = c; sat = sat or {}; sat[k] = true
    elseif c and v < -c then out[k] = -c; sat = sat or {}; sat[k] = true
    else out[k] = v end
  end
  return out, sat
end
return M
