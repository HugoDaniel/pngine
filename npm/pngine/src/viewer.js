// PNGine Viewer API (lean production profile)

export { pngine, destroy } from "./viewer-init.js";
export { draw, play, pause, stop, seek, setFrame, setUniform, setUniforms, getUniforms, writeBuffer, setPointer, getBuffers, getStats, restart, restartSettled } from "./anim.js";
export { extractBytecode, detectFormat, isPng, isZip, isPngb } from "./extract.js";
// The payload walker (02.C2): re-exported here so the types gate pins its
// declaration in the published d.ts (index.js's explicit payloadsOf export
// shadows its star re-export of this file).
export { payloadsOf } from "./payloads.js";
