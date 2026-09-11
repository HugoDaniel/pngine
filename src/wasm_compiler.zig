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
//! - No filesystem, but files ARE served: a host packs a name→bytes table into
//!   linear memory before `compile()`, and the emitter reads every `:file` key
//!   through it (`dsl_sjon/file_resolver.zig`'s `TableResolver`). A compile
//!   that is missing files reports ALL of them at once in `getNeedsPtr`, so a
//!   host fetches once and compiles again. There is still no `base_dir` and no
//!   path resolution here: the table's names are matched, not opened.
//! - Reflection: wgslender module included
//! - PNG generation: Produces self-contained PNGs with embedded executor
//!
//! ## Memory Layout
//!
//! ```
//! WASM Linear Memory:
//! ┌─────────────────────────────────────────┐
//! │ Source Buffer (256KB)                   │ ← JS writes SJON source here
//! ├─────────────────────────────────────────┤
//! │ Output Buffer (256KB)                  │ ← Compiler writes PNGB/PNG here
//! ├─────────────────────────────────────────┤
//! │ Error Buffer (4KB)                     │ ← Compiler writes errors here
//! ├─────────────────────────────────────────┤
//! │ Diag / Needs Buffers (32KB / 8KB)      │ ← Diagnostics + missing files
//! ├─────────────────────────────────────────┤
//! │ Dynamic Heap (wasm_allocator)          │ ← SJON host / PNG / file table
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
//! - `allocFileTable()` / `setFileTableLen()`: Supply files a document names
//! - `getNeedsPtr()` / `getNeedsLen()` / `getNeedsDropped()`: Read which files
//!   the last compile was missing
//!
//! ## Invariants
//!
//! - Source must be written before compile()/compileToPng() is called
//! - Output/error buffers are valid until next compile()/compileToPng() call
//! - All intermediate allocations freed after each compilation. The ONE
//!   deliberate exception is `schema_cache` below, which outlives every call.
//!
//! ## What holds the allocation invariant, and what does not
//!
//! Not the code's shape. Each export threads `std.heap.wasm_allocator` raw
//! into the pipeline and every path frees by hand. Three things watch it:
//!
//!   • `zig build test-sjon-oom` — the exhaustive one. Compiles every fixture
//!     once per allocation index under a `FailingAllocator`, so the FAILURE
//!     path unwinds clean too. The leak it found on its first run was
//!     reachable at exactly one index out of 1,610.
//!   • `tests/npm/wasm-compiler-heap.test.js` — the shipped one. Soaks THIS
//!     module's `.wasm` and asserts `memory.buffer.byteLength` goes flat
//!     across repeated compiles, which is what a leak looks like in a browser
//!     tab: linear memory never shrinks, so anything outliving a call is
//!     permanent. Page-granular, so it sees ~2.7 KiB per compile and up.
//!   • `zig build test-sjon-arena` — the measurement that says why it is done
//!     by hand at all. R3-04 asked for one `ArenaAllocator` per export, which
//!     would make the release structural; measured, that costs 2.0x–3.7x the
//!     peak (5.6 MB → 16.1 MB on the largest fixture) in a linear memory that
//!     never shrinks, so it was rejected with the numbers
//!     (`docs/plans/r3/04-arena-at-the-entry-boundary.md`). Do not re-derive
//!     that from first principles — the gate re-measures it on every run.

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
/// JSON array of the paths the last compile could not resolve. Sized from
/// `Needs` itself (8 KiB of path bytes) plus per-entry quoting and commas.
const NEEDS_MAX = 12 * 1024;
/// Packed file table the host writes before a compile. Big enough for a handful
/// of textures and meshes; a host with more should compile on the CLI.
const FILE_TABLE_MAX = 16 * 1024 * 1024;

// Static I/O buffers
var source_buffer: [SOURCE_MAX]u8 = undefined;
var output_buffer: [OUTPUT_MAX]u8 = undefined;
var error_buffer: [ERROR_MAX]u8 = undefined;
var diag_buffer: [DIAG_MAX]u8 = undefined;
var needs_buffer: [NEEDS_MAX]u8 = undefined;

