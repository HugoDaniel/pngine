//! Shader Emission Module
//!
//! Handles emission of #wgsl and #shaderModule declarations.
//! Includes define substitution for shader code preprocessing.
//!
//! ## WGSL Import Resolution
//!
//! #wgsl macros can have:
//! - `value="inline code"` or `value="./path/to/file.wgsl"` (file path)
//! - `imports=[$wgsl.a, $wgsl.b]` (references to other #wgsl macros)
//!
//! The final shader code is: imports[0] + imports[1] + ... + value
//! This allows sharing common code (constants, utilities) across shaders.
//!
//! ## Invariants
//!
//! * Shader IDs are assigned sequentially starting from next_shader_id.
//! * Define substitution is bounded to MAX_SUBSTITUTION_DEPTH passes.
//! * String literals (quoted content) are never modified during substitution.
//! * Math constants (PI, TAU, E) are substituted only if no user define exists.
//! * File paths are resolved relative to base_dir.
//! * WGSL import cycles are detected by the Analyzer.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");

/// Maximum nesting depth for define substitution (prevents infinite loops).
const MAX_SUBSTITUTION_DEPTH: u8 = 16;

/// Maximum code length to prevent runaway substitution.
const MAX_CODE_LENGTH: u32 = 1024 * 1024; // 1MB

/// Maximum file size for WGSL files.
const MAX_FILE_SIZE: u32 = 256 * 1024; // 256KB

/// Math constants available for substitution.
const math_constants = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "TAU", .value = "6.283185307179586" }, // Check TAU before PI (longer match)
    .{ .name = "PI", .value = "3.141592653589793" },
    .{ .name = "E", .value = "2.718281828459045" },
};

/// Cache for resolved WGSL code (with imports prepended).
/// Key is the #wgsl macro name, value is the resolved code.
var resolved_wgsl_cache: std.StringHashMapUnmanaged([]const u8) = .{};

/// Emit #wgsl and #shaderModule declarations.
pub fn emitShaders(e: *Emitter) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_shader_id = e.next_shader_id;

    // Clear cache from previous runs (if any)
    clearCache(e.gpa);
    defer clearCache(e.gpa);

    // Emit #wgsl declarations
    var it = e.analysis.symbols.wgsl.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const shader_id = e.next_shader_id;
        e.next_shader_id += 1;
        try e.shader_ids.put(e.gpa, name, shader_id);

        // Resolve WGSL with imports prepended
        const raw_code = try resolveWgslWithImports(e, name, info.node);
        if (raw_code.len == 0) continue;

        const code = try substituteDefines(e, raw_code);
        defer if (code.ptr != raw_code.ptr) e.gpa.free(code);

        const data_id = try e.builder.addData(e.gpa, code);

        // Emit create_shader_module opcode
        try e.builder.getEmitter().createShaderModule(
            e.gpa,
            shader_id,
            data_id.toInt(),
        );
    }

    // Also handle #shaderModule
    var sm_it = e.analysis.symbols.shader_module.iterator();
    while (sm_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const shader_id = e.next_shader_id;
        e.next_shader_id += 1;
        try e.shader_ids.put(e.gpa, name, shader_id);

        // Find code property - can be string literal or identifier referencing #wgsl
        const code_value = utils.findPropertyValue(e, info.node, "code") orelse continue;
        const raw_code = resolveShaderCode(e, code_value);
        if (raw_code.len == 0) continue;

        const code = try substituteDefines(e, raw_code);
        defer if (code.ptr != raw_code.ptr) e.gpa.free(code);

        const data_id = try e.builder.addData(e.gpa, code);

        try e.builder.getEmitter().createShaderModule(
            e.gpa,
            shader_id,
            data_id.toInt(),
        );
    }

    // Post-condition: shader IDs were assigned sequentially
    std.debug.assert(e.next_shader_id >= initial_shader_id);
}

