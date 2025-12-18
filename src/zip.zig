//! ZIP archive support for PNGine bundles
//!
//! ## Bundle Format
//! ```
//! shader.zip
//! ├── manifest.json    # Entry point and version
//! ├── pngine.wasm     # Optional: bundled runtime
//! ├── main.pngb       # Compiled bytecode
//! └── assets/         # Optional assets
//! ```
//!
//! ## Usage
//! ```zig
//! const zip = @import("zip.zig");
//!
//! // Read ZIP
//! var reader = try zip.ZipReader.init(allocator, data);
//! defer reader.deinit();
//! const bytecode = try reader.extract("main.pngb");
//!
//! // Write ZIP
//! var writer = zip.ZipWriter.init(allocator);
//! defer writer.deinit();
//! try writer.addFile("main.pngb", bytecode, .deflate);
//! const zip_data = try writer.finish();
//! ```

pub const format = @import("zip/format.zig");
pub const reader = @import("zip/reader.zig");
pub const writer = @import("zip/writer.zig");

pub const ZipReader = reader.ZipReader;
pub const ZipWriter = writer.ZipWriter;
pub const Entry = reader.Entry;
pub const CompressionMethod = writer.CompressionMethod;

/// Check if data is a ZIP file
pub fn isZip(data: []const u8) bool {
    return format.isZip(data);
}

test {
    _ = format;
    _ = reader;
    _ = writer;
    _ = @import("zip/zip_test.zig");
}
