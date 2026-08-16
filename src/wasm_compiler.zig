//! WASM Compiler Entry Point
//!
//! Compiles PNGine `.sjon` source to PNGB bytecode in the browser.
//! Designed for live preview scenarios (sequencer, playground, editor).
//!
//! ## Design
//!
//! - PNGine is a SJON host: source is validated + lowered + emitted via `dsl_sjon`.
//!   The legacy `.pngine` macro DSL was removed in Phase 5 (Stage B2).
//! - Dynamic allocation: Uses wasm_allocator for compiler internals
//! - Static I/O buffers: Fixed-size buffers for source input and output
//! - No file I/O: No imports, no base_dir resolution
//! - Reflection: wgslender module included
//! - PNG generation: Produces self-contained PNGs with embedded executor
//!
//! ## Memory Layout
//!
//! ```
//! WASM Linear Memory:
//! ┌─────────────────────────────────────────┐
//! │ Source Buffer (64KB)                    │ ← JS writes SJON source here
//! ├─────────────────────────────────────────┤
//! │ Output Buffer (256KB)                  │ ← Compiler writes PNGB/PNG here
//! ├─────────────────────────────────────────┤
//! │ Error Buffer (4KB)                     │ ← Compiler writes errors here
//! ├─────────────────────────────────────────┤
//! │ Dynamic Heap (wasm_allocator)          │ ← SJON host / PNG
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Exports
//!
//! - `getSourcePtr()` / `setSourceLen()`: Write SJON source
//! - `compile()`: Run compilation pipeline, returns PNGB bytecode
//! - `compileToPng()`: Compile + embed executor + encode PNG
//! - `getOutputPtr()` / `getOutputLen()`: Read result (PNGB or PNG)
//! - `getErrorPtr()` / `getErrorLen()`: Read error messages
//!
//! ## Invariants
//!
//! - Source must be written before compile()/compileToPng() is called
//! - Output/error buffers are valid until next compile()/compileToPng() call
//! - All intermediate allocations freed after each compilation

const std = @import("std");
const Allocator = std.mem.Allocator;
const PluginSet = @import("types").PluginSet;
const png = @import("png");
const dsl_sjon = @import("dsl_sjon");
const wgslender_native = @import("reflect").wgslender_native;

// Buffer sizes
// SOURCE_MAX bumped 64→256 KiB (2026-07-08): the editor's in-browser compiler
// silently truncated `.sjon` past 64 KiB (source_len = @min(len, SOURCE_MAX)),
// surfacing as a generic "SJON validation failed" once the "Impulse" demo grew
// to the ceiling. The buffer is bss (`undefined`), so this is ~free on disk.
const SOURCE_MAX = 256 * 1024;
const OUTPUT_MAX = 256 * 1024;
const ERROR_MAX = 4 * 1024;
const DIAG_MAX = 32 * 1024;

// Static I/O buffers
var source_buffer: [SOURCE_MAX]u8 = undefined;
var output_buffer: [OUTPUT_MAX]u8 = undefined;
var error_buffer: [ERROR_MAX]u8 = undefined;
var diag_buffer: [DIAG_MAX]u8 = undefined;

var source_len: u32 = 0;
var output_len: u32 = 0;
var error_len: u32 = 0;
var diag_len: u32 = 0;

// The collect-all diagnostic sink (~19KB) lives in bss, not on the wasm stack —
// mirroring the static I/O buffers above. Reset per compile via `sink = .{}`.
var diag_sink: dsl_sjon.Compiler.Diag = .{};

// F9 preloaded schema, built lazily on the first compile and kept for the module's
// lifetime (the editor revalidates on every keystroke; preloading the 83 KB
// manifest ONCE means each compile parses only the user source). Never freed —
// lifetime = the wasm module instance — so a `deinit` would be dead code. A preload
// OOM leaves it null and the Compiler falls back to a per-call preload (correct,
// just not amortized).
var schema_cache: ?dsl_sjon.Compiler.PreloadedSchema = null;

