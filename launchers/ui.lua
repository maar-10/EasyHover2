package.path = "/?.lua;/?/init.lua;" .. package.path
-- Boot phase mirrors the FCS (launchers/fcs.lua -> fcs/boot/loaderui.run): pick the config source
-- FIRST, then the logging switch, then the boot question.

-- UI CONFIG source: 1 current / 2 DEFAULT (session overlay) / 3 disk (import). Empty -> current.
require("fcs.boot.pick").applyKind("uicfg", "UI CONFIG")

-- Boot-time no-op logging switch (mirrors the FCS's _G.EH2_FLIGHTLOG). Y -> record all UI
-- actions/inputs/loop-timings this session; press P in-cockpit to upload the rolling log to carbide.
-- N (or anything else) -> logging stays a single boolean no-op the whole session.
write("Start UI with logging? (Y/N): ")
local ans = (read() or ""):lower()
_G.EH2_UILOG = (ans == "y" or ans == "yes")

-- Boot question (mirrors loaderui.confirmBoot): only start the cockpit on a clear Y; N returns to
-- the console with the config already saved and nothing started. Loops until a clear answer.
local function confirmBoot()
  while true do
    write("UI config complete -- boot UI? (Y/N): ")
    local input = (read() or ""):lower()
    if input == "y" or input == "yes" then return true end
    if input == "n" or input == "no" then return false end
    print("  please answer Y or N")
  end
end
if confirmBoot() then
  require("ui.basalt.app").run()
else
  print("returning to console (config saved, UI not started)")
end
