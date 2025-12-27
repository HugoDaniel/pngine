//! WASM Entry Point for PNGine
//!
//! Provides exported functions for browser usage.
//! Uses global allocator since WASM has no thread-local storage.
//!
//! ## Exported API
//!
//! - `onInit()`: Initialize the allocator
//! - `compile(src_ptr, src_len)`: Compile PBSF to PNGB
//! - `loadModule(ptr, len)`: Load PNGB bytecode for execution
//! - `executeAll()`: Execute all bytecode
//! - `getOutputPtr/Len()`: Get compilation output
//! - `freeOutput()`: Free compilation output
//! - `alloc/free()`: Memory management for JS
//!
//! ## Error Codes
//!
//! All exported functions returning u32 use these codes:
//! - 0: Success
//! - 1: Not initialized (onInit not called)
//! - 2: Out of memory
//! - 3: Parse error
//! - 4: Invalid format
//! - 5: No module loaded
//! - 6: Execution error
//! - 10-19: Assembler errors (see ErrorCode enum)
//! - 99: Unknown error
//!
//! ## Invariants
//!
//! - onInit() must be called before any other function
//! - loadModule() must be called before executeAll()
//! - Module data must remain valid while executing

const std = @import("std");
const assert = std.debug.assert;
const pngine = @import("main.zig");

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const WasmGPU = @import("executor/wasm_gpu.zig").WasmGPU;
const Dispatcher = @import("executor/dispatcher.zig").Dispatcher;
const command_buffer = @import("executor/command_buffer.zig");
const CommandBuffer = command_buffer.CommandBuffer;
const CommandGPU = command_buffer.CommandGPU;

// ============================================================================
// Debug Logging (extern to JS)
// ============================================================================

extern "env" fn jsConsoleLog(ptr: [*]const u8, len: u32) void;

// ============================================================================
// Error Codes
// ============================================================================

