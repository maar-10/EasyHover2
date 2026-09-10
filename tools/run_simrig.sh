#!/usr/bin/env bash
# Run tools/simrig_run.lua headless in CraftOS-PC; print the report.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRAFTOS="/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe"
WORK="$ROOT/tests/.craftos/simrig"; DATA="$WORK/data"; C0="$DATA/computer/0"
rm -rf "$WORK"; mkdir -p "$C0"
for d in fcs tools ui launchers nav beacon controller release; do
  [ -d "$ROOT/$d" ] && cp -r "$ROOT/$d" "$C0"/
done
cat > "$C0/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local ok, res = pcall(function() return require("tools.simrig_run").report() end)
local f = fs.open("/results.txt", "w")
if ok then f.write(res) else f.write("ERROR\n" .. tostring(res)) end
f.close()
os.shutdown()
LUA
timeout 90 "$CRAFTOS" --headless -d "$DATA" >/dev/null 2>&1 || true
if [ -f "$C0/results.txt" ]; then cat "$C0/results.txt"; else echo "NO RESULT (harness did not run)"; exit 1; fi
