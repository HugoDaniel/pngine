//! One seam between the emitter and the bytes behind a `:file` key.
//!
//! Five schema keys name a file today (`(data :file)`, `(wasm-data :file)`,
//! `(wasm-call :file)`, `(buffer :file)`, `(pass :file)`), and the WGSL
//! preprocessor adds two more (`(wgsl :file)`, `(shader-module :file)`). All of
//! them used to reach one function on the Emitter that opened the filesystem
//! directly, which is why none of them worked in the in-browser compiler:
//! `src/wasm_compiler.zig` has neither a `base_dir` nor an `std.Io`.
//!
//! ## Design
//!
//! - `FileResolver` is a vtable-lite pair (`ctx`, `readFn`). Two implementations
//!   ship: `FilesystemResolver` for the CLI, `TableResolver` over bytes the host
//!   hands in for the browser.
//! - **The path rules run in `FileResolver.read`, above the implementation.**
//!   An implementation therefore cannot forget them, and a third one (an HTTP
//!   fetch, a ZIP member) gets them for free. They restate the rules the
//!   pre-SJON `ImportResolver` enforced: relative only, no climbing out of the
//!   document's directory.
//! - **Those rules are LEXICAL, so containment is finished by the one
//!   implementation that has a filesystem.** `normalise` reads the text of a
//!   path and nothing else; a symlink is invisible to it, so `./lib/x.wgsl`
//!   passed every rule and still read `/etc/passwd` when `lib` was a link.
//!   `FilesystemResolver` refuses a symlinked component (§438). A resolver with
//!   no filesystem has no links to follow and needs no such check.
//! - Every read returns `gpa`-owned bytes. The caller frees with `gpa.free`,
//!   whichever implementation answered.
//!
//! ## Invariants
//!
//! - `readFn` is never called with a path that has not been normalised, so an
//!   implementation may treat its argument as clean and relative.
//! - A normalised path never begins with `/`, never contains `..`, `.` or an
//!   empty segment, and never exceeds `MAX_PATH` bytes.
//! - `limit` is the byte ceiling and is EXCLUSIVE: a file that reaches it is
//!   `TooLarge`. That is `std.Io.Dir.readFileAlloc`'s own rule ("if reached or
//!   exceeded"), mirrored here so both implementations agree.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// The longest path a document may write, matching the `[512]u8` join buffer
/// the Emitter's filesystem read used before this module existed.
pub const MAX_PATH: u32 = 512;

/// The most path segments a normalised path may have. The walk is a bounded
/// loop over an explicit stack of this size — no recursion, per the repo's Zig
/// rules — and 64 is far past any real `./lib/shaders/x.wgsl`.
pub const MAX_SEGMENTS: u32 = 64;

/// What a resolver can fail with. Deliberately small and *sentence-shaped*:
/// each variant maps to one refusal the emitter can phrase for an author, and
/// `unreadableFile` in `Emitter.zig` switches on exactly these.
pub const ReadError = error{
    /// The path is well-formed but nothing is there.
    NotFound,
    /// The bytes exist and reach or exceed the caller's limit.
    TooLarge,
    /// The path breaks a rule in the table below — absolute, climbing, empty,
    /// or carrying a byte a path may not carry.
    InvalidPath,
    /// A component of the path is a symbolic link. The lexical rules cannot see
    /// one, so it is refused here where the filesystem can.
    Symlink,
    /// The host has bytes but could not hand them over (a permission error, a
    /// directory where a file was named, a host with no IO at all).
    ReadFailed,
    OutOfMemory,
};

/// The path-rule half of `ReadError`, so `normalise` can be called on its own
/// (the table builder does, to canonicalise its keys) without pretending it
/// might run out of memory.
pub const NormaliseError = error{InvalidPath};

/// A source of bytes for a path written in a document.
pub const FileResolver = struct {
    ctx: *anyopaque,
    readFn: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8, limit: u32) ReadError![]u8,

    /// Apply the path rules, then delegate. THE entry point: nothing else in
    /// the codebase should call `readFn` directly, because the rules live here
    /// and not in the implementations.
    ///
    /// Complexity: O(path.len) for the rules, then the implementation's.
    ///
    /// Caller owns the returned bytes: every implementation allocates or dupes
    /// into `gpa`, so a resolver may never hand back a borrowed slice.
    pub fn read(self: FileResolver, gpa: Allocator, path: []const u8, limit: u32) ReadError![]u8 {
        std.debug.assert(limit > 0); // a zero ceiling would refuse every file
        var buf: [MAX_PATH]u8 = undefined;
        const clean = normalise(path, &buf) catch return error.InvalidPath;
        std.debug.assert(clean.len > 0);
        std.debug.assert(clean[0] != '/');
        const bytes = try self.readFn(self.ctx, gpa, clean, limit);
        std.debug.assert(bytes.len < limit); // the ceiling is exclusive
        return bytes;
    }
};

