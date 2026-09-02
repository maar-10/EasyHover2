package.path = "/?.lua;/?/init.lua;" .. package.path
local t = require("tests.framework")
_G.EH2_SUITEX_NO_RUN = true
local SuiteX = require("easyhover2_suitex")

t.test("suitex loads as a library without running the UI", function()
  t.eq(type(SuiteX), "table")
end)

t.test("theme has matching high-contrast light/dark palettes", function()
  local d, l = SuiteX.theme.palettes.dark, SuiteX.theme.palettes.light
  for _, key in ipairs({ "bg","panel","text","dim","border","accent","ok","update","repair","error","install","btn","btnText","btnActive","btnDisabled" }) do
    t.truthy(d[key] ~= nil, "dark has " .. key); t.truthy(l[key] ~= nil, "light has " .. key)
  end
  t.truthy(d.bg ~= d.text, "dark bg != text"); t.truthy(l.bg ~= l.text, "light bg != text")
  t.eq(SuiteX.theme.get("nope"), SuiteX.theme.palettes.dark, "unknown mode -> dark")
end)

t.test("stateColour maps state keys to palette colours", function()
  local d = SuiteX.theme.palettes.dark
  t.eq(SuiteX.theme.stateColour(d, "notInstalled"), d.install)
  t.eq(SuiteX.theme.stateColour(d, "upToDate"), d.ok)
  t.eq(SuiteX.theme.stateColour(d, "outdated"), d.update)
  t.eq(SuiteX.theme.stateColour(d, "corrupt"), d.error)
  t.eq(SuiteX.theme.stateColour(d, "normal"), d.text)
  t.eq(SuiteX.theme.stateColour(d, nil), d.text, "unknown/checking -> neutral")
end)

t.test("toolInstallPlan: checkbox gates install, dev checkbox picks the channel", function()
  t.eq(SuiteX.toolInstallPlan({ toolChecked = false, devChecked = false }).install, false)
  local a = SuiteX.toolInstallPlan({ toolChecked = true, devChecked = false })
  t.eq(a.install, true); t.eq(a.channel, "min", "dev off -> minified tool")
  local b = SuiteX.toolInstallPlan({ toolChecked = true, devChecked = true })
  t.eq(b.install, true); t.eq(b.channel, "dev", "dev on -> non-minified tool")
  t.eq(SuiteX.toolInstallPlan(nil).install, false, "nil opts -> no install")
end)

