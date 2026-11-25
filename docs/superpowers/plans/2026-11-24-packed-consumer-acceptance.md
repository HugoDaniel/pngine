# Packed-Consumer Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A manual, offline, tiered harness inside this repo that installs the packed PNGine tarballs into an empty home and proves a consumer can use them — Node imports, >1 MiB compilation, a real-GPU render, and a full Vite build through `vite-plugin-pngine`.

**Architecture:** `tests/packed-consumer/run.mjs` drives named tiers against a temporary home. It packs or accepts a tarball directory, pins each tarball's SHA-256, installs through a lockfile whose resolved URLs are those tarballs, and then runs each tier as a separate step that prints one verdict line. Nothing is enforced by hooks or CI; the printed report is the record a release is decided from.

**Tech Stack:** Node 26 ESM (no new dependencies), `node:test` for the harness's own unit tests, the repo's existing `vite`/`playwright-core`/`pngine` build products, and `chromium.connectOverCDP` for the browser tiers.

**Spec:** `docs/superpowers/specs/2026-11-24-packed-consumer-acceptance-design.md`

## Global Constraints

- No new runtime or dev dependencies in `package.json`; the harness uses Node built-ins plus what the repo already installs.
- Every tier fails closed with a **named** failure; only the browser tier may skip, and only with its reason recorded and printed as `SKIPPED`. A skip is never counted as a pass.
- The artifact under test must come from the installed tarballs; a tier may never read `npm/pngine/dist` or `npm/pngine/src` for what it asserts on. Test *fixtures* (e.g. `tests/helpers/memcap-fixtures.js`) may be imported by path.
- Offline: no registry resolution at any point. `npm install --offline` against a lockfile whose `resolved` URLs are `file:` tarballs.
- `--tarballs <dir>` is the input; absent, the harness packs into its own temp dir and says so in the report.
- Tarball SHA-256 is pinned per run and printed; the installed tree is asserted to match.
- Each tier prints exactly one verdict line: `T<n> <name>: PASS|FAIL|SKIPPED  <key numbers>`.
- Node built-ins only for the harness core; `vite` and `playwright-core` are resolved from the repo's `node_modules` by absolute path, never from the temp home's resolution.
- Commit after every task; do not leave the tree dirty between tasks.

## Review Focus

- **A stale `dist/`** quietly ships a `viewer`/`core`/`dev` bundle built from older `src/` — the harness must rebuild and byte-compare, or it certifies nothing.
- **A file missing from the tarball** (wasm, `schema/`, a `.d.ts`) that the checkout has but `files` dropped — must fail by name, not by a downstream stack.
- **A wrapper/compiler-wasm version pairing mismatch** — an old compiler without `allocSource` must produce the pairing message, not a crash or a silent legacy fallback.
- **A machine with no hardware adapter** — the browser tiers must skip by name with the adapter recorded, never assert a black pixel as correct.
- **Repo paths leaking into a production bundle** — a Vite build that embeds `/home/agent/worktrees/...` is not shippable.
- **`--ignore-scripts`** — an install must not depend on install-time generation.

---

### Task 1: Harness skeleton, tarball input, and the report

**Files:**
- Create: `tests/packed-consumer/run.mjs`
- Create: `tests/packed-consumer/lib/report.mjs`
- Create: `tests/packed-consumer/lib/tarballs.mjs`
- Test: `tests/packed-consumer/lib/report.test.mjs`, `tests/packed-consumer/lib/tarballs.test.mjs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `createReport(): { tier(id: string, name: string, verdict: 'PASS'|'FAIL'|'SKIPPED', detail: string, numbers?: object): void; finish(): { ok: boolean, proven: boolean, lines: string[], provenance: object } }` — `proven` is false when any tier was `SKIPPED`, and `finish()` is idempotent so a caller may read it once.
  - `resolveTarballs({ dir?: string, repoRoot: string, scratch: string }): Promise<{ source: 'provided'|'packed', dir: string, files: Array<{ name: string, path: string, sha256: string }> }>`
  - `run.mjs` flag parsing: `--tier=<all|t0|t1|t2|t3>` (repeatable), `--tarballs=<dir>`, `--keep` (leave the temp home), `--cdp=<url>`.

- [ ] **Step 1: Write the failing tests**

```js
// tests/packed-consumer/lib/report.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createReport } from './report.mjs';

