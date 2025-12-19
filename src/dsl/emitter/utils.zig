//! Emitter Utility Functions
//!
//! Property lookup, parsing, and resolution helpers for the DSL emitter.
//! All functions receive `*Emitter` as first parameter to access AST and state.
//!
//! ## Invariants
//!
//! * Property lookups return null if property not found (never panic).
//! * References are always namespace.name format ($namespace.name).
//! * String content extraction strips surrounding quotes.
//! * Number parsing returns null on invalid input (never panic).
//! * Resource ID resolution returns null if resource not registered.
//! * All iteration over AST nodes is bounded by slice length.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const opcodes = @import("../../bytecode/opcodes.zig");
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;

/// Reference to a named resource in a namespace (e.g., $buffer.name).
pub const Reference = struct {
    namespace: []const u8,
    name: []const u8,
};

// ============================================================================
// Property Lookup
// ============================================================================

/// Find a property value by name in a macro node.
pub fn findPropertyValue(e: *Emitter, macro_node: Node.Index, prop_name: []const u8) ?Node.Index {
    // Pre-conditions
    std.debug.assert(macro_node.toInt() < e.ast.nodes.len);
    std.debug.assert(prop_name.len > 0);

    const data = e.ast.nodes.items(.data)[macro_node.toInt()];
    const props = e.ast.extraData(data.extra_range);

    for (props) |prop_idx| {
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const name = getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, name, prop_name)) {
            const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
            return prop_data.node;
        }
    }

    return null;
}

/// Find a property value inside an object node.
pub fn findPropertyValueInObject(e: *Emitter, object_node: Node.Index, prop_name: []const u8) ?Node.Index {
    // Pre-conditions
    std.debug.assert(object_node.toInt() < e.ast.nodes.len);
    std.debug.assert(prop_name.len > 0);

    const obj_tag = e.ast.nodes.items(.tag)[object_node.toInt()];
    if (obj_tag != .object) return null;

    const obj_data = e.ast.nodes.items(.data)[object_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |prop_idx| {
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const name = getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, name, prop_name)) {
            const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
            return prop_data.node;
        }
    }

    return null;
}

/// Get a reference from a property node's value.
pub fn findPropertyReference(e: *Emitter, prop_node: Node.Index) ?Reference {
    // Pre-conditions
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const value_node = prop_data.node;
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .reference) {
        const result = getReference(e, value_node);
        // Post-condition: if returning a reference, both parts are non-empty
        if (result) |ref| {
            std.debug.assert(ref.namespace.len > 0);
        }
        return result;
    }
    return null;
}

/// Extract Reference from a reference node.
/// Supports multi-part names like $wgsl.shader.binding (name="shader.binding").
pub fn getReference(e: *Emitter, node: Node.Index) ?Reference {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.tokens.len > 0);

    const data = e.ast.nodes.items(.data)[node.toInt()];
    const namespace_token = data.node_and_node[0];
    const name_token = data.node_and_node[1];

    const namespace = getTokenSlice(e, namespace_token);

    // For multi-part references, extract full name from source
    // namespace_token + 2 is the first name token (after namespace and dot)
    const name = if (name_token > namespace_token + 2)
        getTokenRange(e, namespace_token + 2, name_token)
    else
        getTokenSlice(e, name_token);

    const result = Reference{
        .namespace = namespace,
        .name = name,
    };

    // Post-condition: namespace is never empty for valid references
    std.debug.assert(result.namespace.len > 0);

    return result;
}

/// Get source text spanning from start_token to end_token (inclusive).
fn getTokenRange(e: *Emitter, start_token: u32, end_token: u32) []const u8 {
    // Pre-conditions
    std.debug.assert(start_token < e.ast.tokens.len);
    std.debug.assert(end_token < e.ast.tokens.len);
    std.debug.assert(start_token <= end_token);

    const starts = e.ast.tokens.items(.start);
    const start = starts[start_token];

    // End is the start of the token after end_token (or source end)
    const end: u32 = if (end_token + 1 < starts.len)
        starts[end_token + 1]
    else
        @intCast(e.ast.source.len);

    // Trim trailing whitespace
    var slice = e.ast.source[start..end];
    for (0..32) |_| {
        if (slice.len == 0) break;
        const last = slice[slice.len - 1];
        if (last != ' ' and last != '\n' and last != '\t' and last != '\r') break;
        slice = slice[0 .. slice.len - 1];
    }

    return slice;
}

