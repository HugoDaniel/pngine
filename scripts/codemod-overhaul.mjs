#!/usr/bin/env node
// The DSL overhaul's corpus rewrite (docs/plans/overhaul/07 §3).
//
// One script, one pass, idempotent. It rewrites every document from the
// pre-overhaul spelling to the target grammar of 02-consistency-rules.md:
// scalars that were positional atom forms become keys, the `(buffers …)` and
// `(targets …)` wrappers go, commands become forms, and the renamed keys are
// renamed.
//
// WHY A TOKENIZER AND NOT A `sed`. Two reasons, both learned from this corpus:
//
//   1. `(entry …)` names two different things. The 979 occurrences in
//      `examples/` are mostly `(entry :binding 0 :buffer u)` — a bind-group
//      entry, an R3 sequence element that STAYS. Only the positional atom form
//      `(entry vsMain)` inside a pipeline stage is retired. A textual rule
//      cannot tell them apart; a structural one reads the parent's head.
//   2. Every rewrite touches WGSL-bearing files, and `(module …)`/`(entry …)`
//      appear inside `"""…"""` shader text as comments. The tokenizer skips
//      strings and comments by construction.
//
// Rewrites are SPAN SPLICES applied right-to-left: nothing is reprinted, so
// the author's line breaks, alignment and comments survive. The only
// reindentation is the wrapper unwrap, which dedents its children by the
// column difference it removes.
//
// Usage:
//   node scripts/codemod-overhaul.mjs [paths…]      rewrite in place
//   node scripts/codemod-overhaul.mjs --check       exit 1 if anything would change
//   node scripts/codemod-overhaul.mjs --dry-run     print a diff-ish report, write nothing
//   node scripts/codemod-overhaul.mjs --group <name> [--group <name>…]
//                                                   run one cut's rewrites only
//                                                   (pipelines, bindings, resources,
//                                                   passes, commands — see GROUPS)
//
// With no paths it walks `examples/` only (DEFAULT_TARGETS); the drift gate in
// build.zig names the wider set (src/, tests/, docs/, npm/, scripts/, README.md,
// CLAUDE.md, CONTRIBUTING.md) explicitly.

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, extname } from 'node:path';

// ---------------------------------------------------------------------------
// Parser: source text → a tree of nodes carrying byte spans.
// ---------------------------------------------------------------------------

// A node is one of:
//   { kind: 'list',  open, close, items }   a ( … ) form; items[0] is its head
//   { kind: 'vec',   open, close, items }   a [ … ] vector
//   { kind: 'kw',    start, end, name }     a :keyword
//   { kind: 'atom',  start, end, text }     a symbol or number
//   { kind: 'str',   start, end }           a "…" or """…""" string
// `close` is the index OF the closing delimiter, so the node's text is
// src.slice(open, close + 1).

const isSpace = (c) => c === ' ' || c === '\t' || c === '\n' || c === '\r';
const isDelim = (c) => c === undefined || isSpace(c) || c === '(' || c === ')' || c === '[' || c === ']' || c === ';' || c === '"';

class ParseError extends Error {}

/// Parse `src` into a list of top-level nodes. Throws ParseError on an
/// unbalanced delimiter or an unterminated string — the caller reports the file
/// rather than silently skipping it (07 §3: "no silent skips").
function parse(src) {
  let i = 0;

  function skipTrivia() {
    for (;;) {
      while (i < src.length && isSpace(src[i])) i++;
      if (src[i] === ';') {
        while (i < src.length && src[i] !== '\n') i++;
        continue;
      }
      return;
    }
  }

  function parseNode() {
    skipTrivia();
    if (i >= src.length) return null;
    const c = src[i];

    if (c === ')' || c === ']') return null;

    if (c === '(' || c === '[') {
      const open = i;
      const closer = c === '(' ? ')' : ']';
      i++;
      const items = [];
      for (;;) {
        skipTrivia();
        if (i >= src.length) throw new ParseError(`unterminated '${c}' at offset ${open}`);
        if (src[i] === closer) break;
        if (src[i] === ')' || src[i] === ']') throw new ParseError(`mismatched '${src[i]}' at offset ${i} (opened '${c}' at ${open})`);
        const n = parseNode();
        if (n === null) throw new ParseError(`unterminated '${c}' at offset ${open}`);
        items.push(n);
      }
      const close = i;
      i++;
      return { kind: c === '(' ? 'list' : 'vec', open, close, items };
    }

    if (c === '"') {
      const start = i;
      if (src.startsWith('"""', i)) {
        const end = src.indexOf('"""', i + 3);
        if (end < 0) throw new ParseError(`unterminated """ string at offset ${start}`);
        i = end + 3;
      } else {
        i++;
        while (i < src.length && src[i] !== '"') {
          if (src[i] === '\\') i++;
          i++;
        }
        if (i >= src.length) throw new ParseError(`unterminated string at offset ${start}`);
        i++;
      }
      return { kind: 'str', start, end: i };
    }

    const start = i;
    while (i < src.length && !isDelim(src[i])) i++;
    if (i === start) throw new ParseError(`unexpected '${src[i]}' at offset ${i}`);
    const text = src.slice(start, i);
    return text[0] === ':'
      ? { kind: 'kw', start, end: i, name: text.slice(1) }
      : { kind: 'atom', start, end: i, text };
  }

  const roots = [];
  for (;;) {
    skipTrivia();
    if (i >= src.length) break;
    const n = parseNode();
    if (n === null) throw new ParseError(`stray '${src[i]}' at offset ${i}`);
    roots.push(n);
  }
  return roots;
}

