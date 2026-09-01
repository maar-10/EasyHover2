local t = require("tests.framework")
local Codec = require("fcs.bringup.logcodec")

local HDR = "t,phase,mode,sp_alt,alt,vSpeed,dut1"

t.test("round-trip: decode(encode(header, rows)) restores every row exactly", function()
  local rows = {
    "0,H,N,5,64,0.1,0",
    "0.06,H,N,5,64.02,0.08,0",
    "0.13,H,N,5,64.05,0.09,0",
  }
  local decoded, hdr = Codec.decode(Codec.encode(HDR, rows))
  t.eq(hdr, HDR, "header comes back verbatim")
  t.eq(#decoded, #rows)
  for i, row in ipairs(rows) do t.eq(decoded[i], row, "row " .. i .. " restored verbatim") end
end)

t.test("identical consecutive rows encode as a bare = marker", function()
  local rows = { "1,H,N,5,64,0,0", "1,H,N,5,64,0,0" }
  local lines = {}
  for line in Codec.encode(HDR, rows):gmatch("[^\n]+") do lines[#lines+1] = line end
  t.eq(lines[1], HDR)
  t.eq(lines[2], rows[1], "first row is verbatim")
  t.eq(lines[3], "=", "identical row collapses to =")
  local decoded = Codec.decode(Codec.encode(HDR, rows))
  t.eq(decoded[2], rows[2], "decode expands = to the previous row")
end)

t.test("delta lines carry only changed fields, addressed by column index", function()
  -- row2 differs from row1 only in columns 1 (t) and 5 (alt)
  local rows = { "1,H,N,5,64,0,0", "1.06,H,N,5,64.5,0,0" }
  local lines = {}
  for line in Codec.encode(HDR, rows):gmatch("[^\n]+") do lines[#lines+1] = line end
  t.eq(lines[2], rows[1])
  t.truthy(lines[3]:find("^1:1%.06,5:64%.5$"), "only changed cells, as i:value pairs: " .. lines[3])
  local decoded = Codec.decode(Codec.encode(HDR, rows))
  t.eq(decoded[2], rows[2])
end)

t.test("empty window encodes to just the header", function()
  t.eq(Codec.encode(HDR, {}), HDR)
  local decoded = Codec.decode(HDR)
  t.eq(#decoded, 0)
  t.eq(select(2, Codec.decode(HDR)), HDR)
end)

t.test("single row round-trips verbatim", function()
  local rows = { "0,I,,0,0,0,0" }
  local decoded = Codec.decode(Codec.encode(HDR, rows))
  t.eq(#decoded, 1)
  t.eq(decoded[1], rows[1])
end)

t.test("summary (# lines) and blanks survive decode untouched", function()
  local rows = { "1,H,N,5,64,0,0", "1.06,H,N,5,64,0,0" }
  local text = "# EasyHover 2 hover bring-up log\n# legend: phase H=HOLD\n\n"
    .. Codec.encode(HDR, rows) .. "\n\n# samples: 2\n"
  local decoded, hdr = Codec.decode(text)
  t.eq(hdr, HDR)
  t.eq(#decoded, 2)
  t.eq(decoded[1], rows[1])
  t.eq(decoded[2], rows[2])
end)

t.test("decode handles the hover_test layout: full summary block BEFORE the header+rows", function()
  local rows = { "1,H,N,5,64,0,0", "1.06,H,N,5,64,0,0" }
  local text = table.concat({
    "# EasyHover 2 hover bring-up log", "# legend: phase H=HOLD",
    "# samples: 2", "# duration_s: 0.06", "",
    Codec.encode(HDR, rows), "",
  }, "\n")
  local decoded, hdr = Codec.decode(text)
  t.eq(hdr, HDR, "header found after the summary block")
  t.eq(#decoded, 2, "summary lines before the rows must not be mistaken for data")
  t.eq(decoded[1], rows[1])
  t.eq(decoded[2], rows[2])
end)

t.test("encode requires a header line (a headerless stream cannot round-trip)", function()
  local ok, err = pcall(Codec.encode, nil, { "1,H,N,5" })
  t.truthy(not ok, "encode(nil, rows) must error")
  t.truthy(tostring(err):find("header"), "error names the missing header: " .. tostring(err))
  local ok2, err2 = pcall(Codec.encode, "", { "1,H,N,5" })
  t.truthy(not ok2 and tostring(err2):find("header"), "encode('', rows) must error: " .. tostring(err2))
end)

t.test("a leading = line never crashes decode (corrupt/truncated file)", function()
  local decoded = Codec.decode(HDR .. "\n=")
  t.eq(#decoded, 0, "= before any row is dropped, not a crash")
end)

t.test("a realistic 3000-row cruise window encodes under 150 KB", function()
  -- Deterministic synthetic cruise at ~16 Hz: slow altitude bob, tiny attitude jitter,
  -- static duties (trimmed), phase/mode constant -- the shape the ring buffer actually holds.
  local rows = {}
  for i = 1, 3000 do
    local ts = i / 16
    local alt = 64 + math.sin(i / 40) * 0.15
    local pitch = math.sin(i / 7) * 0.02
    local dPitch = math.cos(i / 7) * 0.02
    rows[i] = string.format("%.2f,H,N,64,%.2f,%.2f,%.3f,0,270,%.3f,0,0,0,0,0,%.3f,7,7,7,7,0,0",
      ts, alt, (alt - 64) * 5, pitch, dPitch, dPitch)
  end
  local encoded = Codec.encode(HDR, rows)
  local n = #encoded
  print(("codec: %d rows -> %d bytes (%.1f B/row)"):format(#rows, n, n / #rows))
  t.truthy(n <= 150000, "3000-row window must stay under 150 KB, got " .. n)
  local decoded = Codec.decode(encoded)
  t.eq(#decoded, 3000)
  for i = 1, #rows do
    if decoded[i] ~= rows[i] then
      error("row " .. i .. " diverged: " .. decoded[i])
    end
  end
end)