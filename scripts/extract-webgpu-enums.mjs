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
//   node scripts/extract-webgpu-enums.mjs [--spec <path-to-index.bs>]         # drift check
//   node scripts/extract-webgpu-enums.mjs [--spec <path-to-index.bs>] --regen # rewrite the snapshot
//
// Mirrors the `zig build schema-export` convention: the no-arg form is a gate.
// With no --spec it discovers the sibling `../gpuweb` checkout first and keeps
// `external/gpuweb` as the compatibility fallback. The CRD is the authority;
// the committed JSON is only a derived snapshot, so an absent clone still skips
// the gate cleanly (it announces both searched paths). An explicit `--spec`
// path is never ignored: a missing path is an error even in check mode.
//
// The checkout is scratch, never a dependency. The sibling is the checkout the
// plans pin; `external/` is gitignored and the clones that lived there left the
// repo in 2026-08.

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve, dirname, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');
const OUT_PATH = resolve(REPO_ROOT, 'schema/webgpu-enums.json');
const SIBLING_SPEC = resolve(REPO_ROOT, '../gpuweb/spec/index.bs');
const COMPAT_SPEC = resolve(REPO_ROOT, 'external/gpuweb/spec/index.bs');
/** One stable spelling: repo-relative (even when outside the repo) and slash-normalized. */
const displayPath = (abs) => relative(REPO_ROOT, abs).split(sep).join('/');

/**
 * An IDL member default as a plain JS-comparable value: string literals lose
 * their quotes (`"ccw"` → `ccw`), everything else (`0x10`, `{}`, `[]`, `false`)
 * stays verbatim, and an absent default is `null` rather than undefined so the
 * key is always present in the snapshot.
 */
function normalizeDefault(raw) {
  if (raw == null) return null;
  const t = raw.trim();
  if (t === '') return null;
  const quoted = /^"(.*)"$/.exec(t);
  return quoted ? quoted[1] : t;
}

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
function parseSpec(text, revision) {
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
      //
      // Since spec/09 the `required` keyword and the default expression are
      // KEPT rather than stripped: they are the two facts the field ratchet
      // needs to check more than member presence. A member is
      // `{ name, required, default }`, default `null` when the IDL gives none.
      const m = body.match(/^\s*(?:\[[^\]]*\]\s*)?(required\s+)?[\w<>() ,?]+?\s(\w+)\s*(?:=\s*([^;]*?))?\s*;/);
      if (m) bucket.push({ name: m[2], required: !!m[1], default: normalizeDefault(m[3]) });
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
  return { enums, flags, dictionaries, limits, specRevision: revision };
}

/**
 * The selected checkout's HEAD commit. The working directory is derived from
 * the selected `index.bs`, never a hardcoded checkout: a snapshot that cannot
 * say which spec it came from is exactly the failure mode step E exists to end.
 */
function specRevision(specPath) {
  const sha = execFileSync('git', ['-C', dirname(specPath), 'rev-parse', 'HEAD'], {
    encoding: 'utf8',
  }).trim();
  if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error(`unexpected gpuweb rev-parse output: ${JSON.stringify(sha)}`);
  return sha;
}

function render(parsed, source) {
  const command = `node scripts/extract-webgpu-enums.mjs --spec ${source} --regen`;
  const out = {
    $comment:
      `Generated from ${source} by scripts/extract-webgpu-enums.mjs. ` +
      `Do not edit by hand — run \`${command}\`. The canonical WebGPU ` +
      'enum/flag vocabulary; tests/npm/webgpu-conformance.test.js checks ' +
      'schema/pngine.sjon + the cross-stack byte tables against it.',
    source,
    // The gpuweb commit this snapshot was extracted from (spec/09 step E).
    // The checkout is scratch, so the gate cannot demand it — but recording
    // the source and revision makes a stale snapshot VISIBLE instead of
    // silent, which plan 06's "remember to regen" note could not do.
    specRevision: parsed.specRevision,
    enums: parsed.enums,
    flags: parsed.flags,
    dictionaries: parsed.dictionaries,
    limits: parsed.limits,
  };
  return `${JSON.stringify(out, null, 2)}\n`;
}

/**
 * Parse the extractor's arguments. `--spec` takes exactly one path; anything
 * unrecognized is a hard error rather than being ignored (the old build's
 * failure mode: `--spec ../gpuweb/...` was accepted and then discarded).
 */
