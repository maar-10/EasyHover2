-- beacon/runtime.lua
-- A GPS beacon's behaviour, Basalt-free and peripheral-injected so it self-tests headless. A beacon
--   (1) periodically BROADCASTS { id, x, y, z, seq } on the GPS channel (the launcher, T4, owns the
--       sleep-between-broadcasts timer -- this module just builds + sends one frame per call, so it
--       can never busy-wait);
--   (2) HEARS the other beacons on the same channel (via the shared nav receiver) and, from that
--       mesh, runs a SELF-CHECK -- measured range vs configured geometry -- to catch a typo'd
--       coordinate, plus a constellation grade so a beacon screen can say whether NAV can get a fix.
-- Reception + broadcasting live only on beacon/NAV computers; the FCS never opens this channel.
local gpsproto = require("nav.comms.gpsproto")
local Receiver = require("nav.comms.receiver")
local geometry = require("nav.lib.geometry")

local M = {}
local R = {}
R.__index = R

-- blocks: configured-vs-measured range disagreement above this = MISMATCH. The check exists to catch
-- gross coordinate TYPOS (a wrong digit / sign is tens-to-thousands of blocks off), NOT sub-block
-- precision. A benign gap of ~1-2 blocks is normal: CC's modem_message distance is measured
-- modem-block to modem-block, while the configured coordinate is whatever the operator entered (F3
-- player pos, not the exact modem block), so 1.0 false-flagged correctly-placed beacons. 5 clears
-- that placement noise while still catching any real typo loudly. Per-beacon config.tolerance overrides.
M.DEFAULT_TOLERANCE = 5.0

--- Plain Euclidean distance between two {x,y,z}.
function M.geoDistance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function validPos(p)
  return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

