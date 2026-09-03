-- tests/test_cfgseam.lua
local t = require("tests.framework")
local seam = require("ui.basalt.cfgseam")
local cfgspec = require("fcs.io.cfgspec")

t.test("kindOf maps bare config filenames back to their kind", function()
  t.eq(seam.kindOf(cfgspec.FILES.devbind), "devbind")
  t.eq(seam.kindOf(cfgspec.FILES.tuning), "tuning")
  t.eq(seam.kindOf("eh2_ui_config.tbl"), nil, "non-FCS files have no kind")
end)

t.test("read serves the cached body serialised (so cfgspec.load can parse it), nil when absent", function()
  local runtime = { cfgCache = { tuning = { body = { gains = { hoverDuty = 0.5 } } } } }
  local read = seam.read(runtime)
  local parsed = textutils.unserialise(read(cfgspec.FILES.tuning))
  t.eq(parsed.gains.hoverDuty, 0.5)
  t.eq(read(cfgspec.FILES.senscal), nil, "uncached kind -> nil (load merges defaults)")
  -- cfgspec.load round-trips through this read seam exactly as the menu calls it:
  local loaded = cfgspec.load("tuning", read)
  t.eq(loaded.gains.hoverDuty, 0.5)
end)

t.test("write unserialises the menu's cfg and ships it via cfgClient:writeKind", function()
  local calls = {}
  local runtime = { cfgClient = { writeKind = function(self, kind, body, cb)
    calls[#calls + 1] = { kind = kind, body = body, cb = cb } end } }
  local done = {}
  local write = seam.write(runtime, function(kind, ok, err) done = { kind = kind, ok = ok, err = err } end)
  -- the menu calls write(filename, serialisedBody) exactly as cfgspec.save does:
  cfgspec.save("devbind", cfgspec.defaults("devbind"), write)
  t.eq(#calls, 1); t.eq(calls[1].kind, "devbind"); t.truthy(calls[1].body.thrusters ~= nil)
  calls[1].cb(true, nil)   -- simulate the ack
  t.eq(done.kind, "devbind"); t.eq(done.ok, true)
end)

t.test("write refuses a non-FCS filename (no kind) without calling writeKind", function()
  local called = false
  local runtime = { cfgClient = { writeKind = function() called = true end } }
  local write = seam.write(runtime, nil)
  t.eq(write("eh2_ui_config.tbl", textutils.serialise({})), false)
  t.eq(called, false)
end)
