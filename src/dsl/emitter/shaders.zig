//! Shader Emission Module (v2 - Runtime Deduplication)
//!
//! Handles emission of #wgsl and #shaderModule declarations.
//! Uses runtime deduplication via WGSL table (v2 format).
//!
//! ## Design (v2)
//!
//! Instead of prepending imports at compile time (causing code duplication),
//! each #wgsl module is stored separately with its dependency list:
//!
//! ```
//! WGSL Table:
//!   wgsl_id=0: data_id=0, deps=[]           // transform2D
//!   wgsl_id=1: data_id=1, deps=[0]          // primitives
//!   wgsl_id=2: data_id=2, deps=[0,1]        // tangram
//! ```
//!
//! At runtime, the JS/WASM runtime resolves dependencies and concatenates
//! code with deduplication.
//!
//! ## WGSL Macros
//!
//! #wgsl macros can have:
//! - `value="inline code"` or `value="./path/to/file.wgsl"` (file path)
//! - `imports=[a, b]` (bare identifiers referencing other #wgsl macros)
//!
//! ## Invariants
//!
//! * Modules must be processed in dependency order (deps before dependents).
//! * Shader IDs are assigned sequentially starting from next_shader_id.
//! * WGSL IDs in builder.wgsl_table correspond to module order.
//! * Define substitution is bounded to MAX_SUBSTITUTION_DEPTH passes.
//! * String literals (quoted content) are never modified during substitution.
//! * Math constants (PI, TAU, E) are substituted only if no user define exists.
//! * File paths are resolved relative to base_dir.
//! * WGSL import cycles are detected by the Analyzer.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");

// Reflection modules for emission-time WGSL analysis
const reflect = @import("reflect");
const miniray_ffi = reflect.miniray_ffi;
const json = std.json;

/// Maximum nesting depth for define substitution (prevents infinite loops).
const MAX_SUBSTITUTION_DEPTH: u8 = 16;

/// Maximum code length to prevent runaway substitution.
const MAX_CODE_LENGTH: u32 = 1024 * 1024; // 1MB

/// Maximum file size for WGSL files.
const MAX_FILE_SIZE: u32 = 256 * 1024; // 256KB

/// Maximum imports per #wgsl macro.
const MAX_IMPORTS: u32 = 32;

/// Math constants available for substitution.
const math_constants = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "TAU", .value = "6.283185307179586" }, // Check TAU before PI (longer match)
    .{ .name = "PI", .value = "3.141592653589793" },
    .{ .name = "E", .value = "2.718281828459045" },
};

/// Emit #wgsl and #shaderModule declarations.
/// v2 format: stores raw code + deps in WGSL table for runtime deduplication.
pub fn emitShaders(e: *Emitter) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_shader_id = e.next_shader_id;

    // Phase 1: Emit #wgsl declarations in topological order (deps first)
    // Use iterative worklist to process in dependency order
    try emitWgslModulesInOrder(e);

    // Phase 2: Handle #shaderModule
    // #shaderModule with code=wgslName uses the existing wgsl_id
    var sm_it = e.analysis.symbols.shader_module.iterator();
    while (sm_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Find code property - can be string literal or identifier referencing #wgsl
        const code_value = utils.findPropertyValue(e, info.node, "code") orelse continue;

        // Check if code references a #wgsl macro
        const wgsl_ref = getWgslReference(e, code_value);
        if (wgsl_ref) |ref_name| {
            // Reference to #wgsl - use resolved code with all imports concatenated
            const resolved_code = e.resolved_wgsl_cache.get(ref_name) orelse {
                std.debug.print("WARN: resolved_wgsl_cache miss for '{s}'\n", .{ref_name});
                continue;
            };
            std.debug.print("DEBUG: #shaderModule '{s}' using resolved code for '{s}' ({} bytes)\n", .{ name, ref_name, resolved_code.len });

            // Assign shader_id for this #shaderModule
            const shader_id = e.next_shader_id;
            e.next_shader_id += 1;
            try e.shader_ids.put(e.gpa, name, shader_id);

            // Store resolved code (with imports) in data section and emit
            const data_id = try e.builder.addData(e.gpa, resolved_code);
            try e.builder.getEmitter().createShaderModule(
                e.gpa,
                shader_id,
                data_id.toInt(),
            );
        } else {
            // Inline code - apply minification if enabled
            const raw_code = resolveShaderCode(e, code_value);
            if (raw_code.len == 0) continue;

            const substituted = try substituteDefines(e, raw_code);
            defer if (substituted.ptr != raw_code.ptr) e.gpa.free(substituted);

            // Minify if requested, otherwise use substituted code
            const code_to_store: []const u8 = if (e.options.minify_shaders)
                minifyAndCache(e, name, substituted) orelse substituted
            else blk: {
                // Perform reflection on substituted code (no minification)
                reflectAndCache(e, name, substituted);
                break :blk substituted;
            };

            const shader_id = e.next_shader_id;
            e.next_shader_id += 1;
            try e.shader_ids.put(e.gpa, name, shader_id);

            const data_id = try e.builder.addData(e.gpa, code_to_store);

            // Free minified code if it was allocated
            if (e.options.minify_shaders and code_to_store.ptr != substituted.ptr) {
                e.gpa.free(@constCast(code_to_store));
            }

            const wgsl_id = try e.builder.addWgsl(e.gpa, data_id.toInt(), &[_]u16{});
            try e.wgsl_name_to_id.put(e.gpa, name, wgsl_id);

            // NOTE: Emit data_id (not wgsl_id) because wasm_entry.zig uses
            // getDataSlice() directly on the data section, not the WGSL table.
            try e.builder.getEmitter().createShaderModule(
                e.gpa,
                shader_id,
                data_id.toInt(),
            );
        }
    }

    // Post-condition: shader IDs were assigned sequentially
    std.debug.assert(e.next_shader_id >= initial_shader_id);
}

