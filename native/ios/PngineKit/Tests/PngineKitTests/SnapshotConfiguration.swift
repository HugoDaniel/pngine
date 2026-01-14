/**
 * SnapshotConfiguration - Configuration for visual snapshot testing
 *
 * Controls precision, size, and frame timing for GPU rendering snapshot tests.
 * Allows per-test customization to handle GPU variance across devices/simulators.
 */

import Foundation
import CoreGraphics

/// Configuration for snapshot testing with adjustable precision.
public struct SnapshotConfiguration {
    /// Pixel comparison precision (0.0 to 1.0). Default is 0.985 to allow minor GPU differences.
    public var precision: Float

    /// Time value to render the frame at.
    public var time: Float

    /// Size to render at.
    public var size: CGSize

    /// Maximum allowed difference per pixel (0-255 range).
    public var maxPixelDifference: UInt8

    public init(
        precision: Float = 0.985,
        time: Float = 0.0,
        size: CGSize = CGSize(width: 300, height: 300),
        maxPixelDifference: UInt8 = 5
    ) {
        self.precision = precision
        self.time = time
        self.size = size
        self.maxPixelDifference = maxPixelDifference
    }

    // MARK: - Preset Configurations

    /// Default configuration for most tests.
    public static let `default` = SnapshotConfiguration()

    /// High precision for tests that should be nearly exact.
    public static let highPrecision = SnapshotConfiguration(
        precision: 0.99,
        maxPixelDifference: 2
    )

    /// Lower precision for compute shaders which may have floating point variance.
    public static let computeTolerant = SnapshotConfiguration(
        precision: 0.95,
        maxPixelDifference: 10
    )

    /// Small size for quick tests.
    public static let small = SnapshotConfiguration(
        size: CGSize(width: 100, height: 100)
    )

    /// Large size for detailed tests.
    public static let large = SnapshotConfiguration(
        size: CGSize(width: 512, height: 512)
    )

    // MARK: - Custom Mappings per Test

    /// Custom configurations for specific test fixtures that need special handling.
    public static let customMapping: [String: SnapshotConfiguration] = [
        "boidsCompute": .computeTolerant,
        "simpleInstanced": .default,
        "instancedBuiltins": .default,
    ]

    /// Get configuration for a named fixture, falling back to default.
    public static func forFixture(_ name: String) -> SnapshotConfiguration {
        return customMapping[name] ?? .default
    }
}

// MARK: - Snapshot Comparison Result

/// Result of comparing two images.
public struct SnapshotComparisonResult {
    /// Whether the comparison passed within the configured precision.
    public let passed: Bool

    /// Percentage of pixels that matched (0.0 to 1.0).
    public let matchPercentage: Float

    /// Number of pixels that differed beyond threshold.
    public let differingPixelCount: Int

    /// Total number of pixels compared.
    public let totalPixelCount: Int

    /// Maximum difference found in any single pixel channel.
    public let maxDifference: UInt8

    /// Human-readable description of the result.
    public var description: String {
        if passed {
            return "PASS: \(String(format: "%.2f", matchPercentage * 100))% match"
        } else {
            return "FAIL: \(String(format: "%.2f", matchPercentage * 100))% match " +
                   "(\(differingPixelCount)/\(totalPixelCount) pixels differ, max diff: \(maxDifference))"
        }
    }
}

// MARK: - Image Comparison Utilities

/// Utilities for comparing rendered images.
public enum SnapshotComparator {

    /// Compare two RGBA8 pixel buffers with the given configuration.
    /// - Parameters:
    ///   - actual: The rendered image data (RGBA8).
    ///   - expected: The reference image data (RGBA8).
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - config: Comparison configuration.
    /// - Returns: Comparison result with statistics.
    public static func compare(
        actual: Data,
        expected: Data,
        width: Int,
        height: Int,
        config: SnapshotConfiguration
    ) -> SnapshotComparisonResult {
        let totalPixels = width * height
        let bytesPerPixel = 4 // RGBA

        let expectedSize = totalPixels * bytesPerPixel
        guard actual.count == expected.count,
              actual.count == expectedSize else {
            return SnapshotComparisonResult(
                passed: false,
                matchPercentage: 0,
                differingPixelCount: totalPixels,
                totalPixelCount: totalPixels,
                maxDifference: 255
            )
        }

        // Bounds check: ensure buffer size matches our calculation
        assert(actual.count == expectedSize, "Buffer size mismatch: \(actual.count) != \(expectedSize)")

        var differingCount = 0
        var maxDiff: UInt8 = 0

        actual.withUnsafeBytes { actualPtr in
            expected.withUnsafeBytes { expectedPtr in
                let actualBytes = actualPtr.bindMemory(to: UInt8.self)
                let expectedBytes = expectedPtr.bindMemory(to: UInt8.self)

                for i in 0..<totalPixels {
                    let baseIdx = i * bytesPerPixel
                    var pixelDiffers = false

                    for channel in 0..<4 {
                        let idx = baseIdx + channel
                        let diff = abs(Int(actualBytes[idx]) - Int(expectedBytes[idx]))
                        if diff > Int(config.maxPixelDifference) {
                            pixelDiffers = true
                        }
                        maxDiff = max(maxDiff, UInt8(min(diff, 255)))
                    }

                    if pixelDiffers {
                        differingCount += 1
                    }
                }
            }
        }

        let matchPercentage = Float(totalPixels - differingCount) / Float(totalPixels)
        let passed = matchPercentage >= config.precision

        return SnapshotComparisonResult(
            passed: passed,
            matchPercentage: matchPercentage,
            differingPixelCount: differingCount,
            totalPixelCount: totalPixels,
            maxDifference: maxDiff
        )
    }

    /// Compare two CGImages with the given configuration.
    public static func compare(
        actual: CGImage,
        expected: CGImage,
        config: SnapshotConfiguration
    ) -> SnapshotComparisonResult? {
        guard actual.width == expected.width,
              actual.height == expected.height else {
            return nil
        }

        guard let actualData = extractPixelData(from: actual),
              let expectedData = extractPixelData(from: expected) else {
            return nil
        }

        return compare(
            actual: actualData,
            expected: expectedData,
            width: actual.width,
            height: actual.height,
            config: config
        )
    }

    /// Extract raw RGBA pixel data from a CGImage.
    private static func extractPixelData(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var pixelData = Data(count: totalBytes)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let success = pixelData.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? pixelData : nil
    }
}
