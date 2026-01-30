//! PNGine Desktop Viewer
//!
//! A native viewer for PNGine payloads that runs embedded WASM executors
//! via WAMR and traces command buffers. GPU rendering via Dawn/Mach is TODO.
//!
//! ## Architecture
//!
//! ```
//! PNG/PNGB File
//!     |
//!     v
//! [Extract Payload]  -- pngine.format + pngine.png.extract
//!     |
//!     v
//! [Load Executor]    -- WAMR runtime (interpreter or AOT)
//!     |
//!     v
//! [Copy Bytecode]    -- executor.getBytecodePtr()
//!     |
//!     v
//! [Init + Frame]     -- executor.init(), executor.frame()
//!     |
//!     v
//! [Command Buffer]   -- executor.getCommandPtr(), getCommandLen()
//!     |
//!     v
//! [GPU Backend]      -- Runner (trace/Dawn/Mach)
//! ```
//!
//! ## Usage
//!
//! ```
//! desktop-viewer <input.png>          # Run with trace output
//! desktop-viewer <input.png> --trace  # Explicit trace mode
//! desktop-viewer --help               # Show usage
//! ```

const std = @import("std");
const builtin = @import("builtin");

// Import pngine library for format parsing
const pngine = @import("pngine");
const format = pngine.format;

// Import WAMR wrapper
const wamr = @import("wamr");
const WamrRuntime = wamr.WamrRuntime;
const WamrError = wamr.WamrError;

// Command buffer runner (local)
const Runner = @import("runner.zig").Runner;
const Cmd = @import("runner.zig").Cmd;

/// Command line options
const Options = struct {
    input_path: []const u8,
    width: u32 = 512,
    height: u32 = 512,
    time: f32 = 0.0,
    trace_only: bool = true, // Default to trace mode (no GPU backend yet)
    help: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = std.process.Environ.empty,
        .argv0 = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    // Parse command line
    const opts = try parseArgs(allocator);
    defer allocator.free(opts.input_path);

    if (opts.help) {
        printUsage();
        return;
    }

    // Check WAMR availability
    if (!WamrRuntime.isAvailable()) {
        std.debug.print("Error: WAMR not available. Rebuild with WAMR support.\n", .{});
        std.process.exit(1);
    }
    std.debug.print("WAMR version: {s}\n", .{WamrRuntime.version()});

    // Run the viewer
    run(allocator, io, opts) catch |err| {
        std.debug.print("Error: {}\n", .{err});
        std.process.exit(1);
    };
}

