//! Compile-time Shape Generators
//!
//! Canonical compile-time shape generators for the SJON host. (Originally
//! vendored from the legacy `dsl` emitter; that tree was deleted at the SJON
//! cutover, so this is now the single source. See CONTRIBUTING §17.) The
//! generated vertex data is pinned by the golden traces (test-sjon-golden).
//!
//! Generates vertex data for common 3D shapes at compile time.
//! Shapes are emitted directly to the data section as float32 arrays.
//!
//! ## Supported Shapes
//!
//! - `cube`: Unit cube with 36 vertices (6 faces × 2 triangles)
//! - `plane`: Single quad on XY plane with 6 vertices
//! - `sphere`: UV sphere with configurable segments
//!
//! ## Format Specifiers
//!
//! Each vertex can include multiple attributes:
//! - `position3`: vec3f position (12 bytes)
//! - `position4`: vec4f position with w=1 (16 bytes)
//! - `normal3`: vec3f surface normal (12 bytes)
//! - `color3`: vec3f RGB color (12 bytes)
//! - `color4`: vec4f RGBA color (16 bytes)
//! - `uv2`: vec2f texture coordinates (8 bytes)
//!
//! ## Example
//!
//! ```
//! (data :name cubeVertices (cube :format [position4 color4 uv2]))
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum vertices per shape (prevents unbounded allocation)
pub const MAX_VERTICES: u32 = 65536;

/// Maximum attributes per vertex
const MAX_ATTRIBUTES: u32 = 8;

/// Vertex attribute format
pub const Format = enum {
    position3, // vec3f position
    position4, // vec4f position (w=1)
    normal3, // vec3f normal
    color3, // vec3f RGB
    color4, // vec4f RGBA
    uv2, // vec2f UV

    /// Size in bytes for this format
    pub fn byteSize(self: Format) u32 {
        return switch (self) {
            .position3 => 12,
            .normal3 => 12,
            .color3 => 12,
            .position4 => 16,
            .color4 => 16,
            .uv2 => 8,
        };
    }

    /// Size in floats for this format
    pub fn floatCount(self: Format) u32 {
        return switch (self) {
            .position3 => 3,
            .normal3 => 3,
            .color3 => 3,
            .position4 => 4,
            .color4 => 4,
            .uv2 => 2,
        };
    }

    /// Parse a format string.
    ///
    /// Derived from the enum, not mirrored onto it. This was a hand-written
    /// `StaticStringMap` repeating all six tag names, which made the accepted
    /// set a THIRD copy of a list already written twice (here and in
    /// `schema/pngine.sjon`'s `shape-format` member-set). `stringToEnum` makes
    /// the domain exactly the tag names by construction, so only the
    /// schema↔enum pair is left to hold — and `schema_parity_test.zig` holds
    /// that one. `Emitter.readShapeFormats` asserts a miss is unreachable and
    /// leans on precisely this. (§317, r2-07 C)
    pub fn fromString(s: []const u8) ?Format {
        return std.meta.stringToEnum(Format, s);
    }
};

/// Shape configuration
pub const ShapeConfig = struct {
    formats: []const Format,
    // Sphere-specific
    segments: u32 = 24,
    rings: u32 = 12,
    // Plane-specific
    width: f32 = 1.0,
    height: f32 = 1.0,
    // Torus-specific
    radius: f32 = 1.0,
    thickness: f32 = 0.24,
    radial_subdivisions: u32 = 24,
    body_subdivisions: u32 = 12,
    // Truncated cone / cylinder specific
    bottom_radius: f32 = 1.0,
    top_radius: f32 = 0.0,
    cone_height: f32 = 1.0,
    vertical_subdivisions: u32 = 1,
    top_cap: bool = true,
    bottom_cap: bool = true,
    // Faceting (flat normals per triangle)
    faceted: bool = false,
};

/// Per-key ceiling on subdivision counts.
///
/// Not the real limit — that is `MAX_VERTICES` on the generated index count —
/// but the one that makes the size arithmetic safe to PERFORM. Every generator
/// multiplies two or three of these together before it can check anything, and
/// `generateTruncatedCone` allocates from the product ~65 lines before its cap
/// check. 4096 is far above any config that could pass `MAX_VERTICES` (a sphere
/// needs `segs*rings*6 <= 65536`) and far below where the products stop fitting
/// comfortably in u64.
pub const MAX_SUBDIVISIONS: u32 = 4096;

/// The bound an author's generator config broke. Carries enough to write the
/// diagnostic the emitter shows — the schema cannot, because shape sub-forms are
/// `:open true` and so their config keys have no value-kind to bound.
/// A generator refused: either the config broke a bound (`InvalidShapeConfig`,
/// see `checkConfig`) or the mesh it describes exceeds `MAX_VERTICES`
/// (`ShapeTooLarge`). Distinct from `OutOfMemory`, which the cap checks used to
/// borrow — an author asking for a 24-million-index cone is not a machine
/// running out of memory, and the emitter needs to tell the two apart to write a
/// located diagnostic instead of an opaque allocation failure (LEAK-11 B).
pub const GenerateError = error{ InvalidShapeConfig, ShapeTooLarge };

pub const ConfigViolation = struct {
    key: []const u8,
    value: u32,
    min: u32,
    max: u32 = MAX_SUBDIVISIONS,
};

