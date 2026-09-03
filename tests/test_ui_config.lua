package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
local Config = require("ui.config")

t.test("defaults has the full schema", function()
  local d = Config.defaults()
  t.eq(type(d.assign), "table")
  t.eq(d.engine.pulseMs, 250)
  t.eq(d.engine.intervalMs, 330000)   -- 5m30s: one blaze-cake burn on this server
  t.eq(d.engine.invert, false)
  t.eq(d.fuel.pump.kind, "inventory")
end)

t.test("withDefaults keeps saved values and fills new ones", function()
  local merged = Config.withDefaults({ engine = { pulseMs = 300 }, assign = { ["monitor_1"] = "engine" } })
  t.eq(merged.engine.pulseMs, 300)          -- kept
  t.eq(merged.engine.intervalMs, 330000)    -- filled from defaults (5m30s)
  t.eq(merged.assign["monitor_1"], "engine")-- kept
  t.eq(merged.relay.name, nil)              -- default
end)

t.test("save then load round-trips (pre-merge)", function()
  local path = "/eh2_ui_config.tbl"
  if fs.exists(path) then fs.delete(path) end
  local ok = Config.save(path, { assign = { ["m"] = "fcs" }, engine = { invert = true } })
  t.eq(ok, true)
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(err, nil)
  t.eq(cfg.assign["m"], "fcs")
  t.eq(cfg.engine.invert, true)
  t.eq(cfg.engine.pulseMs, nil)             -- load is pre-merge
  fs.delete(path)
end)

t.test("load of a missing file is absent, not an error", function()
  local cfg, existed, err = Config.load("/nope_ui.tbl")
  t.eq(cfg, nil); t.eq(existed, false); t.eq(err, nil)
end)

t.test("load of unparseable is present-with-error", function()
  local path = "/eh2_ui_bad.tbl"
  local f = fs.open(path, "w"); f.write("not a table"); f.close()
  local cfg, existed, err = Config.load(path)
  t.eq(existed, true); t.eq(type(err), "string")
  fs.delete(path)
end)

t.test("pfd render rate defaults to 100ms and round-trips through withDefaults", function()
  t.eq(Config.defaults().pfd.renderMs, 100, "default PFD render cadence")
  t.eq(Config.withDefaults({ pfd = { renderMs = 200 } }).pfd.renderMs, 200, "saved value kept")
  t.eq(Config.withDefaults({}).pfd.renderMs, 100, "filled from defaults")
end)

t.test("sens concern defaults to FCS and preserves a saved source + self cal", function()
  t.eq(Config.withDefaults({}).sens.source, "FCS", "default source")
  local kept = Config.withDefaults({ sens = { source = "SELF", self = { signPitch = -1 } } })
  t.eq(kept.sens.source, "SELF"); t.eq(kept.sens.self.signPitch, -1)
end)

t.test("engine defaults to basic mode", function()
  local d = Config.defaults()
  t.eq(d.engine.mode, "basic")
end)

t.test("relay defaults carry blockSide/feedSide keys (nil)", function()
  local d = Config.defaults()
  t.eq(d.relay.blockSide, nil)
  t.eq(d.relay.feedSide, nil)
end)

t.test("withDefaults preserves a saved latch config", function()
  local merged = Config.withDefaults({
    engine = { mode = "latch" },
    relay  = { name = "redstone_relay_0", blockSide = "back", feedSide = "left" },
  })
  t.eq(merged.engine.mode, "latch")
  t.eq(merged.relay.blockSide, "back")
  t.eq(merged.relay.feedSide, "left")
  -- untouched engine defaults still merge through:
  t.eq(merged.engine.pulseMs, 250)
end)

-- ===== monitorOrder: the CONFIG page's persistent, never-forget monitor list =====

t.test("defaults carry an empty monitorOrder list", function()
  local d = Config.defaults()
  t.eq(type(d.monitorOrder), "table", "monitorOrder should be a table")
  t.eq(#d.monitorOrder, 0, "monitorOrder starts empty")
end)

t.test("withDefaults preserves a saved monitorOrder (ordered, never-forget)", function()
  local merged = Config.withDefaults({ monitorOrder = { "monitor_5", "monitor_1", "monitor_3" } })
  t.eq(merged.monitorOrder[1], "monitor_5")
  t.eq(merged.monitorOrder[2], "monitor_1")
  t.eq(merged.monitorOrder[3], "monitor_3")
end)

t.test("withDefaults gives an absent monitorOrder the empty default", function()
  local merged = Config.withDefaults({ engine = { mode = "latch" } })
  t.eq(type(merged.monitorOrder), "table")
  t.eq(#merged.monitorOrder, 0)
end)

-- Break this test would catch: load of current ignoring a present session overlay,
-- so a DEFAULT-for-this-boot UI would still show current.
t.test("load prefers eh2_ui_config.session.tbl over current when it parses", function()
  local current = "/eh2_ui_config.tbl"
  local session = "/eh2_ui_config.session.tbl"
  if fs.exists(current) then fs.delete(current) end
  if fs.exists(session) then fs.delete(session) end
  t.truthy(Config.save(current, { assign = { m = "current" } }))
  t.truthy(Config.save(session, { assign = { m = "session" } }))
  local cfg, existed, err = Config.load(current)
  t.eq(existed, true); t.eq(err, nil)
  t.eq(cfg.assign.m, "session", "session overlay must win over current")
  fs.delete(current); fs.delete(session)
end)

t.test("load falls back to current when session is missing or unparseable", function()
  local current = "/eh2_ui_config.tbl"
  local session = "/eh2_ui_config.session.tbl"
  if fs.exists(current) then fs.delete(current) end
  if fs.exists(session) then fs.delete(session) end
  t.truthy(Config.save(current, { assign = { m = "current" } }))
  local cfg = select(1, Config.load(current))
  t.eq(cfg.assign.m, "current")
  local f = fs.open(session, "w"); f.write("not a table"); f.close()
  local cfg2, existed2, err2 = Config.load(current)
  t.eq(existed2, true); t.eq(err2, nil)
  t.eq(cfg2.assign.m, "current", "unparseable session must not hide current")
  fs.delete(current); fs.delete(session)
end)
