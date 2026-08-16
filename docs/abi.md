# The Executor WASM ↔ JS ABI (v1) — FROZEN

This document is the canonical specification of the interface between an
**embedded executor** (the WASM binary shipped inside a PNG payload) and the
**JS runtime** (`npm/pngine/src/gpu.js`, `gpu-resource-pass-commands.js`,
`loader.js`, `worker.js`, `worker-viewer.js`).

## Why this interface is frozen

A PNGine PNG is an immutable artifact: bytecode + its own interpreter, minted
once, expected to render forever. The PNGB payload format is locked at v0 *by
design* — payload evolution rides on the embedded executor, so the header never
needs to change. What CANNOT ride along is the other half of the contract: the
JS runtime is the moving part, and it must run **every executor ever shipped
inside a PNG**, forever.

Everything in this document is therefore append-only. The enforcement tests are
listed at the end; a change that trips one of them is presumed wrong — fix the
change, not the test.

## 1. ABI version

```
getAbiVersion() → u32
```

- Executors that **lack** this export are ABI **v1** (everything shipped before
  this document existed). JS must read it as `exports.getAbiVersion?.() ?? 1`.
- The version is a diagnostic and an escape hatch, not a license to change
  things: the change policy below is designed so it stays at 1.

## 2. Executor exports (frozen; additive-only)

| Export | Signature | Semantics |
| --- | --- | --- |
| `memory` | WebAssembly.Memory | Linear memory; all pointers below are offsets into it |
| `getBytecodePtr` | `() → u32` | Pointer where host writes the payload head (header + opcodes + tables) |
| `setBytecodeLen` | `(len: u32) → void` | Set after writing. **Silently clamps** to the binary's bytecode cap (default 256 KB) |
| `getDataPtr` | `() → u32` | Pointer where host writes the data section (split mode) |
| `setDataLen` | `(len: u32) → void` | Set after writing. **Silently clamps** to the data cap (default 512 KB). Never calling it (len stays 0) selects single-buffer mode — see §4 |
| `getCommandPtr` | `() → u32` | Pointer to the command buffer |
| `getCommandLen` | `() → u32` | Reads the `total_len` u32 the executor wrote at `cmd[0..4]` — only valid after `init()`/`frame()` |
| `init` | `() → u32` | Parse header, emit resource-creation commands. `0` ok, `1` bytecode too short, `2` bad magic, `3` unsupported PNGB version |
| `frame` | `(time: f32, width: u32, height: u32) → u32` | Emit per-frame commands. `0` ok, `1` not initialized. Host must pass nonzero width/height |
| `getFrameCounter` | `() → u32` | Frames rendered since `init()` (drives ping-pong pool selection) |
| `setFrameCounter` | `(n: u32) → void` | Restore a saved counter around host-side ephemeral renders (thumbnails must not shift pool phase). Absent on pre-2026-08 binaries — hosts feature-detect |
| `getAbiVersion` | `() → u32` | See §1. Absent on pre-2026-06 binaries |

Buffer caps (256 KB bytecode / 512 KB data / 64 KB commands) are **per-binary**
constants (`wasm_config` build options; the micro build shrinks them). The ABI
constant is the *protocol*: lengths are clamped silently, never rejected.

New exports may be added (JS reads them with optional chaining). Existing
exports may never change signature or semantics, and never be removed.

## 3. Executor imports / the host import object

**Release executors require zero host imports.** The debug-logging sites in
`wasm_entry.zig` are compiled out by default (comptime-gated on the `debug_log`
build option, off by default), so a shipped binary declares no
import section at all. Only a `-Ddebug-log` build declares the one optional
import:

```
env.log(ptr: u32, len: u32) → void    // debug text; declared ONLY under -Ddebug-log
```

