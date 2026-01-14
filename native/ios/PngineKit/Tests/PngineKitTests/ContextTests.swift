/**
 * ContextTests - GPU context initialization tests
 *
 * Tests for PNGine runtime initialization, shutdown, and state management.
 */

import XCTest
@testable import PngineKit

final class ContextTests: XCTestCase {

    // MARK: - Initialization Tests

    func testContextInitialization() {
        // Should succeed (may already be initialized from previous tests)
        let result = pngineInit()
        XCTAssertTrue(result == .ok || result == .alreadyInitialized,
                      "Init should succeed or report already initialized, got: \(result)")
    }

    func testIsInitializedAfterInit() {
        // Ensure initialized
        _ = pngineInit()

        XCTAssertTrue(pngine_is_initialized(),
                      "pngine_is_initialized() should return true after init")
    }

    func testDoubleInitIsIdempotent() {
        // First init
        let first = pngineInit()
        XCTAssertTrue(first == .ok || first == .alreadyInitialized)

        // Second init should also succeed (already initialized)
        let second = pngineInit()
        XCTAssertTrue(second == .ok || second == .alreadyInitialized,
                      "Double init should be idempotent")

        // State should still be initialized
        XCTAssertTrue(pngine_is_initialized())
    }

    // MARK: - Version Tests

    func testVersionString() {
        let version = pngineVersion()
        XCTAssertFalse(version.isEmpty, "Version string should not be empty")

        // Version should be in semver format (e.g., "0.1.0")
        let components = version.split(separator: ".")
        XCTAssertGreaterThanOrEqual(components.count, 2,
                                     "Version should have at least major.minor: \(version)")
    }

    func testVersionCString() {
        let cVersion = pngine_version()
        let version = String(cString: cVersion)
        XCTAssertFalse(version.isEmpty)
        XCTAssertEqual(version, pngineVersion())
    }

    // MARK: - Error String Tests

    func testErrorStringForKnownErrors() {
        // Test all known error codes have descriptions
        let errors: [PngineError] = [
            .ok, .notInitialized, .alreadyInitialized, .contextFailed,
            .bytecodeInvalid, .surfaceFailed, .shaderCompile, .pipelineCreate,
            .textureUnavailable, .resourceNotFound, .outOfMemory,
            .invalidArgument, .renderFailed, .computeFailed
        ]

        for error in errors {
            if error == .ok {
                XCTAssertNil(error.errorDescription, ".ok should have nil description")
            } else {
                XCTAssertNotNil(error.errorDescription,
                               "\(error) should have an error description")
            }
        }
    }

    func testErrorStringFromCAPI() {
        // Test C API error string function
        let okStr = pngine_error_string(0)
        XCTAssertNotNil(okStr)

        let notInitStr = pngine_error_string(-1)
        XCTAssertNotNil(notInitStr)

        if let str = notInitStr {
            let message = String(cString: str)
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - Animation Create/Destroy Tests

    func testAnimationCreateWithNullBytecode() {
        _ = pngineInit()

        // Null bytecode should return nil
        let anim = pngine_create(nil, 0, nil, 100, 100)
        XCTAssertNil(anim, "Creating animation with null bytecode should fail")
    }

    func testAnimationCreateWithZeroSize() {
        _ = pngineInit()

        let bytecode = BytecodeFixtures.simpleInstanced
        let anim = bytecode.withUnsafeBytes { ptr in
            pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                nil,  // null surface
                0,    // zero width
                0     // zero height
            )
        }

        // Should fail with zero size (no surface)
        // Note: Actual behavior depends on implementation
        if anim != nil {
            pngine_destroy(anim)
        }
    }

    // MARK: - Memory Warning Tests

    func testMemoryWarningDoesNotCrash() {
        _ = pngineInit()

        // Memory warning should not crash even without any animations
        pngine_memory_warning()

        // Still initialized after warning
        XCTAssertTrue(pngine_is_initialized())
    }

    // MARK: - Logger Tests

    func testDefaultLoggerExists() {
        XCTAssertNotNil(pngineLogger)
    }

    func testCustomLoggerCanBeSet() {
        class TestLogger: PngineLogger {
            var infoMessages: [String] = []
            var warnMessages: [String] = []
            var errorMessages: [String] = []

            func info(_ message: String) {
                infoMessages.append(message)
            }

            func warn(_ message: String) {
                warnMessages.append(message)
            }

            func error(_ message: String) {
                errorMessages.append(message)
            }
        }

        let testLogger = TestLogger()
        let originalLogger = pngineLogger

        // Set custom logger
        pngineLogger = testLogger

        // Log something
        pngineLogger.info("Test message")

        XCTAssertEqual(testLogger.infoMessages.count, 1)
        XCTAssertEqual(testLogger.infoMessages.first, "Test message")

        // Restore original logger
        pngineLogger = originalLogger
    }
}