// --- The path rules ---------------------------------------------------------

/// Canonicalise a document-written path into `out`, or refuse it.
///
/// | Path                                       | Verdict                     |
/// |--------------------------------------------|-----------------------------|
/// | `./lib/a.wgsl`, `lib/a.wgsl`, `x/../a.wgsl` | accept                      |
/// | `../a.wgsl`, `lib/../../a.wgsl`            | `InvalidPath` (climbs out)  |
/// | `/a.wgsl`, `C:\a.wgsl`, `\\host\a`         | `InvalidPath` (absolute)    |
/// | `` (empty), `a\0b`, `a\nb`, `lib/`         | `InvalidPath` (malformed)   |
///
/// The climb rule is what stops a document *spelling* its way out of the
/// directory it lives in. It is enforced by *counting*, not by string matching:
/// `..` pops the segment stack, and a pop against an empty stack is the climb.
/// `a/../../b` is therefore caught even though it never spells `../` at the
/// front.
///
/// It is half the containment story, not all of it: this function sees TEXT, and
/// a symlink is not in the text. `FilesystemResolver.readFn` finishes the job on
/// the one host where links exist.
///
/// A backslash anywhere is a reject rather than a separator. It makes
/// `C:\a.wgsl` and `\\host\share` fall out of the same rule as `/a.wgsl`, and a
/// `.sjon` document is portable text: its paths are written with `/`.
///
/// Complexity: O(path.len). No allocation; `out` must be `MAX_PATH` bytes.
pub fn normalise(path: []const u8, out: []u8) NormaliseError![]const u8 {
    std.debug.assert(out.len >= MAX_PATH);
    if (path.len == 0 or path.len > MAX_PATH) return error.InvalidPath;
    if (path[0] == '/') return error.InvalidPath;
    // A trailing separator names a directory, and every caller wants a file.
    // Interior `//` is still collapsed below — only the last byte decides.
    if (path[path.len - 1] == '/') return error.InvalidPath;
    for (path) |c| {
        // NUL and the line terminators would let a path smuggle a second value
        // past a host that splits on them; the backslash is the absolute-path
        // rule above. The schema's `file-path` kind rejects these too — this is
        // the second gate, because a resolver is also reachable from a lowering
        // hook one day, where no schema kind has run.
        if (c == 0 or c == '\n' or c == '\r' or c == '\\') return error.InvalidPath;
    }
    // A Windows drive letter (`C:...`) is absolute even with forward slashes.
    if (path.len >= 2 and path[1] == ':') return error.InvalidPath;

    var stack: [MAX_SEGMENTS][]const u8 = undefined;
    var depth: u32 = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    for (0..MAX_SEGMENTS + 1) |_| {
        const seg = it.next() orelse break;
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue; // `//`, `./`, trailing `/`
        if (std.mem.eql(u8, seg, "..")) {
            if (depth == 0) return error.InvalidPath; // the climb
            depth -= 1;
            continue;
        }
        if (depth == MAX_SEGMENTS) return error.InvalidPath;
        stack[depth] = seg;
        depth += 1;
    } else return error.InvalidPath; // more segments than the stack holds

    if (depth == 0) return error.InvalidPath; // `.`, `./`, `a/..` — names no file

    var len: usize = 0;
    for (stack[0..depth], 0..) |seg, i| {
        if (i > 0) {
            if (len + 1 > out.len) return error.InvalidPath;
            out[len] = '/';
            len += 1;
        }
        if (len + seg.len > out.len) return error.InvalidPath;
        @memcpy(out[len..][0..seg.len], seg);
        len += seg.len;
    }
    std.debug.assert(len > 0 and len <= out.len);
    return out[0..len];
}

// --- The filesystem implementation (the CLI) --------------------------------