The host (`loader.js getExecutorImports()`) provides a superset regardless:
`env.log`, `env.wasmInstantiate`, `env.wasmCall`, `env.wasmGetResult`.
Extra provided imports are harmless — WASM instantiation only resolves the
imports a module declares, and a module that declares *fewer* imports always
loads. (The pinned museum binaries predate the gate and still import `env.log`;
the host keeps providing it forever.)

**Policy:** the host-provided set may only **grow**. An executor may only
require imports that the *oldest supported runtime* already provides — which in
practice means: a new executor import requires shipping the JS that provides it
first, and accepting that older runtimes cannot run the new binaries (the
reverse — old binaries on new runtimes — must always work).

## 4. Host call protocol

Canonical implementation: `worker.js loadBytecode()` / `render()`.
`worker-viewer.js` mirrors it. The museum test replays it in Node.

1. `parsePayload(pngb)` (loader.js) → section offsets from the PNGB v0 header.
2. Write `payload[0 .. offsets.data)` into memory at `getBytecodePtr()`;
   call `setBytecodeLen(offsets.data)`.
3. If `offsets.wgsl - offsets.data > 0`: write `payload[offsets.data ..
   offsets.wgsl)` at `getDataPtr()`; call `setDataLen(len)`.
   - **Single-buffer mode (frozen):** if `setDataLen` is never called, the
     executor reads the data section from the bytecode buffer instead
     (`data_in_bytecode`, wasm_entry.zig). Both modes are ABI.
4. `init()` — must return 0. Execute the command buffer:
   `execute(getCommandPtr())` (length is implicit in the buffer header).
5. Per frame: `frame(time, width, height)` — must return 0 — then
   `execute(getCommandPtr())`.

The command buffer is valid until the next `init()`/`frame()` call.

### Status codes

Nonzero means **do not execute this command buffer** — skip it and surface the
status (`worker-core.js render()` posts a deduped `gpu-error`). The set is
append-only; a host must treat an unknown nonzero the same way.

| Call | Code | Meaning |
| ---- | ---- | ------- |
| `init` | 1 | bytecode shorter than the v0 header |
| `init` | 2 | bad magic (not `PNGB`) |
| `init` | 3 | unsupported version |
| `init` | 5 | out-of-range id in resource creation |
| `init` | 6 | command buffer overflowed |
| `frame` | 1 | not initialised — `init()` was not called, or refused |
| `frame` | 2 | out-of-range id in the frame body |
| `frame` | 3 | command buffer overflowed |


## 5. Command-buffer wire format

All integers little-endian. Pointers are u32 offsets into the executor's
`memory`.

```
Header (8 bytes):
  [total_len: u32]   total bytes including header
  [cmd_count: u16]   number of commands
  [flags: u16]       bit 0 = truncated; other bits reserved (0)

Then cmd_count commands:
  [opcode: u8] [args: fixed layout per opcode]
```

Magic resource IDs: `0xFFFF` = none/absent, `0xFFFE` = canvas swap-chain
texture.

