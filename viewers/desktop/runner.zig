//! Command Buffer Runner (Stub GPU Backend)
//!
//! Executes PNGine command buffers by either:
//! 1. Tracing commands to stdout (default, no GPU required)
//! 2. Executing on a real GPU backend (Dawn/Mach - TODO)
//!
//! ## Architecture
//!
//! ```
//! Command Buffer → Runner.execute() → GPU Backend (stub/Dawn/Mach)
//! ```
//!
//! ## Invariants
//! - Command buffer starts with 8-byte header
//! - Commands are sequential, no forward references
//! - Resource IDs are monotonically assigned

const std = @import("std");

/// Command opcodes (matches src/executor/command_buffer.zig).
/// Self-contained to avoid bytecode module dependency.
pub const Cmd = struct {
    // Resource Creation (0x01-0x0F)
    pub const CREATE_BUFFER: u8 = 0x01;
    pub const CREATE_TEXTURE: u8 = 0x02;
    pub const CREATE_SAMPLER: u8 = 0x03;
    pub const CREATE_SHADER: u8 = 0x04;
    pub const CREATE_RENDER_PIPELINE: u8 = 0x05;
    pub const CREATE_COMPUTE_PIPELINE: u8 = 0x06;
    pub const CREATE_BIND_GROUP: u8 = 0x07;
    pub const CREATE_TEXTURE_VIEW: u8 = 0x08;
    pub const CREATE_QUERY_SET: u8 = 0x09;
    pub const CREATE_BIND_GROUP_LAYOUT: u8 = 0x0A;
    pub const CREATE_IMAGE_BITMAP: u8 = 0x0B;
    pub const CREATE_PIPELINE_LAYOUT: u8 = 0x0C;
    pub const CREATE_RENDER_BUNDLE: u8 = 0x0D;

    // Pass Operations (0x10-0x1F)
    pub const BEGIN_RENDER_PASS: u8 = 0x10;
    pub const BEGIN_COMPUTE_PASS: u8 = 0x11;
    pub const SET_PIPELINE: u8 = 0x12;
    pub const SET_BIND_GROUP: u8 = 0x13;
    pub const SET_VERTEX_BUFFER: u8 = 0x14;
    pub const DRAW: u8 = 0x15;
    pub const DRAW_INDEXED: u8 = 0x16;
    pub const END_PASS: u8 = 0x17;
    pub const DISPATCH: u8 = 0x18;
    pub const SET_INDEX_BUFFER: u8 = 0x19;
    pub const EXECUTE_BUNDLES: u8 = 0x1A;

    // Queue Operations (0x20-0x2F)
    pub const WRITE_BUFFER: u8 = 0x20;
    pub const WRITE_TIME_UNIFORM: u8 = 0x21;
    pub const COPY_BUFFER_TO_BUFFER: u8 = 0x22;
    pub const COPY_TEXTURE_TO_TEXTURE: u8 = 0x23;
    pub const WRITE_BUFFER_FROM_WASM: u8 = 0x24;
    pub const COPY_EXTERNAL_IMAGE_TO_TEXTURE: u8 = 0x25;

    // WASM Module Operations (0x30-0x3F)
    pub const INIT_WASM_MODULE: u8 = 0x30;
    pub const CALL_WASM_FUNC: u8 = 0x31;

    // Utility Operations (0x40-0x4F)
    pub const CREATE_TYPED_ARRAY: u8 = 0x40;
    pub const FILL_RANDOM: u8 = 0x41;
    pub const FILL_EXPRESSION: u8 = 0x42;
    pub const FILL_CONSTANT: u8 = 0x43;
    pub const WRITE_BUFFER_FROM_ARRAY: u8 = 0x44;

    // Control (0xF0-0xFF)
    pub const SUBMIT: u8 = 0xF0;
    pub const END: u8 = 0xFF;
};

