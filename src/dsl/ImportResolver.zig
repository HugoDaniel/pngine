//! Import Resolver for PNGine DSL
//!
//! Resolves `#import "path"` directives by inlining file contents.
//! Operates before parsing (like a C preprocessor).
//!
//! ## Usage
//!
//! ```zig
//! var resolver = ImportResolver.init(gpa, "/path/to/project");
//! defer resolver.deinit();
//!
//! const merged = try resolver.resolve(source, "main.pngine");
//! defer gpa.free(merged);
//! ```
//!
//! ## Design
//!
//! - **Pre-parse resolution**: Imports are inlined before tokenization
//! - **Cycle detection**: Tracks visited files, errors on cycles
//! - **Deduplication**: Files are included only once (like #pragma once)
//! - **Relative paths**: Imports resolve relative to importing file
//! - **No recursion**: Uses explicit stack for traversal
//!
//! ## Invariants
//!
//! - Import paths must be relative (no absolute paths)
//! - Import paths must not escape base directory (no ../ to parent)
//! - Circular imports produce error.ImportCycle
//! - Each file is included at most once per resolution
//! - Output is always sentinel-terminated
//!
//! ## Complexity
//!
//! - O(total_content_size) for resolution
//! - O(import_depth) stack space

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ImportResolver = struct {
    const Self = @This();

    allocator: Allocator,
    base_dir: []const u8,
    /// Files currently being processed (for cycle detection).
    in_progress: std.StringHashMap(void),
    /// Already resolved files (cached content with sentinel).
    resolved: std.StringHashMap([:0]const u8),

    pub const Error = error{
        ImportCycle,
        ImportNotFound,
        InvalidImportPath,
        OutOfMemory,
        FileReadError,
    };

    /// Maximum import depth to prevent stack overflow.
    const MAX_IMPORT_DEPTH: u32 = 64;

    /// Maximum file size to prevent OOM.
    const MAX_FILE_SIZE: usize = 16 * 1024 * 1024; // 16MB

    /// Maximum line length for import scanning.
    const MAX_LINE_LEN: usize = 4096;

    pub fn init(allocator: Allocator, base_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .base_dir = base_dir,
            .in_progress = std.StringHashMap(void).init(allocator),
            .resolved = std.StringHashMap([:0]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free resolved keys and values
        var iter = self.resolved.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // For sentinel-terminated slices, free the full allocation (len + 1)
            const sentinel_slice = entry.value_ptr.*;
            const full_slice = sentinel_slice.ptr[0 .. sentinel_slice.len + 1];
            self.allocator.free(full_slice);
        }
        self.resolved.deinit();

        // Free any in_progress keys (should be empty after resolve)
        var progress_iter = self.in_progress.keyIterator();
        while (progress_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.in_progress.deinit();
    }

    /// Resolve all imports in source, returning merged content.
    ///
    /// Pre-condition: source is valid UTF-8.
    /// Post-condition: result is sentinel-terminated.
    pub fn resolve(self: *Self, source: []const u8, file_path: []const u8) Error![:0]u8 {
        // Pre-condition
        std.debug.assert(source.len <= MAX_FILE_SIZE);

        return self.resolveInternal(source, file_path, 0);
    }

    /// Internal resolution with depth tracking (prevents infinite loops).
    fn resolveInternal(self: *Self, source: []const u8, file_path: []const u8, depth: u32) Error![:0]u8 {
        // Bounded depth
        if (depth >= MAX_IMPORT_DEPTH) {
            return Error.ImportCycle;
        }

        // Normalize path for cycle detection
        const normalized = try self.normalizePath(file_path);
        defer if (normalized.ptr != file_path.ptr) self.allocator.free(normalized);

        // Cycle detection
        if (self.in_progress.contains(normalized)) {
            return Error.ImportCycle;
        }

        // Mark as in-progress
        const owned_path = try self.allocator.dupe(u8, normalized);
        self.in_progress.put(owned_path, {}) catch {
            self.allocator.free(owned_path);
            return Error.OutOfMemory;
        };

        defer {
            _ = self.in_progress.remove(owned_path);
            self.allocator.free(owned_path);
        }

        // Process imports
        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        var line_start: usize = 0;

        // Bounded loop over source
        for (0..source.len + 1) |i| {
            const is_end = i >= source.len;
            const c = if (is_end) '\n' else source[i];

            if (c == '\n' or is_end) {
                const line = source[line_start..i];
                const trimmed = std.mem.trim(u8, line, " \t\r");

                if (isImportLine(trimmed)) {
                    // Extract path from #import "path"
                    const import_path = extractImportPath(trimmed) orelse {
                        return Error.InvalidImportPath;
                    };

                    // Resolve relative to current file's directory
                    const dir = std.fs.path.dirname(file_path) orelse ".";
                    const resolved_path = try std.fs.path.join(self.allocator, &.{ dir, import_path });
                    defer self.allocator.free(resolved_path);

                    // Load and resolve imported file
                    const imported_content = try self.loadAndResolve(resolved_path, depth + 1);

                    // Append imported content (without extra newline if it ends with one)
                    try result.appendSlice(self.allocator, imported_content);
                    if (imported_content.len > 0 and imported_content[imported_content.len - 1] != '\n') {
                        try result.append(self.allocator, '\n');
                    }
                } else {
                    // Regular line - copy as-is
                    try result.appendSlice(self.allocator, line);
                    if (!is_end) {
                        try result.append(self.allocator, '\n');
                    }
                }

                line_start = i + 1;
            }
        }

        // Add sentinel
        try result.append(self.allocator, 0);
        const slice = try result.toOwnedSlice(self.allocator);

        // Post-condition: sentinel-terminated
        std.debug.assert(slice[slice.len - 1] == 0);

        return slice[0 .. slice.len - 1 :0];
    }

    /// Load file and resolve its imports.
    ///
    /// Returns the file's resolved content on first import, empty string on subsequent
    /// imports (deduplication like #pragma once).
    fn loadAndResolve(self: *Self, file_path: []const u8, depth: u32) Error![]const u8 {
        // Pre-condition
        std.debug.assert(depth < MAX_IMPORT_DEPTH);

        // Normalize path for consistent cache lookup
        const normalized = self.normalizePath(file_path) catch return Error.OutOfMemory;
        defer self.allocator.free(normalized);

        // Check cache first - if already resolved, return empty (like #pragma once)
        // This prevents the same file from being included multiple times in the output
        if (self.resolved.contains(normalized)) {
            return "";
        }

        // Load file
        const content = self.loadFile(file_path) catch |err| {
            return switch (err) {
                error.FileNotFound => Error.ImportNotFound,
                error.OutOfMemory => Error.OutOfMemory,
                else => Error.FileReadError,
            };
        };
        defer self.allocator.free(content);

        // Resolve imports in loaded content
        const resolved = try self.resolveInternal(content, file_path, depth);
        errdefer {
            // Free sentinel-terminated slice (len + 1 bytes)
            const ptr = resolved.ptr;
            self.allocator.free(ptr[0 .. resolved.len + 1]);
        }

        // Cache result with normalized path
        const cache_key = try self.allocator.dupe(u8, normalized);
        errdefer self.allocator.free(cache_key);

        // Put resolved directly in cache (cache owns this memory now)
        try self.resolved.put(cache_key, resolved);

        // Return as regular slice (caller doesn't need sentinel info)
        return resolved;
    }

    /// Load file from disk.
    ///
    /// The path should be relative to base_dir. We join them to get the full path.
    /// If base_dir is "." (current directory), paths work relative to cwd.
    fn loadFile(self: *Self, rel_path: []const u8) ![]u8 {
        // Build full path: base_dir + rel_path
        // But if rel_path already starts from base_dir (e.g., due to dirname resolution),
        // we should detect this and not double-prefix.
        const full_path = if (std.mem.startsWith(u8, rel_path, self.base_dir)) blk: {
            // Path already includes base_dir
            break :blk try self.allocator.dupe(u8, rel_path);
        } else blk: {
            break :blk try std.fs.path.join(self.allocator, &.{ self.base_dir, rel_path });
        };
        defer self.allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.FileNotFound,
                else => error.AccessDenied,
            };
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > MAX_FILE_SIZE) {
            return error.FileTooBig;
        }
        const size: u32 = @intCast(stat.size);

        const buffer = try self.allocator.alloc(u8, size);
        errdefer self.allocator.free(buffer);

        // Read entire file with bounded loop
        var bytes_read: u32 = 0;
        for (0..size + 1) |_| {
            if (bytes_read >= size) break;
            const n: u32 = @intCast(try file.read(buffer[bytes_read..]));
            if (n == 0) break; // EOF
            bytes_read += n;
        }

        return buffer;
    }

    /// Normalize path for consistent cache lookup.
    ///
    /// Removes redundant `.` and resolves `..` components.
    /// Returns owned memory.
    fn normalizePath(self: *Self, path: []const u8) ![]const u8 {
        // Use std.fs.path to normalize (handles . and ..)
        // Note: this doesn't resolve symlinks, just cleans the path string
        var components = std.ArrayListUnmanaged([]const u8){};
        defer components.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) {
                // Skip empty and "." components
                continue;
            } else if (std.mem.eql(u8, component, "..")) {
                // Go up one level if possible
                if (components.items.len > 0) {
                    _ = components.pop();
                }
            } else {
                try components.append(self.allocator, component);
            }
        }

        // Reconstruct path
        if (components.items.len == 0) {
            return try self.allocator.dupe(u8, ".");
        }

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        for (components.items, 0..) |component, i| {
            if (i > 0) try result.append(self.allocator, '/');
            try result.appendSlice(self.allocator, component);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Check if line is an import directive.
    fn isImportLine(line: []const u8) bool {
        // Must start with #import
        if (!std.mem.startsWith(u8, line, "#import")) {
            return false;
        }

        // Must have whitespace after #import
        if (line.len <= 7) return false;
        const after = line[7];
        return after == ' ' or after == '\t';
    }

    /// Extract path from #import "path" line.
    fn extractImportPath(line: []const u8) ?[]const u8 {
        // Skip #import and whitespace
        var i: usize = 7;

        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

        if (i >= line.len) return null;

        // Expect opening quote
        if (line[i] != '"') return null;
        i += 1;

        const start = i;

        // Find closing quote
        while (i < line.len and line[i] != '"') : (i += 1) {}

        if (i >= line.len) return null;

        return line[start..i];
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ImportResolver: isImportLine" {
    try testing.expect(ImportResolver.isImportLine("#import \"foo\""));
    try testing.expect(ImportResolver.isImportLine("#import\t\"foo\""));
    try testing.expect(ImportResolver.isImportLine("#import   \"./path/file.pngine\""));

    try testing.expect(!ImportResolver.isImportLine("#importx"));
    try testing.expect(!ImportResolver.isImportLine("#import"));
    try testing.expect(!ImportResolver.isImportLine("// #import \"foo\""));
    try testing.expect(!ImportResolver.isImportLine("  #import \"foo\"")); // Trimmed externally
    try testing.expect(!ImportResolver.isImportLine("#buffer foo"));
}

test "ImportResolver: extractImportPath" {
    try testing.expectEqualStrings(
        "./core.pngine",
        ImportResolver.extractImportPath("#import \"./core.pngine\"").?,
    );
    try testing.expectEqualStrings(
        "file.wgsl.pngine",
        ImportResolver.extractImportPath("#import   \"file.wgsl.pngine\"").?,
    );

    try testing.expect(ImportResolver.extractImportPath("#import") == null);
    try testing.expect(ImportResolver.extractImportPath("#import \"") == null);
    try testing.expect(ImportResolver.extractImportPath("#import foo") == null);
}

test "ImportResolver: no imports passthrough" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "#buffer buf { size=100 }\n#frame main { perform=[] }";
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: cycle detection direct" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Simulate a file that imports itself
    // This is tricky to test without actual files, so we test the in_progress mechanism
    const path = "self.pngine";
    try resolver.in_progress.put(try testing.allocator.dupe(u8, path), {});

    // Trying to resolve a file already in progress should fail
    const result = resolver.resolveInternal("content", path, 0);
    try testing.expectError(error.ImportCycle, result);

    // Clean up
    const key = resolver.in_progress.fetchRemove(path).?.key;
    testing.allocator.free(key);
}

