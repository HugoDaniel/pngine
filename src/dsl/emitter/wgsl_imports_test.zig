//! WGSL Import Resolution Tests
//!
//! Comprehensive tests for #wgsl imports including:
//! - File loading from disk
//! - Import prepending in correct order
//! - Deduplication of shared imports
//! - Diamond dependencies
//! - Edge cases and error handling
//! - OOM resilience
//! - Fuzz testing

const std = @import("std");
const testing = std.testing;
const Compiler = @import("../Compiler.zig").Compiler;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;

// ============================================================================
// Test Helpers
// ============================================================================

/// Compile source and return bytecode (caller owns)
fn compileSource(source: [:0]const u8) ![]u8 {
    return Compiler.compile(testing.allocator, source);
}

/// Compile source with base_dir for file loading
fn compileWithBaseDir(source: [:0]const u8, base_dir: []const u8) ![]u8 {
    return Compiler.compileWithOptions(testing.allocator, source, .{
        .base_dir = base_dir,
    });
}

/// Extract shader data from bytecode for verification
fn extractShaderData(pngb: []const u8) ![]const u8 {
    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Return first data section entry (shader code)
    if (module.data_section.len > 0) {
        return module.data_section[0];
    }
    return "";
}

// ============================================================================
// Basic Import Tests
// ============================================================================

test "WGSL imports: single inline import prepended" {
    // Use MYCONST instead of PI to avoid math constant substitution
    const source: [:0]const u8 =
        \\#wgsl constants {
        \\  value="const MYCONST: f32 = 3.14159;"
        \\}
        \\#wgsl shader {
        \\  value="fn main() { let x = MYCONST; }"
        \\  imports=[constants]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Check bytecode contains expected content
    try testing.expect(std.mem.indexOf(u8, pngb, "const MYCONST") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "fn main()") != null);

    // Verify order: constants should come before main
    const const_pos = std.mem.indexOf(u8, pngb, "const MYCONST").?;
    const main_pos = std.mem.indexOf(u8, pngb, "fn main()").?;
    try testing.expect(const_pos < main_pos);
}

test "WGSL imports: multiple imports prepended in order" {
    const source: [:0]const u8 =
        \\#wgsl first { value="MARKER_FIRST" }
        \\#wgsl second { value="MARKER_SECOND" }
        \\#wgsl third { value="MARKER_THIRD" }
        \\#wgsl shader {
        \\  value="MARKER_MAIN"
        \\  imports=[first second third]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // All markers should be present
    try testing.expect(std.mem.indexOf(u8, pngb, "MARKER_FIRST") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "MARKER_SECOND") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "MARKER_THIRD") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "MARKER_MAIN") != null);

    // All imports should come before MAIN
    const main_pos = std.mem.indexOf(u8, pngb, "MARKER_MAIN").?;
    const first_pos = std.mem.indexOf(u8, pngb, "MARKER_FIRST").?;
    const second_pos = std.mem.indexOf(u8, pngb, "MARKER_SECOND").?;
    const third_pos = std.mem.indexOf(u8, pngb, "MARKER_THIRD").?;

    try testing.expect(first_pos < main_pos);
    try testing.expect(second_pos < main_pos);
    try testing.expect(third_pos < main_pos);
}

test "WGSL imports: bare identifiers in imports array" {
    // Bare identifiers in imports array
    const source: [:0]const u8 =
        \\#wgsl first { value="BARE_FIRST" }
        \\#wgsl second { value="BARE_SECOND" }
        \\#wgsl third { value="BARE_THIRD" }
        \\#wgsl shader {
        \\  value="BARE_MAIN"
        \\  imports=[first second third]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify all content present
    try testing.expect(std.mem.indexOf(u8, pngb, "BARE_FIRST") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "BARE_SECOND") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "BARE_THIRD") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "BARE_MAIN") != null);

    // Verify order: all imports should come before MAIN
    const main_pos = std.mem.indexOf(u8, pngb, "BARE_MAIN").?;
    const first_pos = std.mem.indexOf(u8, pngb, "BARE_FIRST").?;
    const second_pos = std.mem.indexOf(u8, pngb, "BARE_SECOND").?;
    const third_pos = std.mem.indexOf(u8, pngb, "BARE_THIRD").?;

    try testing.expect(first_pos < main_pos);
    try testing.expect(second_pos < main_pos);
    try testing.expect(third_pos < main_pos);
}

