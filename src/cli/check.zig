//! Check command: validate bytecode by running through MockGPU.
//!
//! Usage:
//!   pngine check input.pngine   # Compile and validate
//!   pngine check input.pngb     # Validate existing bytecode
//!   pngine check input.png      # Extract and validate from PNG

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const mock_gpu = pngine.mock_gpu;
const MockGPU = mock_gpu.MockGPU;
const Call = mock_gpu.Call;
const Dispatcher = pngine.Dispatcher;
const DescriptorEncoder = pngine.DescriptorEncoder;
const utils = @import("utils.zig");
const bundle = @import("bundle.zig");
const compile = @import("compile.zig");

/// Execute the check command.
///
/// Pre-condition: args is the slice after "check" command.
/// Post-condition: Returns exit code (0 = success, non-zero = error).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    std.debug.assert(args.len <= 1024);

    if (args.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        std.debug.print("Usage: pngine check <input>\n", .{});
        return 1;
    }

    const input = args[0];

    // Load or compile bytecode
    const bytecode = loadOrCompileBytecode(allocator, input) catch |err| {
        return handleLoadError(err, input);
    };
    defer allocator.free(bytecode);

    // Validate and deserialize
    var module = validateAndDeserialize(allocator, bytecode) catch |err| {
        return handleDeserializeError(err);
    };
    defer module.deinit(allocator);

    // Print module info
    printModuleInfo(input, &module);

    // Execute with MockGPU to validate bytecode
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var dispatcher = Dispatcher(MockGPU).init(allocator, &gpu, &module);
    defer dispatcher.deinit();
    dispatcher.executeAll(allocator) catch |err| {
        std.debug.print("\nExecution error: {}\n", .{err});
        return 5;
    };

    // Print execution summary and validate
    const calls = gpu.getCalls();
    return printExecutionSummary(calls, &module);
}

/// Load bytecode from file or compile from source.
fn loadOrCompileBytecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    std.debug.assert(input.len > 0);

    const extension = std.fs.path.extension(input);

    if (std.mem.eql(u8, extension, ".pngb")) {
        return utils.readBinaryFile(allocator, input);
    }

    if (std.mem.eql(u8, extension, ".png")) {
        const png_data = try utils.readBinaryFile(allocator, input);
        defer allocator.free(png_data);

        const bytecode = pngine.png.extractBytecode(allocator, png_data) catch |err| {
            std.debug.print("Error: failed to extract bytecode from PNG: {}\n", .{err});
            return error.InvalidFormat;
        };

        std.debug.assert(bytecode.len > 0);
        return bytecode;
    }

    if (std.mem.eql(u8, extension, ".zip")) {
        const zip_data = try utils.readBinaryFile(allocator, input);
        defer allocator.free(zip_data);

        const bytecode = bundle.extractFromZip(allocator, zip_data) catch |err| {
            std.debug.print("Error: failed to extract bytecode from ZIP: {}\n", .{err});
            return error.InvalidFormat;
        };

        std.debug.assert(bytecode.len > 0);
        return bytecode;
    }

    // Compile source file
    const source = try utils.readSourceFile(allocator, input);
    defer allocator.free(source);

    const bytecode = try compile.compileSource(allocator, input, source);
    std.debug.assert(bytecode.len > 0);
    return bytecode;
}

fn handleLoadError(err: anyerror, input: []const u8) u8 {
    switch (err) {
        error.FileNotFound, error.AccessDenied, error.FileTooLarge => {
            std.debug.print("Error: failed to read '{s}': {}\n", .{ input, err });
            return 2;
        },
        else => {
            std.debug.print("Error: compilation failed: {}\n", .{err});
            return 3;
        },
    }
}

fn validateAndDeserialize(allocator: std.mem.Allocator, bytecode: []const u8) !format.Module {
    std.debug.assert(bytecode.len > 0);

    if (bytecode.len < format.HEADER_SIZE) {
        std.debug.print("Error: file too small to be valid PNGB\n", .{});
        return error.InvalidFormat;
    }
    if (!std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        std.debug.print("Error: invalid PNGB magic bytes\n", .{});
        return error.InvalidFormat;
    }

    const module = try format.deserialize(allocator, bytecode);
    std.debug.assert(module.bytecode.len > 0);
    return module;
}

fn handleDeserializeError(err: anyerror) u8 {
    if (err == error.InvalidFormat) return 4;
    std.debug.print("Error: failed to deserialize PNGB: {}\n", .{err});
    return 4;
}