/// Emit #wgsl modules in topological order (dependencies before dependents).
/// Uses iterative Kahn's algorithm for topological sort.
fn emitWgslModulesInOrder(e: *Emitter) Emitter.Error!void {
    const symbols = &e.analysis.symbols.wgsl;
    if (symbols.count() == 0) return;

    // Track which modules have been processed
    var processed = std.StringHashMapUnmanaged(void){};
    defer processed.deinit(e.gpa);

    // Process modules iteratively (bounded loop)
    // Use simple approach: repeatedly find modules whose deps are all processed
    const max_iterations = symbols.count() * symbols.count() + 1;
    for (0..max_iterations) |_| {
        if (processed.count() >= symbols.count()) break;

        var made_progress = false;

        // Find a module whose deps are all processed
        var it = symbols.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            // Skip if already processed
            if (processed.get(name) != null) continue;

            // Check if all deps are processed
            const deps = getWgslImports(e, info.node);
            var all_deps_ready = true;
            for (deps) |dep| {
                if (processed.get(dep) == null) {
                    // Check if dep exists in symbols (might be missing)
                    if (symbols.get(dep) != null) {
                        all_deps_ready = false;
                        break;
                    }
                }
            }

            if (all_deps_ready) {
                // Process this module
                try emitWgslModule(e, name, info.node);
                try processed.put(e.gpa, name, {});
                made_progress = true;
            }
        }

        if (!made_progress and processed.count() < symbols.count()) {
            // Circular dependency detected - process remaining modules anyway
            it = symbols.iterator();
            while (it.next()) |entry| {
                if (processed.get(entry.key_ptr.*) == null) {
                    try emitWgslModule(e, entry.key_ptr.*, entry.value_ptr.*.node);
                    try processed.put(e.gpa, entry.key_ptr.*, {});
                }
            }
            break;
        }
    }
}