fn run(allocator: std.mem.Allocator, io: std.Io, opts: Options) !void {
    // Load input file
    const file_data = try io.cwd().readFileAlloc(io, opts.input_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(file_data);

    std.debug.print("Loaded {s}: {} bytes\n", .{ opts.input_path, file_data.len });

    // Extract bytecode (handles PNG or raw PNGB)
    const bytecode = try extractBytecode(allocator, file_data);
    defer allocator.free(bytecode);

    std.debug.print("Bytecode: {} bytes\n", .{bytecode.len});

    // Parse header to check for embedded executor
    if (bytecode.len < format.HEADER_SIZE) {
        return error.InvalidBytecode;
    }

    const header: *const format.Header = @ptrCast(@alignCast(bytecode.ptr));
    try header.validate();

    std.debug.print("PNGB v{}, flags: embedded={}\n", .{ header.version, header.flags.has_embedded_executor });

    // Check for embedded executor
    if (!header.hasEmbeddedExecutor()) {
        std.debug.print("Error: No embedded executor in payload\n", .{});
        return error.NoEmbeddedExecutor;
    }

    std.debug.print("Embedded executor: offset={}, len={}\n", .{ header.executor_offset, header.executor_length });

    // Extract executor WASM
    const executor_wasm = bytecode[header.executor_offset..][0..header.executor_length];

    // Initialize WAMR runtime (256KB stack, 256KB heap)
    var runtime = try WamrRuntime.init(allocator, 256 * 1024, 256 * 1024);
    defer runtime.deinit();

    // Load executor WASM
    try runtime.loadModule(executor_wasm);

    // Link log function - required by executor
    runtime.linkLogFunction() catch |err| {
        std.debug.print("linkLogFunction failed: {}\n", .{err});
    };

    std.debug.print("WASM module loaded\n", .{});

    // Get WASM memory info
    const mem = try runtime.getMemory();
    std.debug.print("WASM memory size: {} bytes\n", .{mem.len});

    // Get bytecode pointer and copy full payload
    const bytecode_ptr = try runtime.callGetPtr("getBytecodePtr");
    std.debug.print("getBytecodePtr returned: 0x{x:0>8}\n", .{bytecode_ptr});

    // Check if bytecode fits in memory
    if (bytecode_ptr + bytecode.len > mem.len) {
        std.debug.print("ERROR: bytecode ({} bytes) doesn't fit at 0x{x:0>8} in {} byte memory\n", .{ bytecode.len, bytecode_ptr, mem.len });
        return error.MemoryAccessFailed;
    }

    try runtime.writeMemory(bytecode_ptr, bytecode);
    try runtime.callSetLen("setBytecodeLen", @intCast(bytecode.len));

    std.debug.print("Bytecode copied to WASM memory at 0x{x:0>8}\n", .{bytecode_ptr});

    // Copy data section to WASM memory
    const data_ptr = runtime.callGetPtr("getDataPtr") catch |err| {
        std.debug.print("getDataPtr failed: {}\n", .{err});
        return error.InitFailed;
    };
    const data_offset = header.data_section_offset;
    const data_end: u32 = if (header.wgsl_table_offset > 0)
        header.wgsl_table_offset
    else
        @intCast(bytecode.len);

    if (data_end > data_offset) {
        const data_section = bytecode[data_offset..data_end];
        try runtime.writeMemory(data_ptr, data_section);
        try runtime.callSetLen("setDataLen", @intCast(data_section.len));
        std.debug.print("Data section copied: {} bytes at 0x{x:0>8}\n", .{ data_section.len, data_ptr });
    }

    // Call init()
    std.debug.print("Calling init()...\n", .{});
    const init_result = runtime.callInit() catch |err| {
        std.debug.print("init() call failed: {}\n", .{err});
        return error.InitFailed;
    };
    if (init_result != 0) {
        std.debug.print("Error: init() returned {}\n", .{init_result});
        return error.InitFailed;
    }

    std.debug.print("init() succeeded\n", .{});

    // Get init command buffer
    const init_cmd_ptr = try runtime.callGetPtr("getCommandPtr");
    const init_cmd_len = try runtime.callGetPtr("getCommandLen");

    std.debug.print("Init command buffer: ptr=0x{x:0>8}, len={}\n", .{ init_cmd_ptr, init_cmd_len });

    if (init_cmd_len > 0) {
        const init_cmd_buf = try runtime.readMemory(init_cmd_ptr, init_cmd_len);
        if (opts.trace_only) {
            traceCommandBuffer(init_cmd_buf, "init");
        } else {
            var runner = Runner.init(allocator, opts.width, opts.height);
            defer runner.deinit();
            try runner.execute(init_cmd_buf);
        }
    }

    // Call frame()
    const frame_result = try runtime.callFrame(opts.time, opts.width, opts.height);
    if (frame_result != 0) {
        std.debug.print("Warning: frame() returned {}\n", .{frame_result});
    }

    // Get frame command buffer
    const frame_cmd_ptr = try runtime.callGetPtr("getCommandPtr");
    const frame_cmd_len = try runtime.callGetPtr("getCommandLen");

    std.debug.print("Frame command buffer: ptr=0x{x:0>8}, len={}\n", .{ frame_cmd_ptr, frame_cmd_len });

    if (frame_cmd_len > 0) {
        const frame_cmd_buf = try runtime.readMemory(frame_cmd_ptr, frame_cmd_len);
        if (opts.trace_only) {
            traceCommandBuffer(frame_cmd_buf, "frame");
        } else {
            var runner = Runner.init(allocator, opts.width, opts.height);
            defer runner.deinit();
            try runner.execute(frame_cmd_buf);
        }
    }

    std.debug.print("Done!\n", .{});
}

/// Extract bytecode from PNG or return raw PNGB.
fn extractBytecode(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Check if it's a PNG (magic: 0x89 P N G)
    if (data.len >= 8 and std.mem.eql(u8, data[0..4], &.{ 0x89, 0x50, 0x4E, 0x47 })) {
        // Extract from PNG
        const result = pngine.png.extract.extract(allocator, data) catch {
            return error.ExtractionFailed;
        };
        return result;
    }

    // Check if it's raw PNGB
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], format.MAGIC)) {
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return copy;
    }

    return error.UnknownFormat;
}

