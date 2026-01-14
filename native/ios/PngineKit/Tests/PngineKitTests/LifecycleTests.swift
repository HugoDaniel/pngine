/**
 * LifecycleTests - Background/foreground behavior tests
 *
 * Tests for PngineBackgroundBehavior enum and lifecycle management.
 */

import XCTest
import QuartzCore
import SwiftUI
@testable import PngineKit

final class LifecycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = pngineInit()
    }

    // MARK: - Background Behavior Enum Tests

    func testBackgroundBehaviorEnumValues() {
        // Verify all enum cases exist
        let stop: PngineBackgroundBehavior = .stop
        let pause: PngineBackgroundBehavior = .pause
        let pauseAndRestore: PngineBackgroundBehavior = .pauseAndRestore

        XCTAssertNotNil(stop)
        XCTAssertNotNil(pause)
        XCTAssertNotNil(pauseAndRestore)
    }

    func testDefaultBackgroundBehavior() {
        let view = PngineAnimationView()
        XCTAssertEqual(view.backgroundBehavior, .pauseAndRestore,
                       "Default background behavior should be pauseAndRestore")
    }

    func testBackgroundBehaviorCanBeChanged() {
        let view = PngineAnimationView()

        view.backgroundBehavior = .stop
        XCTAssertEqual(view.backgroundBehavior, .stop)

        view.backgroundBehavior = .pause
        XCTAssertEqual(view.backgroundBehavior, .pause)

        view.backgroundBehavior = .pauseAndRestore
        XCTAssertEqual(view.backgroundBehavior, .pauseAndRestore)
    }

    // MARK: - Play/Pause State Tests

    func testInitialPlayingState() {
        let view = PngineAnimationView()
        XCTAssertFalse(view.isPlaying, "View should not be playing initially")
    }

    func testPlayWithoutAnimation() {
        let view = PngineAnimationView()
        view.play()
        // Should not crash, and should defer play
        XCTAssertFalse(view.isPlaying, "View should not be playing without animation loaded")
    }

    func testPauseWithoutAnimation() {
        let view = PngineAnimationView()
        view.pause()
        // Should not crash
        XCTAssertFalse(view.isPlaying)
    }

    func testStopWithoutAnimation() {
        let view = PngineAnimationView()
        view.stop()
        // Should not crash
        XCTAssertFalse(view.isPlaying)
    }

    // MARK: - Current Time Tests

    func testInitialCurrentTime() {
        let view = PngineAnimationView()
        // Initial time should be 0 or very close to it
        XCTAssertLessThan(view.currentTime, 1.0,
                          "Initial current time should be near 0")
    }

    func testCurrentTimeCanBeSet() {
        let view = PngineAnimationView()
        view.currentTime = 5.0
        // Allow some tolerance for timing
        XCTAssertGreaterThan(view.currentTime, 4.5)
        XCTAssertLessThan(view.currentTime, 5.5)
    }

    // MARK: - Animation Lifecycle with Bytecode

    func testPlayPauseCycleWithAnimation() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)

        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Note: Animation may fail to load in headless test environment
        // but play/pause should still be safe to call
        view.play()
        // If animation loaded, it should be playing
        // If not, play is deferred

        view.pause()
        XCTAssertFalse(view.isPlaying, "Should not be playing after pause")

        view.play()
        // May or may not be playing depending on animation load

        view.stop()
        XCTAssertFalse(view.isPlaying, "Should not be playing after stop")
    }

    // MARK: - SwiftUI View Modifier Tests

    func testSwiftUIViewDefaultBackgroundBehavior() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)

        // We can't directly inspect private properties, but we can test
        // that the modifiers don't crash
        let modifiedView = view.backgroundBehavior(.stop)
        XCTAssertNotNil(modifiedView)
    }

    func testSwiftUIViewAutoPlayModifier() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
        let modifiedView = view.autoPlay(false)
        XCTAssertNotNil(modifiedView)
    }

    func testSwiftUIViewChainedModifiers() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .autoPlay(false)
            .backgroundBehavior(.pause)
        XCTAssertNotNil(view)
    }

    // MARK: - Memory Warning Integration

    func testMemoryWarningDoesNotCrash() {
        let view = PngineAnimationView()
        // Simulate memory warning
        pngine_memory_warning()
        XCTAssertTrue(true, "Memory warning should not crash")
    }

    func testMemoryWarningWithActiveAnimation() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Should not crash even with animation
        pngine_memory_warning()
        XCTAssertTrue(true)
    }

    // MARK: - Edge Case Tests

    func testRapidPlayPauseCycles() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Rapidly toggle play/pause 50 times
        for _ in 0..<50 {
            view.play()
            view.pause()
        }

        XCTAssertFalse(view.isPlaying, "Should be paused after rapid cycles")

        // End with play and verify state
        view.play()
        // May or may not be playing (depends on animation load)
        view.stop()
        XCTAssertFalse(view.isPlaying, "Should not be playing after stop")
    }

    func testViewDeallocWhilePlaying() {
        // Test that deallocation while playing doesn't crash
        // due to CADisplayLink retain cycle
        autoreleasepool {
            let bytecode = BytecodeFixtures.simpleInstanced
            let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            view.load(bytecode: bytecode)
            view.play()
            // View goes out of scope and should be deallocated
            // DisplayLink proxy pattern should prevent retain cycle
        }

        // If we get here, deallocation didn't crash
        XCTAssertTrue(true, "Deallocation while playing should not crash")
    }

    func testMultipleLoadCalls() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        // Load multiple times - should replace previous animation
        for _ in 0..<5 {
            view.load(bytecode: bytecode)
        }

        XCTAssertFalse(view.isPlaying, "Should not be playing after loads")

        // Should still work after multiple loads
        view.play()
        view.stop()
        XCTAssertFalse(view.isPlaying)
    }

    func testLoadWhilePlaying() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)
        view.play()

        // Load new bytecode while playing - should not crash
        view.load(bytecode: bytecode)

        // State after reload
        view.stop()
        XCTAssertFalse(view.isPlaying)
    }

    func testPlayStopRapidCycles() {
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        // Even without animation, rapid play/stop shouldn't crash
        for _ in 0..<20 {
            view.play()
            view.stop()
        }

        XCTAssertFalse(view.isPlaying)
        XCTAssertLessThan(view.currentTime, 1.0, "Time should reset after stop")
    }

    func testCurrentTimeWhilePlaying() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)
        view.play()

        // Set currentTime while playing
        view.currentTime = 2.0

        // Should still be playing
        // Time may vary but should be near what we set
        let time = view.currentTime
        XCTAssertGreaterThan(time, 1.5, "Time should be near what we set")

        view.stop()
    }

    func testZeroSizeViewLoadDeferred() {
        let bytecode = BytecodeFixtures.simpleInstanced
        // Create view with zero size
        let view = PngineAnimationView(frame: .zero)

        // Load should be deferred
        view.load(bytecode: bytecode)

        // Play should also be deferred
        view.play()
        XCTAssertFalse(view.isPlaying, "Should not play until layout")
    }

    // MARK: - SwiftUI Enhancement Tests

    func testAnimationSpeedProperty() {
        let view = PngineAnimationView()

        // Default speed
        XCTAssertEqual(view.animationSpeed, 1.0, "Default animation speed should be 1.0")

        // Can be changed
        view.animationSpeed = 2.0
        XCTAssertEqual(view.animationSpeed, 2.0)

        view.animationSpeed = 0.5
        XCTAssertEqual(view.animationSpeed, 0.5)

        // Negative values for reverse playback
        view.animationSpeed = -1.0
        XCTAssertEqual(view.animationSpeed, -1.0)
    }

    func testTargetFrameRateProperty() {
        let view = PngineAnimationView()

        // Default frame rate (0 = maximum)
        XCTAssertEqual(view.targetFrameRate, 0, "Default target frame rate should be 0")

        // Can be changed
        view.targetFrameRate = 30
        XCTAssertEqual(view.targetFrameRate, 30)

        view.targetFrameRate = 60
        XCTAssertEqual(view.targetFrameRate, 60)
    }

    func testSwiftUIAnimationSpeedModifier() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .animationSpeed(2.0)
        XCTAssertNotNil(view)
    }

    func testSwiftUITargetFrameRateModifier() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .targetFrameRate(30)
        XCTAssertNotNil(view)
    }

    func testSwiftUIConfigureModifier() {
        let bytecode = Data()
        var configureCallCount = 0

        // Note: The configure closure is stored and called when SwiftUI renders the view.
        // In unit tests, we can only verify that the modifier returns a valid view.
        let view = PngineView(bytecode: bytecode)
            .configure { _ in
                configureCallCount += 1
            }
        XCTAssertNotNil(view, "configure modifier should return a valid view")

        // Multiple configure calls should chain
        let chainedView = view.configure { _ in configureCallCount += 1 }
        XCTAssertNotNil(chainedView, "Multiple configure calls should chain")
    }

    func testSwiftUIAllModifiersChained() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .autoPlay(false)
            .backgroundBehavior(.pause)
            .animationSpeed(1.5)
            .targetFrameRate(30)
            .configure { _ in }
        XCTAssertNotNil(view)
    }

    func testControlledPngineViewCreation() {
        let bytecode = BytecodeFixtures.simpleInstanced
        // Note: We can't fully test binding synchronization in unit tests, but we can verify creation
        // Full binding tests would require SwiftUI previews or UI tests
        let view = ControlledPngineView(bytecode: bytecode, isPlaying: .constant(true))
        XCTAssertNotNil(view, "ControlledPngineView should be creatable")

        // Test with false initial state
        let pausedView = ControlledPngineView(bytecode: bytecode, isPlaying: .constant(false))
        XCTAssertNotNil(pausedView, "ControlledPngineView should be creatable with isPlaying=false")
    }

    func testAnimationSpeedAffectsPlayback() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Set 2x speed
        view.animationSpeed = 2.0
        XCTAssertEqual(view.animationSpeed, 2.0)

        view.play()
        view.pause()

        // Animation speed should persist across play/pause
        XCTAssertEqual(view.animationSpeed, 2.0)
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testAsyncPngineViewCreation() {
        // Test that AsyncPngineView can be created with various configurations
        let view = AsyncPngineView {
            // Simulated async load
            return BytecodeFixtures.simpleInstanced
        } placeholder: {
            Text("Loading...")
        }
        XCTAssertNotNil(view, "AsyncPngineView should be creatable")

        // Test with modifiers
        let modifiedView = view
            .autoPlay(false)
            .backgroundBehavior(.pause)
            .animationSpeed(0.5)
            .targetFrameRate(30)
        XCTAssertNotNil(modifiedView, "AsyncPngineView should support fluent modifiers")
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testAsyncPngineViewWithProgressViewPlaceholder() {
        // Test convenience initializer with default ProgressView placeholder
        let view = AsyncPngineView {
            return BytecodeFixtures.simpleInstanced
        }
        XCTAssertNotNil(view, "AsyncPngineView should be creatable with default placeholder")
    }

    func testAnimationSpeedZeroValue() {
        let view = PngineAnimationView()

        // Zero speed should be settable (freezes animation)
        view.animationSpeed = 0.0
        XCTAssertEqual(view.animationSpeed, 0.0, "Zero animation speed should be valid")

        // Negative speed (reverse playback)
        view.animationSpeed = -1.0
        XCTAssertEqual(view.animationSpeed, -1.0, "Negative animation speed should be valid")
    }

    // MARK: - CADisplayLink Optimization Tests (Phase 6)

    func testRespectAnimationFrameRateProperty() {
        let view = PngineAnimationView()

        // Default should be false
        XCTAssertFalse(view.respectAnimationFrameRate, "Default respectAnimationFrameRate should be false")

        // Can be changed
        view.respectAnimationFrameRate = true
        XCTAssertTrue(view.respectAnimationFrameRate, "respectAnimationFrameRate should be settable to true")

        view.respectAnimationFrameRate = false
        XCTAssertFalse(view.respectAnimationFrameRate, "respectAnimationFrameRate should be settable to false")
    }

    func testRespectAnimationFrameRateWithTargetFrameRate() {
        let view = PngineAnimationView()

        // Set both properties
        view.targetFrameRate = 30
        view.respectAnimationFrameRate = true

        XCTAssertEqual(view.targetFrameRate, 30, "targetFrameRate should be 30")
        XCTAssertTrue(view.respectAnimationFrameRate, "respectAnimationFrameRate should be true")
    }

    func testRespectAnimationFrameRateWithAnimation() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Set 30fps with respectAnimationFrameRate
        view.targetFrameRate = 30
        view.respectAnimationFrameRate = true

        // Start playing
        view.play()

        // Properties should persist
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.stop()
    }

    func testSwiftUIRespectAnimationFrameRateModifier() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .respectAnimationFrameRate(true)
            .targetFrameRate(30)
        XCTAssertNotNil(view, "respectAnimationFrameRate modifier should work")
    }

    func testSwiftUIAllModifiersIncludingFrameRate() {
        let bytecode = Data()
        let view = PngineView(bytecode: bytecode)
            .autoPlay(false)
            .backgroundBehavior(.pause)
            .animationSpeed(1.5)
            .targetFrameRate(30)
            .respectAnimationFrameRate(true)
            .configure { _ in }
        XCTAssertNotNil(view, "All modifiers including respectAnimationFrameRate should chain")
    }

    func testControlledPngineViewRespectAnimationFrameRateModifier() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = ControlledPngineView(bytecode: bytecode, isPlaying: .constant(true))
            .respectAnimationFrameRate(true)
            .targetFrameRate(30)
        XCTAssertNotNil(view, "ControlledPngineView should support respectAnimationFrameRate modifier")
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testAsyncPngineViewRespectAnimationFrameRateModifier() {
        let view = AsyncPngineView {
            return BytecodeFixtures.simpleInstanced
        } placeholder: {
            Text("Loading...")
        }
        .respectAnimationFrameRate(true)
        .targetFrameRate(30)
        XCTAssertNotNil(view, "AsyncPngineView should support respectAnimationFrameRate modifier")
    }

    func testFrameRateRanges() {
        let view = PngineAnimationView()

        // Test various frame rate values
        let frameRates = [0, 24, 30, 60, 120]
        for rate in frameRates {
            view.targetFrameRate = rate
            XCTAssertEqual(view.targetFrameRate, rate, "targetFrameRate should be \(rate)")
        }
    }

    func testFrameRateWithPlayPauseCycle() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Set frame rate before playing
        view.targetFrameRate = 30
        view.respectAnimationFrameRate = true

        view.play()
        view.pause()

        // Frame rate settings should persist after pause
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.play()
        view.stop()

        // Frame rate settings should persist after stop
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)
    }
}
