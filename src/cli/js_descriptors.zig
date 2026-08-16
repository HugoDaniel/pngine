//! Descriptor blobs → WebGPU JavaScript, for the `--html` single-file codegen.
//!
//! The mirror image of `dsl_sjon/descriptor_encoder.zig`: that file packs a
//! validated form into the compact blob stored in the data section, and this one
//! unpacks the blob into the `{…}` object literal a browser accepts. The two
//! encodings it has to read are the encoder's own binary layout
//! (`[type_tag][field_count]` then tagged fields) and, for pipelines, JSON.
//!
//! Split out of `js_codegen.zig` in r2-04: the descriptor emitters were four of
//! the file's ten longest functions and share nothing with the page-level driver
//! but these two encodings.
//!
//! ## Invariants
//!
//! - Every emitter appends exactly one JS value and never a trailing comma.
//! - A malformed blob truncates the walk; it never reads out of bounds and never
//!   returns a partial value the caller would splice into valid JS. Blobs come
//!   from payload data, so "malformed" is a supported input, not a bug report.
//! - No recursion: `skipValue` walks nested fields with an explicit stack
//!   (mastery rule 1) — see its comment for the payload that motivated it.

const std = @import("std");
const pngine = @import("pngine");
const descriptors = pngine.types.descriptors;
const opcodes = pngine.opcodes;
const js_emit = @import("js_emit.zig");
const appendInt = js_emit.appendInt;
const appendCompactFloat = js_emit.appendCompactFloat;
const emitJsonValue = js_emit.emitJsonValue;

/// Emit render pipeline descriptor from JSON data.
pub fn emitRenderPipelineDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8, override_format: ?[]const u8) !void {
    // Data is JSON like: {"vertex":{"shader":0,"entryPoint":"vs"},"fragment":{"shader":0,"entryPoint":"fs"},...}
    // We need to replace "shader":N with actual sN references and add layout:'auto' + format
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        // Fallback: emit raw JSON wrapped
        try out.appendSlice(allocator, "JSON.parse('");
        try out.appendSlice(allocator, data);
        try out.appendSlice(allocator, "')");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };

    // Explicit pipeline layout (PL{id}) when the descriptor carries a layoutId,
    // else the auto-derived layout.
    if (obj.get("layoutId")) |l| {
        if (l == .integer) {
            try out.appendSlice(allocator, "{layout:PL");
            try appendInt(out, allocator, @as(u16, @intCast(l.integer)));
            try out.appendSlice(allocator, ",vertex:{module:s");
        } else {
            try out.appendSlice(allocator, "{layout:'auto',vertex:{module:s");
        }
    } else {
        try out.appendSlice(allocator, "{layout:'auto',vertex:{module:s");
    }

    const vs_id = try emitVertexStage(out, allocator, obj);

    try emitFragmentStage(out, allocator, obj, override_format, vs_id);
    try emitPrimitiveState(out, allocator, obj);

    // Depth stencil
    if (obj.get("depthStencil")) |ds| {
        if (ds == .object) {
            try out.appendSlice(allocator, ",depthStencil:");
            try emitJsonValue(out, allocator, ds);
        }
    }

    try out.appendSlice(allocator, "}");
}

/// The `vertex:{…}` half of a render-pipeline descriptor, up to and including
/// the `},fragment:{module:s` that opens the next one. Returns the vertex
/// shader id, which the fragment stage falls back to when the descriptor names
/// no fragment shader of its own.
fn emitVertexStage(out: *std.ArrayList(u8), allocator: std.mem.Allocator, obj: std.json.ObjectMap) !u16 {
    const vertex = obj.get("vertex");
    var vs_id: u16 = 0;
    if (vertex) |v| {
        if (v == .object) {
            if (v.object.get("shader")) |s| {
                if (s == .integer) vs_id = @as(u16, @intCast(s.integer));
            }
        }
    }
    try appendInt(out, allocator, vs_id);

    // Vertex entry point — always emit when specified (needed when multiple entry points exist)
    if (vertex) |v| {
        if (v == .object) {
            if (v.object.get("entryPoint")) |ep| {
                if (ep == .string) {
                    try out.appendSlice(allocator, ",entryPoint:'");
                    try out.appendSlice(allocator, ep.string);
                    try out.appendSlice(allocator, "'");
                }
            }
        }
    }

    // Vertex buffers
    if (vertex) |v| {
        if (v == .object) {
            if (v.object.get("buffers")) |b| {
                if (b == .array and b.array.items.len > 0) {
                    try out.appendSlice(allocator, ",buffers:");
                    try emitJsonValue(out, allocator, b);
                }
            }
        }
    }

    try out.appendSlice(allocator, "},fragment:{module:s");
    return vs_id;
}

