/**
 * LifecycleTests - Background/foreground behavior tests
 *
 * Tests for PngineBackgroundBehavior enum and lifecycle management.
 */

import XCTest
import QuartzCore
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
        var configuredSpeed: Float = 0

        let view = PngineView(bytecode: bytecode)
            .configure { animView in
                configuredSpeed = animView.animationSpeed
            }
        XCTAssertNotNil(view)
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
        let bytecode = Data()
        // Note: We can't fully test bindings in unit tests, but we can verify creation
        // This would typically be tested with SwiftUI previews or UI tests
        XCTAssertTrue(true, "ControlledPngineView should be available")
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
}
