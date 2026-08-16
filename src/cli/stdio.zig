//! The `-` convention: stdin and stdout as first-class input/output paths.
//!
//! ## Design
//!
//! Every command reads its input through `readInput` and writes its artifact
//! through `writeOutput`, so `-` is handled in exactly one place instead of
//! nine. A real path keeps the behaviour it always had — the extension names
//! the format and the file's directory is the base for relative references.
//! Only `-` changes anything, and it changes both:
//!
//! - **Format comes from the bytes, not the name.** stdin has no extension, so
//!   `sniff` reads the leading magic. Order is longest-first and unambiguous:
//!   no PNG starts with `PNGB`, no PNGB starts with `PK`.
//! - **The base directory is the cwd.** A piped document's `(data …)` references
//!   cannot resolve relative to a file that does not exist; the cwd is what
//!   `< shader.sjon` implies to every other Unix tool.
//!
//! ## Invariants
//!
//! - `sniff` is pure and total: bytes in, `Kind` or null out, no allocation.
//! - The read is bounded by `utils.max_file_size` — the same 16 MiB cap that
//!   already guards file reads. A stdin cap looser than the file cap would be
//!   a hole in that guard, not a convenience.
//! - Bytes are returned NUL-terminated whatever the kind, so the SJON frontend
//!   (which wants `[:0]const u8`) and the binary readers share one buffer type.
//! - Binary artifacts are never written to a terminal. The check is split into
//!   a pure predicate (`refuseBinaryToTty`) and its one impure caller, so the
//!   decision can be unit-tested without a test ever writing to fd 1 — which
//!   under the Zig test runner is the test protocol itself (CONTRIBUTING §11c).
//!   The impure caller is covered too: `casePtyGuard` in the e2e hands a child
//!   a pty slave as its stdout and watches the refusal fire.
//! - A real path's extension is matched case-insensitively, and
//!   `kindFromExtension` is the only place that knows either the table or the
//!   rule. `isSjonPath` is how the four commands that need "is this source?"
//!   ask, instead of each spelling the comparison out.

const std = @import("std");
const utils = @import("utils.zig");

/// The argument that means "stdin" as an input and "stdout" as an output.
pub const std_path = "-";

/// What a piece of input turned out to be. `sjon` is the fallback rather than
/// a magic match: it is the only text format, so anything that is not one of
/// the three binary containers and contains no NUL is source.
pub const Kind = enum {
    sjon,
    pngb,
    png,
    zip,

    /// True when a file of this kind must not be written to a terminal.
    pub fn isBinary(kind: Kind) bool {
        return kind != .sjon;
    }
};

pub const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
pub const pngb_magic = "PNGB";
pub const zip_magic = [_]u8{ 'P', 'K', 3, 4 };

/// The four kinds, spelled for error messages. Single source so every command
/// rejects unrecognized input with the same list.
pub const accepted_formats = "SJON source, PNGB bytecode, PNG, or ZIP bundle";

pub const Error = error{
    /// stdin exceeded `utils.max_file_size`.
    StdinTooLarge,
    /// The bytes matched no known magic and are not text.
    UnrecognizedFormat,
    /// A binary artifact was about to be written to a terminal.
    BinaryToTerminal,
    /// Two inputs both asked for stdin.
    DuplicateStdin,
};

/// True if `path` is the bare `-`.
///
/// Deliberately exact: `-o` and `-` are different arguments, and a path that
/// merely starts with `-` is a (probably mistyped) flag, not stdin.
pub fn isStd(path: []const u8) bool {
    return path.len == 1 and path[0] == '-';
}

/// How to name this input in a diagnostic. `-` reads as a typo in a sentence;
/// `<stdin>` does not.
pub fn displayName(path: []const u8) []const u8 {
    return if (isStd(path)) "<stdin>" else path;
}

/// How to name an output destination in a status line. Status lines go to
/// stderr, so they print even when the artifact itself went to stdout.
pub fn outName(path: []const u8) []const u8 {
    return if (isStd(path)) "<stdout>" else path;
}

/// The directory relative references in this input resolve against.
///
/// For a real file that is the file's own directory, which is what lets
/// `examples/teapot.sjon` reach `meshes/teapot.bin`. Piped source has no
/// directory of its own, so it gets the cwd.
pub fn baseDir(path: []const u8) []const u8 {
    if (isStd(path)) return ".";
    return std.fs.path.dirname(path) orelse ".";
}

