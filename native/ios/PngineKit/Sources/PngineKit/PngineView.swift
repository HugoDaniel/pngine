/**
 * PngineView - SwiftUI wrapper for PNGine animations
 *
 * Basic Usage:
 * ```swift
 * import PngineKit
 *
 * struct ContentView: View {
 *     var body: some View {
 *         PngineView(bytecode: myBytecodeData)
 *             .animationSpeed(1.5)
 *             .backgroundBehavior(.pauseAndRestore)
 *             .frame(width: 300, height: 300)
 *     }
 * }
 * ```
 *
 * Async Loading:
 * ```swift
 * AsyncPngineView {
 *     try await loadBytecodeFromNetwork()
 * } placeholder: {
 *     ProgressView()
 * }
 * ```
 *
 * Controlled Playback:
 * ```swift
 * @State private var isPlaying = true
 *
 * ControlledPngineView(bytecode: data, isPlaying: $isPlaying)
 * ```
 */

import SwiftUI
import QuartzCore

#if os(iOS)
import UIKit
public typealias ViewRepresentable = UIViewRepresentable
public typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
public typealias ViewRepresentable = NSViewRepresentable
public typealias PlatformView = NSView
#endif

// MARK: - Background Behavior

/// Controls animation behavior when the app enters background.
/// Following Lottie's LottieBackgroundBehavior pattern.
public enum PngineBackgroundBehavior {
    /// Stop rendering and reset time to 0.
    case stop

    /// Pause at the current frame.
    case pause

    /// Pause at the current frame and automatically resume when foregrounded (default).
    case pauseAndRestore
}

// MARK: - SwiftUI View

@available(iOS 14.0, macOS 11.0, *)
public struct PngineView: ViewRepresentable {
    private let bytecode: Data
    private var autoPlay: Bool
    private var backgroundBehavior: PngineBackgroundBehavior
    private var animationSpeed: Float
    private var targetFrameRate: Int
    private var configurations: [(PngineAnimationView) -> Void]

    public init(
        bytecode: Data,
        autoPlay: Bool = true,
        backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore
    ) {
        self.bytecode = bytecode
        self.autoPlay = autoPlay
        self.backgroundBehavior = backgroundBehavior
        self.animationSpeed = 1.0
        self.targetFrameRate = 0
        self.configurations = []
    }

    // MARK: - Fluent Modifiers

    /// Set whether animation should auto-play.
    public func autoPlay(_ enabled: Bool) -> Self {
        var copy = self
        copy.autoPlay = enabled
        return copy
    }

    /// Set background behavior.
    public func backgroundBehavior(_ behavior: PngineBackgroundBehavior) -> Self {
        var copy = self
        copy.backgroundBehavior = behavior
        return copy
    }

    /// Set animation playback speed. Default is 1.0 (normal speed).
    /// Values > 1.0 speed up, values < 1.0 slow down.
    public func animationSpeed(_ speed: Float) -> Self {
        var copy = self
        copy.animationSpeed = speed
        return copy
    }

    /// Set target frame rate. Default is 0 (maximum).
    /// Lower values can save battery for simple animations.
    public func targetFrameRate(_ rate: Int) -> Self {
        var copy = self
        copy.targetFrameRate = rate
        return copy
    }

    /// Configure the underlying PngineAnimationView directly.
    /// Use this for advanced customization not exposed through modifiers.
    public func configure(_ configure: @escaping (PngineAnimationView) -> Void) -> Self {
        var copy = self
        copy.configurations.append(configure)
        return copy
    }

    private func configureView(_ view: PngineAnimationView) {
        view.backgroundBehavior = backgroundBehavior
        view.animationSpeed = animationSpeed
        view.targetFrameRate = targetFrameRate

        // Apply custom configurations
        for config in configurations {
            config(view)
        }

        view.load(bytecode: bytecode)
        if autoPlay {
            view.play()
        }
    }

    private func updateView(_ view: PngineAnimationView) {
        view.backgroundBehavior = backgroundBehavior
        view.animationSpeed = animationSpeed
        view.targetFrameRate = targetFrameRate

        // Apply custom configurations on update
        for config in configurations {
            config(view)
        }
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        configureView(view)
        return view
    }

    public func updateUIView(_ uiView: PngineAnimationView, context: Context) {
        updateView(uiView)
    }
    #elseif os(macOS)
    public func makeNSView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        configureView(view)
        return view
    }

    public func updateNSView(_ nsView: PngineAnimationView, context: Context) {
        updateView(nsView)
    }
    #endif
}

