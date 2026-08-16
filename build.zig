const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zgpu disabled: zpool dependency uses deprecated @Type (incompatible with Zig 0.16)
    // Re-enable when zgpu updates zpool for Zig 0.16 compatibility
    // const zgpu_dep = b.lazyDependency("zgpu", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    const zgpu_dep: ?*std.Build.Dependency = null;

    // Shared types module (zero dependencies, used by multiple modules)
    const types_module = stdModule(b, target, optimize, "src/types/main.zig", &.{});

    // Bytecode module (depends on types, used by executor)
    const bytecode_module = stdModule(b, target, optimize, "src/bytecode/standalone.zig", &.{
        .{ .name = "types", .module = types_module },
    });

    // ========================================================================
    // wgslender (native Zig WGSL reflection/minification)
    // ========================================================================
    const wgslender_dep = b.dependency("wgslender", .{
        .target = target,
        .optimize = optimize,
    });
    const wgslender_mod = wgslender_dep.module("wgslender");

    // ========================================================================
    // SJON host (schema + validator + lowering)
    // ========================================================================
    // plugin-exec=false: PNGine never runs executable WASM plugins — its
    // expressions use plugins.core's native expr-funcs — so we skip the
    // libwasmtime/libc link SJON would otherwise add on native (SJON's
    // `plugin-exec` build option defaults to true on native). Forced off on
    // wasm32 too; see the `test-sjon-wasm` gate below.
    const sjon_dep = b.dependency("sjon", .{
        .target = target,
        .optimize = optimize,
        .@"plugin-exec" = false,
    });
    const sjon_mod = sjon_dep.module("sjon");

    // Reflect module (for main lib, WGSL reflection via wgslender)
    const reflect_module = stdModule(b, target, optimize, "src/reflect.zig", &.{
        .{ .name = "wgslender", .module = wgslender_mod },
    });

    // Executor module (for main lib, bytecode dispatch)
    const lib_executor_module = stdModule(b, target, optimize, "src/executor/standalone.zig", &.{
        .{ .name = "bytecode", .module = bytecode_module },
    });

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

    // Build options for GPU module (zgpu availability)
    const gpu_build_options = b.addOptions();
    gpu_build_options.addOption(bool, "has_zgpu", zgpu_dep != null);

    // -Dgpu-native: link the real wgpu-native backend into the CLI so that
    // `pngine --frame` produces pixel-exact native renders (no browser in the
    // loop). Defaults to true on a macOS host build when the vendored static lib
    // is present. `vendor/` is gitignored, so we DETECT the lib rather than
    // assume it. `zig build npm` forces this off (cross targets have no libs).
    const vendored_wgpu_present = if (b.build_root.handle.access(
        b.graph.io,
        "vendor/wgpu-native/lib/libwgpu_native.a",
        .{},
    )) |_| true else |_| false;
    const gpu_native_default = target.result.os.tag == .macos and vendored_wgpu_present;
    const has_wgpu_native = b.option(
        bool,
        "gpu-native",
        "Link the native wgpu backend for real --frame rendering (default: macOS host with vendored lib)",
    ) orelse gpu_native_default;
    gpu_build_options.addOption(bool, "has_wgpu_native", has_wgpu_native);
    lib_module.addImport("gpu_build_options", gpu_build_options.createModule());

    // When the native GPU backend is on, attach its link settings to lib_module.
    // In Zig 0.16 module-level link settings propagate to every artifact whose
    // graph includes the module, so this single attachment covers the CLI exe
    // (`zig build`) AND the lib tests (`zig build test`/`test-fast`), both of
    // which import `pngine`. test-standalone uses per-module roots (not
    // lib_module) so it stays GPU-free. Template mirrors the `native` step below.
    if (has_wgpu_native) {
        if (vendored_wgpu_present) {
            lib_module.addIncludePath(b.path("vendor/wgpu-native/include"));
            lib_module.addLibraryPath(b.path("vendor/wgpu-native/lib"));
            lib_module.linkSystemLibrary("wgpu_native", .{});
            lib_module.link_libc = true;
            if (target.result.os.tag == .macos) {
                lib_module.linkFramework("Metal", .{});
                lib_module.linkFramework("MetalKit", .{});
                lib_module.linkFramework("QuartzCore", .{});
            }
        } else {
            // Only reachable via an explicit `-Dgpu-native=true` with no lib.
            const fail = b.addFail(
                "-Dgpu-native=true but vendor/wgpu-native/lib/libwgpu_native.a is " ++
                    "missing. Run scripts/download-wgpu-native.sh first.",
            );
            b.getInstallStep().dependOn(&fail.step);
        }
    }

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
    const wasm_types_module = stdModule(b, wasm_target, .ReleaseSmall, "src/types/main.zig", &.{});

    // Bytecode module for WASM target
    const wasm_bytecode_module = stdModule(b, wasm_target, .ReleaseSmall, "src/bytecode/standalone.zig", &.{
        .{ .name = "types", .module = wasm_types_module },
    });

    // Default wasm_config - wasm_entry.zig uses built-in buffer-size defaults.
    // The one knob: `-Ddebug-log` compiles the executor's dbg() host-log sites
    // (and the env.log import). Off by default so shipping executors carry zero
    // host imports and none of std.fmt's formatting code.
    const wasm_debug_log = b.option(
        bool,
        "debug-log",
        "Compile the executor's dbg() host-log sites (env.log import); off by default",
    ) orelse false;
    const wasm_default_config = b.addOptions();
    wasm_default_config.addOption(bool, "debug_log", wasm_debug_log);

    // Default `plugins` options module — all plugins on ("full"). Wired at every
    // target that compiles src/executor/plugins.zig WITHOUT its own per-variant
    // flags (generic wasm, native/micro executor, standalone executor tests), so
    // the C11 `@import("plugins")` shim always resolves and defaults to full. The
    // executor VARIANTS below wire their own real flags instead. (Helper because
    // an addOptions' createModule() is consumed per import site.)
    const pluginDefaultModule = struct {
        fn make(bld: *std.Build) *std.Build.Module {
            const opts = bld.addOptions();
            opts.addOption(bool, "core", true);
            opts.addOption(bool, "render", true);
            opts.addOption(bool, "compute", true);
            opts.addOption(bool, "wasm", true);
            opts.addOption(bool, "animation", true);
            opts.addOption(bool, "texture", true);
            return opts.createModule();
        }
    }.make;

    // Core-only `plugins` module (every optional plugin off) — used to
    // conformance-test the plugin-disabled `else` skip arms of wasm_entry, which
    // item 2.1 routed through the shared wire_schema spine and item 2.2 made
    // live. Without this the disabled arms would compile but never run in tests.
    const pluginCoreModule = struct {
        fn make(bld: *std.Build) *std.Build.Module {
            const opts = bld.addOptions();
            opts.addOption(bool, "core", true);
            opts.addOption(bool, "render", false);
            opts.addOption(bool, "compute", false);
            opts.addOption(bool, "wasm", false);
            opts.addOption(bool, "animation", false);
            opts.addOption(bool, "texture", false);
            return opts.createModule();
        }
    }.make;

    // Create WASM entry module (separate from main library)
    const wasm_module = stdModule(b, wasm_target, .ReleaseSmall, "src/wasm_entry.zig", &.{
        .{ .name = "types", .module = wasm_types_module },
        .{ .name = "bytecode", .module = wasm_bytecode_module },
        .{ .name = "wasm_config", .module = wasm_default_config.createModule() },
        .{ .name = "plugins", .module = pluginDefaultModule(b) },
    });

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
    const mvp_wasm_module = stdModule(b, wasm_target, .ReleaseSmall, "src/ancillary/mvp.zig", &.{});
    const mvp_wasm = b.addExecutable(.{
        .name = "mvp",
        .root_module = mvp_wasm_module,
    });
    mvp_wasm.rdynamic = true;
    mvp_wasm.entry = .disabled;

    // ========================================================================
    // Executor Variants (embedded in CLI binaries)
    // ========================================================================
    //
    // Pre-built executor WASM modules with different plugin combinations.
    // These are embedded in CLI binaries and in PNG payloads.
    // Built here (before CLI) so artifacts are available for @embedFile.
    //
    // See: docs/plans/archive/embedded-executor-plan.md for architecture details.

    const executors_step = b.step("executors", "Build executor WASM variants");

    const ExecutorVariant = struct {
        name: []const u8,
        render: bool,
        compute: bool,
        wasm: bool,
        animation: bool,
        texture: bool,
        // Size budget (item 4.2 / C7b): measured 2026-07-15 + ~5% headroom.
        // Enforced by tools/assert_executor_budgets.zig; bump deliberately.
        // Re-derived at Arc-3 §5.4: id-narrowing hardening (the noinline `narrowId`
        // guard + its ~57 call sites) grew the shipping executor ~730 B (full
        // 12198→12929) — a deliberate, loud-over-silent trade recorded here.
        max_bytes: u32,
    };

    const executor_variants = [_]ExecutorVariant{
        .{ .name = "core", .render = false, .compute = false, .wasm = false, .animation = false, .texture = false, .max_bytes = 9200 },
        .{ .name = "render", .render = true, .compute = false, .wasm = false, .animation = false, .texture = false, .max_bytes = 11800 },
        .{ .name = "compute", .render = false, .compute = true, .wasm = false, .animation = false, .texture = false, .max_bytes = 9500 },
        .{ .name = "render-compute", .render = true, .compute = true, .wasm = false, .animation = false, .texture = false, .max_bytes = 12100 },
        .{ .name = "render-anim", .render = true, .compute = false, .wasm = false, .animation = true, .texture = false, .max_bytes = 11800 },
        .{ .name = "render-compute-anim", .render = true, .compute = true, .wasm = false, .animation = true, .texture = false, .max_bytes = 12100 },
        .{ .name = "render-wasm", .render = true, .compute = false, .wasm = true, .animation = false, .texture = false, .max_bytes = 12600 },
        .{ .name = "full", .render = true, .compute = true, .wasm = true, .animation = true, .texture = true, .max_bytes = 13600 },
    };

    const ExecutorArtifact = struct {
        name: []const u8,
        bin: std.Build.LazyPath,
        max_bytes: u32,
    };
    var executor_artifacts: [executor_variants.len]ExecutorArtifact = undefined;

    for (executor_variants, 0..) |variant, i| {
        const plugin_options = b.addOptions();
        plugin_options.addOption(bool, "core", true);
        plugin_options.addOption(bool, "render", variant.render);
        plugin_options.addOption(bool, "compute", variant.compute);
        plugin_options.addOption(bool, "wasm", variant.wasm);
        plugin_options.addOption(bool, "animation", variant.animation);
        plugin_options.addOption(bool, "texture", variant.texture);

        const executor_module = stdModule(b, wasm_target, .ReleaseSmall, "src/wasm_entry.zig", &.{
            .{ .name = "plugins", .module = plugin_options.createModule() },
            .{ .name = "bytecode", .module = wasm_bytecode_module },
            .{ .name = "wasm_config", .module = wasm_default_config.createModule() },
        });

        const executor = b.addExecutable(.{
            .name = b.fmt("pngine-{s}", .{variant.name}),
            .root_module = executor_module,
        });
        executor.rdynamic = true;
        executor.entry = .disabled;

        executor_artifacts[i] = .{
            .name = variant.name,
            .bin = executor.getEmittedBin(),
            .max_bytes = variant.max_bytes,
        };

        const install_executor = b.addInstallArtifact(executor, .{
            .dest_dir = .{ .override = .{ .custom = "executors" } },
        });
        executors_step.dependOn(&install_executor.step);
    }

    // C11 guard (item 2.2): the `core` and `full` variants MUST be byte-different.
    // Byte-identical binaries mean plugin gating silently regressed to the
    // pre-2.2 state (every variant compiled all-plugins-on). Runs on
    // `zig build executors` and on every default build (install step).
    {
        var core_bin: ?std.Build.LazyPath = null;
        var full_bin: ?std.Build.LazyPath = null;
        for (executor_artifacts) |art| {
            if (std.mem.eql(u8, art.name, "core")) core_bin = art.bin;
            if (std.mem.eql(u8, art.name, "full")) full_bin = art.bin;
        }
        const guard_mod = stdModule(b, target, optimize, "tools/assert_variants_differ.zig", &.{});
        const guard_exe = b.addExecutable(.{ .name = "assert-variants-differ", .root_module = guard_mod });
        const run_guard = b.addRunArtifact(guard_exe);
        run_guard.addFileArg(core_bin.?);
        run_guard.addFileArg(full_bin.?);
        executors_step.dependOn(&run_guard.step);
        b.getInstallStep().dependOn(&run_guard.step);
    }

    // Per-variant size budget guard (item 4.2 / C7b): each executor WASM must
    // stay under its budget (measured reality + ~10% headroom, declared on the
    // variant table above). The executor ships inside every PNG, so drift here
    // is the costliest — this catches a regression the byte-difference guard
    // cannot (both variants can grow together and still differ).
    {
        const budget_mod = stdModule(b, target, optimize, "tools/assert_executor_budgets.zig", &.{});
        const budget_exe = b.addExecutable(.{ .name = "assert-executor-budgets", .root_module = budget_mod });
        const run_budget = b.addRunArtifact(budget_exe);
        for (executor_artifacts) |art| {
            run_budget.addArg(art.name);
            run_budget.addArg(b.fmt("{d}", .{art.max_bytes}));
            run_budget.addFileArg(art.bin);
        }
        executors_step.dependOn(&run_budget.step);
        b.getInstallStep().dependOn(&run_budget.step);
    }

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

        // Architecture-specific BUILD_TARGET defines for WAMR AOT relocation
        // WAMR needs both BUILD_TARGET_* (preprocessor check) and BUILD_TARGET (string literal)
        const build_target_flag: []const u8 = if (is_aarch64)
            "-DBUILD_TARGET_AARCH64"
        else if (is_x86_64)
            "-DBUILD_TARGET_X86_64"
        else
            "-DBUILD_TARGET_X86_64"; // Fallback

        // BUILD_TARGET must be a string literal for get_current_target() in aot_reloc_*.c
        const build_target_str: []const u8 = if (is_aarch64)
            "-DBUILD_TARGET=\"AARCH64\""
        else if (is_x86_64)
            "-DBUILD_TARGET=\"X86_64\""
        else
            "-DBUILD_TARGET=\"X86_64\""; // Fallback

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
            build_target_flag,
            build_target_str, // String literal for get_current_target()
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

        linkWamr(cli_module, lib, dep);

        break :blk lib;
    } else null;

    // Create build options with embedded WASM
    // Note: AOT is disabled because embedded AOT doesn't work well
    // (read-only memory can't be mmap'd for execution)
    const npm_version = npmPackageVersion(b);
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", npm_version);
    build_options.addOption(bool, "has_embedded_wasm", true);
    build_options.addOption(bool, "has_embedded_aot", false);
    build_options.addOption(bool, "has_wamr", wamr_dep != null);
    cli_module.addImport("build_options", build_options.createModule());

    // Embedded so the CLI works from any directory (bundle command, browser
    // payloads, and the WAMR interpreter all read these).
    addExecutorBlobs(b, cli_module, wasm.getEmittedBin(), executor_artifacts);

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
    // | png          | 91    | PNG encoding/embedding         |
    // | bytecode     | 147   | Format, opcodes, emitter, etc. |
    // | reflect      | 9     | WGSL shader reflection         |
    // | executor     | 114   | Dispatcher, mock_gpu, etc.     |
    // | sjon         | —     | SJON host: schema + emitter    |
    // | sjon-golden  | 74    | Frozen MockGPU call-log traces |
    // | sjon-invalid | 9     | Validator-rejection negatives  |
    // (These counts rot — the live source is `test-standalone --summary all`.)
    //
    // (The legacy .pngine dsl-frontend/backend/complete modules were deleted in
    // Phase 5 B3 and the .pbsf assembler was retired after it; the SJON host
    // carries all source-frontend coverage now.)
    //
    // Usage:
    //   zig build test-standalone   # Run all standalone modules (~3s)
    //   zig build test-types        # Just types
    //   zig build test-png          # Just png
    //   zig build test-bytecode     # Just bytecode
    //   zig build test-sjon         # Just SJON host (schema + emitter)
    //   zig build test-sjon-golden  # Just golden-trace regression
    //   zig build test-reflect      # Just reflect
    //   zig build test-executor     # Just executor

    const standalone_step = b.step("test-standalone", "Run standalone module tests in parallel (~2s)");

    // Types module
    const types_test_step = b.step("test-types", "Run types module tests");
    const types_test_mod = stdModule(b, target, optimize, "src/types/main.zig", &.{});
    addStandaloneTest(b, standalone_step, types_test_step, "types", types_test_mod);

    // PNG module (encoding/embedding)
    const png_test_step = b.step("test-png", "Run PNG module tests");
    const png_test_mod = stdModule(b, target, optimize, "src/png/main.zig", &.{});
    addStandaloneTest(b, standalone_step, png_test_step, "png", png_test_mod);

    // (The legacy test-dsl-frontend and test-dsl-backend step blocks were
    // deleted in Phase 5 B3 along with src/dsl/.)

    // Bytecode module (format, opcodes, emitter, tables) - uses types module import
    const bytecode_step = b.step("test-bytecode", "Run bytecode module tests");
    const bytecode_mod = stdModule(b, target, optimize, "src/bytecode/standalone.zig", &.{
        .{ .name = "types", .module = types_module },
    });
    addStandaloneTest(b, standalone_step, bytecode_step, "bytecode", bytecode_mod);

    // Dedicated tests (moved to tests/zig/bytecode/)
    const bytecode_dedicated_mod = stdModule(b, target, optimize, "tests/zig/test_bytecode.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
    });
    addStandaloneTest(b, standalone_step, bytecode_step, "bytecode-dedicated", bytecode_dedicated_mod);

    // Reflect module (WGSL shader reflection via native wgslender)
    const reflect_step = b.step("test-reflect", "Run reflect module tests");
    const reflect_standalone_mod = stdModule(b, target, optimize, "src/reflect/standalone.zig", &.{
        .{ .name = "wgslender", .module = wgslender_mod },
    });

    addStandaloneTest(b, standalone_step, reflect_step, "reflect", reflect_standalone_mod);

    // Executor module (dispatcher, mock_gpu, command_buffer) - uses bytecode module import
    const executor_step = b.step("test-executor", "Run executor module tests");
    const executor_mod = stdModule(b, target, optimize, "src/executor/standalone.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "plugins", .module = pluginDefaultModule(b) },
    });
    addStandaloneTest(b, standalone_step, executor_step, "executor", executor_mod);

    // Zip module (format, reader, writer)
    const zip_step = b.step("test-zip", "Run zip module tests");
    const zip_mod = stdModule(b, target, optimize, "src/zip.zig", &.{});
    addStandaloneTest(b, standalone_step, zip_step, "zip", zip_mod);

    // Dedicated zip tests (moved to tests/zig/zip/)
    const zip_dedicated_mod = stdModule(b, target, optimize, "tests/zig/test_zip.zig", &.{
        .{ .name = "zip", .module = zip_mod },
    });
    addStandaloneTest(b, standalone_step, zip_step, "zip-dedicated", zip_dedicated_mod);

    // (The legacy test-dsl-complete step + dsl_complete_mod were deleted in
    // Phase 5 B3; the SJON golden gate carries the emitter regression coverage.)

    // ========================================================================
    // SJON host — PRODUCTION module (Phase 3, Commit 1)
    // ========================================================================
    // Makes the proven `.sjon` compiler importable by the CLI/WASM, not just the
    // test harness. Rooted at Compiler.zig. CRITICAL: it reuses the SAME bytecode/
    // executor instances `lib_module` uses (`bytecode_module` / `lib_executor_module`,
    // NOT the standalone `bytecode_mod` / `executor_mod`), so dsl_sjon's
    // `format.PluginSet` / `Builder` types are identical to the legacy `dsl` path's
    // across the CLI boundary. The four vendored backend sub-modules are declared
    // here (hoisted out of the test-sjon block below) and shared with it — they
    // import only `types`/std, so no bytecode-instance conflict.
    const vendored_mods = dslSjonVendored(b, target, optimize, types_module);
    const dsl_sjon_mod = addDslSjonModule(b, target, optimize, "src/dsl_sjon/Compiler.zig", .{
        .types = types_module,
        .bytecode = bytecode_module,
        .reflect = reflect_module,
        .executor = lib_executor_module,
        .sjon = sjon_mod,
        .vendored = vendored_mods,
    });
    lib_module.addImport("dsl_sjon", dsl_sjon_mod);

    // ========================================================================
    // SJON host module (schema + new emitter) — standalone tests
    // ========================================================================
    // Standalone wiring (types/bytecode/reflect/executor) plus the `sjon` module
    // and the embedded `schema/pngine.sjon` manifest. Joins `test-standalone` so
    // the full matrix stays green.
    const sjon_step = b.step("test-sjon", "Run SJON host/emitter tests");
    // Note the DIFFERENT root (complete.zig) and the DIFFERENT bytecode/executor
    // instances (the standalone `*_mod`, not the lib's `*_module`) — which is why
    // `addDslSjonModule` takes both as parameters. `vendored_mods` is the same set
    // the production block built: those four import only `types`/std + the mesh
    // blobs, so sharing them causes no bytecode-instance skew.
    const sjon_test_mod = addDslSjonModule(b, target, optimize, "src/dsl_sjon/complete.zig", .{
        .types = types_module,
        .bytecode = bytecode_mod,
        .reflect = reflect_module,
        .executor = executor_mod,
        .sjon = sjon_mod,
        .vendored = vendored_mods,
    });
    addStandaloneTest(b, standalone_step, sjon_step, "sjon", sjon_test_mod);

    // descriptor_encoder is a leaf module — imported by the SJON host but never the
    // ROOT of a test compilation, so its `test` blocks (the byte-layout unit tests
    // for every descriptor kind, incl. the §5.2 sampler field set) never ran. Give
    // it its own standalone target so those encoder tests actually execute.
    const desc_enc_step = b.step("test-descriptor-encoder", "Run descriptor-encoder byte-layout unit tests");
    addStandaloneTest(b, standalone_step, desc_enc_step, "descriptor-encoder", vendored_mods.descriptor_encoder);

    // Same leaf-module trap (§257/§258): wasm_data, wgsl_scan, and shapes all
    // carry test blocks but were never test roots — dead tests. One standalone
    // target each keeps them in the matrix.
    const wasm_data_step = b.step("test-wasm-data", "Run data-WASM parser unit tests");
    addStandaloneTest(b, standalone_step, wasm_data_step, "wasm-data", vendored_mods.wasm_data);
    const wgsl_scan_step = b.step("test-wgsl-scan", "Run WGSL feature-scan unit tests");
    addStandaloneTest(b, standalone_step, wgsl_scan_step, "wgsl-scan", vendored_mods.wgsl_scan);
    const shapes_step = b.step("test-shapes", "Run compile-time shape-generator unit tests");
    addStandaloneTest(b, standalone_step, shapes_step, "shapes", vendored_mods.shapes);

    // Flat (pNGf) writer refusal conformance (Arc-3 §4.2). `src/cli/flat.zig` is
    // imported by the CLI exe only, so its behavior never rode a test root (the
    // leaf-module gotcha). Expose it as a module and give it a test root that
    // compiles real examples through `flattenPayload` to prove the mini-refusal.
    const flat_module = b.createModule(.{
        .root_source_file = b.path("src/cli/flat.zig"),
        .target = target,
        .optimize = optimize,
    });
    flat_module.addImport("pngine", lib_module);
    const flat_step = b.step("test-flat", "Run pNGf flat-writer refusal conformance tests");
    const flat_test_mod = stdModule(b, target, optimize, "tests/zig/flat/flat_conformance_test.zig", &.{
        .{ .name = "pngine", .module = lib_module },
        .{ .name = "flat", .module = flat_module },
    });
    flat_test_mod.addAnonymousImport("simple_triangle_sjon", .{
        .root_source_file = b.path("examples/simple_triangle.sjon"),
    });
    flat_test_mod.addAnonymousImport("rotating_cube_sjon", .{
        .root_source_file = b.path("examples/rotating_cube.sjon"),
    });
    addStandaloneTest(b, standalone_step, flat_step, "flat", flat_test_mod);

    // The init/frame split is answered by TWO writers over the same MockGPU call
    // log — flat.zig above and js_codegen.zig — with two different rules, and
    // they must agree about the invariant underneath them (LEAK-08-D). Both are
    // reached through `src/cli/writers.zig`: rooting each as its own module in
    // one compilation would claim their shared `call_split.zig` twice, which Zig
    // refuses (a file belongs to exactly one module). Its own doc comment says
    // so; the shipping CLI does not import it.
    const writers_module = b.createModule(.{
        .root_source_file = b.path("src/cli/writers.zig"),
        .target = target,
        .optimize = optimize,
    });
    writers_module.addImport("pngine", lib_module);
    const split_step = b.step("test-split", "Run init/frame split agreement tests (flat vs --html)");
    const split_test_mod = stdModule(b, target, optimize, "tests/zig/cli/split_agreement_test.zig", &.{
        .{ .name = "pngine", .module = lib_module },
        .{ .name = "writers", .module = writers_module },
    });
    addStandaloneTest(b, standalone_step, split_step, "split", split_test_mod);

    // types_gen: pure .d.ts string formatting over the uniform table. Its tests
    // were reachable only through `cli_test_module` (which depends on the WASM
    // build), so they ran only in the ~7-minute `zig build test` — far too slow
    // a lane for what they check. It touches nothing but format/string_table/
    // uniform_table, all of which `bytecode_module` re-exports, so it can be
    // rooted directly. The import is named "pngine" because that is the name
    // src/cli/types_gen.zig asks for; this is the same subset, not the full lib.
    const types_gen_step = b.step("test-types-gen", "Run TypeScript type-generator tests");
    const types_gen_mod = stdModule(b, target, optimize, "src/cli/types_gen.zig", &.{
        .{ .name = "pngine", .module = bytecode_module },
    });
    addStandaloneTest(b, standalone_step, types_gen_step, "types-gen", types_gen_mod);

    // arg_reader: same story — pure std (the module is deliberately stderr-free
    // and dependency-free), yet its tests were also stuck behind the WASM build.
    const arg_reader_step = b.step("test-arg-reader", "Run CLI argument-reader tests");
    const arg_reader_mod = stdModule(b, target, optimize, "src/cli/arg_reader.zig", &.{});
    addStandaloneTest(b, standalone_step, arg_reader_step, "arg-reader", arg_reader_mod);

    // stdio: the `-` convention. Same reasoning as arg_reader — the sniffing
    // table and the tty predicate are pure std, so they do not belong behind a
    // WASM build. The impure half (real stdin, real fd 1) is covered by the
    // spawned `test-cli-pipe` harness instead.
    const cli_stdio_step = b.step("test-cli-stdio", "Run CLI stdin/stdout sniffing + guard unit tests");
    const cli_stdio_mod = stdModule(b, target, optimize, "src/cli/stdio.zig", &.{});
    addStandaloneTest(b, standalone_step, cli_stdio_step, "cli-stdio", cli_stdio_mod);

    // WAMR wrapper. It has always had inline tests and they have never RUN:
    // the module is a leaf, rooted only by the desktop-viewer executable, and a
    // Zig test binary discovers tests in compilation roots. So the buffer
    // alignment LEAK-09 D got wrong had no gate at all. Built with has_wamr
    // FALSE — the same configuration this checkout compiles it in, since the
    // `wamr` dependency is lazy and unfetched — which is exactly why the
    // allocator agreement is exercised through the helper pair rather than
    // through `loadModule`, whose every entry point returns NotAvailable first.
    const wamr_step = b.step("test-wamr", "Run WAMR wrapper tests (buffer alignment; no WAMR needed)");
    const wamr_test_options = b.addOptions();
    wamr_test_options.addOption(bool, "has_wamr", false);
    const wamr_test_mod = stdModule(b, target, optimize, "src/cli/inspect/wamr.zig", &.{
        .{ .name = "build_options", .module = wamr_test_options.createModule() },
    });
    addStandaloneTest(b, standalone_step, wamr_step, "wamr", wamr_test_mod);

    // SJON cross-compile gate: the host must build for wasm32-freestanding with
    // link_libc=false (no libwasmtime, no libc) so Phase 3's in-browser
    // compiler can embed it. Isolated from the real wasm_compiler wiring.
    const wasm_sjon_mod = b.dependency("sjon", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .@"plugin-exec" = false,
    }).module("sjon");
    const sjon_wasm_smoke_mod = b.createModule(.{
        .root_source_file = b.path("src/dsl_sjon/wasm_smoke.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
    });
    sjon_wasm_smoke_mod.addImport("sjon", wasm_sjon_mod);
    const sjon_wasm_smoke = b.addObject(.{
        .name = "sjon-wasm-smoke",
        .root_module = sjon_wasm_smoke_mod,
    });
    const sjon_wasm_step = b.step("test-sjon-wasm", "Compile SJON host for wasm32-freestanding");
    sjon_wasm_step.dependOn(&sjon_wasm_smoke.step);
    // Joined to test-standalone (R1-04 C). It was reachable only by typing the
    // step name, which meant it never ran — a cross-compile gate nobody runs is
    // not a gate. `addObject`, not a test binary, so it cannot go through
    // `addStandaloneTest`: depend on the compile step directly.
    standalone_step.dependOn(&sjon_wasm_smoke.step);

    // ========================================================================
    // Shared SJON fixture-name lists — the golden regen exe and the golden gate
    // (below) cover whatever `examples/` holds, GLOBBED rather than enumerated
    // so a new example cannot ship without golden coverage. The same names are
    // written to a generated source the harness imports, so build.zig and
    // `tests/zig/sjon_golden.zig` cannot disagree. (The `.pngine` ↔ `.sjon`
    // parity oracle that also used these lists was retired in Phase 5 B3 along
    // with the legacy frontend; the golden traces — frozen while parity still
    // held — now carry the net.)
    const sjon_root_fixtures = sjonFixtureNames(b, "examples");
    const sjon_sample_fixtures = sjonFixtureNames(b, "examples/samples");
    const fixture_list = generateFixtureList(b, sjon_root_fixtures, sjon_sample_fixtures);

    // ========================================================================
    // SJON golden-trace regression net (Phase 5 Stage A2) — the coverage that
    // SURVIVES the legacy cut. Two artifacts share tests/zig/sjon_golden.zig:
    //   • test-sjon-golden (addTest, joined to test-standalone): the gate. Embeds
    //     the committed tests/zig/golden/*.trace and asserts the SJON emitter
    //     reproduces each byte-for-byte. Imports ONLY dsl_sjon/bytecode/executor
    //     (never `dsl`), so it keeps compiling after Stage B deletes the frontend.
    //   • gen-goldens (addExecutable): rewrites the traces (`-- --regen`). The exe
    //     build skips `test` blocks, so it does NOT depend on the goldens existing
    //     — which bootstraps the very first regen.
    // Both reuse the parity fixture lists, so the golden set == the parity set.
    const golden_gen_mod = stdModule(b, target, optimize, "tests/zig/sjon_golden.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "executor", .module = executor_mod },
        .{ .name = "dsl_sjon", .module = sjon_test_mod },
    });
    const golden_test_mod = stdModule(b, target, optimize, "tests/zig/sjon_golden.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "executor", .module = executor_mod },
        .{ .name = "dsl_sjon", .module = sjon_test_mod },
    });
    for ([_]struct { dir: []const u8, names: []const []const u8 }{
        .{ .dir = "examples", .names = sjon_root_fixtures },
        .{ .dir = "examples/samples", .names = sjon_sample_fixtures },
    }) |group| {
        for (group.names) |name| {
            const src = b.path(b.fmt("{s}/{s}.sjon", .{ group.dir, name }));
            const trace = b.path(b.fmt("tests/zig/golden/{s}.trace", .{name}));
            golden_gen_mod.addAnonymousImport(b.fmt("{s}_sjon", .{name}), .{ .root_source_file = src });
            golden_test_mod.addAnonymousImport(b.fmt("{s}_sjon", .{name}), .{ .root_source_file = src });
            golden_test_mod.addAnonymousImport(b.fmt("{s}_golden", .{name}), .{ .root_source_file = trace });
        }
    }
    // frame-1 goldens (sjon_golden.zig `frame1_fixtures`): gate-only imports —
    // the gen exe skips test blocks, which bootstraps the first --regen.
    golden_test_mod.addAnonymousImport("boids_frame1_golden", .{ .root_source_file = b.path("tests/zig/golden/boids.frame1.trace") });
    golden_test_mod.addAnonymousImport("webgpu_particle_life_frame1_golden", .{ .root_source_file = b.path("tests/zig/golden/webgpu_particle_life.frame1.trace") });
    // Minified goldens (sjon_golden.zig `minified_fixtures`): same gate-only
    // shape. These pin WGSL minifier OUTPUT — the trace's `code=len=N fnv=…`
    // moves on any change to it, including an accidental entry-point rename.
    for ([_][]const u8{ "uniform_access", "boids", "rotating_cube", "pass_shader_art" }) |name| {
        golden_test_mod.addAnonymousImport(
            b.fmt("{s}_min_golden", .{name}),
            .{ .root_source_file = b.path(b.fmt("tests/zig/golden/{s}.min.trace", .{name})) },
        );
    }
    golden_gen_mod.addAnonymousImport("fixture_list", .{ .root_source_file = fixture_list });
    golden_test_mod.addAnonymousImport("fixture_list", .{ .root_source_file = fixture_list });
    const golden_step = b.step("test-sjon-golden", "Run SJON golden-trace regression tests");
    addStandaloneTest(b, standalone_step, golden_step, "sjon-golden", golden_test_mod);
    const golden_gen_exe = b.addExecutable(.{ .name = "pngine-gen-goldens", .root_module = golden_gen_mod });
    const run_gen_goldens = b.addRunArtifact(golden_gen_exe);
    if (b.args) |fwd| run_gen_goldens.addArgs(fwd);
    const gen_goldens_step = b.step("gen-goldens", "Regenerate tests/zig/golden/*.trace (pass -- --regen to write)");
    gen_goldens_step.dependOn(&run_gen_goldens.step);

    // ========================================================================
    // SJON invalid-negatives gate (Phase 5 Stage A3) — the `.sjon` replacement
    // for the legacy `examples/invalid/` validator-rejection coverage. Asserts
    // the SJON compiler REJECTS each ported negative (with the right error class)
    // under strict validation. Imports ONLY dsl_sjon (never `dsl`), so it keeps
    // gating after Stage B deletes the legacy frontend.
    const sjon_invalid_mod = stdModule(b, target, optimize, "tests/zig/sjon_invalid.zig", &.{
        .{ .name = "dsl_sjon", .module = sjon_test_mod },
    });
    inline for (.{ "bad_wgsl_syntax", "missing_entry_point", "buffer_too_small", "missing_bind_group", "unaligned_uniform", "bad_scissor_rect", "uniform_too_small_for_struct", "missing_uniform_bind", "address_space_mismatch", "workgroup_too_large", "bind_kind_mismatch", "vertex_location_unbound", "texture_sample_type_mismatch", "sampler_comparison_mismatch", "vertex_format_mismatch", "fragment_output_type_mismatch", "fragment_output_unbound", "pass_attachment_count_mismatch", "pass_attachment_format_mismatch", "pass_depth_missing_in_pipeline", "pass_depth_missing_in_pass", "pass_depth_format_mismatch", "pass_resolve_format_mismatch", "pass_sample_count_mismatch", "storage_texture_format_mismatch", "too_many_passes", "too_many_bundles", "sampler_anisotropy_out_of_range", "texture_dimension_out_of_range", "texture_view_dimension_out_of_range", "pipeline_layout_dangling_bgl", "primitive_strip_index_format", "workgroup_512_no_limits", "bind_offset_without_buffer", "bind_slice_past_end", "bind_offset_at_end", "bundle_ref_lowered", "too_many_wasm_args", "unknown_wasm_arg", "pass_mixed_stages", "pass_no_entry_point", "pass_graph_empty", "pass_too_many_entries", "init_workgroups_unresolved", "size_names_a_define", "override_no_default", "override_no_default_compute", "constant_unknown_override", "constant_type_mismatch", "constant_conflict", "pool_overflow", "pool_expression_overflow", "shape_sphere_zero", "shape_cone_bomb", "define_overflow", "pass_shader_name_collision" }) |name| {
        sjon_invalid_mod.addAnonymousImport(name ++ "_invalid", .{ .root_source_file = b.path("examples/invalid/" ++ name ++ ".sjon") });
    }
    const sjon_invalid_step = b.step("test-sjon-invalid", "Run SJON invalid-negatives rejection tests");
    addStandaloneTest(b, standalone_step, sjon_invalid_step, "sjon-invalid", sjon_invalid_mod);

    // ========================================================================
    // OOM-injection sweep (LEAK-10). The negatives above prove the compile path
    // is leak-tight on every INPUT-reachable path; this one proves it on the
    // ALLOCATION-FAILURE path — the one the editor's per-keystroke
    // `wasm_allocator` takes, in linear memory that never shrinks. Rooted at its
    // own harness so the sweep's per-iteration DebugAllocator never shares state
    // with `std.testing.allocator`.
    const sjon_oom_mod = stdModule(b, target, optimize, "tests/zig/sjon_oom.zig", &.{
        .{ .name = "dsl_sjon", .module = sjon_test_mod },
        .{ .name = "bytecode", .module = bytecode_mod },
    });
    inline for (.{ "pass_shader_art", "pipeline_constants", "rotating_cube" }) |name| {
        sjon_oom_mod.addAnonymousImport(name ++ "_sjon", .{ .root_source_file = b.path("examples/" ++ name ++ ".sjon") });
    }
    const sjon_oom_step = b.step("test-sjon-oom", "Run the compile-pipeline OOM-injection sweep");
    addStandaloneTest(b, standalone_step, sjon_oom_step, "sjon-oom", sjon_oom_mod);

    // ========================================================================
    // Native GPU render tests + snapshot/coverage gates (Phase 2 + 3 of the
    // headless render keystone). Two artifacts share tests/zig/render/render_test.zig:
    //   • test-render (addTest): structural pixel assertions + the snapshot gate
    //     (render in-process, png.decode a committed reference PNG, png.compare
    //     with a per-fixture tolerance). Skips if no GPU adapter is available.
    //   • gen-render-snapshots (addExecutable): default mode = the COVERAGE gate
    //     (render every golden fixture as an ISOLATED `pngine --frame` child, diff
    //     the committed coverage.txt, exit 1 on drift); `-- --regen` rewrites the
    //     snapshot PNGs + coverage.txt. Subprocess isolation is mandatory: ~half
    //     the fixtures still SIGABRT inside wgpu-native, which would kill an
    //     in-process harness. The exe build skips `test` blocks, so it doesn't
    //     need the committed snapshots to exist — bootstrapping the first regen.
    //     Mirrors the gen-goldens / schema-export gate/regen split.
    // DELIBERATELY NOT in test-standalone/test: links wgpu-native, needs a real
    // adapter, and (for coverage) shells out to the built CLI. On a GPU-less build
    // both steps fail clean with a rebuild hint instead of compiling the stub.
    const render_test_step = b.step("test-render", "Run native GPU render + snapshot tests (requires -Dgpu-native)");
    const gen_render_step = b.step("gen-render-snapshots", "Coverage gate over all fixtures; `-- --regen` rewrites snapshots + coverage.txt");
    if (has_wgpu_native) {
        // Snapshot `.sjon` sources — rendered in-process by BOTH the test binary
        // (gate) and the regen exe. (embed-key, path) pairs; sample paths differ.
        const render_src_imports = .{
            .{ "simple_triangle_sjon", "examples/simple_triangle.sjon" },
            .{ "pass_shader_art_sjon", "examples/pass_shader_art.sjon" },
            .{ "moving_triangle_sjon", "examples/moving_triangle.sjon" },
            .{ "webgpu_hello_triangle_sjon", "examples/webgpu_hello_triangle.sjon" },
            .{ "pass_compute_rainbow_sjon", "examples/pass_compute_rainbow.sjon" },
            .{ "sample_01_gradient_background_sjon", "examples/samples/01_gradient_background.sjon" },
            .{ "sample_02_shader_art_sjon", "examples/samples/02_shader_art.sjon" },
            .{ "rotating_cube_sjon", "examples/rotating_cube.sjon" },
            .{ "teapot_sjon", "examples/teapot.sjon" },
            .{ "pass_postprocess_sjon", "examples/pass_postprocess.sjon" },
            .{ "pass_bloom_sjon", "examples/pass_bloom.sjon" },
            .{ "webgpu_deferred_rendering_sjon", "examples/webgpu_deferred_rendering.sjon" },
            .{ "simple_triangle_msaa_sjon", "examples/simple_triangle_msaa.sjon" },
            .{ "sample_11_simple_lighting_sjon", "examples/samples/11_simple_lighting.sjon" },
            .{ "test_stencil_sjon", "examples/test_stencil.sjon" },
            .{ "test_stencil_back_sjon", "examples/test_stencil_back.sjon" },
            .{ "test_depth_clear_sjon", "examples/test_depth_clear.sjon" },
            .{ "webgpu_shadow_mapping_sjon", "examples/webgpu_shadow_mapping.sjon" },
            .{ "sample_20_particle_fountain_sjon", "examples/samples/20_particle_fountain.sjon" },
            .{ "webgpu_indirect_draw_sjon", "examples/webgpu_indirect_draw.sjon" },
            .{ "webgpu_indirect_dispatch_sjon", "examples/webgpu_indirect_dispatch.sjon" },
            .{ "webgpu_blend_constant_sjon", "examples/webgpu_blend_constant.sjon" },
            .{ "webgpu_bgl_resources_sjon", "examples/webgpu_bgl_resources.sjon" },
            .{ "webgpu_bgl_storage_texture_sjon", "examples/webgpu_bgl_storage_texture.sjon" },
            .{ "webgpu_compute_512_sjon", "examples/webgpu_compute_512.sjon" },
            .{ "test_copy_texture_sjon", "examples/test_copy_texture.sjon" },
            .{ "test_copy_buffer_sjon", "examples/test_copy_buffer.sjon" },
            .{ "test_viewport_sjon", "examples/test_viewport.sjon" },
            .{ "pipeline_constants_sjon", "examples/pipeline_constants.sjon" },
        };
        // Committed reference PNGs — embedded by the TEST binary only (the regen
        // exe writes them, so it must compile before they exist).
        const render_snapshot_labels = .{
            "simple_triangle",               "moving_triangle_t0",
            "moving_triangle_t1",            "pass_shader_art",
            "webgpu_hello_triangle",         "pass_compute_rainbow",
            "sample_01_gradient_background", "sample_02_shader_art",
            "rotating_cube",                 "teapot",
            "pass_postprocess",              "pass_bloom",
            "webgpu_deferred_rendering",     "simple_triangle_msaa",
            "sample_11_simple_lighting",     "test_stencil",
            "test_stencil_back",             "test_depth_clear",
            "webgpu_shadow_mapping",         "webgpu_indirect_draw",
            "webgpu_indirect_dispatch",      "webgpu_blend_constant",
            "webgpu_bgl_resources",          "webgpu_bgl_storage_texture",
            "pipeline_constants",
        };

        // --- test-render: structural + snapshot gate (in-process) ---
        // Imports `pngine` (lib_module), which already carries the wgpu-native
        // link settings — so the test binary links the backend transitively.
        const render_test_mod = stdModule(b, target, optimize, "tests/zig/render/render_test.zig", &.{
            .{ .name = "pngine", .module = lib_module },
            // The shared malformed corpus, so the NATIVE backend is proven against
            // the same hostile bytes the dispatcher/wasm_entry harnesses use rather
            // than a second hand-maintained copy of them. (R1-01)
            //
            // `bytecode_module`, NOT the standalone `bytecode_mod`: the corpus and
            // `pngine` end up in one binary here, and two modules rooted at the
            // same file are a "file exists in modules 'bytecode' and 'bytecode0'"
            // compile error. The standalone harnesses have no such constraint.
            .{ .name = "malformed_corpus", .module = stdModule(b, target, optimize, "tests/zig/malformed/corpus.zig", &.{
                .{ .name = "bytecode", .module = bytecode_module },
            }) },
        });
        inline for (render_src_imports) |imp|
            render_test_mod.addAnonymousImport(imp[0], .{ .root_source_file = b.path(imp[1]) });
        inline for (render_snapshot_labels) |label|
            render_test_mod.addAnonymousImport(label ++ "_snapshot", .{ .root_source_file = b.path("tests/zig/render/snapshots/" ++ label ++ ".png") });
        // The SAME globbed list the golden gate imports (R1-04 A). The coverage
        // table used to be hand-typed here and had drifted to 111 of 116.
        render_test_mod.addAnonymousImport("fixture_list", .{ .root_source_file = fixture_list });
        const render_test = b.addTest(.{ .name = "render", .root_module = render_test_mod });
        const run_render_test = b.addRunArtifact(render_test);
        render_test_step.dependOn(&run_render_test.step);

        // --- gen-render-snapshots: coverage gate (default) / regen (-- --regen) ---
        const render_gen_mod = stdModule(b, target, optimize, "tests/zig/render/render_test.zig", &.{
            .{ .name = "pngine", .module = lib_module },
        });
        inline for (render_src_imports) |imp|
            render_gen_mod.addAnonymousImport(imp[0], .{ .root_source_file = b.path(imp[1]) });
        render_gen_mod.addAnonymousImport("fixture_list", .{ .root_source_file = fixture_list });
        const render_gen_exe = b.addExecutable(.{ .name = "pngine-gen-render", .root_module = render_gen_mod });
        const run_render_gen = b.addRunArtifact(render_gen_exe);
        run_render_gen.addArtifactArg(cli); // argv[1] = built pngine path (children shell out to it)
        if (b.args) |fwd| run_render_gen.addArgs(fwd); // argv[2..] = --regen (optional)
        // It renders live (one subprocess per fixture + file writes), so it must always re-run
        // AND its stderr must reach the terminal — otherwise the drift diagnostic is
        // swallowed (infer_from_args → .ignore unless side effects are declared).
        run_render_gen.has_side_effects = true;
        gen_render_step.dependOn(&run_render_gen.step);

        // --- native lifetime balance: the wgpu refcount ledger (LEAK-01) ---
        // Separate root from render_test.zig because it asserts on process-global
        // counters: sharing a binary with the snapshot tests would let any
        // fixture's renders drift the ledger between a baseline and its
        // comparison. Rides `test-render` (same -Dgpu-native requirement, same
        // adapter, ~1s) so the native gate stays one command.
        const balance_mod = stdModule(b, target, optimize, "tests/zig/render/native_frame_balance_test.zig", &.{
            .{ .name = "pngine", .module = lib_module },
        });
        inline for (.{
            .{ "simple_triangle_sjon", "examples/simple_triangle.sjon" },
            .{ "simple_triangle_msaa_sjon", "examples/simple_triangle_msaa.sjon" },
            .{ "webgpu_deferred_rendering_sjon", "examples/webgpu_deferred_rendering.sjon" },
            // The valid-document reproduction for the create_texture_view guard
            // hole: one texture + one explicit (texture-view …) bound into the
            // pass, so a per-frame bytecode replay re-creates the view.
            .{ "texture_view_sjon", "examples/texture_view.sjon" },
        }) |imp|
            balance_mod.addAnonymousImport(imp[0], .{ .root_source_file = b.path(imp[1]) });
        const balance_test = b.addTest(.{ .name = "native-balance", .root_module = balance_mod });
        render_test_step.dependOn(&b.addRunArtifact(balance_test).step);
    } else {
        const fail = b.addFail(
            "the native render gates require the wgpu-native backend. Rebuild on a " ++
                "macOS host with the vendored lib (scripts/download-wgpu-native.sh); " ++
                "npm binaries are GPU-less by design.",
        );
        render_test_step.dependOn(&fail.step);
        gen_render_step.dependOn(&fail.step);
    }

    // ========================================================================
    // Schema export — generate the editor-facing TS `.d.ts` + JSON-Schema from
    // `schema/pngine.sjon` via SJON's `SchemaExport`. The tool embeds the SAME
    // `pngine_schema` bytes the compiler validates against, so the artifacts
    // can't drift from the live schema. Default mode diffs the committed
    // `schema/pngine.{d.ts,schema.json}` against a fresh export (exit 1 on
    // drift) — joined to `standalone_step` as a build-time gate. `--regen`
    // (forwarded via `-- --regen`) rewrites them after an intentional schema
    // edit. Self-contained native tool: not imported by `dsl_sjon`/the wasm
    // compiler, so the freestanding surface (`test-sjon-wasm`) is untouched.
    const schema_export_mod = stdModule(b, target, optimize, "tools/schema_export.zig", &.{
        .{ .name = "sjon", .module = sjon_mod },
    });
    schema_export_mod.addAnonymousImport("pngine_schema", .{
        .root_source_file = b.path("schema/pngine.sjon"),
    });
    const schema_export_exe = b.addExecutable(.{
        .name = "pngine-schema-export",
        .root_module = schema_export_mod,
    });
    const run_schema_export = b.addRunArtifact(schema_export_exe);
    if (b.args) |fwd| run_schema_export.addArgs(fwd);
    const schema_export_step = b.step("schema-export", "Verify schema/pngine.{d.ts,schema.json} match the schema (pass -- --regen to write)");
    schema_export_step.dependOn(&run_schema_export.step);
    standalone_step.dependOn(&run_schema_export.step);

    // Dedicated executor tests (moved to tests/zig/executor/)
    // Note: executor_test.zig needs DescriptorEncoder. Phase 5 B3 deleted the
    // legacy `dsl-complete` module, so it now imports the vendored encoder
    // (src/dsl_sjon/descriptor_encoder.zig, the byte-identical copy).
    const executor_dedicated_mod = stdModule(b, target, optimize, "tests/zig/test_executor.zig", &.{
        .{ .name = "executor", .module = executor_mod },
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "descriptor_encoder", .module = vendored_mods.descriptor_encoder },
    });
    addStandaloneTest(b, standalone_step, executor_step, "executor-dedicated", executor_dedicated_mod);

    // Wire-conformance for the SHIPPING executor (src/wasm_entry.zig), compiled
    // for the NATIVE target. Only linkable since item 1.1 (§221) gated off the
    // `env.log` import by default (`debug_log` off) — with the log sites pruned
    // there is no `extern "env"` symbol for a native linker to resolve. This
    // proves wasm_entry's hand-written skipOpcodeParams + executeOpcode consume
    // the exact operand bytes the emitter produced, for every opcode — the same
    // net wire_conformance_test.zig runs against the reference interpreter.
    // Plugins default-on (the all-on default module), so every handler runs.
    const wasm_entry_step = b.step("test-wasm-entry", "Run wasm_entry (shipping executor) wire-conformance tests");
    const wasm_entry_native_mod = stdModule(b, target, optimize, "src/wasm_entry.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "wasm_config", .module = wasm_default_config.createModule() },
        .{ .name = "plugins", .module = pluginDefaultModule(b) },
    });
    const wasm_entry_test_mod = stdModule(b, target, optimize, "tests/zig/test_wasm_entry.zig", &.{
        .{ .name = "wasm_entry", .module = wasm_entry_native_mod },
        .{ .name = "bytecode", .module = bytecode_mod },
    });
    addStandaloneTest(b, standalone_step, wasm_entry_step, "wasm-entry", wasm_entry_test_mod);

    // Same wire-conformance fixtures over a CORE-ONLY executor (every optional
    // plugin off). Here executeOpcode routes every render/compute/texture/wasm
    // opcode through its plugin-disabled `else` arm — which item 2.1 unified onto
    // wire_schema.skipParams. This proves those disabled arms consume exactly the
    // instruction, the same guarantee the all-on build gives the enabled arms.
    const wasm_entry_core_mod = stdModule(b, target, optimize, "src/wasm_entry.zig", &.{
        .{ .name = "bytecode", .module = bytecode_mod },
        .{ .name = "wasm_config", .module = wasm_default_config.createModule() },
        .{ .name = "plugins", .module = pluginCoreModule(b) },
    });
    const wasm_entry_core_test_mod = stdModule(b, target, optimize, "tests/zig/test_wasm_entry.zig", &.{
        .{ .name = "wasm_entry", .module = wasm_entry_core_mod },
        .{ .name = "bytecode", .module = bytecode_mod },
    });
    addStandaloneTest(b, standalone_step, wasm_entry_step, "wasm-entry-core", wasm_entry_core_test_mod);

    // Ancillary module (MVP matrix generator for WASM)
    const ancillary_step = b.step("test-ancillary", "Run ancillary WASM module tests");
    const ancillary_mod = stdModule(b, target, optimize, "src/ancillary/mvp.zig", &.{});
    addStandaloneTest(b, standalone_step, ancillary_step, "ancillary", ancillary_mod);

    // Make 'zig build test' also run standalone dedicated tests
    test_step.dependOn(standalone_step);

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
    addExecutorBlobs(b, cli_test_module, wasm.getEmittedBin(), executor_artifacts);
    if (wamr_lib) |lib| linkWamr(cli_test_module, lib, wamr_dep);

    const cli_tests = b.addTest(.{
        .root_module = cli_test_module,
    });
    cli_tests.step.dependOn(&wasm.step);
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);

    // Dedicated CLI tests (moved to tests/zig/cli/)
    const cli_dedicated_mod = stdModule(b, target, optimize, "tests/zig/test_cli.zig", &.{
        .{ .name = "cli", .module = cli_test_module },
    });
    const cli_dedicated_test = b.addTest(.{ .name = "cli-dedicated", .root_module = cli_dedicated_mod });
    cli_dedicated_test.step.dependOn(&wasm.step);
    test_step.dependOn(&b.addRunArtifact(cli_dedicated_test).step);

    // CLI pipe e2e — the `-` stdin/stdout convention. An executable, not a
    // test: the only way to observe what the CLI does with real file
    // descriptors is to spawn it, and a spawned child needs the built binary's
    // path, which `addArtifactArg` supplies as argv[1]. Same shape as
    // gen-goldens / gen-render-snapshots, minus their -Dgpu-native gate — this
    // one runs anywhere, so `test` depends on it.
    const pipe_e2e_mod = stdModule(b, target, optimize, "tests/zig/cli/pipe_e2e.zig", &.{});
    // The tty-guard case allocates a pty, and std has no API for that: the
    // four steps (posix_openpt/grantpt/unlockpt/ptsname) are libc. macOS links
    // libSystem regardless; this is what makes the same code link elsewhere.
    pipe_e2e_mod.link_libc = true;
    const pipe_e2e = b.addExecutable(.{ .name = "pngine-pipe-e2e", .root_module = pipe_e2e_mod });
    const run_pipe_e2e = b.addRunArtifact(pipe_e2e);
    run_pipe_e2e.addArtifactArg(cli);
    const pipe_step = b.step("test-cli-pipe", "Run CLI stdin/stdout pipe e2e (spawns the built binary)");
    pipe_step.dependOn(&run_pipe_e2e.step);
    test_step.dependOn(&run_pipe_e2e.step);

    // ------------------------------------------------------------------
    // Source-only cut: no tests/ directory
    // ------------------------------------------------------------------
    //
    // `scripts/mirror.sh` publishes the engine without tests — it deletes
    // tests/ and strips every inline `test {}` block. The steps above are all
    // rooted at files in there, so in the public release repo `zig build test`
    // died with `failed to check cache: 'tests/zig/test_bytecode.zig'
    // FileNotFound`, which reads like a broken checkout rather than a
    // deliberate cut.
    //
    // Dropping the dependencies here, rather than guarding ~25 registration
    // sites, keeps this to one block that CANNOT fire in the development
    // repo: tests/ is present, so the branch is dead. And it fails loudly
    // instead of reporting a green run over zero tests (pitfall 43) — a
    // reviewer who types `zig build test` gets told where the tests live.
    const tests_present = if (b.build_root.handle.access(b.graph.io, "tests", .{})) |_| true else |_| false;
    if (!tests_present) {
        const fail = b.addFail(
            "this is a release cut: the test suite (tests/) is not part of the " ++
                "public repositories. `zig build` and `zig build drift` do work " ++
                "in this checkout.",
        );
        for ([_]*std.Build.Step{ test_step, fast_test_step, standalone_step, render_test_step }) |s| {
            s.dependencies.clearRetainingCapacity();
            s.dependOn(&fail.step);
        }
    }

    // Benchmark executable
    const bench_module = stdModule(b, target, optimize, "src/benchmark.zig", &.{
        .{ .name = "pngine", .module = lib_module },
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

    // Micro WASM: stripped-down executor for size-coding (demoscene, JS13K)
    // Reduced buffer sizes: 16KB bytecode, 32KB data, 8KB commands, 8 passes
    {
        const micro_config = b.addOptions();
        micro_config.addOption(u32, "max_bytecode_kb", 16);
        micro_config.addOption(u32, "max_data_kb", 32);
        micro_config.addOption(u32, "command_buffer_kb", 8);
        micro_config.addOption(u32, "max_wgsl_modules", 16);
        micro_config.addOption(u32, "max_passes", 8);

        const micro_module = stdModule(b, wasm_target, .ReleaseSmall, "src/wasm_entry.zig", &.{
            .{ .name = "types", .module = wasm_types_module },
            .{ .name = "bytecode", .module = wasm_bytecode_module },
            .{ .name = "wasm_config", .module = micro_config.createModule() },
            .{ .name = "plugins", .module = pluginDefaultModule(b) },
        });

        const micro_wasm = b.addExecutable(.{
            .name = "pngine-micro",
            .root_module = micro_module,
        });
        micro_wasm.rdynamic = true;
        micro_wasm.entry = .disabled;

        const micro_step = b.step("wasm-micro", "Build micro WASM executor (reduced buffers for size-coding)");
        micro_step.dependOn(&b.addInstallArtifact(micro_wasm, .{}).step);
    }

    // Executor variants are built earlier (before CLI) so they can be embedded.
    // See "Executor Variants" section above.
    // The `executors_step` and `executor_artifacts` are defined there.

    // WASM Compiler: DSL → PNGB in the browser (for live preview)
    const wasm_compiler_step = b.step("wasm-compiler", "Build WASM compiler module");

    // Reflect module for WASM target (with native wgslender)
    const wasm_wgslender_dep = b.dependency("wgslender", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const wasm_reflect_module = stdModule(b, wasm_target, .ReleaseSmall, "src/reflect.zig", &.{
        .{ .name = "wgslender", .module = wasm_wgslender_dep.module("wgslender") },
    });

    // WASM compiler module
    const wasm_compiler_module = stdModule(b, wasm_target, .ReleaseSmall, "src/wasm_compiler.zig", &.{
        .{ .name = "types", .module = wasm_types_module },
        .{ .name = "bytecode", .module = wasm_bytecode_module },
        .{ .name = "reflect", .module = wasm_reflect_module },
    });

    // PNG module for PNG encoding and bytecode embedding (zero external deps)
    const wasm_png_module = stdModule(b, wasm_target, .ReleaseSmall, "src/png/main.zig", &.{});
    wasm_compiler_module.addImport("png", wasm_png_module);

    // ── SJON host for wasm32-freestanding (in-browser .sjon compile) ─────────
    // Phase 3 Commit 4: the SAME dsl_sjon module the CLI imports, cross-compiled
    // for the in-browser compiler. CRITICAL (mirrors the native §57 discipline):
    // reuse the SAME `wasm_types_module` / `wasm_bytecode_module` instances
    // `wasm_compiler_module` imports, so dsl_sjon's `format.PluginSet` is the
    // IDENTICAL type `getExecutorWasm` expects — no adapter across the boundary
    // (`format.zig` imports `plugins` from `types`, so both trace to one
    // `wasm_types_module`). This is the first build of the FULL dsl_sjon host
    // (Compiler+Emitter+values+shapes+…+sjon) for wasm32-freestanding —
    // `test-sjon-wasm` only proved the bare `sjon` dep links libc-free. The four
    // vendored sub-modules import only `types`/std (+ mesh blobs) → no
    // bytecode-instance skew, same as the native block.
    const wasm_executor_module = stdModule(b, wasm_target, .ReleaseSmall, "src/executor/standalone.zig", &.{
        .{ .name = "bytecode", .module = wasm_bytecode_module },
    });
    const wasm_dsl_sjon_mod = addDslSjonModule(b, wasm_target, .ReleaseSmall, "src/dsl_sjon/Compiler.zig", .{
        .types = wasm_types_module,
        .bytecode = wasm_bytecode_module,
        .reflect = wasm_reflect_module,
        .executor = wasm_executor_module,
        .sjon = wasm_sjon_mod,
        .vendored = dslSjonVendored(b, wasm_target, .ReleaseSmall, wasm_types_module),
    });
    wasm_compiler_module.addImport("dsl_sjon", wasm_dsl_sjon_mod);

    // Embed all executor variant WASMs (for compileToPng)
    for (executor_artifacts) |artifact| {
        wasm_compiler_module.addAnonymousImport(b.fmt("executor_{s}", .{artifact.name}), .{
            .root_source_file = artifact.bin,
        });
    }

    const wasm_compiler = b.addExecutable(.{
        .name = "pngine-compiler",
        .root_module = wasm_compiler_module,
    });
    wasm_compiler.rdynamic = true;
    wasm_compiler.entry = .disabled;

    const install_wasm_compiler = b.addInstallArtifact(wasm_compiler, .{
        .dest_dir = .{ .override = .{ .custom = "playground" } },
    });
    wasm_compiler_step.dependOn(&install_wasm_compiler.step);
    wasm_compiler_step.dependOn(executors_step);

    // Also copy the compiler WASM + schema into the npm package. pnpm packs
    // npm/pngine by its `files` list, so anything a downstream consumer (e.g.
    // pstudio) resolves through node_modules must exist in-package. The wasm
    // is a gitignored build product (like dist/); the schema copy is
    // committed and drift-gated.
    const install_npm_wasm_compiler = b.addInstallArtifact(wasm_compiler, .{
        .dest_dir = .{ .override = .{ .custom = "../npm/pngine/wasm" } },
    });
    wasm_compiler_step.dependOn(&install_npm_wasm_compiler.step);
    const install_npm_schema = b.addInstallFile(
        b.path("schema/pngine.sjon"),
        "../npm/pngine/schema/pngine.sjon",
    );
    wasm_compiler_step.dependOn(&install_npm_schema.step);

    // Web build: WASM + JS files for browser deployment
    // Uses source JS files for development (works with Vite dev server)
    // For production bundles, use: node npm/pngine/scripts/bundle.cjs
    const web_step = b.step("web", "Build demo bundle (WASM + JS)");

    // Include compiler WASM in web build
    web_step.dependOn(wasm_compiler_step);

    // Install ancillary mvp.wasm to playground/assets directory
    const install_mvp_wasm = b.addInstallArtifact(mvp_wasm, .{
        .dest_dir = .{ .override = .{ .custom = "playground/assets" } },
    });
    web_step.dependOn(&install_mvp_wasm.step);

    // Also copy WASM to npm package directory
    const install_npm_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../npm/pngine/wasm" } },
    });
    web_step.dependOn(&install_npm_wasm.step);

    // Copy demo HTML files
    const html_files = [_][]const u8{
        "tools/playground/index.html",
        "tools/inspector/inspect.html",
    };
    for (html_files) |file| {
        const install_file = b.addInstallFile(b.path(file), b.fmt("playground/{s}", .{std.fs.path.basename(file)}));
        web_step.dependOn(&install_file.step);
    }

    // Copy ALL JS modules from npm/pngine/src/ to the playground. A directory
    // glob — NOT a hand-maintained list — so a newly-added module can't be
    // forgotten: that omission shipped a broken dev demo during the JS arc
    // (gpu.js imported the new descriptor-decode.js, absent from the old list,
    // so Vite 500'd the whole module graph; journal §204). `.mjs` bundler entry
    // points are intentionally excluded.
    const install_src_js = b.addInstallDirectory(.{
        .source_dir = b.path("npm/pngine/src"),
        .install_dir = .{ .custom = "playground" },
        .install_subdir = "",
        .include_extensions = &.{".js"},
    });
    web_step.dependOn(&install_src_js.step);

    // Per-file install: index.js is ALSO exposed as pngine.js (the demo's public
    // entry point).
    const SrcFile = struct { src: []const u8, dest: []const u8 };
    const js_files = [_]SrcFile{
        .{ .src = "npm/pngine/src/index.js", .dest = "playground/pngine.js" },
    };
    for (js_files) |file| {
        const install_file = b.addInstallFile(b.path(file.src), file.dest);
        web_step.dependOn(&install_file.step);
    }

    // Web bundle: minified production bundles (requires Node.js + esbuild)
    // Produces npm/pngine/dist/{viewer,dev,core,executor}.mjs with DEBUG=false
    const web_bundle_step = b.step("web-bundle", "Build minified production JS bundle");
    web_bundle_step.dependOn(web_step);
    const bundle_cmd = b.addSystemCommand(&.{ "node", "npm/pngine/scripts/bundle.cjs" });
    web_bundle_step.dependOn(&bundle_cmd.step);

    // One command for "is any generated artifact stale?".
    //
    // Every gate below is the verify half of a regenerate/verify pair, and each
    // was previously reachable only by hand — a gate nobody runs is not a gate.
    // `schema-export` already blocks `test-standalone`; these join it so the
    // rest can't rot in place the way the website's gallery payloads did
    // (journal §268 — those left with the site in §302, and the gate with them:
    // an artifact this repo no longer stores cannot go stale in this repo).
    //
    // They run in check mode UNCONDITIONALLY: `b.args` is deliberately not
    // forwarded, so `zig build drift -- --regen` cannot talk a gate into
    // rewriting the artifact it is supposed to be judging. Regenerating is
    // always the sibling step's job, named in each comment.
    //
    // Requires Node.js (seven of the ten gates are node scripts). That is why
    // this hangs off `test`, the full developer suite, and not off
    // `test-standalone`/`test-fast`, which stay pure-Zig and fast.
    //
    // Five of the ten skip cleanly when their input is absent, and say so.
    // `test` depends on `drift`, so without that a release clone fails its own
    // suite on things it was never meant to carry: journal-toc and
    // check-bundle-doc and check-sjon-reference read files `.mirrorignore`
    // strips, webgpu-enums needs the external/gpuweb clone, gen-js-fragments
    // needs terser out of node_modules. A skip is never total —
    // check-bundle-doc errors if EVERY table it knows about is gone, and
    // check-sjon-reference errors if it parses no forms out of the schema.
    const drift_step = b.step("drift", "Verify every generated artifact is current (schema, journal index, npm versions+metadata, executor wasm + its no-allocator property, wgpu wrapper coverage, npm schema, bundle doc, js fragments, webgpu enums, sjon reference, cli flags)");

    // schema/pngine.{d.ts,schema.json} <- `zig build schema-export -- --regen`
    const drift_schema = b.addRunArtifact(schema_export_exe);
    drift_step.dependOn(&drift_schema.step);

    // docs/journal.md section index <- `node scripts/journal-toc.mjs`
    const drift_journal = b.addSystemCommand(&.{ "node", "scripts/journal-toc.mjs", "--check" });
    drift_step.dependOn(&drift_journal.step);

    // npm package version lockstep <- `node npm/pngine/scripts/sync-versions.mjs`
    const drift_versions = b.addSystemCommand(&.{ "node", "npm/pngine/scripts/sync-versions.mjs", "--check" });
    drift_step.dependOn(&drift_versions.step);

    // npm/pngine/wasm/pngine.wasm <- `zig build web`
    //
    // The committed runtime-fallback executor (downstream consumers like
    // pstudio resolve the same file via the npm package) rots in place when
    // the executor changes — the §291 opcode sweep shipped without
    // refreshing it (§292). Byte-exact, which it can afford to be because the
    // executor build is reproducible.
    const drift_npm_wasm = b.addSystemCommand(&.{
        "sh", "-c",
        \\cmp -s "$0" "$1" || {
        \\  echo "npm/pngine/wasm/pngine.wasm is stale (committed != built executor)." >&2
        \\  echo "Regenerate with: zig build web" >&2
        \\  exit 1
        \\}
    });
    drift_npm_wasm.addFileArg(wasm.getEmittedBin());
    drift_npm_wasm.addArg("npm/pngine/wasm/pngine.wasm");
    drift_step.dependOn(&drift_npm_wasm.step);

    // The executor allocates nothing — checked in the shipped bytes.
    //
    // A module can only get more memory through `memory.grow`, so its absence
    // from the code section IS the property. Nothing gated it before: the
    // "fixed-size .bss, no allocator" design was true, load-bearing (§309's
    // flat-`wasmBytes` soak leans on it), and one `std.heap.wasm_allocator`
    // away from shipping otherwise in silence. Not a regenerate/verify pair
    // like its neighbours — there is nothing to regenerate, only something that
    // must stay true. (LEAK-09 E)
    const drift_executor_static = b.addSystemCommand(&.{ "node", "scripts/check-executor-static.mjs" });
    drift_step.dependOn(&drift_executor_static.step);

    // Every wgpu reference goes through src/gpu/wgpu_c.zig's wrappers.
    //
    // The refcount ledger those wrappers keep is what the LEAK-01/02/04 balance
    // tests assert on, and it is only as complete as the claim that nothing
    // reaches wgpu around it. That claim lived in a COMMENT, was false, and the
    // one kind that escaped (surfaces) was the one kind nothing could see leak.
    // Same shape as the gate above: nothing to regenerate, just something that
    // must stay true. (LEAK-04)
    const drift_wgpu_wrappers = b.addSystemCommand(&.{ "node", "scripts/check-wgpu-wrappers.mjs" });
    drift_step.dependOn(&drift_wgpu_wrappers.step);

    // npm/pngine/schema/pngine.sjon <- `zig build wasm-compiler` (or `web`)
    //
    // The npm package ships the schema (the editor imports
    // `pngine/schema/pngine.sjon?raw`); this committed copy must stay
    // byte-identical to the single source of truth at schema/pngine.sjon.
    const drift_npm_schema = b.addSystemCommand(&.{
        "sh", "-c",
        \\cmp -s "$0" "$1" || {
        \\  echo "npm/pngine/schema/pngine.sjon is stale (committed != schema/pngine.sjon)." >&2
        \\  echo "Regenerate with: zig build wasm-compiler" >&2
        \\  exit 1
        \\}
    });
    drift_npm_schema.addArg("schema/pngine.sjon");
    drift_npm_schema.addArg("npm/pngine/schema/pngine.sjon");
    drift_step.dependOn(&drift_npm_schema.step);

    // docs/publishing.md's bundle table <- hand-written, checked against
    // `npm/pngine/scripts/bundle.cjs`.
    //
    // The odd one out: there is no regen sibling, because the artifact is
    // PROSE. That is also why it needed a gate more than the others did — the
    // table documented `browser.mjs` (a file the bundler actively deletes) and
    // missed the whole player-profile split, for two refactors, because nothing
    // ever compared it to the build (§324).
    const drift_bundle_doc = b.addSystemCommand(&.{ "node", "scripts/check-bundle-doc.mjs", "--check" });
    drift_step.dependOn(&drift_bundle_doc.step);

    // src/cli/js_fragments.zig <- `zig build gen-fragments`
    //
    // The regen step existed with no verify half for its whole life. The file
    // is the JS that every `--html` page ships, so an edit to
    // scripts/gen-js-fragments.js that nobody regenerated left the generator
    // and the shipped output silently disagreeing.
    const drift_fragments = b.addSystemCommand(&.{ "node", "scripts/gen-js-fragments.js", "--check" });
    drift_step.dependOn(&drift_fragments.step);

    // schema/webgpu-enums.json <- `node scripts/extract-webgpu-enums.mjs --regen`
    //
    // Skips cleanly without the `external/gpuweb` clone (the snapshot is the
    // source of truth for everything that consumes it; the spec is only needed
    // to regenerate). The check mode already existed — it was just never wired.
    const drift_webgpu_enums = b.addSystemCommand(&.{ "node", "scripts/extract-webgpu-enums.mjs" });
    drift_step.dependOn(&drift_webgpu_enums.step);

    // Licence + repository metadata across all eight publishable packages.
    //
    // The six platform packages shipped `"license": "MIT"` against a CC0-1.0
    // project for their whole existence, and no package carried its licence
    // TEXT. CHANGELOG 1.0.27 claims the first as fixed — that fix touched
    // `npm/pngine` alone, because nothing compared the other seven to it.
    const drift_npm_metadata = b.addSystemCommand(&.{ "node", "scripts/check-npm-metadata.mjs", "--check" });
    drift_step.dependOn(&drift_npm_metadata.step);

    // docs/sjon-reference.md <- schema/pngine.sjon
    //
    // The second prose gate, and the same shape as the bundle table: the schema
    // is the declared source of truth for what a document may contain, the
    // reference is where a human is told, and nothing compared them. It had
    // drifted to missing 16 of 67 forms — the entire depth/stencil group, render
    // bundles, query sets, all three copies, both wasm forms — plus 73 keys
    // (r2-05, §334). Forms and keys only: value-kinds are the schema's internal
    // type vocabulary and gating them would force fabricated mentions.
    const drift_sjon_reference = b.addSystemCommand(&.{ "node", "scripts/check-sjon-reference.mjs", "--check" });
    drift_step.dependOn(&drift_sjon_reference.step);

    // CLAUDE.md's CLI options tables <- the `src/cli/*.zig` parsers.
    //
    // The third prose gate. Ten gates and not one read the CLI tables, so the
    // Compile Options table documented `--no-executor` — a flag `compile` has
    // never had (it is `--embed-executor`, and the default is inverted) — until
    // a user copied it and got `Unknown option`. Flag EXISTENCE only: help
    // prose, defaults and percentage claims need a human, and gating them would
    // force fabricated matches (min1-03, §340).
    const drift_cli_flags = b.addSystemCommand(&.{ "node", "scripts/check-cli-flags.mjs", "--check" });
    drift_step.dependOn(&drift_cli_flags.step);

    test_step.dependOn(drift_step);

    // Regenerate minified JS fragments for --html codegen (requires Node.js + terser)
    const gen_frag_step = b.step("gen-fragments", "Regenerate minified JS fragments for --html output");
    const gen_frag_cmd = b.addSystemCommand(&.{ "node", "scripts/gen-js-fragments.js" });
    gen_frag_step.dependOn(&gen_frag_cmd.step);

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

        // Create sub-modules for this cross-compile target
        const cross_types = stdModule(b, cross_target, .ReleaseFast, "src/types/main.zig", &.{});

        const cross_bytecode = stdModule(b, cross_target, .ReleaseFast, "src/bytecode/standalone.zig", &.{
            .{ .name = "types", .module = cross_types },
        });

        const cross_wgslender = b.dependency("wgslender", .{
            .target = cross_target,
            .optimize = .ReleaseFast,
        }).module("wgslender");
        const cross_reflect = stdModule(b, cross_target, .ReleaseFast, "src/reflect.zig", &.{
            .{ .name = "wgslender", .module = cross_wgslender },
        });

        const cross_executor = stdModule(b, cross_target, .ReleaseFast, "src/executor/standalone.zig", &.{
            .{ .name = "bytecode", .module = cross_bytecode },
            .{ .name = "plugins", .module = pluginDefaultModule(b) },
        });

        // SJON host frontend for this cross target — the SAME module the CLI
        // imports on native (line ~728) and wasm (~1240). Without it,
        // src/main.zig's `@import("dsl_sjon")` fails to resolve and no npm
        // platform binary links. The vendored sub-modules import only
        // types/std (+ mesh blobs), so no bytecode-instance skew.
        const cross_sjon = b.dependency("sjon", .{
            .target = cross_target,
            .optimize = .ReleaseFast,
            .@"plugin-exec" = false,
        }).module("sjon");
        const cross_dsl_sjon = addDslSjonModule(b, cross_target, .ReleaseFast, "src/dsl_sjon/Compiler.zig", .{
            .types = cross_types,
            .bytecode = cross_bytecode,
            .reflect = cross_reflect,
            .executor = cross_executor,
            .sjon = cross_sjon,
            .vendored = dslSjonVendored(b, cross_target, .ReleaseFast, cross_types),
        });

        // Create library module for this target
        const cross_lib = b.addModule("pngine", .{
            .root_source_file = b.path("src/main.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
        });
        cross_lib.addImport("types", cross_types);
        cross_lib.addImport("bytecode", cross_bytecode);
        cross_lib.addImport("reflect", cross_reflect);
        cross_lib.addImport("executor", cross_executor);
        cross_lib.addImport("dsl_sjon", cross_dsl_sjon);

        const cross_gpu_options = b.addOptions();
        cross_gpu_options.addOption(bool, "has_zgpu", false);
        // npm cross targets never link wgpu-native (no per-target Rust libs, and
        // it would blow the ~1MB binary size budget) — the stub backend is used,
        // so `--frame` hard-errors on npm binaries. Keep in lockstep with the
        // has_wgpu_native option the host build adds above.
        cross_gpu_options.addOption(bool, "has_wgpu_native", false);
        cross_lib.addImport("gpu_build_options", cross_gpu_options.createModule());

        // Create CLI module for this target. `strip = true` drops debug info
        // and symbol tables from the released binary — these ship to users and
        // are never debugged in place, so the symbols are pure payload (linux
        // ≈19M → ~6M). The host `pngine` CLI (line ~582) keeps its symbols for
        // local debugging; only these six cross artifacts are stripped.
        const cross_cli_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = cross_target,
            .optimize = .ReleaseFast,
            .strip = true,
        });
        cross_cli_module.addImport("pngine", cross_lib);

        // Embed WASM executor in cross-compiled CLI (WASM is target-independent)
        const cross_build_options = b.addOptions();
        cross_build_options.addOption([]const u8, "version", npm_version);
        cross_build_options.addOption(bool, "has_embedded_wasm", true);
        cross_build_options.addOption(bool, "has_embedded_aot", false);
        cross_build_options.addOption(bool, "has_wamr", false);
        cross_cli_module.addImport("build_options", cross_build_options.createModule());

        addExecutorBlobs(b, cross_cli_module, wasm.getEmittedBin(), executor_artifacts);

        const cross_cli = b.addExecutable(.{
            .name = "pngine",
            .root_module = cross_cli_module,
        });

        // Install to npm package directory
        const install_dir = b.fmt("npm/pngine-{s}/bin", .{npm_target.name});
        const install_cross = b.addInstallArtifact(cross_cli, .{
            .dest_dir = .{ .override = .{ .custom = install_dir } },
        });
        npm_step.dependOn(&install_cross.step);
    }

    // Also copy WASM to npm package
    const npm_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "npm/pngine/wasm" } },
    });
    npm_step.dependOn(&npm_wasm.step);

    // Desktop Viewer (WAMR + trace mode)
    // ========================================================================
    //
    // Standalone viewer for PNG files with embedded executors.
    // Uses WAMR to run embedded WASM executor and traces command buffers.
    // See: docs/plans/archive/embedded-executor-plan.md Phase 7
    //
    // Usage: zig build desktop-viewer -- triangle-embedded.png

    const desktop_viewer_step = b.step("desktop-viewer", "Build desktop PNG viewer with WAMR");

    // Create WAMR wrapper module (reuses CLI's WAMR wrapper)
    const wamr_wrapper_options = b.addOptions();
    wamr_wrapper_options.addOption(bool, "has_wamr", wamr_dep != null);

    const wamr_wrapper_module = stdModule(b, target, optimize, "src/cli/inspect/wamr.zig", &.{
        .{ .name = "build_options", .module = wamr_wrapper_options.createModule() },
    });

    // Link WAMR library to wrapper module
    if (wamr_lib) |lib| {
        wamr_wrapper_module.linkLibrary(lib);
        if (wamr_dep) |dep| {
            wamr_wrapper_module.addIncludePath(dep.path("core/iwasm/include"));
        }
        wamr_wrapper_module.link_libc = true;
    }

    // Create desktop viewer module
    const desktop_viewer_module = stdModule(b, target, optimize, "tools/viewers/desktop/main.zig", &.{
        .{ .name = "pngine", .module = lib_module },
        .{ .name = "wamr", .module = wamr_wrapper_module },
    });

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

    // ========================================================================
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

