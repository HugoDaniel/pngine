#!/usr/bin/env node

/**
 * Drift gate: every ```sjon fence in the engine's own prose, run through the
 * built CLI.
 *
 * README.md, docs/sjon-reference.md, docs/architecture.md, CONTRIBUTING.md and
 * CLAUDE.md quote a lot of SJON, and quoted SJON rots the moment the schema
 * moves. The
 * 3.0.0 overhaul renamed keys, retired forms and made members required, and
 * each of those cuts left a fence somewhere that still read fine and no
 * longer compiled — the README's headline example declared a pipeline and a
 * frame both named `main` from the commit that made names one namespace
 * until the audit that noticed (overhaul/09 §3, §8). check-llms-txt covers
 * docs/llms.txt's three programs; check-sjon-reference compares the
 * reference's KEY coverage against the schema; nothing ran `validate` over
 * the fences themselves. This is that gate, ported from the docs site's
 * scripts/check-fences.mjs (same rules, same allowed classes), so the two
 * doc sets are judged alike.
 *
 * WHAT IT CHECKS
 *   - every ```sjon fence validates. Most fences are FRAGMENTS on purpose:
 *     they name a pipeline or a buffer another fence declares, or they show
 *     two keys out of a form. So four diagnostics are allowed and everything
 *     else fails — including warnings, because the one warning a reference
 *     example can carry (`no-unused-binding`, W0003) is the `:layout auto`
 *     desync that renders black (CONTRIBUTING pitfall 37):
 *
 *       not_cross_ref              a name the fence does not declare
 *       keyword pair at top level  a deliberate `:key value` excerpt
 *       cannot read '…': FileNotFound   a `:file` path the repo does not hold
 *       `(x …)` is a child of …, not a document form
 *                                  a child form shown on its own
 *
 *   - a fence that SHOWS an error opens with `; invalid: <needle>` and must
 *     then be refused with a diagnostic whose code or message contains the
 *     needle — so a pitfall the engine stops rejecting fails the gate too;
 *   - an UNTAGGED fence whose first non-blank line opens a form (`(`) or a
 *     `;` comment is an error: tag it `sjon` (validated) or `text` (a grammar template with
 *     `<placeholders>`, not validated). A fragment must not pose as a program
 *     and a program must not escape the gate by losing its tag
 *     (check-llms-txt's rule).
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK
 *   Inline code spans (`(buffer :name …)` in a table cell) and prose claims
 *   about defaults or behaviour. Those need a human; overhaul/09 §3 is the
 *   checklist.
 *
 * Deliberately strict about its own inputs: zero ```sjon fences across the
 * files that are present is an ERROR, not a pass (pitfall 43). A named file
 * that is absent is skipped and said so — CONTRIBUTING.md and CLAUDE.md are
 * held back from the release cut (.mirrorignore); the other three ship.
 *
 * CLAUDE.md joined the list in §376. Its quick skeleton had been missing
 * `(texture … :size)` and a compute pipeline's `:layout` — two members 3.0.0
 * made required — because a `"""<wgsl>""" placeholder made it untestable by
 * construction. It is a whole program now, so the file that teaches an agent
 * the language cannot claim a shape the compiler refuses.
 *
 * The CLI it runs is the freshly built one: build.zig passes it as
 * `--cli <path>` via addArtifactArg, so `zig build drift` builds the CLI first.
 * By hand it defaults to zig-out/bin/pngine.
 *
 * Usage: node scripts/check-doc-fences.mjs [--check] [--verbose]
 *                                          [--cli <path/to/pngine>] [file…]
 *        exit 0 clean · 1 drift · 2 the gate itself cannot run
 */

import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const DEFAULT_FILES = ["README.md", "docs/sjon-reference.md", "docs/architecture.md", "CONTRIBUTING.md", "CLAUDE.md"];