/// GPU backend implementation.
/// Currently a stub that traces commands; will be replaced with Dawn/Mach.
pub const Runner = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    trace_mode: bool,

    // Resource tracking (for future GPU backend)
    buffer_count: u32,
    texture_count: u32,
    pipeline_count: u32,

    /// Initialize a new command runner.
    ///
    /// Pre-condition: width > 0, height > 0
    /// Post-condition: Runner ready for execute()
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Runner {
        std.debug.assert(width > 0);
        std.debug.assert(height > 0);

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .trace_mode = true, // Default to trace mode
            .buffer_count = 0,
            .texture_count = 0,
            .pipeline_count = 0,
        };
    }

    /// Clean up resources.
    pub fn deinit(self: *Runner) void {
        // Stub: no resources to clean up yet
        self.* = undefined;
    }

    /// Execute a command buffer.
    ///
    /// Pre-condition: buf.len >= 8 (header)
    /// Post-condition: All commands processed or error returned
    pub fn execute(self: *Runner, buf: []const u8) !void {
        std.debug.assert(buf.len >= 8);

        // Parse header
        const total_len = std.mem.readInt(u32, buf[0..4], .little);
        const cmd_count = std.mem.readInt(u16, buf[4..6], .little);
        const flags = std.mem.readInt(u16, buf[6..8], .little);

        if (self.trace_mode) {
            std.debug.print("[Runner] Command buffer: len={}, cmds={}, flags=0x{x:0>4}\n", .{
                total_len, cmd_count, flags,
            });
        }

        var pos: usize = 8;
        var cmd_idx: u16 = 0;

        // Bounded loop with safety
        const max_cmds: u32 = 4096;
        for (0..max_cmds) |_| {
            if (cmd_idx >= cmd_count or pos >= buf.len) break;

            const cmd = buf[pos];
            const cmd_size = self.processCommand(buf, pos, cmd_idx);
            pos += cmd_size;
            cmd_idx += 1;

            if (cmd == Cmd.END) break;
        } else {
            // Loop exhausted without END - possible malformed buffer
            std.debug.print("[Runner] Warning: max commands ({}) reached\n", .{max_cmds});
        }

        if (self.trace_mode) {
            std.debug.print("[Runner] Processed {} commands\n", .{cmd_idx});
        }
    }

    /// Process a single command, returns bytes consumed.
    fn processCommand(self: *Runner, buf: []const u8, pos: usize, idx: u16) usize {
        const cmd = buf[pos];
        const name = cmdName(cmd);
        const size = cmdSize(cmd);

        if (self.trace_mode) {
            std.debug.print("  [{d:>3}] 0x{x:0>2} {s}", .{ idx, cmd, name });

            // Print command-specific params
            switch (cmd) {
                Cmd.CREATE_BUFFER => {
                    if (pos + size <= buf.len) {
                        const id = std.mem.readInt(u16, buf[pos + 1 ..][0..2], .little);
                        const buf_size = std.mem.readInt(u32, buf[pos + 3 ..][0..4], .little);
                        const usage = buf[pos + 7];
                        std.debug.print(" id={} size={} usage=0x{x:0>2}", .{ id, buf_size, usage });
                        self.buffer_count += 1;
                    }
                },
                Cmd.CREATE_TEXTURE => {
                    if (pos + size <= buf.len) {
                        const id = std.mem.readInt(u16, buf[pos + 1 ..][0..2], .little);
                        std.debug.print(" id={}", .{id});
                        self.texture_count += 1;
                    }
                },
                Cmd.CREATE_SHADER => {
                    if (pos + size <= buf.len) {
                        const id = std.mem.readInt(u16, buf[pos + 1 ..][0..2], .little);
                        const ptr = std.mem.readInt(u32, buf[pos + 3 ..][0..4], .little);
                        const len = std.mem.readInt(u32, buf[pos + 7 ..][0..4], .little);
                        std.debug.print(" id={} ptr=0x{x:0>8} len={}", .{ id, ptr, len });
                    }
                },
                Cmd.CREATE_RENDER_PIPELINE, Cmd.CREATE_COMPUTE_PIPELINE => {
                    if (pos + size <= buf.len) {
                        const id = std.mem.readInt(u16, buf[pos + 1 ..][0..2], .little);
                        std.debug.print(" id={}", .{id});
                        self.pipeline_count += 1;
                    }
                },
                Cmd.SET_PIPELINE => {
                    if (pos + size <= buf.len) {
                        const id = std.mem.readInt(u16, buf[pos + 1 ..][0..2], .little);
                        std.debug.print(" id={}", .{id});
                    }
                },
                Cmd.DRAW => {
                    if (pos + size <= buf.len) {
                        const vtx_count = std.mem.readInt(u32, buf[pos + 1 ..][0..4], .little);
                        const inst_count = std.mem.readInt(u32, buf[pos + 5 ..][0..4], .little);
                        std.debug.print(" vertices={} instances={}", .{ vtx_count, inst_count });
                    }
                },
                Cmd.DISPATCH => {
                    if (pos + size <= buf.len) {
                        const x = std.mem.readInt(u32, buf[pos + 1 ..][0..4], .little);
                        const y = std.mem.readInt(u32, buf[pos + 5 ..][0..4], .little);
                        const z = std.mem.readInt(u32, buf[pos + 9 ..][0..4], .little);
                        std.debug.print(" workgroups=[{} {} {}]", .{ x, y, z });
                    }
                },
                else => {},
            }
            std.debug.print("\n", .{});
        }

        // In future: dispatch to real GPU backend here
        // switch (cmd) {
        //     Cmd.CREATE_BUFFER => dawn.createBuffer(...),
        //     ...
        // }

        return size;
    }
};