/// First bound `config` breaks for `shape`, or null when it is generatable.
///
/// These numbers used to be `std.debug.assert`s inside the generators — author
/// input asserted as an invariant, which panics the CLI and, in the ReleaseSmall
/// wasm compiler where asserts are compiled out, walks into the math anyway
/// (LEAK-11 B). Input is not an invariant: the emitter calls this to produce a
/// located diagnostic, and each generator calls it to refuse rather than trust
/// its caller.
pub fn checkConfig(shape: ShapeType, config: ShapeConfig) ?ConfigViolation {
    const Bound = struct { key: []const u8, value: u32, min: u32 };
    const bounds: []const Bound = switch (shape) {
        // A closed surface needs at least a triangle around and a band across.
        .sphere => &.{
            .{ .key = "segments", .value = config.segments, .min = 3 },
            .{ .key = "rings", .value = config.rings, .min = 2 },
        },
        .torus => &.{
            .{ .key = "radial-subdivisions", .value = config.radial_subdivisions, .min = 3 },
            .{ .key = "body-subdivisions", .value = config.body_subdivisions, .min = 3 },
        },
        .truncated_cone, .cylinder => &.{
            .{ .key = "radial-subdivisions", .value = config.radial_subdivisions, .min = 3 },
            .{ .key = "vertical-subdivisions", .value = config.vertical_subdivisions, .min = 1 },
        },
        // Fixed-topology generators: nothing author-supplied reaches their sizes.
        .cube, .plane, .teapot, .dragon => &.{},
    };
    for (bounds) |b| {
        if (b.value < b.min or b.value > MAX_SUBDIVISIONS)
            return .{ .key = b.key, .value = b.value, .min = b.min };
    }
    return null;
}

/// Generate cube vertices with specified format.
/// Returns byte array with vertex data.
/// Cube is centered at origin with side length 2 (vertices at ±1).
pub fn generateCube(allocator: Allocator, config: ShapeConfig) ![]u8 {
    // Pre-conditions
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);

    const vertex_count: u32 = 36; // 6 faces × 2 triangles × 3 vertices
    var stride: u32 = 0;
    for (config.formats) |fmt| {
        stride += fmt.floatCount();
    }

    const total_floats = vertex_count * stride;
    const bytes = try allocator.alloc(u8, total_floats * 4);
    errdefer allocator.free(bytes);

    // Cast to f32 slice for easier writing
    const floats = std.mem.bytesAsSlice(f32, bytes);

    // Cube face data: 6 faces, each with 2 triangles (6 vertices)
    // Face order: -Y (bottom), +X (right), +Y (top), -X (left), +Z (front), -Z (back)
    const faces = [6][4][3]f32{
        // -Y face (bottom) - vertices at y=-1
        .{ .{ 1, -1, 1 }, .{ -1, -1, 1 }, .{ -1, -1, -1 }, .{ 1, -1, -1 } },
        // +X face (right) - vertices at x=1
        .{ .{ 1, 1, 1 }, .{ 1, -1, 1 }, .{ 1, -1, -1 }, .{ 1, 1, -1 } },
        // +Y face (top) - vertices at y=1
        .{ .{ -1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, -1 }, .{ -1, 1, -1 } },
        // -X face (left) - vertices at x=-1
        .{ .{ -1, -1, 1 }, .{ -1, 1, 1 }, .{ -1, 1, -1 }, .{ -1, -1, -1 } },
        // +Z face (front) - vertices at z=1
        .{ .{ 1, 1, 1 }, .{ -1, 1, 1 }, .{ -1, -1, 1 }, .{ 1, -1, 1 } },
        // -Z face (back) - vertices at z=-1
        .{ .{ 1, -1, -1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 } },
    };

    // Face normals
    const normals = [6][3]f32{
        .{ 0, -1, 0 }, // -Y
        .{ 1, 0, 0 }, // +X
        .{ 0, 1, 0 }, // +Y
        .{ -1, 0, 0 }, // -X
        .{ 0, 0, 1 }, // +Z
        .{ 0, 0, -1 }, // -Z
    };

    // Face colors (matching rotating_cube.pngine pattern)
    const colors = [6][4]f32{
        .{ 0.5, 0.0, 0.5, 1.0 }, // -Y: purple-ish
        .{ 1.0, 0.5, 0.5, 1.0 }, // +X: red-ish
        .{ 0.5, 1.0, 0.5, 1.0 }, // +Y: green-ish
        .{ 0.0, 0.5, 0.5, 1.0 }, // -X: cyan-ish
        .{ 0.5, 0.5, 1.0, 1.0 }, // +Z: blue-ish
        .{ 0.5, 0.5, 0.5, 1.0 }, // -Z: gray
    };

    // UVs for each vertex in a quad (0=TL, 1=TR, 2=BR, 3=BL)
    const uvs = [4][2]f32{
        .{ 0, 1 }, // 0: top-left
        .{ 1, 1 }, // 1: top-right
        .{ 1, 0 }, // 2: bottom-right
        .{ 0, 0 }, // 3: bottom-left
    };

    // Triangle indices for a quad (two triangles)
    const tri_indices = [6]u8{ 0, 1, 2, 3, 0, 2 };

    var offset: usize = 0;
    for (0..6) |face_idx| { // 6 faces
        const face = faces[face_idx];
        const normal = normals[face_idx];
        const color = colors[face_idx];

        for (tri_indices) |vi| { // 6 vertices per face (2 triangles)
            const pos = face[vi];
            const uv = uvs[vi];

            // Write each format attribute
            for (config.formats) |fmt| {
                switch (fmt) {
                    .position3 => {
                        floats[offset] = pos[0];
                        floats[offset + 1] = pos[1];
                        floats[offset + 2] = pos[2];
                        offset += 3;
                    },
                    .position4 => {
                        floats[offset] = pos[0];
                        floats[offset + 1] = pos[1];
                        floats[offset + 2] = pos[2];
                        floats[offset + 3] = 1.0; // w=1
                        offset += 4;
                    },
                    .normal3 => {
                        floats[offset] = normal[0];
                        floats[offset + 1] = normal[1];
                        floats[offset + 2] = normal[2];
                        offset += 3;
                    },
                    .color3 => {
                        floats[offset] = color[0];
                        floats[offset + 1] = color[1];
                        floats[offset + 2] = color[2];
                        offset += 3;
                    },
                    .color4 => {
                        floats[offset] = color[0];
                        floats[offset + 1] = color[1];
                        floats[offset + 2] = color[2];
                        floats[offset + 3] = color[3];
                        offset += 4;
                    },
                    .uv2 => {
                        floats[offset] = uv[0];
                        floats[offset + 1] = uv[1];
                        offset += 2;
                    },
                }
            }
        }
    }

    // Post-condition: wrote exactly expected bytes
    std.debug.assert(offset == total_floats);

    return bytes;
}

