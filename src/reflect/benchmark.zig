//! Miniray FFI vs Subprocess Benchmark
//!
//! Compares performance of FFI direct calls vs subprocess spawning.
//! Run: zig build test-reflect -- --test-filter "benchmark"

const std = @import("std");
const Miniray = @import("miniray.zig").Miniray;
const has_ffi = @import("miniray.zig").has_ffi;

const WGSL_SIMPLE =
    \\struct Uniforms {
    \\    time: f32,
    \\    resolution: vec2<f32>,
    \\}
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    \\    return vec4f(0.0);
    \\}
    \\@fragment fn fs() -> @location(0) vec4<f32> {
    \\    return vec4f(1.0);
    \\}
;

const WGSL_COMPLEX =
    \\struct Particle {
    \\    position: vec3<f32>,
    \\    velocity: vec3<f32>,
    \\    color: vec4<f32>,
    \\    life: f32,
    \\    size: f32,
    \\    padding: vec2<f32>,
    \\}
    \\
    \\struct Uniforms {
    \\    time: f32,
    \\    deltaTime: f32,
    \\    gravity: vec3<f32>,
    \\    spawnRate: f32,
    \\    maxParticles: u32,
    \\    emitterPos: vec3<f32>,
    \\}
    \\
    \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
    \\@group(0) @binding(1) var<storage, read_write> particles: array<Particle>;
    \\@group(0) @binding(2) var<storage, read_write> counter: atomic<u32>;
    \\
    \\@compute @workgroup_size(64)
    \\fn update(@builtin(global_invocation_id) id: vec3<u32>) {
    \\    let idx = id.x;
    \\    if (idx >= uniforms.maxParticles) { return; }
    \\    // Update particle
    \\}
    \\
    \\@vertex fn vs(@builtin(instance_index) i: u32) -> @builtin(position) vec4<f32> {
    \\    return vec4f(particles[i].position, 1.0);
    \\}
    \\
    \\@fragment fn fs(@location(0) color: vec4<f32>) -> @location(0) vec4<f32> {
    \\    return color;
    \\}
;

fn runBenchmark(comptime name: []const u8, wgsl: []const u8, iterations: u32) !void {
    const allocator = std.testing.allocator;
    const miniray = Miniray{};

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..3) |_| {
        var r = miniray.reflect(allocator, wgsl) catch continue;
        r.deinit();
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        timer.reset();
        var reflection = miniray.reflect(allocator, wgsl) catch |err| {
            std.debug.print("[{s}] Error: {}\n", .{ name, err });
            return err;
        };
        const elapsed = timer.read();
        reflection.deinit();

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;

    const mode = if (has_ffi) "FFI" else "subprocess";
    std.debug.print(
        \\
        \\[{s}] {s} benchmark ({d} iterations):
        \\  Mode: {s}
        \\  Avg:  {d:.3} ms
        \\  Min:  {d:.3} ms
        \\  Max:  {d:.3} ms
        \\
    , .{ name, mode, iterations, mode, avg_ms, min_ms, max_ms });
}

test "benchmark: simple shader" {
    std.debug.print("\n", .{});
    try runBenchmark("simple", WGSL_SIMPLE, 10);
}

test "benchmark: complex shader" {
    std.debug.print("\n", .{});
    try runBenchmark("complex", WGSL_COMPLEX, 10);
}

test "benchmark: mode detection" {
    if (has_ffi) {
        std.debug.print("\n[BENCHMARK] Running in FFI mode (fast path)\n", .{});
    } else {
        std.debug.print("\n[BENCHMARK] Running in subprocess mode (fallback)\n", .{});
    }
}
