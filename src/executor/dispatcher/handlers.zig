//! Dispatcher Handler Modules
//!
//! Re-exports all opcode handler modules for use by the main dispatcher.
//!
//! ## Handler Categories
//!
//! - resource: GPU resource creation (buffers, textures, pipelines)
//! - pass: Render and compute pass operations (draw, dispatch)
//! - queue: GPU queue operations (write_buffer, submit)
//! - frame: Frame control and pass definitions
//! - pool: Ping-pong buffer pool operations
//! - wasm_ops: Nested WASM module operations
//!
//! Which module owns which opcode is NOT restated in each module: it is one
//! table, `opcode_class.zig`'s `classOf`, re-exported here. The six
//! `is_*_opcode` predicates that used to answer it were a second copy of each
//! handler's own switch (r3-02).
//!
//! ## Usage
//!
//! ```zig
//! const handlers = @import("dispatcher/handlers.zig");
//! const class = handlers.opcode_class.classOf(op) orelse return error.InvalidOpcode;
//! const handled = switch (class) {
//!     .resource => try handlers.resource.handle(Self, self, op, gpa),
//!     // ... one arm per Class
//! };
//! // `false` means the handler's switch disagrees with `classOf` — refuse,
//! // never discard: a discarded `false` desyncs the operand stream.
//! if (!handled) return error.InvalidOpcode;
//! ```

pub const resource = @import("resource.zig");
pub const pass = @import("pass.zig");
pub const queue = @import("queue.zig");
pub const frame = @import("frame.zig");
pub const pool = @import("pool.zig");
pub const wasm_ops = @import("wasm_ops.zig");
pub const scanner = @import("scanner.zig");
pub const opcode_class = @import("opcode_class.zig");

// Re-export scanner types for convenience
pub const OpcodeScanner = scanner.OpcodeScanner;
pub const PassRange = scanner.PassRange;

/// Which handler owns an opcode — the single source of truth the router asks.
pub const Class = opcode_class.Class;
