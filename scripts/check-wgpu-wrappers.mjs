#!/usr/bin/env node
/**
 * Every wgpu reference goes through `src/gpu/wgpu_c.zig`. Check it.
 *
 * The refcount ledger in that file (`lifetimes`) is what LEAK-01, LEAK-02 and
 * LEAK-04 are all gated on: a per-kind acquire/release count, asserted flat
 * across frames and across animation lifecycles. Its correctness rests on one
 * claim, written in a comment at the top of the file — that the wrappers are
 * the ONLY route from the engine to wgpu, so no call site can take a reference
 * the counters never see.
 *
 * The claim was false when it was written. Four `wgpuInstanceCreateSurface`
 * calls in `native_api.zig` went straight to C, the comment waved them off as
 * "not refcount traffic" (a surface is refcounted like everything else), and
 * the surface leak that follows from that was invisible to every balance test
 * in the repo for as long as the surface path existed. A comment asserting an
 * invariant is not an invariant; this is the check that makes it one.
 *
 * ## The rule
 *
 * Outside `wgpu_c.zig`, a call to a raw `c.wgpu*` function is an error unless
 * it is on the allowlist below — which holds only calls that take and give back
 * NO reference (capability queries). Anything else must be wrapped, so that
 * acquisitions and releases pass through `acquired()` / `releasing()`.
 *
 * Adding a genuinely reference-free call to the allowlist is a one-line, fully
 * deliberate act. That is the point: the decision gets made, rather than made
 * by default.
 *
 * Usage: node scripts/check-wgpu-wrappers.mjs
 * Exit: 0 clean · 1 an unwrapped call site, or the scan is blind
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** The wrapper file itself — where raw C calls are the whole job. */
const WRAPPER = "src/gpu/wgpu_c.zig";

const ROOTS = ["src", "tests", "tools"];

/**
 * Raw calls allowed outside the wrapper: they neither acquire nor release a
 * reference, so the ledger has nothing to say about them. Keep this list short
 * and keep the reason attached.
 */
const ALLOWED = new Map([
  ["wgpuDeviceGetLimits", "capability query; fills a caller-owned struct"],
  ["wgpuAdapterHasFeature", "capability query; returns a bool"],
]);

/**
 * Calls to `c.wgpuFoo(` / `wgpu.c.wgpuFoo(` in `source`, minus the allowlist.
 * Returns [{ name, line }].
 *
 * Line comments are stripped first — the balance test names
 * `c.wgpuInstanceCreateSurface` in a comment explaining why it does NOT call it,
 * and a gate that cannot tell prose from code gets disabled within the week.
 */
export function scanSource(source) {
  const hits = [];
  const lines = source.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const code = lines[i].replace(/\/\/.*$/, "");
    for (const m of code.matchAll(/\bc\.(wgpu[A-Za-z0-9_]*)\s*\(/g)) {
      if (ALLOWED.has(m[1])) continue;
      hits.push({ name: m[1], line: i + 1 });
    }
  }
  return hits;
}

function zigFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir).sort()) {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...zigFiles(full));
    else if (entry.endsWith(".zig")) out.push(full);
  }
  return out;
}

let failed = false;
const fail = (msg) => {
  console.error(`✗ ${msg}`);
  failed = true;
};

// Fail-probe, every run: a scanner nobody has watched find something is a
// decoration (CONTRIBUTING pitfall 30).
if (scanSource("    const s = c.wgpuInstanceCreateSurface(inst, &desc);\n").length !== 1) {
  fail("the scan cannot see an unwrapped call it was handed — gate is blind");
}
if (scanSource("    // never call c.wgpuSurfaceRelease(s) from here\n").length !== 0) {
  fail("the scan flags a call named in a comment — gate cries wolf");
}
if (scanSource("    _ = c.wgpuDeviceGetLimits(dev, &lim);\n").length !== 0) {
  fail("the allowlist is not being honoured");
}

let scanned = 0;
for (const root of ROOTS) {
  const abs = path.join(REPO, root);
  let files;
  try {
    files = zigFiles(abs);
  } catch {
    continue; // a release mirror may ship without tests/ or tools/
  }
  for (const file of files) {
    const rel = path.relative(REPO, file);
    if (rel === WRAPPER) continue;
    scanned++;
    for (const hit of scanSource(readFileSync(file, "utf8"))) {
      fail(
        `${rel}:${hit.line}: raw ${hit.name} outside ${WRAPPER}.\n` +
          "  wgpu is refcounted C and the leak gates count every acquisition and\n" +
          "  release through the wrappers in that file. A call site that goes\n" +
          "  straight to C takes references the ledger cannot see — which is how\n" +
          "  the surface came to leak on every failed create AND every successful\n" +
          "  destroy without a single test noticing (LEAK-04).\n" +
          "  Wrap it there with acquired()/releasing(), or — if it truly takes no\n" +
          "  reference — add it to ALLOWED in this script with the reason.",
      );
    }
  }
}

if (failed) process.exit(1);
console.log(`check-wgpu-wrappers: ${scanned} file(s), every wgpu reference goes through ${WRAPPER}`);
