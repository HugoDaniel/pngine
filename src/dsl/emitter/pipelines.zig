//! Pipeline Emission Module
//!
//! Handles emission of pipeline declarations:
//! - #renderPipeline (render pipeline descriptor JSON)
//! - #computePipeline (compute pipeline descriptor JSON)
//!
//! Builds JSON descriptors for runtime pipeline creation.
//!
//! ## Invariants
//!
//! * Pipeline IDs are assigned sequentially starting from next_pipeline_id.
//! * JSON output is always valid (properly escaped strings, balanced braces).
//! * Stage descriptors always have a shader ID and entry point.
//! * All property iteration is bounded by MAX_PROPERTIES.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const utils = @import("utils.zig");

/// Maximum properties per pipeline (prevents runaway iteration).
const MAX_PROPERTIES: u32 = 64;

/// Emit #renderPipeline and #computePipeline declarations.
pub fn emitPipelines(e: *Emitter) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(e.ast.nodes.len > 0);

    const initial_pipeline_id = e.next_pipeline_id;

    // Render pipelines (bounded iteration)
    var rp_it = e.analysis.symbols.render_pipeline.iterator();
    for (0..MAX_PROPERTIES) |_| {
        const entry = rp_it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const pipeline_id = e.next_pipeline_id;
        e.next_pipeline_id += 1;
        try e.pipeline_ids.put(e.gpa, name, pipeline_id);

        // Build pipeline descriptor JSON for runtime
        const desc = buildRenderPipelineDescriptor(e, info.node) catch |err| {
            std.debug.print("Failed to build render pipeline descriptor: {}\n", .{err});
            continue;
        };
        defer e.gpa.free(desc);

        const desc_id = try e.builder.addData(e.gpa, desc);

        try e.builder.getEmitter().createRenderPipeline(
            e.gpa,
            pipeline_id,
            desc_id.toInt(),
        );
    } else unreachable; // Exceeded MAX_PROPERTIES

    // Compute pipelines (bounded iteration)
    var cp_it = e.analysis.symbols.compute_pipeline.iterator();
    for (0..MAX_PROPERTIES) |_| {
        const entry = cp_it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        const pipeline_id = e.next_pipeline_id;
        e.next_pipeline_id += 1;
        try e.pipeline_ids.put(e.gpa, name, pipeline_id);

        // Build compute pipeline descriptor JSON
        const desc = buildComputePipelineDescriptor(e, info.node) catch |err| {
            std.debug.print("Failed to build compute pipeline descriptor: {}\n", .{err});
            continue;
        };
        defer e.gpa.free(desc);

        const desc_id = try e.builder.addData(e.gpa, desc);

        try e.builder.getEmitter().createComputePipeline(
            e.gpa,
            pipeline_id,
            desc_id.toInt(),
        );
    } else unreachable; // Exceeded MAX_PROPERTIES

    // Post-condition: pipeline IDs were assigned sequentially
    std.debug.assert(e.next_pipeline_id >= initial_pipeline_id);
}

/// Parsed render pipeline properties.
const RenderPipelineProps = struct {
    vertex_shader_id: u16 = 0,
    vertex_entry: []const u8 = "vertexMain",
    fragment_shader_id: u16 = 0,
    fragment_entry: []const u8 = "fragmentMain",
    has_fragment: bool = false,
    target_format: ?[]const u8 = null, // e.g., "rgba8unorm", null = use canvas format
    vertex_buffers_json: ?[]const u8 = null,
    primitive_json: ?[]const u8 = null,
    depth_stencil_json: ?[]const u8 = null,
    multisample_json: ?[]const u8 = null,
};

