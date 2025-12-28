//! Executor Variant Selection
//!
//! Maps a PluginSet to the best matching pre-built executor variant.
//! Used during compilation to select which embedded WASM executor to use.
//!
//! ## Pre-built Variants
//!
//! | Name               | render | compute | wasm | animation | texture |
//! |--------------------|--------|---------|------|-----------|---------|
//! | core               |   ❌   |    ❌   |  ❌  |     ❌    |    ❌   |
//! | render             |   ✅   |    ❌   |  ❌  |     ❌    |    ❌   |
//! | compute            |   ❌   |    ✅   |  ❌  |     ❌    |    ❌   |
//! | render-compute     |   ✅   |    ✅   |  ❌  |     ❌    |    ❌   |
//! | render-anim        |   ✅   |    ❌   |  ❌  |     ✅    |    ❌   |
//! | render-compute-anim|   ✅   |    ✅   |  ❌  |     ✅    |    ❌   |
//! | render-wasm        |   ✅   |    ❌   |  ✅  |     ❌    |    ❌   |
//! | full               |   ✅   |    ✅   |  ✅  |     ✅    |    ✅   |
//!
//! ## Selection Strategy
//!
//! 1. Try exact match first
//! 2. If no exact match, find smallest variant that covers all required plugins
//! 3. Fall back to "full" variant (always valid)
//!
//! ## Invariants
//!
//! - Core plugin is always enabled (PluginSet.core = true)
//! - Selection always returns a valid variant name
//! - Selected variant enables at least all required plugins

const std = @import("std");
const assert = std.debug.assert;

// Use bytecode module import for PluginSet
const bytecode_mod = @import("bytecode");
pub const PluginSet = bytecode_mod.PluginSet;

// ============================================================================
// Variant Definition
// ============================================================================

/// Pre-built executor variant configuration.
pub const Variant = struct {
    /// Variant name (matches build.zig executor name).
    name: []const u8,
    /// Plugin configuration for this variant.
    plugins: PluginSet,
    /// Estimated WASM size in bytes (for size optimization).
    estimated_size: u32,
};

/// All pre-built executor variants.
/// These must match the variants defined in build.zig.
pub const VARIANTS = [_]Variant{
    .{
        .name = "core",
        .plugins = .{
            .render = false,
            .compute = false,
            .wasm = false,
            .animation = false,
            .texture = false,
        },
        .estimated_size = 8 * 1024, // ~8KB
    },
    .{
        .name = "render",
        .plugins = .{
            .render = true,
            .compute = false,
            .wasm = false,
            .animation = false,
            .texture = false,
        },
        .estimated_size = 15 * 1024, // ~15KB
    },
    .{
        .name = "compute",
        .plugins = .{
            .render = false,
            .compute = true,
            .wasm = false,
            .animation = false,
            .texture = false,
        },
        .estimated_size = 12 * 1024, // ~12KB
    },
    .{
        .name = "render-compute",
        .plugins = .{
            .render = true,
            .compute = true,
            .wasm = false,
            .animation = false,
            .texture = false,
        },
        .estimated_size = 20 * 1024, // ~20KB
    },
    .{
        .name = "render-anim",
        .plugins = .{
            .render = true,
            .compute = false,
            .wasm = false,
            .animation = true,
            .texture = false,
        },
        .estimated_size = 18 * 1024, // ~18KB
    },
    .{
        .name = "render-compute-anim",
        .plugins = .{
            .render = true,
            .compute = true,
            .wasm = false,
            .animation = true,
            .texture = false,
        },
        .estimated_size = 25 * 1024, // ~25KB
    },
    .{
        .name = "render-wasm",
        .plugins = .{
            .render = true,
            .compute = false,
            .wasm = true,
            .animation = false,
            .texture = false,
        },
        .estimated_size = 30 * 1024, // ~30KB (WASM with nested runtime)
    },
    .{
        .name = "full",
        .plugins = .{
            .render = true,
            .compute = true,
            .wasm = true,
            .animation = true,
            .texture = true,
        },
        .estimated_size = 45 * 1024, // ~45KB
    },
};

