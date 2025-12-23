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
const ImportResolver = @import("ImportResolver.zig").ImportResolver;

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
        FileReadError,
        ImportCycle,
        ImportNotFound,
        InvalidImportPath,
    };

    /// Options for compilation.
    pub const Options = struct {
        /// Base directory for resolving relative file paths (e.g., asset URLs, imports).
        /// If null, file embedding is disabled and blob={file={...}} will be ignored.
        /// Also used for resolving #import directives.
        base_dir: ?[]const u8 = null,

        /// File path of the source file (for import path resolution).
        /// Required when using #import directives.
        file_path: ?[]const u8 = null,

        /// Whether to resolve #import directives.
        /// Defaults to true when base_dir is set.
        resolve_imports: bool = true,

        /// Path to miniray binary for WGSL reflection.
        /// If null, "miniray" is looked up in PATH.
        /// Required for setUniform() API to work with custom uniforms.
        miniray_path: ?[]const u8 = null,
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
        return compileWithOptions(gpa, source, .{});
    }

    /// Compile DSL source to PNGB bytecode with options.
    ///
    /// Returns owned PNGB bytes that the caller must free.
    pub fn compileWithOptions(gpa: Allocator, source: [:0]const u8, options: Options) Error![]u8 {
        // Pre-condition
        std.debug.assert(source.len == 0 or source[source.len] == 0);

        // Phase 0: Resolve imports (if enabled and base_dir is set)
        var resolved_source: ?[:0]u8 = null;
        defer if (resolved_source) |s| gpa.free(s);

        const actual_source = if (options.resolve_imports and options.base_dir != null) blk: {
            var resolver = ImportResolver.init(gpa, options.base_dir.?);
            defer resolver.deinit();

            const file_path = options.file_path orelse "main.pngine";
            resolved_source = resolver.resolve(source, file_path) catch |err| {
                return switch (err) {
                    error.ImportCycle => error.ImportCycle,
                    error.ImportNotFound => error.ImportNotFound,
                    error.InvalidImportPath => error.InvalidImportPath,
                    error.OutOfMemory => error.OutOfMemory,
                    error.FileReadError => error.FileReadError,
                };
            };
            break :blk resolved_source.?;
        } else source;

        // Phase 1: Parse
        var ast = Parser.parse(gpa, actual_source) catch |err| {
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
            // Debug: print analysis errors
            std.debug.print("\nAnalysis errors ({d}):\n", .{analysis.errors.len});
            for (analysis.errors) |err| {
                std.debug.print("  - [{s}] {s}\n", .{ @tagName(err.kind), err.message });
            }
            return error.AnalysisError;
        }

        // Phase 3: Emit PNGB
        const pngb = try Emitter.emitWithOptions(gpa, &ast, &analysis, .{
            .base_dir = options.base_dir,
            .miniray_path = options.miniray_path,
        });

        // Post-condition: valid PNGB header
        std.debug.assert(pngb.len >= 4);
        std.debug.assert(std.mem.eql(u8, pngb[0..4], "PNGB"));

        return pngb;
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
        \\#renderPipeline pipe { vertex={ module=shader } }
        \\#renderPass pass { pipeline=pipe draw=3 }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expect(pngb.len > 16); // More than just header
}

test "Compiler: error on undefined reference" {
    const source: [:0]const u8 =
        \\#renderPipeline pipe { vertex={ module=missing } }
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
        \\#computePipeline pipe { compute={ module=compute } }
        \\#computePass pass { pipeline=pipe dispatch=[8 8 1] }
        \\#frame main { perform=[pass] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);
}

// ============================================================================
// E2E Tests for Example Files
// ============================================================================

test "E2E: parse simple_triangle.pngine" {
    // Test parsing the simple triangle example
    const source: [:0]const u8 =
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vertexMain module=code }
        \\  fragment={
        \\    entryPoint=fragMain
        \\    module=code
        \\    targets=[{ format=preferredCanvasFormat }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\}
        \\
        \\#renderPass renderPipeline {
        \\  colorAttachments=[{
        \\    view=contextCurrentTexture
        \\    clearValue=[0, 0, 0, 0]
        \\    loadOp=clear
        \\    storeOp=store
        \\  }]
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#frame simpleTriangle {
        \\  perform=[renderPipeline]
        \\}
        \\
        \\#shaderModule code {
        \\  code="@vertex fn vertexMain() {}"
        \\}
    ;

    // Parse
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Analyze (verify bare name resolution works)
    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have no errors (bare names resolve correctly)
    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify bare name resolution for module=code
    try testing.expect(analysis.resolved_identifiers.count() > 0);
}

