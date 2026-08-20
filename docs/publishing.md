# NPM Package: Build & Publishing

> How the `pngine` npm package (and its 6 platform binary packages) is
> structured, built, and published.

PNGine is distributed as an npm package with native CLI binaries (similar to
esbuild).

## Package Structure

```
npm/
├── pngine/                      # Main package
│   ├── src/                     # JS sources (authoritative) — see the map below
│   ├── bin/pngine.cjs           # CLI wrapper (finds native binary)
│   ├── dist/                    # Bundled output (GITIGNORED, generated) — table below
│   ├── wasm/pngine.wasm         # WASM runtime fallback (~13K, used when PNG lacks embedded executor)
│   ├── wasm/pngine-compiler.wasm # In-browser compiler (~1.6M) — GITIGNORED build
│   │                            #   product of `zig build wasm-compiler`; prepublishOnly
│   │                            #   refuses to publish without it
│   ├── schema/pngine.sjon       # Committed copy of the repo-root schema (drift-gated
│   │                            #   by `zig build drift` — regen: `zig build wasm-compiler`)
│   ├── scripts/bundle.cjs       # esbuild bundler script
│   ├── package.json
│   └── README.md
│
├── vite-plugin-pngine/          # Vite plugin — versions and publishes independently
├── pngine-darwin-arm64/         # macOS Apple Silicon
├── pngine-darwin-x64/           # macOS Intel
├── pngine-linux-x64/            # Linux x64
├── pngine-linux-arm64/          # Linux ARM64
├── pngine-win32-x64/            # Windows x64
└── pngine-win32-arm64/          # Windows ARM64
    └── bin/pngine[.exe]         # Native binary
```

### `src/` by role

Grouped rather than listed: what matters is which of the six bundles a file
reaches, and each group is pulled in as a unit.

| Role | Files |
| ---- | ----- |
| **Profile entry points** (one per `exports` subpath) | `index.js` · `viewer.js` · `dev.js` · `core.js` · `executor.js` · `mini.js` |
| **Main thread** | `init.js` (dev) · `viewer-init.js` (viewer) · `init-core.js` (shared) · `anim.js` · `playback-state.js` (pure play/pause/time math) · `worker-errors.js` |
| **Worker** | `worker.js` (dev) · `worker-viewer.js` (viewer) · `worker-core.js` (shared orchestration) · `worker-prefetch.js` (thumbnail prefetch, dev only) |
| **GPU dispatch** | `gpu.js` · `gpu-resource-pass-commands.js` · `gpu-queue-commands.js` · `gpu-stats.js` · `descriptor-decode.js` · `enums.js` · `uniform-convert.js` |
| **Payload decode** | `loader.js` · `extract.js` · `detect.js` · `png-chunks.js` · `inflate.js` |
| **Other** | `compiler.js` (wasm-compiler wrapper) · `audio.js` (Sointu worklet player) |

The whole `src/` tree is published, not just the bundles — `files` lists
`src/`, and the authoring subpaths below resolve into it.

## Build Commands

```bash
# Build WASM + copy JS sources for development (outputs to zig-out/playground/)
zig build web

# Build minified production bundle (runs zig build web + esbuild)
zig build web-bundle

# Build all platform binaries (cross-compilation)
zig build npm

# Bundle JavaScript manually (creates dist/ files)
node npm/pngine/scripts/bundle.cjs         # Production (minified)
node npm/pngine/scripts/bundle.cjs --debug # Debug (source maps, no minify)

# Stage binaries for publishing (zig-out/npm → npm/pngine-*/bin)
./npm/pngine/scripts/prepare-publish.sh

# Gates → build → stage → dry-run → publish (see Publishing Workflow)
./npm/publish.sh
```

## Published Surface Beyond the Bundles

Besides the `dist/` bundles, the package ships the unbundled `src/` tree and
four authoring subpath exports — `pngine/compiler`, `pngine/compiler-wasm`,
`pngine/worker`, `pngine/schema/pngine.sjon` — so a consumer (an editor such as
**pstudio**, or any external tool) can resolve the whole engine from
node_modules instead of reaching into this repo. `npm`/`pnpm` pack the package
by the `files` allowlist, so anything a consumer needs at runtime **must** be
listed there. Two of these files are special:

- `wasm/pngine-compiler.wasm` is a **gitignored build product** — run
  `zig build wasm-compiler` (or `zig build web`) before publishing
  (`prepublishOnly` hard-fails without it), and before any `file:`-dependency
  install that expects the in-browser compiler.
