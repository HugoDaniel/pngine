//! Validate command: upfront source-level validation of `.sjon` files.
//!
//! ## Usage
//! ```
//! pngine validate shader.sjon             # Human-readable error/warning report
//! pngine validate shader.sjon --json      # Structured JSON output
//! pngine validate shader.sjon --verbose   # Show each validation phase
//! ```
//!
//! ## Design
//! Compiles the source with WGSL validation always enabled, then discards the
//! bytecode output. The SJON host runs parse → lower → materialize-defaults →
//! validate → WGSL-validate → emit (catching schema, cross-reference, and
//! shader errors).
//!
//! The legacy `.pngine` macro DSL and `.pbsf` assembler frontends were
//! retired. For bytecode-level inspection (MockGPU, WAMR), use `pngine
//! inspect`.

const std = @import("std");
const pngine = @import("pngine");
const utils = @import("utils.zig");
const stdio = @import("stdio.zig");
const arg_reader = @import("arg_reader.zig");

/// Execute the validate command.
///
/// Pre-condition: args is the slice after "validate" command.
/// Post-condition: Returns exit code (0 = success, 1 = errors found).
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    std.debug.assert(args.len <= 1024);

    // Parse arguments (shared plumbing via ArgReader).
    var opts = Options{};
    var reader = arg_reader.ArgReader.init(args);
    while (reader.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json_output = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            opts.strict = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return 0;
        } else if (arg_reader.ArgReader.isFlag(arg)) {
            return arg_reader.unknownOption(arg);
        } else {
            reader.addPositional(arg) catch return arg_reader.duplicateInput();
        }
    }
    if (reader.positional) |p| opts.input = p;

    if (opts.input.len == 0) {
        std.debug.print("Error: no input file specified\n\n", .{});
        printHelp();
        return 1;
    }

    // Only accept source files (legacy `.pngine`/`.pbsf` frontends retired).
    // `-` is checked after the read instead — stdin's kind comes from its bytes.
    if (!stdio.isSjonPath(opts.input)) {
        std.debug.print("Error: validate only accepts .sjon source files\n", .{});
        std.debug.print("  For bytecode inspection, use: pngine inspect {s}\n", .{opts.input});
        return 1;
    }

    return runValidation(allocator, io, opts);
}

const Options = struct {
    input: []const u8 = "",
    json_output: bool = false,
    verbose: bool = false,
    /// Exit 1 when a VALID document still carried warnings (for CI). Off by
    /// default: advisory findings are advisory, and a lint pack that failed
    /// builds by default would be a lint pack people turn off.
    strict: bool = false,
};

/// Read the source and run the SJON validator. `run()` has already
/// restricted the extension to `.sjon`.
fn runValidation(allocator: std.mem.Allocator, io: std.Io, opts: Options) !u8 {
    const in = stdio.readInput(allocator, io, opts.input) catch |err| {
        if (opts.json_output) {
            // The JSON envelope is the contract for `--json`; a read failure
            // has to arrive in it too, or a consumer sees an empty stdout and
            // an exit code with no explanation it can parse.
            const line = std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"message\":\"failed to read input: {s}\"}}\n", .{@errorName(err)}) catch return 2;
            defer allocator.free(line);
            utils.writeStdout(io, line) catch {};
            return 2;
        }
        return stdio.reportReadError(err, opts.input);
    };
    defer in.deinit(allocator);

    if (in.kind != .sjon) {
        std.debug.print("Error: validate expects SJON source, got {t} on stdin\n", .{in.kind});
        std.debug.print("  For bytecode inspection, use: pngine inspect -\n", .{});
        return 1;
    }
    const source = in.bytes;

    if (opts.verbose) {
        std.debug.print("Read: {d} bytes\n", .{source.len});
    }

    return runSjonValidation(allocator, io, opts, source);
}

