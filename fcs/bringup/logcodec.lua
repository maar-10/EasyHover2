-- Cheap flight-log encoding: changed-fields delta over slim CSV rows. Pure Lua, no CC deps.
--
-- Wire format (line-oriented, decodeable by tools/decode_flightlog.lua):
--   header     -> verbatim on the first line (may be nil/empty)
--   first row  -> verbatim CSV
--   later rows -> ","-joined `i:value` pairs for the cells that CHANGED vs the previous row
--                 (i = 1-based column index; unchanged cells inherit)
--   "="        -> row identical to the previous row
-- `#` lines (summary/legend) and blank lines pass through untouched.
-- Values must never contain "," ":" or "=" (true for every emitter in this codebase).
local M = {}

local function split(row)
  local cells, start = {}, 1
  while true do
    local pos = row:find(",", start, true)
    if pos then
      cells[#cells+1] = row:sub(start, pos - 1)
      start = pos + 1
    else
      cells[#cells+1] = row:sub(start)
      break
    end
  end
  return cells
end

-- encode(header, rows): rows is an array of equal-column CSV strings (instrument.formatRow
-- output); header is the column-name line, REQUIRED -- decode() always treats the first
-- non-# line as the header, so a headerless stream could not round-trip.
function M.encode(header, rows)
  if not header or header == "" then error("logcodec.encode requires a header line") end
  if #rows == 0 then return header end
  local out = {}
  if header and header ~= "" then out[#out+1] = header end
  local prev = rows[1]
  out[#out+1] = prev
  for i = 2, #rows do
    local cur = rows[i]
    if cur == prev then
      out[#out+1] = "="
    else
      local a, b = split(prev), split(cur)
      local delta = {}
      for c = 1, #b do
        if a[c] ~= b[c] then delta[#delta+1] = c .. ":" .. b[c] end
      end
      out[#out+1] = table.concat(delta, ",")
    end
    prev = cur
  end
  return table.concat(out, "\n")
end

-- decode(text): replays the wire format back to slim CSV rows. Skips `#` and blank lines and
-- the column header. Returns rows (full CSV strings), header (or nil).
function M.decode(text)
  local rows, header, cols = {}, nil, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line == "=" then
        -- Only meaningful after at least one row; a corrupt/truncated file may open with one.
        if cols then rows[#rows+1] = table.concat(cols, ",") end
      elseif cols == nil then
        -- header, then the first verbatim row -- in that order, whatever they contain
        if header == nil then
          header = line
        else
          cols = split(line)
          rows[#rows+1] = line
        end
      else
        local cur = {}
        for c = 1, #cols do cur[c] = cols[c] end
        for pair in line:gmatch("[^,]+") do
          local idx, val = pair:match("^(%d+):(.*)$")
          cur[tonumber(idx)] = val
        end
        cols = cur
        rows[#rows+1] = table.concat(cur, ",")
      end
    end
  end
  return rows, header
end

return M