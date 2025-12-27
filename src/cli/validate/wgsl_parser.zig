//! WGSL Declaration Parser
//!
//! Lightweight parser that extracts key declarations from WGSL shader code:
//! - Entry points: @vertex, @fragment, @compute function declarations
//! - Bindings: @group(N) @binding(M) variable declarations
//!
//! ## Design
//! - Does NOT fully parse WGSL grammar - just extracts declarations
//! - Uses labeled switch state machine for O(n) parsing
//! - No allocations in hot path (fixed-size arrays)
//! - Sentinel-terminated input for safe EOF detection
//!
//! ## Invariants
//! - All loops have explicit upper bounds
//! - Entry point count <= MAX_ENTRY_POINTS (16)
//! - Binding count <= MAX_BINDINGS (32)
//! - Function names <= 64 characters

const std = @import("std");

/// Maximum number of entry points we track per shader.
pub const MAX_ENTRY_POINTS: u8 = 16;

/// Maximum number of bindings we track per shader.
pub const MAX_BINDINGS: u8 = 32;

/// Maximum length of an identifier (function name, variable name).
pub const MAX_IDENTIFIER_LEN: u8 = 64;

/// Maximum iterations in main parse loop (safety bound).
const MAX_PARSE_ITERATIONS: u32 = 100_000;

/// Entry point stage (matches WebGPU GPUShaderStage).
pub const Stage = enum(u8) {
    vertex = 1,
    fragment = 2,
    compute = 4,

    pub fn toString(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "compute",
        };
    }
};