/// Parse all render pipeline properties from node.
fn parseRenderPipelineProps(e: *Emitter, node: Node.Index) RenderPipelineProps {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    var props = RenderPipelineProps{};

    const data = e.ast.nodes.items(.data)[node.toInt()];
    const prop_list = e.ast.extraData(data.extra_range);

    for (prop_list) |prop_idx| {
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const prop_name = utils.getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, prop_name, "vertex")) {
            const stage_info = parseStageDescriptor(e, prop_node);
            if (stage_info.shader_id) |id| props.vertex_shader_id = id;
            if (stage_info.entry_point) |ep| props.vertex_entry = ep;
            props.vertex_buffers_json = parseVertexBuffersLayout(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "fragment")) {
            props.has_fragment = true;
            const stage_info = parseStageDescriptor(e, prop_node);
            if (stage_info.shader_id) |id| props.fragment_shader_id = id;
            if (stage_info.entry_point) |ep| props.fragment_entry = ep;
            props.target_format = parseFragmentTargetFormat(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "primitive")) {
            props.primitive_json = buildPrimitiveJson(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "depthStencil")) {
            props.depth_stencil_json = buildDepthStencilJson(e, prop_node);
        } else if (std.mem.eql(u8, prop_name, "multisample")) {
            props.multisample_json = buildMultisampleJson(e, prop_node);
        }
    }

    // Post-condition: vertex entry is valid
    std.debug.assert(props.vertex_entry.len > 0);

    return props;
}

/// Parse the target format from fragment stage's targets array.
/// Parses: fragment={ ... targets=[{ format=rgba8unorm }] }
/// Returns null if not specified (will use canvas format at runtime).
fn parseFragmentTargetFormat(e: *Emitter, prop_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return null;

    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |obj_prop_idx| {
        const inner_prop: Node.Index = @enumFromInt(obj_prop_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_prop.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);

        if (std.mem.eql(u8, inner_name, "targets")) {
            const inner_data = e.ast.nodes.items(.data)[inner_prop.toInt()];
            const targets_node = inner_data.node;
            const targets_tag = e.ast.nodes.items(.tag)[targets_node.toInt()];

            if (targets_tag != .array) return null;

            // Get first target from array
            const first_target = utils.getArrayFirstElement(e, targets_node) orelse return null;
            const first_tag = e.ast.nodes.items(.tag)[first_target.toInt()];

            if (first_tag != .object) return null;

            // Look for format property in first target
            const format_node = utils.findPropertyValueInObject(e, first_target, "format") orelse return null;
            const format_text = getIdentifierOrStringValue(e, format_node);

            // Handle special case: preferredCanvasFormat means use canvas format
            if (std.mem.eql(u8, format_text, "preferredCanvasFormat")) {
                return null;
            }

            return format_text;
        }
    }

    return null;
}

/// Build JSON descriptor for render pipeline.
/// Format: {"vertex":{"shader":N,"entryPoint":"..."},"fragment":{...}}
fn buildRenderPipelineDescriptor(e: *Emitter, node: Node.Index) ![]u8 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    var props = parseRenderPipelineProps(e, node);

    // Free temporary JSON strings after use
    defer if (props.vertex_buffers_json) |buffers| e.gpa.free(buffers);
    defer if (props.primitive_json) |p| e.gpa.free(p);
    defer if (props.depth_stencil_json) |d| e.gpa.free(d);
    defer if (props.multisample_json) |m| e.gpa.free(m);

    // Build JSON
    var json = std.ArrayListUnmanaged(u8){};
    errdefer json.deinit(e.gpa);

    try json.append(e.gpa, '{');

    // Vertex stage (required)
    try appendVertexStageJson(e, &json, &props);

    // Fragment stage (optional)
    if (props.has_fragment) {
        try appendFragmentStageJson(e, &json, &props);
    }

    // Optional states
    if (props.primitive_json) |p| {
        try json.appendSlice(e.gpa, ",\"primitive\":");
        try json.appendSlice(e.gpa, p);
    }
    if (props.depth_stencil_json) |d| {
        try json.appendSlice(e.gpa, ",\"depthStencil\":");
        try json.appendSlice(e.gpa, d);
    }
    if (props.multisample_json) |m| {
        try json.appendSlice(e.gpa, ",\"multisample\":");
        try json.appendSlice(e.gpa, m);
    }

    try json.append(e.gpa, '}');

    const result = try json.toOwnedSlice(e.gpa);

    // Post-condition: valid JSON with balanced braces
    std.debug.assert(result.len >= 2);
    std.debug.assert(result[0] == '{' and result[result.len - 1] == '}');

    return result;
}