/// The `fragment:{…}` half: shader, entry point, blend state and colour target
/// format. Format priority is override (the render pass's actual target) >
/// descriptor > `f`, the canvas format resolved at runtime.
fn emitFragmentStage(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    override_format: ?[]const u8,
    vs_id: u16,
) !void {
    // Fragment shader
    const fragment = obj.get("fragment");
    var fs_id: u16 = 0;
    var target_format: ?[]const u8 = null;
    var fs_entry: ?[]const u8 = null;
    if (fragment) |f| {
        if (f == .object) {
            if (f.object.get("shader")) |s| {
                if (s == .integer) fs_id = @as(u16, @intCast(s.integer));
            }
            if (f.object.get("targetFormat")) |tf| {
                if (tf == .string) target_format = tf.string;
            }
            if (f.object.get("entryPoint")) |ep| {
                if (ep == .string) fs_entry = ep.string;
            }
        }
    } else {
        fs_id = vs_id;
    }
    try appendInt(out, allocator, fs_id);

    // Fragment entry point — always emit when specified (needed when multiple entry points exist)
    if (fs_entry) |ep| {
        try out.appendSlice(allocator, ",entryPoint:'");
        try out.appendSlice(allocator, ep);
        try out.appendSlice(allocator, "'");
    }
    // Blend state from the descriptor's fragment.targets[0].blend (browser-shape,
    // the WebGPU-ready `{color,alpha}` object). js_codegen previously dropped it →
    // --html never blended, so set_blend_constant had no visible effect. Emit it
    // verbatim (WebGPU accepts the string factors incl. constant/one-minus-constant).
    var blend_val: ?std.json.Value = null;
    if (fragment) |f| {
        if (f == .object) {
            if (f.object.get("targets")) |t| {
                if (t == .array and t.array.items.len > 0 and t.array.items[0] == .object) {
                    if (t.array.items[0].object.get("blend")) |bl| blend_val = bl;
                }
            }
        }
    }

    // Format priority: override (from render pass target) > JSON descriptor > canvas
    const effective_format = override_format orelse target_format;
    try out.appendSlice(allocator, ",targets:[{format:");
    if (effective_format) |fmt| {
        try out.append(allocator, '\'');
        try out.appendSlice(allocator, fmt);
        try out.append(allocator, '\'');
    } else {
        try out.append(allocator, 'f');
    }
    if (blend_val) |bl| {
        try out.appendSlice(allocator, ",blend:");
        try emitJsonValue(out, allocator, bl);
    }
    try out.appendSlice(allocator, "}]}");
}

/// The `primitive:{…}` block, omitted entirely when every field is at its
/// WebGPU default — a `{topology:'triangle-list'}` no browser needs is pure
/// payload weight.
fn emitPrimitiveState(out: *std.ArrayList(u8), allocator: std.mem.Allocator, obj: std.json.ObjectMap) !void {
    // Primitive — omit entirely when all defaults (topology=triangle-list, cullMode=none)
    const primitive = obj.get("primitive");
    if (primitive) |prim| {
        if (prim == .object) {
            const topo = prim.object.get("topology");
            const topo_str = if (topo != null and topo.? == .string) topo.?.string else "triangle-list";
            const is_default_topo = std.mem.eql(u8, topo_str, "triangle-list");

            const ff = prim.object.get("frontFace");
            const cm = prim.object.get("cullMode");
            const sif = prim.object.get("stripIndexFormat");
            const ud = prim.object.get("unclippedDepth");
            const has_ff = ff != null and ff.? == .string;
            const has_cm = cm != null and cm.? == .string;
            const has_sif = sif != null and sif.? == .string;
            const has_ud = ud != null and ud.? == .bool;

            if (!is_default_topo or has_ff or has_cm or has_sif or has_ud) {
                try out.appendSlice(allocator, ",primitive:{");
                var prim_first = true;
                if (!is_default_topo) {
                    try out.appendSlice(allocator, "topology:'");
                    try out.appendSlice(allocator, topo_str);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_ff) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "frontFace:'");
                    try out.appendSlice(allocator, ff.?.string);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_cm) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "cullMode:'");
                    try out.appendSlice(allocator, cm.?.string);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_sif) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "stripIndexFormat:'");
                    try out.appendSlice(allocator, sif.?.string);
                    try out.appendSlice(allocator, "'");
                    prim_first = false;
                }
                if (has_ud) {
                    if (!prim_first) try out.appendSlice(allocator, ",");
                    try out.appendSlice(allocator, "unclippedDepth:");
                    try out.appendSlice(allocator, if (ud.?.bool) "true" else "false");
                }
                try out.appendSlice(allocator, "}");
            }
        }
    }
}