/// Validate `.sjon` source through the SJON host pipeline. `compileWithOptions`
/// runs parse → lower → materialize-defaults → validate → WGSL-validate → emit;
/// a `Compiler.Diag` sink collects every diagnostic (structural + emit-time) with
/// its source location, and — because the sink owns rendering — the pipeline emits
/// NO stderr dump, so `--json` writes clean structured output to stdout and the
/// human path prints one domain-labeled line. The bytecode is discarded;
/// validation only cares that emission succeeds.
fn runSjonValidation(allocator: std.mem.Allocator, io: std.Io, opts: Options, source: [:0]const u8) !u8 {
    const base_dir = stdio.baseDir(opts.input);

    var diag: pngine.dsl_sjon.Compiler.Diag = .{};
    const bytecode = pngine.dsl_sjon.Compiler.compileWithOptions(allocator, source, .{
        .base_dir = base_dir,
        .validate_shaders = true,
        // `validate` is the one command where a human is explicitly asking for a
        // report, so it is the one that pays for lint. Findings stay advisory by
        // DEFAULT — they change the exit code only under `--strict`.
        .lint_shaders = true,
        .io = io,
        .diag = &diag,
    }) catch |err| return reportFailure(allocator, io, opts, &diag, err);
    allocator.free(bytecode);

    return reportSuccess(allocator, io, opts, &diag);
}

/// The class of a compile failure, for the JSON envelope's `message`.
fn genericMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ParseError => "parse failed",
        error.ValidationError => "validation failed",
        error.EmitError => "emit failed",
        error.FileReadError => "failed to read referenced file",
        error.OutOfMemory => "out of memory",
        else => "validation failed",
    };
}

/// Render a failed validation. Always exit 1.
fn reportFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    diag: *const pngine.dsl_sjon.Compiler.Diag,
    err: anyerror,
) u8 {
    const msg = failureMessage(diag, genericMessage(err));

    if (opts.json_output) {
        // `diagnostics` is the structured, located array: SJON structural
        // rejects AND Emitter cross-validation checks both carry real line/col
        // (+ a code / WGSL-module tag), one entry per offending form — a
        // multi-shader document reports every broken shader, not just the first.
        // A genuinely unlocatable check — a used-but-unbound binding with no
        // SJON node, an unreadable file behind a hook-lowered form — stays an
        // unlocated headline and is omitted from the array, so `message` is
        // that refusal's whole report and carries the headline, not the class
        // string. (It used to carry the class string, and a document whose
        // only fault was a missing file answered `"emit failed"` with an
        // empty array — indistinguishable, to a gate, from having no answer.)
        var jbuf: [32 * 1024]u8 = undefined;
        const n = diag.writeJson(&jbuf);
        const quoted = std.json.Stringify.valueAlloc(allocator, msg, .{}) catch return 1;
        defer allocator.free(quoted);
        const line = std.fmt.allocPrint(allocator, "{{\"status\":\"error\",\"message\":{s},\"diagnostics\":{s}}}\n", .{ quoted, jbuf[0..n] }) catch return 1;
        defer allocator.free(line);
        utils.writeStdout(io, line) catch {};
    } else {
        std.debug.print("{s}: {s}\n", .{ stdio.displayName(opts.input), msg });
        printLocatedErrors(diag);
    }
    return 1;
}

/// The headline of a failed validation, for BOTH output modes: the Emitter's
/// domain-labeled message when it captured one (a WGSL error, an unreadable
/// file, an unbound binding), else the error class string. Located entries
/// are the detail; this is the one line that must never say less than the
/// terminal does.
fn failureMessage(diag: *const pngine.dsl_sjon.Compiler.Diag, generic: []const u8) []const u8 {
    std.debug.assert(generic.len > 0);
    return if (diag.set) diag.message() else generic;
}

/// Whether `--strict` turns a SUCCESSFUL validation into exit 1.
///
/// `dropped` counts as a failure on its own: the entries array is capped at
/// `Diag.MAX_ENTRIES`, so a non-zero `dropped` means what we can see is a
/// PREFIX. Reading zero warnings off a truncated list and reporting clean is
/// green-over-nothing — the flag exists to refuse exactly that.
fn strictFailure(strict: bool, warnings: u32, dropped: u32) bool {
    return strict and (warnings > 0 or dropped > 0);
}

