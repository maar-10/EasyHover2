#!/usr/bin/env node
// tools/build.mjs -- pre-deploy minify build. Reads every .lua under the minify dirs, runs
// luamin.minify on each, writes to dist/<same path>. HARD-FAILS the whole build if ANY file
// stops parsing (names it), and writes a fresh dist/ each run (deterministic + idempotent).
//
// dist/ is committed; in-game installs fetch dist/ over raw, so this NEVER runs in-game --
// it is a developer pre-commit step. Config lists are top-of-file so this vendors into the
// other suite repos (EasyKey, DriveByWire, ...) unchanged.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, rmSync, existsSync, realpathSync } from "node:fs";
import { join, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
let luamin;
try { luamin = require("luamin"); }
catch { console.error("luamin is not installed. Run: npm install"); process.exit(1); }

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..");

// --- config (top-of-file so this vendors cleanly into other repos) ---
export const MINIFY_DIRS = ["fcs", "ui", "launchers", "tools", "nav", "beacon", "controller"];
export const DIST = "dist";

function walkLua(absDir) {
  const out = [];
  for (const name of readdirSync(absDir)) {
    const abs = join(absDir, name);
    if (statSync(abs).isDirectory()) out.push(...walkLua(abs));
    else if (name.endsWith(".lua")) out.push(abs);
  }
  return out.sort();
}

// build(root) -> sorted array of repo-relative paths written under root/dist. Throws on parse fail.
// Two-phase: minify everything into memory FIRST (nothing touches disk yet); only once every
// file has parsed successfully do we wipe dist/ and flush the buffered output. This guarantees
// a mid-run parse failure writes nothing partial -- dist/ is left exactly as it was before the
// call. Buffered bytes are tiny (whole-repo Lua source, ~150KB) so an in-memory Map is fine; no
// temp files/dirs needed for a dev-only tool that never runs in-game.
export function build(root = REPO_ROOT) {
  const distAbs = join(root, DIST);
  const buffered = new Map(); // rel -> minified bytes
  for (const d of MINIFY_DIRS) {
    const dirAbs = join(root, d);
    if (!existsSync(dirAbs)) continue;
    for (const abs of walkLua(dirAbs)) {
      const rel = relative(root, abs).split(sep).join("/");
      const src = readFileSync(abs, "utf8");
      let min;
      try { min = luamin.minify(src); }
      catch (e) { throw new Error(`luamin failed to parse ${rel}: ${e.message}`); }
      buffered.set(rel, min);
    }
  }
  // All files parsed successfully -- safe to touch disk now.
  if (existsSync(distAbs)) rmSync(distAbs, { recursive: true, force: true }); // fresh each run
  for (const [rel, min] of buffered) {
    const outAbs = join(distAbs, rel);
    mkdirSync(dirname(outAbs), { recursive: true });
    writeFileSync(outAbs, min);
  }
  return [...buffered.keys()].sort();
}

// CLI entry (only when run directly, not when imported by the test).
const invoked = process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
if (invoked) {
  try { const w = build(); console.log(`built ${w.length} file(s) into ${DIST}/`); }
  catch (e) { console.error(e.message); process.exit(1); }
}
