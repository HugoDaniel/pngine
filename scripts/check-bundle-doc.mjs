#!/usr/bin/env node

/**
 * Drift gate: the bundle set, as told by the bundler, the two docs, and the
 * package's own `exports` map.
 *
 * `scripts/bundle.cjs` emits six profile bundles and knows their names in
 * `SIZE_BUDGETS`. Three other places restate that set, and every one of them
 * had rotted:
 *
 *   - `docs/publishing.md` documented `browser.mjs`, an output the bundler's
 *     cleanup array DELETES, and missed the whole player-profile split.
 *   - `npm/pngine/README.md` (the PUBLISHED one) listed `index.js`, renamed to
 *     `index.cjs` two refactors earlier.
 *   - `package.json` had no `exports` subpath for `mini-no-audio.mjs`, so a
 *     bundle that was built, budgeted, published and documented in the README
 *     resolved to ERR_PACKAGE_PATH_NOT_EXPORTED for four months.
 *
 * That last one is why the `exports` check is here and not just the doc checks:
 * a dist listing, a size table and a README row all claimed it shipped, and
 * none of them is a resolution test. `exports` is the package's real surface.
 *
 * `dist/` is gitignored, so this cannot diff against built artifacts without
 * requiring a bundler run. Everything it compares is committed.
 *
 * Deliberately strict about its own inputs: parsing zero budgets, or finding no
 * marked table, is an ERROR. A drift check that silently matches nothing reads
 * green over nothing at all (CONTRIBUTING pitfall 43).
 *
 * Usage: node scripts/check-bundle-doc.mjs [--check]   # exit 1 on drift
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BUNDLER = path.join(ROOT, "npm/pngine/scripts/bundle.cjs");
const PKG = path.join(ROOT, "npm/pngine/package.json");
const MARKER = "<!-- BUNDLE-TABLE:";

/**
 * Docs carrying a marked bundle table. `budgets` = does it restate the gate
 * value? `optional` = the release mirror strips it (`.mirrorignore` drops
 * `docs/`), so a public clone must still be able to run `zig build drift`.
 */
const DOCS = [
  { file: "docs/publishing.md", budgets: true, optional: true },
  { file: "npm/pngine/README.md", budgets: false, optional: false },
];

function fail(msg) {
  console.error(`check-bundle-doc: ${msg}`);
  process.exit(1);
}

/** `SIZE_BUDGETS` from the bundler: Map<'viewer.mjs', 49700>. */
function budgetsFromBundler(src) {
  const block = src.match(/const SIZE_BUDGETS = \{([\s\S]*?)\n {2}\};/);
  if (!block) fail("bundle.cjs: no `const SIZE_BUDGETS = {` block found — did the bundler's shape change?");
  const out = new Map();
  for (const m of block[1].matchAll(/^\s*'([\w.-]+\.mjs)':\s*(\d+),/gm)) out.set(m[1], Number(m[2]));
  if (out.size === 0) fail("bundle.cjs: SIZE_BUDGETS parsed to zero entries — the regex has drifted from the source");
  return out;
}

/** The marked table in a doc: Map<'viewer.mjs', budget|null>. */
function rowsFromDoc(src, file) {
  const at = src.indexOf(MARKER);
  if (at < 0) fail(`${file}: no \`${MARKER}\` marker — the bundle table cannot be located`);
  const out = new Map();
  for (const line of src.slice(at).split("\n")) {
    // Stop at the first non-table line after the table; skip header + separator.
    if (out.size > 0 && !line.startsWith("|")) break;
    if (!line.startsWith("|")) continue;
    const cells = line.split("|").map((c) => c.trim());
    const name = cells[1]?.match(/^`([\w.-]+\.mjs)`$/)?.[1];
    if (!name) continue;
    const budget = cells.at(-2)?.match(/^(\d+)$/)?.[1];
    out.set(name, budget === undefined ? null : Number(budget));
  }
  if (out.size === 0) fail(`${file}: the marked table has no \`<name>.mjs\` rows`);
  return out;
}

/** Every dist file any `exports` condition points at. */
function exportedFiles(pkg) {
  const out = new Set();
  const walk = (node) => {
    if (typeof node === "string") out.add(path.basename(node));
    else if (node && typeof node === "object") Object.values(node).forEach(walk);
  };
  walk(pkg.exports ?? fail("package.json: no `exports` map"));
  return out;
}

const budgets = budgetsFromBundler(readFileSync(BUNDLER, "utf8"));
const exported = exportedFiles(JSON.parse(readFileSync(PKG, "utf8")));
const problems = [];

let checked = 0;

for (const { file, budgets: hasBudgets, optional } of DOCS) {
  const abs = path.join(ROOT, file);
  if (optional && !existsSync(abs)) {
    console.log(`check-bundle-doc: ${file} absent — skipping (stripped by .mirrorignore in a release clone).`);
    continue;
  }
  const rows = rowsFromDoc(readFileSync(abs, "utf8"), file);
  checked += 1;
  for (const [name, budget] of budgets) {
    if (!rows.has(name)) problems.push(`${file}: ${name} is emitted by bundle.cjs but absent from the table`);
    else if (hasBudgets && rows.get(name) !== budget) {
      problems.push(`${file}: ${name} budget is ${rows.get(name)}, bundle.cjs says ${budget}`);
    }
  }
  for (const name of rows.keys()) {
    if (!budgets.has(name)) problems.push(`${file}: ${name} is documented, but bundle.cjs budgets no such output`);
  }
}

// Skipping is per-doc and never total: with every table absent this would read
// green over nothing at all, which is the failure mode the whole check exists
// to prevent (CONTRIBUTING pitfall 43).
if (checked === 0) fail("every documented table was skipped — nothing was compared");

// The surface check: a bundle nothing exports cannot be imported, however many
// docs list it.
for (const name of budgets.keys()) {
  if (!exported.has(name)) {
    problems.push(`package.json: ${name} is built and documented but has no \`exports\` subpath — it would resolve to ERR_PACKAGE_PATH_NOT_EXPORTED`);
  }
}

if (problems.length > 0) {
  console.error("=== BUNDLE DRIFT ===");
  for (const p of problems) console.error(`  x ${p}`);
  console.error(
    "\nThe emitted bundle set, the two documented tables and package.json's\n" +
      "`exports` have diverged. The tables are hand-written prose, so there is no\n" +
      "--regen; each is marked with an HTML comment naming this check.",
  );
  process.exit(1);
}

console.log(`check-bundle-doc: ok (${budgets.size} bundles: budgets, ${checked} doc table(s), exports subpaths)`);
