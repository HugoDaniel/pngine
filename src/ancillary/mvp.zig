//! MVP Matrix Generator for WASM
//!
//! A minimal WASM module that generates Model-View-Projection matrices.
//! Designed to be embedded in PNGine payloads for 3D rendering.
//!
//! ## Exports
//! - `buildMVPMatrix(w: f32, h: f32, t: f32) -> u32` - Returns pointer to 64-byte matrix
//! - `memory` - Linear memory containing the matrix data
//!
//! ## Memory Layout
//! The matrix is stored at offset 0 in memory as 16 consecutive f32 values
//! in column-major order (WebGPU standard).

const std = @import("std");
const math = std.math;

// Static matrix storage at known offset (16 floats = 64 bytes)
var matrix: [16]f32 = undefined;

/// Build a Model-View-Projection matrix for a rotating cube.
///
/// Arguments:
/// - w: Canvas width in pixels
/// - h: Canvas height in pixels
/// - t: Time in seconds (for rotation animation)
///
/// Returns: Pointer to 64 bytes (16 x f32) containing the MVP matrix
export fn buildMVPMatrix(w: f32, h: f32, t: f32) [*]f32 {
    // Pre-condition: valid dimensions
    std.debug.assert(w > 0 and h > 0);

    const aspect = w / h;
    const fov: f32 = (2.0 * math.pi) / 5.0; // 72 degrees

    // Build perspective projection matrix
    var projection: [16]f32 = undefined;
    perspectiveMatrix(&projection, fov, aspect, 1.0, 100.0);

    // Build view matrix: identity -> translate -> rotate
    var view: [16]f32 = undefined;
    identityMatrix(&view);

    // Translate camera back by -4 on Z axis
    translateMatrix(&view, 0.0, 0.0, -4.0);

    // Rotate around Y axis by time
    rotateY(&view, t);

    // MVP = projection * view
    multiplyMatrix(&matrix, &projection, &view);

    // Post-condition: matrix has valid values
    std.debug.assert(!math.isNan(matrix[0]));

    return &matrix;
}

/// Create a 4x4 identity matrix
fn identityMatrix(m: *[16]f32) void {
    m.* = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
}

/// Create a perspective projection matrix (WebGPU: Z range [0, 1])
fn perspectiveMatrix(m: *[16]f32, fov_y: f32, aspect: f32, z_near: f32, z_far: f32) void {
    const f = 1.0 / math.tan(fov_y * 0.5);
    const range_inv = 1.0 / (z_near - z_far);

    m.* = .{
        f / aspect, 0, 0,                        0,
        0,          f, 0,                        0,
        0,          0, z_far * range_inv,        -1,
        0,          0, z_far * z_near * range_inv, 0,
    };
}

/// Apply translation to a matrix (in-place)
fn translateMatrix(m: *[16]f32, x: f32, y: f32, z: f32) void {
    // Column-major: translation is in column 3 (indices 12, 13, 14)
    // For identity matrix this is simple, but for general case:
    // m[12] = m[0]*x + m[4]*y + m[8]*z + m[12]
    // m[13] = m[1]*x + m[5]*y + m[9]*z + m[13]
    // m[14] = m[2]*x + m[6]*y + m[10]*z + m[14]
    // m[15] = m[3]*x + m[7]*y + m[11]*z + m[15]
    m[12] = m[0] * x + m[4] * y + m[8] * z + m[12];
    m[13] = m[1] * x + m[5] * y + m[9] * z + m[13];
    m[14] = m[2] * x + m[6] * y + m[10] * z + m[14];
    m[15] = m[3] * x + m[7] * y + m[11] * z + m[15];
}

/// Apply rotation around Y axis to a matrix (in-place)
fn rotateY(m: *[16]f32, angle: f32) void {
    const c = math.cos(angle);
    const s = math.sin(angle);

    // Rotation matrix around Y:
    // [ c  0  s  0]
    // [ 0  1  0  0]
    // [-s  0  c  0]
    // [ 0  0  0  1]

    // Save original column 0 and column 2
    const m0 = m[0];
    const m1 = m[1];
    const m2 = m[2];
    const m3 = m[3];
    const m8 = m[8];
    const m9 = m[9];
    const m10 = m[10];
    const m11 = m[11];

    // New column 0 = old_col0 * c + old_col2 * (-s)
    m[0] = m0 * c - m8 * s;
    m[1] = m1 * c - m9 * s;
    m[2] = m2 * c - m10 * s;
    m[3] = m3 * c - m11 * s;

    // New column 2 = old_col0 * s + old_col2 * c
    m[8] = m0 * s + m8 * c;
    m[9] = m1 * s + m9 * c;
    m[10] = m2 * s + m10 * c;
    m[11] = m3 * s + m11 * c;
}

/// Multiply two 4x4 matrices: result = a * b
fn multiplyMatrix(result: *[16]f32, a: *const [16]f32, b: *const [16]f32) void {
    // Column-major multiplication
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| {
                sum += a[k * 4 + row] * b[col * 4 + k];
            }
            result[col * 4 + row] = sum;
        }
    }
}

// Tests
test "identity matrix" {
    var m: [16]f32 = undefined;
    identityMatrix(&m);
    try std.testing.expectEqual(@as(f32, 1), m[0]);
    try std.testing.expectEqual(@as(f32, 1), m[5]);
    try std.testing.expectEqual(@as(f32, 1), m[10]);
    try std.testing.expectEqual(@as(f32, 1), m[15]);
    try std.testing.expectEqual(@as(f32, 0), m[1]);
}

test "perspective matrix non-nan" {
    var m: [16]f32 = undefined;
    perspectiveMatrix(&m, math.pi / 4.0, 1.0, 0.1, 100.0);
    for (m) |v| {
        try std.testing.expect(!math.isNan(v));
    }
}

test "buildMVPMatrix returns valid matrix" {
    const ptr = buildMVPMatrix(512, 512, 0);
    for (0..16) |i| {
        try std.testing.expect(!math.isNan(ptr[i]));
    }
}

test "buildMVPMatrix rotation changes matrix" {
    const ptr1 = buildMVPMatrix(512, 512, 0);
    var m1: [16]f32 = undefined;
    @memcpy(&m1, ptr1[0..16]);

    const ptr2 = buildMVPMatrix(512, 512, 1.0);
    var different = false;
    for (0..16) |i| {
        if (m1[i] != ptr2[i]) {
            different = true;
            break;
        }
    }
    try std.testing.expect(different);
}
