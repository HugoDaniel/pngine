#!/bin/bash
# Download the wgpu-native library for this macOS host
#
# This script downloads a pre-built wgpu-native library from GitHub releases
# into vendor/wgpu-native/. It is what `-Dgpu-native` links against, so
# `pngine --frame` renders real pixels instead of the headless stub.
#
# Usage:
#   ./scripts/download-wgpu-native.sh

set -e

# wgpu-native version (check https://github.com/gfx-rs/wgpu-native/releases)
VERSION="v27.0.4.0"
BASE_URL="https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor/wgpu-native"

mkdir -p "$VENDOR_DIR"

download_and_extract() {
    local name=$1
    local url=$2
    local dest=$3

    echo "Downloading $name..."

    local tmp_zip="/tmp/wgpu-$name.zip"
    curl -L "$url" -o "$tmp_zip"

    mkdir -p "$dest"
    unzip -o "$tmp_zip" -d "$dest"
    rm "$tmp_zip"

    echo "  -> Installed to $dest"
}

download_macos() {
    echo "Downloading wgpu-native for macOS..."

    # Detect architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        download_and_extract \
            "macos-arm64" \
            "$BASE_URL/wgpu-macos-aarch64-release.zip" \
            "$VENDOR_DIR"
    else
        download_and_extract \
            "macos-x64" \
            "$BASE_URL/wgpu-macos-x86_64-release.zip" \
            "$VENDOR_DIR"
    fi

    echo "macOS libraries installed."
}

download_headers() {
    # Headers are included in any platform package
    # We'll use the ones from macOS if they don't exist
    if [ ! -f "$VENDOR_DIR/include/webgpu.h" ]; then
        echo "Headers already installed with platform libraries."
    fi
}

if [ $# -gt 0 ]; then
    echo "Usage: $0"
    echo "(the ios/macos/all modes went with the native platform bindings in 2026-08)"
    exit 1
fi

download_macos

echo ""
echo "Done! wgpu-native library is in: vendor/wgpu-native/"
echo ""
echo "Next step: zig build -Dgpu-native, then 'pngine <input>.sjon --frame'"