/// Generate plane vertices (single quad on XY plane).
/// Plane is centered at origin with configurable width and height.
pub fn generatePlane(allocator: Allocator, config: ShapeConfig) ![]u8 {
    // Pre-conditions
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);

    const vertex_count: u32 = 6; // 2 triangles × 3 vertices
    var stride: u32 = 0;
    for (config.formats) |fmt| {
        stride += fmt.floatCount();
    }

    const total_floats = vertex_count * stride;
    const bytes = try allocator.alloc(u8, total_floats * 4);
    errdefer allocator.free(bytes);

    const floats = std.mem.bytesAsSlice(f32, bytes);

    const hw = config.width / 2.0;
    const hh = config.height / 2.0;

    // Quad vertices (two triangles, CCW winding)
    const positions = [6][3]f32{
        .{ -hw, -hh, 0 }, // tri1: bottom-left
        .{ hw, -hh, 0 }, // tri1: bottom-right
        .{ hw, hh, 0 }, // tri1: top-right
        .{ -hw, -hh, 0 }, // tri2: bottom-left
        .{ hw, hh, 0 }, // tri2: top-right
        .{ -hw, hh, 0 }, // tri2: top-left
    };

    const uvs = [6][2]f32{
        .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 },
        .{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 },
    };

    const normal = [3]f32{ 0, 0, 1 };
    const color = [4]f32{ 1, 1, 1, 1 };

    var offset: usize = 0;
    for (0..6) |vi| {
        const pos = positions[vi];
        const uv = uvs[vi];

        for (config.formats) |fmt| {
            switch (fmt) {
                .position3 => {
                    floats[offset] = pos[0];
                    floats[offset + 1] = pos[1];
                    floats[offset + 2] = pos[2];
                    offset += 3;
                },
                .position4 => {
                    floats[offset] = pos[0];
                    floats[offset + 1] = pos[1];
                    floats[offset + 2] = pos[2];
                    floats[offset + 3] = 1.0;
                    offset += 4;
                },
                .normal3 => {
                    floats[offset] = normal[0];
                    floats[offset + 1] = normal[1];
                    floats[offset + 2] = normal[2];
                    offset += 3;
                },
                .color3 => {
                    floats[offset] = color[0];
                    floats[offset + 1] = color[1];
                    floats[offset + 2] = color[2];
                    offset += 3;
                },
                .color4 => {
                    floats[offset] = color[0];
                    floats[offset + 1] = color[1];
                    floats[offset + 2] = color[2];
                    floats[offset + 3] = color[3];
                    offset += 4;
                },
                .uv2 => {
                    floats[offset] = uv[0];
                    floats[offset + 1] = uv[1];
                    offset += 2;
                },
            }
        }
    }

    // Post-condition
    std.debug.assert(offset == total_floats);

    return bytes;
}

