//! Validator state machine, resource tracking, and pass-state rules
//! (E001-E003, E008). The general shape of the validator, before any one
//! error class.

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
