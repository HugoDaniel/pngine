//! PNGine: A register-based bytecode interpreter for WebGPU.
//!
//! This module provides:
//! - The PNGB (binary) bytecode format and its SJON frontend
//! - Bytecode execution with pluggable GPU backends
//! - Runtime data generation (procedural arrays)
//!
//! Invariants:
//! - All allocation happens at init, not during frame execution
//! - Bytecode execution is deterministic (seeded PRNG)
//! - Resource IDs are dense indices into fixed-size tables

const std = @import("std");

// Core types (zero-dependency, enables parallel compilation)
// Uses module import provided by build.zig
pub const types = @import("types");

// Bytecode (module import to avoid conflict with bytecode/standalone.zig)
const bytecode_mod = @import("bytecode");
pub const string_table = bytecode_mod.string_table;
pub const data_section = bytecode_mod.data_section;
pub const opcodes = bytecode_mod.opcodes;
pub const wire_schema = bytecode_mod.wire_schema;
pub const emitter = bytecode_mod.emitter;
pub const format = bytecode_mod.format;
pub const uniform_table = bytecode_mod.uniform_table;

// Executor (use module import)
const executor_mod = @import("executor");
pub const mock_gpu = executor_mod.mock_gpu;
pub const dispatcher = executor_mod.dispatcher;
pub const command_buffer = executor_mod.command_buffer;
pub const plugins = executor_mod.plugins;
pub const variant = executor_mod.variant;

// Executor types for backward compatibility
pub const MockGPU = executor_mod.MockGPU;
pub const Dispatcher = executor_mod.Dispatcher;
pub const MockDispatcher = executor_mod.MockDispatcher;
pub const Variant = executor_mod.Variant;
pub const selectVariant = executor_mod.selectVariant;

// executor_test.zig moved to tests/zig/executor/executor_test.zig
// Discovered by tests/zig/test_executor.zig dedicated test step

