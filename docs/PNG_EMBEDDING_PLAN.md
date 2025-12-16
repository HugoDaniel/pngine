# PNGine PNG Embedding Plan

## Overview

Embed PNGB bytecode into PNG files as an ancillary chunk, enabling self-contained shader art that displays as a preview image and executes in browsers.

**Goal**: `shader.png` = preview image + embedded bytecode, runnable with a single JS call.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        PNG File Structure                           │
├─────────────────────────────────────────────────────────────────────┤
│ PNG Signature (8 bytes)                                             │
│ IHDR (image header)                                                 │
│ ... standard PNG chunks ...                                         │
│ IDAT (compressed image data)                                        │
│ pNGb (PNGine bytecode) ◄── OUR CUSTOM CHUNK                        │
│ IEND (end marker)                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Chunk ID: `pNGb`

```
Byte 1: 'p' (lowercase) → Ancillary chunk (can be ignored by decoders)
Byte 2: 'N' (uppercase) → Public chunk (registered naming convention)
Byte 3: 'G' (uppercase) → Reserved bit (must be uppercase per PNG spec)
Byte 4: 'b' (lowercase) → Safe to copy (chunk doesn't depend on image data)
```

### Chunk Data Format

```
┌─────────────────────────────────────────────────────────────────────┐
│ pNGb Chunk Data                                                     │
├──────────────────┬──────────────────────────────────────────────────┤
│ Version (1 byte) │ 0x01 = current version                           │
├──────────────────┼──────────────────────────────────────────────────┤
│ Flags (1 byte)   │ Bit 0: compressed (1) / raw (0)                  │
│                  │ Bit 1-7: reserved                                 │
├──────────────────┼──────────────────────────────────────────────────┤
│ Payload          │ PNGB bytecode (optionally gzip-compressed)       │
└──────────────────┴──────────────────────────────────────────────────┘
```

---

## Compression Strategy

### Analysis: When to Compress

PNGB bytecode already uses:
- Varint encoding for integers
- String interning (string table)
- Data section with shader code

Additional gzip compression benefits:
- **Shader code**: Highly compressible text (WGSL has repetitive keywords)
- **JSON descriptors**: Repetitive structure compresses well
- **Typical ratio**: 2-4x compression on shader-heavy bytecode

### Compression Decision

```
If bytecode > 256 bytes:
    compressed = gzip(bytecode)
    If compressed.len < bytecode.len * 0.9:
        Use compressed (set flag bit 0)
    Else:
        Use raw bytecode
Else:
    Use raw bytecode (gzip overhead not worth it)
```

### Implementation Notes

**Zig (CLI)**:
- Use `std.compress.gzip` for compression
- Already available in std library, no dependencies

**JavaScript (Browser)**:
- Use `DecompressionStream` API for decompression
- Supported in all modern browsers (Chrome 80+, Firefox 113+, Safari 16.4+)

---

## File Structure

```
src/
├── png/
│   ├── chunk.zig          # PNG chunk read/write
│   ├── crc32.zig          # CRC-32 implementation
│   ├── embed.zig          # Embed PNGB into PNG
│   └── extract.zig        # Extract PNGB from PNG

web/
├── pngine-png.js          # PNG chunk extraction
├── pngine-loader.js       # (existing) WASM loader
└── pngine.js              # Unified API
```

---

## Implementation: Zig PNG Module

### 1. `src/png/crc32.zig` (~50 lines)

```zig
//! CRC-32 implementation for PNG chunk validation.
//!
//! Uses the PNG/zlib polynomial 0xEDB88320 (bit-reversed).
//! Lookup table generated at comptime for O(1) per-byte updates.

/// Precomputed CRC-32 lookup table.
const crc_table: [256]u32 = comptime blk: {
    var table: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            c = if (c & 1 != 0)
                0xEDB88320 ^ (c >> 1)
            else
                c >> 1;
        }
        table[n] = c;
    }
    break :blk table;
};

/// Calculate CRC-32 over a byte slice.
/// Invariant: Returns same value as zlib crc32() for same input.
pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
}

/// Update running CRC with additional data.
pub fn update(crc: u32, data: []const u8) u32 {
    var c = crc ^ 0xFFFFFFFF;
    for (data) |byte| {
        c = crc_table[(c ^ byte) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}
```

