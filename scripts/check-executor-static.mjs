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
 * Since the capacity raise (memcap 02.4) the same artifacts also promise exact
 * input capacities and a reviewed initial-memory layout. The loader reads
 * `getBytecodeCapacity()`/`getDataCapacity()` from the binary, so a module that
 * silently lost an export or changed its initial pages would move the host's
 * write contract. Those values are asserted here too, not printed for review:
 * standard 2,097,152 / 4,194,304 in 114 pages; micro 16,384 / 32,768 in 17.
 *
 * ## What the scan is, exactly
 *
 * `memory.grow` is the two bytes `0x40 0x00` (opcode, then the zero memory
 * index). Finding it without decoding every instruction means one conservative
 * confusion: `0x40` is ALSO the empty block type, so `block`/`loop`/`if`
 * immediately followed by `unreachable` reads the same. That shape appears zero
 * times in all ten executor modules today. Left in deliberately — a gate that
 * errs toward "look at this" is worth more than one that can be talked out of
 * noticing a real grow whose operand happens to end in 0x02.
 *
 * The capacity functions are pure comptime reads, so their bodies are exactly
 * `i32.const <value>; end`. The verifier decodes the export section to find the
 * function index and the code section to read that constant; a body that stops
 * being a constant return is a finding, not a pass.
 *
 * The synthetic modules below are the fail-probe, and they run every time: a
 * module that grows must be detected, one that does not must not be; a missing
 * export, a wrong value, a wrong page count, and a compiler-shaped module must
 * each be named. A scanner nobody has watched find something is a decoration.
 *
 * The verifier is executor-only. `pngine-compiler.wasm` grows its linear memory
 * by design (R5) and is rejected as `not-an-executor` if handed in; the target
 * list never contains it.
 *
 * Usage: node scripts/check-executor-static.mjs
 * Exit: 0 clean · 1 a module can grow its memory, or its capacities/pages are
 *       not the configured ones, or the scan itself is blind
 */

