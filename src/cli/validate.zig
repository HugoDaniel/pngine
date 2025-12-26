//! Validate command: runtime validation via wasm3 command buffer inspection.
//!
//! ## Usage
//! ```
//! pngine validate shader.pngine                    # Human-readable validation
//! pngine validate shader.pngine --json             # JSON output for LLM consumption
//! pngine validate shader.pngine --json --phase init  # Only resource creation
//! pngine validate shader.pngine --json --phase frame # Only first frame commands
//! pngine validate shader.pngine --symptom black    # Diagnose "black screen"
//! ```
//!
//! ## Design
//! Uses wasm3 to execute the WASM executor, captures command buffer output,
//! and validates it for correctness. Provides structured JSON output for
//! LLM-based debugging workflows.
//!
//! ## Module Organization
//!
//! - `validate/types.zig` - Shared types (Options, ValidationResult, etc.)
//! - `validate/args.zig` - CLI argument parsing
//! - `validate/loader.zig` - Bytecode loading from various formats
//! - `validate/executor.zig` - WASM execution and validation
//! - `validate/output.zig` - JSON and human-readable output
//! - `validate/wasm3.zig` - wasm3 runtime wrapper
//! - `validate/cmd_validator.zig` - Command buffer state machine
//! - `validate/symptom_diagnosis.zig` - Symptom-based diagnosis

const std = @import("std");

// Submodules
const types = @import("validate/types.zig");
const args_mod = @import("validate/args.zig");
const loader = @import("validate/loader.zig");
const executor = @import("validate/executor.zig");
const output = @import("validate/output.zig");

// Re-export types for external use
pub const Phase = types.Phase;
pub const Symptom = types.Symptom;
pub const Options = types.Options;
pub const ValidationResult = types.ValidationResult;

/// Execute the validate command.
///
/// Pre-condition: args is the slice after "validate" command.
/// Post-condition: Returns exit code (0 = success, 1 = validation errors).
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    // Parse arguments
    var opts = Options.init();

    const parse_result = args_mod.parseArgs(args, &opts);
    if (parse_result == 255) return 0; // Help was shown
    if (parse_result != 0) return parse_result;

    // Parse --frames argument (needs allocator, so done after parseArgs)
    var owned_frame_indices: ?[]u32 = null;
    defer if (owned_frame_indices) |fi| allocator.free(fi);

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--frames") and i + 1 < args.len) {
            owned_frame_indices = args_mod.parseFrameIndices(allocator, args[i + 1]) catch |err| {
                std.debug.print("Error: invalid --frames format: {s}\n", .{@errorName(err)});
                return 1;
            };
            opts.frame_indices = owned_frame_indices.?;
            break;
        }
    }

    // Pre-condition: valid options after parsing
    std.debug.assert(opts.input_path.len > 0);
    std.debug.assert(opts.width > 0 and opts.height > 0);
    std.debug.assert(opts.frame_indices.len > 0);

    // Load and compile source to bytecode
    const bytecode = loader.loadBytecode(allocator, opts.input_path) catch |err| {
        if (opts.json_output) {
            try output.outputJsonError(allocator, "compile_error", @errorName(err));
        } else {
            std.debug.print("Error: failed to load '{s}': {s}\n", .{ opts.input_path, @errorName(err) });
        }
        return 3;
    };
    defer allocator.free(bytecode);

    // Run validation
    var result = ValidationResult.init();
    defer result.deinit(allocator);

    executor.validateBytecode(allocator, bytecode, &result, &opts) catch |err| {
        if (opts.json_output) {
            try output.outputJsonError(allocator, "validation_error", @errorName(err));
        } else {
            std.debug.print("Error: validation failed: {s}\n", .{@errorName(err)});
        }
        return 3;
    };

    // Output results
    if (opts.json_output) {
        try output.outputJson(allocator, &result, &opts);
    } else {
        try output.outputHuman(&result, &opts);
    }

    // Return exit code based on result
    if (result.status == .err) return 1;
    if (result.status == .warning and opts.strict) return 1;
    return 0;
}

// ============================================================================
// Tests (reference submodule tests for discovery)
// ============================================================================

test {
    // Import submodules to discover their tests
    _ = @import("validate/types.zig");
    _ = @import("validate/args.zig");
    _ = @import("validate/loader.zig");
    _ = @import("validate/executor.zig");
    _ = @import("validate/output.zig");
    _ = @import("validate/wasm3.zig");
    _ = @import("validate/cmd_validator.zig");
    _ = @import("validate/symptom_diagnosis.zig");
}