### 2. `src/png/chunk.zig` (~150 lines)

```zig
//! PNG chunk parsing and serialization.
//!
//! PNG chunks have structure: Length (4B) + Type (4B) + Data + CRC (4B)
//! All multi-byte values are big-endian.

const std = @import("std");
const crc32 = @import("crc32.zig");

pub const Chunk = struct {
    chunk_type: [4]u8,
    data: []const u8,
};

pub const PNG_SIGNATURE: [8]u8 = .{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

/// Parse PNG chunks from buffer.
/// Returns iterator over chunks.
pub fn parseChunks(png_data: []const u8) ChunkIterator {
    // Pre-condition: valid PNG signature
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(std.mem.eql(u8, png_data[0..8], &PNG_SIGNATURE));

    return .{ .data = png_data, .pos = 8 };
}

pub const ChunkIterator = struct {
    data: []const u8,
    pos: usize,

    pub fn next(self: *ChunkIterator) ?Chunk {
        if (self.pos + 12 > self.data.len) return null;

        const length = std.mem.readInt(u32, self.data[self.pos..][0..4], .big);
        const chunk_type = self.data[self.pos + 4 ..][0..4].*;

        if (self.pos + 12 + length > self.data.len) return null;

        const chunk_data = self.data[self.pos + 8 ..][0..length];

        // Validate CRC
        const stored_crc = std.mem.readInt(u32, self.data[self.pos + 8 + length ..][0..4], .big);
        var crc_data: [4 + length]u8 = undefined; // Can't use variable length
        // ... CRC validation

        self.pos += 12 + length;

        return .{ .chunk_type = chunk_type, .data = chunk_data };
    }
};

/// Serialize a chunk to writer.
pub fn writeChunk(writer: anytype, chunk_type: [4]u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    try writer.writeInt(u32, @intCast(data.len), .big);

    // Type (4 bytes)
    try writer.writeAll(&chunk_type);

    // Data
    try writer.writeAll(data);

    // CRC over type + data
    const crc = crc32.crc32(&chunk_type);
    const final_crc = crc32.update(crc, data);
    try writer.writeInt(u32, final_crc, .big);
}
```

### 3. `src/png/embed.zig` (~200 lines)