/// Emit a single #wgsl module.
/// Stores raw code in data section and adds entry to WGSL table with deps.
/// If minify_shaders option is enabled, minifies the code and uses mapped reflection.
fn emitWgslModule(e: *Emitter, name: []const u8, macro_node: Node.Index) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(name.len > 0);
    std.debug.assert(e.wgsl_name_to_id.get(name) == null);

    // Get the value property
    const value_node = utils.findPropertyValue(e, macro_node, "value") orelse {
        // No value property - skip
        return;
    };
    const value_str = utils.getStringContent(e, value_node);
    if (value_str.len == 0) return;

    // Load raw code (file or inline) - NO import prepending
    const raw_code = try loadWgslValue(e, value_str);
    defer e.gpa.free(raw_code);

    if (raw_code.len == 0) return;

    // Apply define substitution
    const substituted = try substituteDefines(e, raw_code);
    defer if (substituted.ptr != raw_code.ptr) e.gpa.free(substituted);

    // Minify if requested (stores minified code, caches reflection with mapped names)
    // Otherwise store original and reflect on substituted code
    const code_to_store: []const u8 = if (e.options.minify_shaders)
        minifyAndCache(e, name, substituted) orelse substituted
    else blk: {
        // Perform reflection on substituted code (no minification)
        reflectAndCache(e, name, substituted);
        break :blk substituted;
    };

    // Store in data section
    const data_id = try e.builder.addData(e.gpa, code_to_store);

    // Free minified code if it was allocated
    if (e.options.minify_shaders and code_to_store.ptr != substituted.ptr) {
        e.gpa.free(@constCast(code_to_store));
    }

    // Get direct dependencies (imports)
    const import_names = getWgslImports(e, macro_node);
    var deps = std.ArrayListUnmanaged(u16){};
    defer deps.deinit(e.gpa);

    for (import_names) |import_name| {
        if (e.wgsl_name_to_id.get(import_name)) |dep_wgsl_id| {
            try deps.append(e.gpa, dep_wgsl_id);
        }
        // Note: missing deps are silently ignored (analyzer should have caught this)
    }

    // Add to WGSL table (for import resolution tracking)
    const wgsl_id = try e.builder.addWgsl(e.gpa, data_id.toInt(), deps.items);
    try e.wgsl_name_to_id.put(e.gpa, name, wgsl_id);

    // NOTE: We do NOT create a shader module here for #wgsl declarations.
    // #wgsl is a reusable code fragment - it may be incomplete (missing imports).
    // Only #shaderModule creates actual GPU shader modules with fully resolved code.

    // Cache the resolved code for #shaderModule to use later
    // Build resolved code by concatenating deps + this module's code
    try buildAndCacheResolvedCode(e, name, code_to_store, deps.items);
}

/// Perform WGSL reflection on substituted code and cache the result.
///
/// This is called during emission to ensure reflection data matches
/// the actual emitted code (after define substitution).
///
/// Requires libminiray.a to be linked at build time.
/// If not available, reflection is skipped with a warning.
fn reflectAndCache(e: *Emitter, name: []const u8, code: []const u8) void {
    // Pre-conditions
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len > 0);

    // Skip if already cached (shouldn't happen, but be safe)
    if (e.wgsl_reflections.contains(name)) return;

    // FFI is mandatory - no subprocess fallback
    if (comptime !miniray_ffi.has_miniray_lib) {
        std.log.warn("WGSL reflection skipped for '{s}': libminiray.a not linked", .{name});
        return;
    }

    reflectViaFfi(e, name, code);
}

/// Reflect via FFI (libminiray.a linked).
fn reflectViaFfi(e: *Emitter, name: []const u8, code: []const u8) void {
    var result = miniray_ffi.reflectFfi(code) catch |err| {
        std.log.warn("WGSL reflection (FFI) failed for '{s}': {}", .{ name, err });
        return;
    };
    defer result.deinit();

    // Parse JSON into ReflectionData
    const parsed = reflect.Miniray.parseJson(e.gpa, result.json) catch |err| {
        std.log.warn("WGSL reflection JSON parse failed for '{s}': {}", .{ name, err });
        return;
    };

    // Cache the result
    e.wgsl_reflections.put(e.gpa, name, parsed) catch {
        var ref_copy = parsed;
        ref_copy.deinit();
        std.log.warn("WGSL reflection cache put failed for '{s}': OutOfMemory", .{name});
    };
}

/// Minify WGSL code and cache reflection data with mapped names.
///
/// Returns the minified code (caller owns) or null if minification failed.
/// The reflection data with mapped identifiers is cached automatically.
///
/// Requires libminiray.a to be linked (FFI path).
fn minifyAndCache(e: *Emitter, name: []const u8, code: []const u8) ?[]const u8 {
    // Pre-conditions
    std.debug.assert(name.len > 0);
    std.debug.assert(code.len > 0);

    // Skip if already cached
    if (e.wgsl_reflections.contains(name)) return null;

    // Minification requires FFI (no subprocess fallback for minify+reflect)
    if (comptime !miniray_ffi.has_miniray_lib) {
        std.log.warn("minify_shaders requires libminiray.a: '{s}' not minified", .{name});
        // Fall back to reflection-only
        reflectAndCache(e, name, code);
        return null;
    }

    // Call minifyAndReflectFfi
    var result = miniray_ffi.minifyAndReflectFfi(code, null) catch |err| {
        std.log.warn("WGSL minification failed for '{s}': {}", .{ name, err });
        // Fall back to reflection-only
        reflectAndCache(e, name, code);
        return null;
    };
    defer result.deinit();

    // Parse reflection JSON with mapped names
    const parsed = reflect.Miniray.parseJson(e.gpa, result.json) catch |err| {
        std.log.warn("WGSL minify reflection parse failed for '{s}': {}", .{ name, err });
        return null;
    };

    // Cache the reflection with mapped names
    e.wgsl_reflections.put(e.gpa, name, parsed) catch {
        var ref_copy = parsed;
        ref_copy.deinit();
        std.log.warn("WGSL reflection cache put failed for '{s}': OutOfMemory", .{name});
        return null;
    };

    // Return a copy of the minified code (caller owns)
    return e.gpa.dupe(u8, result.code) catch null;
}

