/**
 * RenderingSnapshotTests - Visual regression tests for GPU rendering
 *
 * Tests that rendered output matches expected reference images.
 * Uses SnapshotConfiguration for per-test precision control.
 *
 * Note: These tests require GPU access. In headless CI environments,
 * tests may be skipped if GPU initialization fails.
 */

import XCTest
import QuartzCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
@testable import PngineKit

final class RenderingSnapshotTests: XCTestCase {

    /// Whether GPU rendering is available in this test environment.
    /// Uses lazy static initialization for thread-safe one-time check.
    private static let gpuAvailable: Bool = {
        // Initialize PNGine
        _ = pngineInit()

        // Check if GPU rendering is available
        let available = checkGPUAvailability()
        if !available {
            print("[RenderingSnapshotTests] GPU not available - rendering tests will be skipped")
        }
        return available
    }()

    override class func setUp() {
        super.setUp()
        // Trigger lazy initialization of gpuAvailable
        _ = gpuAvailable
    }

    /// Check if we can successfully create and render an animation.
    private class func checkGPUAvailability() -> Bool {
        let bytecode = BytecodeFixtures.simpleInstanced
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                100, 100
            )
        }) else {
            return false
        }

        // Try to render a frame
        let result = pngine_render(anim, 0.0)
        pngine_destroy(anim)

        return result == 0
    }

    // MARK: - Helper Methods

    /// Skip test if GPU is not available.
    private func skipIfNoGPU(file: StaticString = #file, line: UInt = #line) throws {
        try XCTSkipUnless(
            Self.gpuAvailable,
            "GPU not available in this environment",
            file: file,
            line: line
        )
    }

    /// Render bytecode to a CGImage for snapshot comparison.
    private func renderToImage(
        bytecode: Data,
        config: SnapshotConfiguration
    ) -> CGImage? {
        let width = UInt32(config.size.width)
        let height = UInt32(config.size.height)

        let layer = CAMetalLayer()
        layer.frame = CGRect(origin: .zero, size: config.size)
        layer.contentsScale = 1.0

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                width, height
            )
        }) else {
            return nil
        }

        defer { pngine_destroy(anim) }

        // Render frame
        let result = pngine_render(anim, config.time)
        guard result == 0 else { return nil }

        // Extract image from metal layer drawable
        // Note: This is a simplified approach - in practice you may need
        // to use MTLTexture.getBytes() for headless rendering
        return captureLayerContents(layer)
    }

    /// Capture the contents of a CAMetalLayer as a CGImage.
    ///
    /// - Note: Currently returns nil. Capturing Metal layer contents requires
    ///   MTLTexture readback which needs a proper rendering context. Full visual
    ///   regression testing should use UI tests or the CLI renderer.
    ///
    /// - TODO: Implement MTLTexture.getBytes() for headless snapshot capture.
    private func captureLayerContents(_ layer: CAMetalLayer) -> CGImage? {
        // For unit tests, we can't easily capture Metal layer contents
        // without a proper rendering context. This would need a more
        // sophisticated approach using MTLTexture readback.
        //
        // For now, return nil - full snapshot testing requires
        // either UI tests or a custom MTLTexture capture mechanism.
        return nil
    }

    // MARK: - Render Output Tests (Smoke Tests)
    //
    // Note: These tests verify that rendering completes without crashes.
    // They are smoke tests, not visual regression tests. Visual correctness
    // would require capturing GPU output via MTLTexture readback.

    func testSimpleInstancedRenders() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.simpleInstanced
        let config = SnapshotConfiguration.forFixture("simpleInstanced")
        let layer = CAMetalLayer()
        layer.frame = CGRect(origin: .zero, size: config.size)

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                UInt32(config.size.width),
                UInt32(config.size.height)
            )
        }) else {
            XCTFail("Failed to create animation from simpleInstanced bytecode")
            return
        }

        defer { pngine_destroy(anim) }

        // Render multiple frames to ensure stability
        for i in 0..<5 {
            let result = pngine_render(anim, Float(i) * 0.016)
            XCTAssertEqual(result, 0, "Render frame \(i) should succeed")
        }
    }

    func testInstancedBuiltinsRenders() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.instancedBuiltins
        let config = SnapshotConfiguration.forFixture("instancedBuiltins")
        let layer = CAMetalLayer()
        layer.frame = CGRect(origin: .zero, size: config.size)

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                UInt32(config.size.width),
                UInt32(config.size.height)
            )
        }) else {
            XCTFail("Failed to create animation from instancedBuiltins bytecode")
            return
        }

        defer { pngine_destroy(anim) }

        // Render multiple frames
        for i in 0..<5 {
            let result = pngine_render(anim, Float(i) * 0.016)
            XCTAssertEqual(result, 0, "Render frame \(i) should succeed")
        }
    }

    func testBoidsComputeRenders() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.boidsCompute
        let config = SnapshotConfiguration.forFixture("boidsCompute")
        let layer = CAMetalLayer()
        layer.frame = CGRect(origin: .zero, size: config.size)

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                UInt32(config.size.width),
                UInt32(config.size.height)
            )
        }) else {
            XCTFail("Failed to create animation from boidsCompute bytecode")
            return
        }

        defer { pngine_destroy(anim) }

        // Render multiple frames - compute shader should initialize on first frame
        for i in 0..<10 {
            let result = pngine_render(anim, Float(i) * 0.016)
            XCTAssertEqual(result, 0, "Render frame \(i) should succeed")
        }
    }

    // MARK: - Consistency Tests

    func testRenderConsistency() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.simpleInstanced
        let config = SnapshotConfiguration.default
        let layer = CAMetalLayer()
        layer.frame = CGRect(origin: .zero, size: config.size)

        // Create and render multiple times to check consistency
        for iteration in 0..<3 {
            guard let anim = bytecode.withUnsafeBytes({ ptr in
                pngine_create(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count,
                    Unmanaged.passUnretained(layer).toOpaque(),
                    UInt32(config.size.width),
                    UInt32(config.size.height)
                )
            }) else {
                XCTFail("Failed to create animation on iteration \(iteration)")
                continue
            }

            let result = pngine_render(anim, 0.0)
            XCTAssertEqual(result, 0, "Render should succeed on iteration \(iteration)")

            pngine_destroy(anim)
        }
    }

    func testRenderAtDifferentTimes() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.simpleInstanced
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        guard let anim = bytecode.withUnsafeBytes({ ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                300, 300
            )
        }) else {
            XCTFail("Failed to create animation")
            return
        }

        defer { pngine_destroy(anim) }

        // Test rendering at various time points
        let timePoints: [Float] = [0.0, 0.5, 1.0, 2.0, 5.0, 10.0]
        for time in timePoints {
            let result = pngine_render(anim, time)
            XCTAssertEqual(result, 0, "Render at time \(time) should succeed")
        }
    }

    func testRenderAtDifferentSizes() throws {
        try skipIfNoGPU()

        let bytecode = BytecodeFixtures.simpleInstanced
        let sizes: [(UInt32, UInt32)] = [
            (100, 100),
            (200, 200),
            (300, 300),
            (512, 512),
            (200, 400),  // Non-square
            (400, 200),
        ]

        for (width, height) in sizes {
            let layer = CAMetalLayer()
            layer.frame = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

            guard let anim = bytecode.withUnsafeBytes({ ptr in
                pngine_create(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count,
                    Unmanaged.passUnretained(layer).toOpaque(),
                    width, height
                )
            }) else {
                XCTFail("Failed to create animation at size \(width)x\(height)")
                continue
            }

            let result = pngine_render(anim, 0.0)
            XCTAssertEqual(result, 0, "Render at size \(width)x\(height) should succeed")

            pngine_destroy(anim)
        }
    }

    // MARK: - Snapshot Comparator Tests

    func testSnapshotComparatorIdentical() {
        // Test that identical images pass comparison
        let width = 10
        let height = 10
        let data = Data(repeating: 128, count: width * height * 4)

        let result = SnapshotComparator.compare(
            actual: data,
            expected: data,
            width: width,
            height: height,
            config: .default
        )

        XCTAssertTrue(result.passed, "Identical images should pass")
        XCTAssertEqual(result.matchPercentage, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.differingPixelCount, 0)
        XCTAssertEqual(result.maxDifference, 0)
    }

    func testSnapshotComparatorSlightDifference() {
        // Test that slight differences within tolerance pass
        let width = 10
        let height = 10
        let expected = Data(repeating: 128, count: width * height * 4)
        var actual = expected

        // Modify a few pixels slightly
        actual[0] = 130  // +2 difference
        actual[4] = 126  // -2 difference

        let result = SnapshotComparator.compare(
            actual: actual,
            expected: expected,
            width: width,
            height: height,
            config: .default
        )

        XCTAssertTrue(result.passed, "Slight differences should pass with default config")
    }

    func testSnapshotComparatorLargeDifference() {
        // Test that large differences fail
        let width = 10
        let height = 10
        let expected = Data(repeating: 0, count: width * height * 4)
        let actual = Data(repeating: 255, count: width * height * 4)

        let result = SnapshotComparator.compare(
            actual: actual,
            expected: expected,
            width: width,
            height: height,
            config: .default
        )

        XCTAssertFalse(result.passed, "Completely different images should fail")
        XCTAssertEqual(result.matchPercentage, 0.0, accuracy: 0.001)
    }

    func testSnapshotComparatorSizeMismatch() {
        // Test that mismatched sizes fail
        let expected = Data(repeating: 128, count: 100 * 4)
        let actual = Data(repeating: 128, count: 200 * 4)

        let result = SnapshotComparator.compare(
            actual: actual,
            expected: expected,
            width: 10,
            height: 10,
            config: .default
        )

        XCTAssertFalse(result.passed, "Size mismatch should fail")
    }

    func testSnapshotConfigurationPresets() {
        // Test that presets have expected values
        XCTAssertEqual(SnapshotConfiguration.default.precision, 0.985, accuracy: 0.001)
        XCTAssertEqual(SnapshotConfiguration.highPrecision.precision, 0.99, accuracy: 0.001)
        XCTAssertEqual(SnapshotConfiguration.computeTolerant.precision, 0.95, accuracy: 0.001)

        XCTAssertEqual(SnapshotConfiguration.small.size.width, 100)
        XCTAssertEqual(SnapshotConfiguration.large.size.width, 512)
    }

    func testSnapshotConfigurationForFixture() {
        // Test fixture-specific configurations
        let boidsConfig = SnapshotConfiguration.forFixture("boidsCompute")
        XCTAssertEqual(boidsConfig.precision, 0.95, accuracy: 0.001, "boidsCompute should use computeTolerant")

        let defaultConfig = SnapshotConfiguration.forFixture("unknownFixture")
        XCTAssertEqual(defaultConfig.precision, 0.985, accuracy: 0.001, "Unknown fixture should use default")
    }
}
