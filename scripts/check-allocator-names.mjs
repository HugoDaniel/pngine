#!/usr/bin/env node

/**
 * Drift gate: one name for the allocator, one spelling for its type.
 *
 * The tree grew three names for the same parameter (`gpa` in the newest code,
 * `allocator` in the oldest, `alloc` in `src/reflect/`) and two spellings of
 * `std.mem.Allocator`, because nothing enforced either. R3-05 unified them;
 * this keeps them unified, the same move `check-cli-flags.mjs` made for flags.
 *
 * Two rules, both mechanical:
 *
 *   1. A binding of type `Allocator` — parameter, struct field, or local — is
 *      named `gpa` or `arena`. Never `allocator`, never `alloc`.
 *   2. The type is spelled through the file-local `const Allocator =
 *      std.mem.Allocator` alias, not written out.
 *
 * Deliberately narrow, and deliberately lexical. It reads Zig the way the
 * rename did — skipping comments, string literals, multiline strings and char
 * literals — so an English sentence about "the caller's allocator" is not a
 * finding. It checks the NAME at a binding site and nothing else: whether a
 * given allocator should have been an arena is a judgement, and a gate that
 * pretended otherwise would produce a decoration.
 *
 * Usage: node scripts/check-allocator-names.mjs [--check]   # exit 1 on drift
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DIRS = ["src", "tools"];
const BANNED = new Set(["allocator", "alloc"]);
const ALIAS_DECL = "const Allocator = std.mem.Allocator;";

/** Every `.zig` file under `dirs`, sorted for stable output. */
function zigFiles(dirs) {
  const out = [];
  const walk = (d) => {
    for (const e of readdirSync(d).sort()) {
      const p = path.join(d, e);
      if (statSync(p).isDirectory()) walk(p);
      else if (e.endsWith(".zig")) out.push(p);
    }
  };
  for (const d of dirs) {
    const abs = path.join(ROOT, d);
    try { if (statSync(abs).isDirectory()) walk(abs); } catch { /* absent: skip */ }
  }
  return out;
}

/**
 * Strip Zig comments and literals, replacing each with spaces so every byte
 * offset — and therefore every line number — is preserved.
 */
function codeOnly(src) {
  const blank = (s) => s.replace(/[^\n]/g, " ");
  let out = "", i = 0;
  while (i < src.length) {
    const c = src[i];
    const toEol = () => { const e = src.indexOf("\n", i); return e === -1 ? src.length : e; };
    if (c === "/" && src[i + 1] === "/") { const e = toEol(); out += blank(src.slice(i, e)); i = e; continue; }
    if (c === "\\" && src[i + 1] === "\\") { const e = toEol(); out += blank(src.slice(i, e)); i = e; continue; }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== c && src[j] !== "\n") { if (src[j] === "\\") j++; j++; }
      const e = Math.min(j + 1, src.length);
      out += blank(src.slice(i, e)); i = e; continue;
    }
    out += c; i++;
  }
  return out;
}

const findings = [];
let files = 0, bindings = 0;

for (const abs of zigFiles(DIRS)) {
  const rel = path.relative(ROOT, abs);
  const raw = readFileSync(abs, "utf8");
  const code = codeOnly(raw);
  const lines = code.split("\n");
  files++;

  // Rule 1 — a binding of type Allocator must be named `gpa` or `arena`.
  // Matches a parameter or field (`name: Allocator,`) and a local bound from
  // an allocator-producing call (`const name = x.allocator();`).
  lines.forEach((line, n) => {
    const decl = line.match(/(?:^|[(,\s])([A-Za-z_]\w*)\s*:\s*(?:std\.mem\.)?Allocator\s*[,)]/);
    if (decl) {
      bindings++;
      if (BANNED.has(decl[1])) {
        findings.push(`${rel}:${n + 1}: binding of type Allocator is named \`${decl[1]}\` — use \`gpa\`, or \`arena\` if it is arena-backed`);
      }
    }
    const local = line.match(/\b(?:const|var)\s+([A-Za-z_]\w*)\s*=\s*[\w.?*]*\.allocator\(\)/);
    if (local) {
      bindings++;
      if (BANNED.has(local[1])) {
        findings.push(`${rel}:${n + 1}: allocator bound to \`${local[1]}\` — use \`gpa\`, or \`arena\` if it comes from an arena`);
      }
    }
  });

  // Rule 2 — the type goes through the file-local alias.
  lines.forEach((line, n) => {
    if (!line.includes("std.mem.Allocator")) return;
    if (line.trim() === ALIAS_DECL) return; // the alias declaration itself
    findings.push(`${rel}:${n + 1}: spells \`std.mem.Allocator\` — add \`${ALIAS_DECL}\` and use \`Allocator\``);
  });
}

if (findings.length > 0) {
  for (const f of findings) console.error(`check-allocator-names: FAIL — ${f}`);
  console.error(`check-allocator-names: ${findings.length} violation(s) across ${files} file(s). See CONTRIBUTING.md, "One name for the allocator".`);
  process.exit(1);
}
console.log(`check-allocator-names: ok (${bindings} allocator bindings across ${files} files)`);