// The four fragment classes (the docs site's list, verbatim). Each names a
// thing a FRAGMENT does that a document must not; anything else is the page
// being wrong.
const ALLOWED = [
  (d) => d.code === "not_cross_ref",
  (d) => /keyword pair at top level/.test(d.message),
  (d) => /FileNotFound/.test(d.message),
  (d) => /is a child of .* not a document form/.test(d.message),
];

// --- args --------------------------------------------------------------------
let cliPath = path.join(ROOT, "zig-out/bin/pngine");
let verbose = false;
const named = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--check") continue;
  if (a === "--verbose") {
    verbose = true;
    continue;
  }
  if (a === "--cli") {
    cliPath = process.argv[++i];
    if (!cliPath) fatal("--cli needs a path");
    continue;
  }
  if (a.startsWith("--")) fatal(`unknown argument ${a}`);
  named.push(a);
}

function fatal(msg) {
  console.error(`check-doc-fences: ${msg}`);
  process.exit(2);
}

if (!existsSync(cliPath)) {
  fatal(`no CLI at ${cliPath} — run \`zig build\` first, or pass --cli <path>.`);
}

// Defaults are repo paths; a file named on the command line resolves against
// the cwd, like any CLI argument.
const files = named.length ? named.map((f) => path.resolve(f)) : DEFAULT_FILES.map((f) => path.resolve(ROOT, f));
const rel = (p) => {
  const r = path.relative(ROOT, p);
  return r.startsWith("..") ? p : r;
};

