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

/// A scratch directory whose absolute path the commands can spell.
///
/// Deliberately NOT `std.testing.tmpDir` + `Dir.realPath`: zig 0.16's
/// `realPathPosix` returns `error.OperationUnsupported` on OpenBSD, so a test
/// harness that canonicalises its tmpdir there crashes before the command
/// runs. `currentPathAlloc` + `createDirPathOpen` (the recipe `pipe_e2e.zig`
/// and `walk_test.zig` already use) are implemented on every target this
/// suite runs on; the absolute path is the process cwd plus the unique name
/// this helper creates, so no OS canonicalisation is needed.
///
/// `prefix` names the lane; the random suffix keeps concurrent tests apart.
pub const Scratch = struct {
    dir: std.Io.Dir,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn init(gpa: Allocator, io: std.Io, prefix: []const u8) !Scratch {
        var s: Scratch = .{ .dir = undefined };
        const cwd = try std.process.currentPathAlloc(io, gpa);
        defer gpa.free(cwd);

        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        var name: [12]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random_bytes);

        const p = try std.fmt.bufPrint(&s.path_buf, "{s}/.zig-cache/tmp/{s}-{s}", .{ cwd, prefix, name });
        s.dir = try std.Io.Dir.cwd().createDirPathOpen(io, p, .{});
        s.path_len = p.len;
        return s;
    }

    pub fn path(self: *const Scratch) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn deinit(self: *Scratch, io: std.Io) void {
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path()) catch {};
        self.* = undefined;
    }

    /// `<scratch>/<name>`, sentinel-terminated, in `buf`.
    pub fn file(self: *const Scratch, buf: []u8, name: []const u8) [:0]const u8 {
        return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ self.path(), name }) catch unreachable;
    }
};
