# PNGine iOS Implementation Improvement Plan

**Status**: Analysis Complete
**Reference**: Lottie iOS v4.6.0 patterns (~/llm/lottie/ios/, ~/llm/repositories/lottie-ios/)

## Executive Summary

The current PNGine iOS implementation has **solid architecture** (9/10) but needs significant improvements in **testing** (0/10), **error handling** (2/10), and **thread safety** (2/10). Adopting patterns from Lottie iOS can elevate production readiness from pre-alpha (3/10) to beta quality.

## Current State Analysis

### Strengths
| Aspect | Rating | Notes |
|--------|--------|-------|
| Architecture | 9/10 | Clean Zig → C → Swift FFI |
| Build System | 9/10 | XCFramework + SPM working |
| API Surface | 9/10 | Minimal, focused C API |
| Code Reuse | 9/10 | ~90% shared with web runtime |
| Documentation | 8/10 | Good plan docs |

### Critical Gaps
| Aspect | Rating | Impact |
|--------|--------|--------|
| Testing | 0/10 | Cannot catch regressions |
| Error Handling | 2/10 | Silent failures, no user feedback |
| Thread Safety | 2/10 | Data races in diagnostics |
| Lifecycle | 3/10 | No background/foreground handling |
| SwiftUI API | 4/10 | Basic wrapper, no fluent modifiers |

---

## Improvement Areas

### 1. Testing Infrastructure (Priority: Critical)

**Current State**: Zero automated tests. Manual testing via embedded bytecode fixtures.

**Lottie Pattern**: 20 test files, 2,039 lines, snapshot testing with precision adjustment.

#### Recommended Test Structure

```
Tests/
├── PngineTests/
│   ├── ContextTests.swift           # GPU context initialization
│   ├── BytecodeParsingTests.swift   # PNGB format validation
│   ├── RenderingTests.swift         # GPU pipeline tests
│   ├── MemoryTests.swift            # Leak detection
│   └── ThreadSafetyTests.swift      # Concurrent access tests
├── PngineSnapshotTests/
│   ├── SimpleTriangleTests.swift
│   ├── RotatingCubeTests.swift
│   ├── ComputeTests.swift
│   └── SnapshotConfiguration.swift  # Precision config per test
└── TestUtils/
    ├── BytecodeFixtures.swift       # Base64 test bytecodes
    ├── MockSurface.swift            # Headless rendering
    └── AssertHelpers.swift          # Custom XCT assertions
```

#### Snapshot Testing Strategy (from Lottie)

```swift
// SnapshotConfiguration.swift
struct SnapshotConfiguration {
    var precision: Float = 0.985  // Allow minor GPU differences
    var frame: CGFloat = 0.0      // Test specific frame
    var size: CGSize = CGSize(width: 300, height: 300)

    // Custom configs for edge cases
    static let customMapping: [String: SnapshotConfiguration] = [
        "compute_spiral": .init(precision: 0.95),  // Compute has variance
        "depth_buffer": .init(precision: 0.99),    // Depth should be exact
    ]
}
```

#### XCTest Foundation

```swift
// ContextTests.swift
import XCTest
@testable import PngineKit

@MainActor
final class ContextTests: XCTestCase {

    override func setUp() async throws {
        // Ensure context is initialized
        XCTAssertTrue(pngine_init() == 0, "Context init failed")
    }

    override func tearDown() async throws {
        // Don't shutdown - context is shared
    }

    func testContextInitialization() {
        XCTAssertTrue(pngine_is_initialized())
    }

    func testDoubleInitIsIdempotent() {
        XCTAssertEqual(pngine_init(), 0)
        XCTAssertEqual(pngine_init(), 0)  // Should not fail
    }

    func testAnimationCreateDestroy() throws {
        let bytecode = BytecodeFixtures.simpleTriangle
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 300, height: 300)

        guard let anim = pngine_create(
            bytecode.bytes,
            bytecode.count,
            Unmanaged.passUnretained(layer).toOpaque(),
            300, 300
        ) else {
            XCTFail("Animation creation failed")
            return
        }

        pngine_destroy(anim)
    }
}
```

#### CI Integration

```yaml
# .github/workflows/ios.yml
name: iOS Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-15
    strategy:
      matrix:
        xcode: ['16.1', '16.2']
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_${{ matrix.xcode }}.app

      - name: Build Zig libraries
        run: |
          zig build native-ios -Doptimize=ReleaseFast
          ./scripts/build-xcframework.sh

      - name: Run tests
        run: |
          xcodebuild test \
            -scheme PngineKit \
            -destination 'platform=iOS Simulator,name=iPhone 15' \
            -resultBundlePath TestResults

      - name: Upload test artifacts
        uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: test-results
          path: TestResults
```

---

### 2. Error Handling (Priority: Critical)

**Current State**: Errors caught in Zig but silently discarded. `pngine_get_error()` never set.

**Lottie Pattern**: Logger system, compatibility warnings, graceful degradation.

#### Error Callback Pattern

