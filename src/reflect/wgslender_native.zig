//! Native Zig wgslender Adapter
//!
//! Direct Zig calls to the wgslender module for WGSL reflection and
//! minification.
//!
//! ## Type Conversion
//!
//! wgslender types → PNGine ReflectionData types:
//! - BindingInfo.group: i32 → Binding.group: u32
//! - BindingInfo.address_space: []const u8 → AddressSpace enum
//! - StructLayout → Layout (recursive field conversion)
//! - EntryPointInfo.stage: []const u8 → Stage enum

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgslender = @import("wgslender");

const wgslender_mod = @import("wgslender.zig");
const ReflectionData = wgslender_mod.ReflectionData;
const Binding = wgslender_mod.Binding;
const Layout = wgslender_mod.Layout;
const Field = wgslender_mod.Field;
const EntryPoint = wgslender_mod.EntryPoint;
const Resource = wgslender_mod.Resource;
const IoVar = wgslender_mod.IoVar;

pub const Error = error{
    OutOfMemory,
    ReflectFailed,
};

/// `lintNative`'s error set: `Error` plus the one failure only it has.
///
/// Deliberately NOT folded into `Error` — `reflectNative` and
/// `validateNative` cannot produce `LintUnavailable`, and callers switch
/// exhaustively over `Error` (see `wgslender.zig`'s `reflect`). Widening the
/// shared set would make every one of those switches claim to handle an error
/// its function never returns.
pub const LintError = Error || error{
    /// Called in a build that does not link the rule engine. See
    /// `lint_available`.
    LintUnavailable,
};

/// Whether this build links wgslender's lint rule engine.
///
/// False on wasm, and measured rather than assumed: linking `wgslender.lint`
/// costs **+88,212 bytes (+5.3%)** in `pngine-compiler.wasm` — the whole rule
/// set, its DCE pass and its config tables. The in-browser compiler never
/// enables lint (`lint_shaders` is a `pngine validate` opt-in), so that is 88 KB
/// of download for nothing.
///
/// The editor is not losing anything: pstudio surfaces WGSL lint through
/// `wgslender-lsp`, which runs the same rules with real code actions. Duplicating
/// them inside the PNGine compiler would ship the engine twice to one page.
///
/// This must be a `comptime` branch, not a runtime early-return — a runtime
/// guard still leaves the call reachable, so the rules link anyway.
pub const lint_available = !@import("builtin").target.cpu.arch.isWasm();

/// Related location for a diagnostic (e.g. "first declared here").
pub const RelatedDiagnostic = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