/// Get human-readable command name.
fn cmdName(cmd: u8) []const u8 {
    return switch (cmd) {
        Cmd.CREATE_BUFFER => "CREATE_BUFFER",
        Cmd.CREATE_TEXTURE => "CREATE_TEXTURE",
        Cmd.CREATE_SAMPLER => "CREATE_SAMPLER",
        Cmd.CREATE_SHADER => "CREATE_SHADER",
        Cmd.CREATE_RENDER_PIPELINE => "CREATE_RENDER_PIPELINE",
        Cmd.CREATE_COMPUTE_PIPELINE => "CREATE_COMPUTE_PIPELINE",
        Cmd.CREATE_BIND_GROUP => "CREATE_BIND_GROUP",
        Cmd.CREATE_TEXTURE_VIEW => "CREATE_TEXTURE_VIEW",
        Cmd.CREATE_QUERY_SET => "CREATE_QUERY_SET",
        Cmd.CREATE_BIND_GROUP_LAYOUT => "CREATE_BIND_GROUP_LAYOUT",
        Cmd.CREATE_IMAGE_BITMAP => "CREATE_IMAGE_BITMAP",
        Cmd.CREATE_PIPELINE_LAYOUT => "CREATE_PIPELINE_LAYOUT",
        Cmd.CREATE_RENDER_BUNDLE => "CREATE_RENDER_BUNDLE",
        Cmd.BEGIN_RENDER_PASS => "BEGIN_RENDER_PASS",
        Cmd.BEGIN_COMPUTE_PASS => "BEGIN_COMPUTE_PASS",
        Cmd.SET_PIPELINE => "SET_PIPELINE",
        Cmd.SET_BIND_GROUP => "SET_BIND_GROUP",
        Cmd.SET_VERTEX_BUFFER => "SET_VERTEX_BUFFER",
        Cmd.DRAW => "DRAW",
        Cmd.DRAW_INDEXED => "DRAW_INDEXED",
        Cmd.END_PASS => "END_PASS",
        Cmd.DISPATCH => "DISPATCH",
        Cmd.SET_INDEX_BUFFER => "SET_INDEX_BUFFER",
        Cmd.EXECUTE_BUNDLES => "EXECUTE_BUNDLES",
        Cmd.WRITE_BUFFER => "WRITE_BUFFER",
        Cmd.WRITE_TIME_UNIFORM => "WRITE_TIME_UNIFORM",
        Cmd.COPY_BUFFER_TO_BUFFER => "COPY_BUFFER_TO_BUFFER",
        Cmd.COPY_TEXTURE_TO_TEXTURE => "COPY_TEXTURE_TO_TEXTURE",
        Cmd.WRITE_BUFFER_FROM_WASM => "WRITE_BUFFER_FROM_WASM",
        Cmd.COPY_EXTERNAL_IMAGE_TO_TEXTURE => "COPY_EXTERNAL_IMAGE_TO_TEXTURE",
        Cmd.INIT_WASM_MODULE => "INIT_WASM_MODULE",
        Cmd.CALL_WASM_FUNC => "CALL_WASM_FUNC",
        Cmd.CREATE_TYPED_ARRAY => "CREATE_TYPED_ARRAY",
        Cmd.FILL_RANDOM => "FILL_RANDOM",
        Cmd.FILL_EXPRESSION => "FILL_EXPRESSION",
        Cmd.FILL_CONSTANT => "FILL_CONSTANT",
        Cmd.WRITE_BUFFER_FROM_ARRAY => "WRITE_BUFFER_FROM_ARRAY",
        Cmd.SUBMIT => "SUBMIT",
        Cmd.END => "END",
        else => "UNKNOWN",
    };
}

