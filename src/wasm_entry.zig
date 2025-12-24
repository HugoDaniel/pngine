//! WASM Executor Entry Point
//!
//! Minimal WASM module that executes PNGB bytecode and outputs a command buffer.
//! Designed for embedding in PNG payloads with plugin-based conditional compilation.
//!
//! ## Design
//!
//! - Static allocation: All buffers pre-allocated, no malloc after init
//! - Command buffer output: Executor writes platform-agnostic GPU commands
//! - Plugin-aware: Code size varies based on enabled plugins
//! - Minimal imports: Only log() from host (optional)
//!
//! ## Memory Layout
//!
//! ```
//! WASM Linear Memory (2MB default):
//! ┌─────────────────────────────────────────┐
//! │ Bytecode Buffer (256KB)                 │ ← Host writes here
//! ├─────────────────────────────────────────┤
//! │ Data Section Buffer (512KB)             │ ← Host writes here
//! ├─────────────────────────────────────────┤
//! │ Command Buffer (64KB)                   │ ← Executor writes here
//! ├─────────────────────────────────────────┤
//! │ Scratch Space (remaining)               │ ← Internal use
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Exports
//!
//! - `init()`: Parse bytecode, emit resource creation commands
//! - `frame(time, width, height)`: Emit per-frame commands
//! - `getCommandPtr()` / `getCommandLen()`: Read command buffer
//! - `getBytecodePtr()` / `setBytecodeLen()`: Write bytecode
//! - `getDataPtr()` / `setDataLen()`: Write data section
//!
//! ## Invariants
//!
//! - Bytecode must be written before init() is called
//! - Data section must be written before init() is called
//! - Command buffer is valid until next init() or frame() call

const std = @import("std");
const builtin = @import("builtin");
const plugins = @import("executor/plugins.zig");
const command_buffer = @import("executor/command_buffer.zig");
const CommandBuffer = command_buffer.CommandBuffer;
const Cmd = command_buffer.Cmd;
const format = @import("bytecode/format.zig");
const opcodes = @import("bytecode/opcodes.zig");
const OpCode = opcodes.OpCode;

// ============================================================================
// Configuration
// ============================================================================

/// Maximum bytecode size (256KB).
const MAX_BYTECODE_SIZE: u32 = 256 * 1024;

/// Maximum data section size (512KB).
const MAX_DATA_SIZE: u32 = 512 * 1024;

/// Command buffer capacity (64KB).
const COMMAND_BUFFER_SIZE: u32 = 64 * 1024;

/// Maximum WGSL modules for resolution.
const MAX_WGSL_MODULES: u32 = 64;

/// Maximum iterations for bytecode execution (safety bound).
/// Must be >= bytecode size to handle 1-byte opcodes worst case.
const MAX_EXEC_ITERATIONS: u32 = MAX_BYTECODE_SIZE;

// Compile-time invariants
comptime {
    const assert = std.debug.assert;
    // Command buffer must fit meaningful output.
    assert(COMMAND_BUFFER_SIZE >= 4096);
    // Bytecode buffer must hold at least header + minimal bytecode.
    assert(MAX_BYTECODE_SIZE >= format.HEADER_SIZE + 64);
    // Data section must accommodate typical shader code.
    assert(MAX_DATA_SIZE >= 8192);
    // Execution bound must handle worst-case 1-byte opcodes.
    assert(MAX_EXEC_ITERATIONS >= MAX_BYTECODE_SIZE);
}

// ============================================================================
// Static Buffers (No Malloc)
// ============================================================================

/// Bytecode buffer - host writes here via getBytecodePtr().
var bytecode_buffer: [MAX_BYTECODE_SIZE]u8 = undefined;
var bytecode_len: u32 = 0;

/// Data section buffer - host writes here via getDataPtr().
var data_buffer: [MAX_DATA_SIZE]u8 = undefined;
var data_len: u32 = 0;

/// Command buffer - executor writes here, host reads via getCommandPtr().
var cmd_buffer: [COMMAND_BUFFER_SIZE]u8 = undefined;

/// Executor state.
var initialized: bool = false;
var frame_counter: u32 = 0;
var resources_created: bool = false;

// Parsed module info (cached after init)
var string_table_offset: u32 = 0;
var string_table_len: u32 = 0;
var data_section_offset: u32 = 0;
var bytecode_start: u32 = 0;
var bytecode_end: u32 = 0;

