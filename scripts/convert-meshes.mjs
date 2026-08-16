#!/usr/bin/env node
// Convert WebGPU samples mesh data to compact binary .bin files for @embedFile.
//
// Binary format per .bin:
//   Header (12 bytes):
//     u32 vertex_count
//     u32 triangle_count
//     u32 index_size (2 = u16, 4 = u32)
//   Positions (vertex_count * 3 * 4 bytes): f32[3] per vertex, little-endian
//   Normals   (vertex_count * 3 * 4 bytes): f32[3] per vertex, little-endian
//   Indices   (triangle_count * 3 * index_size bytes)
//
// Usage: node scripts/convert-meshes.mjs
//
// Requires a webgpu-samples checkout at external/webgpu-samples (see below).
// The .bin files this produces are committed, so this only needs running when
// the upstream mesh data changes.

import { createRequire } from 'module';
import { writeFileSync, readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');

// The upstream checkout is scratch, not a dependency: external/ is gitignored
// and was emptied when the reference clones left the repo in 2026-08. Fail with
// the clone command rather than with a stack trace from createRequire.
const SAMPLES = resolve(root, 'external/webgpu-samples');
if (!existsSync(resolve(SAMPLES, 'package.json'))) {
  console.error(`[meshes] webgpu-samples not found at ${SAMPLES}`);
  console.error('[meshes] git clone https://github.com/webgpu/webgpu-samples external/webgpu-samples');
  process.exit(1);
}

const require = createRequire(resolve(SAMPLES, 'package.json'));

// ── Normal computation (ported from webgpu-samples/meshes/utils.ts) ──

function computeSurfaceNormals(positions, triangles) {
  const normals = positions.map(() => [0, 0, 0]);
  for (const [i0, i1, i2] of triangles) {
    const p0 = positions[i0], p1 = positions[i1], p2 = positions[i2];
    const v0 = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]];
    const v1 = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]];
    // Normalize v0, v1
    let len0 = Math.sqrt(v0[0] ** 2 + v0[1] ** 2 + v0[2] ** 2);
    let len1 = Math.sqrt(v1[0] ** 2 + v1[1] ** 2 + v1[2] ** 2);
    if (len0 > 0) { v0[0] /= len0; v0[1] /= len0; v0[2] /= len0; }
    if (len1 > 0) { v1[0] /= len1; v1[1] /= len1; v1[2] /= len1; }
    // Cross product
    const nx = v0[1] * v1[2] - v0[2] * v1[1];
    const ny = v0[2] * v1[0] - v0[0] * v1[2];
    const nz = v0[0] * v1[1] - v0[1] * v1[0];
    normals[i0][0] += nx; normals[i0][1] += ny; normals[i0][2] += nz;
    normals[i1][0] += nx; normals[i1][1] += ny; normals[i1][2] += nz;
    normals[i2][0] += nx; normals[i2][1] += ny; normals[i2][2] += nz;
  }
  for (const n of normals) {
    const len = Math.sqrt(n[0] ** 2 + n[1] ** 2 + n[2] ** 2);
    if (len > 0) { n[0] /= len; n[1] /= len; n[2] /= len; }
  }
  return normals;
}

function generateNormals(maxAngle, positions, triangles) {
  // Compute face normals
  const numFaces = triangles.length;
  const faceNormals = [];
  for (let i = 0; i < numFaces; i++) {
    const [n1, n2, n3] = triangles[i];
    const v1 = positions[n1], v2 = positions[n2], v3 = positions[n3];
    const ax = v2[0] - v1[0], ay = v2[1] - v1[1], az = v2[2] - v1[2];
    const bx = v3[0] - v1[0], by = v3[1] - v1[1], bz = v3[2] - v1[2];
    const nx = ay * bz - az * by, ny = az * bx - ax * bz, nz = ax * by - ay * bx;
    const len = Math.sqrt(nx * nx + ny * ny + nz * nz);
    faceNormals.push(len > 0 ? [nx / len, ny / len, nz / len] : [0, 0, 0]);
  }

  // Build vertex-to-position dedup map
  const vertToShared = new Map();
  let sharedIdx = 0;
  const vertIndices = [];
  for (let i = 0; i < positions.length; i++) {
    const key = positions[i].join(',');
    if (!vertToShared.has(key)) vertToShared.set(key, sharedIdx++);
    vertIndices.push(vertToShared.get(key));
  }

  // Map shared vertices to faces
  const vertFaces = [];
  for (let i = 0; i < numFaces; i++) {
    for (let j = 0; j < 3; j++) {
      const shared = vertIndices[triangles[i][j]];
      if (!vertFaces[shared]) vertFaces[shared] = [];
      vertFaces[shared].push(i);
    }
  }

  // Generate new vertices with angle-weighted normals
  const maxAngleCos = Math.cos(maxAngle);
  const newPositions = [], newNormals = [], newTriangles = [];
  const vertMap = new Map();
  let newIdx = 0;

  for (let i = 0; i < numFaces; i++) {
    const thisFaceNormal = faceNormals[i];
    const newTri = [];
    for (let j = 0; j < 3; j++) {
      const origIdx = triangles[i][j];
      const shared = vertIndices[origIdx];
      const norm = [0, 0, 0];
      for (const faceIdx of vertFaces[shared]) {
        const other = faceNormals[faceIdx];
        const dot = thisFaceNormal[0] * other[0] + thisFaceNormal[1] * other[1] + thisFaceNormal[2] * other[2];
        if (dot > maxAngleCos) {
          norm[0] += other[0]; norm[1] += other[1]; norm[2] += other[2];
        }
      }
      const len = Math.sqrt(norm[0] ** 2 + norm[1] ** 2 + norm[2] ** 2);
      if (len > 0) { norm[0] /= len; norm[1] /= len; norm[2] /= len; }

      const key = JSON.stringify({ p: positions[origIdx], n: norm });
      if (!vertMap.has(key)) {
        vertMap.set(key, newIdx++);
        newPositions.push(positions[origIdx]);
        newNormals.push(norm);
      }
      newTri.push(vertMap.get(key));
    }
    newTriangles.push(newTri);
  }

  return { positions: newPositions, normals: newNormals, triangles: newTriangles };
}

