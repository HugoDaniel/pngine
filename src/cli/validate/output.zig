//! Output formatting for validate command.
//!
//! Handles JSON and human-readable output of validation results.

const std = @import("std");
const types = @import("types.zig");
const Options = types.Options;
const ValidationResult = types.ValidationResult;
const CommandInfo = types.CommandInfo;

/// Output validation result as JSON.
pub fn outputJson(allocator: std.mem.Allocator, result: *const ValidationResult, opts: *const Options) !void {
    _ = allocator;

    std.debug.print("{{\n", .{});
    std.debug.print("  \"status\": \"{s}\",\n", .{@tagName(result.status)});
    std.debug.print("  \"input\": \"{s}\",\n", .{opts.input_path});

    // Module info (if available)
    if (result.module_info) |info| {
        std.debug.print("  \"module\": {{\n", .{});
        std.debug.print("    \"version\": {d},\n", .{info.version});
        std.debug.print("    \"has_executor\": {s},\n", .{if (info.has_executor) "true" else "false"});
        std.debug.print("    \"executor_size\": {d},\n", .{info.executor_size});
        std.debug.print("    \"bytecode_size\": {d},\n", .{info.bytecode_size});
        std.debug.print("    \"strings_count\": {d},\n", .{info.strings_count});
        std.debug.print("    \"data_blobs_count\": {d},\n", .{info.data_blobs_count});
        std.debug.print("    \"wgsl_entries_count\": {d},\n", .{info.wgsl_entries_count});
        std.debug.print("    \"uniform_entries_count\": {d},\n", .{info.uniform_entries_count});
        std.debug.print("    \"has_animation\": {s},\n", .{if (info.has_animation) "true" else "false"});
        std.debug.print("    \"scene_count\": {d}\n", .{info.scene_count});
        std.debug.print("  }},\n", .{});
    }

    // Errors
    std.debug.print("  \"errors\": [", .{});
    for (result.errors.items, 0..) |err, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("\n    {{\"code\": \"{s}\", \"severity\": \"error\", \"message\": \"{s}\"", .{ err.code, err.message });
        if (err.command_index) |idx| {
            std.debug.print(", \"command_index\": {d}", .{idx});
        }
        std.debug.print("}}", .{});
    }
    std.debug.print("\n  ],\n", .{});

    // Warnings
    std.debug.print("  \"warnings\": [", .{});
    for (result.warnings.items, 0..) |warn, i| {
        if (i > 0) std.debug.print(",", .{});
        std.debug.print("\n    {{\"code\": \"{s}\", \"severity\": \"warning\", \"message\": \"{s}\"", .{ warn.code, warn.message });
        if (warn.command_index) |idx| {
            std.debug.print(", \"command_index\": {d}", .{idx});
        }
        std.debug.print("}}", .{});
    }
    std.debug.print("\n  ]", .{});

    // Init commands (if verbose or phase includes init)
    if (opts.verbose or opts.phase == .init or opts.phase == .both) {
        std.debug.print(",\n  \"initialization\": {{\n", .{});
        std.debug.print("    \"phase\": \"init\",\n", .{});
        std.debug.print("    \"commands\": [", .{});
        for (result.init_commands, 0..) |cmd_info, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\"index\": {d}, \"cmd\": \"{s}\"}}", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
        if (result.init_commands.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("],\n", .{});
        std.debug.print("    \"summary\": {{\n", .{});
        std.debug.print("      \"total_commands\": {d},\n", .{result.init_commands.len});
        outputCommandSummary(result.init_commands, result);
        std.debug.print("    }}\n", .{});
        std.debug.print("  }}", .{});
    }

    // Multi-frame results (if multiple frames requested)
    if (result.frame_results.items.len > 1) {
        std.debug.print(",\n  \"frames\": [\n", .{});
        for (result.frame_results.items, 0..) |fr, i| {
            if (i > 0) std.debug.print(",\n", .{});
            std.debug.print("    {{\n", .{});
            std.debug.print("      \"frame_index\": {d},\n", .{fr.frame_index});
            std.debug.print("      \"time\": {d:.4},\n", .{fr.time});
            std.debug.print("      \"command_count\": {d},\n", .{fr.commands.len});
            std.debug.print("      \"draw_count\": {d},\n", .{fr.draw_count});
            std.debug.print("      \"dispatch_count\": {d}\n", .{fr.dispatch_count});
            std.debug.print("    }}", .{});
        }
        std.debug.print("\n  ]", .{});

        // Frame diff analysis
        if (result.frame_diff) |diff| {
            std.debug.print(",\n  \"frame_diff\": {{\n", .{});
            std.debug.print("    \"static_command_count\": {d},\n", .{diff.static_command_count});
            std.debug.print("    \"varying_command_count\": {d},\n", .{diff.varying_command_count});
            std.debug.print("    \"time_is_varying\": {s},\n", .{if (diff.time_is_varying) "true" else "false"});
            std.debug.print("    \"draw_counts_consistent\": {s},\n", .{if (diff.draw_counts_consistent) "true" else "false"});
            std.debug.print("    \"summary\": \"{s}\"\n", .{diff.summary});
            std.debug.print("  }}", .{});
        }
    } else if (opts.verbose or opts.phase == .frame or opts.phase == .both) {
        // Single frame (backwards compatible output)
        std.debug.print(",\n  \"first_frame\": {{\n", .{});
        std.debug.print("    \"phase\": \"frame\",\n", .{});
        std.debug.print("    \"time\": {d},\n", .{opts.time});
        std.debug.print("    \"canvas_size\": [{d}, {d}],\n", .{ opts.width, opts.height });
        std.debug.print("    \"commands\": [", .{});
        for (result.frame_commands, 0..) |cmd_info, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\"index\": {d}, \"cmd\": \"{s}\"}}", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
        if (result.frame_commands.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("],\n", .{});
        std.debug.print("    \"summary\": {{\n", .{});
        std.debug.print("      \"total_commands\": {d},\n", .{result.frame_commands.len});
        outputCommandSummary(result.frame_commands, result);
        std.debug.print("    }}\n", .{});
        std.debug.print("  }}", .{});
    }

    // Symptom-based diagnosis (if requested)
    if (result.diagnosis) |diag| {
        std.debug.print(",\n  \"diagnosis\": {{\n", .{});
        std.debug.print("    \"symptom\": \"{s}\",\n", .{@tagName(diag.symptom)});
        std.debug.print("    \"summary\": \"{s}\",\n", .{diag.summary});

        // Likely causes
        std.debug.print("    \"likely_causes\": [", .{});
        for (diag.likely_causes, 0..) |cause, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\n", .{});
            std.debug.print("        \"probability\": \"{s}\",\n", .{cause.probability});
            std.debug.print("        \"cause\": \"{s}\",\n", .{cause.cause});
            std.debug.print("        \"evidence\": \"{s}\",\n", .{cause.evidence});
            std.debug.print("        \"fix\": \"{s}\"\n", .{cause.fix});
            std.debug.print("      }}", .{});
        }
        if (diag.likely_causes.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("],\n", .{});

        // Diagnostic checks
        std.debug.print("    \"checks\": [", .{});
        for (diag.checks, 0..) |check, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("\n      {{\n", .{});
            std.debug.print("        \"check\": \"{s}\",\n", .{check.check_name});
            std.debug.print("        \"passed\": {s},\n", .{if (check.passed) "true" else "false"});
            std.debug.print("        \"severity\": \"{s}\",\n", .{@tagName(check.severity)});
            std.debug.print("        \"message\": \"{s}\"", .{check.message});
            if (check.suggestion.len > 0) {
                std.debug.print(",\n        \"suggestion\": \"{s}\"", .{check.suggestion});
            }
            std.debug.print("\n      }}", .{});
        }
        if (diag.checks.len > 0) std.debug.print("\n    ", .{});
        std.debug.print("]\n", .{});
        std.debug.print("  }}", .{});
    }

    std.debug.print("\n}}\n", .{});
}