--- selfCheck(selfPos, peers, tolerance) -> { ok, checked, mismatches = {{id,measured,expected,delta}} }.
--- peers: { [id] = { pos={x,y,z}, dist=n|nil } } (receiver:beacons()). Only peers with a measured
--- distance are checkable; results sorted by id for a stable screen.
function M.selfCheck(selfPos, peers, tolerance)
  tolerance = tolerance or M.DEFAULT_TOLERANCE
  local mism, checked = {}, 0
  if validPos(selfPos) then
    for id, p in pairs(peers or {}) do
      if type(p.dist) == "number" and validPos(p.pos) then
        checked = checked + 1
        local expected = M.geoDistance(selfPos, p.pos)
        local delta = math.abs(p.dist - expected)
        if delta > tolerance then
          mism[#mism + 1] = { id = id, measured = p.dist, expected = expected, delta = delta }
        end
      end
    end
  end
  table.sort(mism, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return { ok = (#mism == 0), checked = checked, mismatches = mism }
end

--- constellation(selfPos, peers) -> geometry.grade over this beacon + every heard peer position.
function M.constellation(selfPos, peers)
  local list = {}
  if validPos(selfPos) then list[#list + 1] = { x = selfPos.x, y = selfPos.y, z = selfPos.z } end
  local ids = {}
  for id in pairs(peers or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local p = peers[id]
    if validPos(p.pos) then list[#list + 1] = { x = p.pos.x, y = p.pos.y, z = p.pos.z } end
  end
  return geometry.grade(list)
end

-- selfQuality grades HDOP at atPos == selfPos itself, so a naive [self + peers] host list always
-- has self exactly coincide with atPos -- a zero-range, zero-information host that geometry.hdop's
-- shared normalInvDiag rightly excludes (see its `r > 1e-6` guard). That drops the *usable* host
-- count by one, so geometry.hdop's hard `#hosts/used >= REQUIRED_HOSTS(4)` gate can never pass for
-- self + 3 peers. Unlike NAV's real trilateration (unknown position -- needs a 4th host to resolve
-- gps.locate()'s mirror ambiguity), a beacon already KNOWS its own position is the correct root, so
-- grading only needs the ranging hosts (peers) to well-condition a 3x3 system: 3 non-coplanar
-- directions, not 4. That relaxed threshold isn't expressible through the exported geometry.hdop
-- (its gate is hardcoded to REQUIRED_HOSTS), so horizontalDop reimplements normalInvDiag's math
-- locally, over peers only, requiring REQUIRED_HOSTS - 1 real hosts instead of REQUIRED_HOSTS.
local MIN_RANGING_HOSTS = geometry.REQUIRED_HOSTS - 1

local function horizontalDop(hosts, atPos)
  if type(hosts) ~= "table" or type(atPos) ~= "table" then return nil end
  local nxx, nxy, nxz, nyy, nyz, nzz = 0, 0, 0, 0, 0, 0
  local used = 0
  for _, ho in ipairs(hosts) do
    local dx, dy, dz = atPos.x - ho.x, atPos.y - ho.y, atPos.z - ho.z
    local r = math.sqrt(dx * dx + dy * dy + dz * dz)
    if r > 1e-6 then
      used = used + 1
      local ux, uy, uz = dx / r, dy / r, dz / r
      nxx = nxx + ux * ux; nxy = nxy + ux * uy; nxz = nxz + ux * uz
      nyy = nyy + uy * uy; nyz = nyz + uy * uz
      nzz = nzz + uz * uz
    end
  end
  if used < MIN_RANGING_HOSTS then return nil end
  -- Symmetric normal matrix N = [[nxx,nxy,nxz],[nxy,nyy,nyz],[nxz,nyz,nzz]]; invert via cofactors
  -- and keep only the horizontal (x,z) diagonal terms of N^-1 -- exactly geometry.hdop's math.
  local det = nxx * (nyy * nzz - nyz * nyz) - nxy * (nxy * nzz - nyz * nxz) + nxz * (nxy * nyz - nyy * nxz)
  if math.abs(det) < 1e-12 then return nil end
  local ixx = (nyy * nzz - nyz * nyz) / det
  local izz = (nxx * nyy - nxy * nxy) / det
  local sum = ixx + izz
  if sum <= 0 then return nil end
  return math.sqrt(sum)
end

--- selfQuality(selfPos, peers) -> { hosts, quality?, errorEst? }. HORIZONTAL fix quality this
--- beacon would give NAV, graded at its OWN position over [self + heard peers] -- the honest,
--- HDOP-based metric (matches nav/runtime + nav/ui/main). < 4 hosts -> hosts only (no quality).
function M.selfQuality(selfPos, peers)
  local list, peerList = {}, {}
  if validPos(selfPos) then list[#list + 1] = { x = selfPos.x, y = selfPos.y, z = selfPos.z } end
  local ids = {}
  for id in pairs(peers or {}) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(ids) do
    local p = peers[id]
    if validPos(p.pos) then
      local pos = { x = p.pos.x, y = p.pos.y, z = p.pos.z }
      list[#list + 1] = pos
      peerList[#peerList + 1] = pos
    end
  end
  local hosts = #list
  if hosts < geometry.REQUIRED_HOSTS or not validPos(selfPos) then return { hosts = hosts } end
  local dq = geometry.dopQuality(horizontalDop(peerList, selfPos))
  return { hosts = hosts, quality = dq.quality, errorEst = dq.errorEst }
end

--- new(opts): config (beacon.config-shaped), modem (raw dev with .transmit/.open), now (fn->ms),
--- receiver (defaults to a fresh nav receiver on the config channel).
function M.new(opts)
  opts = opts or {}
  local cfg = opts.config or {}
  return setmetatable({
    config = cfg,
    modem = opts.modem,
    now = opts.now or function() return os.epoch("utc") end,
    seq = 0,
    receiver = opts.receiver or Receiver.new({ channel = cfg.channel, now = opts.now }),
  }, R)
end

--- Can this beacon broadcast right now? Needs an enabled, id'd, positioned config + a modem.
function R:ready()
  local c = self.config
  return c.enabled ~= false and c.id ~= nil and validPos(c.pos) and c.channel ~= nil and self.modem ~= nil
end

--- Build one broadcast frame at the current seq.
function R:frame()
  local c = self.config
  return { id = c.id, x = c.pos.x, y = c.pos.y, z = c.pos.z, seq = self.seq }
end

--- Send one broadcast (seq++). Returns true if sent, false if not ready. The launcher calls this on
--- a timer and sleeps between calls -- never a busy loop.
function R:broadcast()
  if not self:ready() then return false end
  self.seq = self.seq + 1
  self.modem.transmit(self.config.channel, self.config.channel, gpsproto.encode(self:frame()))
  return true
end

--- Feed a raw modem_message (channel, replyChannel, msg, distance) to the mesh receiver.
function R:onModemMessage(channel, replyChannel, msg, distance)
  return self.receiver:onMessage(channel, replyChannel, msg, distance)
end

--- The heard peers, excluding our own id (a stray self-echo never counts as a peer).
function R:peers(now)
  local all = self.receiver:beacons(now)
  if self.config.id ~= nil then all[self.config.id] = nil end
  return all
end

function R:selfCheck(now)
  return M.selfCheck(self.config.pos, self:peers(now), self.config.tolerance)
end

function R:constellation(now)
  return M.constellation(self.config.pos, self:peers(now))
end

function R:selfQuality(now)
  return M.selfQuality(self.config.pos, self:peers(now))
end

-- Same GOOD/FAIR/POOR/WAITING thresholds the console uses (see beacon/console.lua): quality >= 0.75
-- GOOD, >= 0.4 FAIR, else POOR; under 4 hosts (still gathering peers) is WAITING, not graded at all.
local function qualityGrade(sq)
  if (sq.hosts or 0) < 4 or not sq.quality then return "WAITING" end
  local q = sq.quality
  if q >= 0.75 then return "GOOD" end
  if q >= 0.4 then return "FAIR" end
  return "POOR"
end

--- statusPayload(now) -> the DIAG query reply payload (see beacon/update.lua's M.status).
function R:statusPayload(now)
  local c = self.config
  local sc = self:selfCheck(now)
  local sq = self:selfQuality(now)
  return {
    enabled = c.enabled ~= false,
    pos = c.pos,
    intervalMs = c.intervalMs,
    selfCheck = { ok = sc.ok, mismatches = #(sc.mismatches or {}) },
    constellation = { hosts = sq.hosts, grade = qualityGrade(sq), errorEst = sq.errorEst },
    seq = self.seq,
  }
end

return M
