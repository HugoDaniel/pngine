//! WASM Executor Entry Point
//!
//! Minimal WASM module that executes PNGB bytecode and outputs a command buffer.
//! Designed for embedding in PNG payloads with plugin-based conditional compilation.
//!
//! ## Design
//!
//! - Static allocation: All buffers pre-allocated, no malloc after init
//! - Command buffer output: Executor writes platform-agnostic GPU commands
//! - Plugin-aware: Code size varies based on enabled plugins
//! - Zero host imports by default: the one optional import (`env.log`) is
//!   compiled in only under `-Ddebug-log`; a release build declares no imports
//!
//! ## Memory Layout
//!
//! ```
//! WASM Linear Memory (2MB default):
//! ┌─────────────────────────────────────────┐
//! │ Bytecode Buffer (256KB)                 │ ← Host writes here
//! ├─────────────────────────────────────────┤
//! │ Data Section Buffer (512KB)             │ ← Host writes here
//! ├─────────────────────────────────────────┤
//! │ Command Buffer (64KB)                   │ ← Executor writes here
//! ├─────────────────────────────────────────┤
//! │ Scratch Space (remaining)               │ ← Internal use
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Exports
//!
//! - `init()`: Parse bytecode, emit resource creation commands
//! - `frame(time, width, height)`: Emit per-frame commands
//! - `getCommandPtr()` / `getCommandLen()`: Read command buffer
//! - `getBytecodePtr()` / `setBytecodeLen()`: Write bytecode
//! - `getDataPtr()` / `setDataLen()`: Write data section
//!
//! ## Invariants
//!
//! - Bytecode must be written before init() is called
//! - Data section must be written before init() is called
//! - Command buffer is valid until next init() or frame() call

const std = @import("std");
const builtin = @import("builtin");
const plugins = @import("executor/plugins.zig");
/// Which plugins this executor was compiled with. `pub` so the decode
/// characterization suite can pick the matching expected dump: the same test
/// file runs against both the all-plugins and the core-only build, and a
/// disabled plugin emits no command at all for its opcodes.
pub const plugin_options = plugins.options;
const command_buffer = @import("executor/command_buffer.zig");
pub const CommandBuffer = command_buffer.CommandBuffer; // pub for wire conformance
const Cmd = command_buffer.Cmd;

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;
const wire_schema = bytecode_mod.wire_schema;
const ColorAttachment = bytecode_mod.emitter.Emitter.ColorAttachment;

// ============================================================================
// Configuration (overridable via "wasm_config" build option module)
// ============================================================================

/// Buffer size configuration. Defaults are used when no "wasm_config" module
/// is provided by the build system. The micro build (`zig build wasm-micro`)
/// overrides these with smaller values for size-coding.
const wasm_config = struct {
    const cfg = @import("wasm_config");
    pub const max_bytecode_kb: u32 = if (@hasDecl(cfg, "max_bytecode_kb")) cfg.max_bytecode_kb else 256;
    pub const max_data_kb: u32 = if (@hasDecl(cfg, "max_data_kb")) cfg.max_data_kb else 512;
    pub const command_buffer_kb: u32 = if (@hasDecl(cfg, "command_buffer_kb")) cfg.command_buffer_kb else 64;
    pub const max_wgsl_modules: u32 = if (@hasDecl(cfg, "max_wgsl_modules")) cfg.max_wgsl_modules else 64;
    pub const max_passes: u32 = if (@hasDecl(cfg, "max_passes")) cfg.max_passes else bytecode_mod.DEFAULT_MAX_PASSES;
    /// Compile the `dbg()` debug-logging sites (and the `env.log` import they
    /// use). Off by default: shipping executors carry zero host imports and
    /// none of `std.fmt`'s formatting code. Turn on with `-Ddebug-log` for the
    /// dev/playground executor (`zig build web`). Keeping this comptime-false by
    /// default is also what lets wasm_entry.zig link on a *native* test target
    /// (the 1.2 wire-conformance suite): with the log sites pruned, `log` is
    /// unreferenced, so there is no `extern "env"` symbol for a native linker
    /// to resolve.
    pub const debug_log: bool = if (@hasDecl(cfg, "debug_log")) cfg.debug_log else false;
};

/// Maximum bytecode size.
const MAX_BYTECODE_SIZE: u32 = wasm_config.max_bytecode_kb * 1024;

/// Maximum data section size.
const MAX_DATA_SIZE: u32 = wasm_config.max_data_kb * 1024;

/// Command buffer capacity.
const COMMAND_BUFFER_SIZE: u32 = wasm_config.command_buffer_kb * 1024;

/// Maximum WGSL modules for resolution.
const MAX_WGSL_MODULES: u32 = wasm_config.max_wgsl_modules;

/// Maximum passes that can be defined. A define_pass whose id is >= this stores
/// no range (executeResourceCreation), so the pass is silently dropped at load.
/// `pub` so the pass-cap pin (tests/zig/executor/wasm_entry_pass_cap_test.zig)
/// reads the real cap the emitter must mirror.
pub const MAX_PASSES: u32 = wasm_config.max_passes;

/// Maximum iterations for bytecode execution (safety bound).
/// Must be >= bytecode size to handle 1-byte opcodes worst case.
const MAX_EXEC_ITERATIONS: u32 = MAX_BYTECODE_SIZE;

/// Element caps for the two count-prefixed opcodes this file decodes by hand,
/// taken from the wire schema rather than re-typed — `repMaxOf` explains why a
/// consumer that picks its own number desyncs the stream instead of clamping.
const MAX_MRT: u8 = @intCast(wire_schema.repMaxOf(.begin_render_pass_mrt));
const MAX_WASM_ARGS: u8 = @intCast(wire_schema.repMaxOf(.call_wasm_func));
const MAX_BUNDLES: u32 = wire_schema.repMaxOf(.execute_bundles);

// Compile-time invariants
comptime {
    const assert = std.debug.assert;
    // Command buffer must fit meaningful output.
    assert(COMMAND_BUFFER_SIZE >= 4096);
    // Bytecode buffer must hold at least header + minimal bytecode.
    assert(MAX_BYTECODE_SIZE >= format.HEADER_SIZE + 64);
    // Data section must accommodate typical shader code.
    assert(MAX_DATA_SIZE >= 8192);
    // Execution bound must handle worst-case 1-byte opcodes.
    assert(MAX_EXEC_ITERATIONS >= MAX_BYTECODE_SIZE);
}

// ============================================================================
// Static Buffers (No Malloc)
// ============================================================================

/// Bytecode buffer - host writes here via getBytecodePtr().
var bytecode_buffer: [MAX_BYTECODE_SIZE]u8 = undefined;
var bytecode_len: u32 = 0;

/// Data section buffer - host writes here via getDataPtr().
var data_buffer: [MAX_DATA_SIZE]u8 = undefined;
var data_len: u32 = 0;

/// Command buffer - executor writes here, host reads via getCommandPtr().
var cmd_buffer: [COMMAND_BUFFER_SIZE]u8 = undefined;

/// Executor state.
var initialized: bool = false;
var frame_counter: u32 = 0;
var resources_created: bool = false;

/// Latched by `narrowId` when a decoded id operand exceeds the u16 resource-table
/// width. The emitter never emits an id past u16, so a larger value is a hostile
/// or corrupt stream; init()/frame() report it as a nonzero status (surfaced by
/// the host as an onError) rather than build a command buffer that addresses a
/// wrong-but-valid resource. Reset at the top of init() and every frame().
/// (Arc-3 §5.4)
var malformed_body: bool = false;

/// Pass definition storage.
/// Stores bytecode ranges for pass bodies (between define_pass and end_pass_def).
/// pass_ranges[pass_id] = { start_pc, end_pc } relative to bytecode_start.
const PassRange = struct {
    start: u32,
    end: u32,
};
var pass_ranges: [MAX_PASSES]PassRange = [_]PassRange{.{ .start = 0, .end = 0 }} ** MAX_PASSES;
var pass_count: u32 = 0;