```c
// pngine.h - Add error callback
typedef void (*PngineErrorCallback)(int code, const char* message, void* user_data);

PNGINE_EXPORT void pngine_set_error_callback(
    PngineErrorCallback callback,
    void* user_data
);

// Error codes
typedef enum {
    PNGINE_ERROR_NONE = 0,
    PNGINE_ERROR_CONTEXT_INIT = -1,
    PNGINE_ERROR_BYTECODE_INVALID = -2,
    PNGINE_ERROR_SHADER_COMPILE = -3,
    PNGINE_ERROR_PIPELINE_CREATE = -4,
    PNGINE_ERROR_TEXTURE_UNAVAIL = -5,
    PNGINE_ERROR_OUT_OF_MEMORY = -6,
} PngineError;
```

```swift
// PngineKit.swift - Swift-side error handling
public enum PngineError: LocalizedError {
    case contextInitFailed
    case bytecodeInvalid
    case shaderCompileFailed(String)
    case pipelineCreateFailed
    case textureUnavailable
    case outOfMemory

    public var errorDescription: String? {
        switch self {
        case .contextInitFailed:
            return "GPU context initialization failed"
        case .bytecodeInvalid:
            return "Invalid bytecode format"
        case .shaderCompileFailed(let details):
            return "Shader compilation failed: \(details)"
        case .pipelineCreateFailed:
            return "Failed to create render pipeline"
        case .textureUnavailable:
            return "Surface texture not available"
        case .outOfMemory:
            return "Out of GPU memory"
        }
    }
}

// Logger protocol (Lottie pattern)
public protocol PngineLogger {
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

public class DefaultPngineLogger: PngineLogger {
    public static let shared = DefaultPngineLogger()

    public func info(_ message: String) {
        #if DEBUG
        print("[PngineKit] \(message)")
        #endif
    }

    public func warn(_ message: String) {
        print("[PngineKit] ⚠️ \(message)")
    }

    public func error(_ message: String) {
        print("[PngineKit] ❌ \(message)")
    }
}
```

---

### 3. Thread Safety (Priority: High)

**Current State**: Global diagnostic counters unprotected. Context access not synchronized.

#### Atomic Counters

```zig
// wgpu_native_gpu.zig - Replace module-level vars
const AtomicU32 = std.atomic.Value(u32);

// Thread-safe debug counters
var debug_compute_passes: AtomicU32 = AtomicU32.init(0);
var debug_draws: AtomicU32 = AtomicU32.init(0);

// In beginComputePass:
_ = debug_compute_passes.fetchAdd(1, .monotonic);

// In draw:
_ = debug_draws.fetchAdd(1, .monotonic);

// In debug export:
export fn pngine_debug_compute_passes() callconv(.c) u32 {
    return debug_compute_passes.load(.monotonic);
}
```

#### Per-Animation Diagnostics

```zig
// Move diagnostics into PngineAnimation struct
pub const PngineAnimation = struct {
    gpu: *WgpuNativeGPU,
    module: *BytecodeModule,
    dispatcher: *Dispatcher,
    width: u32,
    height: u32,

    // Per-animation diagnostics (no global state)
    diagnostics: struct {
        compute_passes: u32 = 0,
        draws: u32 = 0,
        last_error: ?[:0]const u8 = null,
    } = .{},
};

// API becomes:
export fn pngine_debug_draws(anim: ?*PngineAnimation) callconv(.c) u32 {
    const a = anim orelse return 0;
    return a.diagnostics.draws;
}
```

---

### 4. Lifecycle Management (Priority: High)

**Current State**: No background/foreground handling. CADisplayLink always runs.

**Lottie Pattern**: `LottieBackgroundBehavior` enum, notification observers, engine-aware defaults.

#### Background Behavior Enum

```swift
// PngineKit.swift
public enum PngineBackgroundBehavior {
    /// Stop rendering and reset time to 0
    case stop

    /// Pause at current frame
    case pause

    /// Pause and automatically resume when foregrounded (default)
    case pauseAndRestore
}
```

#### Notification Handling

```swift
// PngineAnimationView.swift
public class PngineAnimationView: UIView {
    public var backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore

    private var storedTime: Float = 0
    private var wasPlayingBeforeBackground = false

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func applicationDidEnterBackground() {
        wasPlayingBeforeBackground = isPlaying

        switch backgroundBehavior {
        case .stop:
            stop()
        case .pause:
            pause()
        case .pauseAndRestore:
            storedTime = currentTime
            pause()
        }
    }

    @objc private func applicationWillEnterForeground() {
        guard backgroundBehavior == .pauseAndRestore,
              wasPlayingBeforeBackground else { return }

        currentTime = storedTime
        play()
    }

    @objc private func didReceiveMemoryWarning() {
        // PNGine doesn't cache animations, but could release non-essential resources
        logger.warn("Memory warning received")
    }
}
```

---

### 5. SwiftUI API Enhancement (Priority: Medium)

**Current State**: Basic `PngineView` struct wrapping UIKit view.

**Lottie Pattern**: Fluent modifiers, async loading with placeholder, configuration accumulation.

#### Fluent Modifier Pattern

