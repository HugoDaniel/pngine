//! PNGine Performance Benchmarks
//!
//! Measures critical path performance:
//! - PNGB parsing: target <1ms
//! - Frame execution overhead: target <0.1ms
//!
//! Run with: zig build bench
//! For release mode: zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const pngine = @import("main.zig");

// Use bytecode module import
const bytecode_mod = @import("bytecode");
const format = bytecode_mod.format;
const Module = format.Module;
const MockGPU = @import("executor/mock_gpu.zig").MockGPU;
const Dispatcher = @import("executor/dispatcher.zig").Dispatcher;
const simple_triangle = @import("fixtures/simple_triangle.zig");

const WARMUP_ITERATIONS: u32 = 100;
const BENCH_ITERATIONS: u32 = 10000;

/// Benchmark result with timing statistics.
const BenchResult = struct {
    name: []const u8,
    iterations: u32,
    total_ns: u64,
    min_ns: u64,
    max_ns: u64,

    pub fn avg_ns(self: BenchResult) u64 {
        return self.total_ns / self.iterations;
    }

    pub fn avg_us(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.avg_ns())) / 1000.0;
    }

    pub fn avg_ms(self: BenchResult) f64 {
        return @as(f64, @floatFromInt(self.avg_ns())) / 1_000_000.0;
    }

    pub fn print(self: BenchResult) void {
        std.debug.print(
            \\
            \\  {s}
            \\    iterations: {d}
            \\    avg: {d:.3} µs ({d:.4} ms)
            \\    min: {d:.3} µs
            \\    max: {d:.3} µs
            \\
        , .{
            self.name,
            self.iterations,
            self.avg_us(),
            self.avg_ms(),
            @as(f64, @floatFromInt(self.min_ns)) / 1000.0,
            @as(f64, @floatFromInt(self.max_ns)) / 1000.0,
        });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print(
        \\
        \\╔════════════════════════════════════════════╗
        \\║       PNGine Performance Benchmarks        ║
        \\╠════════════════════════════════════════════╣
        \\║ Targets:                                   ║
        \\║   - PNGB parsing: <1ms                     ║
        \\║   - Frame execution: <0.1ms                ║
        \\╚════════════════════════════════════════════╝
        \\
    , .{});

    // First, compile PBSF to PNGB (one-time cost, not benchmarked)
    std.debug.print("\nCompiling PBSF to PNGB...\n", .{});
    const pngb = try pngine.compile(allocator, simple_triangle.simple_triangle_pbsf);
    defer allocator.free(pngb);
    std.debug.print("  PNGB size: {d} bytes\n", .{pngb.len});

    // Benchmark 1: PNGB Parsing (Deserialization)
    const parse_result = try benchParsing(allocator, pngb);
    parse_result.print();

    const parse_target_ms: f64 = 1.0;
    if (parse_result.avg_ms() < parse_target_ms) {
        std.debug.print("  ✓ PASS: {d:.4} ms < {d} ms target\n", .{ parse_result.avg_ms(), parse_target_ms });
    } else {
        std.debug.print("  ✗ FAIL: {d:.4} ms >= {d} ms target\n", .{ parse_result.avg_ms(), parse_target_ms });
    }

    // Benchmark 2: Frame Execution (MockGPU dispatch)
    const exec_result = try benchExecution(allocator, pngb);
    exec_result.print();

    const exec_target_ms: f64 = 0.1;
    if (exec_result.avg_ms() < exec_target_ms) {
        std.debug.print("  ✓ PASS: {d:.4} ms < {d} ms target\n", .{ exec_result.avg_ms(), exec_target_ms });
    } else {
        std.debug.print("  ✗ FAIL: {d:.4} ms >= {d} ms target\n", .{ exec_result.avg_ms(), exec_target_ms });
    }

    // Benchmark 3: Full Pipeline (Parse + Execute)
    const full_result = try benchFullPipeline(allocator, pngb);
    full_result.print();

    // Summary
    std.debug.print(
        \\
        \\════════════════════════════════════════════
        \\Summary:
        \\  Parse:   {d:.3} µs ({d:.4} ms)
        \\  Execute: {d:.3} µs ({d:.4} ms)
        \\  Total:   {d:.3} µs ({d:.4} ms)
        \\
        \\  Parse target (<1ms):    {s}
        \\  Execute target (<0.1ms): {s}
        \\════════════════════════════════════════════
        \\
    , .{
        parse_result.avg_us(),
        parse_result.avg_ms(),
        exec_result.avg_us(),
        exec_result.avg_ms(),
        full_result.avg_us(),
        full_result.avg_ms(),
        if (parse_result.avg_ms() < parse_target_ms) "✓ PASS" else "✗ FAIL",
        if (exec_result.avg_ms() < exec_target_ms) "✓ PASS" else "✗ FAIL",
    });
}

fn benchParsing(allocator: std.mem.Allocator, pngb: []const u8) !BenchResult {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        var module = try format.deserialize(allocator, pngb);
        module.deinit(allocator);
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..BENCH_ITERATIONS) |_| {
        timer.reset();

        var module = try format.deserialize(allocator, pngb);
        module.deinit(allocator);

        const elapsed = timer.read();
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = "PNGB Parsing (deserialize)",
        .iterations = BENCH_ITERATIONS,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

fn benchExecution(allocator: std.mem.Allocator, pngb: []const u8) !BenchResult {
    // Parse once
    var module = try format.deserialize(allocator, pngb);
    defer module.deinit(allocator);

    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        gpu.reset();
        var dispatcher = Dispatcher(MockGPU).init(&gpu, &module);
        try dispatcher.executeAll(allocator);
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..BENCH_ITERATIONS) |_| {
        gpu.reset();
        timer.reset();

        var dispatcher = Dispatcher(MockGPU).init(&gpu, &module);
        try dispatcher.executeAll(allocator);

        const elapsed = timer.read();
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = "Frame Execution (MockGPU dispatch)",
        .iterations = BENCH_ITERATIONS,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

fn benchFullPipeline(allocator: std.mem.Allocator, pngb: []const u8) !BenchResult {
    var gpu: MockGPU = .empty;
    defer gpu.deinit(allocator);

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..WARMUP_ITERATIONS) |_| {
        gpu.reset();
        var module = try format.deserialize(allocator, pngb);
        var dispatcher = Dispatcher(MockGPU).init(&gpu, &module);
        try dispatcher.executeAll(allocator);
        module.deinit(allocator);
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..BENCH_ITERATIONS) |_| {
        gpu.reset();
        timer.reset();

        var module = try format.deserialize(allocator, pngb);
        var dispatcher = Dispatcher(MockGPU).init(&gpu, &module);
        try dispatcher.executeAll(allocator);
        module.deinit(allocator);

        const elapsed = timer.read();
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = "Full Pipeline (parse + execute)",
        .iterations = BENCH_ITERATIONS,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}