var source_len: u32 = 0;
var output_len: u32 = 0;
var error_len: u32 = 0;
var diag_len: u32 = 0;
var needs_len: u32 = 0;
var needs_dropped: u32 = 0;

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
///
/// The eight names are NOT repeated here. build.zig derives each anonymous
/// import name as `executor_<variant>` from `executor/variant.zig:VARIANTS`,
/// so this reads the same table: adding a variant there needs no edit here,
/// and a name can never drift between the two.
const executors = struct {
    /// Look up embedded executor bytes by variant name (see selectVariant).
    fn get(name: []const u8) ?[]const u8 {
        inline for (dsl_sjon.VARIANTS) |v| {
            if (std.mem.eql(u8, name, v.name)) return @embedFile("executor_" ++ v.name);
        }
        return null;
    }

    /// The always-valid fallback (`selectVariant` returns it when nothing
    /// smaller covers the plugin set), resolved through the same table.
    const full: []const u8 = @embedFile("executor_full");
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

// --- The file table (how a `:file` works with no filesystem) ---

// The host packs every file the document names into ONE heap buffer and hands
// its length over; `compile()` parses it into a `TableResolver` the emitter
// reads through. Packed rather than one call per file because a call per file
// is a round-trip per file, and the `needs` protocol answers a whole document's
// worth of missing files at once.
//
// ⚠️ It is ONE round per import LEVEL, not one round full stop, since 05
// (journal §411). An `(import :file "./other.sjon")` is discovered by parsing,
// so a document's second-level imports cannot be known until the first level is
// in hand: a host that imports must loop until `needs` comes back empty. A
// document with no import — which is every document that existed before that
// feature — still settles in one round.
//
// Wire format, little-endian, no padding:
//
//     [u32 count] ( [u32 name_len][name bytes][u32 data_len][data bytes] )*
//
// Owned here and freed at the top of the next compile, so a host may write a
// new table without leaking the old one and may leave one in place across
// compiles of the same document.

var file_table_buf: ?[]u8 = null;
var file_table_len: u32 = 0;
/// Parsed view over `file_table_buf`. Entries borrow it, so it must not be
/// freed or rewritten while a compile is running.
var file_entries: [dsl_sjon.Compiler.TableResolver.MAX_ENTRIES]dsl_sjon.Compiler.TableResolver.Entry = undefined;
var file_entry_count: u32 = 0;

/// Allocate (or reallocate) the file-table buffer and return a pointer the host
/// writes into. Returns null on OOM or a length past `FILE_TABLE_MAX`.
export fn allocFileTable(len: u32) ?[*]u8 {
    freeFileTable();
    if (len == 0) return null;
    if (len > FILE_TABLE_MAX) return null;
    const buf = std.heap.wasm_allocator.alloc(u8, len) catch return null;
    file_table_buf = buf;
    return buf.ptr;
}

/// Declare how many of the allocated bytes the host actually wrote.
export fn setFileTableLen(len: u32) void {
    const cap: u32 = if (file_table_buf) |b| @intCast(b.len) else 0;
    file_table_len = @min(len, cap);
}

fn freeFileTable() void {
    if (file_table_buf) |b| std.heap.wasm_allocator.free(b);
    file_table_buf = null;
    file_table_len = 0;
    file_entry_count = 0;
}

/// Parse the packed table into `file_entries`. Returns false on a malformed
/// buffer — a truncated length prefix or a run that claims more bytes than
/// remain. Refusing is the point: a silent short read would hand the emitter
/// half a texture and blame the document.
fn parseFileTable() bool {
    file_entry_count = 0;
    const buf = file_table_buf orelse return true; // no table is not an error
    const bytes = buf[0..file_table_len];
    if (bytes.len == 0) return true;
    if (bytes.len < 4) return false;

    const count = std.mem.readInt(u32, bytes[0..4], .little);
    if (count > dsl_sjon.Compiler.TableResolver.MAX_ENTRIES) return false;
    // Every bound below is written as a SUBTRACTION from the remaining length,
    // never as `off + len > bytes.len`. This is the wasm32 build: `usize` is 32
    // bits there, so a host handing in a `name_len` of 0xFFFFFFFF wrapped that
    // addition to a small number, passed the check, and sliced out of bounds.
    // `bytes.len - off` cannot underflow — each arm establishes `off <=
    // bytes.len` before subtracting (§438).
    var off: usize = 4;
    for (0..count) |i| {
        if (bytes.len - off < 4) return false;
        const name_len = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
        if (name_len == 0 or name_len > bytes.len - off) return false;
        const name = bytes[off..][0..name_len];
        off += name_len;

        if (bytes.len - off < 4) return false;
        const data_len = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
        if (data_len > bytes.len - off) return false;
        const data = bytes[off..][0..data_len];
        off += data_len;

        file_entries[i] = .{ .name = name, .bytes = data };
    }
    file_entry_count = count;
    return true;
}

/// The resolver for this compile. ALWAYS a resolver, even with no table yet.
///
/// It used to be null until the host supplied entries, and for every other
/// `:file` key that was harmless: the `needs` pre-pass walks the validated
/// forest and reports what the document names whether or not anything can be
/// read, so round one produced the complete list regardless.
///
/// `(import …)` is not like the others. The composer runs BEFORE validation —
/// there is no forest to pre-walk, because what the forest contains is what the
/// import decides — so the only way a path reaches `needs` is by being ATTEMPTED
/// and failing. A null resolver made that attempt impossible, and the first
/// round of every import chain refused with "this host has no file resolver"
/// and an empty `needs`: unrecoverable, because the host is never told what to
/// fetch. An empty table answers `NotFound` instead, which is what `needs`
/// listens for.
///
/// An empty table is also the truer model. This host HAS a file mechanism; the
/// table being empty means nothing has been handed over yet, not that files are
/// impossible here — which is exactly what the NotFound wording says.
var table_resolver: dsl_sjon.Compiler.TableResolver = .{ .entries = &.{} };

fn fileResolver() dsl_sjon.Compiler.FileResolver {
    table_resolver = .{ .entries = file_entries[0..file_entry_count] };
    return table_resolver.resolver();
}

// --- The `needs` list (what the host must fetch before compiling again) ---

/// Every file the last compile named and could not read, as a JSON array of
/// strings. Written after EVERY compile, success or failure, so a host reads it
/// unconditionally and `[]` means "nothing missing".
var needs_sink: dsl_sjon.Compiler.Needs = .{};

fn writeNeedsJson() void {
    var w: std.Io.Writer = .fixed(needs_buffer[0..]);
    w.writeByte('[') catch {};
    for (0..needs_sink.count) |i| {
        if (i > 0) w.writeByte(',') catch {};
        // `std.json.fmt` emits a complete JSON value, quotes included — a path
        // with a backslash or a quote in it must not break the array.
        w.print("{f}", .{std.json.fmt(needs_sink.pathAt(@intCast(i)), .{})}) catch break;
    }
    w.writeByte(']') catch {};
    needs_len = @intCast(w.buffered().len);
    needs_dropped = needs_sink.dropped;
}

fn writeEmptyNeeds() void {
    needs_buffer[0] = '[';
    needs_buffer[1] = ']';
    needs_len = 2;
    needs_dropped = 0;
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
fn dupeSourceZ(gpa: Allocator) ?[:0]u8 {
    const source_z = gpa.allocSentinel(u8, source_len, 0) catch return null;
    @memcpy(source_z, source_buffer[0..source_len]);
    return source_z;
}

/// SJON path of `compile()`: validate + lower + emit PNGB (no executor).
fn compileSjon(gpa: Allocator) i32 {
    writeEmptyDiag(); // valid [] until the compile runs (covers the early -1 return)
    writeEmptyNeeds();
    diag_sink = .{};
    needs_sink = .{};
    if (!parseFileTable()) {
        writeError("the file table is malformed — expected [u32 count]([u32 name_len][name][u32 data_len][data])*");
        return 3;
    }
    const source_z = dupeSourceZ(gpa) orelse return -1;
    defer gpa.free(source_z);

    const pngb = dsl_sjon.Compiler.compileWithOptions(gpa, source_z, .{
        .validate_shaders = true,
        .diag = &diag_sink,
        .resolver = fileResolver(),
        .needs = &needs_sink,
        .schema_cache = schemaCache(),
    }) catch |err| {
        writeDiagJson();
        writeNeedsJson();
        return sjonErrorCodeWithDiag(err, &diag_sink);
    };
    defer gpa.free(pngb);
    writeDiagJson();
    writeNeedsJson();

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
fn compileToPngSjon(gpa: Allocator) i32 {
    writeEmptyDiag();
    writeEmptyNeeds();
    diag_sink = .{};
    needs_sink = .{};
    if (!parseFileTable()) {
        writeError("the file table is malformed — expected [u32 count]([u32 name_len][name][u32 data_len][data])*");
        return 3;
    }
    const source_z = dupeSourceZ(gpa) orelse return -1;
    defer gpa.free(source_z);

    // ONE compile. Which executor variant to embed depends on the plugin set,
    // which is only known after the walk — so the resolver is handed down and
    // called at that point, rather than the export paying for a whole throwaway
    // validate + emit up front just to read it. (The discarded pass also ran with
    // validate_shaders off, so it never caught anything this one doesn't.)
    var result = dsl_sjon.Compiler.compileWithPlugins(gpa, source_z, .{
        .embed_executor = true,
        .resolve_executor = getExecutorWasm,
        .validate_shaders = true,
        .diag = &diag_sink,
        .resolver = fileResolver(),
        .needs = &needs_sink,
        .schema_cache = schemaCache(),
    }) catch |err| {
        writeDiagJson();
        writeNeedsJson();
        return sjonErrorCodeWithDiag(err, &diag_sink);
    };
    defer result.deinit(gpa);
    writeDiagJson();
    writeNeedsJson();

    // Encode 1x1 transparent PNG
    const pixel = [_]u8{ 0, 0, 0, 0 };
    const png_data = png.encoder.encode(gpa, &pixel, 1, 1) catch {
        writeError("PNG encoding failed");
        return 4;
    };
    defer gpa.free(png_data);

    // Embed bytecode in PNG as pNGb chunk
    const final_png = png.embed.embed(gpa, png_data, result.pngb) catch {
        writeError("Bytecode embedding failed");
        return 4;
    };
    defer gpa.free(final_png);

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

    const gpa = std.heap.wasm_allocator;

    // PNGine is a SJON host: only `.sjon` source compiles. A non-SJON first byte
    // (`#`/`//` macro DSL, or junk) is reported, not silently miscompiled — the
    // legacy `.pngine` frontend was removed in Phase 5 (Stage B2).
    if (!isSjon(source_buffer[0..source_len])) {
        writeEmptyDiag();
        writeError("legacy .pngine DSL is no longer supported — use SJON (.sjon) source");
        return 1;
    }
    return compileSjon(gpa);
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

    const gpa = std.heap.wasm_allocator;

    if (!isSjon(source_buffer[0..source_len])) {
        writeEmptyDiag();
        writeError("legacy .pngine DSL is no longer supported — use SJON (.sjon) source");
        return 1;
    }
    return compileToPngSjon(gpa);
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

/// The paths the last compile could not resolve, as a JSON array of strings.
/// Always valid JSON: `[]` when nothing is missing, and after an early return.
export fn getNeedsPtr() [*]const u8 {
    return &needs_buffer;
}

export fn getNeedsLen() u32 {
    return needs_len;
}

/// Entries that did not fit in the list. NON-ZERO MEANS THE ARRAY IS A PREFIX —
/// a host that ignores it cannot tell "nothing else is missing" from "the
/// buffer filled up", which is the failure `Diag.dropped` exists to prevent too.
export fn getNeedsDropped() u32 {
    return needs_dropped;
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
    // A log line, not a value: dropping one that does not fit is the right
    // degradation. (§440's classification of every `bufPrint … catch` here.)
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    log(msg.ptr, @intCast(msg.len));
}
