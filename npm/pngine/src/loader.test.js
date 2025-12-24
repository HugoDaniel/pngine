/**
 * loader.js Unit Tests
 *
 * Tests PNGB v5 header parsing, embedded executor detection,
 * and plugin parsing.
 *
 * Run with: node --test loader.test.js
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  parsePayload,
  getExecutorVariantName,
  getExecutorImports,
  createExecutor,
} from "./loader.js";

// ============================================================================
// Test Utilities
// ============================================================================

/**
 * Build a PNGB v5 header (40 bytes)
 */
function buildV5Header(opts = {}) {
  const {
    magic = [0x50, 0x4e, 0x47, 0x42], // "PNGB"
    version = 5,
    flags = 0,
    plugins = 0x01, // core only
    executorOffset = 0,
    executorLength = 0,
    stringTableOffset = 40,
    dataOffset = 40,
    wgslOffset = 40,
    uniformOffset = 40,
    animationOffset = 40,
  } = opts;

  const buf = new ArrayBuffer(40);
  const view = new DataView(buf);
  const bytes = new Uint8Array(buf);

  // Magic (4 bytes)
  bytes.set(magic, 0);

  // Version (u16 little-endian)
  view.setUint16(4, version, true);

  // Flags (u16 little-endian)
  view.setUint16(6, flags, true);

  // Plugins (u8)
  bytes[8] = plugins;

  // Reserved (3 bytes)
  bytes[9] = 0;
  bytes[10] = 0;
  bytes[11] = 0;

  // Executor offset (u32 little-endian)
  view.setUint32(12, executorOffset, true);

  // Executor length (u32 little-endian)
  view.setUint32(16, executorLength, true);

  // String table offset (u32 little-endian)
  view.setUint32(20, stringTableOffset, true);

  // Data section offset (u32 little-endian)
  view.setUint32(24, dataOffset, true);

  // WGSL table offset (u32 little-endian)
  view.setUint32(28, wgslOffset, true);

  // Uniform table offset (u32 little-endian)
  view.setUint32(32, uniformOffset, true);

  // Animation table offset (u32 little-endian)
  view.setUint32(36, animationOffset, true);

  return bytes;
}

/**
 * Build a PNGB v4 header (28 bytes)
 */
function buildV4Header(opts = {}) {
  const {
    magic = [0x50, 0x4e, 0x47, 0x42],
    version = 4,
    flags = 0,
    stringTableOffset = 28,
    dataOffset = 28,
    wgslOffset = 28,
    uniformOffset = 28,
    animationOffset = 28,
  } = opts;

  const buf = new ArrayBuffer(28);
  const view = new DataView(buf);
  const bytes = new Uint8Array(buf);

  bytes.set(magic, 0);
  view.setUint16(4, version, true);
  view.setUint16(6, flags, true);
  view.setUint32(8, stringTableOffset, true);
  view.setUint32(12, dataOffset, true);
  view.setUint32(16, wgslOffset, true);
  view.setUint32(20, uniformOffset, true);
  view.setUint32(24, animationOffset, true);

  return bytes;
}

// ============================================================================
// parsePayload Tests
// ============================================================================