test('a tier verdict line carries id, name, verdict and numbers', () => {
  const r = createReport();
  r.tier('T0', 'package shape', 'PASS', 'all subpaths resolve', { subpaths: 8, files: 58 });
  const { lines, ok } = r.finish();
  assert.equal(ok, true);
  assert.match(lines[0], /^T0 package shape: PASS\s+subpaths=8 files=58$/);
});

test('a skip is not a pass and is marked in the report', () => {
  const r = createReport();
  r.tier('T2', 'render', 'SKIPPED', 'software adapter: swiftshader');
  const { ok, proven, lines } = r.finish();
  assert.equal(ok, true);           // a skip does not fail the run...
  assert.equal(proven, false);      // ...but the report says not everything was proven
  assert.match(lines[0], /SKIPPED/); // and it is never printed as PASS
});

test('a failure fails the run', () => {
  const r = createReport();
  r.tier('T1', 'compiler', 'FAIL', 'determinism: second compile differed', { });
  assert.equal(r.finish().ok, false);
});
```

```js
// tests/packed-consumer/lib/tarballs.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { resolveTarballs, sha256 } from './tarballs.mjs';

test('a provided directory is used as-is and every file is hashed', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'pc-tar-'));
  writeFileSync(join(dir, 'pngine-4.4.0.tgz'), 'x');
  const got = await resolveTarballs({ dir, repoRoot: '/nonexistent', scratch: dir });
  assert.equal(got.source, 'provided');
  assert.equal(got.files.length, 1);
  assert.equal(got.files[0].sha256, sha256(Buffer.from('x')));
});

test('a missing directory is a named failure, not an empty install', async () => {
  await assert.rejects(
    resolveTarballs({ dir: '/definitely/not/here', repoRoot: '/nonexistent', scratch: '/tmp' }),
    /--tarballs directory/,
  );
});
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `node --test tests/packed-consumer/lib/*.test.mjs`
Expected: FAIL — `Cannot find module './report.mjs'`.

- [ ] **Step 3: Implement `report.mjs`**

`createReport()` keeps an array of `{ id, name, verdict, detail, numbers }`. `finish()` returns
`ok` (`true` when no `FAIL`), `lines` (one per tier, `numbers` rendered as `k=v` sorted), and
`proven` (`true` only when no tier was `SKIPPED`), plus `provenance` (filled by `run.mjs`:
commit, node, tarball source, CDP endpoint when used).

- [ ] **Step 4: Implement `tarballs.mjs`**

`sha256(buf)` via `node:crypto`. `resolveTarballs` returns a provided directory unchanged after
hashing every `*.tgz`, and rejects with `--tarballs directory <dir> does not exist` otherwise.
The `packed` branch shells `npm pack --pack-destination <scratch>` from `npm/pngine`,
`npm/vite-plugin-pngine`, and each `npm/pngine-*/` that has a `package.json`, capturing stdout
and naming the package on a non-zero exit.

- [ ] **Step 5: Implement `run.mjs`'s skeleton**

Parse the flags above, create the temp home (`mkdtempSync(join(tmpdir(),'pngine-consumer-'))`),
resolve tarballs, print the provenance header (`commit`, `node`, tarball source, per-tarball
`name sha256[0..12]`), dispatch tiers in order, print the report, and `process.exit(ok ? 0 : 1)`.
An unknown `--tier` value prints the valid set and exits 2.

- [ ] **Step 6: Run the tests and the skeleton**

Run: `node --test tests/packed-consumer/lib/*.test.mjs`
Expected: PASS (4 tests).

