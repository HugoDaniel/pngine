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

    // MARK: - Thorough Phase 6 Testing

    func testRespectAnimationFrameRateRapidToggling() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)
        view.targetFrameRate = 30
        view.play()

        // Rapidly toggle 100 times - should not crash
        for i in 0..<100 {
            view.respectAnimationFrameRate = (i % 2 == 0)
        }

        // Should end up with false (100 is even, so last set was true at i=98, then false at i=99)
        XCTAssertFalse(view.respectAnimationFrameRate)
        view.stop()
    }

    func testFrameRateEdgeCases() {
        let view = PngineAnimationView()

        // Test zero (should mean max rate)
        view.targetFrameRate = 0
        XCTAssertEqual(view.targetFrameRate, 0)

        // Test common rates
        view.targetFrameRate = 24
        XCTAssertEqual(view.targetFrameRate, 24)

        view.targetFrameRate = 30
        XCTAssertEqual(view.targetFrameRate, 30)

        view.targetFrameRate = 60
        XCTAssertEqual(view.targetFrameRate, 60)

        // Test ProMotion rates
        view.targetFrameRate = 120
        XCTAssertEqual(view.targetFrameRate, 120)

        // Test very high rate (beyond typical displays)
        view.targetFrameRate = 240
        XCTAssertEqual(view.targetFrameRate, 240)
    }

    func testDynamicFrameRateChangesDuringPlayback() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)
        view.play()

        // Change frame rate multiple times while playing
        view.targetFrameRate = 30
        XCTAssertEqual(view.targetFrameRate, 30)

        view.targetFrameRate = 60
        XCTAssertEqual(view.targetFrameRate, 60)

        view.respectAnimationFrameRate = true
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.targetFrameRate = 24
        XCTAssertEqual(view.targetFrameRate, 24)

        view.respectAnimationFrameRate = false
        XCTAssertFalse(view.respectAnimationFrameRate)

        view.stop()
    }

    func testFrameRateWithAnimationSpeedInteraction() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Both properties should be independent
        view.animationSpeed = 2.0
        view.targetFrameRate = 30
        view.respectAnimationFrameRate = true

        XCTAssertEqual(view.animationSpeed, 2.0)
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.play()

        // Change speed, frame rate should be unaffected
        view.animationSpeed = 0.5
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        // Change frame rate, speed should be unaffected
        view.targetFrameRate = 60
        XCTAssertEqual(view.animationSpeed, 0.5)

        view.stop()
    }

    func testFrameRateAfterAnimationReload() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        // Set frame rate before loading
        view.targetFrameRate = 30
        view.respectAnimationFrameRate = true

        view.load(bytecode: bytecode)

        // Settings should persist after load
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.play()

        // Reload animation while playing
        view.load(bytecode: BytecodeFixtures.instancedBuiltins)

        // Settings should still persist
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.stop()
    }

    func testFrameRateStressTest() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Stress test: rapid property changes
        for i in 0..<200 {
            view.targetFrameRate = (i % 4) * 30  // 0, 30, 60, 90, 0, ...
            view.respectAnimationFrameRate = (i % 3 == 0)
            if i % 5 == 0 {
                view.play()
            } else if i % 7 == 0 {
                view.pause()
            }
        }

        view.stop()
        XCTAssertFalse(view.isPlaying)
    }

    func testFrameRateWithDifferentBytecodeFixtures() {
        // Test with simpleInstanced
        let view1 = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view1.targetFrameRate = 30
        view1.respectAnimationFrameRate = true
        view1.load(bytecode: BytecodeFixtures.simpleInstanced)
        view1.play()
        XCTAssertEqual(view1.targetFrameRate, 30)
        view1.stop()

        // Test with instancedBuiltins
        let view2 = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view2.targetFrameRate = 60
        view2.respectAnimationFrameRate = true
        view2.load(bytecode: BytecodeFixtures.instancedBuiltins)
        view2.play()
        XCTAssertEqual(view2.targetFrameRate, 60)
        view2.stop()

        // Test with boidsCompute
        let view3 = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view3.targetFrameRate = 24
        view3.respectAnimationFrameRate = true
        view3.load(bytecode: BytecodeFixtures.boidsCompute)
        view3.play()
        XCTAssertEqual(view3.targetFrameRate, 24)
        view3.stop()
    }

    func testRespectAnimationFrameRateWithoutTargetFrameRate() {
        let view = PngineAnimationView()

        // Set respectAnimationFrameRate without setting targetFrameRate
        view.respectAnimationFrameRate = true

        // Should not crash, targetFrameRate defaults to 0 (max)
        XCTAssertTrue(view.respectAnimationFrameRate)
        XCTAssertEqual(view.targetFrameRate, 0)

        // Now set a target frame rate
        view.targetFrameRate = 30
        XCTAssertEqual(view.targetFrameRate, 30)
        XCTAssertTrue(view.respectAnimationFrameRate)
    }

    func testFrameRatePropertyOrdering() {
        let view = PngineAnimationView()

        // Test setting respectAnimationFrameRate first, then targetFrameRate
        view.respectAnimationFrameRate = true
        view.targetFrameRate = 30

        XCTAssertTrue(view.respectAnimationFrameRate)
        XCTAssertEqual(view.targetFrameRate, 30)

        // Reset
        view.respectAnimationFrameRate = false
        view.targetFrameRate = 0

        // Test setting targetFrameRate first, then respectAnimationFrameRate
        view.targetFrameRate = 60
        view.respectAnimationFrameRate = true

        XCTAssertTrue(view.respectAnimationFrameRate)
        XCTAssertEqual(view.targetFrameRate, 60)
    }

    func testFrameRateWithViewDeallocation() {
        // Test that setting frame rate properties doesn't prevent deallocation
        autoreleasepool {
            let bytecode = BytecodeFixtures.simpleInstanced
            let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            view.targetFrameRate = 30
            view.respectAnimationFrameRate = true
            view.load(bytecode: bytecode)
            view.play()
            // View should be deallocated when leaving scope
        }

        // If we get here, deallocation didn't crash
        XCTAssertTrue(true, "View deallocation with frame rate settings should not crash")
    }

    func testSwiftUIModifierOrder() {
        let bytecode = Data()

        // Test various modifier orderings - all should work
        let view1 = PngineView(bytecode: bytecode)
            .targetFrameRate(30)
            .respectAnimationFrameRate(true)
        XCTAssertNotNil(view1)

        let view2 = PngineView(bytecode: bytecode)
            .respectAnimationFrameRate(true)
            .targetFrameRate(30)
        XCTAssertNotNil(view2)

        let view3 = PngineView(bytecode: bytecode)
            .animationSpeed(2.0)
            .targetFrameRate(30)
            .respectAnimationFrameRate(true)
            .backgroundBehavior(.pause)
            .autoPlay(false)
        XCTAssertNotNil(view3)
    }

    func testLowFrameRateValues() {
        let view = PngineAnimationView()

        // Test very low but valid frame rates
        view.targetFrameRate = 1
        XCTAssertEqual(view.targetFrameRate, 1)

        view.targetFrameRate = 10
        XCTAssertEqual(view.targetFrameRate, 10)

        view.targetFrameRate = 15
        XCTAssertEqual(view.targetFrameRate, 15)

        // CAFrameRateRange minimum logic should handle low values
        view.respectAnimationFrameRate = true
        XCTAssertTrue(view.respectAnimationFrameRate)
    }

    func testNegativeFrameRateValuesClamped() {
        let view = PngineAnimationView()

        // Negative values should be clamped to 0 (max frame rate)
        view.targetFrameRate = -1
        XCTAssertEqual(view.targetFrameRate, 0, "Negative frame rate should be clamped to 0")

        view.targetFrameRate = -100
        XCTAssertEqual(view.targetFrameRate, 0, "Large negative frame rate should be clamped to 0")

        view.targetFrameRate = -999999
        XCTAssertEqual(view.targetFrameRate, 0, "Very large negative frame rate should be clamped to 0")

        // Verify positive values still work after negative clamping
        view.targetFrameRate = 30
        XCTAssertEqual(view.targetFrameRate, 30, "Positive frame rate should work after negative clamping")
    }

    func testNegativeFrameRateWithRespectAnimationFrameRate() {
        let bytecode = BytecodeFixtures.simpleInstanced
        let view = PngineAnimationView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.load(bytecode: bytecode)

        // Set respectAnimationFrameRate first, then negative frame rate
        view.respectAnimationFrameRate = true
        view.targetFrameRate = -50

        // Should be clamped and not crash when playing
        XCTAssertEqual(view.targetFrameRate, 0)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.play()
        view.pause()

        // Settings should persist
        XCTAssertEqual(view.targetFrameRate, 0)
        XCTAssertTrue(view.respectAnimationFrameRate)

        view.stop()
    }
}