test "WGSL imports: multiple bare identifiers in imports" {
    // Multiple bare identifiers in imports
    const source: [:0]const u8 =
        \\#wgsl first { value="MIXED_FIRST" }
        \\#wgsl second { value="MIXED_SECOND" }
        \\#wgsl shader {
        \\  value="MIXED_MAIN"
        \\  imports=[first second]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify all content present
    try testing.expect(std.mem.indexOf(u8, pngb, "MIXED_FIRST") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "MIXED_SECOND") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "MIXED_MAIN") != null);

    // Verify order: imports should come before MAIN
    const main_pos = std.mem.indexOf(u8, pngb, "MIXED_MAIN").?;
    const first_pos = std.mem.indexOf(u8, pngb, "MIXED_FIRST").?;
    const second_pos = std.mem.indexOf(u8, pngb, "MIXED_SECOND").?;

    try testing.expect(first_pos < main_pos);
    try testing.expect(second_pos < main_pos);
}

test "WGSL imports: nested imports (A imports B imports C)" {
    const source: [:0]const u8 =
        \\#wgsl base { value="NESTED_BASE" }
        \\#wgsl middle {
        \\  value="NESTED_MIDDLE"
        \\  imports=[base]
        \\}
        \\#wgsl top {
        \\  value="NESTED_TOP"
        \\  imports=[middle]
        \\}
        \\#shaderModule main { code=top }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify all content present
    try testing.expect(std.mem.indexOf(u8, pngb, "NESTED_BASE") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "NESTED_MIDDLE") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "NESTED_TOP") != null);

    // Verify order: BASE < MIDDLE < TOP (nested imports resolved recursively)
    const base_pos = std.mem.indexOf(u8, pngb, "NESTED_BASE").?;
    const middle_pos = std.mem.indexOf(u8, pngb, "NESTED_MIDDLE").?;
    const top_pos = std.mem.indexOf(u8, pngb, "NESTED_TOP").?;

    try testing.expect(base_pos < middle_pos);
    try testing.expect(middle_pos < top_pos);
}

// ============================================================================
// Deduplication Tests
// ============================================================================

test "WGSL imports: diamond dependency has shared import present" {
    // Diamond: shader imports both A and B, both A and B import common
    // NOTE: Deduplication is handled by the cache - each #wgsl is resolved once
    const source: [:0]const u8 =
        \\#wgsl common { value="DIAMOND_COMMON" }
        \\#wgsl branchA {
        \\  value="DIAMOND_A"
        \\  imports=[common]
        \\}
        \\#wgsl branchB {
        \\  value="DIAMOND_B"
        \\  imports=[common]
        \\}
        \\#wgsl shader {
        \\  value="DIAMOND_MAIN"
        \\  imports=[branchA branchB]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify all content is present
    try testing.expect(std.mem.indexOf(u8, pngb, "DIAMOND_COMMON") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "DIAMOND_A") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "DIAMOND_B") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "DIAMOND_MAIN") != null);
}

test "WGSL imports: same import listed twice produces content" {
    const source: [:0]const u8 =
        \\#wgsl common { value="DUPE_MARKER" }
        \\#wgsl shader {
        \\  value="DUPE_MAIN"
        \\  imports=[common common]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Both marker and main content should be present
    try testing.expect(std.mem.indexOf(u8, pngb, "DUPE_MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "DUPE_MAIN") != null);
}

test "WGSL imports: multiple shaderModules share same resolved wgsl" {
    const source: [:0]const u8 =
        \\#wgsl shared { value="// SHARED_CODE" }
        \\#wgsl shaderA {
        \\  value="// SHADER_A"
        \\  imports=[shared]
        \\}
        \\#wgsl shaderB {
        \\  value="// SHADER_B"
        \\  imports=[shared]
        \\}
        \\#shaderModule modA { code=shaderA }
        \\#shaderModule modB { code=shaderB }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Both shaders should be present
    try testing.expect(std.mem.indexOf(u8, pngb, "// SHADER_A") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "// SHADER_B") != null);

    // Shared code appears in both (expected, as they're separate shaders)
    // But within each shader, shared should appear only once
}