Run: `node tests/packed-consumer/run.mjs --tier=t0`
Expected: the provenance header, then `T0 … : SKIPPED  not implemented yet`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tests/packed-consumer/
git commit -m "test(consumer): add the packed-consumer harness skeleton"
```

---

### Task 2: T0 — install and package shape

**Files:**
- Create: `tests/packed-consumer/lib/install.mjs`, `tests/packed-consumer/tiers/t0-shape.mjs`
- Modify: `tests/packed-consumer/run.mjs` (register the tier)
- Test: `tests/packed-consumer/lib/install.test.mjs`

**Interfaces:**
- Consumes: `resolveTarballs`'s `{ dir, files }`.
- Produces:
  - `installInto({ home, tarballs, repoRoot, ignoreScripts?: boolean }): { nodeModules: string, installed: Record<string,string> }` — writes `package.json` + `package-lock.json` whose `resolved` values are `file:` URLs for every tarball, then runs `npm ci --offline --no-audit --no-fund` (plus `--ignore-scripts`) in `home`.
  - `runT0({ home, tarballs, repoRoot }): Promise<{ verdict, detail, numbers }>`.

- [ ] **Step 1: Write the failing install test**

```js
test('install resolves only from the tarballs and records what landed', async () => {
  const { home } = await makeEmptyHome();
  const { nodeModules, installed } = await installInto({
    home, tarballs: FIXTURE_TARBALLS, repoRoot: REPO, ignoreScripts: true,
  });
  assert.match(installed.pngine, /^4\.\d+\.\d+$/);
  assert.ok(existsSync(join(nodeModules, 'pngine', 'dist', 'dev.mjs')));
  assert.ok(!existsSync(join(nodeModules, 'pngine', 'node_modules')));
});
```

`FIXTURE_TARBALLS` packs once in `before()` into a temp dir from `REPO` (the repo's own `npm pack`)
so the test needs no network; skip the test body with a named message when
`npm/pngine/dist/dev.mjs` is absent (`run \`zig build web-bundle\``).

- [ ] **Step 2: Run it and watch it fail**

Run: `node --test tests/packed-consumer/lib/install.test.mjs`
Expected: FAIL — `Cannot find module './install.mjs'`.

- [ ] **Step 3: Implement `install.mjs`**

Mirror npm's edge rule: the root `package.json` depends on `pngine` and `vite-plugin-pngine` by
exact version, and each `optionalDependencies` row the packages declare is written where the real
package declares it, resolved to the sibling tarball when present. Assert afterwards that every
`package.json` under `node_modules` is reachable from the root by dependency/optional/dev/peer
edges, and name any orphan. Run npm with `--offline`, `--no-audit`, `--no-fund`, and capture
stdout/stderr; on a non-zero exit print both before failing.

- [ ] **Step 4: Implement `t0-shape.mjs`**

Assertions, each failing with its own line: every `exports` subpath resolves by name from the
installed tree; `pngine.wasm` and `pngine-compiler.wasm` resolve through the package and their
SHA-256 equals `npm/pngine/wasm/*` (which must be rebuilt by the caller if absent — say so);
the installed tree matches the pinned tarball hashes (re-hash each installed package's files and
compare against the manifest the tarball declared); `schema/pngine.sjon` and `schema/pngine.d.ts` exist; every `.d.ts` referenced by `exports.types`
exists; the installed `version` equals the tarball's; the packed file list equals `files` expanded
over the packed tree, by name and count, with an extension allowlist per directory (reject
`.map`, `.tsbuildinfo`, `.DS_Store`).

- [ ] **Step 5: Add the stale-`dist` rebuild comparison**

Before packing (in the `packed` branch) rebuild the bundles into a temp dir with
`PNGINE_BUNDLE_DIST_DIR=<scratch>/dist node npm/pngine/scripts/bundle.cjs` (the only redirect the
script honours; it takes no `--out`) and byte-compare each file against `npm/pngine/dist/`; a difference fails with `dist/<file> is stale; run
\`node npm/pngine/scripts/bundle.cjs\``. When `--tarballs` is provided, skip the rebuild and say
`dist freshness: not checked (provided tarballs)` in the detail line — a named gap, not a silence.

- [ ] **Step 6: Run T0 end to end**