/// Count the warning-severity entries the sink collected.
fn warningCount(diag: *const pngine.dsl_sjon.Compiler.Diag) u32 {
    std.debug.assert(diag.count <= pngine.dsl_sjon.Compiler.Diag.MAX_ENTRIES);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < diag.count) : (i += 1) {
        if (diag.entries[i].severity == .warning) n += 1;
    }
    return n;
}

/// Render a successful validation — which can still carry advisory warnings.
/// Exit 0, unless `--strict` turns those warnings into a failure (for CI).
///
/// Why `--strict` exists at all: a warning here is not always cosmetic. A
/// reflection-INFRA failure (realistically OOM inside wgslender) warns and
/// proceeds, and the emitted payload is complete but its uniform table is
/// missing that module's bindings — so `setUniform` silently no-ops at runtime,
/// far from the cause. Without this flag there was no way for the one command
/// whose job is answering "is this document sound?" to answer "I could not
/// check". `inspect` had `--strict` for the same reason; `validate` did not.
fn reportSuccess(
    allocator: std.mem.Allocator,
    io: std.Io,
    opts: Options,
    diag: *const pngine.dsl_sjon.Compiler.Diag,
) u8 {
    // A document is strictly clean only when nothing was reported AND nothing
    // was dropped. `dropped > 0` means the entries array is a PREFIX, so
    // "no warnings visible" cannot be told apart from "the sink filled up" —
    // and certifying clean off a truncated list is exactly the kind of
    // green-over-nothing this flag is meant to prevent.
    const warnings = warningCount(diag);
    const strict_fail = strictFailure(opts.strict, warnings, diag.dropped);
    if (opts.json_output) {
        // Stable envelope: always carry `diagnostics`. A SUCCESSFUL validation
        // may still have collected warnings (advisory uniform-table notes), so
        // serialize the sink instead of hardcoding `[]`.
        var jbuf: [32 * 1024]u8 = undefined;
        const n = diag.writeJson(&jbuf);
        // `dropped` rides the envelope because `writeJson` emits a bare array.
        // It is not decoration: `Diag` caps at 64 entries, which was ample when
        // only errors and a few uniform-table notes landed here, and is reachable
        // now that advisory lint findings do too. A consumer that sees
        // `"dropped": 7` knows the array is a prefix, not the whole story.
        const line = std.fmt.allocPrint(
            allocator,
            "{{\"status\":\"ok\",\"diagnostics\":{s},\"dropped\":{d}}}\n",
            .{ jbuf[0..n], diag.dropped },
        ) catch return 0;
        defer allocator.free(line);
        utils.writeStdout(io, line) catch {};
        // `--strict` changes ONLY the exit code; the envelope keeps `status:
        // "ok"` because the document IS valid — the warnings are already in
        // `diagnostics`. Making the shape depend on a flag would cost every
        // consumer more than it buys the one running CI.
        return if (strict_fail) 1 else 0;
    }

    std.debug.print("{s}: OK\n", .{stdio.displayName(opts.input)});
    // The sink owns rendering (the compiler printed nothing), so surface
    // any collected warnings for the human too. Bounded by MAX_ENTRIES.
    var i: u32 = 0;
    while (i < diag.count) : (i += 1) {
        const e = diag.entries[i];
        if (e.severity != .warning) continue;
        std.debug.print("  warning: {s}\n", .{diag.entryMessage(e)});
    }
    if (diag.dropped > 0) {
        std.debug.print(
            "  ({d} further diagnostic(s) dropped — the sink caps at {d})\n",
            .{ diag.dropped, pngine.dsl_sjon.Compiler.Diag.MAX_ENTRIES },
        );
    }
    // Say WHY the exit code disagrees with the "OK" above — a CI log showing a
    // successful report and a failing command, with nothing joining them, is
    // how a flag like this gets blamed for flakiness.
    if (strict_fail) {
        std.debug.print(
            "  (--strict: {d} warning(s){s} → exit 1)\n",
            .{ warnings, if (diag.dropped > 0) " plus dropped diagnostics" else "" },
        );
    }
    return if (strict_fail) 1 else 0;
}