/// A named module import: the `(name, module)` pair `addImport` takes.
const ModImport = struct { name: []const u8, module: *std.Build.Module };

/// Create a source module with the standard `target`/`optimize` wiring plus a
/// list of named imports. Collapses the `b.createModule(.{...})` + `addImport`
/// boilerplate that repeats ~30 times across this file into one call. Modules
/// that also need anonymous imports append them to the returned module; modules
/// with C sources, include paths, or link flags stay inline at the call site —
/// that wiring genuinely varies and does not belong in the common helper.
/// Wire the executor payload every `pngine` CLI build embeds: the generic WASM
/// runtime plus one blob per executor variant.
///
/// Three modules need exactly this set — the host executable, the host test
/// module, and each cross-compiled npm binary — and they must not disagree: a
/// variant missing from one of them is a CLI that silently cannot run that
/// plugin set. `artifacts` is the `build()`-local ExecutorArtifact array, which
/// is why it arrives as `anytype`.
fn addExecutorBlobs(
    b: *std.Build,
    mod: *std.Build.Module,
    wasm_bin: std.Build.LazyPath,
    artifacts: anytype,
) void {
    mod.addAnonymousImport("embedded_wasm", .{ .root_source_file = wasm_bin });
    for (artifacts) |artifact| {
        mod.addAnonymousImport(b.fmt("executor_{s}", .{artifact.name}), .{
            .root_source_file = artifact.bin,
        });
    }
}

