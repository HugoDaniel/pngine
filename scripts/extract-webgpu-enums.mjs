#!/usr/bin/env node
// Extract WebGPU enum / flag vocabularies from the gpuweb spec into a committed
// snapshot (`schema/webgpu-enums.json`). This is the upstream source of truth
// the conformance test (`tests/npm/webgpu-conformance.test.js`) checks PNGine's
// curated `schema/pngine.sjon` + the cross-stack byte tables against.
//
// The spec embeds its WebIDL inline in `<script type=idl>` blocks. Every enum is
// a `enum GPUFoo { "a", "b", … };` block of quoted strings (with `//` comments);
// the flag sets (GPUBufferUsage, GPUTextureUsage, …) are `namespace GPUFoo {
//   const GPUFlagsConstant NAME = 0x..; }` blocks. Both declare at column 0, so a
// line-anchored scan is robust against indented example code elsewhere.
//
// Since the field-level ratchet (docs/plans/spec/06) the snapshot also carries:
//   - `dictionaries`: each `dictionary GPUFoo { … }` block's DECLARED member
//     names (the `required` keyword and defaults stripped; inherited members are
//     NOT flattened — GPUObjectDescriptorBase's `label` stays on the base entry,
//     since PNGine's `:name` is its analogue). A declaration may continue on the
//     next line (`dictionary GPUFoo\n : Base {`).
//   - `limits`: the GPUSupportedLimits interface's readonly attribute names.
//
// Usage:
//   node scripts/extract-webgpu-enums.mjs            # drift check (exit 1 on diff)
//   node scripts/extract-webgpu-enums.mjs --regen    # rewrite the snapshot
//
// Mirrors the `zig build schema-export` convention: the no-arg form is a gate.
// Without a gpuweb checkout it skips cleanly (the committed JSON is what tests
// consume; the spec is only needed to regenerate it). That checkout is scratch,
// never a dependency — external/ is gitignored, and the clones that lived there
// left the repo in 2026-08.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');
const SPEC_PATH = resolve(REPO_ROOT, 'external/gpuweb/spec/index.bs');
const OUT_PATH = resolve(REPO_ROOT, 'schema/webgpu-enums.json');

/** Strip a `//`-to-end-of-line comment (IDL has no `//` inside string values). */
function stripLineComment(line) {
  const i = line.indexOf('//');
  return i === -1 ? line : line.slice(0, i);
}

/**
 * Parse every `enum GPU* { … }` and `namespace GPU* { … }` block from the spec
 * text. Returns `{ enums: {Name: string[]}, flags: {Name: {CONST: "0x.."}} }`
 * in source-encounter order (stable diffs).
 */
