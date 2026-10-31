// PNGine Dev API (full-feature profile)

export { pngine, destroy } from "./init.js";
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms, writeBuffer, setPointer, getBuffers, getStats, restart, restartSettled } from "./anim.js";
export { extractBytecode, detectFormat, isPng, isZip, isPngb } from "./extract.js";
export { parsePayload, createExecutor, getExecutorImports, getExecutorVariantName } from "./loader.js";
// The payload walker (02.C2): re-exported here so the types gate pins its
// declaration in the published d.ts.
export { payloadsOf } from "./payloads.js";
