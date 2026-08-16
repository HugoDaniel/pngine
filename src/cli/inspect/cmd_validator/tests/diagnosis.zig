//! The diagnostic layer built on top of validation: symptom-based
//! diagnosis, missing-operation detection, parameter checks, pattern
//! detection, and likely-causes analysis.

const std = @import("std");
const pngine = @import("pngine");
const Cmd = pngine.command_buffer.Cmd;
const desc = pngine.types.descriptors;

const cv_shared = @import("../params.zig");
const validator_mod = @import("../validator.zig");
const parse_mod = @import("../parse.zig");
const Validator = validator_mod.Validator;
const parseCommands = parse_mod.parseCommands;
const writeJsonEscaped = cv_shared.writeJsonEscaped;
const BufferUsage = cv_shared.BufferUsage;
const TextureUsage = cv_shared.TextureUsage;
const TextureInfo = cv_shared.TextureInfo;
const Symptom = cv_shared.Symptom;
const Severity = cv_shared.Severity;
const PassState = cv_shared.PassState;
const Issue = cv_shared.Issue;
const Diagnosis = cv_shared.Diagnosis;
const ParsedCommand = cv_shared.ParsedCommand;
const DescriptorType = cv_shared.DescriptorType;
const TextureField = cv_shared.TextureField;
const ValueType = cv_shared.ValueType;

// ============================================================================
// Symptom-Based Diagnosis Tests (Feature 2)
// ============================================================================

// ============================================================================
// Feature 3: Missing Operations Detection Tests
// ============================================================================

// ============================================================================
// Feature 4: Parameter Validation Tests
// ============================================================================

// ============================================================================
// Pattern Detection Tests (Feature 5)
// ============================================================================

// ============================================================================
// Likely Causes Analysis Tests (Feature 6)
// ============================================================================

// ============================================================================
// Analysis reads the stream, not the leftover live state (§337)
// ============================================================================
//
// Every check below has a sibling above that proves the warning *fires*. None
// of them had a sibling proving it *stops*, and that is precisely the half that
// was broken: `hasBindGroupUsage` read `bound_bind_groups`, which the final
// SUBMIT clears, and `hasWriteBuffer` returned a hardcoded `false`. Both warned
// on every healthy program in the corpus — 176 false claims across 120
// fixtures — while their positive tests stayed green.

/// Does `detectMissingOperations` name this operation?
fn missingOpReported(validator: *const Validator, op: []const u8) bool {
    for (validator.detectMissingOperations().slice()) |m| {
        if (std.mem.eql(u8, m.operation, op)) return true;
    }
    return false;
}

// ============================================================================
// Indirect draws, bundles, and pass-scoped state (§337)
// ============================================================================