/// Error codes returned by exported functions.
/// These map to the error codes documented in the module header.
pub const ErrorCode = enum(u32) {
    success = 0,
    not_initialized = 1,
    out_of_memory = 2,
    parse_error = 3,
    invalid_format = 4,
    no_module_loaded = 5,
    execution_error = 6,
    // Assembler errors (10-19)
    unknown_form = 10,
    invalid_form_structure = 11,
    undefined_resource = 12,
    duplicate_resource = 13,
    too_many_resources = 14,
    expected_atom = 15,
    expected_string = 16,
    expected_number = 17,
    expected_list = 18,
    invalid_resource_id = 19,
    // Catch-all
    unknown = 99,

    pub fn toU32(self: ErrorCode) u32 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// Global State (WASM has no TLS)
// ============================================================================

var gpa: std.heap.GeneralPurposeAllocator(.{
    // Disable safety checks for smaller binary
    .safety = false,
    .never_unmap = true,
}) = undefined;
var allocator: std.mem.Allocator = undefined;
var initialized: bool = false;

// Last compilation result
var last_output: ?[]u8 = null;
var last_error: u32 = 0;

// Execution state
var gpu: WasmGPU = .empty;
var current_module: ?Module = null;
var module_data: ?[]u8 = null; // Owned copy of PNGB data
var frame_counter: u32 = 0; // Persists across executeAll calls for ping-pong
var resources_created: bool = false; // Track if first frame has run (resources created)

// Command buffer for renderFrame (static allocation)
var cmd_buffer: [command_buffer.DEFAULT_CAPACITY]u8 = undefined;

// ============================================================================
// Exported Functions
// ============================================================================

/// Initialize the WASM module. Must be called before any other function.
///
/// Post-condition: initialized == true, allocator is valid.
export fn onInit() void {
    gpa = .{};
    allocator = gpa.allocator();
    initialized = true;
    last_output = null;
    last_error = 0;
    gpu = .empty;
    current_module = null;
    module_data = null;
    frame_counter = 0;

    // Post-condition: runtime is ready
    assert(initialized);
}

/// Compile PBSF source to PNGB bytecode.
/// Returns: ErrorCode.success on success, error code on failure.
/// Use getOutputPtr() and getOutputLen() to retrieve the result.
export fn compile(src_ptr: [*]const u8, src_len: usize) u32 {
    if (!initialized) return ErrorCode.not_initialized.toU32();

    // Free previous output
    if (last_output) |output| {
        allocator.free(output);
        last_output = null;
    }

    // Create sentinel-terminated copy for parser
    const source_z = allocator.allocSentinel(u8, src_len, 0) catch return ErrorCode.out_of_memory.toU32();
    defer allocator.free(source_z[0 .. src_len + 1]);
    @memcpy(source_z[0..src_len], src_ptr[0..src_len]);

    // Compile
    const result = pngine.compile(allocator, source_z) catch |err| {
        last_error = @intFromEnum(switch (err) {
            error.ParseError => ErrorCode.parse_error,
            error.OutOfMemory => ErrorCode.out_of_memory,
            // Assembler errors
            error.UnknownForm => ErrorCode.unknown_form,
            error.InvalidFormStructure => ErrorCode.invalid_form_structure,
            error.UndefinedResource => ErrorCode.undefined_resource,
            error.DuplicateResource => ErrorCode.duplicate_resource,
            error.TooManyResources => ErrorCode.too_many_resources,
            error.ExpectedAtom => ErrorCode.expected_atom,
            error.ExpectedString => ErrorCode.expected_string,
            error.ExpectedNumber => ErrorCode.expected_number,
            error.ExpectedList => ErrorCode.expected_list,
            error.InvalidResourceId => ErrorCode.invalid_resource_id,
            else => ErrorCode.unknown,
        });
        return last_error;
    };

    last_output = result;
    last_error = 0;
    return ErrorCode.success.toU32();
}

/// Get pointer to last compilation output.
export fn getOutputPtr() ?[*]const u8 {
    if (last_output) |output| {
        return output.ptr;
    }
    return null;
}

/// Get length of last compilation output.
export fn getOutputLen() usize {
    if (last_output) |output| {
        return output.len;
    }
    return 0;
}

/// Free the last compilation output.
export fn freeOutput() void {
    if (last_output) |output| {
        allocator.free(output);
        last_output = null;
    }
}

// ============================================================================
// Execution Exports
// ============================================================================

/// Load PNGB bytecode for execution.
/// Returns: ErrorCode.success on success, error code on failure.
///
/// Pre-condition: onInit() has been called.
/// Post-condition: On success, current_module is valid and frame_counter == 0.
export fn loadModule(pngb_ptr: [*]const u8, pngb_len: usize) u32 {
    // Pre-condition check
    if (!initialized) return ErrorCode.not_initialized.toU32();
    assert(pngb_len > 0);

    // Free previous module if any
    freeModule();

    // Reset frame counter and resources flag for new module
    frame_counter = 0;
    resources_created = false;

    // Make owned copy of PNGB data (must outlive module)
    const data = allocator.alloc(u8, pngb_len) catch return ErrorCode.out_of_memory.toU32();
    @memcpy(data, pngb_ptr[0..pngb_len]);
    module_data = data;

    // Deserialize module
    current_module = format.deserialize(allocator, data) catch |err| {
        allocator.free(data);
        module_data = null;
        return @intFromEnum(switch (err) {
            error.InvalidMagic, error.UnsupportedVersion, error.InvalidFormat, error.InvalidOffset => ErrorCode.invalid_format,
            error.OutOfMemory => ErrorCode.out_of_memory,
            else => ErrorCode.unknown,
        });
    };

    // Set module reference for GPU backend
    gpu.setModule(&current_module.?);

    // Post-condition: module loaded successfully
    assert(current_module != null);
    assert(frame_counter == 0);

    return ErrorCode.success.toU32();
}

/// Get the current frame counter (for debugging).
export fn getFrameCounter() u32 {
    return frame_counter;
}

/// Execute all bytecode in the loaded module.
/// Returns: ErrorCode.success on success, error code on failure.
///
/// Pre-condition: onInit() and loadModule() have been called.
/// Post-condition: frame_counter is incremented by number of end_frame opcodes.
export fn executeAll() u32 {
    // Pre-condition checks
    if (!initialized) return ErrorCode.not_initialized.toU32();
    const module = &(current_module orelse return ErrorCode.no_module_loaded.toU32());

    const frame_before = frame_counter;

    // Use persistent frame counter for ping-pong buffer patterns
    var dispatcher = Dispatcher(WasmGPU).initWithFrame(allocator, &gpu, module, frame_counter);
    dispatcher.executeAll(allocator) catch return ErrorCode.execution_error.toU32();

    // Update global frame counter for next call
    frame_counter = dispatcher.frame_counter;

    // Post-condition: frame counter can only increase (never decreases)
    assert(frame_counter >= frame_before);

    return ErrorCode.success.toU32();
}

/// Execute a specific frame by index.
/// Returns: ErrorCode.success on success, error code on failure.
///
/// Pre-condition: onInit() and loadModule() have been called.
/// Post-condition: frame_counter is incremented by 1.
export fn executeFrame(target_frame_id: u32) u32 {
    // Pre-condition checks
    if (!initialized) return ErrorCode.not_initialized.toU32();
    const module = &(current_module orelse return ErrorCode.no_module_loaded.toU32());

    const frame_before = frame_counter;

    // Scan bytecode to find frame with matching ID
    var dispatcher = Dispatcher(WasmGPU).initWithFrame(allocator, &gpu, module, frame_counter);
    defer dispatcher.deinit();

    const frame_range = scanForFrame(module.bytecode, target_frame_id) orelse
        return ErrorCode.execution_error.toU32();

    // Execute just the frame's bytecode range
    dispatcher.pc = frame_range.start;
    const max_iterations: usize = 10000;
    for (0..max_iterations) |_| {
        if (dispatcher.pc >= frame_range.end) break;
        dispatcher.step(allocator) catch return ErrorCode.execution_error.toU32();
    }

    // Update global frame counter
    frame_counter = dispatcher.frame_counter;

    // Post-condition: frame counter incremented
    assert(frame_counter >= frame_before);

    return ErrorCode.success.toU32();
}

/// Execute a specific frame by name (string ID in module's string table).
/// Returns: ErrorCode.success on success, error code on failure.
export fn executeFrameByName(name_ptr: [*]const u8, name_len: usize) u32 {
    // Pre-condition checks
    if (!initialized) return ErrorCode.not_initialized.toU32();
    const module = &(current_module orelse return ErrorCode.no_module_loaded.toU32());

    const target_name = name_ptr[0..name_len];

    // Find string ID for the name
    var target_string_id: ?u16 = null;
    for (0..module.strings.count()) |i| {
        const str = module.strings.get(@enumFromInt(@as(u16, @intCast(i))));
        if (std.mem.eql(u8, str, target_name)) {
            target_string_id = @intCast(i);
            break;
        }
    }

    const string_id = target_string_id orelse {
        return ErrorCode.execution_error.toU32();
    };

    // Scan for frame with this name
    const frame_range = scanForFrameByNameId(module.bytecode, string_id) orelse {
        return ErrorCode.execution_error.toU32();
    };

    const frame_before = frame_counter;

    // Execute the frame
    var dispatcher = Dispatcher(WasmGPU).initWithFrame(allocator, &gpu, module, frame_counter);
    defer dispatcher.deinit();

    // Scan for pass definitions before executing - exec_pass needs pass_ranges
    dispatcher.scanPassDefinitions();

    dispatcher.pc = frame_range.start;
    const max_iterations: usize = 10000;
    for (0..max_iterations) |_| {
        if (dispatcher.pc >= frame_range.end) break;
        dispatcher.step(allocator) catch return ErrorCode.execution_error.toU32();
    }

    frame_counter = dispatcher.frame_counter;
    assert(frame_counter >= frame_before);

    return ErrorCode.success.toU32();
}

// ============================================================================
// Command Buffer API (new - for minimal JS bundle)
// ============================================================================

/// Render a frame and return pointer to command buffer.
/// Instead of calling extern JS functions directly, this writes GPU commands
/// to a buffer that JS can execute with a minimal dispatcher.
///
/// Returns: Pointer to command buffer, or 0 on error.
///
/// Command buffer format:
/// - [total_len: u32] [cmd_count: u16] [flags: u16]
/// - [cmd: u8] [args: ...] repeated for each command
///
/// Pre-condition: onInit() and loadModule() have been called.
/// Static CommandGPU to keep WGSL alive until next frame.
var static_cmd_gpu: ?CommandGPU = null;

export fn renderFrame(time: f32, frame_id: u16) ?[*]const u8 {
    _ = time; // TODO: pass time to commands
    _ = frame_id; // TODO: filter by frame

    // Pre-condition checks
    if (!initialized) return null;
    const module = &(current_module orelse return null);

    // Clean up previous frame's allocations
    if (static_cmd_gpu) |*prev_gpu| {
        prev_gpu.deinit();
    }

    // Create command buffer and backend
    var cmds = CommandBuffer.init(&cmd_buffer);
    static_cmd_gpu = CommandGPU.init(&cmds);
    var cmd_gpu = &(static_cmd_gpu.?);
    cmd_gpu.setModule(module);

    // Execute bytecode with command GPU backend
    var dispatcher = Dispatcher(CommandGPU).initWithFrame(allocator, cmd_gpu, module, frame_counter);
    defer dispatcher.deinit();

    if (!resources_created) {
        // First call: execute all bytecode (create resources + first frame)
        dispatcher.executeAll(allocator) catch return null;
        resources_created = true;
    } else {
        // Subsequent calls: skip to frame portion only (avoid re-initializing buffers)
        // Find first define_frame and execute from there
        const frame_start = findFirstFrameStart(module.bytecode) orelse {
            // No frame definition found, execute all (shouldn't happen)
            dispatcher.executeAll(allocator) catch return null;
            return finishFrame(&cmds, &dispatcher);
        };

        // CRITICAL: Scan for pass definitions before executing the frame.
        // exec_pass opcodes within the frame need pass_ranges to be populated.
        dispatcher.scanPassDefinitions();

        dispatcher.pc = frame_start;
        dispatcher.executeFromPC(allocator) catch return null;
    }

    return finishFrame(&cmds, &dispatcher);
}

/// Helper to finish frame and return command buffer pointer.
fn finishFrame(cmds: *CommandBuffer, dispatcher: *Dispatcher(CommandGPU)) ?[*]const u8 {
    // Update frame counter for ping-pong buffer selection
    frame_counter = dispatcher.frame_counter;

    // Finalize and return pointer
    _ = cmds.finish();
    return cmds.ptr();
}

/// Find the bytecode offset of the first define_frame opcode.
fn findFirstFrameStart(bytecode: []const u8) ?usize {
    const opcodes_mod = bytecode_mod.opcodes;
    var pc: usize = 0;
    const max_scan: usize = 10000;

    for (0..max_scan) |_| {
        if (pc >= bytecode.len) break;

        const op: opcodes_mod.OpCode = @enumFromInt(bytecode[pc]);
        if (op == .define_frame) {
            return pc; // Return position of define_frame opcode
        }

        pc += 1;
        skipOpcodeParamsAt(bytecode, &pc, op);
    }

    return null;
}

/// Get command buffer size after renderFrame.
export fn getCommandBufferLen() u32 {
    return std.mem.readInt(u32, cmd_buffer[0..4], .little);
}

/// Frame bytecode range.
const FrameRange = struct {
    start: usize,
    end: usize,
};

/// Scan bytecode to find frame definition by frame ID.
fn scanForFrame(bytecode: []const u8, target_frame_id: u32) ?FrameRange {
    const opcodes_mod = bytecode_mod.opcodes;
    var pc: usize = 0;
    const max_scan: usize = 10000;

    for (0..max_scan) |_| {
        if (pc >= bytecode.len) break;

        const op: opcodes_mod.OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .define_frame) {
            const frame_id_result = opcodes_mod.decodeVarint(bytecode[pc..]);
            pc += frame_id_result.len;
            const name_result = opcodes_mod.decodeVarint(bytecode[pc..]);
            pc += name_result.len;

            if (frame_id_result.value == target_frame_id) {
                // Found the frame - scan for end
                const frame_start = pc;
                for (0..max_scan) |_| {
                    if (pc >= bytecode.len) break;
                    const scan_op: opcodes_mod.OpCode = @enumFromInt(bytecode[pc]);
                    if (scan_op == .end_frame) {
                        return .{ .start = frame_start, .end = pc + 1 }; // Include end_frame
                    }
                    // Skip to next opcode (simplified)
                    pc += 1;
                    skipOpcodeParamsAt(bytecode, &pc, scan_op);
                }
            }
        } else {
            skipOpcodeParamsAt(bytecode, &pc, op);
        }
    }

    return null;
}

