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
/// Bytes in the runtime's time block, and therefore the largest `size` a
/// `write_time_uniform` may carry to the host. Three sources are prefixes of
/// it: 12 `scene-time-inputs`, 16 `pngine-inputs`, 20 `pngine-frame-inputs`
/// (the last four bytes being the frame counter as a u32). Peers that must
/// agree: `gpu.js`'s `timeAB` + `gpu-queue-commands.js`'s clamp,
/// `wgpu_native_gpu.write_time_uniform`, `values.mapDataSource`, docs/abi.md.
const TIME_PAYLOAD_BYTES: u64 = 20;

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
// Frame State (Static Allocation)
// ============================================================================

/// Maximum frames that can be defined in bytecode.
const MAX_FRAMES: u32 = bytecode_mod.DEFAULT_MAX_FRAMES;

/// Frame definition entry: maps frame name string ID to bytecode PC offset.
const FrameEntry = struct {
    name_string_id: u16,
    pc_offset: u32, // PC offset relative to bytecode_start (after define_frame params)
    /// PC offset of this frame's `end_frame` opcode — the frame's END, which
    /// init()'s scan records so `frame()` can bound guard skips (§7.3): a
    /// skip may land exactly on it, never past it. A body that never closes
    /// is a truncated payload; the buffer end is its bound, the same place
    /// execution itself would stop.
    end_pc: u32,
};

/// Frame definition table: maps frame_string_id to PC offset.
var frame_entries: [MAX_FRAMES]FrameEntry = undefined;
var frame_count: u32 = 0;

/// "No frame pinned" — the value `setFrame` takes to release the pin and
/// `getFrameNameId` returns past the table's end (docs/abi.md §2).
const NO_FRAME: u32 = 0xFFFF_FFFF;

/// The frame `frame()` renders when the host pinned one (`setFrame`), by its
/// index in `frame_entries`; `NO_FRAME` when none is. The pin is the host's
/// decision and the ONLY frame selector beside "the first one" — the
/// time-to-scene scheduler that once read the payload's animation table is
/// retired (frame-program plan §8.1/D1): no runtime path delivered the table,
/// and `setFrame` covers the whole-frame choice it existed for. Cleared by
/// `init()`, since a new payload has new frames.
var pinned_frame: u32 = NO_FRAME;

// ============================================================================
// Frame-Program Controls (plan §7.2, task F3)
// ============================================================================

/// The control table: slot 0 is `time`, 1..64 the declared controls in
/// declaration order. Static, like every buffer here — 65 f32, no allocator,
/// and the memory never grows, so a host's `Float32Array` over
/// `getControlPtr()` stays valid for the life of the instance (the drift
/// gate's no-allocator property is what makes that view safe).
var controls: [opcodes.MAX_CONTROLS + 1]f32 = @splat(0);

