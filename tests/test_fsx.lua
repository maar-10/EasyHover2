local t = require("tests.framework")
local fsx = require("fcs.io.fsx")

local PATH = "/eh2_test_fsx.tbl"
local DIR  = "/eh2_test_fsx_dir"

local function cleanup()
  if fs.exists(PATH) then fs.delete(PATH) end
  if fs.exists(PATH .. ".tmp") then fs.delete(PATH .. ".tmp") end
  if fs.exists(DIR) then fs.delete(DIR) end
end

t.test("fsx.read: absent path returns nil", function()
  cleanup()
  t.eq(fsx.read(PATH), nil)
end)

t.test("fsx.read: a directory returns nil (not an error)", function()
  cleanup()
  fs.makeDir(DIR)
  t.eq(fsx.read(DIR), nil)
  cleanup()
end)

t.test("fsx.read: present file returns its body", function()
  cleanup()
  local f = fs.open(PATH, "w"); f.write("hello fsx"); f.close()
  t.eq(fsx.read(PATH), "hello fsx")
  cleanup()
end)

t.test("fsx.writeAtomic: writes the body, readable back, tmp cleaned up (moved into place)", function()
  cleanup()
  local ok = fsx.writeAtomic(PATH, "atomic body")
  t.eq(ok, true)
  t.eq(fs.exists(PATH), true)
  t.eq(fs.exists(PATH .. ".tmp"), false)
  local f = fs.open(PATH, "r"); local body = f.readAll(); f.close()
  t.eq(body, "atomic body")
  cleanup()
end)

t.test("fsx.writeAtomic: overwrites an existing file atomically", function()
  cleanup()
  local f = fs.open(PATH, "w"); f.write("old"); f.close()
  fsx.writeAtomic(PATH, "new")
  local f2 = fs.open(PATH, "r"); local body = f2.readAll(); f2.close()
  t.eq(body, "new")
  cleanup()
end)

t.test("fsx.delete: removes an existing file", function()
  cleanup()
  local f = fs.open(PATH, "w"); f.write("x"); f.close()
  fsx.delete(PATH)
  t.eq(fs.exists(PATH), false)
end)

t.test("fsx.delete: absent path is a no-op, not an error", function()
  cleanup()
  fsx.delete(PATH) -- must not throw
  t.eq(fs.exists(PATH), false)
end)

t.test("fsx.exists: true for a present file, false for absent", function()
  cleanup()
  t.eq(fsx.exists(PATH), false)
  local f = fs.open(PATH, "w"); f.write("x"); f.close()
  t.eq(fsx.exists(PATH), true)
  cleanup()
end)

t.test("writeAtomic: false on unopenable tmp; existing file left intact", function()
  local path = "/eh2_fsx_guard.tbl"
  if fs.exists(path) then fs.delete(path) end
  fsx.writeAtomic(path, "PRECIOUS")
  local realOpen = fs.open
  fs.open = function(p, m) if m == "w" then return nil end return realOpen(p, m) end
  local ret = fsx.writeAtomic(path, "OVERWRITE-ATTEMPT")
  fs.open = realOpen
  t.eq(ret, false, "reports failure instead of crashing")
  t.eq(fsx.read(path), "PRECIOUS", "previous good content survives the failed write")
  fs.delete(path)
end)