fn printModuleInfo(input: []const u8, module: *const format.Module) void {
    std.debug.assert(input.len > 0);
    std.debug.print("PNGB: {s}\n", .{input});
    std.debug.print("  Bytecode:     {d} bytes\n", .{module.bytecode.len});
    std.debug.print("  Strings:      {d} entries\n", .{module.strings.count()});
    std.debug.print("  Data section: {d} entries\n", .{module.data.count()});
}

const CallCounts = struct {
    shader: u32 = 0,
    pipeline: u32 = 0,
    draw: u32 = 0,
    dispatch: u32 = 0,
    texture: u32 = 0,
    sampler: u32 = 0,
    buffer: u32 = 0,
    bind_group: u32 = 0,
};

fn countCallTypes(calls: []const Call) CallCounts {
    var counts: CallCounts = .{};
    for (calls) |call| {
        switch (call.call_type) {
            .create_shader_module => counts.shader += 1,
            .create_render_pipeline, .create_compute_pipeline => counts.pipeline += 1,
            .draw, .draw_indexed => counts.draw += 1,
            .dispatch => counts.dispatch += 1,
            .create_texture => counts.texture += 1,
            .create_sampler => counts.sampler += 1,
            .create_buffer => counts.buffer += 1,
            .create_bind_group => counts.bind_group += 1,
            else => {},
        }
    }
    return counts;
}

fn printCallCounts(counts: CallCounts) void {
    if (counts.shader > 0) std.debug.print("  Shaders:     {d}\n", .{counts.shader});
    if (counts.pipeline > 0) std.debug.print("  Pipelines:   {d}\n", .{counts.pipeline});
    if (counts.buffer > 0) std.debug.print("  Buffers:     {d}\n", .{counts.buffer});
    if (counts.texture > 0) std.debug.print("  Textures:    {d}\n", .{counts.texture});
    if (counts.sampler > 0) std.debug.print("  Samplers:    {d}\n", .{counts.sampler});
    if (counts.bind_group > 0) std.debug.print("  Bind groups: {d}\n", .{counts.bind_group});
    if (counts.draw > 0) std.debug.print("  Draw calls:  {d}\n", .{counts.draw});
    if (counts.dispatch > 0) std.debug.print("  Dispatches:  {d}\n", .{counts.dispatch});
}

fn printExecutionSummary(calls: []const Call, module: *const format.Module) u8 {
    std.debug.print("\nExecution OK: {d} GPU calls\n", .{calls.len});

    const counts = countCallTypes(calls);
    printCallCounts(counts);

    const desc_errors = validateDescriptors(calls, module);
    if (desc_errors > 0) {
        std.debug.print("\nWarning: {d} invalid descriptor(s) detected\n", .{desc_errors});
        std.debug.print("  These may cause errors in the web runtime\n", .{});
        return 6;
    }

    reportEntryPoints(calls, module);
    reportBufferUsage(calls);

    const bind_group_warnings = validateBindGroupSetup(calls);
    if (bind_group_warnings > 0) {
        std.debug.print("\nWarning: {d} draw call(s) may have missing bind groups\n", .{bind_group_warnings});
        std.debug.print("  Ensure bindGroups=[...] is set in render passes\n", .{});
    }

    return 0;
}

fn reportEntryPoints(calls: []const Call, module: *const format.Module) void {
    var reported_any = false;

    for (calls) |call| {
        switch (call.call_type) {
            .create_render_pipeline => {
                const data_id = call.params.create_render_pipeline.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (findJsonString(data, "\"vertex\"") != null) {
                    if (!reported_any) {
                        std.debug.print("\nEntry points (verify these match shader functions):\n", .{});
                        reported_any = true;
                    }

                    if (findEntryPointForStage(data, "\"vertex\"")) |ep| {
                        const pid = call.params.create_render_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} vertex: {s}\n", .{ pid, ep });
                    }
                    if (findEntryPointForStage(data, "\"fragment\"")) |ep| {
                        const pid = call.params.create_render_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} fragment: {s}\n", .{ pid, ep });
                    }
                }
            },
            .create_compute_pipeline => {
                const data_id = call.params.create_compute_pipeline.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (findJsonString(data, "\"compute\"") != null) {
                    if (!reported_any) {
                        std.debug.print("\nEntry points (verify these match shader functions):\n", .{});
                        reported_any = true;
                    }

                    if (findEntryPointForStage(data, "\"compute\"")) |ep| {
                        const pid = call.params.create_compute_pipeline.pipeline_id;
                        std.debug.print("  Pipeline {d} compute: {s}\n", .{ pid, ep });
                    }
                }
            },
            else => {},
        }
    }
}