```zig
//! Embed PNGB bytecode into PNG files.
//!
//! Inserts a pNGb ancillary chunk before IEND containing compressed bytecode.

const std = @import("std");
const chunk = @import("chunk.zig");
const crc32 = @import("crc32.zig");

pub const PNGB_CHUNK_TYPE: [4]u8 = .{ 'p', 'N', 'G', 'b' };
pub const PNGB_VERSION: u8 = 0x01;
pub const FLAG_COMPRESSED: u8 = 0x01;

pub const Error = error{
    InvalidPng,
    MissingIEND,
    OutOfMemory,
    CompressionFailed,
};

/// Embed PNGB bytecode into a PNG image.
/// Returns new PNG data with embedded pNGb chunk.
///
/// Strategy:
/// 1. Find IEND chunk position
/// 2. Compress bytecode if beneficial
/// 3. Insert pNGb chunk before IEND
pub fn embed(
    allocator: std.mem.Allocator,
    png_data: []const u8,
    bytecode: []const u8,
) Error![]u8 {
    // Pre-conditions
    std.debug.assert(png_data.len >= 8);
    std.debug.assert(bytecode.len >= 16); // Minimum PNGB size

    // Validate PNG signature
    if (!std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Find IEND position
    const iend_pos = findIEND(png_data) orelse return Error.MissingIEND;

    // Compress bytecode if beneficial
    const payload = try maybeCompress(allocator, bytecode);
    defer if (payload.compressed) allocator.free(payload.data);

    // Build pNGb chunk
    const pngb_chunk = try buildPngbChunk(allocator, payload);
    defer allocator.free(pngb_chunk);

    // Assemble final PNG:
    // [original up to IEND] + [pNGb chunk] + [IEND]
    const result_size = iend_pos + pngb_chunk.len + (png_data.len - iend_pos);
    const result = try allocator.alloc(u8, result_size);
    errdefer allocator.free(result);

    @memcpy(result[0..iend_pos], png_data[0..iend_pos]);
    @memcpy(result[iend_pos..][0..pngb_chunk.len], pngb_chunk);
    @memcpy(result[iend_pos + pngb_chunk.len ..], png_data[iend_pos..]);

    return result;
}

const Payload = struct {
    data: []const u8,
    compressed: bool,
};

fn maybeCompress(allocator: std.mem.Allocator, data: []const u8) !Payload {
    // Don't compress small data
    if (data.len <= 256) {
        return .{ .data = data, .compressed = false };
    }

    // Try gzip compression
    var compressed = std.ArrayList(u8).init(allocator);
    errdefer compressed.deinit();

    var compressor = try std.compress.gzip.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();

    // Use compressed only if significantly smaller
    if (compressed.items.len < data.len * 9 / 10) {
        return .{ .data = try compressed.toOwnedSlice(), .compressed = true };
    }

    compressed.deinit();
    return .{ .data = data, .compressed = false };
}

fn findIEND(png_data: []const u8) ?usize {
    // IEND has 0-length data, so look for pattern:
    // 00 00 00 00 (length) + 49 45 4E 44 (IEND)
    const iend_pattern: [8]u8 = .{ 0, 0, 0, 0, 'I', 'E', 'N', 'D' };
    return std.mem.indexOf(u8, png_data, &iend_pattern);
}

fn buildPngbChunk(allocator: std.mem.Allocator, payload: Payload) ![]u8 {
    const header_size = 2; // version + flags
    const data_size = header_size + payload.data.len;
    const chunk_size = 4 + 4 + data_size + 4; // length + type + data + crc

    var result = try allocator.alloc(u8, chunk_size);
    var fbs = std.io.fixedBufferStream(result);
    const writer = fbs.writer();

    // Length
    try writer.writeInt(u32, @intCast(data_size), .big);

    // Type
    try writer.writeAll(&PNGB_CHUNK_TYPE);

    // Data: version + flags + payload
    try writer.writeByte(PNGB_VERSION);
    try writer.writeByte(if (payload.compressed) FLAG_COMPRESSED else 0);
    try writer.writeAll(payload.data);

    // CRC over type + data
    const crc_start = 4; // After length
    const crc_end = crc_start + 4 + data_size;
    const crc = crc32.crc32(result[crc_start..crc_end]);
    try writer.writeInt(u32, crc, .big);

    return result;
}
```

### 4. `src/png/extract.zig` (~100 lines)

```zig
//! Extract PNGB bytecode from PNG files.

const std = @import("std");
const chunk = @import("chunk.zig");
const embed = @import("embed.zig");

pub const Error = error{
    InvalidPng,
    NoPngbChunk,
    InvalidPngbVersion,
    DecompressionFailed,
    OutOfMemory,
};

/// Extract PNGB bytecode from PNG data.
/// Returns owned slice that caller must free.
pub fn extract(allocator: std.mem.Allocator, png_data: []const u8) Error![]u8 {
    // Validate PNG
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &chunk.PNG_SIGNATURE)) {
        return Error.InvalidPng;
    }

    // Find pNGb chunk
    var iter = chunk.parseChunks(png_data);
    while (iter.next()) |c| {
        if (std.mem.eql(u8, &c.chunk_type, &embed.PNGB_CHUNK_TYPE)) {
            return parsePngbChunk(allocator, c.data);
        }
    }

    return Error.NoPngbChunk;
}

fn parsePngbChunk(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    if (data.len < 2) return Error.InvalidPngbVersion;

    const version = data[0];
    const flags = data[1];
    const payload = data[2..];

    if (version != embed.PNGB_VERSION) {
        return Error.InvalidPngbVersion;
    }

    const is_compressed = (flags & embed.FLAG_COMPRESSED) != 0;

    if (is_compressed) {
        // Decompress gzip
        var decompressor = std.compress.gzip.decompressor(
            std.io.fixedBufferStream(payload).reader()
        );

        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        // Read decompressed data with bounded loop
        for (0..16 * 1024 * 1024) |_| { // Max 16 MiB
            const byte = decompressor.reader().readByte() catch |err| {
                if (err == error.EndOfStream) break;
                return Error.DecompressionFailed;
            };
            try result.append(byte);
        }

        return result.toOwnedSlice();
    } else {
        // Return copy of raw payload
        const result = try allocator.alloc(u8, payload.len);
        @memcpy(result, payload);
        return result;
    }
}
```