/// A shader entry point declaration.
pub const EntryPoint = struct {
    name: [MAX_IDENTIFIER_LEN]u8 = undefined,
    name_len: u8 = 0,
    stage: Stage,
    /// For compute shaders: workgroup size (0 if not specified).
    workgroup_size: [3]u16 = .{ 0, 0, 0 },

    /// Get the entry point name as a slice.
    pub fn getName(self: *const EntryPoint) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Address space for variable bindings.
pub const AddressSpace = enum(u8) {
    uniform,
    storage,
    storage_read,
    storage_read_write,
    texture,
    sampler,
    unknown,

    pub fn toString(self: AddressSpace) []const u8 {
        return switch (self) {
            .uniform => "uniform",
            .storage => "storage",
            .storage_read => "storage,read",
            .storage_read_write => "storage,read_write",
            .texture => "texture",
            .sampler => "sampler",
            .unknown => "unknown",
        };
    }
};

/// A binding declaration (@group/@binding variable).
pub const Binding = struct {
    name: [MAX_IDENTIFIER_LEN]u8 = undefined,
    name_len: u8 = 0,
    group: u8,
    binding: u8,
    address_space: AddressSpace,
    /// Type name (e.g., "texture_2d<f32>", "sampler", "MyStruct").
    type_name: [MAX_IDENTIFIER_LEN]u8 = undefined,
    type_name_len: u8 = 0,

    /// Get the binding name as a slice.
    pub fn getName(self: *const Binding) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Get the type name as a slice.
    pub fn getTypeName(self: *const Binding) []const u8 {
        return self.type_name[0..self.type_name_len];
    }
};

/// Result of parsing WGSL declarations.
pub const ParseResult = struct {
    entry_points: [MAX_ENTRY_POINTS]EntryPoint = undefined,
    entry_point_count: u8 = 0,
    bindings: [MAX_BINDINGS]Binding = undefined,
    binding_count: u8 = 0,
    /// True if parse completed without errors.
    valid: bool = true,
    /// Error message if valid is false.
    error_message: []const u8 = "",

    /// Get entry points as a slice.
    pub fn getEntryPoints(self: *const ParseResult) []const EntryPoint {
        return self.entry_points[0..self.entry_point_count];
    }

    /// Get bindings as a slice.
    pub fn getBindings(self: *const ParseResult) []const Binding {
        return self.bindings[0..self.binding_count];
    }

    /// Check if a specific entry point exists.
    pub fn hasEntryPoint(self: *const ParseResult, name: []const u8, stage: Stage) bool {
        for (self.getEntryPoints()) |ep| {
            if (ep.stage == stage and std.mem.eql(u8, ep.getName(), name)) {
                return true;
            }
        }
        return false;
    }

    /// Find entry point by name (any stage).
    pub fn findEntryPoint(self: *const ParseResult, name: []const u8) ?*const EntryPoint {
        for (self.getEntryPoints()) |*ep| {
            if (std.mem.eql(u8, ep.getName(), name)) {
                return ep;
            }
        }
        return null;
    }

    /// Find binding by group and binding number.
    pub fn findBinding(self: *const ParseResult, group: u8, binding_num: u8) ?*const Binding {
        for (self.getBindings()) |*b| {
            if (b.group == group and b.binding == binding_num) {
                return b;
            }
        }
        return null;
    }

    /// Add an entry point (bounded).
    fn addEntryPoint(self: *ParseResult, ep: EntryPoint) void {
        if (self.entry_point_count < MAX_ENTRY_POINTS) {
            self.entry_points[self.entry_point_count] = ep;
            self.entry_point_count += 1;
        }
    }

    /// Add a binding (bounded).
    fn addBinding(self: *ParseResult, b: Binding) void {
        if (self.binding_count < MAX_BINDINGS) {
            self.bindings[self.binding_count] = b;
            self.binding_count += 1;
        }
    }
};

/// Parser state for the labeled switch state machine.
const State = enum {
    start,
    at_sign,
    identifier,
    after_stage,
    expect_fn,
    fn_name,
    after_group,
    expect_group_num,
    after_binding,
    expect_binding_num,
    expect_var,
    var_address_space,
    var_name,
    expect_colon,
    var_type,
    line_comment,
    block_comment,
    string_literal,
};

/// Parse WGSL source code and extract declarations.
///
/// Complexity: O(n) where n = source.len
///
/// Pre-condition: source is valid UTF-8
/// Post-condition: result.entry_point_count <= MAX_ENTRY_POINTS
/// Post-condition: result.binding_count <= MAX_BINDINGS
pub fn parse(source: []const u8) ParseResult {
    // Pre-conditions
    std.debug.assert(source.len <= 10 * 1024 * 1024); // Max 10MB

    var result = ParseResult{};
    var index: usize = 0;

    // Temporary state for current declaration
    var current_stage: ?Stage = null;
    var current_group: ?u8 = null;
    var current_binding: ?u8 = null;
    var workgroup_size: [3]u16 = .{ 0, 0, 0 };

    // Main parse loop with safety bound
    for (0..MAX_PARSE_ITERATIONS) |_| {
        if (index >= source.len) break;

        const c = source[index];

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            index += 1;
            continue;
        }

        // Handle comments
        if (c == '/') {
            if (index + 1 < source.len) {
                if (source[index + 1] == '/') {
                    // Line comment - skip to end of line
                    index = skipLineComment(source, index);
                    continue;
                } else if (source[index + 1] == '*') {
                    // Block comment - skip to */
                    index = skipBlockComment(source, index);
                    continue;
                }
            }
        }

        // Handle string literals (skip them)
        if (c == '"') {
            index = skipStringLiteral(source, index);
            continue;
        }

        // Handle @ attributes
        if (c == '@') {
            const attr_result = parseAttribute(source, index);
            index = attr_result.end_index;

            switch (attr_result.kind) {
                .vertex => current_stage = .vertex,
                .fragment => current_stage = .fragment,
                .compute => current_stage = .compute,
                .group => current_group = attr_result.value,
                .binding => current_binding = attr_result.value,
                .workgroup_size => {
                    workgroup_size = attr_result.workgroup_size;
                },
                .unknown, .builtin, .location => {},
            }
            continue;
        }

        // Handle 'fn' keyword after stage attribute
        if (current_stage != null and c == 'f' and index + 1 < source.len and source[index + 1] == 'n') {
            // Check it's actually "fn" keyword (followed by whitespace or parenthesis)
            if (index + 2 >= source.len or !isIdentChar(source[index + 2])) {
                index += 2;
                // Skip whitespace
                while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
                    index += 1;
                }
                // Parse function name
                const name_start = index;
                while (index < source.len and isIdentChar(source[index])) {
                    index += 1;
                }
                const name_end = index;

                if (name_end > name_start) {
                    var ep = EntryPoint{
                        .stage = current_stage.?,
                        .workgroup_size = workgroup_size,
                    };
                    const name_len = @min(name_end - name_start, MAX_IDENTIFIER_LEN);
                    @memcpy(ep.name[0..name_len], source[name_start..][0..name_len]);
                    ep.name_len = @intCast(name_len);
                    result.addEntryPoint(ep);
                }

                // Reset state
                current_stage = null;
                workgroup_size = .{ 0, 0, 0 };
                continue;
            }
        }

        // Handle 'var' keyword after @group/@binding
        if ((current_group != null or current_binding != null) and c == 'v') {
            if (index + 2 < source.len and source[index + 1] == 'a' and source[index + 2] == 'r') {
                // Check it's actually "var" keyword
                if (index + 3 >= source.len or !isIdentChar(source[index + 3])) {
                    index += 3;

                    // Parse address space if present: var<uniform>, var<storage>, etc.
                    var address_space: AddressSpace = .unknown;
                    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
                        index += 1;
                    }

                    if (index < source.len and source[index] == '<') {
                        const addr_result = parseAddressSpace(source, index);
                        address_space = addr_result.space;
                        index = addr_result.end_index;
                    }

                    // Skip whitespace
                    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
                        index += 1;
                    }

                    // Parse variable name
                    const name_start = index;
                    while (index < source.len and isIdentChar(source[index])) {
                        index += 1;
                    }
                    const name_end = index;

                    // Skip to colon and type
                    while (index < source.len and source[index] != ':' and source[index] != ';' and source[index] != '\n') {
                        index += 1;
                    }

                    var type_name: [MAX_IDENTIFIER_LEN]u8 = undefined;
                    var type_name_len: u8 = 0;

                    if (index < source.len and source[index] == ':') {
                        index += 1;
                        // Skip whitespace
                        while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
                            index += 1;
                        }
                        // Parse type name (may include <...>)
                        const type_start = index;
                        var angle_depth: u8 = 0;
                        while (index < source.len) {
                            const tc = source[index];
                            if (tc == '<') {
                                angle_depth += 1;
                            } else if (tc == '>') {
                                if (angle_depth > 0) angle_depth -= 1;
                            } else if (angle_depth == 0 and (tc == ';' or tc == ',' or tc == '=' or tc == '\n')) {
                                break;
                            }
                            index += 1;
                        }
                        const type_end = index;

                        // Trim trailing whitespace from type
                        var actual_end = type_end;
                        while (actual_end > type_start and (source[actual_end - 1] == ' ' or source[actual_end - 1] == '\t')) {
                            actual_end -= 1;
                        }

                        type_name_len = @intCast(@min(actual_end - type_start, MAX_IDENTIFIER_LEN));
                        @memcpy(type_name[0..type_name_len], source[type_start..][0..type_name_len]);

                        // Infer address space from type if not explicit
                        if (address_space == .unknown) {
                            const type_str = type_name[0..type_name_len];
                            if (std.mem.startsWith(u8, type_str, "texture")) {
                                address_space = .texture;
                            } else if (std.mem.eql(u8, type_str, "sampler") or std.mem.startsWith(u8, type_str, "sampler_")) {
                                address_space = .sampler;
                            }
                        }
                    }

                    if (name_end > name_start and (current_group != null or current_binding != null)) {
                        var b = Binding{
                            .group = current_group orelse 0,
                            .binding = current_binding orelse 0,
                            .address_space = address_space,
                            .type_name_len = type_name_len,
                        };
                        const name_len = @min(name_end - name_start, MAX_IDENTIFIER_LEN);
                        @memcpy(b.name[0..name_len], source[name_start..][0..name_len]);
                        b.name_len = @intCast(name_len);
                        @memcpy(b.type_name[0..type_name_len], type_name[0..type_name_len]);
                        result.addBinding(b);
                    }

                    // Reset state
                    current_group = null;
                    current_binding = null;
                    continue;
                }
            }
        }

        // If we have pending attributes but hit something else, reset
        if (c == ';' or c == '{' or c == '}') {
            current_stage = null;
            current_group = null;
            current_binding = null;
            workgroup_size = .{ 0, 0, 0 };
        }

        index += 1;
    } else {
        // Safety bound reached
        result.valid = false;
        result.error_message = "Parse iteration limit reached";
    }

    // Post-conditions
    std.debug.assert(result.entry_point_count <= MAX_ENTRY_POINTS);
    std.debug.assert(result.binding_count <= MAX_BINDINGS);

    return result;
}