test "E2E: parse simple_triangle_msaa.pngine" {
    // Test MSAA example with #define and #texture
    const source: [:0]const u8 =
        \\#define SAMPLE_COUNT=4
        \\
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entrypoint=vertexMain module=code }
        \\  fragment={
        \\    entrypoint=fragMain
        \\    module=code
        \\    targets=[{ format=preferredCanvasFormat }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\  multisample=SAMPLE_COUNT
        \\}
        \\
        \\#texture tex {
        \\  size=[canvas.width canvas.height]
        \\  sampleCount=SAMPLE_COUNT
        \\  format=preferredCanvasFormat
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\
        \\#renderPass renderIt {
        \\  colorAttachments=[{
        \\    view=tex
        \\    resolveTarget=contextCurrentTexture
        \\    clearValue=[0, 0, 0, 0]
        \\    loadOp=clear
        \\    storeOp=discard
        \\  }]
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#frame msaaTriangle {
        \\  perform=[renderIt]
        \\}
        \\
        \\#shaderModule code {
        \\  code="@vertex fn vertexMain() {}"
        \\}
    ;

    // Parse
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Analyze
    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have no errors
    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify we have a #define node
    try testing.expect(analysis.symbols.define.count() > 0);

    // Verify we have a texture
    try testing.expect(analysis.symbols.texture.count() > 0);

    // Verify builtin refs were detected (canvas.width/height)
    var has_builtin_ref = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .builtin_ref) {
            has_builtin_ref = true;
            break;
        }
    }
    try testing.expect(has_builtin_ref);
}

test "E2E: parse moving_triangle.pngine" {
    // Test animated example with uniforms, #buffer, #queue, #bindGroup
    const source: [:0]const u8 =
        \\#define SAMPLE_COUNT=4
        \\
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entrypoint=vertexMain module=code }
        \\  fragment={
        \\    entrypoint=fragMain
        \\    module=code
        \\    targets=[{ format=preferredCanvasFormat }]
        \\  }
        \\  primitive={ topology=triangle-list }
        \\  multisample=SAMPLE_COUNT
        \\}
        \\
        \\#texture tex {
        \\  size=[canvas.width canvas.height]
        \\  sampleCount=SAMPLE_COUNT
        \\  format=preferredCanvasFormat
        \\  usage=[RENDER_ATTACHMENT]
        \\}
        \\
        \\#renderPass drawTriangle {
        \\  colorAttachments=[{
        \\    view=tex
        \\    resolveTarget=contextCurrentTexture
        \\    clearValue=[0 0 0 0]
        \\    loadOp=clear
        \\    storeOp=discard
        \\  }]
        \\  pipeline=pipeline
        \\  bindGroups=[inputsBinding]
        \\  draw=3
        \\}
        \\
        \\#frame msaaTriangle {
        \\  perform=[
        \\    writeInputUniforms
        \\    drawTriangle
        \\  ]
        \\}
        \\
        \\#buffer uniformInputsBuffer {
        \\  size=4
        \\  usage=[UNIFORM COPY_DST]
        \\}
        \\
        \\#queue writeInputUniforms {
        \\  writeBuffer={
        \\    buffer=uniformInputsBuffer
        \\    bufferOffset=0
        \\    data=code.inputs
        \\  }
        \\}
        \\
        \\#bindGroup inputsBinding {
        \\  layout={ pipeline=pipeline index=0 }
        \\  entries=[
        \\    { binding=0 resource={ buffer=uniformInputsBuffer }}
        \\  ]
        \\}
        \\
        \\#shaderModule code {
        \\  code="@vertex fn vertexMain() {}"
        \\}
    ;

    // Parse
    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Analyze
    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    // Should have no errors
    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify all resource types are present
    try testing.expect(analysis.symbols.buffer.count() > 0);
    try testing.expect(analysis.symbols.bind_group.count() > 0);
    try testing.expect(analysis.symbols.texture.count() > 0);
    try testing.expect(analysis.symbols.render_pipeline.count() > 0);
    try testing.expect(analysis.symbols.render_pass.count() > 0);
    try testing.expect(analysis.symbols.frame.count() > 0);

    // Verify bare name resolution for buffer=uniformInputsBuffer
    try testing.expect(analysis.resolved_identifiers.count() > 0);

    // Verify uniform_access node for data=code.inputs
    var has_uniform_access = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .uniform_access) {
            has_uniform_access = true;
            break;
        }
    }
    try testing.expect(has_uniform_access);
}

