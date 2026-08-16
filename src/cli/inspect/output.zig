//! Output formatting for validate command.
//!
//! Handles JSON and human-readable output of validation results.

const std = @import("std");
const types = @import("types.zig");
const wgsl_reflect = @import("wgsl_reflect.zig");
const params = @import("cmd_validator/params.zig");
const utils = @import("../utils.zig");
const Options = types.Options;
const ValidationResult = types.ValidationResult;
const CommandInfo = types.CommandInfo;

/// JSON string escaper, shared with the cmd_validator serializers.
const writeJsonEscaped = params.writeJsonEscaped;

/// Write a quoted, JSON-escaped string (`"…"`). Every free-text field routes
/// through here so the emitted document is valid JSON regardless of content.
fn jsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonEscaped(writer, s);
    try writer.writeByte('"');
}

/// Output validation result as JSON to stdout (so `--json` is pipeable; human
/// diagnostics stay on stderr).
///
/// Thin wrapper: buffers `writeReportJson` into an allocating writer, then emits
/// the finished document in one go.
pub fn outputJson(io: std.Io, allocator: std.mem.Allocator, result: *const ValidationResult, opts: *const Options) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeReportJson(&aw.writer, result, opts);
    utils.writeStdout(io, aw.writer.buffered()) catch {};
}

/// Render the inspect validation report as JSON to `writer`.
///
/// Pure: writes only to `writer` (no globals), so it is unit-testable. All
/// free-text fields (messages, summaries, causes, WGSL source, input path) are
/// escaped via `jsonString`, guaranteeing valid JSON regardless of content.
pub fn writeReportJson(writer: *std.Io.Writer, result: *const ValidationResult, opts: *const Options) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"status\": \"{s}\",\n", .{@tagName(result.status)});
    try writer.writeAll("  \"input\": ");
    try jsonString(writer, opts.input_path);
    try writer.writeAll(",\n");

    if (result.module_info) |info| try writeModuleSection(writer, info);

    try writeIssueArray(writer, "errors", "error", result.errors.items);
    try writer.writeAll(",\n");
    try writeIssueArray(writer, "warnings", "warning", result.warnings.items);

    if (opts.verbose or opts.phase == .init or opts.phase == .both) {
        try writePhaseSection(writer, "initialization", "init", null, result.init_commands, result);
    }

    // Multiple frames replace the single-frame section rather than joining it,
    // so `first_frame` stays exactly what it was before multi-frame existed.
    if (result.frame_results.items.len > 1) {
        try writeFramesSection(writer, result);
    } else if (opts.verbose or opts.phase == .frame or opts.phase == .both) {
        try writePhaseSection(writer, "first_frame", "frame", opts, result.frame_commands, result);
    }

    if (result.diagnosis) |diag| try writeDiagnosisSection(writer, diag);
    if (result.likely_causes) |causes| try writeLikelyCausesSection(writer, causes);

    const wgsl_shaders = result.getWgslShaders();
    if (wgsl_shaders.len > 0) try writeWgslSection(writer, wgsl_shaders);

    try writer.writeAll("\n}\n");
}

/// `"module": { … }`, the PNGB header summary. Trailing comma included: every
/// section after it is unconditional or supplies its own leading separator.
fn writeModuleSection(writer: *std.Io.Writer, info: anytype) !void {
    try writer.writeAll("  \"module\": {\n");
    try writer.print("    \"version\": {d},\n", .{info.version});
    try writer.print("    \"has_executor\": {s},\n", .{if (info.has_executor) "true" else "false"});
    try writer.print("    \"executor_size\": {d},\n", .{info.executor_size});
    try writer.print("    \"bytecode_size\": {d},\n", .{info.bytecode_size});
    try writer.print("    \"strings_count\": {d},\n", .{info.strings_count});
    try writer.print("    \"data_blobs_count\": {d},\n", .{info.data_blobs_count});
    try writer.print("    \"wgsl_entries_count\": {d},\n", .{info.wgsl_entries_count});
    try writer.print("    \"uniform_entries_count\": {d},\n", .{info.uniform_entries_count});
    try writer.print("    \"has_animation\": {s},\n", .{if (info.has_animation) "true" else "false"});
    try writer.print("    \"scene_count\": {d}\n", .{info.scene_count});
    try writer.writeAll("  },\n");
}

/// `"errors"` and `"warnings"` — the same array shape with a different literal
/// severity, which is why they share one writer rather than two near-copies.
fn writeIssueArray(
    writer: *std.Io.Writer,
    key: []const u8,
    severity: []const u8,
    issues: anytype,
) !void {
    try writer.print("  \"{s}\": [", .{key});
    for (issues, 0..) |issue, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\"code\": ");
        try jsonString(writer, issue.code);
        try writer.print(", \"severity\": \"{s}\", \"message\": ", .{severity});
        try jsonString(writer, issue.message);
        if (issue.command_index) |idx| {
            try writer.print(", \"command_index\": {d}", .{idx});
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  ]");
}