/// Which passes an `exec_pass_once` has already run, per pass id, for the life
/// of the loaded payload. Cleared by `init()` — a reload re-arms every init
/// pass, and nothing else does.
///
/// This used to be keyed off `frame_counter == 0` instead, which is a different
/// property in three observable ways (docs/abi.md §7): `setFrameCounter(0)` —
/// what a thumbnail restore hands back before the first live frame — re-ran
/// every init pass; duplicated `:init` entries ran once *each*, because nothing
/// recorded that the pass had gone; and a counter driven forward before the
/// first frame skipped them permanently. The reference dispatcher always keyed
/// per pass id (`Dispatcher.executed_once`); this is the executors agreeing.
///
/// Static allocation, like everything else here: one bool per pass slot.
var pass_executed_once: [MAX_PASSES]bool = @splat(false);

// Parsed module info (cached after init)
var string_table_offset: u32 = 0;
var string_table_len: u32 = 0;
var data_section_offset: u32 = 0;
var data_section_len: u32 = 0;
var bytecode_start: u32 = 0;
var bytecode_end: u32 = 0;

/// True if data section is in bytecode_buffer (embedded executor mode).
/// False if data section is in separate data_buffer (shared executor mode).
var data_in_bytecode: bool = false;

// ============================================================================
// Animation State (Static Allocation)
// ============================================================================

/// Maximum scenes per animation.
const MAX_SCENES: u32 = 256;

/// Maximum frames that can be defined in bytecode.
const MAX_FRAMES: u32 = 64;

/// Scene data (without string table lookup - just IDs and time ranges).
const SceneEntry = struct {
    frame_string_id: u16,
    start_ms: u32,
    end_ms: u32,
};

/// Frame definition entry: maps frame name string ID to bytecode PC offset.
const FrameEntry = struct {
    name_string_id: u16,
    pc_offset: u32, // PC offset relative to bytecode_start (after define_frame params)
};

/// Animation metadata.
var anim_duration_ms: u32 = 0;
var anim_loop: bool = false;
var anim_end_behavior: u8 = 0; // 0=hold, 1=stop, 2=restart
var anim_scene_count: u32 = 0;
var anim_scenes: [MAX_SCENES]SceneEntry = undefined;

/// Frame definition table: maps frame_string_id to PC offset.
var frame_entries: [MAX_FRAMES]FrameEntry = undefined;
var frame_count: u32 = 0;

/// Whether animation table was successfully parsed.
var has_animation: bool = false;

// ============================================================================
// Host Imports (Minimal)
// ============================================================================

/// Optional debug logging. Referenced ONLY inside `dbg()`'s comptime-gated
/// block, so a release build (`debug_log == false`) drops this import entirely
/// and links natively. See wasm_config.debug_log and abi.md §3.
extern "env" fn log(ptr: [*]const u8, len: u32) void;

/// Format `fmt`/`args` and hand the bytes to the host `env.log` import.
/// Compiles to nothing unless the `debug_log` build option is set: the
/// `if (wasm_config.debug_log)` guard is a comptime-false const, so Zig prunes
/// the whole block from analysis — `std.fmt` and the `log` import go with it.
inline fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (wasm_config.debug_log) {
        var buf: [128]u8 = undefined;
        const written = std.fmt.bufPrint(&buf, fmt, args) catch return;
        log(written.ptr, @intCast(written.len));
    }
}

/// A pointer as the u32 address the command buffer stores. On wasm32 — the
/// shipping target — `usize` is u32, so this is identity. The truncate matters
/// only when wasm_entry.zig is compiled for a 64-bit host (the native
/// wire-conformance test, §221 item 1.2), where the stored address is written
/// into the command buffer but never dereferenced.
inline fn dataAddr(ptr: anytype) u32 {
    return @truncate(@intFromPtr(ptr));
}

// ============================================================================
// Exports - Memory Interface
// ============================================================================

/// Get pointer where host should write bytecode.
/// (`pub` for the native malformed-input suite; `export` already ships it.)
pub export fn getBytecodePtr() [*]u8 {
    return &bytecode_buffer;
}

/// Set bytecode length after host writes.
pub export fn setBytecodeLen(len: u32) void {
    bytecode_len = @min(len, MAX_BYTECODE_SIZE);
}

/// Get pointer where host should write data section.
export fn getDataPtr() [*]u8 {
    return &data_buffer;
}

/// Set data section length after host writes.
pub export fn setDataLen(len: u32) void {
    data_len = @min(len, MAX_DATA_SIZE);
}

/// Get pointer to command buffer output.
/// `pub` for the native executor-agreement test (LEAK-03) — visibility only,
/// the wasm export is unchanged.
pub export fn getCommandPtr() [*]const u8 {
    return &cmd_buffer;
}

/// Get command buffer length after init() or frame().
/// `pub` for the same reason as `getCommandPtr`.
pub export fn getCommandLen() u32 {
    return std.mem.readInt(u32, cmd_buffer[0..4], .little);
}

// ============================================================================
// Exports - Execution Interface
// ============================================================================

/// Initialize executor. Call after writing bytecode and data.
///
/// Parses the bytecode header and emits all resource creation commands
/// to the command buffer. Host should execute these commands to create
/// GPU resources before calling frame().
///
/// Returns: 0 on success, error code on failure (1 too short, 2 bad magic,
/// 3 unsupported version, 4 invalid section offsets).
/// Complexity: O(n) where n = bytecode size.
pub export fn init() u32 {
    const assert = std.debug.assert;

    // Pre-condition: bytecode was written by host.
    assert(bytecode_len <= MAX_BYTECODE_SIZE);

    // Reset state
    frame_counter = 0;
    resources_created = false;
    pass_count = 0;
    pass_executed_once = @splat(false);
    frame_count = 0;
    has_animation = false;
    anim_scene_count = 0;
    malformed_body = false;

    // Validate bytecode - need at least v0 header size
    if (bytecode_len < format.HEADER_SIZE) {
        return 1; // Invalid bytecode
    }

    // Parse header
    const header = bytecode_buffer[0..bytecode_len];
    if (!std.mem.eql(u8, header[0..4], "PNGB")) {
        return 2; // Invalid magic
    }

    const version = std.mem.readInt(u16, header[4..6], .little);
    if (version != format.VERSION) {
        return 3; // Unsupported version (only v0 supported)
    }

    // Check if payload has embedded executor (v0 format, flag bit 0)
    const flags = std.mem.readInt(u16, header[6..8], .little);
    const has_embedded_executor = (flags & 0x01) != 0;

    // Cache offsets for v0 format (40-byte header)
    if (has_embedded_executor) {
        // Embedded executor: bytecode starts after header + executor WASM
        const executor_offset = std.mem.readInt(u32, header[12..16], .little);
        const executor_length = std.mem.readInt(u32, header[16..20], .little);
        // Guard the u32 add explicitly: asserts are stripped in ReleaseSmall, so
        // a hostile executor_length could wrap this small and slip past the
        // ordering check below.
        const sum = @addWithOverflow(executor_offset, executor_length);
        if (sum[1] != 0) return 4; // executor offset+length overflows u32
        bytecode_start = sum[0];
    } else {
        // No embedded executor: bytecode starts right after header
        bytecode_start = format.HEADER_SIZE;
    }
    // If host pre-loaded data into data_buffer via setDataLen(), use split mode.
    // Otherwise, data section is in bytecode_buffer (legacy single-payload mode).
    data_in_bytecode = (data_len == 0);
    string_table_offset = std.mem.readInt(u32, header[20..24], .little);
    data_section_offset = std.mem.readInt(u32, header[24..28], .little);
    const wgsl_table_offset = std.mem.readInt(u32, header[28..32], .little);
    // Parse animation table offset (v0 header, byte 36) — validated below.
    const animation_table_offset = std.mem.readInt(u32, header[36..40], .little);

    // Validate section offsets BEFORE the subtractions/slices that follow. In
    // ReleaseSmall the post-condition asserts (:end of init) are stripped and
    // these subtractions/underflows would silently OOB-slice adjacent memory as
    // bytecode. Ascending order is a format invariant in BOTH payload modes: the
    // string table occupies [string_table_offset, data_section_offset) and the
    // data section [data_section_offset, wgsl_table_offset), so the two
    // subtractions underflow unless the offsets ascend. The upper bound is
    // mode-dependent — embedded mode holds every section in bytecode_buffer
    // (wgsl_table_offset ≤ bytecode_len); split mode loads the data section into
    // data_buffer and sets bytecode_len == data_section_offset, so only the
    // string table (always in bytecode_buffer) is bounded by bytecode_len while
    // the data section must fit in data_buffer.
    if (bytecode_start > string_table_offset or
        string_table_offset > data_section_offset or
        data_section_offset > wgsl_table_offset)
    {
        return 4; // non-ascending section offsets
    }
    if (data_in_bytecode) {
        if (wgsl_table_offset > bytecode_len) return 4; // section past buffer end
    } else {
        if (data_section_offset > bytecode_len) return 4; // string table past buffer
        if (wgsl_table_offset - data_section_offset > data_len) return 4; // data past data_buffer
    }

    bytecode_end = string_table_offset;
    string_table_len = data_section_offset - string_table_offset;
    // Data section ends where WGSL table begins (not at end of file)
    data_section_len = wgsl_table_offset - data_section_offset;

    parseAnimationTable(animation_table_offset);

    // Debug: log bytecode info
    const bc_len = bytecode_end -| bytecode_start;
    const first_byte: u8 = if (bc_len > 0) bytecode_buffer[bytecode_start] else 0;
    dbg("bc_start={d} bc_end={d} len={d} first=0x{x:0>2}", .{ bytecode_start, bytecode_end, bc_len, first_byte });

    // Execute resource creation phase
    var cmds = CommandBuffer.init(&cmd_buffer);
    executeResourceCreation(&cmds);
    _ = cmds.finish();

    // A resource-creation opcode carried an out-of-range id (only reachable from a
    // hostile/corrupt stream) — refuse the module rather than create resources
    // under a wrapped id. `initialized` stays false, so a host that ignores this
    // code still gets a loud frame() == 1.
    if (malformed_body) return 5; // out-of-range id in resource creation

    // The payload needs more resource-creation commands than the buffer holds.
    // Same verdict as above and for the same reason: a truncated init would
    // create SOME of the resources and leave every later id dangling, which
    // surfaces later as an unrelated GPU validation error. (LEAK-09 C)
    if (cmds.truncated) return 6; // command buffer overflowed

    // Build frame name → PC offset mapping for animation scene selection
    scanFrameDefinitions();

    // Post-condition: state is consistent.
    assert(bytecode_start <= bytecode_end);
    assert(bytecode_end <= bytecode_len);

    initialized = true;
    resources_created = true;
    return 0;
}