/// Number of pre-built variants.
pub const VARIANT_COUNT: usize = VARIANTS.len;

// ============================================================================
// Selection Logic
// ============================================================================

/// Check if a variant covers all required plugins.
/// A variant "covers" a requirement if every true flag in required is also true in variant.
fn covers(variant: PluginSet, required: PluginSet) bool {
    // Pre-condition: both have core = true
    assert(variant.core);
    assert(required.core);

    // Check each plugin flag
    if (required.render and !variant.render) return false;
    if (required.compute and !variant.compute) return false;
    if (required.wasm and !variant.wasm) return false;
    if (required.animation and !variant.animation) return false;
    if (required.texture and !variant.texture) return false;

    return true;
}

/// Count enabled plugins in a PluginSet (excluding core which is always on).
fn countPlugins(plugins: PluginSet) u8 {
    var count: u8 = 0;
    if (plugins.render) count += 1;
    if (plugins.compute) count += 1;
    if (plugins.wasm) count += 1;
    if (plugins.animation) count += 1;
    if (plugins.texture) count += 1;
    return count;
}

/// Select the best variant for a given PluginSet.
///
/// Returns the smallest variant that covers all required plugins.
/// Always returns a valid variant (falls back to "full" if needed).
///
/// Complexity: O(VARIANT_COUNT) = O(1) since variants is a small constant.
pub fn selectVariant(required: PluginSet) *const Variant {
    // Pre-condition: core is always true
    assert(required.core);

    // Strategy: find smallest covering variant by estimated size
    var best: ?*const Variant = null;
    var best_size: u32 = std.math.maxInt(u32);

    for (&VARIANTS) |*variant| {
        if (covers(variant.plugins, required)) {
            if (variant.estimated_size < best_size) {
                best = variant;
                best_size = variant.estimated_size;
            }
        }
    }

    // Post-condition: always have a result (full covers everything)
    const result = best orelse &VARIANTS[VARIANT_COUNT - 1]; // "full" is last
    assert(covers(result.plugins, required));
    return result;
}

/// Select variant by name.
/// Returns null if name is not a valid variant.
pub fn findVariantByName(name: []const u8) ?*const Variant {
    for (&VARIANTS) |*variant| {
        if (std.mem.eql(u8, variant.name, name)) {
            return variant;
        }
    }
    return null;
}

/// Get the WASM file path for a variant.
/// Returns path relative to zig-out/executors/ directory.
///
/// Note: This is for build-time use. At runtime, the executor is embedded.
pub fn getVariantPath(variant: *const Variant, buf: []u8) []u8 {
    const fmt_result = std.fmt.bufPrint(buf, "zig-out/executors/pngine-{s}.wasm", .{variant.name}) catch {
        return buf[0..0];
    };
    return fmt_result;
}