/// Resolve shader code from a code property node.
///
/// The code property can be:
/// - A string literal: code="@vertex fn vs() {}"
/// - An identifier referencing a #wgsl macro: code=cubeShader
/// - A string reference: code="$wgsl.sceneEShader"
///
/// For identifier/string references, looks up the resolved #wgsl code from cache.
fn resolveShaderCode(e: *Emitter, code_node: Node.Index) []const u8 {
    // Pre-condition
    std.debug.assert(code_node.toInt() < e.ast.nodes.len);

    const code_tag = e.ast.nodes.items(.tag)[code_node.toInt()];

    // Direct string value
    if (code_tag == .string_value) {
        const content = utils.getStringContent(e, code_node);

        // Check if it's a reference string like "$wgsl.name"
        if (std.mem.startsWith(u8, content, "$wgsl.")) {
            const wgsl_name = content[6..]; // Skip "$wgsl."
            // Look up resolved code from cache (populated during #wgsl emission)
            if (resolved_wgsl_cache.get(wgsl_name)) |cached| {
                return cached;
            }
        }

        return content;
    }

    // Identifier value - resolve to #wgsl macro
    if (code_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[code_node.toInt()];
        const wgsl_name = utils.getTokenSlice(e, token);

        // Look up resolved code from cache (populated during #wgsl emission)
        if (resolved_wgsl_cache.get(wgsl_name)) |cached| {
            return cached;
        }
    }

    // Post-condition: return empty for unresolved
    return "";
}

/// Substitute #define values into shader code.
/// Uses iterative multi-pass approach (no recursion).
/// Memory: Caller owns returned slice if different from input.
pub fn substituteDefines(e: *Emitter, code: []const u8) Emitter.Error![]const u8 {
    // Pre-conditions
    std.debug.assert(code.len > 0);
    std.debug.assert(code.len <= MAX_CODE_LENGTH);

    // Check if we need to do any substitution
    const has_defines = e.analysis.symbols.define.count() > 0;
    const has_math_constants = hasMathConstant(code);

    // If nothing to substitute, return original code
    if (!has_defines and !has_math_constants) {
        return code;
    }

    // Iterative substitution with bounded depth (replaces recursion)
    var current = try e.gpa.dupe(u8, code);
    errdefer e.gpa.free(current);

    for (0..MAX_SUBSTITUTION_DEPTH) |_| {
        const substituted = try substituteOnce(e, current);

        if (substituted.ptr == current.ptr) {
            // No more substitutions needed
            break;
        } else {
            e.gpa.free(current);
            current = substituted;
        }
    } else {
        // Hit max depth - likely circular reference, but we return what we have
    }

    // Post-condition: result has content
    std.debug.assert(current.len > 0);

    return current;
}

/// Perform one pass of define substitution (no recursion).
/// Returns input pointer if no changes made, new allocation otherwise.
fn substituteOnce(e: *Emitter, code: []const u8) Emitter.Error![]u8 {
    // Pre-conditions
    std.debug.assert(code.len > 0);

    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(e.gpa);

    var made_substitution = false;
    var pos: u32 = 0;
    var in_string = false;

    // Bounded loop over code characters
    for (0..MAX_CODE_LENGTH) |_| {
        if (pos >= code.len) break;

        const c = code[pos];

        // Handle escaped quote sequence \" - this represents a WGSL string delimiter
        // In DSL syntax, \" inside a string value becomes " in the output,
        // which starts/ends a string literal in the target language (WGSL)
        if (c == '\\' and pos + 1 < code.len and code[pos + 1] == '"') {
            in_string = !in_string;
            try result.append(e.gpa, c);
            pos += 1;
            try result.append(e.gpa, code[pos]);
            pos += 1;
            continue;
        }

        // Regular quote toggles string state
        if (c == '"') {
            in_string = !in_string;
            try result.append(e.gpa, c);
            pos += 1;
            continue;
        }

        // Don't substitute inside string literals
        if (in_string) {
            try result.append(e.gpa, c);
            pos += 1;
            continue;
        }

        // Try substitution
        const sub_result = trySubstitute(e, code, pos);
        if (sub_result.value) |value| {
            try result.appendSlice(e.gpa, value);
            pos += sub_result.advance;
            made_substitution = true;
        } else {
            try result.append(e.gpa, c);
            pos += 1;
        }
    } else {
        // Hit max iterations - code too long
        std.debug.assert(false);
    }

    // Post-condition: result is valid
    std.debug.assert(result.items.len > 0 or code.len == 0);

    if (!made_substitution) {
        result.deinit(e.gpa);
        return @constCast(code);
    }

    return try result.toOwnedSlice(e.gpa);
}

/// Result of attempting substitution at a position.
const SubstituteResult = struct {
    value: ?[]const u8,
    advance: u32,
};