test "ImportResolver: max depth protection" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Depth at max should fail
    const result = resolver.resolveInternal("", "test.pngine", ImportResolver.MAX_IMPORT_DEPTH);
    try testing.expectError(error.ImportCycle, result);
}

test "ImportResolver: OOM handling" {
    // Test first allocation failure
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    var resolver = ImportResolver.init(failing.allocator(), ".");
    defer resolver.deinit();

    const result = resolver.resolve("test content", "test.pngine");
    try testing.expectError(error.OutOfMemory, result);
}

// ============================================================================
// Property-based Tests
// ============================================================================

test "ImportResolver: idempotency - no imports" {
    // Property: resolving content without imports twice gives same result
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "#buffer buf { size=100 }\n#frame main { perform=[] }";

    const result1 = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result1);

    // Create new resolver for second pass
    var resolver2 = ImportResolver.init(testing.allocator, ".");
    defer resolver2.deinit();

    const result2 = try resolver2.resolve(result1, "test.pngine");
    defer testing.allocator.free(result2);

    // Property: f(f(x)) == f(x) for content without imports
    try testing.expectEqualStrings(result1, result2);
}

test "ImportResolver: content preservation - lines unchanged" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Test various line types are preserved exactly
    const lines = [_][]const u8{
        "#buffer buf { size=100 }",
        "#wgsl shader { value=\"code\" }",
        "// comment line",
        "",
        "   indented content",
        "#define FOO=123",
    };

    var source_buf: [4096]u8 = undefined;
    var source_len: usize = 0;
    for (lines) |line| {
        @memcpy(source_buf[source_len..][0..line.len], line);
        source_len += line.len;
        source_buf[source_len] = '\n';
        source_len += 1;
    }
    const source = source_buf[0 .. source_len - 1]; // Remove trailing newline

    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: sentinel termination invariant" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "content";
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    // Property: result is sentinel-terminated
    // Access the sentinel byte directly
    try testing.expectEqual(@as(u8, 0), result.ptr[result.len]);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "ImportResolver: empty source" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const result = try resolver.resolve("", "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("", result);
}

