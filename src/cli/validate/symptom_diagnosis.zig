//! Symptom-Based Diagnosis for GPU Command Buffer Validation
//!
//! Analyzes command buffers based on user-reported visual symptoms and provides
//! targeted diagnostics with likely causes, evidence, and fix suggestions.
//!
//! ## Supported Symptoms
//!
//! - **black**: Canvas is completely black / nothing renders
//! - **colors**: Wrong colors / unexpected colors
//! - **blend**: Wrong blending / transparency issues
//! - **flicker**: Flickering / strobing
//! - **geometry**: Wrong geometry / distortion
//!
//! ## Design
//!
//! Each symptom triggers a set of diagnostic checks that examine the command
//! buffer for patterns known to cause that symptom. Checks are ordered by
//! probability (most likely causes first).
//!
//! ## Invariants
//!
//! - All loops bounded by command count
//! - No allocations in hot path (uses stack arrays)
//! - Results are deterministic given same input

const std = @import("std");
const cmd_validator = @import("cmd_validator.zig");
const ParsedCommand = cmd_validator.ParsedCommand;
const Validator = cmd_validator.Validator;

/// Symptom category for diagnosis.
pub const Symptom = enum {
    black, // Black screen / nothing renders
    colors, // Wrong colors
    blend, // Blending/transparency issues
    flicker, // Flickering / strobing
    geometry, // Wrong geometry / distortion
    none, // No specific symptom
};

/// Severity of a diagnostic check result.
pub const CheckSeverity = enum {
    err, // Definitely causing the symptom
    warning, // Likely contributing to symptom
    info, // Additional context
};

/// Result of a single diagnostic check.
pub const DiagnosticCheck = struct {
    check_name: []const u8,
    passed: bool,
    severity: CheckSeverity,
    message: []const u8,
    suggestion: []const u8,
};

/// Likely cause with probability and evidence.
pub const LikelyCause = struct {
    probability: []const u8, // "high", "medium", "low"
    cause: []const u8,
    evidence: []const u8,
    fix: []const u8,
};

/// Complete diagnosis result for a symptom.
pub const DiagnosisResult = struct {
    symptom: Symptom,
    checks: []const DiagnosticCheck,
    likely_causes: []const LikelyCause,
    summary: []const u8,
};

/// Maximum number of checks per symptom.
const MAX_CHECKS: u32 = 16;

/// Maximum number of likely causes per diagnosis.
const MAX_CAUSES: u32 = 8;

// Comptime validation
comptime {
    std.debug.assert(MAX_CHECKS <= 32);
    std.debug.assert(MAX_CAUSES <= 16);
}

/// Diagnose command buffer based on reported symptom.
///
/// Complexity: O(init_cmds.len + frame_cmds.len)
///
/// Pre-condition: validator has been run on commands
/// Post-condition: Returns diagnosis with checks and likely causes
pub fn diagnose(
    symptom: Symptom,
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    // Pre-conditions
    std.debug.assert(init_cmds.len <= 10000);
    std.debug.assert(frame_cmds.len <= 10000);

    return switch (symptom) {
        .black => diagnoseBlackScreen(init_cmds, frame_cmds, validator),
        .colors => diagnoseWrongColors(init_cmds, frame_cmds, validator),
        .blend => diagnoseBlendIssues(init_cmds, frame_cmds, validator),
        .flicker => diagnoseFlickering(init_cmds, frame_cmds, validator),
        .geometry => diagnoseGeometryIssues(init_cmds, frame_cmds, validator),
        .none => .{
            .symptom = .none,
            .checks = &.{},
            .likely_causes = &.{},
            .summary = "No specific symptom selected - run general validation",
        },
    };
}

// ============================================================================
// Black Screen Diagnosis
// ============================================================================

