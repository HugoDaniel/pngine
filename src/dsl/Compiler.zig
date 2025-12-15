//! DSL Compiler - High-level interface
//!
//! Compiles PNGine DSL source to PNGB bytecode.
//! This is the main entry point for DSL compilation.
//!
//! ## Pipeline
//!
//! ```
//! Source (.pngine.wgsl)
//!   ├── Lexer: tokenize into token stream
//!   ├── Parser: build AST from tokens
//!   ├── Analyzer: semantic analysis, symbol resolution
//!   └── Emitter: generate PNGB bytecode
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const pngb = try Compiler.compile(allocator, source);
//! defer allocator.free(pngb);
//! ```
//!
//! ## Invariants
//!
//! - Input must be sentinel-terminated for `compile()`
//! - `compileSlice()` handles non-sentinel input by copying
//! - Analysis errors prevent emission (returns error.AnalysisError)
//! - Output is always valid PNGB when successful
//! - All intermediate allocations are cleaned up on error
//!
//! ## Error Handling
//!
//! - `ParseError`: Syntax error in DSL source
//! - `AnalysisError`: Semantic error (undefined ref, cycle, duplicate)
//! - `EmitError`: Bytecode generation failed
//! - `OutOfMemory`: Allocation failure

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig").Parser;
const Analyzer = @import("Analyzer.zig").Analyzer;
const Emitter = @import("Emitter.zig").Emitter;
const Ast = @import("Ast.zig").Ast;

pub const Compiler = struct {
    const Self = @This();

    pub const Error = error{
        OutOfMemory,
        ParseError,
        AnalysisError,
        EmitError,
        DataSectionOverflow,
        TooManyDataEntries,
        StringTableOverflow,
    };

    pub const CompileResult = struct {
        pngb: []u8,
        warnings: []const Warning,

        pub fn deinit(self: *CompileResult, gpa: Allocator) void {
            gpa.free(self.pngb);
            gpa.free(self.warnings);
            self.* = undefined;
        }
    };

    pub const Warning = struct {
        line: u32,
        column: u32,
        message: []const u8,
    };

    /// Compile DSL source to PNGB bytecode.
    ///
    /// Returns owned PNGB bytes that the caller must free.
    pub fn compile(gpa: Allocator, source: [:0]const u8) Error![]u8 {
        // Pre-condition
        std.debug.assert(source.len == 0 or source[source.len] == 0);

        // Phase 1: Parse
        var ast = Parser.parse(gpa, source) catch |err| {
            return switch (err) {
                error.ParseError => error.ParseError,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        defer ast.deinit(gpa);

        // Phase 2: Analyze
        var analysis = Analyzer.analyze(gpa, &ast) catch |err| {
            return switch (err) {
                error.AnalysisError => error.AnalysisError,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        defer analysis.deinit(gpa);

        if (analysis.hasErrors()) {
            return error.AnalysisError;
        }

        // Phase 3: Emit PNGB
        return Emitter.emit(gpa, &ast, &analysis);
    }

    /// Compile DSL source from a non-sentinel-terminated slice.
    /// Makes a copy with sentinel terminator.
    pub fn compileSlice(gpa: Allocator, source: []const u8) Error![]u8 {
        const source_z = gpa.allocSentinel(u8, source.len, 0) catch return error.OutOfMemory;
        defer gpa.free(source_z);
        @memcpy(source_z, source);
        return compile(gpa, source_z);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Compiler: simple shader to PNGB" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {}" }
        \\#frame main { perform=[] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    // Verify PNGB header
    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "Compiler: full pipeline" {
    const source: [:0]const u8 =
        \\#wgsl shader { value="@vertex fn vs() {} @fragment fn fs() {}" }
        \\#renderPipeline pipe { vertex={ module=$wgsl.shader } }
        \\#renderPass pass { pipeline=$renderPipeline.pipe draw=3 }
        \\#frame main { perform=[$renderPass.pass] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 16); // More than just header
}

test "Compiler: error on undefined reference" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=$wgsl.missing } }
        \\#frame main { perform=[] }
    ;

    const result = Compiler.compile(testing.allocator, source);
    try testing.expectError(error.AnalysisError, result);
}

test "Compiler: compileSlice" {
    const source = "#frame main { perform=[] }";

    const pngb = try Compiler.compileSlice(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "Compiler: empty input" {
    const source: [:0]const u8 = "#frame main { perform=[] }";

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

test "Compiler: compute shader" {
    const source: [:0]const u8 =
        \\#wgsl compute { value="@compute fn main() {}" }
        \\#computePipeline pipe { compute={ module=$wgsl.compute } }
        \\#computePass pass { pipeline=$computePipeline.pipe dispatch=[8 8 1] }
        \\#frame main { perform=[$computePass.pass] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}