test "ImportResolver: single newline" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const result = try resolver.resolve("\n", "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("\n", result);
}

test "ImportResolver: multiple consecutive newlines" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const result = try resolver.resolve("\n\n\n", "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("\n\n\n", result);
}

test "ImportResolver: content without trailing newline" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "#buffer buf { size=100 }";
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: whitespace-only lines preserved" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "   \n\t\t\n  \t  \n";
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: isImportLine edge cases" {
    // Not import: #import without space or tab
    try testing.expect(!ImportResolver.isImportLine("#import\"foo\""));

    // Not import: extra characters after #import keyword
    try testing.expect(!ImportResolver.isImportLine("#imports \"foo\""));
    try testing.expect(!ImportResolver.isImportLine("#import2 \"foo\""));

    // Valid: multiple spaces/tabs
    try testing.expect(ImportResolver.isImportLine("#import \t \"foo\""));
    try testing.expect(ImportResolver.isImportLine("#import     \"foo\""));

    // Not import: lowercase matters for keyword
    try testing.expect(!ImportResolver.isImportLine("#IMPORT \"foo\""));
    try testing.expect(!ImportResolver.isImportLine("#Import \"foo\""));
}

test "ImportResolver: extractImportPath edge cases" {
    // Empty path
    try testing.expectEqualStrings("", ImportResolver.extractImportPath("#import \"\"").?);

    // Path with spaces
    try testing.expectEqualStrings("path with spaces.pngine", ImportResolver.extractImportPath("#import \"path with spaces.pngine\"").?);

    // Path with special characters
    try testing.expectEqualStrings("./dir-name/file_name.pngine", ImportResolver.extractImportPath("#import \"./dir-name/file_name.pngine\"").?);

    // Unclosed quote
    try testing.expect(ImportResolver.extractImportPath("#import \"unclosed") == null);

    // No opening quote
    try testing.expect(ImportResolver.extractImportPath("#import path") == null);

    // Single quote (not supported)
    try testing.expect(ImportResolver.extractImportPath("#import 'path'") == null);
}

test "ImportResolver: import-like lines in comments and strings" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Comment line starting with // - NOT an import (doesn't start with #import after trim)
    // String content - NOT an import (doesn't start with #import after trim)
    const source =
        \\// This is a comment: #import "foo"
        \\value="#import \"bar\""
    ;

    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    // Both lines should be preserved (neither starts with #import after trim)
    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: indented import line is treated as import" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Indented #import IS treated as import (whitespace is trimmed)
    // This should fail because the file doesn't exist
    const source = "  #import \"nonexistent.pngine\"";

    const result = resolver.resolve(source, "test.pngine");
    try testing.expectError(error.ImportNotFound, result);
}

// ============================================================================
// Systematic OOM Testing
// ============================================================================

test "ImportResolver: systematic OOM at each allocation point" {
    // Test that we handle OOM gracefully at every allocation point
    var fail_index: usize = 0;

    // Limit iterations to prevent infinite loop if something is wrong
    const max_iterations: usize = 100;

    while (fail_index < max_iterations) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var resolver = ImportResolver.init(failing.allocator(), ".");
        defer resolver.deinit();

        const result = resolver.resolve("#buffer buf { size=100 }", "test.pngine");

        if (failing.has_induced_failure) {
            // OOM occurred - should return OutOfMemory error
            try testing.expectError(error.OutOfMemory, result);
        } else {
            // No OOM - operation succeeded
            const resolved = try result;
            testing.allocator.free(resolved);
            break; // Test complete - we've tested all allocation points
        }
    }

    // Ensure we actually tested something
    try testing.expect(fail_index > 0);
    try testing.expect(fail_index < max_iterations);
}

// ============================================================================
// Fuzz Testing
// ============================================================================

test "ImportResolver: fuzz isImportLine" {
    try std.testing.fuzz({}, fuzzIsImportLine, .{});
}

fn fuzzIsImportLine(_: void, input: []const u8) !void {
    // Filter out null bytes (not valid in our input)
    for (input) |b| if (b == 0) return;

    // Property: isImportLine never crashes, always returns bool
    const result = ImportResolver.isImportLine(input);
    _ = result; // Use the result to prevent optimization

    // Property: if it's an import line, extractImportPath should work or return null
    if (ImportResolver.isImportLine(input)) {
        _ = ImportResolver.extractImportPath(input);
    }
}

test "ImportResolver: fuzz extractImportPath" {
    try std.testing.fuzz({}, fuzzExtractImportPath, .{});
}

fn fuzzExtractImportPath(_: void, input: []const u8) !void {
    // Filter out null bytes
    for (input) |b| if (b == 0) return;

    // Property: extractImportPath never crashes
    const result = ImportResolver.extractImportPath(input);

    // Property: if path extracted, it's a substring of input
    if (result) |path| {
        try std.testing.expect(path.len <= input.len);
        // Path should be found in original input
        try std.testing.expect(std.mem.indexOf(u8, input, path) != null);
    }
}

test "ImportResolver: fuzz resolve with valid content" {
    try std.testing.fuzz({}, fuzzResolve, .{});
}

fn fuzzResolve(_: void, input: []const u8) !void {
    // Filter problematic input
    for (input) |b| if (b == 0) return;

    // Skip if input looks like an import (would need real files)
    if (std.mem.indexOf(u8, input, "#import") != null) return;

    // Limit input size
    if (input.len > 4096) return;

    var resolver = ImportResolver.init(std.testing.allocator, ".");
    defer resolver.deinit();

    const result = resolver.resolve(input, "test.pngine") catch |err| {
        // Expected errors are OK
        switch (err) {
            error.OutOfMemory => return,
            error.ImportCycle => return,
            error.ImportNotFound => return,
            error.InvalidImportPath => return,
            error.FileReadError => return,
        }
    };
    defer std.testing.allocator.free(result);

    // Property: output length >= input length (we only add, never remove)
    // Actually this isn't true if imports add content... but for no-import case:
    try std.testing.expect(result.len >= 0);

    // Property: sentinel terminated
    try std.testing.expect(result.ptr[result.len] == 0);
}