/// Try to substitute a define or math constant at the given position.
fn trySubstitute(e: *Emitter, code: []const u8, pos: u32) SubstituteResult {
    // Pre-conditions
    std.debug.assert(pos < code.len);

    // Check user defines first (they take precedence)
    var def_it = e.analysis.symbols.define.iterator();
    while (def_it.next()) |def_entry| {
        const def_name = def_entry.key_ptr.*;
        const def_info = def_entry.value_ptr.*;

        if (matchesIdentifier(code, pos, def_name)) {
            const value = getDefineValue(e, def_info.node);
            return .{ .value = value, .advance = @intCast(def_name.len) };
        }
    }

    // Check math constants
    for (math_constants) |constant| {
        // Skip if user defined this name
        if (e.analysis.symbols.define.get(constant.name) != null) continue;

        if (matchesIdentifier(code, pos, constant.name)) {
            return .{ .value = constant.value, .advance = @intCast(constant.name.len) };
        }
    }

    // Post-condition: no match found
    return .{ .value = null, .advance = 0 };
}

/// Check if identifier matches at position (whole word match).
fn matchesIdentifier(code: []const u8, pos: u32, name: []const u8) bool {
    // Pre-conditions
    std.debug.assert(name.len > 0);

    if (pos + name.len > code.len) return false;
    if (!std.mem.eql(u8, code[pos..][0..name.len], name)) return false;

    // Ensure whole word match
    const before_ok = pos == 0 or !isIdentChar(code[pos - 1]);
    const after_ok = pos + name.len >= code.len or !isIdentChar(code[pos + name.len]);

    return before_ok and after_ok;
}

/// Check if a character is a valid identifier character.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// Check if code contains any math constant (PI, TAU, E) as whole word.
fn hasMathConstant(code: []const u8) bool {
    // Pre-condition
    std.debug.assert(code.len <= MAX_CODE_LENGTH);

    for (0..@min(code.len, MAX_CODE_LENGTH)) |i| {
        const pos: u32 = @intCast(i);
        for (math_constants) |constant| {
            if (matchesIdentifier(code, pos, constant.name)) return true;
        }
    }
    return false;
}

/// Get the string value of a #define.
fn getDefineValue(e: *Emitter, define_node: Node.Index) []const u8 {
    // Pre-condition
    std.debug.assert(define_node.toInt() < e.ast.nodes.len);

    const value_node = e.ast.nodes.items(.data)[define_node.toInt()].node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    const result = if (value_tag == .string_value)
        utils.getStringContent(e, value_node)
    else
        utils.getNodeText(e, value_node);

    // Post-condition: returned valid slice
    std.debug.assert(result.len > 0 or value_tag != .string_value);

    return result;
}

// ============================================================================
// WGSL Import Resolution
// ============================================================================

/// Clear the resolved WGSL cache, freeing all values and internal memory.
fn clearCache(gpa: std.mem.Allocator) void {
    var it = resolved_wgsl_cache.valueIterator();
    while (it.next()) |value_ptr| {
        gpa.free(value_ptr.*);
    }
    resolved_wgsl_cache.clearAndFree(gpa);
}

/// Resolve WGSL code with imports prepended.
/// Memory: Result is cached and owned by the cache.
fn resolveWgslWithImports(e: *Emitter, name: []const u8, macro_node: Node.Index) Emitter.Error![]const u8 {
    // Pre-conditions
    std.debug.assert(name.len > 0);
    std.debug.assert(macro_node.toInt() < e.ast.nodes.len);

    // Check cache first
    if (resolved_wgsl_cache.get(name)) |cached| {
        return cached;
    }

    // Get the value property
    const value_node = utils.findPropertyValue(e, macro_node, "value") orelse return "";
    const value_str = utils.getStringContent(e, value_node);
    if (value_str.len == 0) return "";

    // Get imports array
    const imports = getWgslImports(e, macro_node);

    // If no imports, just load the value (inline or from file)
    if (imports.len == 0) {
        const code = try loadWgslValue(e, value_str);
        try resolved_wgsl_cache.put(e.gpa, name, code);
        return code;
    }

    // Resolve imports and concatenate
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(e.gpa);

    // Add each import's resolved code
    for (imports) |import_name| {
        // Look up the imported #wgsl macro
        if (e.analysis.symbols.wgsl.get(import_name)) |import_info| {
            // Recursively resolve (with caching)
            const import_code = try resolveWgslWithImports(e, import_name, import_info.node);
            if (import_code.len > 0) {
                try result.appendSlice(e.gpa, import_code);
                try result.append(e.gpa, '\n');
            }
        }
    }

    // Add the main value
    const main_code = try loadWgslValue(e, value_str);
    defer e.gpa.free(main_code);
    try result.appendSlice(e.gpa, main_code);

    const final = try result.toOwnedSlice(e.gpa);
    try resolved_wgsl_cache.put(e.gpa, name, final);

    // Post-condition: result has content
    std.debug.assert(final.len > 0);

    return final;
}