/// `"initialization"` and `"first_frame"` — one command list plus its summary.
///
/// `opts` non-null adds the frame-only `time` and `canvas_size` keys; the init
/// section has neither.
fn writePhaseSection(
    writer: *std.Io.Writer,
    key: []const u8,
    phase: []const u8,
    opts: ?*const Options,
    commands: []const CommandInfo,
    result: *const ValidationResult,
) !void {
    try writer.print(",\n  \"{s}\": {{\n", .{key});
    try writer.print("    \"phase\": \"{s}\",\n", .{phase});
    if (opts) |o| {
        try writer.print("    \"time\": {d},\n", .{o.time});
        try writer.print("    \"canvas_size\": [{d}, {d}],\n", .{ o.width, o.height });
    }
    try writer.writeAll("    \"commands\": [");
    for (commands, 0..) |cmd_info, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("\n      {{\"index\": {d}, \"cmd\": \"{s}\"}}", .{ cmd_info.index, @tagName(cmd_info.cmd) });
    }
    if (commands.len > 0) try writer.writeAll("\n    ");
    try writer.writeAll("],\n");
    try writer.writeAll("    \"summary\": {\n");
    try writer.print("      \"total_commands\": {d},\n", .{commands.len});
    try writeCommandSummary(writer, commands, result);
    try writer.writeAll("    }\n");
    try writer.writeAll("  }");
}

/// `"frames"` plus the `"frame_diff"` that only exists alongside it.
fn writeFramesSection(writer: *std.Io.Writer, result: *const ValidationResult) !void {
    try writer.writeAll(",\n  \"frames\": [\n");
    for (result.frame_results.items, 0..) |fr, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("    {\n");
        try writer.print("      \"frame_index\": {d},\n", .{fr.frame_index});
        try writer.print("      \"time\": {d:.4},\n", .{fr.time});
        try writer.print("      \"command_count\": {d},\n", .{fr.commands.len});
        try writer.print("      \"draw_count\": {d},\n", .{fr.draw_count});
        try writer.print("      \"dispatch_count\": {d}\n", .{fr.dispatch_count});
        try writer.writeAll("    }");
    }
    try writer.writeAll("\n  ]");

    if (result.frame_diff) |diff| {
        try writer.writeAll(",\n  \"frame_diff\": {\n");
        try writer.print("    \"static_command_count\": {d},\n", .{diff.static_command_count});
        try writer.print("    \"varying_command_count\": {d},\n", .{diff.varying_command_count});
        try writer.print("    \"time_is_varying\": {s},\n", .{if (diff.time_is_varying) "true" else "false"});
        try writer.print("    \"draw_counts_consistent\": {s},\n", .{if (diff.draw_counts_consistent) "true" else "false"});
        try writer.writeAll("    \"summary\": ");
        try jsonString(writer, diff.summary);
        try writer.writeAll("\n  }");
    }
}

/// `"diagnosis"` — the `--symptom` report: ranked causes plus the checks run.
fn writeDiagnosisSection(writer: *std.Io.Writer, diag: anytype) !void {
    try writer.writeAll(",\n  \"diagnosis\": {\n");
    try writer.print("    \"symptom\": \"{s}\",\n", .{@tagName(diag.symptom)});
    try writer.writeAll("    \"summary\": ");
    try jsonString(writer, diag.summary);
    try writer.writeAll(",\n");

    try writer.writeAll("    \"likely_causes\": [");
    for (diag.likelyCauses(), 0..) |cause, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"probability\": ");
        try jsonString(writer, cause.probability);
        try writer.writeAll(",\n        \"cause\": ");
        try jsonString(writer, cause.cause);
        try writer.writeAll(",\n        \"evidence\": ");
        try jsonString(writer, cause.evidence);
        try writer.writeAll(",\n        \"fix\": ");
        try jsonString(writer, cause.fix);
        try writer.writeAll("\n      }");
    }
    if (diag.likelyCauses().len > 0) try writer.writeAll("\n    ");
    try writer.writeAll("],\n");

    try writer.writeAll("    \"checks\": [");
    for (diag.checks(), 0..) |check, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n      {\n");
        try writer.writeAll("        \"check\": ");
        try jsonString(writer, check.check_name);
        try writer.print(",\n        \"passed\": {s},\n", .{if (check.passed) "true" else "false"});
        try writer.print("        \"severity\": \"{s}\",\n", .{@tagName(check.severity)});
        try writer.writeAll("        \"message\": ");
        try jsonString(writer, check.message);
        if (check.suggestion.len > 0) {
            try writer.writeAll(",\n        \"suggestion\": ");
            try jsonString(writer, check.suggestion);
        }
        try writer.writeAll("\n      }");
    }
    if (diag.checks().len > 0) try writer.writeAll("\n    ");
    try writer.writeAll("]\n");
    try writer.writeAll("  }");
}