/// Generate sphere vertices (UV sphere, deindexed).
/// Sphere centered at origin with configurable segments (longitude) and rings (latitude).
pub fn generateSphere(allocator: Allocator, config: ShapeConfig) ![]u8 {
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);
    if (checkConfig(.sphere, config) != null) return error.InvalidShapeConfig;

    const segs = config.segments;
    const rings = config.rings;
    const r = config.radius;

    // Indexed: (segs+1) × (rings+1) vertices, segs × rings × 6 indices.
    // In u64 and BEFORE either allocation: both counts derive from author
    // numbers, so the multiply must not be the thing that overflows.
    const num_indices_wide = @as(u64, segs) * rings * 6;
    if (num_indices_wide > MAX_VERTICES) return error.ShapeTooLarge;
    const num_indices: u32 = @intCast(num_indices_wide);

    var stride: u32 = 0;
    for (config.formats) |fmt| stride += fmt.floatCount();

    // Allocate indexed vertices
    const indexed_count = (segs + 1) * (rings + 1);
    const indexed = try allocator.alloc(f32, indexed_count * 6); // pos3 + normal3
    defer allocator.free(indexed);

    // Generate indexed vertices with smooth normals
    var vi: usize = 0;
    for (0..rings + 1) |y| {
        for (0..segs + 1) |x| {
            const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(segs));
            const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(rings));
            const theta = u * std.math.pi * 2.0;
            const phi = v * std.math.pi;
            const sin_theta = @sin(theta);
            const cos_theta = @cos(theta);
            const sin_phi = @sin(phi);
            const cos_phi = @cos(phi);
            const nx = cos_theta * sin_phi;
            const ny = cos_phi;
            const nz = sin_theta * sin_phi;
            indexed[vi + 0] = r * nx;
            indexed[vi + 1] = r * ny;
            indexed[vi + 2] = r * nz;
            indexed[vi + 3] = nx;
            indexed[vi + 4] = ny;
            indexed[vi + 5] = nz;
            vi += 6;
        }
    }
    std.debug.assert(vi == indexed_count * 6);

    // Generate indices
    const indices = try allocator.alloc(u32, num_indices);
    defer allocator.free(indices);
    const verts_around: u32 = segs + 1;
    var ii: usize = 0;
    for (0..segs) |x| {
        for (0..rings) |y| {
            const xi: u32 = @intCast(x);
            const yi: u32 = @intCast(y);
            indices[ii + 0] = (yi + 0) * verts_around + xi;
            indices[ii + 1] = (yi + 0) * verts_around + xi + 1;
            indices[ii + 2] = (yi + 1) * verts_around + xi;
            indices[ii + 3] = (yi + 1) * verts_around + xi;
            indices[ii + 4] = (yi + 0) * verts_around + xi + 1;
            indices[ii + 5] = (yi + 1) * verts_around + xi + 1;
            ii += 6;
        }
    }
    std.debug.assert(ii == num_indices);

    return deindexAndEmit(allocator, config, indexed, 6, indices, num_indices);
}

/// Generate torus vertices (deindexed).
/// Torus centered at origin on XZ plane with configurable radius, thickness, subdivisions.
pub fn generateTorus(allocator: Allocator, config: ShapeConfig) ![]u8 {
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);
    if (checkConfig(.torus, config) != null) return error.InvalidShapeConfig;

    const radial = config.radial_subdivisions;
    const body = config.body_subdivisions;
    const major_r = config.radius;
    const minor_r = config.thickness;

    const radial_parts = radial + 1;
    const body_parts = body + 1;
    const indexed_count = radial_parts * body_parts;
    const num_indices = radial * body * 6;
    if (num_indices > MAX_VERTICES) return error.ShapeTooLarge;

    const indexed = try allocator.alloc(f32, indexed_count * 6);
    defer allocator.free(indexed);

    var vi: usize = 0;
    for (0..body_parts) |slice| {
        const v = @as(f32, @floatFromInt(slice)) / @as(f32, @floatFromInt(body));
        const slice_angle = v * std.math.pi * 2.0;
        const slice_sin = @sin(slice_angle);
        const ring_radius = major_r + slice_sin * minor_r;
        const ny = @cos(slice_angle);
        const y = ny * minor_r;
        for (0..radial_parts) |ring| {
            const u = @as(f32, @floatFromInt(ring)) / @as(f32, @floatFromInt(radial));
            const ring_angle = u * std.math.pi * 2.0;
            const x_sin = @sin(ring_angle);
            const z_cos = @cos(ring_angle);
            indexed[vi + 0] = x_sin * ring_radius;
            indexed[vi + 1] = y;
            indexed[vi + 2] = z_cos * ring_radius;
            indexed[vi + 3] = x_sin * slice_sin;
            indexed[vi + 4] = ny;
            indexed[vi + 5] = z_cos * slice_sin;
            vi += 6;
        }
    }
    std.debug.assert(vi == indexed_count * 6);

    const indices = try allocator.alloc(u32, num_indices);
    defer allocator.free(indices);
    var ii: usize = 0;
    for (0..body) |slice| {
        for (0..radial) |ring| {
            const s: u32 = @intCast(slice);
            const ri: u32 = @intCast(ring);
            indices[ii + 0] = radial_parts * s + ri;
            indices[ii + 1] = radial_parts * (s + 1) + ri;
            indices[ii + 2] = radial_parts * s + ri + 1;
            indices[ii + 3] = radial_parts * (s + 1) + ri;
            indices[ii + 4] = radial_parts * (s + 1) + ri + 1;
            indices[ii + 5] = radial_parts * s + ri + 1;
            ii += 6;
        }
    }
    std.debug.assert(ii == num_indices);

    return deindexAndEmit(allocator, config, indexed, 6, indices, num_indices);
}

