//! Command Buffer Validator - State Machine and Resource Tracking
//!
//! Validates GPU command buffer correctness by tracking resource lifetimes and
//! pass state transitions. Enables LLM-friendly diagnostics without a browser.
//!
//! ## Design
//!
//! The validator is a state machine with three states: none, render, compute.
//! Resources are tracked in hash maps keyed by their 16-bit IDs.
//!
//! ## Error Codes
//!
//! - E001: missing_resource - Reference to non-existent resource
//! - E002: state_violation - Command in wrong state (draw outside pass)
//! - E004: memory_bounds - Pointer + length exceeds WASM memory bounds
//! - E005: duplicate_id - Resource ID already in use
//! - E006: invalid_descriptor - Invalid resource descriptor (bad usage flags, format, etc)
//! - E007: pass_mismatch - END_PASS without matching BEGIN
//! - E008: nested_pass - BEGIN_PASS inside active pass
//!
//! ## Warning Codes
//!
//! - W003: zero_count - Draw/dispatch with zero work (nothing will render)
//! - W004: null_pointer - Null pointer with non-zero length (suspicious)
//! - W006: suspicious_descriptor - Suspicious but valid descriptor (unusual combinations)
//! - W009: uniform_conflict - Bytecode writes to buffer with uniform fields (may override setUniform)
//!
//! ## Invariants
//!
//! - All loops bounded by MAX_COMMANDS (10000)
//! - No recursion in validation logic
//! - Errors collected in issues list, never thrown
//! - Resource maps never exceed MAX_RESOURCES (1024)
//!
//! ## Layout
//!
//! This file is the stable import facade; the implementation lives in
//! `cmd_validator/`:
//! - `params.zig`    - shared types, usage flags, ParsedCommand
//! - `validator.zig` - the Validator state machine
//! - `parse.zig`     - parseCommands/parseParams byte-stream parsing
//! - `tests.zig`     - the test suite

const params = @import("cmd_validator/params.zig");
const validator_mod = @import("cmd_validator/validator.zig");
const parse_mod = @import("cmd_validator/parse.zig");

pub const BufferUsage = params.BufferUsage;
pub const TextureUsage = params.TextureUsage;
pub const CANVAS_TEXTURE_ID = params.CANVAS_TEXTURE_ID;
pub const NO_DEPTH_TEXTURE_ID = params.NO_DEPTH_TEXTURE_ID;
pub const Severity = params.Severity;
pub const Issue = params.Issue;
pub const Symptom = params.Symptom;
pub const DiagnosticCheck = params.DiagnosticCheck;
pub const Diagnosis = params.Diagnosis;
pub const TextureInfo = params.TextureInfo;
pub const ParsedCommand = params.ParsedCommand;
/// The command-buffer opcode `ParsedCommand.cmd` carries.
pub const Cmd = params.Cmd;
pub const CreateBufferParams = params.CreateBufferParams;
pub const CreateResourceParams = params.CreateResourceParams;
pub const CreateShaderParams = params.CreateShaderParams;
pub const CreateBindGroupParams = params.CreateBindGroupParams;
pub const CreateTextureViewParams = params.CreateTextureViewParams;
pub const BeginRenderPassParams = params.BeginRenderPassParams;
pub const SetPipelineParams = params.SetPipelineParams;
pub const SetBindGroupParams = params.SetBindGroupParams;
pub const SetVertexBufferParams = params.SetVertexBufferParams;
pub const SetIndexBufferParams = params.SetIndexBufferParams;
pub const DrawParams = params.DrawParams;
pub const DrawIndexedParams = params.DrawIndexedParams;
pub const DispatchParams = params.DispatchParams;
pub const WriteBufferParams = params.WriteBufferParams;
pub const WriteTimeUniformParams = params.WriteTimeUniformParams;
pub const CopyBufferParams = params.CopyBufferParams;
pub const CopyTextureParams = params.CopyTextureParams;
pub const CopyExternalImageParams = params.CopyExternalImageParams;
pub const InitWasmModuleParams = params.InitWasmModuleParams;
pub const CallWasmFuncParams = params.CallWasmFuncParams;
pub const WriteBufferFromWasmParams = params.WriteBufferFromWasmParams;

pub const Validator = validator_mod.Validator;
pub const parseCommands = parse_mod.parseCommands;