/// `"likely_causes"` — the state-machine analysis, emitted whenever it has
/// anything to say (no `--symptom` required).
fn writeLikelyCausesSection(writer: *std.Io.Writer, causes: anytype) !void {
    if (causes.count == 0) return;

    try writer.writeAll(",\n  \"likely_causes\": [");
    const sorted = causes.sortedByProbability();
    for (sorted[0..causes.count], 0..) |cause, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\"name\": ");
        try jsonString(writer, cause.name);
        try writer.print(", \"probability\": {d}, ", .{cause.probability});
        try writer.writeAll("\"description\": ");
        try jsonString(writer, cause.description);
        try writer.print(", \"category\": \"{s}\"", .{cause.category.toString()});
        if (cause.related_code) |code| {
            try writer.writeAll(", \"related_code\": ");
            try jsonString(writer, code);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  ");
    try writer.writeAll("]");
}

/// `"wgsl_shaders"` — reflected entry points and bindings, plus the source
/// itself under `--extract-wgsl`.
fn writeWgslSection(writer: *std.Io.Writer, shaders: anytype) !void {
    try writer.writeAll(",\n  \"wgsl_shaders\": [");
    for (shaders, 0..) |shader, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.print("      \"shader_id\": {d},\n", .{shader.shader_id});

        try writer.writeAll("      \"entry_points\": [");
        const entry_points = shader.getEntryPoints();
        for (entry_points, 0..) |ep, j| {
            if (j > 0) try writer.writeAll(",");
            try writer.writeAll("\n        {\"name\": ");
            try jsonString(writer, ep.name);
            try writer.print(", \"stage\": \"{s}\"", .{@tagName(ep.stage)});
            if (ep.stage == .compute and (ep.workgroup_size[0] > 0 or ep.workgroup_size[1] > 0 or ep.workgroup_size[2] > 0)) {
                try writer.print(", \"workgroup_size\": [{d}, {d}, {d}]", .{
                    ep.workgroup_size[0],
                    ep.workgroup_size[1],
                    ep.workgroup_size[2],
                });
            }
            try writer.writeAll("}");
        }
        if (entry_points.len > 0) try writer.writeAll("\n      ");
        try writer.writeAll("],\n");

        try writer.writeAll("      \"bindings\": [");
        const bindings = shader.getBindings();
        for (bindings, 0..) |binding, j| {
            if (j > 0) try writer.writeAll(",");
            try writer.print("\n        {{\"group\": {d}, \"binding\": {d}, \"address_space\": \"{s}\"", .{
                binding.group,
                binding.binding,
                @tagName(binding.address_space),
            });
            const type_name = binding.type_name;
            if (type_name.len > 0) {
                try writer.writeAll(", \"type\": ");
                try jsonString(writer, type_name);
            }
            try writer.writeAll("}");
        }
        if (bindings.len > 0) try writer.writeAll("\n      ");
        try writer.writeAll("]");

        if (shader.source) |src| {
            try writer.print(",\n      \"source_length\": {d}", .{src.len});
            // Long sources are summarised by length only, to keep the report
            // pipeable into a terminal.
            if (src.len <= 4096) {
                try writer.writeAll(",\n      \"source\": ");
                try jsonString(writer, src);
            }
        }
        try writer.writeAll("\n    }");
    }
    try writer.writeAll("\n  ]");
}

/// Render an error envelope as JSON to `writer` (escaped, valid-JSON guaranteed).
pub fn writeReportJsonError(writer: *std.Io.Writer, err_type: []const u8, message: []const u8) !void {
    try writer.writeAll("{\n  \"status\": \"error\",\n  \"errors\": [\n    {\"code\": \"E000\", \"type\": ");
    try jsonString(writer, err_type);
    try writer.writeAll(", \"message\": ");
    try jsonString(writer, message);
    try writer.writeAll("}\n  ]\n}\n");
}

/// Output an error envelope as JSON to stdout. Thin wrapper over `writeReportJsonError`.
pub fn outputJsonError(io: std.Io, allocator: std.mem.Allocator, err_type: []const u8, message: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeReportJsonError(&aw.writer, err_type, message);
    utils.writeStdout(io, aw.writer.buffered()) catch {};
}

/// Write command summary statistics (command counts by category) to `writer`.
fn writeCommandSummary(writer: *std.Io.Writer, commands: []const CommandInfo, result: *const ValidationResult) !void {
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

    try writer.print("      \"resources_created\": {d},\n", .{resource_count});
    try writer.print("      \"draw_calls\": {d},\n", .{draw_count});
    try writer.print("      \"compute_dispatches\": {d},\n", .{compute_count});
    try writer.print("      \"queue_operations\": {d}\n", .{queue_count});
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

// ============================================================================
// Tests
// ============================================================================