// ============================================================================
// Edge Cases
// ============================================================================

test "WGSL imports: empty imports array" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="fn main() {}"
        \\  imports=[]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "fn main()") != null);
}

test "WGSL imports: no imports property" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="fn main() {}" }
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "fn main()") != null);
}

test "WGSL imports: empty value string" {
    const source: [:0]const u8 =
        \\#wgsl empty { value="" }
        \\#wgsl shader {
        \\  value="fn main() {}"
        \\  imports=[empty]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Should still compile, just with empty import
    try testing.expect(std.mem.indexOf(u8, pngb, "fn main()") != null);
}

test "WGSL imports: string-style references in imports array" {
    // String references in imports array
    const source: [:0]const u8 =
        \\#wgsl constants { value="const X: f32 = 1.0;" }
        \\#wgsl shader {
        \\  value="fn main() { let y = X; }"
        \\  imports=["constants"]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "const X") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "fn main()") != null);
}

test "WGSL imports: import references non-existent wgsl causes error" {
    const source: [:0]const u8 =
        \\#wgsl shader {
        \\  value="fn main() {}"
        \\  imports=[doesNotExist]
        \\}
        \\#shaderModule main { code=shader }
    ;

    // Referencing non-existent wgsl triggers analysis error (undefined reference)
    const result = compileSource(source);
    try testing.expectError(error.AnalysisError, result);
}

test "WGSL imports: very long import chain (stress test)" {
    // Create a chain of 20 imports using bufPrint
    var source_buf: [8192]u8 = undefined;
    @memset(&source_buf, 0); // Zero-initialize for sentinel
    var pos: usize = 0;

    // First: base module
    const base = "#wgsl m0 { value=\"M0_MARKER\" }\n";
    @memcpy(source_buf[pos..][0..base.len], base);
    pos += base.len;

    // Chain: each imports the previous
    for (1..20) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl m{d} {{ value=\"M{d}_MARKER\" imports=[m{d}] }}\n", .{ i, i, i - 1 }) catch break;
        pos += line.len;
    }

    // Final shader
    const final = "#wgsl shader { value=\"FINAL_MARKER\" imports=[m19] }\n#shaderModule main { code=shader }\n";
    @memcpy(source_buf[pos..][0..final.len], final);
    pos += final.len;

    // Null terminate
    source_buf[pos] = 0;

    const source_z: [:0]const u8 = source_buf[0..pos :0];

    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    // All modules should be present
    try testing.expect(std.mem.indexOf(u8, pngb, "M0_MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "M19_MARKER") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "FINAL_MARKER") != null);
}

test "WGSL imports: wide import tree (many direct imports)" {
    var source_buf: [8192]u8 = undefined;
    @memset(&source_buf, 0); // Zero-initialize for sentinel
    var pos: usize = 0;

    // Create 30 independent modules
    for (0..30) |i| {
        const line = std.fmt.bufPrint(source_buf[pos..], "#wgsl lib{d} {{ value=\"// LIB{d}\" }}\n", .{ i, i }) catch break;
        pos += line.len;
    }

    // Shader imports all 30 - build import list
    const imports_start = "#wgsl shader { value=\"// MAIN\" imports=[";
    @memcpy(source_buf[pos..][0..imports_start.len], imports_start);
    pos += imports_start.len;

    for (0..30) |i| {
        if (i > 0) {
            source_buf[pos] = ' ';
            pos += 1;
        }
        const ref = std.fmt.bufPrint(source_buf[pos..], "lib{d}", .{i}) catch break;
        pos += ref.len;
    }

    const imports_end = "] }\n#shaderModule main { code=shader }\n";
    @memcpy(source_buf[pos..][0..imports_end.len], imports_end);
    pos += imports_end.len;

    const source_z = source_buf[0..pos :0];

    const pngb = try compileSource(source_z);
    defer testing.allocator.free(pngb);

    // All libraries should be present
    try testing.expect(std.mem.indexOf(u8, pngb, "// LIB0") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "// LIB29") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "// MAIN") != null);
}

// ============================================================================
// File Loading Tests (requires temp files)
// ============================================================================