Run: `node tests/packed-consumer/run.mjs --tier=t0`
Expected: `T0 package shape: PASS  subpaths=8 files=<n> tarballs=<n>`, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tests/packed-consumer/ && git commit -m "test(consumer): install the tarballs and assert the package shape"
```

---

### Task 3: T1 — compiler acceptance and the heap soak

**Files:**
- Create: `tests/packed-consumer/tiers/t1-compiler.mjs`
- Modify: `tests/packed-consumer/run.mjs` (register the tier)
- Test: `tests/packed-consumer/tiers/t1-compiler.test.mjs`

**Interfaces:**
- Consumes: `installInto`'s `nodeModules`.
- Produces: `runT1({ home, tarballs }): Promise<{ verdict, detail, numbers }>` with numbers
  `{ sourceBytes, rawBytes, pngBytes, edits, heapSettled }`.

- [ ] **Step 1: Write the failing test**

```js
test('a >1 MiB document compiles deterministically through the installed wrapper', async () => {
  const { home } = await installFixture();
  // Resolve through the SUBPATH, never a file path: the door the editor uses.
  const req = createRequire(join(home, 'package.json'));
  const { createCompiler } = await import(pathToFileURL(req.resolve('pngine/compiler')).href);
  const compiler = await createCompiler(pathToFileURL(req.resolve('pngine/wasm/pngine-compiler.wasm')).href);
  const source = makeDataFixture();            // tests/helpers/memcap-fixtures.js, imported by path
  const a = compiler.compile(source);
  const b = compiler.compile(source);
  assert.equal(a.errors, null);
  assert.deepEqual(Buffer.from(a.pngb), Buffer.from(b.pngb));
  compiler.destroy?.();
});
```

`pngine/compiler` and `pngine/wasm/pngine-compiler.wasm` are both resolved with
`createRequire(join(home,'package.json')).resolve(...)` so the assertion exercises the exports map.
`pngine/wasm/pngine-compiler.wasm` must be reachable by that specifier — if the exports map does not
expose it, that is a finding about the package, recorded as a red rather than worked around.

- [ ] **Step 2: Run it and watch it fail**

Run: `node --test tests/packed-consumer/tiers/t1-compiler.test.mjs`
Expected: FAIL — `Cannot find module .../tiers/t1-compiler.mjs`.

- [ ] **Step 3: Implement the five assertions in `t1-compiler.mjs`**

1. `≥1.25 MiB` source compiles; two compiles byte-identical (`rawBytes ≥ 1,310,720`).
2. `compileToPng` yields `pngBytes > 1,048,576`.
3. Twenty successive edits (append a distinct comment per round to the same document) all compile
   with `errors === null`.
4. A deliberate error (a dangling cross-reference) returns a non-empty `errors` naming it; the next
   good source compiles again.
5. Heap: four warm compiles, sample `heapBytes()`, twenty more; assert no growth after the last
   pre-measurement round and record the settled value.

- [ ] **Step 4: Add the pairing refusal**

Write the stub, do not hunt for one: `8` bytes — `00 61 73 6d 01 00 00 00` (magic + version, an empty
module) — into the temp home as `stub-compiler.wasm`, and hand it to the installed `createCompiler`.
Assert the rejection message contains `allocSource` and that no compile was attempted (the stub has
no exports to write through). Then assert the same call with the installed WASM still succeeds, so
the test cannot pass by refusing everything.

- [ ] **Step 5: Run T1**

Run: `node tests/packed-consumer/run.mjs --tier=t1`
Expected: `T1 compiler acceptance: PASS  source=1310792 raw=1311394 png=1318954 edits=20 heapSettled=<n>`.

- [ ] **Step 6: Commit**

```bash
git add tests/packed-consumer/ && git commit -m "test(consumer): accept the installed compiler at >1 MiB"
```

---

### Task 4: T1 long tail — install arms and the missing-binary remedy

**Files:**
- Modify: `tests/packed-consumer/lib/install.mjs`, `tests/packed-consumer/tiers/t1-compiler.mjs`
- Test: `tests/packed-consumer/lib/install-tail.test.mjs`

**Interfaces:**
- Consumes: `installInto`.
- Produces: `installArms({ home, tarballs }): Promise<Array<{ arm: string, ok: boolean, detail: string }>>`.

- [ ] **Step 1: Write the failing tests**

```js
test('a normal install and an --ignore-scripts install produce the same tree', async () => { ... });
test('removing the platform package makes the wrapper refuse with a named remedy', async () => {
  const { nodeModules } = await installFixture();
  rmSync(join(nodeModules, '@pngine'), { recursive: true, force: true });
  const out = await runBin(join(nodeModules, '.bin', 'pngine'), ['--version'])
    .catch((e) => e);
  assert.match(String(out.message ?? out.stdout), /@pngine\/linux-x64|npm install pngine/);
});
test('core and mini import under plain Node with no DOM', async () => {
  const core = await import(pathToFileURL(require.resolve('pngine/core', { paths: [home] })));
  assert.equal(typeof core.pngine, 'function');
});
```

- [ ] **Step 2: Run them and watch them fail**

Run: `node --test tests/packed-consumer/lib/install-tail.test.mjs`
Expected: FAIL — `Cannot find module './install.mjs'` for `installArms`, then the assertion failures.

- [ ] **Step 3: Implement `installArms`** — two temp homes, one with `--ignore-scripts`; compare the
  installed file lists (name + size) and fail naming the first difference. Export `runBin(binPath,
  argv)` that spawns with `stdio: 'pipe'` and rejects with `{ code, stdout, stderr }`. Wire the
  result into T1's numbers as `arms=<passed>/2` and `remedy=named|missing`.

- [ ] **Step 3: Run T1 again**

Run: `node tests/packed-consumer/run.mjs --tier=t1`
Expected: PASS, with `arms=2/2` and `remedy=named` in the numbers.

- [ ] **Step 4: Commit**

```bash
git add tests/packed-consumer/ && git commit -m "test(consumer): cover the install arms and the missing-binary remedy"
```

---

### Task 5: T2 — render on a hardware adapter

**Files:**
- Create: `tests/packed-consumer/tiers/t2-render.mjs`, `tests/packed-consumer/lib/browser.mjs`
- Modify: `tests/packed-consumer/run.mjs` (register the tier)
- Test: `tests/packed-consumer/tiers/t2-render.test.mjs`

**Interfaces:**
- Consumes: `installInto`'s `nodeModules`, and compiles its own payload through the installed
  compiler, so `--tier=t2` alone is a valid run and the tier never depends on T1 having run.
- Produces:
  - `connectHardware({ cdp?: string }): Promise<{ browser, adapter, close(): Promise<void> }>` — throws `software adapter: <arch>` when `architecture` matches `/swiftshader|llvmpipe|lavapipe|software/i`.
  - `runT2({ home, tarballs }): Promise<{ verdict, detail, numbers }>` with `{ adapter, pixel }`.

- [ ] **Step 1: Write the failing test** — a stub CDP endpoint that answers with a software adapter
  must produce `SKIPPED` with that reason, and never `PASS`.

- [ ] **Step 2: Implement `browser.mjs`** by copying the proven shape from
  `tests/e2e/qemus-test.js` and `/tmp/mac-verify`'s driver: `playwright-core` loaded by absolute
  path from the repo, `connectOverCDP`, an adapter probe on a routed localhost page, then the
  caller's page.

- [ ] **Step 3: Implement `t2-render.mjs`** — serve the temp home over a local HTTP server (the
  page imports the installed `pngine` bundle by relative path), `pngine()` a compiled PNG, draw,
  screenshot the canvas, decode the centre pixel through an OffscreenCanvas in-page, assert
  `[255,0,0,255]` (the memcap fixture's red).

- [ ] **Step 4: Run T2**

Run: `node tests/packed-consumer/run.mjs --tier=t2 --cdp=http://192.168.128.1:9222`
Expected: `T2 render: PASS  adapter=amd/rdna-1 pixel=255,0,0,255`. On this host without `--cdp`
the line must read `SKIPPED  no hardware adapter`.