function parseArgs(argv) {
  let regen = false;
  let requestedSpec = null;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--regen') {
      regen = true;
    } else if (arg === '--spec') {
      const value = argv[++i];
      if (value === undefined || value === '' || value.startsWith('--')) {
        console.error('[webgpu-enums] --spec requires a path to a gpuweb spec/index.bs');
        console.error('[webgpu-enums] usage: node scripts/extract-webgpu-enums.mjs [--spec <path-to-index.bs>] [--regen]');
        process.exit(2);
      }
      requestedSpec = value;
    } else {
      console.error(`[webgpu-enums] unknown option: ${arg}`);
      console.error('[webgpu-enums] usage: node scripts/extract-webgpu-enums.mjs [--spec <path-to-index.bs>] [--regen]');
      process.exit(2);
    }
  }
  return { regen, requestedSpec };
}

const { regen, requestedSpec } = parseArgs(process.argv.slice(2));

/**
 * Select the CRD index. An explicit --spec is resolved against the repo root
 * (the documented invocation is repo-relative) and must exist. With no
 * argument, prefer this host's sibling checkout and retain external/gpuweb as
 * the compatibility fallback; only when neither exists may the gate skip.
 */
function selectSpec() {
  if (requestedSpec !== null) {
    const abs = resolve(REPO_ROOT, requestedSpec);
    return {
      path: existsSync(abs) ? abs : null,
      source: displayPath(abs),
      explicit: true,
      searched: [displayPath(abs)],
    };
  }
  const candidates = [SIBLING_SPEC, COMPAT_SPEC];
  const found = candidates.find((candidate) => existsSync(candidate));
  return {
    path: found ?? null,
    source: found ? displayPath(found) : null,
    explicit: false,
    searched: candidates.map(displayPath),
  };
}

const selected = selectSpec();

if (!selected.path) {
  if (selected.explicit) {
    console.error(`[webgpu-enums] spec not found: ${selected.source}`);
    console.error('[webgpu-enums] the --spec path must name an existing gpuweb spec/index.bs.');
    process.exit(1);
  }
  const searched = selected.searched.join(' and ');
  if (regen) {
    console.error(`[webgpu-enums] spec not found — searched ${searched}`);
    console.error('[webgpu-enums] git clone https://github.com/gpuweb/gpuweb ../gpuweb');
    console.error('[webgpu-enums] then retry --regen.');
    process.exit(1);
  }
  console.log(`[webgpu-enums] gpuweb spec absent — skipped drift check; searched ${searched} (schema-only conformance tests still run against the committed snapshot).`);
  process.exit(0);
}

/**
 * Read the spec with its Bikeshed includes expanded in place. `index.bs`
 * carries `<pre class=include>\npath: sections/copies.bs\n</pre>` blocks
 * since the 2026-08 split, and every texel-copy dictionary
 * (GPUTexelCopyTextureInfo, GPUCopyExternalImageSourceInfo, …) lives in one
 * of them — reading `index.bs` alone silently dropped five dictionaries from
 * the snapshot, which is how the copy endpoints escaped FORM_DICT_MAP
 * (overhaul/09 D20). One level, no recursion: the sections include nothing.
 */
function readSpecWithIncludes(path) {
  const text = readFileSync(path, 'utf8');
  const dir = dirname(path);
  return text.replace(/<pre class=include>\s*\npath:\s*(\S+)\s*\n<\/pre>/g, (_, rel) => {
    const inc = resolve(dir, rel);
    if (!existsSync(inc)) throw new Error(`[webgpu-enums] include not found: ${inc}`);
    return readFileSync(inc, 'utf8');
  });
}

let revision;
try {
  revision = specRevision(selected.path);
} catch (err) {
  console.error(`[webgpu-enums] cannot read the revision of the selected checkout at ${selected.source}: ${err.message}`);
  process.exit(1);
}

const next = render(parseSpec(readSpecWithIncludes(selected.path), revision), selected.source);

if (regen) {
  writeFileSync(OUT_PATH, next);
  console.log(`[webgpu-enums] wrote ${displayPath(OUT_PATH)} from ${selected.source} @ ${revision}`);
  process.exit(0);
}

const current = existsSync(OUT_PATH) ? readFileSync(OUT_PATH, 'utf8') : '';
if (current !== next) {
  console.error(`[webgpu-enums] DRIFT: schema/webgpu-enums.json is stale vs ${selected.source} @ ${revision}.`);
  console.error(`[webgpu-enums] run: node scripts/extract-webgpu-enums.mjs --spec ${selected.source} --regen`);
  process.exit(1);
}
console.log(`[webgpu-enums] snapshot up to date: ${selected.source} @ ${revision}`);