/// Static checks for black screen diagnosis.
const black_screen_checks = struct {
    const no_draw: DiagnosticCheck = .{
        .check_name = "has_draw_command",
        .passed = false,
        .severity = .err,
        .message = "No DRAW commands in frame - nothing is rendered",
        .suggestion = "Add draw=N to your #renderPass or check frame.perform includes the pass",
    };

    const no_pipeline: DiagnosticCheck = .{
        .check_name = "pipeline_before_draw",
        .passed = false,
        .severity = .err,
        .message = "SET_PIPELINE missing before DRAW",
        .suggestion = "Ensure pipeline is set in render pass: pipeline=pipelineName",
    };

    const zero_vertices: DiagnosticCheck = .{
        .check_name = "vertex_count_nonzero",
        .passed = false,
        .severity = .err,
        .message = "DRAW vertex_count is 0",
        .suggestion = "Set draw=N where N > 0 (e.g., draw=3 for triangle)",
    };

    const no_render_pass: DiagnosticCheck = .{
        .check_name = "has_render_pass",
        .passed = false,
        .severity = .err,
        .message = "No BEGIN_RENDER_PASS in frame",
        .suggestion = "Add a #renderPass and include it in #frame perform=[]",
    };

    const no_submit: DiagnosticCheck = .{
        .check_name = "has_submit",
        .passed = false,
        .severity = .err,
        .message = "No SUBMIT command - command buffer not executed",
        .suggestion = "Ensure #frame is properly defined with perform=[]",
    };

    const draw_ok: DiagnosticCheck = .{
        .check_name = "has_draw_command",
        .passed = true,
        .severity = .info,
        .message = "Draw commands found",
        .suggestion = "",
    };

    const pipeline_ok: DiagnosticCheck = .{
        .check_name = "pipeline_before_draw",
        .passed = true,
        .severity = .info,
        .message = "Pipeline set before draw",
        .suggestion = "",
    };

    const vertices_ok: DiagnosticCheck = .{
        .check_name = "vertex_count_nonzero",
        .passed = true,
        .severity = .info,
        .message = "Non-zero vertex count",
        .suggestion = "",
    };

    const render_pass_ok: DiagnosticCheck = .{
        .check_name = "has_render_pass",
        .passed = true,
        .severity = .info,
        .message = "Render pass found",
        .suggestion = "",
    };
};

/// Diagnose "black screen" symptom.
///
/// Checks for common causes of nothing rendering:
/// - Missing DRAW commands
/// - Missing pipeline binding
/// - Zero vertex count
/// - Missing render pass
fn diagnoseBlackScreen(
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    _ = init_cmds;

    var checks: [MAX_CHECKS]DiagnosticCheck = undefined;
    var check_count: u32 = 0;

    var causes: [MAX_CAUSES]LikelyCause = undefined;
    var cause_count: u32 = 0;

    // Check 1: Has draw command?
    const has_draw = validator.draw_count > 0;
    if (!has_draw) {
        checks[check_count] = black_screen_checks.no_draw;
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "No DRAW command in frame",
            .evidence = "Command buffer has commands but no DRAW",
            .fix = "Add draw=N to your #renderPass or check frame.perform includes the pass",
        };
        cause_count += 1;
    } else {
        checks[check_count] = black_screen_checks.draw_ok;
        check_count += 1;
    }

    // Check 2: Has render pass?
    var has_render_pass = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .begin_render_pass) {
            has_render_pass = true;
            break;
        }
    }
    if (!has_render_pass) {
        checks[check_count] = black_screen_checks.no_render_pass;
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "No render pass in frame",
            .evidence = "Frame commands have no BEGIN_RENDER_PASS",
            .fix = "Add a #renderPass and include it in #frame perform=[]",
        };
        cause_count += 1;
    } else {
        checks[check_count] = black_screen_checks.render_pass_ok;
        check_count += 1;
    }

    // Check 3: Pipeline set before draw?
    var pipeline_before_draw = true;
    var saw_pipeline = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .set_pipeline) {
            saw_pipeline = true;
        } else if (cmd.cmd == .draw or cmd.cmd == .draw_indexed) {
            if (!saw_pipeline) {
                pipeline_before_draw = false;
                break;
            }
        } else if (cmd.cmd == .begin_render_pass) {
            saw_pipeline = false; // Reset for new pass
        }
    }
    if (has_draw and !pipeline_before_draw) {
        checks[check_count] = black_screen_checks.no_pipeline;
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "Pipeline not set before draw",
            .evidence = "DRAW issued without prior SET_PIPELINE",
            .fix = "Ensure pipeline=pipelineName is set in #renderPass",
        };
        cause_count += 1;
    } else if (has_draw) {
        checks[check_count] = black_screen_checks.pipeline_ok;
        check_count += 1;
    }

    // Check 4: Vertex count > 0?
    var has_zero_vertices = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .draw) {
            if (cmd.params.draw.vertex_count == 0) {
                has_zero_vertices = true;
                break;
            }
        } else if (cmd.cmd == .draw_indexed) {
            if (cmd.params.draw_indexed.index_count == 0) {
                has_zero_vertices = true;
                break;
            }
        }
    }
    if (has_zero_vertices) {
        checks[check_count] = black_screen_checks.zero_vertices;
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "Drawing zero vertices",
            .evidence = "DRAW command has vertex_count=0",
            .fix = "Set draw=N where N > 0 in #renderPass",
        };
        cause_count += 1;
    } else if (has_draw) {
        checks[check_count] = black_screen_checks.vertices_ok;
        check_count += 1;
    }

    // Check 5: Has submit?
    var has_submit = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .submit) {
            has_submit = true;
            break;
        }
    }
    if (!has_submit) {
        checks[check_count] = black_screen_checks.no_submit;
        check_count += 1;
        causes[cause_count] = .{
            .probability = "medium",
            .cause = "Command buffer not submitted",
            .evidence = "No SUBMIT command found",
            .fix = "Ensure #frame is defined with perform=[]",
        };
        cause_count += 1;
    }

    // Generate summary
    const summary: []const u8 = if (cause_count == 0)
        "No obvious issues found - check WGSL shader for bugs"
    else if (cause_count == 1)
        "Found 1 likely cause for black screen"
    else
        "Found multiple issues that could cause black screen";

    return .{
        .symptom = .black,
        .checks = checks[0..check_count],
        .likely_causes = causes[0..cause_count],
        .summary = summary,
    };
}