---

## Implementation: CLI Commands

### New Commands

```
pngine embed <source.pngine> <image.png> -o <output.png>
pngine embed <bytecode.pngb> <image.png> -o <output.png>
pngine extract <shader.png> -o <output.pngb>
pngine run <shader.png>  # Check mode with embedded bytecode
```

### CLI Updates (`src/cli.zig`)

```zig
// Add to command dispatch
} else if (std.mem.eql(u8, command, "embed")) {
    return runEmbed(allocator, args[2..]);
} else if (std.mem.eql(u8, command, "extract")) {
    return runExtract(allocator, args[2..]);
}

fn runEmbed(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse args: source, image, -o output
    // Read source (compile if .pngine/.pbsf, load if .pngb)
    // Read PNG image
    // Embed bytecode
    // Write output PNG
}

fn runExtract(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Read PNG
    // Extract PNGB
    // Write to output file
}
```

---

## Implementation: JavaScript PNG Loader

### `web/pngine-png.js` (~100 lines)

```javascript
/**
 * PNG Chunk Extraction for PNGine
 *
 * Extracts pNGb chunks from PNG files and decompresses if needed.
 */

const PNG_SIGNATURE = new Uint8Array([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
const PNGB_CHUNK_TYPE = 'pNGb';
const PNGB_VERSION = 0x01;
const FLAG_COMPRESSED = 0x01;

/**
 * Extract PNGB bytecode from a PNG file.
 *
 * @param {ArrayBuffer} pngBuffer - Raw PNG file data
 * @returns {Promise<Uint8Array>} Extracted PNGB bytecode
 * @throws {Error} If PNG is invalid or has no pNGb chunk
 */
export async function extractPngb(pngBuffer) {
    const png = new Uint8Array(pngBuffer);

    // Validate PNG signature
    for (let i = 0; i < 8; i++) {
        if (png[i] !== PNG_SIGNATURE[i]) {
            throw new Error('Invalid PNG signature');
        }
    }

    // Parse chunks
    let pos = 8;
    while (pos < png.length) {
        if (pos + 12 > png.length) break;

        const view = new DataView(pngBuffer, pos, 8);
        const length = view.getUint32(0, false); // big-endian
        const type = new TextDecoder().decode(png.subarray(pos + 4, pos + 8));

        if (type === PNGB_CHUNK_TYPE) {
            const data = png.subarray(pos + 8, pos + 8 + length);
            return await parsePngbChunk(data);
        }

        pos += 12 + length; // length + type + data + crc
    }

    throw new Error('No pNGb chunk found in PNG');
}

/**
 * Parse pNGb chunk data and decompress if needed.
 */
async function parsePngbChunk(data) {
    if (data.length < 2) {
        throw new Error('Invalid pNGb chunk: too short');
    }

    const version = data[0];
    const flags = data[1];
    const payload = data.subarray(2);

    if (version !== PNGB_VERSION) {
        throw new Error(`Unsupported pNGb version: ${version}`);
    }

    const isCompressed = (flags & FLAG_COMPRESSED) !== 0;

    if (isCompressed) {
        // Decompress using browser API
        const ds = new DecompressionStream('gzip');
        const blob = new Blob([payload]);
        const decompressed = await new Response(
            blob.stream().pipeThrough(ds)
        ).arrayBuffer();
        return new Uint8Array(decompressed);
    } else {
        return payload;
    }
}

/**
 * Check if a PNG contains embedded PNGine bytecode.
 */
export function hasPngb(pngBuffer) {
    try {
        const png = new Uint8Array(pngBuffer);
        let pos = 8;
        while (pos < png.length) {
            if (pos + 12 > png.length) break;
            const type = new TextDecoder().decode(png.subarray(pos + 4, pos + 8));
            if (type === PNGB_CHUNK_TYPE) return true;
            const length = new DataView(pngBuffer, pos, 4).getUint32(0, false);
            pos += 12 + length;
        }
    } catch (e) {
        return false;
    }
    return false;
}
```