describe("parsePayload", () => {
  describe("v5 format", () => {
    it("parses minimal v5 header without embedded executor", () => {
      const header = buildV5Header();
      const result = parsePayload(header);

      assert.equal(result.version, 5);
      assert.equal(result.hasEmbeddedExecutor, false);
      assert.equal(result.hasAnimationTable, false);
      assert.equal(result.executor, null);
      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, false);
    });

    it("parses v5 header with embedded executor", () => {
      // Executor at offset 40, length 8
      const executor = new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]);
      const header = buildV5Header({
        flags: 0x01, // has_embedded_executor
        executorOffset: 40,
        executorLength: 8,
        stringTableOffset: 48,
        dataOffset: 48,
        wgslOffset: 48,
        uniformOffset: 48,
        animationOffset: 48,
      });

      // Combine header + executor
      const payload = new Uint8Array(48);
      payload.set(header, 0);
      payload.set(executor, 40);

      const result = parsePayload(payload);

      assert.equal(result.version, 5);
      assert.equal(result.hasEmbeddedExecutor, true);
      assert.notEqual(result.executor, null);
      assert.equal(result.executor.length, 8);
      assert.deepEqual([...result.executor], [...executor]);
    });

    it("parses v5 header with animation table flag", () => {
      const header = buildV5Header({
        flags: 0x02, // has_animation_table
      });

      const result = parsePayload(header);

      assert.equal(result.hasEmbeddedExecutor, false);
      assert.equal(result.hasAnimationTable, true);
    });

    it("parses v5 header with both flags set", () => {
      const header = buildV5Header({
        flags: 0x03, // has_embedded_executor | has_animation_table
        executorOffset: 40,
        executorLength: 4,
        stringTableOffset: 44,
        dataOffset: 44,
        wgslOffset: 44,
        uniformOffset: 44,
        animationOffset: 44,
      });

      const payload = new Uint8Array(44);
      payload.set(header, 0);
      payload.set([0xDE, 0xAD, 0xBE, 0xEF], 40);

      const result = parsePayload(payload);

      assert.equal(result.hasEmbeddedExecutor, true);
      assert.equal(result.hasAnimationTable, true);
    });

    it("extracts bytecode section correctly", () => {
      // Header(40) + Bytecode(10) = StringTable at 50
      const bytecode = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      const header = buildV5Header({
        stringTableOffset: 50,
        dataOffset: 50,
        wgslOffset: 50,
        uniformOffset: 50,
        animationOffset: 50,
      });

      const payload = new Uint8Array(50);
      payload.set(header, 0);
      payload.set(bytecode, 40);

      const result = parsePayload(payload);

      assert.equal(result.bytecode.length, 10);
      assert.deepEqual([...result.bytecode], [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    });

    it("extracts bytecode after embedded executor", () => {
      // Header(40) + Executor(8) + Bytecode(5) = StringTable at 53
      const executor = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7]);
      const bytecode = new Uint8Array([10, 20, 30, 40, 50]);
      const header = buildV5Header({
        flags: 0x01,
        executorOffset: 40,
        executorLength: 8,
        stringTableOffset: 53,
        dataOffset: 53,
        wgslOffset: 53,
        uniformOffset: 53,
        animationOffset: 53,
      });

      const payload = new Uint8Array(53);
      payload.set(header, 0);
      payload.set(executor, 40);
      payload.set(bytecode, 48);

      const result = parsePayload(payload);

      assert.equal(result.executor.length, 8);
      assert.equal(result.bytecode.length, 5);
      assert.deepEqual([...result.bytecode], [10, 20, 30, 40, 50]);
    });
  });

  describe("v4 backward compatibility", () => {
    it("parses minimal v4 header", () => {
      const header = buildV4Header();
      const result = parsePayload(header);

      assert.equal(result.version, 4);
      assert.equal(result.hasEmbeddedExecutor, false);
      assert.equal(result.executor, null);
      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, false);
    });

    it("extracts bytecode from v4 format", () => {
      // V4 Header(28) + Bytecode(6) = StringTable at 34
      const bytecode = new Uint8Array([0xA, 0xB, 0xC, 0xD, 0xE, 0xF]);
      const header = buildV4Header({
        stringTableOffset: 34,
        dataOffset: 34,
        wgslOffset: 34,
        uniformOffset: 34,
        animationOffset: 34,
      });

      const payload = new Uint8Array(34);
      payload.set(header, 0);
      payload.set(bytecode, 28);

      const result = parsePayload(payload);

      assert.equal(result.version, 4);
      assert.equal(result.bytecode.length, 6);
      assert.deepEqual([...result.bytecode], [0xA, 0xB, 0xC, 0xD, 0xE, 0xF]);
    });
  });

  describe("error handling", () => {
    it("throws on empty input", () => {
      assert.throws(() => parsePayload(new Uint8Array(0)), /too short/);
    });

    it("throws on truncated header (less than v4 size)", () => {
      assert.throws(() => parsePayload(new Uint8Array(20)), /too short/);
    });

    it("throws on invalid magic", () => {
      const header = buildV5Header({ magic: [0x00, 0x00, 0x00, 0x00] });
      assert.throws(() => parsePayload(header), /bad magic/);
    });

    it("throws on partial magic", () => {
      const header = buildV5Header({ magic: [0x50, 0x4e, 0x00, 0x00] });
      assert.throws(() => parsePayload(header), /bad magic/);
    });

    it("throws on unsupported version", () => {
      const header = buildV5Header({ version: 3 });
      assert.throws(() => parsePayload(header), /Unsupported.*version/);
    });

    it("throws on future version", () => {
      const header = buildV5Header({ version: 99 });
      assert.throws(() => parsePayload(header), /Unsupported.*version/);
    });
  });

  describe("plugin parsing", () => {
    it("parses core-only plugins", () => {
      const header = buildV5Header({ plugins: 0x01 });
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, false);
      assert.equal(result.plugins.compute, false);
      assert.equal(result.plugins.wasm, false);
      assert.equal(result.plugins.animation, false);
      assert.equal(result.plugins.texture, false);
    });

    it("parses render plugin", () => {
      const header = buildV5Header({ plugins: 0x03 }); // core + render
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, true);
      assert.equal(result.plugins.compute, false);
    });

    it("parses compute plugin", () => {
      const header = buildV5Header({ plugins: 0x05 }); // core + compute
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, false);
      assert.equal(result.plugins.compute, true);
    });

    it("parses wasm plugin", () => {
      const header = buildV5Header({ plugins: 0x09 }); // core + wasm
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.wasm, true);
    });

    it("parses animation plugin", () => {
      const header = buildV5Header({ plugins: 0x11 }); // core + animation
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.animation, true);
    });

    it("parses texture plugin", () => {
      const header = buildV5Header({ plugins: 0x21 }); // core + texture
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.texture, true);
    });

    it("parses full plugin set", () => {
      const header = buildV5Header({ plugins: 0x3F }); // all plugins
      const result = parsePayload(header);

      assert.equal(result.plugins.core, true);
      assert.equal(result.plugins.render, true);
      assert.equal(result.plugins.compute, true);
      assert.equal(result.plugins.wasm, true);
      assert.equal(result.plugins.animation, true);
      assert.equal(result.plugins.texture, true);
    });
  });

  describe("offsets", () => {
    it("returns correct offsets for v5 without executor", () => {
      const header = buildV5Header({
        stringTableOffset: 100,
        dataOffset: 200,
        wgslOffset: 300,
        uniformOffset: 400,
        animationOffset: 500,
      });

      // Need payload large enough for offsets
      const payload = new Uint8Array(500);
      payload.set(header, 0);

      const result = parsePayload(payload);

      assert.equal(result.offsets.executor, 0);
      assert.equal(result.offsets.executorLength, 0);
      assert.equal(result.offsets.bytecode, 40); // After header
      assert.equal(result.offsets.bytecodeLength, 60); // 100 - 40
      assert.equal(result.offsets.stringTable, 100);
      assert.equal(result.offsets.data, 200);
      assert.equal(result.offsets.wgsl, 300);
      assert.equal(result.offsets.uniform, 400);
      assert.equal(result.offsets.animation, 500);
    });

    it("returns correct offsets for v5 with executor", () => {
      const header = buildV5Header({
        flags: 0x01,
        executorOffset: 40,
        executorLength: 16,
        stringTableOffset: 100,
        dataOffset: 200,
        wgslOffset: 300,
        uniformOffset: 400,
        animationOffset: 500,
      });

      const payload = new Uint8Array(500);
      payload.set(header, 0);

      const result = parsePayload(payload);

      assert.equal(result.offsets.executor, 40);
      assert.equal(result.offsets.executorLength, 16);
      assert.equal(result.offsets.bytecode, 56); // 40 + 16
      assert.equal(result.offsets.bytecodeLength, 44); // 100 - 56
    });
  });
});

