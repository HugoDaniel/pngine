/**
 * Reading `schema/pngine.sjon` as text, for the gates that hold it to something.
 *
 * Two gates now scan the schema — `tests/npm/webgpu-conformance.test.js`
 * (half A, the WebGPU mirror) and `scripts/check-sugar-ledger.mjs` (half B, the
 * forms pngine invented) — and the scanner has a bug history worth not
 * repeating twice. It lives here so there is one of it.
 *
 * Beside the schema rather than under `tests/` for the reason
 * `webgpu-mapping.mjs` is: the release cut strips `tests/`, and one of the two
 * callers is a `scripts/` gate that ships.
 */

/**
 * The text of one `(form :name NAME …)` block, plus the column it starts at.
 *
 * `indentPattern` scopes the search: top-level forms sit at exactly two spaces,
 * and a slot-local form nested inside another is found with `' +'`.
 *
 * Returns null when the form is absent — callers decide whether that is an
 * error, because one of them is a gate whose whole job is to notice.
 */
export function formSlice(src, name, indentPattern = " {2}") {
  // `\b` is NOT enough to end a form name: kebab-case makes `-` a word
  // boundary, so `compute` matched `(form :name compute-pipeline` — the first
  // one in the file — and read ITS keys. Silent for as long as no form name was
  // a prefix of another; the `(compute …)` stage made one.
  const re = new RegExp(`^(${indentPattern})\\(form :name ${name}(?=[\\s)])`, "m");
  const m = src.match(re);
  if (!m) return null;
  const depth = m[1].length;
  const rest = src.slice(m.index + m[0].length);
  const end = rest.search(new RegExp(`\\n {0,${depth}}\\((?:form|value-kind) :name `));
  return { block: end < 0 ? rest : rest.slice(0, end), indent: depth };
}

/**
 * Every `(key :name …)` line of a form block, WITH the keys a `(variant …)`
 * adds.
 *
 * A discriminated form declares its conditional keys one level deeper —
 * `(variant :when clear (key :name clear-value …))` — so a column-exact scan
 * loses them the moment a key moves into a variant, and the member reads as one
 * PNGine does not spell. That is silent in the direction that matters: a gate
 * would go green on a schema that stopped declaring something. Hence the
 * descent, which is deliberately ONE level (variants do not nest) and anchored
 * on the variant's own column.
 *
 * `each` receives the line's match: [, indent, name, rest-of-line].
 */
export function keyLines(block, depth, each) {
  let inVariant = false;
  for (const line of block.split("\n")) {
    const opener = line.match(/^( *)\((variant|form) /);
    if (opener && opener[1].length === depth + 2) {
      inVariant = opener[2] === "variant";
      continue;
    }
    const m = line.match(/^( *)\(key :name ([^\s)]+)(.*)$/);
    if (!m) continue;
    const col = m[1].length;
    if (col === depth + 2) {
      inVariant = false;
      each(m);
    } else if (inVariant && col === depth + 4) {
      each(m);
    }
  }
}