// --- node helpers ----------------------------------------------------------

const nodeStart = (n) => (n.kind === 'list' || n.kind === 'vec' ? n.open : n.start);
const nodeEnd = (n) => (n.kind === 'list' || n.kind === 'vec' ? n.close + 1 : n.end);

/// The head symbol of a form, or null for a vector / a list that does not start
/// with a bare symbol.
function headOf(n) {
  if (n.kind !== 'list') return null;
  const h = n.items[0];
  return h && h.kind === 'atom' ? h.text : null;
}

/// Every `:key value` pair in a form, as { kw, value, index } where `index` is
/// the position of the keyword in `items`. A keyword whose value is another
/// keyword (or which ends the form) is reported with `value: null`.
function kvsOf(form) {
  const out = [];
  for (let k = 1; k < form.items.length; k++) {
    const it = form.items[k];
    if (it.kind !== 'kw') continue;
    const v = form.items[k + 1];
    out.push({ kw: it, value: v && v.kind !== 'kw' ? v : null, index: k });
  }
  return out;
}

const kvOf = (form, name) => kvsOf(form).find((p) => p.kw.name === name) || null;
const childrenOf = (form, head) => form.items.filter((n) => headOf(n) === head);

/// Walk every list node in the tree, parents before children.
function* walk(nodes) {
  const stack = [...nodes].reverse();
  while (stack.length) {
    const n = stack.pop();
    if (n.kind === 'list' || n.kind === 'vec') {
      if (n.kind === 'list') yield n;
      for (let k = n.items.length - 1; k >= 0; k--) stack.push(n.items[k]);
    }
  }
}

// ---------------------------------------------------------------------------
// Edit list: span splices, applied right-to-left so earlier offsets stay valid.
// ---------------------------------------------------------------------------

class Edits {
  constructor(src) {
    this.src = src;
    this.list = [];
    this.counts = Object.create(null);
  }

  /// Replace [start, end) with `text`, attributing the change to rule `rule`.
  splice(start, end, text, rule) {
    if (start > end) throw new Error(`inverted splice ${start}..${end}`);
    this.list.push({ start, end, text, rule });
    this.counts[rule] = (this.counts[rule] || 0) + 1;
  }

  /// Delete a node together with the whitespace that precedes it, so removing a
  /// positional child does not leave a double space behind. The gap is only
  /// absorbed when it is pure whitespace — a comment between siblings is the
  /// author's and stays.
  deleteWithGap(node, prevEnd, rule) {
    this.deleteSpan(nodeStart(node), nodeEnd(node), prevEnd, rule);
  }

  /// Delete [start, end), absorbing the whitespace back to `prevEnd` — and, when
  /// that leaves the line blank, the whole line. Deleting a key that owned its
  /// own line otherwise leaves a line of trailing spaces behind, which no author
  /// wrote and every formatter would strip.
  deleteSpan(start, end, prevEnd, rule) {
    // Absorb same-line whitespace back to the previous sibling — but only
    // whitespace: a comment between siblings is the author's and stays.
    let from = /^[ \t]*$/.test(this.src.slice(prevEnd, start)) ? prevEnd : start;
    let to = end;
    // When the deleted span OWNS the start of its line, take the newline and the
    // indentation with it, and any spaces it leaves trailing. Otherwise a key
    // that had a line to itself leaves a line of whitespace nobody wrote.
    const lineStart = this.src.lastIndexOf('\n', from - 1) + 1;
    if (lineStart > 0 && /^[ \t]*$/.test(this.src.slice(lineStart, from))) {
      from = lineStart - 1;
      // Trailing spaces go too — but ONLY when nothing else follows on the line.
      // Eating the separator before a sibling key overlaps that key's own
      // deletion (`:draw 4 :instance-count 5` on one line hit exactly this).
      const nl = this.src.indexOf('\n', to);
      const lineEnd = nl < 0 ? this.src.length : nl;
      if (/^[ \t]*$/.test(this.src.slice(to, lineEnd))) to = lineEnd;
    }
    // A deletion that absorbed no gap and left none behind would JOIN its two
    // neighbours: `(fragment :module code :entry f …)` collapsed to
    // `:entry f(target …)`, one token where the author had two. A single space
    // is the separator the deleted node was standing in for. Not needed against
    // a bracket, which separates on its own.
    const joins = from === start && to === end && !isSpace(this.src[end]) && this.src[end] !== ')' && this.src[start - 1] !== '(';
    this.splice(from, to, joins ? ' ' : '', rule);
  }

