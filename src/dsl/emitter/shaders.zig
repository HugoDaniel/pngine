//! Shader Emission Module
//!
//! Handles emission of #wgsl and #shaderModule declarations.
//! Includes define substitution for shader code preprocessing.
//!
//! ## Invariants
//!
//! * Shader IDs are assigned sequentially starting from next_shader_id.
//! * Define substitution is bounded to MAX_SUBSTITUTION_DEPTH passes.
//! * String literals (quoted content) are never modified during substitution.
//! * Math constants (PI, TAU, E) are substituted only if no user define exists.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");

/// Maximum nesting depth for define substitution (prevents infinite loops).
const MAX_SUBSTITUTION_DEPTH: u8 = 16;

/// Maximum code length to prevent runaway substitution.
const MAX_CODE_LENGTH: u32 = 1024 * 1024; // 1MB

/// Math constants available for substitution.
const math_constants = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "TAU", .value = "6.283185307179586" }, // Check TAU before PI (longer match)
    .{ .name = "PI", .value = "3.141592653589793" },
    .{ .name = "E", .value = "2.718281828459045" },
};

/// Emit #wgsl and #shaderModule declarations.
pub fn emitShaders(e: *Emitter) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_shader_id = e.next_shader_id;

    // Emit #wgsl declarations
    var it = e.analysis.symbols.wgsl.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const shader_id = e.next_shader_id;
        e.next_shader_id += 1;
        try e.shader_ids.put(e.gpa, name, shader_id);

        // Get shader value, substitute defines, and add to data section
        const value = utils.findPropertyValue(e, info.node, "value") orelse continue;
        const raw_code = utils.getStringContent(e, value);
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

        // Find code property, substitute defines, and add to data section
        const code_value = utils.findPropertyValue(e, info.node, "code") orelse continue;
        const raw_code = utils.getStringContent(e, code_value);
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