- `schema/pngine.sjon` is a **committed copy** of the repo-root schema,
  refreshed by the same build step and byte-checked by `zig build drift`.

## JavaScript Build System

The JS runtime uses esbuild for bundling with two build modes:

| Mode       | Command                              | Features                                    |
| ---------- | ------------------------------------ | ------------------------------------------- |
| Production | `node scripts/bundle.cjs`            | Minified, `DEBUG=false`, strips debug logs  |
| Debug      | `node scripts/bundle.cjs --debug`    | Source maps, `DEBUG=true`, preserves logs   |

### Emitted bundles

One row per entry point `bundle.cjs` writes. The **budget** column is the gate
in `bundle.cjs`'s `SIZE_BUDGETS`, which fails the build when a bundle grows past
it — the durable number. Sizes are a measurement (2026-08-10, production) and
will drift; the budget is what holds them.

<!-- BUNDLE-TABLE: checked against scripts/bundle.cjs by `zig build drift` -->

| Bundle | Subpath | Profile | Size (gz) | Budget |
| ------ | ------- | ------- | --------- | ------ |
| `viewer.mjs` | `pngine` (browser), `pngine/viewer` | Lean production viewer; embedded-executor payloads only, worker inlined | 49.7 KB (17.0) | 51200 |
| `dev.mjs` | `pngine/dev` | Full-feature browser API: shared `pngine.wasm` fallback, prefetch, diagnostics | 54.3 KB (18.6) | 55800 |
| `core.mjs` | `pngine/core` | Low-level runtime API (dispatcher + loader), no main-thread wrapper | 26.6 KB (9.0) | 27300 |
| `executor.mjs` | `pngine/executor` | Executor helpers — `parsePayload`, `createExecutor`, imports | 1.9 KB (0.9) | 2200 |
| `mini.mjs` | `pngine/mini` | Flat pNGf main-thread player, with the Sointu audio worklet | 7.1 KB (3.3) | 7300 |
| `mini-no-audio.mjs` | `pngine/mini-no-audio` | `mini.js` built with `AUDIO=false` — the audio path is DCE'd, not branched around | 6.4 KB (3.0) | 6600 |
| `index.mjs` / `index.cjs` | `pngine` (node) | Generated stubs; every export throws "browser only" | 2.8 KB | — |
| `*.d.ts` | `types` per subpath | Hand-authored type text emitted by `writeTypeDefs()` | — | — |

`exports` is the package's real surface: a bundle without an `exports` subpath
is reachable by nobody (`exports` blocks deep imports with
`ERR_PACKAGE_PATH_NOT_EXPORTED`), whatever a `dist/` listing, a size table or
a README row says. Every bundle above has its subpath.

**Key optimization**: `gpu.js` uses a closure pattern instead of classes, so
every private binding is a local the minifier can rename. Shape (the real
returned object is much wider — `setMemory`, `setTime`, `setPointer`,
`setUniform`, `execute`, `destroy`, …):

```javascript
export function createCommandDispatcher(device, ctx) {
  let dbg = false;                  // becomes a single-letter var
  return { setDebug(v) { dbg = v; }, execute, destroy /* … */ };
}
```

**DEBUG flag usage**: `DEBUG` is an esbuild `--define`, so production strips the
whole statement; `dbg` is the per-instance runtime toggle behind it.

```javascript
DEBUG && dbg && console.log(`[GPU] Execute: ${cmdCount} cmds, ${totalLen}b`);
```

## Binary Sizes

| Platform     | Size |
| ------------ | ---- |
| darwin-arm64 | 2.9M |
| darwin-x64   | 3.2M |
| linux-x64    | 3.3M |
| linux-arm64  | 2.9M |
| win32-x64    | 3.6M |
| win32-arm64  | 3.1M |
| WASM         | ~13K |

> **Sizes are approximate and drift as executor variants are embedded.** The npm
> cross binaries are built with `strip = true` (build.zig), which drops DWARF
> debug info — this is the difference between the ~19M unstripped linux binary
> and the ~3.3M shipped one. The host `pngine` CLI (`zig build`) keeps its
> symbols for local debugging. On Windows, strip emits a separate `pngine.pdb`
> in `zig-out/`; `prepare-publish.sh` copies only the named `.exe`, so the PDB
> never ships.

**The platform binaries are build products — they are NOT committed.** They are
gitignored (`npm/pngine-*/bin/`) and regenerated per release by `zig build npm`
+ `npm/pngine/scripts/prepare-publish.sh`. `bin/pngine.cjs` resolves the right
one at runtime via `require.resolve`, so a fresh clone just runs those two
commands before publishing.

