#!/usr/bin/env node

/**
 * Generate or verify the committed play runtime.
 *
 * `pngine play` embeds `src/cli/play_runtime.min.mjs` with `@embedFile` and
 * hands it to the browser as a Blob module. The asset is the byte-exact
 * production `dev.mjs` bundle, so ordinary CLI builds need neither Node nor
 * esbuild — only the committed copy.
 *
 * Usage:
 *   node scripts/gen-play-runtime.mjs                 # rebuild dev.mjs and rewrite the asset
 *   node scripts/gen-play-runtime.mjs --check         # rebuild dev.mjs and verify the asset
 *   node scripts/gen-play-runtime.mjs --dist <dir>    # rebuild dev.mjs into <dir>, touch nothing else
 *
 * `--dist <dir>` redirects the whole bundle into an isolated directory and
 * deliberately does not read or write the committed asset. tests/npm/
 * play-runtime.test.js uses it so its two fresh builds never race the shared
 * `npm/pngine/dist/` that other parallel test files read, and never repair a
 * stale committed asset before comparing against it.
 *
 * Run this LOCALLY (esbuild lives in node_modules); never through obs. The
 * Zig drift gate deliberately has no esbuild dependency: it byte-compares
 * `npm/pngine/dist/dev.mjs` against the committed asset, so refresh dist with
 * this script before running `zig build drift`.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BUNDLE = path.join(ROOT, "npm/pngine/scripts/bundle.cjs");
const DEFAULT_DIST = path.join(ROOT, "npm/pngine/dist");
const COMMITTED = path.join(ROOT, "src/cli/play_runtime.min.mjs");

const args = process.argv.slice(2);
const CHECK = args.includes("--check");
const distArg = args.indexOf("--dist");
let dist = DEFAULT_DIST;
if (distArg !== -1) {
  const value = args[distArg + 1];
  if (!value || value.startsWith("--")) {
    console.error("play-runtime: --dist requires a directory argument");
    process.exit(2);
  }
  dist = path.resolve(value);
}
const REDIRECTED = distArg !== -1;
const FRESH = path.join(dist, "dev.mjs");

const env = { ...process.env };
if (REDIRECTED) env.PNGINE_BUNDLE_DIST_DIR = dist;
execFileSync(process.execPath, [BUNDLE], { cwd: ROOT, stdio: "inherit", env });

if (!existsSync(FRESH)) {
  console.error(`play-runtime: ${path.relative(ROOT, FRESH)} was not produced by bundle.cjs`);
  process.exit(1);
}
const fresh = readFileSync(FRESH);

if (CHECK) {
  const committed = existsSync(COMMITTED) ? readFileSync(COMMITTED) : null;
  if (committed === null || !committed.equals(fresh)) {
    console.error("play-runtime: stale; run node scripts/gen-play-runtime.mjs");
    process.exit(1);
  }
  console.log(`play-runtime: current (${fresh.length} B)`);
  process.exit(0);
}

if (REDIRECTED) {
  console.log(
    `play-runtime: built ${path.relative(ROOT, FRESH)} (${fresh.length} B); committed asset untouched`,
  );
  process.exit(0);
}

writeFileSync(COMMITTED, fresh);
console.log(`play-runtime: wrote ${path.relative(ROOT, COMMITTED)} (${fresh.length} B)`);
