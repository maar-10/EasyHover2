#!/usr/bin/env bash
# End-to-end test of easyhover2_suite.lua against a LOCALHOST MIRROR of the repo.
#
#   bash tests/run_suite_e2e.sh
#
# This is the test that actually proves the Suite: it really fetches, really stages, really
# commits, really repairs, and really extends configs. Serving the repo from a local static
# file server instead of GitHub keeps it fast, offline and independent of the repository's
# visibility.
#
# Needs: CraftOS-PC (console build), a static file server (python preferred), curl.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CRAFTOS="${CRAFTOS_BIN:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="$HERE/.craftos/suite_e2e"
DATA="$WORK/data"
C0="$DATA/computer/0"

# ---------- pick a static file server ----------
# Prefer `python -m http.server`; fall back to python3, then to a minimal static server if
# present. Probe each candidate and use the first one that actually exists on PATH.
SERVER_KIND=""
if command -v python >/dev/null 2>&1; then
  SERVER_KIND="python"
elif command -v python3 >/dev/null 2>&1; then
  SERVER_KIND="python3"
elif command -v busybox >/dev/null 2>&1; then
  SERVER_KIND="busybox"
elif command -v npx >/dev/null 2>&1; then
  SERVER_KIND="npx"
else
  echo "no static file server available (need python, python3, busybox httpd, or npx http-server)"
  exit 1
fi
echo "server backend: $SERVER_KIND"

start_server() {
  local port="$1"
  case "$SERVER_KIND" in
    python|python3)
      "$SERVER_KIND" -m http.server "$port" --directory "$ROOT" --bind 127.0.0.1 >/dev/null 2>&1 &
      ;;
    busybox)
      busybox httpd -f -p "127.0.0.1:$port" -h "$ROOT" >/dev/null 2>&1 &
      ;;
    npx)
      npx --yes http-server "$ROOT" -a 127.0.0.1 -p "$port" -c-1 --silent >/dev/null 2>&1 &
      ;;
  esac
  SERVER_PID=$!
}

# ---------- serve the repo ----------
# Pick a FREE port at runtime: a script piped into `head`/a here-string reader can get
# SIGPIPE'd, leaving a stray server bound to the old port and serving a since-deleted dir.
# Never pipe this script's stdout through something that closes early.
PORT="${EASYHOVER2_E2E_PORT:-8754}"
port_free() { ! (curl -fsS --max-time 1 "http://127.0.0.1:$1/" -o /dev/null 2>/dev/null); }
for _ in $(seq 1 20); do port_free "$PORT" && break; PORT=$((PORT + 1)); done

start_server "$PORT"
cleanup() { kill "$SERVER_PID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for _ in $(seq 1 40); do
  curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null 2>/dev/null && break
  sleep 0.25
done
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/manifest.lua" -o /dev/null 2>/dev/null \
  || { echo "could not serve the mirror on port $PORT"; exit 1; }
MIRROR="http://127.0.0.1:$PORT"
echo "mirror: $MIRROR"
echo ""

# ---------- lay out a bare computer ----------
lay_out_computer() {
  rm -rf "$WORK"
  mkdir -p "$C0" "$DATA/config"
  # CraftOS-PC blocks private ranges by default; allow localhost.
  printf '{ "http_enable": true, "http_whitelist": ["*"], "http_blacklist": [] }' \
    > "$DATA/config/global.json"
  cp "$ROOT/easyhover2_suite.lua" "$C0/easyhover2_suite.lua"
  printf '%s' "$MIRROR" > "$C0/easyhover2_suite_src.txt"
  # the probe compares the install record against the release it was served
  cp "$ROOT/manifest.lua" "$C0/mirror_manifest.lua"
}
lay_out_computer

# Phases that need a BARE computer rather than the aged one the chain has been building. A
# second role cannot be tested on top of the first: installing ui over fcs is a role CHANGE,
# which is a different operation from the fresh install a pilot actually performs. `switch`
# lays out its own bare computer and installs fcs itself before switching, so it too needs a
# clean start rather than the one earlier phases have been aging.
FRESH_PHASES=" ui switch nav beacon beaconcontrol "

FAILED=0
run_phase() {
  local phase="$1"
  [[ "$FRESH_PHASES" == *" $phase "* ]] && lay_out_computer
  printf '%s' "$phase" > "$C0/pc_phase.txt"
  cp "$ROOT/tests/suite_probe.lua" "$C0/e2e_probe.lua"
  rm -f "$C0/pc_result.txt"
  # --script, NOT /startup.lua: the Suite installs its own startup.lua, and overwriting it
  # would make the probe itself a modified release file -- which the Suite would then
  # correctly report as a corrupt install. That test artefact looks exactly like a real bug.
  timeout 180 "$CRAFTOS" --headless -d "$DATA" --script "$C0/e2e_probe.lua" >/dev/null 2>&1 || true
  if [[ -f "$C0/pc_result.txt" ]]; then
    cat "$C0/pc_result.txt"
    grep -q "FAIL" "$C0/pc_result.txt" && FAILED=$((FAILED + 1))
  else
    echo "=== $phase === NO RESULT (hung or crashed)"
    FAILED=$((FAILED + 1))
  fi
  echo ""
}

# Order matters: each phase builds on the computer the previous one left behind, which is
# exactly how a real install ages. Iterating on one phase is much faster than the whole chain:
#   EASYHOVER2_E2E_PHASES="install badconfig" bash tests/run_suite_e2e.sh
# `install` is a prerequisite for every later phase, so keep it first in any subset.
# `ui` and `switch` are last because they wipe the computer to a bare one.
ALL_PHASES="install current configkeep update repair badconfig detect protect check ui switch nav beacon beaconcontrol"
PHASES="${EASYHOVER2_E2E_PHASES:-$ALL_PHASES}"
[[ "$PHASES" != "$ALL_PHASES" ]] && echo "(limited to: $PHASES)" && echo ""

for phase in $PHASES; do
  run_phase "$phase"
done

if [[ $FAILED -gt 0 ]]; then
  echo "FAILED: $FAILED phase(s)"
  exit 1
fi
echo "PASS: suite e2e green ($MIRROR)"