/// Build and cache the fully resolved code for #shaderModule backward compatibility.
/// This concatenates all dependency code (deduplicated) + this module's code.
fn buildAndCacheResolvedCode(e: *Emitter, name: []const u8, code: []const u8, deps: []const u16) Emitter.Error!void {
    if (deps.len == 0) {
        // No deps - just cache the code itself
        const cached = try e.gpa.dupe(u8, code);
        errdefer e.gpa.free(cached); // Free if put fails
        try e.resolved_wgsl_cache.put(e.gpa, name, cached);
        return;
    }

    // Collect all transitive deps (for full resolution)
    var included = std.AutoHashMapUnmanaged(u16, void){};
    defer included.deinit(e.gpa);

    var order = std.ArrayListUnmanaged(u16){};
    defer order.deinit(e.gpa);

    // Iterative DFS to collect all deps
    var stack = std.ArrayListUnmanaged(u16){};
    defer stack.deinit(e.gpa);

    for (deps) |dep| {
        try stack.append(e.gpa, dep);
    }

    for (0..MAX_IMPORTS * MAX_IMPORT_DEPTH) |_| {
        if (stack.items.len == 0) break;
        const current = stack.pop() orelse break;

        if (included.contains(current)) continue;

        // Get this module's deps
        const wgsl_entry = e.builder.wgsl_table.get(current) orelse continue;
        var all_deps_included = true;
        for (wgsl_entry.deps) |sub_dep| {
            if (!included.contains(sub_dep)) {
                all_deps_included = false;
                try stack.append(e.gpa, current); // Re-push current
                try stack.append(e.gpa, sub_dep); // Process dep first
                break;
            }
        }

        if (all_deps_included) {
            try included.put(e.gpa, current, {});
            try order.append(e.gpa, current);
        }
    }

    // Build result
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(e.gpa);

    for (order.items) |wgsl_id| {
        const entry = e.builder.wgsl_table.get(wgsl_id) orelse continue;
        const dep_code = e.builder.data.get(@enumFromInt(entry.data_id));
        if (dep_code.len > 0) {
            try result.appendSlice(e.gpa, dep_code);
            try result.append(e.gpa, '\n');
        }
    }

    // Add this module's code
    try result.appendSlice(e.gpa, code);

    const cached = try result.toOwnedSlice(e.gpa);
    errdefer e.gpa.free(cached); // Free if put fails
    try e.resolved_wgsl_cache.put(e.gpa, name, cached);
}

/// Extract #wgsl reference name from a code value.
/// Returns the identifier name if it references a #wgsl.
/// Returns null if it's inline code (not a reference).
fn getWgslReference(e: *Emitter, code_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(code_node.toInt() < e.ast.nodes.len);

    const code_tag = e.ast.nodes.items(.tag)[code_node.toInt()];

    // Identifier value - reference to #wgsl macro
    if (code_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[code_node.toInt()];
        const wgsl_name = utils.getTokenSlice(e, token);
        // Check if this name exists in the wgsl symbol table
        if (e.wgsl_name_to_id.get(wgsl_name) != null) {
            return wgsl_name;
        }
    }

    return null;
}