  /// Delete a `:key value` pair from `form`, gap and blank line included.
  deleteKv(form, pair, rule) {
    this.deleteSpan(pair.kw.start, nodeEnd(pair.value), nodeEnd(form.items[pair.index - 1]), rule);
  }

  apply() {
    if (!this.list.length) return this.src;
    const sorted = [...this.list].sort((a, b) => a.start - b.start || a.end - b.end);
    for (let k = 1; k < sorted.length; k++) {
      if (sorted[k].start < sorted[k - 1].end) {
        throw new Error(
          `overlapping edits: ${sorted[k - 1].rule} [${sorted[k - 1].start},${sorted[k - 1].end}) ` +
            `vs ${sorted[k].rule} [${sorted[k].start},${sorted[k].end})`,
        );
      }
    }
    let out = this.src;
    for (let k = sorted.length - 1; k >= 0; k--) {
      out = out.slice(0, sorted[k].start) + sorted[k].text + out.slice(sorted[k].end);
    }
    return out;
  }
}

/// The 0-based column of `offset` in `src` (tabs count as one).
function columnOf(src, offset) {
  const nl = src.lastIndexOf('\n', offset - 1);
  return offset - (nl + 1);
}

/// Remove `n` leading spaces from every line but the first — the reindent an
/// unwrap owes its children.
function dedent(text, n) {
  if (n <= 0) return text;
  return text
    .split('\n')
    .map((line, k) => (k === 0 ? line : line.replace(new RegExp(`^ {1,${n}}`), '')))
    .join('\n');
}

// ---------------------------------------------------------------------------
// The rewrites (docs/plans/overhaul/07 §2, rows 2–19)
// ---------------------------------------------------------------------------

/// Heads whose positional-atom children become keys, by parent head.
/// `(vertex (module code) (entry vsMain) …)` → `(vertex :module code :entry vsMain …)`
const ATOM_FORM_TO_KEY = {
  vertex: ['module', 'entry'],
  fragment: ['module', 'entry'],
  compute: ['module', 'entry'],
  primitive: ['topology'],
};

/// Wrappers that R3 drops: the children splice into the parent in place.
const WRAPPERS = { buffers: 'vertex', targets: 'fragment' };

/// Plain key renames, by rule GROUP and then by the head of the form that
/// carries the key.
const KEY_RENAMES = {
  pipelines: {
    'render-pipeline': { 'pipeline-layout': 'layout' },
    'compute-pipeline': { 'pipeline-layout': 'layout' },
  },
  bindings: {
    'bind-group': { 'layout-pipeline': 'layout', 'layout-index': 'group', 'bind-group-layout': 'layout' },
  },
  resources: {
    texture: { 'size-from': 'size' },
    init: { shader: 'module' },
    'image-bitmap': { image: 'data' },
    'wasm-data': { url: 'file' },
    'wasm-call': { url: 'file' },
    buffer: { wasm: 'file' },
    data: { blob: 'file' },
    // The fifth "file on disk" spelling F12 missed (audit 09 D18): the pass
    // sugar's WASM data files. R11 — sugar is spelled like what it lowers to,
    // and this lowers to `(buffer :file …)`.
    pass: { data: 'file' },
    // GPUTextureViewDescriptor.dimension (audit 09 D19). Per-head, so the BGL
    // resource forms — whose member IS `viewDimension` — are untouched.
    'texture-view': { 'view-dimension': 'dimension' },
  },
  passes: {
    'write-buffer': { 'data-from-wasm': 'data' },
    // GPURenderPassTimestampWrites' two indices, spelled as the IDL spells
    // them (audit 09 D21; R8's argument — `2d-array` is long too).
    'timestamp-writes': { begin: 'beginning-of-pass-write-index', end: 'end-of-pass-write-index' },
  },
};

