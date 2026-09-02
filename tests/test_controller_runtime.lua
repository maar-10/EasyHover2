package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local CR = require("controller.runtime")
local Update = require("beacon.update")
local gpsproto = require("nav.comms.gpsproto")

-- A fake ender modem that records what it transmits, so sending is testable with no peripheral.
local function fakeModem()
  return { sent = {},
    transmit = function(self, ch, reply, msg) self.sent[#self.sent + 1] = { ch = ch, reply = reply, msg = msg } end,
  }
end
-- CC modems are called method-style; our runtime calls modem.transmit(ch, reply, msg) as a plain
-- function, so bind self (mirrors beacon/runtime.lua's tests).
local function modemFor(m)
  return { transmit = function(ch, reply, msg) m:transmit(ch, reply, msg) end }
end

local function clockAt(v) local c = { v = v }; return c, function() return c.v end end

t.test("hearing a gpsproto broadcast adds an unknown id, then updates its lastPos+lastSeen", function()
  local c, now = clockAt(1000)
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = now })
  local matched = r:onMessage(65000, 65000, gpsproto.encode({ id = "B1", x = 10, y = 20, z = 30 }), 40, 1000)
  t.truthy(matched, "a gpsproto broadcast matches")
  local v = r:view(1000)
  t.eq(#v, 1)
  t.eq(v[1].id, "B1")
  t.eq(v[1].pos.x, 10); t.eq(v[1].pos.y, 20); t.eq(v[1].pos.z, 30)
  t.eq(v[1].lastSeen, 1000)

  c.v = 1500
  r:onMessage(65000, 65000, gpsproto.encode({ id = "B1", x = 11, y = 20, z = 30 }), 40, 1500)
  local v2 = r:view(1500)
  t.eq(v2[1].pos.x, 11, "lastPos updates on a fresh broadcast")
  t.eq(v2[1].lastSeen, 1500)
end)

t.test("an Update STATUS frame merges enabled/health into the roster entry", function()
  local c, now = clockAt(2000)
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = now })
  local status = Update.status("B2", {
    enabled = false, pos = { x = 1, y = 2, z = 3 }, intervalMs = 2500,
    selfCheck = { ok = true, mismatches = 0 }, constellation = { hosts = 4, grade = "GOOD" }, seq = 7,
  })
  local matched = r:onMessage(65000, 65000, Update.encode(status), nil, 2000)
  t.truthy(matched, "a STATUS frame matches")
  local v = r:view(2000)
  t.eq(#v, 1)
  t.eq(v[1].id, "B2")
  t.eq(v[1].enabled, false)
  t.truthy(v[1].health, "health summary present")
  t.eq(v[1].health.selfCheck.ok, true)
  t.eq(v[1].health.constellation.grade, "GOOD")
  t.eq(v[1].health.intervalMs, 2500, "the beacon's own broadcast interval rides the STATUS reply")
  t.eq(v[1].lastReplyAgeMs, 0, "just replied -- age since the STATUS reply is 0 at this instant")

  c.v = 2400
  local v2 = r:view(2400)
  t.eq(v2[1].lastReplyAgeMs, 400, "lastReplyAgeMs advances with the clock, independent of ageMs (lastSeen)")
end)

t.test("an Update ACK frame sets lastAck (does not raise/crash, matches)", function()
  local c, now = clockAt(3000)
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = now })
  local matched = r:onMessage(65000, 65000, Update.encode(Update.ack("B3")), nil, 3000)
  t.truthy(matched, "an ACK frame matches")
  t.eq(r.roster.B3.lastAck, 3000)
end)

t.test("onMessage ignores anything that isn't a beacon/GPS/update frame", function()
  local c, now = clockAt(1000)
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = now })
  local matched = r:onMessage(65000, 65000, "garbage, not a frame", nil, 1000)
  t.eq(matched, false)
  t.eq(#r:view(1000), 0)
end)

