package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local BR = require("beacon.runtime")
local gpsproto = require("nav.comms.gpsproto")

-- A fake ender modem that records what it transmits, so the broadcast is testable with no peripheral.
local function fakeModem()
  return { sent = {}, opened = {},
    open = function(self, ch) self.opened[ch] = true end,
    transmit = function(self, ch, reply, msg) self.sent[#self.sent + 1] = { ch = ch, reply = reply, msg = msg } end,
  }
end
-- CC modems are called method-style (modem.transmit(...)) as globals-free wrapped peripherals; our
-- runtime calls modem.transmit(ch, reply, msg), so bind self.
local function modemFor(m)
  return { open = function(ch) m:open(ch) end, transmit = function(ch, reply, msg) m:transmit(ch, reply, msg) end }
end

local function clockAt(v) local c = { v = v }; return c, function() return c.v end end

t.test("a ready beacon broadcasts its encoded frame on its channel and increments seq", function()
  local raw = fakeModem()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "B1", channel = 65000, enabled = true, pos = { x = 5, y = 6, z = 7 } },
                     modem = modemFor(raw), now = now })
  t.truthy(r:broadcast())
  t.eq(#raw.sent, 1)
  t.eq(raw.sent[1].ch, 65000)
  local f = gpsproto.decode(raw.sent[1].msg)
  t.eq(f.id, "B1"); t.eq(f.x, 5); t.eq(f.y, 6); t.eq(f.z, 7); t.eq(f.seq, 1)
  t.truthy(r:broadcast())
  t.eq(gpsproto.decode(raw.sent[2].msg).seq, 2, "seq advances each broadcast")
end)

t.test("an unconfigured or disabled beacon refuses to broadcast", function()
  local raw = fakeModem()
  local r = BR.new({ config = { id = "B1", channel = 65000, enabled = false, pos = { x = 1, y = 2, z = 3 } },
                     modem = modemFor(raw) })
  t.eq(r:broadcast(), false, "disabled -> no broadcast")
  local r2 = BR.new({ config = { id = "B1", channel = 65000, enabled = true, pos = {} }, modem = modemFor(raw) })
  t.eq(r2:broadcast(), false, "no coordinates -> no broadcast")
  t.eq(#raw.sent, 0)
end)

t.test("hearing peers populates the mesh, excluding our own echo", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "B1", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B2", x = 30, y = 0, z = 0 }), 30)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B1", x = 0, y = 0, z = 0 }), 0) -- own echo
  local peers = r:peers()
  t.truthy(peers.B2 ~= nil, "heard B2")
  t.eq(peers.B1, nil, "our own id is not a peer")
end)

t.test("constellation grading over self + peers uses nav geometry", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B", x = 200, y = 2, z = 0 }), 200)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "C", x = 0, y = 1, z = 200 }), 200)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "D", x = 60, y = 150, z = 60 }), 180)
  local g = r:constellation()
  t.truthy(g.usable, "self + 3 non-coplanar peers -> a usable 4-host constellation")
  t.eq(g.usableHosts, 4)
end)

t.test("runtime selfCheck flags a typo'd peer from the heard mesh", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "B", x = 0, y = 0, z = 40 }), 12) -- claims 40, measured 12
  local sc = r:selfCheck()
  t.truthy(not sc.ok)
  t.eq(sc.mismatches[1].id, "B")
end)

t.test("selfQuality reports GOOD for a wide, flat mesh and POOR for a clustered one", function()
  local Runtime = require("beacon.runtime")
  local selfPos = { x = 824, y = 86, z = 2922 }
  local peers = {
    ["68"] = { pos = { x = 6462,  y = 200, z = 6107  }, dist = 1 },
    ["69"] = { pos = { x = 7144,  y = 65,  z = -7266 }, dist = 1 },
    ["70"] = { pos = { x = -7210, y = 64,  z = -7260 }, dist = 1 },
  }
  local q = Runtime.selfQuality(selfPos, peers)
  t.eq(q.hosts, 4, "self + 3 peers")
  t.truthy(q.quality and q.quality >= 0.75, "wide-flat -> GOOD (" .. tostring(q.quality) .. ")")
  t.truthy(q.errorEst and q.errorEst < 2, "small horizontal error")

  -- A genuinely HORIZONTALLY clustered constellation: all three peers bunched far to +x, at nearly
  -- the same z, all near build height (as MC beacons are) so there is NO vertical spread to rescue
  -- the geometry. Every line-of-sight points the same way -> the horizontal normal matrix is nearly
  -- singular -> huge HDOP -> POOR. (An earlier fixture put one peer 130 blocks below build height,
  -- which is unrealistic for MC beacons and its vertical baseline made the fix well-conditioned ->
  -- GOOD; that hid the honest degeneracy this case is meant to exercise.)
  local clustered = {
    ["68"] = { pos = { x = 5000, y = 92, z = 40  }, dist = 1 },
    ["69"] = { pos = { x = 5100, y = 88, z = -40 }, dist = 1 },
    ["70"] = { pos = { x = 5050, y = 91, z = 80  }, dist = 1 },
  }
  local qc = Runtime.selfQuality({ x = 0, y = 90, z = 0 }, clustered)
  t.truthy(qc.quality and qc.quality < 0.5, "clustered -> POOR (" .. tostring(qc.quality) .. ")")
end)