- [ ] **Step 5: Commit**

```bash
git add tests/packed-consumer/ && git commit -m "test(consumer): render the installed runtime on a hardware adapter"
```

---

### Task 6: T3 — the Vite build path

**Files:**
- Create: `tests/packed-consumer/tiers/t3-vite.mjs`, `tests/packed-consumer/app/` (template: `index.html`, `main.js`, `vite.config.mjs`)
- Modify: `tests/packed-consumer/run.mjs` (register the tier)
- Test: `tests/packed-consumer/tiers/t3-vite.test.mjs`

**Interfaces:**
- Consumes: T2's `connectHardware`.
- Produces: `runT3({ home, tarballs, cdp }): Promise<{ verdict, detail, numbers }>` with
  `{ builtBytes, assets, checkoutPaths, pixel }`.

- [ ] **Step 1: Write the failing test** — a template that imports a nonexistent subpath must fail
  the build with the subpath named.

- [ ] **Step 2: Write the app template**, mirroring the editor: `import { pngine, draw } from 'pngine'`,
  `import { createCompiler } from 'pngine/compiler'`, `import schema from 'pngine/schema/pngine.sjon?raw'`,
  `new URL('pngine.wasm', import.meta.url)` built from the installed package, and
  `vite.config.mjs` with `pnginePlugin()` imported from the installed `vite-plugin-pngine`, `vite`
  linked by `file:` to the repo's own install.