// ============================================================================
// Value Extraction
// ============================================================================

/// Get string content from a string_value node, stripping quotes.
pub fn getStringContent(e: *Emitter, value_node: Node.Index) []const u8 {
    // Pre-conditions
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.source.len > 0);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    // Handle both regular strings and runtime interpolations (strings with $)
    if (value_tag != .string_value and value_tag != .runtime_interpolation) return "";

    const value_token = e.ast.nodes.items(.main_token)[value_node.toInt()];
    const raw = getTokenSlice(e, value_token);

    // Strip quotes
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        const result = raw[1 .. raw.len - 1];
        // Post-condition: result length is raw length minus 2 (quotes)
        std.debug.assert(result.len == raw.len - 2);
        return result;
    }
    return raw;
}

/// Get text content from a node's main token.
pub fn getNodeText(e: *Emitter, node: Node.Index) []const u8 {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.tokens.len > 0);

    const token = e.ast.nodes.items(.main_token)[node.toInt()];
    // Pre-condition: token index is valid
    std.debug.assert(token < e.ast.tokens.len);

    return getTokenSlice(e, token);
}

/// Get the source slice for a token, trimming trailing whitespace.
/// Returns the trimmed token text from source. Result is a view into source buffer.
pub fn getTokenSlice(e: *Emitter, token_index: u32) []const u8 {
    // Pre-conditions
    std.debug.assert(token_index < e.ast.tokens.len);
    std.debug.assert(e.ast.source.len > 0);

    const starts = e.ast.tokens.items(.start);
    const start = starts[token_index];
    const end: u32 = if (token_index + 1 < starts.len)
        starts[token_index + 1]
    else
        @intCast(e.ast.source.len);

    // Pre-condition: start <= end (valid range)
    std.debug.assert(start <= end);

    // Trim whitespace (bounded loop for safety)
    var slice = e.ast.source[start..end];
    const max_trim: usize = 64; // Reasonable max whitespace to trim
    for (0..max_trim) |_| {
        if (slice.len == 0) break;
        const last = slice[slice.len - 1];
        if (last == ' ' or last == '\n' or last == '\t' or last == '\r') {
            slice = slice[0 .. slice.len - 1];
        } else {
            break;
        }
    }
    return slice;
}

/// Get identifier or string value text (handles both node types).
pub fn getIdentifierOrStringValue(e: *Emitter, value_node: Node.Index) []const u8 {
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (value_tag == .string_value) {
        return getStringContent(e, value_node);
    }
    return getNodeText(e, value_node);
}

// ============================================================================
// Number Parsing
// ============================================================================

/// Parse a number_value node as u32.
pub fn parseNumber(e: *Emitter, value_node: Node.Index) ?u32 {
    // Pre-conditions
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (value_tag != .number_value) return null;

    const value_token = e.ast.nodes.items(.main_token)[value_node.toInt()];
    const text = getTokenSlice(e, value_token);

    return std.fmt.parseInt(u32, text, 10) catch null;
}

/// Parse a number_value node as f64.
pub fn parseFloatNumber(e: *Emitter, value_node: Node.Index) ?f64 {
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (value_tag != .number_value) return null;

    const value_token = e.ast.nodes.items(.main_token)[value_node.toInt()];
    const text = getTokenSlice(e, value_token);

    return std.fmt.parseFloat(f64, text) catch null;
}

/// Parse a property as u32.
pub fn parsePropertyNumber(e: *Emitter, node: Node.Index, prop_name: []const u8) ?u32 {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(prop_name.len > 0);

    const value = findPropertyValue(e, node, prop_name) orelse return null;
    return parseNumber(e, value);
}

/// Parse a boolean value (identifier true/false).
pub fn parseBoolValue(e: *Emitter, value_node: Node.Index) bool {
    // Pre-conditions
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const text = getNodeText(e, value_node);
    return std.mem.eql(u8, text, "true");
}

