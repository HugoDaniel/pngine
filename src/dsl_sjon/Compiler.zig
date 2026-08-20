//! SJON-backed PNGine compiler.
//!
//! PNGine is a SJON *host*: this module composes the embedded `schema/pngine.sjon`
//! manifest with the user document, registers the `pngine/*` lowering hooks (see
//! `hooks.zig`), runs `Host.validateDocument`, and walks the validated/lowered
//! forest to emit PNGB through the existing bytecode layer (`Emitter.zig`).
//!
//! Schema injection: PNGine **preloads** the embedded manifest once via
//! `sjon.preloadSchema` (F9) and hands it to every `validateDocument` through
//! `HostOptions.preloaded`. The user document then parses at offset 0 — spans
//! arrive in document coordinates, with no manifest prefix to subtract. That keeps
//! the whole pipeline (staged lowering + materialized defaults + validation) in
//! SJON and needs no filesystem/resolver — it works on wasm32-freestanding. A
//! long-lived caller (the in-browser compiler) caches one `PreloadedSchema` across
//! compiles so keystroke revalidation never re-parses the 83 KB manifest; the CLI
//! and test paths preload per call. See CONTRIBUTING.md.
//!
//! `compile` / `compileWithPlugins` mirror the signatures of `src/dsl/Compiler.zig`
//! so the CLI / WASM callers can switch on input extension without caring which
//! frontend produced the bytecode.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sjon = @import("sjon");
const bytecode = @import("bytecode");
const executor = @import("executor");

const Emitter = @import("Emitter.zig").Emitter;
const hooks = @import("hooks.zig");
const values = @import("values.zig");
const Expr = sjon.Expr;

/// The PNGine WebGPU schema, embedded as a portable SJON manifest. Provided as
/// the `pngine_schema` anonymous import by build.zig.
pub const manifest_src: [:0]const u8 = @embedFile("pngine_schema");

/// Plugin feature flags → executor-variant selection. Reused from the bytecode
/// layer exactly as the legacy compiler does.
pub const PluginSet = bytecode.format.PluginSet;

/// Re-export the canonical PluginSet → executor-variant selector so the WASM
/// compiler (which only imports `dsl_sjon`) reaches it without a build-graph
/// dependency on the executor module directly. The variant→WASM-bytes table
/// stays module-local (each module `@embedFile`s its own executor copies).
pub const selectVariant = executor.selectVariant;

/// Re-export the vendored descriptor encoder so top-level `pngine` can expose it
/// (consumed by `cli/inspect.zig` for its `DescriptorType` enum) without
/// file-importing the module root into a second module. See `src/main.zig`.
pub const DescriptorEncoder = @import("descriptor_encoder").DescriptorEncoder;