/// Heads renamed outright (D3: the IDL word is `depthStencilAttachment`).
const HEAD_RENAMES = { 'depth-attachment': 'depth-stencil-attachment' };

/// The rule groups, in the order the cuts land. Each is a set of rewrites that
/// one schema+emitter commit makes legal, so running a group leaves the tree
/// green: the corpus, the schema and the golden traces move together. Running
/// the whole codemod at once is only correct once every cut has landed.
export const GROUPS = ['pipelines', 'bindings', 'resources', 'passes', 'commands'];

/// Build ` :key value` text for each named key present on `form`, deleting the
/// original pair. Returns the collected text, or '' when none were present.
function liftKeys(e, src, form, names, rule) {
  const parts = [];
  for (const name of names) {
    const pair = kvOf(form, name);
    if (!pair || !pair.value) continue;
    parts.push(` :${name} ${src.slice(nodeStart(pair.value), nodeEnd(pair.value))}`);
    e.deleteKv(form, pair, rule);
  }
  return parts.join('');
}

/// The indentation a new child form of `form` should carry: the parent's own
/// column plus two, on a fresh line — unless the whole form sits on one line,
/// where the child joins it with a single space.
function childIndent(src, form) {
  const oneLine = !src.slice(form.open, form.close).includes('\n');
  return oneLine ? ' ' : '\n' + ' '.repeat(columnOf(src, form.open) + 2);
}

