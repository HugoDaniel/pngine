#!/bin/bash
# Download wgpu-native libraries for all platforms
#
# This script downloads pre-built wgpu-native libraries from GitHub releases.
# These are required for native platform builds (iOS, macOS, etc.).
#
# Usage:
#   ./scripts/download-wgpu-native.sh          # All platforms
#   ./scripts/download-wgpu-native.sh ios      # iOS only
#   ./scripts/download-wgpu-native.sh macos    # macOS only

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

download_ios() {
    echo "Downloading wgpu-native for iOS..."

    # iOS device (arm64)
    download_and_extract \
        "ios-device" \
        "$BASE_URL/wgpu-ios-aarch64-release.zip" \
        "$VENDOR_DIR/ios/device"

    # iOS simulator (arm64)
    download_and_extract \
        "ios-simulator-arm64" \
        "$BASE_URL/wgpu-ios-aarch64-simulator-release.zip" \
        "$VENDOR_DIR/ios/simulator"

    echo "iOS libraries installed."
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

# Parse arguments
PLATFORM="${1:-all}"

case "$PLATFORM" in
    ios)
        download_ios
        ;;
    macos)
        download_macos
        ;;
    all)
        download_macos
        download_ios
        ;;
    *)
        echo "Usage: $0 [ios|macos|all]"
        exit 1
        ;;
esac

echo ""
echo "Done! wgpu-native libraries are in: vendor/wgpu-native/"
echo ""
echo "Next steps:"
echo "  - Build for macOS: zig build native"
echo "  - Build for iOS:   zig build native-ios"
echo "  - Create XCFramework: ./scripts/build-xcframework.sh"
