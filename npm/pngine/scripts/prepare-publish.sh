#!/usr/bin/env bash
# Stage the built binaries and executor into the npm package directories.
#
#   zig build npm                            # cross-compile all platform binaries
#   ./npm/pngine/scripts/prepare-publish.sh  # copy them into npm/pngine-*/bin
#
# The platform set is the set of `npm/pngine-<os>-<cpu>/` directories — the
# same source of truth sync-versions.mjs and check-npm-metadata.mjs derive
# from — so adding a platform package is one directory, not three lists.
# A missing binary is an error: a platform package published without its
# binary installs a wrapper that resolves nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ZIG_OUT="$ROOT_DIR/zig-out/npm"
NPM_DIR="$ROOT_DIR/npm"

missing=0
for dir in "$NPM_DIR"/pngine-*/; do
    platform="$(basename "$dir")"          # pngine-darwin-arm64
    platform="${platform#pngine-}"         # darwin-arm64
    binary=pngine
    case "$platform" in win32-*) binary=pngine.exe ;; esac

    src="$ZIG_OUT/pngine-$platform/bin/$binary"
    dst="$NPM_DIR/pngine-$platform/bin/$binary"
    if [ -f "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  pngine-$platform/bin/$binary ($(du -h "$dst" | cut -f1))"
    else
        echo "  ERROR: $src not found — run \`zig build npm\`" >&2
        missing=1
    fi
done

# The runtime-fallback executor. `zig build npm` installs it here too; the
# committed copy is drift-gated against the build, so this is normally a no-op.
if [ -f "$ZIG_OUT/pngine/wasm/pngine.wasm" ]; then
    mkdir -p "$NPM_DIR/pngine/wasm"
    cp "$ZIG_OUT/pngine/wasm/pngine.wasm" "$NPM_DIR/pngine/wasm/"
    echo "  pngine/wasm/pngine.wasm ($(du -h "$NPM_DIR/pngine/wasm/pngine.wasm" | cut -f1))"
else
    echo "  ERROR: $ZIG_OUT/pngine/wasm/pngine.wasm not found — run \`zig build npm\`" >&2
    missing=1
fi

[ "$missing" = 0 ] || exit 1
echo "staged. Publish with ./npm/publish.sh (see docs/publishing.md)."
