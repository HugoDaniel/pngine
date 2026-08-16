// WASM compiler wrapper
// Compiles PNGine DSL source → PNGB bytecode or self-contained PNG in the browser

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Create a compiler instance from WASM module.
 *
 * @param {string} wasmUrl - URL to pngine-compiler.wasm
 * @returns {Promise<{
 *   compile: (source: string) => {pngb: Uint8Array|null, errors: string|null, diagnostics: Array<any>},
 *   compileToPng: (source: string) => {png: Uint8Array|null, errors: string|null, diagnostics: Array<any>},
 *   minifyWgsl: (wgsl: string) => {minified: string|null, error: string|null},
 * }>}
 */
export async function createCompiler(wasmUrl) {
  const { instance } = await WebAssembly.instantiateStreaming(
    fetch(wasmUrl),
    {
      env: {
        log(ptr, len) { /* compiler log — unused */ },
        // SJON host hook. The freestanding `sjon` expression evaluator declares
        // `env.sjon_host_invoke_plugin` unconditionally (it dispatches
        // `:impl "wasm:<export>"` plugin functions on wasm32). PNGine registers
        // only the `core` arithmetic vocabulary — no executable plugins — so it is
        // never called; this no-op stub (returns null) just satisfies the import
        // so the compiler instantiates. Required for ALL sources (the import is in
        // the module regardless of input format), not only `.sjon`. See CONTRIBUTING §60.
        sjon_host_invoke_plugin() { return 0; },
      },
    }
  );
  const wasm = /** @type {PngineCompilerExports} */ (/** @type {unknown} */ (instance.exports));
  const memory = wasm.memory;

  /** Write source into WASM memory. */
  function writeSource(source) {
    const encoded = encoder.encode(source);
    const srcPtr = wasm.getSourcePtr();
    new Uint8Array(memory.buffer, srcPtr, encoded.length).set(encoded);
    wasm.setSourceLen(encoded.length);
  }

  /** Read error string from WASM memory. */
  function readErrors() {
    const errPtr = wasm.getErrorPtr();
    const errLen = wasm.getErrorLen();
    return decoder.decode(new Uint8Array(memory.buffer, errPtr, errLen));
  }

  /** Read output bytes from WASM memory. */
  function readOutput() {
    const outPtr = wasm.getOutputPtr();
    const outLen = wasm.getOutputLen();
    return new Uint8Array(memory.buffer, outPtr, outLen).slice();
  }

  /** Read structured diagnostics (JSON array) from WASM memory. */
  function readDiagnostics() {
    const ptr = wasm.getDiagPtr();
    const len = wasm.getDiagLen();
    if (len === 0) return [];
    const json = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
    try { return JSON.parse(json); } catch { return []; }
  }

  return {
    /**
     * Compile DSL source to PNGB bytecode.
     * @param {string} source - PNGine DSL source code
     * @returns {{pngb: Uint8Array|null, errors: string|null, diagnostics: Array}}
     */
    compile(source) {
      writeSource(source);
      const result = wasm.compile();
      const diagnostics = readDiagnostics();
      if (result !== 0) return { pngb: null, errors: readErrors(), diagnostics };
      return { pngb: readOutput(), errors: null, diagnostics };
    },

    /**
     * Compile DSL source to self-contained PNG with embedded executor.
     * @param {string} source - PNGine DSL source code
     * @returns {{png: Uint8Array|null, errors: string|null, diagnostics: Array}}
     */
    compileToPng(source) {
      writeSource(source);
      const result = wasm.compileToPng();
      const diagnostics = readDiagnostics();
      if (result !== 0) return { png: null, errors: readErrors(), diagnostics };
      return { png: readOutput(), errors: null, diagnostics };
    },

    /**
     * Minify WGSL source via wgslender.
     * Deterministic: whitespace/comment-only differences collapse to the same output.
     * @param {string} wgsl - WGSL shader source
     * @returns {{minified: string|null, error: string|null}}
     */
    minifyWgsl(wgsl) {
      writeSource(wgsl);
      const result = wasm.minifyWgsl();
      if (result !== 0) return { minified: null, error: readErrors() };
      return { minified: decoder.decode(readOutput()), error: null };
    }
  };
}
