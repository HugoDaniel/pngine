//! Bytecode loading for the inspect command.
//!
//! One format-dispatching loader shared by both inspect modes — the MockGPU
//! summary path and the deep/WAMR path. `.pngb` is read directly, `.png`/`.zip`
//! extract their embedded bytecode, and `.sjon` is compiled through the standard
//! base_dir-aware compile path. Errors propagate raw; each caller maps them to
//! its own messages/exit codes.
//!
//! `-` reads stdin and takes its kind from the bytes instead of a name, which
//! is what makes `pngine extract art.png | pngine inspect -` work: the middle
//! of a pipeline has no filename to dispatch on.

const std = @import("std");
const pngine = @import("pngine");
const stdio = @import("../stdio.zig");
const compile = @import("../compile.zig");
const bundle = @import("../bundle.zig");
const test_utils = @import("../../test_utils.zig");

/// Load bytecode from a file, or from stdin when `path` is `-`.
///
/// - `.pngb` → read directly
/// - `.png`  → extract embedded pNGb chunk
/// - `.zip`  → extract bytecode from the bundle
/// - `.sjon` → compile (base_dir = the source file's directory)
/// - `-`     → whichever of the four the leading bytes say it is
///
/// Pre-condition: path is non-empty
/// Post-condition: Returns owned bytecode slice (caller must free)
pub fn loadBytecode(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);

    const in = try stdio.readInput(allocator, io, path);
    defer in.deinit(allocator);

    return switch (in.kind) {
        // Already bytecode: hand back an owned copy, since `in` frees its own.
        .pngb => allocator.dupe(u8, in.bytes),
        .png => pngine.png.extractBytecode(allocator, in.bytes),
        .zip => bundle.extractFromZip(allocator, in.bytes),
        // base_dir resolves any relative file references in the source; for
        // stdin that is the cwd (stdio.baseDir).
        .sjon => compile.compileSource(allocator, io, path, in.bytes),
    };
}

// ============================================================================
// Tests
// ============================================================================
//
// These pin the dispatch skeleton. The `.png` / `.zip` / `.sjon` branches
// delegate to already-tested primitives (png.extractBytecode, bundle
// extraction, the compile facade) and are exercised end-to-end by the inspect
// command's own test suite.
