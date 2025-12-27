/**
 * Simple test for loader.js parsing logic
 * Run with: node npm/pngine/src/loader.test.js
 */

import { parsePayload, getExecutorVariantName } from "./loader.js";
import { readFileSync } from "fs";

function test(name, fn) {
  try {
    fn();
    console.log(`✓ ${name}`);
  } catch (e) {
    console.log(`✗ ${name}: ${e.message}`);
    process.exitCode = 1;
  }
}

function assertEqual(actual, expected, msg) {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${expected}, got ${actual}`);
  }
}

// Test parsing non-embedded PNGB
test("parsePayload: non-embedded PNGB", () => {
  const data = readFileSync("/tmp/test.pngb");
  const pngb = new Uint8Array(data);
  const result = parsePayload(pngb);

  assertEqual(result.version, 0, "version");
  assertEqual(result.hasEmbeddedExecutor, false, "hasEmbeddedExecutor");
  assertEqual(result.executor, null, "executor");
  assertEqual(result.offsets.bytecode, 40, "bytecodeOffset");
  assertEqual(result.offsets.stringTable, 77, "stringTableOffset");
  assertEqual(result.bytecode.length, 37, "bytecodeLength");
});

// Test parsing embedded PNGB
test("parsePayload: embedded PNGB", () => {
  const data = readFileSync("/tmp/test-embedded.pngb");
  const pngb = new Uint8Array(data);
  const result = parsePayload(pngb);

  assertEqual(result.version, 0, "version");
  assertEqual(result.hasEmbeddedExecutor, true, "hasEmbeddedExecutor");
  assertEqual(result.executor !== null, true, "executor exists");
  assertEqual(result.executor.length, 6643, "executorLength");
  assertEqual(result.offsets.executor, 40, "executorOffset");
  // Bytecode starts after header + executor
  assertEqual(result.offsets.bytecode, 40 + 6643, "bytecodeOffset");
  assertEqual(result.bytecode.length, 37, "bytecodeLength");

  // Check WASM magic at executor start
  assertEqual(result.executor[0], 0x00, "WASM magic[0]");
  assertEqual(result.executor[1], 0x61, "WASM magic[1] (a)");
  assertEqual(result.executor[2], 0x73, "WASM magic[2] (s)");
  assertEqual(result.executor[3], 0x6d, "WASM magic[3] (m)");
});

// Test plugins parsing
test("parsePayload: plugins byte", () => {
  const data = readFileSync("/tmp/test-embedded.pngb");
  const pngb = new Uint8Array(data);
  const result = parsePayload(pngb);

  // 0x03 = PLUGIN_CORE | PLUGIN_RENDER
  assertEqual(result.plugins.core, true, "core plugin");
  assertEqual(result.plugins.render, true, "render plugin");
  assertEqual(result.plugins.compute, false, "compute plugin");
  assertEqual(result.plugins.wasm, false, "wasm plugin");
  assertEqual(result.plugins.animation, false, "animation plugin");
  assertEqual(result.plugins.texture, false, "texture plugin");
});

// Test variant name generation
test("getExecutorVariantName: core only", () => {
  const name = getExecutorVariantName({ core: true, render: false, compute: false, wasm: false, animation: false, texture: false });
  assertEqual(name, "core", "variant name");
});

test("getExecutorVariantName: render", () => {
  const name = getExecutorVariantName({ core: true, render: true, compute: false, wasm: false, animation: false, texture: false });
  assertEqual(name, "core-render", "variant name");
});

test("getExecutorVariantName: full", () => {
  const name = getExecutorVariantName({ core: true, render: true, compute: true, wasm: true, animation: true, texture: true });
  assertEqual(name, "core-render-compute-wasm-anim-texture", "variant name");
});

// Test error handling
test("parsePayload: short file throws", () => {
  try {
    parsePayload(new Uint8Array([0x50, 0x4e, 0x47, 0x42]));
    throw new Error("Should have thrown");
  } catch (e) {
    if (!e.message.includes("too short")) throw e;
  }
});

test("parsePayload: bad magic throws", () => {
  try {
    const bad = new Uint8Array(40);
    bad.set([0x89, 0x50, 0x4e, 0x47]); // PNG magic, not PNGB
    parsePayload(bad);
    throw new Error("Should have thrown");
  } catch (e) {
    if (!e.message.includes("bad magic")) throw e;
  }
});

console.log("\nAll tests passed!");