// ============================================================================
// getExecutorVariantName Tests
// ============================================================================

describe("getExecutorVariantName", () => {
  it("returns 'core' for core-only", () => {
    const plugins = {
      core: true,
      render: false,
      compute: false,
      wasm: false,
      animation: false,
      texture: false,
    };
    assert.equal(getExecutorVariantName(plugins), "core");
  });

  it("returns 'core-render' for core+render", () => {
    const plugins = {
      core: true,
      render: true,
      compute: false,
      wasm: false,
      animation: false,
      texture: false,
    };
    assert.equal(getExecutorVariantName(plugins), "core-render");
  });

  it("returns 'core-render-compute' for core+render+compute", () => {
    const plugins = {
      core: true,
      render: true,
      compute: true,
      wasm: false,
      animation: false,
      texture: false,
    };
    assert.equal(getExecutorVariantName(plugins), "core-render-compute");
  });

  it("returns full name for all plugins", () => {
    const plugins = {
      core: true,
      render: true,
      compute: true,
      wasm: true,
      animation: true,
      texture: true,
    };
    assert.equal(
      getExecutorVariantName(plugins),
      "core-render-compute-wasm-anim-texture"
    );
  });

  it("returns 'core-wasm' for core+wasm", () => {
    const plugins = {
      core: true,
      render: false,
      compute: false,
      wasm: true,
      animation: false,
      texture: false,
    };
    assert.equal(getExecutorVariantName(plugins), "core-wasm");
  });
});

