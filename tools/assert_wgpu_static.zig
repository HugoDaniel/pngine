//! Build guard: when the vendored wgpu-native is linked (`-Dgpu-native`), the
//! link must be STATIC — the exact `vendor/wgpu-native/lib/libwgpu_native.a`
//! whose presence build.zig probed, handed to the linker as a file.
//!
//! Why this exists: wgpu-native's macOS release zip vendors a
//! `libwgpu_native.dylib` NEXT TO that archive, and a by-name
//! `-lwgpu_native` library search prefers a dylib (ld64's default
//! `-search_dylibs_first`, and Zig's linker the same — verified against the
//! v27.0.4.0 zip). The binary then records `@rpath/libwgpu_native.dylib`,
//! which resolves only against the build host's vendor/ path, so an installed
//! pngine dies on every other machine:
//!
//!   Library not loaded: @rpath/libwgpu_native.dylib
//!     Referenced from: …/node_modules/@pngine/darwin-arm64/bin/pngine
//!
//! What it checks: the produced CLI binary — Mach-O (darwin) or ELF (any
//! other host) — is parsed directly and its DYNAMIC library dependencies are
//! enumerated (Mach-O `LC_LOAD_*_DYLIB` load commands / ELF `DT_NEEDED`
//! entries). Any entry naming `libwgpu_native` fails the build. A binary the
//! tool cannot parse also fails: a guard that skips what it cannot read is
//! not a guard.
//!
//! Wired into build.zig's default install step whenever the wgpu-native link
//! is active (same wiring as the executor guards), taking the built CLI as
//! its file arg so the link finishes first — a `zig build` that links the
//! backend cannot skip it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The dylib load commands (plus their common supertype), by std.macho's
/// spellings — every way a Mach-O binary can name a dynamic dependency.
const macho_dylib_cmds = [_]u32{
    @intFromEnum(std.macho.LC.LOAD_DYLIB),
    @intFromEnum(std.macho.LC.LOAD_WEAK_DYLIB),
    @intFromEnum(std.macho.LC.REEXPORT_DYLIB),
    @intFromEnum(std.macho.LC.LAZY_LOAD_DYLIB),
    @intFromEnum(std.macho.LC.LOAD_UPWARD_DYLIB),
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 2) {
        std.debug.print("usage: assert_wgpu_static <pngine-binary>\n", .{});
        return 2;
    }

    // 512 MiB: the host CLI links a 33 MB archive and keeps its symbols, so
    // it is two orders past the npm binaries' ~6 MB — but still bounded.
    const bin = try Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bin);

    const deps: []const []const u8 = machoDylibDeps(arena, bin) catch |macho_err| switch (macho_err) {
        error.NotMachO => elfNeededLibs(arena, bin) catch |elf_err| return parseFailed(args[1], elf_err),
        else => return parseFailed(args[1], macho_err),
    };

    for (deps) |dep| {
        if (std.mem.indexOf(u8, dep, "libwgpu_native") != null) {
            std.debug.print(
                "\nBUILD GUARD FAILED (wgpu static link): {s} records a DYNAMIC dependency" ++
                    "\n    {s}" ++
                    "\non wgpu-native. The vendored libwgpu_native.a must reach the linker as a" ++
                    "\nFILE (build.zig's addObjectFile of the probed path), never as a by-name" ++
                    "\n-lwgpu_native search: wgpu-native's macOS zip vendors a dylib next to the" ++
                    "\narchive, and a dylib-first search ships a binary that only runs on the" ++
                    "\nmachine that built it (Library not loaded: @rpath/libwgpu_native.dylib)." ++
                    "\n",
                .{ args[1], dep },
            );
            return 1;
        }
    }

    std.debug.print(
        "wgpu static-link guard OK: {s} carries no dynamic wgpu_native dependency ({d} deps checked)\n",
        .{ args[1], deps.len },
    );
    return 0;
}

fn parseFailed(path: []const u8, err: anyerror) u8 {
    std.debug.print(
        "\nBUILD GUARD FAILED (wgpu static link): cannot read the dynamic dependencies of" ++
            "\n    {s}: {s}" ++
            "\nThe guard must parse the produced binary (Mach-O or ELF) to prove the wgpu-native" ++
            "\nlink is static; an unreadable binary is a failed guard, not a skipped one." ++
            "\n",
        .{ path, @errorName(err) },
    );
    return 1;
}