/// The process-lifetime preloaded schema, built on first use. Returns null only on
/// the (unreachable-in-practice, byte-diff-gated) preload failure, in which case
/// the Compiler preloads per call.
fn schemaCache() ?*const dsl_sjon.Compiler.PreloadedSchema {
    if (schema_cache == null) {
        schema_cache = dsl_sjon.Compiler.preloadSchema(std.heap.wasm_allocator) catch return null;
    }
    return if (schema_cache) |*s| s else null;
}

// --- Executor variant lookup ---

/// Embedded executor WASM variants (built by build.zig).
const executors = struct {
    const core: []const u8 = @embedFile("executor_core");
    const render: []const u8 = @embedFile("executor_render");
    const compute: []const u8 = @embedFile("executor_compute");
    const render_compute: []const u8 = @embedFile("executor_render-compute");
    const render_anim: []const u8 = @embedFile("executor_render-anim");
    const render_compute_anim: []const u8 = @embedFile("executor_render-compute-anim");
    const render_wasm: []const u8 = @embedFile("executor_render-wasm");
    const full: []const u8 = @embedFile("executor_full");

    /// Look up embedded executor bytes by variant name (see selectVariant).
    fn get(name: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "core", core },
            .{ "render", render },
            .{ "compute", compute },
            .{ "render-compute", render_compute },
            .{ "render-anim", render_anim },
            .{ "render-compute-anim", render_compute_anim },
            .{ "render-wasm", render_wasm },
            .{ "full", full },
        });
        return map.get(name);
    }
};

/// Select embedded executor bytes for the required plugins.
///
/// Delegates the PluginSet → variant-name decision to the canonical
/// `executor/variant.zig:selectVariant` (re-exported via `dsl_sjon`), then maps
/// the name onto this module's embedded copies. Replaces a hand-transcribed
/// ladder that diverged from selectVariant for render-less combos.
///
/// Pre-conditions:
/// - plugins.core is true
///
/// Post-conditions:
/// - Returns non-empty WASM bytes
fn getExecutorWasm(plugins: PluginSet) []const u8 {
    std.debug.assert(plugins.core);
    const name = dsl_sjon.selectVariant(plugins).name;
    return executors.get(name) orelse executors.full;
}

// --- SJON dispatch (PNGine as a SJON host; in-browser .sjon compile) ---

/// Detect SJON source by its first non-whitespace byte: `(` (a form) or `;` (a
/// SJON line comment). Every example `.sjon` opens with a comment header, so a
/// `(`-only sniff would misroute every real file. A non-SJON first byte (`#`/`//`
/// or junk) is rejected by compile()/compileToPng() — the legacy `.pngine` macro
/// DSL was removed in Phase 5 (Stage B2).
fn isSjon(src: []const u8) bool {
    for (src) |c| switch (c) {
        ' ', '\t', '\r', '\n' => continue,
        '(', ';' => return true,
        else => return false,
    };
    return false;
}

/// Map `dsl_sjon.Compiler.Error` to the i32 codes the editor understands:
/// 1=parse, 2=validation, 3=emit, -1=OOM. The human message goes to
/// `error_buffer`; structured SJON diagnostics into `diag_buffer` are deferred to
/// Phase 4 (the editor still gets pass/fail + msg).
fn sjonErrorCode(err: dsl_sjon.Compiler.Error) i32 {
    return switch (err) {
        error.ParseError => blk: {
            writeError("SJON parse failed");
            break :blk 1;
        },
        error.ValidationError => blk: {
            writeError("SJON validation failed");
            break :blk 2;
        },
        error.EmitError => blk: {
            writeError("SJON emission failed");
            break :blk 3;
        },
        // Unreachable on wasm (no executors_dir / io is passed), but the error set
        // is exhaustive; treat a resource-read failure as an emit failure.
        error.FileReadError => blk: {
            writeError("SJON executor read failed");
            break :blk 3;
        },
        error.OutOfMemory => -1,
    };
}

/// Like `sjonErrorCode`, but prefers the rich, domain-labeled message captured in
/// `diag` (a WGSL syntax/type error, a missing entry point) over the generic
/// error-class string — so the editor's red panel shows the real WGSL error,
/// correctly labeled, instead of the misleading "SJON validation failed" when the
/// user is editing a `(shader-module …)`. Falls back to the generic message when
/// the sink is unset: a structural SJON reject is resolved in `validateDocument`,
/// before the Emitter, so it never writes the sink and stays generic.
fn sjonErrorCodeWithDiag(err: dsl_sjon.Compiler.Error, diag: *const dsl_sjon.Compiler.Diag) i32 {
    if (diag.set) {
        writeError(diag.message());
        return if (err == error.EmitError) 3 else 2;
    }
    return sjonErrorCode(err);
}