test "E2E: space-separated arrays parse correctly" {
    // Test that space-separated arrays work (e.g., [0 0 0 0])
    const source: [:0]const u8 =
        \\#renderPass pass {
        \\  colorAttachments=[{
        \\    clearValue=[0 0 0 1]
        \\    loadOp=clear
        \\  }]
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Find the inner array (clearValue)
    var found_array = false;
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .array) {
            const data = ast.nodes.items(.data)[i];
            const elements = ast.extraData(data.extra_range);
            // The clearValue array should have 4 elements
            if (elements.len == 4) {
                found_array = true;
                break;
            }
        }
    }
    try testing.expect(found_array);
}

test "E2E: comma-separated arrays parse correctly" {
    // Test that comma-separated arrays also work (e.g., [0, 0, 0, 0])
    const source: [:0]const u8 =
        \\#renderPass pass {
        \\  colorAttachments=[{
        \\    clearValue=[0, 0, 0, 1]
        \\    loadOp=clear
        \\  }]
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    // Find the inner array (clearValue)
    var found_array = false;
    for (ast.nodes.items(.tag), 0..) |tag, i| {
        if (tag == .array) {
            const data = ast.nodes.items(.data)[i];
            const elements = ast.extraData(data.extra_range);
            // The clearValue array should have 4 elements
            if (elements.len == 4) {
                found_array = true;
                break;
            }
        }
    }
    try testing.expect(found_array);
}

// ============================================================================
// Deep Nesting Tests (from old preprocessor tests)
// ============================================================================

test "E2E: vertex buffers with attributes (deep nesting)" {
    // Test complex nested structure: buffers -> attributes
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe {
        \\  vertex={
        \\    module=code
        \\    buffers=[{
        \\      arrayStride=100
        \\      stepMode=vertex
        \\      attributes=[{
        \\        format=float32x4
        \\        offset=0
        \\        shaderLocation=0
        \\      }]
        \\    }]
        \\  }
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify deep nesting was parsed (multiple array levels)
    var array_count: usize = 0;
    var object_count: usize = 0;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .array) array_count += 1;
        if (tag == .object) object_count += 1;
    }
    // Should have: buffers array, attributes array
    try testing.expect(array_count >= 2);
    // Should have: vertex object, buffer object, attribute object
    try testing.expect(object_count >= 3);
}

test "E2E: fragment blend state (complex object)" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe {
        \\  vertex={ module=code }
        \\  fragment={
        \\    module=code
        \\    targets=[{
        \\      format=bgra8unorm
        \\      blend={
        \\        color={
        \\          operation=add
        \\          srcFactor=src-alpha
        \\          dstFactor=one-minus-src-alpha
        \\        }
        \\        alpha={
        \\          operation=add
        \\          srcFactor=one
        \\          dstFactor=zero
        \\        }
        \\      }
        \\    }]
        \\  }
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);
}

test "E2E: depth stencil state (deep object)" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe {
        \\  vertex={ module=code }
        \\  depthStencil={
        \\    format=depth24plus
        \\    depthWriteEnabled=true
        \\    depthCompare=less
        \\    stencilFront={
        \\      compare=always
        \\      failOp=keep
        \\      depthFailOp=keep
        \\      passOp=keep
        \\    }
        \\    stencilBack={
        \\      compare=always
        \\      failOp=keep
        \\      depthFailOp=keep
        \\      passOp=keep
        \\    }
        \\  }
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify boolean was parsed
    var has_boolean = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .boolean_value) {
            has_boolean = true;
            break;
        }
    }
    try testing.expect(has_boolean);
}

test "E2E: multisample with hex mask" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe {
        \\  vertex={ module=code }
        \\  multisample={
        \\    count=4
        \\    mask=0xFFFFFFFF
        \\    alphaToCoverageEnabled=false
        \\  }
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Verify hex number and boolean were parsed
    var has_number = false;
    var has_boolean = false;
    for (ast.nodes.items(.tag)) |tag| {
        if (tag == .number_value) has_number = true;
        if (tag == .boolean_value) has_boolean = true;
    }
    try testing.expect(has_number);
    try testing.expect(has_boolean);
}