/// Identify `data` by its leading bytes. Pure; null means "none of the four".
///
/// Complexity: O(n) — the text fallback scans for NUL. Everything else is a
/// fixed-length prefix compare.
pub fn sniff(data: []const u8) ?Kind {
    if (data.len >= png_signature.len and std.mem.eql(u8, data[0..png_signature.len], &png_signature)) return .png;
    if (data.len >= pngb_magic.len and std.mem.eql(u8, data[0..pngb_magic.len], pngb_magic)) return .pngb;
    if (data.len >= zip_magic.len and std.mem.eql(u8, data[0..zip_magic.len], &zip_magic)) return .zip;

    // Text or nothing. A NUL means these are bytes from some binary format we
    // do not know — handing them to the SJON parser would produce a confusing
    // syntax error instead of an honest "I don't recognise this".
    if (data.len == 0) return null;
    if (std.mem.indexOfScalar(u8, data, 0) != null) return null;
    return .sjon;
}

/// Kind implied by a real path's extension, or null if the extension is not
/// one we handle. Keeps the historical extension dispatch in one place.
///
/// Case-insensitive: `ART.PNG` is a PNG. Extensions are names, and a file off a
/// camera, a Windows share, or a decade-old download is entitled to shout. The
/// fold is here rather than at the call sites because this is the only function
/// that knows the table — one place owns both what the extensions are and how
/// they are compared.
pub fn kindFromExtension(path: []const u8) ?Kind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".sjon")) return .sjon;
    if (std.ascii.eqlIgnoreCase(ext, ".pngb")) return .pngb;
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(ext, ".zip")) return .zip;
    return null;
}

/// True when `path` names SJON source — including `-`, whose kind comes from
/// its bytes rather than its name but which is source in every case that asks.
///
/// Four commands need this question answered (`cli.zig`'s implicit-render
/// entry, `compile`, `validate`, `render`), and each had its own
/// `isStd(path) or std.mem.eql(u8, extension(path), ".sjon")`. Five copies of a
/// rule is five places to fix when the rule changes — which is exactly what
/// folding case would have been. Now the extension table and the case rule live
/// in one function, and everyone asks it.
pub fn isSjonPath(path: []const u8) bool {
    std.debug.assert(path.len > 0);
    return isStd(path) or kindFromExtension(path) == .sjon;
}

/// Input bytes plus what they turned out to be.
pub const Input = struct {
    /// NUL-terminated so the SJON frontend can take `bytes` directly; binary
    /// consumers ignore the sentinel.
    bytes: [:0]const u8,
    kind: Kind,

    pub fn deinit(self: Input, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }
};

/// Chunk size for the stdin read. 64 KiB is a pipe buffer's worth.
const chunk_len: u32 = 64 * 1024;

/// Termination bound for the read loop.
///
/// It counts *reads*, not chunks, and a stream may hand over as little as one
/// byte per read — a slow producer at the far end of a pipe is entitled to.
/// Sizing this by chunks (`max_file_size / chunk_len`) would therefore reject
/// a perfectly small input from a trickling writer with "too large". So the
/// bound is per byte; the byte check inside the loop is the real cap, and this
/// only guarantees the loop ends.
const max_reads: u32 = utils.max_file_size + 2;

