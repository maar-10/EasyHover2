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
  -- Production shape: full instrument schema (real header + column count, every duty column),
  -- slow altitude bob, tiny attitude jitter, static trimmed duties -- what the ring buffer holds.
  local I = require("fcs.bringup.instrument")
  local frame = require("fcs.frame")
  local ids = {}
  for _, id in ipairs(frame.LIFT)    do ids[#ids+1] = id end
  for _, id in ipairs(frame.LATERAL) do ids[#ids+1] = id end
  for _, id in ipairs(frame.MAIN)    do ids[#ids+1] = id end
  for _, id in ipairs(frame.FRONTAL) do ids[#ids+1] = id end
  local duties = {}
  for _, id in ipairs(ids) do duties[id] = 7 end
  local rows = {}
  for i = 1, 3000 do
    local alt = 64 + math.sin(i / 40) * 0.15
    local pitch = math.sin(i / 7) * 0.02
    rows[i] = I.formatRow({
      t = i / 16, dt = 1 / 16, phase = "HOLD", mode = "NORMAL", onGround = false,
      sp_alt = 64, alt = alt, vSpeed = math.cos(i / 40) * 0.02,
      pitch = pitch, roll = 0, heading = 270, yawRate = 0,
      swayVel = 0, surgeVel = 0, swayPos = 0.1, surgePos = -0.1, heave = 0.5,
      dPitch = math.cos(i / 7) * 0.02, dRoll = 0, dYaw = 0, dSway = 0, dSurge = 0,
      sp_pitch = 0, sp_roll = 0, sp_hdg = 270, sp_sway = 0.1, sp_surge = -0.1,
      terms = {
        alt   = { P = 1.0, I = 0.1,  D = 0.01 },
        pitch = { P = 0.6, I = 0.02, D = 0.003 },
        roll  = { P = 0.2, I = 0.01, D = 0.001 },
        yaw   = { P = 0.5, I = 0.05, D = 0.005 },
        sway  = { P = 0.4, I = 0.04, D = 0.004 },
        surge = { P = 0.3, I = 0.03, D = 0.002 },
      },
      sat = { heave = false, pitch = false, roll = false, yaw = false, sway = false, surge = false },
      heaveBanded = false, ff_pitch = 0, master = "CPL", noFuel = false, duties = duties,
    })
  end
  local hdr = I.header()
  local ncols = select(2, hdr:gsub(",", ",")) + 1
  local encoded = Codec.encode(hdr, rows)
  local n = #encoded
  print(("codec: %d rows x %d cols -> %d bytes (%.1f B/row)"):format(#rows, ncols, n, n / #rows))
  t.truthy(n <= 150000, "3000-row window must stay under 150 KB, got " .. n)
  local decoded, outHdr = Codec.decode(encoded)
  t.eq(outHdr, hdr)
  t.eq(#decoded, 3000)
  for i = 1, #rows do
    if decoded[i] ~= rows[i] then
      error("row " .. i .. " diverged: " .. decoded[i])
    end
  end
end)