/// Append vertex stage JSON to output.
fn appendVertexStageJson(e: *Emitter, json: *std.ArrayListUnmanaged(u8), props: *const RenderPipelineProps) !void {
    // Pre-condition
    std.debug.assert(props.vertex_entry.len > 0);

    try json.appendSlice(e.gpa, "\"vertex\":{\"shader\":");
    var buf: [16]u8 = undefined;
    const shader_str = std.fmt.bufPrint(&buf, "{d}", .{props.vertex_shader_id}) catch "0";
    try json.appendSlice(e.gpa, shader_str);
    try json.appendSlice(e.gpa, ",\"entryPoint\":\"");
    try json.appendSlice(e.gpa, props.vertex_entry);
    try json.append(e.gpa, '"');
    if (props.vertex_buffers_json) |buffers| {
        try json.appendSlice(e.gpa, ",\"buffers\":");
        try json.appendSlice(e.gpa, buffers);
    }
    try json.append(e.gpa, '}');

    // Post-condition: JSON ends with closing brace
    std.debug.assert(json.items.len > 0 and json.items[json.items.len - 1] == '}');
}

/// Append fragment stage JSON to output.
fn appendFragmentStageJson(e: *Emitter, json: *std.ArrayListUnmanaged(u8), props: *const RenderPipelineProps) !void {
    // Pre-condition
    std.debug.assert(props.has_fragment);
    std.debug.assert(props.fragment_entry.len > 0);

    var buf: [16]u8 = undefined;
    try json.appendSlice(e.gpa, ",\"fragment\":{\"shader\":");
    const frag_str = std.fmt.bufPrint(&buf, "{d}", .{props.fragment_shader_id}) catch "0";
    try json.appendSlice(e.gpa, frag_str);
    try json.appendSlice(e.gpa, ",\"entryPoint\":\"");
    try json.appendSlice(e.gpa, props.fragment_entry);
    try json.append(e.gpa, '"');

    // Add target format if specified (otherwise JS will use canvas format)
    if (props.target_format) |format| {
        try json.appendSlice(e.gpa, ",\"targetFormat\":\"");
        try json.appendSlice(e.gpa, format);
        try json.append(e.gpa, '"');
    }

    try json.append(e.gpa, '}');

    // Post-condition: JSON ends with closing brace
    std.debug.assert(json.items.len > 0 and json.items[json.items.len - 1] == '}');
}

/// Build JSON for primitive state: { topology, cullMode, frontFace, ... }
fn buildPrimitiveJson(e: *Emitter, prop_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return null;

    var json = std.ArrayListUnmanaged(u8){};
    json.append(e.gpa, '{') catch return null;

    var first = true;
    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |inner_idx| {
        const inner_node: Node.Index = @enumFromInt(inner_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_node.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);
        const inner_data = e.ast.nodes.items(.data)[inner_node.toInt()];
        const value_node = inner_data.node;

        if (!first) json.append(e.gpa, ',') catch return null;
        first = false;

        // Handle each primitive property
        if (std.mem.eql(u8, inner_name, "topology") or
            std.mem.eql(u8, inner_name, "cullMode") or
            std.mem.eql(u8, inner_name, "frontFace") or
            std.mem.eql(u8, inner_name, "stripIndexFormat"))
        {
            // String enum values
            const value_text = getIdentifierOrStringValue(e, value_node);
            const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":\"{s}\"", .{ inner_name, value_text }) catch return null;
            json.appendSlice(e.gpa, entry) catch {
                e.gpa.free(entry);
                return null;
            };
            e.gpa.free(entry);
        } else if (std.mem.eql(u8, inner_name, "unclippedDepth")) {
            const value = parseBoolValue(e, value_node);
            const entry = std.fmt.allocPrint(e.gpa, "\"unclippedDepth\":{s}", .{if (value) "true" else "false"}) catch return null;
            json.appendSlice(e.gpa, entry) catch {
                e.gpa.free(entry);
                return null;
            };
            e.gpa.free(entry);
        } else {
            first = true; // Reset if unknown property
        }
    }

    json.append(e.gpa, '}') catch return null;
    return json.toOwnedSlice(e.gpa) catch null;
}