pub const Compiler = struct {
    pub const Error = error{
        OutOfMemory,
        ParseError,
        ValidationError,
        EmitError,
        FileReadError,
    };

    /// Domain-labeled compile-diagnostic sink (WGSL vs SJON). A caller (the
    /// in-browser compiler, `pngine validate`) passes one in `Options.diag` to
    /// receive the real WGSL error detail on a shader-module failure instead of a
    /// generic error-class string. Defined in `diag.zig` (the Emitter writes into it).
    pub const Diag = @import("diag.zig").Diag;

    /// The F9 preloaded schema (borrowed, must outlive every `HostResult` validated
    /// against it). Re-exported here (like `Diag`) so a long-lived caller (the wasm
    /// compiler / editor) can hold one across compiles via `dsl_sjon.Compiler.*`
    /// without a direct `sjon` build-graph edge. Build one with `preloadSchema`,
    /// hand it back via `Options.schema_cache`, and `deinit` after the last compile.
    pub const PreloadedSchema = sjon.Host.PreloadedSchema;

    /// Compilation options. Mirrors the legacy `dsl/Compiler.zig` shape so the
    /// CLI/WASM call sites stay frontend-agnostic. Trimmed to the fields the SJON
    /// path consumes today; grows in Phase 2/3.
    pub const Options = struct {
        base_dir: ?[]const u8 = null,
        file_path: ?[]const u8 = null,
        minify_shaders: bool = false,
        validate_shaders: bool = false,
        /// Advisory WGSL lint (`@wgslender/recommended`) on top of
        /// `validate_shaders`, which it implies. Findings warn and never fail
        /// the compile. Only `pngine validate` sets it — see the Emitter field
        /// for why it is not folded into `validate_shaders`.
        lint_shaders: bool = false,
        /// Embed the executor WASM in the payload (self-contained PNG). Uses
        /// `executors_dir` first, then falls back to `embedded_executor_wasm`.
        /// Defaults false (preview/dev builds emit bytecode without an executor).
        embed_executor: bool = false,
        /// Directory of pre-built executor WASM files (`pngine-{variant}.wasm`).
        /// Requires `io`; on wasm (io == null) this path yields FileReadError and
        /// the `embedded_executor_wasm` fallback is used instead.
        executors_dir: ?[]const u8 = null,
        /// Fallback executor WASM bytes (e.g. from `@embedFile` in the CLI/WASM
        /// entry), used when `executors_dir` has no matching variant file.
        embedded_executor_wasm: ?[]const u8 = null,
        /// Pick the executor WASM from the DETECTED plugin set, consulted after
        /// the walk (between `executors_dir` and `embedded_executor_wasm`).
        ///
        /// For a caller that selects among compiled-in variants rather than files
        /// on disk — the in-browser compiler. Without it such a caller has to learn
        /// the plugin set before compiling, which meant a whole throwaway
        /// validate + emit just to read `plugins_used` off the discarded builder.
        /// The bytes are borrowed (static/`@embedFile`), never freed here.
        resolve_executor: ?*const fn (PluginSet) []const u8 = null,
        io: ?std.Io = null,
        /// Optional domain-labeled diagnostic sink. When non-null and an
        /// Emitter-phase WGSL/entry check fails, the specific message lands here
        /// (see `Diag`); the caller surfaces it instead of the generic error class.
        /// Null on the golden/parity paths — the message is unused there.
        diag: ?*Diag = null,
        /// Optional preloaded schema (F9), borrowed for the duration of the call.
        /// A long-lived caller (the wasm compiler / editor) preloads the manifest
        /// once via `preloadSchema` and threads it here so keystroke revalidation
        /// never re-parses the 83 KB manifest. Null (CLI, golden, tests) preloads a
        /// per-call schema owned by the internal `Validated` and freed with it.
        schema_cache: ?*const PreloadedSchema = null,
    };

    /// Result of compilation with plugin detection and variant selection. Same
    /// shape as the legacy compiler so executor embedding is identical.
    pub const CompileWithPluginsResult = struct {
        pngb: []u8,
        plugins: PluginSet,
        variant_name: []const u8,
        variant_size: u32,

        pub fn deinit(self: *CompileWithPluginsResult, gpa: Allocator) void {
            gpa.free(self.pngb);
            self.* = undefined;
        }
    };

    /// Validated document + (when we preloaded our own schema) the `PreloadedSchema`
    /// its plugins were borrowed from. `result.plugins` aliases the preloaded set
    /// (Host.zig copies the `Plugin` structs by value, but their internal slices
    /// point into the preloaded arena), so `owned_schema` must outlive — and is
    /// freed AFTER — `result`. Null when the caller supplied a cache (borrowed, not
    /// owned). The user `source` also backs the tree and is the caller's to keep
    /// alive across the compile call (it always is).
    const Validated = struct {
        result: sjon.Host.HostResult,
        owned_schema: ?sjon.Host.PreloadedSchema,
        gpa: Allocator,

        fn deinit(self: *Validated) void {
            self.result.deinit();
            if (self.owned_schema) |*s| s.deinit();
        }
    };

    /// Compile `.sjon` source to PNGB bytecode.
    pub fn compile(gpa: Allocator, source: [:0]const u8) Error![]u8 {
        return compileWithOptions(gpa, source, .{});
    }

    /// Build + configure a diagnostics-aware Emitter over the validated forest.
    /// The static `Emitter.emit` wrapper stays for the golden/parity harnesses;
    /// this path attaches the optional Diag sink (the Emitter writes WGSL/entry
    /// failures into it) and threads the user source so a cross-validation
    /// `tree.spanOf` maps to a 1-based (line, col) squiggle.
    ///
    /// F9: the tree parses `source` at offset 0, so spans are already in document
    /// coordinates — the Emitter's `locate` resolves them against `user_source`
    /// with no prefix to subtract. Callers own the returned Emitter:
    /// `defer em.deinit(); try em.run();`.
    fn initEmitter(gpa: Allocator, result: *const sjon.Host.HostResult, options: Options, source: [:0]const u8) Emitter {
        // lint implies validate: the lint path IS the validation path (one
        // analysis pass serves both), so asking for lint without validation is
        // not a state the Emitter can be in.
        var em = Emitter.init(gpa, result, options.base_dir, options.io, options.validate_shaders or options.lint_shaders);
        em.lint_shaders = options.lint_shaders;
        em.minify_shaders = options.minify_shaders;
        em.diag = options.diag;
        em.user_source = source;
        return em;
    }

    pub fn compileWithOptions(gpa: Allocator, source: [:0]const u8, options: Options) Error![]u8 {
        var v = try validate(gpa, source, options.diag, options.schema_cache);
        defer v.deinit();
        var em = initEmitter(gpa, &v.result, options, source);
        defer em.deinit();
        try em.run();
        const pngb = em.builder.finalize(gpa) catch return error.OutOfMemory;
        // A successful compile always yields a well-formed header. finalize()
        // returning short/unmagicked bytes with no error would otherwise reach
        // the CLI's writer and be embedded in a PNG as-is.
        std.debug.assert(pngb.len >= bytecode.format.HEADER_SIZE);
        std.debug.assert(std.mem.eql(u8, pngb[0..4], bytecode.format.MAGIC));
        return pngb;
    }

    /// Compile and return bytecode with detected plugins + selected executor
    /// variant (used when embedding the executor in the payload).
    pub fn compileWithPlugins(gpa: Allocator, source: [:0]const u8, options: Options) Error!CompileWithPluginsResult {
        var v = try validate(gpa, source, options.diag, options.schema_cache);
        defer v.deinit();

        var em = initEmitter(gpa, &v.result, options, source);
        defer em.deinit();
        try em.run();

        // Definitive plugin set: the union of every EMITTED opcode's requirement
        // (bytecode/emitter.zig accumulates it in `plugins_used`). This replaced a
        // form-head heuristic that only detected render/compute and silently
        // under-selected variants for texture/wasm payloads — harmless only while
        // C11 left every variant byte-identical (item 2.2).
        const plugin_set = em.builder.getEmitter().plugins_used;
        // Every payload needs the core opcodes; a set without them means the walk
        // emitted nothing, and selectVariant would pick a variant that cannot run
        // the bytecode it is about to be embedded beside.
        std.debug.assert(plugin_set.core);
        const variant = executor.selectVariant(plugin_set);
        std.debug.assert(variant.name.len > 0);

        // Resolve the executor WASM to embed (self-contained PNG), mirroring the
        // legacy `dsl/Compiler.zig` path: prefer a variant file under
        // `executors_dir`, else the caller-supplied `embedded_executor_wasm`.
        // Only the file-read bytes are owned; the embedded fallback is borrowed.
        var executor_wasm: ?[]u8 = null;
        var executor_is_fallback = false;
        defer if (executor_wasm != null and !executor_is_fallback) gpa.free(executor_wasm.?);
        if (options.embed_executor) {
            if (options.executors_dir) |dir| {
                executor_wasm = readExecutorWasm(gpa, options.io, dir, variant.name) catch null;
            }
            if (executor_wasm == null) {
                if (options.resolve_executor) |resolve| {
                    executor_wasm = @constCast(resolve(plugin_set));
                    executor_is_fallback = true; // borrowed bytes — do not free
                }
            }
            if (executor_wasm == null) {
                if (options.embedded_executor_wasm) |embedded| {
                    executor_wasm = @constCast(embedded);
                    executor_is_fallback = true;
                }
            }
        }

        const pngb = if (executor_wasm) |exe|
            em.builder.finalizeWithOptions(gpa, .{ .executor = exe, .plugins = plugin_set }) catch return error.OutOfMemory
        else
            em.builder.finalize(gpa) catch return error.OutOfMemory;
        std.debug.assert(pngb.len >= bytecode.format.HEADER_SIZE);
        std.debug.assert(std.mem.eql(u8, pngb[0..4], bytecode.format.MAGIC));

        return .{
            .pngb = pngb,
            .plugins = plugin_set,
            .variant_name = variant.name,
            .variant_size = variant.estimated_size,
        };
    }

    /// Preload the embedded PNGine schema (F9): parse the 83 KB manifest ONCE into
    /// a borrowed `PreloadedSchema` that `validateDocument` composes with the user
    /// document via `HostOptions.preloaded`. The user source then parses at offset
    /// 0 — every diagnostic span is document-local, no prefix to subtract. The
    /// result must outlive every `HostResult` validated against it (its plugins are
    /// borrowed): a long-lived caller caches one across compiles; the CLI/golden/
    /// test paths preload per call and free it with the `Validated`.
    ///
    /// The manifest is `@embedFile`'d + byte-diff-gated by schema-export, so it
    /// must preload clean; a non-empty diagnostic set is a build-time schema bug,
    /// surfaced as `error.ValidationError` (stderr dump off-freestanding) rather
    /// than silently mis-validating every document.
    pub fn preloadSchema(gpa: Allocator) Error!sjon.Host.PreloadedSchema {
        var pre = sjon.preloadSchema(gpa, &.{manifest_src}) catch return error.OutOfMemory;
        if (pre.hasErrors()) {
            renderPreloadDiagnostics(&pre);
            pre.deinit();
            return error.ValidationError;
        }
        return pre;
    }

    /// Run the host pipeline (lowering + defaults + validation) over `source`
    /// against the preloaded schema, and surface diagnostics. Returns the validated
    /// document on success; the caller emits from it. `cache` is a borrowed
    /// long-lived schema (editor); null preloads one owned by the returned
    /// `Validated` (freed after its `HostResult`).
    fn validate(gpa: Allocator, source: [:0]const u8, diag: ?*Diag, cache: ?*const sjon.Host.PreloadedSchema) Error!Validated {
        // F9: preload the schema (borrowed by the HostResult) instead of prepending
        // it to the source. `owned_schema` holds our own when no cache was supplied;
        // it is moved into the returned `Validated` on success (arena buffers don't
        // move, so the HostResult's borrowed plugin pointers stay valid).
        var owned_schema: ?sjon.Host.PreloadedSchema = null;
        errdefer if (owned_schema) |*s| s.deinit();
        const preloaded: *const sjon.Host.PreloadedSchema = cache orelse blk: {
            owned_schema = try preloadSchema(gpa);
            break :blk &owned_schema.?;
        };

        // Evaluate the document's (define …) constants into a lowering env so a
        // lowering hook's `numberEval` can resolve a define-ref expression at
        // lowering time (e.g. `(init … :workgroups [(ceil (/ NUM 64))])`). The arena
        // owns the parsed tree + bindings; the env is consumed during the
        // validateDocument lowering pass and never referenced after, so it is
        // freed when validate() returns.
        var env_arena = std.heap.ArenaAllocator.init(gpa);
        defer env_arena.deinit();
        const lowering_env = buildLoweringEnv(env_arena.allocator(), source);

        var registry = hooks.buildRegistry(gpa) catch return error.OutOfMemory;
        var result = sjon.validateDocument(gpa, source, .{
            .preloaded = preloaded,
            .lowering_registry = &registry,
            .lowering_env = &lowering_env,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                registry.deinit(gpa);
                return error.OutOfMemory;
            },
        };
        registry.deinit(gpa); // lowering is done; the registry is no longer referenced

        if (result.hasErrors()) {
            // A sink owns rendering (validate.zig prints `diag.message()`; the
            // in-browser compiler reads `error_buffer`): route the rich SJON
            // structural diagnostics (real spans + codes) into its collect-all
            // channel so `--json` carries located squiggles — and SKIP the stderr
            // dump so a structural reject prints once, not twice. The Emitter never
            // runs on a structural reject, so this is where these enter the sink.
            // No sink → `renderDiagnostics` is the CLI human fallback (compile/render).
            if (diag) |sink| {
                collectStructural(sink, &result, source);
            } else {
                renderDiagnostics(&result);
            }
            result.deinit();
            return error.ValidationError;
        }
        // A clean result may still carry WARNINGS — SJON's after-the-match
        // advisories (`deprecated_member`, `union_ambiguous` since SJON 1.2.0,
        // `numeric_bounds_invalid`). They used to be dropped here, so `pngine
        // validate` could never show one; now they ride the sink exactly as
        // wgslender's lint findings do — advisory by default, exit 1 under
        // `--strict`. No sink (compile/render without `--json`) → silent, as
        // every other advisory is on that path.
        if (result.diagnostics.len != 0) {
            if (diag) |sink| collectStructural(sink, &result, source);
        }
        // A clean result is the emitter's precondition on both counts: it walks
        // `data_forest` and reads spans off the tree, and it never re-checks
        // either. Returning an error-free-but-empty result would emit an empty
        // payload rather than reject the document.
        std.debug.assert(!result.hasErrors());
        return .{ .result = result, .owned_schema = owned_schema, .gpa = gpa };
    }

    /// Merge `HostResult.diagnostics` into `sink` as LOCATED collect-all entries.
    /// F9: every span is document-local (the user source parses at offset 0), so
    /// each resolves directly to a 1-based (line, col) against `source` — no prefix
    /// rebasing, and no schema/manifest diagnostics reach here (they stayed on the
    /// `PreloadedSchema` at preload time).
    fn collectStructural(
        sink: *Diag,
        result: *const sjon.Host.HostResult,
        source: []const u8,
    ) void {
        for (result.diagnostics) |d| {
            const sev: Diag.Severity = if (d.severity == .warning) .warning else .err;
            const lc = Diag.lineColOf(source, d.span.start);
            var end_line: u32 = 0;
            var end_col: u32 = 0;
            if (d.span.end > d.span.start) {
                const lce = Diag.lineColOf(source, d.span.end);
                end_line = lce.line;
                end_col = lce.col;
            }
            sink.addLocated(.sjon, sev, lc.line, lc.col, end_line, end_col, @tagName(d.code), "", d.message);
        }
    }

    /// Evaluate the document's top-level `(define :name N :value V)` constants into
    /// a lowering `Expr.Env`, so a lowering hook (e.g. `pngine/init-v1`) can resolve
    /// a define-ref expression in a value slot via `numberEval`. Best-effort and
    /// lenient: a parse or eval failure here is not fatal (the subsequent
    /// `validateDocument` reports the real diagnostic) — we contribute the constants
    /// that resolve. Mirrors the emitter's post-validation `buildEnv`: the same
    /// core-only eval schema (define values use core expr-funcs like `*`/`/`/`ceil`,
    /// never pngine forms), the same REAL values (02 R7 — a hook that reads a
    /// constant into a count slot narrows it there), and the same fixed-point
    /// resolution, so a define may name one declared after it. Bindings + name
    /// slices are owned by `arena`.
    fn buildLoweringEnv(arena: Allocator, source: [:0]const u8) Expr.Env {
        var tree = sjon.parse(arena, source) catch return .{};
        const eval_schema = sjon.Schema.Schema.init(&.{sjon.plugins.core.plugin});
        const Pending = struct { name: []const u8, vnode: sjon.Ast.NodeIndex, done: bool };
        var pending: std.ArrayList(Pending) = .empty;
        for (tree.root) |idx| {
            if (tree.tagOf(idx) != .form) continue;
            const hdr = tree.formHeader(idx);
            if (!std.mem.eql(u8, hdr.head, "define")) continue;
            var name: ?[]const u8 = null;
            var value_node: ?sjon.Ast.NodeIndex = null;
            for (hdr.children) |c| {
                if (tree.tagOf(c) != .kvpair) continue;
                const kv = tree.kvpairHeader(c);
                if (std.mem.eql(u8, kv.key, "name")) {
                    if (tree.tagOf(kv.value) == .symbol) name = tree.symbolText(kv.value);
                } else if (std.mem.eql(u8, kv.key, "value")) {
                    value_node = kv.value;
                }
            }
            const nm = name orelse continue;
            const vnode = value_node orelse continue;
            pending.append(arena, .{ .name = nm, .vnode = vnode, .done = false }) catch return .{};
        }
        var bindings: std.ArrayList(Expr.Env.Binding) = .empty;
        var env: Expr.Env = .{};
        // ≤ pending.len productive passes; a pass that binds nothing ends it
        // (what is left is a cycle or a bad expression — the emitter's buildEnv
        // reports it; this env is best-effort).
        for (0..pending.items.len + 1) |_| {
            var bound_this_pass: usize = 0;
            for (pending.items) |*p| {
                if (p.done) continue;
                env = .{ .bindings = bindings.items };
                const n = values.evalDefineValue(arena, &tree, eval_schema, &env, p.vnode) catch continue;
                bindings.append(arena, .{ .name = p.name, .value = .{ .number = n } }) catch return .{ .bindings = bindings.items };
                p.done = true;
                bound_this_pass += 1;
            }
            if (bound_this_pass == 0) break;
        } else unreachable;
        return .{ .bindings = bindings.items };
    }

    /// Read the executor WASM for `variant_name` from `executors_dir`
    /// (`{dir}/pngine-{variant}.wasm`). File IO is gated behind `io != null`, so
    /// on wasm32-freestanding (io == null) it returns `FileReadError` immediately
    /// and the caller falls back to `embedded_executor_wasm`. Vendored verbatim
    /// from `src/dsl/Compiler.zig` so the SJON path embeds identically.
    fn readExecutorWasm(gpa: Allocator, io: ?std.Io, executors_dir: []const u8, variant_name: []const u8) Error![]u8 {
        // No filesystem on wasm32-freestanding: `std.Io.Dir.cwd()` references posix
        // AT/IOV_MAX, absent there. Comptime-gated (matches Emitter.readDataFile) so
        // the IO body below is pruned off-host and the caller falls back to
        // `embedded_executor_wasm`. The legacy wasm path never hit this — it calls
        // Emitter directly, bypassing dsl.Compiler's file reads.
        if (comptime builtin.target.os.tag == .freestanding) return error.FileReadError;
        // Both feed a fixed-size bufPrint below; an empty variant would silently
        // build `.../pngine-.wasm` and fail as a missing file rather than as the
        // caller bug it is.
        std.debug.assert(executors_dir.len > 0);
        std.debug.assert(variant_name.len > 0);
        // Build path: {executors_dir}/pngine-{variant}.wasm
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/pngine-{s}.wasm", .{ executors_dir, variant_name }) catch {
            return error.FileReadError;
        };

        // Read file (guarded: no IO context → no filesystem, e.g. wasm)
        const io_ctx = io orelse return error.FileReadError;
        const file = std.Io.Dir.cwd().openFile(io_ctx, path, .{}) catch {
            return error.FileReadError;
        };
        defer file.close(io_ctx);

        const stat = file.stat(io_ctx) catch {
            return error.FileReadError;
        };

        // Sanity check: executor should be < 1MB
        const max_executor_size: u64 = 1024 * 1024;
        if (stat.size > max_executor_size) {
            return error.FileReadError;
        }

        const size: u32 = @intCast(stat.size);
        const wasm = gpa.alloc(u8, size) catch {
            return error.OutOfMemory;
        };
        errdefer gpa.free(wasm);

        // Bounded read loop (Zig mastery principles)
        var bytes_read: u32 = 0;
        for (0..size + 1) |_| {
            if (bytes_read >= size) break;
            const n: u32 = @intCast(file.readStreaming(io_ctx, &.{wasm[bytes_read..]}) catch {
                return error.FileReadError;
            });
            if (n == 0) break;
            bytes_read += n;
        }

        // Post-condition: read complete file
        std.debug.assert(bytes_read == size);

        return wasm;
    }

    /// Print error-severity diagnostics for the CLI human. F9: spans are already in
    /// document coordinates (offset 0), so no rebasing — the byte offset prints
    /// as-is.
    ///
    /// The fallback for `compile`/`render` (no `Diag` sink). It prints SJON's
    /// message verbatim, exactly as the sink path records it — a diagnostic that
    /// reads differently depending on which command produced it is the
    /// inconsistency this path exists to avoid.
    fn renderDiagnostics(result: *const sjon.Host.HostResult) void {
        // stderr is absent on wasm32-freestanding, and `std.debug.print` would pull
        // `std.Io.Threaded` (getrandom/RandomFile) into the build there. The target
        // check is comptime-known, so on freestanding this whole block is the dead
        // branch and is never analyzed — keeping the in-browser compiler libc-free.
        // It surfaces SJON diagnostics via the error code + error_buffer instead
        // (rich structured diagnostics → Phase 4).
        if (builtin.target.os.tag != .freestanding) {
            std.debug.print("\nSJON validation errors ({d} diagnostics):\n", .{result.diagnostics.len});
            for (result.diagnostics) |d| {
                if (d.severity != .err) continue;
                std.debug.print("  @{d} [{s}/{s}]: {s}\n", .{ d.span.start, @tagName(d.phase), @tagName(d.code), d.message });
            }
        }
    }

    /// Print preload-phase schema diagnostics (a broken embedded manifest — should
    /// never happen; the schema is byte-diff-gated). Freestanding-guarded like
    /// `renderDiagnostics`. Spans are local to the manifest source.
    fn renderPreloadDiagnostics(pre: *const sjon.Host.PreloadedSchema) void {
        if (builtin.target.os.tag != .freestanding) {
            std.debug.print("\nPNGine schema failed to preload ({d} diagnostics):\n", .{pre.diagnostics.len});
            for (pre.diagnostics) |d| {
                if (d.severity != .err) continue;
                std.debug.print("  @{d} [{s}/{s}]: {s}\n", .{ d.span.start, @tagName(d.phase), @tagName(d.code), d.message });
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

/// Validate `source` exactly as `validate` does (preloaded schema, hooks
/// registered) and assert an error-severity diagnostic with tag-name `code`
/// fired. Backs the Step-1 negative tests: a tightened constraint must *reject*
/// at author time, surfaced as a specific diagnostic (with a span) rather than a
/// silent default the emitter swallows.
fn expectDiagnostic(gpa: Allocator, source: [:0]const u8, code: []const u8) !void {
    var pre = try Compiler.preloadSchema(gpa);
    defer pre.deinit();
    var registry = try hooks.buildRegistry(gpa);
    defer registry.deinit(gpa);
    var result = try sjon.validateDocument(gpa, source, .{ .preloaded = &pre, .lowering_registry = &registry });
    defer result.deinit();
    for (result.diagnostics) |d| {
        if (d.severity == .err and std.mem.eql(u8, @tagName(d.code), code)) return;
    }
    std.debug.print("\nexpected diagnostic '{s}', got {d}:\n", .{ code, result.diagnostics.len });
    for (result.diagnostics) |d| std.debug.print("  [{s}] {s}\n", .{ @tagName(d.code), d.message });
    return error.DiagnosticNotFound;
}

// ── F8: the closed-symbol sweep (05 §4) ─────────────────────────────────────
// A symbol slot with no member-set and no cross-ref accepts ANY spelling, which
// is how `:write-mask everything` validated and rendered every channel, and how
// a `(wasm-call :args [canvas-widht])` typo reached the emitter as a silent
// 0.0. Both are closed now. The exceptions below are the ones that CANNOT be
// closed by this schema, and each names something inside an opaque artifact
// SJON does not parse: a WGSL entry point, a WGSL `override`, a WASM export,
// and the `:name` keys that DECLARE cross-ref targets rather than reference
// them. The route for the first two is filed upstream (06 S11,
// `(cross-ref-provider …)`).
//
// The test is the gate the plan asked for: a new loose slot has to be listed
// here, which is the moment to ask whether it should be closed instead.

const loose_symbol_kinds = [_][]const u8{ "entry-point", "override-name" };
const primitive_symbol_keys = [_][]const u8{ "name", "func" };

// ── S13 / S14 adoption (05 §2 R7, 05 §5 C8) ─────────────────────────────────
// SJON answered the two asks this schema was waiting on:
//
//   • S13 — a `scalar-or-ref` slot now reports the arm the value's SHAPE
//     selected instead of collapsing to `union_no_branch_matched`. That is
//     what lets every numeric kind gain the `(define …)` arm WITHOUT trading
//     away the bound that rejected the literal. The two tests directly above
//     are the ratchet: `repr_out_of_range` and `unit_forbidden` are the base
//     arm's own codes, and `byte-count` is a union now.
//
//   • S14 — `(variant :when [a b])`, so `:strip-index-format` is declared once
//     for the two topologies WebGPU reads it for. It was the emitter's rule
//     (`checkStripIndexFormat`) only because a key belonged to one variant.

/// Validate `source` and assert NOTHING rejected it — the positive half of
/// `expectDiagnostic`. A widened slot has to keep accepting what it accepted,
/// and a two-value `(variant …)` has to accept BOTH values: a test that
/// exercises one of them cannot tell `:when [a b]` from `:when a`.
fn expectValidates(gpa: Allocator, source: [:0]const u8) !void {
    var pre = try Compiler.preloadSchema(gpa);
    defer pre.deinit();
    var registry = try hooks.buildRegistry(gpa);
    defer registry.deinit(gpa);
    var result = try sjon.validateDocument(gpa, source, .{ .preloaded = &pre, .lowering_registry = &registry });
    defer result.deinit();
    var errors: u32 = 0;
    for (result.diagnostics) |d| {
        if (d.severity != .err) continue;
        errors += 1;
        std.debug.print("  [{s}] {s}\n", .{ @tagName(d.code), d.message });
    }
    if (errors != 0) return error.UnexpectedDiagnostic;
}

/// The `(primitive …)` scaffold C8 is about: one document, one knob.
fn primitiveDoc(comptime primitive: []const u8) [:0]const u8 {
    return "(shader-module :name code :code \"@vertex fn v() -> @builtin(position) vec4f { return vec4f(0); } @fragment fn f() -> @location(0) vec4f { return vec4f(1); }\")\n" ++
        "(render-pipeline :name pipe :layout auto\n" ++
        "  (vertex :module code :entry v)\n" ++
        "  (fragment :module code :entry f (target :format preferred-canvas-format))\n" ++
        "  " ++ primitive ++ ")\n" ++
        "(render-pass :name draw :pipeline pipe\n" ++
        "  (color-attachment :view context-current-texture :clear-value [0 0 0 1] :load-op clear :store-op store)\n" ++
        "  (draw :vertex-count 3))\n" ++
        "(frame :name main :perform [draw])";
}

// ── Device limits (Arc-3 §5.3b) ──────────────────────────────────────────────

/// Records the plugin set `compileWithPlugins` hands its resolver, so the test
/// below can assert the resolver sees the DETECTED set — the fact the browser
/// export path used to buy with a whole throwaway compile.
var seen_plugins: ?PluginSet = null;

fn recordingResolver(plugins: PluginSet) []const u8 {
    seen_plugins = plugins;
    return &[_]u8{}; // no bytes to embed; the payload just has no executor
}
