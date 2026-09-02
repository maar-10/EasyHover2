-- controller/runtime.lua
-- The GPS beacon controller's core, Basalt-free and peripheral-injected so it self-tests headless.
-- The controller (1) keeps a persisted roster of known beacons (id -> operator annotations +
-- last-known position, seeded from controller.config), (2) hears the shared GPS channel -- both
-- passive gpsproto broadcasts (nav/comms/gpsproto) and beacon/update.lua reply frames (STATUS/ACK)
-- -- merging what it hears into that roster, and (3) SENDS token-guarded targeted (or broadcast)
-- remote commands via beacon/update.lua's wire format. No peripheral/os/fs access at module load:
-- the clock and modem are INJECTED; config persistence goes through an injected save fn.
local Update = require("beacon.update")
local gpsproto = require("nav.comms.gpsproto")
local Config = require("controller.config")

local M = {}
local R = {}
R.__index = R

local DEFAULT_STALE_MS = 8000

--- Plain Euclidean distance between two {x,y,z}.
local function dist3(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- new(opts): config (controller.config-shaped, carrying .roster), modem (raw dev with .transmit),
--- now (fn -> ms; default os.epoch), token (default config.updateToken), channel (default
--- config.channel), staleMs (default 8000), save (default controller.config.save), path (default
--- controller.config.PATH). Seeds the live roster from config.roster -- each id starts SILENT,
--- carrying its persisted name/expectedPos/lastPos (no runtime fields yet).
function M.new(opts)
  opts = opts or {}
  local cfg = opts.config or Config.defaults()
  local roster = {}
  for id, meta in pairs(cfg.roster or {}) do
    roster[id] = { name = meta.name, expectedPos = meta.expectedPos, lastPos = meta.lastPos }
  end
  return setmetatable({
    config = cfg,
    modem = opts.modem,
    now = opts.now or function() return os.epoch("utc") end,
    token = opts.token or cfg.updateToken,
    channel = opts.channel or cfg.channel,
    staleMs = opts.staleMs or DEFAULT_STALE_MS,
    save = opts.save or Config.save,
    path = opts.path or Config.PATH,
    roster = roster,
  }, R)
end

--- Get-or-create the roster entry for id (an unknown id is auto-added, carrying no annotations).
function R:_ensure(id)
  local e = self.roster[id]
  if not e then e = {}; self.roster[id] = e end
  return e
end

--- Feed one raw modem_message (channel, replyChannel, msg, distance, now). Recognizes a passive
--- gpsproto broadcast (updates lastPos/lastSeen) or a beacon/update.lua STATUS/ACK reply (updates
--- status/lastReply or lastAck). Auto-adds an unknown id. Returns true iff it matched a beacon
--- frame, else false (anything else, or the wrong channel, is ignored).
function R:onMessage(channel, _replyChannel, msg, _distance, now)
  if self.channel ~= nil and channel ~= self.channel then return false end
  now = now or self.now()

  local g = gpsproto.decode(msg)
  if g then
    local e = self:_ensure(g.id)
    e.lastPos = { x = g.x, y = g.y, z = g.z }
    e.lastSeen = now
    return true
  end

  local f = Update.decode(msg)
  if f then
    if f.k == Update.STATUS_KIND then
      local e = self:_ensure(f.id)
      e.status = {
        enabled = f.enabled,
        pos = f.pos,
        intervalMs = f.intervalMs,
        selfCheck = f.selfCheck,
        constellation = f.constellation,
        seq = f.seq,
      }
      e.lastReply = now
      return true
    elseif f.k == Update.ACK_KIND then
      local e = self:_ensure(f.id)
      e.lastAck = now
      return true
    end
  end

  return false
end

-- A beacon is LIVE if heard directly within staleMs, or a fresh status reply says it's enabled.
local function isLive(now, e, staleMs)
  if e.lastSeen and (now - e.lastSeen) <= staleMs then return true end
  if e.lastReply and (now - e.lastReply) <= staleMs and e.status and e.status.enabled ~= false then return true end
  return false
end

local function freshReply(now, e, staleMs)
  return e.lastReply ~= nil and (now - e.lastReply) <= staleMs
end

local function classify(now, e, staleMs)
  if isLive(now, e, staleMs) then return "LIVE" end
  if freshReply(now, e, staleMs) and e.status and e.status.enabled == false then return "DISABLED" end
  if e.lastQueried and (now - e.lastQueried) <= staleMs then return "OFFLINE" end
  return "SILENT"
end

--- posDrift(expectedPos, lastPos) -> true iff expectedPos is pinned and lastPos differs from it by
--- more than ~2 blocks (Euclidean). Same 2-block placement-noise tolerance idea as
--- beacon/runtime.lua's selfCheck, just applied to the controller's own drift flag.
local function posDrift(expectedPos, lastPos)
  if not expectedPos or not lastPos then return false end
  return dist3(expectedPos, lastPos) > 2
end

--- view(now) -> a list of every known beacon, sorted by id:
---   { id, name, pos (status.pos or lastPos), expectedPos, lastSeen, ageMs, enabled (status.enabled),
---     health (status.selfCheck/constellation/intervalMs), status = LIVE|DISABLED|OFFLINE|SILENT,
---     posDrift, lastReply, lastReplyAgeMs (age since the last STATUS reply -- DIAG's own column,
---     distinct from ageMs which tracks passive-broadcast lastSeen) }
function R:view(now)
  now = now or self.now()
  local ids = {}
  for id in pairs(self.roster) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)

  local out = {}
  for _, id in ipairs(ids) do
    local e = self.roster[id]
    local status = e.status
    out[#out + 1] = {
      id = id,
      name = e.name,
      pos = (status and status.pos) or e.lastPos,
      expectedPos = e.expectedPos,
      lastSeen = e.lastSeen,
      ageMs = e.lastSeen and (now - e.lastSeen) or nil,
      enabled = status and status.enabled,
      health = status and { selfCheck = status.selfCheck, constellation = status.constellation, intervalMs = status.intervalMs } or nil,
      status = classify(now, e, self.staleMs),
      posDrift = posDrift(e.expectedPos, e.lastPos),
      lastReply = e.lastReply,
      lastReplyAgeMs = e.lastReply and (now - e.lastReply) or nil,
    }
  end
  return out
