import { defineConfig } from 'vite'
import { readdirSync } from 'fs'
import { resolve } from 'path'

const PNGINE_SRC = resolve(__dirname, 'npm/pngine/src')

// Redirect every `./x.js` the playground imports to the LIVE npm/pngine/src
// module, so editing runtime JS shows up on reload without `zig build web`.
//
// This must cover ALL of npm/pngine/src, which is why it is read from the
// directory instead of hand-listed. build.zig copies the whole directory into
// zig-out/playground (a glob since §204, after the hand-list there rotted and
// shipped a dead demo), and vite's root IS zig-out/playground — so any name
// missing from this map silently resolves to the stale copy next to the HTML.
//
// Worse than stale: a page that imports both `./pngine.js` and any other src
// module would then get TWO instances of that module — the live one, reached
// through the aliased entry's own relative import, and the copied one, reached
// directly. So narrowing this to just the public entry is not a simplification;
// it is how the module graph forks in two. (The worked example used to be
// test-embedded-executor.html, importing `./pngine.js` and `./loader.js`
// together; it was deleted in §278, but the hazard is a property of the alias
// map, not of that page.)
//
// Aliases are matched on the specifier string globally, so a page-local module
// served from zig-out/playground must never share a basename with one in
// npm/pngine/src — it would silently resolve to the runtime module instead.
// Today no page ships one, so the rule costs nothing; it is a constraint on
// what may be added, not a description of a current collision.
const liveSrcAliases = Object.fromEntries(
  readdirSync(PNGINE_SRC)
    .filter((f) => f.endsWith('.js'))
    .map((f) => [`./${f}`, resolve(PNGINE_SRC, f)]),
)

export default defineConfig({
  define: { DEBUG: 'true' },
  root: 'zig-out/playground',
  appType: 'mpa',
  server: {
    port: 5173,
    open: false
  },
  assetsInclude: ['**/*.wasm'],
  build: {
    outDir: '../../dist-playground',
  },
  resolve: {
    alias: {
      ...liveSrcAliases,
      // build.zig installs index.js under the public name pngine.js; there is
      // no pngine.js in src/, so this cannot be derived from the directory.
      './pngine.js': resolve(PNGINE_SRC, 'index.js'),
    }
  }
})
