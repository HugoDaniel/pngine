//! Minimal WASM binary parser for data WASM files.
//!
//! Extracts export information needed to create GPU storage buffers:
//! - `l` (i32 global): byte length of data
//! - `s` (i32 global): start offset in memory (default 0)
//! - `gen` (function): whether a generator function exists
//!
//! Only parses Global (0x06) and Export (0x07) sections.
//!
//! ## Invariants
//! - `l`/`s` must resolve to a PARSED, i32-const, non-negative global within
//!   the first `MAX_GLOBALS` — anything else returns null (a reject at the
//!   caller), never a silent 0 length / 0 offset and never an OOB read.
//! - Every inner read is bounded to its section; section sizes are
//!   authoritative (the parse resyncs to `section_end` unconditionally).

const std = @import("std");

/// Parse window for the Global section. Data WASM files carry 2 globals
/// (`l`, `s`); 64 leaves generous headroom for toolchain-added extras.
const MAX_GLOBALS = 64;

pub const WasmDataInfo = struct {
    byte_length: u32,
    start_offset: u32 = 0,
    has_gen: bool = false,
};

/// Parse a WASM binary to extract data info from exports.
/// Returns null if the WASM is invalid, missing the required `l` export, or
/// `l`/`s` cannot be resolved to a non-negative i32-const global — a reject
/// beats the silent zero-length buffer / wrong-offset write those cases
/// previously produced.
pub fn parseWasmDataInfo(wasm: []const u8) ?WasmDataInfo {
    // Validate magic + version
    if (wasm.len < 8) return null;
    if (!std.mem.eql(u8, wasm[0..4], "\x00asm")) return null;

    // null = declared but unresolvable (non-i32-const init, truncated entry):
    // an export pointing at one rejects instead of reading 0 or garbage.
    var globals: [MAX_GLOBALS]?i32 = @splat(null);
    var parsed_count: u32 = 0; // entries actually visited (≤ MAX_GLOBALS)

    var export_l: ?u32 = null; // global index for 'l'
    var export_s: ?u32 = null; // global index for 's'
    var has_gen = false;

    var pos: usize = 8;
    while (pos < wasm.len) {
        const section_id = wasm[pos];
        pos += 1;
        const section_size = readLeb128(wasm, &pos) orelse break;
        const section_end = pos + section_size;
        if (section_end > wasm.len) break;
        // Bound every inner read to THIS section: a truncated or lying entry
        // can never bleed into the next section's bytes.
        const sec = wasm[0..section_end];

        if (section_id == 0x06) {
            // Global section
            const declared = readLeb128(sec, &pos) orelse break;
            for (0..@min(declared, MAX_GLOBALS)) |i| {
                if (pos + 2 > sec.len) break;
                _ = sec[pos]; // valtype
                _ = sec[pos + 1]; // mutability
                pos += 2;
                // Parse init expression (null for non-i32-const forms)
                globals[i] = parseI32ConstExpr(sec, &pos);
                parsed_count += 1;
            }
        } else if (section_id == 0x07) {
            // Export section
            const count = readLeb128(sec, &pos) orelse break;
            for (0..count) |_| {
                const name_len = readLeb128(sec, &pos) orelse break;
                if (pos + name_len > sec.len) break;
                const name = sec[pos..][0..name_len];
                pos += name_len;
                if (pos >= sec.len) break;
                const kind = sec[pos];
                pos += 1;
                const index = readLeb128(sec, &pos) orelse break;

                if (kind == 0x03) {
                    // Global export
                    if (name.len == 1 and name[0] == 'l') export_l = index;
                    if (name.len == 1 and name[0] == 's') export_s = index;
                } else if (kind == 0x00) {
                    // Function export
                    if (name.len == 3 and std.mem.eql(u8, name, "gen")) has_gen = true;
                }
            }
        }
        // Section sizes are authoritative — resync unconditionally so a
        // desynced inner parse can't cascade into the following sections.
        pos = section_end;
    }
    std.debug.assert(parsed_count <= MAX_GLOBALS);

    // 'l' export is required; 's' is optional but must resolve when present.
    const l_idx = export_l orelse return null;
    const byte_length = resolveGlobal(&globals, parsed_count, l_idx) orelse return null;
    var info = WasmDataInfo{
        .byte_length = byte_length,
        .has_gen = has_gen,
    };
    if (export_s) |s_idx| {
        info.start_offset = resolveGlobal(&globals, parsed_count, s_idx) orelse return null;
    }
    return info;
}

