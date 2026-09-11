#!/usr/bin/env node
/**
 * Drift gate: `schema/sugar-ledger.mjs` <-> the sugar tier of
 * `schema/pngine.sjon`.
 *
 * Half A of the schema — the WebGPU mirror — is held bidirectionally against
 * the gpuweb IDL snapshot by `tests/npm/webgpu-conformance.test.js`. Half B, the
 * forms pngine invented, had nothing. This is the sugar part of half B: the
 * forms a hook lowers, whose whole contract is that they expand into ordinary
 * core forms, which means a human could have written the result by hand.
 *
 * The check runs both ways, and the form set is DERIVED rather than listed:
 *
 *   1. Sugar forms are the ones declaring `:lowering`, plus everything reachable
 *      through their `:positional` sections that no hook `:produces` (a produced
 *      head is a core form the sugar forwards, not sugar of its own).
 *   2. Every derived form must be in the ledger, and every ledger form must be
 *      derived. A new sugar form fails until it is written down.
 *   3. Every key of every derived form must be in the ledger, and every ledger
 *      key must exist on that form in the schema.
 *   4. Every entry states exactly one of `twin` + `equivalence`, or `ledger`.
 *   5. Every `twin` names a file that exists.
 *   6. A slot-local form nested inside a sugar form may only NARROW its
 *      top-level namesake — never add a key the core form lacks. That is the
 *      shape a core capability would arrive in wearing a sugar spelling, and
 *      today no sugar form does it.
 *   7. Every `twin` is GATED: its basename must be a render row that is one
 *      HALF of a `twin_of` pair — either the row carries `twin_of` itself, or
 *      another row names it — and the pair's `twin_level` must be the level the
 *      ledger claims. Without this rule a `twin:` is an existence claim and
 *      nothing measures the equivalence it names, which is what the first twin
 *      was, and it had already drifted by the time it moved into the corpus
 *      (§425 stopped the hook emitting a dead last-pass texture; the twin still
 *      carried one).
 *
 *      Both directions count because the corpus grows both ways. A twin written
 *      FOR a sugar fixture carries `twin_of` (`pass_half_res_hand`). A core
 *      document the sugar was later derived FROM is named BY the sugar's row
 *      (`webgpu_shadow_mapping`, which `webgpu_shadow_mapping_graph` twins) —
 *      the pair is equally gated, and refusing it would only push someone to
 *      write a third copy of a document the corpus already holds.
 *   8. Every `twin` is written in CORE forms: no sugar head may appear in it.
 *      That is the half of "hand-written" a pixel compare cannot see — a twin
 *      that quietly used the very key it claims to prove would render
 *      identically and prove nothing. `zig build test-core` is the exact
 *      version of this check (it compiles every example with an EMPTY lowering
 *      registry), but it does not know which examples are twins, so a sugar
 *      twin would merely be counted on the sugar side. This rule names it.
 *
 * Rule 7 is why twins live in `examples/` rather than beside the plan that
 * introduced them: a render row embeds its source through `build.zig`, and
 * `docs/plans/` is stripped by the release cut. `examples/` ships, so the twin
 * is also swept by `test-core` — which is the OTHER half of the claim, and the
 * one nothing else could make. A twin asserts two things, "someone could have
 * written this by hand" and "it is the same program", and `test-core` proves
 * the first by compiling it byte-identically with an EMPTY lowering registry.
 *
 * The derivation is self-guarding: an accidentally empty closure fails rule 2
 * against a non-empty ledger rather than passing silently.
 *
 * Usage: node scripts/check-sugar-ledger.mjs [--check]
 * (`--check` is accepted for symmetry with the other drift gates; this one
 * never writes anything.)
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { formSlice, keyLines } from "../schema/schema-scan.mjs";
import { EQUIVALENCE_LEVELS, SUGAR_FORMS } from "../schema/sugar-ledger.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SJON = readFileSync(path.join(ROOT, "schema/pngine.sjon"), "utf8");

// The render corpus, for rule 7. `tests/` is stripped by the release cut, so an
// absent file skips that rule rather than failing it — the same treatment every
// other cut-aware gate gives its missing input.
const RENDER_TEST = path.join(ROOT, "tests/zig/render/render_test.zig");
const RENDER_SRC = existsSync(RENDER_TEST) ? readFileSync(RENDER_TEST, "utf8") : null;

/** The render row named `label`, as its single source line, or null. */
function renderRow(label) {
  if (RENDER_SRC === null) return null;
  for (const line of RENDER_SRC.split("\n"))
    if (line.includes(`.label = "${label}"`)) return line;
  return null;
}

