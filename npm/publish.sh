#!/usr/bin/env bash
set -e

# PNGine npm publish script
# Builds binaries, copies to npm dirs, publishes.
# Each `npm publish` requires a browser-generated OTP token.

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
ZIG_OUT="$ROOT/zig-out/npm"

PLATFORMS=(
  "darwin-arm64:pngine"
  "darwin-x64:pngine"
  "linux-arm64:pngine"
  "linux-x64:pngine"
  "win32-arm64:pngine.exe"
  "win32-x64:pngine.exe"
)
MAIN_PACKAGE=pngine

VERSION=$(grep '"version"' "$DIR/$MAIN_PACKAGE/package.json" | head -1 | sed 's/.*: "//;s/".*//')

echo "=== PNGine Publish Script (v$VERSION) ==="
echo ""

# Step 1: Run the gates
#
# These mirror `.githooks/pre-push` — the repo's only automated gate. This
# script used to run a lone default-mode `test-standalone`, which is weaker
# than what a normal push already has to pass; publishing on a weaker bar than
# pushing makes no sense.
echo "--- Running gates (same set as .githooks/pre-push) ---"
cd "$ROOT"
zig build drift
zig build test --summary all
zig build test-standalone -Doptimize=ReleaseFast --summary all
if [ "$(uname -s)" = "Darwin" ] && [ -f "$ROOT/vendor/wgpu-native/lib/libwgpu_native.a" ]; then
  zig build test-render
else
  echo "  no Metal host or no vendor/wgpu-native — render gates skipped"
fi
npm run test:types
npm run test:npm
echo "Gates passed"
echo ""

# Step 2: Build
#
# `wasm-compiler` is here because `npm/pngine`'s prepublishOnly hard-requires
# `wasm/pngine-compiler.wasm`, which is a gitignored build product that `zig
# build npm` does not produce. Without it a clean-machine run published six
# platform packages and then died on the seventh — the worst possible place to
# fail, since the platform versions are already public by then.
echo "--- Building npm binaries + wasm ---"
zig build npm
zig build web           # npm/pngine/wasm/pngine.wasm (runtime fallback)
zig build wasm-compiler # npm/pngine/wasm/pngine-compiler.wasm (prepublishOnly)
test -f "$DIR/pngine/wasm/pngine-compiler.wasm" || {
  echo "ERROR: wasm/pngine-compiler.wasm still missing after 'zig build wasm-compiler'" >&2
  exit 1
}
echo "Done"
echo ""

# Step 3: Copy binaries from zig-out to npm package dirs
echo "--- Copying binaries ---"
for entry in "${PLATFORMS[@]}"; do
  platform="${entry%%:*}"
  binary="${entry##*:}"
  src="$ZIG_OUT/pngine-$platform/bin/$binary"
  dst="$DIR/pngine-$platform/bin/$binary"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "  pngine-$platform ($(du -h "$dst" | cut -f1))"
  else
    echo "  ERROR: $src not found" >&2
    exit 1
  fi
done
if [ -f "$ZIG_OUT/pngine/wasm/pngine.wasm" ]; then
  mkdir -p "$DIR/pngine/wasm"
  cp "$ZIG_OUT/pngine/wasm/pngine.wasm" "$DIR/pngine/wasm/"
  echo "  pngine.wasm ($(du -h "$DIR/pngine/wasm/pngine.wasm" | cut -f1))"
fi
echo ""

# Step 4: Check npm login
echo "--- Checking npm login ---"
if ! npm whoami 2>/dev/null; then
  echo "Not logged in. Running npm login..."
  npm login
fi
echo "Logged in as: $(npm whoami)"
echo ""

# Step 5: Publish platform packages
echo "--- Publishing platform packages ---"
echo ""
for entry in "${PLATFORMS[@]}"; do
  platform="${entry%%:*}"
  echo "Publishing @pngine/$platform@$VERSION..."
  cd "$DIR/pngine-$platform"
  npm publish --access public
  echo ""
done

# Step 6: Publish main package
echo "--- Publishing main package ---"
echo ""
echo "Publishing pngine@$VERSION..."
cd "$DIR/$MAIN_PACKAGE"
npm publish
echo ""

echo "=== All packages published (v$VERSION) at $(date) ==="