test "E2E: primitive state with all options" {
    const source: [:0]const u8 =
        \\#shaderModule code { code="" }
        \\#renderPipeline pipe {
        \\  vertex={ module=code }
        \\  primitive={
        \\    topology=triangle-strip
        \\    stripIndexFormat=uint16
        \\    frontFace=cw
        \\    cullMode=back
        \\    unclippedDepth=false
        \\  }
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);
}

test "E2E: bind group layout with multiple entry types" {
    const source: [:0]const u8 =
        \\#bindGroupLayout layout {
        \\  entries=[
        \\    { binding=0 visibility=[VERTEX FRAGMENT] buffer={ type=uniform } }
        \\    { binding=1 visibility=[FRAGMENT] sampler={ type=filtering } }
        \\    { binding=2 visibility=[FRAGMENT] texture={ sampleType=float } }
        \\  ]
        \\}
    ;

    var ast = try Parser.parse(testing.allocator, source);
    defer ast.deinit(testing.allocator);

    var analysis = try Analyzer.analyze(testing.allocator, &ast);
    defer analysis.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), analysis.errors.len);

    // Should have 3 entry objects in the array
    var entry_count: usize = 0;
    const tags = ast.nodes.items(.tag);
    const data = ast.nodes.items(.data);
    for (tags, 0..) |tag, i| {
        if (tag == .array) {
            const elements = ast.extraData(data[i].extra_range);
            // Find entries array (has 3 elements)
            if (elements.len == 3) {
                entry_count = elements.len;
                break;
            }
        }
    }
    try testing.expectEqual(@as(usize, 3), entry_count);
}

// ============================================================================
// Full PNGB Compilation Tests
// ============================================================================

test "E2E: compile simple_triangle to PNGB" {
    // Full compilation test - parse, analyze, emit PNGB.
    const source: [:0]const u8 =
        \\#shaderModule code {
        \\  code="@vertex fn vertexMain() {} @fragment fn fragMain() {}"
        \\}
        \\
        \\#renderPipeline pipeline {
        \\  layout=auto
        \\  vertex={ entryPoint=vertexMain module=code }
        \\  fragment={ entryPoint=fragMain module=code }
        \\}
        \\
        \\#renderPass render {
        \\  pipeline=pipeline
        \\  draw=3
        \\}
        \\
        \\#frame main {
        \\  perform=[render]
        \\}
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    // Property: valid PNGB header.
    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    // Property: bytecode section exists and contains expected opcodes.
    const format = @import("../bytecode/format.zig");
    const opcodes = @import("../bytecode/opcodes.zig");

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify expected opcodes are present.
    var has_shader = false;
    var has_pipeline = false;
    var has_draw = false;
    var has_frame = false;

    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_shader_module)) has_shader = true;
        if (byte == @intFromEnum(opcodes.OpCode.create_render_pipeline)) has_pipeline = true;
        if (byte == @intFromEnum(opcodes.OpCode.draw)) has_draw = true;
        if (byte == @intFromEnum(opcodes.OpCode.define_frame)) has_frame = true;
    }

    try testing.expect(has_shader);
    try testing.expect(has_pipeline);
    try testing.expect(has_draw);
    try testing.expect(has_frame);
}

test "E2E: compile with texture and sampler" {
    // Test texture/sampler emission.
    const source: [:0]const u8 =
        \\#texture msaaTexture {
        \\  width=512
        \\  height=512
        \\  format=bgra8unorm
        \\  usage=[RENDER_ATTACHMENT]
        \\  sampleCount=4
        \\}
        \\
        \\#sampler linearSampler {
        \\  magFilter=linear
        \\  minFilter=linear
        \\}
        \\
        \\#frame main { perform=[] }
    ;

    const pngb = try Compiler.compile(testing.allocator, source);
    defer testing.allocator.free(pngb);

    try testing.expectEqualStrings("PNGB", pngb[0..4]);

    const format = @import("../bytecode/format.zig");
    const opcodes = @import("../bytecode/opcodes.zig");

    var module = try format.deserialize(testing.allocator, pngb);
    defer module.deinit(testing.allocator);

    // Verify texture and sampler opcodes are present.
    var has_texture = false;
    var has_sampler = false;

    for (module.bytecode) |byte| {
        if (byte == @intFromEnum(opcodes.OpCode.create_texture)) has_texture = true;
        if (byte == @intFromEnum(opcodes.OpCode.create_sampler)) has_sampler = true;
    }

    try testing.expect(has_texture);
    try testing.expect(has_sampler);
}

