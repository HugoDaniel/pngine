//! Bytecode Dispatcher
//!
//! Decodes PNGB bytecode and dispatches operations to GPU backend.
//! Uses a pluggable backend interface for testability.
//!
//! ## Design
//!
//! - **Generic backend**: Any type with required GPU methods works (MockGPU, NativeGPU)
//! - **Two-phase execution**: Pass definitions are recorded, then executed via exec_pass
//! - **Ping-pong support**: frame_counter enables double-buffering via pool operations
//! - **Bounded execution**: All loops have explicit max iterations (10000 for main, 1000 for passes)
//! - **Plugin-aware**: Commands are grouped by plugin (core/render/compute/texture/wasm)
//! - **Modular handlers**: Each opcode category is handled by a separate module in dispatcher/
//!
//! ## Architecture
//!
//! ```
//! PNGB Bytecode → Dispatcher.step() → Handler.handle() → Backend.method() → GPU calls
//!                     ↓
//!              pass_ranges map (for deferred exec_pass)
//! ```
//!
//! ## Handler Modules
//!
//! - resource.zig: create_buffer, create_texture, create_pipeline, etc.
//! - pass.zig: begin_render_pass, draw, dispatch, end_pass
//! - queue.zig: write_buffer, submit
//! - frame.zig: define_frame, exec_pass, define_pass
//! - pool.zig: set_*_pool operations
//! - wasm_ops.zig: init_wasm_module, call_wasm_func
//! - scanner.zig: OpcodeScanner for pass definition discovery
//!
//! ## Invariants
//!
//! - Bytecode is validated before execution (pc never exceeds bytecode.len)
//! - All resource IDs reference previously created resources
//! - Execution is deterministic (no randomness in dispatch)
//! - Pass definitions must end with end_pass_def before being executed
//! - frame_counter increments exactly once per end_frame opcode

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Use bytecode module import (named bytecode_mod to avoid conflict with local vars)
const bytecode_mod = @import("bytecode");
const opcodes = bytecode_mod.opcodes;
const OpCode = opcodes.OpCode;
const format = bytecode_mod.format;
const Module = format.Module;

const MockGPU = @import("mock_gpu.zig").MockGPU;

// Handler modules (pub for test access via module import)
pub const handlers = @import("dispatcher/handlers.zig");
const OpcodeScanner = handlers.OpcodeScanner;
const PassRange = handlers.PassRange;

/// Execution error types.
pub const ExecuteError = error{
    InvalidOpcode,
    UnexpectedEndOfBytecode,
    InvalidResourceId,
    PassNotEnded,
    NotInPass,
    /// A pass executed itself (directly or via a cycle) past the nesting cap.
    PassRecursionTooDeep,
    /// A count-prefixed opcode declared more elements than `wire_schema.repMaxOf`
    /// allows. Not a clamp-and-continue: the skipper walks `@min(count, max)`
    /// elements, so a larger count leaves the pc mid-operand and every following
    /// opcode is read out of the previous instruction's body.
    RepCountOverCap,
    /// A count-prefixed opcode declared ZERO elements where the instruction
    /// is meaningless without one: an MRT pass with no colour attachment (the
    /// backends took it as an empty slice; the native one asserted on it).
    RepCountEmpty,
    /// One execution asked for more instructions than it is allowed: more than
    /// `MAX_TOP_LEVEL_STEPS` at the top level, or more than `MAX_TOTAL_STEPS`
    /// counted across every nesting level (LEAK-09 B).
    ///
    /// A refusal, not a panic: the bound is a property of the INPUT (one step
    /// per opcode byte), so a long enough payload reaches it by construction.
    /// (r2-07)
    InstructionBudgetExhausted,
    /// The backend's call log filled. MockGPU-only — see `MockGPU.record`.
    /// A hostile stream can make one pass body run millions of times without
    /// tripping any per-level bound, and every one of those calls was recorded.
    CallBudgetExhausted,
    OutOfMemory,
    /// Command requires a plugin that is not enabled.
    PluginDisabled,
    /// Module not set on backend.
    ModuleNotSet,
    /// Surface texture unavailable for rendering.
    SurfaceTextureUnavailable,
    /// No surface configured for presentation.
    NoSurfaceConfigured,
    /// Texture not found in resource table.
    TextureNotFound,
    /// Shader compilation failed.
    ShaderCompilationFailed,
    /// Pipeline creation failed.
    PipelineCreationFailed,
    /// A descriptor omits a member the WebGPU IDL marks `required`. The
    /// compiler enforces required-ness (spec/09), so this is a malformed
    /// payload, not a document — and refusing it is what keeps the native
    /// backend from substituting a value the browser would have rejected.
    MissingRequiredMember,
};

