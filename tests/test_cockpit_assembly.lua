-- tests/test_cockpit_assembly.lua
-- Task 27 (cockpit assembly): whole-cockpit construction probe (REAL CraftOS-PC Basalt) + the
-- testable per-frame nav-root/screen-visibility helpers M.run() is built from. NEVER
-- basalt.run() here (blocks on os.pullEventRaw() forever) -- basalt.update("timer", -1) is the
-- one-render-pass primitive used throughout the existing Basalt test suite (see
-- tests/test_basalt_app.lua's header comment for the full provenance).
local t = require("tests.framework")
local M = require("ui.basalt.app")

-- Mock modem, mirroring tests/test_basalt_app.lua's newMockModem/newRuntime EXACTLY, so this
-- probe's runtime is the SAME real shape M.run() itself builds (real Config/Engine/CfgClient --
-- just modem/wrap swapped out so nothing here touches an actual peripheral).
local function newMockModem()
  local sent = {}
  local dev = {
    open = function() end,
    isWireless = function() return false end,
  }
  dev.transmit = function(tx, rx, msg) sent[#sent + 1] = { tx = tx, rx = rx, msg = msg } end
  dev._sent = sent
  return dev
end

local function newRuntime()
  local modem = newMockModem()
  local runtime = M.buildRuntime({
    modem = modem,
    wrap = function() return {} end,  -- no relay/fuel peripherals present in this probe
  })
  -- Seed the live-cfg cache so BIT/CONFIG menus pass M.showScreen's cfgMenuStatus gate and
  -- actually construct (the probe asserts frameRec.built[id], not the SYNC placeholder).
  -- fcssync is a read-only cfgClient checker: its build() refreshAll marks kinds "sync" then
  -- readKind's; without an FCS reply that would leave the gate closed for later menus. Make
  -- readKind answer immediately so the probe stays headless and the stub cfgserver can go.
  for _, kind in ipairs({ "tuning", "devbind", "senscal" }) do
    runtime.cfgCache[kind] = { body = {}, status = "ok" }
  end
  runtime.cfgClient.readKind = function(self, kind, cb)
    local body = {}
    if cb then cb(body) end
  end
  return runtime
end

-- ===== M.rootForMonitor: pure =====

t.test("rootForMonitor: unassigned falls back to emc", function()
  t.eq(M.rootForMonitor({}, "monA"), "emc")
  t.eq(M.rootForMonitor(nil, "monA"), "emc")
end)

t.test("rootForMonitor: a valid assignment wins", function()
  t.eq(M.rootForMonitor({ monA = "fcs" }, "monA"), "fcs")
  t.eq(M.rootForMonitor({ monA = "ap" }, "monA"), "ap")
end)

t.test("rootForMonitor: an assignment naming an unknown screen id falls back to emc", function()
  t.eq(M.rootForMonitor({ monA = "bogus" }, "monA"), "emc")
end)

-- ===== M.newFrameRec: terminal roots at config, a monitor roots at its assigned page =====

t.test("newFrameRec: terminal frameRec roots its Nav stack at 'config'", function()
  local basalt = M.ensureBasalt()
  local term = M.newFrameRec(basalt.getMainFrame(), "config")
  t.eq(term.nav:top(), "config")
  t.eq(term.nav:depth(), 1)
end)

t.test("newFrameRec: a monitor frameRec roots at its resolved assigned page id", function()
  local basalt = M.ensureBasalt()
  local root = M.rootForMonitor({ monA = "fcs" }, "monA")
  local mon = M.newFrameRec(basalt.createFrame(), root)
  t.eq(mon.nav:top(), "fcs")
end)

-- ===== M.showScreen: lazy build + cache + visibility toggle =====

t.test("showScreen builds on first visit, caches, and shows exactly one child at a time", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "emc")
  local runtime = newRuntime()

  local emcEntry = M.showScreen(basalt, runtime, frameRec, "emc")
  t.truthy(emcEntry ~= nil, "emc entry should be built")
  t.truthy(emcEntry.handle ~= nil and emcEntry.handle.id == "emc", "emc handle id matches")
  t.eq(emcEntry.childFrame:getVisible(), true, "the only built screen starts visible")

  local fcsEntry = M.showScreen(basalt, runtime, frameRec, "fcs")
  t.truthy(fcsEntry ~= nil, "fcs entry should be built")
  t.eq(fcsEntry.childFrame:getVisible(), true, "newly shown screen is visible")
  t.eq(emcEntry.childFrame:getVisible(), false, "previously shown screen is now hidden")

  -- Revisiting emc must reuse the CACHED entry (same table identity), not rebuild it.
  local emcAgain = M.showScreen(basalt, runtime, frameRec, "emc")
  t.truthy(emcAgain == emcEntry, "cached entry reused on a repeat visit, not rebuilt")
  t.eq(emcEntry.childFrame:getVisible(), true, "showing emc again flips visibility back")
  t.eq(fcsEntry.childFrame:getVisible(), false, "fcs is hidden once emc is shown again")
end)