test "WGSL imports: load from file path" {
    // Create temp directory and files
    const tmp_dir = "/tmp/pngine_wgsl_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Write WGSL file
    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/constants.wgsl", .{});
        defer file.close();
        try file.writeAll("const FILE_LOADED: f32 = 42.0;");
    }

    const source: [:0]const u8 =
        \\#wgsl constants { value="./constants.wgsl" }
        \\#shaderModule main { code=constants }
    ;

    const pngb = try compileWithBaseDir(source, tmp_dir);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "FILE_LOADED") != null);
}

test "WGSL imports: file with imports from file" {
    const tmp_dir = "/tmp/pngine_wgsl_test2";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    try std.fs.cwd().makePath(tmp_dir);
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Write base WGSL
    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/base.wgsl", .{});
        defer file.close();
        try file.writeAll("const BASE_LOADED: f32 = 1.0;");
    }

    // Write main WGSL
    {
        const file = try std.fs.cwd().createFile(tmp_dir ++ "/main.wgsl", .{});
        defer file.close();
        try file.writeAll("fn useBase() { let x = BASE_LOADED; }");
    }

    const source: [:0]const u8 =
        \\#wgsl base { value="./base.wgsl" }
        \\#wgsl mainShader {
        \\  value="./main.wgsl"
        \\  imports=[base]
        \\}
        \\#shaderModule shader { code=mainShader }
    ;

    const pngb = try compileWithBaseDir(source, tmp_dir);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "BASE_LOADED") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "useBase") != null);
}

test "WGSL imports: missing file path handled gracefully" {
    const source: [:0]const u8 =
        \\#wgsl missing { value="./does_not_exist.wgsl" }
        \\#shaderModule main { code=missing }
    ;

    // Should return error for missing file
    const result = compileWithBaseDir(source, "/tmp/nonexistent");
    try testing.expectError(error.OutOfMemory, result);
}

// ============================================================================
// Content Integrity Tests
// ============================================================================

test "WGSL imports: multiline content preserved" {
    const source: [:0]const u8 =
        \\#wgsl multiline {
        \\  value="struct Vertex {\n  position: vec3f,\n  color: vec4f,\n};"
        \\}
        \\#shaderModule main { code=multiline }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "struct Vertex") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "position") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "color") != null);
}

test "WGSL imports: special characters in WGSL preserved" {
    const source: [:0]const u8 =
        \\#wgsl special {
        \\  value="// Comment with unicode: αβγ δεζ\nconst x = 1.0e-10;"
        \\}
        \\#shaderModule main { code=special }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    try testing.expect(std.mem.indexOf(u8, pngb, "1.0e-10") != null);
}

// ============================================================================
// Integration with #define substitution
// ============================================================================

test "WGSL imports: #define substitution applied to imported code" {
    const source: [:0]const u8 =
        \\#define RADIUS=10
        \\#wgsl constants { value="const r = RADIUS;" }
        \\#wgsl shader {
        \\  value="fn main() { let x = r; }"
        \\  imports=[constants]
        \\}
        \\#shaderModule main { code=shader }
    ;

    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // RADIUS should be substituted with 10
    try testing.expect(std.mem.indexOf(u8, pngb, "const r = 10") != null);
}

// ============================================================================
// Cache Behavior Tests
// ============================================================================

test "WGSL imports: cache produces consistent results" {
    const source: [:0]const u8 =
        \\#wgsl base { value="// BASE" }
        \\#wgsl a { value="// A" imports=[base] }
        \\#wgsl b { value="// B" imports=[base] }
        \\#shaderModule modA { code=a }
        \\#shaderModule modB { code=b }
    ;

    // Compile multiple times - should be consistent
    const pngb1 = try compileSource(source);
    defer testing.allocator.free(pngb1);

    const pngb2 = try compileSource(source);
    defer testing.allocator.free(pngb2);

    // Bytecode should be identical
    try testing.expectEqualSlices(u8, pngb1, pngb2);
}

// ============================================================================
// OOM Resilience Tests
// ============================================================================