/// One document's rewrite. `groups` selects which rule groups run (default:
/// all of them). Returns { text, counts, error }.
export function rewrite(src, groups = GROUPS) {
  const on = (g) => groups.includes(g);
  let roots;
  try {
    roots = parse(src);
  } catch (e) {
    if (e instanceof ParseError) return { text: src, counts: {}, error: e.message };
    throw e;
  }

  const e = new Edits(src);

  for (const form of walk(roots)) {
    const head = headOf(form);
    if (!head) continue;

    // --- R1: positional atom forms become keys -----------------------------
    const atomKeys = on('pipelines') ? ATOM_FORM_TO_KEY[head] : undefined;
    if (atomKeys) {
      const moved = [];
      for (const key of atomKeys) {
        const child = childrenOf(form, key)[0];
        if (!child) continue;
        const arg = child.items[1];
        if (!arg || child.items.length !== 2) continue; // not the atom shape — leave it
        moved.push({ key, text: src.slice(nodeStart(arg), nodeEnd(arg)) });
        const idx = form.items.indexOf(child);
        e.deleteWithGap(child, nodeEnd(form.items[idx - 1]), `${head}/(${key} …)→:${key}`);
      }
      if (moved.length) {
        const at = nodeEnd(form.items[0]);
        e.splice(at, at, moved.map((m) => ` :${m.key} ${m.text}`).join(''), `${head}/keys`);
      }
    }

    // --- R3: drop the (buffers …) / (targets …) wrappers --------------------
    if (WRAPPERS[head] !== undefined) continue; // handled from the parent below
    for (const [wrapperHead, parentHead] of on('pipelines') ? Object.entries(WRAPPERS) : []) {
      if (head !== parentHead) continue;
      for (const w of childrenOf(form, wrapperHead)) {
        const kids = w.items.slice(1);
        if (!kids.length) continue; // an empty wrapper is a negative's business
        // Everything between the wrapper's head and its close, not just the
        // children: a comment sitting above the first `(vertex-buffer …)` is the
        // author's and belongs to the child, not to the wrapper that is going
        // away. Slicing child-start-to-child-end silently ate those.
        const inner = src.slice(nodeEnd(w.items[0]), w.close).replace(/^\s+/, '').replace(/\s+$/, '');
        // How far left the children move. When the first child sits on the
        // wrapper's OWN line (`(targets (target …`), the lines under it were
        // indented relative to the WRAPPER — and the child lands exactly where
        // the wrapper opened, so nothing shifts. Dedenting by the head's width
        // there stripped 30 corpus lines to column 0: still legal, unreadable,
        // and invisible to every gate.
        const sameLine = !src.slice(w.open, nodeStart(kids[0])).includes('\n');
        const shift = sameLine ? 0 : columnOf(src, nodeStart(kids[0])) - columnOf(src, w.open);
        e.splice(w.open, w.close + 1, dedent(inner, shift), `unwrap (${wrapperHead} …)`);
      }
    }

    // --- R10: key renames ---------------------------------------------------
    for (const group of groups) {
      const renames = KEY_RENAMES[group]?.[head];
      if (!renames) continue;
      for (const pair of kvsOf(form)) {
        const to = renames[pair.kw.name];
        if (!to) continue;
        e.splice(pair.kw.start, pair.kw.end, `:${to}`, `${head}/:${pair.kw.name}→:${to}`);
      }
    }

    // --- D3: head renames ---------------------------------------------------
    const newHead = on('passes') ? HEAD_RENAMES[head] : undefined;
    if (newHead) {
      const h = form.items[0];
      e.splice(h.start, h.end, newHead, `(${head} …)→(${newHead} …)`);
    }

    // --- D10/R2: the compute stage becomes a (compute …) sub-form -----------
    if (head === 'compute-pipeline' && on('pipelines')) {
      const keys = liftKeys(e, src, form, ['module', 'entry'], 'compute-pipeline/stage keys');
      const constants = childrenOf(form, 'constant');
      if (keys) {
        let body = '';
        for (const c of constants) {
          body += `\n${' '.repeat(columnOf(src, form.open) + 4)}${src.slice(nodeStart(c), nodeEnd(c))}`;
          e.deleteWithGap(c, nodeEnd(form.items[form.items.indexOf(c) - 1]), 'compute-pipeline/(constant …)');
        }
        e.splice(form.close, form.close, `${childIndent(src, form)}(compute${keys}${body})`, 'compute-pipeline/(compute …)');
      }
    }

    // --- R5: texture :width/:height/:depth-or-array-layers → :size [w h d] ---
    if (head === 'texture' && on('resources')) {
      const w = kvOf(form, 'width');
      const h = kvOf(form, 'height');
      const d = kvOf(form, 'depth-or-array-layers');
      if (w && w.value) {
        const dims = [w, h, d]
          .filter((p) => p && p.value)
          .map((p) => src.slice(nodeStart(p.value), nodeEnd(p.value)));
        e.splice(w.kw.start, nodeEnd(w.value), `:size [${dims.join(' ')}]`, 'texture/:width→:size');
        for (const p of [h, d]) if (p && p.value) e.deleteKv(form, p, 'texture/:width→:size');
      }
    }

    // --- R10: buffer contents are `:data`, and they size the buffer ---------
    if (head === 'buffer' && on('resources')) {
      const mapped = kvOf(form, 'mapped-at-creation');
      if (mapped && mapped.value) {
        e.splice(mapped.kw.start, mapped.kw.end, ':data', 'buffer/:mapped-at-creation→:data');
        // The 39 documents that named the same data twice: `:size verts` beside
        // `:mapped-at-creation verts`. `:data` sizes the buffer now, so the
        // duplicate goes — but only when it names the SAME data (a numeric
        // `:size` beside `:data` stays; it is a real over-allocation).
        const size = kvOf(form, 'size');
        const same =
          size &&
          size.value &&
          src.slice(nodeStart(size.value), nodeEnd(size.value)) ===
            src.slice(nodeStart(mapped.value), nodeEnd(mapped.value));
        if (same) e.deleteKv(form, size, 'buffer/drop duplicate :size');
      }
    }

    // --- D5: the copy operations take (source …) / (destination …) ----------
    if (on('passes') && (head === 'copy-texture-to-texture' || head === 'copy-external-image-to-texture')) {
      const srcKey = head === 'copy-external-image-to-texture' ? 'image' : 'texture';
      const from = kvOf(form, 'source');
      const to = kvOf(form, 'destination') || kvOf(form, 'texture');
      if (from && from.value && to && to.value) {
        // `:mip-level` and `:origin` are members of the DESTINATION
        // (GPUTexelCopyTextureInfo), not of the copy. Leaving them on the parent
        // would keep half the dictionary flat, which is the shape D5 retires —
        // and `cubemap.sjon` uploads its six faces by `:origin` alone.
        const dstKeys = liftKeys(e, src, form, ['mip-level', 'origin'], 'copy/(destination …)');
        const ind = childIndent(src, form);
        const parts =
          `${ind}(source :${srcKey} ${src.slice(nodeStart(from.value), nodeEnd(from.value))})` +
          `${ind}(destination :texture ${src.slice(nodeStart(to.value), nodeEnd(to.value))}${dstKeys})`;
        e.deleteKv(form, from, 'copy/(source …)');
        e.deleteKv(form, to, 'copy/(destination …)');
        e.splice(form.close, form.close, parts, 'copy/child forms');
      }
    }

    // --- R9 + D11: dispatch is a form, and :workgroups is a vector ----------
    if (head === 'compute-pass' && on('commands')) {
      const n = kvOf(form, 'dispatch-workgroups');
      const v = kvOf(form, 'dispatch');
      const ind = kvOf(form, 'dispatch-indirect');
      if (n && n.value) {
        const text = src.slice(nodeStart(n.value), nodeEnd(n.value));
        e.deleteKv(form, n, 'compute-pass/(dispatch …)');
        e.splice(form.close, form.close, `${childIndent(src, form)}(dispatch :workgroups [${text}])`, 'compute-pass/(dispatch …)');
      } else if (v && v.value) {
        const text = src.slice(nodeStart(v.value), nodeEnd(v.value));
        e.deleteKv(form, v, 'compute-pass/(dispatch …)');
        e.splice(form.close, form.close, `${childIndent(src, form)}(dispatch :workgroups ${text})`, 'compute-pass/(dispatch …)');
      } else if (ind && ind.value) {
        const off = kvOf(form, 'dispatch-indirect-offset');
        const offText = off && off.value ? ` :offset ${src.slice(nodeStart(off.value), nodeEnd(off.value))}` : '';
        e.deleteKv(form, ind, 'compute-pass/(dispatch-indirect …)');
        if (off && off.value) e.deleteKv(form, off, 'compute-pass/(dispatch-indirect …)');
        const buf = src.slice(nodeStart(ind.value), nodeEnd(ind.value));
        e.splice(form.close, form.close, `${childIndent(src, form)}(dispatch-indirect :buffer ${buf}${offText})`, 'compute-pass/(dispatch-indirect …)');
      }
    }

    // --- D11: `(init … :workgroups [N])` is the same decision as the dispatch --
    if (head === 'init' && on('commands')) {
      const wg = kvOf(form, 'workgroups');
      if (wg && wg.value && wg.value.kind !== 'vec') {
        const text = src.slice(nodeStart(wg.value), nodeEnd(wg.value));
        e.splice(nodeStart(wg.value), nodeEnd(wg.value), `[${text}]`, 'init/:workgroups → vector');
      }
    }

    // --- R9: a render-bundle issues draw FORMS ------------------------------
    if (head === 'render-bundle' && on('commands')) {
      const draw = kvOf(form, 'draw');
      if (draw && draw.value) {
        const inst = kvOf(form, 'instance-count');
        const instText = inst && inst.value ? ` :instance-count ${src.slice(nodeStart(inst.value), nodeEnd(inst.value))}` : '';
        const count = src.slice(nodeStart(draw.value), nodeEnd(draw.value));
        e.deleteKv(form, draw, 'render-bundle/(draw …)');
        if (inst && inst.value) e.deleteKv(form, inst, 'render-bundle/(draw …)');
        e.splice(form.close, form.close, `${childIndent(src, form)}(draw :vertex-count ${count}${instText})`, 'render-bundle/(draw …)');
      }
    }
  }

  return { text: e.apply(), counts: e.counts, error: null };
}

