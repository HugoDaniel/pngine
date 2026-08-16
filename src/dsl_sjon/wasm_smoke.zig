//! wasm32-freestanding cross-compile gate for the SJON dependency.
//!
//! `zig build test-sjon-wasm` builds this as a relocatable object for
//! wasm32-freestanding with `link_libc = false`, proving SJON's host surface
//! cross-compiles with no libwasmtime and no libc — the load-bearing assumption
//! behind embedding the SJON compiler in the browser (Phase 3) and the
//! `plugin-exec = false` dependency wiring.
//!
//! Keep the import list at exactly `sjon`: pulling in reflect/executor here
//! would muddy the "does SJON cross-compile?" signal. The real
//! `wasm_compiler` integration is Phase 3.

const sjon = @import("sjon");

/// OR the addresses of the host entry points so the optimizer can't drop them.
/// Taking each `&fn` forces full semantic analysis + codegen for
/// wasm32-freestanding — `validateDocument` transitively pulls in the host,
/// manifest loader, validator, default-materializer, and lowering runtime.
export fn pngine_sjon_wasm_smoke() usize {
    return @intFromPtr(&sjon.parse) |
        @intFromPtr(&sjon.validate) |
        @intFromPtr(&sjon.validateDocument) |
        @intFromPtr(&sjon.evalExpr);
}