/// Read `path`, or all of stdin when it is `-`, and identify it.
///
/// A real path is still identified by extension — that is the behaviour every
/// existing test pins, and a `.png` whose bytes are not a PNG should say so as
/// a PNG error, not be silently reinterpreted. Only stdin is sniffed.
///
/// Pre-condition: path is non-empty.
/// Post-condition: the returned buffer is NUL-terminated at [len].
pub fn readInput(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Input {
    std.debug.assert(path.len > 0);

    if (isStd(path)) {
        const bytes = try readAllStdin(gpa, io);
        errdefer gpa.free(bytes);
        const kind = sniff(bytes) orelse return Error.UnrecognizedFormat;
        return .{ .bytes = bytes, .kind = kind };
    }

    const kind = kindFromExtension(path) orelse return error.UnsupportedFormat;
    // Sentinel-terminated even for binary kinds: one buffer type for both
    // consumers costs a byte and removes a whole branch from every caller.
    const bytes = try utils.readSourceFile(gpa, io, path);
    std.debug.assert(bytes[bytes.len] == 0);
    return .{ .bytes = bytes, .kind = kind };
}

/// Slurp stdin with an explicit cap.
///
/// Post-condition: the result is at most `max_file_size` bytes.
fn readAllStdin(gpa: std.mem.Allocator, io: std.Io) ![:0]u8 {
    return accumulateStdin(gpa, io, std.Io.File.stdin());
}

/// The read loop itself, over anything with `readStreaming(io, [][]u8) !usize`.
///
/// Split from `readAllStdin` for one reason: how a stream *paces* its bytes is
/// the whole risk here, and a real fd cannot be made to trickle on demand. A
/// scripted reader can — one byte per read, exactly-at-the-cap, ending by a
/// zero read or by `error.EndOfStream` — so every branch below is driven by a
/// test rather than argued about in a comment.
///
/// Pre-condition: the cap is positive (asserted so a future edit to
/// `max_file_size` cannot silently disable the guard).
/// Post-condition: the result is at most `max_file_size` bytes.
fn accumulateStdin(gpa: std.mem.Allocator, io: std.Io, reader: anytype) ![:0]u8 {
    comptime std.debug.assert(utils.max_file_size > 0);
    // `anytype` accepts every type until the call below fails somewhere deep
    // inside it. Name the one thing this seam requires, so passing the wrong
    // thing is a sentence rather than an error trace through std.
    comptime std.debug.assert(std.meta.hasMethod(@TypeOf(reader), "readStreaming"));

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);

    var buf: [chunk_len]u8 = undefined;
    for (0..max_reads) |_| {
        // A stream signals its end with error.EndOfStream, not a zero read —
        // unlike the file readers in utils.zig, which stat the size first and
        // so never reach EOF at all. Both spellings end the loop; anything else
        // is a real failure and propagates.
        const n = reader.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) break;
        if (list.items.len + n > utils.max_file_size) return Error.StdinTooLarge;
        try list.appendSlice(gpa, buf[0..n]);
    } else return Error.StdinTooLarge; // Defense in depth: unreachable by the
    // arithmetic below (`max_reads > max_file_size`, and a read that returns 0
    // breaks), so no test drives it. Kept because the alternative to a bounded
    // loop is an unbounded one.

    std.debug.assert(list.items.len <= utils.max_file_size);
    return list.toOwnedSliceSentinel(gpa, 0);
}

/// A resolved output destination, carrying who owns the string.
///
/// The choice is three-way — an explicit `-o`, stdout because the input was
/// piped, or a name derived from the input — and each arm has a different
/// ownership answer. Expressing that at the call site as
/// `defer if (output_path == null and !isStd(input)) free(derived)` restates
/// the whole if-chain in a condition that has to be kept in sync with it, in
/// every command. Pairing the answer with the value removes the chance to get
/// them out of step.
pub const Output = struct {
    path: []const u8,
    owns: bool,

    /// A path this struct does not own: an argv slice, or the `-` literal.
    pub fn borrowed(path: []const u8) Output {
        std.debug.assert(path.len > 0);
        return .{ .path = path, .owns = false };
    }

    /// A freshly allocated path this struct takes responsibility for.
    pub fn owned(path: []const u8) Output {
        std.debug.assert(path.len > 0);
        return .{ .path = path, .owns = true };
    }

    pub fn deinit(self: Output, gpa: std.mem.Allocator) void {
        if (self.owns) gpa.free(self.path);
    }
};

/// Should this write be refused? Pure, so the branch a spawned test can never
/// reach (stdout being a terminal) is still covered by a unit test.
pub fn refuseBinaryToTty(is_binary: bool, is_tty: bool) bool {
    return is_binary and is_tty;
}

/// Write `data` to `path`, or to stdout when it is `-`.
///
/// Binary artifacts are refused on a terminal: dumping a PNG into a user's
/// scrollback corrupts the terminal state and is never what was meant. Text
/// reports write to a terminal freely.
///
/// Pre-condition: path is non-empty, and `data` is a real artifact.
/// An empty artifact is never a legitimate outcome — a PNGB is 40 bytes of
/// header before it holds anything, a PNG has its signature, a ZIP its central
/// directory — so `data.len == 0` means a compile silently produced nothing,
/// and writing an empty file (or nothing at all) hides that from a pipeline.
/// The file path already asserted this in `utils.writeOutputFile`; asserting it
/// here too means one function has one contract, whichever branch it takes.
pub fn writeOutput(io: std.Io, path: []const u8, data: []const u8, binary: bool) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(data.len > 0);

    if (!isStd(path)) return utils.writeOutputFile(io, path, data);

    const out = std.Io.File.stdout();
    if (refuseBinaryToTty(binary, try out.isTty(io))) return Error.BinaryToTerminal;
    try out.writeStreamingAll(io, data);
}