/// Generate truncated cone vertices (deindexed).
/// Centered at origin along Y axis. topRadius=0 gives a cone, topRadius=bottomRadius gives a cylinder.
pub fn generateTruncatedCone(allocator: Allocator, config: ShapeConfig) ![]u8 {
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);
    if (checkConfig(.truncated_cone, config) != null) return error.InvalidShapeConfig;

    const radial = config.radial_subdivisions;
    const vert_sub = config.vertical_subdivisions;
    const bot_r = config.bottom_radius;
    const top_r = config.top_radius;
    const h = config.cone_height;
    const has_top = config.top_cap;
    const has_bot = config.bottom_cap;

    const extra: u32 = (if (has_top) @as(u32, 2) else 0) + (if (has_bot) @as(u32, 2) else 0);
    const verts_around: u32 = radial + 1;

    // Slant for normals
    const slant = std.math.atan2(bot_r - top_r, h);
    const cos_slant = @cos(slant);
    const sin_slant = @sin(slant);

    const start_i: i32 = if (has_top) -2 else 0;
    const end_i: i32 = @as(i32, @intCast(vert_sub)) + if (has_bot) @as(i32, 2) else 0;
    const num_rings: u32 = @intCast(end_i - start_i + 1);
    const indexed_count = num_rings * verts_around;

    // The cap, hoisted above the allocation it is supposed to bound. It used to
    // sit ~65 lines further down, beside the INDEX allocation, so
    // `(truncated-cone :radial-subdivisions 20000 :vertical-subdivisions 20000)`
    // — a ~70-byte form — allocated and FILLED ~9.6 GB before anything checked
    // (LEAK-11 B). Counted exactly (the same skipped-ring rule the emit loop
    // below uses) rather than bounded, so no config's accept/reject verdict
    // changes; in u64, because both factors come from author numbers.
    // `checkConfig` above already bounds those, which is what keeps this loop
    // short.
    const total_rings_for_idx = vert_sub + extra;
    var num_indices: u32 = 0;
    {
        var wide: u64 = 0;
        for (0..total_rings_for_idx) |yy_idx| {
            if ((yy_idx == 1 and has_top) or (yy_idx == total_rings_for_idx - 2 and has_bot)) continue;
            wide += @as(u64, radial) * 6;
        }
        if (wide > MAX_VERTICES) return error.ShapeTooLarge;
        num_indices = @intCast(wide);
    }

    const indexed = try allocator.alloc(f32, indexed_count * 6);
    defer allocator.free(indexed);

    var vi: usize = 0;
    var yy = start_i;
    for (0..num_rings) |_| {
        defer yy += 1;
        var v_val = @as(f32, @floatFromInt(yy)) / @as(f32, @floatFromInt(vert_sub));
        var y_val = h * v_val;
        var ring_radius: f32 = 0;

        if (yy < 0) {
            y_val = 0;
            v_val = 1;
            ring_radius = bot_r;
        } else if (yy > @as(i32, @intCast(vert_sub))) {
            y_val = h;
            v_val = 1;
            ring_radius = top_r;
        } else {
            ring_radius = bot_r + (top_r - bot_r) * (@as(f32, @floatFromInt(yy)) / @as(f32, @floatFromInt(vert_sub)));
        }
        if (yy == -2 or yy == @as(i32, @intCast(vert_sub)) + 2) {
            ring_radius = 0;
            v_val = 0;
        }
        y_val -= h / 2.0;

        for (0..verts_around) |ii_ring| {
            const angle = @as(f32, @floatFromInt(ii_ring)) * std.math.pi * 2.0 / @as(f32, @floatFromInt(radial));
            const sin_a = @sin(angle);
            const cos_a = @cos(angle);
            indexed[vi + 0] = sin_a * ring_radius;
            indexed[vi + 1] = y_val;
            indexed[vi + 2] = cos_a * ring_radius;
            if (yy < 0) {
                indexed[vi + 3] = 0;
                indexed[vi + 4] = -1;
                indexed[vi + 5] = 0;
            } else if (yy > @as(i32, @intCast(vert_sub))) {
                indexed[vi + 3] = 0;
                indexed[vi + 4] = 1;
                indexed[vi + 5] = 0;
            } else if (ring_radius == 0.0) {
                indexed[vi + 3] = 0;
                indexed[vi + 4] = 0;
                indexed[vi + 5] = 0;
            } else {
                indexed[vi + 3] = sin_a * cos_slant;
                indexed[vi + 4] = sin_slant;
                indexed[vi + 5] = cos_a * cos_slant;
            }
            // v_val available for UV generation if needed
            vi += 6;
        }
    }
    std.debug.assert(vi == indexed_count * 6);

    // (index count + cap: computed above, before the vertex allocation)
    const indices = try allocator.alloc(u32, num_indices);
    defer allocator.free(indices);
    var ii: usize = 0;
    for (0..total_rings_for_idx) |yy_idx| {
        if ((yy_idx == 1 and has_top) or (yy_idx == total_rings_for_idx - 2 and has_bot)) continue;
        const yi: u32 = @intCast(yy_idx);
        for (0..radial) |ri_idx| {
            const ri: u32 = @intCast(ri_idx);
            indices[ii + 0] = verts_around * (yi + 0) + 0 + ri;
            indices[ii + 1] = verts_around * (yi + 0) + 1 + ri;
            indices[ii + 2] = verts_around * (yi + 1) + 1 + ri;
            indices[ii + 3] = verts_around * (yi + 0) + 0 + ri;
            indices[ii + 4] = verts_around * (yi + 1) + 1 + ri;
            indices[ii + 5] = verts_around * (yi + 1) + 0 + ri;
            ii += 6;
        }
    }
    std.debug.assert(ii == num_indices);

    return deindexAndEmit(allocator, config, indexed, 6, indices, num_indices);
}

/// Generate cylinder vertices (wrapper around truncated cone with equal radii).
pub fn generateCylinder(allocator: Allocator, config: ShapeConfig) ![]u8 {
    var cone_config = config;
    cone_config.top_radius = config.radius;
    cone_config.bottom_radius = config.radius;
    cone_config.cone_height = config.cone_height;
    return generateTruncatedCone(allocator, cone_config);
}

// ============================================================================
// Deindex + Facet helpers
// ============================================================================