/** The row that names `label` as ITS twin, or null. */
function rowTwinning(label) {
  if (RENDER_SRC === null) return null;
  for (const line of RENDER_SRC.split("\n"))
    if (line.includes(`.twin_of = "${label}"`)) return line;
  return null;
}

/** `.twin_level` of a row line, defaulted the way the Zig struct defaults it. */
const levelOf = (row) => (row.includes(".twin_level = .byte") ? "byte" : "pixel");

/** A `.sjon` source with its `"""…"""` blocks and `;` comments removed, so a
 *  head named in prose or inside WGSL is not mistaken for a form. */
function coreText(src) {
  return src.replace(/"""[\s\S]*?"""/g, "").replace(/;[^\n]*/g, "");
}

const errors = [];
const fail = (msg) => errors.push(msg);

// --- read the schema -------------------------------------------------------

/** `value-kind :name X :underlying form` -> its head names. Both head-set
 *  spellings occur: `:names [a b]` and `(head :name a)` children. */
function valueKindHeads() {
  const out = new Map();
  for (const m of SJON.matchAll(/\(value-kind :name ([a-z0-9-]+) :underlying form :heads \(head-set([\s\S]*?)\)\)/g)) {
    const names = /:names \[([^\]]*)\]/.exec(m[2]);
    out.set(m[1], names
      ? names[1].trim().split(/\s+/)
      : [...m[2].matchAll(/\(head :name ([a-z0-9-]+)/g)].map((h) => h[1]));
  }
  return out;
}