`cmd_count` and `total_len` always describe the same commands: the buffer ends
exactly where the last WHOLE command ends. A command that does not fit is
dropped entirely, along with everything after it, and **flags bit 0** is set —
the payload wanted more commands than the 64 KB buffer holds (8 KB in the micro
executor). `init`/`frame` return a nonzero status in that case, so a conforming
host never executes a truncated buffer; the header stays honest anyway, so one
that ignores the status still reads no residue. (Earlier executors counted
commands the buffer had no room for, and a handler's operand reads ran past
`total_len` into the previous frame's bytes.)

### Opcode table (complete; sizes exclude the opcode byte)

| Op | Name | Argument layout | Size |
| --- | --- | --- | --- |
| 0x01 | create_buffer | `[id:u16][size:u32][usage:u16]` (usage = WebGPU GPUBufferUsage bits) | 8 |
| 0x02 | create_texture | `[id:u16][desc_ptr:u32][desc_len:u32]` → binary texture descriptor (§6.1) | 10 |
| 0x03 | create_sampler | `[id:u16][desc_ptr:u32][desc_len:u32]` → binary sampler descriptor (§6.1) | 10 |
| 0x04 | create_shader | `[id:u16][code_ptr:u32][code_len:u32]` → WGSL UTF-8 text | 10 |
| 0x05 | create_render_pipeline | `[id:u16][desc_ptr:u32][desc_len:u32]` → **JSON** descriptor (§6.2) | 10 |
| 0x06 | create_compute_pipeline | `[id:u16][desc_ptr:u32][desc_len:u32]` → binary (§6.3) | 10 |
| 0x07 | create_bind_group | `[id:u16][layout_id:u16][entries_ptr:u32][entries_len:u32]` → binary entries (§6.4). `layout_id` names two id spaces — see below | 12 |
| 0x08 | create_texture_view | `[id:u16][texture_id:u16][desc_ptr:u32][desc_len:u32]` | 12 |
| 0x09 | create_query_set | `[id:u16][desc_ptr:u32][desc_len:u32]` → `[type:u8 (1=timestamp, else occlusion)][count:u16]` | 10 |
| 0x0A | create_bind_group_layout | `[id:u16][desc_ptr:u32][desc_len:u32]` → **JSON** (GPUBindGroupLayoutDescriptor) | 10 |
| 0x0B | create_image_bitmap | `[id:u16][data_ptr:u32][data_len:u32]` → blob `[mime_len:u8][mime][image bytes]` (async in JS) | 10 |
| 0x0C | create_pipeline_layout | `[id:u16][desc_ptr:u32][desc_len:u32]` → **JSON** `{bindGroupLayouts:[bgl ids]}` | 10 |
| 0x0D | create_render_bundle | `[id:u16][desc_ptr:u32][desc_len:u32]` → binary bundle descriptor (§6.5) | 10 |
| 0x10 | begin_render_pass | `[color_id:u16][load:u8][store:u8][depth_id:u16][r:u8][g:u8][b:u8][a:u8][resolve_id:u16]` | 12 |
| 0x11 | begin_compute_pass | — | 0 |
| 0x12 | set_pipeline | `[id:u16]` | 2 |
| 0x13 | set_bind_group | `[slot:u8][id:u16]` | 3 |
| 0x14 | set_vertex_buffer | `[slot:u8][id:u16]` | 3 |
| 0x15 | draw | `[vtx:u32][inst:u32][first_vtx:u32][first_inst:u32]` | 16 |
| 0x16 | draw_indexed | `[idx:u32][inst:u32][first_idx:u32][base_vtx:i32][first_inst:u32]` | 20 |
| 0x17 | end_pass | — | 0 |
| 0x18 | dispatch | `[x:u32][y:u32][z:u32]` | 12 |
| 0x19 | set_index_buffer | `[id:u16][format:u8 (0=uint16, 1=uint32)]` | 3 |
| 0x1A | execute_bundles | `[count:u8][bundle_ids:u16 × count]` | 1+2n |
| 0x1B | begin_render_pass_mrt | `[count:u8]` then per attachment `[tex_id:u16][load:u8][store:u8][r:u8][g:u8][b:u8][a:u8]` then `[depth_id:u16]` | 1+8n+2 |
| 0x1C | draw_indirect | `[buffer_id:u16][offset:u32]` | 6 |
| 0x1D | draw_indexed_indirect | `[buffer_id:u16][offset:u32]` | 6 |
| 0x1E | dispatch_indirect | `[buffer_id:u16][offset:u32]` | 6 |
| 0x1F | set_viewport | `[x:u32][y:u32][w:u32][h:u32][min_depth:f32][max_depth:f32]` | 24 |
| 0x20 | write_buffer | `[id:u16][offset:u32][data_ptr:u32][data_len:u32]` | 14 |
| 0x21 | write_time_uniform | `[id:u16][offset:u32][size:u16]` — JS writes `Float32Array([time, w, h, w/h])`, clamped to min(size, 16) | 8 |
| 0x22 | copy_buffer_to_buffer | `[src:u16][src_off:u32][dst:u16][dst_off:u32][size:u32]` | 16 |
| 0x23 | copy_texture_to_texture | `[src:u16][dst:u16][w:u16][h:u16]` (0 → canvas dims) | 8 |
| 0x24 | write_buffer_from_wasm | `[buffer_id:u16][buffer_off:u32][call_id:u32][size:u32]` | 14 |
| 0x25 | copy_external_image_to_texture | `[bitmap_id:u16][texture_id:u16][mip:u8][origin_x:u16][origin_y:u16][origin_z:u16]` | 11 |
| 0x26 | write_pointer_uniform | `[id:u16][offset:u32][size:u16]` — 12 floats of pointer state, clamped to min(size, 48) | 8 |
| 0x27 | resolve_query_set | `[qs_id:u16][first:u32][count:u32][dest_buf:u16][dest_off:u32]` | 16 |
| 0x30 | init_wasm_module | `[module_id:u16][data_ptr:u32][data_len:u32]` (async in JS) | 10 |
| 0x31 | call_wasm_func | `[call_id:u16][module_id:u16][name_ptr:u32][name_len:u32][args_len:u8][args blob inline]` | 13+n |
| 0x4A | set_pass_timestamp_writes | `[qs_id:u16][begin_idx:u16][end_idx:u16]` | 6 |
| 0x4B | set_pass_occlusion_query_set | `[qs_id:u16]` | 2 |
| 0x4C | end_occlusion_query | — | 0 |
| 0x4D | begin_occlusion_query | `[query_index:u32]` | 4 |
| 0x4E | set_stencil_reference | `[reference:u32]` | 4 |
| 0x4F | set_scissor_rect | `[x:u32][y:u32][w:u32][h:u32]` | 16 |
| 0x50 | set_pass_depth_stencil_ops | `[depth_load:u8][depth_store:u8][stencil_load:u8][stencil_store:u8]` | 4 |
| 0x51 | set_blend_constant | `[r:f32][g:f32][b:f32][a:f32]` — the `constant`/`one-minus-constant` blend factor value | 16 |
| 0xF0 | submit | — | 0 |
| 0xFF | end | — | 0 |

Load op encoding: 0=load, 1=clear. Store op: 0=store, 1=discard.
The 0x40–0x49 gap and all other unassigned values are reserved **forever** —
never reuse a retired or skipped value.

`call_wasm_func` args blob (as emitted): `[arg_count:u8]` then per arg a
`[type:u8]` tag followed by that tag's value bytes. The blob is **variable
width** — four of the seven tags carry no value — and `args_len` covers the
whole blob, count byte included, so a zero-arg call sends `args_len` **1**, not
0.

| Tag | `WasmArgType` | Value bytes | Resolved by |
| --- | --- | --- | --- |
| 0x00 | `literal_f32` | 4 (f32 LE) | compiler |
| 0x01 | `canvas_width` | — | player, at call time |
| 0x02 | `canvas_height` | — | player, at call time |
| 0x03 | `time_total` | — | player, at call time |
| 0x04 | `literal_i32` | 4 (i32 LE) | compiler |
| 0x05 | `literal_u32` | 4 (u32 LE) | compiler |
| 0x06 | `time_delta` | — | player, at call time |

The executor forwards the blob verbatim with the runtime tags **unresolved**, so
`gpu.js decodeWasmArgs` is the single place a `#wasmCall`'s arguments are
actually built. An **unknown tag consumes zero value bytes and stops the walk**:
its width is precisely what is unknown, so no argument after it can be located
(`WasmArgType.valueByteSize`'s `_ => 0`, mirrored by `decodeWasmArgs`'s
`else break`). Cap: ≤ 32 args — see the next section. Pinned against the Zig
enum by `tests/npm/wasm-args-decode.test.js`.

**Unknown opcodes abort the buffer.** A command no JS sub-dispatcher claims
returns the `UNKNOWN_CMD` sentinel (`gpu.js`); `execute()` stops there and
reports `unknown GPU command 0x…` through the host's `onError`. It cannot do
otherwise — the operand width is exactly what is unknown, so advancing would
read operand bytes as opcodes. This is why opcodes are append-only, and why a
new opcode may only be *emitted* by executors that ship after the JS that
handles it (§7 clause 7). `mini.js`, whose flat player implements a subset by
design, `throw`s instead. Both refuse; neither skips.

### Frontend-enforced runtime caps

Three limits are enforced by the compiler so a shipped PNG never trips them
silently. The first two are structural to the *default* executor rather than to
the wire format (`bytecode.DEFAULT_MAX_PASSES` / `bytecode.MAX_EXECUTE_BUNDLES`);
the third is part of the wire format itself:

- **≤ 32 passes per document.** The embedded executor stores pass ranges in a
  fixed `pass_ranges[32]` table (`wasm_config.max_passes`); a `define_pass`
  beyond index 32 is silently dropped at load. The reference dispatcher's pass
  map is unbounded, so an over-cap document renders under native `--frame`/tests
  but loses passes in browsers. The SJON emitter rejects `> 32` passes up front.
- **≤ 16 bundles per `execute_bundles`**
  (`wire_schema.repMaxOf(.execute_bundles)`, which `MAX_EXECUTE_BUNDLES` now
  derives from). The opcode decodes into a fixed `[16]u16` buffer in *both* the
  shipping executor and the reference dispatcher, and the SJON emitter rejects a
  pass listing more. Over-cap is **refused**, not read-and-discarded, so the
  decoders and `skipParams` can never disagree about where the command ends.
  A custom executor build may raise `max_passes`, but the bundle cap is fixed
  by the opcode layout.
- **≤ 32 args per `call_wasm_func`** (`wire_schema.repMaxOf(.call_wasm_func)`).
  Unlike the two above, over-cap here is not a silent drop but a **stream
  desync**: the count is one byte, so 33 encodes fine, and every consumer then
  resolves the overflow differently — `skipParams` and the reference dispatcher
  walk 32 args and read the surplus arg bytes as the next opcode. A 40-arg
  `(wasm-call …)` used to compile with exit 0 and crash `pngine inspect`. The
  emitter now rejects over-cap at the declaration; both decoders refuse such a
  stream (`RepCountOverCap` / the `malformed_body` latch) rather than resyncing
  on garbage.

The same reasoning applies to `begin_render_pass_mrt`'s ≤ 8 attachments, which
the emitter cannot exceed (it gathers into a fixed 8-slot array), so only the
decoders enforce it. A rep-group cap is a property of the **wire contract**, not
a per-consumer clamp: see `wire_schema.repMaxOf`.

## 6. Descriptor sub-formats

### 6.1 Binary tagged descriptors (texture, sampler)

```
[type_tag: u8] [field_count: u8] ( [field_id: u8] [value_type: u8] [value] )*
```

Value types (subset consumed by JS): `0x00`=u32 (4 bytes), `0x03`=array (entries
follow, bind-group only), `0x06`=u16 (2 bytes), `0x07`=enum (1 byte).
Unknown field IDs must be skipped by their value-type size — fields are
**append-only**.

Texture (tag 0x01): `0x01` width u32 · `0x02` height u32 · `0x03` depth u32 ·
`0x05` sampleCount u32 · `0x06` dimension enum (0=1d,1=2d,2=3d) · `0x07` format
enum (table below) · `0x08` usage enum (GPUTextureUsage bits) · `0x0A`
size-from-image-bitmap u16 (bitmap id). Omitting width AND height makes the
texture **canvas-bound** (tracks canvas size on resize).

Sampler (tag 0x02): `0x01` addressModeU · `0x02` addressModeV · `0x04`
magFilter · `0x05` minFilter · `0x09` compare — all enums:
filter 0=nearest,1=linear · address 0=clamp-to-edge,1=repeat,2=mirror-repeat ·
compare 0..7 = never,less,equal,less-equal,greater,not-equal,greater-equal,always.

Texture format enum (append-only): 0x00 rgba8unorm · 0x01 rgba8snorm ·
0x02 rgba8uint · 0x03 rgba8sint · 0x04 bgra8unorm · 0x05 rgba16float ·
0x06 rgba32float · 0x10 depth24plus · 0x11 depth24plus-stencil8 ·
0x12 depth32float · 0x20 r32float · 0x21 rg32float · 0x22 r32uint ·
0x30 r8unorm · 0x31 rg8unorm · 0x32 r16float · 0x33 rg16float ·
unknown → preferred canvas format.

### 6.2 Render pipeline descriptor (JSON)

UTF-8 JSON. Fields consumed by gpu.js (all others ignored — additions are
fine, removals/renames are not): `layoutId` (pipeline-layout id; absent/unknown
→ `"auto"`), `vertex.shader` (shader id, default 0), `vertex.entryPoint`
(default `"vs_main"`), `vertex.buffers` (GPUVertexBufferLayout[]), `primitive`
(default triangle-list), `depthStencil`, `multisample`, `fragment.shader`
(falls back to vertex shader), `fragment.entryPoint` (default `"fs_main"`),
`fragment.targets` (formats default to preferred canvas format), and the
**legacy** `fragment.targetFormat` / `"preferredCanvasFormat"` string — frozen,
must parse forever. No `fragment` → depth-only pipeline.

### 6.3 Compute pipeline descriptor (binary)

`[0x06][shader_id:u16][entry_len:u8][entry bytes][layout_id:u16?]` — trailing
layout_id optional; `0xFFFF` or absent → `"auto"`. Empty entry → `"main"`.

### 6.4 Bind group entries (binary tagged)

Tag 0x03; field `0x01` (enum) = group index; field `0x02` (array) =
`[entry_count:u8]` then per entry `[binding:u8][resource_type:u8][resource_id:u16]`
plus, for resource_type 0 only, `[offset:u32][size:u32]`.
Resource types: 0=buffer, 1=texture (view created at bind time), 2=sampler.

**`layout_id`'s two id spaces.** Bit 15 (`0x8000`,
`types/opcodes.zig BIND_GROUP_LAYOUT_TAG`) discriminates them:

| Bit 15 | Low 15 bits are | Authored as | Layout to use |
| --- | --- | --- | --- |
| 0 | a pipeline id | `:layout-pipeline` | `pipeline.getBindGroupLayout(group_index)` |
| 1 | a `create_bind_group_layout` id (0x0A) | `:bind-group-layout` | that layout object |

Both spaces are numbered from 0, so the bit is the *only* thing separating them.
A consumer must resolve in the space the bit names and **must not fall back to
the other one**: WebGPU makes an auto-derived layout exclusive to the pipeline
that derived it, and an explicitly created layout incompatible with any
`layout:"auto"` pipeline, so substituting either for the other yields a bind
group the driver rejects at draw time. If the named id does not resolve, skip
creating the bind group — do not guess.

The tag is *set* only for bind groups that name an explicit layout, so payloads
without one are byte-identical to those emitted before it existed. A payload
that does use one requires a runtime new enough to read the bit: the executor
travels inside the PNG, but `gpu.js` does not, so such a payload loaded by an
npm runtime that predates this change (≤ 2.1.0) resolves the tagged id in the
pipeline space, finds nothing, and loses that bind group. That is the one
backward-compatibility cost of the fix, and it is paid only by documents using
`:bind-group-layout`.

### 6.5 Render bundle descriptor (binary)