/// Link the WAMR static library into a module that runs WASM natively
/// (`pngine inspect --deep`). Shared by the CLI executable and its test module.
fn linkWamr(
    mod: *std.Build.Module,
    lib: *std.Build.Step.Compile,
    dep: ?*std.Build.Dependency,
) void {
    mod.linkLibrary(lib);
    if (dep) |d| mod.addIncludePath(d.path("core/iwasm/include"));
    mod.link_libc = true;
}

/// Every `.sjon` basename in `sub_path`, sorted, on the build arena.
///
/// Globbed rather than hand-listed: the golden gate must cover whatever
/// `examples/` actually holds. A hand-list gives a NEW example zero regression
/// coverage until someone remembers to edit build.zig — silently, because
/// nothing compares the list against the directory.
///
/// Sorted because `Dir.iterate()` order is filesystem-dependent and this feeds
/// a generated source file; unsorted, the build hash would change per machine.
fn sjonFixtureNames(b: *std.Build, sub_path: []const u8) []const []const u8 {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, b.pathFromRoot(sub_path), .{ .iterate = true }) catch |err|
        std.debug.panic("build: cannot open {s}: {s}", .{ sub_path, @errorName(err) });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err|
        std.debug.panic("build: cannot iterate {s}: {s}", .{ sub_path, @errorName(err) })) |entry|
    {
        if (entry.kind != .file) continue;
        const base = std.fs.path.stem(entry.name);
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".sjon")) continue;
        names.append(b.allocator, b.dupe(base)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.order(u8, a, c) == .lt;
        }
    }.lessThan);

    std.debug.assert(names.items.len > 0); // an empty examples dir means a bad path
    return names.toOwnedSlice(b.allocator) catch @panic("OOM");
}