/// Get command size (opcode + parameters).
fn cmdSize(cmd: u8) usize {
    return switch (cmd) {
        Cmd.CREATE_BUFFER => 1 + 2 + 4 + 1, // id(2) + size(4) + usage(1)
        Cmd.CREATE_TEXTURE, Cmd.CREATE_SAMPLER, Cmd.CREATE_SHADER => 1 + 2 + 4 + 4,
        Cmd.CREATE_RENDER_PIPELINE, Cmd.CREATE_COMPUTE_PIPELINE => 1 + 2 + 4 + 4,
        Cmd.CREATE_QUERY_SET, Cmd.CREATE_BIND_GROUP_LAYOUT => 1 + 2 + 4 + 4,
        Cmd.CREATE_PIPELINE_LAYOUT, Cmd.CREATE_RENDER_BUNDLE => 1 + 2 + 4 + 4,
        Cmd.CREATE_BIND_GROUP => 1 + 2 + 2 + 4 + 4,
        Cmd.CREATE_TEXTURE_VIEW => 1 + 2 + 2 + 4 + 4,
        Cmd.CREATE_IMAGE_BITMAP => 1 + 2 + 4 + 4,
        Cmd.BEGIN_RENDER_PASS => 1 + 2 + 1 + 1 + 2,
        Cmd.BEGIN_COMPUTE_PASS, Cmd.END_PASS, Cmd.SUBMIT, Cmd.END => 1,
        Cmd.SET_PIPELINE => 1 + 2,
        Cmd.SET_BIND_GROUP, Cmd.SET_VERTEX_BUFFER => 1 + 1 + 2,
        Cmd.DRAW => 1 + 4 + 4 + 4 + 4,
        Cmd.DRAW_INDEXED => 1 + 4 + 4 + 4 + 4 + 4,
        Cmd.DISPATCH => 1 + 4 + 4 + 4,
        Cmd.SET_INDEX_BUFFER => 1 + 2 + 1,
        Cmd.WRITE_BUFFER, Cmd.WRITE_BUFFER_FROM_WASM => 1 + 2 + 4 + 4 + 4,
        Cmd.WRITE_TIME_UNIFORM => 1 + 2 + 4 + 2,
        Cmd.COPY_EXTERNAL_IMAGE_TO_TEXTURE => 1 + 2 + 2 + 1 + 2 + 2,
        Cmd.INIT_WASM_MODULE => 1 + 2 + 4 + 4,
        Cmd.CALL_WASM_FUNC => 1 + 2 + 2 + 4 + 4 + 4 + 4,
        else => 1,
    };
}
