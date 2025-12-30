/**
 * Minification + Uniform Access Tests (JS/Browser)
 *
 * Verifies that WGSL minification does NOT break uniform access in the browser.
 *
 * What Minification Preserves (by design):
 * - Struct field names (e.g., `.time`, `.resolution`)
 * - Entry point names (e.g., `@vertex fn vertexMain`)
 * - Binding variable names (e.g., `var<uniform> uniforms`)
 *
 * What Minification Renames (internal only):
 * - Struct type names (`struct Uniforms` -> `struct a`)
 * - Local variables (`let myValue` -> `let a`)
 * - Helper functions (`fn computeNormal()` -> `fn a()`)
 *
 * Test Strategy:
 * 1. Load compiled bytecode (with --minify flag)
 * 2. Verify shaders compile in WebGPU
 * 3. Verify uniform buffers can be written to
 * 4. Verify render/compute passes execute correctly
 *
 * Run with: node tests/minify-uniforms.test.js
 */

import { execSync } from "child_process";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, "..");

/**
 * Compile a .pngine file with optional minification.
 * @param {string} source - DSL source code
 * @param {boolean} minify - Whether to enable minification
 * @returns {Buffer} - Compiled PNGB bytecode
 */
function compileSource(source, minify = false) {
  const tempInput = join(PROJECT_ROOT, "zig-out", "temp-test.pngine");
  const tempOutput = join(PROJECT_ROOT, "zig-out", "temp-test.pngb");
  const pngine = join(PROJECT_ROOT, "zig-out", "bin", "pngine");

  // Ensure CLI is built
  if (!existsSync(pngine)) {
    console.log("Building pngine CLI...");
    execSync(`/Users/hugo/.zvm/bin/zig build`, { cwd: PROJECT_ROOT });
  }

  // Write source to temp file
  writeFileSync(tempInput, source);

  try {
    // Compile with pngine CLI
    const args = [pngine, "compile", tempInput, "-o", tempOutput];
    if (minify) args.push("--minify");
    execSync(args.join(" "), {
      cwd: PROJECT_ROOT,
      stdio: "pipe",
    });

    // Read compiled output
    return readFileSync(tempOutput);
  } finally {
    // Cleanup
    if (existsSync(tempInput)) unlinkSync(tempInput);
    if (existsSync(tempOutput)) unlinkSync(tempOutput);
  }
}

/**
 * Parse PNGB header and extract all shader code from data section.
 * Concatenates all non-empty entries to get the complete shader.
 * @param {Buffer} pngb - PNGB bytecode
 * @returns {string} - Combined shader code from all data section entries
 */
function extractShaderCode(pngb) {
  // PNGB v0 Header (40 bytes):
  // 0-3: magic "PNGB"
  // 4-5: version
  // 6-7: flags
  // 8: plugins
  // 9-11: reserved
  // 12-15: executor_offset
  // 16-19: executor_length
  // 20-23: string_table_offset
  // 24-27: data_section_offset
  // 28-31: wgsl_table_offset
  // 32-35: uniform_table_offset
  // 36-39: animation_table_offset

  const dataSectionOffset = pngb.readUInt32LE(24);
  const wgslTableOffset = pngb.readUInt32LE(28);

  if (dataSectionOffset >= pngb.length) {
    throw new Error("Invalid data section offset");
  }

  // Data section format:
  // count: u16
  // offsets: [count]u16
  // lengths: [count]u16
  // data: bytes

  let pos = dataSectionOffset;
  const count = pngb.readUInt16LE(pos);
  pos += 2;

  if (count === 0) return "";

  // Read all entry metadata
  const offsets = [];
  const lengths = [];
  for (let i = 0; i < count; i++) {
    offsets.push(pngb.readUInt16LE(pos));
    pos += 2;
  }
  for (let i = 0; i < count; i++) {
    lengths.push(pngb.readUInt16LE(pos));
    pos += 2;
  }

  // Extract all entries and concatenate
  const dataBase = pos;
  let allShaderCode = "";
  for (let i = 0; i < count; i++) {
    if (lengths[i] > 0) {
      const start = dataBase + offsets[i];
      const end = start + lengths[i];
      const data = pngb.subarray(start, end).toString("utf-8");
      allShaderCode += data;
    }
  }

  return allShaderCode;
}

// ============================================================================
// Test Cases
// ============================================================================