/// Render a frame. Call once per animation frame.
///
/// Updates uniforms with the provided time/dimensions and emits
/// frame rendering commands to the command buffer.
///
/// Parameters:
/// - time: Elapsed time in seconds
/// - width: Canvas width in pixels
/// - height: Canvas height in pixels
///
/// Returns: 0 on success, error code on failure.
/// Complexity: O(n) where n = frame bytecode size.
pub export fn frame(time: f32, width: u32, height: u32) u32 {
    const assert = std.debug.assert;

    // Pre-condition: must be initialized first.
    if (!initialized) {
        return 1; // Not initialized
    }

    // Pre-condition: dimensions are valid.
    assert(width > 0);
    assert(height > 0);

    malformed_body = false;
    var cmds = CommandBuffer.init(&cmd_buffer);
    executeFrame(&cmds, time, width, height);
    _ = cmds.finish();

    // Post-condition: frame counter advances.
    const prev_frame = frame_counter;
    frame_counter += 1;
    assert(frame_counter == prev_frame + 1);

    // A frame opcode carried an out-of-range id (hostile/corrupt stream only).
    // Report it so the host skips this frame's command buffer and surfaces an
    // onError, instead of executing commands that address wrapped ids.
    if (malformed_body) return 2; // out-of-range id in frame body

    // The frame wanted more commands than the buffer holds. The commands that
    // DID fit are whole and executable, but they are not the frame the payload
    // describes — a prefix ending mid-pass renders something nobody authored.
    // So: same shape as malformed_body, the host skips the buffer and reports.
    // (LEAK-09 C)
    if (cmds.truncated) return 3; // command buffer overflowed

    return 0;
}

/// Get current frame counter (for debugging/sync).
/// `pub` for the native executor-agreement test (LEAK-03); export unchanged.
pub export fn getFrameCounter() u32 {
    return frame_counter;
}

/// Restore a saved frame counter. The counter IS the ping-pong pool phase
/// (`actual_id = base + (frame_counter + offset) % pool_size`), so host-side
/// ephemeral renders (timeline thumbnails) save/restore around frame() to
/// stay side-effect-free (docs/abi.md §2).
///
/// Does not touch once-pass state — a promise this comment made long before it
/// was true. Once-ness lives in `pass_executed_once`, keyed per pass id and
/// cleared only by `init()`; restoring a saved counter of 0 used to re-arm
/// every init pass. (§347)
pub export fn setFrameCounter(n: u32) void {
    frame_counter = n;
}

/// ABI version of the executor↔host interface (docs/abi.md).
/// Binaries without this export are version 1; the host reads it via
/// `exports.getAbiVersion?.() ?? 1`. The interface is frozen append-only,
/// so this should stay at 1 — it exists as a diagnostic and escape hatch.
export fn getAbiVersion() u32 {
    return 1;
}

// ============================================================================
// Internal - Bytecode Execution
// ============================================================================

/// Execute resource creation opcodes (everything before first define_frame).
/// Also stores pass bytecode ranges for later replay via exec_pass.
fn executeResourceCreation(cmds: *CommandBuffer) void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];
    var pc: usize = 0;
    var op_count: u32 = 0;

    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;
        op_count += 1;

        // Debug: log each opcode
        dbg("op[{d}]=0x{x:0>2} pc={d}", .{ op_count, @intFromEnum(op), pc });

        // Stop at first frame definition
        if (op == .define_frame) break;

        // Handle define_pass: store range and skip to end_pass_def
        if (op == .define_pass) {
            const pass_id = read_varint(bytecode, &pc);
            _ = readByteClamped(bytecode, &pc); // pass_type (unused here)
            _ = read_varint(bytecode, &pc); // desc_id

            // Store pass body start (after define_pass params)
            const pass_start: u32 = @intCast(pc);

            // Scan for end_pass_def to find pass body end
            for (0..MAX_EXEC_ITERATIONS) |_| {
                if (pc >= bytecode.len) break;
                const inner_op: OpCode = @enumFromInt(bytecode[pc]);
                pc += 1;
                if (inner_op == .end_pass_def) break;
                skipOpcodeParams(bytecode, &pc, inner_op);
            }

            // Store pass range
            if (pass_id < MAX_PASSES) {
                pass_ranges[pass_id] = .{
                    .start = pass_start,
                    .end = @intCast(pc - 1), // Before end_pass_def opcode
                };
                if (pass_id >= pass_count) {
                    pass_count = pass_id + 1;
                }

                // Debug: log pass range
                dbg("pass[{d}] range={d}-{d}", .{ pass_id, pass_start, pc - 1 });
            }

            continue;
        }

        executeOpcode(cmds, bytecode, &pc, op);
    }

    // Log final command count
    dbg("cmds={d}", .{cmds.cmd_count});
}

/// Test-only: run `executeResourceCreation` over a raw opcode stream and report
/// how many pass ranges it stored. Drives the real >MAX_PASSES silent-drop
/// (item 1.5): a `define_pass` whose id is >= MAX_PASSES stores no range and is
/// lost at load. Pins the divergence that motivates the emitter's matching
/// >MAX_PASSES reject. `pub` for the pin test only — not an `export`, and
/// unreachable from any export, so it is dead-stripped from the shipping wasm.
pub fn passRangeCountForTest(raw_bytecode: []const u8, cmds: *CommandBuffer) u32 {
    std.debug.assert(raw_bytecode.len <= bytecode_buffer.len);
    @memcpy(bytecode_buffer[0..raw_bytecode.len], raw_bytecode);
    bytecode_start = 0;
    bytecode_end = @intCast(raw_bytecode.len);
    pass_count = 0;
    executeResourceCreation(cmds);
    return pass_count;
}