// ---------------------------------------------------------------------------
// Embedded documents (07 §1.2 / §1.3)
// ---------------------------------------------------------------------------
//
// A `.sjon` file is not the only place a document lives: the Zig tests carry
// them in `\\` multiline literals, the npm tests in template literals, and the
// docs in fenced code blocks. All three are compiled or validated by a gate, so
// leaving them behind does not fail quietly — it fails loudly, in a place that
// looks like an emitter bug.
//
// Every extractor obeys the same safety rule: a block is rewritten ONLY when it
// parses as a document AND a rule actually fires on it. WGSL, JSON, shell and
// prose blocks live in the same syntax and are left untouched by construction —
// they carry none of the heads the rules key on.

/// Does this block look like a document rather than a fragment of one? Every
/// embedded document in the tree is a run of complete top-level forms.
/// The heads a pngine document may carry at top level. Not a schema — a
/// DISCRIMINATOR: an embedded block is only a document when every one of its
/// top-level forms is one of these. Sniffing the text instead ("starts with
/// `(`, ends with `)`") got both answers wrong: it skipped the reference's
/// skeleton fence, whose last line ends in a trailing comment, and it would
/// happily have rewritten a fenced block of some other S-expression language.
const DOCUMENT_HEADS = new Set([
  'define', 'limits', 'canvas', 'shader-module', 'data', 'image-bitmap',
  'texture', 'texture-view', 'buffer', 'query-set', 'queue', 'bind-group',
  'bind-group-layout', 'pipeline-layout', 'sampler', 'render-pipeline',
  'compute-pipeline', 'render-pass', 'compute-pass', 'render-bundle', 'frame',
  'init', 'pass-graph', 'wasm-call',
]);

function looksLikeDocument(text) {
  let roots;
  try {
    roots = parse(text);
  } catch {
    return false;
  }
  if (!roots.length) return false;
  return roots.every((n) => n.kind === 'list' && DOCUMENT_HEADS.has(headOf(n)));
}