/// Render an input-side failure. One message per cause, shared by every
/// command so `compile`, `inspect` and `list` explain the same thing the same
/// way. Returns the exit code the caller should use.
pub fn reportReadError(err: anyerror, path: []const u8) u8 {
    switch (err) {
        Error.StdinTooLarge => {
            std.debug.print("Error: input exceeds the {d} MiB limit\n", .{utils.max_file_size / (1024 * 1024)});
            return 2;
        },
        Error.UnrecognizedFormat => {
            std.debug.print("Error: unrecognized input format on stdin (expected {s})\n", .{accepted_formats});
            return 4;
        },
        error.UnsupportedFormat => {
            std.debug.print("Error: '{s}' has no recognized extension (expected .sjon, .pngb, .png or .zip)\n", .{path});
            return 4;
        },
        else => {
            std.debug.print("Error: failed to read '{s}': {}\n", .{ displayName(path), err });
            return 2;
        },
    }
}

/// Render an output-side failure. Returns the exit code the caller should use.
pub fn reportWriteError(err: anyerror, path: []const u8) u8 {
    if (err == Error.BinaryToTerminal) {
        std.debug.print("Error: refusing to write binary output to a terminal; pipe or redirect it\n", .{});
        return 1;
    }
    std.debug.print("Error: failed to write '{s}': {}\n", .{ if (isStd(path)) "<stdout>" else path, err });
    return 2;
}

/// True when both inputs asked for stdin. Only one stream can be stdin;
/// `diff - -` would otherwise read the same bytes twice and always report a
/// match, which is worse than an error. Pure — the caller renders it via
/// `reportDoubleStdin` so this stays testable without stderr noise.
pub fn bothStdin(a: []const u8, b: []const u8) bool {
    return isStd(a) and isStd(b);
}

/// Render the double-stdin rejection; returns the exit code to use.
pub fn reportDoubleStdin() u8 {
    std.debug.print("Error: only one input may be stdin ('-')\n", .{});
    return 1;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// A stdin that delivers exactly what a test tells it to, at the pace it says.
///
/// The kernel decides how much a real pipe hands over per read, so neither the
/// trickle case (one byte at a time) nor the exactly-at-the-cap case can be
/// staged with a real fd. Bytes are *synthesized* rather than stored — `;` is a
/// SJON comment, so 16 MiB of them is valid text and costs no fixture.
const ScriptedStdin = struct {
    /// Bytes still to hand over.
    remaining: u64,
    /// Ceiling on a single read. 1 is the trickling-producer case.
    per_read: u32 = chunk_len,
    /// How the stream behaves once `remaining` hits zero.
    end: End = .end_of_stream,

    const End = enum {
        /// The POSIX spelling of EOF, and what a file-backed stdin gives.
        zero_read,
        /// What `std.Io.File.readStreaming` raises at end of stream.
        end_of_stream,
        /// A genuine failure — must propagate, not be read as an ending.
        read_error,
    };

    /// Two members so the loop's `else => |e| return e` prong is reachable:
    /// a read failure must not be mistaken for a clean end of stream.
    const ReadError = error{ EndOfStream, InputOutput };

    /// Public because the seam's contract is checked with `std.meta.hasMethod`,
    /// and `@hasDecl` from another file cannot see a private one.
    pub fn readStreaming(self: *ScriptedStdin, io: std.Io, buffers: []const []u8) ReadError!usize {
        _ = io;
        std.debug.assert(buffers.len >= 1);
        const dest = buffers[0];
        std.debug.assert(dest.len > 0);

        if (self.remaining == 0) return switch (self.end) {
            .zero_read => 0,
            .end_of_stream => error.EndOfStream,
            .read_error => error.InputOutput,
        };

        const n: usize = @intCast(@min(@min(self.remaining, self.per_read), dest.len));
        std.debug.assert(n > 0);
        @memset(dest[0..n], ';');
        self.remaining -= n;
        return n;
    }
};

/// Bound on the walk below. The 64 KiB payload needs ~10 allocations (an
/// ArrayList doubling, plus the sentinel copy); 64 is slack, and exhausting it
/// means the allocation shape changed enough to be worth re-reading.
const max_alloc_points: u32 = 64;
