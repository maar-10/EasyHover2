#!/usr/bin/env bash
# ACCEPTANCE GATE: run the full suite against the MINIFIED dist/ tree, proving luamin preserved
# behaviour. Mirror of run_headless.sh; only the app role dirs are sourced from dist/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== manifest sync check =="
if ! bash "$ROOT/tools/run_gen.sh" --check; then
  echo "manifest(s) OUT OF SYNC -- run: node tools/build.mjs && bash tools/run_gen.sh"
  exit 1
fi
echo ""

if [ ! -d "$ROOT/dist" ]; then echo "no dist/ -- run: node tools/build.mjs"; exit 1; fi

DATA="$(mktemp -d)"
COMP="$DATA/computer/0"
mkdir -p "$COMP"
# app role dirs: MINIFIED, from dist/
for d in fcs tools ui launchers nav beacon controller; do [ -d "$ROOT/dist/$d" ] && cp -r "$ROOT/dist/$d" "$COMP/"; done
# not minified: basalt, the suite bootstrap, the committed manifests
[ -d "$ROOT/release" ] && cp -r "$ROOT/release" "$COMP/"
[ -f "$ROOT/easyhover2_suite.lua" ] && cp "$ROOT/easyhover2_suite.lua" "$COMP/"
[ -f "$ROOT/easyhover2_suitex.lua" ] && cp "$ROOT/easyhover2_suitex.lua" "$COMP/"
[ -f "$ROOT/manifest.lua" ] && cp "$ROOT/manifest.lua" "$COMP/"
[ -f "$ROOT/manifest-dev.lua" ] && cp "$ROOT/manifest-dev.lua" "$COMP/"
# tests stay as source and require the (now minified) modules
cp -r "$ROOT/tests" "$COMP/"
cat > "$COMP/startup.lua" <<'LUA'
package.path = "/?.lua;/?/init.lua;" .. package.path
local suites = { "tests.test_keymap", "tests.test_input_events", "tests.test_hwconfig", "tests.test_smoke", "tests.test_pid", "tests.test_pwm", "tests.test_sigma_delta",
                 "tests.test_mixer", "tests.test_sim", "tests.test_integration", "tests.test_angle", "tests.test_yaw_mixer", "tests.test_mixer_yawrear",
                 "tests.test_sim_yaw", "tests.test_heading", "tests.test_surge_mixer", "tests.test_sim_horizontal", "tests.test_translate", "tests.test_leash", "tests.test_envelope", "tests.test_fueltable", "tests.test_oscillation", "tests.test_backend", "tests.test_backend_dropin", "tests.test_probe", "tests.test_calibration", "tests.test_calibrate", "tests.test_tuning", "tests.test_profile", "tests.test_instrument", "tests.test_loop", "tests.test_hover_test", "tests.test_scheme_heave", "tests.test_level", "tests.test_pilot", "tests.test_pilot_drift", "tests.test_protocol", "tests.test_telemetry", "tests.test_command", "tests.test_health", "tests.test_modem_mock", "tests.test_ui_config", "tests.test_ui_toolkit", "tests.test_fuelrate", "tests.test_fedtrack", "tests.test_ui_engine", "tests.test_relaywriter", "tests.test_ui_fuel", "tests.test_ui_detect", "tests.test_ui_panels", "tests.test_ui_monitors", "tests.test_flight", "tests.test_suite", "tests.test_suitex", "tests.test_suite_selfupdate", "tests.test_tuningdefaults", "tests.test_cfgspec", "tests.test_binddevices", "tests.test_cfgsync", "tests.test_fcs2disk", "tests.test_bootloader", "tests.test_bootloaderui", "tests.test_cfgserver", "tests.test_cadence", "tests.test_nav", "tests.test_nav_geometry", "tests.test_trilaterate", "tests.test_nav_heading", "tests.test_nav_fix", "tests.test_nav_gpsproto", "tests.test_nav_receiver", "tests.test_beacon_config", "tests.test_beacon_selfcheck", "tests.test_beacon_runtime", "tests.test_beacon_console", "tests.test_nav_runtime", "tests.test_nav_config", "tests.test_nav_ui", "tests.test_basalt_app", "tests.test_fcslink", "tests.test_page_emc", "tests.test_page_fcs", "tests.test_page_ap", "tests.test_page_nav", "tests.test_page_config", "tests.test_bitconfig_hub", "tests.test_bitconfig_tuning", "tests.test_bitconfig_mdb", "tests.test_bitconfig_uical", "tests.test_bitconfig_senscal", "tests.test_bitconfig_dtc", "tests.test_bitconfig_fcssync", "tests.test_cockpit_assembly", "tests.test_switchbtn", "tests.test_region", "tests.test_picker", "tests.test_listpicker", "tests.test_keypad", "tests.test_comauto", "tests.test_region_emc", "tests.test_region_fcs", "tests.test_params", "tests.test_page_flight", "tests.test_fsx", "tests.test_manifest_channels", "tests.test_modes_golden", "tests.test_tuning_modes", "tests.test_scheme_manual", "tests.test_scheme_drone", "tests.test_scheme_cruise", "tests.test_modes_registry", "tests.test_modes_master", "tests.test_loop_setactive", "tests.test_loop_trim", "tests.test_buildloop_modes", "tests.test_keymap_tilt", "tests.test_pilot_modes", "tests.test_flight_modes", "tests.test_flight_master", "tests.test_ui_flightmode_state", "tests.test_panels_fcs_modes", "tests.test_region_fcs_modes", "tests.test_configkit", "tests.test_btnfit", "tests.test_beacon_update", "tests.test_beacon_command", "tests.test_beaconupdate", "tests.test_manifest_tools", "tests.test_instr_horizon", "tests.test_instr_tape", "tests.test_instr_attitude", "tests.test_instr_readout", "tests.test_page_pfd", "tests.test_glyph", "tests.test_instr_sensread", "tests.test_senssource", "tests.test_nav_groundspeed", "tests.test_bitconfig_senssource", "tests.test_splitconfig", "tests.test_bitconfig_pfd", "tests.test_fcs_status", "tests.test_log_buffer", "tests.test_uilog", "tests.test_waypoints", "tests.test_wptserver", "tests.test_waypointlist", "tests.test_wptclient", "tests.test_navtarget", "tests.test_wptdisk", "tests.test_routefollow", "tests.test_comms_hygiene_e2e", "tests.test_fault", "tests.test_gfxpicker", "tests.test_control_terms", "tests.test_scheme_terms", "tests.test_loop_diag", "tests.test_cut", "tests.test_controller_config", "tests.test_controller_runtime", "tests.test_controller_app" }
local t = require("tests.framework")
local loadErrs = {}
for _, s in ipairs(suites) do
  local ok, err = pcall(require, s)
  if not ok then loadErrs[#loadErrs+1] = s .. ": " .. tostring(err) end
end
local passed, summary = t.run()
local ok = passed and #loadErrs == 0
local extra = ""
if #loadErrs > 0 then
  extra = "\nSUITE LOAD FAILURES (" .. #loadErrs .. "):\n"
  for _, e in ipairs(loadErrs) do extra = extra .. "  " .. e .. "\n" end
end
local f = fs.open("/results.txt", "w"); f.write((ok and "OK\n" or "FAILED\n") .. summary .. extra); f.close()
os.shutdown()
LUA
timeout 60 "/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe" --headless -d "$DATA" >/dev/null 2>&1 || true
if [ ! -f "$COMP/results.txt" ]; then echo "NO RESULTS (harness did not run)"; exit 1; fi
cat "$COMP/results.txt"
grep -q '^OK' "$COMP/results.txt"