fn reportBufferUsage(calls: []const Call) void {
    var flags_buf: [128]u8 = undefined;
    var reported_any = false;

    for (calls) |call| {
        if (call.call_type == .create_buffer) {
            if (!reported_any) {
                std.debug.print("\nBuffer usage (verify these match shader bindings):\n", .{});
                reported_any = true;
            }

            const buffer_id = call.params.create_buffer.buffer_id;
            const size = call.params.create_buffer.size;
            const usage: pngine.opcodes.BufferUsage = @bitCast(call.params.create_buffer.usage);

            var flags_len: usize = 0;
            const flags_to_check = [_]struct { flag: bool, name: []const u8 }{
                .{ .flag = usage.uniform, .name = "UNIFORM" },
                .{ .flag = usage.storage, .name = "STORAGE" },
                .{ .flag = usage.vertex, .name = "VERTEX" },
                .{ .flag = usage.index, .name = "INDEX" },
                .{ .flag = usage.copy_src, .name = "COPY_SRC" },
                .{ .flag = usage.copy_dst, .name = "COPY_DST" },
                .{ .flag = usage.map_read, .name = "MAP_READ" },
                .{ .flag = usage.map_write, .name = "MAP_WRITE" },
            };

            for (flags_to_check) |f| {
                if (f.flag) {
                    if (flags_len > 0) {
                        flags_buf[flags_len] = '|';
                        flags_len += 1;
                    }
                    @memcpy(flags_buf[flags_len..][0..f.name.len], f.name);
                    flags_len += f.name.len;
                }
            }

            const flags_str = if (flags_len > 0) flags_buf[0..flags_len] else "(none)";
            std.debug.print("  Buffer {d}: size={d}, usage={s}\n", .{ buffer_id, size, flags_str });
        }
    }
}

fn findJsonString(data: []const u8, needle: []const u8) ?usize {
    return std.mem.indexOf(u8, data, needle);
}

fn findEntryPointForStage(data: []const u8, stage_pattern: []const u8) ?[]const u8 {
    const stage_start = std.mem.indexOf(u8, data, stage_pattern) orelse return null;
    const entry_pattern = "\"entryPoint\":\"";
    const ep_start = std.mem.indexOfPos(u8, data, stage_start, entry_pattern) orelse return null;
    const name_start = ep_start + entry_pattern.len;
    if (name_start >= data.len) return null;
    const name_end = std.mem.indexOfPos(u8, data, name_start, "\"") orelse return null;
    return data[name_start..name_end];
}

fn validateDescriptors(calls: []const Call, module: *const format.Module) u32 {
    var error_count: u32 = 0;

    for (calls) |call| {
        switch (call.call_type) {
            .create_texture => {
                const data_id = call.params.create_texture.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: texture descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.texture)) {
                    std.debug.print("  Error: texture descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                }
            },
            .create_sampler => {
                const data_id = call.params.create_sampler.descriptor_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: sampler descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.sampler)) {
                    std.debug.print("  Error: sampler descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                }
            },
            .create_bind_group => {
                const data_id = call.params.create_bind_group.entry_data_id;
                const data = module.data.get(@enumFromInt(data_id));

                if (data.len < 2) {
                    std.debug.print("  Error: bind group descriptor too short ({d} bytes)\n", .{data.len});
                    error_count += 1;
                    continue;
                }

                const type_tag = data[0];
                if (type_tag != @intFromEnum(DescriptorEncoder.DescriptorType.bind_group)) {
                    std.debug.print("  Error: bind group descriptor has invalid type tag 0x{X:0>2}\n", .{type_tag});
                    error_count += 1;
                    continue;
                }

                const field_count = data[1];
                if (field_count < 2) {
                    std.debug.print("  Error: bind group has invalid field count {d} (expected >= 2)\n", .{field_count});
                    error_count += 1;
                }
            },
            else => {},
        }
    }

    return error_count;
}

fn validateBindGroupSetup(calls: []const Call) u32 {
    var warning_count: u32 = 0;
    var in_render_pass = false;
    var pipeline_set = false;
    var bind_group_set = false;

    for (calls) |call| {
        switch (call.call_type) {
            .begin_render_pass => {
                in_render_pass = true;
                pipeline_set = false;
                bind_group_set = false;
            },
            .end_pass => in_render_pass = false,
            .set_pipeline => if (in_render_pass) {
                pipeline_set = true;
            },
            .set_bind_group => if (in_render_pass) {
                bind_group_set = true;
            },
            .draw, .draw_indexed => {
                if (in_render_pass and pipeline_set and !bind_group_set) {
                    warning_count += 1;
                    std.debug.print("  Warning: draw call without set_bind_group\n", .{});
                }
            },
            else => {},
        }
    }

    return warning_count;
}
