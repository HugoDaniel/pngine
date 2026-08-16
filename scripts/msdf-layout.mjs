#!/usr/bin/env node
// msdf-layout.mjs — build-time text layout for examples/webgpu_text_msdf.sjon
// (docs/plans/wgpu-samples/15-text-rendering-msdf.md).
//
// Ports upstream msdfText.ts's measureText/formatText (kerning, newline/CR/
// space handling, centering) and bakes what its 505-line load-time renderer
// only existed to produce: the glyph table and the per-text-block char
// placement buffers. Regenerates the committed fixture in full — this script
// is the fixture's source of truth. Usage:
//   node scripts/msdf-layout.mjs <ya-hei-ascii-msdf.json> > examples/webgpu_text_msdf.sjon
import { readFileSync } from 'node:fs';

const json = JSON.parse(readFileSync(process.argv[2] ?? new URL('../../llm/repositories/webgpu-samples/public/assets/font/ya-hei-ascii-msdf.json', import.meta.url), 'utf8'));

const { lineHeight, scaleW, scaleH } = json.common;
const u = 1 / scaleW, v = 1 / scaleH;
const charsById = new Map(json.chars.map(c => [c.id, c]));
const defaultChar = charsById.get(63) ?? json.chars[0]; // '?'
const kernings = new Map();
for (const k of json.kernings ?? []) {
  if (!kernings.has(k.first)) kernings.set(k.first, new Map());
  kernings.get(k.first).set(k.second, k.amount);
}
const getChar = code => charsById.get(code) ?? defaultChar;
const xAdvance = (code, next) => {
  const c = getChar(code);
  const kern = next >= 0 ? (kernings.get(code)?.get(next) ?? 0) : 0;
  return c.xadvance + kern;
};

// Upstream measureText, verbatim semantics (incl. the case-10 fallthrough
// into case 13's break).
function measureText(text, charCallback) {
  let maxWidth = 0;
  const lineWidths = [];
  let x = 0, y = 0, line = 0, printed = 0;
  let nextCode = text.charCodeAt(0);
  for (let i = 0; i < text.length; ++i) {
    const code = nextCode;
    nextCode = i < text.length - 1 ? text.charCodeAt(i + 1) : -1;
    switch (code) {
      case 10:
        lineWidths.push(x);
        line++;
        maxWidth = Math.max(maxWidth, x);
        x = 0;
        y -= lineHeight;
      // eslint-disable-next-line no-fallthrough
      case 13:
        break;
      case 32:
        x += xAdvance(code);
        break;
      default:
        charCallback?.(x, y, line, getChar(code));
        x += xAdvance(code, nextCode);
        printed++;
    }
  }
  lineWidths.push(x);
  maxWidth = Math.max(maxWidth, x);
  return { width: maxWidth, height: lineWidths.length * lineHeight, lineWidths, printedCharCount: printed };
}

// Dense glyph-index remap over the chars actually used.
const usedCodes = new Set();
const collect = text => { for (const ch of text) { const c = ch.charCodeAt(0); if (c !== 10 && c !== 13 && c !== 32) usedCodes.add(getChar(c).id); } };

const BODY = `
WebGPU exposes an API for performing operations, such as rendering
and computation, on a Graphics Processing Unit.

Graphics Processing Units, or GPUs for short, have been essential
in enabling rich rendering and computational applications in personal
computing. WebGPU is an API that exposes the capabilities of GPU
hardware for the Web. The API is designed from the ground up to
efficiently map to (post-2014) native GPU APIs. WebGPU is not related
to WebGL and does not explicitly target OpenGL ES.

WebGPU sees physical GPU hardware as GPUAdapters. It provides a
connection to an adapter via GPUDevice, which manages resources, and
the device’s GPUQueues, which execute commands. GPUDevice may have
its own memory with high-speed access to the processing units.
GPUBuffer and GPUTexture are the physical resources backed by GPU
memory. GPUCommandBuffer and GPURenderBundle are containers for
user-recorded commands. GPUShaderModule contains shader code. The
other resources, such as GPUSampler or GPUBindGroup, configure the
way physical resources are used by the GPU.

GPUs execute commands encoded in GPUCommandBuffers by feeding data
through a pipeline, which is a mix of fixed-function and programmable
stages. Programmable stages execute shaders, which are special
programs designed to run on GPU hardware. Most of the state of a
pipeline is defined by a GPURenderPipeline or a GPUComputePipeline
object. The state not included in these pipeline objects is set
during encoding with commands, such as beginRenderPass() or
setBlendConstant().`;

