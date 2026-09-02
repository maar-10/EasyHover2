#!/usr/bin/env bash
# Render ONE real EasyHover 2 Basalt panel (from the render_panel RECIPES) to an SVG via CraftOS-PC.
# The recipe fixes the panel's monitor size; the id is all that matters. Usage:
#   bash tools/render/render.sh <panel-id>            e.g. bash tools/render/render.sh uical_settings
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PANEL="${1:-pfd}"
OUTDIR="${EH2_RENDER_OUT:-$ROOT/tools/render/out}"
mkdir -p "$OUTDIR"

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
for d in fcs ui nav beacon controller release tools; do
  [ -d "$ROOT/$d" ] && cp -r "$ROOT/$d" "$COMP/"
done

cat > "$COMP/startup.lua" <<LUA
package.path = "/?.lua;/?/init.lua;" .. package.path
_G.EH2_RENDER_PANEL = "$PANEL"
require("tools.render.render_panel")
LUA

timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true

# render_panel writes /render_out_<id>.txt (same as the batch path).
if [ ! -f "$COMP/render_out_${PANEL}.txt" ]; then echo "NO OUTPUT (render did not run for '$PANEL')"; exit 1; fi
cp "$COMP/render_out_${PANEL}.txt" "$OUTDIR/${PANEL}.txt"
if head -1 "$OUTDIR/${PANEL}.txt" | grep -q '^ERR '; then echo "BUILD ERROR: $(head -1 "$OUTDIR/${PANEL}.txt")"; exit 1; fi
node "$ROOT/tools/render/grid_to_svg.mjs" "$OUTDIR/${PANEL}.txt" "$OUTDIR/${PANEL}.svg" >/dev/null
echo "==> $OUTDIR/${PANEL}.svg"
