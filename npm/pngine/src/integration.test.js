/**
 * Integration Tests for loader.js
 *
 * Tests with real PNGB payloads generated from Zig format.zig
 *
 * Run with: node --test integration.test.js
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { parsePayload, getExecutorVariantName } from "./loader.js";

// ============================================================================
// Real PNGB Payload Tests
// ============================================================================

/**
 * Build a real PNGB v5 payload matching format.zig serialization.
 *
 * This creates a complete payload with:
 * - 40-byte v5 header
 * - Optional embedded executor
 * - Bytecode section
 * - Empty string table (2 bytes: u16 count = 0)
 * - Empty data section (2 bytes: u16 count = 0)
 * - Empty wgsl table (1 byte: varint count = 0)
 * - Empty uniform table (1 byte: varint count = 0)
 * - Empty animation table (1 byte: varint count = 0)
 */
function buildRealPNGBPayload(opts = {}) {
  const {
    executor = null,
    bytecode = new Uint8Array([]),
    plugins = 0x01,
  } = opts;

  const hasExecutor = executor !== null && executor.length > 0;
  const executorLen = hasExecutor ? executor.length : 0;

  // Section sizes (matching format.zig)
  const stringTableSize = 2; // u16 count = 0
  const dataSectionSize = 2; // u16 count = 0
  const wgslTableSize = 1; // varint count = 0
  const uniformTableSize = 1; // varint count = 0
  const animationTableSize = 1; // varint count = 0

  // Calculate offsets
  const headerSize = 40;
  const executorOffset = hasExecutor ? headerSize : 0;
  const bytecodeStart = headerSize + executorLen;
  const stringTableOffset = bytecodeStart + bytecode.length;
  const dataOffset = stringTableOffset + stringTableSize;
  const wgslOffset = dataOffset + dataSectionSize;
  const uniformOffset = wgslOffset + wgslTableSize;
  const animationOffset = uniformOffset + uniformTableSize;
  const totalSize = animationOffset + animationTableSize;

  // Allocate buffer
  const payload = new Uint8Array(totalSize);
  const view = new DataView(payload.buffer);

  // Write header
  payload.set([0x50, 0x4e, 0x47, 0x42], 0); // "PNGB"
  view.setUint16(4, 5, true); // version
  view.setUint16(6, hasExecutor ? 0x01 : 0x00, true); // flags
  payload[8] = plugins; // plugins
  payload[9] = 0; payload[10] = 0; payload[11] = 0; // reserved
  view.setUint32(12, executorOffset, true);
  view.setUint32(16, executorLen, true);
  view.setUint32(20, stringTableOffset, true);
  view.setUint32(24, dataOffset, true);
  view.setUint32(28, wgslOffset, true);
  view.setUint32(32, uniformOffset, true);
  view.setUint32(36, animationOffset, true);

  // Write executor
  if (hasExecutor) {
    payload.set(executor, headerSize);
  }

  // Write bytecode
  if (bytecode.length > 0) {
    payload.set(bytecode, bytecodeStart);
  }

  // Write empty sections (matching format.zig)
  view.setUint16(stringTableOffset, 0, true); // string table: u16 count = 0
  view.setUint16(dataOffset, 0, true); // data section: u16 count = 0
  payload[wgslOffset] = 0; // wgsl table: varint count = 0
  payload[uniformOffset] = 0; // uniform table: varint count = 0
  payload[animationOffset] = 0; // animation table: varint count = 0

  return payload;
}