// ============================================================================
// Host Imports (Minimal)
// ============================================================================

/// Optional debug logging.
extern "env" fn log(ptr: [*]const u8, len: u32) void;

// ============================================================================
// Exports - Memory Interface
// ============================================================================

/// Get pointer where host should write bytecode.
export fn getBytecodePtr() [*]u8 {
    return &bytecode_buffer;
}

/// Set bytecode length after host writes.
export fn setBytecodeLen(len: u32) void {
    bytecode_len = @min(len, MAX_BYTECODE_SIZE);
}

/// Get pointer where host should write data section.
export fn getDataPtr() [*]u8 {
    return &data_buffer;
}

/// Set data section length after host writes.
export fn setDataLen(len: u32) void {
    data_len = @min(len, MAX_DATA_SIZE);
}

/// Get pointer to command buffer output.
export fn getCommandPtr() [*]const u8 {
    return &cmd_buffer;
}

/// Get command buffer length after init() or frame().
export fn getCommandLen() u32 {
    return std.mem.readInt(u32, cmd_buffer[0..4], .little);
}

// ============================================================================
// Exports - Execution Interface
// ============================================================================

/// Initialize executor. Call after writing bytecode and data.
///
/// Parses the bytecode header and emits all resource creation commands
/// to the command buffer. Host should execute these commands to create
/// GPU resources before calling frame().
///
/// Returns: 0 on success, error code on failure.
/// Complexity: O(n) where n = bytecode size.
export fn init() u32 {
    const assert = std.debug.assert;

    // Pre-condition: bytecode was written by host.
    assert(bytecode_len <= MAX_BYTECODE_SIZE);

    // Reset state
    frame_counter = 0;
    resources_created = false;

    // Validate bytecode - need at least v4 header size
    if (bytecode_len < format.HEADER_SIZE_V4) {
        return 1; // Invalid bytecode
    }

    // Parse header (first 8 bytes are common to all versions)
    const header = bytecode_buffer[0..bytecode_len];
    if (!std.mem.eql(u8, header[0..4], "PNGB")) {
        return 2; // Invalid magic
    }

    const version = std.mem.readInt(u16, header[4..6], .little);
    if (version < 4 or version > 5) {
        return 3; // Unsupported version
    }

    // Cache offsets based on version
    if (version == 5) {
        // V5: 40-byte header
        if (bytecode_len < format.HEADER_SIZE) {
            return 1; // Invalid bytecode for v5
        }
        bytecode_start = format.HEADER_SIZE;
        string_table_offset = std.mem.readInt(u32, header[24..28], .little);
        string_table_len = std.mem.readInt(u32, header[28..32], .little);
        data_section_offset = std.mem.readInt(u32, header[32..36], .little);
        bytecode_end = string_table_offset;
    } else {
        // V4: 28-byte header
        bytecode_start = format.HEADER_SIZE_V4;
        string_table_offset = std.mem.readInt(u32, header[12..16], .little);
        string_table_len = std.mem.readInt(u32, header[16..20], .little);
        data_section_offset = std.mem.readInt(u32, header[20..24], .little);
        bytecode_end = string_table_offset;
    }

    // Execute resource creation phase
    var cmds = CommandBuffer.init(&cmd_buffer);
    executeResourceCreation(&cmds);
    _ = cmds.finish();

    // Post-condition: state is consistent.
    assert(bytecode_start <= bytecode_end);
    assert(bytecode_end <= bytecode_len);

    initialized = true;
    resources_created = true;
    return 0;
}

/// Render a frame. Call once per animation frame.
///
/// Updates uniforms with the provided time/dimensions and emits
/// frame rendering commands to the command buffer.
///
/// Parameters:
/// - time: Elapsed time in seconds
/// - width: Canvas width in pixels
/// - height: Canvas height in pixels
///
/// Returns: 0 on success, error code on failure.
/// Complexity: O(n) where n = frame bytecode size.
export fn frame(time: f32, width: u32, height: u32) u32 {
    const assert = std.debug.assert;

    // Pre-condition: must be initialized first.
    if (!initialized) {
        return 1; // Not initialized
    }

    // Pre-condition: dimensions are valid.
    assert(width > 0);
    assert(height > 0);

    var cmds = CommandBuffer.init(&cmd_buffer);
    executeFrame(&cmds, time, width, height);
    _ = cmds.finish();

    // Post-condition: frame counter advances.
    const prev_frame = frame_counter;
    frame_counter += 1;
    assert(frame_counter == prev_frame + 1);

    return 0;
}

