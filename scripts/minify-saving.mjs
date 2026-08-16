#!/usr/bin/env node

/**
 * Measure what `--minify` actually saves, across the example corpus.
 *
 * Not a pass/fail gate. The saving legitimately varies with corpus
 * composition — a threshold would either sit so loose it never fires or so
 * tight it fires on every new mesh fixture. This is a NUMBER THAT GETS LOOKED
 * AT, the way `coverage.txt` is.
 *
 * It exists because `--minify` was a dead flag for eight months (declared in
 * `Compiler.Options`, set by every CLI call site, read by nothing) while three
 * layers of documentation claimed a 30-50% saving. Nobody noticed because
 * nothing ever measured it. Run at the commit before the wiring landed, this
 * script reports exactly 0.0% — that is the baseline it was built to reproduce
 * (docs/plans/min1/04-gates.md).
 *
 * WGSL blobs are identified via the payload's own WGSL TABLE (wgsl_id →
 * data_id), not by sniffing which blobs look like text. The data section also
 * holds mesh vertex data and `#data` blobs, and a heuristic that guesses wrong
 * about a mesh silently moves the denominator.
 *
 * Reports two deltas, because they answer different questions:
 *   - raw:      how much smaller the WGSL text is (what the minifier did)
 *   - deflated: how much smaller the PNG gets (what a user actually ships,
 *               since the pNGb chunk is raw-DEFLATE compressed)
 * The second is always the smaller number and is the honest one to quote.
 *
 * Usage:
 *   node scripts/minify-saving.mjs              # aggregate only
 *   node scripts/minify-saving.mjs --verbose    # per-example rows too
 *   node scripts/minify-saving.mjs --json
 */

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { deflateRawSync } from "node:zlib";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLI = path.join(ROOT, "zig-out/bin/pngine");
const EXAMPLES = path.join(ROOT, "examples");

const args = process.argv.slice(2);
const VERBOSE = args.includes("--verbose");
const JSON_OUT = args.includes("--json");

/** LEB128, matching `opcodes.encodeVarint`. */
function readVarint(buf, pos) {
  let value = 0;
  let shift = 0;
  for (let i = 0; i < 5; i++) {
    const b = buf[pos + i];
    value |= (b & 0x7f) << shift;
    if ((b & 0x80) === 0) return { value: value >>> 0, len: i + 1 };
    shift += 7;
  }
  throw new Error("varint too long");
}

/**
 * Sum the WGSL blob bytes in a PNGB payload, and concatenate them so the
 * DEFLATE measurement sees the shader text alone — the payload as a whole also
 * contains bytecode and mesh data, which would dilute the ratio.
 */
function wgslBytes(buf) {
  if (buf.subarray(0, 4).toString("latin1") !== "PNGB") {
    throw new Error("not a PNGB payload");
  }
  const dv = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const dataOff = dv.getUint32(24, true);
  const wgslOff = dv.getUint32(28, true);
  const uniformOff = dv.getUint32(32, true);

  // Data section: count u16, then [count]{offset u32, len u32}, then blobs.
  const blobCount = dv.getUint16(dataOff, true);
  const entriesAt = dataOff + 2;
  const blobsBase = entriesAt + blobCount * 8;

  // WGSL table: count varint, then [count]{data_id varint, dep_count varint, deps…}
  const table = buf.subarray(wgslOff, uniformOff);
  const shaderDataIds = new Set();
  if (table.length > 0) {
    let pos = 0;
    const count = readVarint(table, pos);
    pos += count.len;
    for (let i = 0; i < count.value; i++) {
      const dataId = readVarint(table, pos);
      pos += dataId.len;
      const depCount = readVarint(table, pos);
      pos += depCount.len;
      for (let d = 0; d < depCount.value; d++) pos += readVarint(table, pos).len;
      shaderDataIds.add(dataId.value);
    }
  }

  const parts = [];
  for (const id of shaderDataIds) {
    if (id >= blobCount) continue;
    const off = dv.getUint32(entriesAt + id * 8, true);
    const len = dv.getUint32(entriesAt + id * 8 + 4, true);
    parts.push(buf.subarray(blobsBase + off, blobsBase + off + len));
  }
  const concat = Buffer.concat(parts);
  return {
    modules: shaderDataIds.size,
    raw: concat.length,
    deflated: concat.length === 0 ? 0 : deflateRawSync(concat).length,
  };
}

