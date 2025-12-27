//! FFI Integration Test
//!
//! Simple test to verify FFI is working and measure performance.
//! Run: zig run test/ffi_test.zig -Mbuild_options=...

const std = @import("std");

// Import the reflect module
const reflect = @import("../src/reflect.zig");
const Miniray = reflect.Miniray;

const WGSL_TEST =
    \\struct U { time: f32, scale: vec2<f32>, }
    \\@group(0) @binding(0) var<uniform> u: U;
    \\@fragment fn fs() -> @location(0) vec4<f32> { return vec4f(1.0); }
;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Miniray FFI Test ===\n\n", .{});

    // Report FFI status
    if (reflect.has_miniray_lib) {
        std.debug.print("Mode: FFI (libminiray.a linked)\n", .{});
    } else {
        std.debug.print("Mode: Subprocess (fallback)\n", .{});
    }

    const miniray = Miniray{};

    // Warmup
    std.debug.print("\nWarmup...\n", .{});
    for (0..3) |_| {
        var r = miniray.reflect(allocator, WGSL_TEST) catch continue;
        r.deinit();
    }

    // Benchmark
    const iterations: u32 = 20;
    std.debug.print("\nBenchmark ({d} iterations)...\n", .{iterations});

    var timer = try std.time.Timer.start();
    var total_ns: u64 = 0;

    for (0..iterations) |i| {
        timer.reset();
        var reflection = try miniray.reflect(allocator, WGSL_TEST);
        const elapsed = timer.read();
        reflection.deinit();

        total_ns += elapsed;

        if (i < 3 or i == iterations - 1) {
            const ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;
            std.debug.print("  [{d:2}] {d:.3} ms\n", .{i + 1, ms});
        } else if (i == 3) {
            std.debug.print("  ...\n", .{});
        }
    }

    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;

    std.debug.print(
        \\
        \\Results:
        \\  Total:    {d:.1} ms
        \\  Average:  {d:.3} ms per call
        \\  Ops/sec:  {d:.0}
        \\
    , .{ total_ms, avg_ms, 1000.0 / avg_ms });
}