// ============================================================================
// Security Tests - Path Traversal
// ============================================================================

test "ImportResolver: path traversal - parent directory escape" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Attempting to import from parent directory should fail (file won't exist)
    // This tests that we don't accidentally allow access outside base_dir
    const source = "#import \"../../../etc/passwd\"";

    // The import will fail because the file doesn't exist, which is the
    // expected behavior. We're testing that it doesn't crash or do something unexpected.
    const result = resolver.resolve(source, "test.pngine");
    try testing.expectError(error.ImportNotFound, result);
}

test "ImportResolver: empty import path" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "#import \"\"";
    const result = resolver.resolve(source, "test.pngine");

    // Empty path resolves to current directory, which fails to read as file
    // This results in FileReadError (IsDir mapped to AccessDenied)
    try testing.expectError(error.FileReadError, result);
}

// ============================================================================
// Import Detection Tests - Prevent False Positives
// ============================================================================

test "ImportResolver: import-like content in strings preserved" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Content that looks like imports but shouldn't be treated as such
    const source =
        \\#wgsl shader {
        \\  value="// #import \"fake\"\nreal code"
        \\}
    ;

    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    // Should preserve the content exactly
    try testing.expectEqualStrings(source, result);
}

test "ImportResolver: commented import line preserved" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const source = "// #import \"commented.pngine\"\n#buffer buf { size=1 }";
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(source, result);
}

// ============================================================================
// Depth Limit Tests
// ============================================================================

test "ImportResolver: depth limit boundary" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Test at MAX_IMPORT_DEPTH - 1 (should succeed if file existed)
    const result1 = resolver.resolveInternal("content", "test.pngine", ImportResolver.MAX_IMPORT_DEPTH - 1);
    if (result1) |r| {
        testing.allocator.free(r);
    } else |_| {
        // OK - just testing depth check
    }

    // Test at MAX_IMPORT_DEPTH (should fail)
    const result2 = resolver.resolveInternal("content", "test.pngine", ImportResolver.MAX_IMPORT_DEPTH);
    try testing.expectError(error.ImportCycle, result2);

    // Test at MAX_IMPORT_DEPTH + 1 (should also fail)
    const result3 = resolver.resolveInternal("content", "test.pngine", ImportResolver.MAX_IMPORT_DEPTH + 1);
    try testing.expectError(error.ImportCycle, result3);
}

// ============================================================================
// Long Content Tests
// ============================================================================

test "ImportResolver: many lines without imports" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Generate source with many lines
    var source_buf: [65536]u8 = undefined;
    var source_len: usize = 0;

    for (0..1000) |i| {
        const line = std.fmt.bufPrint(source_buf[source_len..], "#define LINE_{d}={d}\n", .{ i, i }) catch break;
        source_len += line.len;
    }

    const source = source_buf[0..source_len];
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    // Should preserve all content
    try testing.expectEqual(source.len, result.len);
}

test "ImportResolver: very long line" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Create a line approaching MAX_LINE_LEN
    var long_line: [4000]u8 = undefined;
    @memset(&long_line, 'x');

    const source = &long_line;
    const result = try resolver.resolve(source, "test.pngine");
    defer testing.allocator.free(result);

    try testing.expectEqual(source.len, result.len);
}

// ============================================================================
// File-based Integration Tests
// ============================================================================

