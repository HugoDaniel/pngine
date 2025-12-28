//! Init Macro Emission Module
//!
//! Handles emission of #init declarations by expanding them into:
//! - Synthetic compute pipeline
//! - Synthetic bind group (with optional params buffer at binding 1)
//! - Synthetic params buffer (when params=[] is specified)
//! - Synthetic compute pass (registered as a regular pass for frame reference)
//!
//! ## Example Expansion
//!
//! ```
//! #init resetParticles {
//!   buffer=particles
//!   shader=initParticles
//!   params=[12345]
//! }
//! ```
//!
//! Expands to bytecode equivalent of:
//! - Buffer for params with UNIFORM + COPY_DST usage
//! - Compute pipeline using initParticles shader
//! - Bind group with particles buffer at binding 0, params at binding 1
//! - Compute pass that dispatches the shader
//!
//! ## Invariants
//!
//! * Init macros are emitted after pipelines but before regular passes.
//! * Each #init registers a pass ID so it can be referenced in #frame { init=[...] }.
//! * Workgroup count is calculated from buffer size and workgroup size (default 64).
//! * Params buffer uses UNIFORM + COPY_DST usage for shader access.

const std = @import("std");
const Emitter = @import("../Emitter.zig").Emitter;
const Node = @import("../Ast.zig").Node;
const DescriptorEncoder = @import("../DescriptorEncoder.zig").DescriptorEncoder;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const BufferUsage = opcodes.BufferUsage;
const utils = @import("utils.zig");

/// Maximum #init macros to emit.
const MAX_INIT_MACROS: u32 = 64;

/// Default workgroup size for init shaders.
const DEFAULT_WORKGROUP_SIZE: u32 = 64;

/// Maximum params elements in #init params=[] array.
const MAX_PARAMS_ELEMENTS: u32 = 64;

/// Emit all #init macro declarations.
/// Creates synthetic pipelines, bind groups, and passes for each #init.
pub fn emitInitMacros(e: *Emitter) Emitter.Error!void {
    // Pre-condition
    std.debug.assert(e.ast.nodes.len > 0);

    var it = e.analysis.symbols.buffer_init.iterator();
    for (0..MAX_INIT_MACROS) |_| {
        const entry = it.next() orelse break;
        const name = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        try emitInitMacro(e, name, info.node);
    } else unreachable; // Exceeded MAX_INIT_MACROS
}

/// Emit a single #init macro as synthetic resources.
fn emitInitMacro(e: *Emitter, name: []const u8, node: Node.Index) Emitter.Error!void {
    // Pre-conditions
    std.debug.assert(node.toInt() < e.ast.nodes.len);
    std.debug.assert(name.len > 0);

    // Parse required properties
    const buffer_name = getBufferName(e, node) orelse return; // Skip if missing (analyzer should catch)
    const shader_name = getShaderName(e, node) orelse return;

    // Look up buffer ID
    const buffer_id = e.buffer_ids.get(buffer_name) orelse return;

    // Look up shader ID
    const shader_id = e.shader_ids.get(shader_name) orelse return;

    // Get buffer size for dispatch calculation
    const buffer_size = getBufferSize(e, buffer_name);
    // Ensure at least 1 workgroup (ceil division, min 1)
    const workgroup_count = @max(1, (buffer_size + DEFAULT_WORKGROUP_SIZE - 1) / DEFAULT_WORKGROUP_SIZE);

    // Check for optional params
    const params_data = try getParamsData(e, node);
    defer if (params_data) |data| e.gpa.free(data);
    var params_buffer_id: ?u16 = null;

    // 0. Create params buffer if params specified
    if (params_data) |data| {
        params_buffer_id = e.next_buffer_id;
        e.next_buffer_id += 1;

        // Create buffer with UNIFORM + COPY_DST usage
        try e.builder.getEmitter().createBuffer(
            e.gpa,
            params_buffer_id.?,
            @intCast(data.len),
            BufferUsage.uniform_copy_dst,
        );

        // Add data to data section
        const params_data_id = try e.builder.addData(e.gpa, data);

        // Write data to buffer
        try e.builder.getEmitter().writeBuffer(
            e.gpa,
            params_buffer_id.?,
            0, // offset
            params_data_id.toInt(),
        );
    }

    // 1. Create synthetic compute pipeline
    const pipeline_id = e.next_pipeline_id;
    e.next_pipeline_id += 1;

    // Build pipeline descriptor JSON
    const desc = try std.fmt.allocPrint(
        e.gpa,
        "{{\"compute\":{{\"shader\":{d},\"entryPoint\":\"main\"}}}}",
        .{shader_id},
    );
    defer e.gpa.free(desc);

    const desc_id = try e.builder.addData(e.gpa, desc);

    try e.builder.getEmitter().createComputePipeline(
        e.gpa,
        pipeline_id,
        desc_id.toInt(),
    );

    // 2. Create synthetic bind group
    const bind_group_id = e.next_bind_group_id;
    e.next_bind_group_id += 1;

    // Create bind group entries
    var entries_buf: [2]DescriptorEncoder.BindGroupEntry = undefined;
    var entry_count: usize = 1;

    // Binding 0: target buffer (storage)
    entries_buf[0] = DescriptorEncoder.BindGroupEntry{
        .binding = 0,
        .resource_type = .buffer,
        .resource_id = buffer_id,
        .offset = 0,
        .size = 0, // 0 = whole buffer
    };

    // Binding 1: params buffer (uniform) - if params specified
    if (params_buffer_id) |pid| {
        entries_buf[1] = DescriptorEncoder.BindGroupEntry{
            .binding = 1,
            .resource_type = .buffer,
            .resource_id = pid,
            .offset = 0,
            .size = 0, // 0 = whole buffer
        };
        entry_count = 2;
    }

    // Encode bind group descriptor
    const bg_desc = try DescriptorEncoder.encodeBindGroupDescriptor(e.gpa, 0, entries_buf[0..entry_count]);
    defer e.gpa.free(bg_desc);

    const bg_desc_id = try e.builder.addData(e.gpa, bg_desc);

    // Emit bind group creation (uses pipeline for auto layout)
    try e.builder.getEmitter().createBindGroup(
        e.gpa,
        bind_group_id,
        pipeline_id,
        bg_desc_id.toInt(),
    );

    // 3. Create synthetic compute pass
    const pass_id = e.next_pass_id;
    e.next_pass_id += 1;

    // Register pass with the #init name so it can be referenced in frames
    try e.pass_ids.put(e.gpa, name, pass_id);

    const pass_desc = "{}";
    const pass_desc_id = try e.builder.addData(e.gpa, pass_desc);

    try e.builder.getEmitter().definePass(
        e.gpa,
        pass_id,
        .compute,
        pass_desc_id.toInt(),
    );

    // Begin compute pass
    try e.builder.getEmitter().beginComputePass(e.gpa);

    // Set pipeline
    try e.builder.getEmitter().setPipeline(e.gpa, pipeline_id);

    // Set bind group at index 0
    try e.builder.getEmitter().setBindGroup(e.gpa, 0, bind_group_id);

    // Dispatch workgroups
    try e.builder.getEmitter().dispatch(
        e.gpa,
        @intCast(workgroup_count),
        1,
        1,
    );

    // End compute pass
    try e.builder.getEmitter().endPass(e.gpa);

    // End pass definition
    try e.builder.getEmitter().endPassDef(e.gpa);
}

