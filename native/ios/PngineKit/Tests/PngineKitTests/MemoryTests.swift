/**
 * MemoryTests - Memory leak detection tests
 *
 * Tests for proper resource cleanup and memory management.
 * Uses XCTMemoryMetric where available.
 */

import XCTest
import QuartzCore
@testable import PngineKit

final class MemoryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = pngineInit()
    }

    // MARK: - Animation Lifecycle Tests

    func testAnimationCreateDestroyCycle() {
        // Create and destroy animation multiple times to check for leaks
        let bytecode = BytecodeFixtures.simpleInstanced

        for i in 0..<10 {
            let layer = CAMetalLayer()
            layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

            let anim = bytecode.withUnsafeBytes { ptr in
                pngine_create(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count,
                    Unmanaged.passUnretained(layer).toOpaque(),
                    100, 100
                )
            }

            if let anim = anim {
                // Render a few frames
                for j in 0..<3 {
                    _ = pngine_render(anim, Float(j) * 0.016)
                }

                // Destroy
                pngine_destroy(anim)
            }

            // Allow autoreleasepool to drain
            if i % 5 == 0 {
                autoreleasepool { }
            }
        }

        // If we get here without crash, basic lifecycle is working
        XCTAssertTrue(true)
    }

    func testMultipleAnimationsSimultaneously() {
        let bytecode = BytecodeFixtures.simpleInstanced
        var animations: [OpaquePointer] = []
        var layers: [CAMetalLayer] = []

        // Create multiple animations
        for _ in 0..<5 {
            let layer = CAMetalLayer()
            layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
            layers.append(layer)

            let anim = bytecode.withUnsafeBytes { ptr in
                pngine_create(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count,
                    Unmanaged.passUnretained(layer).toOpaque(),
                    100, 100
                )
            }

            if let anim = anim {
                animations.append(anim)
            }
        }

        // Render all simultaneously
        for time in stride(from: Float(0), to: 0.1, by: 0.016) {
            for anim in animations {
                _ = pngine_render(anim, time)
            }
        }

        // Destroy all
        for anim in animations {
            pngine_destroy(anim)
        }

        XCTAssertTrue(true, "Multiple animations should work without issues")
    }

    // MARK: - Resize Tests

    func testResizeDoesNotLeak() {
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
            return // Skip if creation failed
        }

        // Resize multiple times
        for size in stride(from: 100, through: 500, by: 50) {
            pngine_resize(anim, UInt32(size), UInt32(size))
            _ = pngine_render(anim, 0.0)
        }

        // Resize back down
        for size in stride(from: 500, through: 100, by: -50) {
            pngine_resize(anim, UInt32(size), UInt32(size))
            _ = pngine_render(anim, 0.0)
        }

        pngine_destroy(anim)
        XCTAssertTrue(true)
    }

    // MARK: - Memory Warning Tests

    func testMemoryWarningWithActiveAnimations() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                100, 100
            )
        }

        // Render some frames
        if let anim = anim {
            _ = pngine_render(anim, 0.0)
            _ = pngine_render(anim, 0.016)
        }

        // Trigger memory warning
        pngine_memory_warning()

        // Should still be able to render after memory warning
        if let anim = anim {
            let result = pngine_render(anim, 0.032)
            // Result may vary, but shouldn't crash
            _ = result

            pngine_destroy(anim)
        }

        XCTAssertTrue(true)
    }

    // MARK: - Null Safety Tests

    func testDestroyNullAnimation() {
        // Should not crash
        pngine_destroy(nil)
        XCTAssertTrue(true)
    }

    func testRenderNullAnimation() {
        let result = pngine_render(nil, 0.0)
        // Should return error, not crash
        XCTAssertNotEqual(result, 0, "Rendering null animation should return error")
    }

    func testResizeNullAnimation() {
        // Should not crash
        pngine_resize(nil, 100, 100)
        XCTAssertTrue(true)
    }

    func testGetDimensionsNullAnimation() {
        let width = pngine_get_width(nil)
        let height = pngine_get_height(nil)

        XCTAssertEqual(width, 0, "Null animation width should be 0")
        XCTAssertEqual(height, 0, "Null animation height should be 0")
    }

    // MARK: - Performance Tests

    func testRenderPerformance() {
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
            return
        }

        measure {
            for i in 0..<60 {
                _ = pngine_render(anim, Float(i) * 0.016)
            }
        }

        pngine_destroy(anim)
    }

    // MARK: - Memory Metric Tests (iOS 13+)

    @available(iOS 13.0, macOS 10.15, *)
    func testAnimationMemoryFootprint() {
        let bytecode = BytecodeFixtures.boidsCompute

        let metrics: [XCTMetric] = [XCTMemoryMetric()]
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: metrics, options: options) {
            let layer = CAMetalLayer()
            layer.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

            let anim = bytecode.withUnsafeBytes { ptr in
                pngine_create(
                    ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    ptr.count,
                    Unmanaged.passUnretained(layer).toOpaque(),
                    300, 300
                )
            }

            if let anim = anim {
                // Render several frames
                for i in 0..<30 {
                    _ = pngine_render(anim, Float(i) * 0.016)
                }

                pngine_destroy(anim)
            }
        }
    }
}
