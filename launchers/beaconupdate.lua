package.path = "/?.lua;/?/init.lua;" .. package.path
-- launchers/beaconupdate.lua
-- Shell entry for the beacon updater: real ender modem + persisted token/channel, then delegate to
-- the pure tools.beaconupdate core and print the report. Prompts for the shared secret once and
-- saves it to /eh2_beacon_update.tbl (must match the beacons' [U] update token).
local Tool = require("tools.beaconupdate")
local Update = require("beacon.update")

local CFG_PATH = "/eh2_beacon_update.tbl"

local function loadCfg()
  if not fs.exists(CFG_PATH) or fs.isDir(CFG_PATH) then return {} end
  local f = fs.open(CFG_PATH, "r"); local raw = f.readAll(); f.close()
  local c = textutils.unserialise(raw or ""); return type(c) == "table" and c or {}
end

local function saveCfg(c)
  local f = fs.open(CFG_PATH, "w"); f.write(textutils.serialise(c)); f.close()
end

local function findModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local m = peripheral.wrap(name)
      if m.isWireless and m.isWireless() then return m end
    end
  end
  return nil
end

local cfg = loadCfg()
cfg.channel = cfg.channel or 65000
if not Update.validToken(cfg.updateToken) then
  write("Set the shared update secret (must match the beacons): ")
  local tok = read()
  tok = tostring(tok or ""):gsub("%s", "")
  if tok == "" then print("no token entered -- aborting."); return end
  cfg.updateToken = tok; saveCfg(cfg)
end

local modem = findModem()
if not modem then print("no wireless/ender modem found."); return end
modem.open(cfg.channel)

-- One shared deadline across all pull() calls: the whole ack window opens at the first pull and every
-- pull races the SAME clock, so beacons that answer late still land inside the window.
local deadline
local r = Tool.run({
  token = cfg.updateToken, channel = cfg.channel,
  transmit = function(ch, reply, msg) modem.transmit(ch, reply, msg) end,
  pull = function(timeoutS)
    if deadline == nil then deadline = os.clock() + timeoutS end
    local timer = os.startTimer(deadline - os.clock())   -- ONE deadline timer per pull: the old
    while true do                                        -- code re-armed a fresh timer on every
      local remaining = deadline - os.clock()            -- non-matching event, leaking strays
      if remaining <= 0 then os.cancelTimer(timer) return nil end
      local ev = { os.pullEvent() }
      if ev[1] == "modem_message" then
        local f = Update.decode(ev[5])
        if f and f.k == Update.ACK_KIND then
          os.cancelTimer(timer)
          return f.id
        end
      elseif ev[1] == "timer" and ev[2] == timer then
        return nil
      end
    end
  end,
})

if not r.ok then print(r.err); return end
if #r.responders == 0 then
  print("no beacons answered (asleep/unloaded, or wrong token/channel).")
else
  print("updating: " .. table.concat(r.responders, ", "))
end
