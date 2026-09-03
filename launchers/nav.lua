package.path = "/?.lua;/?/init.lua;" .. package.path
-- NAV + waypoint sources independently: 1 current / 2 DEFAULT (session overlay) / 3 disk (import).
-- Empty/invalid -> current so unattended boot still works.
local pick = require("fcs.boot.pick")
pick.applyKind("nav", "NAV CONFIG")
pick.applyKind("nav_wpt", "NAV WAYPOINTS")
require("nav.app").run()