/// The version the CLI reports, read from npm/pngine/package.json — the
/// version source of truth (sync-versions.mjs keeps the platform packages in
/// lockstep with it). Read at build time so the binary can't drift from the
/// published package the way the old hardcoded literal did.
fn npmPackageVersion(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const manifest_path = "npm/pngine/package.json";
    const json = std.Io.Dir.cwd().readFileAlloc(io, b.pathFromRoot(manifest_path), b.allocator, .limited(64 * 1024)) catch |err|
        std.debug.panic("build: cannot read {s}: {s}", .{ manifest_path, @errorName(err) });
    const key = "\"version\": \"";
    const at = std.mem.indexOf(u8, json, key) orelse
        std.debug.panic("build: no \"version\" field in {s}", .{manifest_path});
    const rest = json[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse
        std.debug.panic("build: unterminated version string in {s}", .{manifest_path});
    const version = rest[0..end];
    std.debug.assert(version.len >= 5); // shortest valid semver is "x.y.z"
    std.debug.assert(std.ascii.isDigit(version[0]));
    return version;
}

/// Emit the globbed fixture names as a Zig source the golden harness imports.
///
/// They stay string LITERALS, so `tests/zig/sjon_golden.zig` can keep using
/// `inline for` + `@embedFile(name ++ "_sjon")` — the reason this is generated
/// source rather than data passed some other way.
fn generateFixtureList(
    b: *std.Build,
    root: []const []const u8,
    samples: []const []const u8,
) std.Build.LazyPath {
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator,
        \\//! GENERATED by build.zig (`sjonFixtureNames`) — do not edit.
        \\//!
        \\//! One entry per `examples/**/*.sjon`, so the golden gate cannot drift
        \\//! from the directory it is meant to cover.
        \\
        \\
    ) catch @panic("OOM");
    for ([_]struct { decl: []const u8, names: []const []const u8 }{
        .{ .decl = "root", .names = root },
        .{ .decl = "samples", .names = samples },
    }) |group| {
        src.print(b.allocator, "pub const {s} = [_][]const u8{{\n", .{group.decl}) catch @panic("OOM");
        for (group.names) |name| src.print(b.allocator, "    \"{s}\",\n", .{name}) catch @panic("OOM");
        src.appendSlice(b.allocator, "};\n\n") catch @panic("OOM");
    }
    return b.addWriteFiles().add("golden_fixtures.zig", src.items);
}