`[cf_count:u8][color_formats:u8 × n (0 entries → preferred canvas)]`
`[ds_format:u8 (0xFF=none)][sample_count:u8][pipeline_id:u16]`
`[bg_count:u8][bg_ids:u16 × n][vb_count:u8][vb_ids:u16 × n]`
`[has_ib:u8][ib_id:u16?][draw_type:u8 (1=indexed)]`
then draw args: indexed `[idx:u32][inst:u32][first:u32][base_vtx:i32][first_inst:u32]`,
else `[vtx:u32][inst:u32][first_vtx:u32][first_inst:u32]`.

## 7. Change policy

1. **Opcodes are append-only.** Never renumber, never reuse a value (including
   reserved gaps), never change an existing layout. New data → new opcode or a
   new descriptor field ID.
2. **Descriptor layouts are immutable.** New binary fields get new field IDs
   (readers skip unknown IDs by value-type size). New JSON fields are additive;
   existing fields — including legacy ones — parse forever.
3. **Exports are additive-only**; JS reads new exports via optional chaining.
4. **The host import set may only grow** (§3).
5. **Museum fixtures are append-only** (`tests/npm/fixtures/abi/*`). If a JS
   change breaks a pinned golden, the change is presumed wrong. Overriding
   requires `--force` on the regen script plus a commit message arguing
   semantic equivalence.
