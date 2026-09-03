-- tests/test_cfgclient.lua
local t = require("tests.framework")
local C = require("ui.basalt.cfgclient")
local S = require("fcs.comms.cfgsync")

-- A mock link: records every frame passed to :send.
local function mockLink()
  local sent = {}
  return { sent = sent, send = function(self, f) sent[#sent + 1] = f end }
end

t.test("readKind sends hello+req and delivers a matching cfg reply to the callback", function()
  local link = mockLink()
  local c = C.new({ link = link, now = function() return 1000 end })
  local got
  local sid = c:readKind("tuning", function(body) got = body end)
  t.eq(link.sent[1].k, "hello"); t.eq(link.sent[2].k, "req"); t.eq(link.sent[2].kind, "tuning")
  t.eq(c:onReply(S.cfg(sid, "tuning", { gains = 7 }), 1100), true, "reply resolved a pending read")
  t.eq(got.gains, 7)
  t.eq(c:onReply(S.cfg(sid, "tuning", { gains = 9 }), 1200), false, "already resolved -> no double fire")
end)

t.test("a cfg reply with a mismatched sid or kind is ignored", function()
  local c = C.new({ link = mockLink(), now = function() return 0 end })
  local fired = false
  local sid = c:readKind("tuning", function() fired = true end)
  t.eq(c:onReply(S.cfg("other", "tuning", {}), 1), false)
  t.eq(c:onReply(S.cfg(sid, "senscal", {}), 1), false)
  t.eq(fired, false)
end)

t.test("writeKind sends a set and delivers the ack (ok/err) to the callback", function()
  local link = mockLink()
  local c = C.new({ link = link, now = function() return 0 end })
  local okSeen, errSeen, called
  local sid = c:writeKind("devbind", { thrusters = {} }, function(ok, err) called = true; okSeen = ok; errSeen = err end)
  t.eq(link.sent[1].k, "set"); t.eq(link.sent[1].kind, "devbind")
  c:onReply(S.ack(sid, "devbind", false, "missing sensors"), 1)
  t.eq(called, true); t.eq(okSeen, false); t.eq(errSeen, "missing sensors")
end)

t.test("tick resends up to `retries` attempts then fails the callback", function()
  local now = 0
  local link = mockLink()
  local c = C.new({ link = link, retries = 3, timeout = 2.0, now = function() return now end })
  local failBody, failCalled = "unset", false
  c:readKind("tuning", function(body) failCalled = true; failBody = body end)
  -- attempt 1 already sent (hello+req = 2 frames). Advance past each deadline: 2 more attempts.
  now = 2000; c:tick(now)   -- attempt 2
  now = 4000; c:tick(now)   -- attempt 3
  t.truthy(#link.sent >= 6, "three attempts each sent hello+req")
  t.eq(failCalled, false, "not failed yet -- retries not exhausted")
  now = 6000; c:tick(now)   -- past attempt 3's deadline, tries == retries -> fail
  t.eq(failCalled, true); t.eq(failBody, nil, "read failure delivers nil")
end)

t.test("tick failure for a write delivers (false, 'FCS not answering')", function()
  local now = 0
  local c = C.new({ link = mockLink(), retries = 1, timeout = 2.0, now = function() return now end })
  local ok, err, called
  c:writeKind("tuning", {}, function(o, e) called = true; ok = o; err = e end)
  now = 2000; c:tick(now)
  t.eq(called, true); t.eq(ok, false); t.eq(err, "FCS not answering")
end)