/// Build JSON for depth/stencil state
fn buildDepthStencilJson(e: *Emitter, prop_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return null;

    var json = std.ArrayListUnmanaged(u8){};
    json.append(e.gpa, '{') catch return null;

    var first = true;
    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |inner_idx| {
        const inner_node: Node.Index = @enumFromInt(inner_idx);
        if (!first) json.append(e.gpa, ',') catch return null;
        first = false;

        const handled = appendDepthStencilProperty(e, &json, inner_node);
        if (!handled) first = true; // Reset if unknown property
    }

    json.append(e.gpa, '}') catch return null;

    // Post-condition: result is valid JSON object
    const result = json.toOwnedSlice(e.gpa) catch return null;
    std.debug.assert(result.len >= 2);
    return result;
}

/// Append a single depth/stencil property to JSON. Returns false if property unknown.
fn appendDepthStencilProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), inner_node: Node.Index) bool {
    // Pre-condition
    std.debug.assert(inner_node.toInt() < e.ast.nodes.len);

    const inner_token = e.ast.nodes.items(.main_token)[inner_node.toInt()];
    const inner_name = utils.getTokenSlice(e, inner_token);
    const inner_data = e.ast.nodes.items(.data)[inner_node.toInt()];
    const value_node = inner_data.node;

    // String enum values
    if (std.mem.eql(u8, inner_name, "format") or std.mem.eql(u8, inner_name, "depthCompare")) {
        return appendStringProperty(e, json, inner_name, value_node);
    }
    // Boolean values
    if (std.mem.eql(u8, inner_name, "depthWriteEnabled")) {
        return appendBoolProperty(e, json, inner_name, value_node);
    }
    // Numeric values
    if (std.mem.eql(u8, inner_name, "depthBias") or
        std.mem.eql(u8, inner_name, "stencilReadMask") or
        std.mem.eql(u8, inner_name, "stencilWriteMask"))
    {
        return appendNumericProperty(e, json, inner_name, value_node);
    }
    // Float values
    if (std.mem.eql(u8, inner_name, "depthBiasSlopeScale") or
        std.mem.eql(u8, inner_name, "depthBiasClamp"))
    {
        return appendFloatProperty(e, json, inner_name, value_node);
    }
    // Stencil face states
    if (std.mem.eql(u8, inner_name, "stencilFront") or std.mem.eql(u8, inner_name, "stencilBack")) {
        return appendStencilFaceProperty(e, json, inner_name, value_node);
    }

    return false;
}

/// Append a string property: "name":"value"
fn appendStringProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), name: []const u8, value_node: Node.Index) bool {
    const value_text = getIdentifierOrStringValue(e, value_node);
    const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":\"{s}\"", .{ name, value_text }) catch return false;
    defer e.gpa.free(entry);
    json.appendSlice(e.gpa, entry) catch return false;
    return true;
}

/// Append a boolean property: "name":true/false
fn appendBoolProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), name: []const u8, value_node: Node.Index) bool {
    const value = parseBoolValue(e, value_node);
    const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":{s}", .{ name, if (value) "true" else "false" }) catch return false;
    defer e.gpa.free(entry);
    json.appendSlice(e.gpa, entry) catch return false;
    return true;
}

/// Append a numeric property: "name":123
fn appendNumericProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), name: []const u8, value_node: Node.Index) bool {
    const value = utils.resolveNumericValue(e, value_node) orelse 0;
    const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":{d}", .{ name, value }) catch return false;
    defer e.gpa.free(entry);
    json.appendSlice(e.gpa, entry) catch return false;
    return true;
}

