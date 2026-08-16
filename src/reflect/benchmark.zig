//! wgslender Native Benchmark
//!
//! Benchmarks WGSL reflection performance via native wgslender Zig module.
//! Run: zig build test-reflect -- --test-filter "benchmark"

const std = @import("std");
const builtin = @import("builtin");
const wgslender_native = @import("wgslender_native.zig");

fn nanotime() u64 {
    if (comptime builtin.os.tag == .freestanding) return 0;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
}

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

    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..3) |_| {
        var r = wgslender_native.reflectNative(allocator, wgsl) catch continue;
        r.deinit();
    }

    // Benchmark
    for (0..iterations) |_| {
        const start = nanotime();
        var reflection = try wgslender_native.reflectNative(allocator, wgsl);
        const elapsed = nanotime() - start;
        reflection.deinit();

        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    const min_ms = @as(f64, @floatFromInt(min_ns)) / 1_000_000.0;
    const max_ms = @as(f64, @floatFromInt(max_ns)) / 1_000_000.0;

    std.debug.print(
        \\
        \\[{s}] native benchmark ({d} iterations):
        \\  Avg:  {d:.3} ms
        \\  Min:  {d:.3} ms
        \\  Max:  {d:.3} ms
        \\
    , .{ name, iterations, avg_ms, min_ms, max_ms });
}