/// Every `LC_LOAD_*_DYLIB` name in a Mach-O binary, sliced from `bin`.
/// Errors unless the file is a plain (non-fat) Mach-O image whose load
/// commands walk exactly.
fn machoDylibDeps(arena: Allocator, bin: []const u8) ![]const []const u8 {
    if (bin.len < @sizeOf(std.macho.mach_header)) return error.NotMachO;
    const magic_le = std.mem.readInt(u32, bin[0..4], .little);
    const magic_be = std.mem.readInt(u32, bin[0..4], .big);
    var endian: std.builtin.Endian = undefined;
    var cmd0: usize = undefined;
    if (magic_le == std.macho.MH_MAGIC_64) {
        endian = .little;
        cmd0 = @sizeOf(std.macho.mach_header_64);
    } else if (magic_le == std.macho.MH_MAGIC) {
        endian = .little;
        cmd0 = @sizeOf(std.macho.mach_header);
    } else if (magic_be == std.macho.MH_MAGIC_64) {
        endian = .big;
        cmd0 = @sizeOf(std.macho.mach_header_64);
    } else if (magic_be == std.macho.MH_MAGIC) {
        endian = .big;
        cmd0 = @sizeOf(std.macho.mach_header);
    } else if (magic_le == std.macho.FAT_MAGIC or magic_be == std.macho.FAT_MAGIC or
        magic_le == std.macho.FAT_MAGIC_64 or magic_be == std.macho.FAT_MAGIC_64)
    {
        return error.FatBinary;
    } else {
        return error.NotMachO;
    }
    if (bin.len < cmd0) return error.Truncated;
    const ncmds = std.mem.readInt(u32, bin[16..20], endian);

    var deps: std.ArrayList([]const u8) = .empty;
    var off: usize = cmd0;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (off + 8 > bin.len) return error.Truncated;
        const cmd = std.mem.readInt(u32, bin[off..][0..4], endian);
        const cmdsize = std.mem.readInt(u32, bin[off + 4 ..][0..4], endian);
        if (cmdsize < 8 or off + cmdsize > bin.len) return error.Truncated;
        for (macho_dylib_cmds) |dylib_cmd| {
            if (cmd != dylib_cmd) continue;
            // dylib_command: cmd, cmdsize, dylib{ name: lc_str(offset), … }
            const name_off = std.mem.readInt(u32, bin[off + 8 ..][0..4], endian);
            const start = off + name_off;
            if (name_off < 8 or start >= off + cmdsize) return error.Malformed;
            const end = std.mem.indexOfScalar(u8, bin[start .. off + cmdsize], 0) orelse
                return error.Malformed;
            try deps.append(arena, bin[start .. start + end]);
        }
        off += cmdsize;
    }
    return deps.toOwnedSlice(arena);
}

/// Every `DT_NEEDED` string in an ELF image, sliced from `bin`. Addresses in
/// the dynamic section are virtual; they translate through the `PT_LOAD`
/// segments the same way a loader maps them.
fn elfNeededLibs(arena: Allocator, bin: []const u8) ![]const []const u8 {
    if (bin.len < 64 or !std.mem.eql(u8, bin[0..4], "\x7fELF")) return error.NotElf;
    const is_64 = bin[4] == 2;
    const endian: std.builtin.Endian = switch (bin[5]) {
        1 => .little,
        2 => .big,
        else => return error.Malformed,
    };
    const phoff: u64 = if (is_64)
        std.mem.readInt(u64, bin[32..40], endian)
    else
        std.mem.readInt(u32, bin[28..32], endian);
    const phentsize: u16 = if (is_64)
        std.mem.readInt(u16, bin[54..56], endian)
    else
        std.mem.readInt(u16, bin[42..44], endian);
    const phnum: u16 = if (is_64)
        std.mem.readInt(u16, bin[56..58], endian)
    else
        std.mem.readInt(u16, bin[44..46], endian);

    const Segment = struct { vaddr: u64, offset: u64, filesz: u64 };
    var loads: std.ArrayList(Segment) = .empty;
    var dynamic: ?Segment = null;
    var ph: usize = 0;
    while (ph < phnum) : (ph += 1) {
        const p = phoff + ph * phentsize;
        if (p + phentsize > bin.len) return error.Truncated;
        const p_type = std.mem.readInt(u32, bin[p..][0..4], endian);
        // PT_LOAD = 1, PT_DYNAMIC = 2
        if (p_type == 1 or p_type == 2) {
            const seg: Segment = if (is_64) .{
                .vaddr = std.mem.readInt(u64, bin[p + 16 ..][0..8], endian),
                .offset = std.mem.readInt(u64, bin[p + 8 ..][0..8], endian),
                .filesz = std.mem.readInt(u64, bin[p + 32 ..][0..8], endian),
            } else .{
                .vaddr = std.mem.readInt(u32, bin[p + 8 ..][0..4], endian),
                .offset = std.mem.readInt(u32, bin[p + 4 ..][0..4], endian),
                .filesz = std.mem.readInt(u32, bin[p + 16 ..][0..4], endian),
            };
            if (p_type == 1) {
                try loads.append(arena, seg);
            } else {
                dynamic = seg;
            }
        }
    }
    const dyn = dynamic orelse return error.NoDynamicSection;

    const v2o = struct {
        fn map(segs: []const Segment, v: u64) ?u64 {
            for (segs) |s| {
                if (v >= s.vaddr and v < s.vaddr + s.filesz) return s.offset + (v - s.vaddr);
            }
            return null;
        }
    }.map;

    const entry_size: usize = if (is_64) 16 else 8;
    var needed: std.ArrayList(u64) = .empty;
    var strtab: u64 = 0;
    var off: u64 = dyn.offset;
    const dyn_end = dyn.offset + dyn.filesz;
    while (off + entry_size <= dyn_end and off + entry_size <= bin.len) {
        const tag: i64 = if (is_64)
            std.mem.readInt(i64, bin[@intCast(off)..][0..8], endian)
        else
            std.mem.readInt(i32, bin[@intCast(off)..][0..4], endian);
        const val: u64 = if (is_64)
            std.mem.readInt(u64, bin[@intCast(off + 8)..][0..8], endian)
        else
            std.mem.readInt(u32, bin[@intCast(off + 4)..][0..4], endian);
        if (tag == 0) break; // DT_NULL
        if (tag == 1) try needed.append(arena, val); // DT_NEEDED
        if (tag == 5) strtab = val; // DT_STRTAB
        off += entry_size;
    }
    if (strtab == 0 and needed.items.len > 0) return error.Malformed;
    const strtab_off = v2o(loads.items, strtab) orelse return error.Malformed;

    var deps: std.ArrayList([]const u8) = .empty;
    for (needed.items) |n| {
        const start: usize = @intCast(strtab_off + n);
        if (start >= bin.len) return error.Malformed;
        const end = std.mem.indexOfScalar(u8, bin[start..], 0) orelse return error.Malformed;
        try deps.append(arena, bin[start .. start + end]);
    }
    return deps.toOwnedSlice(arena);
}