/// Scan bytecode to find frame definition by name string ID.
fn scanForFrameByNameId(bytecode: []const u8, target_name_id: u16) ?FrameRange {
    const opcodes_mod = bytecode_mod.opcodes;
    var pc: usize = 0;
    const max_scan: usize = 10000;

    for (0..max_scan) |_| {
        if (pc >= bytecode.len) break;

        const op: opcodes_mod.OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .define_frame) {
            const frame_id_result = opcodes_mod.decodeVarint(bytecode[pc..]);
            pc += frame_id_result.len;
            const name_result = opcodes_mod.decodeVarint(bytecode[pc..]);
            pc += name_result.len;

            if (name_result.value == target_name_id) {
                // Found the frame - scan for end
                const frame_start = pc;
                for (0..max_scan) |_| {
                    if (pc >= bytecode.len) break;
                    const scan_op: opcodes_mod.OpCode = @enumFromInt(bytecode[pc]);
                    if (scan_op == .end_frame) {
                        return .{ .start = frame_start, .end = pc + 1 }; // Include end_frame
                    }
                    pc += 1;
                    skipOpcodeParamsAt(bytecode, &pc, scan_op);
                }
            }
        } else {
            skipOpcodeParamsAt(bytecode, &pc, op);
        }
    }

    return null;
}

