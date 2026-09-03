local hwconfig = require("fcs.io.hwconfig")
local tuningdefaults = require("fcs.io.tuningdefaults")

local M = { FILES = { devbind = "eh2_devbind.tbl", senscal = "eh2_senscal.tbl", tuning = "eh2_tuning.tbl", fuelcal = "eh2_fuelcal.tbl" } }

function M.defaults(kind)
  local d = hwconfig.defaults()
  if kind == "devbind" then return { thrusters = d.thrusters, sensors = d.sensors, fuelRelay = d.fuelRelay } end
  if kind == "senscal" then return d.bindings end
  if kind == "tuning" then return tuningdefaults.get() end
  if kind == "fuelcal" then return { fuel = require("fcs.fueltable").default } end
  error("unknown cfg kind: " .. tostring(kind))
end

function M.merge(kind, saved)
  saved = saved or {}
  -- L2: a senscal saved before compassSign existed carries signHeading but no compassSign; the
  -- default merge would then set compassSign=+1, mirroring the PFD tape on a signHeading=-1 craft.
  -- Backfill compassSign := signHeading BEFORE merging (on a copy) when it is absent. An explicit
  -- compassSign the operator set is never touched.
  if kind == "senscal" and type(saved) == "table"
     and saved.signHeading ~= nil and saved.compassSign == nil then
    local copy = {}
    for k, v in pairs(saved) do copy[k] = v end
    copy.compassSign = saved.signHeading
    saved = copy
  end
  return hwconfig.merge(saved, M.defaults(kind))
end

function M.validate(kind, cfg)
  if type(cfg) ~= "table" then return false, "not a table" end
  local req = ({ devbind = {"thrusters","sensors"}, senscal = {"signPitch","signHeading"}, tuning = {"gains","caps","feel"}, fuelcal = {"fuel"} })[kind]
  for _, k in ipairs(req or {}) do if cfg[k] == nil then return false, "missing " .. k end end
  return true
end

function M.load(kind, read)
  local body = read(M.FILES[kind])
  if body == nil then return M.merge(kind, {}), false, nil end
  local saved = textutils.unserialise(body)
  if type(saved) ~= "table" then return M.merge(kind, {}), true, "unparseable" end
  return M.merge(kind, saved), true, nil
end

function M.sessionFile(kind)
  local f = M.FILES[kind]
  if not f then return nil end
  return (f:gsub("%.tbl$", ".session.tbl"))
end

-- Session overlay (DEFAULT-for-this-boot) wins when present and parseable; unparseable
-- session falls through to the current split. Same merge contract as M.load.
function M.loadLive(kind, read)
  local sf = M.sessionFile(kind)
  if sf then
    local body = read(sf)
    if body ~= nil then
      local saved = textutils.unserialise(body)
      if type(saved) == "table" then return M.merge(kind, saved), true, nil end
    end
  end
  return M.load(kind, read)
end

function M.save(kind, cfg, write)
  return write(M.FILES[kind], textutils.serialise(cfg))
end

function M.splitLegacy(hw)
  return { devbind = { thrusters = hw.thrusters, sensors = hw.sensors, fuelRelay = hw.fuelRelay },
           senscal = hw.bindings }
end

function M.assembleHw(devbind, senscal)
  return { thrusters = devbind.thrusters, sensors = devbind.sensors, fuelRelay = devbind.fuelRelay,
           bindings = senscal }
end

function M.tryAssemble(read)
  local db, dbEx, dbErr = M.loadLive("devbind", read)
  local sc, scEx, scErr = M.loadLive("senscal", read)
  if dbErr or scErr then return nil, dbErr or scErr end
  -- Both splits must exist to assemble. If only one is present, load() filled the other with
  -- IDENTITY defaults; assembling would fly a real craft with an identity sign map (F3). Return
  -- nil so the caller falls through to the fused /eh2_hw_config.tbl (split preferred only when complete).
  if not dbEx or not scEx then return nil, nil end
  return M.assembleHw(db, sc)
end

return M