t.test("selfQuality with fewer than 4 hosts reports hosts only", function()
  local Runtime = require("beacon.runtime")
  local q = Runtime.selfQuality({ x = 0, y = 0, z = 0 }, { ["a"] = { pos = { x = 10, y = 0, z = 0 }, dist = 1 } })
  t.eq(q.hosts, 2)
  t.eq(q.quality, nil, "no quality below 4 hosts")
end)

t.test("statusPayload reports enabled/pos/intervalMs/seq + selfCheck/constellation summaries", function()
  local c, now = clockAt(1000)
  local selfPos = { x = 824, y = 86, z = 2922 }
  local r = BR.new({ config = { id = "A", channel = 65000, enabled = true, intervalMs = 2500, pos = selfPos },
                     modem = modemFor(fakeModem()), now = now })
  -- 3 wide, flat peers -> a usable/GOOD constellation, matching the earlier selfQuality GOOD fixture.
  -- Measured dist = the true geoDistance to selfPos, so selfCheck agrees (no typo -> no mismatch).
  local peers = {
    { id = "68", x = 6462,  y = 200, z = 6107  },
    { id = "69", x = 7144,  y = 65,  z = -7266 },
    { id = "70", x = -7210, y = 64,  z = -7260 },
  }
  for _, p in ipairs(peers) do
    local dist = BR.geoDistance(selfPos, p)
    r:onModemMessage(65000, 65000, gpsproto.encode({ id = p.id, x = p.x, y = p.y, z = p.z }), dist)
  end
  r:broadcast(); r:broadcast()   -- seq = 2

  local sp = r:statusPayload()
  t.eq(sp.enabled, true)
  t.eq(sp.pos.x, 824); t.eq(sp.pos.y, 86); t.eq(sp.pos.z, 2922)
  t.eq(sp.intervalMs, 2500)
  t.eq(sp.seq, 2)
  t.truthy(sp.selfCheck, "has a selfCheck summary")
  t.eq(sp.selfCheck.ok, true)
  t.eq(sp.selfCheck.mismatches, 0, "count, not the mismatch list")
  t.truthy(sp.constellation, "has a constellation summary")
  t.eq(sp.constellation.hosts, 4)
  t.eq(sp.constellation.grade, "GOOD")
  t.truthy(sp.constellation.errorEst and sp.constellation.errorEst < 2)
end)

t.test("statusPayload: enabled defaults true when unset; grade WAITING under 4 hosts", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, pos = { x = 0, y = 0, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  local sp = r:statusPayload()
  t.eq(sp.enabled, true, "unset enabled defaults to true")
  t.eq(sp.constellation.hosts, 1, "just self, no peers heard")
  t.eq(sp.constellation.grade, "WAITING")
  t.eq(sp.seq, 0)
end)

t.test("statusPayload: disabled config + FAIR/POOR grades", function()
  local c, now = clockAt(1000)
  local r = BR.new({ config = { id = "A", channel = 65000, enabled = false, pos = { x = 0, y = 90, z = 0 } },
                     modem = modemFor(fakeModem()), now = now })
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "68", x = 5000, y = 92, z = 40  }), 1)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "69", x = 5100, y = 88, z = -40 }), 1)
  r:onModemMessage(65000, 65000, gpsproto.encode({ id = "70", x = 5050, y = 91, z = 80  }), 1)
  local sp = r:statusPayload()
  t.eq(sp.enabled, false)
  t.eq(sp.constellation.grade, "POOR", "clustered mesh -> POOR")
end)
