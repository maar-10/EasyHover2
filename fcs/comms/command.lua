-- fcs/comms/command.lua
local session = require("fcs.comms.session")
local M = {}

-- A per-boot session id. Command ids reset to 1 on every UI restart, and the FCS runs continuously
-- remembering which ids it has handled -- so without a session tag a restarted UI's id 1 collided
-- with the FCS's old handled set and the command was ACKed but silently never applied. Stamping a
-- fresh sid per Sender namespaces the dedup so a reboot's ids can never be swallowed. (Shared with
-- telemetry, which has the mirror problem on FCS restart -- see fcs/comms/session.lua.)
M.newSid = session.new

local Sender = {}; Sender.__index = Sender
M.Sender = { new = function(cfg)
  cfg = cfg or {}
  return setmetatable({ timeout = cfg.timeout or 1.0, maxRetries = cfg.maxRetries or 4,
                        sid = cfg.sid or M.newSid(), nextId = 0, pending = {} }, Sender)
end }
function Sender:send(cmd)
  self.nextId = self.nextId + 1
  local frame = { k = "cmd", sid = self.sid, id = self.nextId, cmd = cmd }
  self.pending[self.nextId] = { frame = frame, age = 0, tries = 0 }
  return frame
end
-- Accepts an ack frame ({k=ack, sid, id}) or a bare id (legacy). An ack from a DIFFERENT session
-- (e.g. still in flight when the UI rebooted) must not clear this session's pending.
function Sender:ack(ack)
  if type(ack) == "table" then
    if ack.sid ~= nil and ack.sid ~= self.sid then return end
    self.pending[ack.id] = nil
  else
    self.pending[ack] = nil
  end
end
-- Returns the frames due for retransmission. A pending entry that has exhausted maxRetries is
-- DROPPED (not retried again): with the FCS down, unbounded retry would grow `pending` forever
-- and spam the command channel; telemetry is the truth, so a dropped command simply never shows.
-- Second return lists the dropped frames so callers can annunciate if they want to.
function Sender:tick(dt)
  local due, dropped = {}, {}
  for id, p in pairs(self.pending) do
    p.age = p.age + dt
    if p.age >= self.timeout then
      if p.tries >= self.maxRetries then
        self.pending[id] = nil
        dropped[#dropped + 1] = p.frame
      else
        p.tries = p.tries + 1
        p.age = 0
        due[#due + 1] = p.frame
      end
    end
  end
  return due, dropped
end

local Receiver = {}; Receiver.__index = Receiver
M.Receiver = { new = function()
  return setmetatable({ handled = {}, sid = nil }, Receiver)
end }
function Receiver:receive(frame, apply)
  if type(frame) ~= "table" or frame.k ~= "cmd" or type(frame.id) ~= "number" then
    return nil
  end
  -- Dedup key is (session, id): idempotent for retries within a session, but a restarted sender
  -- (new sid, ids from 1) is never mistaken for a duplicate. A new sid also drops the previous
  -- session's handled entries -- otherwise the set grew unbounded, one dead id-range per reboot.
  if frame.sid ~= self.sid then
    self.handled = {}
    self.sid = frame.sid
  end
  local key = tostring(frame.sid or "") .. ":" .. tostring(frame.id)
  if not self.handled[key] then
    self.handled[key] = true
    apply(frame.cmd)
  end
  return { k = "ack", sid = frame.sid, id = frame.id }
end

return M