6. **PNGB stays v0.** Payload evolution = embedded executor evolution. A
   *frontend-only* table — one parsed by `gpu.js` / native / `js_codegen` but
   NEVER by the shipping wasm executor (the uniform table is the original
   precedent) — may still grow the payload without touching the ABI, provided:
   (a) it uses the header's spare capacity in place — a free `flags` bit + the
   `reserved [3]u8` (a u24 offset), never a repacked or moved field (the 40-byte
   header is frozen); (b) **empty ⟹ absent**: an empty table serializes to ZERO
   bytes with the flag clear and `reserved` `{0,0,0}`, so every payload that
   doesn't use the feature stays byte-for-byte identical (museum + goldens hold
   by construction); (c) the shipping executor stays blind to it (pinned by a
   corpus survival case). The device-limits table
   (`has_device_limits` = flags bit 2, `reserved` @9–11 = u24 LE offset, table
   appended after the animation table) is the worked example — zero executor
   bytes, zero museum churn, PNGB still v0.
7. New executors may only emit opcodes/descriptors the *already-shipped* JS
   understands; ship the JS first (see the unknown-opcode rule in §5).
8. **The command stream is create-only, and stays that way.** There are 13
   create opcodes and no destroy/release/free of any kind. This is a decision,
   not a gap: resource lifetime is scoped to the DEVICE, and the release
   mechanism is whole-device teardown (`gpu.destroy()` + `device.destroy()`, or
   the payload reload that replaces the dispatcher outright). A payload cannot
   free an individual resource because a payload is *data* — it describes what
   exists, not a sequence of allocations to be balanced.

   The consequences are load-bearing rather than theoretical, so both are
   gated. A `create_*` opcode reaching bytecode the runtime REPLAYS — past the
   first `define_frame`, or inside a `define_pass` body — emits a create
   command every frame forever with nothing to balance it; nothing in
   `wasm_entry.zig` prevents that, so `tests/zig/sjon_golden.zig` scans for it
   and `tests/npm/frame-purity.test.js` asserts the same property through the
   real JS dispatcher. And because JS discipline is the *only* line of defence,
   every create handler carries an id guard.

   Adding a destroy opcode was considered and **rejected**: it would put
   resource lifetime in the payload, where a malformed or hostile stream could
   free a resource still bound by a later command, and it buys nothing the
   device-scoped model does not already give. Revisiting it is an ABI event
   under clause 1, not an implementation detail.