// MARK: - Async Loading View

/// A SwiftUI view that loads animation bytecode asynchronously with a placeholder.
///
/// Usage:
/// ```swift
/// AsyncPngineView {
///     try await loadBytecodeFromNetwork()
/// } placeholder: {
///     ProgressView()
/// }
/// .animationSpeed(1.5)
/// ```
@available(iOS 15.0, macOS 12.0, *)
public struct AsyncPngineView<Placeholder: View>: View {
    private let loadBytecode: () async throws -> Data
    private let placeholder: () -> Placeholder
    private var autoPlay: Bool
    private var backgroundBehavior: PngineBackgroundBehavior
    private var animationSpeed: Float
    private var targetFrameRate: Int
    private var configurations: [(PngineAnimationView) -> Void]

    @State private var bytecode: Data?
    @State private var loadError: Error?

    public init(
        _ loadBytecode: @escaping () async throws -> Data,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.loadBytecode = loadBytecode
        self.placeholder = placeholder
        self.autoPlay = true
        self.backgroundBehavior = .pauseAndRestore
        self.animationSpeed = 1.0
        self.targetFrameRate = 0
        self.configurations = []
    }

    // MARK: - Fluent Modifiers

    /// Set whether animation should auto-play.
    public func autoPlay(_ enabled: Bool) -> Self {
        var copy = self
        copy.autoPlay = enabled
        return copy
    }

    /// Set background behavior.
    public func backgroundBehavior(_ behavior: PngineBackgroundBehavior) -> Self {
        var copy = self
        copy.backgroundBehavior = behavior
        return copy
    }

    /// Set animation playback speed.
    public func animationSpeed(_ speed: Float) -> Self {
        var copy = self
        copy.animationSpeed = speed
        return copy
    }

    /// Set target frame rate.
    public func targetFrameRate(_ rate: Int) -> Self {
        var copy = self
        copy.targetFrameRate = rate
        return copy
    }

    /// Configure the underlying PngineAnimationView directly.
    public func configure(_ configure: @escaping (PngineAnimationView) -> Void) -> Self {
        var copy = self
        copy.configurations.append(configure)
        return copy
    }

    public var body: some View {
        Group {
            if let bytecode = bytecode {
                PngineView(bytecode: bytecode, autoPlay: autoPlay, backgroundBehavior: backgroundBehavior)
                    .animationSpeed(animationSpeed)
                    .targetFrameRate(targetFrameRate)
                    .configure { view in
                        for config in configurations {
                            config(view)
                        }
                    }
            } else if loadError != nil {
                // Show placeholder on error (could be enhanced with error view)
                placeholder()
            } else {
                placeholder()
            }
        }
        .task {
            do {
                bytecode = try await loadBytecode()
            } catch {
                loadError = error
                pngineLogger.error("Failed to load bytecode: \(error.localizedDescription)")
            }
        }
    }
}

/// Convenience initializer for AsyncPngineView with ProgressView placeholder.
@available(iOS 15.0, macOS 12.0, *)
public extension AsyncPngineView where Placeholder == ProgressView<EmptyView, EmptyView> {
    init(_ loadBytecode: @escaping () async throws -> Data) {
        self.init(loadBytecode, placeholder: { ProgressView() })
    }
}

// MARK: - Controlled Playback View

/// A PngineView variant with SwiftUI binding for playback control.
///
/// Usage:
/// ```swift
/// struct ContentView: View {
///     @State private var isPlaying = true
///
///     var body: some View {
///         VStack {
///             ControlledPngineView(bytecode: data, isPlaying: $isPlaying)
///                 .frame(width: 300, height: 300)
///
///             Button(isPlaying ? "Pause" : "Play") {
///                 isPlaying.toggle()
///             }
///         }
///     }
/// }
/// ```
@available(iOS 14.0, macOS 11.0, *)
public struct ControlledPngineView: ViewRepresentable {
    private let bytecode: Data
    @Binding private var isPlaying: Bool
    private var backgroundBehavior: PngineBackgroundBehavior
    private var animationSpeed: Float
    private var targetFrameRate: Int
    private var configurations: [(PngineAnimationView) -> Void]

    public init(
        bytecode: Data,
        isPlaying: Binding<Bool>,
        backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore
    ) {
        self.bytecode = bytecode
        self._isPlaying = isPlaying
        self.backgroundBehavior = backgroundBehavior
        self.animationSpeed = 1.0
        self.targetFrameRate = 0
        self.configurations = []
    }