import { readFileSync, existsSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

/** Exact per-module contract. Values are bytes and 64 KiB pages. */
export const STANDARD_EXPECT = Object.freeze({
  bytecodeCapacity: 2_097_152,
  dataCapacity: 4_194_304,
  initialPages: 114,
});
export const MICRO_EXPECT = Object.freeze({
  bytecodeCapacity: 16_384,
  dataCapacity: 32_768,
  initialPages: 17,
});

/**
 * Compiler-only exports. Any module carrying one is the compiler, not an
 * executor: R5 says its linear memory grows by design and this verifier must
 * never judge it with the executor's no-grow rule.
 */
const COMPILER_ONLY_EXPORTS = [
  "compile",
  "compileToPng",
  "minifyWgsl",
  "allocSource",
  "allocFileTable",
];

/** A bounds-checked reader over one section's bytes. */
function ulebReader(bytes) {
  let p = 0;
  const byte = () => {
    if (p >= bytes.length) throw new Error("truncated WASM section");
    return bytes[p++];
  };
  const uleb = () => {
    let r = 0, s = 0, b;
    do {
      b = byte();
      r += (b & 0x7f) * 2 ** s;
      s += 7;
    } while (b & 0x80);
    return r;
  };
  const skip = (n) => {
    p += n;
    if (p > bytes.length) throw new Error("field runs past its section");
  };
  const string = () => {
    const len = uleb();
    const start = p;
    skip(len);
    return bytes.subarray(start, start + len).toString("utf8");
  };
  const skipString = () => { skip(uleb()); };
  return { byte, uleb, skip, string, skipString, pos: () => p };
}

/** Walk a module's top-level sections. Returns [{id, body}]. */
function sections(input) {
  const bytes = Buffer.isBuffer(input) ? input : Buffer.from(input);
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
      r += (b & 0x7f) * 2 ** s;
      s += 7;
    } while (b & 0x80);
    return r;
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

/** Offsets of every `memory.grow`-shaped byte pair in a parsed code section. */
function growSitesIn(secs) {
  const code = secs.find((s) => s.id === 10);
  if (!code) return [];
  const hits = [];
  for (let i = 0; i + 1 < code.body.length; i++) {
    if (code.body[i] === 0x40 && code.body[i + 1] === 0x00) hits.push(i);
  }
  return hits;
}

/** `{ min, max }` in 64 KiB pages, or null when the module declares no memory. */
function limitsIn(secs) {
  const mem = secs.find((s) => s.id === 5);
  if (!mem) return null;
  const { uleb } = ulebReader(mem.body);
  if (uleb() === 0) return null; // count
  const flags = uleb();
  const min = uleb();
  return { min, max: flags & 1 ? uleb() : null };
}

/** Every export: name -> { kind, index }. */
function exportsIn(secs) {
  const exp = secs.find((s) => s.id === 7);
  const out = new Map();
  if (!exp) return out;
  const { byte, uleb, string } = ulebReader(exp.body);
  const count = uleb();
  for (let i = 0; i < count; i++) {
    const name = string();
    const kind = byte();
    const index = uleb();
    out.set(name, { kind, index });
  }
  return out;
}

/** Count function imports, which shift defined-function indices. */
function importedFunctionsIn(secs) {
  const imp = secs.find((s) => s.id === 2);
  if (!imp) return 0;
  const { byte, uleb, skipString } = ulebReader(imp.body);
  const limits = () => {
    const flags = uleb();
    uleb(); // min
    if (flags & 1) uleb(); // max
  };
  const count = uleb();
  let funcs = 0;
  for (let i = 0; i < count; i++) {
    skipString(); // module
    skipString(); // field
    const kind = byte();
    if (kind === 0) {
      uleb();
      funcs++;
    } else if (kind === 1) {
      byte(); // element type
      limits();
    } else if (kind === 2) {
      limits();
    } else if (kind === 3) {
      byte(); // value type
      byte(); // mutability
    } else if (kind === 4) {
      byte(); // attribute
      uleb(); // type index
    } else {
      throw new Error(`unknown import kind ${kind}`);
    }
  }
  return funcs;
}

/** Parsed function bodies in definition order (imports excluded). */
function codeBodiesIn(secs) {
  const code = secs.find((s) => s.id === 10);
  if (!code) return [];
  const { uleb, skip, pos } = ulebReader(code.body);
  const count = uleb();
  const bodies = [];
  for (let i = 0; i < count; i++) {
    const len = uleb();
    const start = pos();
    skip(len);
    bodies.push(code.body.subarray(start, start + len));
  }
  return bodies;
}

/** `{ value }` or `{ error }`: a body that is exactly `i32.const <n>; end`. */
function constantReturn(body) {
  const { byte, uleb, pos } = ulebReader(body);
  const localGroups = uleb();
  for (let i = 0; i < localGroups; i++) {
    uleb(); // local count
    byte(); // value type
  }
  const op = byte();
  if (op !== 0x41) {
    return { error: `body starts with 0x${op.toString(16)} instead of i32.const` };
  }
  let value = 0, shift = 0, b;
  do {
    b = byte();
    value += (b & 0x7f) * 2 ** shift;
    shift += 7;
  } while (b & 0x80);
  if (shift < 32 && (b & 0x40)) value -= 2 ** shift; // sign-extend i32
  if (byte() !== 0x0b) return { error: "i32.const is not immediately followed by end" };
  if (pos() !== body.length) return { error: "body has instructions after end" };
  return { value };
}

/** Everything the verifier needs about one module. Throws on malformed bytes. */
function readModuleFacts(input) {
  const secs = sections(input);
  const exportsMap = exportsIn(secs);
  const importedFunctions = importedFunctionsIn(secs);
  const bodies = codeBodiesIn(secs);
  const capacity = (name) => {
    const entry = exportsMap.get(name);
    if (!entry) return { state: "missing" };
    if (entry.kind !== 0) return { state: "wrong-kind", kind: entry.kind };
    const body = bodies[entry.index - importedFunctions];
    if (!body) return { state: "unreadable", detail: `function index ${entry.index} has no body` };
    const constant = constantReturn(body);
    if (constant.error) return { state: "unreadable", detail: constant.error };
    return { state: "value", value: constant.value };
  };
  return {
    secs,
    growSites: growSitesIn(secs),
    memory: limitsIn(secs),
    exports: exportsMap,
    bodies,
    importedFunctions,
    bytecodeCapacity: capacity("getBytecodeCapacity"),
    dataCapacity: capacity("getDataCapacity"),
  };
}

/** Read a path or accept bytes; returns bytes plus a display label. */
function loadInput(bytesOrPath, fallbackLabel = "module") {
  if (typeof bytesOrPath === "string") {
    return { bytes: readFileSync(bytesOrPath), label: path.basename(bytesOrPath) };
  }
  return { bytes: Buffer.from(bytesOrPath), label: fallbackLabel };
}

/**
 * Minimal modules the scanner is checked against, hand-assembled so the probe
 * needs no toolchain and no build output: one `() -> ()` entry, one
 * `() -> i32` per capacity export, one memory, and one body.
 *
 * `grow` selects the original probe body — `i32.const 1; memory.grow; drop` —
 * versus `memory.size; drop`. A `null` capacity leaves that export out.
 * `compilerExport` adds the compiler's signature `compile` export.
 */
export function buildProbeModule({
  grow = false,
  pages = 1,
  bytecodeCapacity = null,
  dataCapacity = null,
  compilerExport = false,
} = {}) {
  const uleb = (value) => {
    const out = [];
    let v = value >>> 0;
    do {
      let b = v & 0x7f;
      v >>>= 7;
      if (v) b |= 0x80;
      out.push(b);
    } while (v);
    return out;
  };
  const section = (id, payload) => [id, ...uleb(payload.length), ...payload];
  const name = (s) => [...uleb(Buffer.byteLength(s)), ...Buffer.from(s)];

  // type 0: () -> ()   type 1: () -> i32
  const types = [0x02, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01];
  const funcTypes = [0x00]; // main
  const exports = [...name("memory"), 0x02, 0x00];
  let exportCount = 1;
  const bodies = [
    [0x00, ...(grow ? [0x41, 0x01, 0x40, 0x00, 0x1a, 0x0b] : [0x3f, 0x00, 0x1a, 0x0b])],
  ];

  let index = 1;
  if (compilerExport) {
    funcTypes.push(0x00);
    exports.push(...name("compile"), 0x00, index);
    bodies.push([0x00, 0x0b]);
    exportCount++;
    index++;
  }

  for (const [exportName, capacity] of [
    ["getBytecodeCapacity", bytecodeCapacity],
    ["getDataCapacity", dataCapacity],
  ]) {
    if (capacity === null || capacity === undefined) continue;
    funcTypes.push(0x01);
    exports.push(...name(exportName), 0x00, index);
    bodies.push([0x00, 0x41, ...uleb(capacity), 0x0b]);
    exportCount++;
    index++;
  }

  const code = [bodies.length, ...bodies.flatMap((b) => [...uleb(b.length), ...b])];
  return Buffer.from([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    ...section(1, types),
    ...section(3, [funcTypes.length, ...funcTypes]),
    ...section(5, [0x01, 0x00, ...uleb(pages)]), // one memory, min pages, no max
    ...section(7, [exportCount, ...exports]),
    ...section(10, code),
  ]);
}

export function memoryGrowSites(bytes) {
  return growSitesIn(sections(bytes));
}

export function memoryLimits(bytes) {
  return limitsIn(sections(bytes));
}

/**
 * What the scan reports about one module. Capacities are `null` when the
 * export is absent or unreadable; `pages` is `null` when there is no memory.
 */
export function measureExecutorModule(bytesOrPath) {
  const { bytes } = loadInput(bytesOrPath);
  const facts = readModuleFacts(bytes);
  return {
    growSites: facts.growSites.length,
    pages: facts.memory ? facts.memory.min : null,
    bytecodeCapacity:
      facts.bytecodeCapacity.state === "value" ? facts.bytecodeCapacity.value : null,
    dataCapacity: facts.dataCapacity.state === "value" ? facts.dataCapacity.value : null,
  };
}

/**
 * Judge one executor module against `expect`. Returns findings, empty = pass.
 * Each finding is `{ code, message, ...details }`; the CLI prints messages and
 * the tests assert codes. The verifier is executor-only (R5): compiler modules
 * are rejected before any executor rule runs.
 */
export function verifyExecutorModule(bytesOrPath, { expect, label } = {}) {
  let input;
  try {
    input = loadInput(bytesOrPath, label || "module");
  } catch (e) {
    return [{ code: "unreadable-module", message: `${label || "module"}: unreadable (${e.message})` }];
  }
  const tag = label || input.label;

  let facts;
  try {
    facts = readModuleFacts(input.bytes);
  } catch (e) {
    return [{ code: "unreadable-module", message: `${tag}: ${e.message}` }];
  }

  const compiler =
    typeof bytesOrPath === "string" && path.basename(bytesOrPath) === "pngine-compiler.wasm"
      ? "pngine-compiler.wasm"
      : COMPILER_ONLY_EXPORTS.find((name) => facts.exports.has(name));
  if (compiler) {
    return [{
      code: "not-an-executor",
      message:
        `${tag}: not an executor module (${compiler}); the compiler's linear memory ` +
        "grows by design — this verifier is executor-only (R5)",
    }];
  }

  const findings = [];
  if (facts.growSites.length > 0) {
    findings.push({
      code: "memory-grow",
      message:
        `${tag}: ${facts.growSites.length} memory.grow site(s) in the code section ` +
        `(first at code+0x${facts.growSites[0].toString(16)}).\n` +
        "  The executor must allocate nothing after init: all state is fixed-size\n" +
        "  .bss and the command buffer is a cursor over a static array. Something\n" +
        "  in its module graph now reaches an allocator (std.heap.wasm_allocator,\n" +
        "  an ArrayList, a std API that allocates internally) — find it and remove\n" +
        "  it, or if the growth is genuinely intended, change this gate on purpose.",
    });
  }

  if (expect) {
    for (const [field, name] of [
      ["bytecodeCapacity", "getBytecodeCapacity"],
      ["dataCapacity", "getDataCapacity"],
    ]) {
      const expected = expect[field];
      if (expected === undefined) continue;
      const actual = facts[field];
      if (actual.state === "missing") {
        findings.push({ code: "missing-capacity", name, message: `${tag}: missing ${name} export` });
      } else if (actual.state === "wrong-kind") {
        findings.push({
          code: "missing-capacity",
          name,
          message: `${tag}: missing ${name} function export (kind ${actual.kind})`,
        });
      } else if (actual.state === "unreadable") {
        findings.push({
          code: "unreadable-capacity",
          name,
          message: `${tag}: ${name} is not a constant return (${actual.detail})`,
        });
      } else if (actual.value !== expected) {
        findings.push({
          code: "wrong-capacity",
          name,
          expected,
          actual: actual.value,
          message: `${tag}: ${name} is ${actual.value}; expected ${expected}`,
        });
      }
    }

    if (expect.initialPages !== undefined) {
      if (!facts.memory) {
        findings.push({
          code: "missing-memory",
          message: `${tag}: no initial memory section; expected ${expect.initialPages} page(s)`,
        });
      } else if (facts.memory.min !== expect.initialPages) {
        findings.push({
          code: "wrong-pages",
          expected: expect.initialPages,
          actual: facts.memory.min,
          message: `${tag}: initial memory is ${facts.memory.min} page(s); expected ${expect.initialPages}`,
        });
      }
    }
  }

  return findings;
}

/**
 * The executor artifacts `zig build` leaves in a checkout. The compiler is
 * never a candidate: it is not named here, and `pngine-compiler.wasm` lives
 * beside the shared fallback rather than in the variant directory.
 * A missing micro artifact is returned in `skippedMicro` so the CLI can say so
 * loudly; it never disappears from the report.
 */
export function collectExecutorTargets(root = REPO) {
  const targets = [];
  const shared = path.join(root, "npm/pngine/wasm/pngine.wasm");
  if (existsSync(shared)) targets.push({ file: shared, expect: STANDARD_EXPECT });
  const variants = path.join(root, "zig-out/executors");
  if (existsSync(variants)) {
    for (const f of readdirSync(variants).sort()) {
      if (f.endsWith(".wasm") && f !== "pngine-compiler.wasm") {
        targets.push({ file: path.join(variants, f), expect: STANDARD_EXPECT });
      }
    }
  }
  const micro = path.join(root, "zig-out/bin/pngine-micro.wasm");
  const skippedMicro = existsSync(micro) ? null : micro;
  if (!skippedMicro) targets.push({ file: micro, expect: MICRO_EXPECT });
  return { targets, skippedMicro };
}

function main() {
  let failed = false;
  const fail = (msg) => { console.error(`✗ ${msg}`); failed = true; };

  // The fail-probes, first: everything below is worthless if these are wrong.
  const PROBE = {
    pages: STANDARD_EXPECT.initialPages,
    bytecodeCapacity: STANDARD_EXPECT.bytecodeCapacity,
    dataCapacity: STANDARD_EXPECT.dataCapacity,
  };
  const probeFindings = (overrides) =>
    verifyExecutorModule(buildProbeModule({ ...PROBE, ...overrides }), {
      expect: STANDARD_EXPECT,
      label: "probe",
    });

  if (memoryGrowSites(buildProbeModule({ ...PROBE, grow: true })).length !== 1) {
    fail("the scan cannot see a memory.grow it was handed — gate is blind");
  }
  if (memoryGrowSites(buildProbeModule({ ...PROBE, grow: false })).length !== 0) {
    fail("the scan reports memory.grow in a module that has none — gate cries wolf");
  }
  if (!probeFindings({ grow: true }).some((f) => f.code === "memory-grow")) {
    fail("the verifier cannot see a memory.grow it was handed — gate is blind");
  }
  if (probeFindings({}).length !== 0) {
    fail("the verifier rejects a probe with exact capacities and pages — gate cries wolf");
  }
  if (
    !probeFindings({ bytecodeCapacity: null }).some(
      (f) => f.code === "missing-capacity" && f.name === "getBytecodeCapacity",
    )
  ) {
    fail("the verifier cannot see a missing capacity export — gate is blind");
  }
  if (!probeFindings({ bytecodeCapacity: 262_144 }).some((f) => f.code === "wrong-capacity")) {
    fail("the verifier cannot see a wrong capacity value — gate is blind");
  }
  if (!probeFindings({ pages: 113 }).some((f) => f.code === "wrong-pages")) {
    fail("the verifier cannot see a wrong initial page count — gate is blind");
  }
  if (!probeFindings({ compilerExport: true }).some((f) => f.code === "not-an-executor")) {
    fail("the verifier accepts a compiler-shaped module — R5 gate is blind");
  }

  const { targets, skippedMicro } = collectExecutorTargets(REPO);
  if (skippedMicro) {
    console.log(
      `! micro executor missing at ${path.relative(REPO, skippedMicro)}; skipped — ` +
        "build it with: zig build wasm-micro",
    );
  }
  if (targets.length === 0) {
    console.log("check-executor-static: no executor wasm present, skipping");
    return;
  }

  for (const { file, expect } of targets) {
    const rel = path.relative(REPO, file);
    let bytes, measured;
    try {
      bytes = readFileSync(file);
      measured = measureExecutorModule(bytes);
    } catch (e) {
      fail(`${rel}: unreadable (${e.message})`);
      continue;
    }
    const findings = verifyExecutorModule(bytes, { expect, label: rel });
    if (findings.length > 0) {
      for (const finding of findings) fail(finding.message);
      continue;
    }
    const pages = measured.pages === null ? "no memory section" : `${measured.pages} page(s)`;
    const cap = (value) => (value === null ? "missing" : `${value} B`);
    console.log(
      `  ${rel}: no memory.grow, ${pages}, ` +
        `bytecode ${cap(measured.bytecodeCapacity)}, data ${cap(measured.dataCapacity)}`,
    );
  }

  if (failed) process.exit(1);
  console.log(
    `check-executor-static: ${targets.length} executor module(s) cannot grow; ` +
      "capacities and initial pages match the configuration",
  );
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedDirectly) main();
