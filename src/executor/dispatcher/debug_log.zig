//! Debug-log shim — the single WASM↔JS import the dispatcher itself needs.
//!
//! `gpuDebugLog` is an `extern "env"` symbol the browser host resolves (it is
//! *not* part of the frozen command-buffer ABI; see docs/abi.md). The
//! dispatcher's frame/pass handlers call it only inside
//! `if (@import("builtin").target.cpu.arch == .wasm32)` guards, so on native
//! builds the reference is comptime-pruned and never linked.
//!
//! This declaration used to live in the (now-deleted) WasmGPU backend; it is
//! extracted here so the dispatcher pulls in ~10 lines instead of a 550-line
//! legacy module just to emit a debug trace.

/// Emit a (type, value) debug pair over the JS host's console channel.
pub extern "env" fn gpuDebugLog(msg_type: u8, value: u32) void;