// ============================================================================
// Expression Resolution
// ============================================================================

/// Resolve a node to its numeric u32 value.
/// Handles: number literals, identifier refs to #define, expression trees.
pub fn resolveNumericValue(e: *Emitter, value_node: Node.Index) ?u32 {
    // Pre-condition
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    // Direct number literal
    if (value_tag == .number_value) {
        const value_token = e.ast.nodes.items(.main_token)[value_node.toInt()];
        const text = getTokenSlice(e, value_token);
        return std.fmt.parseInt(u32, text, 10) catch null;
    }

    // Identifier - look up in defines, data declarations, and recursively resolve
    if (value_tag == .identifier_value) {
        const name = getNodeText(e, value_node);

        // Check #define first
        if (e.analysis.symbols.define.get(name)) |def_info| {
            const define_value = e.ast.nodes.items(.data)[def_info.node.toInt()].node;
            return resolveNumericValue(e, define_value);
        }

        // Check #data - return byte size of the data array
        if (e.analysis.symbols.data.get(name)) |data_info| {
            return calculateDataByteSize(e, data_info.node);
        }

        return null;
    }

    // Expression nodes: evaluate the expression tree
    const data = e.ast.nodes.items(.data)[value_node.toInt()];
    switch (value_tag) {
        .expr_mul => {
            const lhs: Node.Index = @enumFromInt(data.node_and_node[0]);
            const rhs: Node.Index = @enumFromInt(data.node_and_node[1]);
            const left = resolveNumericValue(e, lhs) orelse return null;
            const right = resolveNumericValue(e, rhs) orelse return null;
            return left * right;
        },
        .expr_add => {
            const lhs: Node.Index = @enumFromInt(data.node_and_node[0]);
            const rhs: Node.Index = @enumFromInt(data.node_and_node[1]);
            const left = resolveNumericValue(e, lhs) orelse return null;
            const right = resolveNumericValue(e, rhs) orelse return null;
            return left + right;
        },
        .expr_sub => {
            const lhs: Node.Index = @enumFromInt(data.node_and_node[0]);
            const rhs: Node.Index = @enumFromInt(data.node_and_node[1]);
            const left = resolveNumericValue(e, lhs) orelse return null;
            const right = resolveNumericValue(e, rhs) orelse return null;
            return left -| right; // Saturating subtraction
        },
        .expr_div => {
            const lhs: Node.Index = @enumFromInt(data.node_and_node[0]);
            const rhs: Node.Index = @enumFromInt(data.node_and_node[1]);
            const left = resolveNumericValue(e, lhs) orelse return null;
            const right = resolveNumericValue(e, rhs) orelse return null;
            if (right == 0) return null;
            return left / right;
        },
        else => return null,
    }
}

/// Resolve numeric value including string expressions.
/// Handles #define substitution and functions like ceil().
pub fn resolveNumericValueOrString(e: *Emitter, value_node: Node.Index) ?u32 {
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .string_value) {
        const text = getStringContent(e, value_node);
        return parseExpressionWithDefines(e, text);
    }

    return resolveNumericValue(e, value_node);
}

/// Parse expression with #define substitution and function support.
/// Supports: integers, +, *, /, ceil(), and #define references.
fn parseExpressionWithDefines(e: *Emitter, expr: []const u8) ?u32 {
    var buffer: [256]u8 = undefined;
    var result = substituteDefines(e, expr, &buffer) orelse return null;

    // Handle ceil() function
    if (std.mem.startsWith(u8, result, "ceil(") and result[result.len - 1] == ')') {
        const inner = result[5 .. result.len - 1];
        const inner_value = parseArithmeticExpression(inner) orelse return null;
        return inner_value; // ceil of integer division is already handled
    }

    return parseArithmeticExpression(result);
}

