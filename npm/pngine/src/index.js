// PNGine - Public API
// Tree-shakeable exports

export { pngine, destroy } from "./init.js";
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms } from "./anim.js";
export { extractBytecode, detectFormat, isPng, isZip, isPngb } from "./extract.js";

// Embedded executor support (advanced)
export { parsePayload, createExecutor, getExecutorImports, getExecutorVariantName } from "./loader.js";