/// Get buffer name from #init macro's buffer property.
fn getBufferName(e: *Emitter, node: Node.Index) ?[]const u8 {
    const buffer_node = utils.findPropertyValue(e, node, "buffer") orelse return null;
    const tags = e.ast.nodes.items(.tag);
    if (tags[buffer_node.toInt()] != .identifier_value) return null;

    const token = e.ast.nodes.items(.main_token)[buffer_node.toInt()];
    return utils.getTokenSlice(e, token);
}

/// Get shader name from #init macro's shader property.
fn getShaderName(e: *Emitter, node: Node.Index) ?[]const u8 {
    const shader_node = utils.findPropertyValue(e, node, "shader") orelse return null;
    const tags = e.ast.nodes.items(.tag);
    if (tags[shader_node.toInt()] != .identifier_value) return null;

    const token = e.ast.nodes.items(.main_token)[shader_node.toInt()];
    return utils.getTokenSlice(e, token);
}

/// Get buffer size from analyzer's symbol table.
/// Returns buffer size or 0 if not found.
fn getBufferSize(e: *Emitter, buffer_name: []const u8) u32 {
    // Look up buffer in symbols
    const buffer_info = e.analysis.symbols.buffer.get(buffer_name) orelse return 0;

    // Get the buffer node
    const buffer_node = buffer_info.node;

    // Find size property
    const size_node = utils.findPropertyValue(e, buffer_node, "size") orelse return 0;
    const tags = e.ast.nodes.items(.tag);

    if (tags[size_node.toInt()] == .number_value) {
        // Parse numeric size
        const token = e.ast.nodes.items(.main_token)[size_node.toInt()];
        const text = utils.getTokenSlice(e, token);
        return std.fmt.parseInt(u32, text, 0) catch return 0;
    }

    // Size could be a reference or expression - default to reasonable size
    return DEFAULT_WORKGROUP_SIZE * 16; // 1024 elements
}

/// Get params data from #init macro's params property.
/// Parses params=[] array and returns f32 bytes, or null if no params.
///
/// Memory: Returns allocated slice that caller must free.
fn getParamsData(e: *Emitter, node: Node.Index) Emitter.Error!?[]const u8 {
    // Pre-condition
    std.debug.assert(node.toInt() < e.ast.nodes.len);

    const params_node = utils.findPropertyValue(e, node, "params") orelse return null;
    const tags = e.ast.nodes.items(.tag);

    if (tags[params_node.toInt()] != .array) return null;

    var data_bytes: std.ArrayListUnmanaged(u8) = .{};

    const array_data = e.ast.nodes.items(.data)[params_node.toInt()];
    const elements = e.ast.extraData(array_data.extra_range);

    // Bounded iteration over array elements
    const max_elements = @min(elements.len, MAX_PARAMS_ELEMENTS);
    for (0..max_elements) |i| {
        const elem_idx = elements[i];
        const elem: Node.Index = @enumFromInt(elem_idx);
        if (utils.parseFloatNumber(e, elem)) |num| {
            // Write as f32
            const f: f32 = @floatCast(num);
            const bytes = std.mem.asBytes(&f);
            data_bytes.appendSlice(e.gpa, bytes) catch continue;
        }
    }

    if (data_bytes.items.len > 0) {
        // Return the slice - caller owns the memory
        return data_bytes.toOwnedSlice(e.gpa) catch return null;
    }

    data_bytes.deinit(e.gpa);
    return null;
}
