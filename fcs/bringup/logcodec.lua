-- Cheap flight-log encoding: changed-fields delta over slim CSV rows. Pure Lua, no CC deps.
--
-- Wire format (line-oriented, decodeable by tools/decode_flightlog.lua):
--   header     -> verbatim on the first line (required; decode() treats the first non-# line
--                 as the header, so a headerless stream could not round-trip)
--   first row  -> verbatim CSV
--   later rows -> ","-joined `i:value` pairs for the cells that CHANGED vs the previous row
--                 (i = 1-based column index; unchanged cells inherit)
--   "="        -> row identical to the previous row
-- `#` lines (summary/legend) and blank lines pass through untouched.
-- Values must never contain "," ":" or "=" (instrument.formatRow sanitizes its strings).
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

-- delta line for one row transition; both rows are equal-column CSV strings
local function deltaLine(prevRow, curRow)
  local a, b = split(prevRow), split(curRow)
  local delta = {}
  for c = 1, #b do
    if a[c] ~= b[c] then delta[#delta+1] = c .. ":" .. b[c] end
  end
  return table.concat(delta, ",")
end

-- encode(header, rows): rows is an array of equal-column CSV strings (instrument.formatRow
-- output); header is the column-name line, REQUIRED -- decode() always treats the first
-- non-# line as the header, so a headerless stream could not round-trip.
function M.encode(header, rows)
  if not header or header == "" then error("logcodec.encode requires a header line") end
  if #rows == 0 then return header end
  local out = { header, rows[1] }
  local prev = rows[1]
  for i = 2, #rows do
    local cur = rows[i]
    if cur == prev then
      out[#out+1] = "="
    else
      out[#out+1] = deltaLine(prev, cur)
    end
    prev = cur
  end
  return table.concat(out, "\n")
end

-- Streaming encoder: same wire format, splittable at row boundaries. encoder(header) makes
-- the state; encodeChunk(state, rows) -> text, newState emits the next chunk. Continuation
-- chunks carry their own LEADING newline, so raw server-side concatenation of chunk bodies
-- (body || chunk, no separator) is byte-identical to encode(header, allRows) and decode()
-- needs no chunk awareness. encodeChunk never mutates the input state (newState =
-- { header, prev = <row> string }): the caller swaps it in only after an upload succeeds, so
-- a failed append re-encodes the identical chunk on retry.
function M.encoder(header)
  if not header or header == "" then error("logcodec.encoder requires a header line") end
  return { header = header, prev = nil }
end

function M.encodeChunk(state, rows)
  if #rows == 0 then return "", state end
  local out, from, prefix = {}, 1, ""
  if state.prev == nil then
    out[#out+1] = state.header
    out[#out+1] = rows[1]
    from = 2
  else
    prefix = "\n"               -- continuation chunks carry their own leading separator
  end
  local prev = state.prev or rows[1]
  for i = from, #rows do
    local cur = rows[i]
    if cur == prev then
      out[#out+1] = "="
    else
      out[#out+1] = deltaLine(prev, cur)
    end
    prev = cur
  end
  return prefix .. table.concat(out, "\n"), { header = state.header, prev = rows[#rows] }
end

-- compose(header, rows, summary, plain): build a complete log file body. Encoded mode is the
-- wire format + the summary block; plain mode (the escape hatch when compression misbehaves,
-- settings eh2_log_plain) is readable slim CSV with no codec lines at all.
function M.compose(plain, header, rows, summary)
  if not header or header == "" then error("logcodec.compose requires a header line") end
  if plain then
    return header .. "\n" .. table.concat(rows, "\n") .. (#rows > 0 and "\n" or "") .. "\n" .. summary .. "\n"
  end
  return M.encode(header, rows) .. "\n\n" .. summary .. "\n"
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