/// Get current frame counter (for debugging/sync).
export fn getFrameCounter() u32 {
    return frame_counter;
}

// ============================================================================
// Internal - Bytecode Execution
// ============================================================================

/// Execute resource creation opcodes (everything before first define_frame).
fn executeResourceCreation(cmds: *CommandBuffer) void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];
    var pc: usize = 0;

    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        // Stop at first frame definition
        if (op == .define_frame) break;

        executeOpcode(cmds, bytecode, &pc, op);
    }
}

/// Execute frame opcodes.
fn executeFrame(cmds: *CommandBuffer, time: f32, width: u32, height: u32) void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];

    // Find first frame
    var pc: usize = 0;
    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .define_frame) {
            // Skip frame_id and name_id
            _ = readVarint(bytecode, &pc);
            _ = readVarint(bytecode, &pc);
            break;
        }

        skipOpcodeParams(bytecode, &pc, op);
    }

    // Execute frame body
    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .end_frame) break;

        // Handle time uniform specially
        if (op == .write_time_uniform) {
            const buffer_id = readVarint(bytecode, &pc);
            const offset = readVarint(bytecode, &pc);
            const size = readVarint(bytecode, &pc);
            _ = size;

            // Write time uniform data (time, width, height, aspect)
            const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
            _ = aspect;
            _ = time;

            // For now just emit the command - host will fill in actual values
            cmds.writeTimeUniform(@intCast(buffer_id), @intCast(offset), 16);
            continue;
        }

        executeOpcode(cmds, bytecode, &pc, op);
    }
}

/// Execute a single opcode. Dispatches to plugin-specific handlers.
/// Complexity: O(1) for most opcodes.
fn executeOpcode(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        // Core plugin (always enabled)
        .create_buffer, .create_shader_module, .create_sampler, .create_bind_group,
        .create_bind_group_layout, .create_pipeline_layout, .write_buffer,
        .copy_buffer_to_buffer, .submit,
        => execCore(cmds, bytecode, pc, op),

        // Render plugin
        .create_render_pipeline, .begin_render_pass, .set_pipeline, .set_bind_group,
        .set_vertex_buffer, .set_index_buffer, .draw, .draw_indexed,
        .end_pass, .create_render_bundle,
        => execRender(cmds, bytecode, pc, op),

        // Compute plugin
        .create_compute_pipeline, .begin_compute_pass, .dispatch,
        => execCompute(cmds, bytecode, pc, op),

        // Texture plugin
        .create_texture, .create_texture_view, .create_image_bitmap,
        .copy_texture_to_texture, .copy_external_image_to_texture,
        => execTexture(cmds, bytecode, pc, op),

        // WASM plugin
        .init_wasm_module, .call_wasm_func, .write_buffer_from_wasm,
        => execWasm(cmds, bytecode, pc, op),

        // Utility operations
        .create_typed_array, .fill_random, .fill_constant,
        .fill_expression, .write_buffer_from_array,
        => execUtility(cmds, bytecode, pc, op),

        // Pass/Frame structure and ignored opcodes
        .define_pass, .define_frame, .end_pass_def, .end_frame, .exec_pass,
        .nop, .create_query_set, .execute_bundles, .create_shader_concat,
        .write_uniform, .write_time_uniform, .set_bind_group_pool,
        .set_vertex_buffer_pool, .select_from_pool, .fill_linear, .fill_element_index,
        => skipOpcodeParams(bytecode, pc, op),

        _ => {}, // Unknown opcode
    }
}

// ============================================================================
// Plugin Handlers - Core (Always Enabled)
// ============================================================================