/// Substitute #define references in expression string.
fn substituteDefines(e: *Emitter, expr: []const u8, buffer: *[256]u8) ?[]const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    const max_iterations: usize = 256;

    for (0..max_iterations) |_| {
        if (i >= expr.len) break;

        const c = expr[i];

        // Check for identifier start
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = i;
            while (i < expr.len and (std.ascii.isAlphanumeric(expr[i]) or expr[i] == '_')) : (i += 1) {}
            const ident = expr[start..i];

            // Look up in defines (via symbol table)
            if (e.analysis.symbols.define.get(ident)) |def_info| {
                // Get the define's value node and resolve it
                const define_value_node = e.ast.nodes.items(.data)[def_info.node.toInt()].node;
                if (resolveNumericValue(e, define_value_node)) |define_value| {
                    // Append the define value
                    const value_str = std.fmt.bufPrint(buffer[pos..], "{d}", .{define_value}) catch return null;
                    pos += value_str.len;
                } else {
                    // Define exists but couldn't resolve value - keep identifier
                    if (pos + ident.len > buffer.len) return null;
                    @memcpy(buffer[pos..][0..ident.len], ident);
                    pos += ident.len;
                }
            } else {
                // Not a define, keep as-is (might be a function name)
                if (pos + ident.len > buffer.len) return null;
                @memcpy(buffer[pos..][0..ident.len], ident);
                pos += ident.len;
            }
        } else {
            // Copy character as-is
            if (pos >= buffer.len) return null;
            buffer[pos] = c;
            pos += 1;
            i += 1;
        }
    }

    return buffer[0..pos];
}

/// Parse arithmetic expression with +, *, / operators.
fn parseArithmeticExpression(expr: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return null;

    // Try simple integer first
    if (std.fmt.parseInt(u32, trimmed, 10)) |val| {
        return val;
    } else |_| {}

    // Handle addition (lowest precedence)
    if (std.mem.indexOf(u8, trimmed, "+")) |_| {
        var sum: u32 = 0;
        var it = std.mem.splitScalar(u8, trimmed, '+');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t");
            const part_value = parseMulDiv(part_trimmed) orelse return null;
            sum += part_value;
        }
        return sum;
    }

    return parseMulDiv(trimmed);
}

/// Parse multiplication and division (handles "4*4", "2048/64", "4*4/2").
fn parseMulDiv(expr: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, expr, " \t");
    if (trimmed.len == 0) return null;

    // Check for * or /
    var has_ops = false;
    for (trimmed) |c| {
        if (c == '*' or c == '/') {
            has_ops = true;
            break;
        }
    }

    if (!has_ops) {
        return std.fmt.parseInt(u32, trimmed, 10) catch null;
    }

    // Parse left to right (handles chained operations)
    var result: u32 = 0;
    var current_num: u32 = 0;
    var last_op: u8 = '+'; // Start with implicit add
    var i: usize = 0;

    while (i <= trimmed.len) : (i += 1) {
        const c = if (i < trimmed.len) trimmed[i] else 0;

        if (c == '*' or c == '/' or c == 0) {
            // Apply pending operation
            switch (last_op) {
                '+' => result = current_num,
                '*' => result *= current_num,
                '/' => {
                    if (current_num == 0) return null;
                    // Use ceiling division for ceil(a/b) pattern
                    result = (result + current_num - 1) / current_num;
                },
                else => {},
            }
            last_op = c;
            current_num = 0;
        } else if (std.ascii.isDigit(c)) {
            current_num = current_num * 10 + (c - '0');
        } else if (c != ' ' and c != '\t') {
            return null; // Invalid character
        }
    }

    return result;
}

/// Parse a string containing a simple arithmetic expression.
/// Supports: integers, +, *, and combinations thereof (e.g., "4*4*4", "4+4+4").
/// Operator precedence: * before + (standard math rules).
pub fn parseStringExpression(expr: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, expr, " \t\n\r");
    if (trimmed.len == 0) return null;

    // Try simple integer first
    if (std.fmt.parseInt(u32, trimmed, 10)) |val| {
        return val;
    } else |_| {}

    // Handle addition: split by + and sum (+ has lower precedence than *)
    if (std.mem.indexOf(u8, trimmed, "+")) |_| {
        var sum: u32 = 0;
        var it = std.mem.splitScalar(u8, trimmed, '+');
        while (it.next()) |part| {
            const part_trimmed = std.mem.trim(u8, part, " \t");
            // Each part may contain multiplication - parse recursively
            const part_value = parseMultiplication(part_trimmed) orelse return null;
            sum += part_value;
        }
        return sum;
    }

    // No addition - try multiplication only
    return parseMultiplication(trimmed);
}