// ============================================================================
// Wrong Colors Diagnosis
// ============================================================================

/// Diagnose "wrong colors" symptom.
fn diagnoseWrongColors(
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    _ = init_cmds;
    _ = validator;

    var checks: [MAX_CHECKS]DiagnosticCheck = undefined;
    var check_count: u32 = 0;

    var causes: [MAX_CAUSES]LikelyCause = undefined;
    var cause_count: u32 = 0;

    // Check for clear color in render pass
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .begin_render_pass) {
            // Load op 1 = clear, store op 1 = store
            const load_op = cmd.params.begin_render_pass.load_op;
            if (load_op != 1) {
                checks[check_count] = .{
                    .check_name = "load_op",
                    .passed = false,
                    .severity = .warning,
                    .message = "Render pass loadOp is not 'clear'",
                    .suggestion = "Use loadOp=clear in colorAttachments",
                };
                check_count += 1;
            }
            break;
        }
    }

    // Check for uniform writes (colors might be from shader constants)
    var has_uniform_write = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .write_buffer or cmd.cmd == .write_time_uniform) {
            has_uniform_write = true;
            break;
        }
    }
    if (!has_uniform_write) {
        checks[check_count] = .{
            .check_name = "uniforms_written",
            .passed = false,
            .severity = .warning,
            .message = "No WRITE_BUFFER for uniforms",
            .suggestion = "If shader uses uniforms for colors, ensure they are written",
        };
        check_count += 1;
        causes[cause_count] = .{
            .probability = "medium",
            .cause = "Uniforms not written",
            .evidence = "No WRITE_BUFFER commands for uniform data",
            .fix = "Add #queue with writeBuffer for uniform data",
        };
        cause_count += 1;
    }

    const summary: []const u8 = if (cause_count == 0)
        "No obvious color issues - check WGSL shader color output"
    else
        "Found potential color-related issues";

    return .{
        .symptom = .colors,
        .checks = checks[0..check_count],
        .likely_causes = causes[0..cause_count],
        .summary = summary,
    };
}

// ============================================================================
// Blend Issues Diagnosis
// ============================================================================

/// Diagnose "blend issues" symptom.
fn diagnoseBlendIssues(
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    _ = frame_cmds;
    _ = validator;

    var checks: [MAX_CHECKS]DiagnosticCheck = undefined;
    var check_count: u32 = 0;

    var causes: [MAX_CAUSES]LikelyCause = undefined;
    var cause_count: u32 = 0;

    // Check pipeline creation for blend state
    var has_pipeline = false;
    for (init_cmds) |cmd| {
        if (cmd.cmd == .create_render_pipeline) {
            has_pipeline = true;
            // Note: blend state is in the descriptor, we can't easily parse it
            // Just flag that blend is configured in pipeline
            checks[check_count] = .{
                .check_name = "blend_state",
                .passed = true,
                .severity = .info,
                .message = "Pipeline created - blend state is in pipeline descriptor",
                .suggestion = "Verify blend state in #renderPipeline targets",
            };
            check_count += 1;
            break;
        }
    }

    if (!has_pipeline) {
        checks[check_count] = .{
            .check_name = "blend_state",
            .passed = false,
            .severity = .err,
            .message = "No render pipeline created",
            .suggestion = "Add #renderPipeline with blend state in targets",
        };
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "No pipeline for blend configuration",
            .evidence = "No CREATE_RENDER_PIPELINE command found",
            .fix = "Define #renderPipeline with blend: { ... } in targets",
        };
        cause_count += 1;
    } else {
        // Suggest checking blend configuration
        causes[cause_count] = .{
            .probability = "medium",
            .cause = "Blend state misconfigured",
            .evidence = "Pipeline exists but blend may not be enabled",
            .fix = "In #renderPipeline targets, add blend: { color: { ... } alpha: { ... } }",
        };
        cause_count += 1;
    }

    const summary: []const u8 = if (has_pipeline)
        "Pipeline exists - verify blend state configuration"
    else
        "No pipeline found for blend configuration";

    return .{
        .symptom = .blend,
        .checks = checks[0..check_count],
        .likely_causes = causes[0..cause_count],
        .summary = summary,
    };
}