/// Execute frame opcodes.
/// If animation is defined, selects the appropriate scene based on time.
fn executeFrame(cmds: *CommandBuffer, time: f32, width: u32, height: u32) void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];

    // Convert time to milliseconds for scene lookup
    const time_ms: u32 = @intFromFloat(@max(0.0, time * 1000.0));

    // Try to find the appropriate frame for this time
    var pc: usize = 0;
    var found_frame = false;

    // If animation is defined, select scene by time
    if (has_animation) {
        if (findSceneAtTime(time_ms)) |scene_idx| {
            const scene = anim_scenes[scene_idx];
            if (findFramePcByStringId(scene.frame_string_id)) |frame_pc| {
                // Found the frame for this scene
                pc = frame_pc;
                found_frame = true;

                // Debug: log scene selection
                dbg("t={d}ms scene={d} frame_id={d} pc={d}", .{ time_ms, scene_idx, scene.frame_string_id, pc });
            }
        }
    }

    // Fallback: find first frame if no animation or scene not found
    if (!found_frame) {
        for (0..MAX_EXEC_ITERATIONS) |_| {
            if (pc >= bytecode.len) break;

            const op: OpCode = @enumFromInt(bytecode[pc]);
            pc += 1;

            if (op == .define_frame) {
                // Skip frame_id and name_id
                _ = read_varint(bytecode, &pc);
                _ = read_varint(bytecode, &pc);
                break;
            }

            skipOpcodeParams(bytecode, &pc, op);
        }
    }

    // Execute frame body
    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .end_frame) break;

        // Handle exec_pass: replay stored pass bytecode
        if (op == .exec_pass) {
            const pass_id = read_varint(bytecode, &pc);
            if (pass_id < pass_count) {
                const range = pass_ranges[pass_id];
                executePassBody(cmds, bytecode, range.start, range.end);
            }
            continue;
        }

        // Handle exec_pass_once: run an init pass once per loaded payload.
        // Keyed per pass id, NOT off frame_counter — see `pass_executed_once`.
        if (op == .exec_pass_once) {
            const pass_id = read_varint(bytecode, &pc);
            if (pass_id < pass_count and !pass_executed_once[pass_id]) {
                pass_executed_once[pass_id] = true;
                const range = pass_ranges[pass_id];
                executePassBody(cmds, bytecode, range.start, range.end);
            }
            continue;
        }

        // Handle time uniform specially
        if (op == .write_time_uniform) {
            const buffer_id = read_varint(bytecode, &pc);
            const offset = read_varint(bytecode, &pc);
            const size = read_varint(bytecode, &pc);
            _ = size;
            _ = width;
            _ = height;
            cmds.writeTimeUniform(narrowId(buffer_id), @intCast(offset), 16);
            continue;
        }

        // Handle pointer uniform specially
        if (op == .write_pointer_uniform) {
            const buffer_id = read_varint(bytecode, &pc);
            const offset = read_varint(bytecode, &pc);
            const size = read_varint(bytecode, &pc);
            cmds.writePointerUniform(narrowId(buffer_id), @intCast(offset), @intCast(size));
            continue;
        }

        executeOpcode(cmds, bytecode, &pc, op);
    }
}

/// Execute a stored pass body (between define_pass params and end_pass_def).
fn executePassBody(cmds: *CommandBuffer, bytecode: []const u8, start: u32, end: u32) void {
    var pc: usize = start;
    const end_pc: usize = end;

    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= end_pc or pc >= bytecode.len) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        // Skip pass structure opcodes (we're inside the pass body)
        if (op == .end_pass_def) break;

        executeOpcode(cmds, bytecode, &pc, op);
    }
}

/// Execute a single opcode. Dispatches to plugin-specific handlers.
/// Complexity: O(1) for most opcodes.
pub fn executeOpcode(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void { // pub for wire conformance
    switch (op) {
        // Core plugin (always enabled)
        .create_buffer,
        .create_shader_module,
        .create_sampler,
        .create_bind_group,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_query_set,
        .write_buffer,
        .copy_buffer_to_buffer,
        .resolve_query_set,
        .submit,
        => execCore(cmds, bytecode, pc, op),

        // Render plugin
        .create_render_pipeline,
        .begin_render_pass,
        .begin_render_pass_mrt,
        .set_pipeline,
        .set_bind_group,
        .set_vertex_buffer,
        .set_index_buffer,
        .draw,
        .draw_indexed,
        .draw_indirect,
        .draw_indexed_indirect,
        .set_viewport,
        .set_stencil_reference,
        .set_scissor_rect,
        .set_blend_constant,
        .set_pass_occlusion_query_set,
        .set_pass_timestamp_writes,
        .set_pass_depth_stencil_ops,
        .set_pass_clear_values,
        .begin_occlusion_query,
        .end_occlusion_query,
        .end_pass,
        .create_render_bundle,
        .execute_bundles,
        => execRender(cmds, bytecode, pc, op),

        // Compute plugin
        .create_compute_pipeline,
        .begin_compute_pass,
        .dispatch,
        .dispatch_indirect,
        => execCompute(cmds, bytecode, pc, op),

        // Texture plugin
        .create_texture,
        .create_texture_view,
        .create_image_bitmap,
        .copy_texture_to_texture,
        .copy_external_image_to_texture,
        => execTexture(cmds, bytecode, pc, op),

        // WASM plugin
        .init_wasm_module,
        .call_wasm_func,
        .write_buffer_from_wasm,
        => execWasm(cmds, bytecode, pc, op),

        // Pool operations (render/compute - use frame_counter for selection)
        .set_vertex_buffer_pool,
        .set_bind_group_pool,
        .begin_render_pass_pool,
        => execPool(cmds, bytecode, pc, op),

        // Pass/Frame structure and ignored opcodes
        .define_pass,
        .define_frame,
        .end_pass_def,
        .end_frame,
        .exec_pass,
        .exec_pass_once,
        .nop,
        .create_shader_concat,
        .write_uniform,
        .write_time_uniform,
        .write_pointer_uniform,
        .write_audio_data,
        .select_from_pool,
        => skipOpcodeParams(bytecode, pc, op),

        _ => {}, // Unknown opcode
    }
}

// ============================================================================
// Plugin Handlers - Core (Always Enabled)
// ============================================================================

/// Handle core plugin opcodes: buffer, shader, sampler, bind group, submit.
/// Handle core plugin opcodes (always enabled). Routes to resource-creation vs
/// data/queue sub-handlers to stay within the ≤70-line budget (item 4.1); the
/// decode of each opcode is byte-for-byte unchanged.
fn execCore(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_buffer,
        .create_shader_module,
        .create_sampler,
        .create_bind_group,
        .create_bind_group_layout,
        .create_pipeline_layout,
        .create_query_set,
        => execCoreCreate(cmds, bytecode, pc, op),
        .write_buffer,
        .copy_buffer_to_buffer,
        .resolve_query_set,
        .submit,
        => execCoreData(cmds, bytecode, pc, op),
        else => {},
    }
}