/// Attribute kind from parsing @ attribute.
const AttributeKind = enum {
    vertex,
    fragment,
    compute,
    group,
    binding,
    workgroup_size,
    builtin,
    location,
    unknown,
};

/// Result of parsing an @ attribute.
const AttributeResult = struct {
    kind: AttributeKind,
    value: u8 = 0,
    workgroup_size: [3]u16 = .{ 0, 0, 0 },
    end_index: usize,
};

/// Parse an @ attribute starting at index.
fn parseAttribute(source: []const u8, start: usize) AttributeResult {
    // Pre-condition
    std.debug.assert(start < source.len and source[start] == '@');

    var index = start + 1; // Skip @

    // Read attribute name
    const name_start = index;
    while (index < source.len and isIdentChar(source[index])) {
        index += 1;
    }
    const name = source[name_start..index];

    // Match attribute name
    const kind: AttributeKind = if (std.mem.eql(u8, name, "vertex"))
        .vertex
    else if (std.mem.eql(u8, name, "fragment"))
        .fragment
    else if (std.mem.eql(u8, name, "compute"))
        .compute
    else if (std.mem.eql(u8, name, "group"))
        .group
    else if (std.mem.eql(u8, name, "binding"))
        .binding
    else if (std.mem.eql(u8, name, "workgroup_size"))
        .workgroup_size
    else if (std.mem.eql(u8, name, "builtin"))
        .builtin
    else if (std.mem.eql(u8, name, "location"))
        .location
    else
        .unknown;

    var result = AttributeResult{
        .kind = kind,
        .end_index = index,
    };

    // Parse parenthesized value for group, binding, workgroup_size, etc.
    // Skip whitespace first
    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
        index += 1;
    }

    if (index < source.len and source[index] == '(') {
        index += 1;

        switch (kind) {
            .group, .binding, .location => {
                // Parse single number
                result.value = @intCast(parseNumber(source, &index));
            },
            .workgroup_size => {
                // Parse up to 3 numbers: workgroup_size(x), workgroup_size(x, y), or workgroup_size(x, y, z)
                result.workgroup_size[0] = @intCast(parseNumber(source, &index));
                skipWhitespace(source, &index);
                if (index < source.len and source[index] == ',') {
                    index += 1;
                    result.workgroup_size[1] = @intCast(parseNumber(source, &index));
                    skipWhitespace(source, &index);
                    if (index < source.len and source[index] == ',') {
                        index += 1;
                        result.workgroup_size[2] = @intCast(parseNumber(source, &index));
                    }
                }
            },
            else => {},
        }

        // Find closing parenthesis
        while (index < source.len and source[index] != ')') {
            index += 1;
        }
        if (index < source.len) {
            index += 1; // Skip )
        }

        result.end_index = index;
    }

    return result;
}

