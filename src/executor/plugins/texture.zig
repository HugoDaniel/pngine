//! Texture Plugin
//!
//! Handles texture creation, views, and image loading.
//! Only included when `(texture …)`, `(texture-view …)`, or `(image-bitmap …)` is used.
//!
//! ## Commands Handled
//!
//! - CREATE_TEXTURE
//! - CREATE_TEXTURE_VIEW
//! - CREATE_IMAGE_BITMAP
//! - COPY_TEXTURE_TO_TEXTURE
//! - COPY_EXTERNAL_IMAGE_TO_TEXTURE
//!
//! ## Invariants
//!
//! - Texture IDs must be unique
//! - Texture views must reference existing textures
//! - Image data must be valid PNG/JPEG format

const std = @import("std");
const assert = std.debug.assert;

const CommandBuffer = @import("../command_buffer.zig").CommandBuffer;
const Cmd = @import("../command_buffer.zig").Cmd;

/// Texture plugin state.
pub const TexturePlugin = struct {
    const Self = @This();

    /// Command buffer to write to.
    cmd_buffer: *CommandBuffer,

    /// Initialize texture plugin with command buffer.
    pub fn init(cmd_buffer: *CommandBuffer) Self {
        // Pre-condition: command buffer initialized
        assert(cmd_buffer.buffer.len >= 8);

        return .{
            .cmd_buffer = cmd_buffer,
        };
    }

    // ========================================================================
    // Texture Creation
    // ========================================================================

    /// Create a texture.
    ///
    /// Args:
    ///   id: Resource ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createTexture(self: *Self, id: u16, desc_ptr: u32, desc_len: u32) void {
        // Pre-condition: descriptor present
        assert(desc_len > 0);

        self.cmd_buffer.createTexture(id, desc_ptr, desc_len);
    }

    /// Create a texture view.
    ///
    /// Args:
    ///   id: View resource ID
    ///   texture_id: Parent texture ID
    ///   desc_ptr: Pointer to descriptor in WASM memory
    ///   desc_len: Descriptor length
    pub fn createTextureView(self: *Self, id: u16, texture_id: u16, desc_ptr: u32, desc_len: u32) void {
        self.cmd_buffer.createTextureView(id, texture_id, desc_ptr, desc_len);
    }

    /// Create an image bitmap from encoded image data.
    ///
    /// Args:
    ///   id: Resource ID
    ///   data_ptr: Pointer to image data in WASM memory
    ///   data_len: Data length
    pub fn createImageBitmap(self: *Self, id: u16, data_ptr: u32, data_len: u32) void {
        // Pre-condition: data present
        assert(data_len > 0);

        self.cmd_buffer.createImageBitmap(id, data_ptr, data_len);
    }

    // ========================================================================
    // Copy Operations
    // ========================================================================

    /// Copy texture to texture.
    ///
    /// Args:
    ///   src_id: Source texture ID
    ///   dst_id: Destination texture ID
    ///   width: Width in pixels
    ///   height: Height in pixels
    pub fn copyTextureToTexture(self: *Self, src_id: u16, dst_id: u16, width: u16, height: u16) void {
        // Pre-conditions
        assert(width > 0);
        assert(height > 0);

        self.cmd_buffer.copyTextureToTexture(src_id, dst_id, width, height);
    }

    /// Copy external image (ImageBitmap/video frame) to texture.
    ///
    /// Args:
    ///   bitmap_id: ImageBitmap resource ID
    ///   texture_id: Destination texture ID
    ///   mip_level: Target mip level
    ///   origin_x: X origin in texture
    ///   origin_y: Y origin in texture
    ///   origin_z: destination array layer / depth slice
    pub fn copyExternalImageToTexture(
        self: *Self,
        bitmap_id: u16,
        texture_id: u16,
        mip_level: u8,
        origin_x: u16,
        origin_y: u16,
        origin_z: u16,
    ) void {
        self.cmd_buffer.copyExternalImageToTexture(bitmap_id, texture_id, mip_level, origin_x, origin_y, origin_z);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