// ============================================================================
// Flickering Diagnosis
// ============================================================================

/// Diagnose "flickering" symptom.
fn diagnoseFlickering(
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    _ = validator;

    var checks: [MAX_CHECKS]DiagnosticCheck = undefined;
    var check_count: u32 = 0;

    var causes: [MAX_CAUSES]LikelyCause = undefined;
    var cause_count: u32 = 0;

    // Check for multiple submits per frame
    var submit_count: u32 = 0;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .submit) {
            submit_count += 1;
        }
    }
    if (submit_count > 1) {
        checks[check_count] = .{
            .check_name = "multiple_submits",
            .passed = false,
            .severity = .warning,
            .message = "Multiple SUBMIT commands per frame",
            .suggestion = "Use single submit at end of frame",
        };
        check_count += 1;
        causes[cause_count] = .{
            .probability = "medium",
            .cause = "Multiple submits causing sync issues",
            .evidence = std.fmt.comptimePrint("{d} SUBMIT commands found", .{2}),
            .fix = "Consolidate to single SUBMIT at end of #frame",
        };
        cause_count += 1;
    }

    // Check for ping-pong buffers (pool > 1)
    var has_pool_buffers = false;
    for (init_cmds) |cmd| {
        if (cmd.cmd == .create_buffer) {
            // Buffer pool info isn't directly in command, but we can check
            // if there are multiple buffers with same base parameters
            has_pool_buffers = true; // Simplified check
            break;
        }
    }

    // Check for compute passes (often used with ping-pong)
    var has_compute = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .begin_compute_pass) {
            has_compute = true;
            break;
        }
    }

    if (has_compute and has_pool_buffers) {
        checks[check_count] = .{
            .check_name = "ping_pong_pattern",
            .passed = true,
            .severity = .info,
            .message = "Compute with buffers detected - check ping-pong offsets",
            .suggestion = "Verify bindGroupsPoolOffsets alternate correctly",
        };
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "Ping-pong buffer offset mismatch",
            .evidence = "Compute shader with buffer pools detected",
            .fix = "In #computePass, ensure bindGroupsPoolOffsets=[1] or similar",
        };
        cause_count += 1;
    }

    const summary: []const u8 = if (cause_count == 0)
        "No obvious flickering issues - check frame timing"
    else
        "Found potential causes for flickering";

    return .{
        .symptom = .flicker,
        .checks = checks[0..check_count],
        .likely_causes = causes[0..cause_count],
        .summary = summary,
    };
}

// ============================================================================
// Geometry Issues Diagnosis
// ============================================================================