// (text, centered, pixelScale, color, mode, baseTransform)
// mode 0 = rides the cube model matrix; mode 1 = rides the crawl matrix.
const rotY = a => [Math.cos(a),0,-Math.sin(a),0, 0,1,0,0, Math.sin(a),0,Math.cos(a),0, 0,0,0,1];
const rotX = a => [1,0,0,0, 0,Math.cos(a),Math.sin(a),0, 0,-Math.sin(a),Math.cos(a),0, 0,0,0,1];
const translate = (x,y,z) => [1,0,0,0, 0,1,0,0, 0,0,1,0, x,y,z,1];
const mul = (a,b) => { // column-major a*b
  const r = new Array(16).fill(0);
  for (let c2 = 0; c2 < 4; c2++) for (let r2 = 0; r2 < 4; r2++)
    for (let k = 0; k < 4; k++) r[c2*4+r2] += a[k*4+r2]*b[c2*4+k];
  return r;
};
const face = (pos, rot) => {
  let m = translate(...pos);
  if (rot?.[0]) m = mul(m, rotX(rot[0]));
  if (rot?.[1]) m = mul(m, rotY(rot[1]));
  return m;
};
const I = translate(0,0,0);

const blocks = [
  { name: 'front',  text: 'Front',  centered: true, scale: 1/128, color: [1,0,0,1], mode: 0, base: face([0,0,1.1]) },
  { name: 'back',   text: 'Back',   centered: true, scale: 1/128, color: [0,1,1,1], mode: 0, base: face([0,0,-1.1],[0,Math.PI,0]) },
  { name: 'right',  text: 'Right',  centered: true, scale: 1/128, color: [0,1,0,1], mode: 0, base: face([1.1,0,0],[0,Math.PI/2,0]) },
  { name: 'left',   text: 'Left',   centered: true, scale: 1/128, color: [1,0,1,1], mode: 0, base: face([-1.1,0,0],[0,-Math.PI/2,0]) },
  { name: 'top',    text: 'Top',    centered: true, scale: 1/128, color: [0,0,1,1], mode: 0, base: face([0,1.1,0],[-Math.PI/2,0,0]) },
  { name: 'bottom', text: 'Bottom', centered: true, scale: 1/128, color: [1,1,0,1], mode: 0, base: face([0,-1.1,0],[Math.PI/2,0,0]) },
  { name: 'title',  text: 'WebGPU', centered: true, scale: 1/128, color: [1,1,1,1], mode: 1, base: I },
  { name: 'body',   text: BODY,     centered: false, scale: 1/256, color: [1,1,1,1], mode: 1, base: translate(-3,-0.1,0) },
];

for (const b of blocks) collect(b.text);
const used = [...usedCodes].sort((a,b)=>a-b);
const dense = new Map(used.map((id,i)=>[id,i]));

const fmt = n => {
  if (Number.isInteger(n) && Math.abs(n) < 1e7) return String(n);
  return Number(n.toFixed(7)).toString();
};

const glyphFloats = [];
for (const id of used) {
  const c = charsById.get(id);
  glyphFloats.push(c.x*u, c.y*v, c.width*u, c.height*v, c.width, c.height, c.xoffset, -c.yoffset);
}

function layoutBlock(b) {
  const arr = [];
  let m;
  if (b.centered) {
    m = measureText(b.text);
    measureText(b.text, (x, y, line, ch) => {
      const lineOffset = m.width * -0.5 - (m.width - m.lineWidths[line]) * -0.5;
      arr.push(x + lineOffset, y + m.height * 0.5, dense.get(ch.id), 0);
    });
  } else {
    m = measureText(b.text, (x, y, line, ch) => {
      arr.push(x, y, dense.get(ch.id), 0);
    });
  }
  return { floats: [...b.base, ...b.color, b.scale, b.mode, 0, 0, ...arr], count: m.printedCharCount };
}

const laid = blocks.map(b => ({ ...b, ...layoutBlock(b) }));

const wrap = (floats, indent = '  ') => {
  const lines = [];
  for (let i = 0; i < floats.length; i += 8)
    lines.push(indent + floats.slice(i, i+8).map(fmt).join(' '));
  return lines.join('\n');
};