/// Print command buffer trace.
fn traceCommandBuffer(buf: []const u8, phase: []const u8) void {
    if (buf.len < 8) {
        std.debug.print("[{s}] Command buffer too short\n", .{phase});
        return;
    }

    const total_len = std.mem.readInt(u32, buf[0..4], .little);
    const cmd_count = std.mem.readInt(u16, buf[4..6], .little);
    const flags = std.mem.readInt(u16, buf[6..8], .little);

    std.debug.print("[{s}] Command buffer: len={}, commands={}, flags=0x{x:0>4}\n", .{
        phase,
        total_len,
        cmd_count,
        flags,
    });

    var pos: usize = 8;
    var cmd_idx: u16 = 0;

    // Bounded loop
    const max_cmds: u32 = 4096;
    for (0..max_cmds) |_| {
        if (cmd_idx >= cmd_count or pos >= buf.len) break;

        const cmd = buf[pos];
        const cmd_name = cmdName(cmd);
        const cmd_size = cmdSize(cmd);
        std.debug.print("  [{d:>3}] 0x{x:0>2} {s}\n", .{ cmd_idx, cmd, cmd_name });

        pos += cmd_size;
        cmd_idx += 1;

        if (cmd == Cmd.END) break;
    }
}

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
        Cmd.BEGIN_RENDER_PASS => "BEGIN_RENDER_PASS",
        Cmd.BEGIN_COMPUTE_PASS => "BEGIN_COMPUTE_PASS",
        Cmd.SET_PIPELINE => "SET_PIPELINE",
        Cmd.SET_BIND_GROUP => "SET_BIND_GROUP",
        Cmd.SET_VERTEX_BUFFER => "SET_VERTEX_BUFFER",
        Cmd.DRAW => "DRAW",
        Cmd.DRAW_INDEXED => "DRAW_INDEXED",
        Cmd.END_PASS => "END_PASS",
        Cmd.DISPATCH => "DISPATCH",
        Cmd.WRITE_BUFFER => "WRITE_BUFFER",
        Cmd.WRITE_TIME_UNIFORM => "WRITE_TIME_UNIFORM",
        Cmd.INIT_WASM_MODULE => "INIT_WASM_MODULE",
        Cmd.CALL_WASM_FUNC => "CALL_WASM_FUNC",
        Cmd.SUBMIT => "SUBMIT",
        Cmd.END => "END",
        else => "UNKNOWN",
    };
}

fn cmdSize(cmd: u8) usize {
    return switch (cmd) {
        Cmd.CREATE_BUFFER => 1 + 2 + 4 + 1,
        Cmd.CREATE_TEXTURE, Cmd.CREATE_SAMPLER, Cmd.CREATE_SHADER => 1 + 2 + 4 + 4,
        Cmd.CREATE_RENDER_PIPELINE, Cmd.CREATE_COMPUTE_PIPELINE => 1 + 2 + 4 + 4,
        Cmd.CREATE_BIND_GROUP => 1 + 2 + 2 + 4 + 4,
        Cmd.CREATE_TEXTURE_VIEW => 1 + 2 + 2 + 4 + 4,
        Cmd.BEGIN_RENDER_PASS => 1 + 2 + 1 + 1 + 2,
        Cmd.BEGIN_COMPUTE_PASS, Cmd.END_PASS, Cmd.SUBMIT, Cmd.END => 1,
        Cmd.SET_PIPELINE => 1 + 2,
        Cmd.SET_BIND_GROUP, Cmd.SET_VERTEX_BUFFER => 1 + 1 + 2,
        Cmd.DRAW => 1 + 4 + 4 + 4 + 4,
        Cmd.DRAW_INDEXED => 1 + 4 + 4 + 4 + 4 + 4,
        Cmd.DISPATCH => 1 + 4 + 4 + 4,
        Cmd.WRITE_BUFFER => 1 + 2 + 4 + 4 + 4,
        Cmd.WRITE_TIME_UNIFORM => 1 + 2 + 4 + 2,
        Cmd.INIT_WASM_MODULE => 1 + 2 + 4 + 4,
        Cmd.CALL_WASM_FUNC => 1 + 2 + 2 + 4 + 4 + 4 + 4,
        else => 1,
    };
}

fn parseArgs(allocator: std.mem.Allocator) !Options {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    var opts = Options{
        .input_path = "",
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            opts.trace_only = true;
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            opts.width = try std.fmt.parseInt(u32, arg["--width=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--height=")) {
            opts.height = try std.fmt.parseInt(u32, arg["--height=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--time=")) {
            opts.time = try std.fmt.parseFloat(f32, arg["--time=".len..]);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            opts.input_path = try allocator.dupe(u8, arg);
        }
    }

    if (opts.input_path.len == 0 and !opts.help) {
        printUsage();
        std.process.exit(1);
    }

    return opts;
}

fn printUsage() void {
    std.debug.print(
        \\PNGine Desktop Viewer
        \\
        \\Usage: desktop-viewer <input.png> [options]
        \\
        \\Options:
        \\  --trace          Print command buffer trace (default, no GPU)
        \\  --width=N        Canvas width (default: 512)
        \\  --height=N       Canvas height (default: 512)
        \\  --time=T         Time value in seconds (default: 0.0)
        \\  -h, --help       Show this help
        \\
        \\Example:
        \\  desktop-viewer triangle-embedded.png
        \\  desktop-viewer triangle-embedded.png --width=1024 --height=768
        \\
    , .{});
}
