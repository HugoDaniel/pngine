/**
 * ReferenceImageGenerator - Utilities for generating and managing reference images
 *
 * Provides synthetic reference patterns for testing the snapshot comparison utilities.
 *
 * Important: The generated references are simplified approximations of expected output,
 * NOT actual GPU-rendered frames. They use basic geometry checks (e.g., rectangular
 * bounding boxes instead of triangle intersection tests).
 *
 * For actual visual regression testing against GPU output:
 * - Use the CLI renderer to generate reference PNGs: `pngine shader.pngine --frame`
 * - Or use UI tests with captured screenshots
 *
 * This generator is primarily useful for:
 * - Testing the SnapshotComparator algorithm itself
 * - Smoke testing that reference generation utilities work
 * - Understanding expected output patterns for different fixtures
 */

import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import PngineKit

/// Utilities for generating and storing reference images.
public enum ReferenceImageGenerator {

    // MARK: - Reference Image Paths

    /// Directory for storing reference images (relative to test bundle).
    public static let referenceImageDirectory = "ReferenceImages"

    /// Get the expected reference image path for a fixture.
    public static func referenceImagePath(
        for fixture: String,
        config: SnapshotConfiguration
    ) -> String {
        let size = "\(Int(config.size.width))x\(Int(config.size.height))"
        let time = String(format: "%.2f", config.time)
        return "\(referenceImageDirectory)/\(fixture)_\(size)_t\(time).png"
    }

    // MARK: - Reference Data Generation

    /// Generate reference pixel data for a fixture.
    /// Returns RGBA8 pixel data that can be used for comparison.
    ///
    /// Note: This creates a solid color reference based on expected output characteristics.
    /// For actual GPU-rendered references, use the CLI rendering or UI tests.
    public static func generateReferenceData(
        for fixture: String,
        config: SnapshotConfiguration
    ) -> ReferenceData {
        let width = Int(config.size.width)
        let height = Int(config.size.height)
        let pixelCount = width * height
        let bytesPerPixel = 4

        // Generate expected reference based on fixture type
        var data = Data(count: pixelCount * bytesPerPixel)

        data.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)