end

--- sendCommand(id, op, args, now) -- fail-closed: refuses (returns false, transmits nothing) unless
--- the controller has a valid token. Targets exactly one beacon id. A "query" op records
--- entry.lastQueried on that beacon.
function R:sendCommand(id, op, args, now)
  if not Update.validToken(self.token) then return false end
  self.modem.transmit(self.channel, self.channel, Update.encode(Update.cmd(op, self.token, args, id)))
  if op == "query" then
    self:_ensure(id).lastQueried = now or self.now()
  end
  return true
end

--- sendCommandAll(op, args, now) -- same fail-closed gate, broadcasts to every beacon (target=nil).
--- A "query" op records lastQueried on every currently-known roster entry.
function R:sendCommandAll(op, args, now)
  if not Update.validToken(self.token) then return false end
  self.modem.transmit(self.channel, self.channel, Update.encode(Update.cmd(op, self.token, args, nil)))
  if op == "query" then
    now = now or self.now()
    for _, e in pairs(self.roster) do e.lastQueried = now end
  end
  return true
end

function R:query(id, now) return self:sendCommand(id, "query", nil, now) end
function R:queryAll(now) return self:sendCommandAll("query", nil, now) end

--- sendReinstall(id, now) -- Phase P6: folds the retired standalone updater (tools/beaconupdate.lua)
--- into the controller. Fail-closed, same gate as sendCommand: refuses (returns false, transmits
--- nothing) unless the controller has a valid token. Sends the LEGACY reinstall command
--- (beacon/update.lua's M.command/CMD_KIND), NOT an op-tagged Update.cmd -- already-deployed
--- beacons predate the op-tagged protocol and only understand this reinstall frame. Targets exactly
--- one beacon id; see beacon/update.lua's M.targeted for the addressing + backward-compat note.
function R:sendReinstall(id, now)
  if not Update.validToken(self.token) then return false end
  self.modem.transmit(self.channel, self.channel, Update.encode(Update.command(self.token, id)))
  return true
end

--- sendReinstallAll(now) -- same fail-closed gate and LEGACY protocol as sendReinstall, broadcasts
--- the reinstall to every beacon (target = nil).
function R:sendReinstallAll(now)
  if not Update.validToken(self.token) then return false end
  self.modem.transmit(self.channel, self.channel, Update.encode(Update.command(self.token)))
  return true
end

--- toConfigRoster() -> the serializable roster { [id] = { name, expectedPos, lastPos } }, stripped
--- of every runtime-only field (lastSeen/status/lastReply/lastQueried/lastAck never persist).
function R:toConfigRoster()
  local out = {}
  for id, e in pairs(self.roster) do
    out[id] = { name = e.name, expectedPos = e.expectedPos, lastPos = e.lastPos }
  end
  return out
end

--- Write the current roster back into self.config and persist it via the injected save fn.
function R:_persist()
  self.config.roster = self:toConfigRoster()
  if self.save then self.save(self.path, self.config) end
end

--- setName(id, name) -- annotate (auto-adding an unknown id) and persist.
function R:setName(id, name)
  self:_ensure(id).name = name
  self:_persist()
end

--- setExpectedPos(id, pos) -- pin the surveyed/expected position (auto-adding an unknown id) and
--- persist.
function R:setExpectedPos(id, pos)
  self:_ensure(id).expectedPos = pos
  self:_persist()
end

--- remove(id) -- drop a beacon from the roster entirely and persist.
function R:remove(id)
  self.roster[id] = nil
  self:_persist()
end

--- setToken(token) -- set the controller's shared secret. Updates BOTH self.token (the live value
--- every send's fail-closed gate reads -- so a freshly-set token works immediately, no reboot) AND
--- config.updateToken, then persists via _persist (which also re-writes the live roster, keeping
--- annotations). A blank/whitespace token is stored as-is; Update.validToken still gates sending, so
--- clearing the token simply disables remote commands again rather than throwing.
function R:setToken(token)
  self.token = token
  self.config.updateToken = token
  self:_persist()
end

return M
