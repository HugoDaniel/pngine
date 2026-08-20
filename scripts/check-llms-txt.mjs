#!/usr/bin/env node

/**
 * Drift gate: `docs/llms.txt`, the LLM-facing SJON reference, against the
 * engine itself.
 *
 * `docs/llms.txt` is the one document written to be fetched by an LLM agent
 * and pasted into its context whole: a compact reference plus complete
 * programs to copy. Nothing checked it, and the previous copy (living in the
 * docs site's `public/`) described a retired `#macro` DSL for months — a file
 * whose whole purpose is to brief LLMs, briefing them on syntax that no
 * longer existed (§360). Same lesson as check-sjon-reference: prose that
 * describes a build is an artifact, and the fix is a gate, not a rewrite.
 *
 * The file is canonical HERE; the docs site (site-pngine) snapshots it into
 * `public/llms.txt` with its own byte-exact `--check`, so this gate is the
 * only place its content is checked.
 *
 * WHAT IT CHECKS
 *   - every ```sjon fence is a complete program that `pngine validate --json`
 *     accepts with ZERO diagnostics — the file promises "copy them as-is",
 *     and a warning in a reference example teaches the warning;
 *   - every fence carries an info string (`sjon`, `text`, `bash`, …). An
 *     untagged fence is an error: it is how a fragment poses as a program
 *     (or a program escapes the gate) — classify it;
 *   - every `raw.githubusercontent.com/HugoDaniel/pngine/main/<path>` URL
 *     names a tracked path that `.mirrorignore` does not hold back from the
 *     release cut, because that is the URL an agent will actually fetch
 *     (docs/llm-overview.md is stripped, and was the first link proposed);
 *   - no em-dashes: the docs site serves this file verbatim, and its prose
 *     rule bans them (site-pngine README).
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK
 *   Form/key coverage. That is docs/sjon-reference.md's job (check-sjon-
 *   reference.mjs); this file is a curated subset by design and links to
 *   the full reference. Nor the "Caps" numbers, the diagnostic-code table or
 *   the CLI flag list — those need a human, and matching them by regex would
 *   force fabricated mentions (pitfall 53's scope rule).
 *
 * Deliberately strict about its own inputs: zero ```sjon fences is an ERROR,
 * not a pass, and so is a missing file — the file ships in the release cut,
 * so a clone without it is broken, not stripped (pitfall 43).
 *
 * The CLI it runs is the freshly built one: build.zig passes it as
 * `--cli <path>` via addArtifactArg, so `zig build drift` builds the CLI first.
 * By hand it defaults to zig-out/bin/pngine.
 *
 * Usage: node scripts/check-llms-txt.mjs [--check] [--cli <path/to/pngine>]
 *        exit 0 clean · 1 drift · 2 the gate itself cannot run
 */

import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const FILE = path.join(ROOT, "docs/llms.txt");
const MIRRORIGNORE = path.join(ROOT, ".mirrorignore");
const RAW_PREFIX = "https://raw.githubusercontent.com/HugoDaniel/pngine/main/";

// --- args --------------------------------------------------------------------
let cliPath = path.join(ROOT, "zig-out/bin/pngine");
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--check") continue;
  if (a === "--cli") {
    cliPath = process.argv[++i];
    if (!cliPath) fatal("--cli needs a path");
    continue;
  }
  fatal(`unknown argument ${a}`);
}

function fatal(msg) {
  console.error(`check-llms-txt: ${msg}`);
  process.exit(2);
}

const rel = (p) => path.relative(ROOT, p);

if (!existsSync(FILE)) {
  fatal(`${rel(FILE)} is missing — it ships in the release cut, so this is a broken checkout, not a stripped one.`);
}
if (!existsSync(cliPath)) {
  fatal(`no CLI at ${cliPath} — run \`zig build\` first, or pass --cli <path>.`);
}

const text = readFileSync(FILE, "utf8");
const lines = text.split("\n");
const lineOf = (offset) => text.slice(0, offset).split("\n").length;