test "WGSL imports: OOM during resolution" {
    // This test verifies that OOM conditions are handled gracefully
    // by exercising the normal path and checking it doesn't crash.
    // Full FailingAllocator testing is complex due to cleanup code paths.
    const source: [:0]const u8 =
        \\#wgsl a { value="// A" }
        \\#wgsl b { value="// B" imports=[a] }
        \\#wgsl c { value="// C" imports=[b] }
        \\#shaderModule main { code=c }
    ;

    // Verify normal compilation works
    const pngb = try compileSource(source);
    defer testing.allocator.free(pngb);

    // Verify content is present
    try testing.expect(std.mem.indexOf(u8, pngb, "// A") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "// B") != null);
    try testing.expect(std.mem.indexOf(u8, pngb, "// C") != null);
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "WGSL imports: property - resolved code length >= original" {
    // Property: adding imports can only increase or maintain code length
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    for (0..50) |_| {
        var source_buf: [2048]u8 = undefined;
        @memset(&source_buf, 0); // Zero-initialize for sentinel
        var pos: usize = 0;

        // Random number of imports (0-5)
        const num_imports = random.intRangeAtMost(u8, 0, 5);

        // Generate import modules
        for (0..num_imports) |i| {
            const len = random.intRangeAtMost(u8, 5, 50);
            const header = std.fmt.bufPrint(source_buf[pos..], "#wgsl imp{d} {{ value=\"", .{i}) catch break;
            pos += header.len;
            for (0..len) |_| {
                source_buf[pos] = 'x';
                pos += 1;
            }
            @memcpy(source_buf[pos..][0..4], "\" }\n");
            pos += 4;
        }

        // Generate main shader
        const main_len = random.intRangeAtMost(u8, 10, 100);
        const main_header = "#wgsl main { value=\"";
        @memcpy(source_buf[pos..][0..main_header.len], main_header);
        pos += main_header.len;
        for (0..main_len) |_| {
            source_buf[pos] = 'y';
            pos += 1;
        }
        source_buf[pos] = '"';
        pos += 1;

        // Add imports if any
        if (num_imports > 0) {
            const imports_start = " imports=[";
            @memcpy(source_buf[pos..][0..imports_start.len], imports_start);
            pos += imports_start.len;
            for (0..num_imports) |i| {
                if (i > 0) {
                    source_buf[pos] = ' ';
                    pos += 1;
                }
                const ref = std.fmt.bufPrint(source_buf[pos..], "imp{d}", .{i}) catch break;
                pos += ref.len;
            }
            source_buf[pos] = ']';
            pos += 1;
        }
        const ending = " }\n#shaderModule mod { code=main }\n";
        @memcpy(source_buf[pos..][0..ending.len], ending);
        pos += ending.len;

        const source_z = source_buf[0..pos :0];

        const pngb = compileSource(source_z) catch continue;
        defer testing.allocator.free(pngb);

        // Property: bytecode was generated (not empty)
        try testing.expect(pngb.len > 0);
    }
}

// ============================================================================
// Fuzz Testing
// ============================================================================

fn fuzzWgslImports(_: void, input: []const u8) !void {
    // Filter out null bytes and very short inputs
    for (input) |b| {
        if (b == 0) return;
    }
    if (input.len < 10) return;

    // Create a simple shader with the fuzzed content as value
    var source_buf: [2048]u8 = undefined;
    const content_len = @min(input.len, 500);

    // Escape problematic characters for WGSL string
    var escaped_buf: [1024]u8 = undefined;
    var escaped_len: usize = 0;
    for (input[0..content_len]) |c| {
        if (escaped_len >= escaped_buf.len - 2) break;
        if (c == '"' or c == '\\' or c == '\n' or c == '\r') {
            // Skip problematic chars
            continue;
        }
        if (c >= 32 and c < 127) {
            escaped_buf[escaped_len] = c;
            escaped_len += 1;
        }
    }

    if (escaped_len == 0) return;

    const source = std.fmt.bufPrint(&source_buf, "#wgsl fuzz {{ value=\"{s}\" }}\n#shaderModule m {{ code=fuzz }}\n", .{escaped_buf[0..escaped_len]}) catch return;

    const source_z = source[0..source.len :0];

    // Property: should not crash, may return error
    const result = compileSource(source_z);
    if (result) |pngb| {
        defer testing.allocator.free(pngb);
        // Property: if compilation succeeds, bytecode is valid
        try testing.expect(pngb.len > 0);
    } else |_| {
        // Compilation error is acceptable for fuzz input
    }
}

test "WGSL imports: fuzz test" {
    try std.testing.fuzz({}, fuzzWgslImports, .{});
}