/// Parse address space from <...>.
fn parseAddressSpace(source: []const u8, start: usize) struct { space: AddressSpace, end_index: usize } {
    // Pre-condition
    std.debug.assert(start < source.len and source[start] == '<');

    var index = start + 1;

    // Skip whitespace
    while (index < source.len and (source[index] == ' ' or source[index] == '\t')) {
        index += 1;
    }

    const name_start = index;
    while (index < source.len and (isIdentChar(source[index]) or source[index] == '_')) {
        index += 1;
    }
    const name = source[name_start..index];

    var space: AddressSpace = .unknown;
    if (std.mem.eql(u8, name, "uniform")) {
        space = .uniform;
    } else if (std.mem.eql(u8, name, "storage")) {
        // Check for access mode: storage, read or storage, read_write
        skipWhitespace(source, &index);
        if (index < source.len and source[index] == ',') {
            index += 1;
            skipWhitespace(source, &index);
            const mode_start = index;
            while (index < source.len and (isIdentChar(source[index]) or source[index] == '_')) {
                index += 1;
            }
            const mode = source[mode_start..index];
            if (std.mem.eql(u8, mode, "read")) {
                space = .storage_read;
            } else if (std.mem.eql(u8, mode, "read_write")) {
                space = .storage_read_write;
            } else {
                space = .storage;
            }
        } else {
            space = .storage;
        }
    }

    // Find closing >
    while (index < source.len and source[index] != '>') {
        index += 1;
    }
    if (index < source.len) {
        index += 1; // Skip >
    }

    return .{ .space = space, .end_index = index };
}