/// Instruction budget for one top-level execution pass. Bounds the linear walk
/// over the bytecode; nested pass bodies carry their own caps (frame.zig's
/// PASS_MAX_ITERATIONS / PASS_MAX_DEPTH).
///
/// Exceeding it is a REFUSAL (`error.InstructionBudgetExhausted`), not a panic —
/// see the `else` branch in `execute_from_pc` for why the distinction matters
/// here and not in loops whose bound the input cannot reach.
pub const MAX_TOP_LEVEL_STEPS: u32 = 10_000;

/// Instruction budget for ONE pass body (`frame.zig executePass`). Above the
/// compiler's own ceiling — `MAX_FRAME_STEPS = 2048` commands per pass form,
/// each a few opcodes — so no compiled document reaches it, and reaching it is
/// a refusal (`error.InstructionBudgetExhausted`), not a silent stop: the old
/// `for (0..1000)` fell through, running the first 1000 ops of a longer pass and
/// dropping its `end_pass`. The product across nesting levels is bounded
/// separately by `MAX_TOTAL_STEPS`. (Third leak pass)
pub const PASS_MAX_ITERATIONS: u32 = 16_384;

/// Instruction budget for ONE execution counted across every nesting level —
/// the bound `MAX_TOP_LEVEL_STEPS` and frame.zig's per-pass caps cannot express
/// between them.
///
/// Each of those is individually correct and they compose by MULTIPLYING: a
/// chain of 60 distinct passes, each body running the next 1000 times, satisfies
/// the depth cap (60 < 64), satisfies every per-level loop bound (1000 ==
/// PASS_MAX_ITERATIONS), repeats no pass id so the cycle guard has no grounds to
/// fire — and asks for 1000^59 steps out of 120 KB of bytecode. Non-cyclic, so
/// nothing that watches for cycles sees it; the browser executor is immune only
/// because it does not recurse at all (`wasm_entry` routes a nested `exec_pass`
/// to `skipOpcodeParams`). This is the native/`inspect` path's bound.
///
/// 1M is ~100× the largest honest payload: the top level is capped at 10_000
/// instructions and each of a frame's passes adds hundreds.
pub const MAX_TOTAL_STEPS: u32 = 1_000_000;

/// One entry in the backend contract: a method name plus the parameter types
/// that follow the universal `self: *T, allocator: Allocator` prefix.
///
/// Every contract method has the shape `fn(*Self, Allocator, ...) !void`, so
/// only the tail varies and only the tail is spelled out here.
pub const MethodSpec = struct {
    name: []const u8,
    params: []const type = &.{},
};

const ColorAttachment = bytecode_mod.emitter.Emitter.ColorAttachment;