/// Handle core plugin opcodes: buffer, shader, sampler, bind group, submit.
fn execCore(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_buffer => {
            const id = readVarint(bytecode, pc);
            const size = readVarint(bytecode, pc);
            const usage = bytecode[pc.*];
            pc.* += 1;
            cmds.createBuffer(@intCast(id), @intCast(size), usage);
        },
        .create_shader_module => {
            const id = readVarint(bytecode, pc);
            const data_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(data_id));
            cmds.createShader(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .create_sampler => {
            const id = readVarint(bytecode, pc);
            const desc_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(desc_id));
            cmds.createSampler(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .create_bind_group => {
            const id = readVarint(bytecode, pc);
            const layout_id = readVarint(bytecode, pc);
            const entries_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(entries_id));
            cmds.createBindGroup(@intCast(id), @intCast(layout_id), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .create_bind_group_layout => {
            const id = readVarint(bytecode, pc);
            const desc_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(desc_id));
            cmds.createBindGroupLayout(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .create_pipeline_layout => {
            const id = readVarint(bytecode, pc);
            const desc_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(desc_id));
            cmds.createPipelineLayout(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .write_buffer => {
            const buffer_id = readVarint(bytecode, pc);
            const offset = readVarint(bytecode, pc);
            const data_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(data_id));
            cmds.writeBuffer(@intCast(buffer_id), @intCast(offset), @intFromPtr(data.ptr), @intCast(data.len));
        },
        .copy_buffer_to_buffer => {
            const src_id = readVarint(bytecode, pc);
            const src_off = readVarint(bytecode, pc);
            const dst_id = readVarint(bytecode, pc);
            const dst_off = readVarint(bytecode, pc);
            const size = readVarint(bytecode, pc);
            cmds.copyBufferToBuffer(@intCast(src_id), @intCast(src_off), @intCast(dst_id), @intCast(dst_off), @intCast(size));
        },
        .submit => cmds.submit(),
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Render
// ============================================================================

/// Handle render plugin opcodes: pipeline, pass, draw commands.
fn execRender(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_render_pipeline => {
            if (comptime plugins.isEnabled(.render)) {
                const id = readVarint(bytecode, pc);
                const desc_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(desc_id));
                cmds.createRenderPipeline(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                skipRenderPipelineParams(bytecode, pc);
            }
        },
        .begin_render_pass => {
            if (comptime plugins.isEnabled(.render)) {
                const color_id = readVarint(bytecode, pc);
                const load_op = bytecode[pc.*];
                pc.* += 1;
                const store_op = bytecode[pc.*];
                pc.* += 1;
                const depth_id = readVarint(bytecode, pc);
                cmds.beginRenderPass(@intCast(color_id), load_op, store_op, @intCast(depth_id));
            } else {
                skipRenderPassParams(bytecode, pc);
            }
        },
        .set_pipeline => {
            const id = readVarint(bytecode, pc);
            cmds.setPipeline(@intCast(id));
        },
        .set_bind_group => {
            const slot = bytecode[pc.*];
            pc.* += 1;
            const id = readVarint(bytecode, pc);
            cmds.setBindGroup(slot, @intCast(id));
        },
        .set_vertex_buffer => {
            if (comptime plugins.isEnabled(.render)) {
                const slot = bytecode[pc.*];
                pc.* += 1;
                const id = readVarint(bytecode, pc);
                cmds.setVertexBuffer(slot, @intCast(id));
            } else {
                pc.* += 1;
                _ = readVarint(bytecode, pc);
            }
        },
        .set_index_buffer => {
            if (comptime plugins.isEnabled(.render)) {
                const id = readVarint(bytecode, pc);
                const fmt = bytecode[pc.*];
                pc.* += 1;
                cmds.setIndexBuffer(@intCast(id), fmt);
            } else {
                _ = readVarint(bytecode, pc);
                pc.* += 1;
            }
        },
        .draw => {
            if (comptime plugins.isEnabled(.render)) {
                const vtx = readVarint(bytecode, pc);
                const inst = readVarint(bytecode, pc);
                const first_vtx = readVarint(bytecode, pc);
                const first_inst = readVarint(bytecode, pc);
                cmds.draw(@intCast(vtx), @intCast(inst), @intCast(first_vtx), @intCast(first_inst));
            } else {
                skipDrawParams(bytecode, pc);
            }
        },
        .draw_indexed => {
            if (comptime plugins.isEnabled(.render)) {
                const idx = readVarint(bytecode, pc);
                const inst = readVarint(bytecode, pc);
                const first_idx = readVarint(bytecode, pc);
                const base_vtx = readVarint(bytecode, pc);
                const first_inst = readVarint(bytecode, pc);
                cmds.drawIndexed(@intCast(idx), @intCast(inst), @intCast(first_idx), @intCast(base_vtx), @intCast(first_inst));
            } else {
                skipDrawIndexedParams(bytecode, pc);
            }
        },
        .end_pass => cmds.endPass(),
        .create_render_bundle => {
            if (comptime plugins.isEnabled(.render)) {
                const id = readVarint(bytecode, pc);
                const desc_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(desc_id));
                cmds.createRenderBundle(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Compute
// ============================================================================

/// Handle compute plugin opcodes: pipeline, pass, dispatch.
fn execCompute(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_compute_pipeline => {
            if (comptime plugins.isEnabled(.compute)) {
                const id = readVarint(bytecode, pc);
                const desc_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(desc_id));
                cmds.createComputePipeline(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .begin_compute_pass => {
            if (comptime plugins.isEnabled(.compute)) {
                cmds.beginComputePass();
            }
        },
        .dispatch => {
            if (comptime plugins.isEnabled(.compute)) {
                const x = readVarint(bytecode, pc);
                const y = readVarint(bytecode, pc);
                const z = readVarint(bytecode, pc);
                cmds.dispatch(@intCast(x), @intCast(y), @intCast(z));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Texture
// ============================================================================

/// Handle texture plugin opcodes: texture creation, copy.
fn execTexture(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                const id = readVarint(bytecode, pc);
                const desc_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(desc_id));
                cmds.createTexture(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .create_texture_view => {
            if (comptime plugins.isEnabled(.texture)) {
                const id = readVarint(bytecode, pc);
                const tex_id = readVarint(bytecode, pc);
                const desc_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(desc_id));
                cmds.createTextureView(@intCast(id), @intCast(tex_id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .create_image_bitmap => {
            if (comptime plugins.isEnabled(.texture)) {
                const id = readVarint(bytecode, pc);
                const data_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(data_id));
                cmds.createImageBitmap(@intCast(id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .copy_texture_to_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                const src_id = readVarint(bytecode, pc);
                const dst_id = readVarint(bytecode, pc);
                cmds.copyTextureToTexture(@intCast(src_id), @intCast(dst_id), 0, 0);
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .copy_external_image_to_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                const bmp_id = readVarint(bytecode, pc);
                const tex_id = readVarint(bytecode, pc);
                const mip = readVarint(bytecode, pc);
                const ox = readVarint(bytecode, pc);
                const oy = readVarint(bytecode, pc);
                cmds.copyExternalImageToTexture(@intCast(bmp_id), @intCast(tex_id), @intCast(mip), @intCast(ox), @intCast(oy));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - WASM
// ============================================================================

/// Handle WASM plugin opcodes: module init, function calls.
fn execWasm(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .init_wasm_module => {
            if (comptime plugins.isEnabled(.wasm)) {
                const mod_id = readVarint(bytecode, pc);
                const data_id = readVarint(bytecode, pc);
                const data = getDataSlice(@intCast(data_id));
                cmds.initWasmModule(@intCast(mod_id), @intFromPtr(data.ptr), @intCast(data.len));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        .call_wasm_func => {
            if (comptime plugins.isEnabled(.wasm)) {
                const call_id = readVarint(bytecode, pc);
                const mod_id = readVarint(bytecode, pc);
                const func_id = readVarint(bytecode, pc);
                const arg_count_raw = bytecode[pc.*];
                pc.* += 1;

                // Get function name from string table
                const func_name = getStringSlice(@intCast(func_id));

                // Calculate args size for command buffer
                // Args start at current pc, format: [arg_type:u8][value?:0-4 bytes]...
                const args_start = pc.*;
                for (0..arg_count_raw) |_| {
                    const arg_type: opcodes.WasmArgType = @enumFromInt(bytecode[pc.*]);
                    pc.* += 1;
                    pc.* += arg_type.valueByteSize();
                }
                const args_end = pc.*;

                // Emit call_wasm_func command with args embedded
                // Build args buffer: [arg_count][arg_type, value?]...
                var args_buf: [257]u8 = undefined; // 1 + 16 args * max 5 bytes each
                args_buf[0] = arg_count_raw;
                const args_len = args_end - args_start;
                if (args_len <= 256) {
                    @memcpy(args_buf[1 .. 1 + args_len], bytecode[args_start..args_end]);
                    cmds.callWasmFunc(
                        @intCast(call_id),
                        @intCast(mod_id),
                        @intFromPtr(func_name.ptr),
                        @intCast(func_name.len),
                        @intFromPtr(&args_buf),
                        @intCast(1 + args_len),
                    );
                }
            } else {
                skipWasmCallParams(bytecode, pc);
            }
        },
        .write_buffer_from_wasm => {
            if (comptime plugins.isEnabled(.wasm)) {
                const call_id = readVarint(bytecode, pc);
                const buffer_id = readVarint(bytecode, pc);
                const offset = readVarint(bytecode, pc);
                const size = readVarint(bytecode, pc);
                cmds.writeBufferFromWasm(@intCast(buffer_id), @intCast(offset), @intCast(call_id), @intCast(size));
            } else {
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
                _ = readVarint(bytecode, pc);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Utility
// ============================================================================

/// Handle utility opcodes: typed arrays, fill operations.
fn execUtility(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_typed_array => {
            const id = readVarint(bytecode, pc);
            const arr_type = bytecode[pc.*];
            pc.* += 1;
            const count = readVarint(bytecode, pc);
            cmds.createTypedArray(@intCast(id), arr_type, @intCast(count));
        },
        .fill_random => {
            const arr_id = readVarint(bytecode, pc);
            const offset = readVarint(bytecode, pc);
            const count = readVarint(bytecode, pc);
            const stride = bytecode[pc.*];
            pc.* += 1;
            // Skip seed, min, max IDs - JS generates random data
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            cmds.fillRandom(@intCast(arr_id), @intCast(offset), @intCast(count), stride, 0);
        },
        .fill_constant => {
            const arr_id = readVarint(bytecode, pc);
            const offset = readVarint(bytecode, pc);
            const count = readVarint(bytecode, pc);
            const stride = bytecode[pc.*];
            pc.* += 1;
            const value_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(value_id));
            cmds.fillConstant(@intCast(arr_id), @intCast(offset), @intCast(count), stride, @intFromPtr(data.ptr));
        },
        .fill_expression => {
            const arr_id = readVarint(bytecode, pc);
            const offset = readVarint(bytecode, pc);
            const count = readVarint(bytecode, pc);
            const stride = bytecode[pc.*];
            pc.* += 1;
            const expr_id = readVarint(bytecode, pc);
            const data = getDataSlice(@intCast(expr_id));
            cmds.fillExpression(@intCast(arr_id), @intCast(offset), @intCast(count), stride, @intFromPtr(data.ptr), @intCast(data.len));
        },
        .write_buffer_from_array => {
            const buffer_id = readVarint(bytecode, pc);
            const offset = readVarint(bytecode, pc);
            const arr_id = readVarint(bytecode, pc);
            cmds.writeBufferFromArray(@intCast(buffer_id), @intCast(offset), @intCast(arr_id));
        },
        else => {},
    }
}

// ============================================================================
// Internal - Helpers
// ============================================================================

/// Read varint from bytecode.
fn readVarint(bytecode: []const u8, pc: *usize) u32 {
    const result = opcodes.decodeVarint(bytecode[pc.*..]);
    pc.* += result.len;
    return result.value;
}

/// Get slice from data section by data ID.
fn getDataSlice(data_id: u16) []const u8 {
    // Data section format: count (u16) + entries (offset, len pairs)
    if (data_len == 0) return &[_]u8{};

    const data = data_buffer[0..data_len];
    if (data.len < 2) return &[_]u8{};

    const count = std.mem.readInt(u16, data[0..2], .little);
    if (data_id >= count) return &[_]u8{};

    // Each entry is 8 bytes: offset (u32) + length (u32)
    const entry_offset: usize = 2 + @as(usize, data_id) * 8;
    if (entry_offset + 8 > data.len) return &[_]u8{};

    const offset = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
    const len = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

    if (offset + len > data.len) return &[_]u8{};
    return data[offset..][0..len];
}

/// Get string slice from string table by string ID.
/// String table format: count(u16) + offsets([count]u16) + lengths([count]u16) + data(bytes)
fn getStringSlice(string_id: u16) []const u8 {
    if (string_table_len == 0) return &[_]u8{};

    // String table is in bytecode_buffer at string_table_offset
    const table = bytecode_buffer[string_table_offset..][0..string_table_len];
    if (table.len < 2) return &[_]u8{};

    const count = std.mem.readInt(u16, table[0..2], .little);
    if (string_id >= count) return &[_]u8{};

    // Calculate offsets and lengths array positions
    const offsets_start: usize = 2;
    const lengths_start: usize = 2 + @as(usize, count) * 2;
    const data_start: usize = 2 + @as(usize, count) * 4;

    if (data_start > table.len) return &[_]u8{};

    // Read this string's offset and length
    const offset_pos = offsets_start + @as(usize, string_id) * 2;
    const length_pos = lengths_start + @as(usize, string_id) * 2;

    if (offset_pos + 2 > table.len or length_pos + 2 > table.len) return &[_]u8{};

    const str_offset = std.mem.readInt(u16, table[offset_pos..][0..2], .little);
    const str_len = std.mem.readInt(u16, table[length_pos..][0..2], .little);

    // String offset is relative to data section start
    const abs_offset = data_start + str_offset;
    if (abs_offset + str_len > table.len) return &[_]u8{};

    return table[abs_offset..][0..str_len];
}

/// Skip parameters for an opcode (for scanning without executing).
fn skipOpcodeParams(bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .end_pass, .submit, .end_frame, .nop, .begin_compute_pass, .end_pass_def => {},
        .set_pipeline, .exec_pass => _ = readVarint(bytecode, pc),
        .define_frame, .create_shader_module, .write_buffer, .write_uniform,
        .create_texture, .create_render_pipeline, .create_compute_pipeline,
        .create_sampler, .create_bind_group_layout, .create_pipeline_layout,
        .create_query_set, .create_render_bundle, .create_image_bitmap,
        .init_wasm_module, .copy_texture_to_texture => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .create_buffer => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            pc.* += 1;
        },
        .dispatch, .write_buffer_from_array, .write_time_uniform, .create_bind_group,
        .create_texture_view => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .draw, .write_buffer_from_wasm => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .draw_indexed, .copy_buffer_to_buffer, .copy_external_image_to_texture => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .begin_render_pass => {
            _ = readVarint(bytecode, pc);
            pc.* += 2;
            _ = readVarint(bytecode, pc);
        },
        .set_bind_group, .set_vertex_buffer => {
            pc.* += 1;
            _ = readVarint(bytecode, pc);
        },
        .set_index_buffer => {
            _ = readVarint(bytecode, pc);
            pc.* += 1;
        },
        .define_pass, .create_typed_array => {
            _ = readVarint(bytecode, pc);
            pc.* += 1;
            _ = readVarint(bytecode, pc);
        },
        .fill_constant, .fill_expression => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            pc.* += 1;
            _ = readVarint(bytecode, pc);
        },
        .fill_linear, .fill_element_index => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            pc.* += 1;
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .fill_random => {
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            pc.* += 1;
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
            _ = readVarint(bytecode, pc);
        },
        .set_bind_group_pool, .set_vertex_buffer_pool => {
            pc.* += 1;
            _ = readVarint(bytecode, pc);
            pc.* += 2;
        },
        .select_from_pool => {
            pc.* += 1;
            _ = readVarint(bytecode, pc);
            pc.* += 1;
        },
        .execute_bundles => {
            const count = readVarint(bytecode, pc);
            for (0..count) |_| {
                _ = readVarint(bytecode, pc);
            }
        },
        .create_shader_concat => {
            _ = readVarint(bytecode, pc);
            const count = readVarint(bytecode, pc);
            for (0..count) |_| {
                _ = readVarint(bytecode, pc);
            }
        },
        .call_wasm_func => skipWasmCallParams(bytecode, pc),
        _ => {},
    }
}

// Skip helpers for plugin-disabled paths
fn skipRenderPipelineParams(bytecode: []const u8, pc: *usize) void {
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
}

fn skipRenderPassParams(bytecode: []const u8, pc: *usize) void {
    _ = readVarint(bytecode, pc);
    pc.* += 2;
    _ = readVarint(bytecode, pc);
}

fn skipDrawParams(bytecode: []const u8, pc: *usize) void {
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
}

fn skipDrawIndexedParams(bytecode: []const u8, pc: *usize) void {
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
}

fn skipWasmCallParams(bytecode: []const u8, pc: *usize) void {
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    _ = readVarint(bytecode, pc);
    const arg_count = readVarint(bytecode, pc);
    for (0..arg_count) |_| {
        const arg_type = bytecode[pc.*];
        pc.* += 1;
        if (arg_type == 1) pc.* += 1
        else if (arg_type == 2) pc.* += 2
        else if (arg_type == 3) pc.* += 4
        else if (arg_type == 4) pc.* += 8;
    }
}