/// Emit compute pipeline descriptor from JSON data.
pub fn emitComputePipelineDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    // Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
    //                 [layout_id:u16 LE (optional)]
    if (data.len >= 4 and data[0] == 0x06) {
        const shader_id: u16 = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
        const entry_len = data[3];
        const has_entry = entry_len > 0 and data.len >= 4 + entry_len;
        const entry_point = if (has_entry) data[4 .. 4 + entry_len] else "main";

        try out.appendSlice(allocator, "{layout:");
        if (extractComputePipelineLayoutId(data)) |lid| {
            try out.appendSlice(allocator, "PL");
            try appendInt(out, allocator, lid);
        } else {
            try out.appendSlice(allocator, "'auto'");
        }
        try out.appendSlice(allocator, ",compute:{module:s");
        try appendInt(out, allocator, shader_id);
        if (!std.mem.eql(u8, entry_point, "main")) {
            try out.appendSlice(allocator, ",entryPoint:'");
            try out.appendSlice(allocator, entry_point);
            try out.appendSlice(allocator, "'");
        }
        try out.appendSlice(allocator, "}}");
        return;
    }

    // Fallback: try JSON (legacy/manual descriptors)
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        try out.appendSlice(allocator, "{layout:'auto',compute:{module:s0}}");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return,
    };

    var cs_id: u16 = 0;

    if (obj.get("compute")) |comp| {
        if (comp == .object) {
            if (comp.object.get("shader")) |s| {
                if (s == .integer) cs_id = @as(u16, @intCast(s.integer));
            }
        }
    }

    try out.appendSlice(allocator, "{layout:'auto',compute:{module:s");
    try appendInt(out, allocator, cs_id);
    try out.appendSlice(allocator, "}}");
}

/// The `@group(N)` index a bind-group descriptor targets, read in a pre-pass
/// because it is emitted before the entries but may be stored after them.
fn scanBindGroupIndex(data: []const u8, field_count: u8) u8 {
    var group_index: u8 = 0;
    var q: usize = 2;
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x01 and vt == 0x07) {
            // layout field: group_index
            if (q < data.len) {
                group_index = data[q];
                q += 1;
            }
        } else if (fi == 0x02 and vt == 0x03) {
            // entries array — skipped here, emitted by the caller
            if (q < data.len) {
                var ec = data[q];
                q += 1;
                while (ec > 0) : (ec -= 1) {
                    if (q + 4 > data.len) break;
                    const rt = data[q + 1];
                    q += 4; // binding + resource_type + resource_id(u16)
                    if (rt == 0x00) q += 8; // buffer: offset + size
                }
            }
        }
    }
    return group_index;
}

