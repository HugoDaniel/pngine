// PNGine - Public API
// Tree-shakeable exports

export { pngine, destroy } from "./_init.js";
export { draw, play, pause, stop, seek, setFrame } from "./_anim.js";
export { extractBytecode, detectFormat, isPng, isZip, isPngb } from "./_extract.js";
