#!/usr/bin/env node

/**
 * Drift gate: docs/payload-kinds.md <- src/payload/envelope.zig's v1_kinds
 * (checkpoint 02.C1, the registry freeze).
 *
 * The kind registry is the family's collision guarantee: "the tags are
 * reserved now so no two sets pick the same four bytes". A registry that
 * lives only in prose drifts the way every other ungated document here did
 * (see the sjon-reference and cli-flags gates for the two nearest
 * precedents), and a registry that lives only in the source has no face a
 * human can read or an owner can file against. So the doc is the face, the
 * Zig table is the anchor, and this gate is the weld.
 *
 * What it asserts:
 *   - the tag SET is identical on both sides (missing and extra rows are
 *     both drift)
 *   - each tag's Status (registered|reserved) and Owner agree
 *   - no lowercase-initial tag is ever listed (private tags are never
 *     registered, never claimed)
 *   - both sides parse to a non-empty inventory (strict about its own
 *     inputs, like check-npm-metadata: a regex that silently matches
 *     nothing would turn this gate into a no-op)
 *
 * Bodies, handlers and legacy carriers are deliberately NOT compared: they
 * are prose the document carries alone.
 *
 * Usage:
 *   node scripts/check-payload-kinds.mjs --check              # the gate
 *   node scripts/check-payload-kinds.mjs --check --doc A --src B
 *       # compare scratch copies (used to demonstrate the failure mode
 *       # without mutating the tree)
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_DOC = path.join(ROOT, "docs/payload-kinds.md");
const DEFAULT_SRC = path.join(ROOT, "src/payload/envelope.zig");

function fail(msg) {
  console.error(`check-payload-kinds: ${msg}`);
  process.exit(1);
}

// --check is the only mode; the gate never rewrites anything.
const argv = process.argv.slice(2);
if (!argv.includes("--check")) fail("run with --check (there is no regen: the doc is hand-written prose)");
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const DOC_PATH = opt("--doc", DEFAULT_DOC);
const SRC_PATH = opt("--src", DEFAULT_SRC);

// One v1_kinds row in the Zig source:
//   .{ .tag = tagOf("PNGB"), .owner = "pngine", .status = .registered }, // 02:45
function parseSource(text) {
  const rows = new Map();
  const entry =
    /\.\{\s*\.tag\s*=\s*tagOf\("([A-Za-z0-9]{4})"\)\s*,\s*\.owner\s*=\s*"([^"]*)"\s*,\s*\.status\s*=\s*\.(registered|reserved)\s*,?\s*\}/g;
  for (const m of text.matchAll(entry)) {
    const [, tag, owner, status] = m;
    if (rows.has(tag)) fail(`src lists tag ${tag} twice in v1_kinds`);
    rows.set(tag, { status, owner });
  }
  return rows;
}

// The inventory table: the one under "## The v1 inventory", rows shaped
// | `TAG` | status | owner | ... |.
function parseDoc(text) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => l.startsWith("## The v1 inventory"));
  if (start < 0) fail("docs/payload-kinds.md has no '## The v1 inventory' section");
  const rows = new Map();
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("## ")) break; // next section ends the table
    const m = line.match(/^\|\s*`([A-Za-z0-9]{4})`\s*\|/);
    if (!m) continue;
    const cells = line.split("|").map((c) => c.trim());
    // cells[0] is empty (leading |): [1] tag, [2] status, [3] owner.
    const tag = cells[1].replace(/`/g, "");
    const status = cells[2];
    const owner = cells[3];
    if (tag[0] >= "a" && tag[0] <= "z") {
      fail(`${DOC_PATH}: lists private lowercase-initial tag \`${tag}\` (never registered, never claimed)`);
    }
    if (status !== "registered" && status !== "reserved") {
      fail(`${DOC_PATH}: tag \`${tag}\` status must be registered|reserved, found ${JSON.stringify(status)}`);
    }
    if (!owner) fail(`${DOC_PATH}: tag \`${tag}\` has an empty Owner cell`);
    if (rows.has(tag)) fail(`${DOC_PATH}: lists tag \`${tag}\` twice`);
    rows.set(tag, { status, owner });
  }
  return rows;
}

const src = parseSource(readFileSync(SRC_PATH, "utf8"));
const doc = parseDoc(readFileSync(DOC_PATH, "utf8"));

if (src.size === 0) fail(`${SRC_PATH}: parsed 0 v1_kinds entries (regex rot? the gate refuses to pass on nothing)`);
if (doc.size === 0) fail(`${DOC_PATH}: parsed 0 inventory rows (table shape changed? the gate refuses to pass on nothing)`);

const problems = [];
for (const tag of [...src.keys()].sort()) {
  if (!doc.has(tag)) {
    problems.push(`tag \`${tag}\` is in src/payload/envelope.zig's v1_kinds but has no row in ${path.relative(ROOT, DOC_PATH)}`);
    continue;
  }
  if (doc.get(tag).status !== src.get(tag).status) {
    problems.push(`tag \`${tag}\`: doc says ${doc.get(tag).status}, source says ${src.get(tag).status}`);
  }
  if (doc.get(tag).owner !== src.get(tag).owner) {
    problems.push(`tag \`${tag}\`: doc owner is ${JSON.stringify(doc.get(tag).owner)}, source says ${JSON.stringify(src.get(tag).owner)}`);
  }
}
for (const tag of [...doc.keys()].sort()) {
  if (!src.has(tag)) {
    problems.push(`tag \`${tag}\` has a row in ${path.relative(ROOT, DOC_PATH)} but is absent from src/payload/envelope.zig's v1_kinds`);
  }
}

if (problems.length > 0) {
  console.error("check-payload-kinds: docs/payload-kinds.md and src/payload/envelope.zig disagree:");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}

console.log(
  `check-payload-kinds: ${src.size} kinds agree between docs/payload-kinds.md and src/payload/envelope.zig`,
);