/// Skip opcode parameters at current position (modifies pc).
/// This must handle ALL opcodes that can appear before define_frame in bytecode.
fn skipOpcodeParamsAt(bytecode: []const u8, pc: *usize, op: bytecode_mod.opcodes.OpCode) void {
    const opcodes_mod = bytecode_mod.opcodes;
    switch (op) {
        // No parameters
        .end_pass, .submit, .end_frame, .nop, .begin_compute_pass, .end_pass_def => {},

        // 1 varint
        .set_pipeline, .exec_pass => pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len,

        // 2 varints
        .define_frame, .create_shader_module, .write_buffer, .write_uniform => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 2 varints (resource creation with descriptor)
        .create_texture, .create_bind_group, .create_render_pipeline, .create_compute_pipeline,
        .create_sampler, .create_bind_group_layout, .create_pipeline_layout, .create_texture_view,
        .create_query_set, .create_render_bundle, .create_image_bitmap => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 2 varints + 1 byte
        .create_buffer => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
        },

        // 3 varints
        .dispatch, .write_buffer_from_array, .write_time_uniform => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 4 varints (write_buffer_from_wasm: call_id, buffer_id, offset, byte_len)
        .write_buffer_from_wasm => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 4 varints
        .draw => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 5 varints
        .draw_indexed, .copy_buffer_to_buffer, .copy_external_image_to_texture => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 1 varint + 2 bytes + 1 varint
        .begin_render_pass => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 1 byte + 1 varint
        .set_bind_group, .set_vertex_buffer => {
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 1 byte + 1 varint + 2 bytes
        .set_vertex_buffer_pool, .set_bind_group_pool => {
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
            pc.* += 1;
        },

        // 1 varint + 1 byte
        .set_index_buffer => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
        },

        // 1 varint + 1 byte + 1 varint (create_typed_array: array_id, elem_type, count)
        .create_typed_array => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 5 varints + 1 byte (fill_constant: array_id, offset, count, stride, value)
        .fill_constant => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1; // stride
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 6 varints + 1 byte (fill_linear, fill_element_index)
        .fill_linear, .fill_element_index => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1; // stride
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 7 varints + 1 byte (fill_random)
        .fill_random => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1; // stride
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 5 varints + 1 byte (fill_expression: array_id, offset, count, stride, expr_data_id)
        .fill_expression => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1; // stride
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 1 varint + 1 byte + 1 varint (define_pass: pass_id, pass_type, desc_data_id)
        .define_pass => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 1 byte + 1 varint + 1 byte (select_from_pool)
        .select_from_pool => {
            pc.* += 1;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += 1;
        },

        // Variable length (execute_bundles: count + count varints)
        .execute_bundles => {
            const bundle_count = opcodes_mod.decodeVarint(bytecode[pc.*..]);
            pc.* += bundle_count.len;
            for (0..bundle_count.value) |_| {
                pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            }
        },

        // Variable length (create_shader_concat: shader_id, count, data_ids...)
        .create_shader_concat => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len; // shader_id
            const count = opcodes_mod.decodeVarint(bytecode[pc.*..]);
            pc.* += count.len;
            for (0..count.value) |_| {
                pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            }
        },

        // 2 varints (copy_texture_to_texture)
        .copy_texture_to_texture => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // 2 varints (init_wasm_module)
        .init_wasm_module => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len;
        },

        // Variable length (call_wasm_func)
        .call_wasm_func => {
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len; // call_id
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len; // module_id
            pc.* += opcodes_mod.decodeVarint(bytecode[pc.*..]).len; // func_name_id
            const arg_count = opcodes_mod.decodeVarint(bytecode[pc.*..]);
            pc.* += arg_count.len;
            // Skip arg_count * (type_byte + value)
            for (0..arg_count.value) |_| {
                const arg_type = bytecode[pc.*];
                pc.* += 1;
                // Arg types: 0=none, 1-4=sized values
                if (arg_type == 1) pc.* += 1
                else if (arg_type == 2) pc.* += 2
                else if (arg_type == 3) pc.* += 4
                else if (arg_type == 4) pc.* += 8;
            }
        },

        // Unknown opcodes - shouldn't happen but handle gracefully
        _ => {},
    }
}