/// Core resource-creation opcodes: buffer, shader, sampler, bind group[/layout],
/// pipeline layout, query set — each decodes an id (+ layout/desc data) → a
/// create call.
fn execCoreCreate(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .create_buffer => {
            const o = readOps(.create_buffer, bytecode, pc);
            const usage: u16 = @as(u16, o.usage_lo) | (@as(u16, o.usage_hi) << 8);
            cmds.createBuffer(narrowId(o.buffer_id), @intCast(o.size), usage);
        },
        .create_shader_module => {
            const o = readOps(.create_shader_module, bytecode, pc);
            const data = getDataSlice(narrowId(o.v1));
            cmds.createShader(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
        },
        .create_sampler => {
            const o = readOps(.create_sampler, bytecode, pc);
            const data = getDataSlice(narrowId(o.v1));
            cmds.createSampler(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
        },
        .create_bind_group => {
            const o = readOps(.create_bind_group, bytecode, pc);
            const data = getDataSlice(narrowId(o.v2));
            cmds.createBindGroup(narrowId(o.v0), narrowId(o.v1), dataAddr(data.ptr), @intCast(data.len));
        },
        .create_bind_group_layout => {
            const o = readOps(.create_bind_group_layout, bytecode, pc);
            const data = getDataSlice(narrowId(o.v1));
            cmds.createBindGroupLayout(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
        },
        .create_pipeline_layout => {
            const o = readOps(.create_pipeline_layout, bytecode, pc);
            const data = getDataSlice(narrowId(o.v1));
            cmds.createPipelineLayout(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
        },
        .create_query_set => {
            const o = readOps(.create_query_set, bytecode, pc);
            const data = getDataSlice(narrowId(o.v1));
            cmds.createQuerySet(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Core data/queue opcodes: write_buffer, copy_buffer_to_buffer,
/// resolve_query_set, submit.
fn execCoreData(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .write_buffer => {
            const o = readOps(.write_buffer, bytecode, pc);
            const data = getDataSlice(narrowId(o.v2));
            cmds.writeBuffer(narrowId(o.v0), @intCast(o.v1), dataAddr(data.ptr), @intCast(data.len));
        },
        .copy_buffer_to_buffer => {
            const o = readOps(.copy_buffer_to_buffer, bytecode, pc);
            cmds.copyBufferToBuffer(narrowId(o.v0), @intCast(o.v1), narrowId(o.v2), @intCast(o.v3), @intCast(o.v4));
        },
        .resolve_query_set => {
            const o = readOps(.resolve_query_set, bytecode, pc);
            cmds.resolveQuerySet(narrowId(o.v0), @intCast(o.v1), @intCast(o.v2), narrowId(o.v3), @intCast(o.v4));
        },
        .submit => cmds.submit(),
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

// ============================================================================
// Plugin Handlers - Render
// ============================================================================

/// Handle render plugin opcodes: pipeline, pass, draw commands.
/// Handle render plugin opcodes. Routes each render-family opcode to a
/// sub-family handler grouped by WebGPU render-pass-encoder concept
/// (pipeline / pass / bind / draw / viewport / query), keeping every handler
/// within the ≤70-line mastery budget. Each opcode's decode is byte-for-byte
/// unchanged — only the dispatch is grouped (item 4.1).
fn execRender(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_render_pipeline, .create_render_bundle, .execute_bundles => execRenderPipeline(cmds, bytecode, pc, op),
        .begin_render_pass, .begin_render_pass_mrt, .end_pass => execRenderPass(cmds, bytecode, pc, op),
        .set_pipeline, .set_bind_group, .set_vertex_buffer, .set_index_buffer => execRenderBind(cmds, bytecode, pc, op),
        .draw, .draw_indexed, .draw_indirect, .draw_indexed_indirect => execRenderDraw(cmds, bytecode, pc, op),
        .set_viewport, .set_scissor_rect, .set_stencil_reference, .set_pass_depth_stencil_ops, .set_blend_constant, .set_pass_clear_values => execRenderViewport(cmds, bytecode, pc, op),
        .set_pass_occlusion_query_set, .set_pass_timestamp_writes, .begin_occlusion_query, .end_occlusion_query => execRenderQuery(cmds, bytecode, pc, op),
        else => {},
    }
}

/// Render pipeline + render-bundle opcodes (create/replay).
fn execRenderPipeline(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .create_render_pipeline => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.create_render_pipeline, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.createRenderPipeline(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .create_render_bundle => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.create_render_bundle, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.createRenderBundle(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .execute_bundles => {
            if (comptime plugins.isEnabled(.render)) {
                // Reading every id and discarding the surplus past the cap kept
                // this in step with the reference dispatcher (which did the
                // same) and out of step with `skipParams`, whose clamp is the
                // schema's cap — 10_000 bytes apart at 60_000 ids (§320). The
                // frontend rejects over-cap passes, so a compiled PNG never
                // reaches the latch.
                const count = read_varint(bytecode, pc);
                if (count > MAX_BUNDLES) malformed_body = true;
                const n = @min(count, MAX_BUNDLES);
                var ids: [MAX_BUNDLES]u16 = undefined;
                for (0..n) |i| {
                    ids[i] = narrowId(read_varint(bytecode, pc));
                }
                cmds.executeBundles(ids[0..n]);
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Render-pass lifecycle opcodes (begin single/MRT, end).
fn execRenderPass(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .begin_render_pass => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.begin_render_pass, bytecode, pc);
                cmds.beginRenderPass(
                    narrowId(o.color_texture_id),
                    o.load_op,
                    o.store_op,
                    narrowId(o.depth_texture_id),
                    o.clear_r,
                    o.clear_g,
                    o.clear_b,
                    o.clear_a,
                    narrowId(o.resolve_texture_id),
                );
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .begin_render_pass_mrt => {
            if (comptime plugins.isEnabled(.render)) {
                // MAX_MRT is the wire contract's cap, not a local clamp: the
                // skipper advances past exactly @min(count, MAX_MRT) elements,
                // so a count above it leaves this decode and every other
                // consumer at different pcs. The emitter cannot produce one
                // (gatherColorAttachments stops at 8), so it is a corrupt or
                // hostile stream — latch and let init()/frame() refuse it.
                const count = readByteClamped(bytecode, pc);
                if (count > MAX_MRT) malformed_body = true;
                const n = @min(count, MAX_MRT);
                var attachments: [MAX_MRT]ColorAttachment = undefined;
                for (0..n) |i| {
                    const tex_id = read_varint(bytecode, pc);
                    const load_op = readByteClamped(bytecode, pc);
                    const store_op = readByteClamped(bytecode, pc);
                    const clear_r = readByteClamped(bytecode, pc);
                    const clear_g = readByteClamped(bytecode, pc);
                    const clear_b = readByteClamped(bytecode, pc);
                    const clear_a = readByteClamped(bytecode, pc);
                    attachments[i] = .{
                        .texture_id = narrowId(tex_id),
                        .load_op = @enumFromInt(load_op),
                        .store_op = @enumFromInt(store_op),
                        .clear_r = clear_r,
                        .clear_g = clear_g,
                        .clear_b = clear_b,
                        .clear_a = clear_a,
                    };
                }
                const depth_id = read_varint(bytecode, pc);
                cmds.beginRenderPassMRT(attachments[0..n], narrowId(depth_id));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .end_pass => cmds.endPass(),
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Render binding-state opcodes (pipeline, bind group, vertex/index buffers).
fn execRenderBind(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .set_pipeline => {
            const o = readOps(.set_pipeline, bytecode, pc);
            cmds.setPipeline(narrowId(o.v0));
        },
        .set_bind_group => {
            const o = readOps(.set_bind_group, bytecode, pc);
            cmds.setBindGroup(o.slot, narrowId(o.id));
        },
        .set_vertex_buffer => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_vertex_buffer, bytecode, pc);
                cmds.setVertexBuffer(o.slot, narrowId(o.id));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_index_buffer => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_index_buffer, bytecode, pc);
                cmds.setIndexBuffer(narrowId(o.buffer_id), o.index_format);
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Render draw opcodes (direct + indirect, indexed + non-indexed).
fn execRenderDraw(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .draw => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.draw, bytecode, pc);
                cmds.draw(@intCast(o.v0), @intCast(o.v1), @intCast(o.v2), @intCast(o.v3));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .draw_indexed => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.draw_indexed, bytecode, pc);
                cmds.drawIndexed(@intCast(o.v0), @intCast(o.v1), @intCast(o.v2), @intCast(o.v3), @intCast(o.v4));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .draw_indirect => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.draw_indirect, bytecode, pc);
                cmds.drawIndirect(narrowId(o.v0), @intCast(o.v1));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .draw_indexed_indirect => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.draw_indexed_indirect, bytecode, pc);
                cmds.drawIndexedIndirect(narrowId(o.v0), @intCast(o.v1));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Render viewport/scissor/stencil/depth-stencil state opcodes.
fn execRenderViewport(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .set_viewport => {
            if (comptime plugins.isEnabled(.render)) {
                // min_depth/max_depth arrive as raw f32 bit patterns (u32_le).
                const o = readOps(.set_viewport, bytecode, pc);
                cmds.setViewport(@intCast(o.x), @intCast(o.y), @intCast(o.w), @intCast(o.h), @bitCast(o.min_depth), @bitCast(o.max_depth));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_scissor_rect => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_scissor_rect, bytecode, pc);
                cmds.setScissorRect(@intCast(o.v0), @intCast(o.v1), @intCast(o.v2), @intCast(o.v3));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_stencil_reference => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_stencil_reference, bytecode, pc);
                cmds.setStencilReference(@intCast(o.v0));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_pass_depth_stencil_ops => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_pass_depth_stencil_ops, bytecode, pc);
                cmds.setPassDepthStencilOps(o.depth_load_op, o.depth_store_op, o.stencil_load_op, o.stencil_store_op);
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_blend_constant => {
            if (comptime plugins.isEnabled(.render)) {
                // r, g, b, a arrive as raw f32 bit patterns (u32_le).
                const o = readOps(.set_blend_constant, bytecode, pc);
                cmds.setBlendConstant(@bitCast(o.r), @bitCast(o.g), @bitCast(o.b), @bitCast(o.a));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_pass_clear_values => {
            if (comptime plugins.isEnabled(.render)) {
                // depth arrives as a raw f32 bit pattern (u32_le), stencil as u32.
                const o = readOps(.set_pass_clear_values, bytecode, pc);
                cmds.setPassClearValues(@bitCast(o.depth_bits), o.stencil_value);
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

/// Render query opcodes (occlusion + timestamp writes).
fn execRenderQuery(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .set_pass_occlusion_query_set => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_pass_occlusion_query_set, bytecode, pc);
                cmds.setPassOcclusionQuerySet(narrowId(o.v0));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .set_pass_timestamp_writes => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.set_pass_timestamp_writes, bytecode, pc);
                cmds.setPassTimestampWrites(narrowId(o.v0), @intCast(o.v1), @intCast(o.v2));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .begin_occlusion_query => {
            if (comptime plugins.isEnabled(.render)) {
                const o = readOps(.begin_occlusion_query, bytecode, pc);
                cmds.beginOcclusionQuery(@intCast(o.v0));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .end_occlusion_query => {
            if (comptime plugins.isEnabled(.render)) {
                cmds.endOcclusionQuery();
            }
        },
        else => {},
    }
    std.debug.assert(pc.* >= pc_start); // post: decode advances monotonically
}

// ============================================================================
// Plugin Handlers - Compute
// ============================================================================

/// Handle compute plugin opcodes: pipeline, pass, dispatch.
fn execCompute(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_compute_pipeline => {
            if (comptime plugins.isEnabled(.compute)) {
                const o = readOps(.create_compute_pipeline, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.createComputePipeline(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .begin_compute_pass => {
            if (comptime plugins.isEnabled(.compute)) {
                cmds.beginComputePass();
            }
        },
        .dispatch => {
            if (comptime plugins.isEnabled(.compute)) {
                const o = readOps(.dispatch, bytecode, pc);
                cmds.dispatch(@intCast(o.v0), @intCast(o.v1), @intCast(o.v2));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .dispatch_indirect => {
            if (comptime plugins.isEnabled(.compute)) {
                const o = readOps(.dispatch_indirect, bytecode, pc);
                cmds.dispatchIndirect(narrowId(o.v0), @intCast(o.v1));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Texture
// ============================================================================

/// Handle texture plugin opcodes: texture creation, copy.
fn execTexture(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .create_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                const o = readOps(.create_texture, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.createTexture(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .create_texture_view => {
            if (comptime plugins.isEnabled(.texture)) {
                const o = readOps(.create_texture_view, bytecode, pc);
                const data = getDataSlice(narrowId(o.v2));
                cmds.createTextureView(narrowId(o.v0), narrowId(o.v1), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .create_image_bitmap => {
            if (comptime plugins.isEnabled(.texture)) {
                const o = readOps(.create_image_bitmap, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.createImageBitmap(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .copy_texture_to_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                const o = readOps(.copy_texture_to_texture, bytecode, pc);
                cmds.copyTextureToTexture(narrowId(o.v0), narrowId(o.v1), 0, 0);
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .copy_external_image_to_texture => {
            if (comptime plugins.isEnabled(.texture)) {
                // mip_level is a RAW BYTE, not a varint. The layout table says so
                // (L_COPY_EXT_IMG, .byte), so reading it through wire_schema can no
                // longer drift from the emitter — this decoder once read it as a
                // varint and desynced for any mip >= 0x80, where the high bit reads
                // as a varint continuation (§221 item 1.2).
                const o = readOps(.copy_external_image_to_texture, bytecode, pc);
                cmds.copyExternalImageToTexture(narrowId(o.bitmap_id), narrowId(o.texture_id), @intCast(o.mip_level), @intCast(o.origin_x), @intCast(o.origin_y), @intCast(o.origin_z));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - WASM
// ============================================================================

/// Handle WASM plugin opcodes: module init, function calls.
fn execWasm(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .init_wasm_module => {
            if (comptime plugins.isEnabled(.wasm)) {
                const o = readOps(.init_wasm_module, bytecode, pc);
                const data = getDataSlice(narrowId(o.v1));
                cmds.initWasmModule(narrowId(o.v0), dataAddr(data.ptr), @intCast(data.len));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .call_wasm_func => {
            if (comptime plugins.isEnabled(.wasm)) {
                const call_id = read_varint(bytecode, pc);
                const mod_id = read_varint(bytecode, pc);
                const func_id = read_varint(bytecode, pc);
                // Same contract as MRT above: over-cap means the stream did not
                // come from this compiler, and walking `count` args when the
                // skipper walks `@min(count, MAX_WASM_ARGS)` desyncs everything
                // after this instruction.
                const arg_count_raw = readByteClamped(bytecode, pc);
                if (arg_count_raw > MAX_WASM_ARGS) malformed_body = true;
                const arg_count = @min(arg_count_raw, MAX_WASM_ARGS);

                // Get function name from string table
                const func_name = getStringSlice(narrowId(func_id));

                // Calculate args size for command buffer
                // Args start at current pc, format: [arg_type:u8][value?:0-4 bytes]...
                const args_start = pc.*;
                for (0..arg_count) |_| {
                    const arg_type: opcodes.WasmArgType = @enumFromInt(readByteClamped(bytecode, pc));
                    pc.* = @min(pc.* + arg_type.valueByteSize(), bytecode.len);
                }
                const args_end = pc.*;

                // Emit call_wasm_func command with args embedded
                // Build args buffer: [arg_count][arg_type, value?]...
                // The bound is arithmetic, not a guess: the loop runs at most
                // MAX_WASM_ARGS times and each pass advances the pc by at most a
                // tag byte + 4 value bytes. The `if (args_len <= 256)` that used
                // to guard this memcpy DROPPED the whole call when it tripped —
                // silently, since the executor's only channel is the latch below.
                var args_buf: [1 + @as(usize, MAX_WASM_ARGS) * 5]u8 = undefined;
                const args_len = args_end - args_start;
                std.debug.assert(args_len <= args_buf.len - 1);
                // The count byte describes the body that follows it, so it is the
                // CLAMPED count — a header promising more args than were copied is
                // the descriptor-desync of §318 one layer down.
                args_buf[0] = arg_count;
                @memcpy(args_buf[1 .. 1 + args_len], bytecode[args_start..args_end]);
                // Pass args slice directly - command buffer copies inline
                cmds.callWasmFunc(
                    narrowId(call_id),
                    narrowId(mod_id),
                    dataAddr(func_name.ptr),
                    @intCast(func_name.len),
                    args_buf[0 .. 1 + args_len],
                );
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        .write_buffer_from_wasm => {
            if (comptime plugins.isEnabled(.wasm)) {
                const o = readOps(.write_buffer_from_wasm, bytecode, pc);
                cmds.writeBufferFromWasm(narrowId(o.v1), @intCast(o.v2), narrowId(o.v0), @intCast(o.v3));
            } else {
                skipOpcodeParams(bytecode, pc, op);
            }
        },
        else => {},
    }
}

// ============================================================================
// Plugin Handlers - Pool Operations
// ============================================================================

/// Handle pool opcodes: set_vertex_buffer_pool, set_bind_group_pool.
/// Calculates actual resource ID based on frame_counter.
fn execPool(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    switch (op) {
        .set_vertex_buffer_pool => {
            const o = readOps(.set_vertex_buffer_pool, bytecode, pc);

            // Guard `% pool_size`: a hostile pool_size==0 would trap (`% 0`) in
            // the shipping wasm. Native aborts the frame (pool.zig error); the
            // void handler here skips the op (emits no command) — operands are
            // already consumed, so pc stays correct for the caller.
            if (o.pool_size == 0) return;
            // Calculate actual buffer ID: base_id + (frame_counter + offset) % pool_size
            const actual_id: u16 = narrowId(o.base_id + (frame_counter + o.offset) % o.pool_size);
            cmds.setVertexBuffer(o.slot, actual_id);
        },
        .set_bind_group_pool => {
            const o = readOps(.set_bind_group_pool, bytecode, pc);

            // Guard `% pool_size`: hostile pool_size==0 would trap. Skip the op.
            if (o.pool_size == 0) return;
            // Calculate actual bind group ID: base_id + (frame_counter + offset) % pool_size
            const actual_id: u16 = narrowId(o.base_id + (frame_counter + o.offset) % o.pool_size);
            cmds.setBindGroup(o.slot, actual_id);
        },
        .begin_render_pass_pool => {
            const o = readOps(.begin_render_pass_pool, bytecode, pc);

            // Guard `% pool_size`: hostile pool_size==0 would trap. Skip the op.
            if (o.pool_size == 0) return;
            // Calculate actual texture ID: base_tex_id + (frame_counter + offset) % pool_size
            const actual_id: u16 = narrowId(o.base_tex_id + (frame_counter + o.offset) % o.pool_size);
            cmds.beginRenderPass(actual_id, o.load_op, o.store_op, narrowId(o.depth_tex_id), o.clear_r, o.clear_g, o.clear_b, o.clear_a, 0xFFFF);
        },
        else => {},
    }
}

// ============================================================================
// Internal - Animation Table Parsing
// ============================================================================

/// Parse animation table from bytecode buffer at given offset.
/// Format: flags(u8), [name_string_id(varint), duration_ms(u32), end_behavior(u8),
///         scene_count(varint), scenes[scene_count]{id_varint, frame_varint, start_u32, end_u32}]
fn parseAnimationTable(offset: u32) void {
    // `offset > bytecode_len` is NOT a precondition violation: it happens for a
    // hostile animation_table_offset (init() defers this section's bound to here,
    // not to its ascending-offset check) AND legitimately in split-payload mode,
    // where the animation table sits past the truncated bytecode_buffer. The
    // guard below is the real handling — turn the section off, never slice out of
    // range. A `assert(offset <= bytecode_len)` here would contradict that guard
    // (Debug-panic on input the function is built to absorb; stripped anyway in
    // the shipping ReleaseSmall build). (Arc-3 §3.2)
    if (offset >= bytecode_len) {
        has_animation = false;
        return;
    }

    const data = bytecode_buffer[offset..bytecode_len];
    if (data.len == 0) {
        has_animation = false;
        return;
    }

    var pos: usize = 0;

    // Read flags
    const flags = data[pos];
    pos += 1;

    const has_anim_flag = (flags & 1) != 0;
    if (!has_anim_flag) {
        has_animation = false;
        return;
    }

    anim_loop = (flags & 2) != 0;

    // Read name_string_id (skip - we don't need the name)
    if (pos >= data.len) return;
    const name_result = opcodes.decode_varint(data[pos..]);
    pos += name_result.len;

    // Read duration_ms
    if (pos + 4 > data.len) return;
    anim_duration_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    // Read end_behavior
    if (pos >= data.len) return;
    anim_end_behavior = data[pos];
    pos += 1;

    // Read scene_count
    if (pos >= data.len) return;
    const count_result = opcodes.decode_varint(data[pos..]);
    pos += count_result.len;
    anim_scene_count = @min(count_result.value, MAX_SCENES);

    // Read scenes (bounded loop)
    for (0..anim_scene_count) |i| {
        // id_string_id (skip - we don't need scene ID)
        if (pos >= data.len) break;
        pos += opcodes.decode_varint(data[pos..]).len;

        // frame_string_id (this maps to a #frame name)
        if (pos >= data.len) break;
        const frame_result = opcodes.decode_varint(data[pos..]);
        pos += frame_result.len;

        // start_ms
        if (pos + 4 > data.len) break;
        const start_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        // end_ms
        if (pos + 4 > data.len) break;
        const end_ms = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        anim_scenes[i] = .{
            .frame_string_id = @intCast(frame_result.value),
            .start_ms = start_ms,
            .end_ms = end_ms,
        };

        // Debug: log each scene
        dbg("scene[{d}] frame_id={d} {d}-{d}ms", .{ i, frame_result.value, start_ms, end_ms });
    }

    has_animation = anim_scene_count > 0;

    // Debug: log animation info
    dbg("anim: scenes={d} dur={d}ms loop={}", .{ anim_scene_count, anim_duration_ms, anim_loop });

    // Post-condition
    std.debug.assert(anim_scene_count <= MAX_SCENES);
}

/// Find scene index for a given time (in milliseconds).
/// Returns scene index or null if no matching scene.
fn findSceneAtTime(time_ms: u32) ?u32 {
    if (!has_animation or anim_scene_count == 0) return null;

    // Handle looping: wrap time to duration
    var effective_time = time_ms;
    if (anim_loop and anim_duration_ms > 0) {
        effective_time = time_ms % anim_duration_ms;
    }

    // Find scene containing this time
    for (0..anim_scene_count) |i| {
        const scene = anim_scenes[i];
        if (effective_time >= scene.start_ms and effective_time < scene.end_ms) {
            return @intCast(i);
        }
    }

    // Past all scenes: return last scene if hold behavior (0)
    if (anim_end_behavior == 0 and anim_scene_count > 0) {
        return anim_scene_count - 1;
    }

    return null;
}

/// Find PC offset for a frame by its string ID.
/// Returns PC offset relative to bytecode_start, or null if not found.
fn findFramePcByStringId(frame_string_id: u16) ?u32 {
    for (0..frame_count) |i| {
        if (frame_entries[i].name_string_id == frame_string_id) {
            return frame_entries[i].pc_offset;
        }
    }
    return null;
}

/// Scan bytecode for all define_frame opcodes and build frame_entries table.
/// Must be called after executeResourceCreation() to build frame name → PC mapping.
fn scanFrameDefinitions() void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];
    var pc: usize = 0;
    frame_count = 0;

    for (0..MAX_EXEC_ITERATIONS) |_| {
        if (pc >= bytecode.len) break;
        if (frame_count >= MAX_FRAMES) break;

        const op: OpCode = @enumFromInt(bytecode[pc]);
        pc += 1;

        if (op == .define_frame) {
            // Read frame_id (skip)
            _ = read_varint(bytecode, &pc);
            // Read name_string_id (we need this for matching)
            const name_id = read_varint(bytecode, &pc);

            // Store frame entry: name_string_id → current PC (after params)
            frame_entries[frame_count] = .{
                .name_string_id = @intCast(name_id),
                .pc_offset = @intCast(pc), // Points to first opcode inside frame body
            };
            frame_count += 1;

            // Debug: log frame definition
            dbg("frame[{d}] name_id={d} pc={d}", .{ frame_count - 1, name_id, pc });

            // Continue scanning - skip frame body to find next frame
            for (0..MAX_EXEC_ITERATIONS) |_| {
                if (pc >= bytecode.len) break;
                const inner_op: OpCode = @enumFromInt(bytecode[pc]);
                pc += 1;
                if (inner_op == .end_frame) break;
                skipOpcodeParams(bytecode, &pc, inner_op);
            }
        } else {
            skipOpcodeParams(bytecode, &pc, op);
        }
    }

    // Debug: log total frame count
    dbg("total frames={d}", .{frame_count});
}

// ============================================================================
// Internal - Helpers
// ============================================================================

/// Read varint from bytecode.
/// Narrow a decoded varint operand to a u16 resource/pass/data/string id. On an
/// out-of-range value, latch `malformed_body` (init()/frame() then refuse the
/// frame/module wholesale) and return the NONE sentinel — never the bare
/// `@intCast`, which panics in a Debug/native build and wraps to a wrong-but-
/// valid id in the shipping ReleaseSmall build. The reference dispatcher's
/// `wire.narrowU16` errors the whole decode; this void command-writer has no
/// per-op error return, so the latch is its equivalent loud channel. For a
/// well-formed stream (every id ≤ u16) this is byte-identical to `@intCast`, so
/// goldens/snapshots are unchanged. (Arc-3 §5.4)
noinline fn narrowId(v: u32) u16 {
    if (v > std.math.maxInt(u16)) {
        malformed_body = true;
        return 0xFFFF;
    }
    return @intCast(v);
}

fn read_varint(bytecode: []const u8, pc: *usize) u32 {
    // Bounds-safe: `decode_varint` asserts the full encoding is present (asserts
    // are stripped in ReleaseSmall → OOB read on a bytecode truncated mid-varint).
    // `decode_varint_safe` returns {0,0} on truncation; every caller loop is
    // `for (0..MAX_EXEC_ITERATIONS)`-bounded, so a stationary pc terminates. For
    // well-formed input this is byte-identical to `decode_varint` (proven in
    // opcodes.zig) → goldens unchanged.
    if (pc.* >= bytecode.len) return 0;
    const result = opcodes.decode_varint_safe(bytecode[pc.*..]);
    pc.* += result.len;
    return result.value;
}

/// Read a raw 4-byte little-endian u32 (for f32 bit patterns).
fn readRawU32(bytecode: []const u8, pc: *usize) u32 {
    if (pc.* + 4 > bytecode.len) return 0;
    const value = std.mem.readInt(u32, bytecode[pc.*..][0..4], .little);
    pc.* += 4;
    return value;
}

/// Read one raw operand byte, clamping at the buffer end.
///
/// The hand-rolled decode sites this replaces indexed `bytecode[pc.*]` blind —
/// an OOB read on bytecode truncated mid-instruction, since ReleaseSmall strips
/// the bounds check. Clamping matches `wire_schema.skipParams`, so decode and
/// skip now agree on malformed input; for well-formed bytecode it is
/// byte-identical, leaving goldens and conformance landings unchanged.
noinline fn readByteClamped(bytecode: []const u8, pc: *usize) u8 {
    if (pc.* >= bytecode.len) return 0;
    const b = bytecode[pc.*];
    pc.* += 1;
    return b;
}

/// Decode `op`'s fixed-shape operands into a typed struct whose fields are named
/// by `wire_schema`'s layout for that opcode, advancing `pc` past them.
///
/// This is the decode half of the executor's decode/effect split, mirroring the
/// reference dispatcher's `wire.readOperands(wire.layoutOf(.op), self)`. It
/// replaces ~40 hand-written read sequences: the operand layout — field order,
/// count, and each field's wire encoding — now has ONE definition serving both
/// decoders, so an emitter change that outruns the executor embedded in every
/// PNG is a `@compileError` in `layoutOf` rather than a silent mis-decode.
///
/// Count-prefixed opcodes (MRT, execute_bundles, call_wasm_func,
/// create_shader_concat) still decode manually — the same exemption the
/// dispatcher has, since each maps onto a shape the wire table does not
/// describe.
///
/// ## Why this walks the layout instead of calling `wire_schema.readOperands`
/// `readOperands` is duck-typed on a FALLIBLE reader (`try` per field), which
/// suits the dispatcher — it turns a bad operand into an error. This executor
/// has no per-op error channel: it clamps and latches `malformed_body` instead.
/// Adapting it with an `error{}` reader compiled but cost 3.2KB on the
/// all-plugins executor (16157 B vs 12929 B) — an empty error set did NOT
/// collapse away, so every operand read carried a branch; forcing the inline
/// made it worse still (17115 B). Walking `layout.head` directly is ~10 lines
/// and 12766 B, BELOW the pre-migration hand-rolled baseline. The duplication
/// is a reader loop, not a layout: it is mechanically derived from the same
/// table, so it cannot disagree about what the wire looks like (journal §270).
fn readOps(comptime op: OpCode, bytecode: []const u8, pc: *usize) wire_schema.Operands(wire_schema.layoutOf(op)) {
    const layout = comptime wire_schema.layoutOf(op);
    var out: wire_schema.Operands(layout) = undefined;
    inline for (layout.head) |field| {
        @field(out, field.name) = switch (field.kind) {
            .varint => read_varint(bytecode, pc),
            .byte => readByteClamped(bytecode, pc),
            .u32_le => readRawU32(bytecode, pc),
            .wasm_arg => @compileError("wire_schema: wasm_arg decodes manually"),
        };
    }
    return out;
}

/// Get slice from data section by data ID.
/// Data section is in bytecode_buffer (embedded mode) or data_buffer (shared mode).
///
/// Data section format:
///   count: u16
///   entries: [count]{offset: u32, len: u32}  // offsets relative to data portion
///   data: raw bytes
fn getDataSlice(data_id: u16) []const u8 {
    // Determine source buffer based on mode
    const data: []const u8 = blk: {
        if (data_in_bytecode) {
            // Embedded mode: data section is in bytecode_buffer
            if (data_section_len == 0) break :blk &[_]u8{};
            break :blk bytecode_buffer[data_section_offset..][0..data_section_len];
        } else {
            // Shared mode: data section is in separate data_buffer
            if (data_len == 0) break :blk &[_]u8{};
            break :blk data_buffer[0..data_len];
        }
    };

    if (data.len < 2) return &[_]u8{};

    const count = std.mem.readInt(u16, data[0..2], .little);
    if (data_id >= count) return &[_]u8{};

    // Entry table starts at offset 2, each entry is 8 bytes
    const entry_offset: usize = 2 + @as(usize, data_id) * 8;
    if (entry_offset + 8 > data.len) return &[_]u8{};

    // Offsets in entries are relative to the data portion (after entry table)
    const blob_offset = std.mem.readInt(u32, data[entry_offset..][0..4], .little);
    const blob_len = std.mem.readInt(u32, data[entry_offset + 4 ..][0..4], .little);

    // Data portion starts after: count (2) + entries (count * 8)
    const data_start: usize = 2 + @as(usize, count) * 8;
    // Saturating adds: on wasm32 usize is u32 and blob_offset/blob_len are hostile
    // u32s that could wrap `data_start + blob_offset` small enough to pass the
    // bounds check below (asserts stripped in ReleaseSmall). Saturation pins an
    // overflow at maxInt → the check fails → empty slice.
    const abs_offset = data_start +| blob_offset;
    if (abs_offset +| blob_len > data.len) return &[_]u8{};
    return data[abs_offset..][0..blob_len];
}

/// Get string slice from string table by string ID.
/// String table format: count(u16) + offsets([count]u16) + lengths([count]u16) + data(bytes)
fn getStringSlice(string_id: u16) []const u8 {
    if (string_table_len == 0) return &[_]u8{};

    // String table is in bytecode_buffer at string_table_offset
    const table = bytecode_buffer[string_table_offset..][0..string_table_len];
    if (table.len < 2) return &[_]u8{};

    const count = std.mem.readInt(u16, table[0..2], .little);
    if (string_id >= count) return &[_]u8{};

    // Calculate offsets and lengths array positions
    const offsets_start: usize = 2;
    const lengths_start: usize = 2 + @as(usize, count) * 2;
    const data_start: usize = 2 + @as(usize, count) * 4;

    if (data_start > table.len) return &[_]u8{};

    // Read this string's offset and length
    const offset_pos = offsets_start + @as(usize, string_id) * 2;
    const length_pos = lengths_start + @as(usize, string_id) * 2;

    if (offset_pos + 2 > table.len or length_pos + 2 > table.len) return &[_]u8{};

    const str_offset = std.mem.readInt(u16, table[offset_pos..][0..2], .little);
    const str_len = std.mem.readInt(u16, table[length_pos..][0..2], .little);

    // String offset is relative to data section start
    const abs_offset = data_start + str_offset;
    if (abs_offset + str_len > table.len) return &[_]u8{};

    return table[abs_offset..][0..str_len];
}

/// Skip an opcode's operands (scan without executing), delegating to the shared
/// `wire_schema` spine — the SAME operand-layout table the reference scanner and
/// dispatcher read (bytecode/wire_schema.zig). Before item 2.1 wasm_entry
/// hand-decoded this in a 130-line switch plus five helper fns that could (and
/// did) drift from the emitter: it read `call_wasm_func`'s arg count and
/// `create_shader_concat`'s part count as varints where the emitter writes raw
/// bytes (benign only because both counts stay < 0x80 in practice). Routing
/// through `wire_schema.skipParams` makes drift a `@compileError` (layoutOf is
/// comptime-total) and is pinned per-opcode by the wasm_entry wire-conformance
/// suite (§221 item 1.2). Deliberate deltas vs the old switch are
/// malformed-input-only: skipParams clamps every advance to `bytecode.len` and
/// caps rep-groups at the scanner's bounds.
pub fn skipOpcodeParams(bytecode: []const u8, pc: *usize, op: OpCode) void { // pub for wire conformance
    // Pre-condition: pc is at or before an operand region.
    std.debug.assert(pc.* <= bytecode.len);
    pc.* = wire_schema.skipParams(bytecode, @intCast(pc.*), op);
    // Post-condition: skipParams never advances past the buffer end.
    std.debug.assert(pc.* <= bytecode.len);
}