/// Print the collected LOCATED error entries under the headline.
///
/// Without this a structural reject printed two words — "validation failed" —
/// while every diagnostic explaining it sat in the sink, reachable only
/// through `--json`. That is not an oversight in `diag.zig`: a structural
/// reject deliberately never claims the first-writer headline (`.set` is the
/// Emitter's WGSL-vs-SJON channel, and a negative test pins `!diag.set` for a
/// schema reject), so for those rejects the ENTRIES, not the headline, are the
/// human's whole report. The success path already prints its warnings this
/// way; the failure path just never printed its errors.
///
/// An entry repeating the headline is skipped — the WGSL path fills both.
fn printLocatedErrors(diag: *const pngine.dsl_sjon.Compiler.Diag) void {
    std.debug.assert(diag.count <= pngine.dsl_sjon.Compiler.Diag.MAX_ENTRIES);
    var i: u32 = 0;
    while (i < diag.count) : (i += 1) {
        const e = diag.entries[i];
        if (e.severity != .err or e.line == 0) continue;
        const m = diag.entryMessage(e);
        if (diag.set and std.mem.eql(u8, m, diag.message())) continue;
        const shader = diag.entryShader(e);
        if (shader.len != 0) {
            std.debug.print("  {s}:{d}:{d}: {s}\n", .{ shader, e.line, e.col, m });
        } else {
            std.debug.print("  {d}:{d}: {s}\n", .{ e.line, e.col, m });
        }
    }
    if (diag.dropped > 0) {
        std.debug.print(
            "  ({d} further diagnostic(s) dropped — the sink caps at {d})\n",
            .{ diag.dropped, pngine.dsl_sjon.Compiler.Diag.MAX_ENTRIES },
        );
    }
}

// ============================================================================
// Help
// ============================================================================

fn printHelp() void {
    std.debug.print(
        \\PNGine Validate - Source-level validation
        \\
        \\Usage: pngine validate <input.sjon|-> [options]
        \\
        \\Validates source for correctness. Runs the full compiler pipeline with
        \\WGSL validation enabled, catching:
        \\  - Syntax errors (malformed forms, invalid tokens)
        \\  - Semantic errors (undefined references, schema violations, cycles)
        \\  - Shader errors (WGSL type errors, undefined symbols, uniformity)
        \\
        \\Also reports ADVISORY WGSL lint findings (wgslender's
        \\@wgslender/recommended pack: unused vars and bindings, dead and
        \\unreachable code, constant conditions, for-direction, duplicate cases,
        \\self-assignment, redundant casts). Advisory means advisory — findings
        \\print as warnings and, by default, never change the exit code — pass
        \\--strict to turn any warning into exit 1 (for CI).
        \\
        \\  An unused BINDING is the one worth acting on: `:layout auto` strips
        \\  bindings no entry point uses, which desyncs any (bind-group ...) that
        \\  binds them and otherwise surfaces only as an opaque abort at render
        \\  time.
        \\
        \\
        \\Options:
        \\  --json                 Output structured JSON
        \\  --strict               Exit code 1 on warnings (for CI). Changes only
        \\                         the exit code — --json still reports status "ok"
        \\                         for a valid document, with the warnings in
        \\                         "diagnostics".
        \\  -v, --verbose          Show each validation phase
        \\  -h, --help             Show this help
        \\
        \\For bytecode-level inspection, use: pngine inspect <input>
        \\
        \\Examples:
        \\  pngine validate shader.sjon
        \\  pngine validate shader.sjon --json
        \\  pngine validate shader.sjon --verbose
        \\  pngine validate shader.sjon --strict     # fail CI on advisory findings
        \\  curl -s $url | pngine validate - --json
        \\
    , .{});
}

// ============================================================================
// Tests
// ============================================================================
//
// Discovered via `src/cli.zig`'s `test { _ = @import("cli/validate.zig"); }`
// block, so they run under the full `zig build test` (not `test-standalone`).