/// Reads under `base_dir` through `io`. Freestanding-guarded exactly the way
/// the Emitter's own reader was: on wasm32 there is no filesystem, the branch
/// is comptime-known, and the whole IO path compiles out.
pub const FilesystemResolver = struct {
    base_dir: []const u8,
    io: std.Io,

    pub fn resolver(self: *FilesystemResolver) FileResolver {
        std.debug.assert(self.base_dir.len > 0);
        return .{ .ctx = @ptrCast(self), .readFn = readFn };
    }

    fn readFn(ctx: *anyopaque, gpa: Allocator, path: []const u8, limit: u32) ReadError![]u8 {
        const self: *FilesystemResolver = @ptrCast(@alignCast(ctx));
        std.debug.assert(path.len > 0); // FileResolver.read normalised it
        std.debug.assert(limit > 0);
        if (comptime builtin.os.tag == .freestanding) return error.ReadFailed;

        var join: [MAX_PATH * 2]u8 = undefined;
        const full = std.fmt.bufPrint(&join, "{s}/{s}", .{ self.base_dir, path }) catch
            return error.InvalidPath;
        try self.refuseSymlinkedComponent(full, self.base_dir.len);
        return std.Io.Dir.cwd().readFileAlloc(self.io, full, gpa, .limited(limit)) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileNotFound => error.NotFound,
            error.StreamTooLong => error.TooLarge,
            // Everything else — a permission bit, a directory named as a file,
            // a broken symlink chain, a device that went away — is one refusal
            // to an author: the host would not hand the bytes over.
            else => error.ReadFailed,
        };
    }

    /// Refuse `full` when any component below `base_len` is a symbolic link.
    ///
    /// `normalise` already refused every path that SPELLS an escape, but it
    /// reads text and a link is not text: with `lib -> /etc`, the document
    /// writes `./lib/passwd`, every lexical rule passes, and the read leaves the
    /// directory anyway. That is the hole the module header used to claim was
    /// closed (§438).
    ///
    /// Refuses a link that points INSIDE the directory too. "No links on the
    /// path" is a rule an author can check by looking; "no links that resolve
    /// out" needs the resolution, and doing it per component is where the
    /// classic time-of-check bugs live. A project that keeps its shaders behind
    /// a link can name the real directory.
    ///
    /// Bounded by `MAX_SEGMENTS`, no recursion. `base_dir` itself is the
    /// compiler's own argument, not the document's, so it is not walked.
    ///
    /// Complexity: O(segments) `readlink` calls, each O(path.len).
    fn refuseSymlinkedComponent(self: *const FilesystemResolver, full: []const u8, base_len: usize) ReadError!void {
        std.debug.assert(full.len > base_len); // pre: at least `base/` plus a name
        if (comptime builtin.os.tag == .freestanding) return;
        var link_buf: [MAX_PATH]u8 = undefined;
        var i = base_len;
        for (0..MAX_SEGMENTS + 1) |_| {
            if (i >= full.len) return;
            // Advance past the separator, then to the end of this component.
            i += 1;
            const start = i;
            while (i < full.len and full[i] != '/') i += 1;
            if (i == start) return; // a trailing separator; nothing left to check
            // A component that is not a link (`NotLink`), is missing, or cannot
            // be read is not THIS check's refusal — the read below reports what
            // is actually wrong with it. Only a successful readlink is a link.
            _ = std.Io.Dir.cwd().readLink(self.io, full[0..i], &link_buf) catch continue;
            return error.Symlink;
        }
        // More components than `normalise` admits. It ran first, so this is
        // unreachable; refuse rather than assert, the way every other bound a
        // document can reach is refused (pitfall 89).
        return error.InvalidPath;
    }
};

// --- The table implementation (the browser) ---------------------------------

