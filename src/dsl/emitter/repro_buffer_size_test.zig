const std = @import("std");
const testing = std.testing;
const Compiler = @import("../../dsl/Compiler.zig").Compiler;
const bytecode = @import("bytecode");
const opcodes = bytecode.opcodes;

test "Emitter: consistent buffer sizes for time uniform" {
    const allocator = testing.allocator;

    // Use a custom buffer size to verify the emitter picks it up
    // Default is 16 bytes. If we define 32, it should use 32.
    const source = "#buffer timeBuf { size=32 usage=[UNIFORM COPY_DST] }\n\n#queue updateTime {\n  writeBuffer={\n    buffer=timeBuf\n    data=pngineInputs\n  }\n}\n\n#frame main {\n  perform=[updateTime]\n}";

    const result = try Compiler.compile(allocator, source);
    defer allocator.free(result);

    std.debug.print("Test Started: scanning bytecode len={d}\n", .{result.len});

    // Scan bytecode for create_buffer and write_time_uniform
    var pc: usize = 40;
    // Get string table offset to know where bytecode ends
    const string_table_offset = std.mem.readInt(u32, result[20..24], .little);
    const end = string_table_offset;
    
    var time_buffer_id: ?u16 = null;
    var create_size: ?u32 = null;
    var write_size: ?u32 = null;

    while (pc < end) {
        const op: opcodes.OpCode = @enumFromInt(result[pc]);
        pc += 1;

        if (op == .create_buffer) {
            const result_id = opcodes.decode_varint(result[pc..]);
            pc += result_id.len;
            const result_size = opcodes.decode_varint(result[pc..]);
            pc += result_size.len;
            pc += 1; // usage
            
            // Assume first buffer is ours
            if (time_buffer_id == null) {
                time_buffer_id = @intCast(result_id.value);
                create_size = result_size.value;
            }
        } else if (op == .write_time_uniform) {
            const result_id = opcodes.decode_varint(result[pc..]);
            pc += result_id.len;
            const result_off = opcodes.decode_varint(result[pc..]);
            pc += result_off.len;
            const result_sz = opcodes.decode_varint(result[pc..]);
            pc += result_sz.len;

            if (time_buffer_id) |tid| {
                if (result_id.value == tid) {
                    write_size = result_sz.value;
                }
            }
        } else {
            // Helper to skip params
            skipOpcodeParams(result, &pc, op);
        }
    }

    if (create_size) |c| {
        if (write_size) |w| {
            std.debug.print("Buffer: create={d}, write={d}\n", .{c, w});
            // With our fix, write size should match buffer size (32)
            // Before fix, it was hardcoded to 16
            try testing.expectEqual(c, w); 
            try testing.expectEqual(@as(u32, 32), w);
        } else {
            std.debug.print("Buffer: create={d}, write=NULL\n", .{c});
            return error.TestUnexpectedResult;
        }
    } else {
        std.debug.print("Buffer: create=NULL\n", .{});
        return error.TestUnexpectedResult;
    }
}

// Minimal skip logic for test
fn skipOpcodeParams(code: []const u8, pc: *usize, op: opcodes.OpCode) void {
    switch (op) {
        .define_frame => {
            _ = opcodes.decode_varint(code[pc.*..]).len; // id
            const r1 = opcodes.decode_varint(code[pc.*..]); pc.* += r1.len;
            const r2 = opcodes.decode_varint(code[pc.*..]); pc.* += r2.len;
        },
        .end_frame, .submit => {},
        else => {} // Should not happen in this simple test source
    }
}