function parseSpec(text) {
  const lines = text.split('\n');
  const enums = {};
  const flags = {};
  const dictionaries = {};
  let limits = null;
  let mode = null; // 'enum' | 'flags' | 'dict' | 'limits' | null
  let name = '';
  let bucket = null;
  let pendingDict = ''; // `dictionary GPUFoo` seen, `{` still on a later line

  for (const raw of lines) {
    if (mode === null) {
      if (pendingDict) {
        // Declaration continuation (` : GPUBase {`, possibly spread over more
        // than one line). Anything that is not inheritance/whitespace before
        // the `{` means the parse went wrong — fail loud rather than silently
        // dropping the dictionary (§292: a mapped dictionary dropping would
        // trip FORM_DICT_MAP, but an unmapped one would just vanish).
        if (/\{/.test(raw)) {
          mode = 'dict';
          name = pendingDict;
          bucket = [];
          pendingDict = '';
        } else if (!/^\s*(?::\s*\w+\s*)?$/.test(stripLineComment(raw))) {
          throw new Error(`unparseable continuation of "dictionary ${pendingDict}": ${JSON.stringify(raw)}`);
        }
        continue;
      }
      const e = raw.match(/^enum\s+(GPU\w+)\s*\{/);
      if (e) {
        mode = 'enum';
        name = e[1];
        bucket = [];
        continue;
      }
      const n = raw.match(/^namespace\s+(GPU\w+)\s*\{/);
      if (n) {
        mode = 'flags';
        name = n[1];
        bucket = {};
        continue;
      }
      const d = raw.match(/^dictionary\s+(GPU\w+)\s*(\{)?/);
      if (d) {
        if (d[2] || /\{/.test(raw)) {
          mode = 'dict';
          name = d[1];
          bucket = [];
        } else {
          pendingDict = d[1]; // `: Base {` continues on the next line
        }
        continue;
      }
      if (/^interface\s+GPUSupportedLimits\s*\{/.test(raw)) {
        mode = 'limits';
        name = 'GPUSupportedLimits';
        bucket = [];
        continue;
      }
      continue;
    }
    if (raw.trimStart().startsWith('};')) {
      // Only keep flag namespaces that actually declare flag constants — many
      // `namespace` blocks in the spec are operation/algorithm holders.
      if (mode === 'enum') enums[name] = bucket;
      else if (mode === 'dict') dictionaries[name] = bucket;
      else if (mode === 'limits') limits = bucket;
      else if (Object.keys(bucket).length > 0) flags[name] = bucket;
      mode = null;
      bucket = null;
      continue;
    }
    const body = stripLineComment(raw);
    if (mode === 'enum') {
      for (const m of body.matchAll(/"([^"]+)"/g)) bucket.push(m[1]);
    } else if (mode === 'dict') {
      // `required GPUFoo bar;` / `GPUFoo bar = default;` / `sequence<T> bar = [];`
      // / `[Clamp] unsigned short bar = 1;` — the member name is the last
      // identifier before `;` or `=`; a leading `[ExtAttr]` is skipped.
      const m = body.match(/^\s*(?:\[[^\]]*\]\s*)?(?:required\s+)?[\w<>() ,?]+?\s(\w+)\s*(?:=[^;]*)?;/);
      if (m) bucket.push(m[1]);
    } else if (mode === 'limits') {
      const m = body.match(/^\s*readonly attribute [\w ]+\s(\w+);/);
      if (m) bucket.push(m[1]);
    } else {
      const c = body.match(/const\s+\w+\s+(\w+)\s*=\s*(0x[0-9a-fA-F]+)/);
      if (c) bucket[c[1]] = c[2].toLowerCase();
    }
  }
  if (mode !== null) throw new Error(`unterminated ${mode} block '${name}' in spec`);
  if (!limits) throw new Error('GPUSupportedLimits interface not found in spec');
  return { enums, flags, dictionaries, limits };
}

function render(parsed) {
  const out = {
    $comment:
      'Generated from external/gpuweb/spec/index.bs by ' +
      'scripts/extract-webgpu-enums.mjs. Do not edit by hand — run ' +
      '`node scripts/extract-webgpu-enums.mjs --regen`. The canonical WebGPU ' +
      'enum/flag vocabulary; tests/npm/webgpu-conformance.test.js checks ' +
      'schema/pngine.sjon + the cross-stack byte tables against it.',
    source: 'external/gpuweb/spec/index.bs',
    enums: parsed.enums,
    flags: parsed.flags,
    dictionaries: parsed.dictionaries,
    limits: parsed.limits,
  };
  return `${JSON.stringify(out, null, 2)}\n`;
}

const regen = process.argv.includes('--regen');

if (!existsSync(SPEC_PATH)) {
  if (regen) {
    console.error(`[webgpu-enums] spec not found: ${SPEC_PATH}`);
    console.error('[webgpu-enums] git clone https://github.com/gpuweb/gpuweb external/gpuweb');
    console.error('[webgpu-enums] then retry --regen.');
    process.exit(1);
  }
  console.log('[webgpu-enums] gpuweb spec absent — skipping drift check (snapshot is source of truth).');
  process.exit(0);
}

const next = render(parseSpec(readFileSync(SPEC_PATH, 'utf8')));

if (regen) {
  writeFileSync(OUT_PATH, next);
  console.log(`[webgpu-enums] wrote ${OUT_PATH}`);
  process.exit(0);
}

const current = existsSync(OUT_PATH) ? readFileSync(OUT_PATH, 'utf8') : '';
if (current !== next) {
  console.error('[webgpu-enums] DRIFT: schema/webgpu-enums.json is stale vs the gpuweb spec.');
  console.error('[webgpu-enums] run: node scripts/extract-webgpu-enums.mjs --regen');
  process.exit(1);
}
console.log('[webgpu-enums] snapshot up to date.');