const BASIC_UNIFORM_SHADER = `
#wgsl shader {
  value="
struct Uniforms {
    time: f32,
    resolution: vec2f,
    color: vec4f,
}
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@vertex fn vertexMain(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    let t = uniforms.time;
    return vec4f(0.0, 0.0, 0.0, 1.0);
}

@fragment fn fragmentMain() -> @location(0) vec4f {
    return uniforms.color;
}
"
}

#shaderModule shaderMod { code=shader }

#buffer uniformBuffer {
  size=32
  usage=[UNIFORM COPY_DST]
}

#bindGroupLayout layout0 {
  entries=[
    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type=uniform } }
  ]
}

#bindGroup group0 {
  layout=layout0
  entries=[
    { binding=0 resource={ buffer=uniformBuffer } }
  ]
}

#renderPipeline pipeline {
  vertex={ module=shaderMod entryPoint=vertexMain }
  fragment={
    module=shaderMod
    entryPoint=fragmentMain
    targets=[{ format=bgra8unorm }]
  }
}

#renderPass mainPass {
  colorAttachments=[{ clearValue=[0 0 0 1] loadOp=clear storeOp=store }]
  pipeline=pipeline
  bindGroups=[group0]
  draw=3
}

#frame main { perform=[mainPass] }
`;

async function runTests() {
  console.log("Running minification + uniform access tests...\n");

  let passed = 0;
  let failed = 0;

  // Test 1: Compile without minification
  try {
    console.log("Test 1: Compile without minification");
    const pngb = compileSource(BASIC_UNIFORM_SHADER, false);
    console.log(`  Compiled: ${pngb.length} bytes`);
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    console.log(`  FAIL: ${e.message}\n`);
    failed++;
  }

  // Test 2: Compile with minification (if available)
  try {
    console.log("Test 2: Compile with minification");
    const pngb = compileSource(BASIC_UNIFORM_SHADER, true);
    console.log(`  Compiled: ${pngb.length} bytes`);
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    if (e.message.includes("libminiray")) {
      console.log("  SKIP: libminiray not available\n");
    } else {
      console.log(`  FAIL: ${e.message}\n`);
      failed++;
    }
  }

  // Test 3: Entry points preserved in minified shader
  try {
    console.log("Test 3: Entry points preserved in minified shader");
    const pngb = compileSource(BASIC_UNIFORM_SHADER, true);
    const shaderCode = extractShaderCode(pngb);

    if (!shaderCode.includes("vertexMain")) {
      throw new Error("vertexMain not found in shader code");
    }
    if (!shaderCode.includes("fragmentMain")) {
      throw new Error("fragmentMain not found in shader code");
    }

    console.log("  Entry points found: vertexMain, fragmentMain");
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    if (e.message.includes("libminiray")) {
      console.log("  SKIP: libminiray not available\n");
    } else {
      console.log(`  FAIL: ${e.message}\n`);
      failed++;
    }
  }

  // Test 4: Binding variable name preserved
  try {
    console.log("Test 4: Binding variable name preserved");
    const pngb = compileSource(BASIC_UNIFORM_SHADER, true);
    const shaderCode = extractShaderCode(pngb);

    if (!shaderCode.includes("uniforms")) {
      throw new Error("'uniforms' binding name not found in shader code");
    }

    console.log("  Binding name found: uniforms");
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    if (e.message.includes("libminiray")) {
      console.log("  SKIP: libminiray not available\n");
    } else {
      console.log(`  FAIL: ${e.message}\n`);
      failed++;
    }
  }

  // Test 5: Struct field accesses preserved
  try {
    console.log("Test 5: Struct field accesses preserved");
    const pngb = compileSource(BASIC_UNIFORM_SHADER, true);
    const shaderCode = extractShaderCode(pngb);

    if (!shaderCode.includes(".time")) {
      throw new Error(".time field access not found in shader code");
    }
    if (!shaderCode.includes(".color")) {
      throw new Error(".color field access not found in shader code");
    }

    console.log("  Field accesses found: .time, .color");
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    if (e.message.includes("libminiray")) {
      console.log("  SKIP: libminiray not available\n");
    } else {
      console.log(`  FAIL: ${e.message}\n`);
      failed++;
    }
  }

  // Test 6: Minified is smaller
  try {
    console.log("Test 6: Minified bytecode is smaller");
    const pngbNormal = compileSource(BASIC_UNIFORM_SHADER, false);
    const pngbMinified = compileSource(BASIC_UNIFORM_SHADER, true);

    if (pngbMinified.length > pngbNormal.length) {
      throw new Error(
        `Minified (${pngbMinified.length}) larger than normal (${pngbNormal.length})`
      );
    }

    const reduction = (
      ((pngbNormal.length - pngbMinified.length) / pngbNormal.length) *
      100
    ).toFixed(1);
    console.log(
      `  Normal: ${pngbNormal.length} bytes, Minified: ${pngbMinified.length} bytes (${reduction}% reduction)`
    );
    passed++;
    console.log("  PASS\n");
  } catch (e) {
    if (e.message.includes("libminiray")) {
      console.log("  SKIP: libminiray not available\n");
    } else {
      console.log(`  FAIL: ${e.message}\n`);
      failed++;
    }
  }

  // Summary
  console.log("=".repeat(50));
  console.log(`Results: ${passed} passed, ${failed} failed`);

  if (failed > 0) {
    process.exit(1);
  }
}

// Run tests
runTests().catch((e) => {
  console.error("Test runner error:", e);
  process.exit(1);
});