/// Compute flat normal for a triangle from 3 positions in indexed data.
fn computeFlatNormal(indexed: []const f32, src_stride: u32, idx0: u32, idx1: u32, idx2: u32) [3]f32 {
    const b0 = idx0 * src_stride;
    const b1 = idx1 * src_stride;
    const b2 = idx2 * src_stride;
    const e0 = [3]f32{ indexed[b1] - indexed[b0], indexed[b1 + 1] - indexed[b0 + 1], indexed[b1 + 2] - indexed[b0 + 2] };
    const e1 = [3]f32{ indexed[b2] - indexed[b0], indexed[b2 + 1] - indexed[b0 + 1], indexed[b2 + 2] - indexed[b0 + 2] };
    var n = [3]f32{
        e0[1] * e1[2] - e0[2] * e1[1],
        e0[2] * e1[0] - e0[0] * e1[2],
        e0[0] * e1[1] - e0[1] * e1[0],
    };
    const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
    if (len > 1e-7) {
        n[0] /= len;
        n[1] /= len;
        n[2] /= len;
    }
    return n;
}

/// Emit a single vertex to the output float buffer.
fn emitVertex(
    floats: []align(1) f32,
    offset: *usize,
    formats: []const Format,
    pos: [3]f32,
    normal: [3]f32,
) void {
    for (formats) |fmt| {
        switch (fmt) {
            .position3 => {
                floats[offset.* + 0] = pos[0];
                floats[offset.* + 1] = pos[1];
                floats[offset.* + 2] = pos[2];
                offset.* += 3;
            },
            .position4 => {
                floats[offset.* + 0] = pos[0];
                floats[offset.* + 1] = pos[1];
                floats[offset.* + 2] = pos[2];
                floats[offset.* + 3] = 1.0;
                offset.* += 4;
            },
            .normal3 => {
                floats[offset.* + 0] = normal[0];
                floats[offset.* + 1] = normal[1];
                floats[offset.* + 2] = normal[2];
                offset.* += 3;
            },
            .color3 => {
                floats[offset.* + 0] = 1;
                floats[offset.* + 1] = 1;
                floats[offset.* + 2] = 1;
                offset.* += 3;
            },
            .color4 => {
                floats[offset.* + 0] = 1;
                floats[offset.* + 1] = 1;
                floats[offset.* + 2] = 1;
                floats[offset.* + 3] = 1;
                offset.* += 4;
            },
            .uv2 => {
                floats[offset.* + 0] = std.math.atan2(pos[2], pos[0]) / (2.0 * std.math.pi) + 0.5;
                floats[offset.* + 1] = pos[1] * 0.5 + 0.5;
                offset.* += 2;
            },
        }
    }
}

/// Deindex indexed geometry, optionally facet (flat normals), and emit formatted vertex data.
/// `indexed` contains interleaved pos3+normal3 per vertex (6 floats each).
/// `src_stride` is floats per indexed vertex (always 6 for pos3+normal3).
fn deindexAndEmit(
    allocator: Allocator,
    config: ShapeConfig,
    indexed: []const f32,
    src_stride: u32,
    indices: []const u32,
    num_indices: u32,
) ![]u8 {
    std.debug.assert(src_stride == 6);
    std.debug.assert(num_indices == indices.len);
    std.debug.assert(num_indices % 3 == 0);

    var out_stride: u32 = 0;
    for (config.formats) |fmt| out_stride += fmt.floatCount();

    const total_floats = num_indices * out_stride;
    const bytes = try allocator.alloc(u8, total_floats * 4);
    errdefer allocator.free(bytes);
    const floats = std.mem.bytesAsSlice(f32, bytes);

    var offset: usize = 0;
    const num_tris = num_indices / 3;

    for (0..num_tris) |tri| {
        const ti = tri * 3;
        const idx0 = indices[ti + 0];
        const idx1 = indices[ti + 1];
        const idx2 = indices[ti + 2];

        // Compute flat normal if faceted
        const flat_n = if (config.faceted)
            computeFlatNormal(indexed, src_stride, idx0, idx1, idx2)
        else
            [3]f32{ 0, 0, 0 }; // unused

        // Emit 3 vertices per triangle
        const tri_indices_arr = [3]u32{ idx0, idx1, idx2 };
        for (tri_indices_arr) |idx| {
            const base = idx * src_stride;
            const pos = [3]f32{ indexed[base + 0], indexed[base + 1], indexed[base + 2] };
            const normal = if (config.faceted)
                flat_n
            else
                [3]f32{ indexed[base + 3], indexed[base + 4], indexed[base + 5] };

            emitVertex(floats, &offset, config.formats, pos, normal);
        }
    }

    std.debug.assert(offset == total_floats);
    return bytes;
}

/// Calculate vertex stride in bytes for given formats.
pub fn calculateStride(formats: []const Format) u32 {
    var stride: u32 = 0;
    for (formats) |fmt| {
        stride += fmt.byteSize();
    }
    return stride;
}