### Updated `web/pngine-loader.js`

```javascript
import { PNGineGPU } from './pngine-gpu.js';
import { extractPngb, hasPngb } from './pngine-png.js';

// ... existing code ...

/**
 * Initialize PNGine from a PNG file with embedded bytecode.
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string|ArrayBuffer} pngSource - URL to PNG or raw PNG data
 * @param {string} wasmUrl - URL to pngine.wasm file
 * @returns {Promise<PNGine>} Initialized PNGine instance with loaded module
 */
export async function initFromPng(canvas, pngSource, wasmUrl = 'pngine.wasm') {
    // Initialize base PNGine
    const pngine = await initPNGine(canvas, wasmUrl);

    // Load PNG data
    let pngBuffer;
    if (typeof pngSource === 'string') {
        const response = await fetch(pngSource);
        if (!response.ok) {
            throw new Error(`Failed to fetch PNG: ${response.status}`);
        }
        pngBuffer = await response.arrayBuffer();
    } else {
        pngBuffer = pngSource;
    }

    // Extract and load bytecode
    const bytecode = await extractPngb(pngBuffer);
    pngine.loadModule(bytecode);

    return pngine;
}
```

---

## Unified API: `web/pngine.js`

```javascript
/**
 * PNGine - WebGPU Bytecode Engine
 *
 * Unified API for loading and running PNGine content.
 */

import { initPNGine, initFromPng, PNGine, ErrorCode } from './pngine-loader.js';
import { extractPngb, hasPngb } from './pngine-png.js';

export { initPNGine, initFromPng, PNGine, ErrorCode, extractPngb, hasPngb };

/**
 * Run a PNGine shader from a PNG file.
 *
 * Simple one-liner for embedding in web pages:
 *
 *   <canvas id="shader"></canvas>
 *   <script type="module">
 *     import { run } from './pngine.js';
 *     run(document.getElementById('shader'), 'shader.png');
 *   </script>
 *
 * @param {HTMLCanvasElement} canvas - Canvas element for rendering
 * @param {string} pngUrl - URL to PNG with embedded bytecode
 * @param {Object} options - Optional configuration
 * @param {string} options.wasmUrl - URL to pngine.wasm (default: 'pngine.wasm')
 * @param {boolean} options.animate - Start animation loop (default: true)
 * @returns {Promise<{pngine: PNGine, stop: Function}>} Controller object
 */
export async function run(canvas, pngUrl, options = {}) {
    const { wasmUrl = 'pngine.wasm', animate = true } = options;

    const pngine = await initFromPng(canvas, pngUrl, wasmUrl);

    // Find uniform buffer for time updates
    const uniformBufferId = pngine.findUniformBuffer();

    let running = animate;
    let startTime = performance.now();

    function frame() {
        if (!running) return;

        const time = (performance.now() - startTime) / 1000;

        if (uniformBufferId !== null) {
            pngine.writeTimeUniform(uniformBufferId, time);
        }

        pngine.executeAll();
        requestAnimationFrame(frame);
    }

    if (animate) {
        requestAnimationFrame(frame);
    }

    return {
        pngine,
        stop() {
            running = false;
        },
        start() {
            if (!running) {
                running = true;
                startTime = performance.now();
                requestAnimationFrame(frame);
            }
        },
        setTime(t) {
            startTime = performance.now() - t * 1000;
        }
    };
}
```

---

## Size Optimization Techniques

### 1. Compression Thresholds

| Bytecode Size | Action |
|--------------|--------|
| < 256 bytes | No compression (gzip overhead) |
| 256 - 4KB | Gzip level 6 (balanced) |
| > 4KB | Gzip level 9 (max compression) |

### 2. Shader Minification (Future)