t.test("toolsToInstall returns the ticked tools in order", function()
  t.eq(#SuiteX.toolsToInstall({}), 0)
  t.eq(#SuiteX.toolsToInstall(nil), 0)
  local both = SuiteX.toolsToInstall({ installSplitConfig = true, installFcs2Disk = true })
  t.eq(both[1], "splitconfig"); t.eq(both[2], "fcs2disk")
  local only = SuiteX.toolsToInstall({ installSplitConfig = true })
  t.eq(#only, 1); t.eq(only[1], "splitconfig")
end)

-- Phase P6: the standalone beacon updater is retired -- reinstall is folded into the beacon
-- controller's UPDATE/UPDATE ALL actions (controller/runtime.lua). The Advanced-tab checkbox and
-- installBeaconUpdater flag are gone; ticking nothing beacon-updater-shaped must never resurrect it.
t.test("toolsToInstall never returns beaconupdate (retired -- folded into the controller)", function()
  local out = SuiteX.toolsToInstall({ installBeaconUpdater = true, installSplitConfig = true, installFcs2Disk = true })
  for _, k in ipairs(out) do t.truthy(k ~= "beaconupdate", "beaconupdate must never be installable again") end
end)

t.test("toolsToInstall includes fcs2disk when its flag is set", function()
  local out = SuiteX.toolsToInstall({ installFcs2Disk = true })
  local found = false
  for _, k in ipairs(out) do if k == "fcs2disk" then found = true end end
  t.truthy(found, "fcs2disk requested when installFcs2Disk flag set")
end)

t.test("toolsToInstall omits fcs2disk when its flag is unset", function()
  for _, k in ipairs(SuiteX.toolsToInstall({})) do t.truthy(k ~= "fcs2disk", "no fcs2disk unless flagged") end
end)

t.test("checkboxLabels renders a visible box and a full-width (clickable) line in both states", function()
  local off, on = SuiteX.checkboxLabels("Split config (split legacy FCS config)")
  t.truthy(off:find("[ ]", 1, true), "unchecked shows an EMPTY box, not an invisible space")
  t.truthy(on:find("[x]", 1, true), "checked shows a TICKED box")
  t.truthy(off:find("Split config", 1, true), "label text folded into the unchecked box")
  t.truthy(on:find("Split config", 1, true), "label text folded into the checked box")
  -- Same length in both states so the CheckBox's autoSize width (== #text) is stable and the WHOLE
  -- visible line stays the click target -- the old bare 1-char " " box was invisible AND its click
  -- target was a single cell nowhere near the description label.
  t.eq(#off, #on, "unchecked and checked lines are the same width")
  t.eq(off, "[ ] Split config (split legacy FCS config)")
  t.eq(on,  "[x] Split config (split legacy FCS config)")
  t.eq(SuiteX.checkboxLabels(nil), "[ ] ", "nil label is safe")
end)

t.test("buttonStates: Go disabled only when already current", function()
  t.eq(SuiteX.buttonStates("update").go, "active")
  t.eq(SuiteX.buttonStates("current").go, "disabled")
  t.eq(SuiteX.buttonStates("current").verify, "active")
  -- Repair MUST stay available when already up-to-date: with Go disabled, Repair is the only engine
  -- op that installs the ticked Advanced-tab optional tools (split-config / FCS config dump) --
  -- see the repair handler's installToolIfRequested call. If this ever flips to "disabled", there's
  -- no way to add an optional tool without a version bump.
  t.eq(SuiteX.buttonStates("current").repair, "active")
end)

t.test("overallState resolves role/plan/files into a state", function()
  t.eq(SuiteX.overallState(nil, nil, false), "none")
  t.eq(SuiteX.overallState(nil, nil, true), "fix")
  t.eq(SuiteX.overallState("fcs", nil, true), "checking")
  t.eq(SuiteX.overallState("fcs", "update", true), "update")
  t.eq(SuiteX.overallState("fcs", "current", true), "current")
end)

t.test("roleText labels each state", function()
  t.eq(SuiteX.roleText("none"), "Not installed!")
  t.eq(SuiteX.roleText("fix"), "FIX!")
  t.eq(SuiteX.roleText("current", "fcs"), "FCS")
  t.eq(SuiteX.roleText("update", "ui"), "UI")
  t.eq(SuiteX.roleText("repair", "fcs"), "FCS?", "broken install marks the role")
end)

t.test("stateKey/filesKey colour the right lines", function()
  t.eq(SuiteX.stateKey("none"), "notInstalled")
  t.eq(SuiteX.stateKey("install"), "notInstalled")
  t.eq(SuiteX.stateKey("current"), "upToDate")
  t.eq(SuiteX.stateKey("update"), "outdated")
  t.eq(SuiteX.stateKey("repair"), "corrupt")
  t.eq(SuiteX.stateKey("fix"), "corrupt")
  t.eq(SuiteX.stateKey("checking"), "normal")
  -- Files line only tints on an update (yellow) or a corrupt/broken install (red).
  t.eq(SuiteX.filesKey("current"), "normal")
  t.eq(SuiteX.filesKey("update"), "outdated")
  t.eq(SuiteX.filesKey("repair"), "corrupt")
  t.eq(SuiteX.filesKey("install"), "normal")
end)

t.test("goLabel names the primary action by plan", function()
  t.eq(SuiteX.goLabel("install"), "Install")
  t.eq(SuiteX.goLabel("update"), "Update")
  t.eq(SuiteX.goLabel("repair"), "Repair")
  t.eq(SuiteX.goLabel("current"), "Go")
  t.eq(SuiteX.goLabel(nil), "Go")
end)

t.test("planView builds Role/version/Files lines coloured by state", function()
  local v = SuiteX.planView({ role="fcs", state={version="a"}, manifest={version="b"}, plan="update",
    report={ missing={}, corrupt={"x","y"}, total=10, present=10 }, diffLabel="outdated", hasFiles=true })
  t.eq(v.lines[1].text, "Role: FCS")
  t.eq(v.lines[1].key, "outdated")
  t.eq(v.lines[2].text, "Installed version: a")
  t.truthy(v.lines[3].text:find("b", 1, true), "live version shows the release")
  t.eq(v.lines[4].text, "Files: 8 ok / 0 missing / 2 outdated")
  t.eq(v.lines[4].key, "outdated")
  t.eq(v.buttons.go, "active")
  t.eq(v.goLabel, "Update")
end)

t.test("planView: nothing installed reads Not installed! (blue key)", function()
  local v = SuiteX.planView({ role=nil, state={}, manifest={version="b"}, plan=nil, report=nil, hasFiles=false })
  t.eq(v.lines[1].text, "Role: Not installed!")
  t.eq(v.lines[1].key, "notInstalled")
  t.eq(v.lines[2].text, "Installed version: none")
end)

t.test("checkDriver steps to completion and reports like a one-shot check", function()
  local files = { {dst="a"},{dst="b"},{dst="c"},{dst="d"} }
  local verdict = { a="ok", b="corrupt", c="ok", d="missing" }
  local drv = SuiteX.checkDriver(files, function(e) return verdict[e.dst] end)
  local done = drv.step(2); t.eq(done, false)
  local i, total = drv.progress(); t.eq(i, 2); t.eq(total, 4)
  done = drv.step(10); t.eq(done, true)               -- clamps past the end
  local r = drv.result()
  t.eq(#r.corrupt, 1); t.eq(#r.missing, 1); t.eq(r.present, 3); t.eq(r.total, 4); t.eq(r.ok, false)
end)

t.test("shouldArmCheck: skip a redundant same-target re-arm; arm on change, force, or first check", function()
  -- The check-freeze fix. While a check for the SAME target (role+channel) is already in flight, a
  -- non-forced re-arm must be SKIPPED: re-arming reassigns ctx.check, which orphans the running
  -- driveCheck coroutine (its `ctx.check == myCheck` guard makes it exit before finishCheck, leaving
  -- the bar frozen at the first step with the buttons disabled). A burst of such re-arms (from UI
  -- callbacks fired by queued events after a running program is stopped) is what wedged SuiteX.
  t.eq(SuiteX.shouldArmCheck(true, "min|fcs", "min|fcs", false), false, "same target, in flight, not forced -> skip")
  -- Legitimate re-checks still arm:
  t.eq(SuiteX.shouldArmCheck(false, nil, "min|fcs", false), true, "first check (no prior) -> arm")
  t.eq(SuiteX.shouldArmCheck(true, "min|fcs", "min|ui", false), true, "role change -> arm")
  t.eq(SuiteX.shouldArmCheck(true, "min|fcs", "dev|fcs", false), true, "channel change -> arm")
  t.eq(SuiteX.shouldArmCheck(true, "min|fcs", "min|fcs", true), true, "forced (Verify / post-op) -> arm even for same target")
end)

t.test("drainEvents flushes the queued backlog up to its own sentinel timer", function()
  -- The freeze re-fix: after stopping a running EH2 program, a backlog of queued events (modem
  -- messages, key/char, stray timers) is delivered into SuiteX's loop and starves the check
  -- coroutine's sleep-timer, wedging the bar after one batch. Draining that backlog at startup
  -- removes the trigger -- exactly what a manual restart does today.
  local queue = { {"modem_message", 1}, {"char", "p"}, {"key", 50}, {"timer", 7}, {"timer", 99} }
  local i = 0
  local pull = function() i = i + 1; return table.unpack(queue[i]) end
  local startTimer = function(_n) return 99 end                 -- our sentinel id
  local drained = SuiteX.drainEvents(pull, startTimer)
  t.eq(drained, 4, "drained the 4 real events (incl. a foreign timer), stopped at the sentinel")
end)

t.test("drainEvents on an empty queue returns 0 (sentinel fires first)", function()
  local pull = function() return "timer", 42 end               -- only the sentinel is ever pulled
  local startTimer = function(_n) return 42 end
  t.eq(SuiteX.drainEvents(pull, startTimer), 0, "nothing to drain")
end)

t.test("logo is a rectangular ASCII block", function()
  t.truthy(#SuiteX.logo >= 1, "has rows")
  local w = #SuiteX.logo[1]
  for _, row in ipairs(SuiteX.logo) do t.eq(#row, w, "rows equal width") end
  local lw, lh = SuiteX.logoSize(); t.eq(lw, w); t.eq(lh, #SuiteX.logo)
  t.truthy(w <= 49, "fits a 51-wide terminal with margin")
end)

t.test("basaltAction: use cached only on an exact size+sum match", function()
  local sum = function(s) return #s == 3 and "GOOD" or "BAD" end
  local want = { size = 3, sum = "GOOD" }
  t.eq(SuiteX.basaltAction("abc", want, sum), "use")
  t.eq(SuiteX.basaltAction(nil, want, sum), "fetch", "missing -> fetch")
  t.eq(SuiteX.basaltAction("abcd", want, sum), "fetch", "size mismatch -> fetch")
  t.eq(SuiteX.basaltAction("abX", { size=3, sum="GOOD" }, function() return "BAD" end), "fetch", "sum mismatch -> fetch")
end)