/// Emit bind group descriptor from binary data.
///
/// Over the 70-line rule by design: the body is one walk over a contiguous
/// tagged-field table, and the arms are the table's rows. Its only separable
/// job — the group-index pre-pass — is already `scanBindGroupIndex` above.
pub fn emitBindGroupDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8, layout_id: u16) !void {
    // Binary format: [type_tag:u8][field_count:u8] then fields
    // field_id=0x01 (layout): [0x01][0x07][group_index:u8]
    // field_id=0x02 (entries): [0x02][0x03][count:u8] then per entry:
    //   [binding:u8][resource_type:u8][resource_id:u16 LE]
    //   if buffer: +[offset:u32 LE][size:u32 LE]

    if (data.len < 2) return;

    var q: usize = 2; // skip type_tag + field_count
    const field_count = data[1];
    const group_index = scanBindGroupIndex(data, field_count);

    // `layout_id` names one of two id spaces (opcodes.BIND_GROUP_LAYOUT_TAG):
    // tagged ⇒ the standalone BGL<n> this page already declares, untagged ⇒ the
    // auto-derived layout of pipeline p<n>. Emitting the pipeline form for a
    // tagged id printed `p<bgl id>` — a *different* pipeline when the ids
    // collided, and an undeclared identifier when they did not (§339).
    try out.appendSlice(allocator, "{layout:");
    if (opcodes.layoutIdIsBindGroupLayout(layout_id)) {
        try out.appendSlice(allocator, "BGL");
        try appendInt(out, allocator, opcodes.layoutIdValue(layout_id));
    } else {
        try out.appendSlice(allocator, "p");
        try appendInt(out, allocator, layout_id);
        try out.appendSlice(allocator, ".getBindGroupLayout(");
        try appendInt(out, allocator, group_index);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, ",entries:[");

    // Second pass: emit entries
    q = 2;
    var first_entry = true;
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x01 and vt == 0x07) {
            q += 1; // skip group_index
        } else if (fi == 0x02 and vt == 0x03) {
            if (q >= data.len) break;
            var ec = data[q];
            q += 1;
            while (ec > 0) : (ec -= 1) {
                if (q + 4 > data.len) break;
                const binding = data[q];
                const rt = data[q + 1];
                const ri = std.mem.readInt(u16, data[q + 2 ..][0..2], .little);
                q += 4;

                if (!first_entry) try out.appendSlice(allocator, ",");
                first_entry = false;

                try out.appendSlice(allocator, "{binding:");
                try appendInt(out, allocator, binding);
                try out.appendSlice(allocator, ",resource:");

                if (rt == 0x00) {
                    // buffer
                    try out.appendSlice(allocator, "{buffer:b");
                    try appendInt(out, allocator, ri);
                    try out.appendSlice(allocator, "}");
                    q += 8; // skip offset + size
                } else if (rt == 0x02) {
                    // sampler
                    try out.appendSlice(allocator, "m");
                    try appendInt(out, allocator, ri);
                } else if (rt == 0x03 or rt == 0x01) {
                    // texture bound directly → default view
                    try out.appendSlice(allocator, "T");
                    try appendInt(out, allocator, ri);
                    try out.appendSlice(allocator, ".createView()");
                } else if (rt == 0x04) {
                    // explicit (texture-view …) → the pre-created view var
                    try out.appendSlice(allocator, "V");
                    try appendInt(out, allocator, ri);
                }

                try out.appendSlice(allocator, "}");
            }
        }
    }

    try out.appendSlice(allocator, "]}");
}

// --- DCE helpers: extract resource IDs from descriptors ---

/// Extract shader IDs from a render pipeline descriptor (JSON format).
pub fn extractRenderPipelineShaders(allocator: std.mem.Allocator, data: []const u8, used_shaders: *std.AutoHashMapUnmanaged(u16, void)) std.mem.Allocator.Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("vertex")) |v| {
        if (v == .object) {
            if (v.object.get("shader")) |s| {
                if (s == .integer) try used_shaders.put(allocator, @intCast(s.integer), {});
            }
        }
    }
    if (obj.get("fragment")) |f| {
        if (f == .object) {
            if (f.object.get("shader")) |s| {
                if (s == .integer) try used_shaders.put(allocator, @intCast(s.integer), {});
            }
        }
    } else {
        // fragment defaults to same shader as vertex
        if (obj.get("vertex")) |v| {
            if (v == .object) {
                if (v.object.get("shader")) |s| {
                    if (s == .integer) try used_shaders.put(allocator, @intCast(s.integer), {});
                }
            }
        }
    }
}

/// Extract shader ID from a compute pipeline descriptor (binary or JSON).
pub fn extractComputePipelineShader(allocator: std.mem.Allocator, data: []const u8, used_shaders: *std.AutoHashMapUnmanaged(u16, void)) std.mem.Allocator.Error!void {
    // Binary format: [type_tag:0x06][shader_id:u16 LE][entry_len:u8][entry_bytes]
    if (data.len >= 4 and data[0] == 0x06) {
        const shader_id: u16 = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
        try used_shaders.put(allocator, shader_id, {});
        return;
    }
    // JSON fallback
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("compute")) |comp| {
        if (comp == .object) {
            if (comp.object.get("shader")) |s| {
                if (s == .integer) try used_shaders.put(allocator, @intCast(s.integer), {});
            }
        }
    }
}

/// The explicit pipeline-layout id a render pipeline references (its JSON
/// `layoutId`), or null for an auto-layout pipeline.
pub fn extractRenderPipelineLayoutId(allocator: std.mem.Allocator, data: []const u8) ?u16 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get("layoutId")) |l| {
        if (l == .integer) return @intCast(l.integer);
    }
    return null;
}

/// The explicit pipeline-layout id a compute pipeline references (the trailing
/// u16 past its entry point at offset 4+entry_len), or null for auto-layout.
pub fn extractComputePipelineLayoutId(data: []const u8) ?u16 {
    if (data.len < 4 or data[0] != 0x06) return null;
    const entry_len = data[3];
    const off: usize = 4 + @as(usize, entry_len);
    if (data.len < off + 2) return null;
    return @as(u16, data[off]) | (@as(u16, data[off + 1]) << 8);
}

