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
//! - data_gen: Data generation (typed arrays, fill operations)
//! - pool: Ping-pong buffer pool operations
//! - wasm_ops: Nested WASM module operations
//!
//! ## Usage
//!
//! ```zig
//! const handlers = @import("dispatcher/handlers.zig");
//! if (try handlers.resource.handle(Self, self, op, allocator)) return;
//! if (try handlers.pass.handle(Self, self, op, allocator)) return;
//! // ... etc
//! ```

pub const resource = @import("resource.zig");
pub const pass = @import("pass.zig");
pub const queue = @import("queue.zig");
pub const frame = @import("frame.zig");
pub const data_gen = @import("data_gen.zig");
pub const pool = @import("pool.zig");
pub const wasm_ops = @import("wasm_ops.zig");
pub const scanner = @import("scanner.zig");

// Re-export scanner types for convenience
pub const OpcodeScanner = scanner.OpcodeScanner;
pub const PassRange = scanner.PassRange;