/// Zig: a run of consecutive `\\`-prefixed lines. The document is the text
/// after the prefix; the run is re-emitted at the indentation of its first line
/// (a `\\` literal's own indentation is not part of its value).
function zigBlocks(src) {
  const out = [];
  const lines = src.split('\n');
  const starts = [];
  let at = 0;
  for (const line of lines) {
    starts.push(at);
    at += line.length + 1;
  }
  const isCont = (k) => /^\s*\\\\/.test(lines[k]);
  for (let k = 0; k < lines.length; k += 1) {
    if (!isCont(k)) continue;
    let j = k;
    while (j + 1 < lines.length && isCont(j + 1)) j += 1;
    const indent = lines[k].match(/^\s*/)[0];
    const doc = lines.slice(k, j + 1).map((l) => l.replace(/^\s*\\\\/, '')).join('\n');
    out.push({
      start: starts[k],
      end: starts[j] + lines[j].length,
      doc,
      render: (text) => text.split('\n').map((l) => `${indent}\\\\${l}`).join('\n'),
    });
    k = j;
  }
  return out;
}

/// JS: template literals. Paired left to right over unescaped backticks, which
/// is enough for the test files that carry documents — and `looksLikeDocument`
/// discards anything a mis-pairing would produce.
function backtickBlocks(src) {
  const out = [];
  const ticks = [];
  for (let k = 0; k < src.length; k += 1) {
    if (src[k] === '\\') { k += 1; continue; }
    if (src[k] === '`') ticks.push(k);
  }
  for (let k = 0; k + 1 < ticks.length; k += 2) {
    const start = ticks[k] + 1;
    const end = ticks[k + 1];
    out.push({ start, end, doc: src.slice(start, end), render: (text) => text });
  }
  return out;
}

/// Markdown / llms.txt: fenced code blocks, tagged or not. An untagged fence
/// carrying WGSL or shell parses to atoms no rule matches, so the language tag
/// is not load-bearing.
function fenceBlocks(src) {
  const out = [];
  const re = /^```[^\n]*\n([\s\S]*?)^```/gm;
  for (let m = re.exec(src); m; m = re.exec(src)) {
    const start = m.index + m[0].indexOf('\n') + 1;
    out.push({ start, end: start + m[1].length, doc: m[1], render: (text) => text });
  }
  return out;
}

const EXTRACTORS = { '.zig': zigBlocks, '.js': backtickBlocks, '.mjs': backtickBlocks, '.md': fenceBlocks, '.txt': fenceBlocks };

/// Rewrite every embedded document in a host file. Returns the same shape as
/// `rewrite`, so the driver treats both kinds of file identically.
export function rewriteEmbedded(src, ext, groups = GROUPS) {
  const extract = EXTRACTORS[ext];
  if (!extract) return { text: src, counts: {}, error: null };

  const counts = Object.create(null);
  const patches = [];
  for (const block of extract(src)) {
    if (!looksLikeDocument(block.doc)) continue;
    const r = rewrite(block.doc, groups);
    if (r.error || r.text === block.doc) continue;
    for (const [rule, n] of Object.entries(r.counts)) counts[rule] = (counts[rule] || 0) + n;
    patches.push({ start: block.start, end: block.end, text: block.render(r.text) });
  }

  let text = src;
  for (let k = patches.length - 1; k >= 0; k -= 1) {
    const q = patches[k];
    text = text.slice(0, q.start) + q.text + text.slice(q.end);
  }
  return { text, counts, error: null };
}

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

const DEFAULT_TARGETS = ['examples'];

/// Directories the walk never descends into. `node_modules` matters more than
/// it looks: `examples/vite-gallery/node_modules/pngine/schema/pngine.sjon` is
/// an installed copy of the SCHEMA, and rewriting a schema with a document
/// codemod is exactly the kind of silent damage this script must not do.
const SKIP_DIRS = new Set(['node_modules', '.git', 'zig-out', '.zig-cache', 'dist']);

/// Files whose SJON is HISTORY, not source. `docs/journal.md` is append-only by
/// construction and records what each cut looked like at the time; `docs/plans/`
/// argues from the old spelling TO the new one, so rewriting it would delete the
/// argument. Both are prose about documents, not documents.
/// `docs/new-interpreter.md` is the third kind: a HISTORICAL design document for
/// PBSF, the retired bootstrap frontend, whose `(vertex $shd:0 (entry "vs"))`
/// parses as SJON and matches a rule head while meaning something else entirely.
/// It says so in its own header — "do not treat the syntax examples as current"
/// — which is exactly the sentence a codemod cannot read.
const SKIP_PATHS = ['docs/journal.md', 'docs/plans/', 'CHANGELOG.md', 'docs/new-interpreter.md'];