// --- fences ------------------------------------------------------------------
// A fence opens on a line that is ``` plus an optional info string (leading
// whitespace allowed: the reference indents fences inside list items) and
// closes on the next line that is ``` alone. Bodies are taken verbatim.
function fencesOf(text, file) {
  const lines = text.split("\n");
  const out = [];
  let open = null;
  for (let i = 0; i < lines.length; i++) {
    const m = /^\s*```(.*)$/.exec(lines[i]);
    if (!m) continue;
    if (open === null) {
      open = { info: m[1].trim(), line: i + 1, start: i + 1 };
    } else if (m[1].trim() === "") {
      const body = lines.slice(open.start, i);
      out.push({ ...open, body: body.join("\n") + "\n", first: body.find((l) => l.trim()) ?? "" });
      open = null;
    } else {
      fatal(`${rel(file)}:${i + 1}: a fence opened at line ${open.line} was never closed before another opened.`);
    }
  }
  if (open !== null) fatal(`${rel(file)}: the fence opened at line ${open.line} is never closed.`);
  return out;
}

const problems = [];
const problem = (file, line, msg) => problems.push(`${rel(file)}:${line}: ${msg}`);

const tmp = mkdtempSync(path.join(tmpdir(), "pngine-doc-fences-"));
let filesSeen = 0;
let sjonTotal = 0;
let allowedTotal = 0;
let negatives = 0;

for (const file of files) {
  if (!existsSync(file)) {
    console.log(`check-doc-fences: ${rel(file)} absent — skipped (the release cut strips it).`);
    continue;
  }
  filesSeen++;
  const fences = fencesOf(readFileSync(file, "utf8"), file);

  for (const f of fences) {
    if (f.info === "" && /^\s*[(;]/.test(f.first)) {
      problem(
        file,
        f.line,
        "untagged fence opens a form or a `;` comment — tag it `sjon` (a program or fragment; validated) " +
          "or `text` (a grammar template with <placeholders>; not validated).",
      );
      continue;
    }
    if (f.info !== "sjon") continue;
    sjonTotal++;

    // Each fence goes through a file in a scratch dir, the way the site's
    // gate runs them: a `:file "x.bin"` then resolves nowhere and surfaces as
    // the FileNotFound class, which is the honest outcome for a path the
    // docs only illustrate.
    const scratch = path.join(tmp, `${rel(file).replace(/[\\/]/g, "_")}.${f.line}.sjon`);
    writeFileSync(scratch, f.body);
    const r = spawnSync(cliPath, ["validate", scratch, "--json"], { encoding: "utf8" });
    if (r.error) fatal(`could not spawn ${cliPath}: ${r.error.message}`);
    let report = null;
    try {
      report = JSON.parse(r.stdout);
    } catch {
      problem(file, f.line, `validate produced no JSON (exit ${r.status}): ${(r.stderr || r.stdout).trim().split("\n")[0]}`);
      continue;
    }
    const diags = report.diagnostics ?? [];
    const where = (d) => f.line + (d.line ?? 1) - 1;

    // A negative: `; invalid: <needle>` on the first non-blank line.
    const neg = /^\s*;\s*invalid:\s*(.+?)\s*$/.exec(f.first);
    if (neg) {
      negatives++;
      const needle = neg[1];
      const pool = [...diags, { code: "", message: report.message ?? "" }];
      const hit = report.status !== "ok" && pool.some((d) => (d.code ?? "").includes(needle) || (d.message ?? "").includes(needle));
      if (hit) {
        if (verbose) console.log(`  (negative) ${rel(file)}:${f.line}: refused with '${needle}'`);
        continue;
      }
      problem(
        file,
        f.line,
        `marked \`; invalid: ${needle}\` but ` +
          (report.status === "ok"
            ? "validates clean — the engine no longer refuses it, so the pitfall text is stale."
            : `fails with something else: ${diags.map((d) => d.code || d.message).join("; ") || report.message}`),
      );
      continue;
    }

    if (report.dropped) {
      problem(file, f.line, `validate dropped ${report.dropped} diagnostic(s) — the array is a prefix, not the verdict.`);
      continue;
    }

    // A refusal with no diagnostic is the worst outcome, not a clean one: the
    // CLI said no and cannot say where. Judge the headline by the same rules
    // rather than let an empty array read as "nothing wrong".
    if (report.status !== "ok" && diags.length === 0) {
      const headline = { code: "", message: report.message ?? "" };
      if (ALLOWED.some((rule) => rule(headline))) {
        allowedTotal++;
        if (verbose) console.log(`  (allowed) ${rel(file)}:${f.line}: headline: ${headline.message}`);
        continue;
      }
      problem(file, f.line, `validate reported ${JSON.stringify(report.status)} with no diagnostic (${headline.message || "no message"})`);
      continue;
    }

    for (const d of diags) {
      if (ALLOWED.some((rule) => rule(d))) {
        allowedTotal++;
        if (verbose) console.log(`  (allowed) ${rel(file)}:${where(d)}: ${d.code ?? "compiler"}: ${d.message}`);
        continue;
      }
      problem(file, where(d), `${d.severity ?? "error"} ${d.code ?? "compiler"}: ${d.message}`);
    }
  }
}
rmSync(tmp, { recursive: true, force: true });

if (filesSeen === 0) fatal("none of the named files exist — nothing to gate is a broken invocation, not a pass.");
if (sjonTotal === 0) {
  fatal(`parsed ${filesSeen} file(s) but no \`\`\`sjon fence — the scanner or the documents are broken, not the programs.`);
}

// --- verdict -----------------------------------------------------------------
if (problems.length === 0) {
  console.log(
    `check-doc-fences: OK — ${sjonTotal} sjon fence(s) in ${filesSeen} file(s) validate ` +
      `(${allowedTotal} fragment diagnostic(s) allowed, ${negatives} negative(s) refused as marked).`,
  );
  process.exit(0);
}

console.error(`check-doc-fences: ${problems.length} problem(s) across ${sjonTotal} sjon fence(s) in ${filesSeen} file(s):\n`);
for (const p of problems) console.error(`  ${p}\n`);
console.error(
  "  A fragment may only miss names it does not declare, show a `:key value` pair, name\n" +
    "  a `:file` the repo lacks, or be a child form on its own. Anything else is the page\n" +
    "  being wrong: fix the fence, or open it with `; invalid: <needle>` if it shows an error.\n" +
    "  Re-run: node scripts/check-doc-fences.mjs",
);
process.exit(1);