/// Calculate vertex count for a shape with given config.
/// For indexed meshes (teapot, dragon), returns the unique vertex count.
pub fn vertexCountForConfig(shape: ShapeType, config: ShapeConfig) u32 {
    return switch (shape) {
        .cube => 36,
        .plane => 6,
        .sphere => config.segments * config.rings * 6,
        .torus => config.radial_subdivisions * config.body_subdivisions * 6,
        .truncated_cone, .cylinder => blk: {
            const radial = config.radial_subdivisions;
            const vert_sub = config.vertical_subdivisions;
            const extra: u32 = (if (config.top_cap) @as(u32, 2) else 0) + (if (config.bottom_cap) @as(u32, 2) else 0);
            const total_rings = vert_sub + extra;
            var count: u32 = 0;
            for (0..total_rings) |yy_idx| {
                if ((yy_idx == 1 and config.top_cap) or (yy_idx == total_rings - 2 and config.bottom_cap)) continue;
                count += radial * 6;
            }
            break :blk count;
        },
        .teapot, .dragon => indexedVertexCount(shape),
    };
}

/// Shape types supported by the generator
pub const ShapeType = enum {
    cube,
    plane,
    sphere,
    torus,
    truncated_cone,
    cylinder,
    teapot,
    dragon,

    /// Whether this shape produces indexed geometry (separate vertex + index data).
    pub fn isIndexed(self: ShapeType) bool {
        return switch (self) {
            .teapot, .dragon => true,
            else => false,
        };
    }
};

/// Result from indexed mesh generators (teapot, dragon).
/// Caller owns all allocated memory.
pub const IndexedMeshResult = struct {
    vertex_bytes: []u8,
    index_bytes: []u8,
    vertex_count: u32,
    index_count: u32,
    index_format: u8, // 0 = u16, 1 = u32
};

// ============================================================================
// Static Mesh Generators (teapot, dragon)
// ============================================================================

/// Embedded binary mesh data (pre-baked by scripts/convert-meshes.mjs).
/// Binary format: [u32 vertex_count][u32 triangle_count][u32 index_size]
///                [f32×3 × vertex_count positions][f32×3 × vertex_count normals]
///                [index_size × 3 × triangle_count indices]
// Meshes are referenced via build.zig anonymous imports (not a relative
// `meshes/…` path: Zig's @embedFile rejects a cross-tree `../` escape past the
// module root). Canonical home is `src/dsl_sjon/meshes/`.
const teapot_bin = @embedFile("teapot_bin");
const dragon_bin = @embedFile("dragon_bin");

/// Header of an embedded mesh binary.
const MeshBinHeader = struct {
    vertex_count: u32,
    triangle_count: u32,
    index_size: u32, // 2 = u16, 4 = u32
};

fn readMeshBinHeader(data: []const u8) MeshBinHeader {
    std.debug.assert(data.len >= 12);
    return .{
        .vertex_count = std.mem.readInt(u32, data[0..4], .little),
        .triangle_count = std.mem.readInt(u32, data[4..8], .little),
        .index_size = std.mem.readInt(u32, data[8..12], .little),
    };
}

/// Compute projected-plane UVs (project positions onto a 2D plane, normalize to [0,1]).
fn computeProjectedPlaneUVs(
    positions: []const f32, // flat array: [x,y,z, x,y,z, ...]
    vertex_count: u32,
    uv_out: []f32, // output: [u,v, u,v, ...], length = vertex_count * 2
) void {
    std.debug.assert(positions.len >= vertex_count * 3);
    std.debug.assert(uv_out.len >= vertex_count * 2);

    // Use XY projection (matching WebGPU samples default)
    var min_x: f32 = std.math.inf(f32);
    var min_y: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    var max_y: f32 = -std.math.inf(f32);

    for (0..vertex_count) |i| {
        const x = positions[i * 3 + 0];
        const y = positions[i * 3 + 1];
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
    }

    const range_x = max_x - min_x;
    const range_y = max_y - min_y;
    const inv_x = if (range_x > 0) 1.0 / range_x else 0.0;
    const inv_y = if (range_y > 0) 1.0 / range_y else 0.0;

    for (0..vertex_count) |i| {
        uv_out[i * 2 + 0] = (positions[i * 3 + 0] - min_x) * inv_x;
        uv_out[i * 2 + 1] = (positions[i * 3 + 1] - min_y) * inv_y;
    }
}

