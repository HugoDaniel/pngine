#!/usr/bin/env node
/**
 * ABI fixture generation pinner (docs/abi.md §8).
 *
 * Pins an immutable "generation" of the executor WASM↔JS ABI:
 *   tests/npm/fixtures/abi/<gen>/
 *     executor.wasm      — the pinned executor binary (committed bytes, never rebuilt)
 *     manifest.json      — surface snapshot (exports/imports/hashes/opcodes)
 *     payloads/*.pngb    — payloads compiled with the pinned executor embedded
 *     golden/*.log       — recorded dispatcher call logs (museum test)
 *
 * Generations are APPEND-ONLY: this script refuses to overwrite an existing
 * generation directory. `--force` permits re-recording golden/*.log ONLY, and
 * doing so requires a commit message arguing semantic equivalence (abi.md §7).
 *
 * Usage:
 *   node scripts/gen-abi-fixtures.mjs --gen v1 [--executor <path>] [--force]
 *
 * Prerequisites: `zig build` (CLI at zig-out/bin/pngine).
 */

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { parsePayload, getExecutorImports } from "../npm/pngine/src/loader.js";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// Must match src/executor/variant.zig VARIANTS and build.zig executor names.
const VARIANT_NAMES = [
  "core", "render", "compute", "render-compute",
  "render-anim", "render-compute-anim", "render-wasm", "full",
];