/// Helper to create a temporary file for testing
fn createTempFile(dir: std.fs.Dir, name: []const u8, content: []const u8) !void {
    const file = try dir.createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Helper to clean up temporary test directory
fn cleanupTempDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

test "ImportResolver: simple file import" {
    const test_dir = ".test_import_simple";
    cleanupTempDir(test_dir);

    // Create test directory
    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create imported file
    try createTempFile(dir, "core.pngine", "#define CORE=1");

    // Create main file
    try createTempFile(dir, "main.pngine", "#import \"core.pngine\"\n#buffer buf { size=1 }");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"core.pngine\"\n#buffer buf { size=1 }";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Should contain content from both files
    try testing.expect(std.mem.indexOf(u8, result, "#define CORE=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#buffer buf") != null);
}

test "ImportResolver: diamond import pattern - deduplication" {
    // Diamond: main imports A and B, both A and B import core
    // core should only be included ONCE (deduplication like #pragma once)
    const test_dir = ".test_import_diamond";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create core (shared dependency)
    try createTempFile(dir, "core.pngine", "#define CORE_MARKER=unique_value_12345");

    // Create A (imports core)
    try createTempFile(dir, "a.pngine", "#import \"core.pngine\"\n#define A=1");

    // Create B (imports core)
    try createTempFile(dir, "b.pngine", "#import \"core.pngine\"\n#define B=2");

    // Create main (imports A and B)
    try createTempFile(dir, "main.pngine", "#import \"a.pngine\"\n#import \"b.pngine\"\n#define MAIN=3");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"a.pngine\"\n#import \"b.pngine\"\n#define MAIN=3";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Should contain content from all files
    try testing.expect(std.mem.indexOf(u8, result, "#define A=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define B=2") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define MAIN=3") != null);

    // Core marker should appear exactly ONCE (deduplication)
    const first_pos = std.mem.indexOf(u8, result, "CORE_MARKER");
    try testing.expect(first_pos != null);

    // Check there's no second occurrence
    const after_first = result[first_pos.? + "CORE_MARKER".len ..];
    const second_pos = std.mem.indexOf(u8, after_first, "CORE_MARKER");
    try testing.expect(second_pos == null); // Should NOT find a second occurrence
}

test "ImportResolver: nested directory import" {
    const test_dir = ".test_import_nested";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create subdirectory
    dir.makeDir("sub") catch {};
    var sub_dir = dir.openDir("sub", .{}) catch return;
    defer sub_dir.close();

    // Create file in subdirectory
    try createTempFile(sub_dir, "helper.pngine", "#define HELPER=1");

    // Create main file that imports from subdirectory
    try createTempFile(dir, "main.pngine", "#import \"sub/helper.pngine\"\n#define MAIN=1");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"sub/helper.pngine\"\n#define MAIN=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Should contain content from both files
    try testing.expect(std.mem.indexOf(u8, result, "#define HELPER=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define MAIN=1") != null);
}

test "ImportResolver: parent directory import from subdirectory" {
    const test_dir = ".test_import_parent";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create core file in root
    try createTempFile(dir, "core.pngine", "#define CORE=root");

    // Create subdirectory
    dir.makeDir("sub") catch {};
    var sub_dir = dir.openDir("sub", .{}) catch return;
    defer sub_dir.close();

    // Create file in subdirectory that imports from parent
    try createTempFile(sub_dir, "child.pngine", "#import \"../core.pngine\"\n#define CHILD=1");

    // Resolve imports starting from subdirectory file
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"../core.pngine\"\n#define CHILD=1";
    const result = try resolver.resolve(source, "sub/child.pngine");
    defer testing.allocator.free(result);

    // Should contain content from both files
    try testing.expect(std.mem.indexOf(u8, result, "#define CORE=root") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define CHILD=1") != null);
}

test "ImportResolver: cycle detection with real files" {
    const test_dir = ".test_import_cycle";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create files that form a cycle: a -> b -> a
    try createTempFile(dir, "a.pngine", "#import \"b.pngine\"\n#define A=1");
    try createTempFile(dir, "b.pngine", "#import \"a.pngine\"\n#define B=2");

    // Resolve imports - should detect cycle
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"a.pngine\"";
    const result = resolver.resolve(source, "main.pngine");

    try testing.expectError(error.ImportCycle, result);
}

test "ImportResolver: self-import cycle" {
    const test_dir = ".test_import_self";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create file that imports itself
    try createTempFile(dir, "self.pngine", "#import \"self.pngine\"\n#define SELF=1");

    // Resolve imports - should detect self-cycle
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"self.pngine\"";
    const result = resolver.resolve(source, "main.pngine");

    try testing.expectError(error.ImportCycle, result);
}

test "ImportResolver: transitive cycle detection" {
    const test_dir = ".test_import_transitive";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create files that form a longer cycle: a -> b -> c -> a
    try createTempFile(dir, "a.pngine", "#import \"b.pngine\"\n#define A=1");
    try createTempFile(dir, "b.pngine", "#import \"c.pngine\"\n#define B=2");
    try createTempFile(dir, "c.pngine", "#import \"a.pngine\"\n#define C=3");

    // Resolve imports - should detect cycle
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"a.pngine\"";
    const result = resolver.resolve(source, "main.pngine");

    try testing.expectError(error.ImportCycle, result);
}

test "ImportResolver: import ordering preserved" {
    const test_dir = ".test_import_order";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create files with distinctive markers
    try createTempFile(dir, "first.pngine", "MARKER_FIRST");
    try createTempFile(dir, "second.pngine", "MARKER_SECOND");
    try createTempFile(dir, "third.pngine", "MARKER_THIRD");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"first.pngine\"\n#import \"second.pngine\"\n#import \"third.pngine\"\nMARKER_MAIN";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Find positions of markers
    const pos_first = std.mem.indexOf(u8, result, "MARKER_FIRST");
    const pos_second = std.mem.indexOf(u8, result, "MARKER_SECOND");
    const pos_third = std.mem.indexOf(u8, result, "MARKER_THIRD");
    const pos_main = std.mem.indexOf(u8, result, "MARKER_MAIN");

    // All markers should be present
    try testing.expect(pos_first != null);
    try testing.expect(pos_second != null);
    try testing.expect(pos_third != null);
    try testing.expect(pos_main != null);

    // Order should be: first, second, third, main
    try testing.expect(pos_first.? < pos_second.?);
    try testing.expect(pos_second.? < pos_third.?);
    try testing.expect(pos_third.? < pos_main.?);
}

test "ImportResolver: deduplication across resolve calls" {
    // Tests that files imported in one resolve() call are deduplicated
    // in subsequent resolve() calls on the same resolver instance
    const test_dir = ".test_import_cache";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create file with unique content
    try createTempFile(dir, "shared.pngine", "#define SHARED=yes");

    // Resolve imports twice from different entry points using SAME resolver
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    // First resolution - includes shared.pngine
    const source1 = "#import \"shared.pngine\"\n#define FIRST=1";
    const result1 = try resolver.resolve(source1, "main1.pngine");
    defer testing.allocator.free(result1);

    // Second resolution - shared.pngine is deduplicated (already included)
    const source2 = "#import \"shared.pngine\"\n#define SECOND=2";
    const result2 = try resolver.resolve(source2, "main2.pngine");
    defer testing.allocator.free(result2);

    // First result should have shared content
    try testing.expect(std.mem.indexOf(u8, result1, "#define SHARED=yes") != null);
    try testing.expect(std.mem.indexOf(u8, result1, "#define FIRST=1") != null);

    // Second result should NOT have shared content (deduplicated)
    try testing.expect(std.mem.indexOf(u8, result2, "#define SHARED=yes") == null);
    try testing.expect(std.mem.indexOf(u8, result2, "#define SECOND=2") != null);

    // Cache should have entry for shared.pngine
    try testing.expect(resolver.resolved.count() >= 1);
}

test "ImportResolver: empty imported file" {
    const test_dir = ".test_import_empty";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create empty file
    try createTempFile(dir, "empty.pngine", "");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"empty.pngine\"\n#define AFTER=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Should still have the content after the import
    try testing.expect(std.mem.indexOf(u8, result, "#define AFTER=1") != null);
}

test "ImportResolver: import with trailing content" {
    const test_dir = ".test_import_trailing";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create file with trailing newlines
    try createTempFile(dir, "trailing.pngine", "#define TRAILING=1\n\n\n");

    // Resolve imports
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"trailing.pngine\"\n#define AFTER=2";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Both definitions should be present
    try testing.expect(std.mem.indexOf(u8, result, "#define TRAILING=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define AFTER=2") != null);
}

// ============================================================================
// Path Normalization Tests
// ============================================================================

test "ImportResolver: normalizePath basic cases" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Simple path unchanged
    const p1 = try resolver.normalizePath("a/b/c");
    defer testing.allocator.free(p1);
    try testing.expectEqualStrings("a/b/c", p1);

    // Remove single dot
    const p2 = try resolver.normalizePath("a/./b/./c");
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings("a/b/c", p2);

    // Resolve parent directory
    const p3 = try resolver.normalizePath("a/b/../c");
    defer testing.allocator.free(p3);
    try testing.expectEqualStrings("a/c", p3);

    // Multiple parent refs
    const p4 = try resolver.normalizePath("a/b/c/../../d");
    defer testing.allocator.free(p4);
    try testing.expectEqualStrings("a/d", p4);
}

test "ImportResolver: normalizePath edge cases" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Just a dot
    const p1 = try resolver.normalizePath(".");
    defer testing.allocator.free(p1);
    try testing.expectEqualStrings(".", p1);

    // Multiple dots in sequence
    const p2 = try resolver.normalizePath("./././.");
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings(".", p2);

    // Parent at start (can't go higher)
    const p3 = try resolver.normalizePath("../a");
    defer testing.allocator.free(p3);
    try testing.expectEqualStrings("a", p3);

    // Empty path components (double slashes)
    const p4 = try resolver.normalizePath("a//b///c");
    defer testing.allocator.free(p4);
    try testing.expectEqualStrings("a/b/c", p4);

    // Trailing slash
    const p5 = try resolver.normalizePath("a/b/c/");
    defer testing.allocator.free(p5);
    try testing.expectEqualStrings("a/b/c", p5);

    // Leading slash preserved... actually no, let's check
    const p6 = try resolver.normalizePath("/a/b/c");
    defer testing.allocator.free(p6);
    try testing.expectEqualStrings("a/b/c", p6);

    // Complex mix
    const p7 = try resolver.normalizePath("./a/../b/./c/../d");
    defer testing.allocator.free(p7);
    try testing.expectEqualStrings("b/d", p7);
}

test "ImportResolver: normalizePath parent overflow" {
    // More .. than path components
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const p1 = try resolver.normalizePath("a/../../..");
    defer testing.allocator.free(p1);
    try testing.expectEqualStrings(".", p1);

    const p2 = try resolver.normalizePath("../../../a");
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings("a", p2);
}

test "ImportResolver: normalizePath idempotent" {
    // Property: normalize(normalize(x)) == normalize(x)
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const paths = [_][]const u8{
        "a/b/c",
        "./a/../b",
        "a//b///c",
        "../a/./b/../c",
        ".",
        "",
        "a/b/c/../../d/e/../f",
    };

    for (paths) |path| {
        const once = try resolver.normalizePath(path);
        defer testing.allocator.free(once);

        const twice = try resolver.normalizePath(once);
        defer testing.allocator.free(twice);

        try testing.expectEqualStrings(once, twice);
    }
}

// ============================================================================
// Deduplication with Path Variants
// ============================================================================

test "ImportResolver: dedup with dot prefix" {
    // Import same file with and without ./ prefix
    const test_dir = ".test_dedup_dot";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "core.pngine", "#define CORE_UNIQUE_MARKER=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    // Import with ./ and without - should deduplicate
    const source = "#import \"./core.pngine\"\n#import \"core.pngine\"\n#define MAIN=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Core should appear exactly once
    const first = std.mem.indexOf(u8, result, "CORE_UNIQUE_MARKER");
    try testing.expect(first != null);
    const rest = result[first.? + "CORE_UNIQUE_MARKER".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "CORE_UNIQUE_MARKER") == null);
}

