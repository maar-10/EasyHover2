-- EasyHover 2 SuiteX -- Basalt 2.0 front-end for the Suite. Run via `wget run`.
-- Self-contained (helpers inline + on the SuiteX table) so it works before anything is installed;
-- fetches a vendored basalt-full.lua and the classic Suite (as a library) at runtime.
local SuiteX = {}

-- (helpers added in later tasks)

SuiteX.theme = { palettes = {
  dark = { bg=colours.black, panel=colours.grey, text=colours.white, dim=colours.lightGrey,
    border=colours.lightGrey, accent=colours.cyan, ok=colours.lime, update=colours.yellow,
    repair=colours.orange, error=colours.red, install=colours.lightBlue, btn=colours.grey,
    btnText=colours.white, btnActive=colours.lime, btnDisabled=colours.grey },
  light = { bg=colours.white, panel=colours.lightGrey, text=colours.black, dim=colours.grey,
    border=colours.grey, accent=colours.blue, ok=colours.green, update=colours.orange,
    repair=colours.brown, error=colours.red, install=colours.blue, btn=colours.lightGrey,
    btnText=colours.black, btnActive=colours.green, btnDisabled=colours.lightGrey },
} }
function SuiteX.theme.get(mode) return SuiteX.theme.palettes[mode] or SuiteX.theme.palettes.dark end

--- Maps a status "state key" to a palette colour. The four states the operator cares about --
--- not installed (blue), up to date (green), an available update (yellow), corrupt/broken (red)
--- -- plus a neutral default for the transient "checking" phase.
function SuiteX.theme.stateColour(pal, key)
  if key == "notInstalled" then return pal.install
  elseif key == "upToDate" then return pal.ok
  elseif key == "outdated" then return pal.update
  elseif key == "corrupt" then return pal.error
  else return pal.text end
end

function SuiteX.buttonStates(plan)
  return { go = (plan == "current") and "disabled" or "active",
    verify = "active", repair = "active", switch = "active", tools = "active", quit = "active" }
end

--- toolInstallPlan(opts) -> { install, channel }. An Advanced-tab optional-tool checkbox gates
--- installing a standalone tool alongside the role; the dev checkbox picks the variant
--- (off -> minified, on -> readable source), mirroring the role install channel.
function SuiteX.toolInstallPlan(opts)
  opts = opts or {}
  return {
    install = opts.toolChecked == true,
    channel = opts.devChecked and "dev" or "min",
  }
end

