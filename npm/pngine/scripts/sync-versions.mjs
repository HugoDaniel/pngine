#!/usr/bin/env node
// sync-versions.mjs — keep the version numbers of the npm packages in lockstep.
//
// `npm/pngine` is the source of truth: its `version` field drives
//   - every `npm/pngine-<os>-<cpu>/package.json` `version`, and
//   - every `optionalDependencies` pin inside `npm/pngine/package.json`.
// A single missed bump ships a wrapper that resolves the wrong binary (or none).
// It is also checked against CHANGELOG.md's newest released heading, because
// nothing enforced that and it slipped twice (2.0.0 shipped with 175 commits
// of user-visible work unrecorded).
//
// Modes:
//   (default)   stamp every out-of-date version to the root version.
//   --check     assert everything is in lockstep; exit 1 with a drift report.
//
// Version *values* are edited surgically (a targeted string replace) so the
// hand-authored formatting — inline `"os": ["darwin"]` arrays and friends — is
// preserved. Structural drift (a platform package with no matching
// optionalDependencies pin, or a stray pin) is reported but never auto-fixed:
// adding/removing a platform is a deliberate act, not a formatting rewrite.

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const npmDir = join(scriptDir, '..', '..'); // repo/npm
const rootPkgPath = join(npmDir, 'pngine', 'package.json');

const check = process.argv.includes('--check');

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const readText = (p) => readFileSync(p, 'utf8');

const rootText = readText(rootPkgPath);
const rootPkg = JSON.parse(rootText);
const version = rootPkg.version;
if (typeof version !== 'string' || !version) {
  console.error(`npm/pngine/package.json has no usable "version" field`);
  process.exit(1);
}

// Discover platform packages: npm/pngine-<os>-<cpu>/ (excludes the root
// `pngine` dir and any non-binary package like vite-plugin-pngine).
const platformDirs = readdirSync(npmDir, { withFileTypes: true })
  .filter((d) => d.isDirectory() && /^pngine-.+/.test(d.name))
  .map((d) => d.name)
  .sort();

const drift = []; // human-readable drift lines
const structural = []; // drift a surgical stamp cannot fix
/** @type {Array<[string, string]>} pending [path, newText] writes */
const writes = [];

// 1. Each platform package's version must equal the root version.
const platformNames = [];
for (const dir of platformDirs) {
  const p = join(npmDir, dir, 'package.json');
  const text = readText(p);
  const pkg = JSON.parse(text);
  platformNames.push(pkg.name);
  if (pkg.version === version) continue;
  drift.push(`${pkg.name}: version ${pkg.version} != ${version}`);
  const re = /^(\s*"version":\s*")[^"]*(")/m;
  if (!re.test(text)) {
    structural.push(`${pkg.name}: no top-level "version" field to stamp`);
    continue;
  }
  writes.push([p, text.replace(re, `$1${version}$2`)]);
}
platformNames.sort();

// 2. Root optionalDependencies must pin every platform package — no more, no
//    less — each at the root version.
const optional = rootPkg.optionalDependencies ?? {};
let newRootText = rootText;
for (const name of platformNames) {
  if (optional[name] === version) continue;
  if (!(name in optional)) {
    structural.push(`root optionalDependencies is missing a pin for ${name}`);
    drift.push(`root optionalDependencies[${name}]: (missing) != ${version}`);
    continue;
  }
  drift.push(`root optionalDependencies[${name}]: ${optional[name]} != ${version}`);
  const re = new RegExp(`("${escapeRegex(name)}":\\s*")[^"]*(")`);
  newRootText = newRootText.replace(re, `$1${version}$2`);
}
for (const name of Object.keys(optional)) {
  if (!platformNames.includes(name)) {
    structural.push(`root optionalDependencies has a stray pin ${name} (no such platform package)`);
    drift.push(`root optionalDependencies[${name}]: no matching platform package`);
  }
}
if (newRootText !== rootText) writes.push([rootPkgPath, newRootText]);

// 3. CHANGELOG.md's newest RELEASED heading must be the current version.
//
// `docs/publishing.md` wrote down that nothing enforced this and that it had
// already slipped once. It then slipped again: 2.0.0 shipped and 175 commits
// of user-visible work went unrecorded. A `## [Unreleased]` block above the
// newest release is fine and expected — this only asserts that no RELEASED
// version is newer than, or different from, what the package claims to be.
//
// Structural, never auto-fixed: writing changelog prose is not a stamp.
const changelogPath = join(npmDir, '..', 'CHANGELOG.md');
let changelogTop = null;
try {
  const headings = [...readText(changelogPath).matchAll(/^## \[([^\]]+)\]/gm)].map((m) => m[1]);
  changelogTop = headings.find((h) => h.toLowerCase() !== 'unreleased') ?? null;
  if (changelogTop === null) {
    structural.push('CHANGELOG.md has no released `## [x.y.z]` heading');
    drift.push('CHANGELOG.md: no released version heading found');
  } else if (changelogTop !== version) {
    structural.push(
      `CHANGELOG.md's newest release is [${changelogTop}] but the package is ${version} — ` +
        'record the release, or correct the version',
    );
    drift.push(`CHANGELOG.md newest release: ${changelogTop} != ${version}`);
  }
} catch {
  // The release mirror keeps CHANGELOG.md, so this should not fire there;
  // absent means someone is running from a partial tree. Not an error.
  console.error('note: CHANGELOG.md not readable — version/changelog check skipped');
}

if (check) {
  if (drift.length === 0) {
    console.log(`all ${platformNames.length + 1} npm packages in sync at ${version}`);
    process.exit(0);
  }
  console.error('npm version drift detected:');
  for (const d of drift) console.error(`  - ${d}`);
  console.error('\nRun `node npm/pngine/scripts/sync-versions.mjs` to stamp value drift.');
  if (structural.length) {
    console.error('These need a manual edit — a version stamp cannot fix them:');
    for (const s of structural) console.error(`  - ${s}`);
  }
  process.exit(1);
}

// Write mode: apply the surgical version stamps.
for (const [p, text] of writes) writeFileSync(p, text);
if (writes.length) {
  console.log(`stamped ${writes.length} file(s) to ${version}`);
} else {
  console.log(`already in sync at ${version}`);
}
if (structural.length) {
  console.error('\nUnresolved structural drift (fix by hand):');
  for (const s of structural) console.error(`  - ${s}`);
  process.exit(1);
}