pub fn outputJsonError(allocator: std.mem.Allocator, err_type: []const u8, message: []const u8) !void {
    _ = allocator;
    std.debug.print(
        \\{{
        \\  "status": "error",
        \\  "errors": [
        \\    {{"code": "E000", "type": "{s}", "message": "{s}"}}
        \\  ]
        \\}}
        \\
    , .{ err_type, message });
}

/// Output command summary statistics (command counts by category).
fn outputCommandSummary(commands: []const CommandInfo, result: *const ValidationResult) void {
    var resource_count: u32 = 0;
    var pass_count: u32 = 0;
    var queue_count: u32 = 0;
    var draw_count: u32 = 0;
    var compute_count: u32 = 0;

    for (commands) |cmd_info| {
        const tag: u8 = @intFromEnum(cmd_info.cmd);
        if (tag >= 0x01 and tag <= 0x0F) {
            resource_count += 1;
        } else if (tag >= 0x10 and tag <= 0x1F) {
            pass_count += 1;
            if (cmd_info.cmd == .draw or cmd_info.cmd == .draw_indexed) {
                draw_count += 1;
            } else if (cmd_info.cmd == .dispatch) {
                compute_count += 1;
            }
        } else if (tag >= 0x20 and tag <= 0x2F) {
            queue_count += 1;
        }
    }

    // Use validated counts if available
    if (result.draw_count > 0) draw_count = result.draw_count;
    if (result.dispatch_count > 0) compute_count = result.dispatch_count;

    std.debug.print("      \"resources_created\": {d},\n", .{resource_count});
    std.debug.print("      \"draw_calls\": {d},\n", .{draw_count});
    std.debug.print("      \"compute_dispatches\": {d},\n", .{compute_count});
    std.debug.print("      \"queue_operations\": {d}\n", .{queue_count});
}