/// The COMPLETE backend contract: it mirrors the `self.backend.<method>(...)`
/// call sites in dispatcher/{resource,pass,queue,pool,wasm_ops}.zig. When a
/// handler begins calling a new backend method, add it here too. (pool.zig
/// reuses set_vertex_buffer / set_bind_group / begin_render_pass, so it adds
/// nothing new.)
pub const CONTRACT = [_]MethodSpec{
    // Resource creation (dispatcher/resource.zig)
    .{ .name = "create_buffer", .params = &.{ u16, u32, u16 } },
    .{ .name = "create_texture", .params = &.{ u16, u16 } },
    .{ .name = "create_sampler", .params = &.{ u16, u16 } },
    .{ .name = "create_shader_module", .params = &.{ u16, u16 } },
    .{ .name = "create_render_pipeline", .params = &.{ u16, u16 } },
    .{ .name = "create_compute_pipeline", .params = &.{ u16, u16 } },
    .{ .name = "create_bind_group", .params = &.{ u16, u16, u16 } },
    .{ .name = "create_bind_group_layout", .params = &.{ u16, u16 } },
    .{ .name = "create_pipeline_layout", .params = &.{ u16, u16 } },
    .{ .name = "create_image_bitmap", .params = &.{ u16, u16 } },
    .{ .name = "create_texture_view", .params = &.{ u16, u16, u16 } },
    .{ .name = "create_query_set", .params = &.{ u16, u16 } },
    .{ .name = "create_render_bundle", .params = &.{ u16, u16 } },

    // Pass operations (dispatcher/pass.zig)
    .{ .name = "begin_render_pass", .params = &.{ u16, u8, u8, u16, u32, u32, u32, u32, u16 } },
    .{ .name = "begin_render_pass_mrt", .params = &.{ []const ColorAttachment, u16 } },
    .{ .name = "begin_compute_pass" },
    .{ .name = "set_pipeline", .params = &.{u16} },
    .{ .name = "set_bind_group", .params = &.{ u8, u16 } },
    .{ .name = "set_vertex_buffer", .params = &.{ u8, u16 } },
    .{ .name = "set_index_buffer", .params = &.{ u16, u8 } },
    .{ .name = "draw", .params = &.{ u32, u32, u32, u32 } },
    .{ .name = "draw_indexed", .params = &.{ u32, u32, u32, u32, u32 } },
    .{ .name = "dispatch", .params = &.{ u32, u32, u32 } },
    .{ .name = "draw_indirect", .params = &.{ u16, u32 } },
    .{ .name = "draw_indexed_indirect", .params = &.{ u16, u32 } },
    .{ .name = "dispatch_indirect", .params = &.{ u16, u32 } },
    .{ .name = "set_viewport", .params = &.{ u32, u32, u32, u32, u32, u32 } },
    .{ .name = "set_pass_occlusion_query_set", .params = &.{u16} },
    .{ .name = "set_pass_timestamp_writes", .params = &.{ u16, u32, u32 } },
    .{ .name = "begin_occlusion_query", .params = &.{u32} },
    .{ .name = "end_occlusion_query" },
    .{ .name = "set_stencil_reference", .params = &.{u32} },
    .{ .name = "set_scissor_rect", .params = &.{ u32, u32, u32, u32 } },
    .{ .name = "set_pass_depth_stencil_ops", .params = &.{ u8, u8, u8, u8 } },
    .{ .name = "set_blend_constant", .params = &.{ u32, u32, u32, u32 } },
    .{ .name = "set_pass_clear_values", .params = &.{ u32, u32 } },
    .{ .name = "execute_bundles", .params = &.{[]const u16} },
    .{ .name = "end_pass" },

    // Queue operations (dispatcher/queue.zig)
    .{ .name = "write_buffer", .params = &.{ u16, u32, u16 } },
    .{ .name = "write_time_uniform", .params = &.{ u16, u32, u16 } },
    .{ .name = "write_pointer_uniform", .params = &.{ u16, u32, u16 } },
    .{ .name = "write_audio_data", .params = &.{ u16, u32, u16 } },
    .{ .name = "copy_external_image_to_texture", .params = &.{ u16, u16, u8, u16, u16, u16 } },
    .{ .name = "copy_buffer_to_buffer", .params = &.{ u16, u32, u16, u32, u32 } },
    .{ .name = "copy_texture_to_texture", .params = &.{ u16, u16 } },
    .{ .name = "write_uniform", .params = &.{ u16, u16 } },
    .{ .name = "resolve_query_set", .params = &.{ u16, u32, u32, u16, u32 } },
    .{ .name = "submit" },

    // Nested-WASM operations (dispatcher/wasm_ops.zig)
    .{ .name = "init_wasm_module", .params = &.{ u16, u16 } },
    .{ .name = "call_wasm_func", .params = &.{ u16, u16, u16, []const u8 } },
    .{ .name = "write_buffer_from_wasm", .params = &.{ u16, u16, u32, u32 } },
};