/// 1-based line/column position in source.
pub const Position = struct {
    line: u32,
    column: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// Inline source rewrite associated with a diagnostic. Drives LSP
/// quickfix code actions.
pub const Fix = struct {
    range: Range,
    text: []const u8,
};

/// Structured payload mirroring wgslender's `Diagnostic.QuickFixHint`.
/// type_mismatch is intentionally omitted — pngine doesn't surface it
/// yet. Add when needed.
pub const QuickFix = union(enum) {
    none,
    did_you_mean: []const u8,
    unused_symbol: []const u8,
    feature_not_enabled: []const u8,
    duplicate_location: u32,
    vertex_missing_builtin_position,
};

/// WGSL validation diagnostic entry.
///
/// Preserves wgslender's full diagnostic data: error codes, ranges,
/// related locations, and WGSL spec references.
pub const ValidationDiagnostic = struct {
    pub const Severity = enum { @"error", warning, info, note, hint };
    severity: Severity,
    message: []const u8,
    line: u32,
    column: u32,
    /// End position for multi-character underlines.
    end_line: u32 = 0,
    end_column: u32 = 0,
    /// Structured error code (e.g. "E0200").
    code: []const u8 = "",
    /// Related locations (e.g. "first declared here").
    related: []const RelatedDiagnostic = &.{},
    /// WGSL spec section reference (e.g. "6.4").
    spec_ref: []const u8 = "",
    /// Optional source rewrite the editor can apply as a quickfix.
    fix: ?Fix = null,
    /// Structured quickfix hint (e.g. "did you mean 'X'?").
    data: QuickFix = .none,
};

/// Result of WGSL validation.
pub const ValidationResult = struct {
    valid: bool,
    diagnostics: []const ValidationDiagnostic,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *ValidationResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Validate WGSL source code using wgslender's semantic validator.
///
/// Returns structured diagnostics with source positions.
/// Checks types, symbols, control flow, and uniformity.
pub fn validateNative(gpa: Allocator, wgsl_source: []const u8) Error!ValidationResult {
    return validateNativeWithOffset(gpa, wgsl_source, 0);
}

/// Validate WGSL with a line offset added to every diagnostic position.
///
/// Use this when the WGSL is a snippet embedded in a larger document
/// (e.g. a `(shader-module :code …)` or `(pass :code …)` block in a
/// `.sjon` file). Pass
/// `line_offset = N` so that diagnostics on snippet line 1 report as line
/// `N + 1` in the host document. Columns are not adjusted — the caller
/// must still rebase column positions on snippet line 1 (which becomes
/// host line `N + 1`) if columns also start mid-line.
pub fn validateNativeWithOffset(
    gpa: Allocator,
    wgsl_source: []const u8,
    line_offset: i32,
) Error!ValidationResult {
    std.debug.assert(wgsl_source.len > 0);

    // Sentinel-terminate the source (wgslender requires [:0]const u8)
    const source_z = gpa.allocSentinel(u8, wgsl_source.len, 0) catch return error.OutOfMemory;
    defer gpa.free(source_z);
    @memcpy(source_z, wgsl_source);

    var result = wgslender.validateWithOptions(
        gpa,
        source_z,
        .{ .line_offset = line_offset },
    ) catch return error.ReflectFailed;
    // wgslender's Validator.Result.deinit dropped its allocator param (the
    // Result owns an arena). ReflectResult/MinifyAndReflectResult below still
    // take one — do not "unify" these.
    defer result.deinit();

    // Convert to PNGine types
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    return .{
        .valid = result.valid,
        .diagnostics = try convertDiagnostics(alloc, result.diagnostics.diagnostics.items),
        .arena = arena,
    };
}

/// Convert a wgslender diagnostic list into PNGine's `ValidationDiagnostic`
/// slice, allocating everything from `alloc` (an arena owned by the caller's
/// result).
///
/// Shared by `validateNativeWithOffset` and `lintNative` — the validator and
/// the linter emit the same `Diagnostic.Entry` shape, and a lint finding is a
/// diagnostic in every respect that matters here. Keeping one converter is what
/// makes `.fix` and `.data` reach lint findings for free.
fn convertDiagnostics(
    alloc: Allocator,
    entries: []const wgslender.Diagnostic.Entry,
) Error![]const ValidationDiagnostic {
    var diags = std.ArrayList(ValidationDiagnostic).empty;
    for (entries) |*entry| {
        const severity: ValidationDiagnostic.Severity = switch (entry.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .info => .info,
            .note => .note,
            .hint => .hint,
            .disabled => continue,
        };
        // Convert related locations
        var related_list = std.ArrayList(RelatedDiagnostic).empty;
        for (entry.related) |rel| {
            related_list.append(alloc, .{
                .line = rel.range.start.line,
                .column = rel.range.start.column,
                .message = alloc.dupe(u8, rel.message) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        // Convert optional inline fix
        var fix_out: ?Fix = null;
        if (entry.fix) |f| {
            const text = alloc.dupe(u8, f.text) catch return error.OutOfMemory;
            fix_out = Fix{
                .range = .{
                    .start = .{ .line = f.range.start.line, .column = f.range.start.column },
                    .end = .{ .line = f.range.end.line, .column = f.range.end.column },
                },
                .text = text,
            };
        }

        // Convert structured quickfix hint
        const data_out: QuickFix = switch (entry.data) {
            .none => .none,
            .did_you_mean => |s| .{ .did_you_mean = alloc.dupe(u8, s) catch return error.OutOfMemory },
            .unused_symbol => |s| .{ .unused_symbol = alloc.dupe(u8, s) catch return error.OutOfMemory },
            .feature_not_enabled => |s| .{ .feature_not_enabled = alloc.dupe(u8, s) catch return error.OutOfMemory },
            .duplicate_location => |n| .{ .duplicate_location = n },
            .vertex_missing_builtin_position => .vertex_missing_builtin_position,
            // type_mismatch is not yet exposed through the adapter; collapse
            // to .none so consumers see a plain diagnostic without quickfix.
            .type_mismatch => .none,
            // lint_fix is an LSP-only hint: wgslender's diagnostics bridge
            // derives it from `Entry.fix` for the editor's "Apply autofix"
            // action, in LSP coordinates. PNGine's adapter is a compiler
            // frontend with no code-action surface, so it collapses to .none —
            // the byte-offset original stays on `Entry.fix` for anyone who
            // needs it.
            .lint_fix => .none,
        };

        diags.append(alloc, .{
            .severity = severity,
            .message = alloc.dupe(u8, entry.message) catch return error.OutOfMemory,
            .line = entry.range.start.line,
            .column = entry.range.start.column,
            .end_line = entry.range.end.line,
            .end_column = entry.range.end.column,
            .code = if (entry.code.len > 0) alloc.dupe(u8, entry.code) catch return error.OutOfMemory else "",
            .related = related_list.toOwnedSlice(alloc) catch return error.OutOfMemory,
            .spec_ref = if (entry.spec_ref.len > 0) alloc.dupe(u8, entry.spec_ref) catch return error.OutOfMemory else "",
            .fix = fix_out,
            .data = data_out,
        }) catch return error.OutOfMemory;
    }

    return diags.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Lint WGSL source with wgslender's rule engine, on top of the same analysis
/// pass the validator runs.
///
/// One `wgslender.lint` call answers both questions: `analysis` carries the
/// validator's own diagnostics (errors AND the warning-severity ones —
/// uniformity `E0700`–`E0703` among them) and `lint` carries the advisory rule
/// findings. Calling `validateNative` and then linting would parse and analyze
/// the module twice, so callers that want both should use this instead.
///
/// Rule selection is `@wgslender/recommended`: nine correctness-flavoured rules
/// (unused vars/bindings, dead + unreachable code, constant conditions,
/// for-direction, duplicate cases, self-assignment, redundant casts), all at
/// warning severity. Style / performance / minify packs are deliberately not
/// extended — they encode opinions the example corpus has never been held to.
///
/// `no-unused-binding` is the one that earns its keep on its own: a binding
/// declared but unused by any entry point is exactly what `(layout auto)`
/// strips, which desyncs the bind group and today surfaces only as an opaque
/// wgpu-native abort at render time (CONTRIBUTING pitfall 37).
pub fn lintNative(gpa: Allocator, wgsl_source: []const u8, line_offset: i32) LintError!LintResult {
    // Comptime, so a build with `lint_available == false` never codegens the
    // call and the rule engine links out entirely.
    if (comptime !lint_available) return error.LintUnavailable;

    std.debug.assert(wgsl_source.len > 0);

    const source_z = gpa.allocSentinel(u8, wgsl_source.len, 0) catch return error.OutOfMemory;
    defer gpa.free(source_z);
    @memcpy(source_z, wgsl_source);

    var result = wgslender.lint(gpa, source_z, .{
        .extends = &.{"@wgslender/recommended"},
        .line_offset = line_offset,
    }) catch return error.ReflectFailed;
    defer result.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    return .{
        .valid = result.analysis.valid,
        .diagnostics = try convertDiagnostics(alloc, result.analysis.diagnostics.diagnostics.items),
        .lint = try convertDiagnostics(alloc, result.lint.diagnostics.diagnostics.items),
        .fixable_count = result.lint.fixable_count,
        .arena = arena,
    };
}

/// Validation + lint from a single analysis pass. `diagnostics` is what
/// `ValidationResult` would carry; `lint` is the advisory rule findings, which
/// are ALWAYS advisory here — `valid` reflects the validator alone, so a lint
/// finding can never fail a build.
pub const LintResult = struct {
    valid: bool,
    diagnostics: []const ValidationDiagnostic,
    lint: []const ValidationDiagnostic,
    /// How many lint findings carry an applicable `.fix` rewrite.
    fixable_count: u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *LintResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// One `(constant :name X :value V)` resolved against its module.
pub const Specialisation = struct {
    /// The `override` identifier to replace.
    name: []const u8,
    /// The value, as an f64 — the width WebGPU itself passes constants at, and
    /// wide enough to hold any u32/i32/f32 exactly. The WGSL literal spelling
    /// is derived from the override's DECLARED type, not from this.
    value: f64,
};

/// Why a specialisation could not be applied. Each names the offending
/// override so the caller can locate it; `.type_mismatch` also carries the
/// declared type, because "3.5 is not a u32" is only actionable with the type.
pub const SpecialiseError = union(enum) {
    /// No `override` by that name in this module.
    unknown: []const u8,
    /// The value cannot be represented in the override's declared type.
    type_mismatch: struct { name: []const u8, typ: []const u8 },
};

/// Rewrite each named `override` declaration into a `const` with the given
/// value — the compile-time half of pipeline-overridable constants.
///
/// pngine is an ahead-of-time compiler and its payload cannot recompile, so a
/// constant's value is always known at build time. Substituting it makes the
/// value visible to wgslender's const-folding and dead-code elimination, so
/// `if (QUALITY > 2) { … }` collapses and the untaken branch leaves the payload
/// — inverting the cost of the feature from "constants add bytes" to
/// "constants remove them".
///
/// Two properties this deliberately guarantees:
///
///  * **Not textual.** The edit range is the reflected `decl_span`, so an
///    `override` named in a comment, a string, or a same-named local is
///    untouched. A regex over `override X` would rediscover the `wgsl_scan`
///    comment-blindness defect (§325).
///  * **Line-preserving.** The replacement carries the same newline count as
///    the declaration it replaces, so every byte after it keeps its line
///    number. wgslender validates the REWRITTEN text (that is the point — a
///    substituted value can be invalid where the override was fine), and this
///    is what keeps its line:col diagnostics pointing at the author's own code.
///
/// Returns the rewritten source (caller-owned) on success. On failure nothing
/// is allocated for the caller and `err_out` names the cause. An empty `specs`
/// returns a plain dupe, so callers need no special case.
pub fn specialiseOverrides(
    gpa: Allocator,
    source: []const u8,
    specs: []const Specialisation,
    err_out: *?SpecialiseError,
) Error![]u8 {
    std.debug.assert(source.len > 0);
    err_out.* = null;
    if (specs.len == 0) return gpa.dupe(u8, source) catch return error.OutOfMemory;

    var reflection = try reflectNative(gpa, source);
    defer reflection.deinit();

    var edits = std.ArrayList(wgslender.Edits.TextEdit).empty;
    defer {
        for (edits.items) |e| gpa.free(e.new_text);
        edits.deinit(gpa);
    }

    for (specs) |spec| {
        const ov = reflection.getOverride(spec.name) orelse {
            err_out.* = .{ .unknown = spec.name };
            return error.ReflectFailed;
        };
        // A declaration whose span was never stamped cannot be edited safely —
        // refuse rather than write at offset 0.
        if (ov.decl_end <= ov.decl_start or ov.decl_end > source.len) {
            err_out.* = .{ .unknown = spec.name };
            return error.ReflectFailed;
        }
        const literal = wgslLiteral(gpa, spec.value, ov.typ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TypeMismatch => {
                err_out.* = .{ .type_mismatch = .{ .name = spec.name, .typ = ov.typ } };
                return error.ReflectFailed;
            },
        };
        defer gpa.free(literal);

        const decl = source[ov.decl_start..ov.decl_end];
        const newlines = std.mem.count(u8, decl, "\n");
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(gpa);
        if (ov.typ.len > 0) {
            text.print(gpa, "const {s}: {s} = {s};", .{ ov.name, ov.typ, literal }) catch return error.OutOfMemory;
        } else {
            // A type-less `override X = 1.0;` infers from its initializer; so
            // does the `const` that replaces it.
            text.print(gpa, "const {s} = {s};", .{ ov.name, literal }) catch return error.OutOfMemory;
        }
        text.appendNTimes(gpa, '\n', newlines) catch return error.OutOfMemory;

        // Hoisted out of the `append` argument on purpose: an inline
        // `toOwnedSlice` hands ownership to a struct literal that the failing
        // `append` never stores, so the buffer escapes the `edits` defer that
        // would otherwise free it. Naming it gives the errdefer something to own
        // in the window between the two calls (LEAK-10).
        const new_text = text.toOwnedSlice(gpa) catch return error.OutOfMemory;
        errdefer gpa.free(new_text);
        edits.append(gpa, .{
            .start = ov.decl_start,
            .end = ov.decl_end,
            .new_text = new_text,
        }) catch return error.OutOfMemory;
    }

    return wgslender.Edits.applyEdits(gpa, source, edits.items) catch return error.OutOfMemory;
}

/// Spell `value` as a WGSL literal of type `typ`, refusing a value the type
/// cannot represent. This is the type check the schema cannot make: the width
/// lives in the shader, not in the SJON.
fn wgslLiteral(gpa: Allocator, value: f64, typ: []const u8) (Allocator.Error || error{TypeMismatch})![]u8 {
    const integral = @floor(value) == value and std.math.isFinite(value);
    if (std.mem.eql(u8, typ, "u32")) {
        if (!integral or value < 0 or value > std.math.maxInt(u32)) return error.TypeMismatch;
        return std.fmt.allocPrint(gpa, "{d}u", .{@as(u32, @intFromFloat(value))});
    }
    if (std.mem.eql(u8, typ, "i32")) {
        if (!integral or value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.TypeMismatch;
        return std.fmt.allocPrint(gpa, "{d}i", .{@as(i32, @intFromFloat(value))});
    }
    if (std.mem.eql(u8, typ, "bool")) {
        if (value != 0 and value != 1) return error.TypeMismatch;
        return gpa.dupe(u8, if (value == 1) "true" else "false");
    }
    // f32 / f16 / an omitted (inferred) type. `{d}` on a whole number prints
    // "3", which WGSL lexes as an AbstractInt — legal in a float context by
    // implicit conversion, but it makes an f16 slot's literal read as an int.
    // Forcing the point keeps the spelling unambiguous at a glance.
    if (!std.math.isFinite(value)) return error.TypeMismatch;
    if (integral) return std.fmt.allocPrint(gpa, "{d}.0", .{value});
    return std.fmt.allocPrint(gpa, "{d}", .{value});
}

/// Reflect on WGSL source code using native wgslender.
///
/// Returns PNGine ReflectionData with bindings, structs, and entry points.
/// Caller owns the returned data and must call deinit().
pub fn reflectNative(gpa: Allocator, wgsl_source: []const u8) Error!ReflectionData {
    std.debug.assert(wgsl_source.len > 0);

    // Sentinel-terminate the source (wgslender requires [:0]const u8)
    const source_z = gpa.allocSentinel(u8, wgsl_source.len, 0) catch return error.OutOfMemory;
    defer gpa.free(source_z);
    @memcpy(source_z, wgsl_source);

    var result = wgslender.reflect(gpa, source_z) catch return error.ReflectFailed;
    defer result.deinit(gpa);

    return convertReflectResult(gpa, &result);
}

/// Minify WGSL source and return both minified code and reflection data.
///
/// The reflection data contains mapped names matching the minified output.
/// Caller owns the returned code slice and ReflectionData.
pub fn minifyAndReflectNative(
    gpa: Allocator,
    wgsl_source: []const u8,
    keep_names: ?[]const []const u8,
) Error!struct { code: []const u8, reflection: ReflectionData } {
    std.debug.assert(wgsl_source.len > 0);

    // Sentinel-terminate the source
    const source_z = gpa.allocSentinel(u8, wgsl_source.len, 0) catch return error.OutOfMemory;
    defer gpa.free(source_z);
    @memcpy(source_z, wgsl_source);

    var options = wgslender.Minifier.Options{
        // Both are DEFLATE plays, not size-of-text plays: grouping similar
        // declarations and canonicalising locals to a, b, c… make structurally
        // similar code compress alike. The pNGb chunk is raw-DEFLATE, so this is
        // the axis that reaches the user.
        .sort_declarations = true,
        .scope_local_rename = true,
        // Keeps uniform STRUCT TYPE names (`Camera` stays `Camera` rather than
        // becoming `n`). Belt-and-braces rather than load-bearing: measured with
        // it off, pngine's uniform table is byte-identical even for nested
        // structs, because reflection is of the MINIFIED text — a mangled type
        // name resolves against an equally mangled key in the reflected struct
        // map (`uniforms.zig`'s nested lookup). Struct MEMBER names, which
        // gpu.js keys `setUniform` by, are never mangled by wgslender at all.
        // Kept on because a readable type name costs nothing and survives into
        // `--extract-wgsl` output.
        .preserve_uniform_struct_types = true,
        // NOT set, and the one that actually matters: `mangle_external_bindings`
        // defaults false, which is what preserves the `@group`/`@binding`
        // variable names the uniform table records and gpu.js writes through.
        // Flipping it true is the fail-probe that turns the minify tests in
        // `Emitter_test.zig` red (min1-04). tree_shaking already defaults true.
    };
    if (keep_names) |names| {
        options.keep_names = names;
    }

    var result = wgslender.minifyAndReflect(gpa, source_z, options) catch return error.ReflectFailed;
    defer result.deinit(gpa);

    // Copy the minified code (owned by wgslender's arena, freed on result.deinit)
    const code = gpa.dupe(u8, result.minify.code) catch return error.OutOfMemory;
    errdefer gpa.free(code);

    // No explicit free in this catch: the errdefer above is the single owner,
    // and returning the error fires it. Freeing here too was a double free on
    // the OOM path — free-list corruption in the editor tab's WasmAllocator,
    // which never shrinks (LEAK-10).
    const reflection = try convertReflectResult(gpa, &result.reflect);

    return .{ .code = code, .reflection = reflection };
}

/// Convert wgslender ReflectResult → PNGine ReflectionData.
fn convertReflectResult(gpa: Allocator, result: *const wgslender.Reflect.ReflectResult) Error!ReflectionData {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // Convert bindings
    var bindings = std.ArrayList(Binding).empty;
    for (result.bindings.items) |*b| {
        // A bare (non-struct) binding has no StructLayout; its physical size
        // still exists on the structured type tree — carry it so consumers
        // (e.g. the uniform table's bare-binding leaf) see a real byte size.
        const layout = if (b.layout) |*l| convertLayout(alloc, l) catch return error.OutOfMemory else Layout{
            .size = typeInfoSize(b.type_info),
            .alignment = 0,
            .fields = &.{},
        };

        const arr = arrayElemInfo(alloc, b.type_info) catch return error.OutOfMemory;
        bindings.append(alloc, .{
            .group = @intCast(b.group),
            .binding = @intCast(b.binding),
            .name = alloc.dupe(u8, b.name) catch return error.OutOfMemory,
            .address_space = Binding.AddressSpace.fromString(b.address_space),
            .type = resolvedTypeName(alloc, b.type_info, b.typ) catch return error.OutOfMemory,
            .layout = layout,
            .resource = convertResource(alloc, b.type_info) catch return error.OutOfMemory,
            .access_mode = alloc.dupe(u8, b.access_mode) catch return error.OutOfMemory,
            .elem_type = arr.elem_type,
            .elem_count = arr.elem_count,
        }) catch return error.OutOfMemory;
    }

    // Convert structs
    var structs = std.StringHashMapUnmanaged(Layout){};
    var struct_iter = result.structs.iterator();
    while (struct_iter.next()) |entry| {
        const name = alloc.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory;
        const layout = convertLayout(alloc, &entry.value_ptr.*) catch return error.OutOfMemory;
        structs.put(alloc, name, layout) catch return error.OutOfMemory;
    }

    // Convert entry points
    var entry_points = std.ArrayList(EntryPoint).empty;
    for (result.entry_points.items) |*ep| {
        // Dupe the per-entry resource var-name usage list (arena-owned upstream).
        var res_names = std.ArrayList([]const u8).empty;
        for (ep.resources.items) |rname| {
            const duped = alloc.dupe(u8, rname) catch return error.OutOfMemory;
            res_names.append(alloc, duped) catch return error.OutOfMemory;
        }

        // Same for the per-entry override names. Upstream this list is the
        // transitive union: `@workgroup_size` operands stamped at parse, plus
        // every `direct_overrides` propagated along the call graph — so an
        // override a helper function reads is attributed to the entry that
        // calls it.
        var ov_names = std.ArrayList([]const u8).empty;
        for (ep.overrides.items) |oname| {
            const duped = alloc.dupe(u8, oname) catch return error.OutOfMemory;
            ov_names.append(alloc, duped) catch return error.OutOfMemory;
        }

        entry_points.append(alloc, .{
            .name = alloc.dupe(u8, ep.name) catch return error.OutOfMemory,
            .stage = EntryPoint.Stage.fromString(ep.stage),
            .workgroup_size = ep.workgroup_size,
            .has_workgroup_size = ep.has_workgroup_size,
            .resources = res_names.toOwnedSlice(alloc) catch return error.OutOfMemory,
            .inputs = try convertIoVars(alloc, ep.inputs.items),
            .outputs = try convertIoVars(alloc, ep.outputs.items),
            .overrides = ov_names.toOwnedSlice(alloc) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }

    // Convert module-scope overrides. `default` is carried as the source text
    // of the initializer — its EMPTINESS is the fact downstream turns on, and
    // the text itself is what a compile-time specialisation would substitute.
    var overrides = std.ArrayList(wgslender_mod.Override).empty;
    for (result.overrides.items) |*o| {
        overrides.append(alloc, .{
            .name = alloc.dupe(u8, o.name) catch return error.OutOfMemory,
            .id = o.id,
            // An override's type may be omitted and inferred from its
            // initializer, so this is legitimately empty — unlike a binding's,
            // it is not a reflection gap. Resolve through the structured tree
            // for the same reason bindings do (§342): an aliased override type
            // spells as the alias name.
            .typ = resolvedTypeName(alloc, o.type_info, o.typ) catch return error.OutOfMemory,
            .default = alloc.dupe(u8, o.default) catch return error.OutOfMemory,
            .decl_start = o.decl_span.start,
            .decl_end = o.decl_span.end,
        }) catch return error.OutOfMemory;
    }

    // Convert errors
    var errors = std.ArrayList(wgslender_mod.ParseError).empty;
    for (result.errors.items) |err_msg| {
        errors.append(alloc, .{
            .message = alloc.dupe(u8, err_msg) catch return error.OutOfMemory,
            .line = 0,
            .column = 0,
        }) catch return error.OutOfMemory;
    }

    return ReflectionData{
        .bindings = bindings.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .structs = structs,
        .entry_points = entry_points.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .overrides = overrides.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .errors = errors.toOwnedSlice(alloc) catch return error.OutOfMemory,
        .arena = arena,
    };
}

/// Map a wgslender binding's structured type → PNGine's Resource tag.
/// Buffers (uniform/storage, or any non-handle type) → `.buffer`; handle
/// types → `.texture`/`.sampler` with descriptive fields. Arena-owned
/// strings (format, sample_type) are duped into `alloc`; enum spellings
/// (`@tagName`, `AccessMode.string()`) are static and referenced directly.
fn convertResource(alloc: Allocator, type_info: ?*const wgslender.Reflect.TypeInfo) Error!Resource {
    const ti = type_info orelse return .buffer;
    switch (ti.*) {
        .texture => |tex| return .{ .texture = .{
            .dim = @tagName(tex.dim),
            .kind = @tagName(tex.kind),
            .sample_type = alloc.dupe(u8, tex.sample_type) catch return error.OutOfMemory,
            .format = alloc.dupe(u8, tex.format) catch return error.OutOfMemory,
            .access = tex.access.string(),
        } },
        .sampler => |samp| return .{ .sampler = .{ .comparison = samp.comparison } },
        else => return .buffer,
    }
}

/// Map a wgslender entry point's I/O slot list → PNGine IoVar slice.
/// All strings are duped into `alloc` (arena-owned upstream).
fn convertIoVars(alloc: Allocator, items: []const wgslender.Reflect.InputOutputInfo) Error![]const IoVar {
    var list = std.ArrayList(IoVar).empty;
    for (items) |*io| {
        list.append(alloc, .{
            .name = alloc.dupe(u8, io.name) catch return error.OutOfMemory,
            .location = io.location,
            .builtin = alloc.dupe(u8, io.builtin) catch return error.OutOfMemory,
            .typ = resolvedTypeName(alloc, io.type_info, io.typ) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// Convert wgslender StructLayout → PNGine Layout.
fn convertLayout(alloc: Allocator, layout: *const wgslender.Reflect.StructLayout) !Layout {
    var fields = std.ArrayList(Field).empty;
    for (layout.fields.items) |*f| {
        const arr = arrayElemInfo(alloc, f.type_info) catch return error.OutOfMemory;
        fields.append(alloc, .{
            .name = try alloc.dupe(u8, f.name),
            .type = try resolvedTypeName(alloc, f.type_info, f.typ),
            .offset = f.offset,
            .size = f.size,
            .alignment = f.alignment,
            .elem_type = arr.elem_type,
            .elem_count = arr.elem_count,
        }) catch return error.OutOfMemory;
    }

    return Layout{
        .size = layout.size,
        .alignment = layout.alignment,
        .fields = fields.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };
}

/// Array element description extracted from a structured `TypeInfo`.
const ArrayElem = struct {
    elem_type: []const u8 = "",
    elem_count: u32 = 0,
};

/// `{ elem_type, elem_count }` for a fixed-size `array<E, N>`, or the empty
/// defaults for anything else (non-array, runtime-sized, unrepresentable
/// element). Uses the structured tree — NOT the `typ` string — so aliased
/// types (`alias L = array<vec4f, 3>`) and const-expression counts
/// (`array<vec4f, N>`) arrive resolved.
fn arrayElemInfo(
    alloc: Allocator,
    type_info: ?*const wgslender.Reflect.TypeInfo,
) Allocator.Error!ArrayElem {
    const ti = type_info orelse return .{};
    if (ti.* != .array) return .{};
    const arr = ti.array;
    const count = arr.count orelse return .{}; // runtime-sized → no info
    const elem = typeInfoName(alloc, arr.format) catch return error.OutOfMemory;
    if (elem.len == 0) return .{}; // unrepresentable element (nested array, …)
    return .{ .elem_type = elem, .elem_count = count };
}

/// Physical byte size of a structured type, or 0 when unknown (no type_info,
/// runtime-sized array, handle types). Every sized `TypeInfo` variant carries
/// its pre-computed size.
fn typeInfoSize(type_info: ?*const wgslender.Reflect.TypeInfo) u32 {
    const ti = type_info orelse return 0;
    return switch (ti.*) {
        .scalar => |s| s.size,
        .vec => |v| v.size,
        .mat => |m| m.size,
        .array => |a| a.size orelse 0,
        .@"struct" => |s| s.size,
        .atomic, .texture, .sampler, .ptr => 0,
    };
}

/// The type name to hand downstream: the STRUCTURED spelling when the tree can
/// spell it, else the declared string.
///
/// Every consumer of a reflected type name matches it against a fixed WGSL
/// vocabulary — `UniformType.fromWgslType`, `type_agree.wgslScalarClass`, and
/// the `structs` map lookup that drives the nested-struct walk. An ALIAS is
/// spelled by its own name (`alias Tint = vec4f` reflects `typ == "Tint"`), so
/// handing the declared string to any of those is a guaranteed miss on a type
/// they all otherwise know. wgslender already resolved it — `type_info` carries
/// the real shape — and dropping that at this boundary is what made an aliased
/// `mat3x3f` uniform pack as 9 unpadded floats instead of 3 vec4 columns, and
/// an aliased struct field vanish from the uniform table entirely (§342).
///
/// Same principle `arrayElemInfo` already states: read the tree, not the string.
///
/// The fallback is not a formality — `typeInfoName` deliberately declines to
/// spell arrays, atomics, textures, samplers and pointers, and those keep their
/// declared spelling (`Emitter.warnBareBindingSkip` matches `"array<"` on it).
fn resolvedTypeName(
    alloc: Allocator,
    type_info: ?*const wgslender.Reflect.TypeInfo,
    declared: []const u8,
) Allocator.Error![]const u8 {
    if (type_info) |ti| {
        const spelled = try typeInfoName(alloc, ti);
        if (spelled.len > 0) return spelled;
    }
    return alloc.dupe(u8, declared);
}

/// Spell a `TypeInfo` leaf as the WGSL type name `UniformType.fromWgslType`
/// understands: scalars/structs by name, vectors/matrices in template form
/// ("vec4<f32>", "mat4x4<f32>"). Empty for shapes with no flat spelling
/// (nested arrays, atomics, textures, samplers, pointers).
fn typeInfoName(alloc: Allocator, ti: *const wgslender.Reflect.TypeInfo) Allocator.Error![]const u8 {
    switch (ti.*) {
        .scalar => |s| return alloc.dupe(u8, s.name),
        .vec => |v| {
            const inner = if (v.format.* == .scalar) v.format.scalar.name else return "";
            return std.fmt.allocPrint(alloc, "vec{d}<{s}>", .{ v.width, inner });
        },
        .mat => |m| {
            const inner = if (m.format.* == .scalar) m.format.scalar.name else return "";
            return std.fmt.allocPrint(alloc, "mat{d}x{d}<{s}>", .{ m.cols, m.rows, inner });
        },
        .@"struct" => |s| return alloc.dupe(u8, s.name),
        else => return "",
    }
}

// ============================================================================
// Tests
// ============================================================================

// --- R1 adapter widening: resource kind / workgroup_size / entry I/O ---

// `resources` lists the buffer bindings an entry actually references.
// Characterized 2026-07-01: through the public `wgslender.reflect` (legacy
// Parser) path, **buffer** bindings (uniform/storage) used in expressions
// reliably appear; texture/sampler bindings used only as sampling-builtin
// arguments do NOT (the legacy parser leaves those arg-ident refs
// unresolved). This is sufficient for R1: the "used but unbound" check
// (Task 2) targets buffer bindings, and the bind resource-kind check
// (Task 3) matches on `(group, binding)` directly — neither relies on
// texture/sampler membership in `resources`.

// A struct-typed vertex parameter must flatten to one `IoVar` per attributed
// member, so the R1 Task 4 vertex-attribute check sees the same `@location`s
// whether the shader lists params inline (rotating_cube) or bundles them in a
// struct (the webgpu-samples idiom). Characterized 2026-07-01: confirms the
// `wgslender.zig` IoVar doc-comment ("Struct-typed parameters/returns are
// flattened to one IoVar per attributed member upstream") holds through the
// native path — the check depends on it to avoid missing struct-bundled inputs.

// --- specialiseOverrides (CONST-04) ----------------------------------------

/// Specialise `source` and return the rewritten text, failing the test with a
/// legible message if the transform refused.
fn specialiseForTest(source: []const u8, specs: []const Specialisation) ![]u8 {
    var err: ?SpecialiseError = null;
    return specialiseOverrides(std.testing.allocator, source, specs, &err) catch |e| {
        std.debug.print("\nspecialise failed: {s} ({any})\n", .{ @errorName(e), err });
        return e;
    };
}
