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
        .root_source_file = b.path("src/wasm.zig"),
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

    // Create build options with embedded WASM
    const build_options = b.addOptions();
    build_options.addOption(bool, "has_embedded_wasm", true);
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

    // Web build: WASM + JS files for browser deployment
    const web_step = b.step("web", "Build complete web bundle (WASM + JS)");

    // Install WASM to web directory
    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    web_step.dependOn(&install_wasm.step);

    // Also copy WASM to npm package directory
    const install_npm_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../npm/pngine/wasm" } },
    });
    web_step.dependOn(&install_npm_wasm.step);

    // Copy JS files to web output (new API)
    const web_files = [_][]const u8{
        "web/index.html",
        "web/pngine.js",
        "web/_init.js",
        "web/_worker.js",
        "web/_gpu.js",
        "web/_anim.js",
        "web/_extract.js",
    };

    for (web_files) |file| {
        const install_file = b.addInstallFile(b.path(file), b.fmt("web/{s}", .{std.fs.path.basename(file)}));
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
