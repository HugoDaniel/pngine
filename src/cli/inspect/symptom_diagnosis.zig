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
const Cmd = cmd_validator.Cmd;

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
    summary: []const u8,

    // Storage is owned by value, not referenced.
    //
    // These used to be `[]const DiagnosticCheck` / `[]const LikelyCause`, and
    // every diagnoser filled a `var checks: [MAX_CHECKS]…` on its own stack and
    // returned `checks[0..n]` — a slice into a frame that is gone the moment
    // the function returns. `pngine inspect --symptom black --json` segfaulted
    // on the simplest fixture in the repo. The unit tests did not catch it
    // because they read the slice immediately, before anything overwrote the
    // dead frame, which is exactly how use-after-return hides (§337).
    //
    // Owning the arrays keeps the type's "static, no deallocation" promise true
    // instead of merely stated, and matches `Validator.MissingOperationsResult`,
    // which already carries its storage this way.
    checks_buf: [MAX_CHECKS]DiagnosticCheck = undefined,
    check_count: u32 = 0,
    causes_buf: [MAX_CAUSES]LikelyCause = undefined,
    cause_count: u32 = 0,

    /// Copy `checks` and `causes` into the result, which then owns them.
    pub fn init(
        symptom: Symptom,
        summary: []const u8,
        checks_in: []const DiagnosticCheck,
        causes_in: []const LikelyCause,
    ) DiagnosisResult {
        std.debug.assert(checks_in.len <= MAX_CHECKS);
        std.debug.assert(causes_in.len <= MAX_CAUSES);

        var self = DiagnosisResult{ .symptom = symptom, .summary = summary };
        @memcpy(self.checks_buf[0..checks_in.len], checks_in);
        self.check_count = @intCast(checks_in.len);
        @memcpy(self.causes_buf[0..causes_in.len], causes_in);
        self.cause_count = @intCast(causes_in.len);

        std.debug.assert(self.checks().len == checks_in.len);
        std.debug.assert(self.likelyCauses().len == causes_in.len);
        return self;
    }

    pub fn checks(self: *const DiagnosisResult) []const DiagnosticCheck {
        return self.checks_buf[0..self.check_count];
    }

    pub fn likelyCauses(self: *const DiagnosisResult) []const LikelyCause {
        return self.causes_buf[0..self.cause_count];
    }
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

/// A diagnosis under construction: the checks observed and the causes they
/// imply, in the fixed-capacity storage `DiagnosisResult` copies out of.
///
/// Every diagnoser used to carry its own pair of arrays and its own pair of
/// hand-advanced counters, and every `checks[check_count] = …; check_count +=
/// 1;` was an unguarded write. The margin is real — MAX_CHECKS is 16 and the
/// busiest diagnoser can reach 9 — but nothing said so, and it had to stay true
/// independently in five places. Bounded here, once.
const Findings = struct {
    checks: [MAX_CHECKS]DiagnosticCheck = undefined,
    check_count: u32 = 0,
    causes: [MAX_CAUSES]LikelyCause = undefined,
    cause_count: u32 = 0,

    /// Record a check with no cause attached: one that passed, or context.
    fn note(self: *Findings, check: DiagnosticCheck) void {
        std.debug.assert(self.check_count < MAX_CHECKS);
        self.checks[self.check_count] = check;
        self.check_count += 1;
    }

    /// Record a cause with no check of its own.
    fn suspect(self: *Findings, cause: LikelyCause) void {
        std.debug.assert(self.cause_count < MAX_CAUSES);
        self.causes[self.cause_count] = cause;
        self.cause_count += 1;
    }

    /// Record a failed check together with the cause it implies — the pairing
    /// every diagnoser repeats.
    fn blame(self: *Findings, check: DiagnosticCheck, cause: LikelyCause) void {
        std.debug.assert(!check.passed);
        self.note(check);
        self.suspect(cause);
    }

    fn finish(self: *const Findings, symptom: Symptom, summary: []const u8) DiagnosisResult {
        std.debug.assert(summary.len > 0);
        return DiagnosisResult.init(
            symptom,
            summary,
            self.checks[0..self.check_count],
            self.causes[0..self.cause_count],
        );
    }
};

/// Whether `tag` opens a render pass. Every 3.0.0 payload opens with the F32
/// form (0x53; MRT 0x54); the 4×u8 pair are decoders for shipped streams.
/// The checks used to look for `.begin_render_pass` alone, so every current
/// payload was "No render pass in frame" (audit 09 C4).
fn opensRenderPass(tag: Cmd) bool {
    return switch (tag) {
        .begin_render_pass, .begin_render_pass_mrt, .begin_render_pass_f32, .begin_render_pass_mrt_f32 => true,
        else => false,
    };
}

