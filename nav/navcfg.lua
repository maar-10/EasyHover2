-- nav/navcfg.lua
-- Pure NAV-settings frames for the cockpit DTC. Transport is 108/109 (same link as waypoints).
local M = {}
function M.getFrame() return { k = "nav_cfg_get" } end
function M.setFrame(body) return { k = "nav_cfg_set", body = body } end
function M.cfgFrame(body) return { k = "nav_cfg", body = body } end
function M.ackFrame(ok, err) return { k = "nav_cfg_ack", ok = ok and true or false, err = err } end

-- apply(cfg, msg) -> reply, newCfg
-- get returns the current table; set replaces it when body is a table.
function M.apply(cfg, msg)
  msg = msg or {}
  if msg.k == "nav_cfg_get" then
    return M.cfgFrame(cfg), cfg
  end
  if msg.k == "nav_cfg_set" then
    if type(msg.body) ~= "table" then
      return M.ackFrame(false, "not a table"), cfg
    end
    return M.ackFrame(true), msg.body
  end
  return nil, cfg
end

return M