Before embedding, minify WGSL:
- Remove comments
- Shorten variable names
- Remove unnecessary whitespace
- Inline small functions

### 3. Preview Image Optimization

For optimal file size, recommend:
- Small preview (256x256 or 512x512)
- 8-bit color depth (no alpha if not needed)
- Indexed color if < 256 unique colors
- High PNG compression level

### 4. Combined Size Targets

| Content | Typical Size |
|---------|-------------|
| Simple triangle | ~400 bytes bytecode |
| Basic shader | ~1-2 KB bytecode |
| Complex shader | ~5-10 KB bytecode |
| Preview image | ~10-50 KB |
| **Total PNG** | **~15-60 KB** |

---

## Testing Strategy

### Unit Tests (Zig)

```zig
test "CRC-32 matches known values" {
    // Test vectors from PNG spec
    try expectEqual(crc32.crc32("IEND"), 0xAE426082);
}

test "embed/extract roundtrip" {
    const bytecode = // ... test PNGB
    const png = // ... minimal valid PNG

    const embedded = try embed.embed(allocator, png, bytecode);
    defer allocator.free(embedded);

    const extracted = try extract.extract(allocator, embedded);
    defer allocator.free(extracted);

    try expectEqualSlices(u8, bytecode, extracted);
}

test "compression applied for large bytecode" {
    // Generate >256 byte bytecode
    // Verify compressed flag is set
}

test "compression skipped for small bytecode" {
    // Generate <256 byte bytecode
    // Verify raw storage
}
```

### Integration Tests (CLI)

```bash
# Test embed command
pngine compile triangle.pngine -o triangle.pngb
pngine embed triangle.pngb preview.png -o triangle.png
pngine extract triangle.png -o extracted.pngb
diff triangle.pngb extracted.pngb

# Test direct source embedding
pngine embed triangle.pngine preview.png -o triangle.png
pngine check triangle.png
```

### Browser Tests (JavaScript)

```javascript
// Test extraction
const png = await fetch('test.png').then(r => r.arrayBuffer());
const bytecode = await extractPngb(png);
assert(bytecode.length > 0);
assert(bytecode[0] === 0x50); // 'P' in PNGB magic

// Test full run
const canvas = document.createElement('canvas');
const controller = await run(canvas, 'test.png');
assert(controller.pngine !== null);
controller.stop();
```

---

## Implementation Order

### Phase 1: Core PNG Module (Zig)
1. `src/png/crc32.zig` - CRC-32 implementation
2. `src/png/chunk.zig` - PNG chunk parsing
3. `src/png/embed.zig` - Embedding logic
4. `src/png/extract.zig` - Extraction logic
5. Unit tests for all modules

### Phase 2: CLI Integration
1. Add `embed` command to `cli.zig`
2. Add `extract` command to `cli.zig`
3. Update `check` command to support `.png` files
4. Integration tests

### Phase 3: JavaScript Loader
1. `web/pngine-png.js` - PNG extraction
2. Update `web/pngine-loader.js` - `initFromPng()`
3. `web/pngine.js` - Unified API with `run()`
4. Browser tests

### Phase 4: Documentation & Polish
1. Update README with PNG embedding usage
2. Add examples/
3. Performance benchmarks
4. Size comparison table

---

## Success Criteria

1. **Functionality**
   - [ ] Embed PNGB into any valid PNG
   - [ ] Extract PNGB from embedded PNG
   - [ ] Roundtrip preserves exact bytecode
   - [ ] Browser can load and run embedded PNG

2. **Size**
   - [ ] pNGb chunk overhead < 20 bytes
   - [ ] Compression reduces shader bytecode by >2x
   - [ ] Example shader.png < 50KB total

3. **API**
   - [ ] Single-line JS API: `run(canvas, 'shader.png')`
   - [ ] CLI: `pngine embed src.pngine img.png -o out.png`
   - [ ] Seamless with existing PNGB workflow

4. **Compatibility**
   - [ ] PNG valid after embedding (passes PNG validators)
   - [ ] Standard image viewers display preview
   - [ ] Works in Chrome, Firefox, Safari