/// Mark each bind-group-layout composed by a pipeline-layout descriptor
/// (`{"bindGroupLayouts":[id0,id1,…]}`) as used.
pub fn extractPipelineLayoutBGLs(allocator: std.mem.Allocator, data: []const u8, used_bgls: *std.AutoHashMapUnmanaged(u16, void)) std.mem.Allocator.Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    if (obj.get("bindGroupLayouts")) |bgls| {
        if (bgls == .array) {
            for (bgls.array.items) |item| {
                if (item == .integer) try used_bgls.put(allocator, @intCast(item.integer), {});
            }
        }
    }
}

/// Emit a `createPipelineLayout` descriptor: `{bindGroupLayouts:[BGL0,BGL1,…]}`
/// from the JSON `{"bindGroupLayouts":[id0,id1,…]}`, mapping each id to its BGL
/// variable reference.
pub fn emitPipelineLayoutDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        try out.appendSlice(allocator, "{bindGroupLayouts:[]}");
        return;
    };
    defer parsed.deinit();
    try out.appendSlice(allocator, "{bindGroupLayouts:[");
    if (parsed.value == .object) {
        if (parsed.value.object.get("bindGroupLayouts")) |bgls| {
            if (bgls == .array) {
                for (bgls.array.items, 0..) |item, i| {
                    if (i != 0) try out.append(allocator, ',');
                    try out.appendSlice(allocator, "BGL");
                    if (item == .integer) try appendInt(out, allocator, @as(u16, @intCast(item.integer)));
                }
            }
        }
    }
    try out.appendSlice(allocator, "]}");
}

/// Extract buffer/sampler/texture IDs from bind group entry data (binary format).
pub fn extractBindGroupResources(
    allocator: std.mem.Allocator,
    data: []const u8,
    used_buffers: *std.AutoHashMapUnmanaged(u16, void),
    used_samplers: *std.AutoHashMapUnmanaged(u16, void),
    used_textures: *std.AutoHashMapUnmanaged(u16, void),
    used_views: *std.AutoHashMapUnmanaged(u16, void),
) std.mem.Allocator.Error!void {
    if (data.len < 2) return;
    const field_count = data[1];
    var q: usize = 2;
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x01 and vt == 0x07) {
            q += 1; // skip group_index
        } else if (fi == 0x02 and vt == 0x03) {
            if (q >= data.len) break;
            var ec = data[q];
            q += 1;
            while (ec > 0) : (ec -= 1) {
                if (q + 4 > data.len) break;
                const rt = data[q + 1];
                const ri = std.mem.readInt(u16, data[q + 2 ..][0..2], .little);
                q += 4;
                switch (rt) {
                    0x00 => {
                        try used_buffers.put(allocator, ri, {});
                        q += 8; // skip offset + size
                    },
                    0x02 => try used_samplers.put(allocator, ri, {}),
                    0x01, 0x03 => try used_textures.put(allocator, ri, {}),
                    0x04 => try used_views.put(allocator, ri, {}), // explicit (texture-view …)
                    else => {},
                }
            }
        }
    }
}

/// The fields a texture descriptor blob can carry. Absent is distinct from
/// zero: a canvas-sized texture simply omits width/height, and the emitter
/// substitutes `c.width`/`c.height` for them.
const TextureFields = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    depth_or_array_layers: ?u32 = null,
    mip_level_count: ?u32 = null,
    sample_count: ?u32 = null,
    dimension: u8 = 1, // 0=1d, 1=2d, 2=3d
    format: ?[]const u8 = null,
    usage: u8 = 0,
};

/// Decode half of the texture descriptor: walk the tagged fields, ignore any
/// tag this build does not know (`skipValue` steps over it by wire type).
fn parseTextureFields(data: []const u8) TextureFields {
    std.debug.assert(data.len >= 2);
    var f: TextureFields = .{};
    var q: usize = 2; // skip type_tag + field_count
    const field_count = data[1];

    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        switch (fi) {
            0x01, 0x02, 0x03, 0x04, 0x05 => { // the five u32 size/count fields
                if (vt != 0x00 or q + 4 > data.len) continue;
                const val = std.mem.readInt(u32, data[q..][0..4], .little);
                switch (fi) {
                    0x01 => f.width = val,
                    0x02 => f.height = val,
                    0x03 => f.depth_or_array_layers = val,
                    0x04 => f.mip_level_count = val,
                    else => f.sample_count = val,
                }
                q += 4;
            },
            0x06 => { // dimension
                if (vt == 0x07 and q < data.len) {
                    f.dimension = data[q];
                    q += 1;
                }
            },
            0x07 => { // format
                if (vt == 0x07 and q < data.len) {
                    f.format = textureFormatStr(data[q]);
                    q += 1;
                }
            },
            0x08 => { // usage — an enum byte in new blobs, a u32 in older ones
                if (vt == 0x07 and q < data.len) {
                    f.usage = data[q];
                    q += 1;
                } else if (vt == 0x00 and q + 4 <= data.len) {
                    f.usage = @intCast(std.mem.readInt(u32, data[q..][0..4], .little));
                    q += 4;
                }
            },
            else => q = skipValue(data, q, vt),
        }
    }
    return f;
}