/// Get frame count in loaded module.
export fn getFrameCount() u32 {
    const module = &(current_module orelse return 0);
    const opcodes_mod = bytecode_mod.opcodes;
    var count: u32 = 0;
    var pc: usize = 0;
    const max_scan: usize = 10000;

    for (0..max_scan) |_| {
        if (pc >= module.bytecode.len) break;
        const op: opcodes_mod.OpCode = @enumFromInt(module.bytecode[pc]);
        pc += 1;
        if (op == .define_frame) {
            count += 1;
            // Skip frame_id and name_id
            pc += opcodes_mod.decodeVarint(module.bytecode[pc..]).len;
            pc += opcodes_mod.decodeVarint(module.bytecode[pc..]).len;
        } else {
            skipOpcodeParamsAt(module.bytecode, &pc, op);
        }
    }

    return count;
}

/// Free the loaded module.
export fn freeModule() void {
    if (current_module) |*module| {
        module.deinit(allocator);
        current_module = null;
    }
    if (module_data) |data| {
        allocator.free(data);
        module_data = null;
    }
    gpu = .empty;
}

/// Allocate memory (for JS to pass data).
export fn alloc(len: usize) ?[*]u8 {
    if (!initialized) return null;
    const slice = allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

/// Free allocated memory.
export fn free(ptr: [*]u8, len: usize) void {
    if (!initialized) return;
    allocator.free(ptr[0..len]);
}

// ============================================================================
// Memory exports for C interop (if needed)
// ============================================================================

export fn memcpy(dest: ?[*]u8, src: ?[*]const u8, n: usize) ?[*]u8 {
    if (dest == null or src == null) return dest;
    @memcpy(dest.?[0..n], src.?[0..n]);
    return dest;
}

export fn memset(dest: ?[*]u8, c: c_int, n: usize) ?[*]u8 {
    if (dest == null) return dest;
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));
    @memset(dest.?[0..n], byte);
    return dest;
}