const dataForms = laid.map(b =>
  `(data :name ${b.name}Data :float32 [\n${wrap(b.floats)}\n])`).join('\n');
const bufForms = laid.map(b =>
  `(buffer :name ${b.name}Buf :size ${b.name}Data :usage [storage] :mapped-at-creation ${b.name}Data)`).join('\n');
const bgForms = laid.map(b =>
  `(bind-group :name ${b.name}Group :layout-pipeline textPipe :layout-index 1\n  (entry :binding 0 :buffer inputs)\n  (entry :binding 1 :buffer ${b.name}Buf))`).join('\n');
const bundleForms = laid.map(b =>
  `(render-bundle :name ${b.name}Bundle\n  :pipeline textPipe\n  :depth-stencil-format depth24plus\n  :bind-groups [fontGroup ${b.name}Group]\n  :draw 4 :instance-count ${b.count})`).join('\n');
const bundleList = laid.map(b => `${b.name}Bundle`).join(' ');

const fixture = `; MSDF text rendering — port of the webgpu-samples \`textRenderingMsdf\` sample.
; Generated by scripts/msdf-layout.mjs; edit the script, not this file.
;
; Six coloured face labels ride a rotating cube, and a Star-Wars-style crawl
; (title + ~1000-character body) tilts back and scrolls on a 14-unit loop.
; Upstream lays the text out at load time (JSON parse, kerning, line breaking,
; centering) only to fill static storage buffers; here the script bakes those
; buffers at build time. Each text block is one render bundle with one
; instanced draw (4 vertices × printed-char count) over a triangle-strip quad.
; The animated part of every transform is computed in WGSL from
; pngine-inputs.time and selected by a mode float in each block's header
; (0 = cube face, 1 = crawl); the static base transform is baked per block.
; The MSDF fragment shader is upstream's median-of-RGB with dpdx/dpdy AA.
;
; The payload is dominated by the ~107 KB font-atlas PNG. The native \`--frame\`
; renderer treats the atlas upload and render-bundle replay as no-ops, so a
; CLI-rendered frame shows only the cube; the text needs the browser.

(data :name fontAtlas :blob "assets/ya-hei-ascii.png" :mime "image/png")
(image-bitmap :name fontImg :image fontAtlas)

(texture :name fontTex :size-from fontImg :format rgba8unorm
  :usage [texture-binding copy-dst render-attachment])
(texture :name depthTex :size canvas :format depth24plus :usage [render-attachment])
(sampler :name fontSamp :mag-filter linear :min-filter linear
  :mipmap-filter linear :max-anisotropy 16)

; Glyph table: 8 f32 per used glyph (texOffset.xy, texExtent.xy, size.xy,
; offset.x, -offset.y) — upstream's charsArray packing, remapped densely to
; the ${used.length} characters the text uses.
(data :name glyphTable :float32 [
${wrap(glyphFloats)}
])
(buffer :name glyphBuf :size glyphTable :usage [storage] :mapped-at-creation glyphTable)

; Per-block data: 24-f32 header (base transform mat4, color vec4, scale,
; mode, 2 pad) then 4 f32 per printed char (x, y, glyphIndex, 0).
${dataForms}

${bufForms}

(buffer :name inputs :size 16 :usage [uniform copy-dst])
(data :name cubeVerts (cube :format [position4 color4 uv2]))
(buffer :name cubeVB :size cubeVerts :usage [vertex] :mapped-at-creation cubeVerts)

(queue :name copyAtlas
  (copy-external-image-to-texture :source fontImg :texture fontTex))
(queue :name writeInputs
  (write-buffer :buffer inputs :offset 0 :data pngine-inputs))

(shader-module :name textCode :code """
struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }

struct Char {
  texOffset : vec2f,
  texExtent : vec2f,
  size : vec2f,
  offset : vec2f,
}

struct FormattedText {
  transform : mat4x4f,
  color : vec4f,
  scale : f32,
  mode : f32,
  chars : array<vec3f>,
}

@group(0) @binding(0) var fontTexture : texture_2d<f32>;
@group(0) @binding(1) var fontSampler : sampler;
@group(0) @binding(2) var<storage> chars : array<Char>;

@group(1) @binding(0) var<uniform> inputs : PngineInputs;
@group(1) @binding(1) var<storage> text : FormattedText;

var<private> quadPos : array<vec2f, 4> = array<vec2f, 4>(
  vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(0.0, 0.0), vec2f(1.0, 0.0));

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) -> mat4x4f {
  let f = 1.0 / tan(fovy * 0.5);
  let nf = 1.0 / (near - far);
  return mat4x4f(
    vec4f(f / aspect, 0, 0, 0),
    vec4f(0, f, 0, 0),
    vec4f(0, 0, far * nf, -1),
    vec4f(0, 0, far * near * nf, 0));
}

// Upstream cube model: translate(0,2,-3) * rotate(axis(sin t, cos t, 0), 1).
fn cubeModel(now: f32) -> mat4x4f {
  let axis = normalize(vec3f(sin(now), cos(now), 0.0));
  let c = cos(1.0);
  let s = sin(1.0);
  let t = 1.0 - c;
  let x = axis.x;
  let y = axis.y;
  let rot = mat4x4f(
    vec4f(t*x*x+c,  t*x*y,    s*y, 0),
    vec4f(t*x*y,    t*y*y+c, -s*x, 0),
    vec4f(-s*y,     s*x,      c,   0),
    vec4f(0, 0, 0, 1));
  let place = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, 1, 0, 0),
    vec4f(0, 0, 1, 0),
    vec4f(0, 2, -3, 1));
  return place * rot;
}

// Upstream crawl: rotX(-pi/8) * translate(0, (t/2.5 mod 14) - 3, 0).
fn crawlMatrix(t: f32) -> mat4x4f {
  let a = -0.39269908;
  let ca = cos(a);
  let sa = sin(a);
  let rx = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, ca, sa, 0),
    vec4f(0, -sa, ca, 0),
    vec4f(0, 0, 0, 1));
  let crawl = (t / 2.5) % 14.0;
  let tr = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, 1, 0, 0),
    vec4f(0, 0, 1, 0),
    vec4f(0, crawl - 3.0, 0, 1));
  return rx * tr;
}

struct VertexOutput {
  @builtin(position) position : vec4f,
  @location(0) texcoord : vec2f,
}

@vertex
fn vertexMain(@builtin(vertex_index) vertex : u32,
              @builtin(instance_index) instance : u32) -> VertexOutput {
  let textElement = text.chars[instance];
  let ch = chars[u32(textElement.z)];
  let charPos = (quadPos[vertex] * ch.size + textElement.xy + ch.offset) * text.scale;

  var pre : mat4x4f;
  if (text.mode < 0.5) {
    pre = cubeModel(inputs.time * 0.2);
  } else {
    pre = crawlMatrix(inputs.time);
  }
  let view = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, 1, 0, 0),
    vec4f(0, 0, 1, 0),
    vec4f(0, 0, -5, 1));
  let proj = perspective(1.2566, inputs.aspect, 1.0, 100.0);

  var output : VertexOutput;
  output.position = proj * view * pre * text.transform * vec4f(charPos, 0.0, 1.0);
  output.texcoord = quadPos[vertex] * vec2f(1.0, -1.0);
  output.texcoord *= ch.texExtent;
  output.texcoord += ch.texOffset;
  return output;
}

fn sampleMsdf(texcoord: vec2f) -> f32 {
  let c = textureSample(fontTexture, fontSampler, texcoord);
  return max(min(c.r, c.g), min(max(c.r, c.g), c.b));
}

// Antialiasing technique from Paul Houx (msdfgen issue 22).
@fragment
fn fragmentMain(input : VertexOutput) -> @location(0) vec4f {
  let pxRange = 4.0;
  let sz = vec2f(textureDimensions(fontTexture, 0));
  let dx = sz.x * length(vec2f(dpdx(input.texcoord.x), dpdy(input.texcoord.x)));
  let dy = sz.y * length(vec2f(dpdx(input.texcoord.y), dpdy(input.texcoord.y)));
  let toPixels = pxRange * inverseSqrt(dx * dx + dy * dy);
  let sigDist = sampleMsdf(input.texcoord) - 0.5;
  let pxDist = sigDist * toPixels;
  let edgeWidth = 0.5;
  let alpha = smoothstep(-edgeWidth, edgeWidth, pxDist);
  if (alpha < 0.001) {
    discard;
  }
  return vec4f(text.color.rgb, text.color.a * alpha);
}
""")

(shader-module :name cubeCode :code """
struct PngineInputs { time: f32, width: f32, height: f32, aspect: f32 }
@group(0) @binding(0) var<uniform> inputs : PngineInputs;

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) -> mat4x4f {
  let f = 1.0 / tan(fovy * 0.5);
  let nf = 1.0 / (near - far);
  return mat4x4f(
    vec4f(f / aspect, 0, 0, 0),
    vec4f(0, f, 0, 0),
    vec4f(0, 0, far * nf, -1),
    vec4f(0, 0, far * near * nf, 0));
}

fn getMVP() -> mat4x4f {
  let now = inputs.time * 0.2;
  let axis = normalize(vec3f(sin(now), cos(now), 0.0));
  let c = cos(1.0);
  let s = sin(1.0);
  let t = 1.0 - c;
  let x = axis.x;
  let y = axis.y;
  let rot = mat4x4f(
    vec4f(t*x*x+c,  t*x*y,    s*y, 0),
    vec4f(t*x*y,    t*y*y+c, -s*x, 0),
    vec4f(-s*y,     s*x,      c,   0),
    vec4f(0, 0, 0, 1));
  let model = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, 1, 0, 0),
    vec4f(0, 0, 1, 0),
    vec4f(0, 2, -3, 1));
  let view = mat4x4f(
    vec4f(1, 0, 0, 0),
    vec4f(0, 1, 0, 0),
    vec4f(0, 0, 1, 0),
    vec4f(0, 0, -5, 1));
  return perspective(1.2566, inputs.aspect, 1.0, 100.0) * view * model * rot;
}

struct VertexOutput {
  @builtin(position) Position : vec4f,
  @location(0) fragPosition : vec4f,
}

@vertex
fn vertexMain(@location(0) position : vec4f,
              @location(1) color : vec4f,
              @location(2) uv : vec2f) -> VertexOutput {
  var output : VertexOutput;
  output.Position = getMVP() * position;
  output.fragPosition = 0.5 * (position + vec4f(1.0));
  return output;
}

@fragment
fn fragMain(@location(0) fragPosition : vec4f) -> @location(0) vec4f {
  return fragPosition;
}
""")

(render-pipeline :name cubePipe
  (layout auto)
  (vertex (module cubeCode) (entry vertexMain)
    (buffers
      (vertex-buffer :array-stride 40
        (attribute :shader-location 0 :offset 0 :format float32x4)
        (attribute :shader-location 1 :offset 16 :format float32x4)
        (attribute :shader-location 2 :offset 32 :format float32x2))))
  (fragment (module cubeCode) (entry fragMain)
    (targets (target :format preferred-canvas-format)))
  (primitive (topology triangle-list) :cull-mode back)
  (depth-stencil :format depth24plus :depth-write-enabled true :depth-compare less))

(render-pipeline :name textPipe
  (layout auto)
  (vertex (module textCode) (entry vertexMain))
  (fragment (module textCode) (entry fragmentMain)
    (targets (target :format preferred-canvas-format
      (blend (color :src-factor src-alpha :dst-factor one-minus-src-alpha :operation add)
             (alpha :src-factor one :dst-factor one :operation add)))))
  (primitive (topology triangle-strip))
  (depth-stencil :format depth24plus :depth-write-enabled false :depth-compare less))

(bind-group :name fontGroup :layout-pipeline textPipe :layout-index 0
  (entry :binding 0 :texture fontTex)
  (entry :binding 1 :sampler fontSamp)
  (entry :binding 2 :buffer glyphBuf))

${bgForms}

(bind-group :name cubeGroup :layout-pipeline cubePipe :layout-index 0
  (entry :binding 0 :buffer inputs))

${bundleForms}

(render-pass :name drawCube
  (color-attachment :view context-current-texture
    :clear-value [0 0 0 1] :load-op clear :store-op store)
  (depth-attachment :view depthTex :depth-clear-value 1.0
    :depth-load-op clear :depth-store-op store)
  :pipeline cubePipe :bind-groups [cubeGroup] :vertex-buffers [cubeVB]
  (draw :vertex-count 36))

(render-pass :name drawText
  (color-attachment :view context-current-texture :load-op load :store-op store)
  (depth-attachment :view depthTex :depth-load-op load :depth-store-op store)
  :execute-bundles [${bundleList}])

(frame :name main :perform [copyAtlas writeInputs drawCube drawText])
`;
process.stdout.write(fixture);
console.error(`glyphs used: ${used.length}; blocks: ${laid.map(b=>`${b.name}=${b.count}`).join(' ')}`);