/// Emit texture descriptor from binary data.
pub fn emitTextureDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    if (data.len < 2) {
        try out.appendSlice(allocator, "{}");
        return;
    }

    const f = parseTextureFields(data);

    // Canvas-size textures omit width/height fields — use canvas dimensions
    try out.appendSlice(allocator, "{size:[");
    if (f.width) |w| {
        try appendInt(out, allocator, w);
    } else {
        try out.appendSlice(allocator, "c.width");
    }
    try out.appendSlice(allocator, ",");
    if (f.height) |h| {
        try appendInt(out, allocator, h);
    } else {
        try out.appendSlice(allocator, "c.height");
    }
    if (f.depth_or_array_layers) |d| {
        try out.appendSlice(allocator, ",");
        try appendInt(out, allocator, d);
    }
    try out.appendSlice(allocator, "],");
    if (f.dimension != 1) {
        try out.appendSlice(allocator, "dimension:'");
        try out.appendSlice(allocator, switch (f.dimension) {
            0 => "1d",
            2 => "3d",
            else => "2d",
        });
        try out.appendSlice(allocator, "',");
    }
    if (f.mip_level_count) |m| {
        try out.appendSlice(allocator, "mipLevelCount:");
        try appendInt(out, allocator, m);
        try out.appendSlice(allocator, ",");
    }
    if (f.sample_count) |n| {
        try out.appendSlice(allocator, "sampleCount:");
        try appendInt(out, allocator, n);
        try out.appendSlice(allocator, ",");
    }
    try out.appendSlice(allocator, "format:'");
    try out.appendSlice(allocator, f.format orelse "rgba8unorm");
    try out.appendSlice(allocator, "',usage:");
    try appendInt(out, allocator, f.usage);
    try out.appendSlice(allocator, "}");
}

/// Emit a texture-view descriptor (TLV type tag 0x09) from binary data as a
/// GPUTextureViewDescriptor object literal. Every field is optional, so an
/// all-default view yields `{}` (a plain createView()).
pub fn emitTextureViewDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    if (data.len < 2) {
        try out.appendSlice(allocator, "{}");
        return;
    }
    var q: usize = 2; // skip type_tag + field_count
    const field_count = data[1];
    var has_fields = false;

    try out.appendSlice(allocator, "{");
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (vt == 0x07 and q < data.len) { // enum → quoted string
            const val = data[q];
            q += 1;
            const kv: ?struct { k: []const u8, v: []const u8 } = switch (fi) {
                0x01 => .{ .k = "format", .v = textureFormatStr(val) },
                0x02 => .{ .k = "dimension", .v = viewDimensionStr(val) },
                0x03 => .{ .k = "aspect", .v = textureAspectStr(val) },
                else => null,
            };
            if (kv) |p| {
                if (has_fields) try out.appendSlice(allocator, ",");
                has_fields = true;
                try out.appendSlice(allocator, p.k);
                try out.appendSlice(allocator, ":'");
                try out.appendSlice(allocator, p.v);
                try out.appendSlice(allocator, "'");
            }
        } else if (vt == 0x00 and q + 4 <= data.len) { // u32 → number
            const val = std.mem.readInt(u32, data[q..][0..4], .little);
            q += 4;
            const key: ?[]const u8 = switch (fi) {
                0x04 => "baseMipLevel",
                0x05 => "mipLevelCount",
                0x06 => "baseArrayLayer",
                0x07 => "arrayLayerCount",
                else => null,
            };
            if (key) |k| {
                if (has_fields) try out.appendSlice(allocator, ",");
                has_fields = true;
                try out.appendSlice(allocator, k);
                try out.appendSlice(allocator, ":");
                try appendInt(out, allocator, val);
            }
        } else {
            q = skipValue(data, q, vt);
        }
    }
    try out.appendSlice(allocator, "}");
}