fn stdModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    path: []const u8,
    imports: []const ModImport,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| mod.addImport(imp.name, imp.module);
    return mod;
}

/// The four `src/dsl_sjon/*` leaf modules a host root imports. They pull in
/// `types`/std (+ the mesh blobs) and nothing else, so ONE set is safe to share
/// between several hosts on the same target — no bytecode-instance skew. That
/// sharing is why they are built here rather than inside `addDslSjonModule`:
/// the native block deliberately hands the same set to both `Compiler.zig` and
/// `complete.zig`.
const DslSjonVendored = struct {
    shapes: *std.Build.Module,
    descriptor_encoder: *std.Build.Module,
    wgsl_scan: *std.Build.Module,
    wasm_data: *std.Build.Module,
};

fn dslSjonVendored(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    types: *std.Build.Module,
) DslSjonVendored {
    const shapes = stdModule(b, target, optimize, "src/dsl_sjon/shapes.zig", &.{});
    shapes.addAnonymousImport("teapot_bin", .{
        .root_source_file = b.path("src/dsl_sjon/meshes/teapot.bin"),
    });
    shapes.addAnonymousImport("dragon_bin", .{
        .root_source_file = b.path("src/dsl_sjon/meshes/dragon.bin"),
    });
    return .{
        .shapes = shapes,
        .descriptor_encoder = stdModule(b, target, optimize, "src/dsl_sjon/descriptor_encoder.zig", &.{
            .{ .name = "types", .module = types },
        }),
        .wgsl_scan = stdModule(b, target, optimize, "src/dsl_sjon/wgsl_scan.zig", &.{}),
        .wasm_data = stdModule(b, target, optimize, "src/dsl_sjon/wasm_data.zig", &.{}),
    };
}

