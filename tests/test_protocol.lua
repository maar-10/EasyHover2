-- tests/test_protocol.lua
local t = require("tests.framework")
local protocol = require("fcs.comms.protocol")

t.test("encode/decode round-trips a table frame", function()
  local f = { k = "cmd", id = 7, cmd = { k = "engage" } }
  local dec = protocol.decode(protocol.encode(f))
  t.eq(dec.k, "cmd"); t.eq(dec.id, 7); t.eq(dec.cmd.k, "engage")
end)

t.test("decode returns nil on garbage instead of throwing", function()
  t.eq(protocol.decode("}{ not lua"), nil, "garbage -> nil")
  t.eq(protocol.decode(nil), nil, "nil -> nil")
  t.eq(protocol.decode(123), nil, "number -> nil")
  t.eq(protocol.decode("42"), nil, "non-table -> nil")
end)

t.test("encode prefers compact single-line serialization when supported", function()
  local f = { k = "tel", a = 1, nested = { b = 2 }, list = { 1, 2, 3 } }
  local s = protocol.encode(f)
  local dec = protocol.decode(s)
  t.eq(dec.nested.b, 2); t.eq(dec.list[3], 3, "fidelity unchanged")
  -- Only assert the layout when this CC:T actually supports the compact option.
  if not textutils.serialize({ 1 }, { compact = true }):find("\n") then
    t.eq(s:find("\n"), nil, "compact encoder emits a single line")
  end
end)
