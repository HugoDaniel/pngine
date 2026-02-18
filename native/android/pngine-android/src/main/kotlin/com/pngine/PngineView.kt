/**
 * PngineView — Android SurfaceView for PNGine animations.
 *
 * The Android equivalent of iOS's PngineAnimationView.
 * Uses SurfaceView + Choreographer for GPU rendering via wgpu-native (Vulkan).
 *
 * Basic Usage (XML):
 * ```xml
 * <com.pngine.PngineView
 *     android:id="@+id/pngineView"
 *     android:layout_width="300dp"
 *     android:layout_height="300dp" />
 * ```
 *
 * Basic Usage (Kotlin):
 * ```kotlin
 * val view = PngineView(context)
 * view.load(bytecodeData)
 * view.play()
 * ```
 */
package com.pngine

import android.content.Context
import android.os.Looper
import android.os.SystemClock
import android.util.AttributeSet
import android.view.Choreographer
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

class PngineView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : SurfaceView(context, attrs, defStyleAttr),
    SurfaceHolder.Callback,
    Choreographer.FrameCallback,
    DefaultLifecycleObserver {

    // ========================================================================
    // Native methods (JNI bridge → pngine_jni.c)
    // ========================================================================

    private external fun nativeInit(): Int
    private external fun nativeShutdown()
    private external fun nativeIsInitialized(): Boolean
    private external fun nativeMemoryWarning()
    private external fun nativeCreate(bytecode: ByteArray, surface: Surface, width: Int, height: Int): Long
    private external fun nativeRender(ptr: Long, time: Float)
    private external fun nativeResize(ptr: Long, width: Int, height: Int)
    private external fun nativeDestroy(ptr: Long)
    private external fun nativeGetError(): String?

    // ========================================================================
    // State
    // ========================================================================

    /** Native animation pointer (0 = no animation). */
    private var nativePtr: Long = 0

    /** Whether the animation loop is running. */
    private var _isPlaying = false

    /** Monotonic start time in nanoseconds. */
    private var startTimeNanos: Long = 0

    /** Time at which we paused, in nanoseconds since startTimeNanos. */
    private var pausedElapsedNanos: Long = 0

    /** Bytecode waiting to be loaded once the surface is ready. */
    private var pendingBytecode: ByteArray? = null

    /** Whether play() was called before the surface/animation was ready. */
    private var shouldAutoPlay = false

    /** Whether we have successfully loaded an animation. */
    private var hasLoadedAnimation = false

    /** Whether the surface is currently available. */
    private var surfaceReady = false

    /** Whether animation was playing before entering background. */
    private var wasPlayingBeforeBackground = false

    /** Error rate limiting: timestamp of last error log. */
    private var lastErrorLogTimeMs: Long = 0

    /** Consecutive render error count. */
    private var consecutiveErrorCount: Int = 0

    /** Count of rendered frames (for debug logging). */
    private var renderCount: Int = 0

    private val logger get() = Pngine.logger

    // ========================================================================
    // Public properties
    // ========================================================================

    /** Controls animation behavior when the app enters background. */
    var backgroundBehavior: PngineBackgroundBehavior = PngineBackgroundBehavior.PAUSE_AND_RESTORE

    /** Animation playback speed multiplier. Default is 1.0 (normal speed). */
    var animationSpeed: Float = 1.0f

    /** Whether the animation is currently playing. */
    val isPlaying: Boolean get() = _isPlaying

    /**
     * Current playback time in seconds.
     * Must be accessed from the main thread.
     */
    var currentTime: Float
        get() {
            assertMainThread("currentTime")
            return if (_isPlaying) {
                val elapsed = SystemClock.elapsedRealtimeNanos() - startTimeNanos
                (elapsed / 1_000_000_000.0f)
            } else {
                pausedElapsedNanos / 1_000_000_000.0f
            }
        }
        set(value) {
            assertMainThread("currentTime")
            val now = SystemClock.elapsedRealtimeNanos()
            startTimeNanos = now - (value * 1_000_000_000.0f).toLong()
            pausedElapsedNanos = (value * 1_000_000_000.0f).toLong()
            // Render the new frame if not playing
            if (!_isPlaying && nativePtr != 0L) {
                nativeRender(nativePtr, value)
            }
        }

    // ========================================================================
    // Initialization
    // ========================================================================

    init {
        holder.addCallback(this)

        // Observe app lifecycle for background/foreground
        ProcessLifecycleOwner.get().lifecycle.addObserver(this)
    }

    // ========================================================================
    // SurfaceHolder.Callback
    // ========================================================================

    override fun surfaceCreated(holder: SurfaceHolder) {
        logger.info("surfaceCreated")
        surfaceReady = true

        // Initialize PNGine runtime if needed
        if (!nativeIsInitialized()) {
            val result = nativeInit()
            if (result != 0) {
                val error = PngineError.fromCode(result)
                logger.error("Failed to initialize PNGine runtime: ${error.description}")
                return
            }
        }

        // Load pending bytecode now that surface is available
        pendingBytecode?.let { bytecode ->
            pendingBytecode = null
            loadBytecodeInternal(bytecode, holder.surface, width, height)
        }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        logger.info("surfaceChanged: ${width}x${height}")
        if (nativePtr != 0L && width > 0 && height > 0) {
            nativeResize(nativePtr, width, height)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        logger.info("surfaceDestroyed")
        surfaceReady = false
        stopAnimation()

        // Destroy native animation — surface is going away
        if (nativePtr != 0L) {
            nativeDestroy(nativePtr)
            nativePtr = 0
            hasLoadedAnimation = false
        }
    }

    // ========================================================================
    // Public API
    // ========================================================================

    /**
     * Load animation from bytecode data.
     */
    fun load(bytecode: ByteArray) {
        assertMainThread("load")
        logger.info("load() called - surface ready: $surfaceReady, bytecode: ${bytecode.size} bytes")

        if (!surfaceReady || width <= 0 || height <= 0) {
            logger.info("Deferring load until surface is ready")
            pendingBytecode = bytecode
            return
        }

        loadBytecodeInternal(bytecode, holder.surface, width, height)
    }

    /**
     * Start animation playback.
     * Must be called from the main thread.
     */
    fun play() {
        assertMainThread("play")
        logger.info("play() called - nativePtr: ${nativePtr != 0L}, isPlaying: $_isPlaying")

        // If animation not loaded yet, defer play until it is
        if (nativePtr == 0L) {
            logger.info("play() deferred - animation not loaded yet")
            shouldAutoPlay = true
            return
        }

        if (_isPlaying) {
            logger.info("play() - already playing")
            return
        }

        // Resume from paused time if we have one
        val now = SystemClock.elapsedRealtimeNanos()
        if (pausedElapsedNanos > 0) {
            startTimeNanos = now - pausedElapsedNanos
        } else {
            startTimeNanos = now
        }

        _isPlaying = true
        consecutiveErrorCount = 0

        // Start the Choreographer render loop
        Choreographer.getInstance().postFrameCallback(this)
        logger.info("Choreographer frame callback started")
    }

    /**
     * Pause animation playback.
     * Must be called from the main thread.
     */
    fun pause() {
        assertMainThread("pause")
        if (!_isPlaying) return

        pausedElapsedNanos = SystemClock.elapsedRealtimeNanos() - startTimeNanos
        stopAnimation()
    }

    /**
     * Stop animation and reset to beginning.
     */
    fun stop() {
        stopAnimation()
        startTimeNanos = SystemClock.elapsedRealtimeNanos()
        pausedElapsedNanos = 0

        // Render at t=0
        if (nativePtr != 0L) {
            nativeRender(nativePtr, 0f)
        }
    }

    /**
     * Render a single frame at the specified time.
     * Returns the error if any occurred.
     */
    fun draw(time: Float): PngineError {
        if (nativePtr == 0L) {
            return PngineError.INVALID_ARGUMENT
        }
        nativeRender(nativePtr, time)
        val errorStr = nativeGetError()
        return if (errorStr != null) PngineError.RENDER_FAILED else PngineError.OK
    }

    // ========================================================================
    // Choreographer.FrameCallback
    // ========================================================================

    override fun doFrame(frameTimeNanos: Long) {
        if (!_isPlaying || nativePtr == 0L) {
            if (nativePtr == 0L && _isPlaying) {
                logger.warn("doFrame() called but animation is nil - stopping")
                stopAnimation()
            }
            return
        }

        // Apply animation speed to elapsed time
        val elapsedNanos = frameTimeNanos - startTimeNanos
        val elapsedSeconds = (elapsedNanos / 1_000_000_000.0f) * animationSpeed

        // Debug logging for first few frames
        if (renderCount < 3) {
            logger.info("doFrame() #$renderCount - time: $elapsedSeconds")
            renderCount++
        }

        nativeRender(nativePtr, elapsedSeconds)

        // Check for errors via nativeGetError
        val errorStr = nativeGetError()
        if (errorStr != null) {
            val now = SystemClock.elapsedRealtime()
            if (lastErrorLogTimeMs == 0L || now - lastErrorLogTimeMs > 1000) {
                logger.error("Render failed: $errorStr (count: $consecutiveErrorCount)")
                lastErrorLogTimeMs = now
            }
            consecutiveErrorCount++

            // Stop after too many consecutive failures (~3 seconds at 60fps)
            if (consecutiveErrorCount > 180) {
                logger.error("Too many consecutive render failures, stopping animation")
                stopAnimation()
                return
            }
        } else {
            consecutiveErrorCount = 0
        }

        // Schedule next frame
        if (_isPlaying) {
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    // ========================================================================
    // Lifecycle (background/foreground)
    // ========================================================================

    override fun onStop(owner: LifecycleOwner) {
        wasPlayingBeforeBackground = _isPlaying

        when (backgroundBehavior) {
            PngineBackgroundBehavior.STOP -> {
                logger.info("Background: stopping animation")
                stop()
            }
            PngineBackgroundBehavior.PAUSE,
            PngineBackgroundBehavior.PAUSE_AND_RESTORE -> {
                logger.info("Background: pausing animation")
                pause()
            }
        }
    }

    override fun onStart(owner: LifecycleOwner) {
        if (backgroundBehavior != PngineBackgroundBehavior.PAUSE_AND_RESTORE) return
        if (!wasPlayingBeforeBackground) {
            logger.info("Foreground: was not playing before background")
            return
        }

        logger.info("Foreground: restoring playback")
        play()
    }

    // ========================================================================
    // Memory pressure
    // ========================================================================

    /**
     * Call this when receiving memory warnings (e.g., from ComponentCallbacks2.onTrimMemory).
     */
    fun onMemoryWarning() {
        logger.warn("Memory warning received")
        nativeMemoryWarning()
    }

    // ========================================================================
    // Cleanup
    // ========================================================================

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        ProcessLifecycleOwner.get().lifecycle.removeObserver(this)
        stopAnimation()
        if (nativePtr != 0L) {
            nativeDestroy(nativePtr)
            nativePtr = 0
        }
    }

    // ========================================================================
    // Internal
    // ========================================================================

    private fun loadBytecodeInternal(bytecode: ByteArray, surface: Surface, width: Int, height: Int) {
        // Destroy existing animation
        if (nativePtr != 0L) {
            nativeDestroy(nativePtr)
            nativePtr = 0
        }

        logger.info("Creating animation with surface, size: ${width}x${height}")
        nativePtr = nativeCreate(bytecode, surface, width, height)

        if (nativePtr == 0L) {
            val errorMsg = nativeGetError() ?: "Unknown error"
            logger.error("Failed to create animation: $errorMsg")
        } else {
            logger.info("Animation created successfully")
            hasLoadedAnimation = true

            // Start playing if we were waiting
            if (shouldAutoPlay) {
                shouldAutoPlay = false
                play()
            }
        }
    }

    private fun stopAnimation() {
        _isPlaying = false
        Choreographer.getInstance().removeFrameCallback(this)
    }

    private fun assertMainThread(methodName: String) {
        check(Looper.getMainLooper().isCurrentThread) {
            "$methodName() must be called on the main thread"
        }
    }

    companion object {
        init {
            System.loadLibrary("pngine")
        }

        /** Get PNGine version string. */
        @JvmStatic
        external fun version(): String
    }
}
