-- nav/waypoints.lua
-- PURE waypoint/route store, owned by the NAV PC (the navigation authority). Model + CRUD +
-- validation + persistence for `/eh2_nav_wpt.tbl`. The cockpit NAV menu is a sync client that reads
-- a cached copy and sends mutations the NAV applies here (see nav/wptserver.lua). Mirrors
-- ui/config.lua's defaults/withDefaults/load/save shape. No Basalt/peripherals; load/save use fs.
--
-- Store shape: { waypoints = { {name,x,y,z,type}, ... }, routes = { {name, legs={{wpt,alt},...}} } }.
-- Waypoints are a stable insertion-ordered array; find/filter are O(n) (fine for CC-scale counts).
local M = {}

M.TYPES = { "base", "outpost", "facility", "poi" }
local TYPE_SET = {}
for _, tp in ipairs(M.TYPES) do TYPE_SET[tp] = true end

function M.isType(t) return TYPE_SET[t] == true end

function M.defaults()
  return { waypoints = {}, routes = {} }
end

function M.withDefaults(saved)
  saved = saved or {}
  return {
    waypoints = type(saved.waypoints) == "table" and saved.waypoints or {},
    routes    = type(saved.routes)    == "table" and saved.routes    or {},
  }
end

-- Index of a waypoint by name (or nil). Internal.
local function indexOf(store, name)
  for i, w in ipairs(store.waypoints) do if w.name == name then return i end end
  return nil
end

--- find(store, name) -> waypoint | nil.
function M.find(store, name)
  local i = indexOf(store, name)
  return i and store.waypoints[i] or nil
end

-- Validate a waypoint spec -> normalised copy | nil, err.
local function validate(spec)
  if type(spec) ~= "table" then return nil, "no waypoint" end
  if type(spec.name) ~= "string" or spec.name == "" then return nil, "name required" end
  if type(spec.x) ~= "number" or type(spec.y) ~= "number" or type(spec.z) ~= "number" then
    return nil, "x/y/z must be numbers"
  end
  if not M.isType(spec.type) then return nil, "invalid type" end
  return { name = spec.name, x = spec.x, y = spec.y, z = spec.z, type = spec.type }
end

