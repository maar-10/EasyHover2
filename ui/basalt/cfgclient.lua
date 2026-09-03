-- ui/basalt/cfgclient.lua
-- Cockpit-side client for the FCS's live config responder (CFG_CH: send req/set on 105, hear
-- cfg/ack on 106). Event-driven (mirrors ui/basalt/wptclient.lua): readKind/writeKind are
-- fire-and-forget with a callback; replies land via the UI modem router -> onReply, and a periodic
-- tick() retransmits timed-out requests (2 s x 3, matching fcs/boot/loaderui.lua's UI_TIMEOUT/
-- UI_RETRIES) and fails the callback when the FCS stays silent. A blocking wait would eat the
-- cockpit's own events, so nothing here blocks. NO peripheral/Basalt access at module load.
local cfgsync = require("fcs.comms.cfgsync")

local M = {}
local C = {}
C.__index = C

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    link = opts.link,
    timeout = opts.timeout or 2.0,   -- seconds per attempt
    retries = opts.retries or 3,     -- total attempts
    now = opts.now or function() return os.epoch("utc") end,
    seq = 0,
    pending = {},   -- sid -> { kind, op="read"|"write", body?, cb, tries, deadline(ms) }
  }, C)
end

function C:_sid()
  self.seq = self.seq + 1
  return "cfg-" .. tostring(self.now()) .. "-" .. tostring(self.seq)
end

function C:_sendRead(sid, kind)
  if self.link then self.link:send(cfgsync.hello(sid)); self.link:send(cfgsync.req(sid, kind)) end
end
function C:_sendWrite(sid, kind, body)
  if self.link then self.link:send(cfgsync.set(sid, kind, body)) end
end

-- readKind(kind, cb): cb(bodyTable|nil). nil = FCS silent after all retries.
function C:readKind(kind, cb)
  local sid = self:_sid()
  self.pending[sid] = { kind = kind, op = "read", cb = cb, tries = 1,
                        deadline = self.now() + self.timeout * 1000 }
  self:_sendRead(sid, kind)
  return sid
end

-- writeKind(kind, body, cb): cb(ok, err). (false, "FCS not answering") on timeout.
function C:writeKind(kind, body, cb)
  local sid = self:_sid()
  self.pending[sid] = { kind = kind, op = "write", body = body, cb = cb, tries = 1,
                        deadline = self.now() + self.timeout * 1000 }
  self:_sendWrite(sid, kind, body)
  return sid
end

-- onReply(frame, now) -> true if it resolved a pending request. Called by the UI modem router.
function C:onReply(frame, now)
  if type(frame) ~= "table" or frame.sid == nil then return false end
  local p = self.pending[frame.sid]
  if not p then return false end
  if p.op == "read" and frame.k == "cfg" and frame.kind == p.kind then
    self.pending[frame.sid] = nil
    if p.cb then p.cb(frame.body) end
    return true
  end
  if p.op == "write" and frame.k == "ack" and frame.kind == p.kind then
    self.pending[frame.sid] = nil
    if p.cb then p.cb(frame.ok and true or false, frame.err) end
    return true
  end
  return false
end

-- tick(now): retransmit timed-out requests up to `retries`; then fail the callback.
function C:tick(now)
  now = now or self.now()
  for sid, p in pairs(self.pending) do
    if now >= p.deadline then
      if p.tries >= self.retries then
        self.pending[sid] = nil
        if p.cb then
          if p.op == "read" then p.cb(nil) else p.cb(false, "FCS not answering") end
        end
      else
        p.tries = p.tries + 1
        p.deadline = now + self.timeout * 1000
        if p.op == "read" then self:_sendRead(sid, p.kind) else self:_sendWrite(sid, p.kind, p.body) end
      end
    end
  end
end

return M
