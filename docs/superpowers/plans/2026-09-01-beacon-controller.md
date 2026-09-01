# GPS Beacon Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new advanced-PC role that remotely monitors and controls the GPS beacons over the beacons' existing token-guarded command channel.

**Architecture:** Extend the proven `beacon/update.lua` protocol with an op-tagged command kind + a status-reply kind (P1); the beacon acts on token-valid commands (P2); a controller runtime keeps a persisted roster + sends commands + collects status (P3); a new role ships it (P4) with a Basalt UI (P5); the standalone updater folds in (P6).

**Tech Stack:** CC:Tweaked Lua 5.1, Basalt 2.0 (full build), the EH2 test framework (`tests/framework`), CraftOS-PC headless test harness.

**Design doc:** `docs/superpowers/specs/2026-09-01-beacon-controller-design.md`.

## Global Constraints

- **Lua 5.1 only** — no `//`, no `goto`, no bitops beyond CC's `bit32`.
- **Fail-closed** — a beacon acts on a command ONLY when the token is valid AND equal; anything else is a no-op (`beacon/update.lua` `accepts` discipline).
- **Comms hygiene** — the controller is passive by default; active polling fires ONLY while the DIAG page is open, rate-gated, NO-OP closed. Beacons never broadcast faster than `config.MIN_INTERVAL_MS` (50 ms / 20 Hz).
- **No remote `set channel`** — excluded by design (orphan risk).
- **TDD** — every change: write failing test → watch it fail → minimal code → pass → commit.
- **Gates each phase:** `bash tests/run_headless.sh` (src) + `bash tests/run_headless_dist.sh` (dist) + `bash tests/run_suite_e2e.sh` (e2e) + manifest sync, all green. Regenerate dist+manifests with `node tools/build.mjs && bash tools/run_gen.sh` before running gates.

---

## File structure

**P1 (this plan):**
- Modify: `beacon/update.lua` — add the op-tagged command kind, the status-reply kind, `cmd()`/`status()` constructors, extended `decode`, and `acceptsCmd()`. One file: it is the shared codec both the beacons and the controller import.
- Test: `tests/test_beacon_update.lua` — extend with the new-kind cases.

**P2–P6 (planned in detail when reached):**
- P2: `beacon/app.lua` (command dispatch in the event loop) + `beacon/runtime.lua` (apply enable/disable/verify/setPos/setInterval; build the query status payload).
- P3: `controller/runtime.lua` (roster registry + sender + collector), `controller/config.lua`.
- P4: `launchers/beaconcontrol.lua`, `tools/gen_manifest.lua` ROLES entry, `controller/config.lua` file.
- P5: `controller/app.lua` + Basalt pages (roster / detail / DIAG), rendered via `tools/render`.
- P6: retire `launchers/beaconupdate.lua` + `tools/beaconupdate.lua` into the controller's UPDATE action.

---

## Phase P1 — extend the beacon command protocol

`beacon/update.lua` today: `CMD_KIND="eh2_beacon_update"`, `ACK_KIND="eh2_beacon_update_ack"`, `validToken`, `command`, `ack`, `encode`, `decode` (returns only those two kinds), `accepts` (both tokens valid+equal). The existing `eh2_beacon_update` command stays untouched (old + new beacons keep understanding reinstall). We ADD a generalized op-tagged command and a status reply.

### Task 1: Op-tagged command kind + constructor + ops set

**Files:**
- Modify: `beacon/update.lua`
- Test: `tests/test_beacon_update.lua`

