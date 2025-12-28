//! Command Buffer Tests
//!
//! Tests for the command buffer encoding and CommandGPU backend:
//! - Basic command encoding (header, commands)
//! - Individual command serialization
//! - WASM plugin commands (initWasmModule, callWasmFunc, writeBufferFromWasm)
//! - Command flow sequences
//!
//! ## Test Categories
//!
//! - Basic: header encoding, command counting
//! - Commands: individual command byte layouts
//! - WASM Plugin: nested WASM module operations

const std = @import("std");
const testing = std.testing;

const command_buffer = @import("../command_buffer.zig");
const CommandBuffer = command_buffer.CommandBuffer;
const Cmd = command_buffer.Cmd;
const HEADER_SIZE = command_buffer.HEADER_SIZE;

// ============================================================================
// Basic Tests
// ============================================================================

test "CommandBuffer basic" {
    var buffer: [1024]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    cmds.createBuffer(0, 256, 0x21);
    cmds.beginRenderPass(0xFFFF, 1, 1, 0xFFFF);
    cmds.setPipeline(0);
    cmds.draw(3, 1, 0, 0);
    cmds.endPass();
    cmds.submit();
    cmds.end();

    const result = cmds.finish();

    // Check header
    const total_len = std.mem.readInt(u32, result[0..4], .little);
    const cmd_count = std.mem.readInt(u16, result[4..6], .little);

    try testing.expect(total_len > HEADER_SIZE);
    try testing.expectEqual(@as(u16, 7), cmd_count);
}

test "CommandBuffer commands" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    cmds.createBuffer(1, 1024, 0x41);
    _ = cmds.finish();

    // Verify command encoding
    // Header (8) + cmd(1) + id(2) + size(4) + usage(1) = 16
    try testing.expectEqual(@as(usize, 16), cmds.pos);

    // Check command byte
    try testing.expectEqual(@as(u8, 0x01), buffer[HEADER_SIZE]);

    // Check id (little-endian)
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buffer[HEADER_SIZE + 1 ..][0..2], .little));

    // Check size
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, buffer[HEADER_SIZE + 3 ..][0..4], .little));
}

// ============================================================================
// WASM Plugin Command Tests
// ============================================================================

test "CommandBuffer: initWasmModule encodes correctly" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const module_id: u16 = 5;
    const data_ptr: u32 = 0x1000;
    const data_len: u32 = 256;
    cmds.initWasmModule(module_id, data_ptr, data_len);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + module_id(2) + data_ptr(4) + data_len(4) = 19
    try testing.expectEqual(@as(usize, 19), cmds.pos);

    // Verify command byte
    try testing.expectEqual(@as(u8, @intFromEnum(Cmd.init_wasm_module)), buffer[HEADER_SIZE]);

    // Verify module_id
    var pos: usize = HEADER_SIZE + 1;
    try testing.expectEqual(module_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;

    // Verify data_ptr
    try testing.expectEqual(data_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;

    // Verify data_len
    try testing.expectEqual(data_len, std.mem.readInt(u32, buffer[pos..][0..4], .little));
}

test "CommandBuffer: callWasmFunc encodes correctly with inline args" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const call_id: u16 = 1;
    const module_id: u16 = 0;
    const func_name_ptr: u32 = 0x2000;
    const func_name_len: u32 = 10;
    // Inline args: [count=3, type=1, type=2, type=3]
    const args = [_]u8{ 3, 0x01, 0x02, 0x03 };

    cmds.callWasmFunc(call_id, module_id, func_name_ptr, func_name_len, &args);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + call_id(2) + module_id(2) + func_name_ptr(4)
    //           + func_name_len(4) + args_len(1) + args(4) = 26
    try testing.expectEqual(@as(usize, 26), cmds.pos);

    // Verify command byte
    try testing.expectEqual(@as(u8, @intFromEnum(Cmd.call_wasm_func)), buffer[HEADER_SIZE]);

    // Verify parameters
    var pos: usize = HEADER_SIZE + 1;
    try testing.expectEqual(call_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try testing.expectEqual(module_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try testing.expectEqual(func_name_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try testing.expectEqual(func_name_len, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    // Args length (u8)
    try testing.expectEqual(@as(u8, 4), buffer[pos]);
    pos += 1;
    // Inline args bytes
    try testing.expectEqualSlices(u8, &args, buffer[pos..][0..4]);
}

test "CommandBuffer: writeBufferFromWasm encodes correctly" {
    var buffer: [256]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    const buffer_id: u16 = 3;
    const buffer_offset: u32 = 64;
    const wasm_ptr: u32 = 0x4000;
    const size: u32 = 128;

    cmds.writeBufferFromWasm(buffer_id, buffer_offset, wasm_ptr, size);
    _ = cmds.finish();

    // Expected: Header (8) + cmd(1) + buffer_id(2) + buffer_offset(4) + wasm_ptr(4) + size(4) = 23
    try testing.expectEqual(@as(usize, 23), cmds.pos);

    // Verify command byte
    try testing.expectEqual(@as(u8, @intFromEnum(Cmd.write_buffer_from_wasm)), buffer[HEADER_SIZE]);

    // Verify parameters
    var pos: usize = HEADER_SIZE + 1;
    try testing.expectEqual(buffer_id, std.mem.readInt(u16, buffer[pos..][0..2], .little));
    pos += 2;
    try testing.expectEqual(buffer_offset, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try testing.expectEqual(wasm_ptr, std.mem.readInt(u32, buffer[pos..][0..4], .little));
    pos += 4;
    try testing.expectEqual(size, std.mem.readInt(u32, buffer[pos..][0..4], .little));
}

test "CommandBuffer: WASM flow sequence" {
    // Test a typical WASM call flow:
    // 1. initWasmModule - load module
    // 2. callWasmFunc - call function with inline args
    // 3. writeBufferFromWasm - copy result to GPU
    var buffer: [512]u8 = undefined;
    var cmds = CommandBuffer.init(&buffer);

    // Args: [count=2][arg1_type=canvas_width][arg2_type=time_total]
    const args = [_]u8{ 2, 0x01, 0x03 };
    cmds.initWasmModule(0, 0x1000, 1024);
    cmds.callWasmFunc(0, 0, 0x2000, 8, &args);
    cmds.writeBufferFromWasm(1, 0, 0, 64);
    cmds.end();

    const result = cmds.finish();
    const cmd_count = std.mem.readInt(u16, result[4..6], .little);

    // 3 WASM commands + 1 end command
    try testing.expectEqual(@as(u16, 4), cmd_count);
}
