// The WASM export surfaces `src/` calls, declared once.
//
// TypeScript types `WebAssembly.Instance.exports` as Record<string, ExportValue>
// — a union of Function | Global | Memory | Table — so every real call site
// ("not callable", "no property .value", "no property .buffer") is an error
// until the surface is named. These interfaces name them.
//
// They are DOCUMENTATION, not enforcement: nothing checks them against the Zig
// side, and TS could not do so. The Zig↔JS numeric ABI is `npm run test:abi`'s
// job — it drives pinned executor binaries through the real dispatcher. What
// these buy is that a typo in an export name, or a call site drifting from the
// shape the rest of the file assumes, becomes a type error instead of an
// undefined at runtime.

/** The `pngine-compiler.wasm` surface (see src/wasm.zig entry points). */
interface PngineCompilerExports {
  memory: WebAssembly.Memory;
  /** Pointer to the source-input staging buffer. */
  getSourcePtr(): number;
  /** Declare how many bytes of source were written at getSourcePtr(). */
  setSourceLen(len: number): void;
  getErrorPtr(): number;
  getErrorLen(): number;
  getOutputPtr(): number;
  getOutputLen(): number;
  /** Structured diagnostics, as a JSON array. */
  getDiagPtr(): number;
  getDiagLen(): number;
  /** Each returns 0 on success, non-zero with getErrorPtr/Len set. */
  compile(): number;
  compileToPng(): number;
  minifyWgsl(): number;
}

/**
 * The executor WASM surface (docs/abi.md, frozen at v1).
 *
 * Every method is OPTIONAL, which is the ABI-evolution contract rather than
 * laziness: loader.js reaches each one through `?.` because a PNG embeds the
 * executor that built it, so a payload pinned years ago is still expected to
 * run against today's host. getAbiVersion() is itself absent on v1 binaries —
 * hence `?.() ?? 1`. The museum fixtures in tests/npm/fixtures/abi keep that
 * promise honest; these declarations only stop a typo becoming an undefined.
 */
interface PngineExecutorExports {
  memory: WebAssembly.Memory;
  getAbiVersion?(): number;
  getBytecodePtr?(): number;
  setBytecodeLen?(len: number): void;
  getDataPtr?(): number;
  setDataLen?(len: number): void;
  init?(): void;
  frame?(time: number, width: number, height: number): void;
  getCommandPtr?(): number;
  getCommandLen?(): number;
}

/**
 * The sointu module embedded in a pNGa chunk. Single-letter exports are
 * sointu's own convention, not minification: the whole song is rendered during
 * instantiation, and these describe where the samples landed.
 */
interface SointuExports {
  /** Memory holding the rendered samples. */
  m: WebAssembly.Memory;
  /** Byte offset of the sample buffer. */
  s: WebAssembly.Global;
  /** Sample buffer length in bytes. */
  l: WebAssembly.Global;
  /** Sample format: 1 = interleaved int16, otherwise float32. */
  t: WebAssembly.Global;
}
