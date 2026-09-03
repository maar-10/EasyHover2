-- Boots the FCS flight app with per-cycle instrumentation ON, skipping the boot loader's
-- "Enable FCS logging?" prompt (a diagnostics shortcut). Press P in-flight to start
-- streaming /eh2_flight_log.csv to carbide (P again stops); a tick appends every 10s.
-- Identical to `fcs`/`flight` otherwise.
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_FLIGHTLOG = true
require("tools.flight")