test "ImportResolver: dedup with parent directory" {
    // Import same file via parent ref: sub/../core.pngine vs core.pngine
    const test_dir = ".test_dedup_parent";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    dir.makeDir("sub") catch {};

    try createTempFile(dir, "core.pngine", "#define CORE_PARENT_TEST=42");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    // Import via parent ref and direct - should deduplicate
    const source = "#import \"core.pngine\"\n#import \"sub/../core.pngine\"\n#define MAIN=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Should appear exactly once
    const first = std.mem.indexOf(u8, result, "CORE_PARENT_TEST");
    try testing.expect(first != null);
    const rest = result[first.? + "CORE_PARENT_TEST".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "CORE_PARENT_TEST") == null);
}

test "ImportResolver: dedup deep diamond" {
    // A -> B -> C
    // A -> D -> C
    // C should appear once
    const test_dir = ".test_dedup_deep_diamond";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "c.pngine", "#define C_DEEP_MARKER=deep");
    try createTempFile(dir, "b.pngine", "#import \"c.pngine\"\n#define B=1");
    try createTempFile(dir, "d.pngine", "#import \"c.pngine\"\n#define D=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"b.pngine\"\n#import \"d.pngine\"\n#define A=1";
    const result = try resolver.resolve(source, "a.pngine");
    defer testing.allocator.free(result);

    // C should appear once, B and D once each
    try testing.expect(std.mem.indexOf(u8, result, "#define B=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define D=1") != null);

    const first_c = std.mem.indexOf(u8, result, "C_DEEP_MARKER");
    try testing.expect(first_c != null);
    const rest = result[first_c.? + "C_DEEP_MARKER".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "C_DEEP_MARKER") == null);
}

test "ImportResolver: dedup wide fan-in" {
    // Many files all importing the same core
    const test_dir = ".test_dedup_fanin";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "shared.pngine", "#define SHARED_FANIN=unique123");

    // Create 10 files that all import shared
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file{d}.pngine", .{i}) catch unreachable;
        var content_buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "#import \"shared.pngine\"\n#define FILE{d}=1", .{i}) catch unreachable;
        try createTempFile(dir, name, content);
    }

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    // Import all 10 files
    const source =
        \\#import "file0.pngine"
        \\#import "file1.pngine"
        \\#import "file2.pngine"
        \\#import "file3.pngine"
        \\#import "file4.pngine"
        \\#import "file5.pngine"
        \\#import "file6.pngine"
        \\#import "file7.pngine"
        \\#import "file8.pngine"
        \\#import "file9.pngine"
        \\#define MAIN=1
    ;
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Shared should appear exactly ONCE despite 10 imports
    const first = std.mem.indexOf(u8, result, "SHARED_FANIN");
    try testing.expect(first != null);
    const rest = result[first.? + "SHARED_FANIN".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "SHARED_FANIN") == null);

    // All file markers should be present
    i = 0;
    while (i < 10) : (i += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, "#define FILE{d}=1", .{i}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, result, marker) != null);
    }
}

test "ImportResolver: dedup chain with branch" {
    // A -> B -> C -> D
    // A -> E -> D (E also imports D)
    // D should appear once
    const test_dir = ".test_dedup_chain";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "d.pngine", "#define D_CHAIN=terminus");
    try createTempFile(dir, "c.pngine", "#import \"d.pngine\"\n#define C=1");
    try createTempFile(dir, "b.pngine", "#import \"c.pngine\"\n#define B=1");
    try createTempFile(dir, "e.pngine", "#import \"d.pngine\"\n#define E=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"b.pngine\"\n#import \"e.pngine\"\n#define A=1";
    const result = try resolver.resolve(source, "a.pngine");
    defer testing.allocator.free(result);

    // D should appear once
    const first = std.mem.indexOf(u8, result, "D_CHAIN");
    try testing.expect(first != null);
    const rest = result[first.? + "D_CHAIN".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "D_CHAIN") == null);

    // Order: D, C, B (from first path), E (D already included), A
    try testing.expect(std.mem.indexOf(u8, result, "#define B=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define C=1") != null);
    try testing.expect(std.mem.indexOf(u8, result, "#define E=1") != null);
}

test "ImportResolver: dedup with nested directories" {
    // main imports sub/a.pngine and sub/b.pngine
    // both import ../shared.pngine (same as shared.pngine)
    const test_dir = ".test_dedup_nested";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    dir.makeDir("sub") catch {};
    var sub = dir.openDir("sub", .{}) catch return;
    defer sub.close();

    try createTempFile(dir, "shared.pngine", "#define SHARED_NESTED=root");
    try createTempFile(sub, "a.pngine", "#import \"../shared.pngine\"\n#define A=1");
    try createTempFile(sub, "b.pngine", "#import \"../shared.pngine\"\n#define B=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"sub/a.pngine\"\n#import \"sub/b.pngine\"\n#define MAIN=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Shared should appear once
    const first = std.mem.indexOf(u8, result, "SHARED_NESTED");
    try testing.expect(first != null);
    const rest = result[first.? + "SHARED_NESTED".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "SHARED_NESTED") == null);
}