/// Resolve an exported global index to a non-negative i32-const value, or
/// null: past the parsed entries (covers indices beyond the `MAX_GLOBALS`
/// window and truncated Global sections — previously an OOB/undefined read),
/// an unresolvable init expression (previously a silent 0), or a negative
/// value (a `@bitCast` would turn -1 into a ~4 GiB buffer request).
fn resolveGlobal(globals: *const [MAX_GLOBALS]?i32, parsed_count: u32, idx: u32) ?u32 {
    std.debug.assert(parsed_count <= globals.len);
    if (idx >= parsed_count) return null;
    const val = globals[idx] orelse return null;
    if (val < 0) return null;
    return @intCast(val);
}

/// Read a LEB128-encoded u32 value.
fn readLeb128(data: []const u8, pos: *usize) ?u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        result |= @as(u32, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift +%= 7;
        if (shift > 28) return null; // overflow
    }
    return null;
}

/// Read a signed LEB128-encoded i32 value.
fn readSignedLeb128(data: []const u8, pos: *usize) ?i32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    var last_byte: u8 = 0;
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        last_byte = byte;
        result |= @as(u32, byte & 0x7F) << shift;
        shift +%= 7;
        if (byte & 0x80 == 0) {
            // Sign extend if high bit of last byte is set
            if (shift < 32 and (last_byte & 0x40) != 0) {
                result |= @as(u32, 0xFFFFFFFF) << shift;
            }
            return @bitCast(result);
        }
        if (shift > 28) return null;
    }
    return null;
}

/// Parse an i32.const init expression: [0x41][i32 LEB128][0x0B].
/// Non-i32-const forms (i64/f32/f64.const, global.get) are skipped with
/// their exact operand width and return null — the caller records the global
/// as unresolvable WITHOUT desyncing the entries that follow (an f32/f64
/// payload byte can legally be 0x0B, so a blind hunt for the end marker
/// would stop mid-operand and corrupt every later global's parse).
fn parseI32ConstExpr(data: []const u8, pos: *usize) ?i32 {
    if (pos.* >= data.len) return null;
    const opcode = data[pos.*];
    pos.* += 1;
    switch (opcode) {
        0x41 => { // i32.const
            if (readSignedLeb128(data, pos)) |value| {
                if (pos.* < data.len and data[pos.*] == 0x0B) pos.* += 1; // end
                return value;
            }
            // Over-long/truncated LEB: fall through to the end-marker hunt.
        },
        0x42 => skipLeb128(data, pos), // i64.const
        0x43 => pos.* = @min(pos.* + 4, data.len), // f32.const (4 raw bytes)
        0x44 => pos.* = @min(pos.* + 8, data.len), // f64.const (8 raw bytes)
        0x23 => skipLeb128(data, pos), // global.get
        else => {},
    }
    // Skip to the end marker (for the known forms above it IS the next byte).
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        if (byte == 0x0B) break;
    }
    return null;
}

/// Skip one LEB128-encoded value of any width (payload bits ignored).
fn skipLeb128(data: []const u8, pos: *usize) void {
    while (pos.* < data.len) {
        const byte = data[pos.*];
        pos.* += 1;
        if (byte & 0x80 == 0) break;
    }
}

// ============================================================================
// Tests
// ============================================================================

/// Append one section (id + LEB128 size + payload) to a test WASM under build.
fn appendSection(buf: *std.ArrayList(u8), a: std.mem.Allocator, id: u8, payload: []const u8) !void {
    try buf.append(a, id);
    var size_buf: [5]u8 = undefined;
    const n = writeLeb128(&size_buf, @intCast(payload.len));
    try buf.appendSlice(a, size_buf[0..n]);
    try buf.appendSlice(a, payload);
}

