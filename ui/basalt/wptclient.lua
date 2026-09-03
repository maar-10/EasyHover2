-- ui/basalt/wptclient.lua
-- Cockpit-side sync client for the NAV-PC-owned waypoint/route store. Sends requests on wired ch 108
-- and awaits replies on 109 (mirrors fcs/boot/loaderui.lua's cfgsync client), caching the last
-- {store, rev, online} in the client object; the NAV menu renders from that cache and mutates
-- through this client. If the NAV PC is silent the client goes `online=false` and the menu goes
-- read-only. NO peripheral/Basalt access at module LOAD; the round-trip is the only in-game part.
local protocol = require("fcs.comms.protocol")
local navcfg = require("nav.navcfg")

local M = {}
M.REQ_CH = 108
M.REPLY_CH = 109

-- ===== PURE request-frame builders (match nav/wptserver.lua's apply) =====
function M.getFrame() return { k = "wpt_get" } end
function M.opFrame(op, args, rev) return { k = "wpt_op", op = op, args = args, rev = rev } end
function M.diskFrame(op) return { k = "wpt_disk", op = op } end

local C = {}
C.__index = C

--- new(opts): opts.link (a fcs.comms.modem Link {txCh=108, rxCh=109}, injected/in-game),
--- opts.timeout (s, default 1.0), opts.retries (default 2), opts.now (fn->ms).
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    link = opts.link,
    timeout = opts.timeout or 1.0,
    retries = opts.retries or 2,
    now = opts.now or function() return os.epoch("utc") end,
    store = { waypoints = {}, routes = {} },
    rev = -1,
    online = false,
    lastErr = nil,
  }, C)
end

--- onReply(frame, now) -> true if a store or nav_cfg reply refreshed the cache + online. PURE.
--- Called by the UI modem router when a reply arrives on 109 -- NOT a blocking wait (a blocking
--- pullEvent inside a Basalt handler would eat the cockpit's own events).
function C:onReply(frame, now)
  if type(frame) ~= "table" then return false end
  if frame.k == "wpt_store" and type(frame.store) == "table" then
    self.store = frame.store
    self.rev = frame.rev or self.rev
    self.online = true
    self.lastReplyAt = now
    self.lastErr = frame.err
    return true
  end
  if frame.k == "wpt_disk_res" then
    self.lastDisk = frame; self.online = true; self.lastReplyAt = now
    return false
  end
  if frame.k == "wpt_err" then self.lastErr = frame.err; return false end
  if frame.k == "nav_cfg" and type(frame.body) == "table" then
    self.navCfg = frame.body
    self.online = true
    self.lastReplyAt = now
    if self._navCfgCb then self._navCfgCb(frame.body) end
    return true
  end
  if frame.k == "nav_cfg_ack" then
    self.online = true
    self.lastReplyAt = now
    if self._navAckCb then self._navAckCb(frame.ok, frame.err) end
    return true
  end
  return false
end

--- stale(now) -> true when no reply has arrived within `maxAge` ms of `now` (NAV offline). PURE.
--- maxAge defaults to ~3x the poll period so a single dropped refresh doesn't flip to offline.
function C:stale(now, maxAge)
  if self.lastReplyAt == nil then return true end
  return (now - self.lastReplyAt) > (maxAge or 6000)
end

--- refreshOnline(now, maxAge) -> online after applying stale(). If the last reply is older than
--- maxAge (default 6000 ms), clears online. Recovery is onReply, not this function. `now` defaults
--- to self.now().
function C:refreshOnline(now, maxAge)
  now = now or self.now()
  if self:stale(now, maxAge) then self.online = false end
  return self.online
end

-- ===== fire-and-forget sends (async). The reply lands via the UI modem router -> onReply. =====
--- request(): ask the NAV PC for the full store (refreshes the cache when the reply arrives).
--- Always sends (recovery poll) after refreshOnline so a silent NAV can come back.
function C:request()
  self:refreshOnline()
  if self.link then self.link:send(M.getFrame()) end
end

--- mutate(op, args): send a store op (addWpt/editWpt/deleteWpt/...); the reply carries the fresh
--- store (or an err surfaced in lastErr). No-ops when the NAV PC is stale -- do not send into the void.
function C:mutate(op, args)
  if not self:refreshOnline() then return end
  if self.link then self.link:send(M.opFrame(op, args, self.rev)) end
end

--- diskOp(op): scan/import/export/clean on the NAV PC's disk drive. No-ops when stale.
function C:diskOp(op)
  if not self:refreshOnline() then return end
  if self.link then self.link:send(M.diskFrame(op)) end
end

function C:requestNavCfg(cb)
  self._navCfgCb = cb
  if self.link then self.link:send(navcfg.getFrame()) end
end

function C:setNavCfg(body, cb)
  self._navAckCb = cb
  if self.link then self.link:send(navcfg.setFrame(body)) end
end

return M