- [ ] **Step 3: Implement `t3-vite.mjs`** — copy the template into the temp home, `npm install
  --offline` the linked tooling, run `vite build`, assert exit 0, then scan every emitted file for
  the repo root path (must be absent) and for the schema's first line (must be present, proving the
  `?raw` import resolved from node_modules).

- [ ] **Step 4: Serve the built `dist/` and render it** through T2's lane; assert the pixel.

- [ ] **Step 5: Run T3**

Run: `node tests/packed-consumer/run.mjs --tier=t3 --cdp=http://192.168.128.1:9222`
Expected: `T3 vite build: PASS  builtBytes=<n> assets=<n> checkoutPaths=0 pixel=255,0,0,255`.

- [ ] **Step 6: Commit**

```bash
git add tests/packed-consumer/ && git commit -m "test(consumer): build and render the installed package through vite"
```

---

### Task 7: Wire it up, record a run, and retire 03.5

**Files:**
- Modify: `package.json` (root) — add `"test:consumer": "node tests/packed-consumer/run.mjs --tier=all"`
- Create: `tests/packed-consumer/README.md`
- Modify: `tests/packed-consumer/run.mjs` and `tests/packed-consumer/lib/report.mjs` — retire the placeholder
- Modify: `docs/plans/memcap/03-verification-and-release.md` — replace the owner-carried 03.5 blocker with a pointer to this harness and the recorded run.

- [ ] **Step 0: Retire the scaffold.** Delete `report.placeholder()` and its call site; a tier module
  that is missing or unregistered now records `FAIL` with the module path in the detail, and the
  `SKIPPABLE` gate is the only way a tier may skip. Replace the `placeholder` test with the inverse:
  a missing `t1-compiler.mjs` produces `T1 …: FAIL  tier module not found: …` and a non-zero exit.
  This is the last task that may touch the scaffold path; after it, no code can skip without
  `SKIPPABLE`.

- [ ] **Step 1:** Add **two** root scripts — `"test:consumer": "node tests/packed-consumer/run.mjs
  --tier=all"` (the tiers) and `"test:consumer:unit": "node --test
  'tests/packed-consumer/**/*.test.mjs'"` (the harness's own suite) — and confirm
  `npm run test:consumer -- --tier=t0` selects only T0 and that `npm run test:consumer:unit` runs the
  unit tests. Until this step the unit suite is invoked by nobody; a gate nothing runs rots.
- [ ] **Step 2:** Write the README: what each tier proves, the flags, the named skips, the prerequisite
  commands (`zig build npm`, `zig build web-bundle`, `zig build wasm-compiler`), and the exact
  invocation on this host.
- [ ] **Step 3:** Run the whole thing and paste the report into the plan document, replacing 03.5.

Run: `npm run test:consumer -- --cdp=http://192.168.128.1:9222`
Expected: four PASS lines (or a named SKIPPED for T2/T3 when no `--cdp`), exit 0.

- [ ] **Step 4: Commit**

```bash
git add package.json tests/packed-consumer/README.md docs/plans/memcap/03-verification-and-release.md
git commit -m "test(consumer): wire the acceptance command and record the run"
```