/// Parse multiplication expression (handles chained: "4*4*4" -> 64).
/// Maximum 8 operands to bound iteration.
fn parseMultiplication(expr: []const u8) ?u32 {
    // Pre-condition
    std.debug.assert(expr.len > 0);

    // Check if contains *
    if (std.mem.indexOf(u8, expr, "*") == null) {
        // No multiplication - parse as single integer
        return std.fmt.parseInt(u32, std.mem.trim(u8, expr, " \t"), 10) catch null;
    }

    // Split by * and multiply all parts (handles "4*4*4", "2*3*4*5", etc.)
    var product: u32 = 1;
    var it = std.mem.splitScalar(u8, expr, '*');
    var count: u32 = 0;
    const max_operands: u32 = 8; // Bound iteration

    while (it.next()) |part| {
        if (count >= max_operands) break;
        count += 1;

        const part_trimmed = std.mem.trim(u8, part, " \t");
        const value = std.fmt.parseInt(u32, part_trimmed, 10) catch return null;
        product *= value;
    }

    // Post-condition: at least one operand was processed
    std.debug.assert(count > 0);

    return product;
}

/// Calculate byte size of a #data declaration.
/// Returns the size in bytes based on float32Array element count.
pub fn calculateDataByteSize(e: *Emitter, data_node: Node.Index) ?u32 {
    // Pre-conditions
    std.debug.assert(data_node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const float_array = findPropertyValue(e, data_node, "float32Array") orelse return null;
    const array_tag = e.ast.nodes.items(.tag)[float_array.toInt()];

    if (array_tag != .array) return null;

    const array_data = e.ast.nodes.items(.data)[float_array.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Each f32 is 4 bytes
    const result: u32 = @intCast(elements.len * 4);

    // Post-condition: result is multiple of 4 (f32 alignment)
    std.debug.assert(result % 4 == 0);

    return result;
}

// ============================================================================
// Usage Flag Parsing
// ============================================================================

/// Parse buffer usage flags from a node.
/// Returns default (empty) usage if no usage property found.
pub fn parseBufferUsage(e: *Emitter, node: Node.Index) opcodes.BufferUsage {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    var usage = opcodes.BufferUsage{};

    const usage_value = findPropertyValue(e, node, "usage") orelse return usage;
    const value_tag = e.ast.nodes.items(.tag)[usage_value.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[usage_value.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        for (elements) |elem_idx| {
            const elem: Node.Index = @enumFromInt(elem_idx);
            const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

            if (elem_tag == .identifier_value) {
                const flag_token = e.ast.nodes.items(.main_token)[elem.toInt()];
                const flag_name = getTokenSlice(e, flag_token);

                if (std.mem.eql(u8, flag_name, "VERTEX")) usage.vertex = true;
                if (std.mem.eql(u8, flag_name, "INDEX")) usage.index = true;
                if (std.mem.eql(u8, flag_name, "UNIFORM")) usage.uniform = true;
                if (std.mem.eql(u8, flag_name, "STORAGE")) usage.storage = true;
                if (std.mem.eql(u8, flag_name, "COPY_SRC")) usage.copy_src = true;
                if (std.mem.eql(u8, flag_name, "COPY_DST")) usage.copy_dst = true;
                if (std.mem.eql(u8, flag_name, "MAP_READ")) usage.map_read = true;
                if (std.mem.eql(u8, flag_name, "MAP_WRITE")) usage.map_write = true;
            }
        }
    }

    return usage;
}

/// Parse texture format from a node.
/// Returns rgba8unorm if no format property found.
pub fn parseTextureFormat(e: *Emitter, node: Node.Index) DescriptorEncoder.TextureFormat {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    const value = findPropertyValue(e, node, "format") orelse return .rgba8unorm;
    const value_tag = e.ast.nodes.items(.tag)[value.toInt()];

    if (value_tag == .identifier_value or value_tag == .string_value) {
        var text = getNodeText(e, value);
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }
        return DescriptorEncoder.TextureFormat.fromString(text);
    }
    return .rgba8unorm;
}

/// Parse texture usage flags from a node.
/// Returns default (empty) usage if no usage property found.
pub fn parseTextureUsage(e: *Emitter, node: Node.Index) DescriptorEncoder.TextureUsage {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(e.ast.nodes.len > 0);

    var usage = DescriptorEncoder.TextureUsage{};

    const usage_value = findPropertyValue(e, node, "usage") orelse return usage;
    const value_tag = e.ast.nodes.items(.tag)[usage_value.toInt()];

    if (value_tag == .array) {
        const array_data = e.ast.nodes.items(.data)[usage_value.toInt()];
        const elements = e.ast.extraData(array_data.extra_range);

        for (elements) |elem_idx| {
            const elem: Node.Index = @enumFromInt(elem_idx);
            const elem_tag = e.ast.nodes.items(.tag)[elem.toInt()];

            if (elem_tag == .identifier_value) {
                const flag_name = getNodeText(e, elem);

                if (std.mem.eql(u8, flag_name, "COPY_SRC")) usage.copy_src = true;
                if (std.mem.eql(u8, flag_name, "COPY_DST")) usage.copy_dst = true;
                if (std.mem.eql(u8, flag_name, "TEXTURE_BINDING")) usage.texture_binding = true;
                if (std.mem.eql(u8, flag_name, "STORAGE_BINDING")) usage.storage_binding = true;
                if (std.mem.eql(u8, flag_name, "RENDER_ATTACHMENT")) usage.render_attachment = true;
            }
        }
    }

    return usage;
}

/// Parse sampler filter mode.
pub fn parseSamplerFilter(e: *Emitter, node: Node.Index, prop_name: []const u8) DescriptorEncoder.FilterMode {
    const value = findPropertyValue(e, node, prop_name) orelse return .linear;
    const value_tag = e.ast.nodes.items(.tag)[value.toInt()];

    if (value_tag == .identifier_value or value_tag == .string_value) {
        var text = getNodeText(e, value);
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }
        if (std.mem.eql(u8, text, "nearest")) return .nearest;
    }
    return .linear;
}

/// Parse sampler address mode.
pub fn parseSamplerAddressMode(e: *Emitter, node: Node.Index) DescriptorEncoder.AddressMode {
    const value = findPropertyValue(e, node, "addressModeU") orelse
        findPropertyValue(e, node, "addressMode") orelse return .clamp_to_edge;
    const value_tag = e.ast.nodes.items(.tag)[value.toInt()];

    if (value_tag == .identifier_value or value_tag == .string_value) {
        var text = getNodeText(e, value);
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            text = text[1 .. text.len - 1];
        }
        if (std.mem.eql(u8, text, "repeat")) return .repeat;
        if (std.mem.eql(u8, text, "mirror-repeat")) return .mirror_repeat;
    }
    return .clamp_to_edge;
}