/// The five target-sensitive modules a `dsl_sjon` host imports, plus the
/// vendored set. A struct rather than positional args so that a TENTH import
/// is a compile error at every call site — the same "the build fails until you
/// do" property `wire_schema.zig`'s `layoutOf` has for opcodes.
const DslSjonDeps = struct {
    types: *std.Build.Module,
    bytecode: *std.Build.Module,
    reflect: *std.Build.Module,
    executor: *std.Build.Module,
    sjon: *std.Build.Module,
    vendored: DslSjonVendored,
};

/// Wire a `dsl_sjon` host root (`Compiler.zig` for production, `complete.zig`
/// for the test build) with its nine sub-modules and the embedded schema.
///
/// Spelled once because a missing import here does NOT fail at the definition
/// site — it fails at `src/main.zig`'s `@import("dsl_sjon")`, in whichever
/// target forgot it. That cost the npm cross build once already (R1-04 B).
///
/// `root` and `deps` are both parameters because the callers genuinely differ:
/// the test build uses a different root AND different `bytecode`/`executor`
/// module instances than the production one.
fn addDslSjonModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
    deps: DslSjonDeps,
) *std.Build.Module {
    const mod = stdModule(b, target, optimize, root, &.{
        .{ .name = "types", .module = deps.types },
        .{ .name = "bytecode", .module = deps.bytecode },
        .{ .name = "reflect", .module = deps.reflect },
        .{ .name = "executor", .module = deps.executor },
        .{ .name = "sjon", .module = deps.sjon },
        .{ .name = "shapes", .module = deps.vendored.shapes },
        .{ .name = "descriptor_encoder", .module = deps.vendored.descriptor_encoder },
        .{ .name = "wgsl_scan", .module = deps.vendored.wgsl_scan },
        .{ .name = "wasm_data", .module = deps.vendored.wasm_data },
    });
    // Embedded the way the CLI embeds executor WASM blobs: a named anonymous
    // import resolved by `@embedFile("pngine_schema")`, which avoids any
    // cross-directory `@embedFile` path boundary.
    mod.addAnonymousImport("pngine_schema", .{
        .root_source_file = b.path("schema/pngine.sjon"),
    });
    return mod;
}

/// Wire one standalone test binary: build the test from `module`, attach its
/// run artifact to `module_step` (the `zig build test-<x>` step) and to the
/// aggregate `test-standalone` step. Module creation stays at the call site —
/// that is where the per-module import wiring genuinely varies.
fn addStandaloneTest(
    b: *std.Build,
    standalone_step: *std.Build.Step,
    module_step: *std.Build.Step,
    name: []const u8,
    module: *std.Build.Module,
) void {
    const t = b.addTest(.{ .name = name, .root_module = module });
    const run = b.addRunArtifact(t);
    module_step.dependOn(&run.step);
    standalone_step.dependOn(&run.step);
}