**Interfaces:**
- Produces: `M.CMD2_KIND = "eh2_beacon_cmd"`; `M.OPS` (set of `enable`/`disable`/`verify`/`query`/`setPos`/`setInterval`/`reboot`); `M.cmd(op, token, args) -> {k=CMD2_KIND, op, token, args}`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_beacon_update.lua`:

```lua
t.test("cmd builds an op-tagged, token-carrying command frame", function()
  local U = require("beacon.update")
  local f = U.cmd("enable", "tok")
  t.eq(f.k, U.CMD2_KIND); t.eq(f.op, "enable"); t.eq(f.token, "tok")
  local g = U.cmd("setInterval", "tok", { intervalMs = 3000 })
  t.eq(g.args.intervalMs, 3000)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh 2>&1 | grep -Ei "op-tagged|FAIL|passed"`
Expected: FAIL (attempt to call `U.cmd`, a nil value).

- [ ] **Step 3: Write minimal implementation** — in `beacon/update.lua`, after the existing `M.CMD_KIND`/`M.ACK_KIND` lines:

```lua
M.CMD2_KIND = "eh2_beacon_cmd"       -- generalized op-tagged remote command
M.STATUS_KIND = "eh2_beacon_status"  -- query reply (Task 3)
M.OPS = { enable = true, disable = true, verify = true, query = true,
          setPos = true, setInterval = true, reboot = true }

function M.cmd(op, token, args) return { k = M.CMD2_KIND, op = op, token = token, args = args } end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | grep -Ei "op-tagged|passed|failed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add beacon/update.lua dist/beacon/update.lua tests/test_beacon_update.lua manifest.lua manifest-dev.lua
git commit -m "feat(beacon): op-tagged remote command frame (protocol P1.1)"
```

### Task 2: Extend `decode` for the new kinds + status constructor

**Files:**
- Modify: `beacon/update.lua`
- Test: `tests/test_beacon_update.lua`

**Interfaces:**
- Produces: `M.status(id, payload) -> {k=STATUS_KIND, id, ...payload}`; `decode` now also returns `CMD2_KIND` and `STATUS_KIND` frames.

- [ ] **Step 1: Write the failing test**

```lua
t.test("decode round-trips cmd + status; rejects GPS + unknown kinds", function()
  local U = require("beacon.update")
  local cmd = U.decode(U.encode(U.cmd("query", "tok")))
  t.truthy(cmd and cmd.op == "query")
  local st = U.decode(U.encode(U.status("beacon-70", { enabled = false, seq = 5 })))
  t.truthy(st and st.id == "beacon-70" and st.enabled == false and st.seq == 5)
  t.eq(U.decode('{"x":1,"y":2,"z":3}'), nil)   -- a GPS frame is not a command
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh 2>&1 | grep -Ei "round-trips cmd|FAIL"`
Expected: FAIL (`U.status` nil; `decode` returns nil for the CMD2 frame).

- [ ] **Step 3: Write minimal implementation** — add `M.status`, and extend `decode`'s kind check:

```lua
function M.status(id, payload)
  local f = { k = M.STATUS_KIND, id = id }
  for k, v in pairs(payload or {}) do f[k] = v end
  return f
end
```

In `M.decode`, change the accepted-kinds line to:

```lua
  if f.k == M.CMD_KIND or f.k == M.ACK_KIND or f.k == M.CMD2_KIND or f.k == M.STATUS_KIND then return f end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | grep -Ei "round-trips cmd|passed|failed"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add beacon/update.lua dist/beacon/update.lua tests/test_beacon_update.lua manifest.lua manifest-dev.lua
git commit -m "feat(beacon): decode + status frame for the command protocol (P1.2)"
```

### Task 3: `acceptsCmd` — the fail-closed gate for op-tagged commands

**Files:**
- Modify: `beacon/update.lua`
- Test: `tests/test_beacon_update.lua`

**Interfaces:**
- Produces: `M.acceptsCmd(frame, cfgToken) -> boolean` (true iff frame is a CMD2 of a known op with a valid token equal to cfgToken).

- [ ] **Step 1: Write the failing test**

```lua
t.test("acceptsCmd is fail-closed: known op + matching valid token only", function()
  local U = require("beacon.update")
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), "tok"), true)
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), "other"), false)   -- token mismatch
  t.eq(U.acceptsCmd(U.cmd("enable", ""), "tok"), false)        -- blank sender token
  t.eq(U.acceptsCmd(U.cmd("enable", "tok"), ""), false)        -- unprovisioned beacon
  t.eq(U.acceptsCmd(U.cmd("nuke", "tok"), "tok"), false)       -- unknown op
  t.eq(U.acceptsCmd({ k = U.CMD_KIND, token = "tok" }, "tok"), false)  -- wrong kind (that's the update cmd)
  t.eq(U.acceptsCmd(nil, "tok"), false)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run_headless.sh 2>&1 | grep -Ei "acceptsCmd|FAIL"`
Expected: FAIL (`U.acceptsCmd` nil).

- [ ] **Step 3: Write minimal implementation**

```lua
function M.acceptsCmd(frame, cfgToken)
  if type(frame) ~= "table" or frame.k ~= M.CMD2_KIND then return false end
  if not M.OPS[frame.op] then return false end
  if not M.validToken(cfgToken) then return false end
  if not M.validToken(frame.token) then return false end
  return frame.token == cfgToken
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node tools/build.mjs && bash tools/run_gen.sh && bash tests/run_headless.sh 2>&1 | grep -Ei "acceptsCmd|passed|failed"`
Expected: PASS.

- [ ] **Step 5: Run the full gate set**

Run: `bash tests/run_headless.sh 2>&1 | tail -2 && bash tests/run_headless_dist.sh 2>&1 | grep -Ei "passed|failed" && bash tests/run_suite_e2e.sh 2>&1 | tail -1`
Expected: src green + IN SYNC, dist green, e2e PASS.

- [ ] **Step 6: Commit**

```bash
git add beacon/update.lua dist/beacon/update.lua tests/test_beacon_update.lua manifest.lua manifest-dev.lua
git commit -m "feat(beacon): fail-closed acceptsCmd gate for remote commands (P1.3)"
```

**P1 deliverable:** the shared codec now speaks the full remote-command + status protocol, fail-closed, with the reinstall command untouched. Nothing consumes it yet — P2 wires the beacon to act on it.

---

## Roadmap — P2..P6 (planned in detail next, each its own executable phase)

- **P2 — beacon handlers.** `beacon/app.lua` event loop: on a `modem_message` that `acceptsCmd`, dispatch by `op` — `enable`/`disable` set + `save()` config; `setInterval` clamps via `config.clampInterval` + save; `setPos` validates + save; `verify` broadcasts once; `reboot` reboots; `query` transmits `Update.status(id, payload)` built from `runtime` (`enabled`, `pos`, `intervalMs`, `selfCheck`, `constellation`/`selfQuality`, `seq`). Tests: each op's effect + a bad-token no-op. Deliverable: beacons controllable remotely (deployable via existing update).
- **P3 — controller core.** Pure `controller/runtime.lua`: persisted roster registry (modeled on the UI monitor registry — auto-populate from broadcasts + query replies, friendly names, expected-position pin, manual remove, SILENT/OFFLINE/DISABLED classification), a command sender (token-guarded), a status collector. TDD headless.
- **P4 — controller role.** `launchers/beaconcontrol.lua`; `gen_manifest.lua` ROLES entry with its own require()-closure (NO flight/FCS code, like nav/beacon); `controller/config.lua`. Tests: closure/manifest assertions.
- **P5 — Basalt UI.** `controller/app.lua` + roster/detail/DIAG pages; design via the `basalt-render` loop (render → view → iterate). DIAG polling only while open, rate-gated, indicator.
- **P6 — fold updater.** Route UPDATE through the controller; retire `launchers/beaconupdate.lua` + `tools/beaconupdate.lua`.

Each phase gets its own bite-sized plan (same discipline as P1) at the time we execute it, so the beacon-side design (P2) is locked before the controller UI (P5) is drawn.

---

## Self-review

- **Spec coverage:** P1 implements design §3.4 (protocol extension) + the wire half of §3.5 (status frame). §3.1–3.3, §3.5-consumer, §4 map to P2–P6 (roadmap). No P1 gap.
- **Placeholder scan:** P1 tasks carry real Lua + real test code + exact run commands. P2–P6 are scoped roadmap, not placeholder tasks — each is a future plan.
- **Type consistency:** `CMD2_KIND`/`STATUS_KIND`/`OPS`/`cmd`/`status`/`acceptsCmd` names are used identically across Tasks 1–3 and the P2 roadmap.
