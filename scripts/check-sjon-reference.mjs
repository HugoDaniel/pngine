#!/usr/bin/env node

/**
 * Drift gate: `docs/sjon-reference.md` against `schema/pngine.sjon`.
 *
 * The schema is the declared single source of truth for what a `.sjon` document
 * may contain; the reference is the only place a human is told. Nothing compared
 * them, and the reference had drifted to missing 15 of 67 forms outright —
 * including the whole depth/stencil group, render bundles, query sets and the
 * three copy operations — plus keys on forms it does document (r2-05, §334).
 * That is pitfall 43's lesson applied to the doc that matters most: prose that
 * describes a build is an artifact, and the fix is the gate, not the rewrite.
 *
 * WHAT IT CHECKS
 *   - every `(form :name X …)` in the schema appears in the reference as a form
 *     head, `(X` followed by whitespace or `)`;
 *   - every `(key :name K …)` appears as `:K`.
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK
 *   `(value-kind :name …)`. Those are the schema's INTERNAL type vocabulary —
 *   `bgl-entry-item`, `float-list`, `pool-size` — and 102 of the 116 do not
 *   appear in the reference for the good reason that an authoring guide should
 *   never name them. Gating them would force 102 fabricated mentions and make
 *   the reference worse. The plan that proposed this gate asked for them; the
 *   census is why it does not (§334). A value-kind's authoring surface is its
 *   MEMBERS, which reach the reader through the keys that carry them.
 *
 * Deliberately strict about its own inputs: parsing zero forms or zero keys is
 * an ERROR, not a pass. A drift check that silently matches nothing reads green
 * over nothing at all (pitfall 43).
 *
 * Usage: node scripts/check-sjon-reference.mjs [--check]   # exit 1 on drift
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SCHEMA = path.join(ROOT, "schema/pngine.sjon");
const REFERENCE = path.join(ROOT, "docs/sjon-reference.md");

/**
 * Forms whose KEYS the reference documents by rule rather than by enumeration.
 * Each entry must say WHY, because the exemption is the part of a gate most
 * likely to be widened later for the wrong reason. The form itself is still
 * required to appear.
 */
const KEY_EXEMPT = {
  limits:
    "all 35 keys are GPUSupportedLimits names in kebab-case; the reference " +
    "documents the naming rule plus worked examples, and spelling out 35 limit " +
    "names would be a worse document, not a more complete one",
};

// --- schema scanner ---------------------------------------------------------
// Tokenize to `(`, `)` and atoms, with `;` comments and double-quoted strings
// removed first. Strings matter: descriptions contain parens ("Positional
// (stencil-front …)/(stencil-back …) carry per-face stencil state.") and would
// corrupt depth tracking, and they span lines, so a line-wise strip is not
// enough.
function tokenize(text) {
  const out = [];
  let i = 0;
  let atom = "";
  const flush = () => {
    if (atom) {
      out.push(atom);
      atom = "";
    }
  };
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      flush();
      i++;
      while (i < text.length && text[i] !== '"') i += text[i] === "\\" ? 2 : 1;
      i++;
      continue;
    }
    if (ch === ";") {
      flush();
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (ch === "(" || ch === ")") {
      flush();
      out.push(ch);
      i++;
      continue;
    }
    if (/\s|\[|\]/.test(ch)) {
      flush();
      i++;
      continue;
    }
    atom += ch;
    i++;
  }
  flush();
  return out;
}

/** Walk the token stream, attributing each `(key :name K)` to its enclosing form. */
function parseSchema(text) {
  const toks = tokenize(text);
  const forms = new Map(); // name -> Set(keys)
  const open = []; // { depth, name } for forms currently enclosing us
  let depth = 0;

  for (let i = 0; i < toks.length; i++) {
    const t = toks[i];
    if (t === "(") {
      depth++;
      if (toks[i + 1] === "form" && toks[i + 2] === ":name" && toks[i + 3]) {
        const name = toks[i + 3];
        open.push({ depth, name });
        if (!forms.has(name)) forms.set(name, new Set());
      } else if (toks[i + 1] === "key" && toks[i + 2] === ":name" && toks[i + 3]) {
        const owner = open[open.length - 1];
        if (owner) forms.get(owner.name).add(toks[i + 3]);
      }
    } else if (t === ")") {
      while (open.length && open[open.length - 1].depth >= depth) open.pop();
      depth--;
    }
  }
  return forms;
}

// --- reference matchers -----------------------------------------------------
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const hasForm = (ref, name) => new RegExp(`\\(${esc(name)}(?=[\\s)\\n])`).test(ref);
const hasKey = (ref, key) => new RegExp(`(?<![a-z0-9-]):${esc(key)}(?![a-z0-9-])`).test(ref);

// --- main -------------------------------------------------------------------
// `.mirrorignore` strips docs/, and `zig build test` depends on `drift`, so a
// release clone must not fail its own suite over a file it was never meant to
// carry. The SCHEMA is not stripped — a missing one is a real error, handled by
// readFileSync throwing.
if (!existsSync(REFERENCE)) {
  console.log(
    `check-sjon-reference: ${path.relative(ROOT, REFERENCE)} absent — skipping ` +
      `(stripped by .mirrorignore in a release clone).`,
  );
  process.exit(0);
}

const schemaText = readFileSync(SCHEMA, "utf8");
const refText = readFileSync(REFERENCE, "utf8");
const forms = parseSchema(schemaText);

const keyCount = [...forms.values()].reduce((n, s) => n + s.size, 0);
if (forms.size === 0 || keyCount === 0) {
  console.error(
    `check-sjon-reference: parsed ${forms.size} forms / ${keyCount} keys from ` +
      `${path.relative(ROOT, SCHEMA)} — the scanner is broken, not the docs.`,
  );
  process.exit(2);
}

const missingForms = [];
const missingKeys = [];
for (const [name, keys] of [...forms].sort()) {
  if (!hasForm(refText, name)) missingForms.push(name);
  if (KEY_EXEMPT[name]) continue;
  for (const key of [...keys].sort()) {
    if (!hasKey(refText, key)) missingKeys.push(`${name} :${key}`);
  }
}

const exemptKeys = Object.keys(KEY_EXEMPT).reduce(
  (n, f) => n + (forms.get(f)?.size ?? 0),
  0,
);

if (missingForms.length === 0 && missingKeys.length === 0) {
  console.log(
    `check-sjon-reference: OK — ${forms.size} forms and ${keyCount - exemptKeys} keys ` +
      `documented (${exemptKeys} keys exempt by rule).`,
  );
  process.exit(0);
}

console.error(
  `check-sjon-reference: docs/sjon-reference.md has drifted from schema/pngine.sjon.\n`,
);
if (missingForms.length) {
  console.error(`  ${missingForms.length} form(s) never appear as \`(name …)\`:`);
  for (const f of missingForms) console.error(`    (${f} …)`);
  console.error("");
}
if (missingKeys.length) {
  console.error(`  ${missingKeys.length} key(s) never appear as \`:key\`:`);
  for (const k of missingKeys) console.error(`    ${k}`);
  console.error("");
}
console.error(
  `  Document them in docs/sjon-reference.md, or — if a form's keys are\n` +
    `  genuinely better documented by rule than by enumeration — add it to\n` +
    `  KEY_EXEMPT in this script WITH the reason.`,
);
process.exit(1);
