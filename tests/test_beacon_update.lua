package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local U = require("beacon.update")
local gpsproto = require("nav.comms.gpsproto")

t.test("validToken rejects nil/non-string/blank, accepts real strings", function()
  t.eq(U.validToken(nil), false)
  t.eq(U.validToken(123), false)
  t.eq(U.validToken(""), false)
  t.eq(U.validToken("   "), false)
  t.eq(U.validToken("s3cret"), true)
end)

t.test("command/ack build the right shapes", function()
  t.eq(U.command("tok").k, U.CMD_KIND); t.eq(U.command("tok").token, "tok")
  t.eq(U.ack("beacon-7").k, U.ACK_KIND); t.eq(U.ack("beacon-7").id, "beacon-7")
end)

t.test("encode/decode round-trips a command and an ack", function()
  local c = U.decode(U.encode(U.command("tok")))
  t.truthy(c and c.k == U.CMD_KIND and c.token == "tok", "command survives")
  local a = U.decode(U.encode(U.ack("b1")))
  t.truthy(a and a.k == U.ACK_KIND and a.id == "b1", "ack survives")
end)

t.test("decode returns nil for a GPS frame and for garbage", function()
  t.eq(U.decode(gpsproto.encode({ id = "b1", x = 1, y = 2, z = 3 })), nil)
  t.eq(U.decode("not a frame"), nil)
end)

t.test("gpsproto.decode returns nil for an update frame (coexistence)", function()
  t.eq(gpsproto.decode(U.encode(U.command("tok"))), nil)
end)

t.test("accepts is the fail-closed gate", function()
  t.eq(U.accepts(U.command("tok"), "tok"), true, "valid match accepted")
  t.eq(U.accepts(U.command("tok"), "other"), false, "mismatch rejected")
  t.eq(U.accepts(U.command("tok"), ""), false, "blank config token rejected")
  t.eq(U.accepts(U.command(""), "tok"), false, "blank command token rejected")
  t.eq(U.accepts(U.ack("b1"), "tok"), false, "non-command rejected")
  t.eq(U.accepts(nil, "tok"), false, "nil frame rejected")
end)

t.test("cmd builds an op-tagged, token-carrying command frame", function()
  local U = require("beacon.update")
  local f = U.cmd("enable", "tok")
  t.eq(f.k, U.CMD2_KIND); t.eq(f.op, "enable"); t.eq(f.token, "tok")
  local g = U.cmd("setInterval", "tok", { intervalMs = 3000 })
  t.eq(g.args.intervalMs, 3000)
end)

t.test("decode round-trips cmd + status; rejects GPS + unknown kinds", function()
  local U = require("beacon.update")
  local cmd = U.decode(U.encode(U.cmd("query", "tok")))
  t.truthy(cmd and cmd.op == "query")
  local st = U.decode(U.encode(U.status("beacon-70", { enabled = false, seq = 5 })))
  t.truthy(st and st.id == "beacon-70" and st.enabled == false and st.seq == 5)
  t.eq(U.decode('{"x":1,"y":2,"z":3}'), nil)   -- a GPS frame is not a command
end)

t.test("acceptsCmd is fail-closed: known op + matching valid token only", function()
  local U = require("beacon.update")
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), "tok"), true)
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), "other"), false)   -- token mismatch
  t.eq(U.acceptsCmd(U.cmd("enable", ""), "tok"), false)        -- blank sender token
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), ""), false)        -- unprovisioned beacon
  t.eq(U.acceptsCmd(U.cmd("nuke", "tok"), "tok"), false)       -- unknown op
  t.eq(U.acceptsCmd({ k = U.CMD_KIND, token = "tok" }, "tok"), false)  -- wrong kind (that's the update cmd)
  t.eq(U.acceptsCmd(nil, "tok"), false)
end)
