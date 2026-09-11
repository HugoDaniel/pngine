// WASM compiler wrapper
// Compiles PNGine DSL source → PNGB bytecode or self-contained PNG in the browser

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/**
 * Create a compiler instance from WASM module.
 *
 * ## Files
 *
 * A `.sjon` document can name files: a texture behind `(data :file …)`, a WASM
 * data generator, a WGSL fragment. The browser has no filesystem, so the host
 * supplies the bytes: pass `{ files }`, a `Map<string, Uint8Array>` keyed by the
 * path as the document writes it (leading `./` optional — the compiler
 * normalises both sides).
 *
 * You do not have to know which files a document names. Compile once and read
 * `needs`: it lists EVERY path the compiler could not resolve, complete after
 * one compile. `compileWithLoader` does that round for you.
 *
 * @param {string} wasmUrl - URL to pngine-compiler.wasm
 * @returns {Promise<{
 *   compile: (source: string, opts?: {files?: Map<string, Uint8Array>}) => {pngb: Uint8Array|null, errors: string|null, diagnostics: Array<any>, needs: string[]},
 *   compileToPng: (source: string, opts?: {files?: Map<string, Uint8Array>}) => {png: Uint8Array|null, errors: string|null, diagnostics: Array<any>, needs: string[]},
 *   compileWithLoader: (source: string, load: (path: string) => Promise<Uint8Array>, opts?: {toPng?: boolean, files?: Map<string, Uint8Array>}) => Promise<{pngb?: Uint8Array|null, png?: Uint8Array|null, errors: string|null, diagnostics: Array<any>, needs: string[]}>,
 *   minifyWgsl: (wgsl: string) => {minified: string|null, error: string|null},
 *   heapBytes: () => number,
 * }>}
 */
/**
 * How many `needs` rounds `compileWithLoader` will run before giving up.
 *
 * Matches `MAX_DOCUMENTS` in `src/dsl_sjon/document_import.zig`: one round
 * resolves one import level, and a composition that pulls in more documents
 * than that is refused by the compiler before this bound is ever reached.
 */