/// How many controls the payload declares (0..MAX_CONTROLS), read by
/// init()'s walk of the resource-creation region. Guards and write_controls
/// check against it — the same bound the reference dispatcher keeps, so a
/// slot past the declarations is a refusal in both, never a silent zero.
var declared_controls: u32 = 0;

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

    // Reset state — ALL of it, first. `initialized` goes false here so a
    // refused re-init (a host that reloads one instance) cannot leave the
    // previous payload runnable: the section offsets below are written before
    // the checks that can refuse, and `frame()` used to run the new start with
    // the old end and lengths. `pass_ranges` is wiped for the same reason — a
    // payload defining only pass 5 left passes 0..4 pointing into the previous
    // payload's bytes. (ABI §4: `frame` == 1 when init "was not called, or
    // refused" — for every init, not only the first.)
    initialized = false;
    frame_counter = 0;
    resources_created = false;
    pass_count = 0;
    pass_ranges = [_]PassRange{.{ .start = 0, .end = 0 }} ** MAX_PASSES;
    pass_executed_once = @splat(false);
    frame_count = 0;
    pinned_frame = NO_FRAME;
    malformed_body = false;
    // The control table resets with everything else: a reloaded instance
    // must not carry a previous payload's host values into this one's
    // guards. Slot 0 (`time`) has nothing to restore — `init()` has no time
    // input; `frame()` stores its argument there before each body (§7.2).
    controls = @splat(0);
    declared_controls = 0;

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
    // v0, and v1 (an executor-less guarded payload, D6): this executor IS the
    // shared one such payloads run on, so refusing 1 would break the pairing
    // the version exists to keep. 2 and up still refuse — status 3 is what a
    // pre-handshake runtime obeys.
    if (!format.versionSupported(version)) {
        return 3; // Unsupported version (0 and 1 supported)
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
    // (The v0 header's byte 36, animation_table_offset, is deliberately NOT
    // read: the PNGB format still carries the section, but this executor no
    // longer schedules frames from it — see `pinned_frame`. It never reads the
    // bytes, so a hostile or truncated table cannot affect it.)

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
/// - time: Elapsed time in seconds. Stored into control slot 0 BEFORE the
///   frame body runs, so every guard in that body sees one value and `time`
///   needs no special case in `exec_if` (frame program §5, §7.1). The host
///   still stages the 20-byte time block itself (`gpu.setTime` /
///   `write_time_uniform`) — the slot is the guards' copy.
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

    // §5: the frame's time lands in slot 0 before the body runs; nothing
    // can set a control while the body runs, so every guard sees one value.
    controls[0] = time;
    malformed_body = false;
    var cmds = CommandBuffer.init(&cmd_buffer);
    executeFrame(&cmds, width, height);
    _ = cmds.finish();

    // Post-condition: frame counter advances.
    const prev_frame = frame_counter;
    frame_counter +%= 1; // host-settable (setFrameCounter), so it wraps rather than traps
    assert(frame_counter == prev_frame + 1);

    // A frame opcode carried an out-of-range id, or a guard refused its
    // input (a slot past the declared controls, an unknown comparison tag,
    // or a skip past the frame's end) — hostile/corrupt streams only, since
    // the compiler emits none of those. Report it so the host skips this
    // frame's command buffer and surfaces an onError, instead of executing
    // commands that address wrapped ids. (§7.3: one latch, one status.)
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

/// How many `define_frame`s `init()` indexed; 0 before a successful init.
/// Additive export (docs/abi.md §2) — hosts feature-detect.
pub export fn getFrameCount() u32 {
    if (!initialized) return 0;
    return frame_count;
}

/// The string id of frame `index`'s name (its `(frame :name …)`, interned in
/// the payload's string table), or `NO_FRAME` past the end or before init.
/// The host resolves the id through the string table it already parses, so
/// the executor never handles a name. Additive export (docs/abi.md §2).
pub export fn getFrameNameId(index: u32) u32 {
    if (!initialized or index >= frame_count) return NO_FRAME;
    return frame_entries[index].name_string_id;
}

/// Pin the frame `frame()` renders, by its index in define order; `NO_FRAME`
/// releases the pin. The pin outranks the animation table and holds until
/// the next `setFrame` or `init()`.
///
/// Returns 0 ok, 1 not initialised, 2 out of range (the pin is left as it
/// was). Additive export (docs/abi.md §2).
pub export fn setFrame(index: u32) u32 {
    if (!initialized) return 1;
    if (index != NO_FRAME and index >= frame_count) return 2;
    pinned_frame = index;
    // Post-condition: the pin names a frame or nothing.
    std.debug.assert(pinned_frame == NO_FRAME or pinned_frame < frame_count);
    return 0;
}

/// ABI version of the executor↔host interface (docs/abi.md).
/// Binaries without this export are version 1; the host reads it via
/// `exports.getAbiVersion?.() ?? 1`. The interface is frozen append-only,
/// so this should stay at 1 — it exists as a diagnostic and escape hatch.
export fn getAbiVersion() u32 {
    return 1;
}

/// Address of control slot 0 in linear memory (frame program §7.2), so a
/// host reads and writes the table through one `Float32Array` over it:
/// slot `i` lives at `getControlPtr() + 4 * i`. The view stays valid for
/// the life of the instance because the executor never grows its memory.
/// Additive export, like `getFrameCount` before it — `getAbiVersion` stays
/// 1 (docs/abi.md §2). The runtime's load handshake (plan §9) treats the
/// export's presence as "this executor knows guards".
pub export fn getControlPtr() u32 {
    return dataAddr(&controls);
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

        // define_control: the declaration phase (plan §7.2). This walk IS
        // the resource-creation region, where the compiler puts the
        // declarations; the authored default lands in the next slot (slot 0
        // is `time`, set per frame by frame()). A 65th control is a
        // malformed payload like any other creation-time refusal — latch,
        // and init() returns 5 below.
        if (op == .define_control) {
            const bits = readRawU32(bytecode, &pc);
            if (declared_controls < opcodes.MAX_CONTROLS) {
                declared_controls += 1;
                controls[declared_controls] = @bitCast(bits);
            } else {
                malformed_body = true;
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

/// Test-only: a host-shaped write into the control table — what a
/// `Float32Array` over `getControlPtr()` does, including to slots a
/// well-formed payload never declared (the guards still refuse those) and
/// to slot 0 (frame() overwrites it). Out-of-range is a typed-array no-op.
/// `pub`, not `export`: unreachable from any export, dead-stripped from
/// the shipping wasm. The native agreement test drives the table this way
/// because a 64-bit host cannot dereference the truncated `dataAddr`
/// pointers the command buffer carries.
pub fn setControlForTest(slot: u32, value: f32) void {
    if (slot <= opcodes.MAX_CONTROLS) controls[slot] = value;
}

/// Test-only: the table itself, for reading defaults and values back.
/// Same visibility rule as `setControlForTest`.
pub fn controlTableForTest() []const f32 {
    return &controls;
}

/// Execute frame opcodes.
/// The frame that runs is the pinned one (`setFrame`), or the first
/// `define_frame` when nothing is pinned. There is no time-based selection:
/// the animation-table scheduler this function once carried is retired
/// (frame-program plan §8.1/D1) — the stock runtime never delivered the
/// table, and `setFrame` names the whole-frame choice it existed for.
fn executeFrame(cmds: *CommandBuffer, width: u32, height: u32) void {
    const bytecode = bytecode_buffer[bytecode_start..bytecode_end];

    // The frame that runs: the pinned one (`setFrame`), else the first in
    // define order. init()'s scan indexed that same first frame as entry 0
    // — the same walk from the same start — so its recorded body start and
    // end ARE this frame's bounds; there is nothing to rescan here.
    var pc: usize = bytecode.len; // no frame: an empty body
    var frame_end: usize = bytecode.len;

    // A host pin (setFrame) is the frame choice: "pin" means the host decided.
    // `setFrame` only stores an index below frame_count, and init() clears it,
    // so the bound holds here.
    if (pinned_frame != NO_FRAME) {
        std.debug.assert(pinned_frame < frame_count);
        pc = frame_entries[pinned_frame].pc_offset;
        frame_end = frame_entries[pinned_frame].end_pc;
        dbg("pinned frame={d} pc={d}", .{ pinned_frame, pc });
    } else if (frame_count > 0) {
        pc = frame_entries[0].pc_offset;
        frame_end = frame_entries[0].end_pc;
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

        // Handle time uniform specially. The size operand rides through (the
        // emitter writes 12 for `scene-time-inputs`, 16 for `pngine-inputs`,
        // 20 for `pngine-frame-inputs`); it used to be read and dropped, so
        // every time write was 16 bytes and a 12-byte buffer got an over-long
        // `writeBuffer` in the browser.
        //
        // The saturation is against the HOST's staging block, so it must equal
        // it: gpu.js stages `TIME_PAYLOAD_BYTES` and clamps to the same number,
        // and the native backend assembles the same block (docs/abi.md 0x21).
        // It was 16 while the block was, which capped `pngine-frame-inputs` to
        // its first 16 bytes and dropped the frame index SILENTLY — native
        // reads the size straight out of the bytecode and so never saw it
        // (CONTRIBUTING pitfall 110: the browser is the strict one here).
        if (op == .write_time_uniform) {
            const buffer_id = read_varint(bytecode, &pc);
            const offset = read_varint(bytecode, &pc);
            const size = read_varint(bytecode, &pc);
            _ = width;
            _ = height;
            cmds.writeTimeUniform(narrowId(buffer_id), @intCast(offset), @intCast(@min(size, TIME_PAYLOAD_BYTES)));
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

        // Guards (§7.1): exec_if compares a control slot against a constant
        // and skips its arm when the comparison is FALSE; exec_skip is the
        // unconditional jump over an else arm. Handled HERE, in the frame
        // body, only: a guard inside a pass definition or the creation
        // region keeps the decode-and-skip it has always had (§7.3 — the
        // compiler never emits one there, and nothing below makes it behave
        // differently). The comparison semantics are the reference
        // dispatcher's (dispatcher/frame.zig), mirrored: same NaN rule,
        // same +0 == -0, an out-of-range slot or unknown tag a refusal.
        //
        // The operand WALK is the shared `skipOpcodeParams` (the wire_schema
        // table, one call for both layouts), and the evaluated fields are
        // then read straight out of the walked bytes — the same trick the
        // dispatcher's load-time scan uses: both guard layouts END in the
        // skip bytes, so the two bytes before the landing pc ARE the skip.
        // The slot is read as ONE byte: a legal slot is 0..64 (always a
        // single-byte varint), and a slot byte with the varint continuation
        // bit decodes to 128+, past every cap — either way the byte's value
        // against `declared_controls` is the whole check, which is exactly
        // what the dispatcher's full varint decode + range check decides.
        // The comptime block below pins the layouts these reads mirror, so
        // a wire change is a build failure here, not a silent mis-decode.
        if (op == .exec_if or op == .exec_skip) {
            const instr = pc - 1; // the opcode byte
            skipOpcodeParams(bytecode, &pc, op);
            const min_len: usize = if (op == .exec_if) 9 else 3;
            if (pc - instr < min_len) {
                // Truncated inside the instruction: no skip bytes exist.
                malformed_body = true;
                continue;
            }
            const skip = @as(u16, bytecode[pc - 2]) | (@as(u16, bytecode[pc - 1]) << 8);

            // exec_if computes `holds`; exec_skip is the unconditional
            // skip, so it enters with holds already false.
            var holds = false;
            if (op == .exec_if) {
                const slot = bytecode[instr + 1];
                const comparison: opcodes.ControlComparison = @enumFromInt(bytecode[instr + 2]);
                // In bounds by the min_len check. An align(1) load: the
                // wire carries the f32's bits little-endian at an
                // unaligned offset, and one i32.load is the whole read.
                const constant: f32 = @bitCast(
                    @as(*align(1) const u32, @ptrCast(bytecode[instr + 3 ..].ptr)).*,
                );
                if (slot > declared_controls) {
                    // A slot past the declarations names a control that
                    // does not exist: refuse, never read a zero. (A
                    // multi-byte slot varint lands here too — its first
                    // byte carries the continuation bit, 128+.)
                    malformed_body = true;
                } else {
                    const value = controls[slot];
                    holds = switch (comparison) {
                        .is => value == constant,
                        .is_not => value != constant,
                        .below => value < constant,
                        .above => value > constant,
                        .at_least => value >= constant,
                        .at_most => value <= constant,
                        // The enum is non-exhaustive so @enumFromInt is
                        // not UB; an unknown tag is malformed input.
                        // Refuse, never guess a comparison.
                        _ => b: {
                            malformed_body = true;
                            break :b true;
                        },
                    };
                }
            }
            if (!holds) {
                pc += skip;
                // §7.3: the skip target must not pass this frame's end,
                // which init()'s scan recorded. On a refusal frame()
                // returns the existing nonzero status and the host discards
                // the whole command buffer — nothing in it has run yet, so
                // the discard is a full rollback. A skip landing INSIDE an
                // instruction is deliberately NOT detected here (§7.3):
                // such a skip decodes attacker-chosen bytes as
                // instructions, which a hostile payload can already do by
                // writing those instructions directly, and the compiler
                // never emits one.
                if (pc > frame_end) malformed_body = true;
            }
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
        .write_controls,
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
        // Frame-program controls and guards (F2/F3): the declaration and
        // the guards are handled by init()'s walk and the frame-body loop,
        // never here -- guards only ever move a frame body's pc, and a
        // define_control is read exactly once by the creation walk. What IS
        // forced here is the operand walk for all three, because the shared
        // wire fixtures step these opcodes through this executor's
        // conformance suite. Skipping (not no-op'ing) keeps the two
        // executors' pcs in step on old payloads and on guarded ones alike.
        .define_control,
        .exec_if,
        .exec_skip,
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
        .write_controls,
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

/// Core data/queue opcodes: write_buffer, write_controls,
/// copy_buffer_to_buffer, resolve_query_set, submit.
fn execCoreData(cmds: *CommandBuffer, bytecode: []const u8, pc: *usize, op: OpCode) void {
    std.debug.assert(pc.* <= bytecode.len); // pre: pc at operand region or buffer end
    const pc_start = pc.*;
    switch (op) {
        .write_buffer => {
            const o = readOps(.write_buffer, bytecode, pc);
            const data = getDataSlice(narrowId(o.v2));
            cmds.writeBuffer(narrowId(o.v0), @intCast(o.v1), dataAddr(data.ptr), @intCast(data.len));
        },
        .write_controls => {
            // No new command-buffer opcode (§7.1): the existing write_buffer
            // command, pointed at this executor's own control table FROM
            // SLOT 1 — slot 0 is `time` and is deliberately not writable
            // through this instruction, so the values are the DECLARED
            // controls in declaration order. The command carries a memory
            // address, not a data-section id, so it holds in both payload
            // modes (embedded and shared). A size that is not a multiple of
            // 4, or that runs past the declared controls, is the same
            // malformed latch the dispatcher's InvalidControlWrite is —
            // init()/frame() refuse and the host discards the buffer. The
            // JS dispatcher's own `dataLen > 0` gate is mirrored: an empty
            // write commands nothing (and keeps the decode-characterization
            // dumps free of a runtime address). Hand-read for the same size
            // reason as the guards; pinned by the comptime block below.
            const buffer = read_varint(bytecode, pc);
            const offset = read_varint(bytecode, pc);
            const size = read_varint(bytecode, pc);
            const count = size / 4;
            if (size % 4 != 0 or count > declared_controls) {
                malformed_body = true;
            } else if (size > 0) {
                cmds.writeBuffer(narrowId(buffer), @intCast(offset), dataAddr(&controls[1]), size);
            }
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
                cmds.beginRenderPassF32(
                    narrowId(o.color_texture_id),
                    o.load_op,
                    o.store_op,
                    narrowId(o.depth_texture_id),
                    o.clear_r_bits,
                    o.clear_g_bits,
                    o.clear_b_bits,
                    o.clear_a_bits,
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
                    // The clear channels arrive as raw f32 bit patterns (u32_le),
                    // like set_blend_constant's — see wire_schema's L_MRT.
                    const clear_r = readRawU32(bytecode, pc);
                    const clear_g = readRawU32(bytecode, pc);
                    const clear_b = readRawU32(bytecode, pc);
                    const clear_a = readRawU32(bytecode, pc);
                    attachments[i] = .{
                        .texture_id = narrowId(tex_id),
                        .load_op = @enumFromInt(load_op),
                        .store_op = @enumFromInt(store_op),
                        .clear_r_bits = clear_r,
                        .clear_g_bits = clear_g,
                        .clear_b_bits = clear_b,
                        .clear_a_bits = clear_a,
                    };
                }
                const depth_id = read_varint(bytecode, pc);
                cmds.beginRenderPassMrtF32(attachments[0..n], narrowId(depth_id));
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
            const actual_id: u16 = narrowId(o.base_id +% (frame_counter +% o.offset) % o.pool_size);
            cmds.setVertexBuffer(o.slot, actual_id);
        },
        .set_bind_group_pool => {
            const o = readOps(.set_bind_group_pool, bytecode, pc);

            // Guard `% pool_size`: hostile pool_size==0 would trap. Skip the op.
            if (o.pool_size == 0) return;
            // Calculate actual bind group ID: base_id + (frame_counter + offset) % pool_size
            const actual_id: u16 = narrowId(o.base_id +% (frame_counter +% o.offset) % o.pool_size);
            cmds.setBindGroup(o.slot, actual_id);
        },
        .begin_render_pass_pool => {
            const o = readOps(.begin_render_pass_pool, bytecode, pc);

            // Guard `% pool_size`: hostile pool_size==0 would trap. Skip the op.
            if (o.pool_size == 0) return;
            // Calculate actual texture ID: base_tex_id + (frame_counter + offset) % pool_size
            const actual_id: u16 = narrowId(o.base_tex_id +% (frame_counter +% o.offset) % o.pool_size);
            cmds.beginRenderPassF32(actual_id, o.load_op, o.store_op, narrowId(o.depth_tex_id), o.clear_r_bits, o.clear_g_bits, o.clear_b_bits, o.clear_a_bits, 0xFFFF);
        },
        else => {},
    }
}

// ============================================================================
// Internal - Frame Table Scan
// ============================================================================

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

            // Store frame entry: name_string_id → current PC (after params).
            // A name id past u16 names no string; `narrowId` latches the
            // malformed flag and the 0xFFFF entry matches no frame.
            frame_entries[frame_count] = .{
                .name_string_id = narrowId(name_id),
                .pc_offset = @intCast(pc), // Points to first opcode inside frame body
                .end_pc = @intCast(bytecode.len), // until the walk finds end_frame
            };
            frame_count += 1;

            // Debug: log frame definition
            dbg("frame[{d}] name_id={d} pc={d}", .{ frame_count - 1, name_id, pc });

            // Continue scanning - skip frame body to find next frame. The
            // first `end_frame` closes this frame (they do not nest); its
            // own pc IS the frame end the guard-skip check needs (§7.3).
            for (0..MAX_EXEC_ITERATIONS) |_| {
                if (pc >= bytecode.len) break;
                const inner_op: OpCode = @enumFromInt(bytecode[pc]);
                pc += 1;
                if (inner_op == .end_frame) {
                    frame_entries[frame_count - 1].end_pc = @intCast(pc - 1);
                    break;
                }
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

// The frame-body guard and write_controls decodes are HAND-READ (see their
// sites for the size reason: a `readOps` instantiation per layout costs the
// embedded executor ~150 B, and §8.1's caps do not have it). This comptime
// block pins the layouts those reads mirror — field count, order, and kind —
// so a wire_schema change is a BUILD FAILURE here, not a silent mis-decode;
// the behavioural suites (wasm_entry_controls_test, the shared agreement
// golden, and the wire fixtures that step these opcodes through
// skipOpcodeParams) cover the rest.
comptime {
    const exec_if_layout = wire_schema.layoutOf(.exec_if);
    std.debug.assert(exec_if_layout.head.len == 5);
    std.debug.assert(exec_if_layout.head[0].kind == .varint); // slot
    std.debug.assert(exec_if_layout.head[1].kind == .byte); // comparison
    std.debug.assert(exec_if_layout.head[2].kind == .u32_le); // constant, f32 bits
    std.debug.assert(exec_if_layout.head[3].kind == .byte); // skip_lo
    std.debug.assert(exec_if_layout.head[4].kind == .byte); // skip_hi

    const exec_skip_layout = wire_schema.layoutOf(.exec_skip);
    std.debug.assert(exec_skip_layout.head.len == 2);
    std.debug.assert(exec_skip_layout.head[0].kind == .byte); // skip_lo
    std.debug.assert(exec_skip_layout.head[1].kind == .byte); // skip_hi

    const write_controls_layout = wire_schema.layoutOf(.write_controls);
    std.debug.assert(write_controls_layout.head.len == 3);
    std.debug.assert(write_controls_layout.head[0].kind == .varint); // buffer
    std.debug.assert(write_controls_layout.head[1].kind == .varint); // offset
    std.debug.assert(write_controls_layout.head[2].kind == .varint); // size

    const define_control_layout = wire_schema.layoutOf(.define_control);
    std.debug.assert(define_control_layout.head.len == 1);
    std.debug.assert(define_control_layout.head[0].kind == .u32_le); // default, f32 bits
}
