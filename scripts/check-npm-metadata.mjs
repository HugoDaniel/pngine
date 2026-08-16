#!/usr/bin/env node

/**
 * Drift gate: the licence and repository metadata of every publishable package.
 *
 * The six platform packages published `"license": "MIT"` against a CC0-1.0
 * project for their entire existence. CHANGELOG 1.0.27 records that bug as
 * fixed; the fix touched `npm/pngine` only, and nothing compared the other
 * seven manifests to it. Every one of the eight also shipped a licence *field*
 * with no licence *text* behind it, because `LICENSE` was never copied into
 * the package dirs.
 *
 * Neither is the kind of thing anyone re-reads. So it is a gate.
 *
 * What it asserts, for each `npm/<pkg>/package.json`:
 *   - `license` matches the root package.json's
 *   - a `LICENSE` file sits beside it, byte-identical to the repo root's
 *     (npm force-includes LICENSE regardless of the `files` allowlist, so its
 *     presence on disk is what decides whether the tarball carries it)
 *   - `repository.url` matches the root's — the address model moved twice in
 *     2026-08 and a stale one points published users at a dead host
 *
 * Deliberately strict about its own inputs: discovering zero packages is an
 * ERROR, not a pass (CONTRIBUTING pitfall 43).
 *
 * Usage: node scripts/check-npm-metadata.mjs [--check]   # exit 1 on drift
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const NPM_DIR = path.join(ROOT, "npm");
const ROOT_PKG = path.join(NPM_DIR, "pngine", "package.json");

function fail(msg) {
  console.error(`check-npm-metadata: ${msg}`);
  process.exit(1);
}

const rootPkg = JSON.parse(readFileSync(ROOT_PKG, "utf8"));
const wantLicense = rootPkg.license ?? fail("npm/pngine/package.json has no `license`");
const wantRepo = rootPkg.repository?.url ?? fail("npm/pngine/package.json has no `repository.url`");
const wantText = readFileSync(path.join(ROOT, "LICENSE"), "utf8");

const dirs = readdirSync(NPM_DIR, { withFileTypes: true })
  .filter((d) => d.isDirectory() && existsSync(path.join(NPM_DIR, d.name, "package.json")))
  .map((d) => d.name)
  .sort();

if (dirs.length === 0) fail("no packages found under npm/ — nothing was compared");

const problems = [];

for (const dir of dirs) {
  const pkgPath = path.join(NPM_DIR, dir, "package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  const at = `npm/${dir}`;

  if (pkg.private === true) continue;

  if (pkg.license !== wantLicense) {
    problems.push(`${at}: license is ${JSON.stringify(pkg.license)}, root says ${JSON.stringify(wantLicense)}`);
  }

  const licensePath = path.join(NPM_DIR, dir, "LICENSE");
  if (!existsSync(licensePath)) {
    problems.push(`${at}: no LICENSE file — the published tarball would show a license field with nothing behind it`);
  } else if (readFileSync(licensePath, "utf8") !== wantText) {
    problems.push(`${at}/LICENSE differs from the repo root LICENSE`);
  }

  const repo = pkg.repository?.url;
  if (repo !== wantRepo) {
    problems.push(`${at}: repository.url is ${JSON.stringify(repo)}, root says ${JSON.stringify(wantRepo)}`);
  }
}

if (problems.length > 0) {
  console.error("=== NPM METADATA DRIFT ===");
  for (const p of problems) console.error(`  x ${p}`);
  console.error(
    "\nEvery publishable package must carry the same license identifier, the\n" +
      "same license text, and the same repository address as npm/pngine.",
  );
  process.exit(1);
}

console.log(`check-npm-metadata: ok (${dirs.length} packages: ${wantLicense}, LICENSE text, repository url)`);