const MAX_IMPORT_ROUNDS = 64;

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

  /**
   * Pack `files` into the compiler's file table.
   *
   * Wire format, little-endian: `[u32 count]([u32 nameLen][name][u32 dataLen][data])*`.
   * One buffer rather than one call per file, because a call per file is a
   * round-trip per file and the whole point of `needs` is that there is one
   * round.
   *
   * @param {Map<string, Uint8Array>|undefined} files
   */
  function writeFileTable(files) {
    if (!files || files.size === 0) {
      // Clearing matters: the table is owned by the WASM module and survives
      // until the next alloc, so a compile after a compile-with-files would
      // otherwise still see the old bytes.
      wasm.setFileTableLen(0);
      return;
    }
    const names = [];
    let total = 4;
    for (const [name, bytes] of files) {
      const n = encoder.encode(name);
      names.push([n, bytes]);
      total += 4 + n.length + 4 + bytes.length;
    }
    const ptr = wasm.allocFileTable(total);
    if (!ptr) throw new Error(`pngine: could not allocate a ${total} byte file table`);
    const view = new DataView(memory.buffer, ptr, total);
    const bytesView = new Uint8Array(memory.buffer, ptr, total);
    let off = 0;
    view.setUint32(off, names.length, true);
    off += 4;
    for (const [name, data] of names) {
      view.setUint32(off, name.length, true);
      off += 4;
      bytesView.set(name, off);
      off += name.length;
      view.setUint32(off, data.length, true);
      off += 4;
      bytesView.set(data, off);
      off += data.length;
    }
    wasm.setFileTableLen(total);
  }

  /**
   * Read the paths the last compile could not resolve.
   * Throws when the list was truncated, because a truncated list read as
   * complete sends the host back with the wrong set of files.
   */
  function readNeeds() {
    const dropped = wasm.getNeedsDropped();
    const len = wasm.getNeedsLen();
    const json = len === 0 ? "[]" : decoder.decode(new Uint8Array(memory.buffer, wasm.getNeedsPtr(), len));
    let paths;
    try { paths = JSON.parse(json); } catch { paths = []; }
    if (dropped > 0) {
      throw new Error(`pngine: this document names more files than the compiler can report (${paths.length} listed, ${dropped} dropped)`);
    }
    return paths;
  }

  /** Read structured diagnostics (JSON array) from WASM memory. */
  function readDiagnostics() {
    const ptr = wasm.getDiagPtr();
    const len = wasm.getDiagLen();
    if (len === 0) return [];
    const json = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
    try { return JSON.parse(json); } catch { return []; }
  }

  /**
   * Compile DSL source to PNGB bytecode.
   *
   * Hoisted out of the returned object rather than written as a method, so
   * `compileWithLoader` can call it by name. Reaching it through `this` needs
   * `this` to be the object, and the object is the resolved value of an `async`
   * factory — so TypeScript types `this` as the PROMISE and rejects every
   * property on it (TS2339, and the JSDoc gate was failing on exactly that).
   *
   * @param {string} source - PNGine DSL source code
   * @param {{files?: Map<string, Uint8Array>}} [opts] - files the document names
   * @returns {{pngb: Uint8Array|null, errors: string|null, diagnostics: Array, needs: string[]}}
   */
  function compile(source, opts = {}) {
    writeFileTable(opts.files);
    writeSource(source);
    const result = wasm.compile();
    const diagnostics = readDiagnostics();
    const needs = readNeeds();
    if (result !== 0) return { pngb: null, errors: readErrors(), diagnostics, needs };
    return { pngb: readOutput(), errors: null, diagnostics, needs };
  }

  /**
   * Compile DSL source to self-contained PNG with embedded executor.
   * @param {string} source - PNGine DSL source code
   * @param {{files?: Map<string, Uint8Array>}} [opts] - files the document names
   * @returns {{png: Uint8Array|null, errors: string|null, diagnostics: Array, needs: string[]}}
   */
  function compileToPng(source, opts = {}) {
    writeFileTable(opts.files);
    writeSource(source);
    const result = wasm.compileToPng();
    const diagnostics = readDiagnostics();
    const needs = readNeeds();
    if (result !== 0) return { png: null, errors: readErrors(), diagnostics, needs };
    return { png: readOutput(), errors: null, diagnostics, needs };
  }

  return {
    compile,
    compileToPng,

    /**
     * Compile, fetching whatever files the document names.
     *
     * ONE ROUND PER IMPORT LEVEL. It used to be one round, permanently, and
     * that was true while every path a document could name belonged to
     * something that names nothing itself — a `.wgsl` fragment, a `.png`
     * texture. `(import …)` broke it: an imported DOCUMENT has imports of its
     * own, and they cannot be known until its bytes are in hand and parsed. A
     * two-level chain therefore reports its second level only after the first
     * has been supplied, and the old code threw on exactly that.
     *
     * `needs` carries only paths that FAILED to read, so a file already
     * supplied never comes back — which makes "nothing fresh this round" the
     * honest end of the line, and keeps the original guarantee: a document that
     * names something genuinely unavailable throws rather than looping.
     *
     * @param {string} source
     * @param {(path: string) => Promise<Uint8Array>} load
     * @param {{toPng?: boolean, files?: Map<string, Uint8Array>}} [opts]
     */
    async compileWithLoader(source, load, opts = {}) {
      const run = opts.toPng ? compileToPng : compile;
      const files = new Map(opts.files ?? []);

      // Bounded, like every loop in this project. A composition holds at most
      // MAX_DOCUMENTS (64, src/dsl_sjon/document_import.zig) and each round
      // resolves at least one more of them, so a chain cannot outlast the
      // bound without the compiler having refused it first.
      for (let round = 0; round < MAX_IMPORT_ROUNDS; round++) {
        const out = run(source, { files });
        if (out.needs.length === 0) return out;

        const fresh = out.needs.filter((path) => !files.has(path));
        if (fresh.length === 0) {
          throw new Error(`pngine: still missing after loading: ${out.needs.join(", ")}`);
        }
        for (const path of fresh) files.set(path, await load(path));
      }
      throw new Error(`pngine: import chain deeper than ${MAX_IMPORT_ROUNDS} levels`);
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
    },

    /**
     * Size of the compiler's WASM linear memory, in bytes.
     *
     * The compiler's counterpart to `getStats().wasmBytes` on the runtime side.
     * `src/wasm_compiler.zig` states an invariant — "All intermediate
     * allocations freed after each compilation" — and this is how a host
     * WATCHES it: an editor compiles per keystroke into a linear memory that
     * never shrinks, so a per-compile allocation that outlives its call shows
     * up here and nowhere else, as a number that keeps climbing.
     *
     * What to expect. It rises over the first few compiles (the allocator
     * grows the heap to the working set, and the 83 KB schema manifest is
     * preloaded once and kept for the module's lifetime — deliberately, see
     * `schema_cache`), then goes FLAT and stays flat, however many compiles
     * follow. A slow climb across many compiles of the SAME source is the
     * failure: not "the heap is large", but "the heap keeps growing".
     *
     * Compiling a bigger document than any before legitimately raises it —
     * compare like with like, which is what `tests/npm/wasm-compiler-heap.test.js`
     * does.
     *
     * @returns {number} bytes of linear memory the module currently holds
     */
    heapBytes() {
      return memory.buffer.byteLength;
    }
  };
}