--- toolsToInstall(flags) -> ordered list of manifest tool keys to install, one per ticked
--- Advanced-tab "Optional tools" checkbox. Pure/nil-safe so it's unit-testable headless; the
--- caller (installToolIfRequested) walks this list and installs each from ctx.manifest.tools.
function SuiteX.toolsToInstall(flags)
  flags = flags or {}
  local out = {}
  if flags.installSplitConfig then out[#out + 1] = "splitconfig" end
  if flags.installFcs2Disk then out[#out + 1] = "fcs2disk" end
  return out
end

--- advancedOps() -> ordered { { id, label }, ... } for the Advanced-tab config buttons.
--- Pure so tests can assert the two ids/labels without constructing Basalt. `id` is the
--- Suite.runConfigFlags key the click handler sets; `label` is the ASCII button text.
function SuiteX.advancedOps()
  return {
    { id = "flagDefaults", label = "FLAG DEFAULTS" },
    { id = "migrateConfig", label = "MIGRATE CONFIG" },
  }
end

--- checkboxLabels(label) -> uncheckedText, checkedText: the two static strings for one Advanced-tab
--- checkbox. The description is folded INTO the CheckBox element's own text/checkedText behind a
--- visible "[ ]"/"[x]" box (rather than sitting in a separate addLabel beside a bare 1-char box).
--- A Basalt CheckBox is clickable across its whole autoSize width (== the string length) and toggles
--- on any click inside that width, so folding the label in makes the ENTIRE visible line the tick
--- target. The old shape -- text=" " (an invisible space) with the description in a plain,
--- non-interactive addLabel four columns to the right -- rendered no visible box and only accepted
--- clicks on a single blank cell nowhere near the words, so clicking the description did nothing.
--- Both returned strings are the same length, so autoSize width is identical checked/unchecked and
--- the full line stays clickable in either state. Pure/nil-safe -> unit-testable headless.
function SuiteX.checkboxLabels(label)
  label = label or ""
  return "[ ] " .. label, "[x] " .. label
end

--- The primary-button label for a plan: fresh Install, Update, or Repair; a neutral "Go" while
--- the plan is still unknown (mid-check) or the install is already current.
function SuiteX.goLabel(plan)
  if plan == "install" then return "Install"
  elseif plan == "update" then return "Update"
  elseif plan == "repair" then return "Repair"
  else return "Go" end
end

--- Collapses (resolved role, computed plan, any-files-on-disk) into one status state:
---   none     -- clean machine, nothing installed
---   fix      -- files present but no role could be identified (needs manual attention)
---   checking -- role known, integrity check still running (plan not computed yet)
---   install/update/repair/current -- the computed plan once the check finishes
function SuiteX.overallState(role, plan, hasFiles)
  if not role then return hasFiles and "fix" or "none" end
  if not plan then return "checking" end
  return plan
end

--- The Role: line's text for each state. A known role is upper-cased (FCS/UI/NAV); a broken
--- install shows the role with a trailing "?"; an unidentifiable-but-present install shows FIX!.
function SuiteX.roleText(state, role)
  if state == "none" then return "Not installed!" end
  if state == "fix" then return "FIX!" end
  local up = (role and role:upper()) or "?"
  if state == "repair" then return up .. "?" end
  return up
end

--- Colour key for the Role + version lines (they share one state colour).
function SuiteX.stateKey(state)
  if state == "none" or state == "install" then return "notInstalled"
  elseif state == "current" then return "upToDate"
  elseif state == "update" then return "outdated"
  elseif state == "repair" or state == "fix" then return "corrupt"
  else return "normal" end
end

--- Colour key for the Files line: only an available update (yellow) or a corrupt/broken install
--- (red) tints it; an all-OK or fresh-install listing stays neutral.
function SuiteX.filesKey(state)
  if state == "update" then return "outdated"
  elseif state == "repair" or state == "fix" then return "corrupt"
  else return "normal" end
end

--- Builds the dashboard's status lines (each {text, key}) plus the button states and the primary
--- action label. `ctx` = { role, state={version}, manifest={version}, plan, report, diffLabel, hasFiles }.
function SuiteX.planView(ctx)
  local state = SuiteX.overallState(ctx.role, ctx.plan, ctx.hasFiles)
  local key = SuiteX.stateKey(state)
  local iv = (ctx.state and ctx.state.version) or "none"
  local lv = (ctx.manifest and ctx.manifest.version) or "?"
  local r = ctx.report or { missing = {}, corrupt = {}, total = 0, present = 0 }
  local corrupt = #(r.corrupt or {})
  local ok = math.max(0, (r.total or 0) - #(r.missing or {}) - corrupt)
  return {
    state = state,
    lines = {
      { text = "Role: " .. SuiteX.roleText(state, ctx.role), key = key },
      { text = "Installed version: " .. iv, key = key },
      { text = "Live version:      " .. lv, key = key },
      { text = ("Files: %d ok / %d missing / %d %s"):format(ok, #(r.missing or {}), corrupt, ctx.diffLabel or "outdated"),
        key = SuiteX.filesKey(state) },
    },
    buttons = SuiteX.buttonStates(ctx.plan),
    goLabel = SuiteX.goLabel(ctx.plan),
  }
end

function SuiteX.checkDriver(files, checkOne)
  local self = { files = files or {}, checkOne = checkOne, i = 0,
    report = { missing = {}, corrupt = {}, present = 0, total = #(files or {}) } }
  function self.step(n)
    local stop = math.min(self.i + (n or 1), #self.files)
    while self.i < stop do
      self.i = self.i + 1
      local e = self.files[self.i]; local v = self.checkOne(e)
      if v == "missing" then self.report.missing[#self.report.missing+1] = e.dst
      else self.report.present = self.report.present + 1
        if v == "corrupt" then self.report.corrupt[#self.report.corrupt+1] = e.dst end end
    end
    return self.i >= #self.files
  end
  function self.progress() return self.i, #self.files end
  function self.result()
    self.report.ok = (#self.report.missing == 0 and #self.report.corrupt == 0)
    return self.report
  end
  return self
end

--- Should startCheck arm a NEW check driver, or is the request redundant? Arming reassigns ctx.check,
--- which orphans any in-flight driveCheck coroutine (its `ctx.check == myCheck` guard makes it exit
--- before finishCheck -- leaving the bar stuck at the first step with the buttons disabled). So a
--- NON-forced re-arm for a target already under check (same role+channel) must be a no-op; a burst of
--- those -- UI callbacks re-firing from events queued after a running program is stopped -- is what
--- wedged SuiteX. Forced re-checks (Verify, post-install) and any target CHANGE always (re)arm.
function SuiteX.shouldArmCheck(hasCheck, prevTarget, newTarget, force)
  if force then return true end
  if not hasCheck then return true end
  return prevTarget ~= newTarget
end

--- Flush the event backlog queued while a previous program (e.g. a running FCS) was stopped, BEFORE
--- the dashboard's check coroutine starts pumping. That backlog -- modem messages, key/char, stray
--- timers -- otherwise starves the check's sleep-timer, wedging the bar after its first ~16-file
--- batch (~28-29% on the FCS role). A manual restart drains the same backlog, which is why the
--- second launch always worked. Pulls events until its OWN 0s sentinel timer surfaces (queued last,
--- after everything already pending), then returns the count drained. pull/startTimer injectable for
--- tests; defaults to the real os API.
function SuiteX.drainEvents(pull, startTimer)
  pull = pull or os.pullEvent
  startTimer = startTimer or os.startTimer
  local sentinel = startTimer(0)
  local drained = 0
  while true do
    local ev = { pull() }
    if ev[1] == "timer" and ev[2] == sentinel then return drained end
    drained = drained + 1
  end
end

SuiteX.logo = {
  "  ___ _  _ ___    ___ ",
  " | __| || |_  )  |__ \\",
  " | _|| __ |/ /     /_/",
  " |___|_||_/___|   (o) ",
}
function SuiteX.logoSize() return #SuiteX.logo[1], #SuiteX.logo end

function SuiteX.basaltAction(localBody, want, checksum)
  if localBody ~= nil and want and #localBody == want.size and checksum(localBody) == want.sum then
    return "use"
  end
  return "fetch"
end

-- ===================================================================
-- run() glue -- Basalt 2.0 UI assembly + bootstrap.
--
-- Basalt element/method names below were verified against the Basalt 2.0 source at the pinned
-- commit (Pyroxenium/Basalt2 @ f6cde73a), NOT against the minified vendored build and NOT from
-- memory. See task-9-report.md for the file:line citations.
-- ===================================================================

--- Same constant as DEFAULT_BASE in easyhover2_suite.lua. Needed once, to fetch that very file
--- before it exists locally -- after that every fetch goes through Suite.base instead, so this
--- is the only place the URL is duplicated.
local BOOT_BASE = "https://raw.githubusercontent.com/maar-10/EasyHover2/main"

local BTN_KEYS = { "go", "verify", "repair", "switch", "tools", "quit" }
local BTN_LABELS = { go = "Go", verify = "Verify", repair = "Repair", switch = "Switch", tools = "Launch", quit = "Quit" }

--- Minimal cache-busted fetch, used ONLY to bootstrap easyhover2_suite.lua itself (before Suite
--- exists, so Suite.fetch is not yet available). Everything after that reuses Suite.fetch.
local function bootFetch(url)
  local sep = url:find("?", 1, true) and "&" or "?"
  local bust = url .. sep .. "cb=" .. tostring((os.epoch and os.epoch("utc")) or os.time())
  local headers = { ["Cache-Control"] = "no-cache", ["Pragma"] = "no-cache" }
  local ok, handle = pcall(http.get, bust, headers)
  if not (ok and handle) then
    sleep(1)
    ok, handle = pcall(http.get, bust, headers)
  end
  if not (ok and handle) then return nil, "could not reach " .. url end
  local body = handle.readAll()
  handle.close()
  if body == nil or body == "" then return nil, "empty response" end
  return body
end

local function writeLocal(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "/" and not fs.exists(dir) then fs.makeDir(dir) end
  local f = fs.open(path, "w")
  if not f then return false end
  f.write(content)
  f.close()
  return true
end

local function abort(msg)
  term.setTextColour(colours.red)
  print("EasyHover 2 SuiteX: " .. tostring(msg))
  term.setTextColour(colours.white)
end

--- Same ordering Suite.main uses: released roles first, then alphabetical within each group.
local function buildOrder(manifest)
  local order = {}
  for name in pairs(manifest.roles) do order[#order + 1] = name end
  table.sort(order, function(a, b)
    local ra, rb = manifest.roles[a], manifest.roles[b]
    local sa = (ra.status == "released") and 0 or 1
    local sb = (rb.status == "released") and 0 or 1
    if sa ~= sb then return sa < sb end
    return a < b
  end)
  return order
end

local function logLine(ctx, text, colour)
  ctx.ui.log:addItem({ text = tostring(text), fg = colour or ctx.pal.text })
  ctx.ui.log:scrollToBottom()
end

local function paintButton(ctx, key, active)
  local btn, pal = ctx.ui.buttons[key], ctx.pal
  btn:setEnabled(active)
  if active then
    btn:setBackground(key == "go" and pal.btnActive or pal.btn)
    btn:setForeground(pal.btnText)
  else
    btn:setBackground(pal.btnDisabled)
    btn:setForeground(pal.dim)
  end
end

--- ready=false: everything greyed out except Quit (a long check/op is running).
--- ready=true: SuiteX.buttonStates(ctx.plan) -- the tested pure helper -- decides the rest.
local function setButtonsEnabled(ctx, ready)
  local states = ready and SuiteX.buttonStates(ctx.plan) or nil
  for _, key in ipairs(BTN_KEYS) do
    if key == "quit" then
      paintButton(ctx, key, true)
    else
      paintButton(ctx, key, ready and states[key] ~= "disabled")
    end
  end
  -- Advanced-tab FLAG DEFAULTS / MIGRATE CONFIG: grey out for the same opInFlight/check
  -- window as Go/Repair. Always re-enabled when ready (unlike Go, these are valid at "current").
  local pal = ctx.pal
  for _, btn in ipairs((ctx.ui and ctx.ui.advOpButtons) or {}) do
    btn:setEnabled(ready == true)
    if ready then
      btn:setBackground(pal.btn); btn:setForeground(pal.btnText)
    else
      btn:setBackground(pal.btnDisabled); btn:setForeground(pal.dim)
    end
  end
end

local function refreshStatus(ctx)
  local view = SuiteX.planView({
    role = ctx.role, state = ctx.state, manifest = ctx.manifest,
    plan = ctx.plan, report = ctx.report, diffLabel = ctx.diffLabel, hasFiles = ctx.hasFiles,
  })
  for i, line in ipairs(view.lines) do
    local lbl = ctx.ui.statusLabels[i]
    if lbl then
      lbl:setText(line.text)
      lbl:setForeground(SuiteX.theme.stateColour(ctx.pal, line.key))
    end
  end
  ctx.ui.buttons.go:setText(view.goLabel)
end

--- Repaints the two tab buttons: the active one gets the accent, the other the neutral button
--- colour. (SuiteX draws its own flush-right tab buttons -- Basalt's TabControl only left-anchors
--- its header tabs, with no right-align option.)
local function paintTabButtons(ctx)
  local pal, ui = ctx.pal, ctx.ui
  ui.tabMain:setBackground(ctx.tab == "main" and pal.accent or pal.btn)
  ui.tabMain:setForeground(ctx.tab == "main" and pal.bg or pal.btnText)
  ui.tabAdv:setBackground(ctx.tab == "advanced" and pal.accent or pal.btn)
  ui.tabAdv:setForeground(ctx.tab == "advanced" and pal.bg or pal.btnText)
end

--- Switches the visible content frame and repaints the tab buttons.
local function showTab(ctx, which)
  ctx.tab = which
  ctx.ui.frameMain:setVisible(which == "main")
  ctx.ui.frameAdv:setVisible(which == "advanced")
  paintTabButtons(ctx)
end

--- Re-applies the current palette to every already-built element. Called on boot and on every
--- light/dark toggle -- elements are never recreated, only repainted.
local function applyTheme(ctx)
  local pal, ui = ctx.pal, ctx.ui
  ui.main:setBackground(pal.bg)
  for _, lbl in ipairs(ui.logoLabels) do lbl:setForeground(pal.accent) end
  ui.themeButton:setBackground(pal.btn); ui.themeButton:setForeground(pal.btnText)
  ui.themeButton:setText((ctx.mode == "dark") and "Dark" or "Light")
  ui.subtitle:setForeground(pal.dim)
  ui.frameMain:setBackground(pal.panel)
  ui.frameAdv:setBackground(pal.panel)
  ui.progress:setBackground(pal.bg)
  ui.progress:setForeground(pal.text)
  ui.progress:setProgressColor(pal.accent)
  ui.log:setBackground(pal.bg); ui.log:setForeground(pal.text)
  ui.roleDropdown:setBackground(pal.bg); ui.roleDropdown:setForeground(pal.text)
  ui.toolDropdown:setBackground(pal.bg); ui.toolDropdown:setForeground(pal.text)
  ui.pickerLabels[1]:setForeground(pal.dim); ui.pickerLabels[2]:setForeground(pal.dim)
  ui.advancedLabel:setForeground(pal.dim)
  ui.devCheck:setBackground(pal.bg); ui.devCheck:setForeground(pal.text)
  ui.toolLabel:setForeground(pal.dim)
  -- Legacy optional tools stay dimmed (they're flagged [OUTDATED]).
  ui.splitCfgCheck:setBackground(pal.bg); ui.splitCfgCheck:setForeground(pal.dim)
  ui.fcs2diskCheck:setBackground(pal.bg); ui.fcs2diskCheck:setForeground(pal.dim)
  ui.advOpLabel:setForeground(pal.dim)
  ui.advOpStatus:setForeground(pal.dim)
  paintTabButtons(ctx)
  refreshStatus(ctx)
  -- Repaint the palette even mid-op, but don't let a theme toggle re-enable the action buttons
  -- while an engine op is in flight -- see ctx.opInFlight in runEngineOp.
  setButtonsEnabled(ctx, ctx.checkDone and not ctx.opInFlight)
end

local function refreshToolsDropdown(ctx)
  local items = {}
  if ctx.spec then
    for _, name in ipairs(ctx.Suite.diagTools(ctx.spec)) do
      items[#items + 1] = { text = name, callback = function()
        local ok, err = pcall(shell.run, name)
        if not ok then logLine(ctx, "tool error: " .. tostring(err), ctx.pal.error) end
      end }
    end
  end
  ctx.ui.toolDropdown:setItems(items)
  ctx.ui.toolDropdown:setSelectedText(#items > 0 and "pick a tool..." or "(none)")
end

--- Turns the checkDriver's raw report into plan + a refreshed status panel + enabled buttons.
--- Mirrors Suite.runUI's recompute(), but fed the ASYNC checkDriver's result instead of a
--- blocking Suite.integrity() call.
local function finishCheck(ctx)
  local report = ctx.check.result()
  local switching = (ctx.state.role ~= nil and ctx.state.role ~= ctx.role)
  local sameVersion = (ctx.state.version == ctx.manifest.version) and not switching
  local plan = ctx.Suite.choosePlan({
    anyInstall = report.present > 0,
    mismatched = not report.ok,
    sameVersion = sameVersion,
    noRecord = (ctx.state.version == nil),
    forceRepair = false,
  })
  ctx.report, ctx.plan, ctx.diffLabel = report, plan, ctx.Suite.diffLabel(plan)
  refreshStatus(ctx)
  -- Belt-and-suspenders: a stray check that completes mid-op (e.g. re-armed by a role pick that
  -- slipped through) must not re-enable the action buttons -- mirrors applyTheme's same guard.
  setButtonsEnabled(ctx, ctx.checkDone and not ctx.opInFlight)
end

--- Drives the incremental check to completion on a Basalt-scheduled coroutine, so the menu stays
--- live the whole time. Each pass steps a batch of files, updates the progress bar, and yields
--- (sleep). A newer check -- from a role switch or a re-verify -- replaces ctx.check, and the
--- `ctx.check == myCheck` guard makes any older coroutine exit rather than double-step.
---
--- This replaces an earlier Basalt Timer element: a frame-added Timer's event delivery was never
--- actually exercised (the Task 9 headless check only CONSTRUCTED it), and in-game the periodic
--- step never fired -- the check sat at 0% and the buttons never enabled. basalt.schedule is the
--- same coroutine mechanism the engine ops already use, and it self-pumps via its own sleep timer.
-- Run the integrity check to completion SYNCHRONOUSLY (no scheduled coroutine, no sleep). The check
-- is a handful of LOCAL file reads + fnv1a checksums -- fast and non-yielding -- so stepping it
-- straight through in one call cannot be starved by an event flood or orphaned by a re-arm. Those
-- were the two ways the old basalt.schedule-driven check wedged at ~28% (exactly one 16-file batch)
-- on a busy multi-computer network: the check's own 0.05s sleep-timer never resurfaced through the
-- event stream, so the coroutine never ran its second batch and finishCheck was never reached. A
-- synchronous run has no timer to starve and no coroutine to orphan -- it is GUARANTEED to reach
-- finishCheck. The brief (~ms) UI pause while it runs is imperceptible. A checkFile throw stays
-- pcall-guarded so a bad on-disk path finishes the check rather than aborting it.
local function runCheck(ctx, myCheck)
  repeat
    local ok, done = pcall(myCheck.step, 16)
    if not ok then done = true end
  until done
  local i, total = myCheck.progress()
  ctx.ui.progress:setProgress(total > 0 and math.floor(i / total * 100 + 0.5) or 100)
  ctx.checkDone = true
  finishCheck(ctx)
end

--- A stable identity for what a check examines: role + channel. Two non-forced startCheck calls with
--- the same target are redundant (SuiteX.shouldArmCheck) -- the running/completed one already covers
--- it. nil when no role is resolved (the no-spec branch below).
local function checkTarget(ctx)
  if not ctx.spec then return nil end
  return (ctx.channel or "?") .. "|" .. (ctx.role or "?")
end

--- (Re)arms the incremental checkDriver and kicks off the coroutine that drives it, greying the
--- buttons out until it completes. `force` (Verify / post-install) always re-arms; otherwise a
--- redundant re-arm for the SAME target is skipped so we never orphan the in-flight driveCheck
--- coroutine -- the freeze bug (see SuiteX.shouldArmCheck).
local function startCheck(ctx, force)
  if not ctx.spec then
    ctx.checkDone = false
    ctx.check = nil
    ctx.checkTarget = nil
    ctx.ui.progress:setProgress(0)
    setButtonsEnabled(ctx, false)
    return
  end
  local target = checkTarget(ctx)
  if not SuiteX.shouldArmCheck(ctx.check ~= nil, ctx.checkTarget, target, force) then return end
  ctx.checkDone = false
  ctx.checkTarget = target
  ctx.check = SuiteX.checkDriver(ctx.spec.files, function(e) return ctx.Suite.checkFile(e, ctx.Suite.readFile) end)
  ctx.ui.progress:setProgress(0)
  setButtonsEnabled(ctx, false)
  runCheck(ctx, ctx.check)   -- SYNCHRONOUS: cannot be starved/orphaned (see runCheck's note)
end

local function activateRole(ctx, roleName)
  -- Same re-entrancy guard as the verify/go/repair handlers: the Role dropdown stays open and
  -- clickable even while setButtonsEnabled() has disabled the six action buttons (it only ever
  -- touched BTN_KEYS, never the dropdowns), so a role picked mid-op must be a no-op rather than
  -- calling startCheck() -> resetting ctx.checkDone mid-flight, which finishCheck's own guard
  -- above also now defends against.
  if ctx.opInFlight then return end
  local spec = ctx.manifest.roles[roleName]
  if not ctx.Suite.isReleased(spec) then
    logLine(ctx, ("role %s is reserved -- ships no files yet"):format(roleName), ctx.pal.repair)
    return
  end
  ctx.role, ctx.spec = roleName, spec
  ctx.ui.roleDropdown:setSelectedText(roleName)
  refreshToolsDropdown(ctx)
  startCheck(ctx)
end

--- Swap SuiteX to another release channel: load that channel's manifest (cached in ctx.manifests
--- after the first fetch), rebuild the manifest-derived UI + the current role's spec, and re-arm
--- the check so the dashboard reflects the new channel's plan. INSPECTION ONLY -- never writes the
--- /eh2_channel.txt marker (that happens on a real install, in runEngineOp). Returns true, or
--- false+err on a fetch/parse failure so the caller can revert the checkbox and keep the current
--- channel.
local function reloadManifest(ctx, channel)
  local manifest = ctx.manifests[channel]
  if not manifest then
    local body, err = ctx.Suite.fetch(ctx.Suite.base .. "/" .. ctx.Suite.manifestName(channel))
    if not body then return false, err end
    manifest = textutils.unserialise(body)
    if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
      return false, "the " .. channel .. " manifest is not readable"
    end
    ctx.manifests[channel] = manifest
  end
  ctx.channel = channel
  ctx.manifest = manifest
  ctx.order = buildOrder(manifest)
  -- keep the same role if the new channel still ships it; otherwise fall back to "unresolved"
  if ctx.role and manifest.roles[ctx.role] and ctx.Suite.isReleased(manifest.roles[ctx.role]) then
    ctx.spec = manifest.roles[ctx.role]
  else
    ctx.role, ctx.spec = nil, nil
  end
  -- refresh the manifest-derived UI (version subtitle + role dropdown items)
  ctx.ui.subtitle:setText("release " .. tostring(manifest.version or "?"))
  local roleItems = {}
  for _, name in ipairs(ctx.order) do
    if ctx.Suite.isReleased(manifest.roles[name]) then
      roleItems[#roleItems + 1] = { text = name, callback = function() activateRole(ctx, name) end }
    end
  end
  ctx.ui.roleDropdown:setItems(roleItems)
  ctx.ui.roleDropdown:setSelectedText(ctx.role or "(choose)")
  refreshToolsDropdown(ctx)
  startCheck(ctx)   -- early-returns cleanly if ctx.spec is nil
  return true
end

--- Runs an engine call (performPlan) without blocking the Basalt render loop: basalt.schedule()
--- wraps it in a coroutine, so the fetch()/sleep() calls inside performPlan yield back to
--- Basalt's event loop between HTTP round-trips instead of freezing the screen for the whole
--- operation. Suite.sink is set for the duration so every say()/warn()/good()/bad() line lands
--- in the log panel; cleared afterwards, then the check re-arms so findings reflect the new state.
---
--- ctx.opInFlight guards against a theme toggle re-enabling the action buttons while this
--- coroutine is still yielding across multi-second HTTP round-trips (setButtonsEnabled(ctx,false)
--- alone is not enough: it only sets the CURRENT paint, but applyTheme() -- called from the
--- Theme button's onClick, which can fire at any point while this coroutine is suspended --
--- would otherwise recompute enabled-state from ctx.checkDone, which is still true from the
--- prior completed check). Set true before the op starts; cleared in the coroutine's tail on
--- BOTH the success and failure path, since that line always runs after the pcall regardless of
--- outcome.
---
--- persistChannel (default true): Go/Repair persist /eh2_channel.txt after a real install.
--- FLAG DEFAULTS / MIGRATE CONFIG pass false -- they are local config ops, not an install.
---
--- statusLabel (optional): a Label to mirror the op's outcome onto, IN ADDITION to the log
--- panel. The log lives on the Main tab's frame, so an op launched from the Advanced tab (the
--- FLAG DEFAULTS / MIGRATE CONFIG buttons) would otherwise write only into a hidden frame -- the
--- operator sees the buttons grey out and re-enable but no result. This label sits beside those
--- buttons on the Advanced tab: it shows "Working..." at launch, then the LAST engine line (the
--- summary good()/bad() line, e.g. "flag-defaults FCS: copied 6, skipped 0"), or the failure.
local function runEngineOp(ctx, fn, persistChannel, statusLabel)
  ctx.opInFlight = true
  setButtonsEnabled(ctx, false)
  ctx.ui.log:clear()
  if statusLabel then
    statusLabel:setText("Working..."); statusLabel:setForeground(ctx.pal.dim)
  end
  ctx.basalt.schedule(function()
    ctx.Suite.sink = function(text, c)
      logLine(ctx, text, c)
      -- Mirror onto the inline label too; the final line left standing is the op's summary.
      if statusLabel then statusLabel:setText(tostring(text)); statusLabel:setForeground(c or ctx.pal.text) end
    end
    local ok, err = pcall(fn)
    ctx.Suite.sink = nil
    ctx.opInFlight = false
    if not ok then
      logLine(ctx, "action failed: " .. tostring(err), ctx.pal.error)
      if statusLabel then statusLabel:setText("failed: " .. tostring(err)); statusLabel:setForeground(ctx.pal.error) end
    elseif persistChannel ~= false then
      -- Persist the channel actually installed so a later bare classic run stays on it (mirrors
      -- the classic suite writing /eh2_channel.txt on a real --dev/--min install). PROTECTED gates
      -- only the release install/delete path, never the Suite's own marker write.
      local f = fs.open(ctx.Suite.CHANNEL_FILE, "w")
      if f then f.write(ctx.channel .. "\n"); f.close() end
    end
    ctx.state = ctx.Suite.parseState(ctx.Suite.readFile(ctx.Suite.STATE_FILE))
    ctx.hasFiles = fs.exists("/startup.lua")
    startCheck(ctx, true)   -- post-op: force a fresh check so findings reflect the new on-disk state
  end)
end

-- Install ONE optional tool (by its manifest.tools key) if it's present in the current-channel
-- manifest. Reuses the SAME engine primitives the role install uses -- Suite.fetch (cache-busted +
-- retry), Suite.checksum (verify BEFORE write), Suite.writeRelease (guarded write). Runs INSIDE
-- runEngineOp's coroutine (Suite.sink is live, so logLine shows progress) right after a successful
-- role install. NOTE: a later role repair/switch may prune the tool's files (they are not part of
-- that role's manifest); reinstall the tool if that happens.
local function installOneTool(ctx, key, doneMsg, displayName)
  displayName = displayName or key
  local tool = ctx.manifest.tools and ctx.manifest.tools[key]
  if not tool or not tool.files then
    logLine(ctx, displayName .. " not in this manifest -- skipped", ctx.pal.error)
    return
  end
  logLine(ctx, ("installing tool: %s (%d file(s))..."):format(tool.title or displayName, #tool.files), ctx.pal.install)
  for _, entry in ipairs(tool.files) do
    local content, err = ctx.Suite.fetch(("%s/%s"):format(ctx.Suite.base, entry.src))
    if not content then
      logLine(ctx, "  fetch failed: " .. entry.src .. " (" .. tostring(err) .. ")", ctx.pal.error); return
    end
    if #content ~= entry.size or ctx.Suite.checksum(content) ~= entry.sum then
      logLine(ctx, "  arrived corrupt: " .. entry.src, ctx.pal.error); return
    end
    local final = "/" .. entry.dst
    if fs.exists(final) then fs.delete(final) end
    if not ctx.Suite.writeRelease(final, content) then
      logLine(ctx, "  write failed: " .. final .. " (disk full?)", ctx.pal.error); return
    end
  end
  logLine(ctx, doneMsg, ctx.pal.ok)
end

-- Install every optional tool whose Advanced-tab checkbox is ticked. ctx.manifest is ALREADY the
-- channel (min/dev) selected via the dev checkbox, so each tool installs straight from it.
local function installToolIfRequested(ctx)
  local keys = SuiteX.toolsToInstall({
    installSplitConfig = ctx.installSplitConfig,
    installFcs2Disk = ctx.installFcs2Disk,
  })
  local doneMsg = {
    splitconfig = "split-config tool installed -- run 'splitconfig' on the FCS to split a legacy fused config",
    fcs2disk = "FCS config-dump tool installed -- run 'fcs2disk' on the FCS to dump its configs to the shared disk",
  }
  local displayName = {
    splitconfig = "split-config tool",
    fcs2disk = "FCS config dump",
  }
  for _, key in ipairs(keys) do
    installOneTool(ctx, key, doneMsg[key], displayName[key])
  end
end

--- Builds the whole Basalt element tree once. Elements are never rebuilt after this; every
--- update (theme toggle, status refresh, progress) mutates the same instances via their setters.
local function buildUI(ctx)
  local basalt, pal = ctx.basalt, ctx.pal
  local main = basalt.getMainFrame()
  local W, H = main:getWidth(), main:getHeight()

  local ui = { logoLabels = {}, statusLabels = {}, pickerLabels = {}, buttons = {} }
  ctx.ui = ui
  ui.main = main
  main:setBackground(pal.bg)

  -- Logo -- autoSize=true (the default) so each equal-width row renders on ONE line. With
  -- autoSize=false and no explicit width, Basalt wraps the row at a tiny default width, so the
  -- rows overlap into the "glitch" the earlier build showed.
  local logoW, logoH = SuiteX.logoSize()
  for i, row in ipairs(SuiteX.logo) do
    ui.logoLabels[i] = main:addLabel({ x = 2, y = i, text = row, foreground = pal.accent })
  end

  -- Header row: Theme button (labelled with the CURRENT mode) + release version on the left; the
  -- Main / Advanced tab buttons flush-right (SuiteX draws its own tabs -- see paintTabButtons).
  local headerRow = logoH + 1
  ui.themeButton = main:addButton({ x = 2, y = headerRow, width = 7, height = 1,
    text = (ctx.mode == "dark") and "Dark" or "Light", background = pal.btn, foreground = pal.btnText })
  ui.themeButton:onClick(function()
    ctx.mode = (ctx.mode == "dark") and "light" or "dark"
    ctx.pal = SuiteX.theme.get(ctx.mode)
    applyTheme(ctx)
  end)
  ui.subtitle = main:addLabel({ x = 10, y = headerRow,
    text = "release " .. tostring(ctx.manifest.version or "?"), foreground = pal.dim })

  local advW, mainW = 10, 6
  local advX = W - advW
  local mainX = advX - mainW - 1
  ui.tabMain = main:addButton({ x = mainX, y = headerRow, width = mainW, height = 1, text = "Main" })
  ui.tabAdv = main:addButton({ x = advX, y = headerRow, width = advW, height = 1, text = "Advanced" })
  ui.tabMain:onClick(function() showTab(ctx, "main") end)
  ui.tabAdv:onClick(function() showTab(ctx, "advanced") end)

  -- Two content frames stacked in the same place; only one is visible at a time (the tab). Full
  -- width below the header, panel-coloured like the old tab body.
  local contentY = headerRow + 1
  local frameH = math.max(6, H - contentY + 1)
  ui.frameMain = main:addFrame({ x = 1, y = contentY, width = W, height = frameH, background = pal.panel })
  ui.frameAdv = main:addFrame({ x = 1, y = contentY, width = W, height = frameH, background = pal.panel })

  local fm = ui.frameMain
  local contentW = math.max(10, W - 2)

  -- Status: Role / Installed version / Live version / Files (4 lines).
  for i = 1, 4 do
    ui.statusLabels[i] = fm:addLabel({ x = 2, y = i, text = "", foreground = pal.text,
      autoSize = false, width = contentW })
  end

  local rowProgress = 5
  ui.progress = fm:addProgressBar({ x = 2, y = rowProgress, width = contentW, height = 1,
    foreground = pal.text, background = pal.bg, progressColor = pal.accent, showPercentage = true })

  local rowPickers = rowProgress + 1
  ui.pickerLabels[1] = fm:addLabel({ x = 2, y = rowPickers, text = "Role:", foreground = pal.dim })
  ui.roleDropdown = fm:addDropDown({ x = 8, y = rowPickers, width = 14, height = 1,
    selectedText = ctx.role or "(choose)", background = pal.bg, foreground = pal.text })
  ui.pickerLabels[2] = fm:addLabel({ x = 24, y = rowPickers, text = "Tool:", foreground = pal.dim })
  ui.toolDropdown = fm:addDropDown({ x = 30, y = rowPickers, width = math.max(8, W - 32), height = 1,
    selectedText = "(none)", background = pal.bg, foreground = pal.text })

  local rowButtons = frameH
  local rowLog = rowPickers + 1
  local logH = math.max(2, rowButtons - rowLog - 1)
  ui.log = fm:addList({ x = 2, y = rowLog, width = contentW, height = logH,
    selectable = false, emptyText = "", background = pal.bg, foreground = pal.text })

  local bw = math.max(6, math.floor((W - 2) / #BTN_KEYS) - 1)
  local bx = 2
  for _, key in ipairs(BTN_KEYS) do
    ui.buttons[key] = fm:addButton({ x = bx, y = rowButtons, width = bw, height = 1, text = BTN_LABELS[key] })
    bx = bx + bw + 1
  end

  -- Advanced tab: the dev-channel toggle -- graphical equivalent of the classic suite's --dev.
  -- Ticked installs the readable source channel (manifest-dev.lua); unticked the minified default.
  -- The choice re-checks the dashboard immediately; it is persisted to /eh2_channel.txt only on a
  -- real install (runEngineOp), never on the toggle itself.
  ui.advancedLabel = ui.frameAdv:addLabel({ x = 2, y = 2, text = "Install channel", foreground = pal.dim })
  local devOff, devOn = SuiteX.checkboxLabels("Dev version (readable source)")
  ui.devCheck = ui.frameAdv:addCheckBox({ x = 2, y = 3, checked = (ctx.channel == "dev"),
    text = devOff, checkedText = devOn, background = pal.bg, foreground = pal.text })
  ui.devCheck:onChange("checked", function(_, checked)
    if ctx.suppressDevBox then return end               -- ignore our own programmatic reverts
    local desired = checked and "dev" or "min"
    if desired == ctx.channel then return end            -- idempotent (also absorbs a revert-to-same)
    if ctx.opInFlight then                                -- no channel switch mid-install
      ctx.suppressDevBox = true
      ui.devCheck:setChecked(ctx.channel == "dev")
      ctx.suppressDevBox = false
      return
    end
    local okReload, err = reloadManifest(ctx, desired)
    if not okReload then
      logLine(ctx, "could not load the " .. desired .. " channel: " .. tostring(err), ctx.pal.error)
      ctx.suppressDevBox = true
      ui.devCheck:setChecked(ctx.channel == "dev")   -- revert to the channel still in effect
      ctx.suppressDevBox = false
    end
  end)

  -- Advanced tab: optionally install the standalone Split-config tool alongside the role. Ticked,
  -- a successful install/update also lays down `splitconfig` (+ its closure) so this PC can split
  -- a legacy fused config into the new per-role files. Just a flag here; installToolIfRequested
  -- does the work after the role install, in the same engine op.
  -- These two optional tools belong to the OLD fused-config world (splitconfig / fcs2disk). The
  -- config overhaul superseded them; they stay installable for now but are flagged [OUTDATED] and
  -- dimmed so the operator reaches for the "Config setup" ops below instead. Slated for removal.
  ui.toolLabel = ui.frameAdv:addLabel({ x = 2, y = 5, text = "Optional tools (legacy)", foreground = pal.dim })
  local splitOff, splitOn = SuiteX.checkboxLabels("Split config (split legacy config)  [OUTDATED]")
  ui.splitCfgCheck = ui.frameAdv:addCheckBox({ x = 2, y = 6, checked = (ctx.installSplitConfig == true),
    text = splitOff, checkedText = splitOn, background = pal.bg, foreground = pal.dim })
  ui.splitCfgCheck:onChange("checked", function(_, checked) ctx.installSplitConfig = checked end)

  -- Advanced tab: optionally install the standalone FCS config-dump tool alongside the role. Ticked,
  -- a successful install/update also lays down `fcs2disk` (+ its closure) so this PC can dump its
  -- FCS configs to the shared disk. Same flag-then-installToolIfRequested flow as the checkbox above.
  local fcs2diskOff, fcs2diskOn = SuiteX.checkboxLabels("FCS config dump (dump FCS configs)  [OUTDATED]")
  ui.fcs2diskCheck = ui.frameAdv:addCheckBox({ x = 2, y = 7, checked = (ctx.installFcs2Disk == true),
    text = fcs2diskOff, checkedText = fcs2diskOn, background = pal.bg, foreground = pal.dim })
  ui.fcs2diskCheck:onChange("checked", function(_, checked) ctx.installFcs2Disk = checked end)

  -- Advanced tab: FLAG DEFAULTS / MIGRATE CONFIG -- same local ops as classic --flag-defaults /
  -- --migrate-config, the current single-source config setup. STACKED one per row (they used to
  -- sit side-by-side with a 1-cell gap and, being grey-on-grey against the grey panel, read as a
  -- single line "FLAG DEFAULTS MIGRATE CONFIG"). Each op mirrors its result onto ui.advOpStatus
  -- below -- the log panel is on the Main frame and invisible here, so without this the ops gave
  -- no feedback. Lua 5.1 reuses the loop variable, so capture op.id in a fresh local per closure.
  ui.advOpLabel = ui.frameAdv:addLabel({ x = 2, y = 9, text = "Config setup", foreground = pal.dim })
  ui.advOpButtons = {}
  local opW = 16
  local opY = 10
  for _, op in ipairs(SuiteX.advancedOps()) do
    local btn = ui.frameAdv:addButton({
      x = 2, y = opY, width = opW, height = 1, text = op.label,
      background = pal.btn, foreground = pal.btnText,
    })
    local opId = op.id
    btn:onClick(function()
      if ctx.opInFlight then return end
      runEngineOp(ctx, function()
        ctx.Suite.runConfigFlags({ [opId] = true }, ctx.role)
      end, false, ui.advOpStatus)
    end)
    ui.advOpButtons[#ui.advOpButtons + 1] = btn
    opY = opY + 1
  end
  -- Inline result line for the two ops above (the log panel lives on the hidden Main frame).
  ui.advOpStatus = ui.frameAdv:addLabel({ x = 2, y = opY + 1, text = "", foreground = pal.dim,
    autoSize = false, width = math.max(10, W - 2) })

  ui.buttons.go:onClick(function()
    -- Defense in depth: setButtonsEnabled()/ctx.opInFlight already keep this disabled during an
    -- op, but a stray click that lands before a repaint catches up must still be a no-op rather
    -- than launching a second concurrent performPlan.
    if ctx.opInFlight or not ctx.spec or ctx.plan == "current" then return end
    runEngineOp(ctx, function()
      local r = ctx.Suite.performPlan(ctx.Suite.base, ctx.manifest, ctx.spec, ctx.role, ctx.plan,
        ctx.report and ctx.report.present == 0)
      installToolIfRequested(ctx)   -- only if its Advanced-tab checkbox is ticked
      return r
    end)
  end)
  ui.buttons.verify:onClick(function()
    if ctx.opInFlight then return end
    startCheck(ctx, true)   -- explicit user re-check: always re-arm, even for the same target
  end)
  ui.buttons.repair:onClick(function()
    if ctx.opInFlight or not ctx.spec then return end
    runEngineOp(ctx, function()
      local r = ctx.Suite.performPlan(ctx.Suite.base, ctx.manifest, ctx.spec, ctx.role, "repair",
        ctx.report and ctx.report.present == 0)
      installToolIfRequested(ctx)   -- also lay down any ticked Advanced-tab optional tool; Repair is
      -- the only always-enabled engine op, so it's the path to add a tool when the role is up-to-date
      -- (Go is disabled at "current"). Mirrors the go handler's post-install tool step.
      return r
    end)
  end)
  ui.buttons.switch:onClick(function() ui.roleDropdown:setState("opened") end)
  ui.buttons.tools:onClick(function() ui.toolDropdown:setState("opened") end)
  ui.buttons.quit:onClick(function() ctx.basalt.stop() end)

  local roleItems = {}
  for _, name in ipairs(ctx.order) do
    if ctx.Suite.isReleased(ctx.manifest.roles[name]) then
      roleItems[#roleItems + 1] = { text = name, callback = function() activateRole(ctx, name) end }
    end
  end
  ui.roleDropdown:setItems(roleItems)
  refreshToolsDropdown(ctx)

  -- Main tab visible first; applyTheme paints everything (incl. status + buttons) for the boot
  -- palette; then arm the check if a role is already resolved. The check runs on a scheduled
  -- coroutine (driveCheck), not a Basalt Timer.
  showTab(ctx, "main")
  applyTheme(ctx)
  if ctx.spec then startCheck(ctx) end
end

function SuiteX.run()
  if not term.isColour() then
    print("EasyHover 2 SuiteX needs an advanced (colour) terminal. Run the classic easyhover2_suite.lua instead.")
    return
  end
  if not http then
    abort("The http API is disabled on this computer, so nothing can be fetched.")
    return
  end

  -- ---- bootstrap: fetch the classic engine as a library (EH2_SUITE_NO_RUN suppresses its own
  -- keyboard-flow Suite.main() call at the bottom of the file; see easyhover2_suite.lua:1570).
  --
  -- The guard there reads the REAL global `_G.EH2_SUITE_NO_RUN`, not a bare name -- so a custom
  -- load() env (e.g. setmetatable({EH2_SUITE_NO_RUN=true},{__index=_G})) does NOT suppress it:
  -- `_G` inside the loaded chunk resolves through that env's __index straight past the custom
  -- table to the one real _G (Lua self-links _G._G = _G), so `_G.EH2_SUITE_NO_RUN` there reads
  -- the untouched real global, still nil, and Suite.main() runs anyway. Verified with a CraftOS-PC
  -- probe. The fix -- and the pattern this codebase's own tests/suite_probe.lua and
  -- tests/test_suite.lua already use -- is to set the flag on the real global directly.
  _G.EH2_SUITE_NO_RUN = true
  local suiteBody, suiteErr = bootFetch(BOOT_BASE .. "/easyhover2_suite.lua")
  if not suiteBody then
    _G.EH2_SUITE_NO_RUN = nil
    abort("could not fetch the Suite engine: " .. tostring(suiteErr))
    return
  end
  -- Load with THIS program's own environment (`_ENV`), not the bare base `_G`. In CC:Tweaked
  -- `shell` (and `require`/`package`) are PROGRAM-scoped -- injected into a program's `_ENV`, not
  -- into base `_G` -- so a chunk loaded without an env can't see them and blows up the moment the
  -- engine touches `shell` (e.g. Suite.selfUpdateNotice's shell.getRunningProgram). `_ENV` carries
  -- shell; `_G` still resolves through it to the one real global, so the `_G.EH2_SUITE_NO_RUN`
  -- suppression above keeps working. (Same reason the Basalt loadfile below passes `_ENV`.)
  local chunk, loadErr = load(suiteBody, "=suite", "t", _ENV)
  if not chunk then
    _G.EH2_SUITE_NO_RUN = nil
    abort("the Suite engine did not parse: " .. tostring(loadErr))
    return
  end
  local loadOk, Suite = pcall(chunk)
  _G.EH2_SUITE_NO_RUN = nil
  if not loadOk or type(Suite) ~= "table" then
    abort("the Suite engine failed to load: " .. tostring(Suite))
    return
  end

  -- ---- the release channel (honors /eh2_channel.txt, same marker the classic suite uses) + manifest
  local channel = Suite.resolveChannel(nil, Suite.readFile(Suite.CHANNEL_FILE))
  local manifestBody, manifestErr = Suite.fetch(Suite.base .. "/" .. Suite.manifestName(channel))
  if not manifestBody then
    abort("could not fetch the release manifest: " .. tostring(manifestErr))
    return
  end
  local manifest = textutils.unserialise(manifestBody)
  if type(manifest) ~= "table" or type(manifest.roles) ~= "table" or not manifest.version then
    abort("the release manifest is not readable.")
    return
  end

  -- ---- ensure Basalt (cache-checked; only fetched when the local copy doesn't match)
  local localBasalt = Suite.readFile("/basalt-full.lua")
  if SuiteX.basaltAction(localBasalt, manifest.basalt, Suite.checksum) == "fetch" then
    local body, fetchErr = Suite.fetch(Suite.base .. "/release/basalt-full.lua")
    if not body then
      abort("could not fetch Basalt: " .. tostring(fetchErr))
      return
    end
    if manifest.basalt and (#body ~= manifest.basalt.size or Suite.checksum(body) ~= manifest.basalt.sum) then
      abort("Basalt arrived corrupt; nothing was changed.")
      return
    end
    if not writeLocal("/basalt-full.lua", body) then
      abort("could not write /basalt-full.lua (disk full?).")
      return
    end
  end
  -- NOT dofile(): CC:Tweaked's dofile (bios.lua) loads with the BIOS's own base _G, which has
  -- no require/package/shell -- and the vendored bundle needs package.path for its internal
  -- module loader. loadfile(path, nil, _ENV) loads it with THIS program's own environment
  -- (which does have them, since SuiteX itself runs as a normal shell program), same as the
  -- classic Suite's own bootstrap load() a few lines above. Verified against CC:Tweaked's
  -- bios.lua (dofile = loadfile(file, nil, _G) with bios's own _G) and against CraftOS-PC
  -- headless: dofile("/release/basalt-full.lua") fails ("attempt to index global 'package'"),
  -- loadfile(path, nil, _ENV) succeeds.
  local basaltChunk, basaltLoadErr = loadfile("/basalt-full.lua", nil, _ENV)
  if not basaltChunk then
    abort("Basalt did not parse: " .. tostring(basaltLoadErr))
    return
  end
  local basaltOk, basalt = pcall(basaltChunk)
  if not basaltOk or type(basalt) ~= "table" then
    abort("Basalt failed to load: " .. tostring(basalt))
    return
  end

  -- ---- what is installed here (mirrors Suite.main, easyhover2_suite.lua:1362-1379, minus the
  -- keyboard askForRole prompt -- SuiteX never blocks on stdin; an unresolved role is picked
  -- from the Role dropdown in the dashboard instead)
  local state = Suite.parseState(Suite.readFile(Suite.STATE_FILE))
  local detected = Suite.detectRole(manifest)
  local role = state.role or detected
  local spec = nil
  if role and manifest.roles[role] and Suite.isReleased(manifest.roles[role]) then
    spec = manifest.roles[role]
  else
    role = nil
  end
  -- Distinguishes "Not installed!" (clean machine) from "FIX!" (files present but no role could
  -- be resolved) when role is nil. /startup.lua is present after any role install.
  local hasFiles = fs.exists("/startup.lua")

  local ctx = {
    mode = "dark", pal = SuiteX.theme.get("dark"),
    Suite = Suite, basalt = basalt, manifest = manifest, order = buildOrder(manifest),
    role = role, spec = spec, state = state, hasFiles = hasFiles, tab = "main",
    plan = nil, report = nil, diffLabel = nil, checkDone = false, checkTarget = nil, opInFlight = false,
    channel = channel, manifests = { [channel] = manifest }, suppressDevBox = false,
  }

  buildUI(ctx)
  -- Flush the stale event backlog (from a just-stopped FCS/UI program) BEFORE basalt starts pumping,
  -- so the freshly-armed integrity-check coroutine's sleep-timer isn't starved after its first batch
  -- -- the ~28-29% wedge that forced a second launch every time. See SuiteX.drainEvents.
  SuiteX.drainEvents()
  basalt.run()
end

if not _G.EH2_SUITEX_NO_RUN then SuiteX.run() end
return SuiteX
