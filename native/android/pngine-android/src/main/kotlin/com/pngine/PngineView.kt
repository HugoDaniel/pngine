/**
 * PngineView - Android SurfaceView for PNGine animations
 *
 * Usage:
 * ```kotlin
 * val pngineView = PngineView(context)
 * pngineView.load(bytecodeData)
 * pngineView.play()
 * ```
 */
package com.pngine

import android.content.Context
import android.util.AttributeSet
import android.view.Choreographer
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView

class PngineView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : SurfaceView(context, attrs, defStyleAttr), SurfaceHolder.Callback {

    private var animationPtr: Long = 0
    private var isPlaying = false
    private var startTimeNanos: Long = 0

    private val choreographer = Choreographer.getInstance()

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (isPlaying && animationPtr != 0L) {
                val elapsedSeconds = (frameTimeNanos - startTimeNanos) / 1_000_000_000f
                nativeRender(animationPtr, elapsedSeconds)
                choreographer.postFrameCallback(this)
            }
        }
    }

    init {
        holder.addCallback(this)

        // Initialize PNGine if needed
        if (!nativeIsInitialized()) {
            val result = nativeInit()
            if (result != 0) {
                throw RuntimeException("Failed to initialize PNGine runtime")
            }
        }
    }

    // MARK: - Public API

    /**
     * Load animation from bytecode data.
     */
    fun load(bytecode: ByteArray) {
        // Wait for surface to be available
        if (!holder.surface.isValid) {
            // Queue load for when surface is ready
            post { load(bytecode) }
            return
        }

        // Destroy existing animation
        if (animationPtr != 0L) {
            nativeDestroy(animationPtr)
            animationPtr = 0
        }

        animationPtr = nativeCreate(bytecode, holder.surface, width, height)
        if (animationPtr == 0L) {
            throw RuntimeException("Failed to create animation: ${nativeGetError()}")
        }
    }

    /**
     * Start animation playback.
     */
    fun play() {
        if (animationPtr == 0L || isPlaying) return

        isPlaying = true
        startTimeNanos = System.nanoTime()
        choreographer.postFrameCallback(frameCallback)
    }

    /**
     * Pause animation playback.
     */
    fun pause() {
        isPlaying = false
        choreographer.removeFrameCallback(frameCallback)
    }

    /**
     * Stop animation and reset to beginning.
     */
    fun stop() {
        pause()
        startTimeNanos = System.nanoTime()

        // Render at t=0
        if (animationPtr != 0L) {
            nativeRender(animationPtr, 0f)
        }
    }

    /**
     * Render a single frame at the specified time.
     */
    fun draw(time: Float) {
        if (animationPtr != 0L) {
            nativeRender(animationPtr, time)
        }
    }

    // MARK: - SurfaceHolder.Callback

    override fun surfaceCreated(holder: SurfaceHolder) {
        // Surface ready - animation can be loaded now
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
        if (animationPtr != 0L && width > 0 && height > 0) {
            nativeResize(animationPtr, width, height)
        }
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        pause()
        if (animationPtr != 0L) {
            nativeDestroy(animationPtr)
            animationPtr = 0
        }
    }

    // MARK: - Cleanup

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        pause()
        if (animationPtr != 0L) {
            nativeDestroy(animationPtr)
            animationPtr = 0
        }
    }

    // MARK: - Memory

    fun onLowMemory() {
        nativeMemoryWarning()
    }

    // MARK: - Native Methods

    private external fun nativeInit(): Int
    private external fun nativeShutdown()
    private external fun nativeIsInitialized(): Boolean
    private external fun nativeMemoryWarning()

    private external fun nativeCreate(
        bytecode: ByteArray,
        surface: Surface,
        width: Int,
        height: Int
    ): Long

    private external fun nativeRender(ptr: Long, time: Float)
    private external fun nativeResize(ptr: Long, width: Int, height: Int)
    private external fun nativeDestroy(ptr: Long)
    private external fun nativeGetError(): String?

    companion object {
        init {
            System.loadLibrary("pngine")
        }

        /**
         * Get PNGine version string.
         */
        @JvmStatic
        external fun version(): String
    }
}
