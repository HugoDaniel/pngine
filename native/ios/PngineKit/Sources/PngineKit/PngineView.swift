/**
 * PngineView - SwiftUI wrapper for PNGine animations
 *
 * Usage:
 * ```swift
 * import PngineKit
 *
 * struct ContentView: View {
 *     var body: some View {
 *         PngineView(bytecode: myBytecodeData)
 *             .frame(width: 300, height: 300)
 *     }
 * }
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

// MARK: - SwiftUI View

@available(iOS 14.0, macOS 11.0, *)
public struct PngineView: ViewRepresentable {
    private let bytecode: Data
    private let autoPlay: Bool

    public init(bytecode: Data, autoPlay: Bool = true) {
        self.bytecode = bytecode
        self.autoPlay = autoPlay
    }

    #if os(iOS)
    public func makeUIView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        view.load(bytecode: bytecode)
        if autoPlay {
            view.play()
        }
        return view
    }

    public func updateUIView(_ uiView: PngineAnimationView, context: Context) {}
    #elseif os(macOS)
    public func makeNSView(context: Context) -> PngineAnimationView {
        let view = PngineAnimationView()
        view.load(bytecode: bytecode)
        if autoPlay {
            view.play()
        }
        return view
    }

    public func updateNSView(_ nsView: PngineAnimationView, context: Context) {}
    #endif
}

// MARK: - UIKit/AppKit View

@available(iOS 14.0, macOS 11.0, *)
public class PngineAnimationView: PlatformView {

    private var metalLayer: CAMetalLayer!
    private var animation: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var isPlaying = false
    private var pendingBytecode: Data?
    private var shouldAutoPlay = false
    private var hasLoadedAnimation = false

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
        metalLayer.contentsScale = UIScreen.main.scale

        #if os(iOS)
        layer.addSublayer(metalLayer)
        #elseif os(macOS)
        wantsLayer = true
        layer = metalLayer
        #endif

        // Initialize PNGine if needed
        if !pngine_is_initialized() {
            let result = pngine_init()
            if result != 0 {
                NSLog("[PngineKit] Failed to initialize PNGine runtime")
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

        let scale = metalLayer.contentsScale
        let width = UInt32(bounds.width * scale)
        let height = UInt32(bounds.height * scale)

        metalLayer.drawableSize = CGSize(width: Int(width), height: Int(height))

        // Load pending bytecode now that we have a valid size
        if let bytecode = pendingBytecode, width > 0, height > 0, !hasLoadedAnimation {
            NSLog("[PngineKit] Layout complete - loading deferred bytecode, size: \(width)x\(height)")
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

        NSLog("[PngineKit] load() called - size: \(width)x\(height), bytecode: \(bytecode.count) bytes")

        // If view has zero size, defer loading until layout
        guard width > 0, height > 0 else {
            NSLog("[PngineKit] Deferring load until layout (zero size)")
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
            NSLog("[PngineKit] Calling pngine_create with layer: \(layerPtr), size: \(width)x\(height)")
            animation = pngine_create(
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                ptr.count,
                layerPtr,
                width,
                height
            )
        }

        if animation == nil {
            let error = pngineLastError() ?? "Unknown error"
            NSLog("[PngineKit] Failed to create animation: \(error)")
        } else {
            NSLog("[PngineKit] Animation created successfully: \(animation!)")
            hasLoadedAnimation = true

            // Start playing if we were waiting
            if shouldAutoPlay {
                shouldAutoPlay = false
                play()
            }
        }
    }

    /// Start animation playback.
    public func play() {
        NSLog("[PngineKit] play() called - animation: \(String(describing: animation)), isPlaying: \(isPlaying)")

        // If animation not loaded yet, defer play until it is
        guard animation != nil else {
            NSLog("[PngineKit] play() deferred - animation not loaded yet")
            shouldAutoPlay = true
            return
        }

        guard !isPlaying else {
            NSLog("[PngineKit] play() - already playing")
            return
        }

        isPlaying = true
        startTime = CACurrentMediaTime()

        displayLink = CADisplayLink(target: self, selector: #selector(render(_:)))
        displayLink?.add(to: .main, forMode: .common)
        NSLog("[PngineKit] Display link started")
    }

    /// Pause animation playback.
    public func pause() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Stop animation and reset to beginning.
    public func stop() {
        pause()
        startTime = CACurrentMediaTime()

        // Render at t=0
        if let anim = animation {
            pngine_render(anim, 0)
        }
    }

    /// Render a single frame at the specified time.
    public func draw(at time: Float) {
        if let anim = animation {
            pngine_render(anim, time)
        }
    }

    // MARK: - Display Link

    private var renderCount = 0

    @objc private func render(_ link: CADisplayLink) {
        guard let anim = animation else { return }

        let elapsed = Float(link.timestamp - startTime)

        // Log first few renders
        if renderCount < 3 {
            NSLog("[PngineKit] render() #\(renderCount) - time: \(elapsed)")

            // Use debug function to check status
            let status = pngine_debug_frame(anim, elapsed)
            NSLog("[PngineKit] debug_frame returned: \(status)")
            renderCount += 1
        } else {
            pngine_render(anim, elapsed)
        }
    }

    // MARK: - Cleanup

    deinit {
        displayLink?.invalidate()
        if let anim = animation {
            pngine_destroy(anim)
        }
    }
}

// MARK: - Memory Warning Handler

@available(iOS 14.0, macOS 11.0, *)
extension PngineAnimationView {
    #if os(iOS)
    public override func didMoveToWindow() {
        super.didMoveToWindow()

        if window != nil {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        } else {
            NotificationCenter.default.removeObserver(
                self,
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }
    }
    #endif

    @objc private func handleMemoryWarning() {
        pngine_memory_warning()
    }
}
