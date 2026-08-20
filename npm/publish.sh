#!/usr/bin/env bash
# Build, verify and publish the npm packages: the six @pngine/<os>-<cpu>
# platform packages, then `pngine`.
#
# Usage:
#   ./npm/publish.sh              gates → build → stage → preflight → publish
#   ./npm/publish.sh --prepare    everything up to preflight; the registry is
#                                 not touched
#   ./npm/publish.sh --publish    publish only, from what --prepare staged
#   ./npm/publish.sh --allow-dirty ... proceed with uncommitted changes under
#                                 npm/, src/, schema/ or build.zig
#
# Publishing needs a terminal: the account has 2FA on writes, so every
# `npm publish` authenticates in the browser. Re-running is safe — a version
# already on the registry is skipped, so a run that stopped after platform
# package 5 continues at 6 rather than failing on "cannot publish over".
#
# `npm/vite-plugin-pngine` versions independently and is not published here.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
MAIN=pngine

MODE=full
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    --prepare) MODE=prepare ;;
    --publish) MODE=publish ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(node -p "require('$DIR/$MAIN/package.json').version")"
if [ -z "$VERSION" ]; then
  echo "npm/$MAIN/package.json has no version" >&2
  exit 1
fi

# The platform packages are the npm/pngine-<os>-<cpu>/ directories — the same
# source of truth sync-versions.mjs, check-npm-metadata.mjs and
# prepare-publish.sh derive from.
PLATFORMS=()
for d in "$DIR"/pngine-*/; do
  d="$(basename "$d")"
  PLATFORMS+=("${d#pngine-}")
done

step() { printf '\n\033[1m--- %s\033[0m\n' "$1"; }

# `published <pkg>` — true when <pkg>@$VERSION is on the registry.
published() {
  [ "$(npm view "$1@$VERSION" version 2>/dev/null)" = "$VERSION" ]
}

echo "pngine $VERSION — $MODE"

# ---------------------------------------------------------------------------
step "Preconditions"
cd "$ROOT"

# Version lockstep and the CHANGELOG heading (the same check drift runs).
node "$DIR/$MAIN/scripts/sync-versions.mjs" --check

# What ships must be committed. Uncommitted changes elsewhere (docs, the
# journal) are reported but do not block.
dirty_shipping="$(git status --porcelain -- npm src schema build.zig build.zig.zon | grep -v '^??' || true)"
dirty_other="$(git status --porcelain | grep -v '^??' | grep -vE '^.. (npm|src|schema)/|build\.zig(\.zon)?$' || true)"
if [ -n "$dirty_shipping" ]; then
  echo "uncommitted changes in what ships:" >&2
  echo "$dirty_shipping" >&2
  if [ "$ALLOW_DIRTY" = 1 ]; then
    echo "  --allow-dirty: continuing." >&2
  else
    echo "  commit them, or pass --allow-dirty." >&2
    exit 1
  fi
fi
[ -z "$dirty_other" ] || { echo "note: uncommitted changes outside the shipped tree:"; echo "$dirty_other"; }

if [ "$MODE" != publish ] && published "$MAIN"; then
  echo "$MAIN@$VERSION is already on the registry — bump the version first." >&2
  exit 1
fi

# The public release cut is a separate step (scripts/mirror.sh --tag); say
# whether it has happened, since a published package should point at a tag.
if git ls-remote --tags https://github.com/HugoDaniel/pngine.git "refs/tags/v$VERSION" 2>/dev/null | grep -q .; then
  echo "release cut: v$VERSION is tagged on github.com/HugoDaniel/pngine"
else
  echo "note: v$VERSION is not tagged on the public repo yet (./scripts/mirror.sh --tag …)"
fi

# ---------------------------------------------------------------------------
if [ "$MODE" != publish ]; then
  # Gates: the same set as .githooks/pre-push, in the same order. Publishing
  # must not clear a lower bar than pushing.
  step "Gates (the pre-push set)"
  zig fmt --check src tools tests build.zig
  zig build drift
  zig build test --summary all
  zig build test-standalone -Doptimize=ReleaseFast --summary all
  if [ "$(uname -s)" = "Darwin" ] && [ -f "$ROOT/vendor/wgpu-native/lib/libwgpu_native.a" ]; then
    zig build gen-render-snapshots
    zig build test-render
    # gen-render-snapshots rewrites tests/zig/render/ when a render moved. A
    # tree that changed here means the committed snapshots were stale.
    if [ -n "$(git status --porcelain -- tests/zig/render)" ]; then
      echo "gen-render-snapshots changed tests/zig/render/ — the committed snapshots were stale:" >&2
      git status --porcelain -- tests/zig/render >&2
      exit 1
    fi
  else
    echo "  no Metal host or no vendor/wgpu-native — render gates skipped"
  fi
  npm run test:types
  npm run test:npm
  echo "gates passed"

  # Build. `wasm-compiler` is here because npm/pngine's prepublishOnly requires
  # wasm/pngine-compiler.wasm, a gitignored build product that `zig build npm`
  # does not produce.
  step "Build (zig build npm / web / wasm-compiler)"
  zig build npm
  zig build web
  zig build wasm-compiler
  test -f "$DIR/$MAIN/wasm/pngine-compiler.wasm" || {
    echo "wasm/pngine-compiler.wasm missing after 'zig build wasm-compiler'" >&2
    exit 1
  }

  step "Stage binaries into the package directories"
  "$DIR/$MAIN/scripts/prepare-publish.sh"
