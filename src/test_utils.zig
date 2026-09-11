const std = @import("std");
const Allocator = std.mem.Allocator;

/// Create a threaded IO instance for testing.
/// Caller must deinit returned Threaded instance.
pub fn initTestIo(gpa: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{
        .environ = std.process.Environ.empty,
        .argv0 = .empty,
    });
}