/// Reads from bytes the host supplied before the compile. This is how the
/// in-browser compiler serves a `:file`: JavaScript packs a name→bytes table
/// into linear memory, `wasm_compiler.zig` parses it, and the emitter reads
/// through here without knowing the difference.
///
/// Stored names are normalised at lookup rather than at construction, so
/// `./lib/a.wgsl` written in a document and `lib/a.wgsl` handed in by
/// JavaScript meet. An entry whose own name cannot normalise (absolute, or
/// climbing) is skipped: no valid document path could ever match it.
pub const TableResolver = struct {
    /// One supplied file. Both slices are borrowed and must outlive the compile.
    pub const Entry = struct {
        name: []const u8,
        bytes: []const u8,
    };

    /// The table bound, and the same number `wanted_files` uses in the emitter's
    /// pre-pass, so "how many files may a document name" has one answer.
    pub const MAX_ENTRIES: u32 = 256;

    entries: []const Entry,

    pub fn resolver(self: *TableResolver) FileResolver {
        std.debug.assert(self.entries.len <= MAX_ENTRIES);
        return .{ .ctx = @ptrCast(self), .readFn = readFn };
    }

    fn readFn(ctx: *anyopaque, gpa: Allocator, path: []const u8, limit: u32) ReadError![]u8 {
        const self: *TableResolver = @ptrCast(@alignCast(ctx));
        std.debug.assert(path.len > 0); // FileResolver.read normalised it
        std.debug.assert(self.entries.len <= MAX_ENTRIES);

        var buf: [MAX_PATH]u8 = undefined;
        for (self.entries[0..@min(self.entries.len, MAX_ENTRIES)]) |e| {
            const clean = normalise(e.name, &buf) catch continue;
            if (!std.mem.eql(u8, clean, path)) continue;
            if (e.bytes.len >= limit) return error.TooLarge;
            return gpa.dupe(u8, e.bytes) catch error.OutOfMemory;
        }
        return error.NotFound;
    }
};

// ============================================================================
// Tests
// ============================================================================

fn expectNormalises(path: []const u8, want: []const u8) !void {
    var buf: [MAX_PATH]u8 = undefined;
    try std.testing.expectEqualStrings(want, try normalise(path, &buf));
}

fn expectInvalid(path: []const u8) !void {
    var buf: [MAX_PATH]u8 = undefined;
    try std.testing.expectError(error.InvalidPath, normalise(path, &buf));
}

// --- The `needs` list -------------------------------------------------------

/// Every file a document names that the host could not supply, complete after
/// ONE compile.
///
/// It exists because the emitter walk stops at the first unreadable file: the
/// refusal is `error.EmitError` and the walk ends there. A browser host, which
/// must be told what to fetch before it can compile at all, would otherwise
/// learn about one file per round — `cubemap.sjon` names six images and would
/// take six compiles. A pre-pass over the validated forest fills this instead,
/// and one round is enough permanently, because every path a document can name
/// is written in the document.
///
/// Caller-owned and allocation-free, deliberately: it is written during a
/// compile that is already failing, is read after the Emitter is gone, and on
/// the browser path lives in bss beside the other static buffers. The shape
/// follows `Diag` — bounded, with a `dropped` count, so "the list is complete"
/// is a question the reader can answer rather than assume.
pub const Needs = struct {
    /// Matches `TableResolver.MAX_ENTRIES`: what a host can supply is what a
    /// document can be missing.
    pub const MAX_ENTRIES: u32 = TableResolver.MAX_ENTRIES;
    /// Path storage. 256 entries at an average 32 bytes; a document that
    /// overruns it sets `dropped` rather than truncating a path in half.
    pub const BYTES: u32 = 8 * 1024;

    buf: [BYTES]u8 = undefined,
    /// End offset in `buf` of each path; entry `i` is `buf[start(i)..ends[i]]`.
    ends: [MAX_ENTRIES]u32 = undefined,
    errs: [MAX_ENTRIES]ReadError = undefined,
    count: u32 = 0,
    used: u32 = 0,
    /// Entries that did not fit, by count or by bytes. NON-ZERO MEANS THE LIST
    /// IS A PREFIX: a reader that ignores this cannot tell "nothing else is
    /// missing" from "the buffer filled up".
    dropped: u32 = 0,

    pub fn add(self: *Needs, p: []const u8, err: ReadError) void {
        std.debug.assert(p.len > 0);
        std.debug.assert(self.count <= MAX_ENTRIES);
        if (self.count == MAX_ENTRIES or self.used + p.len > BYTES) {
            self.dropped += 1;
            return;
        }
        @memcpy(self.buf[self.used..][0..p.len], p);
        self.used += @intCast(p.len);
        self.ends[self.count] = self.used;
        self.errs[self.count] = err;
        self.count += 1;
    }

    pub fn pathAt(self: *const Needs, i: u32) []const u8 {
        std.debug.assert(i < self.count);
        const start = if (i == 0) 0 else self.ends[i - 1];
        std.debug.assert(self.ends[i] > start);
        return self.buf[start..self.ends[i]];
    }

    pub fn errorAt(self: *const Needs, i: u32) ReadError {
        std.debug.assert(i < self.count);
        return self.errs[i];
    }
};
