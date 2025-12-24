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

    // Main library module (exposed for dependents)
    const lib_module = b.addModule("pngine", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zgpu to library module if available (native targets only)
    if (zgpu_dep) |dep| {
        lib_module.addImport("zgpu", dep.module("root"));
    }

    // WASM build target (moved up so CLI can depend on it)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Create WASM entry module (separate from main library)
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

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

    // Note: wasm3 integration for actual WASM execution is deferred.
    // The validate command currently works for static bytecode analysis.
    // To enable WASM execution, wasm3 needs to be compiled as a C library
    // and linked. See: https://github.com/wasm3/wasm3

    // Create build options with embedded WASM
    const build_options = b.addOptions();
    build_options.addOption(bool, "has_embedded_wasm", true);
    build_options.addOption(bool, "has_wasm3", false); // TODO: Enable when wasm3 is integrated
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