/// Output validation result as human-readable text.
pub fn outputHuman(result: *const ValidationResult, opts: *const Options) !void {
    // Header
    std.debug.print("Validating: {s}\n", .{opts.input_path});
    std.debug.print("Canvas size: {d}x{d}, Time: {d:.2}s\n\n", .{ opts.width, opts.height, opts.time });

    // Module info
    if (result.module_info) |info| {
        std.debug.print("Module Info:\n", .{});
        std.debug.print("  Format version: v{d}\n", .{info.version});
        std.debug.print("  Bytecode size: {d} bytes\n", .{info.bytecode_size});
        std.debug.print("  WGSL entries: {d}\n", .{info.wgsl_entries_count});
        std.debug.print("  Data blobs: {d}\n", .{info.data_blobs_count});
        std.debug.print("  Strings: {d}\n", .{info.strings_count});
        std.debug.print("  Uniforms: {d}\n", .{info.uniform_entries_count});
        if (info.has_executor) {
            std.debug.print("  Embedded executor: {d} bytes\n", .{info.executor_size});
        }
        if (info.has_animation) {
            std.debug.print("  Animation scenes: {d}\n", .{info.scene_count});
        }
        std.debug.print("\n", .{});
    }

    // Init commands (if verbose or phase includes init)
    if ((opts.verbose or opts.phase == .init or opts.phase == .both) and result.init_commands.len > 0) {
        std.debug.print("Initialization ({d} commands):\n", .{result.init_commands.len});
        outputHumanCommandList(result.init_commands, opts.verbose, result);
        std.debug.print("\n", .{});
    }

    // Frame commands (if verbose or phase includes frame)
    if ((opts.verbose or opts.phase == .frame or opts.phase == .both) and result.frame_commands.len > 0) {
        std.debug.print("Frame ({d} commands):\n", .{result.frame_commands.len});
        outputHumanCommandList(result.frame_commands, opts.verbose, result);
        std.debug.print("\n", .{});
    }

    // Errors
    if (result.errors.items.len > 0) {
        std.debug.print("Errors:\n", .{});
        for (result.errors.items) |err| {
            std.debug.print("  [{s}] {s}\n", .{ err.code, err.message });
        }
        std.debug.print("\n", .{});
    }

    // Warnings
    if (result.warnings.items.len > 0) {
        std.debug.print("Warnings:\n", .{});
        for (result.warnings.items) |warn| {
            std.debug.print("  [{s}] {s}\n", .{ warn.code, warn.message });
        }
        std.debug.print("\n", .{});
    }

    // Status
    const status_symbol: []const u8 = switch (result.status) {
        .ok => "OK",
        .warning => "WARNING",
        .err => "ERROR",
    };
    std.debug.print("Status: {s}\n", .{status_symbol});
}

/// Output human-readable command list.
fn outputHumanCommandList(commands: []const CommandInfo, verbose: bool, result: *const ValidationResult) void {
    // Count commands by category
    var resource_count: u32 = 0;
    var draw_count: u32 = 0;
    var compute_count: u32 = 0;

    for (commands) |cmd_info| {
        const tag: u8 = @intFromEnum(cmd_info.cmd);
        if (tag >= 0x01 and tag <= 0x0F) {
            resource_count += 1;
        } else if (cmd_info.cmd == .draw or cmd_info.cmd == .draw_indexed) {
            draw_count += 1;
        } else if (cmd_info.cmd == .dispatch) {
            compute_count += 1;
        }
    }

    // Use validated counts if available
    if (result.draw_count > 0) draw_count = result.draw_count;
    if (result.dispatch_count > 0) compute_count = result.dispatch_count;

    std.debug.print("  Resources: {d}, Draws: {d}, Computes: {d}\n", .{ resource_count, draw_count, compute_count });

    // If verbose, list all commands
    if (verbose) {
        for (commands) |cmd_info| {
            std.debug.print("  [{d:3}] {s}\n", .{ cmd_info.index, @tagName(cmd_info.cmd) });
        }
    }
}