// ============================================================================
// Resource Resolution
// ============================================================================

/// Parse a bind group entry from an object node.
pub fn parseBindGroupEntry(e: *Emitter, entry_node: Node.Index) ?DescriptorEncoder.BindGroupEntry {
    const entry_data = e.ast.nodes.items(.data)[entry_node.toInt()];
    const entry_props = e.ast.extraData(entry_data.extra_range);

    var bg_entry = DescriptorEncoder.BindGroupEntry{
        .binding = 0,
        .resource_type = .buffer,
        .resource_id = 0,
    };

    for (entry_props) |prop_idx| {
        const prop: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop.toInt()];
        const prop_name = getTokenSlice(e, prop_token);
        const prop_data = e.ast.nodes.items(.data)[prop.toInt()];
        const value_node = prop_data.node;

        if (std.mem.eql(u8, prop_name, "binding")) {
            bg_entry.binding = @intCast(parseNumber(e, value_node) orelse 0);
        } else if (std.mem.eql(u8, prop_name, "resource")) {
            const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
            if (value_tag == .object) {
                if (findPropertyValueInObject(e, value_node, "buffer")) |buf_node| {
                    bg_entry.resource_type = .buffer;
                    if (resolveBufferId(e, buf_node)) |id| {
                        bg_entry.resource_id = id;
                    }
                } else if (findPropertyValueInObject(e, value_node, "texture")) |tex_node| {
                    bg_entry.resource_type = .texture_view;
                    if (resolveResourceId(e, tex_node, "texture")) |id| {
                        bg_entry.resource_id = id;
                    }
                } else if (findPropertyValueInObject(e, value_node, "sampler")) |samp_node| {
                    bg_entry.resource_type = .sampler;
                    if (resolveResourceId(e, samp_node, "sampler")) |id| {
                        bg_entry.resource_id = id;
                    }
                }
            } else if (value_tag == .identifier_value) {
                // Direct identifier reference - resolve by looking up in symbol tables
                const name = getNodeText(e, value_node);
                if (e.sampler_ids.get(name)) |id| {
                    bg_entry.resource_type = .sampler;
                    bg_entry.resource_id = id;
                } else if (e.texture_ids.get(name)) |id| {
                    bg_entry.resource_type = .texture_view;
                    bg_entry.resource_id = id;
                } else if (e.buffer_ids.get(name)) |id| {
                    bg_entry.resource_type = .buffer;
                    bg_entry.resource_id = id;
                }
            }
        } else if (std.mem.eql(u8, prop_name, "buffer")) {
            bg_entry.resource_type = .buffer;
            if (resolveBufferId(e, value_node)) |id| {
                bg_entry.resource_id = id;
            }
        } else if (std.mem.eql(u8, prop_name, "texture")) {
            bg_entry.resource_type = .texture_view;
            if (resolveResourceId(e, value_node, "texture")) |id| {
                bg_entry.resource_id = id;
            }
        } else if (std.mem.eql(u8, prop_name, "sampler")) {
            bg_entry.resource_type = .sampler;
            if (resolveResourceId(e, value_node, "sampler")) |id| {
                bg_entry.resource_id = id;
            }
        } else if (std.mem.eql(u8, prop_name, "offset")) {
            bg_entry.offset = parseNumber(e, value_node) orelse 0;
        } else if (std.mem.eql(u8, prop_name, "size")) {
            bg_entry.size = parseNumber(e, value_node) orelse 0;
        }
    }

    return bg_entry;
}

