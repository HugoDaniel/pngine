#!/bin/bash
# Prepare npm packages for publishing
#
# This script copies built binaries from zig-out/npm to npm/ packages
#
# Usage:
#   zig build npm                    # Build all platform binaries
#   ./npm/pngine/scripts/prepare-publish.sh  # Prepare for publish

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ZIG_OUT="$ROOT_DIR/zig-out/npm"
NPM_DIR="$ROOT_DIR/npm"

echo "Preparing npm packages for publishing..."
echo ""

# Platform packages
PLATFORMS=(
    "darwin-arm64:pngine"
    "darwin-x64:pngine"
    "linux-arm64:pngine"
    "linux-x64:pngine"
    "win32-arm64:pngine.exe"
    "win32-x64:pngine.exe"
)

for entry in "${PLATFORMS[@]}"; do
    platform="${entry%%:*}"
    binary="${entry##*:}"

    src="$ZIG_OUT/pngine-$platform/bin/$binary"
    dst="$NPM_DIR/pngine-$platform/bin/$binary"

    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  Copied: pngine-$platform/bin/$binary ($(du -h "$dst" | cut -f1))"
    else
        echo "  Warning: $src not found"
    fi
done

# WASM
if [ -f "$ZIG_OUT/pngine/wasm/pngine.wasm" ]; then
    mkdir -p "$NPM_DIR/pngine/wasm"
    cp "$ZIG_OUT/pngine/wasm/pngine.wasm" "$NPM_DIR/pngine/wasm/"
    echo "  Copied: pngine/wasm/pngine.wasm ($(du -h "$NPM_DIR/pngine/wasm/pngine.wasm" | cut -f1))"
fi

echo ""
echo "Done! Packages ready for publishing:"
echo ""
echo "  # Publish platform packages first (order doesn't matter)"
for entry in "${PLATFORMS[@]}"; do
    platform="${entry%%:*}"
    echo "  cd $NPM_DIR/pngine-$platform && npm publish --access public"
done
echo ""
echo "  # Then publish main package"
echo "  cd $NPM_DIR/pngine && npm publish"
