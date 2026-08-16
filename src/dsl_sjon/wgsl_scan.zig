//! Canonical WGSL entry-point / feature scan for the SJON host. (Originally
//! vendored from the legacy `dsl` emitter; that tree was deleted at the SJON
//! cutover, so this is now the single source. See CONTRIBUTING §17.)
//!
//! WGSL Entry Point Scanner
//!
//! Scans WGSL source code for entry point annotations without full parsing.
//! Extracts @fragment and @compute entry points with workgroup sizes.
//!
//! ## Design
//!
//! Uses simple pattern matching on WGSL annotations:
//! - `@fragment fn NAME(` → fragment entry point
//! - `@compute @workgroup_size(X[,Y[,Z]]) fn NAME(` → compute entry point
//!
//! No full WGSL parser — just annotation scanning (same approach as compute.toys).
//!
//! ## Invariants
//!
//! - Scan is O(n) where n = source length
//! - Entry points are returned in source order
//! - Workgroup sizes default to 1 for omitted dimensions
//! - Maximum 16 entry points per scan

const std = @import("std");

/// Maximum entry points to extract from a single code block.
const MAX_ENTRY_POINTS: u32 = 16;

/// Entry point type detected from WGSL annotations.
pub const EntryPointType = enum {
    fragment,
    compute,
};

/// Extracted entry point information.
pub const EntryPoint = struct {
    /// Function name (e.g., "main_image", "physics", "seed").
    name: []const u8,
    /// Whether this is a fragment or compute entry point.
    type: EntryPointType,
    /// Workgroup size for compute shaders [X, Y, Z].
    /// Defaults to [1, 1, 1]. Only meaningful for compute.
    workgroup_size: [3]u32,
    /// False when `@workgroup_size(…)` held something this scanner cannot read —
    /// a const identifier, an expression, or a zero/overflowing dimension. The
    /// dimensions above are then the DEFAULT, not the shader's, so a caller that
    /// dispatches on them dispatches the wrong grid. Fragment entries are always
    /// `true` (they have no workgroup size to get wrong).
    workgroup_known: bool = true,
};

/// Scan result from WGSL source analysis.
pub const ScanResult = struct {
    /// Extracted entry points in source order.
    entries: [MAX_ENTRY_POINTS]EntryPoint,
    /// Number of valid entries.
    count: u32,
    /// Whether any @fragment entry points were found.
    has_fragment: bool,
    /// Whether any @compute entry points were found.
    has_compute: bool,
    /// The source held MORE than `MAX_ENTRY_POINTS` entry points and the scan
    /// stopped early, so `entries` is a PREFIX and `has_fragment`/`has_compute`
    /// describe only that prefix. A caller must not treat a truncated scan as a
    /// complete picture: `(pass …)` lowering builds one compute pipeline+pass per
    /// entry, so silently honouring a prefix drops whole passes, and a kind that
    /// appears only past the cap flips the fragment-vs-compute classification.
    truncated: bool,

    pub fn slice(self: *const ScanResult) []const EntryPoint {
        return self.entries[0..self.count];
    }

    /// Store one entry point, or flag the result truncated when the fixed buffer
    /// is full. Overflow is an entry point that could not be STORED — not a full
    /// buffer with source left to scan, which is the ordinary shape of a shader
    /// holding exactly MAX_ENTRY_POINTS entries followed by a newline.
    fn record(self: *ScanResult, e: EntryPoint) void {
        if (self.count >= MAX_ENTRY_POINTS) {
            self.truncated = true;
            return;
        }
        self.entries[self.count] = e;
        self.count += 1;
    }
};

