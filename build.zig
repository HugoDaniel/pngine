const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add zgpu dependency for native GPU rendering (lazy - only fetched if needed)
    const zgpu_dep = b.lazyDependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });

    // Shared types module (zero dependencies, used by multiple modules)
    const types_module = b.createModule(.{
        .root_source_file = b.path("src/types/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Bytecode module (depends on types, used by executor)
    const bytecode_module = b.createModule(.{
        .root_source_file = b.path("src/bytecode/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytecode_module.addImport("types", types_module);

    // Reflect module (for main lib, WGSL reflection via miniray)
    const reflect_module = b.createModule(.{
        .root_source_file = b.path("src/reflect.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executor module (for main lib, bytecode dispatch)
    const lib_executor_module = b.createModule(.{
        .root_source_file = b.path("src/executor/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_executor_module.addImport("bytecode", bytecode_module);

    // Main library module (exposed for dependents)
    const lib_module = b.addModule("pngine", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("types", types_module);
    lib_module.addImport("bytecode", bytecode_module);
    lib_module.addImport("reflect", reflect_module);
    lib_module.addImport("executor", lib_executor_module);

    // Add zgpu to library module if available (native targets only)
    if (zgpu_dep) |dep| {
        lib_module.addImport("zgpu", dep.module("root"));
    }

    // WASM build target (moved up so CLI can depend on it)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Types module for WASM target
    const wasm_types_module = b.createModule(.{
        .root_source_file = b.path("src/types/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    // Bytecode module for WASM target
    const wasm_bytecode_module = b.createModule(.{
        .root_source_file = b.path("src/bytecode/standalone.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_bytecode_module.addImport("types", wasm_types_module);

    // Create WASM entry module (separate from main library)
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    wasm_module.addImport("types", wasm_types_module);
    wasm_module.addImport("bytecode", wasm_bytecode_module);

    const wasm = b.addExecutable(.{
        .name = "pngine",
        .root_module = wasm_module,
    });
    // Export symbols for JS access
    wasm.rdynamic = true;
    // No main() - use exported functions
    wasm.entry = .disabled;

    // CLI executable
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("pngine", lib_module);

    // Add zgpu to CLI module if available
    if (zgpu_dep) |dep| {
        cli_module.addImport("zgpu", dep.module("root"));
    }

    // Add wasm3 C library for native WASM execution in validate command
    // Build as static library once, share between CLI and CLI tests
    const wasm3_dep = b.lazyDependency("wasm3", .{});
    const wasm3_lib: ?*std.Build.Step.Compile = if (wasm3_dep) |dep| blk: {
        const wasm3_sources: []const []const u8 = &.{
            "source/m3_api_libc.c",
            "source/m3_api_meta_wasi.c",
            "source/m3_api_tracer.c",
            "source/m3_api_uvwasi.c",
            "source/m3_api_wasi.c",
            "source/m3_bind.c",
            "source/m3_code.c",
            "source/m3_compile.c",
            "source/m3_core.c",
            "source/m3_emit.c",
            "source/m3_env.c",
            "source/m3_exec.c",
            "source/m3_function.c",
            "source/m3_info.c",
            "source/m3_module.c",
            "source/m3_optimize.c",
            "source/m3_parse.c",
        };

        // Build wasm3 as static library (compiled once, linked to CLI and CLI tests)
        const wasm3_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wasm3_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = wasm3_sources,
            .flags = &.{
                "-std=gnu11",
                "-fno-sanitize=undefined", // wasm3 uses some UB-ish patterns
            },
        });
        wasm3_module.addIncludePath(dep.path("source"));

        const lib = b.addLibrary(.{
            .name = "wasm3",
            .root_module = wasm3_module,
            .linkage = .static,
        });

        // Link wasm3 library to CLI module
        cli_module.linkLibrary(lib);
        cli_module.addIncludePath(dep.path("source"));
        cli_module.link_libc = true;

        break :blk lib;
    } else null;

    // Create build options with embedded WASM
    const build_options = b.addOptions();
    build_options.addOption(bool, "has_embedded_wasm", true);
    build_options.addOption(bool, "has_wasm3", wasm3_dep != null);
    cli_module.addImport("build_options", build_options.createModule());

    // Embed WASM binary in CLI for bundle command
    cli_module.addAnonymousImport("embedded_wasm", .{
        .root_source_file = wasm.getEmittedBin(),
    });

    const cli = b.addExecutable(.{
        .name = "pngine",
        .root_module = cli_module,
    });

    // CLI depends on WASM being built first
    cli.step.dependOn(&wasm.step);

    b.installArtifact(cli);

    // Run step for CLI
    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    // Native tests
    const tests = b.addTest(.{
        .root_module = lib_module,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Fast tests: lib only (skips CLI and viewer which need wasm3/wasm compile)
    // ~5s vs ~7min for full test suite
    // Use: zig build test-fast
    // Even faster: zig test src/main.zig --test-filter "Lexer"
    const fast_test_step = b.step("test-fast", "Run lib tests only (~5s vs 7min)");
    fast_test_step.dependOn(&run_tests.step);

    // ========================================================================
    // Standalone Test Modules (compile in parallel)
    // ========================================================================
    //
    // These modules have zero external dependencies and can compile/run
    // independently. Use `zig build test-standalone` to run all in parallel.
    //
    // | Module       | Tests | Description                    |
    // |--------------|-------|--------------------------------|
    // | types        | 10    | Core type definitions          |
    // | pbsf         | 35    | S-expression parser            |
    // | png          | 91    | PNG encoding/embedding         |
    // | dsl-frontend | 75    | Token, Lexer, Ast, Parser      |
    // | dsl-backend  | 119   | Analyzer (semantic analysis)   |
    // | bytecode     | 147   | Format, opcodes, emitter, etc. |
    // | reflect      | 9     | WGSL shader reflection         |
    // | executor     | 114   | Dispatcher, mock_gpu, etc.     |
    // | dsl-complete | 361   | Emitter + full compilation     |
    // | Total        | 960   |                                |
    //
    // Usage:
    //   zig build test-standalone   # Run all standalone modules (~3s)
    //   zig build test-types        # Just types
    //   zig build test-pbsf         # Just pbsf
    //   zig build test-png          # Just png
    //   zig build test-dsl-frontend # Just dsl frontend
    //   zig build test-dsl-backend  # Just dsl analyzer
    //   zig build test-bytecode     # Just bytecode
    //   zig build test-dsl-complete # Just dsl emitter (full chain)
    //   zig build test-reflect      # Just reflect
    //   zig build test-executor     # Just executor

    const standalone_step = b.step("test-standalone", "Run standalone module tests in parallel (~2s)");

    // Types module
    const types_test_step = b.step("test-types", "Run types module tests");
    const types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/types/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const types_test = b.addTest(.{ .name = "types", .root_module = types_test_mod });
    const run_types_test = b.addRunArtifact(types_test);
    types_test_step.dependOn(&run_types_test.step);
    standalone_step.dependOn(&run_types_test.step);

    // PBSF module (S-expression parser)
    const pbsf_test_step = b.step("test-pbsf", "Run PBSF parser tests");
    const pbsf_test_mod = b.createModule(.{
        .root_source_file = b.path("src/pbsf/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pbsf_test = b.addTest(.{ .name = "pbsf", .root_module = pbsf_test_mod });
    const run_pbsf_test = b.addRunArtifact(pbsf_test);
    pbsf_test_step.dependOn(&run_pbsf_test.step);
    standalone_step.dependOn(&run_pbsf_test.step);

    // PNG module (encoding/embedding)
    const png_test_step = b.step("test-png", "Run PNG module tests");
    const png_test_mod = b.createModule(.{
        .root_source_file = b.path("src/png/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const png_test = b.addTest(.{ .name = "png", .root_module = png_test_mod });
    const run_png_test = b.addRunArtifact(png_test);
    png_test_step.dependOn(&run_png_test.step);
    standalone_step.dependOn(&run_png_test.step);

    // DSL Frontend module (Token, Lexer, Ast, Parser)
    const dsl_frontend_step = b.step("test-dsl-frontend", "Run DSL frontend tests");
    const dsl_frontend_mod = b.createModule(.{
        .root_source_file = b.path("src/dsl/frontend.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsl_frontend_test = b.addTest(.{ .name = "dsl-frontend", .root_module = dsl_frontend_mod });
    const run_dsl_frontend_test = b.addRunArtifact(dsl_frontend_test);
    dsl_frontend_step.dependOn(&run_dsl_frontend_test.step);
    standalone_step.dependOn(&run_dsl_frontend_test.step);

    // DSL Backend module (Analyzer) - uses types module import
    const dsl_backend_step = b.step("test-dsl-backend", "Run DSL analyzer tests");
    const dsl_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/dsl/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsl_backend_mod.addImport("types", types_module);
    const dsl_backend_test = b.addTest(.{ .name = "dsl-backend", .root_module = dsl_backend_mod });
    const run_dsl_backend_test = b.addRunArtifact(dsl_backend_test);
    dsl_backend_step.dependOn(&run_dsl_backend_test.step);
    standalone_step.dependOn(&run_dsl_backend_test.step);

    // Bytecode module (format, opcodes, emitter, tables) - uses types module import
    const bytecode_step = b.step("test-bytecode", "Run bytecode module tests");
    const bytecode_mod = b.createModule(.{
        .root_source_file = b.path("src/bytecode/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytecode_mod.addImport("types", types_module);
    const bytecode_test = b.addTest(.{ .name = "bytecode", .root_module = bytecode_mod });
    const run_bytecode_test = b.addRunArtifact(bytecode_test);
    bytecode_step.dependOn(&run_bytecode_test.step);
    standalone_step.dependOn(&run_bytecode_test.step);

    // Reflect module (WGSL shader reflection) - no external dependencies
    const reflect_step = b.step("test-reflect", "Run reflect module tests");
    const reflect_mod = b.createModule(.{
        .root_source_file = b.path("src/reflect/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    const reflect_test = b.addTest(.{ .name = "reflect", .root_module = reflect_mod });
    const run_reflect_test = b.addRunArtifact(reflect_test);
    reflect_step.dependOn(&run_reflect_test.step);
    standalone_step.dependOn(&run_reflect_test.step);

    // Executor module (dispatcher, mock_gpu, command_buffer) - uses bytecode module import
    const executor_step = b.step("test-executor", "Run executor module tests");
    const executor_mod = b.createModule(.{
        .root_source_file = b.path("src/executor/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    executor_mod.addImport("bytecode", bytecode_mod);
    const executor_test = b.addTest(.{ .name = "executor", .root_module = executor_mod });
    const run_executor_test = b.addRunArtifact(executor_test);
    executor_step.dependOn(&run_executor_test.step);
    standalone_step.dependOn(&run_executor_test.step);

    // DSL Complete module (emitter + full DSL chain) - uses all external modules
    const dsl_complete_step = b.step("test-dsl-complete", "Run DSL emitter tests");
    const dsl_complete_mod = b.createModule(.{
        .root_source_file = b.path("src/dsl/complete.zig"),
        .target = target,
        .optimize = optimize,
    });
    dsl_complete_mod.addImport("types", types_module);
    dsl_complete_mod.addImport("bytecode", bytecode_mod);
    dsl_complete_mod.addImport("reflect", reflect_mod);
    dsl_complete_mod.addImport("executor", executor_mod);
    const dsl_complete_test = b.addTest(.{ .name = "dsl-complete", .root_module = dsl_complete_mod });
    const run_dsl_complete_test = b.addRunArtifact(dsl_complete_test);
    dsl_complete_step.dependOn(&run_dsl_complete_test.step);
    standalone_step.dependOn(&run_dsl_complete_test.step);

    // Coverage step (requires kcov installed)
    const coverage_step = b.step("coverage", "Run tests with coverage (requires kcov)");

    // Build test executable for coverage (don't run it directly)
    const coverage_tests = b.addTest(.{
        .root_module = lib_module,
    });

    // Run kcov with the test binary
    const run_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=src",
        "--exclude-pattern=test.zig,_test.zig",
        "--exclude-line=unreachable,@panic",
        "coverage",
    });
    run_coverage.addArtifactArg(coverage_tests);
    coverage_step.dependOn(&run_coverage.step);

    // CLI tests
    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.addImport("pngine", lib_module);
    cli_test_module.addImport("build_options", build_options.createModule());
    cli_test_module.addAnonymousImport("embedded_wasm", .{
        .root_source_file = wasm.getEmittedBin(),
    });

    // Link shared wasm3 library to CLI test module (avoids recompiling C sources)
    if (wasm3_lib) |lib| {
        cli_test_module.linkLibrary(lib);
        if (wasm3_dep) |dep| {
            cli_test_module.addIncludePath(dep.path("source"));
        }
        cli_test_module.link_libc = true;
    }

    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });
    cli_tests.step.dependOn(&wasm.step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // Benchmark executable
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench = b.addExecutable(.{
        .name = "pngine-bench",
        .root_module = bench_module,
    });

    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // WASM build step (wasm artifact defined earlier for CLI embedding)
    const wasm_step = b.step("wasm", "Build WASM for browser");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{}).step);

    // ========================================================================
    // Executor Variants (for embedded executor feature)
    // ========================================================================
    //
    // Pre-built executor WASM modules with different plugin combinations.
    // These are embedded in PNG payloads based on DSL feature analysis.
    //
    // See: docs/embedded-executor-plan.md for architecture details.

    const executors_step = b.step("executors", "Build executor WASM variants");

    // Plugin combinations to build (common cases)
    const ExecutorVariant = struct {
        name: []const u8,
        render: bool,
        compute: bool,
        wasm: bool,
        animation: bool,
        texture: bool,
    };

    const executor_variants = [_]ExecutorVariant{
        .{ .name = "core", .render = false, .compute = false, .wasm = false, .animation = false, .texture = false },
        .{ .name = "render", .render = true, .compute = false, .wasm = false, .animation = false, .texture = false },
        .{ .name = "compute", .render = false, .compute = true, .wasm = false, .animation = false, .texture = false },
        .{ .name = "render-compute", .render = true, .compute = true, .wasm = false, .animation = false, .texture = false },
        .{ .name = "render-anim", .render = true, .compute = false, .wasm = false, .animation = true, .texture = false },
        .{ .name = "render-compute-anim", .render = true, .compute = true, .wasm = false, .animation = true, .texture = false },
        .{ .name = "render-wasm", .render = true, .compute = false, .wasm = true, .animation = false, .texture = false },
        .{ .name = "full", .render = true, .compute = true, .wasm = true, .animation = true, .texture = true },
    };

    for (executor_variants) |variant| {
        // Create plugin options for this variant
        const plugin_options = b.addOptions();
        plugin_options.addOption(bool, "core", true); // Always enabled
        plugin_options.addOption(bool, "render", variant.render);
        plugin_options.addOption(bool, "compute", variant.compute);
        plugin_options.addOption(bool, "wasm", variant.wasm);
        plugin_options.addOption(bool, "animation", variant.animation);
        plugin_options.addOption(bool, "texture", variant.texture);

        // Create executor WASM module with plugin options
        const executor_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_entry.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        executor_module.addImport("plugins", plugin_options.createModule());

        const executor = b.addExecutable(.{
            .name = b.fmt("pngine-{s}", .{variant.name}),
            .root_module = executor_module,
        });
        executor.rdynamic = true;
        executor.entry = .disabled;

        // Install to executors directory
        const install_executor = b.addInstallArtifact(executor, .{
            .dest_dir = .{ .override = .{ .custom = "executors" } },
        });
        executors_step.dependOn(&install_executor.step);
    }

    // Web build: WASM + JS files for browser deployment
    const web_step = b.step("web", "Build demo bundle (WASM + JS)");

    // Install WASM to demo directory
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "demo" } },
    });
    web_step.dependOn(&install_wasm.step);

    // Also copy WASM to npm package directory
    const install_npm_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../npm/pngine/wasm" } },
    });
    web_step.dependOn(&install_npm_wasm.step);

    // Copy demo HTML files
    const html_files = [_][]const u8{
        "demo/index.html",
    };
    for (html_files) |file| {
        const install_file = b.addInstallFile(b.path(file), b.fmt("demo/{s}", .{std.fs.path.basename(file)}));
        web_step.dependOn(&install_file.step);
    }

    // Copy JS source files from npm/pngine/src/ to demo output for development
    const SrcFile = struct { src: []const u8, dest: []const u8 };
    const js_files = [_]SrcFile{
        .{ .src = "npm/pngine/src/index.js", .dest = "demo/pngine.js" },
        .{ .src = "npm/pngine/src/init.js", .dest = "demo/init.js" },
        .{ .src = "npm/pngine/src/worker.js", .dest = "demo/worker.js" },
        .{ .src = "npm/pngine/src/gpu.js", .dest = "demo/gpu.js" },
        .{ .src = "npm/pngine/src/anim.js", .dest = "demo/anim.js" },
        .{ .src = "npm/pngine/src/extract.js", .dest = "demo/extract.js" },
    };
    for (js_files) |file| {
        const install_file = b.addInstallFile(b.path(file.src), file.dest);
        web_step.dependOn(&install_file.step);
    }

    // NPM package build: cross-compile CLI for all platforms
    const npm_step = b.step("npm", "Build npm package binaries for all platforms");

    // Target platforms for npm distribution
    const NpmTarget = struct {
        query: std.Target.Query,
        name: []const u8,
        exe_name: []const u8,
    };

    const npm_targets = [_]NpmTarget{
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "darwin-arm64", .exe_name = "pngine" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "darwin-x64", .exe_name = "pngine" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .name = "linux-x64", .exe_name = "pngine" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .name = "linux-arm64", .exe_name = "pngine" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "win32-x64", .exe_name = "pngine.exe" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "win32-arm64", .exe_name = "pngine.exe" },
    };

    for (npm_targets) |npm_target| {
        const cross_target = b.resolveTargetQuery(npm_target.query);

        // Create library module for this target
        const cross_lib = b.addModule("pngine", .{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
        });

        // Create CLI module for this target
        const cross_cli_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
        });
        cross_cli_module.addImport("pngine", cross_lib);

        // Add build options (no embedded WASM for cross-compiled CLI)
        const cross_build_options = b.addOptions();
        cross_build_options.addOption(bool, "has_embedded_wasm", false);
        cross_cli_module.addImport("build_options", cross_build_options.createModule());

        const cross_cli = b.addExecutable(.{
            .name = "pngine",
            .root_module = cross_cli_module,
        });

        // Install to npm package directory
        const install_path = b.fmt("npm/pngine-{s}/bin/{s}", .{ npm_target.name, npm_target.exe_name });
        const install_cross = b.addInstallArtifact(cross_cli, .{
            .dest_dir = .{ .override = .{ .custom = install_path } },
        });
        npm_step.dependOn(&install_cross.step);
    }

    // Also copy WASM to npm package
    const npm_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "npm/pngine/wasm" } },
    });
    npm_step.dependOn(&npm_wasm.step);

    // ========================================================================
    // Native Viewer
    // ========================================================================
    //
    // Standalone viewer for PNG files with embedded executors.
    // See: docs/embedded-executor-plan.md Phase 7
    //
    // Usage: zig build viewer -- shader.png

    const viewer_step = b.step("viewer", "Build native PNG viewer");

    // Create viewer module
    const viewer_module = b.createModule(.{
        .root_source_file = b.path("viewers/native/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    viewer_module.addImport("pngine", lib_module);

    const viewer = b.addExecutable(.{
        .name = "pngine-viewer",
        .root_module = viewer_module,
    });

    b.installArtifact(viewer);
    viewer_step.dependOn(&b.addInstallArtifact(viewer, .{}).step);

    // Run viewer step
    const run_viewer = b.addRunArtifact(viewer);
    run_viewer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_viewer.addArgs(args);
    }

    const run_viewer_step = b.step("run-viewer", "Run the native viewer");
    run_viewer_step.dependOn(&run_viewer.step);

    // Viewer tests
    const viewer_test_module = b.createModule(.{
        .root_source_file = b.path("viewers/native/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    viewer_test_module.addImport("pngine", lib_module);
    const viewer_tests = b.addTest(.{
        .root_module = viewer_test_module,
    });
    test_step.dependOn(&b.addRunArtifact(viewer_tests).step);
}

// Version check at comptime
comptime {
    const required = std.SemanticVersion{ .major = 0, .minor = 14, .patch = 0 };
    if (builtin.zig_version.order(required) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Zig version {} required, found {}",
            .{ required, builtin.zig_version },
        ));
    }
}