9. **`exec_pass_once` means once per loaded payload, per pass id.** An
   `(init …)` step lowers to this opcode, so it is how every document seeds its
   buffers — spawn particles, fill a heightmap, upload a mesh. The executor
   records which pass ids have run (`pass_executed_once`, cleared by `init()`);
   the reference dispatcher records the same in `Dispatcher.executed_once`.
   Three consequences follow, and hosts may rely on all three:

   - **`setFrameCounter` does not re-arm an init pass.** The counter is the
     ping-pong pool phase and nothing else (§2), so restoring a saved 0 around
     a thumbnail render must not re-seed the scene.
   - **A duplicated `:init` entry runs once in total**, not once per listing.
     The compiler refuses to emit that shape at all — a document
     asking for two runs is rejected rather than given one — but the executor
     still has to uphold it: a payload is bytes from the internet, and nothing
     makes them the compiler's bytes. Two frames sharing an init pass is the
     legal form of the same thing, and runs once in whichever frame renders
     first.
   - **The only re-arm is `init()`** — loading a payload. An editor recompile
     re-seeds; seeking, pausing and stopping do not.

   Earlier shipping executors keyed once-ness off `frame_counter == 0`,
   which satisfied none of the three: a restored counter of 0 re-ran every init
   pass, duplicated entries ran once *each*, and a counter driven forward before
   the first frame skipped them permanently. Changing it was a deliberate
   behaviour change to a frozen export, on three grounds — `frame()`'s
   documented contract never mentioned the counter, `setFrameCounter`'s
   explicitly promised the opposite of what it did, and the two executors
   disagreed about the same payload, which is the one thing this document
   exists to prevent.