/// Scan WGSL source for entry point annotations.
///
/// Returns extracted entry points in source order.
/// Does not allocate — uses fixed-size result buffer.
///
/// Complexity: O(n) where n = source.len
pub fn scanEntryPoints(source: []const u8) ScanResult {
    var result = ScanResult{
        .entries = undefined,
        .count = 0,
        .has_fragment = false,
        .has_compute = false,
        .truncated = false,
    };

    var i: u32 = 0;
    const len: u32 = @intCast(source.len);

    // Scans to the end even once the buffer is full: stopping early cannot tell
    // "exactly MAX_ENTRY_POINTS entries" from "more than that", and `truncated`
    // is only meaningful if overflow is actually observed. Still O(n).
    while (i < len) {
        // Trivia first: an `@fragment` inside a comment is not an entry point.
        // Either this advances (and we re-test bounds) or we fall through and
        // advance below, so the loop always makes progress.
        const after_trivia = skipTrivia(source, i);
        if (after_trivia != i) {
            i = after_trivia;
            continue;
        }

        // Look for '@' character
        if (source[i] != '@') {
            i += 1;
            continue;
        }

        // Try @fragment
        if (matchAt(source, i, "@fragment")) {
            const after_attr = i + @as(u32, @intCast("@fragment".len));
            if (findFnName(source, after_attr)) |name| {
                result.record(.{
                    .name = name,
                    .type = .fragment,
                    .workgroup_size = .{ 1, 1, 1 },
                });
                // Set from the entry point being FOUND, not stored: a kind that
                // appears only past the cap is still present in the shader.
                result.has_fragment = true;
            }
            i = after_attr;
            continue;
        }

        // Try @compute
        if (matchAt(source, i, "@compute")) {
            const after_compute = i + @as(u32, @intCast("@compute".len));
            // Look for @workgroup_size after @compute
            const wg_pos = findNextAnnotation(source, after_compute, "@workgroup_size(");
            if (wg_pos) |wg_start| {
                const wg_args_start = wg_start + @as(u32, @intCast("@workgroup_size(".len));
                const wg_size = parseWorkgroupSize(source, wg_args_start);
                // Find the fn name after workgroup_size
                const after_wg = findCloseParen(source, wg_args_start);
                if (after_wg) |after| {
                    if (findFnName(source, after)) |name| {
                        result.record(.{
                            .name = name,
                            .type = .compute,
                            .workgroup_size = wg_size.size,
                            .workgroup_known = wg_size.known,
                        });
                        result.has_compute = true;
                    }
                }
                i = wg_args_start;
            } else {
                i = after_compute;
            }
            continue;
        }

        i += 1;
    }

    // post: the fixed buffer was never overrun, and `truncated` is the only way
    // a caller can learn that entries were dropped.
    std.debug.assert(result.count <= MAX_ENTRY_POINTS);
    for (result.slice()) |e| {
        // post: every name is a slice OF `source`, not a dangling or shifted
        // view. An off-by-one in findFnName would otherwise reach bytecode as a
        // silently wrong entry-point string.
        std.debug.assert(e.name.len > 0);
        std.debug.assert(@intFromPtr(e.name.ptr) >= @intFromPtr(source.ptr));
        std.debug.assert(@intFromPtr(e.name.ptr) + e.name.len <=
            @intFromPtr(source.ptr) + source.len);
        // post: a usable compute size is >= 1 per axis — `hooks.getDispatchSize`
        // divides by it. Unusable sizes are reported, not repaired.
        if (e.workgroup_known) {
            std.debug.assert(e.workgroup_size[0] > 0);
            std.debug.assert(e.workgroup_size[1] > 0);
            std.debug.assert(e.workgroup_size[2] > 0);
        }
    }

    return result;
}

/// Check if `pattern` matches at position `pos` in `source`.
fn matchAt(source: []const u8, pos: u32, pattern: []const u8) bool {
    const end = pos + @as(u32, @intCast(pattern.len));
    if (end > source.len) return false;
    return std.mem.eql(u8, source[pos..end], pattern);
}

/// Find the next occurrence of `pattern` starting from `start`,
/// skipping whitespace. Returns position of pattern start, or null.
fn findNextAnnotation(source: []const u8, start: u32, pattern: []const u8) ?u32 {
    // Trivia, not just whitespace: `@compute /* n */ @workgroup_size(8)` is legal.
    const i = skipTrivia(source, start);
    if (matchAt(source, i, pattern)) return i;
    return null;
}

