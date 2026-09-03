-- tests/test_bitconfig_fcssync.lua
local t = require("tests.framework")
local M = require("ui.basalt.bitconfig.fcssync")

t.test("checkStatus reports per-kind OK / SYNC / NO ANSWER from the cache", function()
  local cache = {
    tuning = { body = { gains = {} }, status = "ok" },
    devbind = { body = nil, status = "sync" },
    senscal = { body = nil, status = "fail" },
  }
  local st = M.checkStatus(cache, { "tuning", "devbind", "senscal" })
  t.eq(st.tuning, "OK")
  t.eq(st.devbind, "SYNC")
  t.eq(st.senscal, "NO ANSWER")
end)

t.test("checkStatus treats an absent cache entry as SYNC (not requested yet)", function()
  local st = M.checkStatus({}, { "tuning" })
  t.eq(st.tuning, "SYNC")
end)

t.test("M.KINDS includes fuelcal", function()
  local set = {}
  for _, k in ipairs(M.KINDS) do set[k] = true end
  t.truthy(set.tuning and set.devbind and set.senscal and set.fuelcal)
end)

return t
