
/**
 * PNGine - Node.js entry
 *
 * Note: PNGine requires a browser with WebGPU support.
 * Use the CLI for compilation: npx pngine compile input.pngine -o output.pngb
 */

const PNG_SIG = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

function isPng(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 8 && PNG_SIG.every((v, i) => b[i] === v);
}

function isZip(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4B;
}

function isPngb(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4E && b[2] === 0x47 && b[3] === 0x42;
}

function detectFormat(d) {
  if (isZip(d)) return 'zip';
  if (isPng(d)) return 'png';
  if (isPngb(d)) return 'pngb';
  return null;
}

const browserOnly = () => { throw new Error('PNGine requires browser with WebGPU'); };

module.exports = {
  pngine: browserOnly, destroy: browserOnly, draw: browserOnly,
  play: browserOnly, pause: browserOnly, stop: browserOnly,
  seek: browserOnly, setFrame: browserOnly, setUniform: browserOnly,
  setUniforms: browserOnly, extractBytecode: browserOnly,
  isPng, isZip, isPngb, detectFormat,
};