fi

# ---------------------------------------------------------------------------
step "Verify the staged binaries"
# Every platform package must carry its binary; the host's must report the
# version being published, which catches a stale zig-out as well as a build
# that ran before the version bump.
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) host=darwin-arm64 ;;
  Darwin-x86_64) host=darwin-x64 ;;
  Linux-aarch64) host=linux-arm64 ;;
  Linux-x86_64) host=linux-x64 ;;
  *) host="" ;;
esac
for platform in "${PLATFORMS[@]}"; do
  binary=pngine
  case "$platform" in win32-*) binary=pngine.exe ;; esac
  path="$DIR/pngine-$platform/bin/$binary"
  [ -f "$path" ] || { echo "$path is missing — run ./npm/publish.sh --prepare" >&2; exit 1; }
  if [ "$platform" = "$host" ]; then
    # The CLI keeps stdout for artifacts; `version` prints on stderr.
    reported="$("$path" version 2>&1 || true)"
    if [ "$reported" != "pngine $VERSION" ]; then
      echo "$path reports '$reported', expected 'pngine $VERSION' — stale build" >&2
      exit 1
    fi
    echo "  $platform: $reported (host binary)"
  else
    echo "  $platform: $(du -h "$path" | cut -f1)"
  fi
done

# ---------------------------------------------------------------------------
step "Preflight (npm publish --dry-run, every package)"
# A dry run packs each package exactly as publish would — running
# npm/pngine's prepublishOnly (bundles + version check) included — without
# authenticating. Any `npm warn publish` is a manifest problem npm would
# otherwise auto-correct behind our back (a repository.url in a
# non-canonical form was one); fail on it here, before anything is public.
preflight_ok=1
for platform in "${PLATFORMS[@]}" ""; do
  if [ -n "$platform" ]; then pkg="pngine-$platform"; else pkg="$MAIN"; fi
  out="$(cd "$DIR/$pkg" && npm publish --dry-run --access public 2>&1)" || { echo "$out"; preflight_ok=0; continue; }
  if echo "$out" | grep -qE '^npm (warn publish|error)'; then
    echo "$out" | grep -E '^npm (warn publish|error)' | sed "s#^#  $pkg: #"
    preflight_ok=0
  else
    echo "  $pkg: $(echo "$out" | sed -n 's/^npm notice package size: //p') packed, $(echo "$out" | sed -n 's/^npm notice total files: //p') files"
  fi
done
[ "$preflight_ok" = 1 ] || { echo "preflight failed — nothing was published" >&2; exit 1; }

if [ "$MODE" = prepare ]; then
  echo
  echo "prepared. Nothing touched the registry. Publish from a terminal with:"
  echo "  ./npm/publish.sh --publish"
  exit 0
fi

# ---------------------------------------------------------------------------
step "Publish"
if [ ! -t 0 ]; then
  echo "publishing needs a terminal: every npm publish authenticates in the browser (2FA on writes)." >&2
  echo "run ./npm/publish.sh --publish from an interactive shell." >&2
  exit 1
fi
if ! npm whoami >/dev/null 2>&1; then
  echo "not logged in — running npm login"
  npm login
fi
echo "logged in as $(npm whoami)"

# Platform packages first: `pngine` pins them as optionalDependencies, and a
# consumer that installs between the two publishes silently drops all six.
for platform in "${PLATFORMS[@]}" ""; do
  if [ -n "$platform" ]; then pkg="pngine-$platform"; name="@pngine/$platform"; else pkg="$MAIN"; name="$MAIN"; fi
  if published "$name"; then
    echo "  $name@$VERSION already on the registry — skipped"
    continue
  fi
  echo "  publishing ${name}@${VERSION} ..."
  (cd "$DIR/$pkg" && npm publish --access public)
done

# ---------------------------------------------------------------------------
step "Registry"
# The registry's read side lags a publish by a few seconds; a package that
# was accepted a moment ago can still 404 here. Poll before calling it missing.
all_ok=1
for platform in "${PLATFORMS[@]}" ""; do
  if [ -n "$platform" ]; then name="@pngine/$platform"; else name="$MAIN"; fi
  seen=0
  for _ in 1 2 3 4 5 6; do
    if published "$name"; then seen=1; break; fi
    sleep 5
  done
  if [ "$seen" = 1 ]; then echo "  $name@$VERSION ok"; else echo "  $name@$VERSION MISSING after 30s"; all_ok=0; fi
done
[ "$all_ok" = 1 ] || exit 1
echo
echo "pngine $VERSION is published."
