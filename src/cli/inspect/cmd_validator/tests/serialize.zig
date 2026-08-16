//! JSON serialization of validator output, plus the writer/parser
//! conformance net that pins CommandBuffer against the inspect decoder.

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
// JSON Serialization Tests
// ============================================================================

// ============================================================================
// Writer ↔ Parser Conformance
// ============================================================================

// This is the guard for the drift class that had `pngine inspect` panicking on
// four shipped examples: `CommandBuffer` (the writer, and the only source of
// truth for the command-buffer wire format) gained an `origin_z` operand on
// COPY_EXTERNAL_IMAGE_TO_TEXTURE and moved CALL_WASM_FUNC's arguments inline,
// while this module's hand-written decoder kept consuming the old byte counts.
// Being short by two bytes desynchronised the stream, so the next tag was read
// out of the middle of an operand — an invalid enum value, i.e. a crash.
//
// Emitting one of *every* command and parsing the result catches any such
// mismatch: a wrong operand length shifts everything after it, so either the
// tag sequence stops matching or the parse errors outright. The coverage
// assertion below makes the test fail when a new Cmd is added without being
// exercised here, so the guard cannot rot.