t.test("view classifies LIVE / DISABLED / OFFLINE / SILENT by staleness", function()
  local c, now = clockAt(1000)
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()),
                     now = now, staleMs = 1000 })

  -- A: heard directly (broadcast) at t=1000.
  r:onMessage(65000, 65000, gpsproto.encode({ id = "A", x = 0, y = 0, z = 0 }), 1, 1000)
  -- B: a fresh STATUS reply saying enabled at t=1000.
  r:onMessage(65000, 65000, Update.encode(Update.status("B", { enabled = true })), nil, 1000)
  -- C: a fresh STATUS reply saying disabled at t=1000.
  r:onMessage(65000, 65000, Update.encode(Update.status("C", { enabled = false })), nil, 1000)
  -- D: known only via the seeded roster -- never heard, replied, or queried.
  r.roster.D = { name = "spare" }
  -- E: queried (no reply yet) at t=1000.
  t.truthy(r:sendCommand("E", "query", nil, 1000))

  do
    local rows = {}
    for _, row in ipairs(r:view(1500)) do rows[row.id] = row.status end -- +500ms: still fresh
    t.eq(rows.A, "LIVE", "heard within staleMs")
    t.eq(rows.B, "LIVE", "fresh reply says enabled")
    t.eq(rows.C, "DISABLED", "fresh reply says disabled")
    t.eq(rows.D, "SILENT", "known but never heard/replied/queried")
    t.eq(rows.E, "OFFLINE", "queried recently, no reply yet")
  end

  do
    local rows = {}
    for _, row in ipairs(r:view(2500)) do rows[row.id] = row.status end -- +1500ms: all stale now
    t.eq(rows.A, "SILENT", "broadcast aged out, no query/reply keeping it up")
    t.eq(rows.B, "SILENT", "reply aged out")
    t.eq(rows.C, "SILENT", "reply aged out")
    t.eq(rows.D, "SILENT")
    t.eq(rows.E, "SILENT", "query aged out with no reply ever received")
  end
end)