// GPU backends. The CLI `--frame` path renders through `NativeGPU`; which
// backend that is is chosen at build time by the `-Dgpu-native` option (default:
// a macOS host with the vendored wgpu-native lib present). When it is OFF the
// untaken `@import` of wgpu_native_gpu.zig is never analyzed, so no @cImport
// fires and the artifact links no GPU library — this is what keeps `zig build
// npm` cross binaries lean and buildable for Linux/Windows (no vendored libs).
pub const gpu_backends = struct {
    pub const has_wgpu_native = @import("gpu_build_options").has_wgpu_native;
    pub const headless_gpu = @import("gpu/headless_gpu.zig");

    pub const NativeGPU = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").WgpuNativeGPU
    else
        headless_gpu.NullGPU;

    // Force the backend contract to be checked for whichever NativeGPU this
    // build selected. Without this the GPU-less backend goes UNVERIFIED: the
    // only `Dispatcher(NativeGPU)` instantiation sits behind render paths that
    // a GPU-less build never analyzes, so nothing type-checks its ~46 methods.
    // That is how it drifted a missing `origin_z` parameter on
    // copy_external_image_to_texture. Instantiating the type is comptime-only
    // (it runs Backend(T).validate() and emits no code).
    comptime {
        _ = executor_mod.Dispatcher(NativeGPU);

        // …and NullGPU unconditionally, even when it is NOT the selected
        // backend. `NativeGPU` above is WgpuNativeGPU whenever
        // `vendor/wgpu-native` is present, which it is on the macOS host every
        // gate runs on — so the line above validated the native backend and
        // left the GPU-less one unchecked. The builds that DO select NullGPU
        // are the ones nobody makes by hand: the six `zig build npm` cross
        // targets and the public release cut (a fresh clone has no gitignored
        // `vendor/`). That is how `begin_render_pass` kept four `u8` clear
        // values after the contract widened them to `u32` bit patterns — it
        // broke both, while `zig build`, `drift` and the full suite stayed
        // green (§377). Comptime-only: it emits no code and links nothing.
        _ = executor_mod.Dispatcher(headless_gpu.NullGPU);
    }

    /// Shared GPU context (instance/adapter/device/queue) for the native
    /// backend. `void` in GPU-less builds — the `--frame` path hard-errors
    /// before ever referencing it, so the type is never instantiated there.
    pub const Context = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").Context
    else
        void;

    /// Native-oracle uncaptured-error capture (Arc-3 §1.1). No-op stubs in
    /// GPU-less builds so render.zig can consult it unconditionally.
    pub const oracle = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").oracle
    else
        struct {
            pub fn reset() void {}
            pub fn hadError() bool {
                return false;
            }
            pub fn message() []const u8 {
                return "";
            }
        };

    /// The raw wgpu-native bindings. Exported so the native lifetime gates can
    /// build a surface of their own (a bare CAMetalLayer, no window) and reach
    /// the windowed code path `--frame` never takes. `void` in GPU-less builds.
    pub const wgpu = if (has_wgpu_native)
        @import("gpu/wgpu_c.zig")
    else
        void;

    /// wgpu refcount ledger (LEAK-01): per-kind acquire/release counters wrapped
    /// around the C bindings, so a test can assert the backend's live-object
    /// vector is flat across frames. `void` in GPU-less builds — there are no
    /// wgpu references to count, and the balance tests only build with the
    /// backend (the same stance `Context` takes).
    pub const lifetimes = if (has_wgpu_native)
        @import("gpu/wgpu_c.zig").lifetimes
    else
        void;

    /// A windowless `CAMetalLayer` factory, so a test binary can build a real
    /// surface (LEAK-04). Exposed here for the same reason `native_api` is: the
    /// shim must live in ONE module, or the two test roots that need it end up
    /// with two copies of an `objc_msgSend` signature.
    pub const metal_layer = @import("gpu/metal_layer.zig");

    /// Authored device limits (Arc-3 §5.3b): the WGPULimits type + its builder.
    /// Only the native render path (comptime-unreachable in GPU-less builds)
    /// uses these, so a `void` type + no-op builder keep the decls type-checking.
    pub const RequiredLimits = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").RequiredLimits
    else
        void;

    pub const buildRequiredLimits = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").buildRequiredLimits
    else
        struct {
            fn noop(_: *const anyopaque) void {}
        }.noop;

    /// Native-stub honesty (Arc-3 §1.2). No-op stubs in GPU-less builds.
    pub const stub = if (has_wgpu_native)
        @import("executor/wgpu_native_gpu.zig").stub
    else
        struct {
            pub fn reset() void {}
            pub fn anyHit() bool {
                return false;
            }
        };

    /// The public C ABI (`pngine_create`/`pngine_render`/…) that the iOS,
    /// Android and desktop viewers link against.
    ///
    /// Exposed here for one reason: until r2-01 this file sat in NO build
    /// target — `grep native_api build.zig` came back empty — so nothing
    /// compiled it, nothing could test it, and it was free to rot against the
    /// backend it drives. Reaching it THROUGH lib_module (rather than as its
    /// own module rooted at native_api.zig) is deliberate: native_api.zig
    /// imports wgpu_native_gpu.zig by file, and a second module rooted there
    /// would collide with this one in any binary holding both ("file exists in
    /// multiple modules" — the same constraint documented at the top of this
    /// struct and in build.zig's render_test_mod). GPU-less builds never
    /// analyze it, exactly like `NativeGPU` above.
    pub const native_api = if (has_wgpu_native)
        @import("native_api.zig")
    else
        struct {};
};

// ZIP bundle support
pub const zip = @import("zip.zig");

// WGSL Reflection (via wgslender) - use module import
pub const reflect = @import("reflect");