/// Append a float property: "name":1.5
fn appendFloatProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), name: []const u8, value_node: Node.Index) bool {
    const value = utils.parseFloatNumber(e, value_node) orelse 0.0;
    const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":{d}", .{ name, value }) catch return false;
    defer e.gpa.free(entry);
    json.appendSlice(e.gpa, entry) catch return false;
    return true;
}

/// Append a stencil face property: "name":{...}
fn appendStencilFaceProperty(e: *Emitter, json: *std.ArrayListUnmanaged(u8), name: []const u8, value_node: Node.Index) bool {
    const face_json = buildStencilFaceJson(e, value_node) orelse return false;
    defer e.gpa.free(face_json);
    const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":{s}", .{ name, face_json }) catch return false;
    defer e.gpa.free(entry);
    json.appendSlice(e.gpa, entry) catch return false;
    return true;
}

/// Build JSON for stencil face state: { compare, failOp, depthFailOp, passOp }
fn buildStencilFaceJson(e: *Emitter, obj_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(obj_node.toInt() < e.ast.nodes.len);

    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];
    if (obj_tag != .object) return null;

    var json = std.ArrayListUnmanaged(u8){};
    json.append(e.gpa, '{') catch return null;

    var first = true;
    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |inner_idx| {
        const inner_node: Node.Index = @enumFromInt(inner_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_node.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);
        const inner_data = e.ast.nodes.items(.data)[inner_node.toInt()];
        const value_node = inner_data.node;

        if (std.mem.eql(u8, inner_name, "compare") or
            std.mem.eql(u8, inner_name, "failOp") or
            std.mem.eql(u8, inner_name, "depthFailOp") or
            std.mem.eql(u8, inner_name, "passOp"))
        {
            if (!first) json.append(e.gpa, ',') catch return null;
            first = false;

            const value_text = getIdentifierOrStringValue(e, value_node);
            const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":\"{s}\"", .{ inner_name, value_text }) catch return null;
            json.appendSlice(e.gpa, entry) catch {
                e.gpa.free(entry);
                return null;
            };
            e.gpa.free(entry);
        }
    }

    json.append(e.gpa, '}') catch return null;

    // Post-condition
    const result = json.toOwnedSlice(e.gpa) catch return null;
    std.debug.assert(result.len >= 2);
    return result;
}

/// Build JSON for multisample state: { count, mask, alphaToCoverageEnabled }
fn buildMultisampleJson(e: *Emitter, prop_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return null;

    var json = std.ArrayListUnmanaged(u8){};
    json.append(e.gpa, '{') catch return null;

    var first = true;
    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |inner_idx| {
        const inner_node: Node.Index = @enumFromInt(inner_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_node.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);
        const inner_data = e.ast.nodes.items(.data)[inner_node.toInt()];
        const value_node = inner_data.node;

        if (!first) json.append(e.gpa, ',') catch return null;
        first = false;

        if (std.mem.eql(u8, inner_name, "count") or std.mem.eql(u8, inner_name, "mask")) {
            const default_val: u32 = if (std.mem.eql(u8, inner_name, "count")) 1 else 0xFFFFFFFF;
            const value = utils.resolveNumericValue(e, value_node) orelse default_val;
            const entry = std.fmt.allocPrint(e.gpa, "\"{s}\":{d}", .{ inner_name, value }) catch return null;
            json.appendSlice(e.gpa, entry) catch {
                e.gpa.free(entry);
                return null;
            };
            e.gpa.free(entry);
        } else if (std.mem.eql(u8, inner_name, "alphaToCoverageEnabled")) {
            const value = parseBoolValue(e, value_node);
            const entry = std.fmt.allocPrint(e.gpa, "\"alphaToCoverageEnabled\":{s}", .{if (value) "true" else "false"}) catch return null;
            json.appendSlice(e.gpa, entry) catch {
                e.gpa.free(entry);
                return null;
            };
            e.gpa.free(entry);
        } else {
            first = true; // Reset if unknown property
        }
    }

    json.append(e.gpa, '}') catch return null;
    return json.toOwnedSlice(e.gpa) catch null;
}

