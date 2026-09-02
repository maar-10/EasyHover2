#!/usr/bin/env bash
# Render EVERY EasyHover 2 panel in one CraftOS-PC boot, then generate an SVG + ASCII preview for each.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="$ROOT/tools/render/out"
mkdir -p "$OUTDIR"

IDS="pfd flight flight_engine flight_calfuel flight_params nav hub tuning mdb uical uical_settings senscal senssource dtc pfdrate waypointlist keypad_name keypad_num listpicker config ap"

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
for d in fcs ui nav beacon controller release tools; do [ -d "$ROOT/$d" ] && cp -r "$ROOT/$d" "$COMP/"; done
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_RENDER_PANEL = "all"
require("tools.render.render_panel")
LUA

timeout 120 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true

for id in $IDS; do
  src="$COMP/render_out_${id}.txt"
  if [ ! -f "$src" ]; then echo "!! $id: NO OUTPUT"; continue; fi
  cp "$src" "$OUTDIR/${id}.txt"
  if head -1 "$src" | grep -q '^ERR '; then
    echo "!! $id: BUILD ERROR -> $(head -1 "$src")"
    continue
  fi
  node "$ROOT/tools/render/grid_to_svg.mjs" "$OUTDIR/${id}.txt" "$OUTDIR/${id}.svg" >/dev/null 2>&1 \
    && echo "ok $id -> out/${id}.svg" || echo "!! $id: svg gen failed"
done
