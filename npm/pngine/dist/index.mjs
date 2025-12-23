
export function isPng(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  const s = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  return b.length >= 8 && s.every((v, i) => b[i] === v);
}
export function isZip(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4B;
}
export function isPngb(d) {
  const b = d instanceof Uint8Array ? d : new Uint8Array(d);
  return b.length >= 4 && b[0] === 0x50 && b[1] === 0x4E && b[2] === 0x47 && b[3] === 0x42;
}
export function detectFormat(d) {
  if (isZip(d)) return 'zip';
  if (isPng(d)) return 'png';
  if (isPngb(d)) return 'pngb';
  return null;
}
const browserOnly = () => { throw new Error('PNGine requires browser with WebGPU'); };
export const pngine = browserOnly, destroy = browserOnly, draw = browserOnly;
export const play = browserOnly, pause = browserOnly, stop = browserOnly;
export const seek = browserOnly, setFrame = browserOnly, extractBytecode = browserOnly;