describe("integration: real PNGB payloads", () => {
  it("parses minimal payload (no executor, no bytecode)", () => {
    const payload = buildRealPNGBPayload();
    const result = parsePayload(payload);

    assert.equal(result.version, 5);
    assert.equal(result.hasEmbeddedExecutor, false);
    assert.equal(result.executor, null);
    assert.equal(result.bytecode.length, 0);
  });

  it("parses payload with bytecode only", () => {
    // Simulate simple bytecode: create_shader_module opcode
    const bytecode = new Uint8Array([0x01, 0x00, 0x00]); // opcode + args
    const payload = buildRealPNGBPayload({ bytecode });
    const result = parsePayload(payload);

    assert.equal(result.bytecode.length, 3);
    assert.deepEqual([...result.bytecode], [0x01, 0x00, 0x00]);
  });

  it("parses payload with embedded executor", () => {
    // Minimal WASM module (8 bytes magic + version)
    const executor = new Uint8Array([
      0x00, 0x61, 0x73, 0x6d, // WASM magic
      0x01, 0x00, 0x00, 0x00, // version 1
    ]);
    const bytecode = new Uint8Array([0x42, 0x43]); // Some bytecode

    const payload = buildRealPNGBPayload({ executor, bytecode });
    const result = parsePayload(payload);

    assert.equal(result.hasEmbeddedExecutor, true);
    assert.equal(result.executor.length, 8);
    assert.deepEqual([...result.executor.slice(0, 4)], [0x00, 0x61, 0x73, 0x6d]);
    assert.equal(result.bytecode.length, 2);
    assert.deepEqual([...result.bytecode], [0x42, 0x43]);
  });

  it("parses payload with all plugins enabled", () => {
    const payload = buildRealPNGBPayload({ plugins: 0x3F });
    const result = parsePayload(payload);

    assert.equal(result.plugins.core, true);
    assert.equal(result.plugins.render, true);
    assert.equal(result.plugins.compute, true);
    assert.equal(result.plugins.wasm, true);
    assert.equal(result.plugins.animation, true);
    assert.equal(result.plugins.texture, true);
  });

  it("correctly identifies section boundaries", () => {
    const bytecode = new Uint8Array([0x10, 0x20, 0x30, 0x40, 0x50]); // 5 bytes
    const payload = buildRealPNGBPayload({ bytecode });
    const result = parsePayload(payload);

    // Header = 40, bytecode = 5, string table starts at 45
    assert.equal(result.offsets.bytecode, 40);
    assert.equal(result.offsets.bytecodeLength, 5);
    assert.equal(result.offsets.stringTable, 45);
    // data = stringTable + 2 = 47
    assert.equal(result.offsets.data, 47);
    // wgsl = data + 2 = 49
    assert.equal(result.offsets.wgsl, 49);
    // uniform = wgsl + 1 = 50
    assert.equal(result.offsets.uniform, 50);
    // animation = uniform + 1 = 51
    assert.equal(result.offsets.animation, 51);
  });
});

// ============================================================================
// Variant Name Tests (matching Zig PluginSet)
// ============================================================================

describe("integration: plugin variant names", () => {
  it("core-only matches Zig PluginSet.core_only", () => {
    const payload = buildRealPNGBPayload({ plugins: 0x01 });
    const result = parsePayload(payload);
    assert.equal(getExecutorVariantName(result.plugins), "core");
  });

  it("full matches Zig PluginSet.full", () => {
    const payload = buildRealPNGBPayload({ plugins: 0x3F });
    const result = parsePayload(payload);
    assert.equal(
      getExecutorVariantName(result.plugins),
      "core-render-compute-wasm-anim-texture"
    );
  });

  it("render+compute matches Zig custom PluginSet", () => {
    // core(0x01) + render(0x02) + compute(0x04) = 0x07
    const payload = buildRealPNGBPayload({ plugins: 0x07 });
    const result = parsePayload(payload);
    assert.equal(getExecutorVariantName(result.plugins), "core-render-compute");
  });
});

// ============================================================================
// Cross-Version Compatibility
// ============================================================================