/// Get identifier or string value text from a node.
fn getIdentifierOrStringValue(e: *Emitter, value_node: Node.Index) []const u8 {
    // Pre-condition
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (value_tag == .identifier_value) {
        return utils.getNodeText(e, value_node);
    } else if (value_tag == .string_value) {
        return utils.getStringContent(e, value_node);
    }
    return "";
}

/// Parse a boolean value from a node (true, false, or identifier).
fn parseBoolValue(e: *Emitter, value_node: Node.Index) bool {
    // Pre-condition
    std.debug.assert(value_node.toInt() < e.ast.nodes.len);

    const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
    if (value_tag == .boolean_value or value_tag == .identifier_value) {
        const text = utils.getNodeText(e, value_node);
        return std.mem.eql(u8, text, "true");
    }
    return false;
}

/// Parse vertex buffers layout from vertex stage descriptor.
/// Returns JSON array string like: [{"arrayStride":40,"attributes":[...]}]
fn parseVertexBuffersLayout(e: *Emitter, prop_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return null;

    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |obj_prop_idx| {
        const inner_prop: Node.Index = @enumFromInt(obj_prop_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_prop.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);

        if (std.mem.eql(u8, inner_name, "buffers")) {
            const inner_data = e.ast.nodes.items(.data)[inner_prop.toInt()];
            const buffers_node = inner_data.node;
            return buildVertexBuffersJson(e, buffers_node);
        }
    }
    return null;
}

/// Build JSON for vertex buffers array.
fn buildVertexBuffersJson(e: *Emitter, buffers_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(buffers_node.toInt() < e.ast.nodes.len);

    const buffers_tag = e.ast.nodes.items(.tag)[buffers_node.toInt()];
    if (buffers_tag != .array) return null;

    const buffers_data = e.ast.nodes.items(.data)[buffers_node.toInt()];
    const buffer_elements = e.ast.extraData(buffers_data.extra_range);

    var result = std.ArrayListUnmanaged(u8){};
    result.append(e.gpa, '[') catch return null;

    var first_buffer = true;
    for (buffer_elements) |buf_idx| {
        const buf_node: Node.Index = @enumFromInt(buf_idx);
        const buf_tag = e.ast.nodes.items(.tag)[buf_node.toInt()];
        if (buf_tag != .object) continue;

        if (!first_buffer) result.append(e.gpa, ',') catch return null;
        first_buffer = false;

        // Parse buffer object: { arrayStride=N, stepMode=instance|vertex, attributes=[...] }
        result.append(e.gpa, '{') catch return null;

        var array_stride: u32 = 0;
        var step_mode: ?[]const u8 = null;
        var attributes_json: ?[]const u8 = null;

        const buf_data = e.ast.nodes.items(.data)[buf_node.toInt()];
        const buf_props = e.ast.extraData(buf_data.extra_range);

        for (buf_props) |bp_idx| {
            const bp_node: Node.Index = @enumFromInt(bp_idx);
            const bp_token = e.ast.nodes.items(.main_token)[bp_node.toInt()];
            const bp_name = utils.getTokenSlice(e, bp_token);

            if (std.mem.eql(u8, bp_name, "arrayStride")) {
                const bp_data = e.ast.nodes.items(.data)[bp_node.toInt()];
                array_stride = utils.resolveNumericValueOrString(e, bp_data.node) orelse 0;
            } else if (std.mem.eql(u8, bp_name, "stepMode")) {
                const bp_data = e.ast.nodes.items(.data)[bp_node.toInt()];
                step_mode = utils.getNodeText(e, bp_data.node);
            } else if (std.mem.eql(u8, bp_name, "attributes")) {
                const bp_data = e.ast.nodes.items(.data)[bp_node.toInt()];
                attributes_json = buildAttributesJson(e, bp_data.node);
            }
        }

        const stride_json = std.fmt.allocPrint(e.gpa, "\"arrayStride\":{d}", .{array_stride}) catch return null;
        result.appendSlice(e.gpa, stride_json) catch {
            e.gpa.free(stride_json);
            return null;
        };
        e.gpa.free(stride_json);

        // Add stepMode if specified (default is "vertex" so only emit if instance)
        if (step_mode) |mode| {
            const mode_json = std.fmt.allocPrint(e.gpa, ",\"stepMode\":\"{s}\"", .{mode}) catch return null;
            result.appendSlice(e.gpa, mode_json) catch {
                e.gpa.free(mode_json);
                return null;
            };
            e.gpa.free(mode_json);
        }

        if (attributes_json) |attrs| {
            result.appendSlice(e.gpa, ",\"attributes\":") catch return null;
            result.appendSlice(e.gpa, attrs) catch return null;
            e.gpa.free(attrs);
        }

        result.append(e.gpa, '}') catch return null;
    }

    result.append(e.gpa, ']') catch return null;
    return result.toOwnedSlice(e.gpa) catch return null;
}

