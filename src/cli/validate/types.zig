//! Validate command types and data structures.
//!
//! Shared type definitions for the validate command modules.

const std = @import("std");
const cmd_validator = @import("cmd_validator.zig");
const symptom_diagnosis = @import("symptom_diagnosis.zig");

/// Maximum input file size (16 MiB).
pub const max_file_size: u32 = 16 * 1024 * 1024;

/// Validation phase to inspect.
pub const Phase = enum {
    init, // Resource creation only
    frame, // First frame only
    both, // Both init and frame
};

/// Known symptom categories for diagnosis.
pub const Symptom = enum {
    black, // Black screen / nothing renders
    colors, // Wrong colors
    blend, // Blending/transparency issues
    flicker, // Flickering / strobing
    geometry, // Wrong geometry / distortion
    none, // No specific symptom
};

/// Validate command options parsed from CLI arguments.
pub const Options = struct {
    input_path: []const u8,
    json_output: bool,
    verbose: bool,
    phase: Phase,
    symptom: Symptom,
    frame_indices: []const u32, // Frame indices to test (parsed from --frames)
    time: f32,
    time_step: f32,
    width: u32,
    height: u32,
    strict: bool,
    extract_wgsl: bool,
    quiet: bool,

    /// Default frame indices (just frame 0).
    pub const default_frames = [_]u32{0};

    /// Create default options.
    pub fn init() Options {
        return .{
            .input_path = "",
            .json_output = false,
            .verbose = false,
            .phase = .both,
            .symptom = .none,
            .frame_indices = &default_frames,
            .time = 0.0,
            .time_step = 1.0 / 60.0, // 60fps default
            .width = 512,
            .height = 512,
            .strict = false,
            .extract_wgsl = false,
            .quiet = false,
        };
    }
};

/// Validation result for a single command.
/// Uses ParsedCommand from cmd_validator for full parameter info.
pub const CommandInfo = cmd_validator.ParsedCommand;

/// Result for a single frame execution.
pub const FrameResult = struct {
    frame_index: u32,
    time: f32,
    commands: []const CommandInfo,
    draw_count: u32,
    dispatch_count: u32,
};

/// Validation error or warning.
pub const ValidationIssue = struct {
    code: []const u8,
    severity: enum { err, warning },
    message: []const u8,
    command_index: ?u32,
};

/// Bytecode module info for output.
pub const ModuleInfo = struct {
    version: u16,
    has_executor: bool,
    executor_size: u32,
    bytecode_size: u32,
    strings_count: u32,
    data_blobs_count: u32,
    wgsl_entries_count: u32,
    uniform_entries_count: u32,
    has_animation: bool,
    scene_count: u32,
};

/// Frame diff analysis for detecting animation issues.
pub const FrameDiff = struct {
    /// Commands that are identical across all frames.
    static_command_count: u32,
    /// Commands that vary between frames.
    varying_command_count: u32,
    /// Whether time values are changing (animation working).
    time_is_varying: bool,
    /// Whether draw counts are consistent.
    draw_counts_consistent: bool,
    /// Summary message for LLM consumption.
    summary: []const u8,
};

/// Complete validation result.
pub const ValidationResult = struct {
    status: enum { ok, warning, err },
    init_commands: []const CommandInfo,
    frame_commands: []const CommandInfo, // First frame (for backwards compat)
    frame_results: std.ArrayListUnmanaged(FrameResult), // All frames
    frame_diff: ?FrameDiff,
    errors: std.ArrayListUnmanaged(ValidationIssue),
    warnings: std.ArrayListUnmanaged(ValidationIssue),
    module_info: ?ModuleInfo,
    resource_counts: ?cmd_validator.Validator.ResourceCounts,
    draw_count: u32,
    dispatch_count: u32,
    diagnosis: ?symptom_diagnosis.DiagnosisResult, // Symptom-based diagnosis (if --symptom used)

    pub fn init() ValidationResult {
        return .{
            .status = .ok,
            .init_commands = &[_]CommandInfo{},
            .frame_commands = &[_]CommandInfo{},
            .frame_results = .{},
            .frame_diff = null,
            .errors = .{},
            .warnings = .{},
            .module_info = null,
            .resource_counts = null,
            .draw_count = 0,
            .dispatch_count = 0,
            .diagnosis = null,
        };
    }

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        if (self.init_commands.len > 0) allocator.free(self.init_commands);
        if (self.frame_commands.len > 0) allocator.free(self.frame_commands);
        for (self.frame_results.items) |fr| {
            if (fr.commands.len > 0) allocator.free(fr.commands);
        }
        self.frame_results.deinit(allocator);
        self.errors.deinit(allocator);
        self.warnings.deinit(allocator);
    }
};
