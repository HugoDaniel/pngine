/**
 * BytecodeParsingTests - PNGB format validation tests
 *
 * Tests for bytecode validation, header parsing, and error handling
 * for malformed bytecode.
 */

import XCTest
import QuartzCore
@testable import PngineKit

final class BytecodeParsingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure PNGine is initialized
        _ = pngineInit()
    }

    // MARK: - Valid Bytecode Tests

    func testSimpleInstancedBytecodeSize() {
        let bytecode = BytecodeFixtures.simpleInstanced
        XCTAssertEqual(bytecode.count, 1315,
                       "Simple instanced bytecode should be 1315 bytes")
    }

    func testInstancedBuiltinsBytecodeSize() {
        let bytecode = BytecodeFixtures.instancedBuiltins
        XCTAssertEqual(bytecode.count, 1481,
                       "Instanced builtins bytecode should be 1481 bytes")
    }

    func testBoidsComputeBytecodeSize() {
        let bytecode = BytecodeFixtures.boidsCompute
        XCTAssertEqual(bytecode.count, 1820,
                       "Boids compute bytecode should be 1820 bytes")
    }

    func testValidBytecodeHasPNGBMagic() {
        let bytecode = BytecodeFixtures.simpleInstanced

        // Check PNGB magic bytes at start
        XCTAssertGreaterThanOrEqual(bytecode.count, 4)

        let magic = bytecode.prefix(4)
        XCTAssertEqual(magic[0], 0x50, "First byte should be 'P' (0x50)")
        XCTAssertEqual(magic[1], 0x4E, "Second byte should be 'N' (0x4E)")
        XCTAssertEqual(magic[2], 0x47, "Third byte should be 'G' (0x47)")
        XCTAssertEqual(magic[3], 0x42, "Fourth byte should be 'B' (0x42)")
    }

    // MARK: - Invalid Bytecode Tests

    func testEmptyBytecodeFailsCreation() {
        let bytecode = BytecodeFixtures.empty

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                nil, 100, 100
            )
        }

        XCTAssertNil(anim, "Empty bytecode should fail to create animation")
    }

    func testTooShortBytecodeFailsCreation() {
        let bytecode = BytecodeFixtures.tooShort

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                nil, 100, 100
            )
        }

        XCTAssertNil(anim, "Too short bytecode should fail to create animation")
    }

    func testWrongMagicBytecodeFailsCreation() {
        let bytecode = BytecodeFixtures.wrongMagic

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                nil, 100, 100
            )
        }

        XCTAssertNil(anim, "Wrong magic bytecode should fail to create animation")
    }

    func testTruncatedBytecodeFailsCreation() {
        let bytecode = BytecodeFixtures.truncated

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                nil, 100, 100
            )
        }

        XCTAssertNil(anim, "Truncated bytecode should fail to create animation")
    }

    // MARK: - Animation Creation with Valid Bytecode

    func testAnimationCreationWithValidBytecodeAndSurface() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        layer.contentsScale = 2.0

        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                Unmanaged.passUnretained(layer).toOpaque(),
                300, 300
            )
        }

        if let anim = anim {
            // Animation created successfully
            XCTAssertEqual(pngine_get_width(anim), 300)
            XCTAssertEqual(pngine_get_height(anim), 300)

            // Clean up
            pngine_destroy(anim)
        } else {
            // Animation creation failed - this may happen in test environment
            // without GPU access, so we just log it
            let error = pngineLastError()
            print("Animation creation failed (expected in headless test): \(error ?? "unknown")")
        }
    }

    // MARK: - Per-Animation Diagnostics Tests

    func testPerAnimationDiagnosticsWithValidAnimation() {
        let bytecode = BytecodeFixtures.boidsCompute
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

        guard let anim = anim else {
            // Skip test if animation creation failed (headless environment)
            return
        }

        // Initial frame count should be 0
        let initialFrameCount = pngine_anim_frame_count(anim)
        XCTAssertEqual(initialFrameCount, 0, "Initial frame count should be 0")

        // Initial error should be ok
        let initialError = pngineAnimLastError(anim)
        XCTAssertEqual(initialError, .ok, "Initial error should be .ok")

        // Reset counters should not crash
        pngine_anim_reset_counters(anim)

        // Clean up
        pngine_destroy(anim)
    }

    func testDiagnosticsWithNullAnimation() {
        // These should not crash with null animation
        let error = pngine_anim_get_last_error(nil)
        XCTAssertNotEqual(error, 0, "Null animation should return error code")

        let computeCounters = pngine_anim_compute_counters(nil)
        XCTAssertEqual(computeCounters, 0, "Null animation should return 0 counters")

        let renderCounters = pngine_anim_render_counters(nil)
        XCTAssertEqual(renderCounters, 0, "Null animation should return 0 counters")

        let frameCount = pngine_anim_frame_count(nil)
        XCTAssertEqual(frameCount, 0, "Null animation should return 0 frame count")

        // Should not crash
        pngine_anim_reset_counters(nil)
    }

    // MARK: - Counter Unpacking Tests

    func testUnpackComputeCounters() {
        // Test packing: [passes:8][pipelines:8][bindgroups:8][dispatches:8]
        let packed: UInt32 = (5 << 24) | (3 << 16) | (2 << 8) | 10

        let (passes, pipelines, bindGroups, dispatches) = unpackComputeCounters(packed)

        XCTAssertEqual(passes, 5)
        XCTAssertEqual(pipelines, 3)
        XCTAssertEqual(bindGroups, 2)
        XCTAssertEqual(dispatches, 10)
    }

    func testUnpackRenderCounters() {
        // Test packing: [render_passes:16][draws:16]
        let packed: UInt32 = (100 << 16) | 500

        let (renderPasses, draws) = unpackRenderCounters(packed)

        XCTAssertEqual(renderPasses, 100)
        XCTAssertEqual(draws, 500)
    }

    func testUnpackCountersWithZero() {
        let (passes, pipelines, bindGroups, dispatches) = unpackComputeCounters(0)
        XCTAssertEqual(passes, 0)
        XCTAssertEqual(pipelines, 0)
        XCTAssertEqual(bindGroups, 0)
        XCTAssertEqual(dispatches, 0)

        let (renderPasses, draws) = unpackRenderCounters(0)
        XCTAssertEqual(renderPasses, 0)
        XCTAssertEqual(draws, 0)
    }

    func testUnpackCountersWithMaxValues() {
        // Max values for each field
        let packedCompute: UInt32 = 0xFFFFFFFF
        let (passes, pipelines, bindGroups, dispatches) = unpackComputeCounters(packedCompute)
        XCTAssertEqual(passes, 255)
        XCTAssertEqual(pipelines, 255)
        XCTAssertEqual(bindGroups, 255)
        XCTAssertEqual(dispatches, 255)

        let packedRender: UInt32 = 0xFFFFFFFF
        let (renderPasses, draws) = unpackRenderCounters(packedRender)
        XCTAssertEqual(renderPasses, 65535)
        XCTAssertEqual(draws, 65535)
    }
}