fn containsRenderPass(cmds: []const ParsedCommand) bool {
    for (cmds) |c| {
        if (opensRenderPass(c.cmd)) return true;
    }
    return false;
}

/// The load op of a single-target render-pass opener, from whichever
/// decoder carried it; null for the MRT forms (per-attachment) and for
/// anything that is not a pass opener.
fn renderPassLoadOp(c: ParsedCommand) ?u8 {
    return switch (c.cmd) {
        .begin_render_pass => c.params.begin_render_pass.load_op,
        .begin_render_pass_f32 => c.params.begin_render_pass_f32.load_op,
        else => null,
    };
}

/// True if any command carries this opcode — the scan the diagnosers repeat.
fn containsCmd(cmds: []const ParsedCommand, tag: Cmd) bool {
    for (cmds) |c| {
        if (c.cmd == tag) return true;
    }
    return false;
}

/// How many commands carry this opcode.
fn countCmd(cmds: []const ParsedCommand, tag: Cmd) u32 {
    var n: u32 = 0;
    for (cmds) |c| {
        if (c.cmd == tag) n += 1;
    }
    std.debug.assert(n <= cmds.len);
    return n;
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
        .none => DiagnosisResult.init(
            .none,
            "No specific symptom selected - run general validation",
            &.{},
            &.{},
        ),
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
        .suggestion = "Add a (draw :vertex-count N) to the (render-pass …), and check the pass is listed in the frame's :perform",
    };

    const no_pipeline: DiagnosticCheck = .{
        .check_name = "pipeline_before_draw",
        .passed = false,
        .severity = .err,
        .message = "SET_PIPELINE missing before DRAW",
        .suggestion = "Give the (render-pass …) a :pipeline",
    };

    const zero_vertices: DiagnosticCheck = .{
        .check_name = "vertex_count_nonzero",
        .passed = false,
        .severity = .err,
        .message = "DRAW vertex_count is 0",
        .suggestion = "Set (draw :vertex-count N) with N > 0 (3 for a triangle)",
    };

    const no_render_pass: DiagnosticCheck = .{
        .check_name = "has_render_pass",
        .passed = false,
        .severity = .err,
        .message = "No BEGIN_RENDER_PASS in frame",
        .suggestion = "Add a (render-pass …) and list it in (frame … :perform [name])",
    };

    const no_submit: DiagnosticCheck = .{
        .check_name = "has_submit",
        .passed = false,
        .severity = .err,
        .message = "No SUBMIT command - command buffer not executed",
        .suggestion = "Ensure a (frame … :perform […]) is declared",
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

/// The cause each failing black-screen check implies, kept beside the checks
/// rather than inline so the diagnoser reads as its five questions.
const black_screen_causes = struct {
    const no_draw: LikelyCause = .{
        .probability = "high",
        .cause = "No DRAW command in frame",
        .evidence = "Command buffer has commands but no DRAW",
        .fix = "Add a (draw :vertex-count N) to the (render-pass …), and check the pass is listed in the frame's :perform",
    };

    const no_render_pass: LikelyCause = .{
        .probability = "high",
        .cause = "No render pass in frame",
        .evidence = "Frame commands have no BEGIN_RENDER_PASS",
        .fix = "Add a (render-pass …) and list it in (frame … :perform [name])",
    };

    const no_pipeline: LikelyCause = .{
        .probability = "high",
        .cause = "Pipeline not set before draw",
        .evidence = "DRAW issued without prior SET_PIPELINE",
        .fix = "Give the (render-pass …) a :pipeline",
    };

    const zero_vertices: LikelyCause = .{
        .probability = "high",
        .cause = "Drawing zero vertices",
        .evidence = "DRAW command has vertex_count=0",
        .fix = "Set (draw :vertex-count N) with N > 0 in the (render-pass …)",
    };

    const no_submit: LikelyCause = .{
        .probability = "medium",
        .cause = "Command buffer not submitted",
        .evidence = "No SUBMIT command found",
        .fix = "Ensure a (frame … :perform […]) is declared",
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

    var f = Findings{};

    // Check 1: Does anything draw? A bundle replay does, and its draws are not
    // in this stream — `drawsPerformed` is what knows that, and reading
    // `draw_count` past it is what made this arm tell the author of
    // `webgpu_render_bundles` to "Add draw=N" (§337, §338).
    const has_draw = validator.drawsPerformed() > 0;
    if (has_draw) {
        f.note(black_screen_checks.draw_ok);
    } else {
        f.blame(black_screen_checks.no_draw, black_screen_causes.no_draw);
    }

    // Check 2: Has render pass? Any of the four opening opcodes.
    if (containsRenderPass(frame_cmds)) {
        f.note(black_screen_checks.render_pass_ok);
    } else {
        f.blame(black_screen_checks.no_render_pass, black_screen_causes.no_render_pass);
    }

    // Check 3: Pipeline set before draw?
    if (has_draw and !pipelineSetBeforeDraw(frame_cmds)) {
        f.blame(black_screen_checks.no_pipeline, black_screen_causes.no_pipeline);
    } else if (has_draw) {
        f.note(black_screen_checks.pipeline_ok);
    }

    // Check 4: Vertex count > 0?
    if (drawsNothing(frame_cmds)) {
        f.blame(black_screen_checks.zero_vertices, black_screen_causes.zero_vertices);
    } else if (has_draw) {
        f.note(black_screen_checks.vertices_ok);
    }

    // Check 5: Has submit?
    if (!containsCmd(frame_cmds, .submit)) {
        f.blame(black_screen_checks.no_submit, black_screen_causes.no_submit);
    }

    const summary: []const u8 = if (f.cause_count == 0)
        "No obvious issues found - check WGSL shader for bugs"
    else if (f.cause_count == 1)
        "Found 1 likely cause for black screen"
    else
        "Found multiple issues that could cause black screen";

    return f.finish(.black, summary);
}

/// Whether every draw in the stream is preceded by a SET_PIPELINE in its pass.
///
/// BEGIN_RENDER_PASS resets the binding: a pipeline set in an earlier pass does
/// not carry into the next one.
fn pipelineSetBeforeDraw(frame_cmds: []const ParsedCommand) bool {
    var saw_pipeline = false;
    for (frame_cmds) |cmd| {
        switch (cmd.cmd) {
            .set_pipeline => saw_pipeline = true,
            .begin_render_pass, .begin_render_pass_mrt, .begin_render_pass_f32, .begin_render_pass_mrt_f32 => saw_pipeline = false,
            .draw, .draw_indexed => if (!saw_pipeline) return false,
            else => {},
        }
    }
    return true;
}

/// Whether any draw asks for zero vertices/indices — a draw that renders
/// nothing at all.
fn drawsNothing(frame_cmds: []const ParsedCommand) bool {
    for (frame_cmds) |cmd| {
        switch (cmd.cmd) {
            .draw => if (cmd.params.draw.vertex_count == 0) return true,
            .draw_indexed => if (cmd.params.draw_indexed.index_count == 0) return true,
            else => {},
        }
    }
    return false;
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

    var f = Findings{};

    // Check the first render pass's load op (1 = clear).
    for (frame_cmds) |cmd| {
        if (!opensRenderPass(cmd.cmd)) continue;
        const load_op = renderPassLoadOp(cmd) orelse break;
        if (load_op != 1) {
            f.note(.{
                .check_name = "load_op",
                .passed = false,
                .severity = .warning,
                .message = "Render pass loadOp is not 'clear'",
                .suggestion = "Use :load-op clear on the (color-attachment …)",
            });
        }
        break;
    }

    // Check for uniform writes (colors might be from shader constants)
    const wrote_uniforms = containsCmd(frame_cmds, .write_buffer) or
        containsCmd(frame_cmds, .write_time_uniform);
    if (!wrote_uniforms) {
        f.blame(.{
            .check_name = "uniforms_written",
            .passed = false,
            .severity = .warning,
            .message = "No WRITE_BUFFER for uniforms",
            .suggestion = "If shader uses uniforms for colors, ensure they are written",
        }, .{
            .probability = "medium",
            .cause = "Uniforms not written",
            .evidence = "No WRITE_BUFFER commands for uniform data",
            .fix = "Add a (queue … (write-buffer :buffer … :data …)) and list it in the frame's :before",
        });
    }

    const summary: []const u8 = if (f.cause_count == 0)
        "No obvious color issues - check WGSL shader color output"
    else
        "Found potential color-related issues";

    return f.finish(.colors, summary);
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

    var f = Findings{};

    // Blend state lives inside the pipeline descriptor, which is opaque bytes
    // here — so the only thing this can check is whether a pipeline exists at
    // all, and otherwise point at where to look.
    const has_pipeline = containsCmd(init_cmds, .create_render_pipeline);
    if (has_pipeline) {
        f.note(.{
            .check_name = "blend_state",
            .passed = true,
            .severity = .info,
            .message = "Pipeline created - blend state is in pipeline descriptor",
            .suggestion = "Verify the (blend …) under the (target …) of the (render-pipeline …)",
        });
        f.suspect(.{
            .probability = "medium",
            .cause = "Blend state misconfigured",
            .evidence = "Pipeline exists but blend may not be enabled",
            .fix = "Under the (target …), add (blend (color :src-factor … :dst-factor …) (alpha …))",
        });
    } else {
        f.blame(.{
            .check_name = "blend_state",
            .passed = false,
            .severity = .err,
            .message = "No render pipeline created",
            .suggestion = "Add a (render-pipeline …) whose (target …) carries a (blend …)",
        }, .{
            .probability = "high",
            .cause = "No pipeline for blend configuration",
            .evidence = "No CREATE_RENDER_PIPELINE command found",
            .fix = "Define a (render-pipeline …) with a (blend …) under its (target …)",
        });
    }

    const summary: []const u8 = if (has_pipeline)
        "Pipeline exists - verify blend state configuration"
    else
        "No pipeline found for blend configuration";

    return f.finish(.blend, summary);
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

    var f = Findings{};

    // Check for multiple submits per frame
    if (countCmd(frame_cmds, .submit) > 1) {
        f.blame(.{
            .check_name = "multiple_submits",
            .passed = false,
            .severity = .warning,
            .message = "Multiple SUBMIT commands per frame",
            .suggestion = "Use single submit at end of frame",
        }, .{
            .probability = "medium",
            .cause = "Multiple submits causing sync issues",
            // Count-free static string: this diagnose path has no allocator, and
            // every `evidence` must outlive the returned DiagnosisResult, so the
            // exact submit count can't be formatted here without a lifetime owner.
            // (The prior comptimePrint hardcoded "2", which lied for counts > 2.)
            .evidence = "Multiple SUBMIT commands found (see the frame command trace for the count)",
            .fix = "One (frame …) submits once — check the pass list is not duplicated",
        });
    }

    // Ping-pong offsets are the usual flicker cause, and the pool depth that
    // would confirm it is not in the command stream — CREATE_BUFFER carries no
    // pool field. "A compute pass and at least one buffer" is as close as this
    // gets, which is why the cause it raises is phrased as somewhere to look.
    if (containsCmd(frame_cmds, .begin_compute_pass) and containsCmd(init_cmds, .create_buffer)) {
        f.note(.{
            .check_name = "ping_pong_pattern",
            .passed = true,
            .severity = .info,
            .message = "Compute with buffers detected - check ping-pong offsets",
            .suggestion = "Verify :bind-groups-pool-offsets alternate correctly",
        });
        f.suspect(.{
            .probability = "high",
            .cause = "Ping-pong buffer offset mismatch",
            .evidence = "Compute shader with buffer pools detected",
            .fix = "On the (compute-pass …), set :bind-groups-pool-offsets [1] or similar",
        });
    }

    const summary: []const u8 = if (f.cause_count == 0)
        "No obvious flickering issues - check frame timing"
    else
        "Found potential causes for flickering";

    return f.finish(.flicker, summary);
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

    var f = Findings{};

    const vertex_buffer_size = firstBufferSizeWithUsage(init_cmds, VERTEX_USAGE);
    const has_vertex_buffer = containsCmd(frame_cmds, .set_vertex_buffer);

    if (vertex_buffer_size > 0 and !has_vertex_buffer) {
        f.blame(.{
            .check_name = "vertex_buffer_bound",
            .passed = false,
            .severity = .warning,
            .message = "Vertex buffer created but not bound",
            .suggestion = "Add :vertex-buffers [name] to the (render-pass …)",
        }, .{
            .probability = "high",
            .cause = "Vertex buffer not bound",
            .evidence = "CREATE_BUFFER with VERTEX usage but no SET_VERTEX_BUFFER",
            .fix = "On the (render-pass …), add :vertex-buffers [posBuffer]",
        });
    }

    if (vertex_buffer_size > 0) {
        // Capacity in the smallest plausible vertex (a vec3 of f32).
        const too_small = vertex_buffer_size / 12 < 3;
        f.note(.{
            .check_name = "vertex_buffer_size",
            .passed = true,
            .severity = .info,
            .message = "Vertex buffer analyzed",
            .suggestion = if (too_small) "Buffer may be too small for a triangle" else "",
        });
        if (too_small) {
            f.suspect(.{
                .probability = "medium",
                .cause = "Vertex buffer too small",
                .evidence = "Buffer can hold < 3 vec3 vertices",
                .fix = "Increase buffer size or check vertex format",
            });
        }
    }

    // Check for uniform buffer (transforms)
    if (firstBufferSizeWithUsage(init_cmds, UNIFORM_USAGE) == 0) {
        f.note(.{
            .check_name = "uniform_buffer",
            .passed = false,
            .severity = .warning,
            .message = "No uniform buffer for transforms",
            .suggestion = "If using MVP matrices, add uniform buffer",
        });
    }

    const summary: []const u8 = if (f.cause_count == 0)
        "No obvious geometry issues - check vertex data and transforms"
    else
        "Found potential geometry-related issues";

    return f.finish(.geometry, summary);
}

const VERTEX_USAGE: u16 = 0x20;
const UNIFORM_USAGE: u16 = 0x40;

/// Size of the first buffer created with `usage_flag` set, or 0 if there is
/// none. Zero doubles as "absent" because a zero-size buffer cannot hold
/// anything either — both answers lead to the same advice.
fn firstBufferSizeWithUsage(init_cmds: []const ParsedCommand, usage_flag: u16) u32 {
    std.debug.assert(usage_flag != 0);
    for (init_cmds) |cmd| {
        if (cmd.cmd != .create_buffer) continue;
        if (cmd.params.create_buffer.usage & usage_flag != 0) {
            return cmd.params.create_buffer.size;
        }
    }
    return 0;
}

// ============================================================================
// Tests
// ============================================================================

/// Whether the diagnosis raised the named check as failed.
fn failedCheck(result: DiagnosisResult, name: []const u8) bool {
    for (result.checks()) |c| {
        if (std.mem.eql(u8, c.check_name, name)) return !c.passed;
    }
    return false;
}

// ── audit 09 C4: the 3.0.0 pass opcodes, and the spelling of the advice ──────
//
// Every 3.0.0 render pass opens with BEGIN_RENDER_PASS_F32 (0x53; the MRT form
// is 0x54) — the 4×u8 predecessors are decoders for already-shipped streams.
// The black-screen and colour checks looked for `.begin_render_pass` only, so
// `pngine inspect examples/simple_triangle.sjon --symptom black` reported "No
// render pass in frame" (high) on every current payload. And every fix string
// spoke the retired `#renderPass draw=N` syntax.

/// The valid frame every symptom sees, spelled with the CURRENT pass opcode.
const f32_pass_frame = [_]ParsedCommand{
    .{ .index = 0, .cmd = .begin_render_pass_f32, .params = .{ .begin_render_pass_f32 = .{ .color_id = 0xFFFF, .load_op = 1, .store_op = 1, .depth_id = 0xFFFF, .resolve_id = 0xFFFF } } },
    .{ .index = 1, .cmd = .set_pipeline, .params = .{ .set_pipeline = .{ .id = 0 } } },
    .{ .index = 2, .cmd = .draw, .params = .{ .draw = .{ .vertex_count = 3, .instance_count = 1, .first_vertex = 0, .first_instance = 0 } } },
    .{ .index = 3, .cmd = .end_pass, .params = .{ .none = {} } },
    .{ .index = 4, .cmd = .submit, .params = .{ .none = {} } },
};

/// The retired PBSF spellings no fix or suggestion may use any more: `#form`,
/// `key=value`, `perform=[…]`, camelCase pngine keys.
const retired_spellings = [_][]const u8{ "#", "draw=", "pipeline=", "perform=", "loadOp=", "vertexBuffers=", "bindGroupsPoolOffsets", "writeBuffer", "blend: {" };

fn expectCurrentSpelling(result: DiagnosisResult) !void {
    for (result.checks()) |check| {
        for (retired_spellings) |bad| {
            if (std.mem.indexOf(u8, check.suggestion, bad) != null or std.mem.indexOf(u8, check.message, bad) != null) {
                std.debug.print("\nretired spelling '{s}' in check '{s}': {s} / {s}\n", .{ bad, check.check_name, check.message, check.suggestion });
                return error.RetiredSpelling;
            }
        }
    }
    for (result.likelyCauses()) |cause| {
        for (retired_spellings) |bad| {
            if (std.mem.indexOf(u8, cause.fix, bad) != null) {
                std.debug.print("\nretired spelling '{s}' in fix: {s}\n", .{ bad, cause.fix });
                return error.RetiredSpelling;
            }
        }
    }
}