/// view-dimension byte → GPUTextureViewDimension string.
fn viewDimensionStr(v: u8) []const u8 {
    return switch (v) {
        0 => "1d",
        1 => "2d",
        2 => "2d-array",
        3 => "cube",
        4 => "cube-array",
        5 => "3d",
        else => "2d",
    };
}

/// texture-aspect byte → GPUTextureAspect string.
fn textureAspectStr(v: u8) []const u8 {
    return switch (v) {
        1 => "stencil-only",
        2 => "depth-only",
        else => "all",
    };
}

/// Parse texture format string from binary descriptor data.
pub fn parseTextureFormat(data: []const u8) ?[]const u8 {
    if (data.len < 2) return null;
    var q: usize = 2;
    const field_count = data[1];
    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;
        if (fi == 0x07 and vt == 0x07 and q < data.len) {
            return textureFormatStr(data[q]);
        }
        q = skipValue(data, q, vt);
    }
    return null;
}

/// Emit sampler descriptor from binary data.
///
/// Over the 70-line rule by design: a contiguous field table (ten sampler
/// fields, three wire types), same judgement as emitBindGroupDesc.
pub fn emitSamplerDesc(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    if (data.len < 2) {
        try out.appendSlice(allocator, "{}");
        return;
    }

    var q: usize = 2;
    const field_count = data[1];
    var has_fields = false;

    try out.appendSlice(allocator, "{");

    for (0..field_count) |_| {
        if (q + 2 > data.len) break;
        const fi = data[q];
        const vt = data[q + 1];
        q += 2;

        const name: ?[]const u8 = switch (fi) {
            0x01 => "addressModeU",
            0x02 => "addressModeV",
            0x03 => "addressModeW",
            0x04 => "magFilter",
            0x05 => "minFilter",
            0x06 => "mipmapFilter",
            0x07 => "lodMinClamp",
            0x08 => "lodMaxClamp",
            0x09 => "compare",
            0x0A => "maxAnisotropy",
            else => null,
        };

        const n = name orelse {
            q = skipValue(data, q, vt);
            continue;
        };

        if (vt == 0x07 and q < data.len) { // enum → quoted string
            if (has_fields) try out.appendSlice(allocator, ",");
            has_fields = true;
            try out.appendSlice(allocator, n);
            try out.appendSlice(allocator, ":'");
            const val_str: []const u8 = switch (fi) {
                0x01, 0x02, 0x03 => addressModeStr(data[q]),
                0x04, 0x05, 0x06 => filterModeStr(data[q]),
                0x09 => compareFnStr(data[q]),
                else => "nearest",
            };
            try out.appendSlice(allocator, val_str);
            try out.appendSlice(allocator, "'");
            q += 1;
        } else if (vt == 0x01 and q + 4 <= data.len) { // f32 (lod clamps) → number
            if (has_fields) try out.appendSlice(allocator, ",");
            has_fields = true;
            try out.appendSlice(allocator, n);
            try out.appendSlice(allocator, ":");
            const bits = std.mem.readInt(u32, data[q..][0..4], .little);
            try appendCompactFloat(out, allocator, @bitCast(bits));
            q += 4;
        } else if (vt == 0x06 and q + 2 <= data.len) { // u16 (max anisotropy) → number
            if (has_fields) try out.appendSlice(allocator, ",");
            has_fields = true;
            try out.appendSlice(allocator, n);
            try out.appendSlice(allocator, ":");
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{std.mem.readInt(u16, data[q..][0..2], .little)}) catch "0";
            try out.appendSlice(allocator, s);
            q += 2;
        } else {
            q = skipValue(data, q, vt);
        }
    }

    try out.appendSlice(allocator, "}");
}

// ============================================================================
// Helpers
// ============================================================================

/// How deep a binary descriptor may nest arrays/structs before `skipValue`
/// gives up. Real descriptors reach two (a sampler's fields, a texture's size
/// array); the cap is for a crafted blob, where each `0x03`/`0x04` byte used to
/// buy a stack frame.
const MAX_NESTING = 32;

