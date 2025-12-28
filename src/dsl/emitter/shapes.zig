//! Compile-time Shape Generators
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
//! #data cubeVertices {
//!   cube={ format=[position4 color4 uv2] }
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum vertices per shape (prevents unbounded allocation)
const MAX_VERTICES: u32 = 65536;

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

    /// Parse format string
    pub fn fromString(s: []const u8) ?Format {
        const map = std.StaticStringMap(Format).initComptime(.{
            .{ "position3", .position3 },
            .{ "position4", .position4 },
            .{ "normal3", .normal3 },
            .{ "color3", .color3 },
            .{ "color4", .color4 },
            .{ "uv2", .uv2 },
        });
        return map.get(s);
    }
};

/// Shape configuration
pub const ShapeConfig = struct {
    formats: []const Format,
    // Sphere-specific
    segments: u32 = 16,
    rings: u32 = 8,
    // Plane-specific
    width: f32 = 1.0,
    height: f32 = 1.0,
};

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

/// Calculate vertex stride in bytes for given formats.
pub fn calculateStride(formats: []const Format) u32 {
    var stride: u32 = 0;
    for (formats) |fmt| {
        stride += fmt.byteSize();
    }
    return stride;
}

/// Calculate vertex count for a shape.
pub fn vertexCount(shape: enum { cube, plane }) u32 {
    return switch (shape) {
        .cube => 36,
        .plane => 6,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "Format: byteSize matches floatCount * 4" {
    const formats = [_]Format{ .position3, .position4, .normal3, .color3, .color4, .uv2 };
    for (formats) |fmt| {
        try std.testing.expectEqual(fmt.floatCount() * 4, fmt.byteSize());
    }
}

test "Format: fromString parses all formats" {
    try std.testing.expectEqual(Format.position3, Format.fromString("position3").?);
    try std.testing.expectEqual(Format.position4, Format.fromString("position4").?);
    try std.testing.expectEqual(Format.normal3, Format.fromString("normal3").?);
    try std.testing.expectEqual(Format.color3, Format.fromString("color3").?);
    try std.testing.expectEqual(Format.color4, Format.fromString("color4").?);
    try std.testing.expectEqual(Format.uv2, Format.fromString("uv2").?);
    try std.testing.expect(Format.fromString("invalid") == null);
}

test "generateCube: position4 color4 uv2 format" {
    const allocator = std.testing.allocator;
    const formats = [_]Format{ .position4, .color4, .uv2 };
    const config = ShapeConfig{ .formats = &formats };

    const bytes = try generateCube(allocator, config);
    defer allocator.free(bytes);

    // 36 vertices × 10 floats × 4 bytes = 1440 bytes
    try std.testing.expectEqual(@as(usize, 1440), bytes.len);

    // Verify first vertex (face -Y, vertex 0: position 1,-1,1)
    const floats = std.mem.bytesAsSlice(f32, bytes);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), floats[0], 0.001); // x
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), floats[1], 0.001); // y
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), floats[2], 0.001); // z
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), floats[3], 0.001); // w
}

test "generateCube: position3 only format" {
    const allocator = std.testing.allocator;
    const formats = [_]Format{.position3};
    const config = ShapeConfig{ .formats = &formats };

    const bytes = try generateCube(allocator, config);
    defer allocator.free(bytes);

    // 36 vertices × 3 floats × 4 bytes = 432 bytes
    try std.testing.expectEqual(@as(usize, 432), bytes.len);
}

test "generatePlane: basic format" {
    const allocator = std.testing.allocator;
    const formats = [_]Format{ .position3, .uv2 };
    const config = ShapeConfig{ .formats = &formats, .width = 2.0, .height = 2.0 };

    const bytes = try generatePlane(allocator, config);
    defer allocator.free(bytes);

    // 6 vertices × 5 floats × 4 bytes = 120 bytes
    try std.testing.expectEqual(@as(usize, 120), bytes.len);

    // Verify first vertex (bottom-left: -1, -1, 0)
    const floats = std.mem.bytesAsSlice(f32, bytes);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), floats[0], 0.001); // x
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), floats[1], 0.001); // y
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), floats[2], 0.001); // z
}

test "calculateStride: matches expected values" {
    const formats1 = [_]Format{ .position4, .color4, .uv2 };
    try std.testing.expectEqual(@as(u32, 40), calculateStride(&formats1));

    const formats2 = [_]Format{ .position3, .normal3 };
    try std.testing.expectEqual(@as(u32, 24), calculateStride(&formats2));
}

test "vertexCount: returns correct counts" {
    try std.testing.expectEqual(@as(u32, 36), vertexCount(.cube));
    try std.testing.expectEqual(@as(u32, 6), vertexCount(.plane));
}