            switch fixture {
            case "simpleInstanced":
                // 4 colored triangles at corners on black background
                generateSimpleInstancedReference(bytes: bytes, width: width, height: height)

            case "instancedBuiltins":
                // Same as simpleInstanced but using builtin indices
                generateSimpleInstancedReference(bytes: bytes, width: width, height: height)

            case "boidsCompute":
                // 64 particles in spiral pattern
                generateBoidsReference(bytes: bytes, width: width, height: height)

            default:
                // Default: black background
                for i in 0..<pixelCount {
                    let baseIdx = i * bytesPerPixel
                    bytes[baseIdx + 0] = 0      // R
                    bytes[baseIdx + 1] = 0      // G
                    bytes[baseIdx + 2] = 0      // B
                    bytes[baseIdx + 3] = 255    // A
                }
            }
        }

        return ReferenceData(
            pixelData: data,
            width: width,
            height: height,
            fixture: fixture,
            config: config
        )
    }

    // MARK: - Reference Generation Helpers

    /// Generate reference for simpleInstanced fixture.
    /// 4 triangles at corners: red (bottom-left), green (bottom-right), blue (top-left), yellow (top-right)
    private static func generateSimpleInstancedReference(
        bytes: UnsafeMutableBufferPointer<UInt8>,
        width: Int,
        height: Int
    ) {
        let bytesPerPixel = 4

        for y in 0..<height {
            for x in 0..<width {
                let pixelIdx = (y * width + x) * bytesPerPixel

                // Normalized coordinates (-1 to 1)
                let nx = Float(x) / Float(width) * 2.0 - 1.0
                let ny = Float(y) / Float(height) * 2.0 - 1.0

                // Default: black background
                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0

                // Check if in any of the 4 quadrants (simplified)
                // Real triangles would need proper triangle intersection
                let triangleSize: Float = 0.15
                let offset: Float = 0.5

                // Bottom-left (red)
                if nx < -offset + triangleSize && ny < -offset + triangleSize && nx > -offset - triangleSize {
                    r = 255
                }
                // Bottom-right (green)
                if nx > offset - triangleSize && ny < -offset + triangleSize && nx < offset + triangleSize {
                    g = 255
                }
                // Top-left (blue)
                if nx < -offset + triangleSize && ny > offset - triangleSize && nx > -offset - triangleSize {
                    b = 255
                }
                // Top-right (yellow)
                if nx > offset - triangleSize && ny > offset - triangleSize && nx < offset + triangleSize {
                    r = 255
                    g = 255
                }

                bytes[pixelIdx + 0] = r
                bytes[pixelIdx + 1] = g
                bytes[pixelIdx + 2] = b
                bytes[pixelIdx + 3] = 255
            }
        }
    }

    /// Generate reference for boidsCompute fixture.
    /// 64 particles in spiral pattern.
    private static func generateBoidsReference(
        bytes: UnsafeMutableBufferPointer<UInt8>,
        width: Int,
        height: Int
    ) {
        let bytesPerPixel = 4

        // Clear to black
        for i in 0..<(width * height * bytesPerPixel) {
            bytes[i] = i % 4 == 3 ? 255 : 0
        }

        // Draw 64 particles in spiral pattern
        for i in 0..<64 {
            let t = Float(i) / 64.0
            let angle = t * 6.28318
            let radius = 0.3 + t * 0.5

            // Position in normalized coordinates
            let px = cos(angle) * radius
            let py = sin(angle) * radius

            // Convert to pixel coordinates
            let screenX = Int((px * 0.5 + 0.5) * Float(width))
            let screenY = Int((py * 0.5 + 0.5) * Float(height))

            // Draw a small dot (3x3 pixels)
            for dy in -1...1 {
                for dx in -1...1 {
                    let x = screenX + dx
                    let y = screenY + dy

                    if x >= 0 && x < width && y >= 0 && y < height {
                        let pixelIdx = (y * width + x) * bytesPerPixel

                        // Color based on position
                        bytes[pixelIdx + 0] = UInt8(min(255, Int((px * 0.5 + 0.5) * 255)))
                        bytes[pixelIdx + 1] = UInt8(min(255, Int((py * 0.5 + 0.5) * 255)))
                        bytes[pixelIdx + 2] = 128
                        bytes[pixelIdx + 3] = 255
                    }
                }
            }
        }
    }

    // MARK: - Image Encoding

    /// Encode pixel data to PNG format.
    public static func encodePNG(
        data: Data,
        width: Int,
        height: Int
    ) -> Data? {
        #if os(iOS)
        guard let cgImage = createCGImage(from: data, width: width, height: height),
              let uiImage = UIImage(cgImage: cgImage).pngData() else {
            return nil
        }
        return uiImage
        #elseif os(macOS)
        guard let cgImage = createCGImage(from: data, width: width, height: height) else {
            return nil
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return pngData
        #endif
    }

    /// Create a CGImage from raw RGBA pixel data.
    private static func createCGImage(from data: Data, width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

// MARK: - Reference Data Container

/// Container for reference image data with metadata.
public struct ReferenceData {
    /// Raw RGBA8 pixel data.
    public let pixelData: Data

    /// Image width in pixels.
    public let width: Int

    /// Image height in pixels.
    public let height: Int

    /// Name of the fixture this reference is for.
    public let fixture: String

    /// Configuration used to generate this reference.
    public let config: SnapshotConfiguration

    /// Compare this reference against actual rendered data.
    public func compare(against actual: Data) -> SnapshotComparisonResult {
        return SnapshotComparator.compare(
            actual: actual,
            expected: pixelData,
            width: width,
            height: height,
            config: config
        )
    }

    /// Encode reference data to PNG format.
    public var pngData: Data? {
        return ReferenceImageGenerator.encodePNG(
            data: pixelData,
            width: width,
            height: height
        )
    }
}

// MARK: - Test Helpers

extension ReferenceImageGenerator {

    /// Print diagnostic information about a comparison failure.
    public static func printComparisonDiagnostics(
        fixture: String,
        result: SnapshotComparisonResult,
        config: SnapshotConfiguration
    ) {
        print("""
        === Snapshot Comparison Failed ===
        Fixture: \(fixture)
        Size: \(Int(config.size.width))x\(Int(config.size.height))
        Time: \(config.time)
        Required precision: \(config.precision)
        Actual match: \(String(format: "%.2f%%", result.matchPercentage * 100))
        Differing pixels: \(result.differingPixelCount) / \(result.totalPixelCount)
        Max pixel difference: \(result.maxDifference)
        ================================
        """)
    }

    /// Generate all reference images for standard fixtures.
    public static func generateAllReferences() -> [ReferenceData] {
        let fixtures = ["simpleInstanced", "instancedBuiltins", "boidsCompute"]
        var references: [ReferenceData] = []

        for fixture in fixtures {
            let config = SnapshotConfiguration.forFixture(fixture)
            let ref = generateReferenceData(for: fixture, config: config)
            references.append(ref)
        }

        return references
    }
}