/// Load WGSL code from a value string.
/// If the value is a file path (starts with "./" or "/"), reads from disk.
/// Otherwise treats as inline WGSL code.
/// Memory: Caller owns returned slice.
fn loadWgslValue(e: *Emitter, value: []const u8) Emitter.Error![]u8 {
    // Pre-condition
    std.debug.assert(value.len > 0);

    // Check if it's a file path
    if (isFilePath(value)) {
        return loadWgslFile(e, value);
    }

    // Inline code - duplicate for caller ownership
    return try e.gpa.dupe(u8, value);
}

/// Check if a value string is a file path.
/// Only recognizes relative paths (./ ../) not absolute paths (/) to avoid
/// treating WGSL comments (// ...) as paths.
fn isFilePath(value: []const u8) bool {
    if (value.len == 0) return false;
    // Only recognize relative paths - WGSL comments start with // which would
    // incorrectly match an absolute path check
    return std.mem.startsWith(u8, value, "./") or
        std.mem.startsWith(u8, value, "../");
}

/// Load WGSL code from a file path.
/// Memory: Caller owns returned slice.
fn loadWgslFile(e: *Emitter, path: []const u8) Emitter.Error![]u8 {
    // Pre-condition
    std.debug.assert(path.len > 0);

    const base_dir = e.options.base_dir orelse ".";
    var path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, path }) catch
        return error.OutOfMemory;

    return readFile(e.gpa, full_path) catch |err| {
        std.debug.print("Warning: Could not read WGSL file '{s}': {}\n", .{ full_path, err });
        return error.OutOfMemory;
    };
}

/// Read file into allocated buffer.
/// Caller owns returned memory.
fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Pre-condition
    std.debug.assert(path.len > 0);

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size: u32 = if (stat.size > MAX_FILE_SIZE)
        return error.FileTooLarge
    else
        @intCast(stat.size);

    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    // Bounded read loop
    var bytes_read: u32 = 0;
    for (0..size + 1) |_| {
        if (bytes_read >= size) break;
        const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
        if (n == 0) break;
        bytes_read += n;
    }

    // Post-condition: buffer is populated
    std.debug.assert(bytes_read <= size);

    return buffer;
}

/// Get WGSL import names from a macro node's imports property.
/// Returns a slice from extra_data (no allocation).
fn getWgslImports(e: *Emitter, macro_node: Node.Index) []const []const u8 {
    // Pre-condition
    std.debug.assert(macro_node.toInt() < e.ast.nodes.len);

    const data = e.ast.nodes.items(.data)[macro_node.toInt()];
    const props = e.ast.extraData(data.extra_range);

    for (props) |prop_idx| {
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const prop_name = utils.getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, prop_name, "imports")) {
            const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
            const value_node = prop_data.node;
            const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

            if (value_tag == .array) {
                return extractImportNames(e, value_node);
            }
        }
    }

    return &[_][]const u8{};
}

/// Extract import names from an array node.
/// Uses static buffer for bounded iteration.
fn extractImportNames(e: *Emitter, array_node: Node.Index) []const []const u8 {
    // Pre-condition
    std.debug.assert(array_node.toInt() < e.ast.nodes.len);

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Static buffer for import names (max 32 imports)
    const MAX_IMPORTS = 32;
    const S = struct {
        var names: [MAX_IMPORTS][]const u8 = undefined;
    };
    var count: u32 = 0;

    for (elements) |elem_idx| {
        if (count >= MAX_IMPORTS) break;

        const elem_node: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem_node.toInt()];

        // Handle reference ($wgsl.name) or string ("$wgsl.name")
        if (elem_tag == .reference) {
            const ref_data = e.ast.nodes.items(.data)[elem_node.toInt()];
            const name_token = ref_data.node_and_node[1];
            S.names[count] = utils.getTokenSlice(e, name_token);
            count += 1;
        } else if (elem_tag == .string_value) {
            // String like "$wgsl.name" - extract the name part
            const str = utils.getStringContent(e, elem_node);
            if (std.mem.startsWith(u8, str, "$wgsl.")) {
                S.names[count] = str[6..]; // Skip "$wgsl."
                count += 1;
            }
        }
    }

    return S.names[0..count];
}