```swift
// PngineView.swift
public struct PngineView: View {
    private let bytecode: Data?
    private var playbackMode: PlaybackMode = .playing
    private var animationSpeed: Float = 1.0
    private var backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore
    private var configurations: [(PngineAnimationView) -> Void] = []

    // Sync init
    public init(bytecode: Data) {
        self.bytecode = bytecode
    }

    // Async init with placeholder
    public init<Placeholder: View>(
        _ loadBytecode: @escaping () async throws -> Data,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) where Placeholder == AnyView {
        // Store async loader
    }

    // MARK: - Fluent Modifiers

    public func playbackMode(_ mode: PlaybackMode) -> Self {
        var copy = self
        copy.playbackMode = mode
        return copy
    }

    public func animationSpeed(_ speed: Float) -> Self {
        var copy = self
        copy.animationSpeed = speed
        return copy
    }

    public func backgroundBehavior(_ behavior: PngineBackgroundBehavior) -> Self {
        var copy = self
        copy.backgroundBehavior = behavior
        return copy
    }

    public func configure(_ configure: @escaping (PngineAnimationView) -> Void) -> Self {
        var copy = self
        copy.configurations.append(configure)
        return copy
    }

    public var body: some View {
        PngineViewRepresentable(
            bytecode: bytecode,
            playbackMode: playbackMode,
            animationSpeed: animationSpeed,
            backgroundBehavior: backgroundBehavior,
            configurations: configurations
        )
    }
}
```

#### Usage Example

```swift
// Before (current)
PngineView(bytecode: data)
    .frame(width: 300, height: 300)

// After (enhanced)
PngineView(bytecode: data)
    .playbackMode(.playing)
    .animationSpeed(1.5)
    .backgroundBehavior(.pauseAndRestore)
    .configure { view in
        view.respectAnimationFrameRate = true
    }
    .frame(width: 300, height: 300)

// Async loading with placeholder
PngineView {
    try await loadBytecodeFromNetwork()
} placeholder: {
    ProgressView()
}
.playbackMode(.playing)
```

---

### 6. CADisplayLink Optimization (Priority: Medium)

**Lottie Pattern**: `respectAnimationFrameRate` to limit display link frequency.

```swift
// PngineAnimationView.swift
public var respectAnimationFrameRate: Bool = false {
    didSet {
        updateDisplayLinkFrameRate()
    }
}

public var targetFrameRate: Int = 60 {
    didSet {
        updateDisplayLinkFrameRate()
    }
}

private func updateDisplayLinkFrameRate() {
    if respectAnimationFrameRate {
        displayLink?.preferredFramesPerSecond = targetFrameRate
    } else {
        displayLink?.preferredFramesPerSecond = 0  // Maximum
    }
}

// Battery optimization: 30fps for simple animations
@available(iOS 15.0, *)
private func setupProMotionAwareDisplayLink() {
    if let displayLink = displayLink {
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: Float(targetFrameRate),
            preferred: Float(targetFrameRate)
        )
    }
}
```

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
1. [ ] Add error callback API to C layer
2. [ ] Implement atomic counters for thread safety
3. [ ] Move diagnostics to per-animation struct
4. [ ] Create XCTest target in Package.swift

### Phase 2: Testing (Week 2-3)
1. [ ] Add context initialization tests
2. [ ] Add bytecode validation tests
3. [ ] Add memory leak tests (use `XCTMemoryMetric`)
4. [ ] Setup CI workflow for iOS

### Phase 3: Lifecycle (Week 3-4)
1. [ ] Add `PngineBackgroundBehavior` enum
2. [ ] Implement notification observers
3. [ ] Add `didMoveToWindow()` handling
4. [ ] Test background/foreground transitions

### Phase 4: SwiftUI Enhancement (Week 4-5)
1. [ ] Implement fluent modifier pattern
2. [ ] Add async loading with placeholder
3. [ ] Add `TimelineView` for progress binding
4. [ ] Update documentation

### Phase 5: Snapshot Testing (Week 5-6)
1. [ ] Integrate snapshot testing library
2. [ ] Create reference images for fixtures
3. [ ] Add precision configuration per test
4. [ ] Setup CI artifact upload

---

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `native/include/pngine.h` | Modify | Add error callback, per-anim diagnostics |
| `src/native_api.zig` | Modify | Error callback, atomic counters |
| `src/executor/wgpu_native_gpu.zig` | Modify | Per-animation diagnostics |
| `native/ios/PngineKit/Sources/PngineKit.swift` | Modify | Error types, logger |
| `native/ios/PngineKit/Sources/PngineView.swift` | Rewrite | Fluent API, lifecycle |
| `native/ios/PngineKit/Tests/` | Create | Test suite |
| `.github/workflows/ios.yml` | Create | CI workflow |

---

## References

- Lottie iOS: https://github.com/airbnb/lottie-ios
- Lottie Specs: `~/llm/lottie/ios/01-architecture-overview.md`
- SwiftUI Integration: `~/llm/lottie/ios/06-swiftui-integration.md`
- Lifecycle Management: `~/llm/lottie/ios/07-lifecycle-battery.md`
