//! A `CAMetalLayer` with no window behind it — the surface path's test fixture.
//!
//! The windowed half of the native backend (`surface != null`) is unreachable
//! from every gate the repo has: `--frame` is headless, and a test binary has
//! no NSApp, no run loop and no window server session it can rely on. That is
//! why the surface leaked for as long as it did — not because the code was
//! subtle, but because nothing ever executed it.
//!
//! A bare `CAMetalLayer` closes that: it vends drawables as soon as it has a
//! device and a drawable size, both of which `wgpuSurfaceConfigure` sets, so a
//! plain `zig test` process can run the whole acquire/present cycle. It is
//! deliberately NOT `+layer` — that returns an autoreleased object and this
//! process has no pool to drain it.
//!
//! Test-only by convention, not by `builtin.is_test`: nothing on a runtime path
//! references it, so it is never analyzed into a shipping binary. Living in the
//! lib module (rather than beside one of the test roots) is what lets both
//! `native_api.zig`'s inline tests and `tests/zig/render/` use the same shim —
//! a file cannot belong to two modules, and a second copy of an `objc_msgSend`
//! signature is exactly the kind of thing that rots apart.

const std = @import("std");

const objc = struct {
    extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
    extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
    extern fn objc_msgSend() void;

    /// `objc_msgSend` is variadic in C and must be called through a
    /// correctly-typed pointer on arm64 — the ABI picks argument registers from
    /// the *static* signature, so calling it untyped is UB.
    const Send0 = *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque;

    fn send0(receiver: ?*anyopaque, sel: [*:0]const u8) ?*anyopaque {
        const f: Send0 = @ptrCast(&objc_msgSend);
        return f(receiver, sel_registerName(sel));
    }
};

/// `[[CAMetalLayer alloc] init]`, or null off Apple platforms / without a
/// runtime that has the class. Callers treat null as `error.SkipZigTest`.
pub fn create() ?*anyopaque {
    if (@import("builtin").target.os.tag != .macos and
        @import("builtin").target.os.tag != .ios) return null;
    const cls = objc.objc_getClass("CAMetalLayer") orelse return null;
    const alloced = objc.send0(cls, "alloc") orelse return null;
    return objc.send0(alloced, "init");
}

pub fn release(layer: *anyopaque) void {
    _ = objc.send0(layer, "release");
}
