#!/usr/bin/env node

/**
 * Drift gate: every long flag documented in a CLAUDE.md options table must
 * exist in the corresponding `src/cli/*.zig` parser.
 *
 * `zig build drift` had ten gates and not one of them read CLAUDE.md's CLI
 * tables, so the Compile Options table documented `--no-executor` — a flag
 * `compile` has never had, spelled `--embed-executor` there and inverted in
 * default — for as long as anyone had looked. It was found the way users find
 * it: by copying the documented flag and getting `Unknown option`.
 *
 * Deliberately narrow. This checks flag EXISTENCE and nothing else, because
 * existence is the part a machine can verify without guessing. Help-text prose,
 * default values and percentage claims are not gated: they need a human, and a
 * gate that pretends otherwise produces a decoration (the same limit r2-05
 * recorded for the sjon-reference gate).
 *
 * Short flags are not checked either — `-m` appears in far too many contexts to
 * match a literal against, and every short flag in these tables is documented
 * beside its long spelling anyway.
 *
 * Usage: node scripts/check-cli-flags.mjs [--check]   # exit 1 on drift
 */

import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const CLAUDE_MD = path.join(ROOT, "CLAUDE.md");

// CLAUDE.md is listed in `.mirrorignore`, so a release clone has no input to
// check against — and a release clone still runs `zig build test`, which
// depends on `drift`. Skip, like the journal/bundle/sjon-reference gates do.
if (!existsSync(CLAUDE_MD)) {
  console.log("check-cli-flags: CLAUDE.md absent — skipping (stripped by .mirrorignore in a release clone).");
  process.exit(0);
}

/** CLAUDE.md table heading → the parser that must accept its flags. */
const TABLES = {
  "Render Options": "src/cli/render.zig",
  "Validate Options": "src/cli/validate.zig",
  "Inspect Options": "src/cli/inspect.zig",
  "Compile Options": "src/cli/compile.zig",
};

const claude = readFileSync(CLAUDE_MD, "utf8");
const lines = claude.split("\n");

/** Collect the `| ... |` rows under a `### <heading>` until the next heading. */
function tableRows(heading) {
  const start = lines.findIndex((l) => l.trim() === `### ${heading}`);
  if (start === -1) return null;
  const rows = [];
  for (let i = start + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith("## ")) break;
    if (line.startsWith("### ")) break;
    if (line.trim().startsWith("|")) rows.push(line);
  }
  return rows;
}

let failures = 0;
let checked = 0;

for (const [heading, relPath] of Object.entries(TABLES)) {
  const rows = tableRows(heading);
  if (rows === null) {
    console.error(`check-cli-flags: FAIL — CLAUDE.md has no "### ${heading}" section`);
    failures++;
    continue;
  }
  // A table that parses to zero flags is a broken gate, not a passing one:
  // renaming a heading would otherwise silently stop checking that command.
  const flags = new Set();
  for (const row of rows) {
    const firstCell = row.split("|")[1] ?? "";
    for (const m of firstCell.matchAll(/--[a-z0-9][a-z0-9-]*/g)) flags.add(m[0]);
  }
  if (flags.size === 0) {
    console.error(`check-cli-flags: FAIL — "${heading}" table parsed to zero long flags`);
    failures++;
    continue;
  }

  const source = readFileSync(path.join(ROOT, relPath), "utf8");
  for (const flag of [...flags].sort()) {
    checked++;
    // The parser spells every flag as a quoted literal, whether it uses a
    // manual eql chain (compile.zig) or the arg_reader spec table (render.zig).
    if (!source.includes(`"${flag}"`)) {
      console.error(
        `check-cli-flags: FAIL — CLAUDE.md "${heading}" documents ${flag}, ` +
          `but ${relPath} has no such flag`,
      );
      failures++;
    }
  }
}

if (failures > 0) {
  console.error(`check-cli-flags: ${failures} drift(s) across ${checked} documented flag(s).`);
  process.exit(1);
}
console.log(`check-cli-flags: ok (${checked} documented flags across ${Object.keys(TABLES).length} tables)`);