/// Advance past one value of type `vt` starting at `pos`, returning the position
/// just after it. `data` is payload-supplied, so every read is bounds-checked
/// and a truncated blob simply stops the walk.
///
/// Iterative: the recursive spelling this replaces let a descriptor blob of
/// `0x03` bytes nest one stack frame per byte, which `pngine <art.png> --html`
/// reaches on any downloaded file (mastery rule 1; CONTRIBUTING pitfall 55).
/// Past `MAX_NESTING` it returns `data.len`, which ends the caller's field loop
/// exactly as a truncated blob does.
pub fn skipValue(data: []const u8, pos: usize, vt: u8) usize {
    std.debug.assert(pos <= data.len); // callers only ever hand us a live cursor

    // One entry per open container: how many of its children are still unread.
    var stack: [MAX_NESTING]u32 = undefined;
    var depth: usize = 0;

    var q = pos;
    var current: ?u8 = vt; // the value type to skip next, if any

    // Bounded: each iteration either advances q, opens a container (which
    // advances q), or closes one, and both counts are bounded by data.len.
    const budget = 4 * data.len + 8;
    for (0..budget) |_| {
        if (current) |t| {
            current = null;
            switch (t) {
                0x00 => q += 4, // u32
                0x01 => q += 4, // f32
                0x02 => q += 2, // string_id
                0x05 => q += 1, // bool
                0x06 => q += 2, // u16
                0x07 => q += 1, // enum
                0x03 => { // array: [count:u8] then count × [field_id][value_type]value
                    if (q < data.len) {
                        if (depth == MAX_NESTING) return data.len;
                        stack[depth] = data[q];
                        depth += 1;
                        q += 1;
                    }
                },
                0x04 => { // nested: [type_tag][field_count] then field_count fields
                    if (q + 2 <= data.len) {
                        if (depth == MAX_NESTING) return data.len;
                        stack[depth] = data[q + 1];
                        depth += 1;
                        q += 2;
                    }
                },
                else => q += 1,
            }
            continue;
        }

        if (depth == 0) return q;
        const remaining = &stack[depth - 1];
        // Out of children, or the blob ends mid-header: close this container.
        // The parent re-checks the same truncation and closes in turn, which is
        // how the recursive version unwound too.
        if (remaining.* == 0 or q + 2 > data.len) {
            depth -= 1;
            continue;
        }
        remaining.* -= 1;
        current = data[q + 1];
        q += 2;
    } else return data.len;
}

// Byte-code → WebGPU string reverse tables are single-sourced with the enum
// definitions in types/descriptors.zig (toWebGPU). TextureFormat is
// non-exhaustive, so an unknown code decodes to its `_` variant and falls back
// to "rgba8unorm"; the exhaustive enums use intToEnum with the same defaults
// the old tables carried in their `else` arms.
fn textureFormatStr(val: u8) []const u8 {
    return @as(descriptors.TextureFormat, @enumFromInt(val)).toWebGPU();
}

fn filterModeStr(val: u8) []const u8 {
    const e = std.enums.fromInt(descriptors.FilterMode, val) orelse return "nearest";
    return e.toWebGPU();
}

fn addressModeStr(val: u8) []const u8 {
    const e = std.enums.fromInt(descriptors.AddressMode, val) orelse return "clamp-to-edge";
    return e.toWebGPU();
}

fn compareFnStr(val: u8) []const u8 {
    const e = std.enums.fromInt(descriptors.CompareFunction, val) orelse return "never";
    return e.toWebGPU();
}

// ============================================================================
// Tests
// ============================================================================

/// The recursive spelling `skipValue` replaced, kept as a test oracle only.
/// Bounded here by construction: the fuzz corpus below is 64 bytes, so the
/// deepest blob it can express is 64 frames.
fn skipValueRecursive(data: []const u8, pos: usize, vt: u8) usize {
    var q = pos;
    switch (vt) {
        0x00 => q += 4,
        0x01 => q += 4,
        0x02 => q += 2,
        0x05 => q += 1,
        0x06 => q += 2,
        0x07 => q += 1,
        0x03 => {
            if (q < data.len) {
                var ec = data[q];
                q += 1;
                while (ec > 0) : (ec -= 1) {
                    if (q + 2 > data.len) break;
                    const inner_vt = data[q + 1];
                    q += 2;
                    q = skipValueRecursive(data, q, inner_vt);
                }
            }
        },
        0x04 => {
            if (q + 2 <= data.len) {
                const nested_fc = data[q + 1];
                q += 2;
                for (0..nested_fc) |_| {
                    if (q + 2 > data.len) break;
                    const inner_vt = data[q + 1];
                    q += 2;
                    q = skipValueRecursive(data, q, inner_vt);
                }
            }
        },
        else => q += 1,
    }
    return q;
}

/// One bind-group descriptor binding sampler id 7, the smallest blob that
/// reaches a `used_*.put`. Layout: [_, field_count, field_index, value_tag,
/// entry_count, _, resource_tag, resource_id_lo, resource_id_hi].
const one_sampler_binding = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x01, 0x00, 0x02, 0x07, 0x00 };