t.test("sendCommand transmits a targeted Update.cmd carrying the token", function()
  local raw = fakeModem()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok123", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.truthy(r:sendCommand("B1", "enable", nil, 5000))
  t.eq(#raw.sent, 1)
  t.eq(raw.sent[1].ch, 65000)
  local f = Update.decode(raw.sent[1].msg)
  t.eq(f.op, "enable")
  t.eq(f.token, "tok123")
  t.eq(f.target, "B1")
end)

t.test("sendCommand refuses (no transmit) when the token is blank or nil -- fail-closed", function()
  local raw = fakeModem()
  local r1 = CR.new({ config = { channel = 65000, updateToken = nil, roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r1:sendCommand("B1", "enable", nil, 5000), false)
  local r2 = CR.new({ config = { channel = 65000, updateToken = "   ", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r2:sendCommand("B1", "enable", nil, 5000), false)
  t.eq(#raw.sent, 0, "nothing transmitted either way")
end)

t.test("sendCommandAll refuses (no transmit) when the token is blank or nil -- fail-closed", function()
  local raw = fakeModem()
  local r1 = CR.new({ config = { channel = 65000, updateToken = nil, roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r1:sendCommandAll("disable", nil, 5000), false)
  local r2 = CR.new({ config = { channel = 65000, updateToken = "   ", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r2:sendCommandAll("disable", nil, 5000), false)
  t.eq(#raw.sent, 0, "nothing transmitted either way")
end)

t.test("queryAll refuses (no transmit) when the token is blank or nil -- fail-closed", function()
  local raw = fakeModem()
  local r1 = CR.new({ config = { channel = 65000, updateToken = nil, roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r1:queryAll(5000), false)
  local r2 = CR.new({ config = { channel = 65000, updateToken = "   ", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r2:queryAll(5000), false)
  t.eq(#raw.sent, 0, "nothing transmitted either way")
end)

t.test("sendCommandAll / queryAll broadcast with target=nil", function()
  local raw = fakeModem()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.truthy(r:queryAll(5000))
  t.eq(#raw.sent, 1)
  local f = Update.decode(raw.sent[1].msg)
  t.eq(f.op, "query")
  t.eq(f.target, nil, "broadcast to all -- no single target")
end)

t.test("query() records lastQueried on the targeted entry; queryAll() records it for the whole roster", function()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = { B1 = {}, B2 = {} } }, modem = modemFor(fakeModem()), now = function() return 9000 end })
  t.truthy(r:query("B1", 9000))
  t.eq(r.roster.B1.lastQueried, 9000)
  t.eq(r.roster.B2.lastQueried, nil, "only the targeted beacon is marked queried")
  t.truthy(r:queryAll(9500))
  t.eq(r.roster.B1.lastQueried, 9500)
  t.eq(r.roster.B2.lastQueried, 9500, "queryAll marks every known beacon")
end)

t.test("posDrift is true when the heard position is >2 blocks from a pinned expectedPos", function()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = function() return 1000 end })
  r:onMessage(65000, 65000, gpsproto.encode({ id = "A", x = 5, y = 0, z = 0 }), 5, 1000) -- 5 blocks off
  r:onMessage(65000, 65000, gpsproto.encode({ id = "B", x = 1, y = 0, z = 0 }), 1, 1000) -- 1 block off
  r:setExpectedPos("A", { x = 0, y = 0, z = 0 })
  r:setExpectedPos("B", { x = 0, y = 0, z = 0 })
  local rows = {}
  for _, row in ipairs(r:view(1000)) do rows[row.id] = row end
  t.truthy(rows.A.posDrift, "5 blocks off -> drift flagged")
  t.truthy(not rows.B.posDrift, "1 block off -> within tolerance, no drift")
end)

t.test("posDrift is false when no expectedPos is pinned", function()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(fakeModem()), now = function() return 1000 end })
  r:onMessage(65000, 65000, gpsproto.encode({ id = "A", x = 500, y = 0, z = 0 }), 500, 1000)
  local rows = r:view(1000)
  t.truthy(not rows[1].posDrift)
end)

t.test("setName / setExpectedPos / remove mutate the roster and persist the config roster", function()
  local saved = {}
  local function fakeSave(path, cfg) saved[#saved + 1] = { path = path, cfg = cfg } end
  local cfg = { channel = 65000, updateToken = "tok", roster = {} }
  local r = CR.new({ config = cfg, modem = modemFor(fakeModem()), now = function() return 1000 end, save = fakeSave, path = "/test_ctrl.tbl" })

  r:setName("B1", "North pad")
  t.eq(r.roster.B1.name, "North pad")
  t.eq(#saved, 1)
  t.eq(saved[1].path, "/test_ctrl.tbl")
  t.eq(saved[1].cfg.roster.B1.name, "North pad")

  r:setExpectedPos("B1", { x = 4, y = 5, z = 6 })
  t.eq(r.roster.B1.expectedPos.x, 4)
  t.eq(#saved, 2)
  t.eq(saved[2].cfg.roster.B1.expectedPos.z, 6)
  t.eq(saved[2].cfg.roster.B1.name, "North pad", "earlier annotation survives")

  r:remove("B1")
  t.eq(r.roster.B1, nil)
  t.eq(#saved, 3)
  t.eq(saved[3].cfg.roster.B1, nil, "removed from the persisted roster too")
end)

-- ===== P6: sendReinstall / sendReinstallAll -- the LEGACY reinstall command, folded from the
-- retired standalone updater (tools/beaconupdate.lua). Already-deployed beacons only understand
-- Update.command (beacon/update.lua's CMD_KIND), NOT the op-tagged Update.cmd used by sendCommand.

t.test("sendReinstall transmits a targeted LEGACY reinstall (Update.command) carrying the token", function()
  local raw = fakeModem()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok123", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.truthy(r:sendReinstall("B1", 5000))
  t.eq(#raw.sent, 1)
  t.eq(raw.sent[1].ch, 65000)
  local f = Update.decode(raw.sent[1].msg)
  t.eq(f.k, Update.CMD_KIND, "the LEGACY reinstall kind, not the op-tagged CMD2_KIND")
  t.eq(f.token, "tok123")
  t.eq(f.target, "B1")
end)

t.test("sendReinstallAll transmits a broadcast LEGACY reinstall (target=nil)", function()
  local raw = fakeModem()
  local r = CR.new({ config = { channel = 65000, updateToken = "tok", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.truthy(r:sendReinstallAll(5000))
  t.eq(#raw.sent, 1)
  local f = Update.decode(raw.sent[1].msg)
  t.eq(f.k, Update.CMD_KIND)
  t.eq(f.token, "tok")
  t.eq(f.target, nil, "broadcast to all -- no single target")
end)

t.test("sendReinstall / sendReinstallAll refuse (no transmit) when the token is blank or nil -- fail-closed", function()
  local raw = fakeModem()
  local r1 = CR.new({ config = { channel = 65000, updateToken = nil, roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r1:sendReinstall("B1", 5000), false)
  t.eq(r1:sendReinstallAll(5000), false)
  local r2 = CR.new({ config = { channel = 65000, updateToken = "   ", roster = {} }, modem = modemFor(raw), now = function() return 5000 end })
  t.eq(r2:sendReinstall("B1", 5000), false)
  t.eq(r2:sendReinstallAll(5000), false)
  t.eq(#raw.sent, 0, "nothing transmitted either way")
end)

t.test("the runtime seeds its roster from config.roster; every seeded id starts SILENT", function()
  local cfg = {
    channel = 65000, updateToken = "tok",
    roster = { B1 = { name = "North pad", expectedPos = { x = 1, y = 2, z = 3 }, lastPos = { x = 1, y = 2, z = 3 } } },
  }
  local r = CR.new({ config = cfg, modem = modemFor(fakeModem()), now = function() return 1000 end })
  local v = r:view(1000)
  t.eq(#v, 1)
  t.eq(v[1].id, "B1")
  t.eq(v[1].name, "North pad")
  t.eq(v[1].pos.x, 1, "seeded lastPos carried into the view")
  t.eq(v[1].status, "SILENT", "seeded, never heard -- starts SILENT")
end)