const work = mkdtempSync(path.join(tmpdir(), "pngine-minify-"));
const rows = [];
const failures = [];

try {
  const inputs = readdirSync(EXAMPLES)
    .filter((f) => f.endsWith(".sjon"))
    .sort();
  if (inputs.length === 0) throw new Error(`no .sjon examples under ${EXAMPLES}`);

  for (const file of inputs) {
    const name = file.replace(/\.sjon$/, "");
    const src = path.join(EXAMPLES, file);
    const plain = path.join(work, `${name}.pngb`);
    const min = path.join(work, `${name}.min.pngb`);
    try {
      // --no-validate: this measures bytes, not WGSL correctness, and the
      // corpus's validation status is a separate gate's business.
      execFileSync(CLI, ["compile", src, "-o", plain, "--no-validate"], { stdio: "pipe" });
      execFileSync(CLI, ["compile", src, "-o", min, "--no-validate", "--minify"], { stdio: "pipe" });
    } catch (err) {
      failures.push({ name, error: (err.stderr?.toString() || err.message).trim().split("\n")[0] });
      continue;
    }
    const a = wgslBytes(readFileSync(plain));
    const b = wgslBytes(readFileSync(min));
    if (a.raw === 0) continue; // no WGSL in this document — nothing to measure
    rows.push({ name, modules: a.modules, before: a, after: b });
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

if (rows.length === 0) {
  console.error("minify-saving: measured nothing — no corpus example yielded WGSL.");
  console.error("A measurement over an empty set reads green over nothing at all.");
  process.exit(1);
}

const sum = (pick) => rows.reduce((n, r) => n + pick(r), 0);
const rawBefore = sum((r) => r.before.raw);
const rawAfter = sum((r) => r.after.raw);
const defBefore = sum((r) => r.before.deflated);
const defAfter = sum((r) => r.after.deflated);
const pct = (before, after) => (before === 0 ? 0 : ((before - after) / before) * 100);

const report = {
  examples: rows.length,
  modules: sum((r) => r.modules),
  failures: failures.length,
  raw: { before: rawBefore, after: rawAfter, saved: pct(rawBefore, rawAfter) },
  deflated: { before: defBefore, after: defAfter, saved: pct(defBefore, defAfter) },
};

if (JSON_OUT) {
  console.log(JSON.stringify({ ...report, rows: VERBOSE ? rows : undefined }, null, 2));
} else {
  if (VERBOSE) {
    const w = Math.max(...rows.map((r) => r.name.length));
    console.log(`${"example".padEnd(w)}  ${"raw".padStart(16)}  ${"deflated".padStart(16)}`);
    for (const r of rows) {
      const raw = `${r.before.raw}→${r.after.raw}`;
      const def = `${r.before.deflated}→${r.after.deflated}`;
      const p = pct(r.before.deflated, r.after.deflated).toFixed(1);
      console.log(`${r.name.padEnd(w)}  ${raw.padStart(16)}  ${def.padStart(16)}  ${p.padStart(5)}%`);
    }
    console.log("");
  }
  console.log(`WGSL minify saving over ${rows.length} examples (${report.modules} modules):`);
  console.log(`  raw:      ${rawBefore} → ${rawAfter} B  (${report.raw.saved.toFixed(1)}% smaller)`);
  console.log(`  deflated: ${defBefore} → ${defAfter} B  (${report.deflated.saved.toFixed(1)}% smaller)`);
  if (report.raw.saved === 0) {
    console.log("");
    console.log("  0.0% — `--minify` changed nothing. Either it is not wired to the");
    console.log("  emitter, or the corpus contains no minifiable WGSL.");
  }
  for (const f of failures) console.error(`  ! ${f.name}: ${f.error}`);
}