/// Find 'fn NAME(' pattern starting from `start`, skipping whitespace/annotations.
/// Returns the function name slice, or null.
fn findFnName(source: []const u8, start: u32) ?[]const u8 {
    var i = start;
    const len: u32 = @intCast(source.len);

    // Skip whitespace and additional annotations (like @workgroup_size)
    var skip_count: u32 = 0;
    while (i < len and skip_count < 256) : (skip_count += 1) {
        // Skip whitespace and comments
        i = skipTrivia(source, i);

        // Skip annotations we don't care about
        if (i < len and source[i] == '@') {
            // Skip past the annotation
            i += 1;
            while (i < len and (isIdentChar(source[i]) or source[i] == '(')) {
                if (source[i] == '(') {
                    // Skip past balanced parens
                    i = findCloseParen(source, i + 1) orelse return null;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Look for 'fn'
        if (matchAt(source, i, "fn") and i + 2 < len and isWhitespace(source[i + 2])) {
            i += 2;
            // Skip trivia after 'fn'
            i = skipTrivia(source, i);
            // Extract name
            const name_start = i;
            while (i < len and isIdentChar(source[i])) : (i += 1) {}
            if (i > name_start) {
                return source[name_start..i];
            }
            return null;
        }

        break;
    }

    return null;
}

/// A `@workgroup_size(…)` argument list, and whether this scanner could read it.
///
/// `known == false` means the dimensions are NOT usable — the caller must refuse
/// the shader rather than fall back to `size`. See `parseWorkgroupSize`.
pub const WorkgroupSize = struct {
    size: [3]u32,
    known: bool,
};

/// Parse a WGSL integer literal: decimal or `0x` hex, with an optional `u`/`i`
/// suffix. Returns the value and the position after it, or null when `start`
/// does not begin a literal.
///
/// The suffix forms are why this exists rather than a bare `parseInt` over a
/// digit run: `@workgroup_size(64u)` is the idiomatic spelling, and a digit-only
/// reader stops at the `u` without consuming it (§325).
fn parseIntLiteral(source: []const u8, start: u32) ?struct { value: u64, end: u32 } {
    const len: u32 = @intCast(source.len);
    var i = start;
    var value: u64 = 0;
    var digits: u32 = 0;

    const hex = i + 1 < len and source[i] == '0' and (source[i + 1] == 'x' or source[i + 1] == 'X');
    if (hex) i += 2;

    while (i < len) : (i += 1) {
        const d: u64 = switch (source[i]) {
            '0'...'9' => source[i] - '0',
            'a'...'f' => if (hex) source[i] - 'a' + 10 else break,
            'A'...'F' => if (hex) source[i] - 'A' + 10 else break,
            else => break,
        };
        // Refuse rather than wrap: a wrapped workgroup size is a wrong dispatch
        // grid, and the caller can only act on `known`.
        if (value > (std.math.maxInt(u64) - d) / 16) return null;
        value = value * (if (hex) @as(u64, 16) else 10) + d;
        digits += 1;
    }
    if (digits == 0) return null;

    // Optional abstract-int suffix.
    if (i < len and (source[i] == 'u' or source[i] == 'i')) i += 1;
    return .{ .value = value, .end = i };
}

/// Parse `workgroup_size(X[,Y[,Z]])` arguments. `start` points at the first char
/// after the opening '('.
///
/// Every argument must be an integer literal. WGSL also allows const-expressions
/// (`@workgroup_size(WG)`, `@workgroup_size(8 * 8)`), which cannot be resolved
/// without const-evaluating the module — so those return `known = false` and the
/// caller refuses the pass. That is the honest answer: the previous reader
/// silently produced `1` for them, which is a wrong dispatch grid, and got there
/// via a loop that did not advance (§325).
fn parseWorkgroupSize(source: []const u8, start: u32) WorkgroupSize {
    var out = WorkgroupSize{ .size = .{ 1, 1, 1 }, .known = true };
    var i = start;
    const len: u32 = @intCast(source.len);

    // Bounded by the argument count, not by the source: three dimensions plus the
    // closing paren is every legal shape, and each pass consumes one argument.
    for (0..3) |dim| {
        i = skipTrivia(source, i);
        if (i >= len) return .{ .size = out.size, .known = false }; // unterminated
        if (source[i] == ')') return out; // omitted dims stay 1

        const lit = parseIntLiteral(source, i) orelse
            return .{ .size = out.size, .known = false }; // identifier / expression
        // WGSL requires each dimension >= 1. Zero is what divided by zero in
        // `hooks.getDispatchSize`, so it never leaves this function as "known".
        if (lit.value == 0 or lit.value > std.math.maxInt(u32)) {
            return .{ .size = out.size, .known = false };
        }
        out.size[dim] = @intCast(lit.value);
        i = skipTrivia(source, lit.end);

        if (i >= len) return .{ .size = out.size, .known = false };
        if (source[i] == ')') return out;
        if (source[i] != ',') return .{ .size = out.size, .known = false }; // `8 * 8`
        i += 1;
    }

    // Three parsed dimensions: the next non-trivia char must close the list.
    i = skipTrivia(source, i);
    if (i < len and source[i] == ')') return out;
    return .{ .size = out.size, .known = false };
}

/// Find the position after the matching close paren.
/// `start` points to first char after opening '('.
fn findCloseParen(source: []const u8, start: u32) ?u32 {
    var i = start;
    const len: u32 = @intCast(source.len);
    var depth: u32 = 1;

    while (i < len and depth > 0) {
        // A paren inside a comment closes nothing — `@workgroup_size(8 /* ) */)`.
        const after_trivia = skipTrivia(source, i);
        if (after_trivia != i) {
            i = after_trivia;
            continue;
        }
        if (source[i] == '(') depth += 1;
        if (source[i] == ')') depth -= 1;
        i += 1;
    }

    return if (depth == 0) i else null;
}

/// Advance past whitespace and comments, returning the first position that is
/// neither. Idempotent, and never moves backwards.
///
/// WGSL block comments **nest** (unlike C), so `/* /* */ */` is one comment and a
/// depth counter is required — matching wgslender's lexer, which is the engine
/// that decides whether the same source compiles at all.
///
/// Every entry point this scanner reports is found by looking for `@` at a
/// position no trivia covers, so this function is the whole of the scanner's
/// comment blindness fix: commenting out an entry point while iterating is the
/// most common thing a shader author does, and it used to be scanned as real.
fn skipTrivia(source: []const u8, start: u32) u32 {
    const len: u32 = @intCast(source.len);
    var i = start;

    // Each iteration consumes at least one byte, so this terminates at `len`.
    while (i < len) {
        if (isWhitespace(source[i])) {
            i += 1;
            continue;
        }
        if (i + 1 >= len or source[i] != '/') break;

        if (source[i + 1] == '/') {
            i += 2;
            while (i < len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (source[i + 1] == '*') {
            i += 2;
            var depth: u32 = 1;
            while (i < len and depth > 0) {
                if (i + 1 < len and source[i] == '/' and source[i + 1] == '*') {
                    depth += 1;
                    i += 2;
                } else if (i + 1 < len and source[i] == '*' and source[i + 1] == '/') {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            // An unterminated block comment swallows the rest of the source,
            // which is also what the compiler will do with it.
            continue;
        }
        break; // a lone '/' is division
    }

    std.debug.assert(i >= start); // post: never rewinds
    std.debug.assert(i <= len);
    return i;
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ============================================================================
// Tests
// ============================================================================

// ---------------------------------------------------------------------------
// Comments (§325)
//
// Commenting an entry point out while iterating is the most common edit a
// shader author makes, and every case below used to be scanned as a live entry
// point — which picks the pass KIND, so the lowering produced a structurally
// different program.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Workgroup-size literal forms (§325)
//
// The digit-only reader terminated only on a bare decimal. Every other legal
// spelling below either HUNG the compiler (the loop advanced neither `i` nor
// `dim`) or, for `0`, reached a division by zero in hooks.getDispatchSize.
// ---------------------------------------------------------------------------