// PNG embedding/extraction/encoding
pub const png = struct {
    pub const crc32 = @import("png/crc32.zig");
    pub const chunk = @import("png/chunk.zig");
    pub const embed = @import("png/embed.zig");
    pub const extract = @import("png/extract.zig");
    pub const encoder = @import("png/encoder.zig");
    pub const decoder = @import("png/decoder.zig");
    pub const compare = @import("png/compare.zig");
    pub const diff = @import("png/diff.zig");

    // Re-export main types
    pub const Chunk = chunk.Chunk;
    pub const ChunkType = chunk.ChunkType;
    pub const PNG_SIGNATURE = chunk.PNG_SIGNATURE;

    // Re-export bytecode functions
    pub const embedBytecode = embed.embed;
    pub const embedAudio = embed.embedAudio;
    pub const embedFlat = embed.embedFlat;
    pub const extractBytecode = extract.extract;
    pub const hasPngb = extract.hasPngb;
    pub const getPngbInfo = extract.getPngbInfo;
    pub const enumerateChunks = extract.enumerateChunks;
    pub const ChunkEntry = extract.ChunkEntry;

    // Re-export encoder functions
    pub const encode = encoder.encode;
    pub const encodeBGRA = encoder.encodeBGRA;

    // Re-export decoder + comparator (render-test pixel assertions)
    pub const decode = decoder.decode;
    pub const Image = decoder.Image;
    pub const compareImages = compare.compare;
    pub const CompareConfig = compare.Config;

    // Re-export the encoded-PNG differ (backs `pngine diff`)
    pub const diffEncoded = diff.diffEncoded;
    pub const DiffOutcome = diff.Outcome;
};

// SJON-backed compiler (the `.sjon` frontend; PNGine is a SJON host). The legacy
// `.pngine` macro DSL (Phase 5 B2) and the `.pbsf` assembler were retired;
// `.sjon` is the sole source frontend.
// Shares the bytecode backend, so `dsl_sjon.PluginSet` == `format.PluginSet` and
// the CLI/WASM switch on file extension without caring which frontend ran. Wired
// as a separate module in build.zig (`dsl_sjon_mod`) reusing lib_module's
// bytecode/executor instances. See Phase 3 in the migration plan.
pub const dsl_sjon = struct {
    const mod = @import("dsl_sjon");
    pub const Compiler = mod.Compiler;
    pub const compile = Compiler.compile;
    pub const compileWithOptions = Compiler.compileWithOptions;
    pub const compileWithPlugins = Compiler.compileWithPlugins;
};

// DescriptorEncoder — the single canonical export. Sources the vendored
// `src/dsl_sjon/` copy (a byte-identical descendant of the legacy
// `dsl/DescriptorEncoder.zig`) via the `dsl_sjon` module boundary; `cli/inspect.zig`
// reads its `DescriptorType` enum.
pub const DescriptorEncoder = @import("dsl_sjon").DescriptorEncoder;

// PluginSet — the single canonical export, consumed by cli/compile.zig and
// cli/render.zig as `pngine.PluginSet` (identical type to `bytecode.format.PluginSet`,
// which is itself `types.PluginSet`).
pub const PluginSet = types.PluginSet;

// Re-export main types
pub const StringTable = string_table.StringTable;
pub const StringId = string_table.StringId;
pub const DataSection = data_section.DataSection;
pub const DataId = data_section.DataId;
pub const OpCode = opcodes.OpCode;
pub const Emitter = emitter.Emitter;
pub const Builder = format.Builder;
pub const Module = format.Module;

// MockGPU, Dispatcher, MockDispatcher are exported above with executor imports

// ============================================================================
// High-level Pipeline Functions
// ============================================================================

/// Load PNGB bytes into a Module for execution.
/// Note: The returned module references the input data - caller must ensure
/// data outlives the module.
pub fn load(allocator: std.mem.Allocator, pngb: []const u8) !Module {
    return format.deserialize(allocator, pngb);
}

// Test fixtures
pub const fixtures = struct {
    pub const simple_triangle = @import("fixtures/simple_triangle.zig");
};
