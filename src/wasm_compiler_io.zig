//! Allocator-generic ownership for the browser compiler's dynamic source and
//! latest output.
//!
//! `src/wasm_compiler.zig` is compiled for `wasm32-freestanding`, where
//! `std.heap.wasm_allocator` is a `BrkAllocator` and a leak is permanent for
//! the tab. This file is the one place that owns the allocating source buffer
//! and the adopted result, written against `std.mem.Allocator` so
//! `tests/zig/wasm_compiler_io.zig` can drive the SAME code under
//! `std.testing.allocator` (leaks and double frees fail) and
//! `FailingAllocator` (every failure path is exercised).
//!
//! ## Storage rules (memcap ruling R3)
//!
//! - Allocate exactly `len + 1` bytes: `len` writable source bytes plus the
//!   zero sentinel the SJON parser requires.
//! - `len == 0` is legal and is a real one-byte allocation. Unlike
//!   `allocFileTable`, zero here is data, not "no buffer".
//! - Never `resize`/`remap` a source buffer. Exact allocation, whole-slice
//!   free. That is the whole contract, so it cannot cross the `BrkAllocator`
//!   small/big size-class boundary `WasmHeapGuard` exists to refuse.
//! - The owner stores the original `[:0]u8`; `Allocator.free` absorbs the
//!   sentinel and releases the full `len + 1` bytes.
//!
//! ## Lifetime
//!
//! A successful `allocSource` replaces (and frees) any previous dynamic
//! source. A refused allocation frees it too and leaves no active source, so a
//! later valid call starts clean. The WASM entry points select legacy vs
//! dynamic; this helper only owns the dynamic allocation.
//!
//! The latest output (ruling R4) is readable until the next `compile`,
//! `compileToPng`, or `minifyWgsl` entry — each clears it before doing anything
//! else — or until the host destroys the WASM instance. There is no teardown
//! export; final reclamation belongs to instance destruction.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The compiler I/O policy ceiling. Source is checked against it now; output
/// adopts the same constant in the later output slices.
pub const COMPILER_IO_MAX: u32 = 16 * 1024 * 1024;

pub const IoOwner = struct {
    gpa: Allocator,
    /// The active dynamic source, sentinel-terminated. `null` means the host
    /// has not allocated one, or the last attempt replaced it with nothing.
    source_buf: ?[:0]u8 = null,
    /// The latest adopted result (memcap 01.4). Owned whole-slice; `null`
    /// means no output is held.
    output_buf: ?[]u8 = null,
    /// Exact text the WASM export copies into `error_buffer` on failure.
    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,

    pub fn init(gpa: Allocator) IoOwner {
        return .{ .gpa = gpa };
    }

    /// Allocate a writable, sentinel-terminated source of `len` bytes.
    ///
    /// Returns `error.SourceTooLarge` before touching the allocator when `len`
    /// exceeds `COMPILER_IO_MAX`. Any failure (limit or OOM) releases a
    /// previously active source and leaves the owner empty; success does the
    /// same to the old source, then installs the new allocation.
    pub fn allocSource(self: *IoOwner, len: u32) error{ OutOfMemory, SourceTooLarge }![*]u8 {
        if (len > COMPILER_IO_MAX) {
            self.releaseSource();
            self.setError("compiler-source-limit: source is {d} bytes; limit is {d} bytes", .{
                len,
                COMPILER_IO_MAX,
            });
            return error.SourceTooLarge;
        }

        // Release before allocating: a replacement is exact-size, never a
        // transient double lifetime, and a failure cannot leave the old source
        // active behind a null return.
        self.releaseSource();
        const buf = self.gpa.allocSentinel(u8, @as(usize, len), 0) catch {
            self.setError("compiler-source-oom: could not allocate {d} bytes for {d} source bytes plus sentinel", .{
                len + 1,
                len,
            });
            return error.OutOfMemory;
        };
        self.source_buf = buf;
        self.last_error_len = 0;
        return buf.ptr;
    }

    /// The active dynamic source, or null when none is allocated.
    pub fn source(self: *const IoOwner) ?[:0]const u8 {
        return if (self.source_buf) |buf| buf else null;
    }

    /// Free the active dynamic source, if any. Idempotent: a second call is a
    /// no-op, not a second free.
    pub fn releaseSource(self: *IoOwner) void {
        if (self.source_buf) |buf| self.gpa.free(buf);
        self.source_buf = null;
    }

    // --- Adopted output (memcap 01.4) ---

    /// Free the latest adopted result, if any. Idempotent: a second call is a
    /// no-op, not a second free. Every compile/minify export calls this at
    /// entry, which is the whole invalidation boundary (ruling R4).
    pub fn clearOutput(self: *IoOwner) void {
        if (self.output_buf) |buf| self.gpa.free(buf);
        self.output_buf = null;
    }

    /// Take ownership of `candidate` as the latest result. Allocates nothing —
    /// the caller already owns the buffer — so there is no OOM path. A previous
    /// output is freed whole-slice.
    ///
    /// `COMPILER_IO_MAX` bounds the adoptable size. A candidate past it is
    /// freed here (the caller hands over ownership unconditionally and must
    /// disarm its local free exactly once), and the exact policy text is left
    /// in `errorText()`. Returns false on that refusal.
    pub fn adoptOutput(self: *IoOwner, candidate: []u8) bool {
        if (candidate.len > COMPILER_IO_MAX) {
            self.gpa.free(candidate);
            self.setError("compiler-output-limit: PNGB output is {d} bytes; limit is {d} bytes", .{
                candidate.len,
                COMPILER_IO_MAX,
            });
            return false;
        }
        self.clearOutput();
        self.output_buf = candidate;
        self.last_error_len = 0;
        return true;
    }

    /// The latest adopted result, empty when none is held. The slice stays
    /// readable until the next `clearOutput`/`adoptOutput` (the exports call
    /// `clearOutput` at entry) or until the WASM instance is destroyed; there
    /// is no teardown export.
    pub fn output(self: *const IoOwner) []const u8 {
        return if (self.output_buf) |buf| buf else &.{};
    }

    /// The failure text from the last `allocSource`/`adoptOutput`, empty after
    /// a success.
    pub fn errorText(self: *const IoOwner) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    fn setError(self: *IoOwner, comptime fmt: []const u8, args: anytype) void {
        // No allocation here: this runs on the OOM path. 128 bytes covers the
        // longest message with both 8-digit decimal substitutions.
        const text = std.fmt.bufPrint(&self.last_error, fmt, args) catch {
            self.last_error_len = 0;
            return;
        };
        self.last_error_len = text.len;
    }
};