/// Resolve shader code from a code property node.
///
/// The code property can be:
/// - A string literal: code="@vertex fn vs() {}"
/// - An identifier referencing a #wgsl macro: code=cubeShader
///
/// For identifier references, looks up the resolved #wgsl code from cache.
fn resolveShaderCode(e: *Emitter, code_node: Node.Index) []const u8 {
    // Pre-condition
    std.debug.assert(code_node.toInt() < e.ast.nodes.len);

    const code_tag = e.ast.nodes.items(.tag)[code_node.toInt()];

    // Direct string value (inline code)
    if (code_tag == .string_value) {
        return utils.getStringContent(e, code_node);
    }

    // Identifier value - resolve to #wgsl macro
    if (code_tag == .identifier_value) {
        const token = e.ast.nodes.items(.main_token)[code_node.toInt()];
        const wgsl_name = utils.getTokenSlice(e, token);

        // Look up resolved code from cache (populated during #wgsl emission)
        if (e.resolved_wgsl_cache.get(wgsl_name)) |cached| {
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
/// Returns false for declarations (identifier followed by ':').
fn matchesIdentifier(code: []const u8, pos: u32, name: []const u8) bool {
    // Pre-conditions
    std.debug.assert(name.len > 0);

    if (pos + name.len > code.len) return false;
    if (!std.mem.eql(u8, code[pos..][0..name.len], name)) return false;

    // Ensure whole word match
    const before_ok = pos == 0 or !isIdentChar(code[pos - 1]);
    const after_ok = pos + name.len >= code.len or !isIdentChar(code[pos + name.len]);

    if (!before_ok or !after_ok) return false;

    // Check if this is a declaration (identifier followed by ':')
    // e.g., "const PI: f32" - PI is being declared, not used
    const after_pos = pos + @as(u32, @intCast(name.len));
    if (after_pos < code.len) {
        // Skip whitespace after identifier (bounded to 16 chars max)
        var check_pos = after_pos;
        for (0..16) |_| {
            if (check_pos >= code.len) break;
            if (code[check_pos] != ' ' and code[check_pos] != '\t') break;
            check_pos += 1;
        }
        // If followed by ':', this is a declaration - don't substitute
        if (check_pos < code.len and code[check_pos] == ':') {
            return false;
        }
    }

    return true;
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
// WGSL File Loading
// ============================================================================

/// Maximum import depth (prevents unbounded iteration).
const MAX_IMPORT_DEPTH: u32 = 64;

/// Load WGSL code from a value string.
/// If the value is a file path (starts with "./" or "/"), reads from disk.
/// Otherwise treats as inline WGSL code.
/// Memory: Caller owns returned slice.
fn loadWgslValue(e: *Emitter, value: []const u8) Emitter.Error![]u8 {
    // Pre-condition
    std.debug.assert(value.len > 0);

    // Check if it's a file path
    if (isFilePath(value)) {
        const result = try loadWgslFile(e, value);
        // Post-condition: file content is non-empty (empty files are valid but unusual)
        std.debug.assert(result.len > 0 or value.len > 0);
        return result;
    }

    // Inline code - duplicate for caller ownership
    const result = try e.gpa.dupe(u8, value);

    // Post-condition: result matches input length
    std.debug.assert(result.len == value.len);

    return result;
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
    // Pre-conditions
    std.debug.assert(path.len > 0);
    std.debug.assert(isFilePath(path));

    const base_dir = e.options.base_dir orelse ".";
    var path_buf: [4096]u8 = undefined;
    const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ base_dir, path }) catch
        return error.OutOfMemory;

    const result = readFile(e.gpa, full_path) catch |err| {
        std.debug.print("Warning: Could not read WGSL file '{s}': {}\n", .{ full_path, err });
        return error.OutOfMemory;
    };

    // Post-condition: result is a valid slice (length indicates validity)
    // Note: Empty files are valid but unusual for WGSL

    return result;
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

    const node_tag = e.ast.nodes.items(.tag)[macro_node.toInt()];
    const data = e.ast.nodes.items(.data)[macro_node.toInt()];

    // Only #wgsl macros have imports
    if (node_tag != .macro_wgsl) {
        return &[_][]const u8{};
    }

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
/// WARNING: Returns slice into static buffer - caller must copy before any
/// call that might re-enter this function (e.g., resolveWgslWithImports).
fn extractImportNames(e: *Emitter, array_node: Node.Index) []const []const u8 {
    // Pre-condition
    std.debug.assert(array_node.toInt() < e.ast.nodes.len);

    const array_data = e.ast.nodes.items(.data)[array_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Static buffer for import names
    const S = struct {
        var names: [MAX_IMPORTS][]const u8 = undefined;
    };
    var count: u32 = 0;

    for (elements) |elem_idx| {
        if (count >= MAX_IMPORTS) break;

        const elem_node: Node.Index = @enumFromInt(elem_idx);
        const elem_tag = e.ast.nodes.items(.tag)[elem_node.toInt()];

        // Handle bare identifiers (imports=[transform2D primitives])
        if (elem_tag == .identifier_value) {
            const elem_token = e.ast.nodes.items(.main_token)[elem_node.toInt()];
            S.names[count] = utils.getTokenSlice(e, elem_token);
            count += 1;
        }
    }

    // Post-condition: count is bounded
    std.debug.assert(count <= MAX_IMPORTS);

    return S.names[0..count];
}