/// Resolve a resource reference to its ID.
pub fn resolveResourceId(e: *Emitter, value_node: Node.Index, resource_type: []const u8) ?u16 {
    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

    if (value_tag == .reference) {
        if (getReference(e, value_node)) |ref| {
            if (std.mem.eql(u8, resource_type, "buffer")) {
                return e.buffer_ids.get(ref.name);
            } else if (std.mem.eql(u8, resource_type, "texture")) {
                return e.texture_ids.get(ref.name);
            } else if (std.mem.eql(u8, resource_type, "sampler")) {
                return e.sampler_ids.get(ref.name);
            }
        }
    }
    return null;
}

/// Resolve a buffer reference to its ID (handles both identifier and reference).
pub fn resolveBufferId(e: *Emitter, node: Node.Index) ?u16 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const name = getNodeText(e, node);
        return e.buffer_ids.get(name);
    } else if (tag == .reference) {
        if (getReference(e, node)) |ref| {
            return e.buffer_ids.get(ref.name);
        }
    }
    return null;
}

/// Resolve bind group layout to pipeline ID.
pub fn resolveBindGroupLayoutId(e: *Emitter, node: Node.Index) u16 {
    const value = findPropertyValue(e, node, "layout") orelse return 0;
    const value_tag = e.ast.nodes.items(.tag)[value.toInt()];

    if (value_tag == .object) {
        const obj_data = e.ast.nodes.items(.data)[value.toInt()];
        const obj_props = e.ast.extraData(obj_data.extra_range);

        for (obj_props) |prop_idx| {
            const prop_node: Node.Index = @enumFromInt(prop_idx);
            const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
            const prop_name = getTokenSlice(e, prop_token);

            if (std.mem.eql(u8, prop_name, "pipeline")) {
                const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
                const prop_value = prop_data.node;
                const prop_value_tag = e.ast.nodes.items(.tag)[prop_value.toInt()];

                if (prop_value_tag == .identifier_value) {
                    const pipeline_name = getNodeText(e, prop_value);
                    return e.pipeline_ids.get(pipeline_name) orelse 0;
                } else if (prop_value_tag == .reference) {
                    if (getReference(e, prop_value)) |ref| {
                        return e.pipeline_ids.get(ref.name) orelse 0;
                    }
                }
            }
        }
    } else if (value_tag == .identifier_value) {
        const text = getNodeText(e, value);
        if (std.mem.eql(u8, text, "auto")) {
            return 0;
        }
    }
    return 0;
}