    // MARK: - Fluent Modifiers

    /// Set background behavior.
    public func backgroundBehavior(_ behavior: PngineBackgroundBehavior) -> Self {
        var copy = self
        copy.backgroundBehavior = behavior
        return copy
    }

    /// Set animation playback speed.
    public func animationSpeed(_ speed: Float) -> Self {
        var copy = self
        copy.animationSpeed = speed
        return copy
    }

    /// Set target frame rate.
    public func targetFrameRate(_ rate: Int) -> Self {
        var copy = self
        copy.targetFrameRate = rate
        return copy
    }

    /// Configure the underlying PngineAnimationView directly.
    public func configure(_ configure: @escaping (PngineAnimationView) -> Void) -> Self {
        var copy = self
        copy.configurations.append(configure)
        return copy
    }

    private func configureView(_ view: PngineAnimationView) {
        view.backgroundBehavior = backgroundBehavior
        view.animationSpeed = animationSpeed
        view.targetFrameRate = targetFrameRate

        for config in configurations {
            config(view)
        }

        view.load(bytecode: bytecode)
    }

    private func updatePlaybackState(_ view: PngineAnimationView) {
        view.backgroundBehavior = backgroundBehavior
        view.animationSpeed = animationSpeed
        view.targetFrameRate = targetFrameRate

        for config in configurations {
            config(view)
        }

        // Sync playback state with binding
        if isPlaying && !view.isPlaying {
            view.play()
        } else if !isPlaying && view.isPlaying {
            view.pause()
        }
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        configureView(view)
        if isPlaying {
            view.play()
        }
        return view
    }

    public func updateUIView(_ uiView: PngineAnimationView, context: Context) {
        updatePlaybackState(uiView)
    }
    #elseif os(macOS)
    public func makeNSView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        configureView(view)
        if isPlaying {
            view.play()
        }
        return view
    }

    public func updateNSView(_ nsView: PngineAnimationView, context: Context) {
        updatePlaybackState(nsView)
    }
    #endif
}

// MARK: - DisplayLink Proxy (breaks retain cycle)

/// Weak proxy to break the CADisplayLink -> View retain cycle.
/// CADisplayLink retains its target strongly, so we use this proxy
/// with a weak reference back to the view.
@available(iOS 14.0, macOS 11.0, *)
private class DisplayLinkProxy {
    weak var target: PngineAnimationView?

    init(_ target: PngineAnimationView) {
        self.target = target
    }

    @objc func handleDisplayLink(_ link: CADisplayLink) {
        target?.render(link)
    }
}

// MARK: - UIKit/AppKit View

@available(iOS 14.0, macOS 11.0, *)
public class PngineAnimationView: PlatformView {

    private var metalLayer: CAMetalLayer!
    private var animation: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var startTime: CFTimeInterval = 0
    private var pausedTime: CFTimeInterval = 0
    private var _isPlaying = false
    private var pendingBytecode: Data?
    private var shouldAutoPlay = false
    private var hasLoadedAnimation = false

    // MARK: - Playback Properties

    /// Controls animation behavior when the app enters background.
    public var backgroundBehavior: PngineBackgroundBehavior = .pauseAndRestore

    /// Animation playback speed multiplier. Default is 1.0 (normal speed).
    /// Values > 1.0 speed up, values < 1.0 slow down. Negative values play in reverse.
    public var animationSpeed: Float = 1.0

    /// Target frame rate for the display link. Set to 0 for maximum (default).
    /// Lower values can save battery for simple animations.
    public var targetFrameRate: Int = 0 {
        didSet {
            updateDisplayLinkFrameRate()
        }
    }

    // MARK: - Lifecycle State

    /// Whether animation was playing before entering background.
    private var wasPlayingBeforeBackground = false

    /// Error rate limiting for render failures
    private var lastErrorLogTime: CFTimeInterval = 0
    private var consecutiveErrorCount: Int = 0

    /// Current playback time in seconds.
    /// - Note: Must be accessed from main thread only.
    public var currentTime: Float {
        get {
            assert(Thread.isMainThread, "currentTime must be accessed on main thread")
            if _isPlaying {
                return Float(CACurrentMediaTime() - startTime)
            } else {
                return Float(pausedTime - startTime)
            }
        }
        set {
            assert(Thread.isMainThread, "currentTime must be set on main thread")
            let now = CACurrentMediaTime()
            startTime = now - CFTimeInterval(newValue)
            pausedTime = now
            // Render the new frame if not playing
            if !_isPlaying, let anim = animation {
                _ = pngine_render(anim, newValue)
            }
        }
    }