## 8. Enforcement map

| Clause | Guard |
| --- | --- |
| Opcode values / header layout / descriptor enums never change at the source | `tests/zig/executor/command_buffer_test.zig` "ABI freeze" tests (rides `zig build test-executor` / `test-standalone`) |
| Export/import surface of shipped binaries never regresses | `tests/npm/abi-surface.test.js` vs `tests/npm/fixtures/abi/*/manifest.json` |
| Current `getExecutorImports()` can instantiate every pinned binary | `abi-surface.test.js` forever-instantiation check |
| Real dispatcher still runs every pinned executor's command stream identically | `tests/npm/abi-museum.test.js` vs `tests/npm/fixtures/abi/*/golden/*.log` |
| New pins are recorded, never mutated | `scripts/gen-abi-fixtures.mjs --gen vN` (refuses to overwrite) |
| No `create_*` opcode reaches replayed bytecode (clause 8) | `tests/zig/sjon_golden.zig` "no fixture creates a GPU resource in replayed bytecode" (bytecode scan) + `tests/npm/frame-purity.test.js` (JS dispatcher call log over the freshly compiled `examples/**` corpus) |
| `exec_pass_once` runs once per `init()`, per pass id (clause 9) | `tests/zig/executor/wasm_entry_once_test.zig` (shipping executor, via the command buffer's `cmd_count`) + `tests/zig/executor/reexecution_test.zig` (reference dispatcher, via the MockGPU call log) |
| `cmd_count`/`total_len` describe the same commands; overflow is reported, never hidden | `tests/zig/executor/command_buffer_test.zig` truncation tests + `tests/zig/executor/wasm_entry_malformed_test.zig` (a frame past the buffer, over both the all-plugins and core-only executor) |
| The executor allocates nothing — no `memory.grow` in any shipped variant | `scripts/check-executor-static.mjs` (rides `zig build drift`) |

There is **no** runtime check that the JS switch covers every opcode an
executor emits. Know what the museum does and does not give you here: generation
v1 pins three payloads (`simple_triangle`, `uniform_access`,
`pass_compute_rainbow`), so it proves *those* streams replay identically
forever — it is a regression net, not an opcode-coverage matrix. Nothing in it
emits `init_wasm_module`/`call_wasm_func`, for instance. Opcode-by-opcode
agreement between the Zig emitter and the JS dispatchers comes from
`tests/npm/command-buffer-widths.test.js` — which drives every command through
the real sub-dispatchers and checks the width each returns against the Zig
emitter — and whole-corpus replay from `frame-purity.test.js`.

When adding an opcode, add it to the JS dispatchers, the Zig freeze test, the
widths test, this document, and pin a new fixture generation exercising it.
