#!/bin/bash
# Build PngineCore.xcframework for iOS
#
# This script:
# 1. Builds Zig static libraries for all iOS targets
# 2. Combines arm64 + x86_64 simulator libs with lipo (if available)
# 3. Creates XCFramework for distribution
#
# Prerequisites:
# - Zig 0.14+ in PATH or at /Users/hugo/.zvm/bin/zig
# - wgpu-native iOS libraries in vendor/wgpu-native/ios/
# - Xcode with iOS SDK (not just Command Line Tools)
#
# Usage:
#   ./scripts/build-xcframework.sh
#
# Output:
#   native/build/PngineCore.xcframework

set -e

# Find zig - check common locations
if command -v zig &> /dev/null; then
    ZIG=$(command -v zig)
elif [ -f "/Users/hugo/.zvm/bin/zig" ]; then
    ZIG="/Users/hugo/.zvm/bin/zig"
elif [ -f "/opt/homebrew/opt/zigup/bin/zig" ]; then
    ZIG="/opt/homebrew/opt/zigup/bin/zig"
else
    echo "Error: zig not found in PATH or common locations"
    exit 1
fi
echo "Using zig: $ZIG"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/native/build"
ZIG_OUT="$ROOT_DIR/zig-out/lib"

echo "Building PngineCore.xcframework..."
echo "Root: $ROOT_DIR"

# Check for wgpu-native iOS libraries
if [ ! -f "$ROOT_DIR/vendor/wgpu-native/ios/device/lib/libwgpu_native.a" ]; then
    echo "Error: Missing wgpu-native iOS device library"
    echo "Download from: https://github.com/gfx-rs/wgpu-native/releases"
    echo "Expected at: vendor/wgpu-native/ios/device/lib/libwgpu_native.a"
    exit 1
fi

if [ ! -f "$ROOT_DIR/vendor/wgpu-native/ios/simulator/lib/libwgpu_native.a" ]; then
    echo "Error: Missing wgpu-native iOS simulator library"
    echo "Download from: https://github.com/gfx-rs/wgpu-native/releases"
    echo "Expected at: vendor/wgpu-native/ios/simulator/lib/libwgpu_native.a"
    exit 1
fi

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build for all iOS targets
echo "Building iOS libraries with Zig..."
cd "$ROOT_DIR"
$ZIG build native-ios

# Check build output
if [ ! -f "$ZIG_OUT/aarch64-ios/libpngine.a" ]; then
    echo "Error: Build failed - missing aarch64-ios/libpngine.a"
    exit 1
fi

# Create fat library for simulator (arm64 + x86_64)
echo "Creating fat library for simulator..."
if [ -f "$ZIG_OUT/x86_64-ios-simulator/libpngine.a" ]; then
    lipo -create \
        "$ZIG_OUT/aarch64-ios-simulator/libpngine.a" \
        "$ZIG_OUT/x86_64-ios-simulator/libpngine.a" \
        -output "$BUILD_DIR/libpngine-simulator.a"
else
    # x86_64 might not be available, use arm64 only
    cp "$ZIG_OUT/aarch64-ios-simulator/libpngine.a" "$BUILD_DIR/libpngine-simulator.a"
fi

# Copy device library
cp "$ZIG_OUT/aarch64-ios/libpngine.a" "$BUILD_DIR/libpngine-device.a"

# Create merged libraries (pngine + wgpu_native) using libtool
# libtool is better on macOS for merging static libraries
echo "Merging with wgpu_native..."

# Device: merge pngine + wgpu_native
libtool -static -o "$BUILD_DIR/libPngineCore-device.a" \
    "$BUILD_DIR/libpngine-device.a" \
    "$ROOT_DIR/vendor/wgpu-native/ios/device/lib/libwgpu_native.a"

# Simulator: merge pngine + wgpu_native
libtool -static -o "$BUILD_DIR/libPngineCore-simulator.a" \
    "$BUILD_DIR/libpngine-simulator.a" \
    "$ROOT_DIR/vendor/wgpu-native/ios/simulator/lib/libwgpu_native.a"

# Create XCFramework
echo "Creating XCFramework..."
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libPngineCore-device.a" \
    -headers "$ROOT_DIR/native/include" \
    -library "$BUILD_DIR/libPngineCore-simulator.a" \
    -headers "$ROOT_DIR/native/include" \
    -output "$BUILD_DIR/PngineCore.xcframework"

# Cleanup intermediate files
rm -f "$BUILD_DIR/libpngine-device.a"
rm -f "$BUILD_DIR/libpngine-simulator.a"
rm -f "$BUILD_DIR/libPngineCore-device.a"
rm -f "$BUILD_DIR/libPngineCore-simulator.a"

echo ""
echo "Success! Created: native/build/PngineCore.xcframework"
echo ""
echo "To use in Xcode:"
echo "  1. Drag PngineCore.xcframework into your project"
echo "  2. Add PngineKit Swift package from native/ios/PngineKit/"
echo "  3. import PngineKit in your Swift code"