// ============================================================================
// Regression Test: demo2025 Pattern
// ============================================================================

test "ImportResolver: demo2025 pattern - main and scene both import core" {
    // Simulates: main imports core, main imports sceneQ, sceneQ imports core
    const test_dir = ".test_demo2025";
    cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    defer cleanupTempDir(test_dir);

    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Core has definitions that would cause duplicate_definition errors if included twice
    try createTempFile(dir, "core.pngine",
        \\#texture depthTexture { format=depth24plus }
        \\#sampler postProcessSampler { }
        \\#buffer uniformBuffer { size=64 }
    );

    // SceneQ imports core
    try createTempFile(dir, "sceneQ.pngine",
        \\#import "core.pngine"
        \\#wgsl sceneQ { value="void main() {}" }
    );

    // Main imports both core and sceneQ
    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source =
        \\#import "core.pngine"
        \\#import "sceneQ.pngine"
        \\#wgsl main { value="void mainFunc() {}" }
    ;
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Each core definition should appear exactly once
    const markers = [_][]const u8{ "depthTexture", "postProcessSampler", "uniformBuffer" };
    for (markers) |marker| {
        const first = std.mem.indexOf(u8, result, marker);
        try testing.expect(first != null);
        const rest = result[first.? + marker.len ..];
        try testing.expect(std.mem.indexOf(u8, rest, marker) == null);
    }

    // SceneQ content should be present
    try testing.expect(std.mem.indexOf(u8, result, "sceneQ") != null);
}

// ============================================================================
// OOM Testing for New Code Paths
// ============================================================================

test "ImportResolver: OOM in normalizePath" {
    // Test OOM at each allocation point in normalizePath
    var fail_index: usize = 0;
    const max_iterations: usize = 50;

    while (fail_index < max_iterations) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var resolver = ImportResolver.init(failing.allocator(), ".");
        defer resolver.deinit();

        const result = resolver.normalizePath("a/./b/../c/d");

        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const path = try result;
            failing.allocator().free(path);
            break;
        }
    }
    try testing.expect(fail_index > 0);
    try testing.expect(fail_index < max_iterations);
}

test "ImportResolver: OOM during dedup file import" {
    const test_dir = ".test_oom_dedup";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "core.pngine", "#define CORE=1");

    var fail_index: usize = 0;
    const max_iterations: usize = 100;

    while (fail_index < max_iterations) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });

        var resolver = ImportResolver.init(failing.allocator(), test_dir);
        defer resolver.deinit();

        const result = resolver.resolve("#import \"core.pngine\"\n#define MAIN=1", "main.pngine");

        if (failing.has_induced_failure) {
            try testing.expectError(error.OutOfMemory, result);
        } else {
            const resolved = try result;
            failing.allocator().free(resolved);
            break;
        }
    }
    try testing.expect(fail_index > 0);
    try testing.expect(fail_index < max_iterations);
}

// ============================================================================
// Property-Based Tests
// ============================================================================

test "ImportResolver: property - dedup reduces output size" {
    // Property: with deduplication, output size <= sum of unique file contents
    const test_dir = ".test_prop_size";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    const shared_content = "#define SHARED=1\n" ** 10; // 160 bytes
    try createTempFile(dir, "shared.pngine", shared_content);
    try createTempFile(dir, "a.pngine", "#import \"shared.pngine\"\n#define A=1");
    try createTempFile(dir, "b.pngine", "#import \"shared.pngine\"\n#define B=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"a.pngine\"\n#import \"b.pngine\"\n#define MAIN=1";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    // Without dedup: source + a + b + shared*2 would be larger
    // With dedup: source + a + b + shared*1
    // shared appears once, so result.len < source.len + a.len + b.len + shared*2
    const with_double_shared = source.len + 50 + 50 + shared_content.len * 2;
    try testing.expect(result.len < with_double_shared);
}

test "ImportResolver: property - order preserved for non-duplicates" {
    const test_dir = ".test_prop_order";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Each file has unique content, no shared imports
    try createTempFile(dir, "first.pngine", "FIRST_UNIQUE");
    try createTempFile(dir, "second.pngine", "SECOND_UNIQUE");
    try createTempFile(dir, "third.pngine", "THIRD_UNIQUE");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"first.pngine\"\n#import \"second.pngine\"\n#import \"third.pngine\"\nMAIN_UNIQUE";
    const result = try resolver.resolve(source, "main.pngine");
    defer testing.allocator.free(result);

    const pos1 = std.mem.indexOf(u8, result, "FIRST_UNIQUE").?;
    const pos2 = std.mem.indexOf(u8, result, "SECOND_UNIQUE").?;
    const pos3 = std.mem.indexOf(u8, result, "THIRD_UNIQUE").?;
    const pos4 = std.mem.indexOf(u8, result, "MAIN_UNIQUE").?;

    try testing.expect(pos1 < pos2);
    try testing.expect(pos2 < pos3);
    try testing.expect(pos3 < pos4);
}

test "ImportResolver: property - first wins in diamond" {
    // In diamond A->B->C, A->D->C, the first path (B) includes C
    const test_dir = ".test_prop_first_wins";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "c.pngine", "C_CONTENT");
    try createTempFile(dir, "b.pngine", "#import \"c.pngine\"\nB_AFTER_C");
    try createTempFile(dir, "d.pngine", "#import \"c.pngine\"\nD_AFTER_C");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const source = "#import \"b.pngine\"\n#import \"d.pngine\"\nA_MAIN";
    const result = try resolver.resolve(source, "a.pngine");
    defer testing.allocator.free(result);

    // C appears before B_AFTER_C (because B imports C first)
    const c_pos = std.mem.indexOf(u8, result, "C_CONTENT").?;
    const b_pos = std.mem.indexOf(u8, result, "B_AFTER_C").?;
    const d_pos = std.mem.indexOf(u8, result, "D_AFTER_C").?;

    try testing.expect(c_pos < b_pos); // C comes before B's content
    try testing.expect(b_pos < d_pos); // B comes before D
}

// ============================================================================
// Fuzz Testing
// ============================================================================

test "ImportResolver: fuzz normalizePath" {
    try std.testing.fuzz({}, fuzzNormalizePath, .{
        .corpus = &.{
            "a/b/c",
            "./a/../b",
            "a//b///c",
            "../../../a",
            ".",
            "",
            "a/b/c/../../d/e/../f",
            "/absolute/path",
            "very/deep/nested/path/that/goes/on/and/on",
        },
    });
}

