//! WASM execution and validation for validate command.
//!
//! Uses wasm3 to execute bytecode and capture command buffer output.

const std = @import("std");
const pngine = @import("pngine");
const format = pngine.format;
const build_options = @import("build_options");
const types = @import("types.zig");
const Options = types.Options;
const ValidationResult = types.ValidationResult;
const FrameResult = types.FrameResult;
const FrameDiff = types.FrameDiff;
const CommandInfo = types.CommandInfo;
const wasm3 = @import("wasm3.zig");
const Wasm3Runtime = wasm3.Wasm3Runtime;
const cmd_validator = @import("cmd_validator.zig");
const Validator = cmd_validator.Validator;
const symptom_diagnosis = @import("symptom_diagnosis.zig");

// Embedded WASM executor (from build)
const embedded_wasm = if (build_options.has_embedded_wasm)
    @embedFile("embedded_wasm")
else
    @as([]const u8, &.{});

/// Check if WASM execution is available.
pub fn isAvailable() bool {
    return Wasm3Runtime.isAvailable() and embedded_wasm.len > 0;
}

/// Validate bytecode structure and content.
pub fn validateBytecode(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    result: *ValidationResult,
    opts: *const Options,
) !void {
    // Pre-condition: bytecode has minimum header size
    if (bytecode.len < format.HEADER_SIZE_V4) {
        try result.errors.append(allocator, .{
            .code = "E001",
            .severity = .err,
            .message = "Bytecode too small - missing header",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Verify magic bytes
    if (!std.mem.eql(u8, bytecode[0..4], format.MAGIC)) {
        try result.errors.append(allocator, .{
            .code = "E002",
            .severity = .err,
            .message = "Invalid magic bytes - not a PNGB file",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Read version
    const version = std.mem.readInt(u16, bytecode[4..6], .little);

    // Validate version
    if (version != format.VERSION and version != format.VERSION_V4) {
        try result.errors.append(allocator, .{
            .code = "E003",
            .severity = .err,
            .message = "Unsupported PNGB version",
            .command_index = null,
        });
        result.status = .err;
        return;
    }

    // Deserialize the full module for analysis
    const module = format.deserialize(allocator, bytecode) catch |err| {
        try result.errors.append(allocator, .{
            .code = "E004",
            .severity = .err,
            .message = switch (err) {
                error.InvalidMagic => "Invalid magic bytes",
                error.InvalidFormat => "Invalid bytecode format",
                error.OutOfMemory => "Out of memory during parsing",
                else => "Failed to parse bytecode",
            },
            .command_index = null,
        });
        result.status = .err;
        return;
    };
    defer @constCast(&module).deinit(allocator);

    // Build module info for output
    result.module_info = .{
        .version = version,
        .has_executor = module.hasEmbeddedExecutor(),
        .executor_size = @intCast(module.executor.len),
        .bytecode_size = @intCast(module.bytecode.len),
        .strings_count = @intCast(module.strings.strings.items.len),
        .data_blobs_count = @intCast(module.data.blobs.items.len),
        .wgsl_entries_count = @intCast(module.wgsl.entries.items.len),
        .uniform_entries_count = @intCast(module.uniforms.bindings.items.len),
        .has_animation = module.animation.hasAnimation(),
        .scene_count = if (module.animation.info) |info| @intCast(info.scenes.len) else 0,
    };

    // Validation checks
    if (module.bytecode.len == 0) {
        try result.warnings.append(allocator, .{
            .code = "W001",
            .severity = .warning,
            .message = "Empty bytecode section",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }

    if (module.wgsl.entries.items.len == 0) {
        try result.warnings.append(allocator, .{
            .code = "W002",
            .severity = .warning,
            .message = "No WGSL shaders defined",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }

    // Execute WASM to capture command buffer
    if (isAvailable()) {
        executeWasm(allocator, bytecode, result, opts) catch |err| {
            try result.warnings.append(allocator, .{
                .code = "W100",
                .severity = .warning,
                .message = switch (err) {
                    error.InitFailed => "wasm3 init failed",
                    error.ParseFailed => "WASM parse failed",
                    error.LoadFailed => "WASM load failed",
                    error.CompileFailed => "WASM compile failed",
                    error.FunctionNotFound => "WASM function not found",
                    error.CallFailed => "WASM call failed",
                    error.MemoryAccessFailed => "WASM memory access failed",
                    else => "WASM execution failed",
                },
                .command_index = null,
            });
            if (result.status == .ok) result.status = .warning;
        };
    } else if (!opts.quiet and opts.verbose) {
        try result.warnings.append(allocator, .{
            .code = "W100",
            .severity = .warning,
            .message = if (!Wasm3Runtime.isAvailable())
                "wasm3 not available at compile time"
            else
                "no embedded WASM executor",
            .command_index = null,
        });
        if (result.status == .ok) result.status = .warning;
    }
}

/// Execute WASM to capture command buffer output.
///
/// Runs init phase once, then executes multiple frames based on opts.frame_indices.
/// Collects per-frame results and performs diff analysis for animation debugging.
///
/// Complexity: O(init_commands + sum(frame_commands))
///
/// Pre-condition: bytecode is valid PNGB format
/// Post-condition: result contains all frame data and validation issues
fn executeWasm(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    result: *ValidationResult,
    opts: *const Options,
) !void {
    // Pre-conditions
    std.debug.assert(bytecode.len >= format.HEADER_SIZE_V4);
    std.debug.assert(opts.frame_indices.len > 0);

    // Initialize wasm3 runtime with 1MB stack
    var runtime = try Wasm3Runtime.init(allocator, 1024 * 1024);
    defer runtime.deinit();

    // Load the embedded WASM executor
    try runtime.loadModule(embedded_wasm);

    // Link host functions (log is optional)
    runtime.linkLogFunction() catch {};

    // Get memory pointers
    const bytecode_ptr = try runtime.callGetPtr("getBytecodePtr");
    const data_ptr = try runtime.callGetPtr("getDataPtr");

    // Write bytecode to WASM memory
    try runtime.writeMemory(bytecode_ptr, bytecode);
    try runtime.callSetLen("setBytecodeLen", @intCast(bytecode.len));

    // Parse bytecode to get data section
    const module = try format.deserialize(allocator, bytecode);
    defer @constCast(&module).deinit(allocator);

    // Write data section to WASM memory
    const data_offset = module.header.data_section_offset;
    const data_end = if (module.header.wgsl_table_offset > 0)
        module.header.wgsl_table_offset
    else
        @as(u32, @intCast(bytecode.len));

    if (data_end > data_offset) {
        const data_section = bytecode[data_offset..data_end];
        try runtime.writeMemory(data_ptr, data_section);
        try runtime.callSetLen("setDataLen", @intCast(data_section.len));
    }

    // Initialize validator for state machine validation
    var validator = Validator.init(allocator);
    defer validator.deinit();

    // Get WASM memory size for bounds checking (E004)
    if (runtime.getMemory()) |mem| {
        validator.setWasmMemorySize(@intCast(mem.len));
    } else |_| {
        // Memory not available, bounds checking will be skipped
    }

    // Execute init phase (always, resources must be created first)
    if (opts.phase == .init or opts.phase == .both) {
        const init_result = try runtime.callInit();
        if (init_result != 0) {
            try result.errors.append(allocator, .{
                .code = "E010",
                .severity = .err,
                .message = "WASM init() returned error",
                .command_index = null,
            });
            result.status = .err;
            return;
        }

        // Read command buffer
        const cmd_ptr = try runtime.callGetPtr("getCommandPtr");
        const cmd_len = try runtime.callGetPtr("getCommandLen");

        if (cmd_len > 0) {
            const cmd_data = try runtime.readMemory(cmd_ptr, cmd_len);
            result.init_commands = try cmd_validator.parseCommands(allocator, cmd_data);
            try validator.validate(result.init_commands);
        }
    }

    // Execute frame phase for each requested frame
    if (opts.phase == .frame or opts.phase == .both) {
        // Bounded loop over frame indices (max 100 frames)
        const max_frames: u32 = @min(@as(u32, @intCast(opts.frame_indices.len)), 100);

        for (0..max_frames) |frame_loop_idx| {
            const frame_idx = opts.frame_indices[frame_loop_idx];
            const frame_time = opts.time + @as(f32, @floatFromInt(frame_idx)) * opts.time_step;

            const frame_wasm_result = try runtime.callFrame(frame_time, opts.width, opts.height);
            if (frame_wasm_result != 0) {
                try result.errors.append(allocator, .{
                    .code = "E011",
                    .severity = .err,
                    .message = "WASM frame() returned error",
                    .command_index = null,
                });
                result.status = .err;
                return;
            }

            // Read command buffer for this frame
            const cmd_ptr = try runtime.callGetPtr("getCommandPtr");
            const cmd_len = try runtime.callGetPtr("getCommandLen");

            if (cmd_len > 0) {
                const cmd_data = try runtime.readMemory(cmd_ptr, cmd_len);
                const frame_commands = try cmd_validator.parseCommands(allocator, cmd_data);

                // Create fresh validator for each frame (resources persist from init)
                var frame_validator = Validator.init(allocator);
                defer frame_validator.deinit();

                // Store frame result
                try result.frame_results.append(allocator, .{
                    .frame_index = frame_idx,
                    .time = frame_time,
                    .commands = frame_commands,
                    .draw_count = countDrawCalls(frame_commands),
                    .dispatch_count = countDispatchCalls(frame_commands),
                });

                // First frame becomes frame_commands for backwards compatibility
                if (frame_loop_idx == 0) {
                    result.frame_commands = frame_commands;
                    try validator.validate(frame_commands);
                }
            }
        }

        // Perform frame diff analysis if multiple frames
        if (result.frame_results.items.len > 1) {
            result.frame_diff = analyzeFrameDiff(result.frame_results.items);
        }
    }

    // Collect validation issues from main validator
    for (validator.issues.items) |issue| {
        if (issue.severity == .err) {
            try result.errors.append(allocator, .{
                .code = issue.code,
                .severity = .err,
                .message = issue.message,
                .command_index = issue.command_index,
            });
        } else {
            try result.warnings.append(allocator, .{
                .code = issue.code,
                .severity = .warning,
                .message = issue.message,
                .command_index = issue.command_index,
            });
        }
    }

    // Update status based on validation
    if (validator.hasErrors()) {
        result.status = .err;
    } else if (validator.warningCount() > 0 and result.status == .ok) {
        result.status = .warning;
    }

    // Store resource counts and statistics from first frame
    result.resource_counts = validator.getResourceCounts();
    result.draw_count = validator.draw_count;
    result.dispatch_count = validator.dispatch_count;

    // Run symptom-based diagnosis if symptom was specified
    if (opts.symptom != .none) {
        const symptom = switch (opts.symptom) {
            .black => symptom_diagnosis.Symptom.black,
            .colors => symptom_diagnosis.Symptom.colors,
            .blend => symptom_diagnosis.Symptom.blend,
            .flicker => symptom_diagnosis.Symptom.flicker,
            .geometry => symptom_diagnosis.Symptom.geometry,
            .none => symptom_diagnosis.Symptom.none,
        };
        result.diagnosis = symptom_diagnosis.diagnose(
            symptom,
            result.init_commands,
            result.frame_commands,
            &validator,
        );
    }

    // Post-condition: frame_results populated if frame phase was run
    if (opts.phase == .frame or opts.phase == .both) {
        std.debug.assert(result.frame_results.items.len > 0 or result.status == .err);
    }
}

/// Count DRAW and DRAW_INDEXED commands in a command list.
///
/// Complexity: O(n) where n = commands.len
///
/// Post-condition: Result <= commands.len
pub fn countDrawCalls(commands: []const CommandInfo) u32 {
    // Pre-condition: commands is bounded
    std.debug.assert(commands.len <= 10000);

    var count: u32 = 0;
    for (commands) |cmd| {
        if (cmd.cmd == .draw or cmd.cmd == .draw_indexed) {
            count += 1;
        }
    }

    // Post-condition: count cannot exceed input length
    std.debug.assert(count <= commands.len);
    return count;
}

/// Count DISPATCH commands in a command list.
///
/// Complexity: O(n) where n = commands.len
///
/// Post-condition: Result <= commands.len
pub fn countDispatchCalls(commands: []const CommandInfo) u32 {
    // Pre-condition: commands is bounded
    std.debug.assert(commands.len <= 10000);

    var count: u32 = 0;
    for (commands) |cmd| {
        if (cmd.cmd == .dispatch) {
            count += 1;
        }
    }

    // Post-condition: count cannot exceed input length
    std.debug.assert(count <= commands.len);
    return count;
}

/// Analyze differences between frames for animation debugging.
///
/// Complexity: O(n) where n = max(frames[0].commands.len, frames[last].commands.len)
///
/// Detects:
/// - Whether time values are changing (animation working)
/// - Whether draw counts are consistent
/// - Static vs varying command patterns
///
/// Pre-condition: frames.len >= 2
/// Post-condition: static_command_count + varying_command_count <= max commands in any frame
pub fn analyzeFrameDiff(frames: []const FrameResult) FrameDiff {
    // Pre-conditions
    std.debug.assert(frames.len >= 2);
    std.debug.assert(frames.len <= 100); // Bounded by max frames limit

    // Check if times are varying
    var time_is_varying = false;
    const first_time = frames[0].time;
    for (frames[1..]) |fr| {
        if (fr.time != first_time) {
            time_is_varying = true;
            break;
        }
    }

    // Check if draw counts are consistent
    var draw_counts_consistent = true;
    const first_draw_count = frames[0].draw_count;
    for (frames[1..]) |fr| {
        if (fr.draw_count != first_draw_count) {
            draw_counts_consistent = false;
            break;
        }
    }

    // Count static vs varying commands (compare first and last frame)
    var static_count: u32 = 0;
    var varying_count: u32 = 0;

    const first_cmds = frames[0].commands;
    const last_cmds = frames[frames.len - 1].commands;

    if (first_cmds.len == last_cmds.len) {
        for (first_cmds, last_cmds) |c1, c2| {
            if (c1.cmd == c2.cmd) {
                static_count += 1;
            } else {
                varying_count += 1;
            }
        }
    } else {
        // Different command counts means significant variation
        varying_count = @intCast(@max(first_cmds.len, last_cmds.len));
    }

    // Generate summary message
    const summary: []const u8 = if (!time_is_varying)
        "Time values identical across frames - animation may not be working"
    else if (!draw_counts_consistent)
        "Draw counts vary between frames - check for conditional rendering issues"
    else
        "Animation appears to be working correctly";

    const result: FrameDiff = .{
        .static_command_count = static_count,
        .varying_command_count = varying_count,
        .time_is_varying = time_is_varying,
        .draw_counts_consistent = draw_counts_consistent,
        .summary = summary,
    };

    // Post-condition: counts are bounded by max command count
    const max_cmds: u32 = @intCast(@max(first_cmds.len, last_cmds.len));
    std.debug.assert(result.static_command_count + result.varying_command_count <= max_cmds + 1);

    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "analyzeFrameDiff: detects time variation" {
    const frames = [_]FrameResult{
        .{ .frame_index = 0, .time = 0.0, .commands = &.{}, .draw_count = 1, .dispatch_count = 0 },
        .{ .frame_index = 1, .time = 0.016, .commands = &.{}, .draw_count = 1, .dispatch_count = 0 },
    };

    const diff = analyzeFrameDiff(&frames);

    try std.testing.expect(diff.time_is_varying);
    try std.testing.expect(diff.draw_counts_consistent);
}

test "analyzeFrameDiff: detects identical times (animation broken)" {
    const frames = [_]FrameResult{
        .{ .frame_index = 0, .time = 0.0, .commands = &.{}, .draw_count = 1, .dispatch_count = 0 },
        .{ .frame_index = 1, .time = 0.0, .commands = &.{}, .draw_count = 1, .dispatch_count = 0 },
    };

    const diff = analyzeFrameDiff(&frames);

    try std.testing.expect(!diff.time_is_varying);
    try std.testing.expectEqualStrings(
        "Time values identical across frames - animation may not be working",
        diff.summary,
    );
}

test "analyzeFrameDiff: detects inconsistent draw counts" {
    const frames = [_]FrameResult{
        .{ .frame_index = 0, .time = 0.0, .commands = &.{}, .draw_count = 1, .dispatch_count = 0 },
        .{ .frame_index = 1, .time = 0.016, .commands = &.{}, .draw_count = 0, .dispatch_count = 0 },
    };

    const diff = analyzeFrameDiff(&frames);

    try std.testing.expect(!diff.draw_counts_consistent);
}
