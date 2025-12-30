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

    // ========================================================================
    // Miniray FFI Integration (required for WGSL reflection/minification)
    // ========================================================================
    //
    // libminiray.a is required for:
    // - WGSL shader reflection (buffer sizes, struct layouts)
    // - Shader minification (--minify flag)
    //
    // Auto-detected at: ../../miniray/build/libminiray.a
    // If not found, reflection/minification features are disabled.
    //
    // REQUIRED VERSION: miniray 0.3.0+
    // Features used: miniray_reflect(), miniray_minify_and_reflect()
    //
    // Build library: cd ../../miniray && make lib
    // Override path: zig build -Dminiray-lib=/path/to/libminiray.a

    const miniray_lib_path = b.option(
        []const u8,
        "miniray-lib",
        "Path to libminiray.a (required for WGSL reflection/minification)",
    );

    // Check if miniray library exists at default location
    const has_miniray_lib = if (miniray_lib_path) |_| true else blk: {
        // Try default development path (compute-initialization is nested in pngine)
        const default_path = "../../miniray/build/libminiray.a";
        if (std.fs.cwd().access(default_path, .{})) |_| {
            break :blk true;
        } else |_| {
            break :blk false;
        }
    };

    const effective_miniray_path: ?[]const u8 = if (miniray_lib_path) |p| p else if (has_miniray_lib) "../../miniray/build/libminiray.a" else null;

    // Build options for reflect module
    const reflect_build_options = b.addOptions();
    reflect_build_options.addOption(bool, "has_miniray_lib", has_miniray_lib);

    // Reflect module (for main lib, WGSL reflection via miniray)
    const reflect_module = b.createModule(.{
        .root_source_file = b.path("src/reflect.zig"),
        .target = target,
        .optimize = optimize,
    });
    reflect_module.addImport("build_options", reflect_build_options.createModule());

    // Add miniray library linking if available
    if (effective_miniray_path) |lib_path| {
        reflect_module.addObjectFile(.{ .cwd_relative = lib_path });
        reflect_module.addIncludePath(.{ .cwd_relative = "../../miniray/build" });
        reflect_module.link_libc = true;

        // Link required system frameworks on macOS
        if (target.result.os.tag == .macos) {
            reflect_module.linkFramework("CoreFoundation", .{});
            reflect_module.linkFramework("Security", .{});
        }
        reflect_module.linkSystemLibrary("pthread", .{});
    }

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

    // Note: AOT compilation is available via wamrc but doesn't work well for
    // embedded scenarios because @embedFile puts data in read-only memory which
    // can't be properly mmap'd for execution. The WASM interpreter is used instead.
    // AOT can be used for loading WASM files from disk (future feature).
    //
    // If you need AOT, use: ./tools/wamrc --target=x86_64 -o file.aot file.wasm

    // Ancillary WASM modules (mvp.wasm for matrix generation)
    const mvp_wasm_module = b.createModule(.{
        .root_source_file = b.path("src/ancillary/mvp.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const mvp_wasm = b.addExecutable(.{
        .name = "mvp",
        .root_module = mvp_wasm_module,
    });
    mvp_wasm.rdynamic = true;
    mvp_wasm.entry = .disabled;

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

    // Add WAMR C library for native WASM execution
    // WAMR provides interpreter + AOT loader support
    const wamr_dep = b.lazyDependency("wamr", .{});
    const wamr_lib: ?*std.Build.Step.Compile = if (wamr_dep) |dep| blk: {
        // Detect target architecture for AOT relocation
        const is_aarch64 = target.result.cpu.arch == .aarch64;
        const is_x86_64 = target.result.cpu.arch == .x86_64;
        const is_darwin = target.result.os.tag == .macos;

        // Core interpreter sources
        const interp_sources: []const []const u8 = &.{
            "core/iwasm/interpreter/wasm_loader.c",
            "core/iwasm/interpreter/wasm_runtime.c",
            "core/iwasm/interpreter/wasm_interp_classic.c",
        };

        // Common runtime sources (without invokeNative - added separately per platform)
        const common_sources: []const []const u8 = &.{
            "core/iwasm/common/wasm_runtime_common.c",
            "core/iwasm/common/wasm_native.c",
            "core/iwasm/common/wasm_exec_env.c",
            "core/iwasm/common/wasm_memory.c",
            "core/iwasm/common/wasm_application.c",
            "core/iwasm/common/wasm_loader_common.c",
            "core/iwasm/common/wasm_c_api.c",
        };

        // Platform-specific invokeNative (handles 64-bit pointer passing correctly)
        const invoke_native_source: []const u8 = if (is_darwin)
            "core/iwasm/common/arch/invokeNative_osx_universal.s"
        else if (target.result.cpu.arch == .x86_64)
            "core/iwasm/common/arch/invokeNative_em64.s"
        else if (target.result.cpu.arch == .aarch64)
            "core/iwasm/common/arch/invokeNative_aarch64.s"
        else
            "core/iwasm/common/arch/invokeNative_general.c";

        // AOT loader sources (not compiler - just loading pre-compiled AOT)
        const aot_sources: []const []const u8 = &.{
            "core/iwasm/aot/aot_loader.c",
            "core/iwasm/aot/aot_runtime.c",
            "core/iwasm/aot/aot_intrinsic.c",
        };

        // Shared utility sources
        const utils_sources: []const []const u8 = &.{
            "core/shared/utils/bh_assert.c",
            "core/shared/utils/bh_bitmap.c", // Required for bulk memory
            "core/shared/utils/bh_common.c",
            "core/shared/utils/bh_hashmap.c",
            "core/shared/utils/bh_list.c",
            "core/shared/utils/bh_log.c",
            "core/shared/utils/bh_queue.c",
            "core/shared/utils/bh_vector.c",
            "core/shared/utils/bh_leb128.c",
            "core/shared/utils/runtime_timer.c",
            "core/shared/utils/uncommon/bh_read_file.c",
        };

        // Memory allocator sources
        const mem_sources: []const []const u8 = &.{
            "core/shared/mem-alloc/mem_alloc.c",
            "core/shared/mem-alloc/ems/ems_alloc.c",
            "core/shared/mem-alloc/ems/ems_hmu.c",
            "core/shared/mem-alloc/ems/ems_kfc.c",
        };

        // POSIX platform sources (for Darwin/macOS and Linux)
        const posix_sources: []const []const u8 = &.{
            "core/shared/platform/common/posix/posix_thread.c",
            "core/shared/platform/common/posix/posix_time.c",
            "core/shared/platform/common/posix/posix_malloc.c",
            "core/shared/platform/common/posix/posix_memmap.c",
            "core/shared/platform/common/posix/posix_clock.c",
            "core/shared/platform/common/posix/posix_blocking_op.c",
            "core/shared/platform/common/memory/mremap.c", // Fallback os_mremap for Darwin
        };

        // Common compile flags for all WAMR sources
        // Note: -fno-sanitize=alignment disables alignment sanitizer which catches
        // misaligned accesses in WAMR's internal table instantiation code
        const wamr_common_flags: []const []const u8 = &.{
            "-std=gnu11",
            "-fno-sanitize=alignment", // WAMR has misaligned table accesses
            "-DWASM_ENABLE_INTERP=1",
            "-DWASM_ENABLE_FAST_INTERP=0", // Classic interpreter
            "-DWASM_ENABLE_AOT=1",
            "-DWASM_ENABLE_BULK_MEMORY=1", // Required for AOT modules
            "-DWASM_ENABLE_REF_TYPES=1", // Required for Zig-produced WASM
            "-DBH_MALLOC=wasm_runtime_malloc",
            "-DBH_FREE=wasm_runtime_free",
            "-DBH_PLATFORM_DARWIN", // For macOS
            "-DBUILD_TARGET_X86_64", // Will be overridden by arch detection
        };

        // Build WAMR as static library
        const wamr_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        // Add all source files with common flags
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = interp_sources,
            .flags = wamr_common_flags,
        });
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = common_sources,
            .flags = wamr_common_flags,
        });
        // Platform-specific invokeNative (assembly for proper 64-bit ABI)
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = &.{invoke_native_source},
            .flags = wamr_common_flags,
        });
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = aot_sources,
            .flags = wamr_common_flags,
        });
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = utils_sources,
            .flags = wamr_common_flags,
        });
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = mem_sources,
            .flags = wamr_common_flags,
        });
        wamr_module.addCSourceFiles(.{
            .root = dep.path("."),
            .files = posix_sources,
            .flags = wamr_common_flags,
        });

        // Platform-specific init
        if (is_darwin) {
            wamr_module.addCSourceFiles(.{
                .root = dep.path("."),
                .files = &.{"core/shared/platform/darwin/platform_init.c"},
                .flags = wamr_common_flags,
            });
        }

        // Architecture-specific AOT relocation
        if (is_aarch64) {
            wamr_module.addCSourceFiles(.{
                .root = dep.path("."),
                .files = &.{"core/iwasm/aot/arch/aot_reloc_aarch64.c"},
                .flags = wamr_common_flags,
            });
        } else if (is_x86_64) {
            wamr_module.addCSourceFiles(.{
                .root = dep.path("."),
                .files = &.{"core/iwasm/aot/arch/aot_reloc_x86_64.c"},
                .flags = wamr_common_flags,
            });
        }

        // Include paths
        wamr_module.addIncludePath(dep.path("core"));
        wamr_module.addIncludePath(dep.path("core/iwasm/include"));
        wamr_module.addIncludePath(dep.path("core/iwasm/common"));
        wamr_module.addIncludePath(dep.path("core/iwasm/interpreter"));
        wamr_module.addIncludePath(dep.path("core/iwasm/aot"));
        wamr_module.addIncludePath(dep.path("core/shared/utils"));
        wamr_module.addIncludePath(dep.path("core/shared/utils/uncommon"));
        wamr_module.addIncludePath(dep.path("core/shared/mem-alloc"));
        wamr_module.addIncludePath(dep.path("core/shared/mem-alloc/ems"));
        wamr_module.addIncludePath(dep.path("core/shared/platform/include"));
        wamr_module.addIncludePath(dep.path("core/shared/platform/common/libc-util"));
        if (is_darwin) {
            wamr_module.addIncludePath(dep.path("core/shared/platform/darwin"));
        }

        const lib = b.addLibrary(.{
            .name = "wamr",
            .root_module = wamr_module,
            .linkage = .static,
        });

        // Link WAMR library to CLI module
        cli_module.linkLibrary(lib);
        cli_module.addIncludePath(dep.path("core/iwasm/include"));
        cli_module.link_libc = true;

        break :blk lib;
    } else null;

    // Create build options with embedded WASM
    // Note: AOT is disabled because embedded AOT doesn't work well
    // (read-only memory can't be mmap'd for execution)
    const build_options = b.addOptions();
    build_options.addOption(bool, "has_embedded_wasm", true);
    build_options.addOption(bool, "has_embedded_aot", false);
    build_options.addOption(bool, "has_wamr", wamr_dep != null);
    cli_module.addImport("build_options", build_options.createModule());

    // Embed WASM binary in CLI for bundle command (browser use) and WAMR interpreter
    cli_module.addAnonymousImport("embedded_wasm", .{
        .root_source_file = wasm.getEmittedBin(),
    });

    const cli = b.addExecutable(.{
        .name = "pngine",
        .root_module = cli_module,
    });

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

    // Fast tests: lib only (skips CLI and viewer which need WASM compile)
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

    // Reflect module (WGSL shader reflection) - uses FFI by default when available
    const reflect_step = b.step("test-reflect", "Run reflect module tests (uses FFI when libminiray.a available)");
    const reflect_standalone_mod = b.createModule(.{
        .root_source_file = b.path("src/reflect/standalone.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Use FFI when library is available (default behavior)
    reflect_standalone_mod.addImport("build_options", reflect_build_options.createModule());

    // Link miniray library for standalone tests too
    if (effective_miniray_path) |lib_path| {
        reflect_standalone_mod.addObjectFile(.{ .cwd_relative = lib_path });
        reflect_standalone_mod.addIncludePath(.{ .cwd_relative = "../../miniray/build" });
        reflect_standalone_mod.link_libc = true;
        if (target.result.os.tag == .macos) {
            reflect_standalone_mod.linkFramework("CoreFoundation", .{});
            reflect_standalone_mod.linkFramework("Security", .{});
        }
        reflect_standalone_mod.linkSystemLibrary("pthread", .{});
    }

    const reflect_test = b.addTest(.{ .name = "reflect", .root_module = reflect_standalone_mod });
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
    dsl_complete_mod.addImport("reflect", reflect_module);
    dsl_complete_mod.addImport("executor", executor_mod);
    // dsl_complete also needs build_options for FFI status
    dsl_complete_mod.addImport("build_options", reflect_build_options.createModule());
    const dsl_complete_test = b.addTest(.{ .name = "dsl-complete", .root_module = dsl_complete_mod });
    const run_dsl_complete_test = b.addRunArtifact(dsl_complete_test);
    dsl_complete_step.dependOn(&run_dsl_complete_test.step);
    standalone_step.dependOn(&run_dsl_complete_test.step);

    // Ancillary module (MVP matrix generator for WASM)
    const ancillary_step = b.step("test-ancillary", "Run ancillary WASM module tests");
    const ancillary_mod = b.createModule(.{
        .root_source_file = b.path("src/ancillary/mvp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ancillary_test = b.addTest(.{ .name = "ancillary", .root_module = ancillary_mod });
    const run_ancillary_test = b.addRunArtifact(ancillary_test);
    ancillary_step.dependOn(&run_ancillary_test.step);
    standalone_step.dependOn(&run_ancillary_test.step);

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

    // Link WAMR library to CLI test module
    if (wamr_lib) |lib| {
        cli_test_module.linkLibrary(lib);
        if (wamr_dep) |dep| {
            cli_test_module.addIncludePath(dep.path("core/iwasm/include"));
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

    // Create bytecode module for WASM target (shared across all executor variants)
    const types_wasm = b.createModule(.{
        .root_source_file = b.path("src/types/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const bytecode_wasm = b.createModule(.{
        .root_source_file = b.path("src/bytecode/standalone.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    bytecode_wasm.addImport("types", types_wasm);

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
        executor_module.addImport("bytecode", bytecode_wasm);

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
    // Uses source JS files for development (works with Vite dev server)
    // For production bundles, use: node npm/pngine/scripts/bundle.js
    const web_step = b.step("web", "Build demo bundle (WASM + JS)");

    // Note: pngine.wasm is no longer copied to demo/ because PNGs now embed their executor.
    // The embedded executor is extracted from the bytecode payload at runtime.

    // Install ancillary mvp.wasm to demo/assets directory
    const install_mvp_wasm = b.addInstallArtifact(mvp_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "demo/assets" } },
    });
    web_step.dependOn(&install_mvp_wasm.step);

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
    // Note: gpu.js uses closure pattern for better minification (58% smaller)
    const SrcFile = struct { src: []const u8, dest: []const u8 };
    const js_files = [_]SrcFile{
        .{ .src = "npm/pngine/src/index.js", .dest = "demo/pngine.js" },
        .{ .src = "npm/pngine/src/init.js", .dest = "demo/init.js" },
        .{ .src = "npm/pngine/src/worker.js", .dest = "demo/worker.js" },
        .{ .src = "npm/pngine/src/gpu.js", .dest = "demo/gpu.js" },
        .{ .src = "npm/pngine/src/anim.js", .dest = "demo/anim.js" },
        .{ .src = "npm/pngine/src/extract.js", .dest = "demo/extract.js" },
        .{ .src = "npm/pngine/src/loader.js", .dest = "demo/loader.js" },
    };
    for (js_files) |file| {
        const install_file = b.addInstallFile(b.path(file.src), file.dest);
        web_step.dependOn(&install_file.step);
    }

    // Web bundle: minified production bundle (requires Node.js + esbuild)
    // Produces npm/pngine/dist/browser.mjs with DEBUG=false (strips debug logging)
    const web_bundle_step = b.step("web-bundle", "Build minified production JS bundle");
    web_bundle_step.dependOn(web_step);
    const bundle_cmd = b.addSystemCommand(&.{ "node", "npm/pngine/scripts/bundle.js" });
    web_bundle_step.dependOn(&bundle_cmd.step);

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
    // Desktop Viewer (WAMR + trace mode)
    // ========================================================================
    //
    // Standalone viewer for PNG files with embedded executors.
    // Uses WAMR to run embedded WASM executor and traces command buffers.
    // See: docs/embedded-executor-plan.md Phase 7
    //
    // Usage: zig build desktop-viewer -- triangle-embedded.png

    const desktop_viewer_step = b.step("desktop-viewer", "Build desktop PNG viewer with WAMR");

    // Create WAMR wrapper module (reuses CLI's WAMR wrapper)
    const wamr_wrapper_options = b.addOptions();
    wamr_wrapper_options.addOption(bool, "has_wamr", wamr_dep != null);

    const wamr_wrapper_module = b.createModule(.{
        .root_source_file = b.path("src/cli/validate/wamr.zig"),
        .target = target,
        .optimize = optimize,
    });
    wamr_wrapper_module.addImport("build_options", wamr_wrapper_options.createModule());

    // Link WAMR library to wrapper module
    if (wamr_lib) |lib| {
        wamr_wrapper_module.linkLibrary(lib);
        if (wamr_dep) |dep| {
            wamr_wrapper_module.addIncludePath(dep.path("core/iwasm/include"));
        }
        wamr_wrapper_module.link_libc = true;
    }

    // Create desktop viewer module
    const desktop_viewer_module = b.createModule(.{
        .root_source_file = b.path("viewers/desktop/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    desktop_viewer_module.addImport("pngine", lib_module);
    desktop_viewer_module.addImport("wamr", wamr_wrapper_module);

    const desktop_viewer = b.addExecutable(.{
        .name = "desktop-viewer",
        .root_module = desktop_viewer_module,
    });

    b.installArtifact(desktop_viewer);
    desktop_viewer_step.dependOn(&b.addInstallArtifact(desktop_viewer, .{}).step);

    // Run desktop viewer step
    const run_desktop_viewer = b.addRunArtifact(desktop_viewer);
    run_desktop_viewer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_desktop_viewer.addArgs(args);
    }

    const run_desktop_viewer_step = b.step("run-desktop-viewer", "Run the desktop viewer");
    run_desktop_viewer_step.dependOn(&run_desktop_viewer.step);
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