/// GPU backend interface.
/// Any type implementing these methods can be used.
pub fn Backend(comptime T: type) type {
    return struct {
        /// Verify the backend implements every contract method with the right
        /// SIGNATURE, not merely the right name. `Dispatcher(T)` runs this at
        /// comptime (below), so a backend that is missing a method — or has one
        /// with the wrong arity or parameter types — is a COMPILE ERROR at
        /// instantiation naming the offending method, rather than a confusing
        /// failure deep inside a handler.
        ///
        /// Checking names alone (the previous behaviour) let a wrong-arity
        /// backend through validate() and blew up later at the call site, which
        /// is exactly what this contract exists to prevent.
        pub fn validate() void {
            comptime {
                for (CONTRACT) |spec| {
                    if (mismatch(spec)) |reason| @compileError(reason);
                }
            }
        }

        /// Compare one method against its spec, returning `null` when it
        /// conforms or a human-readable reason when it does not.
        ///
        /// `validate()` turns a reason into a `@compileError`. This
        /// non-erroring form exists so tests can prove the checker actually
        /// rejects bad signatures — a `@compileError` cannot be caught at
        /// runtime, so without this the checker itself would be untestable and
        /// could silently degrade into the name-only check it replaced.
        ///
        /// The error SET is deliberately not compared: every backend infers its
        /// own from its body, so only the `!void` payload must match.
        pub fn mismatch(comptime spec: MethodSpec) ?[]const u8 {
            if (!@hasDecl(T, spec.name)) {
                return "backend " ++ @typeName(T) ++ " is missing method '" ++
                    spec.name ++ "' required by the dispatcher contract";
            }

            const Fn = @TypeOf(@field(T, spec.name));
            const info = switch (@typeInfo(Fn)) {
                .@"fn" => |f| f,
                else => return "backend " ++ @typeName(T) ++ "." ++ spec.name ++
                    " must be a function, found " ++ @typeName(Fn),
            };

            // self + allocator + the spec tail.
            const want_len = 2 + spec.params.len;
            if (info.params.len != want_len) {
                return std.fmt.comptimePrint(
                    "backend {s}.{s} takes {d} parameter(s), contract requires {d} " ++
                        "(self, allocator, and {d} operand(s))",
                    .{ @typeName(T), spec.name, info.params.len, want_len, spec.params.len },
                );
            }

            if (paramMismatch(info, spec, 0, *T)) |reason| return reason;
            if (paramMismatch(info, spec, 1, Allocator)) |reason| return reason;
            inline for (spec.params, 0..) |Want, i| {
                if (paramMismatch(info, spec, i + 2, Want)) |reason| return reason;
            }

            const Ret = info.return_type orelse
                return "backend " ++ @typeName(T) ++ "." ++ spec.name ++ " has no return type";
            const payload = switch (@typeInfo(Ret)) {
                .error_union => |eu| eu.payload,
                else => Ret,
            };
            if (payload != void) {
                return "backend " ++ @typeName(T) ++ "." ++ spec.name ++
                    " must return !void, found " ++ @typeName(Ret);
            }

            return null;
        }

        fn paramMismatch(
            comptime info: std.builtin.Type.Fn,
            comptime spec: MethodSpec,
            comptime index: usize,
            comptime Want: type,
        ) ?[]const u8 {
            const Got = info.params[index].type orelse
                return std.fmt.comptimePrint(
                    "backend {s}.{s} parameter {d} is untyped (anytype); the contract requires {s}",
                    .{ @typeName(T), spec.name, index, @typeName(Want) },
                );
            if (Got != Want) {
                return std.fmt.comptimePrint(
                    "backend {s}.{s} parameter {d} is {s}, contract requires {s}",
                    .{ @typeName(T), spec.name, index, @typeName(Got), @typeName(Want) },
                );
            }
            return null;
        }
    };
}

/// Maximum number of passes to track.
const MAX_PASSES: u16 = 256;

/// One `define_frame` found by `scan_frame_definitions`: the frame's name in the
/// string table, and the pc of the first opcode of its body. The native twin of
/// wasm_entry's `frame_entries`.
pub const FrameEntry = struct {
    name_string_id: u16,
    pc: u32,
};

