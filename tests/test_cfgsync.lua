-- tests/test_cfgsync.lua
local t = require("tests.framework")
local S = require("fcs.comms.cfgsync")

t.test("responder answers req with cfg only when the provider has it", function()
  local reply = S.Responder.decide(S.req("x", "tuning"), function(k) return k=="tuning" and "BODY" or nil end)
  t.eq(reply.k, "cfg"); t.eq(reply.kind, "tuning"); t.eq(reply.body, "BODY"); t.eq(reply.sid, "x")
  t.eq(S.Responder.decide(S.req("x","senscal"), function() return nil end), nil, "no body -> no reply")
end)

t.test("client walks hello -> req per kind -> done", function()
  local c = S.Client.new({ sid = "s1", kinds = { "tuning" }, timeout = 1 })
  t.eq(c:next().k, "hello"); t.eq(c:next().k, "cfg" and "req" or "req")  -- first req
  t.eq(c:onFrame(S.cfg("s1", "tuning", "B")), "done"); t.eq(c.received.tuning, "B")
end)

t.test("set/ack frame builders carry sid/kind/ok/err", function()
  local s = S.set("s2", "tuning", { gains = 1 })
  t.eq(s.k, "set"); t.eq(s.sid, "s2"); t.eq(s.kind, "tuning"); t.eq(s.body.gains, 1)
  local a = S.ack("s2", "tuning", true, nil)
  t.eq(a.k, "ack"); t.eq(a.sid, "s2"); t.eq(a.kind, "tuning"); t.eq(a.ok, true); t.eq(a.err, nil)
  t.eq(S.ack("s2", "tuning", false, "bad").ok, false)
  t.eq(S.ack("s2", "tuning", nil, "bad").ok, false, "ok is always a bool")
end)

t.test("responder applies a set via the injected applier and returns an ack", function()
  local seen = {}
  local applier = function(kind, body) seen.kind = kind; seen.body = body; return true, nil end
  local reply = S.Responder.decide(S.set("s3", "devbind", { thrusters = {} }), nil, applier)
  t.eq(reply.k, "ack"); t.eq(reply.kind, "devbind"); t.eq(reply.ok, true); t.eq(reply.sid, "s3")
  t.eq(seen.kind, "devbind"); t.truthy(seen.body.thrusters ~= nil)
end)

t.test("responder ack carries the applier's failure reason", function()
  local reply = S.Responder.decide(S.set("s4", "tuning", {}), nil, function() return false, "missing gains" end)
  t.eq(reply.k, "ack"); t.eq(reply.ok, false); t.eq(reply.err, "missing gains")
end)

t.test("a set with no applier is ignored (nil), and req still works unchanged", function()
  t.eq(S.Responder.decide(S.set("s5", "tuning", {}), nil, nil), nil, "no applier -> silent")
  local r = S.Responder.decide(S.req("s5", "tuning"), function(k) return k == "tuning" and "BODY" or nil end)
  t.eq(r.k, "cfg"); t.eq(r.body, "BODY")
end)