/** Every form's block, by name, first occurrence at any nesting depth. */
function formBlocks() {
  const out = new Map();
  for (const m of SJON.matchAll(/^( *)\(form :name ([a-z0-9-]+)/gm)) {
    if (out.has(m[2])) continue;
    const rest = SJON.slice(m.index + m[0].length);
    const end = rest.search(new RegExp(`\\n {0,${m[1].length}}\\((?:form|value-kind) :name `));
    out.set(m[2], { indent: m[1].length, block: end < 0 ? rest : rest.slice(0, end) });
  }
  return out;
}

const VK = valueKindHeads();
const FORMS = formBlocks();

const hookOf = (n) => /:lowering \(lowering :hook ([a-z0-9/-]+)/.exec(FORMS.get(n)?.block ?? "")?.[1] ?? null;
const positionalOf = (n) => /:positional ([a-z0-9-]+)/.exec(FORMS.get(n)?.block ?? "")?.[1] ?? null;

function keysOf(block, indent) {
  const out = [];
  keyLines(block, indent, (m) => out.push(m[2]));
  return out;
}

/** The sugar tier, derived: lowering roots + their positional closure, minus
 *  every head some hook produces. */
function sugarForms() {
  const roots = [...FORMS.keys()].filter(hookOf);
  const produced = new Set();
  for (const r of roots)
    for (const p of /:produces \[([\s\S]*?)\]/.exec(FORMS.get(r).block)?.[1].trim().split(/\s+/) ?? [])
      produced.add(p);

  const seen = new Set();
  const queue = [...roots];
  for (let guard = 0; guard < 1000 && queue.length; guard++) {
    const n = queue.shift();
    if (seen.has(n)) continue;
    seen.add(n);
    const section = positionalOf(n);
    if (!section) continue;
    for (const head of VK.get(section) ?? []) if (!produced.has(head)) queue.push(head);
  }
  return seen;
}

// --- the checks ------------------------------------------------------------

const derived = sugarForms();
const ledgered = new Set(Object.keys(SUGAR_FORMS));

for (const f of derived)
  if (!ledgered.has(f))
    fail(`schema declares sugar form '(${f} …)' and schema/sugar-ledger.mjs does not name it — add it, with a desugars_to per key`);
for (const f of ledgered)
  if (!derived.has(f))
    fail(`schema/sugar-ledger.mjs names '(${f} …)' and it is not a sugar form of the schema — a hook stopped consuming it, or it was renamed`);

for (const f of [...derived].filter((f) => ledgered.has(f)).sort()) {
  const entry = SUGAR_FORMS[f];
  const { block, indent } = FORMS.get(f);

  const hook = hookOf(f);
  if (hook !== (entry.hook ?? null))
    fail(`'(${f} …)': schema hook ${hook ?? "(none)"} vs ledger ${entry.hook ?? "(none)"}`);

  const schemaKeys = new Set(keysOf(block, indent));
  const ledgerKeys = new Set(Object.keys(entry.keys));
  for (const k of schemaKeys)
    if (!ledgerKeys.has(k))
      fail(`'(${f} … :${k} …)' is in the schema and not in the ledger — say what it desugars to, and either name a twin or write down that there is none`);
  for (const k of ledgerKeys)
    if (!schemaKeys.has(k))
      fail(`the ledger names '(${f} … :${k} …)' and the schema does not declare it`);

  for (const [k, e] of Object.entries(entry.keys)) {
    const at = `'(${f} … :${k} …)'`;
    if (!e.desugars_to) fail(`${at}: no desugars_to`);
    if (e.twin && e.ledger) fail(`${at}: claims a twin AND a ledger line — a key is proven or it is not`);
    if (!e.twin && !e.ledger) fail(`${at}: neither a twin nor a ledger line`);
    if (e.twin) {
      if (!EQUIVALENCE_LEVELS.includes(e.equivalence))
        fail(`${at}: equivalence '${e.equivalence}' is not one of ${EQUIVALENCE_LEVELS.join(", ")}`);
      // Twins live in `examples/`, which ships, so this one never skips.
      if (!existsSync(path.join(ROOT, e.twin)))
        fail(`${at}: twin '${e.twin}' does not exist`);

      // Rule 7: the twin is gated, not merely present — either half of a pair.
      const label = path.basename(e.twin, ".sjon");
      if (RENDER_SRC !== null) {
        const own = renderRow(label);
        const paired = own && own.includes(".twin_of =") ? own : rowTwinning(label);
        if (own === null) {
          fail(`${at}: twin '${e.twin}' is not a row in tests/zig/render/render_test.zig — a twin nothing renders is an existence claim, not a measured equivalence (add \`.{ .label = "${label}", … .twin_of = "<the sugar row>" }\`)`);
        } else if (paired === null) {
          fail(`${at}: render row '${label}' is in no \`twin_of\` pair — nothing holds it against the document it twins, in either direction`);
        } else if (levelOf(paired) !== e.equivalence) {
          fail(`${at}: the ledger claims '${e.equivalence}' and the render pair gates '${levelOf(paired)}' — the two files must mean the same thing by the same word`);
        }
      }

      // Rule 8: a twin is written in core forms, or it proves nothing.
      const twinSrc = existsSync(path.join(ROOT, e.twin)) ? coreText(readFileSync(path.join(ROOT, e.twin), "utf8")) : "";
      for (const head of derived)
        if (new RegExp(`\\(\\s*${head}[\\s)]`).test(twinSrc))
          fail(`${at}: twin '${e.twin}' contains a \`(${head} …)\` — a twin written with the sugar it claims to expand renders identically and proves nothing`);
    } else if (e.equivalence) {
      fail(`${at}: states an equivalence without a twin to have measured it on`);
    }
  }

  // Rule 6: a slot-local form may narrow its core namesake, never widen it.
  for (const m of block.matchAll(/^ *\(form :name ([a-z0-9-]+)/gm)) {
    const nested = formSlice(block, m[1], " +");
    const core = FORMS.get(m[1]);
    if (!nested || !core || core.block === nested.block) continue;
    for (const k of keysOf(nested.block, nested.indent))
      if (!keysOf(core.block, core.indent).includes(k))
        fail(`'(${f} … (${m[1]} … :${k} …))' is a key the top-level '(${m[1]} …)' does not have — a sugar form may narrow a core form, never widen it`);
  }
}

// --- report ----------------------------------------------------------------

if (errors.length) {
  console.error("check-sugar-ledger: FAILED");
  for (const e of errors) console.error(`  ${e}`);
  process.exit(1);
}

const keyCount = Object.values(SUGAR_FORMS).reduce((n, f) => n + Object.keys(f.keys).length, 0);
const twinned = Object.values(SUGAR_FORMS).flatMap((f) => Object.values(f.keys)).filter((e) => e.twin).length;
console.log(
  `check-sugar-ledger: OK — ${derived.size} sugar form(s), ${keyCount} key(s), ` +
    `${twinned} with a hand-written twin and ${keyCount - twinned} still on the ledger.`,
);