    /// Whether the animation is currently playing.
    public var isPlaying: Bool {
        return _isPlaying
    }

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupMetalLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetalLayer()
    }

    private func setupMetalLayer() {
        metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Scale will be set properly in updateMetalLayerSize() when we have window context

        #if os(iOS)
        layer.addSublayer(metalLayer)
        #elseif os(macOS)
        wantsLayer = true
        layer = metalLayer
        #endif

        // Initialize PNGine if needed
        if !pngine_is_initialized() {
            let error = pngineInit()
            if error != .ok {
                pngineLogger.error("Failed to initialize PNGine runtime: \(error.errorDescription ?? "unknown")")
            }
        }
    }

    #if os(iOS)
    public override func layoutSubviews() {
        super.layoutSubviews()
        updateMetalLayerSize()
    }
    #elseif os(macOS)
    public override func layout() {
        super.layout()
        updateMetalLayerSize()
    }
    #endif

    private func updateMetalLayerSize() {
        metalLayer.frame = bounds

        // Get scale from window context (avoids deprecated UIScreen.main)
        #if os(iOS)
        let scale = window?.screen.scale ?? UITraitCollection.current.displayScale
        #elseif os(macOS)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        #endif
        metalLayer.contentsScale = scale

        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)

        metalLayer.drawableSize = CGSize(width: Int(width), height: Int(height))

        // Load pending bytecode now that we have a valid size
        if let bytecode = pendingBytecode, width > 0, height > 0, !hasLoadedAnimation {
            pngineLogger.info("Layout complete - loading deferred bytecode, size: \(width)x\(height)")
            pendingBytecode = nil
            loadBytecodeInternal(bytecode, width: width, height: height)
        }

        if let anim = animation, width > 0, height > 0 {
            pngine_resize(anim, width, height)
        }
    }

    // MARK: - Public API

    /// Load animation from bytecode data.
    public func load(bytecode: Data) {
        let scale = metalLayer.contentsScale
        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)

        pngineLogger.info("load() called - size: \(width)x\(height), bytecode: \(bytecode.count) bytes")

        // If view has zero size, defer loading until layout
        guard width > 0, height > 0 else {
            pngineLogger.info("Deferring load until layout (zero size)")
            pendingBytecode = bytecode
            return
        }

        loadBytecodeInternal(bytecode, width: width, height: height)
    }

    private func loadBytecodeInternal(_ bytecode: Data, width: UInt32, height: UInt32) {
        // Destroy existing animation
        if let existing = animation {
            pngine_destroy(existing)
            animation = nil
        }

        bytecode.withUnsafeBytes { ptr in
            let layerPtr = Unmanaged.passUnretained(metalLayer).toOpaque()
            pngineLogger.info("Calling pngine_create with layer: \(layerPtr), size: \(width)x\(height)")
            animation = pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                layerPtr,
                width,
                height
            )
        }

        if animation == nil {
            let errorMsg = pngineLastError() ?? "Unknown error"
            pngineLogger.error("Failed to create animation: \(errorMsg)")
        } else {
            pngineLogger.info("Animation created successfully")
            hasLoadedAnimation = true

            // Start playing if we were waiting
            if shouldAutoPlay {
                shouldAutoPlay = false
                play()
            }
        }
    }

    /// Start animation playback.
    /// - Note: Must be called from main thread.
    public func play() {
        assert(Thread.isMainThread, "play() must be called on main thread")
        pngineLogger.info("play() called - animation: \(animation != nil), isPlaying: \(_isPlaying)")

        // If animation not loaded yet, defer play until it is
        guard animation != nil else {
            pngineLogger.info("play() deferred - animation not loaded yet")
            shouldAutoPlay = true
            return
        }

        guard !_isPlaying else {
            pngineLogger.info("play() - already playing")
            return
        }

        // Resume from paused time if we have one
        let now = CACurrentMediaTime()
        if pausedTime > 0 {
            // Adjust start time to maintain continuity
            let pausedDuration = pausedTime - startTime
            startTime = now - pausedDuration
        } else {
            startTime = now
        }

        _isPlaying = true
        consecutiveErrorCount = 0

        // Use proxy to break retain cycle (CADisplayLink retains target strongly)
        displayLinkProxy = DisplayLinkProxy(self)
        displayLink = CADisplayLink(target: displayLinkProxy!, selector: #selector(DisplayLinkProxy.handleDisplayLink(_:)))
        displayLink?.add(to: .main, forMode: .common)
        updateDisplayLinkFrameRate()
        pngineLogger.info("Display link started")
    }

    private func updateDisplayLinkFrameRate() {
        guard let displayLink = displayLink else { return }
        displayLink.preferredFramesPerSecond = targetFrameRate
    }

    /// Pause animation playback.
    /// - Note: Must be called from main thread.
    public func pause() {
        assert(Thread.isMainThread, "pause() must be called on main thread")
        guard _isPlaying else { return }
        pausedTime = CACurrentMediaTime()
        _isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    /// Stop animation and reset to beginning.
    public func stop() {
        pause()
        startTime = CACurrentMediaTime()
        pausedTime = 0

        // Render at t=0
        if let anim = animation {
            let error = pngineRender(anim, time: 0)
            if error != .ok {
                pngineLogger.error("Render at t=0 failed: \(error.errorDescription ?? "unknown")")
            }
        }
    }

    /// Render a single frame at the specified time.
    /// Returns the error if any occurred.
    @discardableResult
    public func draw(at time: Float) -> PngineError {
        guard let anim = animation else {
            return .invalidArgument
        }
        return pngineRender(anim, time: time)
    }

    // MARK: - Display Link

    private var renderCount = 0

    /// Called by DisplayLinkProxy - must be fileprivate for proxy access.
    fileprivate func render(_ link: CADisplayLink) {
        guard let anim = animation else {
            // Animation became nil while display link was running
            pngineLogger.warn("render() called but animation is nil - stopping display link")
            displayLink?.invalidate()
            displayLink = nil
            displayLinkProxy = nil
            _isPlaying = false
            return
        }

        // Apply animation speed to elapsed time
        let elapsed = Float(link.timestamp - startTime) * animationSpeed

        // Log first few renders for debugging
        if renderCount < 3 {
            pngineLogger.info("render() #\(renderCount) - time: \(elapsed)")
            let status = pngine_debug_frame(anim, elapsed)
            pngineLogger.info("debug_frame returned: \(status)")
            renderCount += 1
        } else {
            let error = pngineRender(anim, time: elapsed)
            if error != .ok {
                // Rate-limit error logging (once per second)
                let now = CACurrentMediaTime()
                if lastErrorLogTime == 0 || now - lastErrorLogTime > 1.0 {
                    pngineLogger.error("Render failed: \(error.errorDescription ?? "unknown") (count: \(consecutiveErrorCount))")
                    lastErrorLogTime = now
                }
                consecutiveErrorCount += 1

                // Stop animation after too many consecutive failures
                if consecutiveErrorCount > 180 {  // ~3 seconds at 60fps
                    pngineLogger.error("Too many consecutive render failures, stopping animation")
                    pause()
                }
            } else {
                consecutiveErrorCount = 0
            }
        }
    }

    // MARK: - Cleanup

    deinit {
        #if os(iOS)
        removeNotificationObservers()
        #endif
        displayLink?.invalidate()
        if let anim = animation {
            pngine_destroy(anim)
        }
    }
}

// MARK: - Lifecycle & Notification Handling

@available(iOS 14.0, macOS 11.0, *)
extension PngineAnimationView {
    #if os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            setupNotificationObservers()
        } else {
            removeNotificationObservers()
        }
    }

    private func setupNotificationObservers() {
        let center = NotificationCenter.default

        // Memory warning
        center.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Background/foreground
        center.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        center.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        pngineLogger.info("Notification observers registered")
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        center.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        pngineLogger.info("Notification observers removed")
    }
    #endif

    @objc private func handleMemoryWarning() {
        pngineLogger.warn("Memory warning received")
        pngine_memory_warning()
    }

    @objc private func applicationDidEnterBackground() {
        wasPlayingBeforeBackground = _isPlaying

        switch backgroundBehavior {
        case .stop:
            pngineLogger.info("Background: stopping animation")
            stop()
        case .pause:
            pngineLogger.info("Background: pausing animation")
            pause()
        case .pauseAndRestore:
            pngineLogger.info("Background: pausing animation (will restore)")
            pause()
        }
    }

    @objc private func applicationWillEnterForeground() {
        guard backgroundBehavior == .pauseAndRestore else { return }
        guard wasPlayingBeforeBackground else {
            pngineLogger.info("Foreground: was not playing before background")
            return
        }

        pngineLogger.info("Foreground: restoring playback")
        play()
    }
}