/// Get the bind group index from layout object.
pub fn getBindGroupIndex(e: *Emitter, node: Node.Index) u8 {
    const value = findPropertyValue(e, node, "layout") orelse return 0;
    const value_tag = e.ast.nodes.items(.tag)[value.toInt()];

    if (value_tag == .object) {
        if (findPropertyValue(e, value, "index")) |index_value| {
            const index_tag = e.ast.nodes.items(.tag)[index_value.toInt()];
            if (index_tag == .number_value) {
                const text = getNodeText(e, index_value);
                return std.fmt.parseInt(u8, text, 10) catch 0;
            }
        }
    }
    return 0;
}

/// Resolve a bind group reference to its ID.
pub fn resolveBindGroupId(e: *Emitter, node: Node.Index) ?u16 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];

    if (tag == .identifier_value) {
        const name = getNodeText(e, node);
        return e.bind_group_ids.get(name);
    } else if (tag == .reference) {
        if (getReference(e, node)) |ref| {
            return e.bind_group_ids.get(ref.name);
        }
    }
    return null;
}

/// Collect array elements from an array node.
/// Returns the extra_data range as a slice of u32 indices.
pub fn collectArrayElements(e: *Emitter, node: Node.Index) []const u32 {
    const tag = e.ast.nodes.items(.tag)[node.toInt()];
    if (tag != .array) return &[_]u32{};

    const data = e.ast.nodes.items(.data)[node.toInt()];
    return e.ast.extra_data[data.extra_range.start..data.extra_range.end];
}

// ============================================================================
// Tests
// ============================================================================

test "parseStringExpression: simple integers" {
    try std.testing.expectEqual(@as(?u32, 42), parseStringExpression("42"));
    try std.testing.expectEqual(@as(?u32, 0), parseStringExpression("0"));
    try std.testing.expectEqual(@as(?u32, 64), parseStringExpression("64"));
}

test "parseStringExpression: two-operand multiplication" {
    try std.testing.expectEqual(@as(?u32, 8), parseStringExpression("2*4"));
    try std.testing.expectEqual(@as(?u32, 8), parseStringExpression("2 * 4"));
    try std.testing.expectEqual(@as(?u32, 12), parseStringExpression("4+4+4"));
}

test "parseStringExpression: chained multiplication (mat4x4 size)" {
    // This is the bug fix: "4*4*4" should evaluate to 64 for mat4x4<f32> size
    try std.testing.expectEqual(@as(?u32, 64), parseStringExpression("4*4*4"));
    try std.testing.expectEqual(@as(?u32, 64), parseStringExpression("4 * 4 * 4"));
    try std.testing.expectEqual(@as(?u32, 120), parseStringExpression("2*3*4*5"));
}

test "parseStringExpression: addition and multiplication mixed" {
    // Addition: 4 + 4 + 4 = 12
    try std.testing.expectEqual(@as(?u32, 12), parseStringExpression("4+4+4"));
    // With multiplication: (2*3) + (4*5) = 6 + 20 = 26
    try std.testing.expectEqual(@as(?u32, 26), parseStringExpression("2*3+4*5"));
}

test "parseStringExpression: whitespace handling" {
    try std.testing.expectEqual(@as(?u32, 64), parseStringExpression("  4*4*4  "));
    try std.testing.expectEqual(@as(?u32, 64), parseStringExpression("\t4*4*4\n"));
}

test "parseStringExpression: invalid returns null" {
    try std.testing.expectEqual(@as(?u32, null), parseStringExpression(""));
    try std.testing.expectEqual(@as(?u32, null), parseStringExpression("abc"));
    try std.testing.expectEqual(@as(?u32, null), parseStringExpression("4*"));
}