// Pinned payload sources. Chosen to cover the three dispatch families:
// minimal render, compute+render+time-uniform, explicit JSON bind-group-layouts.
const FIXTURE_SOURCES = ["simple_triangle", "pass_compute_rainbow", "uniform_access"];

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function parseArgs(argv) {
  const args = { gen: null, executor: "npm/pngine/wasm/pngine.wasm", force: false };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--gen") args.gen = argv[++i];
    else if (argv[i] === "--executor") args.executor = argv[++i];
    else if (argv[i] === "--force") args.force = true;
    else throw new Error(`Unknown argument: ${argv[i]}`);
  }
  if (!args.gen || !/^v[0-9][0-9.]*$/.test(args.gen)) {
    throw new Error("Required: --gen v<N> (e.g. --gen v1)");
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv);
  const genDir = path.join(ROOT, "tests/npm/fixtures/abi", args.gen);
  const goldenOnly = existsSync(genDir);

  if (goldenOnly && !args.force) {
    throw new Error(
      `${genDir} already exists. Generations are append-only — pin a new --gen vN.\n` +
      `(--force re-records golden/*.log only, and requires a semantic-equivalence justification in the commit message.)`,
    );
  }
  if (goldenOnly) {
    console.warn(
      `\n!!! --force: re-recording golden logs for EXISTING generation ${args.gen}.\n` +
      `!!! The commit message MUST argue semantic equivalence (docs/abi.md §7).\n` +
      `!!! executor.wasm, payloads, and manifest.json are NOT touched.\n`,
    );
  }

  const executorBytes = readFileSync(path.join(ROOT, args.executor));
  const executorSha = sha256(executorBytes);

  if (!goldenOnly) {
    const cli = path.join(ROOT, "zig-out/bin/pngine");
    if (!existsSync(cli)) throw new Error("zig-out/bin/pngine not found — run `zig build` first.");

    // Stage the pinned bytes under every variant name so the CLI's disk lookup
    // always finds them (compile.zig falls back to its @embedFile'd executor
    // when a variant file is missing — that would silently pin the WRONG bytes).
    const staging = mkdtempSync(path.join(tmpdir(), "pngine-abi-pin-"));
    try {
      for (const name of VARIANT_NAMES) {
        writeFileSync(path.join(staging, `pngine-${name}.wasm`), executorBytes);
      }

      mkdirSync(path.join(genDir, "payloads"), { recursive: true });
      writeFileSync(path.join(genDir, "executor.wasm"), executorBytes);

      for (const name of FIXTURE_SOURCES) {
        const out = path.join(genDir, "payloads", `${name}.pngb`);
        execFileSync(cli, [
          "compile", path.join(ROOT, "examples", `${name}.sjon`),
          "-o", out, "--embed-executor", "--executors-dir", staging,
        ], { stdio: "inherit" });

        // The whole point of the pin: embedded executor === pinned bytes.
        const info = parsePayload(new Uint8Array(readFileSync(out)));
        if (!info.hasEmbeddedExecutor) throw new Error(`${name}: no embedded executor`);
        if (sha256(info.executor) !== executorSha) {
          throw new Error(`${name}: embedded executor differs from the pinned binary (CLI fallback?)`);
        }
      }
    } finally {
      rmSync(staging, { recursive: true, force: true });
    }

    // Surface snapshot + ABI version of the pinned binary.
    const module = await WebAssembly.compile(executorBytes);
    // instantiate(Module) resolves to the Instance directly (not {instance}).
    const instance = await WebAssembly.instantiate(module, getExecutorImports());
    const abiVersion = instance.exports.getAbiVersion?.() ?? 1;

    // Provenance: hashes of freshly built variants, when present. All 8 are
    // byte-identical today; recorded so divergence is visible in future pins.
    const variants = {};
    for (const name of VARIANT_NAMES) {
      const p = path.join(ROOT, "zig-out/executors", `pngine-${name}.wasm`);
      variants[name] = existsSync(p) ? sha256(readFileSync(p)) : null;
    }

    let zigVersion = null;
    try { zigVersion = execFileSync("zig", ["version"]).toString().trim(); } catch {}

    const manifest = {
      abiVersion,
      pinned: new Date().toISOString().slice(0, 10),
      zigVersion,
      executor: { file: "executor.wasm", sha256: executorSha, bytes: executorBytes.length, source: args.executor },
      variants,
      exports: WebAssembly.Module.exports(module)
        .map((e) => ({ name: e.name, kind: e.kind }))
        .sort((a, b) => a.name.localeCompare(b.name)),
      imports: WebAssembly.Module.imports(module)
        .map((i) => ({ module: i.module, name: i.name, kind: i.kind }))
        .sort((a, b) => a.name.localeCompare(b.name)),
      hostProvidedImports: Object.keys(getExecutorImports().env).map((n) => `env.${n}`).sort(),
      // Command-buffer opcode table (docs/abi.md §5). The surface test and the
      // Zig freeze test each hold their OWN copy — three deliberate tripwires.
      opcodes: {
        "0x01": "create_buffer", "0x02": "create_texture", "0x03": "create_sampler",
        "0x04": "create_shader", "0x05": "create_render_pipeline", "0x06": "create_compute_pipeline",
        "0x07": "create_bind_group", "0x08": "create_texture_view", "0x09": "create_query_set",
        "0x0A": "create_bind_group_layout", "0x0B": "create_image_bitmap", "0x0C": "create_pipeline_layout",
        "0x0D": "create_render_bundle",
        "0x10": "begin_render_pass", "0x11": "begin_compute_pass", "0x12": "set_pipeline",
        "0x13": "set_bind_group", "0x14": "set_vertex_buffer", "0x15": "draw",
        "0x16": "draw_indexed", "0x17": "end_pass", "0x18": "dispatch",
        "0x19": "set_index_buffer", "0x1A": "execute_bundles", "0x1B": "begin_render_pass_mrt",
        "0x1C": "draw_indirect", "0x1D": "draw_indexed_indirect", "0x1E": "dispatch_indirect",
        "0x1F": "set_viewport",
        "0x20": "write_buffer", "0x21": "write_time_uniform", "0x22": "copy_buffer_to_buffer",
        "0x23": "copy_texture_to_texture", "0x24": "write_buffer_from_wasm",
        "0x25": "copy_external_image_to_texture", "0x26": "write_pointer_uniform",
        "0x27": "resolve_query_set",
        "0x30": "init_wasm_module", "0x31": "call_wasm_func",
        "0x4A": "set_pass_timestamp_writes", "0x4B": "set_pass_occlusion_query_set",
        "0x4C": "end_occlusion_query", "0x4D": "begin_occlusion_query",
        "0x4E": "set_stencil_reference", "0x4F": "set_scissor_rect",
        "0x50": "set_pass_depth_stencil_ops", "0x51": "set_blend_constant",
        "0xF0": "submit", "0xFF": "end",
      },
      payloads: Object.fromEntries(FIXTURE_SOURCES.map((name) => {
        const bytes = readFileSync(path.join(genDir, "payloads", `${name}.pngb`));
        return [name, { source: `examples/${name}.sjon`, sha256: sha256(bytes), bytes: bytes.length }];
      })),
    };
    writeFileSync(path.join(genDir, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
    console.log(`Pinned ${args.gen}: executor ${executorSha.slice(0, 12)}… + ${FIXTURE_SOURCES.length} payloads`);
  }

  // Record golden dispatcher logs through the museum harness (the same code
  // the museum test runs — no parallel implementation).
  const { recordMuseumLog } = await import("../tests/npm/helpers/museum-harness.js");
  mkdirSync(path.join(genDir, "golden"), { recursive: true });
  for (const name of FIXTURE_SOURCES) {
    const payload = new Uint8Array(readFileSync(path.join(genDir, "payloads", `${name}.pngb`)));
    const log = await recordMuseumLog(payload);
    writeFileSync(path.join(genDir, "golden", `${name}.log`), log);
    console.log(`Recorded golden/${name}.log (${log.split("\n").length} lines)`);
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