t.test("showScreen returns nil for an unknown screen id (no crash, no partial build)", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "emc")
  local runtime = newRuntime()

  local entry = M.showScreen(basalt, runtime, frameRec, "no_such_screen")
  t.eq(entry, nil)
end)

-- ===== A nav push changes which child the applyState-style loop would target next =====

t.test("a nav push (as the NAV page's [BIT/CONFIG] button does) changes frameRec.nav:top()", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "nav")
  local runtime = newRuntime()

  local navEntry = M.showScreen(basalt, runtime, frameRec, frameRec.nav:top())
  t.eq(frameRec.nav:top(), "nav")
  t.eq(navEntry.childFrame:getVisible(), true)

  -- Same intent seam ui/basalt/pages/nav.lua's [BIT/CONFIG] button's onClick invokes.
  M.PAGES.nav._onButton(frameRec.nav, "bitconfig", os.epoch("utc"))
  t.eq(frameRec.nav:top(), "bitconfig", "nav push landed on the hub")

  -- The applyState loop (M.run()'s closure) always re-resolves frameRec.nav:top() on every
  -- render-gate tick -- simulate exactly that lookup here.
  local hubEntry = M.showScreen(basalt, runtime, frameRec, frameRec.nav:top())
  t.eq(hubEntry.childFrame:getVisible(), true, "the hub is now the visible/targeted child")
  t.eq(navEntry.childFrame:getVisible(), false, "the nav screen is no longer targeted")
  t.truthy(hubEntry ~= navEntry, "a different child is now what apply(state) would be called on")
end)

-- ===== Whole-cockpit construction probe: every M.PAGES screen builds + one shared render pass =====

t.test("whole-cockpit construction probe: every M.PAGES screen builds without error", function()
  local basalt = M.ensureBasalt()
  local frame = basalt.createFrame()
  local frameRec = M.newFrameRec(frame, "emc")
  local runtime = newRuntime()

  local ids = {}
  for id in pairs(M.PAGES) do ids[#ids + 1] = id end
  table.sort(ids)
  t.truthy(#ids >= 12, "every page + BIT/CONFIG hub + 6 sub-menus should be registered")

  for _, id in ipairs(ids) do
    local ok, err = pcall(function() return M.showScreen(basalt, runtime, frameRec, id) end)
    t.truthy(ok, "screen '" .. id .. "' should build without error: " .. tostring(err))
    local entry = frameRec.built[id]
    t.truthy(entry ~= nil, "screen '" .. id .. "' should be cached after building")
    t.eq(entry.handle.id, id, "screen '" .. id .. "'s handle.id matches its registry key")
  end

  -- ONE render pass across the frame with every screen built (only the last-shown one visible).
  -- NEVER basalt.run() here -- that blocks on os.pullEventRaw() in a loop.
  local ok2, err2 = pcall(function() basalt.update("timer", -1) end)
  t.truthy(ok2, "basalt.update should not error after building every screen: " .. tostring(err2))
end)

return true