// ============================================================================
// Uniform Table Exports (Runtime Reflection)
// ============================================================================
//
// These exports enable runtime uniform setting by field name without recompilation.
// The uniform table is embedded in PNGB bytecode at compile time (via miniray reflection)
// and queried at runtime by platforms (Web, iOS, Android, Desktop).
//
// ## Why Runtime Reflection?
//
// 1. **Multiplatform**: Same Zig/WASM code works everywhere - platforms just call
//    setUniform("time", data) without knowing buffer layouts or offsets.
//
// 2. **No Recompilation**: Uniform values can be changed frame-by-frame without
//    regenerating bytecode. Only the shader code itself requires recompilation.
//
// 3. **Dynamic UI**: Platforms can enumerate all uniform fields at runtime to
//    build sliders, color pickers, and other controls dynamically.
//
// 4. **Decoupling**: Platform code doesn't need to match shader struct layouts.
//    The uniform table maps field names → (buffer_id, offset, size, type).
//
// ## Data Flow
//
// Compile Time:
//   WGSL shader → miniray reflection → uniform table → PNGB bytecode
//
// Runtime:
//   JS calls setUniform("time", [1.5]) → WASM looks up field → writes to GPU buffer
//

const uniform_table = bytecode_mod.uniform_table;
const UniformType = uniform_table.UniformType;

/// Get total number of uniform fields across all bindings.
///
/// Use this to enumerate all uniforms for dynamic UI generation.
/// Returns 0 if no module is loaded or module has no uniform bindings.
///
/// Example (JS):
/// ```javascript
/// const count = wasm.getUniformFieldCount();
/// for (let i = 0; i < count; i++) {
///     const name = getUniformFieldName(i);
///     const info = getUniformFieldInfo(i);
///     // Build UI control for this uniform
/// }
/// ```
export fn getUniformFieldCount() u32 {
    const module = &(current_module orelse return 0);
    return module.uniforms.totalFieldCount();
}

/// Get uniform field name by index.
///
/// Writes the field name to the output buffer and returns the actual length.
/// If the buffer is too small, returns the required length without writing.
/// Returns 0 if index is out of bounds or no module is loaded.
///
/// Parameters:
/// - index: Field index (0 to getUniformFieldCount()-1)
/// - out_ptr: Buffer to write the name into
/// - out_len: Size of the output buffer
///
/// Returns: Actual length of the name, or 0 if not found.
///
/// Example (JS):
/// ```javascript
/// const nameLen = wasm.getUniformFieldName(0, namePtr, 256);
/// const name = readString(namePtr, nameLen);
/// ```
export fn getUniformFieldName(index: u32, out_ptr: [*]u8, out_len: u32) u32 {
    const module = &(current_module orelse return 0);

    // Look up field by flat index
    const result = module.uniforms.getFieldByIndex(index) orelse return 0;

    // Get name from string table using string ID
    const name = module.strings.get(@enumFromInt(result.field.name_string_id));

    // Check if buffer is large enough
    if (name.len > out_len) {
        // Return required length so caller can allocate bigger buffer
        return @intCast(name.len);
    }

    // Copy name to output buffer
    @memcpy(out_ptr[0..name.len], name);
    return @intCast(name.len);
}