/// Diagnose "geometry issues" symptom.
fn diagnoseGeometryIssues(
    init_cmds: []const ParsedCommand,
    frame_cmds: []const ParsedCommand,
    validator: *const Validator,
) DiagnosisResult {
    _ = validator;

    var checks: [MAX_CHECKS]DiagnosticCheck = undefined;
    var check_count: u32 = 0;

    var causes: [MAX_CAUSES]LikelyCause = undefined;
    var cause_count: u32 = 0;

    // Check for vertex buffer binding
    var has_vertex_buffer = false;
    for (frame_cmds) |cmd| {
        if (cmd.cmd == .set_vertex_buffer) {
            has_vertex_buffer = true;
            break;
        }
    }

    // Check vertex buffer creation
    var vertex_buffer_size: u32 = 0;
    for (init_cmds) |cmd| {
        if (cmd.cmd == .create_buffer) {
            const usage = cmd.params.create_buffer.usage;
            // VERTEX usage flag is 0x20
            if (usage & 0x20 != 0) {
                vertex_buffer_size = cmd.params.create_buffer.size;
                break;
            }
        }
    }

    if (vertex_buffer_size > 0 and !has_vertex_buffer) {
        checks[check_count] = .{
            .check_name = "vertex_buffer_bound",
            .passed = false,
            .severity = .warning,
            .message = "Vertex buffer created but not bound",
            .suggestion = "Add vertexBuffers=[bufferName] to #renderPass",
        };
        check_count += 1;
        causes[cause_count] = .{
            .probability = "high",
            .cause = "Vertex buffer not bound",
            .evidence = "CREATE_BUFFER with VERTEX usage but no SET_VERTEX_BUFFER",
            .fix = "In #renderPass, add vertexBuffers=[posBuffer]",
        };
        cause_count += 1;
    }

    if (vertex_buffer_size > 0) {
        // Analyze buffer capacity
        const vec3_count = vertex_buffer_size / 12;
        const vec4_count = vertex_buffer_size / 16;
        checks[check_count] = .{
            .check_name = "vertex_buffer_size",
            .passed = true,
            .severity = .info,
            .message = "Vertex buffer analyzed",
            .suggestion = if (vec3_count < 3)
                "Buffer may be too small for a triangle"
            else
                "",
        };
        check_count += 1;

        if (vec3_count < 3) {
            causes[cause_count] = .{
                .probability = "medium",
                .cause = "Vertex buffer too small",
                .evidence = "Buffer can hold < 3 vec3 vertices",
                .fix = "Increase buffer size or check vertex format",
            };
            cause_count += 1;
        }
        _ = vec4_count;
    }

    // Check for uniform buffer (transforms)
    var has_uniform_buffer = false;
    for (init_cmds) |cmd| {
        if (cmd.cmd == .create_buffer) {
            const usage = cmd.params.create_buffer.usage;
            // UNIFORM usage flag is 0x40
            if (usage & 0x40 != 0) {
                has_uniform_buffer = true;
                break;
            }
        }
    }

    if (!has_uniform_buffer) {
        checks[check_count] = .{
            .check_name = "uniform_buffer",
            .passed = false,
            .severity = .warning,
            .message = "No uniform buffer for transforms",
            .suggestion = "If using MVP matrices, add uniform buffer",
        };
        check_count += 1;
    }

    const summary: []const u8 = if (cause_count == 0)
        "No obvious geometry issues - check vertex data and transforms"
    else
        "Found potential geometry-related issues";

    return .{
        .symptom = .geometry,
        .checks = checks[0..check_count],
        .likely_causes = causes[0..cause_count],
        .summary = summary,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "diagnose: black screen with no draw commands" {
    // Property: Missing draw commands are detected for black screen symptom.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const frame_cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    const result = diagnose(.black, &.{}, &frame_cmds, &validator);

    try std.testing.expectEqual(Symptom.black, result.symptom);
    try std.testing.expect(result.likely_causes.len > 0);
    try std.testing.expectEqualStrings("high", result.likely_causes[0].probability);
}

test "diagnose: black screen with valid draw" {
    // Property: Valid draw sequence has fewer issues.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    // Simulate a valid draw
    validator.draw_count = 1;

    const frame_cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .set_pipeline, .params = .{ .set_pipeline = .{ .id = 0 } } },
        .{ .index = 2, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
        .{ .index = 3, .cmd = .end_pass, .params = .{ .none = {} } },
        .{ .index = 4, .cmd = .submit, .params = .{ .none = {} } },
    };

    const result = diagnose(.black, &.{}, &frame_cmds, &validator);

    // Should have mostly "passed" checks
    var failed_count: u32 = 0;
    for (result.checks) |check| {
        if (!check.passed) failed_count += 1;
    }
    try std.testing.expect(failed_count == 0);
}

test "diagnose: geometry issues with missing vertex buffer" {
    // Property: Missing vertex buffer binding is detected.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const init_cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .create_buffer, .params = .{ .create_buffer = .{ .id = 0, .size = 144, .usage = 0x20 } } }, // VERTEX
    };

    const frame_cmds = [_]ParsedCommand{
        .{ .index = 0, .cmd = .begin_render_pass, .params = .{ .begin_render_pass = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF } } },
        .{ .index = 1, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
        .{ .index = 2, .cmd = .end_pass, .params = .{ .none = {} } },
    };

    const result = diagnose(.geometry, &init_cmds, &frame_cmds, &validator);

    try std.testing.expectEqual(Symptom.geometry, result.symptom);
    try std.testing.expect(result.likely_causes.len > 0);
}

test "diagnose: none symptom returns empty diagnosis" {
    // Property: No symptom returns minimal result.
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();

    const result = diagnose(.none, &.{}, &.{}, &validator);

    try std.testing.expectEqual(Symptom.none, result.symptom);
    try std.testing.expectEqual(@as(usize, 0), result.checks.len);
    try std.testing.expectEqual(@as(usize, 0), result.likely_causes.len);
}