// ============================================================================
// getExecutorImports Tests
// ============================================================================

describe("getExecutorImports", () => {
  it("returns object with env namespace", () => {
    const imports = getExecutorImports();
    assert.ok(imports.env);
  });

  it("provides default stub functions", () => {
    const imports = getExecutorImports();
    assert.equal(typeof imports.env.log, "function");
    assert.equal(typeof imports.env.wasmInstantiate, "function");
    assert.equal(typeof imports.env.wasmCall, "function");
    assert.equal(typeof imports.env.wasmGetResult, "function");
  });

  it("uses provided callbacks", () => {
    let logCalled = false;
    const imports = getExecutorImports({
      log: (ptr, len) => {
        logCalled = true;
      },
    });

    imports.env.log(0, 0);
    assert.equal(logCalled, true);
  });

  it("default wasmGetResult returns 0", () => {
    const imports = getExecutorImports();
    const result = imports.env.wasmGetResult(0, 0, 0);
    assert.equal(result, 0);
  });
});

// ============================================================================
// Property-Based Tests
// ============================================================================

describe("property-based tests", () => {
  it("parsePayload: bytecode length equals stringTable - bytecodeOffset", () => {
    // Generate random offsets where stringTable > header
    for (let i = 0; i < 100; i++) {
      const stringTableOffset = 40 + Math.floor(Math.random() * 200);
      const header = buildV5Header({
        stringTableOffset,
        dataOffset: stringTableOffset,
        wgslOffset: stringTableOffset,
        uniformOffset: stringTableOffset,
        animationOffset: stringTableOffset,
      });

      const payload = new Uint8Array(stringTableOffset);
      payload.set(header, 0);

      const result = parsePayload(payload);
      const expectedLen = stringTableOffset - 40;

      assert.equal(
        result.offsets.bytecodeLength,
        expectedLen,
        `iteration ${i}: expected ${expectedLen}, got ${result.offsets.bytecodeLength}`
      );
    }
  });

  it("parsePayload: executor extraction preserves bytes", () => {
    // Test with various executor sizes
    for (const executorLen of [0, 1, 8, 64, 256]) {
      if (executorLen === 0) continue;

      const executor = new Uint8Array(executorLen);
      for (let i = 0; i < executorLen; i++) {
        executor[i] = i % 256;
      }

      const stringTableOffset = 40 + executorLen;
      const header = buildV5Header({
        flags: 0x01,
        executorOffset: 40,
        executorLength: executorLen,
        stringTableOffset,
        dataOffset: stringTableOffset,
        wgslOffset: stringTableOffset,
        uniformOffset: stringTableOffset,
        animationOffset: stringTableOffset,
      });

      const payload = new Uint8Array(stringTableOffset);
      payload.set(header, 0);
      payload.set(executor, 40);

      const result = parsePayload(payload);

      assert.deepEqual(
        [...result.executor],
        [...executor],
        `executor size ${executorLen}`
      );
    }
  });

  it("parsePayload: plugin bitfield roundtrip", () => {
    // Test all 64 combinations of plugins
    for (let plugins = 0; plugins < 64; plugins++) {
      const header = buildV5Header({ plugins });
      const result = parsePayload(header);

      assert.equal(result.plugins.core, (plugins & 0x01) !== 0);
      assert.equal(result.plugins.render, (plugins & 0x02) !== 0);
      assert.equal(result.plugins.compute, (plugins & 0x04) !== 0);
      assert.equal(result.plugins.wasm, (plugins & 0x08) !== 0);
      assert.equal(result.plugins.animation, (plugins & 0x10) !== 0);
      assert.equal(result.plugins.texture, (plugins & 0x20) !== 0);
    }
  });
});