/// Bytecode dispatcher.
pub fn Dispatcher(comptime BackendType: type) type {
    // Validate backend at comptime
    Backend(BackendType).validate();

    return struct {
        const Self = @This();

        /// GPU backend to dispatch calls to.
        backend: *BackendType,

        /// Module being executed.
        module: *const Module,

        /// Current bytecode position.
        pc: u32,

        /// Execution state.
        in_pass_def: bool,
        in_frame_def: bool,

        /// Pass bytecode ranges for exec_pass.
        pass_ranges: std.AutoHashMap(u16, PassRange),

        /// Passes executed via exec_pass_once (run-once tracking).
        ///
        /// Keyed per pass id for the life of the dispatcher — "once" means once
        /// per loaded payload, and re-arming is a new dispatcher (native) or a
        /// new `init()` (browser). The shipping executor agreed to this in §347;
        /// see docs/abi.md §7 and tests/zig/executor/wasm_entry_once_test.zig.
        executed_once: std.AutoHashMap(u16, void),

        /// Frame body pcs in document order, populated by `execute_init`.
        /// Empty until then — `select_frame_pc` returns null, which is how a
        /// caller learns a payload has no frame to render.
        frame_entries: std.ArrayList(FrameEntry),

        /// Current pass ID being defined (for tracking range).
        current_pass_id: ?u16,

        /// Start position of current pass definition.
        current_pass_start: u32,

        /// Frame counter for ping-pong pool calculations.
        frame_counter: u32,

        /// Nesting depth of executePass, guarded against a cyclic exec_pass
        /// (a pass body that runs itself, directly or via a cycle). The per-pass
        /// loop is bounded (PASS_MAX_ITERATIONS) but the recursion through
        /// step → exec_pass → executePass is not — without this a crafted cycle
        /// blows the native stack. (Arc-3 §2.2b)
        pass_exec_depth: u32,

        /// Steps left in the CURRENT execution, across every nesting level.
        /// Reset by each `execute_*` entry point — a viewer calls
        /// `execute_frame_body` once per frame for as long as the page is open,
        /// so a counter that accumulated across calls would refuse frame N of a
        /// perfectly ordinary payload. The bound is on one execution's fan-out.
        /// (LEAK-09 B)
        steps_remaining: u32,

        /// Allocator for internal data structures (pass_ranges map).
        allocator: Allocator,

        /// Initialize dispatcher with default frame counter.
        ///
        /// Complexity: O(1)
        /// Memory: Allocates hashmap for pass ranges (grows on demand).
        pub fn init(allocator: Allocator, backend: *BackendType, module: *const Module) Self {
            return init_with_frame(allocator, backend, module, 0);
        }

        /// Initialize with a specific frame counter (for animation loops).
        ///
        /// The frame_counter enables ping-pong buffer patterns where:
        /// actual_id = base_id + (frame_counter + offset) % pool_size
        ///
        /// Complexity: O(1)
        pub fn init_with_frame(allocator: Allocator, backend: *BackendType, module: *const Module, initial_frame: u32) Self {
            // Pre-conditions
            assert(module.bytecode.len <= 1024 * 1024); // 1MB max bytecode

            return .{
                .backend = backend,
                .module = module,
                .pc = 0,
                .in_pass_def = false,
                .in_frame_def = false,
                .pass_ranges = std.AutoHashMap(u16, PassRange).init(allocator),
                .executed_once = std.AutoHashMap(u16, void).init(allocator),
                .frame_entries = .empty,
                .current_pass_id = null,
                .current_pass_start = 0,
                .frame_counter = initial_frame,
                .pass_exec_depth = 0,
                .steps_remaining = MAX_TOTAL_STEPS,
                .allocator = allocator,
            };
        }

        /// Clean up dispatcher state.
        pub fn deinit(self: *Self) void {
            self.pass_ranges.deinit();
            self.executed_once.deinit();
            self.frame_entries.deinit(self.allocator);
        }

        /// Scan bytecode for pass definitions and populate pass_ranges.
        /// This is needed before executing a single frame, since exec_pass
        /// opcodes within the frame need to reference pass ranges.
        ///
        /// Fallible by design: silently dropping a range on OOM would leave a
        /// later `exec_pass` executing nothing, i.e. a wrong render reported as
        /// a success. See OpcodeScanner.scan_pass_definitions.
        ///
        /// Complexity: O(bytecode.len)
        pub fn scan_pass_definitions(self: *Self) Allocator.Error!void {
            // Pre-condition: module bytecode is valid
            assert(self.module.bytecode.len <= 1024 * 1024);

            // Delegate to OpcodeScanner
            var scanned = try OpcodeScanner.scan_pass_definitions(self.module.bytecode, self.allocator);
            defer scanned.deinit();

            // Merge scanned ranges into our map
            var it = scanned.iterator();
            while (it.next()) |entry| {
                try self.pass_ranges.put(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Post-condition: pass_ranges may have entries (or empty if no passes)
        }

        /// Skip opcode parameters at a given position (for scanning without executing).
        /// Made public for use by CLI frame scanning and tests.
        pub fn skip_opcode_params_at(bytecode: []const u8, pc: *u32, op: OpCode) void {
            var scanner = OpcodeScanner.init(bytecode, pc.*);
            scanner.skip_params(op);
            pc.* = scanner.pc;
        }

        // ====================================================================
        // The init/frame split
        //
        // `execute_all` walks the whole stream once, which is right for a CLI
        // that renders a single frame and exits. A LOOP — a viewer, the C ABI's
        // `pngine_render` — must not replay resource creation per frame, so it
        // uses the three methods below: `execute_init` once, then
        // `select_frame_pc` + `execute_frame_body` per frame.
        //
        // The browser executor has always been split this way
        // (`wasm_entry.init()` / `frame()`); this is the reference dispatcher
        // growing the same shape so both executors run a payload the same
        // number of times. Before §347 the C ABI replayed from pc 0 every
        // frame, which is why a create opcode without a `table[id] != null`
        // guard leaked per frame (LEAK-02) and why every static `write_buffer`
        // re-uploaded its blob at frame rate.
        // ====================================================================

        /// Execute the init region: everything before the first `define_frame`,
        /// then record where each frame body starts.
        ///
        /// Mirrors `wasm_entry.executeResourceCreation` + `scanFrameDefinitions`.
        /// Pass definitions are recorded on the way through by the `define_pass`
        /// handler, exactly as they are in the browser — which is what makes a
        /// later `exec_pass` from inside a frame body resolvable.
        ///
        /// Complexity: O(init region + bytecode.len)
        pub fn execute_init(self: *Self, allocator: Allocator) ExecuteError!void {
            const bytecode = self.module.bytecode;
            self.pc = 0;
            self.steps_remaining = MAX_TOTAL_STEPS;

            for (0..MAX_TOP_LEVEL_STEPS) |_| {
                if (self.pc >= bytecode.len) break;
                const op: OpCode = @enumFromInt(bytecode[self.pc]);
                if (op == .define_frame) break;
                try self.step(allocator);
            } else {
                // Same reasoning as execute_from_pc: the bound is one step per
                // opcode byte, so a long enough payload reaches it by
                // construction. A refusal, not a panic.
                return error.InstructionBudgetExhausted;
            }

            try self.scan_frame_definitions();

            // Post-condition: stopped at a frame definition or at the end.
            assert(self.pc <= bytecode.len);
        }

        /// Record the body pc of every `define_frame` in the stream.
        ///
        /// Walks the whole payload rather than stopping at the first frame:
        /// scene selection needs them all. Body opcodes are walked too and
        /// simply skipped — frames do not nest, so nothing is mis-recorded.
        fn scan_frame_definitions(self: *Self) Allocator.Error!void {
            const bytecode = self.module.bytecode;
            self.frame_entries.clearRetainingCapacity();

            var pc: u32 = 0;
            for (0..MAX_TOP_LEVEL_STEPS) |_| {
                if (pc >= bytecode.len) break;

                const op: OpCode = @enumFromInt(bytecode[pc]);
                pc += 1;

                if (op != .define_frame) {
                    skip_opcode_params_at(bytecode, &pc, op);
                    continue;
                }

                // frame_id, then name_string_id. Decoded length-tolerantly: a
                // truncated varint at the end of a hostile stream must end the
                // scan, not trap.
                const frame_id = opcodes.decode_varint_safe(bytecode[pc..]);
                if (frame_id.len == 0) break;
                pc += @intCast(frame_id.len);
                if (pc >= bytecode.len) break;
                const name = opcodes.decode_varint_safe(bytecode[pc..]);
                if (name.len == 0) break;
                pc += @intCast(name.len);

                try self.frame_entries.append(self.allocator, .{
                    .name_string_id = @truncate(name.value),
                    .pc = pc,
                });
            }

            // Post-condition: every recorded pc addresses a byte we could read.
            for (self.frame_entries.items) |entry| assert(entry.pc <= bytecode.len);
        }

        /// The pc of the frame body to run at `time_seconds`: the animation
        /// scene's frame if the payload has a timeline, else the first frame.
        ///
        /// Mirrors `wasm_entry.executeFrame`'s selection, loop wrap included.
        /// Returns null when the payload defines no frame at all.
        pub fn select_frame_pc(self: *const Self, time_seconds: f32) ?u32 {
            if (self.frame_entries.items.len == 0) return null;

            const anim = &self.module.animation;
            if (anim.info) |info| {
                // A host may hand us any f32 — negative, NaN, or past u32
                // milliseconds. Saturate rather than let @intFromFloat trap.
                const scaled = time_seconds * 1000.0;
                const time_ms: u32 = if (!(scaled > 0.0))
                    0
                else if (scaled >= 4_294_967_000.0)
                    std.math.maxInt(u32)
                else
                    @intFromFloat(scaled);

                const effective = if (info.loop and info.duration_ms > 0)
                    time_ms % info.duration_ms
                else
                    time_ms;

                if (anim.findSceneAtTime(effective)) |scene_idx| {
                    if (anim.getScene(scene_idx)) |scene| {
                        for (self.frame_entries.items) |entry| {
                            if (entry.name_string_id == scene.frame_string_id) return entry.pc;
                        }
                    }
                }
            }

            return self.frame_entries.items[0].pc;
        }

        /// Execute one frame body from `pc` through its `end_frame`.
        ///
        /// `end_frame` is executed, not merely reached: it carries the
        /// frame_counter increment, and the counter IS the ping-pong pool phase.
        /// One increment per call is the property — the pre-split replay
        /// advanced it once per `define_frame` in the whole document, so a
        /// two-scene payload inverted every pooled binding on native and not in
        /// the browser.
        pub fn execute_frame_body(self: *Self, allocator: Allocator) ExecuteError!void {
            const bytecode = self.module.bytecode;

            // Pre-condition: a pc from select_frame_pc, or the end.
            assert(self.pc <= bytecode.len);
            const start = self.pc;
            self.steps_remaining = MAX_TOTAL_STEPS;

            for (0..MAX_TOP_LEVEL_STEPS) |_| {
                if (self.pc >= bytecode.len) break;
                const op: OpCode = @enumFromInt(bytecode[self.pc]);
                try self.step(allocator);
                if (op == .end_frame) break;
            } else {
                return error.InstructionBudgetExhausted;
            }

            // Post-condition: the pc never rewinds.
            assert(self.pc >= start);
        }

        /// Execute all bytecode.
        pub fn execute_all(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: start at beginning
            assert(self.pc == 0);

            try self.execute_from_pc(allocator);

            // Post-condition: consumed all bytecode
            assert(self.pc == self.module.bytecode.len);
        }

        /// Execute bytecode from current PC to end.
        /// Use this when starting from a non-zero position (e.g., skipping resource creation).
        pub fn execute_from_pc(self: *Self, allocator: Allocator) ExecuteError!void {
            // Pre-condition: pc within bounds or at end
            assert(self.pc <= self.module.bytecode.len);
            self.steps_remaining = MAX_TOTAL_STEPS;

            const bytecode = self.module.bytecode;

            for (0..MAX_TOP_LEVEL_STEPS) |_| {
                if (self.pc >= bytecode.len) break;
                try self.step(allocator);
            } else {
                // NOT `unreachable`. The mastery rule's `for (0..MAX) else
                // unreachable` is for bounds nothing outside the code can move;
                // this one is one step per opcode byte, so ANY payload longer
                // than the budget reaches it — 10_001 `nop`s do, which is a
                // corpus case now. Left as `unreachable` it was a Debug panic in
                // `pngine inspect` and, worse, undefined behaviour in the
                // shipping ReleaseFast npm binary, on nothing more exotic than a
                // long PNG from the web. (r2-07)
                return error.InstructionBudgetExhausted;
            }

            // Post-condition: consumed all bytecode
            assert(self.pc == bytecode.len);
        }

        /// Execute single instruction.
        ///
        /// Reads the opcode byte, then dispatches to the handler module for its
        /// category. Each handler arm decodes its operands through the shared
        /// wire schema (`wire_schema.readOperands`) and calls the backend — the
        /// decode/effect split — so this function stays a thin category router.
        pub fn step(self: *Self, allocator: Allocator) ExecuteError!void {
            const bytecode = self.module.bytecode;

            // Both refusals come BEFORE the monotonic-pc `defer` below: neither
            // advances the pc, so registering it first would turn a clean
            // refusal into an assertion failure on the way out.
            if (self.steps_remaining == 0) return error.InstructionBudgetExhausted;
            self.steps_remaining -= 1;

            // Pre-condition: valid PC
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;
            const pc_start = self.pc;
            assert(pc_start < bytecode.len); // pre: opcode byte is readable
            // Post-condition (every return path): a step advances the PC
            // monotonically — it consumes the opcode byte plus each handler's
            // operands and never rewinds.
            defer assert(self.pc > pc_start);

            const op: OpCode = @enumFromInt(bytecode[self.pc]);
            self.pc += 1;

            // Try each handler in priority order
            // Resource creation
            if (handlers.resource.is_resource_opcode(op)) {
                _ = try handlers.resource.handle(Self, self, op, allocator);
                return;
            }

            // Pass operations
            if (handlers.pass.is_pass_opcode(op)) {
                _ = try handlers.pass.handle(Self, self, op, allocator);
                return;
            }

            // Queue operations
            if (handlers.queue.is_queue_opcode(op)) {
                _ = try handlers.queue.handle(Self, self, op, allocator);
                return;
            }

            // Frame control
            if (handlers.frame.is_frame_opcode(op)) {
                _ = try handlers.frame.handle(Self, self, op, allocator);
                return;
            }

            // Pool operations
            if (handlers.pool.is_pool_opcode(op)) {
                _ = try handlers.pool.handle(Self, self, op, allocator);
                return;
            }

            // WASM operations
            if (handlers.wasm_ops.is_wasm_opcode(op)) {
                _ = try handlers.wasm_ops.handle(Self, self, op, allocator);
                return;
            }

            // Special cases
            switch (op) {
                .nop => {},

                // Unimplemented opcodes
                .create_shader_concat,
                .select_from_pool,
                => return error.InvalidOpcode,

                else => return error.InvalidOpcode,
            }
        }

        // ====================================================================
        // Bytecode Reading
        // ====================================================================

        pub fn read_byte(self: *Self) ExecuteError!u8 {
            const bytecode = self.module.bytecode;
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            const byte = bytecode[self.pc];
            self.pc += 1;
            return byte;
        }

        pub fn read_varint(self: *Self) ExecuteError!u32 {
            const bytecode = self.module.bytecode;
            if (self.pc >= bytecode.len) return error.UnexpectedEndOfBytecode;

            // decode_varint asserts the full 2/4-byte encoding is present; a
            // hostile stream can end right after a multi-byte lead byte, so
            // decode length-tolerantly and treat a truncated encoding (len == 0)
            // as end-of-bytecode rather than a panic — the native dispatcher
            // runs Debug/ReleaseSafe, where the assert would trap. (Arc-3 §2.2a)
            const result = opcodes.decode_varint_safe(bytecode[self.pc..]);
            if (result.len == 0) return error.UnexpectedEndOfBytecode;
            self.pc += result.len;
            return result.value;
        }

        /// Read a raw 4-byte little-endian u32 (used for f32 bit patterns).
        pub fn read_raw_u32(self: *Self) ExecuteError!u32 {
            const bytecode = self.module.bytecode;
            if (self.pc + 4 > bytecode.len) return error.UnexpectedEndOfBytecode;

            const value = std.mem.readInt(u32, bytecode[self.pc..][0..4], .little);
            self.pc += 4;
            return value;
        }
    };
}

/// Convenience type alias for MockGPU dispatcher.
pub const MockDispatcher = Dispatcher(MockGPU);

// Dedicated tests moved to tests/zig/executor/dispatcher_test.zig