/// Generate indexed mesh from embedded binary data.
/// Emits interleaved vertex data according to format, plus raw index bytes.
fn generateIndexedMesh(
    allocator: Allocator,
    config: ShapeConfig,
    bin_data: []const u8,
) !IndexedMeshResult {
    // Pre-conditions
    std.debug.assert(config.formats.len > 0);
    std.debug.assert(config.formats.len <= MAX_ATTRIBUTES);
    std.debug.assert(bin_data.len >= 12);

    const header = readMeshBinHeader(bin_data);
    std.debug.assert(header.index_size == 2 or header.index_size == 4);
    std.debug.assert(header.vertex_count > 0);
    std.debug.assert(header.triangle_count > 0);

    const vc = header.vertex_count;
    const tc = header.triangle_count;
    const pos_offset: usize = 12;
    const norm_offset: usize = pos_offset + vc * 3 * 4;
    const idx_offset: usize = norm_offset + vc * 3 * 4;
    const idx_bytes_len: usize = tc * 3 * header.index_size;

    // Validate binary size
    std.debug.assert(bin_data.len >= idx_offset + idx_bytes_len);

    // Copy positions and normals to aligned buffers for safe f32 access
    const pos_floats = try allocator.alloc(f32, vc * 3);
    defer allocator.free(pos_floats);
    const norm_floats = try allocator.alloc(f32, vc * 3);
    defer allocator.free(norm_floats);

    for (0..vc * 3) |i| {
        const p_off = pos_offset + i * 4;
        pos_floats[i] = @bitCast(std.mem.readInt(u32, bin_data[p_off..][0..4], .little));
        const n_off = norm_offset + i * 4;
        norm_floats[i] = @bitCast(std.mem.readInt(u32, bin_data[n_off..][0..4], .little));
    }

    // Compute UVs if needed
    var has_uv = false;
    for (config.formats) |fmt| {
        if (fmt == .uv2) {
            has_uv = true;
            break;
        }
    }

    var uvs: ?[]f32 = null;
    defer if (uvs) |u| allocator.free(u);

    if (has_uv) {
        uvs = try allocator.alloc(f32, vc * 2);
        computeProjectedPlaneUVs(pos_floats, vc, uvs.?);
    }

    // Compute output vertex stride and allocate
    var out_stride: u32 = 0;
    for (config.formats) |fmt| out_stride += fmt.floatCount();

    const total_floats = vc * out_stride;
    const vertex_bytes = try allocator.alloc(u8, total_floats * 4);
    errdefer allocator.free(vertex_bytes);
    const floats: []f32 = @as([*]f32, @ptrCast(@alignCast(vertex_bytes.ptr)))[0..total_floats];

    // Emit interleaved vertex data
    var offset: usize = 0;
    for (0..vc) |i| {
        const pos = [3]f32{ pos_floats[i * 3 + 0], pos_floats[i * 3 + 1], pos_floats[i * 3 + 2] };
        const normal = [3]f32{ norm_floats[i * 3 + 0], norm_floats[i * 3 + 1], norm_floats[i * 3 + 2] };

        for (config.formats) |fmt| {
            switch (fmt) {
                .position3 => {
                    floats[offset + 0] = pos[0];
                    floats[offset + 1] = pos[1];
                    floats[offset + 2] = pos[2];
                    offset += 3;
                },
                .position4 => {
                    floats[offset + 0] = pos[0];
                    floats[offset + 1] = pos[1];
                    floats[offset + 2] = pos[2];
                    floats[offset + 3] = 1.0;
                    offset += 4;
                },
                .normal3 => {
                    floats[offset + 0] = normal[0];
                    floats[offset + 1] = normal[1];
                    floats[offset + 2] = normal[2];
                    offset += 3;
                },
                .color3 => {
                    floats[offset + 0] = 1;
                    floats[offset + 1] = 1;
                    floats[offset + 2] = 1;
                    offset += 3;
                },
                .color4 => {
                    floats[offset + 0] = 1;
                    floats[offset + 1] = 1;
                    floats[offset + 2] = 1;
                    floats[offset + 3] = 1;
                    offset += 4;
                },
                .uv2 => {
                    if (uvs) |u| {
                        floats[offset + 0] = u[i * 2 + 0];
                        floats[offset + 1] = u[i * 2 + 1];
                    } else {
                        floats[offset + 0] = 0;
                        floats[offset + 1] = 0;
                    }
                    offset += 2;
                },
            }
        }
    }
    std.debug.assert(offset == total_floats);

    // Copy index bytes (already in correct binary format)
    const index_bytes = try allocator.alloc(u8, idx_bytes_len);
    errdefer allocator.free(index_bytes);
    @memcpy(index_bytes, bin_data[idx_offset .. idx_offset + idx_bytes_len]);

    return .{
        .vertex_bytes = vertex_bytes,
        .index_bytes = index_bytes,
        .vertex_count = vc,
        .index_count = tc * 3,
        .index_format = if (header.index_size == 2) @as(u8, 0) else @as(u8, 1),
    };
}

/// Generate teapot mesh (792 vertices, 992 triangles, u16 indices).
pub fn generateTeapot(allocator: Allocator, config: ShapeConfig) !IndexedMeshResult {
    return generateIndexedMesh(allocator, config, teapot_bin);
}

/// Generate Stanford dragon mesh (6710 vertices, 11102 triangles, u16 indices).
pub fn generateDragon(allocator: Allocator, config: ShapeConfig) !IndexedMeshResult {
    return generateIndexedMesh(allocator, config, dragon_bin);
}

/// Vertex count for indexed meshes (reads from embedded binary header).
pub fn indexedVertexCount(shape: ShapeType) u32 {
    const bin = switch (shape) {
        .teapot => teapot_bin,
        .dragon => dragon_bin,
        else => unreachable,
    };
    return readMeshBinHeader(bin).vertex_count;
}

/// Index count for indexed meshes (triangle_count * 3).
pub fn indexedIndexCount(shape: ShapeType) u32 {
    const bin = switch (shape) {
        .teapot => teapot_bin,
        .dragon => dragon_bin,
        else => unreachable,
    };
    return readMeshBinHeader(bin).triangle_count * 3;
}

// ============================================================================
// Tests
// ============================================================================

// --- Author-input bounds (LEAK-11 B) ---
//
// These generators used to assert their config — author input treated as an
// invariant — and `generateTruncatedCone` allocated `indexed_count * 6` floats
// ~65 lines before the only cap check. `(truncated-cone :radial-subdivisions
// 20000 :vertical-subdivisions 20000)` therefore asked for ~9.6 GB (and filled
// it) from a ~70-byte form. The test that matters is not "it returns an error"
// but "it returns an error WITHOUT ALLOCATING": a `FailingAllocator` with
// `fail_index = 0` fails the very first allocation, so any attempt at all turns
// the expected refusal into an `OutOfMemory` and fails the test.