// --- fences ------------------------------------------------------------------
// A fence opens on a line that is exactly ``` plus an optional info string and
// closes on the next line that is exactly ```. Bodies are taken verbatim.
const fences = [];
{
  let open = null;
  for (let i = 0; i < lines.length; i++) {
    const m = /^```(.*)$/.exec(lines[i]);
    if (!m) continue;
    if (open === null) {
      open = { info: m[1].trim(), line: i + 1, start: i + 1 };
    } else if (m[1].trim() === "") {
      fences.push({ ...open, body: lines.slice(open.start, i).join("\n") + "\n" });
      open = null;
    } else {
      fatal(`line ${i + 1}: a fence opened at line ${open.line} was never closed before another opened.`);
    }
  }
  if (open !== null) fatal(`the fence opened at line ${open.line} is never closed.`);
}

const problems = [];

const untagged = fences.filter((f) => f.info === "");
for (const f of untagged) {
  problems.push(
    `line ${f.line}: untagged fence — tag it \`sjon\` (a complete program; validated) ` +
      `or \`text\`/\`bash\`/… (not validated). A fragment must not pose as a program.`,
  );
}

const sjonFences = fences.filter((f) => f.info === "sjon");
if (sjonFences.length === 0) {
  fatal(`parsed ${fences.length} fence(s) but no \`\`\`sjon fence — the scanner or the document is broken, not the programs.`);
}

for (const f of sjonFences) {
  const r = spawnSync(cliPath, ["validate", "-", "--json"], { input: f.body, encoding: "utf8" });
  if (r.error) fatal(`could not spawn ${cliPath}: ${r.error.message}`);
  let report = null;
  try {
    report = JSON.parse(r.stdout);
  } catch {
    // fall through: a non-JSON stdout is reported below as a failure
  }
  const clean = r.status === 0 && report && report.status === "ok" && report.diagnostics.length === 0 && report.dropped === 0;
  if (clean) continue;
  const why = report
    ? report.diagnostics.map((d) => `      ${d.code ?? d.severity ?? "?"}: ${d.message ?? JSON.stringify(d)}`).join("\n")
    : `      exit ${r.status}, stdout not JSON: ${(r.stdout || r.stderr).trim().split("\n")[0]}`;
  problems.push(
    `line ${f.line}: \`\`\`sjon fence does not validate clean (status ${report?.status ?? "?"}, ` +
      `${report?.diagnostics?.length ?? "?"} diagnostic(s)):\n${why}`,
  );
}

// --- raw-GitHub URLs must name shipped files ---------------------------------
// rsync exclude semantics, reduced to what .mirrorignore actually uses: a
// pattern with no slash matches that basename anywhere; a trailing slash is a
// directory; otherwise an exact path or a directory prefix.
const ignorePatterns = existsSync(MIRRORIGNORE)
  ? readFileSync(MIRRORIGNORE, "utf8")
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("#"))
  : [];
const heldBack = (p) =>
  ignorePatterns.find((pat) => {
    const bare = pat.replace(/\/$/, "");
    if (!bare.includes("/")) return p === bare || p.split("/").includes(bare);
    return p === bare || p.startsWith(bare + "/");
  });

const urlRe = new RegExp(RAW_PREFIX.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "([^\\s)>\\]`'\"]+)", "g");
const urls = [];
for (let m; (m = urlRe.exec(text)); ) urls.push({ path: m[1], line: lineOf(m.index) });
for (const u of urls) {
  const abs = path.join(ROOT, u.path);
  if (!existsSync(abs)) {
    problems.push(`line ${u.line}: ${RAW_PREFIX}${u.path} — no such file in this checkout.`);
    continue;
  }
  const pat = heldBack(u.path);
  if (pat) {
    problems.push(
      `line ${u.line}: ${RAW_PREFIX}${u.path} — .mirrorignore holds \`${pat}\` back from the release cut, so this URL 404s publicly.`,
    );
  }
}

// --- prose rule the docs site enforces ---------------------------------------
lines.forEach((l, i) => {
  if (l.includes("—")) problems.push(`line ${i + 1}: em-dash — the docs site serves this file verbatim and bans them; use a colon, comma pair or new sentence.`);
});

// --- verdict -----------------------------------------------------------------
if (problems.length === 0) {
  console.log(
    `check-llms-txt: OK — ${sjonFences.length} sjon fence(s) validate clean, ` +
      `${fences.length} fence(s) tagged, ${urls.length} raw-GitHub URL(s) name shipped files, no em-dashes.`,
  );
  process.exit(0);
}

console.error(`check-llms-txt: ${rel(FILE)} has ${problems.length} problem(s):\n`);
for (const p of problems) console.error(`  ${p}\n`);
console.error(
  `  Fix ${rel(FILE)} here (it is canonical; site-pngine snapshots it), then\n` +
    `  re-run: node scripts/check-llms-txt.mjs`,
);
process.exit(1);
