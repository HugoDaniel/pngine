//! The two writers over the captured MockGPU call log, plus the split rules they
//! share — exposed as one module so a single test root can reach all three.
//!
//! It exists because of a Zig rule, not a design one: a source file may belong
//! to exactly one module, and `flat.zig` and `js_codegen.zig` both relatively
//! import `call_split.zig`. Rooting each of them as its own module in the same
//! test compilation therefore claims that file twice and fails to build. Inside
//! the CLI exe the question never arises — everything under `src/cli/` is
//! reached by relative import from `src/cli.zig`, i.e. one module already.
//!
//! Nothing in the shipping binary imports this file; `src/cli.zig` reaches the
//! writers directly, as before.

pub const flat = @import("flat.zig");
pub const js_codegen = @import("js_codegen.zig");
pub const call_split = @import("call_split.zig");