/// Get uniform field info by index.
///
/// Returns field metadata packed into a u64 for efficient transfer:
/// - bits 0-15:  buffer_id (u16) - GPU buffer this field writes to
/// - bits 16-31: offset (u16) - Byte offset within the buffer
/// - bits 32-47: size (u16) - Byte size of the field
/// - bits 48-55: type (u8) - UniformType enum value
/// - bits 56-63: reserved (u8) - Always 0
///
/// Returns 0xFFFFFFFFFFFFFFFF if index is out of bounds.
///
/// UniformType values:
/// - 0: f32 (4 bytes)
/// - 1: i32 (4 bytes)
/// - 2: u32 (4 bytes)
/// - 3: vec2f (8 bytes)
/// - 4: vec3f (12 bytes)
/// - 5: vec4f (16 bytes)
/// - 6: mat3x3f (48 bytes)
/// - 7: mat4x4f (64 bytes)
///
/// Example (JS):
/// ```javascript
/// const info = wasm.getUniformFieldInfo(0);
/// const bufferId = info & 0xFFFF;
/// const offset = (info >> 16) & 0xFFFF;
/// const size = (info >> 32) & 0xFFFF;
/// const type = (info >> 48) & 0xFF;
/// ```
export fn getUniformFieldInfo(index: u32) u64 {
    const module = &(current_module orelse return 0xFFFFFFFFFFFFFFFF);

    const result = module.uniforms.getFieldByIndex(index) orelse return 0xFFFFFFFFFFFFFFFF;

    // Pack into u64: buffer_id | offset | size | type | reserved
    const buffer_id: u64 = result.binding.buffer_id;
    const offset: u64 = result.field.offset;
    const size: u64 = result.field.size;
    const uniform_type: u64 = @intFromEnum(result.field.uniform_type);

    return buffer_id |
        (offset << 16) |
        (size << 32) |
        (uniform_type << 48);
}

/// Set uniform field value by name.
///
/// Looks up the field in the uniform table and writes the value to the
/// corresponding GPU buffer at the correct offset. This is the primary
/// API for runtime uniform setting.
///
/// Parameters:
/// - name_ptr: Pointer to field name (UTF-8, not null-terminated)
/// - name_len: Length of field name
/// - value_ptr: Pointer to value data (raw bytes, correct size for type)
/// - value_len: Length of value data in bytes
///
/// Returns:
/// - 0: Success
/// - 1: Field not found
/// - 2: Size mismatch (value_len doesn't match field size)
/// - 3: No module loaded
///
/// Example (JS):
/// ```javascript
/// // Set time uniform (f32)
/// const timeData = new Float32Array([1.5]);
/// const result = wasm.setUniform(
///     namePtr, nameLen,           // "time"
///     timeData.buffer, 4          // 4 bytes for f32
/// );
///
/// // Set color uniform (vec4f)
/// const colorData = new Float32Array([1.0, 0.0, 0.0, 1.0]);
/// wasm.setUniform(namePtr, nameLen, colorData.buffer, 16);
/// ```
export fn setUniform(
    name_ptr: [*]const u8,
    name_len: u32,
    value_ptr: [*]const u8,
    value_len: u32,
) u32 {
    const module = &(current_module orelse return 3);

    // Look up field name in string table to get string ID
    const name = name_ptr[0..name_len];
    const string_id = module.strings.findId(name) orelse return 1; // Not found

    // Look up field by string ID in uniform table
    const field_info = module.uniforms.findFieldByStringId(string_id.toInt()) orelse return 1;

    // Verify size matches
    if (value_len != field_info.size) return 2; // Size mismatch

    // Write to GPU buffer via gpuWriteBuffer
    // The buffer_id, offset, and value are passed to the GPU backend
    const wasm_gpu = @import("executor/wasm_gpu.zig");
    wasm_gpu.gpuWriteBuffer(
        field_info.buffer_id,
        field_info.offset,
        value_ptr,
        value_len,
    );

    return 0; // Success
}

/// Get uniform field type by index.
///
/// Returns the UniformType enum value for the field, or 255 (unknown) if
/// index is out of bounds. Useful for type-specific UI generation.
///
/// Example (JS):
/// ```javascript
/// const type = wasm.getUniformFieldType(0);
/// if (type === 5) { // vec4f
///     // Show color picker
/// } else if (type === 0) { // f32
///     // Show slider
/// }
/// ```
export fn getUniformFieldType(index: u32) u8 {
    const module = &(current_module orelse return 255);
    const result = module.uniforms.getFieldByIndex(index) orelse return 255;
    return @intFromEnum(result.field.uniform_type);
}

/// Get uniform binding count.
///
/// Returns the number of uniform bindings (not fields). Each binding maps
/// to a GPU buffer and may contain multiple fields.
export fn getUniformBindingCount() u32 {
    const module = &(current_module orelse return 0);
    return @intCast(module.uniforms.bindings.items.len);
}

