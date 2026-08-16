#!/usr/bin/env node
/**
 * The executor allocates nothing. Prove it from the shipped bytes.
 *
 * `src/wasm_entry.zig` holds every piece of state in fixed-size `.bss` and
 * writes commands through a cursor over a static buffer — it references no
 * allocator at all. That is a load-bearing property: the executor runs inside
 * someone else's page for as long as the tab is open, and §309's soak watches
 * `wasmBytes` stay flat across a session because of it.
 *
 * Nothing GATED it. A future `std.heap.wasm_allocator` would compile, link, and
 * ship in silence; the browser soak is end-to-end, manual, and only looks at
 * builds someone thought to run. This is the static half, over the artifact
 * itself: a WASM module can only get more memory through `memory.grow`, so if
 * that instruction is absent from the code section the module cannot grow, no
 * matter what its Zig source came to look like.
 *
 * ## What the scan is, exactly
 *
 * `memory.grow` is the two bytes `0x40 0x00` (opcode, then the zero memory
 * index). Finding it without decoding every instruction means one conservative
 * confusion: `0x40` is ALSO the empty block type, so `block`/`loop`/`if`
 * immediately followed by `unreachable` reads the same. That shape appears zero
 * times in all nine modules today. Left in deliberately — a gate that errs
 * toward "look at this" is worth more than one that can be talked out of
 * noticing a real grow whose operand happens to end in 0x02.
 *
 * The two synthetic modules below are the fail-probe, and they run every time:
 * one that grows must be detected, one that does not must not be. A scanner
 * nobody has watched find something is a decoration.
 *
 * Usage: node scripts/check-executor-static.mjs
 * Exit: 0 clean · 1 a module can grow its memory, or the scan is blind
 */

import { readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Walk a module's top-level sections. Returns [{id, body}]. */
function sections(bytes) {
  if (bytes.length < 8 || bytes.readUInt32LE(0) !== 0x6d736100) {
    throw new Error("not a WASM module (bad magic)");
  }
  let p = 8;
  const out = [];
  const uleb = () => {
    let r = 0, s = 0, b;
    do {
      if (p >= bytes.length) throw new Error("truncated LEB128");
      b = bytes[p++];
      r |= (b & 0x7f) << s;
      s += 7;
    } while (b & 0x80);
    return r >>> 0;
  };
  while (p < bytes.length) {
    const id = bytes[p++];
    const len = uleb();
    const end = p + len;
    if (end > bytes.length) throw new Error(`section ${id} runs past the file`);
    out.push({ id, body: bytes.subarray(p, end) });
    p = end;
  }
  return out;
}

/** Offsets of every `memory.grow`-shaped byte pair in the code section. */
export function memoryGrowSites(bytes) {
  const code = sections(bytes).find((s) => s.id === 10);
  if (!code) return [];
  const hits = [];
  for (let i = 0; i + 1 < code.body.length; i++) {
    if (code.body[i] === 0x40 && code.body[i + 1] === 0x00) hits.push(i);
  }
  return hits;
}

/** `{ min, max }` in 64 KiB pages, or null when the module declares no memory. */
export function memoryLimits(bytes) {
  const mem = sections(bytes).find((s) => s.id === 5);
  if (!mem) return null;
  let p = 0;
  const uleb = () => {
    let r = 0, s = 0, b;
    do { b = mem.body[p++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80);
    return r >>> 0;
  };
  if (uleb() === 0) return null; // count
  const flags = uleb();
  const min = uleb();
  return { min, max: flags & 1 ? uleb() : null };
}

/**
 * Minimal modules the scanner is checked against, hand-assembled so the probe
 * needs no toolchain and no build output: one type `() -> ()`, one function,
 * one 1-page memory, one body.
 */
function probeModule(bodyOps) {
  const body = [0x00, ...bodyOps]; // no locals
  return Buffer.from([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type:   () -> ()
    0x03, 0x02, 0x01, 0x00, //             func:   #0 : type 0
    0x05, 0x03, 0x01, 0x00, 0x01, //       memory: 1 page, no max
    0x0a, body.length + 2, 0x01, body.length, ...body, // code
  ]);
}

// i32.const 1; memory.grow; drop; end   /   memory.size; drop; end
const GROWS = probeModule([0x41, 0x01, 0x40, 0x00, 0x1a, 0x0b]);
const STATIC = probeModule([0x3f, 0x00, 0x1a, 0x0b]);

let failed = false;
const fail = (msg) => { console.error(`✗ ${msg}`); failed = true; };

// The fail-probe, first: everything below is worthless if this is wrong.
if (memoryGrowSites(GROWS).length !== 1) {
  fail("the scan cannot see a memory.grow it was handed — gate is blind");
}
if (memoryGrowSites(STATIC).length !== 0) {
  fail("the scan reports memory.grow in a module that has none — gate cries wolf");
}

// The executor the npm package falls back to is committed, so it is always
// here. The per-variant builds are not; check whatever `zig build web` left.
const targets = [];
const committed = path.join(REPO, "npm/pngine/wasm/pngine.wasm");
if (existsSync(committed)) targets.push(committed);
const variants = path.join(REPO, "zig-out/executors");
if (existsSync(variants)) {
  for (const f of readdirSync(variants).sort()) {
    if (f.endsWith(".wasm")) targets.push(path.join(variants, f));
  }
}

if (targets.length === 0) {
  console.log("check-executor-static: no executor wasm present, skipping");
  process.exit(0);
}

for (const file of targets) {
  const rel = path.relative(REPO, file);
  let bytes;
  try {
    bytes = readFileSync(file);
  } catch (e) {
    fail(`${rel}: unreadable (${e.message})`);
    continue;
  }
  let hits, limits;
  try {
    hits = memoryGrowSites(bytes);
    limits = memoryLimits(bytes);
  } catch (e) {
    fail(`${rel}: ${e.message}`);
    continue;
  }
  if (hits.length > 0) {
    fail(
      `${rel}: ${hits.length} memory.grow site(s) in the code section ` +
        `(first at code+0x${hits[0].toString(16)}).\n` +
        "  The executor must allocate nothing after init: all state is fixed-size\n" +
        "  .bss and the command buffer is a cursor over a static array. Something\n" +
        "  in its module graph now reaches an allocator (std.heap.wasm_allocator,\n" +
        "  an ArrayList, a std API that allocates internally) — find it and remove\n" +
        "  it, or if the growth is genuinely intended, change this gate on purpose.",
    );
    continue;
  }
  const pages = limits ? `${limits.min} page(s)` : "no memory section";
  console.log(`  ${rel}: no memory.grow, ${pages}`);
}

if (failed) process.exit(1);
console.log(`check-executor-static: ${targets.length} executor module(s) cannot grow their memory`);
