package.path = "/?.lua;/?/init.lua;" .. package.path
pcall(function() require("fcs.io.cut").all() end)
local loaderui = require("fcs.boot.loaderui")
local assembled, mode = loaderui.run()
if assembled then
  -- Boot-chosen logging mode: tools/flight.lua reads _G.EH2_FLIGHTLOG (same hook the `fcslog` /
  -- `fcslooprate` launchers set). "full"/"loop" at the logging prompt -> instrumentation for this
  -- instance; nil (None, the default) -> no logging.
  _G.EH2_FLIGHTLOG = mode
  require("tools.flight")
end