/// Build JSON for vertex attributes array.
fn buildAttributesJson(e: *Emitter, attrs_node: Node.Index) ?[]const u8 {
    // Pre-condition
    std.debug.assert(attrs_node.toInt() < e.ast.nodes.len);

    const attrs_tag = e.ast.nodes.items(.tag)[attrs_node.toInt()];
    if (attrs_tag != .array) return null;

    const attrs_data = e.ast.nodes.items(.data)[attrs_node.toInt()];
    const attr_elements = e.ast.extraData(attrs_data.extra_range);

    var result = std.ArrayListUnmanaged(u8){};
    result.append(e.gpa, '[') catch return null;

    var first_attr = true;
    for (attr_elements) |attr_idx| {
        const attr_node: Node.Index = @enumFromInt(attr_idx);
        const attr_tag = e.ast.nodes.items(.tag)[attr_node.toInt()];
        if (attr_tag != .object) continue;

        if (!first_attr) result.append(e.gpa, ',') catch return null;
        first_attr = false;

        // Parse attribute: { shaderLocation=N, offset=N, format=... }
        var shader_location: u32 = 0;
        var attr_offset: u32 = 0;
        var attr_format: []const u8 = "float32x4";

        const attr_data = e.ast.nodes.items(.data)[attr_node.toInt()];
        const attr_props = e.ast.extraData(attr_data.extra_range);

        for (attr_props) |ap_idx| {
            const ap_node: Node.Index = @enumFromInt(ap_idx);
            const ap_token = e.ast.nodes.items(.main_token)[ap_node.toInt()];
            const ap_name = utils.getTokenSlice(e, ap_token);

            if (std.mem.eql(u8, ap_name, "shaderLocation")) {
                const ap_data = e.ast.nodes.items(.data)[ap_node.toInt()];
                shader_location = utils.resolveNumericValueOrString(e, ap_data.node) orelse 0;
            } else if (std.mem.eql(u8, ap_name, "offset")) {
                const ap_data = e.ast.nodes.items(.data)[ap_node.toInt()];
                attr_offset = utils.resolveNumericValueOrString(e, ap_data.node) orelse 0;
            } else if (std.mem.eql(u8, ap_name, "format")) {
                const ap_data = e.ast.nodes.items(.data)[ap_node.toInt()];
                attr_format = utils.getNodeText(e, ap_data.node);
            }
        }

        const attr_json = std.fmt.allocPrint(
            e.gpa,
            "{{\"shaderLocation\":{d},\"offset\":{d},\"format\":\"{s}\"}}",
            .{ shader_location, attr_offset, attr_format },
        ) catch return null;
        result.appendSlice(e.gpa, attr_json) catch {
            e.gpa.free(attr_json);
            return null;
        };
        e.gpa.free(attr_json);
    }

    result.append(e.gpa, ']') catch return null;
    return result.toOwnedSlice(e.gpa) catch return null;
}