/// Host file types that may CONTAIN a document (07 §1.2/§1.3), rewritten through
/// `rewriteEmbedded` rather than whole-file.
const EMBED_EXTS = new Set(Object.keys(EXTRACTORS));

function collect(paths) {
  const out = [];
  // A named path that is not there is SKIPPED, not fatal: `zig build drift`
  // runs this over the same list in a release clone, where `.mirrorignore`
  // strips CLAUDE.md and docs/journal.md. Only an explicitly named path can be
  // missing — the walk below never invents one.
  const stack = paths.filter((p) => existsSync(p));
  while (stack.length) {
    const p = stack.pop();
    const st = statSync(p);
    if (st.isDirectory()) {
      for (const name of readdirSync(p)) {
        if (SKIP_DIRS.has(name)) continue;
        stack.push(join(p, name));
      }
    } else if (extname(p) === '.sjon' || EMBED_EXTS.has(extname(p))) {
      if (!SKIP_PATHS.some((skip) => p.includes(skip))) out.push(p);
    }
  }
  return out.sort();
}

/// Heads plan 03 RETIRED as forms — every one is a key now (`:layout`,
/// `:module`, `:topology`, `:vertex-buffers`, and the `(target …)` list that
/// `(targets …)` used to wrap). The corpus check above proves no DOCUMENT still
/// writes them; this proves the SCHEMA cannot accept them again, which is the
/// half a document scan can never reach. Skipped when the schema is absent (a
/// consumer running this script over its own corpus).
///
/// `entry` is deliberately NOT here: a global `(entry …)` form exists as the
/// head-resolution dummy the bind-group hooks need, filed upstream as S12.
const RETIRED_FORM_HEADS = ['layout', 'module', 'topology', 'buffers', 'targets'];
const SCHEMA_PATH = 'schema/pngine.sjon';

function checkSchemaShape() {
  if (!existsSync(SCHEMA_PATH)) return [];
  const src = readFileSync(SCHEMA_PATH, 'utf8');
  const declared = new Set();
  for (const m of src.matchAll(/\(form\s+:name\s+([\w-]+)/g)) declared.add(m[1]);
  return RETIRED_FORM_HEADS.filter((h) => declared.has(h)).map((h) => `(form :name ${h} …) in ${SCHEMA_PATH}`);
}

function main(argv) {
  const check = argv.includes('--check');
  const dry = argv.includes('--dry-run');
  // `--group X` (repeatable) runs one cut's rewrites only. Absent = every
  // group, which is correct only once every schema cut has landed.
  const groups = [];
  for (let k = 0; k < argv.length; k += 1) {
    if (argv[k] !== '--group') continue;
    const g = argv[k + 1];
    if (!GROUPS.includes(g)) {
      console.error(`unknown --group ${g}; known: ${GROUPS.join(', ')}`);
      return 2;
    }
    groups.push(g);
  }
  const paths = argv.filter((a, k) => !a.startsWith('--') && argv[k - 1] !== '--group');
  const files = collect(paths.length ? paths : DEFAULT_TARGETS);

  const totals = Object.create(null);
  const changed = [];
  const failed = [];

  for (const file of files) {
    const src = readFileSync(file, 'utf8');
    const g = groups.length ? groups : GROUPS;
    const r = extname(file) === '.sjon' ? rewrite(src, g) : rewriteEmbedded(src, extname(file), g);
    if (r.error) {
      failed.push(`${file}: ${r.error}`);
      continue;
    }
    for (const [rule, n] of Object.entries(r.counts)) totals[rule] = (totals[rule] || 0) + n;
    if (r.text === src) continue;
    changed.push(file);
    if (!check && !dry) writeFileSync(file, r.text);
  }

  for (const rule of Object.keys(totals).sort()) console.log(`  ${String(totals[rule]).padStart(5)}  ${rule}`);
  console.log(`${changed.length} of ${files.length} file(s) ${check || dry ? 'would change' : 'rewritten'}`);

  if (failed.length) {
    console.error(`\n${failed.length} file(s) could not be parsed:`);
    for (const f of failed) console.error(`  ${f}`);
    return 2;
  }
  if (check) {
    const shape = checkSchemaShape();
    if (shape.length) {
      console.error('\n--check: the schema declares a form the overhaul retired:');
      for (const f of shape) console.error(`  ${f}`);
      return 1;
    }
  }

  if (check && changed.length) {
    console.error('\n--check: the corpus still carries pre-overhaul spellings:');
    for (const f of changed) console.error(`  ${f}`);
    return 1;
  }
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main(process.argv.slice(2)));