// ============================================================================
// Edge Cases
// ============================================================================

describe("edge cases", () => {
  it("handles zero-length bytecode", () => {
    const header = buildV5Header({
      stringTableOffset: 40, // Immediately after header
      dataOffset: 40,
      wgslOffset: 40,
      uniformOffset: 40,
      animationOffset: 40,
    });

    const result = parsePayload(header);
    assert.equal(result.bytecode.length, 0);
    assert.equal(result.offsets.bytecodeLength, 0);
  });

  it("handles executor at exactly header end", () => {
    const header = buildV5Header({
      flags: 0x01,
      executorOffset: 40,
      executorLength: 1,
      stringTableOffset: 41,
      dataOffset: 41,
      wgslOffset: 41,
      uniformOffset: 41,
      animationOffset: 41,
    });

    const payload = new Uint8Array(41);
    payload.set(header, 0);
    payload[40] = 0xFF;

    const result = parsePayload(payload);
    assert.equal(result.executor.length, 1);
    assert.equal(result.executor[0], 0xFF);
  });

  it("handles large executor (1MB)", () => {
    const executorLen = 1024 * 1024; // 1MB
    const stringTableOffset = 40 + executorLen;

    const header = buildV5Header({
      flags: 0x01,
      executorOffset: 40,
      executorLength: executorLen,
      stringTableOffset,
      dataOffset: stringTableOffset,
      wgslOffset: stringTableOffset,
      uniformOffset: stringTableOffset,
      animationOffset: stringTableOffset,
    });

    const payload = new Uint8Array(stringTableOffset);
    payload.set(header, 0);
    // Fill executor with pattern
    for (let i = 40; i < stringTableOffset; i++) {
      payload[i] = i % 256;
    }

    const result = parsePayload(payload);
    assert.equal(result.executor.length, executorLen);
    // Verify pattern
    assert.equal(result.executor[0], 40 % 256);
    assert.equal(result.executor[100], 140 % 256);
  });

  it("preserves payload reference", () => {
    const header = buildV5Header();
    const result = parsePayload(header);

    // payload should be the same array (subarray doesn't copy)
    assert.equal(result.payload.buffer, header.buffer);
  });

  it("bytecode is a view into payload (no copy)", () => {
    const header = buildV5Header({
      stringTableOffset: 50,
      dataOffset: 50,
      wgslOffset: 50,
      uniformOffset: 50,
      animationOffset: 50,
    });

    const payload = new Uint8Array(50);
    payload.set(header, 0);
    payload.fill(0xAB, 40, 50);

    const result = parsePayload(payload);

    // Modify original payload
    payload[42] = 0xCD;

    // Bytecode view should reflect the change
    assert.equal(result.bytecode[2], 0xCD);
  });
});

console.log("Running loader.js tests...");