/// Write an empty JSON diagnostics array so the editor's `JSON.parse(diag)` always
/// succeeds on an early return (before any compile ran).
fn writeEmptyDiag() void {
    diag_buffer[0] = '[';
    diag_buffer[1] = ']';
    diag_len = 2;
}

/// Serialize the collected diagnostics (`diag_sink`) into `diag_buffer` as the
/// editor's `InputDiagnostic[]` JSON array. Located entries (SJON structural
/// rejects, real line/col) become squiggles; unlocated Emitter headlines are
/// omitted (they still surface via `error_buffer`). Called after every compile,
/// success or error, so `getDiagPtr` always reflects the latest run.
fn writeDiagJson() void {
    diag_len = diag_sink.writeJson(diag_buffer[0..]);
}

/// Copy `source_buffer` into a sentinel-terminated heap buffer for the SJON host
/// (its parser requires `[:0]const u8`).
fn dupeSourceZ(allocator: Allocator) ?[:0]u8 {
    const source_z = allocator.allocSentinel(u8, source_len, 0) catch return null;
    @memcpy(source_z, source_buffer[0..source_len]);
    return source_z;
}

/// SJON path of `compile()`: validate + lower + emit PNGB (no executor).
fn compileSjon(allocator: Allocator) i32 {
    writeEmptyDiag(); // valid [] until the compile runs (covers the early -1 return)
    diag_sink = .{};
    const source_z = dupeSourceZ(allocator) orelse return -1;
    defer allocator.free(source_z);

    const pngb = dsl_sjon.Compiler.compileWithOptions(allocator, source_z, .{
        .validate_shaders = true,
        .diag = &diag_sink,
        .schema_cache = schemaCache(),
    }) catch |err| {
        writeDiagJson();
        return sjonErrorCodeWithDiag(err, &diag_sink);
    };
    defer allocator.free(pngb);
    writeDiagJson();

    if (pngb.len > OUTPUT_MAX) {
        writeError("Output exceeds 256KB limit");
        return 3;
    }
    @memcpy(output_buffer[0..pngb.len], pngb);
    output_len = @intCast(pngb.len);
    return 0;
}

/// SJON path of `compileToPng()`: detect plugins → pick + embed the executor
/// variant → emit PNGB → encode 1×1 PNG → embed bytecode as a pNGb chunk. Reuses
/// `getExecutorWasm` and the `png` encoder/embedder, so the `.sjon` PNG is
/// self-contained and structurally identical to the CLI output.
fn compileToPngSjon(allocator: Allocator) i32 {
    writeEmptyDiag();
    diag_sink = .{};
    const source_z = dupeSourceZ(allocator) orelse return -1;
    defer allocator.free(source_z);

    // ONE compile. Which executor variant to embed depends on the plugin set,
    // which is only known after the walk — so the resolver is handed down and
    // called at that point, rather than the export paying for a whole throwaway
    // validate + emit up front just to read it. (The discarded pass also ran with
    // validate_shaders off, so it never caught anything this one doesn't.)
    var result = dsl_sjon.Compiler.compileWithPlugins(allocator, source_z, .{
        .embed_executor = true,
        .resolve_executor = getExecutorWasm,
        .validate_shaders = true,
        .diag = &diag_sink,
        .schema_cache = schemaCache(),
    }) catch |err| {
        writeDiagJson();
        return sjonErrorCodeWithDiag(err, &diag_sink);
    };
    defer result.deinit(allocator);
    writeDiagJson();

    // Encode 1x1 transparent PNG
    const pixel = [_]u8{ 0, 0, 0, 0 };
    const png_data = png.encoder.encode(allocator, &pixel, 1, 1) catch {
        writeError("PNG encoding failed");
        return 4;
    };
    defer allocator.free(png_data);

    // Embed bytecode in PNG as pNGb chunk
    const final_png = png.embed.embed(allocator, png_data, result.pngb) catch {
        writeError("Bytecode embedding failed");
        return 4;
    };
    defer allocator.free(final_png);

    if (final_png.len > OUTPUT_MAX) {
        writeError("PNG output exceeds 256KB limit");
        return 4;
    }
    @memcpy(output_buffer[0..final_png.len], final_png);
    output_len = @intCast(final_png.len);
    return 0;
}