/// Build JSON descriptor for compute pipeline.
/// Format: {"compute":{"shader":N,"entryPoint":"..."}}
///
/// If no module is specified in compute stage, infers the shader module:
/// - Uses the first available shader module from shader_ids
/// - Supports simple single-module projects like boids.pngine
fn buildComputePipelineDescriptor(e: *Emitter, node: Node.Index) ![]u8 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    var compute_shader_id: ?u16 = null;
    var compute_entry: []const u8 = "main";

    const data = e.ast.nodes.items(.data)[node.toInt()];
    const props = e.ast.extraData(data.extra_range);

    for (props) |prop_idx| {
        const prop_node: Node.Index = @enumFromInt(prop_idx);
        const prop_token = e.ast.nodes.items(.main_token)[prop_node.toInt()];
        const prop_name = utils.getTokenSlice(e, prop_token);

        if (std.mem.eql(u8, prop_name, "compute")) {
            const stage_info = parseStageDescriptor(e, prop_node);
            compute_shader_id = stage_info.shader_id;
            if (stage_info.entry_point) |ep| compute_entry = ep;
        }
    }

    // Module inference: if no module specified, use first available shader module
    const final_shader_id: u16 = compute_shader_id orelse blk: {
        var shader_it = e.shader_ids.iterator();
        const first_entry = shader_it.next();
        break :blk if (first_entry) |entry| entry.value_ptr.* else 0;
    };

    const result = try std.fmt.allocPrint(
        e.gpa,
        "{{\"compute\":{{\"shader\":{d},\"entryPoint\":\"{s}\"}}}}",
        .{ final_shader_id, compute_entry },
    );

    // Post-condition: valid JSON
    std.debug.assert(result.len > 0);
    std.debug.assert(result[0] == '{');

    return result;
}

const StageDescriptor = struct {
    shader_id: ?u16,
    entry_point: ?[]const u8,
};

/// Parse a shader stage descriptor (vertex, fragment, or compute).
fn parseStageDescriptor(e: *Emitter, prop_node: Node.Index) StageDescriptor {
    // Pre-condition
    std.debug.assert(prop_node.toInt() < e.ast.nodes.len);

    var result = StageDescriptor{
        .shader_id = null,
        .entry_point = null,
    };

    const prop_data = e.ast.nodes.items(.data)[prop_node.toInt()];
    const obj_node = prop_data.node;
    const obj_tag = e.ast.nodes.items(.tag)[obj_node.toInt()];

    if (obj_tag != .object) return result;

    const obj_data = e.ast.nodes.items(.data)[obj_node.toInt()];
    const obj_props = e.ast.extraData(obj_data.extra_range);

    for (obj_props) |obj_prop_idx| {
        const inner_prop: Node.Index = @enumFromInt(obj_prop_idx);
        const inner_token = e.ast.nodes.items(.main_token)[inner_prop.toInt()];
        const inner_name = utils.getTokenSlice(e, inner_token);

        if (std.mem.eql(u8, inner_name, "module")) {
            if (utils.findPropertyReference(e, inner_prop)) |ref| {
                // Reference: $wgsl.name or $shaderModule.name
                result.shader_id = e.shader_ids.get(ref.name);
            } else {
                // Bare identifier: module=sceneE
                const inner_data = e.ast.nodes.items(.data)[inner_prop.toInt()];
                const value_node = inner_data.node;
                const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];
                if (value_tag == .identifier_value) {
                    const module_name = utils.getNodeText(e, value_node);
                    result.shader_id = e.shader_ids.get(module_name);
                }
            }
        } else if (std.mem.eql(u8, inner_name, "entryPoint") or
            std.mem.eql(u8, inner_name, "entrypoint"))
        {
            const inner_data = e.ast.nodes.items(.data)[inner_prop.toInt()];
            const value_node = inner_data.node;
            const value_tag = e.ast.nodes.items(.tag)[value_node.toInt()];

            if (value_tag == .identifier_value) {
                result.entry_point = utils.getNodeText(e, value_node);
            } else if (value_tag == .string_value) {
                var text = utils.getNodeText(e, value_node);
                // Strip quotes
                if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                    text = text[1 .. text.len - 1];
                }
                result.entry_point = text;
            }
        }
    }

    return result;
}