## Version Lockstep

`npm/pngine` is the single source of truth for the release version. Its six
`optionalDependencies` pins and the six `npm/pngine-<os>-<cpu>/package.json`
versions must all match it — one missed bump ships a wrapper that resolves the
wrong binary (or none).

`npm/pngine/scripts/sync-versions.mjs` keeps them locked:

```bash
# Stamp every platform package + optionalDependencies pin to npm/pngine's version
node npm/pngine/scripts/sync-versions.mjs

# Assert lockstep (exit 1 with a drift report) — also runs under `npm test`
node npm/pngine/scripts/sync-versions.mjs --check
```

It edits only the version *values*, preserving each file's hand-authored
formatting (inline `"os": ["darwin"]` arrays and the like). It is wired so drift
can't ship:

- `npm/pngine`'s `version` script stamps + stages all platform packages during
  `npm version <bump>`.
- `npm/pngine`'s `prepublishOnly` runs `--check`, so a drifted `npm publish`
  aborts.
- `tests/npm/version-sync.test.js` runs `--check` under `npm test`.

Adding or removing a platform package is a deliberate act: the script reports
such structural drift but never rewrites the pin set for you.

**A bump has a consequence for downstream consumers, worth knowing before you
cut one.** Between the bump and the publish, the six new `@pngine/*` pins
resolve to nothing on the registry. pnpm skips unresolvable **optional**
dependencies silently, so a consumer that reinstalls in that window simply
drops all six entries from its lockfile and ends up with no native `pngine` CLI
binary. It is not an error and nothing warns. Publish the platform packages
first (step 2 below), then have consumers reinstall.

## Publishing Workflow

`npm/vite-plugin-pngine` versions independently and publishes separately —
plain `npm publish` from its directory (its `prepublishOnly` rebuilds the
gitignored `dist/` and runs its vitest suite).

**Bump the version and update `CHANGELOG.md` in the same commit.**
`sync-versions.mjs --check` (part of `zig build drift`) requires the
changelog's newest released heading to match the package version, so a bump
without an entry fails the gate.

`npm/publish.sh` is the whole procedure:

```bash
./npm/publish.sh --prepare   # gates (the pre-push set) → zig build npm/web/wasm-compiler
                             # → stage binaries → npm publish --dry-run for every package
./npm/publish.sh --publish   # publish, from a terminal: platform packages first, then pngine
./npm/publish.sh             # both in one run
```

What it refuses, and why:

- uncommitted changes under `npm/`, `src/`, `schema/` or `build.zig` — what
  ships must be a commit (`--allow-dirty` overrides);
- `pngine@<version>` already on the registry — bump first;
- `gen-render-snapshots` moving `tests/zig/render/` — the committed snapshots
  were stale;
- a staged host binary that does not report `pngine <version>` — a stale
  `zig-out` or a build from before the bump;
- any `npm warn publish` in the dry run — a manifest npm would otherwise
  auto-correct at publish time (a non-canonical `repository.url` was one).

Publishing needs a terminal: the account has 2FA on writes, so each `npm
publish` authenticates in the browser. **Re-running is safe** — a version
already on the registry is skipped, so a run that stopped after platform
package five continues at six instead of failing on "cannot publish over a
previously published version". Platform packages go first because `pngine`
pins them as `optionalDependencies` and a consumer installing between the two
silently drops all six.

The steps the script runs, for doing them by hand:

```bash
zig build npm && zig build web && zig build wasm-compiler
./npm/pngine/scripts/prepare-publish.sh          # zig-out/npm → npm/pngine-*/bin
for p in npm/pngine-*/; do (cd "$p" && npm publish --access public); done
(cd npm/pngine && npm publish)                   # prepublishOnly bundles + checks lockstep
```

## Usage

```bash
# Install
npm install pngine

# CLI usage (uses native binary)
npx pngine compile shader.sjon -o output.pngb
npx pngine shader.sjon -o output.png --frame
```

```javascript
// Browser usage
import { play, pngine } from "pngine";

const canvas = document.getElementById("canvas");
const p = await pngine("shader.png", { canvas });
play(p);
```

## Build System Integration

The `build.zig` npm step:

- Cross-compiles CLI for 6 platforms using `b.resolveTargetQuery()`
- Uses `has_embedded_wasm = false` for cross-compiled builds (WASM not available
  at cross-compile time)
- Outputs to `zig-out/npm/pngine-{platform}/bin/`