// --- Exports ---

export fn getSourcePtr() [*]u8 {
    return &source_buffer;
}

export fn setSourceLen(len: u32) void {
    source_len = @min(len, SOURCE_MAX);
}

/// Run compilation pipeline with WGSL validation (PNGB bytecode only).
/// Returns: 0=ok, 1=parse error, 2=validation error, 3=emit error, -1=OOM
/// Diagnostics (JSON array) are always written to diag_buffer, even on success.
export fn compile() i32 {
    output_len = 0;
    error_len = 0;
    diag_len = 0;

    const allocator = std.heap.wasm_allocator;

    // PNGine is a SJON host: only `.sjon` source compiles. A non-SJON first byte
    // (`#`/`//` macro DSL, or junk) is reported, not silently miscompiled — the
    // legacy `.pngine` frontend was removed in Phase 5 (Stage B2).
    if (!isSjon(source_buffer[0..source_len])) {
        writeEmptyDiag();
        writeError("legacy .pngine DSL is no longer supported — use SJON (.sjon) source");
        return 1;
    }
    return compileSjon(allocator);
}

/// Compile SJON to self-contained PNG with embedded executor.
///
/// Runs the full pipeline: detect plugins → select executor variant → emit PNGB
/// with executor → encode 1x1 PNG → embed bytecode as pNGb chunk.
///
/// Returns: 0=ok, 1=parse error, 2=validation error, 3=emit error,
///          4=png error, -1=OOM
export fn compileToPng() i32 {
    output_len = 0;
    error_len = 0;
    diag_len = 0;

    const allocator = std.heap.wasm_allocator;

    if (!isSjon(source_buffer[0..source_len])) {
        writeEmptyDiag();
        writeError("legacy .pngine DSL is no longer supported — use SJON (.sjon) source");
        return 1;
    }
    return compileToPngSjon(allocator);
}

/// Minify WGSL source via wgslender. Input written to source_buffer; result
/// written to output_buffer. Used by the editor to dedup no-op edits before
/// triggering a full recompile.
/// Returns: 0=ok, 1=minify failure, 2=output too large, -1=OOM.
export fn minifyWgsl() i32 {
    output_len = 0;
    error_len = 0;

    if (source_len == 0) {
        output_len = 0;
        return 0;
    }

    const src = source_buffer[0..source_len];
    var result = wgslender_native.minifyAndReflectNative(std.heap.wasm_allocator, src, null) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                writeError("OutOfMemory");
                return -1;
            },
            error.ReflectFailed => {
                writeError("Minify failed");
                return 1;
            },
        }
    };
    defer std.heap.wasm_allocator.free(result.code);
    defer result.reflection.deinit();

    if (result.code.len > OUTPUT_MAX) {
        writeError("Minified output exceeds 256KB limit");
        return 2;
    }
    @memcpy(output_buffer[0..result.code.len], result.code);
    output_len = @intCast(result.code.len);
    return 0;
}

export fn getOutputPtr() [*]const u8 {
    return &output_buffer;
}

export fn getOutputLen() u32 {
    return output_len;
}

export fn getErrorPtr() [*]const u8 {
    return &error_buffer;
}

export fn getErrorLen() u32 {
    return error_len;
}

export fn getDiagPtr() [*]const u8 {
    return &diag_buffer;
}

export fn getDiagLen() u32 {
    return diag_len;
}

// --- Error formatting ---

fn writeError(msg: []const u8) void {
    const len = @min(msg.len, ERROR_MAX);
    @memcpy(error_buffer[0..len], msg[0..len]);
    error_len = @intCast(len);
}

// --- WASM log ---

extern "env" fn log(ptr: [*]const u8, len: u32) void;

pub const std_options: std.Options = .{
    .logFn = wasmLog,
};

fn wasmLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    log(msg.ptr, @intCast(msg.len));
}