/// Get a human-readable description of a PluginSet.
pub fn describePlugins(plugins: PluginSet, buf: []u8) []u8 {
    var pos: usize = 0;

    // Helper to append a string
    const appendStr = struct {
        fn f(b: []u8, p: *usize, s: []const u8) void {
            if (p.* + s.len <= b.len) {
                @memcpy(b[p.*..][0..s.len], s);
                p.* += s.len;
            }
        }
    }.f;

    var first = true;
    if (plugins.render) {
        appendStr(buf, &pos, "render");
        first = false;
    }
    if (plugins.compute) {
        if (!first) appendStr(buf, &pos, ", ");
        appendStr(buf, &pos, "compute");
        first = false;
    }
    if (plugins.wasm) {
        if (!first) appendStr(buf, &pos, ", ");
        appendStr(buf, &pos, "wasm");
        first = false;
    }
    if (plugins.animation) {
        if (!first) appendStr(buf, &pos, ", ");
        appendStr(buf, &pos, "animation");
        first = false;
    }
    if (plugins.texture) {
        if (!first) appendStr(buf, &pos, ", ");
        appendStr(buf, &pos, "texture");
        first = false;
    }
    if (first) {
        appendStr(buf, &pos, "(core only)");
    }

    return buf[0..pos];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "covers: exact match" {
    const render_only = PluginSet{ .render = true };
    const render_variant = PluginSet{ .render = true };

    try testing.expect(covers(render_variant, render_only));
}

test "covers: variant has more than required" {
    const render_only = PluginSet{ .render = true };
    const render_compute = PluginSet{ .render = true, .compute = true };

    try testing.expect(covers(render_compute, render_only));
}

test "covers: variant missing required plugin" {
    const render_compute = PluginSet{ .render = true, .compute = true };
    const render_only = PluginSet{ .render = true };

    try testing.expect(!covers(render_only, render_compute));
}

test "selectVariant: core only" {
    const core_only = PluginSet{};
    const variant = selectVariant(core_only);

    try testing.expectEqualStrings("core", variant.name);
}

test "selectVariant: render only" {
    const render_only = PluginSet{ .render = true };
    const variant = selectVariant(render_only);

    try testing.expectEqualStrings("render", variant.name);
}

test "selectVariant: compute only" {
    const compute_only = PluginSet{ .compute = true };
    const variant = selectVariant(compute_only);

    try testing.expectEqualStrings("compute", variant.name);
}

test "selectVariant: render + compute" {
    const render_compute = PluginSet{ .render = true, .compute = true };
    const variant = selectVariant(render_compute);

    try testing.expectEqualStrings("render-compute", variant.name);
}

test "selectVariant: render + animation" {
    const render_anim = PluginSet{ .render = true, .animation = true };
    const variant = selectVariant(render_anim);

    try testing.expectEqualStrings("render-anim", variant.name);
}

test "selectVariant: full when needed" {
    const all_plugins = PluginSet{
        .render = true,
        .compute = true,
        .wasm = true,
        .animation = true,
        .texture = true,
    };
    const variant = selectVariant(all_plugins);

    try testing.expectEqualStrings("full", variant.name);
}

test "selectVariant: texture only needs full" {
    // No exact match for texture-only, falls back to full
    const texture_only = PluginSet{ .texture = true };
    const variant = selectVariant(texture_only);

    try testing.expectEqualStrings("full", variant.name);
    try testing.expect(variant.plugins.texture);
}

test "findVariantByName: valid" {
    const variant = findVariantByName("render-compute");
    try testing.expect(variant != null);
    try testing.expect(variant.?.plugins.render);
    try testing.expect(variant.?.plugins.compute);
}

test "findVariantByName: invalid" {
    const variant = findVariantByName("nonexistent");
    try testing.expectEqual(@as(?*const Variant, null), variant);
}

test "countPlugins: none" {
    const core_only = PluginSet{};
    try testing.expectEqual(@as(u8, 0), countPlugins(core_only));
}

test "countPlugins: all" {
    const all = PluginSet{
        .render = true,
        .compute = true,
        .wasm = true,
        .animation = true,
        .texture = true,
    };
    try testing.expectEqual(@as(u8, 5), countPlugins(all));
}

test "describePlugins: core only" {
    var buf: [128]u8 = undefined;
    const desc = describePlugins(PluginSet{}, &buf);
    try testing.expectEqualStrings("(core only)", desc);
}

test "describePlugins: multiple plugins" {
    var buf: [128]u8 = undefined;
    const desc = describePlugins(PluginSet{ .render = true, .compute = true }, &buf);
    try testing.expectEqualStrings("render, compute", desc);
}

test "VARIANTS count" {
    try testing.expectEqual(@as(usize, 8), VARIANT_COUNT);
}

test "all variants have core enabled" {
    for (VARIANTS) |variant| {
        try testing.expect(variant.plugins.core);
    }
}

test "full variant covers all plugins" {
    const full = findVariantByName("full").?;
    try testing.expect(full.plugins.render);
    try testing.expect(full.plugins.compute);
    try testing.expect(full.plugins.wasm);
    try testing.expect(full.plugins.animation);
    try testing.expect(full.plugins.texture);
}