/// Build a test WASM binary with l, s globals and optional gen function.
fn buildTestWasm(byte_length: u32, start_offset: u32, has_gen: bool) [128]u8 {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;

    // Magic + version
    @memcpy(buf[pos..][0..8], "\x00asm\x01\x00\x00\x00");
    pos += 8;

    if (has_gen) {
        // Type section (0x01): one function type () -> ()
        buf[pos] = 0x01; // section id
        pos += 1;
        buf[pos] = 0x04; // section size
        pos += 1;
        buf[pos] = 0x01; // 1 type
        pos += 1;
        buf[pos] = 0x60; // func
        pos += 1;
        buf[pos] = 0x00; // 0 params
        pos += 1;
        buf[pos] = 0x00; // 0 results
        pos += 1;

        // Function section (0x03): one function, type 0
        buf[pos] = 0x03;
        pos += 1;
        buf[pos] = 0x02; // size
        pos += 1;
        buf[pos] = 0x01; // 1 function
        pos += 1;
        buf[pos] = 0x00; // type index 0
        pos += 1;
    }

    // Memory section (0x05): 1 page
    buf[pos] = 0x05;
    pos += 1;
    buf[pos] = 0x03; // size
    pos += 1;
    buf[pos] = 0x01; // 1 memory
    pos += 1;
    buf[pos] = 0x00; // no max
    pos += 1;
    buf[pos] = 0x01; // 1 page
    pos += 1;

    // Global section (0x06): l and s globals
    buf[pos] = 0x06; // section id
    pos += 1;
    // Encode globals into a temp buffer to know section size
    var global_buf: [32]u8 = undefined;
    var gp: usize = 0;
    global_buf[gp] = 0x02; // 2 globals
    gp += 1;
    // Global 0: l (i32, immutable)
    global_buf[gp] = 0x7F; // i32
    gp += 1;
    global_buf[gp] = 0x00; // immutable
    gp += 1;
    global_buf[gp] = 0x41; // i32.const
    gp += 1;
    gp += writeLeb128(global_buf[gp..], byte_length);
    global_buf[gp] = 0x0B; // end
    gp += 1;
    // Global 1: s (i32, immutable)
    global_buf[gp] = 0x7F; // i32
    gp += 1;
    global_buf[gp] = 0x00; // immutable
    gp += 1;
    global_buf[gp] = 0x41; // i32.const
    gp += 1;
    gp += writeLeb128(global_buf[gp..], start_offset);
    global_buf[gp] = 0x0B; // end
    gp += 1;

    buf[pos] = @intCast(gp); // section size
    pos += 1;
    @memcpy(buf[pos..][0..gp], global_buf[0..gp]);
    pos += gp;

    // Export section (0x07)
    buf[pos] = 0x07;
    pos += 1;
    var exp_buf: [64]u8 = undefined;
    var ep: usize = 0;
    const export_count: u8 = if (has_gen) 4 else 3;
    exp_buf[ep] = export_count;
    ep += 1;
    // Export "m" (memory, index 0)
    exp_buf[ep] = 0x01;
    ep += 1; // name len
    exp_buf[ep] = 'm';
    ep += 1;
    exp_buf[ep] = 0x02;
    ep += 1; // memory kind
    exp_buf[ep] = 0x00;
    ep += 1; // index
    // Export "l" (global, index 0)
    exp_buf[ep] = 0x01;
    ep += 1;
    exp_buf[ep] = 'l';
    ep += 1;
    exp_buf[ep] = 0x03;
    ep += 1; // global kind
    exp_buf[ep] = 0x00;
    ep += 1;
    // Export "s" (global, index 1)
    exp_buf[ep] = 0x01;
    ep += 1;
    exp_buf[ep] = 's';
    ep += 1;
    exp_buf[ep] = 0x03;
    ep += 1;
    exp_buf[ep] = 0x01;
    ep += 1;
    // Export "gen" (function, index 0) — optional
    if (has_gen) {
        exp_buf[ep] = 0x03;
        ep += 1; // name len
        @memcpy(exp_buf[ep..][0..3], "gen");
        ep += 3;
        exp_buf[ep] = 0x00;
        ep += 1; // function kind
        exp_buf[ep] = 0x00;
        ep += 1; // index
    }

    buf[pos] = @intCast(ep);
    pos += 1;
    @memcpy(buf[pos..][0..ep], exp_buf[0..ep]);
    pos += ep;

    if (has_gen) {
        // Code section (0x0A): one empty function
        buf[pos] = 0x0A;
        pos += 1;
        buf[pos] = 0x04; // section size
        pos += 1;
        buf[pos] = 0x01; // 1 function body
        pos += 1;
        buf[pos] = 0x02; // body size
        pos += 1;
        buf[pos] = 0x00; // 0 locals
        pos += 1;
        buf[pos] = 0x0B; // end
        pos += 1;
    }

    return buf;
}

/// Widest unsigned LEB128 encoding of a u32: ceil(32 / 7) groups of 7 bits.
const LEB128_U32_BYTES_MAX: usize = 5;

/// Write u32 as unsigned LEB128, return bytes written.
///
/// Requires `LEB128_U32_BYTES_MAX` bytes of room regardless of `value` — the
/// worst case is the only size a caller can size a buffer against without
/// knowing the value, and the unchecked `buf[i]` this replaced wrote past a
/// short slice rather than saying so.
///
/// Complexity: O(1) — at most `LEB128_U32_BYTES_MAX` iterations.
fn writeLeb128(buf: []u8, value: u32) usize {
    std.debug.assert(buf.len >= LEB128_U32_BYTES_MAX);

    var v = value;
    for (0..LEB128_U32_BYTES_MAX) |i| {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            buf[i] = byte;
            // The terminating byte never carries the continuation bit; that is
            // what makes the returned count a whole encoding, not a prefix.
            std.debug.assert(buf[i] & 0x80 == 0);
            return i + 1;
        }
        buf[i] = byte | 0x80;
    }
    // Structurally unreachable: five 7-bit shifts exhaust any u32, so the
    // return above always fires by i == 4. The bound is the TYPE's width, not
    // the input's — see CONTRIBUTING pitfall 49 for why that distinction picks
    // `unreachable` here and a named error elsewhere.
    unreachable;
}