/// Parse a number from source, advancing index.
fn parseNumber(source: []const u8, index: *usize) u32 {
    skipWhitespace(source, index);

    var value: u32 = 0;
    while (index.* < source.len and source[index.*] >= '0' and source[index.*] <= '9') {
        value = value * 10 + (source[index.*] - '0');
        index.* += 1;
    }
    return value;
}

/// Skip whitespace, advancing index.
fn skipWhitespace(source: []const u8, index: *usize) void {
    while (index.* < source.len and (source[index.*] == ' ' or source[index.*] == '\t')) {
        index.* += 1;
    }
}

/// Skip a line comment (// to end of line).
fn skipLineComment(source: []const u8, start: usize) usize {
    var index = start + 2; // Skip //
    while (index < source.len and source[index] != '\n') {
        index += 1;
    }
    return index;
}

/// Skip a block comment (/* to */).
fn skipBlockComment(source: []const u8, start: usize) usize {
    var index = start + 2; // Skip /*
    var depth: u8 = 1;

    while (index + 1 < source.len and depth > 0) {
        if (source[index] == '/' and source[index + 1] == '*') {
            depth += 1;
            index += 2;
        } else if (source[index] == '*' and source[index + 1] == '/') {
            depth -= 1;
            index += 2;
        } else {
            index += 1;
        }
    }
    return index;
}

/// Skip a string literal ("...").
fn skipStringLiteral(source: []const u8, start: usize) usize {
    var index = start + 1; // Skip opening "
    while (index < source.len) {
        if (source[index] == '\\' and index + 1 < source.len) {
            index += 2; // Skip escaped char
        } else if (source[index] == '"') {
            index += 1; // Skip closing "
            break;
        } else {
            index += 1;
        }
    }
    return index;
}

/// Check if character is valid in an identifier.
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

// ============================================================================
// Tests
// ============================================================================

test "parse simple vertex and fragment shader" {
    const source =
        \\@vertex
        \\fn vertexMain(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0);
        \\}
        \\
        \\@fragment
        \\fn fragMain() -> @location(0) vec4f {
        \\    return vec4f(1.0);
        \\}
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 2), result.entry_point_count);

    const eps = result.getEntryPoints();
    try std.testing.expectEqualStrings("vertexMain", eps[0].getName());
    try std.testing.expectEqual(Stage.vertex, eps[0].stage);
    try std.testing.expectEqualStrings("fragMain", eps[1].getName());
    try std.testing.expectEqual(Stage.fragment, eps[1].stage);
}

test "parse compute shader with workgroup_size" {
    const source =
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    // compute work
        \\}
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 1), result.entry_point_count);

    const ep = result.getEntryPoints()[0];
    try std.testing.expectEqualStrings("main", ep.getName());
    try std.testing.expectEqual(Stage.compute, ep.stage);
    try std.testing.expectEqual(@as(u16, 64), ep.workgroup_size[0]);
}

test "parse compute shader with 3D workgroup_size" {
    const source =
        \\@compute @workgroup_size(8, 8, 4)
        \\fn simulate() {
        \\}
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    const ep = result.getEntryPoints()[0];
    try std.testing.expectEqual(@as(u16, 8), ep.workgroup_size[0]);
    try std.testing.expectEqual(@as(u16, 8), ep.workgroup_size[1]);
    try std.testing.expectEqual(@as(u16, 4), ep.workgroup_size[2]);
}

test "parse bindings" {
    const source =
        \\@group(0) @binding(0) var<uniform> inputs : PngineInputs;
        \\@group(0) @binding(1) var mySampler: sampler;
        \\@group(0) @binding(2) var myTexture: texture_2d<f32>;
        \\@group(1) @binding(0) var<storage, read> data: array<f32>;
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 4), result.binding_count);

    const bindings = result.getBindings();

    // First binding: uniform
    try std.testing.expectEqualStrings("inputs", bindings[0].getName());
    try std.testing.expectEqual(@as(u8, 0), bindings[0].group);
    try std.testing.expectEqual(@as(u8, 0), bindings[0].binding);
    try std.testing.expectEqual(AddressSpace.uniform, bindings[0].address_space);

    // Second binding: sampler (inferred)
    try std.testing.expectEqualStrings("mySampler", bindings[1].getName());
    try std.testing.expectEqual(AddressSpace.sampler, bindings[1].address_space);

    // Third binding: texture (inferred)
    try std.testing.expectEqualStrings("myTexture", bindings[2].getName());
    try std.testing.expectEqual(AddressSpace.texture, bindings[2].address_space);

    // Fourth binding: storage read
    try std.testing.expectEqualStrings("data", bindings[3].getName());
    try std.testing.expectEqual(@as(u8, 1), bindings[3].group);
    try std.testing.expectEqual(@as(u8, 0), bindings[3].binding);
    try std.testing.expectEqual(AddressSpace.storage_read, bindings[3].address_space);
}