// ── Binary writer ──

function writeMeshBin(path, positions, normals, triangles, indexSize) {
  const vertCount = positions.length;
  const triCount = triangles.length;
  const headerBytes = 12;
  const posBytes = vertCount * 3 * 4;
  const normBytes = vertCount * 3 * 4;
  const idxBytes = triCount * 3 * indexSize;
  const total = headerBytes + posBytes + normBytes + idxBytes;

  const buf = Buffer.alloc(total);
  let off = 0;

  // Header
  buf.writeUInt32LE(vertCount, off); off += 4;
  buf.writeUInt32LE(triCount, off); off += 4;
  buf.writeUInt32LE(indexSize, off); off += 4;

  // Positions
  for (const p of positions) {
    buf.writeFloatLE(p[0], off); off += 4;
    buf.writeFloatLE(p[1], off); off += 4;
    buf.writeFloatLE(p[2], off); off += 4;
  }

  // Normals
  for (const n of normals) {
    buf.writeFloatLE(n[0], off); off += 4;
    buf.writeFloatLE(n[1], off); off += 4;
    buf.writeFloatLE(n[2], off); off += 4;
  }

  // Indices
  for (const tri of triangles) {
    for (const idx of tri) {
      if (indexSize === 2) {
        buf.writeUInt16LE(idx, off); off += 2;
      } else {
        buf.writeUInt32LE(idx, off); off += 4;
      }
    }
  }

  if (off !== total) throw new Error(`Expected ${total} bytes, wrote ${off}`);
  writeFileSync(path, buf);
  console.log(`  ${path}`);
  console.log(`    vertices: ${vertCount}, triangles: ${triCount}, index size: u${indexSize * 8}`);
  console.log(`    total: ${total} bytes (${(total / 1024).toFixed(1)} KB)`);
}

// ── Convert teapot ──

console.log('Converting teapot...');
const teapot = require('teapot');
const teapotNormals = computeSurfaceNormals(teapot.positions, teapot.cells);
const teapotOut = resolve(root, 'src/dsl/emitter/meshes/teapot.bin');
writeMeshBin(teapotOut, teapot.positions, teapotNormals, teapot.cells, 2);

// ── Convert Stanford dragon ──

console.log('Converting Stanford dragon...');
// Parse the TS file manually (it's a default export with positions and cells)
const dragonTsPath = resolve(root, 'external/webgpu-samples/meshes/stanfordDragonData.ts');
let dragonSrc = readFileSync(dragonTsPath, 'utf-8');
// Strip TypeScript: remove "export default" and trailing semicolons/comments
dragonSrc = dragonSrc.replace(/^\/\/.*\n/gm, '').replace(/^export default\s*/, '').replace(/;\s*$/, '');
const dragonRaw = eval(`(${dragonSrc})`);

// Run angle-weighted normal generation (same as the WebGPU sample)
const dragon = generateNormals(Math.PI, dragonRaw.positions, dragonRaw.cells);

// Determine index size
const indexSize = dragon.positions.length > 65535 ? 4 : 2;
const dragonOut = resolve(root, 'src/dsl/emitter/meshes/dragon.bin');
writeMeshBin(dragonOut, dragon.positions, dragon.normals, dragon.triangles, indexSize);

// Validate
console.log('\nValidation:');
const maxIdx = Math.max(...dragon.triangles.flat());
console.log(`  Dragon max index: ${maxIdx}, vertex count: ${dragon.positions.length}`);
if (maxIdx >= dragon.positions.length) throw new Error('Index out of range!');
const tMaxIdx = Math.max(...teapot.cells.flat());
console.log(`  Teapot max index: ${tMaxIdx}, vertex count: ${teapot.positions.length}`);
if (tMaxIdx >= teapot.positions.length) throw new Error('Index out of range!');
if (tMaxIdx > 65535) throw new Error('Teapot needs u32 indices!');

console.log('\nDone.');
