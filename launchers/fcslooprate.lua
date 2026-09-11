-- Boots the FCS with LOOP-RATE-ONLY logging on (minimal-impact: per-cycle dt only, dumped on P/
-- exit, no periodic I/O). Skips the boot prompt. Identical to fcs/fcslog otherwise.
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_FLIGHTLOG = "loop"
require("tools.flight")