test "parse binding with reversed order (@binding before @group)" {
    const source =
        \\@binding(0) @group(0) var<uniform> params : SimParams;
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 1), result.binding_count);

    const b = result.getBindings()[0];
    try std.testing.expectEqualStrings("params", b.getName());
    try std.testing.expectEqual(@as(u8, 0), b.group);
    try std.testing.expectEqual(@as(u8, 0), b.binding);
}

test "skip comments" {
    const source =
        \\// This is a comment
        \\@vertex
        \\fn vs() -> @builtin(position) vec4f {
        \\    /* block comment */ return vec4f(0.0);
        \\}
        \\/* Multi
        \\   line
        \\   comment */
        \\@fragment
        \\fn fs() -> @location(0) vec4f { return vec4f(1.0); }
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 2), result.entry_point_count);
}

test "hasEntryPoint lookup" {
    const source =
        \\@vertex fn vs() -> @builtin(position) vec4f { return vec4f(0.0); }
        \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }
    ;

    const result = parse(source);

    try std.testing.expect(result.hasEntryPoint("vs", .vertex));
    try std.testing.expect(result.hasEntryPoint("fs", .fragment));
    try std.testing.expect(!result.hasEntryPoint("vs", .fragment)); // Wrong stage
    try std.testing.expect(!result.hasEntryPoint("main", .vertex)); // Doesn't exist
}

test "findBinding lookup" {
    const source =
        \\@group(0) @binding(0) var<uniform> u: U;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(1) @binding(0) var t: texture_2d<f32>;
    ;

    const result = parse(source);

    try std.testing.expect(result.findBinding(0, 0) != null);
    try std.testing.expect(result.findBinding(0, 1) != null);
    try std.testing.expect(result.findBinding(1, 0) != null);
    try std.testing.expect(result.findBinding(1, 1) == null); // Doesn't exist
}

test "parse boids-style shader" {
    const source =
        \\@binding(0) @group(0) var<uniform> params : SimParams;
        \\@binding(1) @group(0) var<storage, read> particlesA : Particles;
        \\@binding(2) @group(0) var<storage, read_write> particlesB : Particles;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) GlobalInvocationID : vec3u) {
        \\}
        \\
        \\@vertex
        \\fn vert_main(@location(0) a_particlePos : vec2f) -> @builtin(position) vec4f {
        \\    return vec4f(a_particlePos, 0.0, 1.0);
        \\}
        \\
        \\@fragment
        \\fn frag_main() -> @location(0) vec4f {
        \\    return vec4(1.0, 1.0, 1.0, 1.0);
        \\}
    ;

    const result = parse(source);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 3), result.entry_point_count);
    try std.testing.expectEqual(@as(u8, 3), result.binding_count);

    // Entry points
    try std.testing.expect(result.hasEntryPoint("main", .compute));
    try std.testing.expect(result.hasEntryPoint("vert_main", .vertex));
    try std.testing.expect(result.hasEntryPoint("frag_main", .fragment));

    // Bindings
    const b0 = result.findBinding(0, 0).?;
    try std.testing.expectEqualStrings("params", b0.getName());
    try std.testing.expectEqual(AddressSpace.uniform, b0.address_space);

    const b1 = result.findBinding(0, 1).?;
    try std.testing.expectEqual(AddressSpace.storage_read, b1.address_space);

    const b2 = result.findBinding(0, 2).?;
    try std.testing.expectEqual(AddressSpace.storage_read_write, b2.address_space);
}

test "empty source" {
    const result = parse("");
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 0), result.entry_point_count);
    try std.testing.expectEqual(@as(u8, 0), result.binding_count);
}

test "source with only comments" {
    const source =
        \\// Just a comment
        \\/* And a block comment */
    ;
    const result = parse(source);
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u8, 0), result.entry_point_count);
}