--- addWpt(store, spec) -> waypoint | nil, err. Rejects a duplicate NAME (use editWpt to change one).
function M.addWpt(store, spec)
  local w, err = validate(spec)
  if not w then return nil, err end
  if indexOf(store, w.name) then return nil, "name exists" end
  store.waypoints[#store.waypoints + 1] = w
  return w
end

--- editWpt(store, name, fields) -> waypoint | nil, err. Updates x/y/z/type of an existing waypoint.
--- fields.name renames (rejects if the new name already exists). Validates the merged result.
function M.editWpt(store, name, fields)
  local i = indexOf(store, name)
  if not i then return nil, "not found" end
  local cur = store.waypoints[i]
  fields = fields or {}
  local newName = name
  if type(fields.name) == "string" and fields.name ~= "" then newName = fields.name end
  if newName ~= name and indexOf(store, newName) then return nil, "name exists" end
  local merged = { name = newName,
    x = fields.x ~= nil and fields.x or cur.x,
    y = fields.y ~= nil and fields.y or cur.y,
    z = fields.z ~= nil and fields.z or cur.z,
    type = fields.type ~= nil and fields.type or cur.type }
  local w, err = validate(merged)
  if not w then return nil, err end
  store.waypoints[i] = w
  return w
end

--- deleteWpt(store, name) -> true | nil.
function M.deleteWpt(store, name)
  local i = indexOf(store, name)
  if not i then return nil end
  table.remove(store.waypoints, i)
  return true
end

--- filter(store, type) -> array of waypoints of `type`, or ALL when type is nil/"all". Stable order.
function M.filter(store, type)
  local all = (type == nil or type == "all")
  local out = {}
  for _, w in ipairs(store.waypoints) do
    if all or w.type == type then out[#out + 1] = w end
  end
  return out
end

--- mergeWpts(store, incoming): add new + REPLACE same-name (dedupe by name). Used by disk import.
--- Invalid incoming entries are skipped, never crash. Returns the number merged.
function M.mergeWpts(store, incoming)
  local n = 0
  for _, spec in ipairs(incoming or {}) do
    local w = validate(spec)
    if w then
      local i = indexOf(store, w.name)
      if i then store.waypoints[i] = w else store.waypoints[#store.waypoints + 1] = w end
      n = n + 1
    end
  end
  return n
end

-- ---- routes (Phase 2): a route is { name, legs = { {wpt, alt}, ... } } -- ordered connected legs,
-- each a waypoint reference + a per-leg altitude override. ----

local function routeIndex(store, name)
  store.routes = store.routes or {}
  for i, r in ipairs(store.routes) do if r.name == name then return i end end
  return nil
end

--- findRoute(store, name) -> route | nil.
function M.findRoute(store, name)
  local i = routeIndex(store, name)
  return i and store.routes[i] or nil
end

--- addRoute(store, name) -> route | nil, err. Rejects blank / duplicate names.
function M.addRoute(store, name)
  if type(name) ~= "string" or name == "" then return nil, "name required" end
  if routeIndex(store, name) then return nil, "name exists" end
  local r = { name = name, legs = {} }
  store.routes[#store.routes + 1] = r
  return r
end

--- renameRoute(store, name, newName) -> true | nil, err.
function M.renameRoute(store, name, newName)
  if type(newName) ~= "string" or newName == "" then return nil, "name required" end
  if routeIndex(store, newName) then return nil, "name exists" end
  local i = routeIndex(store, name)
  if not i then return nil, "not found" end
  store.routes[i].name = newName
  return true
end

--- deleteRoute(store, name) -> true | nil.
function M.deleteRoute(store, name)
  local i = routeIndex(store, name)
  if not i then return nil end
  table.remove(store.routes, i)
  return true
end

--- addLeg(store, routeName, wptName, alt) -> leg | nil, err. `alt` defaults to the waypoint's y.
--- The waypoint must currently exist (you build routes from real waypoints; a later delete leaves the
--- leg unresolved -- see resolveLegs).
function M.addLeg(store, routeName, wptName, alt)
  local r = M.findRoute(store, routeName)
  if not r then return nil, "no such route" end
  local wpt = M.find(store, wptName)
  if not wpt then return nil, "no such waypoint" end
  local leg = { wpt = wptName, alt = (type(alt) == "number") and alt or wpt.y }
  r.legs[#r.legs + 1] = leg
  return leg
end

--- editLegAlt(store, routeName, i, alt) -> true | nil, err.
function M.editLegAlt(store, routeName, i, alt)
  local r = M.findRoute(store, routeName)
  if not r or not r.legs[i] then return nil, "no such leg" end
  if type(alt) ~= "number" then return nil, "alt must be a number" end
  r.legs[i].alt = alt
  return true
end

--- deleteLeg(store, routeName, i) -> true | nil.
function M.deleteLeg(store, routeName, i)
  local r = M.findRoute(store, routeName)
  if not r or not r.legs[i] then return nil end
  table.remove(r.legs, i)
  return true
end

--- moveLeg(store, routeName, i, dir) -> true | nil. Swaps leg i with its neighbour (dir +1 down /
--- -1 up); nil if the move would fall off either end.
function M.moveLeg(store, routeName, i, dir)
  local r = M.findRoute(store, routeName)
  if not r or not r.legs[i] then return nil end
  local j = i + (dir or 0)
  if j < 1 or j > #r.legs then return nil end
  r.legs[i], r.legs[j] = r.legs[j], r.legs[i]
  return true
end

--- resolveLegs(store, route) -> array of { wpt, alt, x, z, y, resolved }. Pairs each leg with its
--- waypoint's x/z; `y` is the PER-LEG altitude (leg.alt). A leg whose waypoint was deleted is flagged
--- resolved=false (x/z/y nil) rather than crashing.
function M.resolveLegs(store, route)
  local out = {}
  for _, leg in ipairs((route and route.legs) or {}) do
    local wpt = M.find(store, leg.wpt)
    if wpt then
      out[#out + 1] = { wpt = leg.wpt, alt = leg.alt, x = wpt.x, z = wpt.z, y = leg.alt, resolved = true }
    else
      out[#out + 1] = { wpt = leg.wpt, alt = leg.alt, resolved = false }
    end
  end
  return out
end

--- mergeRoutes(store, incoming): add new + REPLACE same-name routes (dedupe by name). Used by disk
--- import. Only tables with a name + legs array are accepted. Returns the number merged.
function M.mergeRoutes(store, incoming)
  store.routes = store.routes or {}
  local function idx(name) for i, r in ipairs(store.routes) do if r.name == name then return i end end end
  local n = 0
  for _, r in ipairs(incoming or {}) do
    if type(r) == "table" and type(r.name) == "string" and r.name ~= "" and type(r.legs) == "table" then
      local i = idx(r.name)
      if i then store.routes[i] = r else store.routes[#store.routes + 1] = r end
      n = n + 1
    end
  end
  return n
end

-- ---- persistence (atomic tmp+move, pre-merge load -- mirrors ui/config.lua) ----

local CURRENT_PATH = "/eh2_nav_wpt.tbl"
local SESSION_PATH = "/eh2_nav_wpt.session.tbl"

local function loadAt(path)
  if not fs.exists(path) or fs.isDir(path) then return nil, false end
  local f = fs.open(path, "r")
  if not f then return nil, true end
  local raw = f.readAll(); f.close()
  local cfg = textutils.unserialise(raw or "")
  if type(cfg) ~= "table" then return nil, true end
  return M.withDefaults(cfg), true
end

--- load(path) -> store|nil, existed. Never throws.
--- Loading current prefers a parseable session overlay (DEFAULT-for-this-boot).
function M.load(path)
  if path == CURRENT_PATH then
    local cfg = select(1, loadAt(SESSION_PATH))
    if cfg then return cfg, true end
  end
  return loadAt(path)
end

--- save(path, store) -> true|false, err. Atomic tmp write + move.
function M.save(path, store)
  local tmp = path .. ".tmp"
  local f = fs.open(tmp, "w")
  if not f then return false, "could not open tmp" end
  f.write(textutils.serialise(store)); f.close()
  if fs.exists(path) then fs.delete(path) end
  fs.move(tmp, path)
  return true
end

return M