describe("integration: version compatibility", () => {
  it("v4 payload detected correctly", () => {
    // Build v4 header (28 bytes)
    const v4Payload = new Uint8Array(35); // 28 header + 7 sections
    const view = new DataView(v4Payload.buffer);

    v4Payload.set([0x50, 0x4e, 0x47, 0x42], 0); // "PNGB"
    view.setUint16(4, 4, true); // version 4
    view.setUint16(6, 0, true); // flags
    view.setUint32(8, 28, true); // string_table_offset (at header end)
    view.setUint32(12, 30, true); // data_offset
    view.setUint32(16, 32, true); // wgsl_offset
    view.setUint32(20, 33, true); // uniform_offset
    view.setUint32(24, 34, true); // animation_offset

    // Empty sections
    view.setUint16(28, 0, true); // string table
    view.setUint16(30, 0, true); // data section
    v4Payload[32] = 0; // wgsl
    v4Payload[33] = 0; // uniform
    v4Payload[34] = 0; // animation

    const result = parsePayload(v4Payload);

    assert.equal(result.version, 4);
    assert.equal(result.hasEmbeddedExecutor, false);
    assert.equal(result.executor, null);
    // v4 has no plugin info, should default to core-only
    assert.equal(result.plugins.core, true);
    assert.equal(result.plugins.render, false);
  });
});

// ============================================================================
// Stress Tests
// ============================================================================

describe("integration: stress tests", () => {
  it("handles maximum bytecode size (1MB)", () => {
    const bytecode = new Uint8Array(1024 * 1024);
    for (let i = 0; i < bytecode.length; i++) {
      bytecode[i] = i % 256;
    }

    const payload = buildRealPNGBPayload({ bytecode });
    const result = parsePayload(payload);

    assert.equal(result.bytecode.length, 1024 * 1024);
    // Verify pattern preserved
    assert.equal(result.bytecode[0], 0);
    assert.equal(result.bytecode[255], 255);
    assert.equal(result.bytecode[256], 0);
  });

  it("handles large executor + bytecode", () => {
    const executor = new Uint8Array(500 * 1024); // 500KB
    const bytecode = new Uint8Array(500 * 1024); // 500KB

    // Fill with patterns
    for (let i = 0; i < executor.length; i++) {
      executor[i] = (i * 3) % 256;
    }
    for (let i = 0; i < bytecode.length; i++) {
      bytecode[i] = (i * 7) % 256;
    }

    const payload = buildRealPNGBPayload({ executor, bytecode });
    const result = parsePayload(payload);

    assert.equal(result.executor.length, 500 * 1024);
    assert.equal(result.bytecode.length, 500 * 1024);

    // Verify patterns
    assert.equal(result.executor[100], (100 * 3) % 256);
    assert.equal(result.bytecode[100], (100 * 7) % 256);
  });

  it("parses many payloads without memory issues", () => {
    // Create and parse 1000 payloads
    for (let i = 0; i < 1000; i++) {
      const bytecode = new Uint8Array([i % 256, (i >> 8) % 256]);
      const payload = buildRealPNGBPayload({
        bytecode,
        plugins: (i % 64) | 0x01, // Various plugin combinations
      });

      const result = parsePayload(payload);
      assert.equal(result.bytecode[0], i % 256);
    }
  });
});

// ============================================================================
// Format Compliance Tests (matching format.zig exactly)
// ============================================================================

describe("integration: format compliance", () => {
  it("header size is exactly 40 bytes for v5", () => {
    const payload = buildRealPNGBPayload();
    // First section (string table) starts at offset 40
    assert.equal(payload[20], 40); // string_table_offset low byte
  });

  it("plugin byte is at offset 8", () => {
    const payload = buildRealPNGBPayload({ plugins: 0x2A });
    assert.equal(payload[8], 0x2A);
  });

  it("flags are little-endian at offset 6", () => {
    const executor = new Uint8Array([1, 2, 3, 4]);
    const payload = buildRealPNGBPayload({ executor });
    const view = new DataView(payload.buffer);

    // Flags should be 0x0001 (has_embedded_executor)
    assert.equal(view.getUint16(6, true), 0x0001);
  });

  it("executor_offset is at offset 12", () => {
    const executor = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const payload = buildRealPNGBPayload({ executor });
    const view = new DataView(payload.buffer);

    // Executor should start at offset 40 (after header)
    assert.equal(view.getUint32(12, true), 40);
  });

  it("executor_length is at offset 16", () => {
    const executor = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
    const payload = buildRealPNGBPayload({ executor });
    const view = new DataView(payload.buffer);

    assert.equal(view.getUint32(16, true), 8);
  });
});

console.log("Running integration tests...");
