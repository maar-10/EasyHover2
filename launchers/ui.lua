package.path = "/?.lua;/?/init.lua;" .. package.path
-- Boot-time no-op logging switch (mirrors the FCS's _G.EH2_FLIGHTLOG). Y -> record all UI
-- actions/inputs/loop-timings this session; press P in-cockpit to upload the rolling log to carbide.
-- N (or anything else) -> logging stays a single boolean no-op the whole session.
write("Start UI with logging? (Y/N): ")
local ans = (read() or ""):lower()
_G.EH2_UILOG = (ans == "y" or ans == "yes")
-- UI CONFIG source: 1 current / 2 DEFAULT (session overlay) / 3 disk (import). Empty -> current.
require("fcs.boot.pick").applyKind("uicfg", "UI CONFIG")
require("ui.basalt.app").run()
