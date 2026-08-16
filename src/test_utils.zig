const std = @import("std");

/// Create a threaded IO instance for testing.
/// Caller must deinit returned Threaded instance.
pub fn initTestIo(allocator: std.mem.Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(allocator, .{
        .environ = std.process.Environ.empty,
        .argv0 = .empty,
    });
}