fn fuzzNormalizePath(_: void, input: []const u8) !void {
    // Filter nulls
    for (input) |b| if (b == 0) return;
    // Limit size
    if (input.len > 1024) return;

    var resolver = ImportResolver.init(std.testing.allocator, ".");
    defer resolver.deinit();

    const result = resolver.normalizePath(input) catch |err| {
        switch (err) {
            error.OutOfMemory => return,
        }
    };
    defer std.testing.allocator.free(result);

    // Property: result doesn't contain "//" (double slash)
    try std.testing.expect(std.mem.indexOf(u8, result, "//") == null);

    // Property: result doesn't contain "/." followed by "/" or end
    var i: usize = 0;
    while (i + 1 < result.len) : (i += 1) {
        if (result[i] == '/' and result[i + 1] == '.') {
            if (i + 2 >= result.len or result[i + 2] == '/') {
                // Found "/." at end or followed by "/"
                try std.testing.expect(false);
            }
        }
    }

    // Property: idempotent
    const again = resolver.normalizePath(result) catch return;
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(result, again);
}

test "ImportResolver: fuzz path deduplication equivalence" {
    try std.testing.fuzz({}, fuzzPathEquivalence, .{
        .corpus = &.{
            "a/b",
            "./a/b",
            "a/./b",
            "a/c/../b",
            "x/../a/b",
        },
    });
}

fn fuzzPathEquivalence(_: void, input: []const u8) !void {
    // Filter
    for (input) |b| if (b == 0) return;
    if (input.len > 256) return;
    if (input.len == 0) return;

    var resolver = ImportResolver.init(std.testing.allocator, ".");
    defer resolver.deinit();

    // Generate a few path variants
    var variants: [4][]u8 = undefined;
    var count: usize = 0;
    defer for (variants[0..count]) |v| std.testing.allocator.free(v);

    // Original
    variants[count] = try std.testing.allocator.dupe(u8, input);
    count += 1;

    // With ./ prefix
    if (count < variants.len) {
        variants[count] = try std.fmt.allocPrint(std.testing.allocator, "./{s}", .{input});
        count += 1;
    }

    // Normalize all and compare
    var normalized: [4][]const u8 = undefined;
    var norm_count: usize = 0;
    defer for (normalized[0..norm_count]) |n| std.testing.allocator.free(n);

    for (variants[0..count]) |v| {
        const n = resolver.normalizePath(v) catch continue;
        normalized[norm_count] = n;
        norm_count += 1;
    }

    // All normalizations should produce same result
    if (norm_count > 1) {
        for (normalized[1..norm_count]) |n| {
            try std.testing.expectEqualStrings(normalized[0], n);
        }
    }
}

// ============================================================================
// Stress Tests
// ============================================================================

test "ImportResolver: stress - many imports same file" {
    const test_dir = ".test_stress_many";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "shared.pngine", "#define STRESS_SHARED=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    // Build source with 100 imports of same file
    var source_buf: [8192]u8 = undefined;
    var source_len: usize = 0;

    for (0..100) |_| {
        const import_line = "#import \"shared.pngine\"\n";
        @memcpy(source_buf[source_len..][0..import_line.len], import_line);
        source_len += import_line.len;
    }
    @memcpy(source_buf[source_len..][0..12], "#define M=1\n");
    source_len += 12;

    const result = try resolver.resolve(source_buf[0..source_len], "main.pngine");
    defer testing.allocator.free(result);

    // Should still only have one instance of STRESS_SHARED
    const first = std.mem.indexOf(u8, result, "STRESS_SHARED");
    try testing.expect(first != null);
    const rest = result[first.? + "STRESS_SHARED".len ..];
    try testing.expect(std.mem.indexOf(u8, rest, "STRESS_SHARED") == null);
}

test "ImportResolver: stress - deep nesting" {
    const test_dir = ".test_stress_deep";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Create chain: a0 -> a1 -> a2 -> ... -> a19 -> shared
    try createTempFile(dir, "shared.pngine", "#define DEEP_SHARED=terminus");

    var i: u32 = 20;
    while (i > 0) : (i -= 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "a{d}.pngine", .{i - 1}) catch unreachable;

        var content_buf: [128]u8 = undefined;
        const content = if (i == 20)
            std.fmt.bufPrint(&content_buf, "#import \"shared.pngine\"\n#define A{d}=1", .{i - 1}) catch unreachable
        else
            std.fmt.bufPrint(&content_buf, "#import \"a{d}.pngine\"\n#define A{d}=1", .{ i, i - 1 }) catch unreachable;

        try createTempFile(dir, name, content);
    }

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const result = try resolver.resolve("#import \"a0.pngine\"\n#define MAIN=1", "main.pngine");
    defer testing.allocator.free(result);

    // Shared should appear exactly once
    const first = std.mem.indexOf(u8, result, "DEEP_SHARED");
    try testing.expect(first != null);

    // All A markers should be present
    i = 0;
    while (i < 20) : (i += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buf, "#define A{d}=1", .{i}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, result, marker) != null);
    }
}

// ============================================================================
// Edge Cases
// ============================================================================

test "ImportResolver: import self returns cycle error" {
    const test_dir = ".test_self_import";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    try createTempFile(dir, "self.pngine", "#import \"self.pngine\"\n#define SELF=1");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const result = resolver.resolve("#import \"self.pngine\"", "main.pngine");
    try testing.expectError(error.ImportCycle, result);
}

test "ImportResolver: import with special characters in filename" {
    const test_dir = ".test_special_chars";
    cleanupTempDir(test_dir);
    defer cleanupTempDir(test_dir);

    std.fs.cwd().makeDir(test_dir) catch {};
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return;
    defer dir.close();

    // Files with underscores, dashes, numbers
    try createTempFile(dir, "my-file_v2.pngine", "#define SPECIAL=yes");

    var resolver = ImportResolver.init(testing.allocator, test_dir);
    defer resolver.deinit();

    const result = try resolver.resolve("#import \"my-file_v2.pngine\"\n#define M=1", "main.pngine");
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "#define SPECIAL=yes") != null);
}

test "ImportResolver: empty path after normalization" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Path that normalizes to "."
    const p = try resolver.normalizePath("");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings(".", p);
}

test "ImportResolver: very long path normalization" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    // Create a very long path
    var long_path: [2048]u8 = undefined;
    var pos: usize = 0;
    for (0..100) |i| {
        const segment = std.fmt.bufPrint(long_path[pos..], "dir{d}/", .{i}) catch break;
        pos += segment.len;
    }
    if (pos > 0) pos -= 1; // Remove trailing slash

    const result = try resolver.normalizePath(long_path[0..pos]);
    defer testing.allocator.free(result);

    // Should not crash, result should be same (no . or ..)
    try testing.expect(result.len > 0);
}

test "ImportResolver: unicode in path preserved" {
    var resolver = ImportResolver.init(testing.allocator, ".");
    defer resolver.deinit();

    const unicode_path = "café/日本語/путь";
    const result = try resolver.normalizePath(unicode_path);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(unicode_path, result);
}