// ============================================================================
// Animation Table Exports (Timeline/Scene Support)
// ============================================================================
//
// These exports enable auto-scene switching during playback. The animation
// table is embedded in PNGB bytecode at compile time (from #animation macro)
// and queried at runtime by the JS player.
//
// ## Data Flow
//
// Compile Time:
//   #animation macro → DSL → AnimationTable → PNGB bytecode
//
// Runtime:
//   JS calls getSceneAtTime(1500) → WASM looks up scene → returns scene index
//   JS reads scene info → switches to scene's frame at appropriate time
//

const animation_table = bytecode_mod.animation_table;

/// Check if animation metadata is present.
///
/// Returns 1 if animation table has data, 0 otherwise.
export fn hasAnimationInfo() u32 {
    const module = &(current_module orelse return 0);
    return if (module.animation.info != null) 1 else 0;
}

/// Get total animation duration in milliseconds.
///
/// Returns 0 if no animation is defined.
export fn getAnimationDuration() u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;
    return info.duration_ms;
}

/// Check if animation loops.
///
/// Returns 1 if loop is enabled, 0 otherwise.
export fn getAnimationLoop() u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;
    return if (info.loop) 1 else 0;
}

/// Get animation end behavior.
///
/// Returns:
/// - 0: hold (stay on last frame)
/// - 1: stop (pause playback)
/// - 2: restart (loop from beginning)
/// - 255: no animation
export fn getAnimationEndBehavior() u8 {
    const module = &(current_module orelse return 255);
    const info = module.animation.info orelse return 255;
    return @intFromEnum(info.end_behavior);
}

/// Get animation name.
///
/// Writes the animation name to the output buffer.
/// Returns actual length, or 0 if no animation.
export fn getAnimationName(out_ptr: [*]u8, out_len: u32) u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;

    const name = module.strings.get(@enumFromInt(info.name_string_id));
    if (name.len > out_len) return @intCast(name.len);

    @memcpy(out_ptr[0..name.len], name);
    return @intCast(name.len);
}

/// Get number of scenes in the animation.
export fn getSceneCount() u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;
    return @intCast(info.scenes.len);
}

/// Get scene info by index.
///
/// Returns scene metadata packed into a u64:
/// - bits 0-31:  start_ms (u32) - Scene start time in ms
/// - bits 32-63: end_ms (u32) - Scene end time in ms
///
/// Returns 0xFFFFFFFFFFFFFFFF if index is out of bounds.
export fn getSceneInfo(index: u32) u64 {
    const module = &(current_module orelse return 0xFFFFFFFFFFFFFFFF);
    const info = module.animation.info orelse return 0xFFFFFFFFFFFFFFFF;

    if (index >= info.scenes.len) return 0xFFFFFFFFFFFFFFFF;

    const scene = info.scenes[index];
    const start: u64 = scene.start_ms;
    const end: u64 = scene.end_ms;

    return start | (end << 32);
}

/// Get scene ID string by index.
///
/// Writes the scene ID to the output buffer.
/// Returns actual length, or 0 if not found.
export fn getSceneId(index: u32, out_ptr: [*]u8, out_len: u32) u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;

    if (index >= info.scenes.len) return 0;

    const scene = info.scenes[index];
    const id = module.strings.get(@enumFromInt(scene.id_string_id));
    if (id.len > out_len) return @intCast(id.len);

    @memcpy(out_ptr[0..id.len], id);
    return @intCast(id.len);
}

/// Get scene frame name by index.
///
/// Writes the frame name to the output buffer.
/// Returns actual length, or 0 if not found.
export fn getSceneFrame(index: u32, out_ptr: [*]u8, out_len: u32) u32 {
    const module = &(current_module orelse return 0);
    const info = module.animation.info orelse return 0;

    if (index >= info.scenes.len) return 0;

    const scene = info.scenes[index];
    const name = module.strings.get(@enumFromInt(scene.frame_string_id));
    if (name.len > out_len) return @intCast(name.len);

    @memcpy(out_ptr[0..name.len], name);
    return @intCast(name.len);
}

/// Find scene index at given time (in milliseconds).
///
/// Returns scene index, or 0xFFFFFFFF if no scene at this time.
///
/// Example (JS):
/// ```javascript
/// const sceneIdx = wasm.getSceneAtTime(1500); // Find scene at 1.5 seconds
/// if (sceneIdx !== 0xFFFFFFFF) {
///     const frameName = getSceneFrame(sceneIdx);
///     executeFrameByName(frameName);
/// }
/// ```
export fn getSceneAtTime(time_ms: u32) u32 {
    const module = &(current_module orelse return 0xFFFFFFFF);
    const info = module.animation.info orelse return 0xFFFFFFFF;

    // Use animation_table's findSceneAtTime
    const scene_idx = animation_table.AnimationTable.findSceneAtTimeStatic(info, time_ms);
    return scene_idx orelse 0xFFFFFFFF;
}
